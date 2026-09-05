<#
 One-time (per bench session) setup for the P0 baseline runs. NOT part of
 the deliverable test suite - a scratch driver used to build the shared
 test root the individual state runs point Measure-Furphy.ps1 at.

 Creates:
   tests\.tmp\perf-app-<...>\        app root (addon-sync.ps1, addon-server.ps1,
                                      ui\, host\bin\, flavours\retail\addons.json
                                      seeded with 2 real CurseForge addons)
   tests\.tmp\perf-wowroot-<...>\    a Copy-Fixture wowroot copy

 Prints both paths (last two lines) so the caller's shell can capture them.
#>
param()

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$wowRoot = Copy-Fixture -Destination (New-TempRoot -Name 'perf-wowroot')
$appRoot = New-TempRoot -Name 'perf-app'

Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-sync.ps1') -Destination (Join-Path $appRoot 'addon-sync.ps1') -Force
Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1') -Destination (Join-Path $appRoot 'addon-server.ps1') -Force
Copy-Item -LiteralPath (Join-Path $Script:FurphyBuildRoot 'ui') -Destination (Join-Path $appRoot 'ui') -Recurse -Force

$hostBinSrc = Join-Path $Script:FurphyBuildRoot 'host\bin'
$hostBinDst = Join-Path $appRoot 'host\bin'
New-Item -ItemType Directory -Path $hostBinDst -Force | Out-Null
Get-ChildItem -LiteralPath $hostBinSrc -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $hostBinDst -Recurse -Force
}

# Seed retail with 2 real, known-good CurseForge addons (BigWigs 2382,
# LittleWigs 4383 - both verified retail-compatible, real network install)
# so states F/G have real addon work to do, not an empty addons.json.
$cliPath = Join-Path $appRoot 'addon-sync.ps1'
$addArgs = @('-File', $cliPath, '-Add', '2382,4383', '-Flavor', 'retail', '-WowRoot', $wowRoot, '-Json', '-Quiet')
$seedOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass @addArgs 2>&1
$seedOut | Out-String | Write-Host

$settingsPath = Join-Path $appRoot 'settings.json'
$settings = @{
    port = 47899
    adFilter = $true
    cfFocus = $true
    autoUpdateOnLaunch = $true
    backgroundUpdates = $false
    backgroundIntervalMinutes = 30
    runAtStartup = $false
    showTestRealms = $false
}
$settings | ConvertTo-Json | Set-Content -LiteralPath $settingsPath -Encoding UTF8

Write-Host "APPROOT=$appRoot"
Write-Host "WOWROOT=$wowRoot"
