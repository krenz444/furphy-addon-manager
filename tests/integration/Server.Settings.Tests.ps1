<#
=====================================================================
 tests\integration\Server.Settings.Tests.ps1

 GET/PUT /api/settings: every documented key round-trips, releaseType/port/
 backgroundIntervalMinutes clamp/400 rules, hostTheme validation, and the
 permissive bool-coercion contract (ConvertTo-SettingsBool never 400s -
 confirmed against the actual code; see notesForNext for how this differs
 from a literal read of the task brief).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

Describe 'GET/PUT /api/settings' {
    $root = New-TempRoot -Name 'settings'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899

        It 'GET returns every documented default key' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/settings'
            $r.Ok | Should Be $true
            $s = $r.Body
            $s.releaseType | Should Be 1
            $s.port | Should Be 47899
            $s.adFilter | Should Be $true
            $s.cfFocus | Should Be $true
            $s.backgroundUpdates | Should Be $false
            $s.backgroundIntervalMinutes | Should Be 120
            $s.runAtStartup | Should Be $false
            $s.schemaVersion | Should Be 2
            $s.activeFlavour | Should Be 'retail'
            $s.showTestRealms | Should Be $false
            # no cfApiKey/hasApiKey/apiKeyHint field exists any more (E23) -
            # confirm the removed feature really is gone from the response.
            ($s.PSObject.Properties.Name -contains 'cfApiKey') | Should Be $false
            ($s.PSObject.Properties.Name -contains 'hasApiKey') | Should Be $false
            # no autoUpdateOnLaunch field exists any more (Round 34, removed
            # at Eric's request 2026-09-07 - see CHANGELOG.md) - confirm the
            # removed feature really is gone from the response, same pattern
            # as the cfApiKey removal above.
            ($s.PSObject.Properties.Name -contains 'autoUpdateOnLaunch') | Should Be $false
        }

        It 'PUT releaseType=2 round-trips' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 2 }
            $r.Ok | Should Be $true
            $r.Body.releaseType | Should Be 2
            $g = Invoke-Api -Port 47899 -Method Get -Path '/api/settings'
            $g.Body.releaseType | Should Be 2
            # restore for later Its in this Describe
            Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 1 } | Out-Null
        }

        It 'PUT releaseType out of range (0 or 4) is a clean 400, never a crash' {
            $r0 = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 0 }
            $r0.Ok | Should Be $false
            $r0.StatusCode | Should Be 400

            $r4 = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 4 }
            $r4.Ok | Should Be $false
            $r4.StatusCode | Should Be 400
        }

        It 'PUT releaseType="abc" (non-numeric) is a clean 400, not a raw 500' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 'abc' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'releaseType must be a number'
        }

        It 'PUT port="abc" is a clean 400' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ port = 'notanumber' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'port must be a number'
        }

        It 'PUT port=999999 (out of the 1-65535 TCP range) is a clean 400, and settings.json on disk is left unchanged (security:security-server-settings-port-no-range-check-bricks-launch)' {
            # Before this fix this returned 200 and wrote the out-of-range
            # value straight to settings.json - harmless-looking in the
            # response (Get-SettingsView always echoes the server's own
            # LIVE port, never the stored value), but catastrophic on the
            # NEXT real launch: "Addon Manager.vbs" never passes -Port at
            # all, so it relies entirely on this stored value, and
            # $listener.Start() throws on an out-of-range port - FATAL, no
            # listener on any port, no on-screen error of any kind.
            $before = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json

            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ port = 999999 }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'port must be 1-65535'

            $after = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
            $after.port | Should Be $before.port
        }

        It 'PUT port=0 is also a clean 400 (same 1-65535 range check, the other edge)' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ port = 0 }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'port must be 1-65535'
        }

        It 'PUT a genuinely valid port round-trips through settings.json on disk (the live listener itself is never re-bound by this test)' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ port = 47905 }
            $r.Ok | Should Be $true
            $onDisk = Get-Content -LiteralPath (Join-Path $root 'settings.json') -Raw | ConvertFrom-Json
            $onDisk.port | Should Be 47905
            # restore, so a later It in this Describe (or a future run
            # reusing this pattern) never depends on ordering here
            Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ port = 47899 } | Out-Null
        }

        It 'PUT backgroundIntervalMinutes clamps below 30 up to 30' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ backgroundIntervalMinutes = 5 }
            $r.Ok | Should Be $true
            $r.Body.backgroundIntervalMinutes | Should Be 30
        }

        It 'PUT backgroundIntervalMinutes clamps above 1440 down to 1440' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ backgroundIntervalMinutes = 999999 }
            $r.Ok | Should Be $true
            $r.Body.backgroundIntervalMinutes | Should Be 1440
            # restore
            Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ backgroundIntervalMinutes = 120 } | Out-Null
        }

        It 'PUT backgroundIntervalMinutes="abc" is a clean 400' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ backgroundIntervalMinutes = 'abc' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'PUT silently ignores a stale client sending autoUpdateOnLaunch (Round 34, removed at Eric''s request 2026-09-07)' {
            # Round 34 removed the autoUpdateOnLaunch setting entirely (see
            # CHANGELOG.md); this is no longer a bool field to COERCE (that
            # coverage moved off this key onto whichever bool field the
            # PUT hostTheme/other Its below still exercise) - a stale
            # client (an old cached SPA bundle, a leftover browser tab)
            # that still sends the key must not 400 and must not have it
            # come back on the response or a later GET.
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body '{"autoUpdateOnLaunch":true}'
            $r.Ok | Should Be $true
            ($r.Body.PSObject.Properties.Name -contains 'autoUpdateOnLaunch') | Should Be $false

            $g = Invoke-Api -Port 47899 -Method Get -Path '/api/settings'
            ($g.Body.PSObject.Properties.Name -contains 'autoUpdateOnLaunch') | Should Be $false
        }

        It 'PUT hostTheme with an uppercase name is rejected 400' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ hostTheme = @{ name = 'LofiNight'; colors = @{ bg0 = '#141518' } } }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'PUT hostTheme with a bad color value is rejected 400' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ hostTheme = @{ name = 'lofi'; colors = @{ bg0 = 'not-a-color' } } }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'PUT a valid hostTheme round-trips' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ hostTheme = @{ name = 'lofi-night'; colors = @{ bg0 = '#141518'; bg1 = '#1c1d21' } } }
            $r.Ok | Should Be $true
            $r.Body.hostTheme.name | Should Be 'lofi-night'
            $r.Body.hostTheme.colors.bg0 | Should Be '#141518'
        }

        It 'PUT activeFlavour to a value that is not currently installed is silently ignored (no 400, no change)' {
            $before = (Invoke-Api -Port 47899 -Method Get -Path '/api/settings').Body.activeFlavour
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ activeFlavour = 'classic_era' }
            $r.Ok | Should Be $true
            # this server has 0 detected installed flavours (no -WowRoot), so
            # 'classic_era' never matches Get-CurrentInstalledFlavours and the
            # write is a silent no-op per Handle-SettingsPut's own contract.
            $r.Body.activeFlavour | Should Be $before
        }

        It 'PUT with an empty body is a 400' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body ''
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'GET /api/settings - corrupt settings.json self-repairs, end to end (failure-modes:settingsjson-corruption-silent-reset)' {
    $root = New-TempRoot -Name 'settings-corrupt'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899
        $settingsPath = Join-Path $root 'settings.json'

        # A real preference the user explicitly chose, different from the
        # default, so a silent revert-to-defaults is actually observable.
        Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ adFilter = $false } | Out-Null
        ((Invoke-Api -Port 47899 -Method Get -Path '/api/settings').Body.adFilter) | Should Be $false

        Set-Content -LiteralPath $settingsPath -Value '{"adFilter": false, garbage!!!' -Encoding UTF8 -NoNewline

        It 'the first GET after corruption returns defaults (not a 500) and repairs the file on disk' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/settings'
            $r.Ok | Should Be $true
            $r.Body.adFilter | Should Be $true # back to the default - the false choice was lost, but the app never crashes

            $onDiskRaw = Get-Content -LiteralPath $settingsPath -Raw
            # (parsed directly, not inside a "{...} | Should Not Throw"
            # scriptblock - Pester 3 runs that scriptblock in its own child
            # scope, so an assignment inside it never reaches $onDisk out
            # here; a still-malformed file would fail this It via the
            # uncaught ConvertFrom-Json exception instead, which is fine)
            $onDisk = $onDiskRaw | ConvertFrom-Json -ErrorAction Stop
            $onDisk.adFilter | Should Be $true
        }

        It 'a second GET no longer needs to repair anything (the file already parses) and server.log stops logging a fresh parse failure' {
            $logPathBefore = Get-LastLogLines -Path (Join-Path $root 'server.log') -Lines 5000
            $countBefore = (@($logPathBefore -split "`n") | Where-Object { $_ -match 'Failed to read settings.json' }).Count

            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/settings'
            $r.Ok | Should Be $true
            $r.Body.adFilter | Should Be $true

            $logPathAfter = Get-LastLogLines -Path (Join-Path $root 'server.log') -Lines 5000
            $countAfter = (@($logPathAfter -split "`n") | Where-Object { $_ -match 'Failed to read settings.json' }).Count
            $countAfter | Should Be $countBefore
        }
    } finally {
        Stop-TestServer -Server $server
    }
}
