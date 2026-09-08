#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [switch]$AuditOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ($algorithm.ComputeHash($Bytes) | ForEach-Object {
                $_.ToString('x2')
            }) -join ''
    }
    finally {
        $algorithm.Dispose()
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    Write-Utf8NoBom $temporary (($Value | ConvertTo-Json -Depth 12) + "`n")
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function ConvertTo-ObservationUtc {
    param([object]$Value)
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($AuditOnly -or $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_score_consistency_v7_completion_repair_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_score_consistency_v7_completion_repair_wrong_samsung_boundary'

$micronDrive = $MicronDriveLetter + ':'
$assessmentUid = '450862f3-3419-4f4d-bb52-1aaa0abca161'
$evidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRSC7'
$runRoot = Join-Path $evidenceRoot $assessmentUid
$deploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRSC7D'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidScoreConsistency-v7'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$activePointerPath = Join-Path $evidenceRoot 'active-run.pointer.json'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$markerPath = Join-Path $runRoot 'regroup.observations.json'
$dbBeforePath = Join-Path $runRoot 'db.before.bin'
$hostsBeforePath = Join-Path $runRoot 'hosts.before.bin'
$completionPath = Join-Path $runRoot 'completion.receipt.json'
$archivedPointerPath = Join-Path $runRoot 'active-run.pointer.archived.json'
$deploymentPath = Join-Path $deploymentRoot 'deployment.receipt.json'
$runtimeDbPath = Join-Path $runtimeRoot 'db.json'
$micronHostsPath = Join-Path $micronDrive `
    'Windows\System32\drivers\etc\hosts'
$innerCompletionPath = Join-Path $toolRoot `
    'complete-phase3b2-epinel-solo-raid-score-consistency-v7-in-micron.ps1'
$outerCompletionPath = Join-Path $toolRoot `
    'Complete-Phase3B2-Epinel-SoloRaidScoreConsistency-v7.ps1'
$protectedBase =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidScoreConsistency-v7\CompletionRepair-v1'

$expectedHashes = [ordered]@{
    pointer = 'f91d45f8ba270c3c3fe96e62a35c8f7d2cc62baa9fe887326769fa1718cf84c9'
    runStart = '3bf37fb95f9fd308deaba0dd3a3f13a74de52b5e801fffe5cdc957ef8c98bee9'
    marker = 'e8c13936f34eb3cc65569c5c69035e079049abc67024eccae127200882ab3645'
    dbBefore = 'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
    hostsBefore = 'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
    runtimeDb = '1cc07c06a8395669e068b9e9b4de5d4d33ada131578cb006bf91ad4fc3f6bd76'
    micronHosts = '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'
    deployment = 'dc9b7cce0b14bf6203f7f4c406699878ee7a2525bf30b51fb9843a0bb374c35e'
    priorInnerCompletion =
        '734d2c50f43f57f3acedcbbb35536d8ca0b573147bd4887cf0c7c71d187e63fb'
    outerCompletion =
        '29b19f4653f3d66c123076001092cbcf1de2add63eeac91716e11b6d71288f7d'
    repairedInnerCompletion =
        '6b84316b208f125e4c74aa7982eed754935b19be640ad54e65ce8df79c3549b2'
}

$requiredPaths = @(
    $activePointerPath, $runStartPath, $markerPath, $dbBeforePath,
    $hostsBeforePath, $deploymentPath, $runtimeDbPath, $micronHostsPath,
    $innerCompletionPath, $outerCompletionPath
)
Assert-True (@($requiredPaths | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) `
    'phase3b2_score_consistency_v7_completion_repair_input_missing'
Assert-True (
    @(Get-Process EpinelPS, nikke, NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    -not (Test-Path -LiteralPath $completionPath) -and
    -not (Test-Path -LiteralPath $archivedPointerPath)
) 'phase3b2_score_consistency_v7_completion_repair_runtime_not_cold'

$actualHashes = [ordered]@{
    pointer = Get-Sha256Hex $activePointerPath
    runStart = Get-Sha256Hex $runStartPath
    marker = Get-Sha256Hex $markerPath
    dbBefore = Get-Sha256Hex $dbBeforePath
    hostsBefore = Get-Sha256Hex $hostsBeforePath
    runtimeDb = Get-Sha256Hex $runtimeDbPath
    micronHosts = Get-Sha256Hex $micronHostsPath
    deployment = Get-Sha256Hex $deploymentPath
    priorInnerCompletion = Get-Sha256Hex $innerCompletionPath
    outerCompletion = Get-Sha256Hex $outerCompletionPath
}
foreach ($role in $actualHashes.Keys) {
    Assert-True ($actualHashes[$role] -ceq $expectedHashes[$role]) `
        ('phase3b2_score_consistency_v7_completion_repair_drift:' + $role)
}

$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    [string]$pointer.assessmentUid -ceq $assessmentUid -and
    [string]$pointer.runStartReceiptSha256 -ceq $expectedHashes.runStart -and
    $runStart.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-score-consistency-start/v7' -and
    [string]$runStart.runIntentCode -ceq 'challenge' -and
    $marker.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-score-consistency-marker-evidence/v7' -and
    [string]$marker.assessmentUid -ceq $assessmentUid -and
    [int]$marker.observationCount -eq 13 -and
    [int]$marker.scoreObservationCount -eq 26 -and
    -not $marker.rawRequestPayloadPersisted -and
    @(Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'logs') `
        -Filter 'app-*.log' -File -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_score_consistency_v7_completion_repair_evidence_invalid'

$authoritativeScore = 35177379898L
$scoreObservations = @($marker.scoreObservations)
$completedResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_trial_setdamage' -and
        [int]$_.battleResult -eq 1
    } | Sort-Object { [long]$_.sequence })
$finalCompletedResponse = $completedResponses[-1]
$finalCompletedUtc = ConvertTo-ObservationUtc $finalCompletedResponse.utc
$allInfo = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_get'
    })
$allRanking = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_getranking'
    })
