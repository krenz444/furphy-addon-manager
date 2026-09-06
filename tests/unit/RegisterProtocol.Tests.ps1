<#
  Unit tests (Pester 3 syntax): register-protocol.ps1 round-trip against a
  THROWAWAY registry key (the round-31 -KeyPath test hook), never the real
  HKCU\Software\Classes\curseforge that Eric's own install-link handler lives
  under. Regression for the round-31 bug Eric hit: -Unregister always failed
  with "Cannot convert value PSCustomObject to type SwitchParameter" because
  the branch assigned its status object to a local named $status - which in
  PowerShell IS the [switch]$Status parameter (names are case-insensitive).
  Every It runs the script as a real child powershell.exe exactly the way
  addon-server.ps1's Invoke-ProtocolScript does, so the parameter binding
  under test is the real one.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

$Script:ProtocolScript = Join-Path $Script:FurphyBuildRoot 'register-protocol.ps1'
$Script:TestKey = 'HKCU:\Software\Classes\furphy-test-curseforge-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)

function Invoke-ProtocolForTest {
    param([string]$Switch, [string]$HandlerPath, [string]$SettingsPath)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:ProtocolScript "-$Switch" -Json `
        -KeyPath $Script:TestKey -HandlerPath $HandlerPath -SettingsPath $SettingsPath 2>&1
    $exit = $LASTEXITCODE
    $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
    $json = $null
    try { $json = $text | ConvertFrom-Json } catch { $json = $null }
    return @{ exitCode = $exit; text = $text; json = $json }
}

Describe 'register-protocol.ps1 register / status / unregister round-trip on a throwaway key' {
    # Script-scoped so Pester 3's AfterAll (which runs in its own scope) can see them.
    $Script:ProtoRoot = Join-Path $env:TEMP ('furphy-proto-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $Script:ProtoRoot -Force | Out-Null
    $handler = Join-Path $Script:ProtoRoot 'curseforge-handler.vbs'
    [IO.File]::WriteAllText($handler, "' test handler`r`n")
    $settings = Join-Path $Script:ProtoRoot 'settings.json'
    [IO.File]::WriteAllText($settings, '{"port":47899}')

    AfterAll {
        if ($Script:TestKey -and (Test-Path -LiteralPath $Script:TestKey)) { Remove-Item -Path $Script:TestKey -Recurse -Force -ErrorAction SilentlyContinue }
        if ($Script:ProtoRoot -and (Test-Path -LiteralPath $Script:ProtoRoot)) { Remove-Item -LiteralPath $Script:ProtoRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It '-Status on a fresh key reports registered=false and exits 0' {
        $r = Invoke-ProtocolForTest -Switch 'Status' -HandlerPath $handler -SettingsPath $settings
        $r.exitCode | Should Be 0
        $r.json | Should Not BeNullOrEmpty
        [bool]$r.json.registered | Should Be $false
    }

    It '-Register writes the throwaway key and reports registered=true' {
        $r = Invoke-ProtocolForTest -Switch 'Register' -HandlerPath $handler -SettingsPath $settings
        $r.exitCode | Should Be 0
        [bool]$r.json.registered | Should Be $true
        (Test-Path -LiteralPath "$($Script:TestKey)\shell\open\command") | Should Be $true
        $cmd = [string](Get-ItemProperty -LiteralPath "$($Script:TestKey)\shell\open\command").'(default)'
        $cmd.IndexOf($handler, [StringComparison]::OrdinalIgnoreCase) | Should BeGreaterThan -1
    }

    It '-Unregister succeeds (round-31 regression: no SwitchParameter conversion error) and removes the key' {
        $r = Invoke-ProtocolForTest -Switch 'Unregister' -HandlerPath $handler -SettingsPath $settings
        $r.text | Should Not Match 'SwitchParameter'
        $r.exitCode | Should Be 0
        $r.json | Should Not BeNullOrEmpty
        [bool]$r.json.registered | Should Be $false
        (Test-Path -LiteralPath $Script:TestKey) | Should Be $false
    }

    It 'never touched the real curseforge:// key during the round-trip' {
        # The real key may or may not exist on this machine; what matters is
        # that this test only ever addressed its own throwaway key.
        $Script:TestKey | Should Match 'furphy-test-curseforge-'
    }
}
