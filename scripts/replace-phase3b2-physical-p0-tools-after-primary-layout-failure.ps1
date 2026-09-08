[CmdletBinding()]
param(
    [string]$RepositoryRoot =
        'C:\Users\zih44\Documents\Github\Nikke-Local-Lab',
    [string]$MicronToolRoot = 'E:\NLL\Tools',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP0'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, $Text,
            [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-DiskForDriveLetter {
    param([char]$DriveLetter)
    return (Get-Partition -DriveLetter $DriveLetter | Get-Disk)
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p0_revision_administrator_required'
$bootDisk = Get-DiskForDriveLetter 'C'
$targetDisk = Get-DiskForDriveLetter 'E'
Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $targetDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $targetDisk.IsBoot -and -not $targetDisk.IsSystem) `
    'phase3b2_physical_p0_revision_samsung_boot_required'

$failedAssessmentUid = '6f5e3f50-01c1-4303-a28a-8472ef7e7a35'
$attemptRoot = Join-Path $SamsungProtectedRoot $failedAssessmentUid
$pointerPath = Join-Path $SamsungProtectedRoot 'latest-attempt.pointer.json'
$failurePath = Join-Path $attemptRoot 'physical-p0.failure.receipt.json'
$workflowFailurePath = Join-Path $attemptRoot 'workflow.failure.receipt.json'
$revisionReceiptPath = Join-Path $attemptRoot `
    'physical-p0-tool-revision.receipt.json'
$supersededRoot = Join-Path $attemptRoot `
    'superseded-tools-after-primary-layout-failure'
Assert-True ((Test-Path -LiteralPath $MicronToolRoot -PathType Container) -and
    (Test-Path -LiteralPath $pointerPath -PathType Leaf) -and
    (Get-Item -LiteralPath $failurePath).Length -eq 633L -and
    (Get-Sha256Hex $failurePath) -ceq
        'bfe06a670bdd90d84a05b827689a9872a7c3c608c94c807929e88593dd52af3d' -and
    (Get-Item -LiteralPath $workflowFailurePath).Length -eq 516L -and
    (Get-Sha256Hex $workflowFailurePath) -ceq
        '63bdfb60ea9283ba9c1b5a340e05feb24bc53b5e421479fbfaf296bde1836e9f' -and
    -not (Test-Path -LiteralPath $revisionReceiptPath)) `
    'phase3b2_physical_p0_revision_failure_evidence_invalid'
$pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq 'nll/phase3b2-physical-p0-pointer/v1' -and
    $pointer.assessmentUid -ceq $failedAssessmentUid -and
    $pointer.statusCode -ceq 'failed' -and
    $pointer.receiptSha256 -ceq
        'bfe06a670bdd90d84a05b827689a9872a7c3c608c94c807929e88593dd52af3d' -and
    $failure.failedStageCode -ceq 'client_clone_and_source_verification' -and
    $failure.failureCode -ceq 'phase3b2_physical_p0_client_pin_mismatch' -and
    -not $failure.mutationStarted -and
    -not $failure.automaticRollbackCompleted -and
    -not $failure.serverExecutionStarted -and
    -not $failure.clientExecutionStarted) `
    'phase3b2_physical_p0_revision_failure_contract_invalid'

$primaryPins = @(
    [pscustomobject]@{ Path = 'E:\NIKKE\NIKKE\game\nikke.exe'; Length = 794152L; Sha256 = '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30' },
    [pscustomobject]@{ Path = 'E:\NIKKE\NIKKE\game\nikke_Data\Plugins\x86_64\intl_cacert.pem'; Length = 212549L; Sha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d' },
    [pscustomobject]@{ Path = 'E:\NIKKE\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll'; Length = 304128L; Sha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888' }
)
foreach ($pin in $primaryPins) {
    Assert-True ((Test-Path -LiteralPath $pin.Path -PathType Leaf) -and
        (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
        (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
        'phase3b2_physical_p0_revision_primary_pin_mismatch'
}

$members = @(
    [pscustomobject]@{
        RoleCode = 'physical_p0_apply'
        SourceName = 'prepare-phase3b2-physical-p0-in-micron.ps1'
        DestinationName = 'Prepare-Phase3B2-Physical-P0.ps1'
        OldLength = 32636L
        OldSha256 = '956d513eed03f6b604cda47a866877e00909d9b61d0c27e743b94f2a0c19a962'
        NewLength = 32642L
        NewSha256 = 'cb5bfc9157ca3bc77379c81853913601c88ded9e8134be3b6d284bc0ad4d9d33'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p0_post_apply_verification'
        SourceName = 'verify-phase3b2-physical-p0-in-micron.ps1'
        DestinationName = 'Verify-Phase3B2-Physical-P0.ps1'
        OldLength = 19041L
        OldSha256 = 'e0474f2cfabb9555f88458e63e260b23f9c3436db0f539e2c0a3d8fb5ef6c8b8'
        NewLength = 19059L
        NewSha256 = '5ecb3cc57f2b035444853acf135e834f89ba53e49529b5f934a298d7e563ee04'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p0_workflow'
        SourceName = 'start-phase3b2-physical-p0-in-micron.ps1'
        DestinationName = 'Start-Phase3B2-Physical-P0.ps1'
        OldLength = 7285L
        OldSha256 = '7b8454a830b1c40571d59d409081e55fcaf41cdf3c26557039e44555ecd26f2f'
        NewLength = 7285L
        NewSha256 = 'f69e0e978732cfaec3502b4377f3118ce24f3ec6b6dcf20fdd4341d4f549d41b'
    }
)
foreach ($member in $members) {
    $sourcePath = Join-Path (Join-Path $RepositoryRoot 'scripts') `
        $member.SourceName
    $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
    Assert-True ((Get-Item -LiteralPath $sourcePath).Length -eq
            $member.NewLength -and
        (Get-Sha256Hex $sourcePath) -ceq $member.NewSha256 -and
        (Get-Item -LiteralPath $destinationPath).Length -eq
            $member.OldLength -and
        (Get-Sha256Hex $destinationPath) -ceq $member.OldSha256) `
        'phase3b2_physical_p0_revision_tool_pin_mismatch'
}
$rollbackPath = Join-Path $MicronToolRoot 'Rollback-Phase3B2-Physical-P0.ps1'
Assert-True ((Get-Item -LiteralPath $rollbackPath).Length -eq 7822L -and
    (Get-Sha256Hex $rollbackPath) -ceq
        'b75f68d1b948e9ffed21b02b86d3af71c8c76379bab51b98111ab1d5e451a81c') `
    'phase3b2_physical_p0_revision_rollback_pin_mismatch'

$temporaryRoot = Join-Path $MicronToolRoot (
    '.phase3b2-physical-p0-revision-' + [Guid]::NewGuid().ToString('N'))
$toolRootFull = [IO.Path]::GetFullPath($MicronToolRoot).TrimEnd('\')
$temporaryRootFull = [IO.Path]::GetFullPath($temporaryRoot)
Assert-True ($temporaryRootFull.StartsWith($toolRootFull + '\',
        [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $temporaryRootFull).StartsWith(
        '.phase3b2-physical-p0-revision-', [StringComparison]::Ordinal)) `
    'phase3b2_physical_p0_revision_temporary_path_invalid'

try {
    if (-not (Test-Path -LiteralPath $supersededRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $supersededRoot | Out-Null
    }
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    foreach ($member in $members) {
        $sourcePath = Join-Path (Join-Path $RepositoryRoot 'scripts') `
            $member.SourceName
        $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
        $backupPath = Join-Path $supersededRoot $member.DestinationName
        $stagedPath = Join-Path $temporaryRoot $member.DestinationName
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $destinationPath -Destination $backupPath
        }
        Copy-Item -LiteralPath $sourcePath -Destination $stagedPath
        Assert-True ((Get-Item -LiteralPath $backupPath).Length -eq
                $member.OldLength -and
            (Get-Sha256Hex $backupPath) -ceq $member.OldSha256 -and
            (Get-Item -LiteralPath $stagedPath).Length -eq
                $member.NewLength -and
            (Get-Sha256Hex $stagedPath) -ceq $member.NewSha256) `
            'phase3b2_physical_p0_revision_staging_failed'
    }
    foreach ($member in $members) {
        $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
        $stagedPath = Join-Path $temporaryRoot $member.DestinationName
        Copy-Item -LiteralPath $stagedPath -Destination $destinationPath -Force
        Assert-True ((Get-Item -LiteralPath $destinationPath).Length -eq
                $member.NewLength -and
            (Get-Sha256Hex $destinationPath) -ceq $member.NewSha256) `
            'phase3b2_physical_p0_revision_replacement_failed'
    }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-tool-revision/v1'
        revisedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $failedAssessmentUid
        failureReceiptSha256 =
            'bfe06a670bdd90d84a05b827689a9872a7c3c608c94c807929e88593dd52af3d'
        causeCode = 'primary_install_nested_nikke_directory_omitted_from_pin_path'
        correctedPrimaryInstallGameRootAtMicronBoot = 'C:\NIKKE\NIKKE\game'
        correctedPrimaryInstallGameRootObserved = 'E:\NIKKE\NIKKE\game'
        primaryInstallPinsVerified = $true
        revisedMemberCount = $members.Count
        members = @($members | ForEach-Object {
                [ordered]@{
                    roleCode = $_.RoleCode
                    destinationName = $_.DestinationName
                    previousByteLength = $_.OldLength
                    previousSha256 = $_.OldSha256
                    revisedByteLength = $_.NewLength
                    revisedSha256 = $_.NewSha256
                }
            })
        rollbackToolUnchanged = $true
        failedAttemptEvidencePreserved = $true
        micronSystemModified = $false
        physicalClientCloneModified = $false
        primaryInstallModified = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'boot_micron_and_rerun_physical_p0_workflow_once'
    }
    Write-AtomicUtf8NoBom $revisionReceiptPath `
        (($receipt | ConvertTo-Json -Depth 8) + "`n")
    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $revisionReceiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $revisionReceiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $revisionReceiptPath
    } | ConvertTo-Json -Depth 10
}
catch {
    foreach ($member in $members) {
        $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
        $backupPath = Join-Path $supersededRoot $member.DestinationName
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Copy-Item -LiteralPath $backupPath -Destination $destinationPath -Force
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
    throw
}