$postFinalInfo = @($allInfo | Where-Object {
        (ConvertTo-ObservationUtc $_.utc) -ge $finalCompletedUtc
    })
$postFinalRanking = @($allRanking | Where-Object {
        (ConvertTo-ObservationUtc $_.utc) -ge $finalCompletedUtc
    })
$postFinalSquad = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_getrankersquad' -and
        (ConvertTo-ObservationUtc $_.utc) -ge $finalCompletedUtc
    })
$legacyWholeRunProjectionFails =
    @($allInfo | Where-Object {
            [long]$_.trialDamage -ne $authoritativeScore
        }).Count -gt 0 -and
    @($allRanking | Where-Object {
            [long]$_.rankingDamage -ne $authoritativeScore -or
            [long]$_.userDamage -ne $authoritativeScore -or
            [int]$_.totalUserCount -ne 1
        }).Count -gt 0
$postFinalProjectionPasses =
    [long]$finalCompletedResponse.infoDamage -eq $authoritativeScore -and
    [long]$finalCompletedResponse.userDamage -eq $authoritativeScore -and
    [int]$finalCompletedResponse.totalUserCount -eq 1 -and
    $postFinalInfo.Count -eq 1 -and
    @($postFinalInfo | Where-Object {
            [long]$_.trialDamage -ne $authoritativeScore
        }).Count -eq 0 -and
    $postFinalRanking.Count -eq 3 -and
    @($postFinalRanking | Where-Object {
            [long]$_.rankingDamage -ne $authoritativeScore -or
            [long]$_.userDamage -ne $authoritativeScore -or
            [int]$_.totalUserCount -ne 1
        }).Count -eq 0 -and
    $postFinalSquad.Count -eq 3 -and
    @($postFinalSquad | Where-Object {
            [int]$_.logCount -ne 5 -or
            [long]$_.logDamageSum -ne $authoritativeScore
        }).Count -eq 0
Assert-True ($legacyWholeRunProjectionFails -and $postFinalProjectionPasses) `
    'phase3b2_score_consistency_v7_completion_repair_cause_not_reproduced'

$priorText = (Get-Content -LiteralPath $innerCompletionPath -Raw `
        -Encoding UTF8).Replace("`r`n", "`n")
$before = @'
$infoScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_get'
    })
