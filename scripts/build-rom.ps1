[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateRange(1, 256)]
    [int]$Jobs
)

$ErrorActionPreference = 'Stop'
# Preserve Docker's exit code on PowerShell versions that can turn native
# command failures into terminating errors. This variable is harmless on 5.1.
$PSNativeCommandUseErrorActionPreference = $false

try {
    # Docker Desktop can expose both docker.exe and an extensionless docker.
    $dockerCommand = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $dockerCommand) {
        throw 'Docker was not found. Install Docker Desktop and make sure docker is on PATH.'
    }

    $repositoryRoot = Split-Path -Parent $PSScriptRoot
    $composeArguments = @(
        'compose',
        '--project-directory', $repositoryRoot,
        '-f', (Join-Path $repositoryRoot 'docker-compose.yml'),
        'run', '--build', '--rm'
    )

    if ($PSBoundParameters.ContainsKey('Jobs')) {
        $composeArguments += @('--env', "JOBS=$Jobs")
    }
    $composeArguments += 'rom'

    & $dockerCommand.Source @composeArguments
    exit $LASTEXITCODE
}
catch {
    Write-Error -Message $_ -ErrorAction Continue
    exit 1
}
