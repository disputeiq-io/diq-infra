<#
.SYNOPSIS
    Seeds multi-tenant disputes, PAN/PII-redacted evidence documents, outbox/DLQ replays,
    hybrid RAG knowledge playbooks, and LangGraph4j AI triage recommendations via the local Gateway.
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

Write-Host "Seeding DisputeIQ Phase 1-4 sample data via $GatewayUrl ..."

# 1. Ingest custom tenant knowledge playbooks (with PAN/PII redaction)
foreach ($src in $Data.knowledgeSources) {
    $tenant = $Data.tenants.($src.tenantKey)
    $ingested = Invoke-GatewayJson -Method "POST" -Path "/api/v1/knowledge/sources" -Token $tenant.token -Body @{
        ruleCode    = $src.ruleCode
        title       = $src.title
        network     = $src.network
        reasonCode  = $src.reasonCode
        sourceType  = $src.sourceType
        headingPath = $src.headingPath
        content     = $src.content
    }
    Write-Host "  Indexed policy playbook [$($ingested.ruleCode)] for tenant $($src.tenantKey)"
}

$results = @()

foreach ($entry in $Data.disputes) {
    $tenant = $Data.tenants.($entry.tenantKey)
    $token = $tenant.token

    # 2. File dispute idempotently, then read live state before transitioning
    $case = Invoke-GatewayJson -Method "POST" -Path "/api/v1/disputes" -Token $token `
        -ExtraHeaders @{ "Idempotency-Key" = $entry.idempotencyKey } -Body $entry.payload
    $caseId = $case.id
    $case = Invoke-GatewayJson -Method "GET" -Path "/api/v1/disputes/$caseId" -Token $token

    if ($case.state -eq "FILED" -and $entry.transitionTargetState) {
        $case = Invoke-GatewayJson -Method "PATCH" -Path "/api/v1/disputes/$caseId/state" -Token $token `
            -Body @{ targetState = $entry.transitionTargetState }
    }

    # 3. Inspect outbox events
    $outbox = Invoke-GatewayJson -Method "GET" -Path "/api/v1/disputes/$caseId/events" -Token $token

    # 4. Presign + extract/redact evidence documents
    $extractedCount = 0
    $maskedPans = 0
    $evidenceSummaries = @()
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
        $evidenceSummaries += [string]$extracted.redactedText

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

    # 6. Execute stateful LangGraph4j AI triage recommendation via Gateway -> Agent -> Knowledge
    $triageResp = Invoke-GatewayJson -Method "POST" -Path "/api/v1/agent/triage" -Token $token -Body @{
        caseId            = $caseId
        externalReference = $case.externalReference
        reasonCode        = $case.reasonCode
        amountCents       = $case.amountCents
        currency          = $case.currency
        merchantName      = $case.merchantName
        cardholderClaim   = $case.cardholderClaim
        evidenceCount     = $extractedCount
        evidenceSummaries = $evidenceSummaries
    }

    $results += [PSCustomObject]@{
        Tenant       = $entry.tenantKey
        Reference    = $case.externalReference
        ReasonCode   = $case.reasonCode
        State        = $case.state
        OutboxEvents = $outbox.events.Count
        Docs         = $extractedCount
        MaskedPANs   = $maskedPans
        DlqReplay    = $replayedStatus
        AiDecision   = $triageResp.decision
        Groundedness = $triageResp.groundednessScore
    }
}

# 7. Run CI Golden Eval Suite through gateway
$evalReport = Invoke-GatewayJson -Method "POST" -Path "/api/v1/agent/evals/run" -Token $Data.tenants.alpha.token
Write-Host ""
$results | Format-Table -AutoSize
Write-Host ("Golden Eval Suite -> Cases: {0}, Accuracy: {1:P0}, Recall@5: {2:P0}, CitationPrecision: {3:P0}, Groundedness: {4:P0}, Passed: {5}" -f `
    $evalReport.totalCases, $evalReport.decisionAccuracy, $evalReport.retrievalRecallAt5, $evalReport.citationPrecision, $evalReport.averageGroundedness, $evalReport.passedGate)
Write-Host "Demo seeding complete! Open http://localhost:5173 or inspect via $GatewayUrl"