$infoScoreConsistent = @($infoScoreResponses | Where-Object {
        [long]$_.trialDamage -ne $authoritativeScore
    }).Count -eq 0
$rankingScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_getranking'
    })
$rankingScoreConsistent = @($rankingScoreResponses | Where-Object {
        [long]$_.rankingDamage -ne $authoritativeScore -or
        [long]$_.userDamage -ne $authoritativeScore -or
        [int]$_.totalUserCount -ne 1
    }).Count -eq 0
$rankerSquadScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_getrankersquad'
    })
$rankerSquadScoreConsistent = @($rankerSquadScoreResponses | Where-Object {
        [int]$_.logCount -ne 5 -or
        [long]$_.logDamageSum -ne $authoritativeScore
    }).Count -eq 0
'@.Replace("`r`n", "`n")
$after = @'
function ConvertTo-ScoreObservationUtc {
    param([object]$Value)
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
}
$finalCompletedScoreUtc = if ($null -ne $finalCompletedScoreResponse) {
    ConvertTo-ScoreObservationUtc $finalCompletedScoreResponse.utc
} else { [DateTimeOffset]::MinValue }
$infoScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_get' -and
        (ConvertTo-ScoreObservationUtc $_.utc) -ge $finalCompletedScoreUtc
    })
$infoScoreConsistent = $infoScoreResponses.Count -gt 0 -and
    @($infoScoreResponses | Where-Object {
        [long]$_.trialDamage -ne $authoritativeScore
    }).Count -eq 0
$rankingScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_getranking' -and
        (ConvertTo-ScoreObservationUtc $_.utc) -ge $finalCompletedScoreUtc
    })
$rankingScoreConsistent = $rankingScoreResponses.Count -gt 0 -and
    @($rankingScoreResponses | Where-Object {
        [long]$_.rankingDamage -ne $authoritativeScore -or
        [long]$_.userDamage -ne $authoritativeScore -or
        [int]$_.totalUserCount -ne 1
    }).Count -eq 0
$rankerSquadScoreResponses = @($scoreObservations | Where-Object {
        [string]$_.route -ceq 'soloraid_getrankersquad' -and
        (ConvertTo-ScoreObservationUtc $_.utc) -ge $finalCompletedScoreUtc
    })
$rankerSquadScoreConsistent = $rankerSquadScoreResponses.Count -gt 0 -and
    @($rankerSquadScoreResponses | Where-Object {
        [int]$_.logCount -ne 5 -or
        [long]$_.logDamageSum -ne $authoritativeScore
    }).Count -eq 0
