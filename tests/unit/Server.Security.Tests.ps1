<#
  Unit tests (Pester 3 syntax): addon-server.ps1's two Round 20 (adversarial
  bug pass) security functions - Test-SameOriginRequest (the CSRF guard)
  and ConvertTo-SafeProcessArg (command-line injection guard). Dot-sources
  the guarded server script (see the dot-source guard added to
  addon-server.ps1's own "# Startup" section) - never binds a real socket.
#>

. (Join-Path $PSScriptRoot '..\lib\common.ps1')
. (Join-Path $Script:FurphyBuildRoot 'addon-server.ps1')

Describe 'Test-SameOriginRequest' {

    $Script:Port = 47899

    It 'accepts a same-origin Origin header (http://localhost:<port>)' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/x' -Headers @{ Origin = 'http://localhost:47899' }
        (Test-SameOriginRequest -Context $ctx) | Should Be $true
    }

    It 'accepts a same-origin Origin header using 127.0.0.1 instead of localhost' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/x' -Headers @{ Origin = 'http://127.0.0.1:47899' }
        (Test-SameOriginRequest -Context $ctx) | Should Be $true
    }

    It 'rejects a foreign Origin' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/x' -Headers @{ Origin = 'http://evil.example' }
        (Test-SameOriginRequest -Context $ctx) | Should Be $false
    }

    It 'rejects when neither Origin nor Referer is present' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/x'
        (Test-SameOriginRequest -Context $ctx) | Should Be $false
    }

    It 'falls back to Referer when Origin is absent, and accepts a same-origin Referer' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/x' -Headers @{ Referer = 'http://localhost:47899/index.html' }
        (Test-SameOriginRequest -Context $ctx) | Should Be $true
    }

    It 'rejects an Origin on the wrong port, even for localhost' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/x' -Headers @{ Origin = 'http://localhost:9999' }
        (Test-SameOriginRequest -Context $ctx) | Should Be $false
    }

    It 'rejects an https Origin (the server only ever listens on http)' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/x' -Headers @{ Origin = 'https://localhost:47899' }
        (Test-SameOriginRequest -Context $ctx) | Should Be $false
    }

    It 'rejects a malformed (unparsable) Origin header instead of throwing' {
        $ctx = New-FakeHttpContext -Method 'POST' -Path '/api/x' -Headers @{ Origin = 'not a url at all' }
        (Test-SameOriginRequest -Context $ctx) | Should Be $false
    }
}

Describe 'ConvertTo-SafeProcessArg (CommandLineToArgvW round-trip)' {
    <#
      Every case builds a fake argv0 + one quoted argument via the function
      under test, joins them with a bare space (exactly how Start-Process
      -ArgumentList's elements are joined on this PowerShell version - see
      New-CliProcessArgs's own comment), then asks the REAL Win32
      CommandLineToArgvW to parse that command line back apart -
      ConvertFrom-Win32CommandLine in tests\lib\common.ps1. The assertion
      is "the OS's own argv parser reads back exactly the original value",
      not a hand-rolled reimplementation that could share a bug with the
      code under test.
    #>

    function Test-RoundTrip {
        param([string]$Value)
        $quoted = ConvertTo-SafeProcessArg -Value $Value
        $commandLine = 'argv0.exe ' + $quoted
        $argv = ConvertFrom-Win32CommandLine -CommandLine $commandLine
        return $argv[1]
    }

    It 'a value containing a literal space round-trips exactly (the CS-F2 injection repro: "1 -Remove 999")' {
        Test-RoundTrip -Value '1 -Remove 999' | Should Be '1 -Remove 999'
    }

    It 'a value containing a literal double quote round-trips exactly' {
        Test-RoundTrip -Value 'say "hello"' | Should Be 'say "hello"'
    }

    It 'a value containing backslashes immediately before a quote round-trips exactly (the classic CommandLineToArgvW edge case)' {
        Test-RoundTrip -Value 'C:\some\path\' | Should Be 'C:\some\path\'
    }

    It 'a value that is a single backslash followed by a quote character round-trips exactly' {
        Test-RoundTrip -Value 'a\"b' | Should Be 'a\"b'
    }

    It 'an empty string round-trips as an empty argv element (not a dropped argument)' {
        $quoted = ConvertTo-SafeProcessArg -Value ''
        $commandLine = 'argv0.exe ' + $quoted + ' next'
        $argv = ConvertFrom-Win32CommandLine -CommandLine $commandLine
        $argv.Count | Should Be 3
        $argv[1] | Should Be ''
        $argv[2] | Should Be 'next'
    }

    It 'a value that already looks like an extra command-line flag never becomes a separate argv token' {
        $quoted = ConvertTo-SafeProcessArg -Value '-Force -Remove 12345'
        $commandLine = 'argv0.exe ' + $quoted + ' -Json'
        $argv = ConvertFrom-Win32CommandLine -CommandLine $commandLine
        # Exactly 3 argv entries (argv0, the whole injected-looking value as
        # ONE token, and -Json) - never 5, which is what an unquoted join
        # would have produced.
        $argv.Count | Should Be 3
        $argv[1] | Should Be '-Force -Remove 12345'
        $argv[2] | Should Be '-Json'
    }

    It 'null is treated as an empty string, never throws' {
        $quoted = ConvertTo-SafeProcessArg -Value $null
        $quoted | Should Be '""'
    }
}

Remove-TempRoots
