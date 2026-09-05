<#
=====================================================================
 tests\integration\Server.Security.Tests.ps1

 CSRF guard (Test-SameOriginRequest), the loopback-only listener bind
 (Round 20 security-1: 127.0.0.1 + [::1], never a LAN-reachable prefix),
 POST /api/open's validation (never triggers the positive/window-
 opening case per the task brief), and Read-Body's Content-Type
 enforcement (Round 20 security-2).

 Review fix: the Content-Type Describe is new - a real, confirmed
 coverage gap. Read-Body (addon-server.ps1) throws "bad request:
 Content-Type must be application/json" for anything else, but every
 test in this suite used to call Invoke-Api with no way to send a
 different Content-Type (it hardcoded application/json; charset=utf-8
 on every non-GET call) - this security fix could never actually be
 exercised. Fixed via Invoke-Api's new -ContentType override
 (tests\lib\common.ps1).
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')

Describe 'CSRF guard (Test-SameOriginRequest)' {
    $root = New-TempRoot -Name 'csrf'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899

        It 'a state-changing request with NO Origin/Referer is refused 403' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 1 } -NoOrigin
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 403
        }

        It 'a state-changing request with a FOREIGN Origin is refused 403' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 1 } -Headers @{ Origin = 'http://evil.example.com' } -NoOrigin
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 403
        }

        It 'a foreign Origin on a different PORT (same host) is still refused 403' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 1 } -Headers @{ Origin = 'http://localhost:9999' } -NoOrigin
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 403
        }

        It 'a same-origin Referer (no Origin header at all) is accepted 200' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 1 } -Headers @{ Referer = 'http://localhost:47899/index.html' } -NoOrigin
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 200
        }

        It 'GET requests never need Origin/Referer at all' {
            $r = Invoke-Api -Port 47899 -Method Get -Path '/api/state' -NoOrigin
            $r.Ok | Should Be $true
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'Content-Type validation (Read-Body, Round 20 security-2)' {
    $root = New-TempRoot -Name 'content-type'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899

        It 'a non-application/json Content-Type with a body is rejected 400, never reaching the handler' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 1 } -ContentType 'text/plain'
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'bad request: Content-Type must be application/json'
        }

        It 'a completely missing Content-Type on a request WITH a body is rejected 400' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 1 } -ContentType ''
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'bad request: Content-Type must be application/json'
        }

        It 'application/json with a charset suffix (the SPA''s own real value) is still accepted 200' {
            $r = Invoke-Api -Port 47899 -Method Put -Path '/api/settings' -Body @{ releaseType = 1 } -ContentType 'application/json; charset=utf-8'
            $r.Ok | Should Be $true
            $r.StatusCode | Should Be 200
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'Listener bound to loopback only (Round 20 security-1)' {
    $root = New-TempRoot -Name 'loopback'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899

        It 'GET-NetTCPConnection shows the listener bound only to 127.0.0.1 and/or ::1, never 0.0.0.0/*/[::]' {
            $conns = Get-NetTCPConnection -LocalPort 47899 -State Listen -ErrorAction SilentlyContinue
            $conns | Should Not Be $null
            $badAddrs = @('0.0.0.0', '::')
            foreach ($c in @($conns)) {
                ($badAddrs -contains $c.LocalAddress) | Should Be $false
                (@('127.0.0.1', '::1') -contains $c.LocalAddress) | Should Be $true
            }
        }

        It 'a real LAN IP on this machine refuses the connection (loopback-only bind, not Host-header dispatch)' {
            $lanIps = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' -and $_.AddressState -eq 'Preferred' })
            if ($lanIps.Count -eq 0) {
                Write-Host '  (skipped: no non-loopback IPv4 address found on this machine)'
            } else {
                $lanIp = $lanIps[0].IPAddress
                (Test-PortOpen -Port 47899 -HostName $lanIp -TimeoutMs 1000) | Should Be $false
            }
        }
    } finally {
        Stop-TestServer -Server $server
    }
}

Describe 'POST /api/open validation (never triggering the positive/window-opening case)' {
    $root = New-TempRoot -Name 'open'
    $server = $null
    try {
        $server = Start-TestServer -Root $root -Port 47899

        It 'an unknown "what" is 400' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/open' -Body @{ what = 'not-a-real-target' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'unknown what: not-a-real-target'
        }

        It 'missing "what" entirely is 400' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/open' -Body @{ projectId = 1 }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'what required'
        }

        It 'what=url with a foreign host is 400 (allow-list is exact-match, not prefix)' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/open' -Body @{ what = 'url'; url = 'https://evil.example.com/x' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'what=url with a smuggled space AND a foreign host is 400 (host check runs first)' {
            # IMPORTANT - do not adapt this into a smuggled-space test against
            # www.curseforge.com/addons.wago.io: this endpoint's actual
            # mitigation (Round 20 server-3) is to re-parse the URL and pass
            # only [System.Uri]::AbsoluteUri onward, which PERCENT-ENCODES a
            # raw space rather than rejecting it - so a syntactically-valid
            # allow-listed-host URL containing a space is neutralized and
            # then genuinely OPENED (200), not 400'd. Confirmed live (and
            # accidentally triggered a real Edge window during this file's
            # own development - see notesForNext) that
            # "https://www.curseforge.com/x --app=..." returns 200. The only
            # safe, deterministic way to prove the space can never smuggle an
            # extra argv token is to pair it with a host that ALSO fails the
            # allow-list, so this assertion never depends on reaching (or
            # not reaching) Start-Process at all.
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/open' -Body @{ what = 'url'; url = 'https://evil.example.com/x --app=http://also-evil.example.com/phish' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'what=url missing url entirely is 400' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/open' -Body @{ what = 'url' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
            $r.Body.error | Should Be 'url required'
        }

        It 'what=cf-window with a non-curseforge url is 400' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/open' -Body @{ what = 'cf-window'; url = 'https://addons.wago.io/addons/foo' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }

        It 'what=curseforge with neither slug nor projectId is 400' {
            $r = Invoke-Api -Port 47899 -Method Post -Path '/api/open' -Body @{ what = 'curseforge' }
            $r.Ok | Should Be $false
            $r.StatusCode | Should Be 400
        }
    } finally {
        Stop-TestServer -Server $server
    }
}