'@.Replace("`r`n", "`n")
$replacementCount = [regex]::Matches(
    $priorText, [regex]::Escape($before)
).Count
Assert-True ($replacementCount -eq 1) `
    'phase3b2_score_consistency_v7_completion_repair_projection_shape_invalid'
$repairedText = $priorText.Replace($before, $after)
$tokens = $null
$syntaxErrors = $null
[Management.Automation.Language.Parser]::ParseInput(
    $repairedText, [ref]$tokens, [ref]$syntaxErrors
) | Out-Null
$repairedBytes = [Text.UTF8Encoding]::new($false).GetBytes($repairedText)
$repairedSha256 = Get-BytesSha256Hex $repairedBytes
Assert-True (
    @($syntaxErrors).Count -eq 0 -and
    $repairedBytes.Length -eq 24272 -and
    $repairedSha256 -ceq $expectedHashes.repairedInnerCompletion
) 'phase3b2_score_consistency_v7_completion_repair_candidate_invalid'

$audit = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-solo-raid-score-consistency-completion-repair-audit/v1'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $assessmentUid
    causeCode = 'pre_completion_zero_score_snapshots_included_in_final_projection_gate'
    recoveryCode = 'verify_only_observations_at_or_after_final_completed_response'
    activePointerSha256 = $actualHashes.pointer
    runStartReceiptSha256 = $actualHashes.runStart
    markerEvidenceSha256 = $actualHashes.marker
    authoritativeFiveDeckScore = $authoritativeScore
    legacyWholeRunProjectionFails = $legacyWholeRunProjectionFails
    postFinalInfoObservationCount = $postFinalInfo.Count
    postFinalRankingObservationCount = $postFinalRanking.Count
    postFinalRankerSquadObservationCount = $postFinalSquad.Count
    postFinalProjectionPasses = $postFinalProjectionPasses
    priorInnerCompletionSha256 = $actualHashes.priorInnerCompletion
    repairedInnerCompletionByteLength = $repairedBytes.Length
    repairedInnerCompletionSha256 = $repairedSha256
    runtimeCold = $true
    databaseModified = $false
    hostsModified = $false
    activePointerModified = $false
    markerEvidenceModified = $false
    goldenModified = $false
    dLobbyGoldenModified = $false
    repairApplicable = $true
}
if ($AuditOnly) {
    $audit | ConvertTo-Json -Depth 10
    return
}

$repairUid = [Guid]::NewGuid().ToString('D')
$repairRoot = Join-Path $deploymentRoot `
    ('completion-repair-v1\' + $repairUid)
$protectedRoot = Join-Path $protectedBase $repairUid
$temporaryRepairedPath = Join-Path $env:TEMP `
    ('NLL-v7-completion-repaired-' + [Guid]::NewGuid().ToString('N') + '.ps1')
$priorProtectedPath = Join-Path $protectedRoot 'prior-inner-completion.ps1'
$applied = $false
try {
    New-Item -ItemType Directory -Path $repairRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
    Copy-Item -LiteralPath $innerCompletionPath -Destination `
        (Join-Path $repairRoot 'prior-inner-completion.ps1')
    Copy-Item -LiteralPath $innerCompletionPath -Destination $priorProtectedPath
    Write-Utf8NoBom $temporaryRepairedPath $repairedText
    Copy-Item -LiteralPath $temporaryRepairedPath -Destination `
        $innerCompletionPath -Force
    $applied = $true
    Assert-True (
        (Get-Sha256Hex $innerCompletionPath) -ceq
            $expectedHashes.repairedInnerCompletion
    ) 'phase3b2_score_consistency_v7_completion_repair_apply_failed'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-score-consistency-completion-repair/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        repairUid = $repairUid
        assessmentUid = $assessmentUid
        causeCode = $audit.causeCode
        recoveryCode = $audit.recoveryCode
        deploymentReceiptSha256 = $actualHashes.deployment
        activePointerSha256 = $actualHashes.pointer
        runStartReceiptSha256 = $actualHashes.runStart
        markerEvidenceSha256 = $actualHashes.marker
        authoritativeFiveDeckScore = $authoritativeScore
        postFinalInfoObservationCount = $postFinalInfo.Count
        postFinalRankingObservationCount = $postFinalRanking.Count
        postFinalRankerSquadObservationCount = $postFinalSquad.Count
        postFinalProjectionPasses = $postFinalProjectionPasses
        priorInnerCompletionByteLength = 23342
        priorInnerCompletionSha256 = $actualHashes.priorInnerCompletion
        repairedInnerCompletionByteLength = $repairedBytes.Length
        repairedInnerCompletionSha256 = $repairedSha256
        outerCompletionModified = $false
        runtimeModified = $false
        databaseModified = $false
        hostsModified = $false
        activePointerModified = $false
        markerEvidenceModified = $false
        goldenModified = $false
        dLobbyGoldenModified = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'boot_micron_run_v7_completion_only_without_start'
    }
    $receiptPath = Join-Path $repairRoot 'repair.receipt.json'
    Write-AtomicJson $receiptPath $receipt
    Copy-Item -LiteralPath $receiptPath -Destination $protectedRoot
    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRoot 'repair.receipt.json'
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidScoreConsistency-v7.ps1' -ObservedStageCode battle_result -OutcomeCode success"
    } | ConvertTo-Json -Depth 12
}
catch {
    if ($applied -and (Test-Path -LiteralPath $priorProtectedPath -PathType Leaf)) {
        Copy-Item -LiteralPath $priorProtectedPath -Destination `
            $innerCompletionPath -Force
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $temporaryRepairedPath) {
        Remove-Item -LiteralPath $temporaryRepairedPath -Force
    }
}
