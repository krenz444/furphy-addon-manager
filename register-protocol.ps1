# Opt-in: associate curseforge:// install links with Furphy Addon Manager for the CURRENT USER only
# (HKCU\Software\Classes\curseforge). Reversible; any previous handler command is backed up into
# settings.json (previousCurseforgeHandler) and restored on -Unregister. No elevation needed.
param(
    [switch]$Register,
    [switch]$Unregister,
    [switch]$Status,
    [switch]$Json,
    [string]$HandlerPath = (Join-Path $PSScriptRoot 'curseforge-handler.vbs'),
    [string]$IconPath = (Join-Path $PSScriptRoot 'icon.ico'),
    [string]$SettingsPath = (Join-Path $PSScriptRoot 'settings.json')
)
$ErrorActionPreference = 'Stop'
$keyPath = 'HKCU:\Software\Classes\curseforge'
$cmdPath = "$keyPath\shell\open\command"
$ourCommand = 'wscript.exe "' + $HandlerPath + '" "%1"'

function Read-Settings {
    if (Test-Path -LiteralPath $SettingsPath) {
        $raw = [IO.File]::ReadAllText($SettingsPath)
        if ($raw.Trim().Length -gt 0) { return ($raw | ConvertFrom-Json) }
    }
    return [PSCustomObject]@{ releaseType = 1; autoUpdateOnLaunch = $true; cfApiKey = ''; port = 47831 }
}
function Save-Settings($obj) {
    $json = ConvertTo-Json -InputObject $obj -Depth 10
    $tmp = "$SettingsPath.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $SettingsPath -Force
}
function Get-CurrentCommand {
    try { return [string](Get-ItemProperty -LiteralPath $cmdPath -ErrorAction Stop).'(default)' } catch { return '' }
}
function Get-StatusObject {
    $current = Get-CurrentCommand
    $isOurs = ($current -ne '') -and ($current.IndexOf($HandlerPath, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    return [PSCustomObject]@{
        registered     = $isOurs
        currentHandler = $current
        handlerPath    = $HandlerPath
        handlerExists  = (Test-Path -LiteralPath $HandlerPath)
    }
}
function Emit($obj) {
    if ($Json) { ConvertTo-Json -InputObject $obj -Depth 5 -Compress } else { $obj | Format-List | Out-String | Write-Host }
}

if ($Register) {
    if (-not (Test-Path -LiteralPath $HandlerPath)) { throw "Handler script not found: $HandlerPath" }
    $current = Get-CurrentCommand
    $settings = Read-Settings
    if ($current -ne '' -and $current.IndexOf($HandlerPath, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        # Remember whatever handled curseforge:// before us so -Unregister can put it back.
        if ($settings.PSObject.Properties['previousCurseforgeHandler']) { $settings.previousCurseforgeHandler = $current }
        else { $settings | Add-Member -NotePropertyName previousCurseforgeHandler -NotePropertyValue $current }
        Save-Settings $settings
    }
    New-Item -Path $keyPath -Force | Out-Null
    Set-ItemProperty -LiteralPath $keyPath -Name '(default)' -Value 'URL:CurseForge Protocol (Furphy Addon Manager)'
    Set-ItemProperty -LiteralPath $keyPath -Name 'URL Protocol' -Value ''
    New-Item -Path "$keyPath\DefaultIcon" -Force | Out-Null
    Set-ItemProperty -LiteralPath "$keyPath\DefaultIcon" -Name '(default)' -Value ('"' + $IconPath + '",0')
    New-Item -Path $cmdPath -Force | Out-Null
    Set-ItemProperty -LiteralPath $cmdPath -Name '(default)' -Value $ourCommand
    Emit (Get-StatusObject)
    exit 0
}
if ($Unregister) {
    $status = Get-StatusObject
    if ($status.registered) {
        $settings = Read-Settings
        $previous = ''
        if ($settings.PSObject.Properties['previousCurseforgeHandler']) { $previous = [string]$settings.previousCurseforgeHandler }
        if ($previous -ne '') {
            Set-ItemProperty -LiteralPath $cmdPath -Name '(default)' -Value $previous
            $settings.previousCurseforgeHandler = ''
            Save-Settings $settings
        } else {
            Remove-Item -Path $keyPath -Recurse -Force
        }
    }
    Emit (Get-StatusObject)
    exit 0
}
Emit (Get-StatusObject)
exit 0
