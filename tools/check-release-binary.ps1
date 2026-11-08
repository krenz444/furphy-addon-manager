<#
.SYNOPSIS
Release gate: proves a built Furphy exe can start on a PC that has nothing but Windows.

.DESCRIPTION
Two checks; both must pass.

1. Import table. Every DLL the exe imports directly must ship with Windows (allowlist
   below). Delay-loaded DLLs must be ones the installer writes next to the app
   (-AllowedDelayLoad). A direct import of anything else stops the exe in the Windows
   loader before main() runs, which is how v2.0.0 to v2.0.25 failed on clean PCs with
   "libunwind.dll was not found".

2. Clean start. The exe is copied ALONE into an empty folder (spaces, parentheses and a
   non-ASCII letter in the name) and run with --loader-check, a PATH that holds only
   Windows folders, and Windows error dialogs suppressed. Exit code 0 plus the
   "loader-ok" line is a pass.

Both checks are needed. This PC's System32 also holds DLLs that other software
installed (Visual C++ runtimes and the like), so the clean start alone can pass here and
still fail on a fresh PC. The allowlist alone cannot see a system DLL that is present but
lacks an entry point the exe needs.

The exe is only run when it contains the --loader-check handler. Without it, a file
named *Setup*.exe would enter installer mode and install over this PC's copy.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File tools\check-release-binary.ps1 -ExePath target\release-assets\FurphyAddonManager-Setup.exe -ExpectedVersion 2.0.26
#>
param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [string]$ExpectedVersion,
    [string[]]$AllowedDelayLoad = @('WebView2Loader.dll'),
    [int]$TimeoutSec = 30
)

$ErrorActionPreference = 'Stop'

# DLLs that ship with every supported Windows 10/11 install. Anything else imported
# directly (vcruntime140.dll, libunwind.dll, libc++.dll, libwinpthread-1.dll,
# WebView2Loader.dll, ...) has to be removed, static-linked or delay-loaded.
$SystemDlls = @(
    'advapi32.dll', 'bcrypt.dll', 'bcryptprimitives.dll', 'cfgmgr32.dll', 'combase.dll',
    'comctl32.dll', 'comdlg32.dll', 'crypt32.dll', 'd2d1.dll', 'd3d11.dll', 'dbghelp.dll',
    'dwmapi.dll', 'dwrite.dll', 'dxgi.dll', 'gdi32.dll', 'gdiplus.dll', 'imm32.dll',
    'iphlpapi.dll', 'kernel32.dll', 'kernelbase.dll', 'msimg32.dll', 'msvcrt.dll',
    'mswsock.dll', 'ncrypt.dll', 'netapi32.dll', 'ntdll.dll', 'ole32.dll', 'oleacc.dll',
    'oleaut32.dll', 'powrprof.dll', 'propsys.dll', 'psapi.dll', 'rpcrt4.dll',
    'secur32.dll', 'setupapi.dll', 'shcore.dll', 'shell32.dll', 'shlwapi.dll',
    'ucrtbase.dll', 'uiautomationcore.dll', 'urlmon.dll', 'user32.dll', 'userenv.dll',
    'uxtheme.dll', 'version.dll', 'winhttp.dll', 'wininet.dll', 'winmm.dll',
    'winspool.drv', 'ws2_32.dll', 'wtsapi32.dll'
)

function Test-SystemDll([string]$Name) {
    $n = $Name.ToLowerInvariant()
    if ($n -like 'api-ms-win-*.dll') { return $true }
    return ($SystemDlls -contains $n)
}

