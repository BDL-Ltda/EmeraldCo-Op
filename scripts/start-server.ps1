[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$serverExitCode = 1
$serverKey = $null

try {
    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $serverProgram = Join-Path $repositoryRoot 'bin\hosting\server.exe'
    if (-not (Test-Path -LiteralPath $serverProgram -PathType Leaf)) {
        Write-Host 'Server executable not found. Build it from the repository root:' -ForegroundColor Red
        Write-Host '  go build -o bin/hosting/server.exe ./cmd/server'
        return
    }

    Write-Host 'Emerald Co-Op server - TCP 8765 - up to 5 players'
    Write-Host 'Keep this window open. Press Ctrl+C to stop the server.'
    Write-Host 'Router forwarding and Windows Firewall must be configured separately.'
    Write-Host 'Logs can contain IP addresses. Do not share raw logs publicly.'
    $serverKey = Read-Host 'Server join key (shared privately)' -AsSecureString
    $env:SERVER_JOIN_KEY = [System.Net.NetworkCredential]::new('', $serverKey).Password

    # Keep the key out of command-line arguments and stream logs to this window.
    & $serverProgram -addr '0.0.0.0:8765' -max-players 5
    $serverExitCode = $LASTEXITCODE
    if ($serverExitCode -ne 0) {
        Write-Host 'Server exited with an error. Check the messages above.' -ForegroundColor Red
    }
}
catch {
    # Do not include exception details that could expose private input.
    Write-Host 'Launcher failed. Check the executable and try again.' -ForegroundColor Red
}
finally {
    Remove-Item Env:SERVER_JOIN_KEY -ErrorAction SilentlyContinue
    if ($null -ne $serverKey) {
        $serverKey.Dispose()
        $serverKey = $null
    }
    $global:LASTEXITCODE = $serverExitCode
    Write-Host 'Server is no longer running. You may close this window.'
}
