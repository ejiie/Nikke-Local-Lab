#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [string]$ProtectedBase = '',
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

function Get-CanonicalDamageSourceSum {
    param([object[]]$Rows, [string]$Property)
    [long]$sum = 0
    foreach ($row in @($Rows)) {
        if ($row -is [Collections.IDictionary]) {
            Assert-True $row.Contains($Property) `
                ('phase3b2_damage_source_observer_v8_property_missing:' +
                    $Property)
            $value = $row[$Property]
        }
        else {
            $propertyValue = $row.PSObject.Properties[$Property]
            Assert-True ($null -ne $propertyValue) `
                ('phase3b2_damage_source_observer_v8_property_missing:' +
                    $Property)
            $value = $propertyValue.Value
        }
        $sum += [long]$value
    }
    return $sum
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($AuditOnly -or $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_damage_source_observer_v8_completion_repair_requires_administrator'
$legacySamsungBoundary =
    $env:SystemDrive -ceq 'C:' -and
    $env:USERNAME -ceq 'zih44' -and
    $MicronDriveLetter -ceq 'E'
$currentMicronBoundary =
    $env:SystemDrive -ceq 'C:' -and
    $env:USERNAME -ceq 'nlloperator' -and
    $MicronDriveLetter -ceq 'C'
Assert-True ($legacySamsungBoundary -or $currentMicronBoundary) `
    'phase3b2_damage_source_observer_v8_completion_repair_wrong_boot_boundary'

$micronDrive = $MicronDriveLetter + ':'
$assessmentUid = '9db13331-aa5b-469e-aaa5-d92bcb11c16e'
$evidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRDSO8'
$runRoot = Join-Path $evidenceRoot $assessmentUid
$deploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRDSO8D'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidDamageSourceObserver-v8'
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
    'complete-phase3b2-epinel-solo-raid-damage-source-observer-v8-in-micron.ps1'
$outerCompletionPath = Join-Path $toolRoot `
    'Complete-Phase3B2-Epinel-SoloRaidDamageSourceObserver-v8.ps1'
if ([string]::IsNullOrWhiteSpace($ProtectedBase)) {
    if ($currentMicronBoundary) {
        $ProtectedBase =
            'D:\NLL\Backups\EpinelSoloRaidDamageSourceObserver-v8\CompletionRepair-v1'
    }
    else {
        $ProtectedBase =
            'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidDamageSourceObserver-v8\CompletionRepair-v1'
    }
}
$protectedBase = $ProtectedBase

$expectedHashes = [ordered]@{
    pointer = 'becdde538126fcd9d6df6cb97f1de64751d4257b7d6cbe6e8bbfc335e4ccf58c'
    runStart = '7d9307d9ea0c25f9795b1674e3015e58003add933da06b67c8ec207809f32d4a'
    marker = 'b45c1801576508ff3073f31eacd6d631e596b594cdfff9748884e9e0e090b573'
    dbBefore = 'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
    hostsBefore = 'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
    runtimeDb = 'cb77d9809c38a8c5ec2c90e001dbd926ba3d3bb8ac1441c2a5680ac9c26d673b'
    micronHosts = '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'
    deployment = '8f88367eb79582be6c491ce04515dde5c2ccbbbbb2469262f42d76ddc4e0c51c'
    priorInnerCompletion =
        '4eb6abd1ede68c9bc37b31f06430b00c00280161b0af2f6e7a49368aef9a1109'
    outerCompletion =
        'c22e3f87d46abff37dd2da2c394b02f8c4d24402f7d4562b3a2d11da3545d661'
}

$requiredPaths = @(
    $activePointerPath, $runStartPath, $markerPath, $dbBeforePath,
    $hostsBeforePath, $deploymentPath, $runtimeDbPath, $micronHostsPath,
    $innerCompletionPath, $outerCompletionPath
)
Assert-True (@($requiredPaths | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) `
    'phase3b2_damage_source_observer_v8_completion_repair_input_missing'
Assert-True (
    @(Get-Process EpinelPS, nikke, NikkeLocalLab.Phase3B2.PhysicalBootstrap `
        -ErrorAction SilentlyContinue).Count -eq 0 -and
    -not (Test-Path -LiteralPath $completionPath) -and
    -not (Test-Path -LiteralPath $archivedPointerPath)
) 'phase3b2_damage_source_observer_v8_completion_repair_runtime_not_cold'

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
        ('phase3b2_damage_source_observer_v8_completion_repair_drift:' + $role)
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
        'nll/phase3b2-epinel-solo-raid-damage-source-observer-start/v8' -and
    [string]$runStart.runIntentCode -ceq 'challenge' -and
    $marker.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-damage-source-observer-marker-evidence/v8' -and
    [string]$marker.assessmentUid -ceq $assessmentUid -and
    [int]$marker.observationCount -eq 7 -and
    [int]$marker.scoreObservationCount -eq 15 -and
    [int]$marker.damageSourceObservationCount -eq 7 -and
    -not $marker.rawRequestPayloadPersisted -and
    @(Get-ChildItem -LiteralPath (Join-Path $runtimeRoot 'logs') `
        -Filter 'app-*.log' -File -ErrorAction SilentlyContinue).Count -eq 0
) 'phase3b2_damage_source_observer_v8_completion_repair_evidence_invalid'

$completedRows = @($marker.damageSourceObservations | Where-Object {
        [int]$_.battleResult -eq 1
    } | Sort-Object { [long]$_.sequence })
$authoritativeScore = Get-CanonicalDamageSourceSum $completedRows 'requestDamage'
Assert-True (
    $completedRows.Count -eq 5 -and
    $authoritativeScore -eq 16220800876L
) 'phase3b2_damage_source_observer_v8_completion_repair_observation_invalid'

# Reproduce the first-pass representation used by the original completion.
$dictionaryRowList = [Collections.Generic.List[object]]::new()
foreach ($row in $completedRows) {
    $dictionaryRowList.Add([ordered]@{
            requestDamage = [long]$row.requestDamage
            battleResult = [int]$row.battleResult
        })
}
$dictionaryRows = $dictionaryRowList.ToArray()
$dictionarySum = Get-CanonicalDamageSourceSum $dictionaryRows 'requestDamage'
$jsonValue = $dictionaryRows | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$jsonRows = [object[]]$jsonValue
$jsonSum = Get-CanonicalDamageSourceSum $jsonRows 'requestDamage'
Assert-True (
    $dictionarySum -eq $authoritativeScore -and
    $jsonSum -eq $authoritativeScore
) 'phase3b2_damage_source_observer_v8_completion_repair_representation_test_failed'

$priorText = (Get-Content -LiteralPath $innerCompletionPath -Raw `
        -Encoding UTF8).Replace("`r`n", "`n")
$before = @'
function Get-DamageSourceSum {
    param([object[]]$Rows, [string]$Property)
    $measure = $Rows | Measure-Object -Property $Property -Sum
    if ($null -eq $measure.Sum) { return 0L }
    return [long]$measure.Sum
}
'@.Replace("`r`n", "`n")
$after = @'
function Get-DamageSourceSum {
    param([object[]]$Rows, [string]$Property)
    [long]$sum = 0
    foreach ($row in @($Rows)) {
        if ($row -is [Collections.IDictionary]) {
            Assert-True $row.Contains($Property) `
                ('phase3b2_damage_source_observer_v8_property_missing:' +
                    $Property)
            $value = $row[$Property]
        }
        else {
            $propertyValue = $row.PSObject.Properties[$Property]
            Assert-True ($null -ne $propertyValue) `
                ('phase3b2_damage_source_observer_v8_property_missing:' +
                    $Property)
            $value = $propertyValue.Value
        }
        $sum += [long]$value
    }
    return $sum
}
'@.Replace("`r`n", "`n")
$replacementCount = [regex]::Matches(
    $priorText, [regex]::Escape($before)
).Count
Assert-True ($replacementCount -eq 1) `
    'phase3b2_damage_source_observer_v8_completion_repair_shape_invalid'
$repairedText = $priorText.Replace($before, $after)
$tokens = $null
$syntaxErrors = $null
[Management.Automation.Language.Parser]::ParseInput(
    $repairedText, [ref]$tokens, [ref]$syntaxErrors
) | Out-Null
$repairedBytes = [Text.UTF8Encoding]::new($false).GetBytes($repairedText)
$repairedSha256 = Get-BytesSha256Hex $repairedBytes
Assert-True (@($syntaxErrors).Count -eq 0) `
    'phase3b2_damage_source_observer_v8_completion_repair_candidate_invalid'

$audit = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-solo-raid-damage-source-observer-completion-repair-audit/v1'
    auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    assessmentUid = $assessmentUid
    causeCode =
        'first_pass_ordered_dictionary_not_measure_object_property_compatible'
    recoveryCode =
        'dictionary_and_pscustomobject_aware_checked_damage_sum'
    activePointerSha256 = $actualHashes.pointer
    runStartReceiptSha256 = $actualHashes.runStart
    markerEvidenceSha256 = $actualHashes.marker
    completedDamageSourceObservationCount = $completedRows.Count
    authoritativeFiveDeckScore = $authoritativeScore
    orderedDictionarySum = $dictionarySum
    jsonRoundTripObjectSum = $jsonSum
    representationParityVerified = $true
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
    ('NLL-v8-completion-repaired-' + [Guid]::NewGuid().ToString('N') + '.ps1')
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
    Assert-True ((Get-Sha256Hex $innerCompletionPath) -ceq $repairedSha256) `
        'phase3b2_damage_source_observer_v8_completion_repair_apply_failed'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-damage-source-observer-completion-repair/v1'
        repairedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        repairUid = $repairUid
        assessmentUid = $assessmentUid
        causeCode = $audit.causeCode
        recoveryCode = $audit.recoveryCode
        deploymentReceiptSha256 = $actualHashes.deployment
        activePointerSha256 = $actualHashes.pointer
        runStartReceiptSha256 = $actualHashes.runStart
        markerEvidenceSha256 = $actualHashes.marker
        completedDamageSourceObservationCount = $completedRows.Count
        authoritativeFiveDeckScore = $authoritativeScore
        representationParityVerified = $true
        priorInnerCompletionByteLength = 29714
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
        nextStepCode = 'boot_micron_run_v8_completion_only_without_start'
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
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidDamageSourceObserver-v8.ps1' -ObservedStageCode battle_result -OutcomeCode success"
    } | ConvertTo-Json -Depth 12
}
catch {
    if ($applied -and
        (Test-Path -LiteralPath $priorProtectedPath -PathType Leaf)) {
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
