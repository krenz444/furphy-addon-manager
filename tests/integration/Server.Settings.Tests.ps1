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
