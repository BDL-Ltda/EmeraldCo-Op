# Run with: powershell -NoProfile -File scripts/tests/start-server.Tests.ps1
# No listener is opened: a function stands in for the native server executable.
$ErrorActionPreference = 'Stop'
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('Emerald launcher test ' + [guid]::NewGuid())
$originalKey = $env:SERVER_JOIN_KEY
$state = @{
    Key = [guid]::NewGuid().ToString('N')
    ExitCode = 0
    Calls = 0
    Cancel = $false
}

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    $fixtureScripts = Join-Path $fixtureRoot 'scripts'
    $fixtureHosting = Join-Path $fixtureRoot 'bin\hosting'
    New-Item -ItemType Directory -Path $fixtureScripts, $fixtureHosting | Out-Null
    $fixtureScript = Join-Path $fixtureScripts 'start-server.ps1'
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'start-server.ps1') -Destination $fixtureScript
    $fixtureServer = Join-Path $fixtureHosting 'server.exe'
    New-Item -ItemType File -Path $fixtureServer | Out-Null

    New-Item -Path Function:\Read-Host -Value ({
        param([string]$Prompt, [switch]$AsSecureString)
        if (-not $AsSecureString) { throw 'The key prompt must be masked.' }
        if ($state.Cancel) { throw $state.Key }
        ConvertTo-SecureString -String $state.Key -AsPlainText -Force
    }.GetNewClosure()) | Out-Null
    New-Item -Path ('Function:\' + $fixtureServer) -Value ({
        $state.Calls++
        $state.Arguments = @($args)
        $state.ChildKey = $env:SERVER_JOIN_KEY
        $global:LASTEXITCODE = $state.ExitCode
    }.GetNewClosure()) | Out-Null

    # Invoke from another working directory, with spaces in the repository path.
    $output = & $fixtureScript 6>&1 | Out-String
    Assert-True ($state.Calls -eq 1) 'The server must run once.'
    Assert-True (($state.Arguments -join '|') -eq '-addr|0.0.0.0:8765|-max-players|5') 'Unexpected server arguments.'
    Assert-True ($state.ChildKey -ceq $state.Key) 'The child must receive the prompted key.'
    Assert-True (-not $output.Contains($state.Key)) 'The key appeared in launcher output.'
    Assert-True ($output.Contains('Press Ctrl+C') -and $output.Contains('Server is no longer running.')) 'Startup and shutdown messages must remain visible.'
    Assert-True (-not (Test-Path Env:SERVER_JOIN_KEY)) 'The key must be cleared after success.'
    Assert-True ($LASTEXITCODE -eq 0) 'The successful exit code must be preserved.'
    Write-Output 'PASS: masked key, fixed IPv4 arguments, visible output and paths with spaces'

    $state.ExitCode = 7
    $null = & $fixtureScript 6>&1
    Assert-True ($LASTEXITCODE -eq 7) 'The native failure code must be preserved.'
    Assert-True (-not (Test-Path Env:SERVER_JOIN_KEY)) 'The key must be cleared after native failure.'
    Write-Output 'PASS: native error status and environment cleanup'

    $state.Cancel = $true
    $env:SERVER_JOIN_KEY = $state.Key
    $output = & $fixtureScript 6>&1 | Out-String
    Assert-True ($state.Calls -eq 2) 'A failed prompt must not start the server.'
    Assert-True ($LASTEXITCODE -eq 1) 'A prompt failure must set a failure status.'
    Assert-True (-not (Test-Path Env:SERVER_JOIN_KEY)) 'An inherited key must be cleared after prompt failure.'
    Assert-True (-not $output.Contains($state.Key)) 'An error exposed private input.'
    Write-Output 'PASS: prompt failure does not start a listener or retain a key'

    Remove-Item -LiteralPath $fixtureServer
    $output = & $fixtureScript 6>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 1) 'A missing executable must set a failure status.'
    Assert-True ($output.Contains('go build -o bin/hosting/server.exe ./cmd/server')) 'Missing build instructions.'
    Assert-True ($state.Calls -eq 2) 'A missing executable must not start the server.'
    Write-Output 'PASS: missing executable gives build instructions'
}
finally {
    $env:SERVER_JOIN_KEY = $originalKey
    Remove-Item -LiteralPath Function:\Read-Host -ErrorAction SilentlyContinue
    if ($fixtureServer) {
        Remove-Item -LiteralPath ('Function:\' + $fixtureServer) -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
        $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if ($resolvedFixture -ne $fixtureRoot -or -not $resolvedFixture.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to remove a fixture outside its temporary directory.'
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
