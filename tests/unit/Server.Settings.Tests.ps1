<#
  Unit tests (Pester 3 syntax): addon-server.ps1's settings validation -
  ConvertTo-SettingsBool (Round 20's permissive-but-not-inverted bool
  coercion), Test-HostTheme (E19b's hostTheme shape validation), and
  Get-DefaultSettings' documented defaults (adFilter/cfFocus ON,
  backgroundUpdates/runAtStartup OFF per their own change-history
  comments).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

Describe 'ConvertTo-SettingsBool' {

    It 'a real boolean $true stays $true' {
        (ConvertTo-SettingsBool $true) | Should Be $true
    }

    It 'a real boolean $false stays $false' {
        (ConvertTo-SettingsBool $false) | Should Be $false
    }

    It 'the integer 1 coerces to $true' {
        (ConvertTo-SettingsBool 1) | Should Be $true
    }

    It 'the integer 0 coerces to $false' {
        (ConvertTo-SettingsBool 0) | Should Be $false
    }

    It 'the string "false" coerces to $false (Round 20''s own fix - used to invert to $true)' {
        (ConvertTo-SettingsBool 'false') | Should Be $false
    }

    It 'the string "0" coerces to $false' {
        (ConvertTo-SettingsBool '0') | Should Be $false
    }

    It 'the string "no" coerces to $false' {
        (ConvertTo-SettingsBool 'no') | Should Be $false
    }

    It 'the string "off" coerces to $false' {
        (ConvertTo-SettingsBool 'off') | Should Be $false
    }

    It 'an empty string coerces to $false' {
        (ConvertTo-SettingsBool '') | Should Be $false
    }

    It 'the string is case-insensitive ("FALSE"/"False" both coerce to $false)' {
        (ConvertTo-SettingsBool 'FALSE') | Should Be $false
        (ConvertTo-SettingsBool 'False') | Should Be $false
    }

    It 'any other non-empty string (e.g. "true", "yes", "banana") coerces to $true' {
        (ConvertTo-SettingsBool 'true') | Should Be $true
        (ConvertTo-SettingsBool 'yes') | Should Be $true
        (ConvertTo-SettingsBool 'banana') | Should Be $true
    }
}

Describe 'Test-HostTheme' {

    function New-ValidTheme {
        return [PSCustomObject]@{ name = 'my-theme-1'; colors = [PSCustomObject]@{ bg0 = '#12081f'; accent = '#f16436' } }
    }

    It 'accepts a well-formed theme (lowercase-alnum-hyphen name, hex colors)' {
        (Test-HostTheme -Theme (New-ValidTheme)) | Should Be $true
    }

    It 'rejects $null outright' {
        (Test-HostTheme -Theme $null) | Should Be $false
    }

    It 'rejects a name with uppercase letters (case-SENSITIVE per Round 12''s own fix - "LofiNight" used to pass)' {
        $t = New-ValidTheme
        $t.name = 'LofiNight'
        (Test-HostTheme -Theme $t) | Should Be $false
    }

    It 'rejects a name longer than 32 characters' {
        $t = New-ValidTheme
        $t.name = ('a' * 33)
        (Test-HostTheme -Theme $t) | Should Be $false
    }

    It 'rejects an empty name' {
        $t = New-ValidTheme
        $t.name = ''
        (Test-HostTheme -Theme $t) | Should Be $false
    }

    It 'rejects a name containing characters outside [a-z0-9-]' {
        $t = New-ValidTheme
        $t.name = 'my_theme!'
        (Test-HostTheme -Theme $t) | Should Be $false
    }

    It 'rejects a color value that is not a "#rrggbb" 6-digit hex string' {
        $t = New-ValidTheme
        $t.colors = [PSCustomObject]@{ bg0 = 'rgb(1,2,3)' }
        (Test-HostTheme -Theme $t) | Should Be $false
    }

    It 'rejects a color value with only 3 hex digits (CSS shorthand is not accepted)' {
        $t = New-ValidTheme
        $t.colors = [PSCustomObject]@{ bg0 = '#fff' }
        (Test-HostTheme -Theme $t) | Should Be $false
    }

    It 'rejects more than 12 color keys' {
        $t = New-ValidTheme
        $colors = @{}
        for ($i = 0; $i -lt 13; $i++) { $colors["c$i"] = '#123456' }
        $t.colors = [PSCustomObject]$colors
        (Test-HostTheme -Theme $t) | Should Be $false
    }

    It 'accepts exactly 12 color keys' {
        $t = New-ValidTheme
        $colors = @{}
        for ($i = 0; $i -lt 12; $i++) { $colors["c$i"] = '#123456' }
        $t.colors = [PSCustomObject]$colors
        (Test-HostTheme -Theme $t) | Should Be $true
    }

    It 'rejects a theme with no colors object at all' {
        $t = New-ValidTheme
        $t.colors = $null
        (Test-HostTheme -Theme $t) | Should Be $false
    }
}

