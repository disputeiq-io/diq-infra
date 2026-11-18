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
}

# Also clear any orphaned listeners on DisputeIQ local ports
foreach ($port in @(8080, 8081, 8082, 8087, 5173)) {
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($conn in $listeners) {
        if ($conn.OwningProcess -gt 4) {
            taskkill /PID $conn.OwningProcess /T /F 2>$null | Out-Null
        }
    }
}

if ($WithDocker) {
    docker compose -f (Join-Path $Root "diq-infra\docker\docker-compose.dev.yml") down
}
