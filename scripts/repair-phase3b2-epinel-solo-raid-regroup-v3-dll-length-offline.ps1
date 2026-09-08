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
        (($algorithm.ComputeHash($Bytes) | ForEach-Object {
                    $_.ToString('x2')
                }) -join '')
    }
    finally { $algorithm.Dispose() }
}

function Test-Digest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText(
        $Path, $Text, [Text.UTF8Encoding]::new($false)
    )
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Write-Utf8NoBom $temporary `
            (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
        Move-Item -LiteralPath $temporary -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Assert-PowerShellSyntax {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors
    ) | Out-Null
    Assert-True (@($errors).Count -eq 0) `
        'phase3b2_regroup_v3_length_repair_tool_syntax_invalid'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($AuditOnly -or $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_regroup_v3_length_repair_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_regroup_v3_length_repair_wrong_samsung_boundary'

$micronDrive = $MicronDriveLetter + ':'
if ($AuditOnly) {
    Assert-True (
        $micronDrive -cne $env:SystemDrive -and
        (Test-Path -LiteralPath ($micronDrive + '\') -PathType Container)
    ) 'phase3b2_regroup_v3_length_repair_audit_volume_boundary_invalid'
}
else {
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
    Assert-True (
        $micronDrive -cne $env:SystemDrive -and
        $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
        $micronDisk.FriendlyName -like 'Micron_2200*'
    ) 'phase3b2_regroup_v3_length_repair_physical_boundary_invalid'
}
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_regroup_v3_length_repair_runtime_not_cold'

$deploymentUid = '5095c6cb-85b9-4e0f-a1de-9ff4d0d758d0'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$outerStartPath = Join-Path $toolRoot `
    'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1'
$innerStartPath = Join-Path $toolRoot `
    'start-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1'
$outerCompletionPath = Join-Path $toolRoot `
    'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1'
$innerCompletionPath = Join-Path $toolRoot `
    'complete-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1'
$runtimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v3'
$evidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRTP3'
$deploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRTP3D'
$deploymentReceiptPath = Join-Path $deploymentRoot `
    'deployment.receipt.json'
$repairReceiptPath = Join-Path $deploymentRoot `
    'start-content-length-correction.receipt.json'
$protectedRoot = Join-Path `
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidRegroupSemantics-v3' `
    $deploymentUid
$dBackupSealPath =
    'D:\NikkeLocalLab\Backups\phase3b2-lobby-en-d830a90d-20260826T103327Z\metadata\backup.seal.receipt.json'

$expectedDeploymentReceiptSha256 =
    '71b0ac36178e994ec0a1e4d45d80461fd350e93226f7abf38586ca4b98ede58a'
$expectedPriorOuterStartSha256 =
    '38757bb0098256c839b9b680835ea59ebab3352812417f24447ca691c1664d1a'
$expectedCorrectedOuterStartSha256 =
    'ef93a21dc6555ea1fac5af5f3f69264d7bf6d62399a4db56aea857dd93e0589d'
$expectedServerDllSha256 =
    '79e499169b42e58e73677fc99c77217f15d6056529bd6f583ce2152127ec28be'
$expectedDBackupSealSha256 =
    'e4c1f9af044387f1624a828421800b29c9a0aa4c015f4e82f3534f70484ea613'

Assert-True (
    (Test-Digest $deploymentReceiptPath 4685L `
        $expectedDeploymentReceiptSha256) -and
    (Test-Digest $outerStartPath 8555L `
        $expectedPriorOuterStartSha256) -and
    (Test-Digest $innerStartPath 37963L `
        'd5aa8089e0a6c6075f85f527262a4825a465d48050412f0e3a8c025b92319d69') -and
    (Test-Digest $outerCompletionPath 727L `
        '5ea5f9f4d0883c3ae2f0437ec42cfc6584b7abf5ebdfd5906d3d6bd666ef86fa') -and
    (Test-Digest $innerCompletionPath 11121L `
        'c3bc7a5259f6a7228b75a103338488a7543a8b53fd6aee940d41ae9d83fe17d9') -and
    (Test-Digest (Join-Path $runtimeRoot 'EpinelPS.dll') 15377920L `
        $expectedServerDllSha256) -and
    (Test-Digest $dBackupSealPath 2177L $expectedDBackupSealSha256) -and
    (Test-Path -LiteralPath $evidenceRoot -PathType Container) -and
    @(Get-ChildItem -LiteralPath $evidenceRoot -Force).Count -eq 0 -and
    -not (Test-Path -LiteralPath $repairReceiptPath)
) 'phase3b2_regroup_v3_length_repair_input_missing_or_drifted'

$deploymentReceipt = Get-Content -LiteralPath $deploymentReceiptPath `
    -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $deploymentReceipt.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-regroup-semantics-deployment/v3' -and
    $deploymentReceipt.deploymentUid -ceq $deploymentUid -and
    -not $deploymentReceipt.validationRunConsumed -and
    -not $deploymentReceipt.v2RuntimeModified -and
    -not $deploymentReceipt.micronLobbyGoldenModified -and
    -not $deploymentReceipt.dLobbyGoldenModified
) 'phase3b2_regroup_v3_length_repair_deployment_shape_invalid'

$priorText = [IO.File]::ReadAllText(
    $outerStartPath, [Text.Encoding]::UTF8
).Replace("`r`n", "`n")
$oldValue = '15377408L'
$newValue = '15377920L'
$matchCount = ([regex]::Matches(
        $priorText, [regex]::Escape($oldValue)
    )).Count
Assert-True ($matchCount -eq 1) `
    'phase3b2_regroup_v3_length_repair_projection_shape_invalid'
$correctedText = $priorText.Replace($oldValue, $newValue)
$correctedBytes = [Text.UTF8Encoding]::new($false).GetBytes($correctedText)
Assert-True (
    $correctedBytes.Length -eq 8555 -and
    (Get-BytesSha256Hex $correctedBytes) -ceq
        $expectedCorrectedOuterStartSha256
) 'phase3b2_regroup_v3_length_repair_projection_digest_invalid'

if ($AuditOnly) {
    [pscustomobject]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-regroup-v3-dll-length-repair-audit/v1'
        auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        causeCode = 'derived_outer_start_retained_parent_dll_byte_length'
        expectedServerDllByteLengthBefore = 15377408L
        observedServerDllByteLength = 15377920L
        correctedOuterStartSha256 = $expectedCorrectedOuterStartSha256
        runtimeModified = $false
        databaseModified = $false
        cacheModified = $false
        goldenModified = $false
        deployable = $true
    } | ConvertTo-Json -Depth 6
    return
}

New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
$backupPath = Join-Path $protectedRoot `
    'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v3.before-length-correction.ps1'
Assert-True (-not (Test-Path -LiteralPath $backupPath)) `
    'phase3b2_regroup_v3_length_repair_backup_collision'
Copy-Item -LiteralPath $outerStartPath -Destination $backupPath

$temporaryToolPath = $outerStartPath + '.partial-' +
    [Guid]::NewGuid().ToString('N')
try {
    Write-Utf8NoBom $temporaryToolPath $correctedText
    Assert-PowerShellSyntax $temporaryToolPath
    Assert-True (Test-Digest $temporaryToolPath 8555L `
            $expectedCorrectedOuterStartSha256) `
        'phase3b2_regroup_v3_length_repair_staged_tool_invalid'
    Move-Item -LiteralPath $temporaryToolPath -Destination `
        $outerStartPath -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryToolPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryToolPath -Force
    }
}