Describe 'Get-DefaultSettings' {

    $defaults = Get-DefaultSettings

    It 'defaults releaseType to 1 (release only)' {
        $defaults.releaseType | Should Be 1
    }

    It 'defaults adFilter to ON (superseded by E22, 2026-09-04)' {
        $defaults.adFilter | Should Be $true
    }

    It 'defaults cfFocus to ON (E22)' {
        $defaults.cfFocus | Should Be $true
    }

    It 'defaults backgroundUpdates to OFF (never runs unattended out of the box)' {
        $defaults.backgroundUpdates | Should Be $false
    }

    It 'defaults backgroundIntervalMinutes to 120' {
        $defaults.backgroundIntervalMinutes | Should Be 120
    }

    It 'defaults runAtStartup to OFF, independent of backgroundUpdates' {
        $defaults.runAtStartup | Should Be $false
    }

    It 'defaults schemaVersion to 2 for a brand-new install (never needs migrating)' {
        $defaults.schemaVersion | Should Be 2
    }

    It 'defaults showTestRealms to OFF (PTR/Beta hidden by default)' {
        $defaults.showTestRealms | Should Be $false
    }
}

function New-RawSettingsFile {
    <# Writes -Content verbatim (not through Save-Settings) to a fresh temp root's settings.json and points $Script:SettingsPath at it. #>
    param([string]$Content)
    $settingsRoot = New-TempRoot -Name 'settings-raw'
    $path = Join-Path $settingsRoot 'settings.json'
    Set-Content -LiteralPath $path -Value $Content -Encoding UTF8 -NoNewline
    $Script:SettingsPath = $path
    return $path
}

Describe 'Get-Settings - port range (security:security-server-settings-port-no-range-check-bricks-launch, defense in depth)' {
    <#
      Handle-SettingsPut already rejects an out-of-range port with 400 (see
      the integration Describe for that half) - this covers the SECOND,
      independent guard: Get-Settings' own READ path, which must clamp a
      bad value already sitting on disk (a manual hand-edit, or a file from
      before this fix) back to the 47831 default rather than ever letting
      it round-trip anywhere unfiltered, including into the real startup
      port-resolution fallback that ultimately feeds $listener.Start().
    #>

    It 'a positive but out-of-range on-disk port (999999) reads back as the 47831 default, not the bad value' {
        New-RawSettingsFile -Content '{"port":999999}' | Out-Null
        (Get-Settings).port | Should Be 47831
    }

    It 'an on-disk port of 0 reads back as the 47831 default' {
        New-RawSettingsFile -Content '{"port":0}' | Out-Null
        (Get-Settings).port | Should Be 47831
    }

    It 'a negative on-disk port reads back as the 47831 default' {
        New-RawSettingsFile -Content '{"port":-5}' | Out-Null
        (Get-Settings).port | Should Be 47831
    }

    It 'a genuinely valid on-disk port is unaffected' {
        New-RawSettingsFile -Content '{"port":47905}' | Out-Null
        (Get-Settings).port | Should Be 47905
    }
}

Describe 'Get-Settings - corrupt settings.json self-repairs (failure-modes:settingsjson-corruption-silent-reset)' {
    <#
      Before this round's fix, a malformed settings.json fell back to
      in-memory defaults on every single read forever, with the corrupt
      file itself never repaired - any real choice the user had made
      (most importantly adFilter/cfFocus, both ON by default) silently
      reverted with zero indication, and the same parse-failure warning
      re-logged on every subsequent request for the life of the install.
    #>

    It 'returns Get-DefaultSettings-equivalent values on a parse failure' {
        New-RawSettingsFile -Content '{"adFilter": false, garbage!!!' | Out-Null
        $result = Get-Settings
        $defaults = Get-DefaultSettings
        $result.adFilter | Should Be $defaults.adFilter
        $result.cfFocus | Should Be $defaults.cfFocus
        $result.port | Should Be $defaults.port
    }

    It 'overwrites the corrupt file on disk with valid JSON that parses back to the same defaults' {
        $path = New-RawSettingsFile -Content '{"adFilter": false, garbage!!!'
        Get-Settings | Out-Null

        $raw = Get-Content -LiteralPath $path -Raw
        # (a scriptblock passed to "Should Not Throw" runs in its own child
        # scope in Pester 3 - a variable assigned inside it does not
        # propagate back out, so the parse itself happens directly here;
        # ConvertFrom-Json throwing on still-malformed content would fail
        # this It the normal way, via an uncaught exception)
        $onDisk = $raw | ConvertFrom-Json -ErrorAction Stop
        $onDisk.adFilter | Should Be (Get-DefaultSettings).adFilter
    }

    It 'a second read of the now-repaired file no longer needs to fall back (the repair actually took)' {
        $path = New-RawSettingsFile -Content '{"adFilter": false, garbage!!!'
        Get-Settings | Out-Null
        # Simulate the user having since changed a real preference through
        # the repaired file, to prove the second read is a normal parse of
        # valid JSON - not still silently discarding everything back to
        # defaults every time.
        $repaired = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $repaired.adFilter = $false
        (ConvertTo-Json -InputObject $repaired -Depth 5) | Set-Content -LiteralPath $path -Encoding UTF8
        (Get-Settings).adFilter | Should Be $false
    }
}

Remove-TempRoots
