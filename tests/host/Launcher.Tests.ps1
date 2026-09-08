<#
=====================================================================
 tests\host\Launcher.Tests.ps1

 failure-modes:webview2-missing-no-fallback (complementary half) -
 "Addon Manager.vbs" automated cscript coverage.

 SPEC.md's own ACCEPTANCE for the launcher documents a 4-scenario
 cscript harness verified by hand each round: a neutered copy of the
 real launcher (every sh.Run/MsgBox side effect swapped for
 WScript.Echo, everything else byte-identical) run under cscript
 against scratch FileExists states. This file automates that same
 technique as a permanent regression test AND adds the 5th scenario
 this finding's own fixNote calls for - host build present, hostExe
 simulated/stubbed to exit code 3 (the WebView2-Runtime-missing signal
 host\FurphyHost.cs's own HandleRuntimeMissing sets via ExitCode=3) -
 asserting the launcher now branches into an Edge fallback instead of
 the pre-fix total silence.

 The neutering technique here differs slightly from the literal
 "replace sh.Run/MsgBox text with WScript.Echo" description: the
 hostExe launch line now captures a return value
 (`exitCode = sh.Run(...)`), which a bare token-for-token swap to the
 Sub WScript.Echo cannot do (VBScript cannot assign the result of a Sub
 call). Instead, `Set sh = CreateObject("WScript.Shell")` is replaced
 with a small in-file FakeShell class whose Run method both echoes the
 command (so this test can assert on it exactly like the plain
 WScript.Echo substitution would) and returns a scripted exit code - 0
 normally, or the value passed on cscript's own command line, but only
 when the command targets FurphyHost.exe. This covers both the old
 statement-form Run calls (spawn server, Edge fallback) and the new
 function-form one uniformly, with zero real process ever spawned.
 MsgBox is still swapped for WScript.Echo via a plain token replace -
 VBScript's MsgBox is a language keyword, not an object method, so it
 cannot be intercepted via FakeShell the same way. The hardcoded system
 Edge path is also substituted for a scratch-relative placeholder so
 its presence/absence is test-controlled rather than dependent on
 whatever machine happens to run this suite.

 Reads "Addon Manager.vbs" fresh from the real build root on every run
 (New-NeuteredLauncher below), so this always exercises the actual
 current script, never a stale hand-copied duplicate that could drift
 from it and stop meaning anything.

 No PowerShell/host/Edge process is ever really started - FakeShell.Run
 only echoes and returns a value; cscript.exe itself is the only
 process this file launches, always against a fresh tests\.tmp root,
 never touching port 47831, a real WoW folder, or a real host window.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:LauncherVbsPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'Addon Manager.vbs'

function New-NeuteredLauncher {
    <#
      Builds a neutered copy of the real "Addon Manager.vbs" at
      $Root\Addon Manager.vbs (same leaf name, so its own
      GetParentFolderName(WScript.ScriptFullName) root-relative logic
      resolves against $Root exactly like a real install would).
    #>
    param([string]$Root)

    $text = Get-Content -LiteralPath $Script:LauncherVbsPath -Raw

    $shellNeedle = 'Set sh = CreateObject("WScript.Shell")'
    $edgeNeedle = 'edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"'
    if ($text -notmatch [regex]::Escape($shellNeedle)) {
        throw 'Addon Manager.vbs: expected WScript.Shell CreateObject line not found - has the launcher shape changed?'
    }
    if ($text -notmatch [regex]::Escape($edgeNeedle)) {
        throw 'Addon Manager.vbs: expected hardcoded Edge path line not found - has the launcher shape changed?'
    }

    $fakeShellClass = @'
Class FakeShell
    Public Function Run(cmd, style, waitOnReturn)
        WScript.Echo "RUN: " & cmd
        Dim stubCode
        stubCode = 0
        If InStr(cmd, "FurphyHost.exe") > 0 Then
            If WScript.Arguments.Count > 0 Then
                stubCode = CLng(WScript.Arguments(0))
            End If
        End If
        Run = stubCode
    End Function
End Class

'@

    $text = $text -replace [regex]::Escape('Option Explicit'), ('Option Explicit' + "`r`n" + $fakeShellClass.TrimEnd())
    $text = $text -replace [regex]::Escape($shellNeedle), 'Set sh = New FakeShell'
    $text = $text -replace [regex]::Escape($edgeNeedle), 'edge = root & "\__test_edge.exe"'
    $text = $text -replace '\bMsgBox\b', 'WScript.Echo'

    $outPath = Join-Path -Path $Root -ChildPath 'Addon Manager.vbs'
    Set-Content -LiteralPath $outPath -Value $text -Encoding ASCII
    return $outPath
}

function New-LauncherScratchRoot {
    <#
      A fresh tests\.tmp root shaped like an install directory for the
      launcher's own FileExists checks: settings.json (scratch port
      47902, never 47831), addon-server.ps1, and an empty host\bin\.
      Callers add/remove host\bin\FurphyHost.exe and __test_edge.exe
      (the Edge stand-in) per scenario.
    #>
    param([string]$Name)

    $root = New-TempRoot -Name $Name
    Set-Content -LiteralPath (Join-Path $root 'settings.json') -Value '{"port": 47902}' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $root 'addon-server.ps1') -Value '# placeholder - never actually run, FakeShell intercepts every sh.Run call' -Encoding ASCII
    New-Item -ItemType Directory -Path (Join-Path $root 'host\bin') -Force | Out-Null
    New-NeuteredLauncher -Root $root | Out-Null
    return $root
}