$receipt = [ordered]@{
    schemaVersion = 1
    contractId =
        'nll/phase3b2-epinel-solo-raid-regroup-v3-dll-length-repair/v1'
    correctedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    correctionUid = [Guid]::NewGuid().ToString('D')
    deploymentUid = $deploymentUid
    deploymentReceiptSha256 = $expectedDeploymentReceiptSha256
    causeCode = 'derived_outer_start_retained_parent_dll_byte_length'
    preventedFailureCode =
        'phase3b2_solo_raid_trial_practice_start_content_drifted'
    expectedServerDllByteLengthBefore = 15377408L
    observedServerDllByteLength = 15377920L
    serverDllSha256 = $expectedServerDllSha256
    priorOuterStartByteLength = 8555L
    priorOuterStartSha256 = $expectedPriorOuterStartSha256
    correctedOuterStartByteLength = 8555L
    correctedOuterStartSha256 = $expectedCorrectedOuterStartSha256
    exactExpressionReplacementCount = 1
    priorOuterStartBackedUp = $true
    otherRuntimeToolMutationCount = 0
    runtimeModified = $false
    databaseModified = $false
    cacheModified = $false
    v2RuntimeModified = $false
    micronLobbyGoldenModified = $false
    dLobbyGoldenModified = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    validationRunConsumed = $false
    rollbackCode = 'restore_protected_prior_outer_start_only'
    nextStepCode = 'boot_micron_nlloperator_run_v3_regroup_validation_once'
}
Write-AtomicJson $repairReceiptPath $receipt
Copy-Item -LiteralPath $repairReceiptPath -Destination `
    (Join-Path $protectedRoot `
        'start-content-length-correction.receipt.json')

Assert-True (
    (Test-Digest $outerStartPath 8555L `
        $expectedCorrectedOuterStartSha256) -and
    (Test-Digest $backupPath 8555L $expectedPriorOuterStartSha256) -and
    (Test-Digest (Join-Path $runtimeRoot 'EpinelPS.dll') 15377920L `
        $expectedServerDllSha256) -and
    (Get-Sha256Hex $dBackupSealPath) -ceq $expectedDBackupSealSha256 -and
    @(Get-ChildItem -LiteralPath $evidenceRoot -Force).Count -eq 0
) 'phase3b2_regroup_v3_length_repair_postcondition_invalid'

[pscustomobject]@{
    Receipt = $receipt
    MicronReceiptPath = $repairReceiptPath
    MicronReceiptByteLength = (Get-Item -LiteralPath $repairReceiptPath).Length
    MicronReceiptSha256 = Get-Sha256Hex $repairReceiptPath
    ProtectedReceiptPath = Join-Path $protectedRoot `
        'start-content-length-correction.receipt.json'
    MicronStartCommand =
        "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1' -ValidationKind Challenge"
} | ConvertTo-Json -Depth 9