if (-not ('FurphyGate.PeImports' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace FurphyGate {
    public class PeImportList {
        public List<string> Imports = new List<string>();
        public List<string> DelayImports = new List<string>();
        public ushort Machine;
    }

    public static class PeImports {
        public static PeImportList Read(string path) {
            byte[] b = File.ReadAllBytes(path);
            if (b.Length < 0x40 || b[0] != (byte)'M' || b[1] != (byte)'Z') throw new InvalidDataException("not an MZ executable");
            int pe = BitConverter.ToInt32(b, 0x3C);
            if (b[pe] != (byte)'P' || b[pe + 1] != (byte)'E' || b[pe + 2] != 0 || b[pe + 3] != 0) throw new InvalidDataException("no PE signature");
            PeImportList r = new PeImportList();
            r.Machine = BitConverter.ToUInt16(b, pe + 4);
            int sectionCount = BitConverter.ToUInt16(b, pe + 6);
            int optSize = BitConverter.ToUInt16(b, pe + 20);
            int opt = pe + 24;
            bool plus = BitConverter.ToUInt16(b, opt) == 0x20b;
            ulong imageBase = plus ? BitConverter.ToUInt64(b, opt + 24) : BitConverter.ToUInt32(b, opt + 28);
            int dirCount = BitConverter.ToInt32(b, opt + (plus ? 108 : 92));
            int dirs = opt + (plus ? 112 : 96);
            int sections = opt + optSize;

            Func<uint, int> offset = delegate (uint rva) {
                for (int i = 0; i < sectionCount; i++) {
                    int s = sections + i * 40;
                    uint vsize = BitConverter.ToUInt32(b, s + 8);
                    uint va = BitConverter.ToUInt32(b, s + 12);
                    uint rawSize = BitConverter.ToUInt32(b, s + 16);
                    uint rawPtr = BitConverter.ToUInt32(b, s + 20);
                    uint span = Math.Max(vsize, rawSize);
                    if (rva >= va && rva < va + span) return (int)(rva - va + rawPtr);
                }
                throw new InvalidDataException("RVA 0x" + rva.ToString("X") + " is outside every section");
            };
            Func<int, string> cstr = delegate (int o) {
                int e = o;
                while (b[e] != 0) e++;
                return Encoding.ASCII.GetString(b, o, e - o);
            };

            if (dirCount > 1) {
                uint rva = BitConverter.ToUInt32(b, dirs + 1 * 8);
                if (rva != 0) {
                    for (int o = offset(rva); ; o += 20) {
                        uint lookup = BitConverter.ToUInt32(b, o);
                        uint name = BitConverter.ToUInt32(b, o + 12);
                        uint iat = BitConverter.ToUInt32(b, o + 16);
                        if (lookup == 0 && name == 0 && iat == 0) break;
                        r.Imports.Add(cstr(offset(name)));
                    }
                }
            }
            if (dirCount > 13) {
                uint rva = BitConverter.ToUInt32(b, dirs + 13 * 8);
                if (rva != 0) {
                    for (int o = offset(rva); ; o += 32) {
                        uint attributes = BitConverter.ToUInt32(b, o);
                        uint name = BitConverter.ToUInt32(b, o + 4);
                        if (name == 0) break;
                        // Attribute bit 0 clear means the old VA-based layout.
                        uint nameRva = (attributes & 1) != 0 ? name : (uint)(name - imageBase);
                        r.DelayImports.Add(cstr(offset(nameRva)));
                    }
                }
            }
            return r;
        }
    }

    public static class ErrorMode {
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        public static extern uint SetErrorMode(uint mode);
    }
}
'@
}

# Keyed by hex text: PowerShell 5.1 reads 0xC0000135 as a negative Int32.
$NtStatus = @{
    'C0000135' = 'STATUS_DLL_NOT_FOUND: a DLL the exe imports directly is missing'
    'C0000139' = 'STATUS_ENTRYPOINT_NOT_FOUND: a DLL is present but lacks a function the exe imports'
    'C000007B' = 'STATUS_INVALID_IMAGE_FORMAT: a 32/64-bit mismatch in a loaded DLL'
    'C0000142' = 'STATUS_DLL_INIT_FAILED: a DLL failed to initialise'
}

$ExePath = (Resolve-Path -LiteralPath $ExePath).Path
$failures = New-Object System.Collections.Generic.List[string]
Write-Host "=== Release binary gate: $ExePath"

# 1. Import table
$pe = [FurphyGate.PeImports]::Read($ExePath)
if ($pe.Machine -ne 0x8664) { $failures.Add(('machine type is 0x{0:X4}, expected x64 (0x8664)' -f $pe.Machine)) }
$hard = @($pe.Imports | Sort-Object -Unique)
$delay = @($pe.DelayImports | Sort-Object -Unique)
$badHard = @($hard | Where-Object { -not (Test-SystemDll $_) })
$badDelay = @($delay | Where-Object { ($AllowedDelayLoad -notcontains $_) -and -not (Test-SystemDll $_) })
Write-Host ("  direct imports ({0}): {1}" -f $hard.Count, (($hard | Where-Object { $_ -notlike 'api-ms-win-*' }) -join ', '))
Write-Host ("  delay-loaded ({0}): {1}" -f $delay.Count, ($delay -join ', '))
foreach ($d in $badHard) { $failures.Add("direct import of a DLL that Windows does not ship: $d") }
foreach ($d in $badDelay) { $failures.Add("delay-loaded DLL that the installer does not provide: $d") }

# 2. Clean start
$bytes = [IO.File]::ReadAllBytes($ExePath)
$marker = [Text.Encoding]::ASCII.GetBytes('loader-ok')
$hasHandler = $false
for ($i = 0; $i -le $bytes.Length - $marker.Length; $i++) {
    if ($bytes[$i] -ne $marker[0]) { continue }
    $match = $true
    for ($j = 1; $j -lt $marker.Length; $j++) { if ($bytes[$i + $j] -ne $marker[$j]) { $match = $false; break } }
    if ($match) { $hasHandler = $true; break }
}
$bytes = $null

if (-not $hasHandler) {
    $failures.Add('the exe has no --loader-check handler, so the clean start was not run (running it would install over this PC)')
} else {
    $folderName = 'furphy loader check (' + [char]0x00E9 + ') ' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $iso = Join-Path ([IO.Path]::GetTempPath()) $folderName
    New-Item -ItemType Directory -Path $iso -Force | Out-Null
    $isoExe = Join-Path $iso ([IO.Path]::GetFileName($ExePath))
    Copy-Item -LiteralPath $ExePath -Destination $isoExe -Force

    $win = $env:SystemRoot
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $isoExe
    $psi.Arguments = '--loader-check'
    $psi.WorkingDirectory = $iso
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['PATH'] = "$win\System32;$win;$win\System32\Wbem;$win\System32\WindowsPowerShell\v1.0"

    # SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX: the child inherits it, so a missing
    # DLL ends the process with an NTSTATUS instead of opening a dialog.
    $previousMode = [FurphyGate.ErrorMode]::SetErrorMode(0x0003)
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } finally {
        [void][FurphyGate.ErrorMode]::SetErrorMode($previousMode)
    }
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        $failures.Add("clean start did not exit within $TimeoutSec s")
    } else {
        $proc.WaitForExit()
        $code = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$proc.ExitCode), 0)
        $stdout = $stdoutTask.Result.Trim()
        Write-Host ("  clean start: exit 0x{0:X8}, stdout '{1}'" -f $code, $stdout)
        if ($code -ne 0) {
            $why = $NtStatus[('{0:X8}' -f $code)]
            if (-not $why) { $why = 'unexpected exit code' }
            $failures.Add(('clean start failed with 0x{0:X8} ({1}); stderr: {2}' -f $code, $why, $stderrTask.Result.Trim()))
        } elseif ($stdout -notmatch 'loader-ok') {
            $failures.Add("clean start exited 0 but did not print loader-ok: '$stdout'")
        } elseif ($ExpectedVersion -and $stdout -notmatch [regex]::Escape(" $ExpectedVersion ")) {
            $failures.Add("clean start reported '$stdout', expected version $ExpectedVersion")
        }
    }
    $leftovers = @(Get-ChildItem -LiteralPath $iso -Force | Where-Object { $_.Name -ne [IO.Path]::GetFileName($ExePath) })
    if ($leftovers.Count -gt 0) { $failures.Add('--loader-check wrote files next to the exe: ' + (($leftovers | ForEach-Object { $_.Name }) -join ', ')) }
    Remove-Item -LiteralPath $iso -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host '  RESULT: FAIL'
    foreach ($f in $failures) { Write-Host "   - $f" }
    throw ("Release binary gate failed for {0}: {1}" -f $ExePath, ($failures -join '; '))
}
Write-Host '  RESULT: PASS'
