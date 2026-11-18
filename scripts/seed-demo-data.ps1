<#
.SYNOPSIS
    Seeds realistic multi-tenant disputes, PAN/PII-redacted evidence documents, outbox events, and DLQ replays via the local API Gateway.
#>
param(
    [string]$GatewayUrl = "http://localhost:8080"
)
$ErrorActionPreference = "Stop"

$PayloadFile = Join-Path $PSScriptRoot "..\sample-data\sample-payloads.json"
$Data = Get-Content $PayloadFile -Raw | ConvertFrom-Json

function Invoke-GatewayJson {
    param(
        [string]$Method,
        [string]$Path,
        [string]$Token,
        [hashtable]$ExtraHeaders = @{},
        $Body = $null
    )
    $headers = @{ Authorization = "Bearer $Token" }
    foreach ($k in $ExtraHeaders.Keys) {
        $headers[$k] = $ExtraHeaders[$k]
    }
    $params = @{
        Uri             = "$GatewayUrl$Path"
        Method          = $Method
        Headers         = $headers
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $params["ContentType"] = "application/json"
        $params["Body"] = ($Body | ConvertTo-Json -Depth 10)
    }
    $resp = Invoke-WebRequest @params
    if ([string]::IsNullOrWhiteSpace($resp.Content)) {
        return $null
    }
    return ($resp.Content | ConvertFrom-Json)
}

Write-Host "Seeding DisputeIQ sample data via $GatewayUrl ..."
$results = @()

foreach ($entry in $Data.disputes) {
    $tenant = $Data.tenants.($entry.tenantKey)
    $token = $tenant.token

    # 1. File dispute idempotently, then read live state before transitioning
    $case = Invoke-GatewayJson -Method "POST" -Path "/api/v1/disputes" -Token $token `
        -ExtraHeaders @{ "Idempotency-Key" = $entry.idempotencyKey } -Body $entry.payload
    $caseId = $case.id
    $case = Invoke-GatewayJson -Method "GET" -Path "/api/v1/disputes/$caseId" -Token $token

    # 2. Transition state if still FILED
    if ($case.state -eq "FILED" -and $entry.transitionTargetState) {
        $case = Invoke-GatewayJson -Method "PATCH" -Path "/api/v1/disputes/$caseId/state" -Token $token `
            -Body @{ targetState = $entry.transitionTargetState }
    }

    # 3. Inspect outbox events
    $outbox = Invoke-GatewayJson -Method "GET" -Path "/api/v1/disputes/$caseId/events" -Token $token

    # 4. Presign + extract/redact evidence documents
    $extractedCount = 0
    $maskedPans = 0
    foreach ($doc in $entry.evidence) {
        $ticket = Invoke-GatewayJson -Method "POST" -Path "/api/v1/documents/presign" -Token $token `
            -Body @{
                caseId       = $caseId
                documentType = $doc.documentType
                fileName     = $doc.fileName
            }
        $extracted = Invoke-GatewayJson -Method "POST" -Path "/api/v1/documents/extract" -Token $token `
            -ExtraHeaders @{ "Idempotency-Key" = $doc.idempotencyKey } `
            -Body @{
                caseId       = $caseId
                documentType = $doc.documentType
                fileName     = $doc.fileName
                objectKey    = $ticket.objectKey
                rawText      = $doc.rawText
            }
        $extractedCount++
        $maskedPans += $extracted.maskedPanCount

        # Notify timeline on first ingestion (inbox deduplication prevents duplicates on re-runs)
        $null = Invoke-GatewayJson -Method "POST" -Path "/api/v1/notifications/events" -Token $token `
            -Body @{
                eventId     = "tl-$($extracted.id)"
                caseId      = $caseId
                topic       = "document.evidence.extracted.v1"
                summary     = "Extracted $($doc.documentType) ($($doc.fileName)) · Masked $($extracted.maskedPanCount) PAN(s)"
                payloadJson = ($extracted.extractedFields | ConvertTo-Json -Compress)
            }
    }

    # 5. Optional DLQ simulation + deterministic replay
    $replayedStatus = "N/A"
    if ($null -ne $entry.dlqSimulation) {
        $dlqResp = Invoke-GatewayJson -Method "POST" -Path "/api/v1/notifications/events" -Token $token `
            -Body @{
                eventId         = $entry.dlqSimulation.eventId
                caseId          = $caseId
                topic           = $entry.dlqSimulation.topic
                summary         = $entry.dlqSimulation.summary
                payloadJson     = "{`"caseId`":`"$caseId`"}"
                simulateFailure = $true
                failureReason   = $entry.dlqSimulation.failureReason
            }
        if ($dlqResp.dlq) {
            $replay = Invoke-GatewayJson -Method "POST" `
                -Path "/api/v1/notifications/dlq/$($dlqResp.dlq.dlqId)/replay" -Token $token
            $replayedStatus = $replay.status
        }
    }

    $results += [PSCustomObject]@{
        Tenant       = $entry.tenantKey
        CaseId       = $caseId
        Reference    = $case.externalReference
        State        = $case.state
        OutboxEvents = $outbox.events.Count
        Documents    = $extractedCount
        MaskedPANs   = $maskedPans
        DlqReplay    = $replayedStatus
    }
}

Write-Host ""
$results | Format-Table -AutoSize
Write-Host "Demo seeding complete! Open http://localhost:5173 or run Invoke-RestMethod against $GatewayUrl"
