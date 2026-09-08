<#
  Integration test (Pester 3 syntax): server:seed5-dual-launcher-startup-
  race / cli-installer:F2-dual-server-start-race-fatal-log /
  perf-game:lead5-dual-server-start-race / first-run-docs:fresh-install-
  shared-port-conflict-live-evidence (Round 36 "server" fixer) - all four
  reports describe the same underlying mechanism: 'Addon Manager.vbs' and
  the tray's own TryStartServer each independently ping /api/ping and,
  only if it doesn't answer, spawn a brand-new hidden addon-server.ps1
  with no lock between the two launch paths. When both fire in the same
  narrow window, the loser's HttpListener.Start() throws because the
  winner already bound the exact same prefix - completely harmless (the
  winner keeps serving unaffected), but before this fix the loser logged
  it under a "FATAL:" prefix, which reads like a real crash to anyone
  triaging server.log.

  This test reproduces the race directly and deterministically (no
  artificial timing window needed - a second bind attempt against an
  already-bound HttpListener prefix always fails), and asserts the loser
  exits quickly with the new calm log line instead of the old FATAL one,
  while the winner is completely unaffected and keeps answering
  /api/ping.

  Uses its own dynamically-allocated port (never 47899, the shared suite
  port reserved for a whole-suite run) so it is safe to run standalone
  alongside other agents' activity.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

function Get-FurphyEphemeralPort {
    <#
      Returns a free TCP port on the loopback interface by asking the OS
      for one (bind to port 0, read the assigned port, release it
      immediately). Small TOCTOU window between release and this test's
      own addon-server.ps1 bind is expected and accepted here - the same
      window exists in any "find a free port" helper and is not what this
      test is exercising.
    #>
    $probe = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()
    return $port
}

Describe 'addon-server.ps1 - dual-launcher startup race (same port, back-to-back)' {

    It 'the loser of the bind race exits quickly with a calm log line, never the old FATAL wording, and the winner keeps serving' {
        $port = Get-FurphyEphemeralPort
        $root = New-TempRoot -Name 'server-startup-race'

        $server1 = $null
        $proc2 = $null

        # Round-1-fixer's own live-safety pattern (see Start-TestServer's
        # FURPHY_TEST_SKIP_WAGO_GROWTH handling): scope both test-only skip
        # vars to just this call so neither the first (Start-TestServer,
        # which already sets FURPHY_TEST_SKIP_WAGO_GROWTH itself) nor the
        # second (raw Start-Process below, which needs both set
        # explicitly) instance makes a single live network call during
        # this test.
        $originalSkipCf = $env:FURPHY_TEST_SKIP_CF_CATALOGUE
        $env:FURPHY_TEST_SKIP_CF_CATALOGUE = '1'

        try {
            $server1 = Start-TestServer -Root $root -Port $port

            # Second instance: same root, same port, spawned directly (NOT
            # via Start-TestServer, which would treat the already-healthy
            # first instance as a "stale" straggler and kill it before
            # trying - the opposite of the race this test needs). Mirrors
            # Start-TestServer's own -ArgumentList shape exactly.
            $scriptPath = Join-Path -Path $Script:FurphyBuildRoot -ChildPath 'addon-server.ps1'
            $argList = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
                '-Port', [string]$port, '-Root', $root, '-IdleMinutes', '5'
            )
            $proc2 = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru

            $exited = $proc2.WaitForExit(20000)
            $exited | Should Be $true

            $logPath = Join-Path -Path $root -ChildPath 'server.log'
            $logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
            $logText | Should Not BeNullOrEmpty

            # The new, calm message (addon-server.ps1's listener.Start()
            # catch block) - proves the loser recognised the known-benign
            # race instead of treating it as an unexpected crash.
            ($logText -match 'already running on port ' + [regex]::Escape([string]$port)) | Should Be $true
            ($logText -match 'this instance is exiting') | Should Be $true

            # The old wording must never appear for this specific,
            # well-known exception - a genuinely different bind failure
            # would still legitimately need it, but that is not this case.
            ($logText -match 'FATAL: could not start listener') | Should Be $false

            # The winner (server1) must be completely unaffected.
            $pingOk = $false
            try {
                Invoke-RestMethod -Uri "http://127.0.0.1:$port/api/ping" -Method Get -TimeoutSec 5 | Out-Null
                $pingOk = $true
            } catch {
                $pingOk = $false
            }
            $pingOk | Should Be $true
        } finally {
            if ($proc2 -and -not $proc2.HasExited) {
                try { Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue } catch { }
            }
            Stop-TestServer -Server $server1
            if ($null -eq $originalSkipCf) {
                Remove-Item Env:\FURPHY_TEST_SKIP_CF_CATALOGUE -ErrorAction SilentlyContinue
            } else {
                $env:FURPHY_TEST_SKIP_CF_CATALOGUE = $originalSkipCf
            }
        }
    }
}
