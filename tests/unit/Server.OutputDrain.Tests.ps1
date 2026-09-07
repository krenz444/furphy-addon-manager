<#
  Unit tests (Pester 3 syntax): addon-server.ps1's round-34 Wait-ProcessOutputDrained.

  Regression for the 2026-09-06 21:18 incident (live job 119): a "Check now"
  whose CLI exited 0 with a complete 34-addon result was marked FAILED with
  "CLI exited with code 0" and an empty results[]. Root cause: Start-Process
  -RedirectStandardOutput writes the child's stdout through an asynchronous
  handler in the PARENT process and only flushes/closes that writer on the
  child's Exited event, which fires AFTER Process.HasExited turns true. The
  server read the .out file on the very poll that saw HasExited and got an
  empty (or truncated) file. The no-timeout Process.WaitForExit() overload is
  documented to wait for that asynchronous output handling to complete;
  Wait-ProcessOutputDrained calls it and then confirms the file has content.

  The test reproduces the exact shape: a child powershell.exe that emits one
  large JSON document immediately before exiting, started with the same
  redirection the server uses, read the instant HasExited is observed.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:ServerPath = Join-Path $Script:FurphyBuildRoot 'addon-server.ps1'
. $Script:ServerPath

Describe 'Wait-ProcessOutputDrained (round 34: redirected stdout is complete before it is read)' {
    It 'is defined by addon-server.ps1' {
        (Get-Command Wait-ProcessOutputDrained -ErrorAction SilentlyContinue) | Should Not BeNullOrEmpty
    }

    It 'returns complete JSON from a child that writes ~100 KB right before exiting, 5 runs in a row' {
        $tmp = Join-Path $env:TEMP ('furphy-drain-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $child = Join-Path $tmp 'emit.ps1'
            # 12000 small objects ~ 100 KB, written as ONE string at the very end.
            [IO.File]::WriteAllText($child, @'
$items = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt 12000; $i++) { [void]$items.Append('{"id":' + $i + ',"ok":true},') }
$json = '{"results":[' + $items.ToString().TrimEnd(',') + ']}'
[Console]::Out.Write($json)
exit 0
'@)
            $failures = New-Object System.Collections.Generic.List[string]
            for ($run = 1; $run -le 5; $run++) {
                $outFile = Join-Path $tmp "run$run.out"
                $errFile = Join-Path $tmp "run$run.err"
                $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $child + '"')) -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
                $proc.Handle | Out-Null
                # Poll exactly the way Update-JobStatus does, then drain.
                while (-not $proc.HasExited) { Start-Sleep -Milliseconds 20 }
                Wait-ProcessOutputDrained -Process $proc -OutFile $outFile
                $text = ''
                if (Test-Path -LiteralPath $outFile) { $text = [IO.File]::ReadAllText($outFile, [Text.Encoding]::UTF8) }
                $parsed = $null
                try { $parsed = $text | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
                $count = 0
                if ($parsed -and $parsed.results) { $count = @($parsed.results).Count }
                if ($count -ne 12000) { $failures.Add("run ${run}: exit $($proc.ExitCode), bytes $($text.Length), results $count") }
            }
            ($failures -join '; ') | Should BeNullOrEmpty
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'returns promptly for a child with no output at all (no long stall)' {
        $tmp = Join-Path $env:TEMP ('furphy-drain-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $outFile = Join-Path $tmp 'quiet.out'
            $errFile = Join-Path $tmp 'quiet.err'
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-Command', 'exit 0') -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $proc.Handle | Out-Null
            while (-not $proc.HasExited) { Start-Sleep -Milliseconds 20 }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            Wait-ProcessOutputDrained -Process $proc -OutFile $outFile
            $sw.Stop()
            $sw.ElapsedMilliseconds | Should BeLessThan 3000
        } finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
