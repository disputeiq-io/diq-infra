<#
.SYNOPSIS
    Starts the DisputeIQ local application stack (tenant, dispute, document, notification, gateway, simulator, and web UI).
.PARAMETER WithDocker
    Also starts PostgreSQL, Redis, Kafka, Schema Registry (plus optional Keycloak profile) via Docker Compose and connects services to PostgreSQL.
#>
param(
    [switch]$WithDocker
)
$ErrorActionPreference = "Stop"

$Root = "D:\Projects\disputeiq"
$PidFile = Join-Path $env:TEMP "disputeiq-local-pids.json"
$LogDir = Join-Path $env:TEMP "disputeiq-logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

# Ensure JDK 21 and Gradle 8.10.2 are ready
& (Join-Path $Root "diq-standards\scripts\ensure-toolchain.ps1")

# Clear any previous DisputeIQ listeners so every port binds cleanly
foreach ($port in @(8080, 8081, 8082, 8083, 8084, 8085, 8086, 8087, 5173)) {
    $listeners = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($conn in $listeners) {
        if ($conn.OwningProcess -gt 4) {
            Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
            cmd /c "taskkill /PID $($conn.OwningProcess) /T /F >nul 2>&1"
        }
    }
}
Start-Sleep -Milliseconds 500

if ($WithDocker) {
    Write-Host "Starting backing services via Docker Compose..."
    docker compose -f (Join-Path $Root "diq-infra\docker\docker-compose.dev.yml") up -d --wait
    $springProfile = "default"
} else {
    Write-Host "Starting DisputeIQ in zero-Docker local profile (H2 PostgreSQL-compat + local JWT tokens)..."
    $springProfile = "local"
}

# Publish latest shared libraries and schemas to mavenLocal
foreach ($lib in @("diq-event-schemas", "diq-platform-libs")) {
    Write-Host "Publishing $lib to mavenLocal..."
    Push-Location (Join-Path $Root $lib)
    & .\gradlew.bat publishToMavenLocal --no-daemon -q
    Pop-Location
}

$started = @()
$services = @(
    @{ Name = "diq-tenant-service";       Port = 8081 }
    @{ Name = "diq-dispute-service";      Port = 8082 }
    @{ Name = "diq-document-service";     Port = 8083 }
    @{ Name = "diq-knowledge-service";    Port = 8084 }
    @{ Name = "diq-agent-service";        Port = 8085 }
    @{ Name = "diq-notification-service"; Port = 8086 }
    @{ Name = "diq-gateway";              Port = 8080 }
    @{ Name = "diq-network-simulator";    Port = 8087 }
)

foreach ($svc in $services) {
    $svcDir = Join-Path $Root $svc.Name
    $outLog = Join-Path $LogDir "$($svc.Name).out.log"
    $errLog = Join-Path $LogDir "$($svc.Name).err.log"
    Write-Host "Launching $($svc.Name) on port $($svc.Port) (profile=$springProfile)..."
    $proc = Start-Process -FilePath "cmd.exe" `
        -ArgumentList "/c", "gradlew.bat bootRun --no-daemon --args=`"--spring.profiles.active=$springProfile`"" `
        -WorkingDirectory $svcDir `
        -RedirectStandardOutput $outLog `
        -RedirectStandardError $errLog `
        -PassThru `
        -WindowStyle Hidden
    $started += @{ Name = $svc.Name; Pid = $proc.Id; Port = $svc.Port; Log = $outLog }
}

$webDir = Join-Path $Root "diq-web"
if (-not (Test-Path (Join-Path $webDir "node_modules"))) {
    Write-Host "Installing diq-web npm dependencies..."
    Push-Location $webDir
    npm install --no-audit --no-fund
    Pop-Location
}
$webOut = Join-Path $LogDir "diq-web.out.log"
$webErr = Join-Path $LogDir "diq-web.err.log"
Write-Host "Launching diq-web Vite dev server on port 5173..."
$webProc = Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c", "npm run dev" `
    -WorkingDirectory $webDir `
    -RedirectStandardOutput $webOut `
    -RedirectStandardError $webErr `
    -PassThru `
    -WindowStyle Hidden
$started += @{ Name = "diq-web"; Pid = $webProc.Id; Port = 5173; Log = $webOut }

$started | ConvertTo-Json | Set-Content -Path $PidFile -Encoding UTF8

Write-Host "Waiting for health endpoints..."
$endpoints = @(
    @{ Name = "diq-tenant-service";       Url = "http://localhost:8081/actuator/health" }
    @{ Name = "diq-dispute-service";      Url = "http://localhost:8082/actuator/health" }
    @{ Name = "diq-document-service";     Url = "http://localhost:8083/actuator/health" }
    @{ Name = "diq-knowledge-service";    Url = "http://localhost:8084/actuator/health" }
    @{ Name = "diq-agent-service";        Url = "http://localhost:8085/actuator/health" }
    @{ Name = "diq-notification-service"; Url = "http://localhost:8086/actuator/health" }
    @{ Name = "diq-gateway";              Url = "http://localhost:8080/actuator/health" }
    @{ Name = "diq-network-simulator";    Url = "http://localhost:8087/actuator/health" }
    @{ Name = "diq-web";                  Url = "http://localhost:5173/" }
)

foreach ($ep in $endpoints) {
    $ready = $false
    for ($i = 0; $i -lt 45; $i++) {
        try {
            $resp = Invoke-WebRequest -Uri $ep.Url -UseBasicParsing -TimeoutSec 2
            if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) {
                $ready = $true
                break
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    if ($ready) {
        Write-Host "  READY: $($ep.Name) -> $($ep.Url)"
    } else {
        Write-Warning "  TIMEOUT waiting for $($ep.Name) ($($ep.Url)). Check logs under $LogDir"
    }
}

Write-Host ""
Write-Host "DisputeIQ local stack is running:"
Write-Host "  Web UI:               http://localhost:5173"
Write-Host "  API Gateway:          http://localhost:8080"
Write-Host "  Tenant Service:       http://localhost:8081"
Write-Host "  Dispute Service:      http://localhost:8082"
Write-Host "  Document Service:     http://localhost:8083"
Write-Host "  Knowledge Service:    http://localhost:8084"
Write-Host "  Agent Service:        http://localhost:8085"
Write-Host "  Notification Service: http://localhost:8086"
Write-Host "  Network Simulator:    http://localhost:8087"
Write-Host "Logs: $LogDir"
Write-Host "To stop: .\scripts\stop-local.ps1"
