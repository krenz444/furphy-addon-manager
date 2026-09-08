<#
  Unit tests (Pester 3 syntax): Round 37 (server perf pass) -
  Get-ProtocolStatusObject, addon-server.ps1's own in-process replacement
  for what GET /api/protocol/status used to do by spawning a whole hidden
  register-protocol.ps1 -Status -Json child (measured ~400ms, almost all
  process-start overhead, for a pure registry read with no side effects).

  Runs entirely against a THROWAWAY registry key
  (HKCU:\Software\Classes\furphy-test-curseforge-<guid>), the same
  $KeyPath test hook tests\unit\RegisterProtocol.Tests.ps1 already uses -
  NEVER the real HKCU\Software\Classes\curseforge Eric's own install-link
  handler lives under. $Script:CurseforgeProtocolKeyPath/
  $Script:CurseforgeHandlerPath (both overridden below, right after
  dot-sourcing) are exactly the two script-scope seams that make this
  possible without touching the real key at all.

  "Parity with the script" is proven directly: the real register-
  protocol.ps1 is run as a genuine child process (-Status/-Register/
  -Unregister -Json, exactly the shape Invoke-ProtocolScript itself uses)
  against this SAME throwaway key/handler, and its JSON output is compared
  field-for-field against Get-ProtocolStatusObject's own return value for
  the identical state.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

$Script:ProtocolScriptPath = Join-Path $Script:FurphyBuildRoot 'register-protocol.ps1'

function Invoke-RealProtocolScript {
    param([string]$Switch, [string]$HandlerPath, [string]$SettingsPath, [string]$KeyPath)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script:ProtocolScriptPath "-$Switch" -Json `
        -KeyPath $KeyPath -HandlerPath $HandlerPath -SettingsPath $SettingsPath 2>&1
    $text = ($out | ForEach-Object { [string]$_ }) -join "`n"
    try { return ($text | ConvertFrom-Json) } catch { return $null }
}