function Invoke-Launcher {
    <#
      Runs the neutered "Addon Manager.vbs" already built at $Root under
      cscript, optionally passing a stub hostExe exit code as argv(0).
      Returns exit code + captured stdout/stderr (nothing here ever
      shows a real window - cscript is the console host, never
      wscript).
    #>
    param([string]$Root, [string]$StubExitCode = $null)

    $vbsPath = Join-Path -Path $Root -ChildPath 'Addon Manager.vbs'
    $argList = @('//nologo', $vbsPath)
    if ($null -ne $StubExitCode) { $argList += $StubExitCode }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cscript.exe'
    $psi.Arguments = ($argList | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $Root
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $exited = $proc.WaitForExit(15000)
    if (-not $exited) { try { $proc.Kill() } catch { } }

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        StdOut = $stdout
        StdErr = $stderr
        TimedOut = -not $exited
    }
}

Describe 'Addon Manager.vbs launcher cscript scenarios (failure-modes:webview2-missing-no-fallback)' -Tags 'Host' {

    It 'scenario 1: addon-server.ps1 missing -> exits 1 with the reinstall message, no fallback attempted' {
        $root = New-LauncherScratchRoot -Name 'launcher-noserver'
        Remove-Item -LiteralPath (Join-Path $root 'addon-server.ps1') -Force

        $r = Invoke-Launcher -Root $root
        $r.TimedOut | Should Be $false
        $r.ExitCode | Should Be 1
        $r.StdOut | Should Match 'cannot find addon-server\.ps1'
        $r.StdOut | Should Not Match 'RUN:'
    }

    It 'scenario 2: server not answering, no host build, Edge present -> spawns server then falls back to Edge' {
        $root = New-LauncherScratchRoot -Name 'launcher-noHost-edge'
        Set-Content -LiteralPath (Join-Path $root '__test_edge.exe') -Value 'stub' -Encoding ASCII

        $r = Invoke-Launcher -Root $root
        $r.TimedOut | Should Be $false
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'RUN:.*addon-server\.ps1'
        $r.StdOut | Should Match 'RUN:.*__test_edge\.exe.*--app='
        $r.StdOut | Should Not Match 'FurphyHost\.exe'
    }

    It 'scenario 3: server not answering, host build present -> launches the host directly, no Edge noise' {
        $root = New-LauncherScratchRoot -Name 'launcher-host'
        Set-Content -LiteralPath (Join-Path $root 'host\bin\FurphyHost.exe') -Value 'stub' -Encoding ASCII

        $r = Invoke-Launcher -Root $root -StubExitCode '0'
        $r.TimedOut | Should Be $false
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'RUN:.*FurphyHost\.exe.*--port 47902'
        $r.StdOut | Should Not Match '__test_edge\.exe'
    }

    It 'scenario 4: neither host build nor Edge present -> exits 1 with the reinstall message' {
        $root = New-LauncherScratchRoot -Name 'launcher-none'

        $r = Invoke-Launcher -Root $root
        $r.TimedOut | Should Be $false
        $r.ExitCode | Should Be 1
        $r.StdOut | Should Match 'cannot find its window'
    }

    It 'scenario 5 (this finding): host build present, hostExe stubbed to exit 3, Edge present -> falls back to Edge instead of silence' {
        $root = New-LauncherScratchRoot -Name 'launcher-webview2missing-edge'
        Set-Content -LiteralPath (Join-Path $root 'host\bin\FurphyHost.exe') -Value 'stub' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $root '__test_edge.exe') -Value 'stub' -Encoding ASCII

        $r = Invoke-Launcher -Root $root -StubExitCode '3'
        $r.TimedOut | Should Be $false
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'RUN:.*FurphyHost\.exe.*--port 47902'
        $r.StdOut | Should Match 'RUN:.*__test_edge\.exe.*--app='
    }

    It 'scenario 5b: hostExe stubbed to exit 3, no Edge present -> no crash, no second RUN attempted (nothing left to fall back to)' {
        $root = New-LauncherScratchRoot -Name 'launcher-webview2missing-noedge'
        Set-Content -LiteralPath (Join-Path $root 'host\bin\FurphyHost.exe') -Value 'stub' -Encoding ASCII

        $r = Invoke-Launcher -Root $root -StubExitCode '3'
        $r.TimedOut | Should Be $false
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'RUN:.*FurphyHost\.exe.*--port 47902'
        $r.StdOut | Should Not Match '__test_edge\.exe'
    }

    It 'scenario 5c: hostExe exits normally (0) -> no Edge fallback fires (guards against an unconditional-relaunch regression)' {
        $root = New-LauncherScratchRoot -Name 'launcher-normalexit'
        Set-Content -LiteralPath (Join-Path $root 'host\bin\FurphyHost.exe') -Value 'stub' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $root '__test_edge.exe') -Value 'stub' -Encoding ASCII

        $r = Invoke-Launcher -Root $root -StubExitCode '0'
        $r.TimedOut | Should Be $false
        $r.ExitCode | Should Be 0
        $r.StdOut | Should Match 'RUN:.*FurphyHost\.exe.*--port 47902'
        $r.StdOut | Should Not Match '__test_edge\.exe'
    }
}

Remove-TempRoots
