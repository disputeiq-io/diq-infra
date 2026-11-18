<#
.SYNOPSIS
    Stops locally started DisputeIQ services and optionally stops Docker Compose backing services.
#>
param(
    [switch]$WithDocker
)
$ErrorActionPreference = "Continue"

$Root = "D:\Projects\disputeiq"
$PidFile = Join-Path $env:TEMP "disputeiq-local-pids.json"

if (Test-Path $PidFile) {
    $entries = Get-Content $PidFile -Raw | ConvertFrom-Json
    foreach ($entry in $entries) {
        Write-Host "Stopping $($entry.Name) (PID $($entry.Pid))..."
        taskkill /PID $entry.Pid /T /F 2>$null | Out-Null
    }
    Remove-Item -Force $PidFile -ErrorAction SilentlyContinue
} else {
    Write-Host "No active PID file found at $PidFile."
}

if ($WithDocker) {
    docker compose -f (Join-Path $Root "diq-infra\docker\docker-compose.dev.yml") down
}