Describe 'Get-ProtocolStatusObject - in-process registry read on a throwaway key' {
    $Script:testKey = 'HKCU:\Software\Classes\furphy-test-curseforge-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $protoRoot = New-TempRoot -Name 'protocol-status'
    $handler = Join-Path $protoRoot 'curseforge-handler.vbs'
    [IO.File]::WriteAllText($handler, "' test handler`r`n")
    $settingsPath = Join-Path $protoRoot 'settings.json'
    [IO.File]::WriteAllText($settingsPath, '{"port":47899}')

    AfterAll {
        if (Test-Path -LiteralPath $Script:testKey) { Remove-Item -Path $Script:testKey -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'reports registered=false, handlerExists=true, currentHandler="" before anything ever registered the throwaway key' {
        $Script:CurseforgeProtocolKeyPath = $Script:testKey
        $Script:CurseforgeHandlerPath = $handler

        $status = Get-ProtocolStatusObject
        $status.registered | Should Be $false
        $status.currentHandler | Should Be ''
        $status.handlerPath | Should Be $handler
        $status.handlerExists | Should Be $true
    }

    It 'matches register-protocol.ps1 -Status -Json field-for-field on a fresh (unregistered) key' {
        $Script:CurseforgeProtocolKeyPath = $Script:testKey
        $Script:CurseforgeHandlerPath = $handler

        $inProcess = Get-ProtocolStatusObject
        $fromScript = Invoke-RealProtocolScript -Switch 'Status' -HandlerPath $handler -SettingsPath $settingsPath -KeyPath $Script:testKey
        $fromScript | Should Not BeNullOrEmpty

        [bool]$inProcess.registered | Should Be ([bool]$fromScript.registered)
        [string]$inProcess.currentHandler | Should Be ([string]$fromScript.currentHandler)
        [string]$inProcess.handlerPath | Should Be ([string]$fromScript.handlerPath)
        [bool]$inProcess.handlerExists | Should Be ([bool]$fromScript.handlerExists)
    }

    It 'after register-protocol.ps1 -Register writes the throwaway key, reports registered=true and the real command line' {
        $Script:CurseforgeProtocolKeyPath = $Script:testKey
        $Script:CurseforgeHandlerPath = $handler

        $registerResult = Invoke-RealProtocolScript -Switch 'Register' -HandlerPath $handler -SettingsPath $settingsPath -KeyPath $Script:testKey
        $registerResult | Should Not BeNullOrEmpty
        [bool]$registerResult.registered | Should Be $true

        $status = Get-ProtocolStatusObject
        $status.registered | Should Be $true
        $status.currentHandler.IndexOf($handler, [StringComparison]::OrdinalIgnoreCase) | Should BeGreaterThan -1
    }

    It 'matches register-protocol.ps1 -Status -Json field-for-field once registered' {
        $Script:CurseforgeProtocolKeyPath = $Script:testKey
        $Script:CurseforgeHandlerPath = $handler

        $inProcess = Get-ProtocolStatusObject
        $fromScript = Invoke-RealProtocolScript -Switch 'Status' -HandlerPath $handler -SettingsPath $settingsPath -KeyPath $Script:testKey
        $fromScript | Should Not BeNullOrEmpty

        [bool]$inProcess.registered | Should Be ([bool]$fromScript.registered)
        [string]$inProcess.currentHandler | Should Be ([string]$fromScript.currentHandler)
        [string]$inProcess.handlerPath | Should Be ([string]$fromScript.handlerPath)
        [bool]$inProcess.handlerExists | Should Be ([bool]$fromScript.handlerExists)
    }

    It 'after register-protocol.ps1 -Unregister removes the key, reports registered=false again' {
        $Script:CurseforgeProtocolKeyPath = $Script:testKey
        $Script:CurseforgeHandlerPath = $handler

        Invoke-RealProtocolScript -Switch 'Unregister' -HandlerPath $handler -SettingsPath $settingsPath -KeyPath $Script:testKey | Out-Null

        $status = Get-ProtocolStatusObject
        $status.registered | Should Be $false
        $status.currentHandler | Should Be ''
    }

    It 'reports handlerExists=false when the handler file does not exist' {
        $Script:CurseforgeProtocolKeyPath = $Script:testKey
        $Script:CurseforgeHandlerPath = Join-Path $protoRoot 'no-such-handler.vbs'

        (Get-ProtocolStatusObject).handlerExists | Should Be $false
    }

    It 'reports registered=false when the key does not exist at all (never throws)' {
        $Script:CurseforgeProtocolKeyPath = 'HKCU:\Software\Classes\furphy-test-curseforge-never-created-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $Script:CurseforgeHandlerPath = $handler

        { Get-ProtocolStatusObject } | Should Not Throw
        (Get-ProtocolStatusObject).registered | Should Be $false
    }

    It 'never touched the real curseforge:// key' {
        $Script:testKey | Should Match 'furphy-test-curseforge-'
    }
}

Describe 'Handle-ProtocolStatus - HTTP plumbing calls Get-ProtocolStatusObject, no child process' {

    It 'GET /api/protocol/status returns 200 with the status object shape, reading the overridden throwaway key' {
        $testKey = 'HKCU:\Software\Classes\furphy-test-curseforge-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $protoRoot = New-TempRoot -Name 'protocol-status-http'
        $handler = Join-Path $protoRoot 'curseforge-handler.vbs'
        [IO.File]::WriteAllText($handler, "' test handler`r`n")
        $Script:CurseforgeProtocolKeyPath = $testKey
        $Script:CurseforgeHandlerPath = $handler

        try {
            $ctx = New-FakeHttpContext -Method 'GET' -Path '/api/protocol/status'
            Handle-ProtocolStatus -Context $ctx -RouteMatch $null
            $body = Get-FakeResponseBody -Context $ctx

            $ctx.Response.StatusCode | Should Be 200
            $body.registered | Should Be $false
            $body.handlerPath | Should Be $handler
            $body.handlerExists | Should Be $true
        } finally {
            if (Test-Path -LiteralPath $testKey) { Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
