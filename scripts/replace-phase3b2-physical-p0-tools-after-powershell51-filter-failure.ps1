[CmdletBinding()]
param(
    [string]$RepositoryRoot =
        'C:\Users\zih44\Documents\Github\Nikke-Local-Lab',
    [string]$MicronToolRoot = 'E:\NLL\Tools',
    [string]$MicronClientCloneRoot =
        'E:\NLL\Clients\NIKKE-150.6.9-Physical',
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
    'phase3b2_physical_p0_filter_revision_administrator_required'
$bootDisk = Get-DiskForDriveLetter 'C'
$targetDisk = Get-DiskForDriveLetter 'E'
Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $targetDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $targetDisk.IsBoot -and -not $targetDisk.IsSystem) `
    'phase3b2_physical_p0_filter_revision_samsung_boot_required'

$failedAssessmentUid = 'ca9cba84-06b4-413b-a346-df47b81e7dc6'
$attemptRoot = Join-Path $SamsungProtectedRoot $failedAssessmentUid
$pointerPath = Join-Path $SamsungProtectedRoot 'latest-attempt.pointer.json'
$failurePath = Join-Path $attemptRoot 'physical-p0.failure.receipt.json'
$workflowFailurePath = Join-Path $attemptRoot 'workflow.failure.receipt.json'
$revisionReceiptPath = Join-Path $attemptRoot `
    'physical-p0-powershell51-filter-revision.receipt.json'
$supersededRoot = Join-Path $attemptRoot `
    'superseded-tools-after-powershell51-filter-failure'
Assert-True ((Test-Path -LiteralPath $pointerPath -PathType Leaf) -and
    (Get-Item -LiteralPath $failurePath).Length -eq 646L -and
    (Get-Sha256Hex $failurePath) -ceq
        '20d9931ae1900983af01b4240546144b2628a170c16cf71760872f1920643db5' -and
    (Get-Item -LiteralPath $workflowFailurePath).Length -eq 516L -and
    (Get-Sha256Hex $workflowFailurePath) -ceq
        '638f9eba2aed638153fd8fcbd40272730bf51c6cab0ee12fb7e3bf94e85abd33' -and
    -not (Test-Path -LiteralPath $revisionReceiptPath)) `
    'phase3b2_physical_p0_filter_revision_failure_evidence_invalid'
$pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq 'nll/phase3b2-physical-p0-pointer/v1' -and
    $pointer.assessmentUid -ceq $failedAssessmentUid -and
    $pointer.statusCode -ceq 'failed' -and
    $pointer.receiptSha256 -ceq
        '20d9931ae1900983af01b4240546144b2628a170c16cf71760872f1920643db5' -and
    $failure.failedStageCode -ceq 'client_clone_and_source_verification' -and
    $failure.failureCode -ceq
        'phase3b2_physical_p0_program_inventory_count_mismatch' -and
    -not $failure.mutationStarted -and
    -not $failure.serverExecutionStarted -and
    -not $failure.clientExecutionStarted) `
    'phase3b2_physical_p0_filter_revision_failure_contract_invalid'

$legacyMatches = @(Get-ChildItem -LiteralPath $MicronClientCloneRoot -Recurse `
    -File -Filter *.exe -Force)
$exactMatches = @(Get-ChildItem -LiteralPath $MicronClientCloneRoot -Recurse `
    -File -Force | Where-Object Extension -IEQ '.exe')
$compatibilityOnlyMatches = @($legacyMatches | Where-Object Extension -INE '.exe')
Assert-True ($legacyMatches.Count -eq 16 -and $exactMatches.Count -eq 15 -and
    $compatibilityOnlyMatches.Count -eq 1 -and
    $compatibilityOnlyMatches[0].FullName.Substring(
        $MicronClientCloneRoot.Length + 1).Replace('\', '/') -ceq
        'NIKKE/game/wesight/crashsight_data/NIKKE.exe_crashsight_data_db' -and
    $compatibilityOnlyMatches[0].Length -eq 94208L -and
    (Get-Sha256Hex $compatibilityOnlyMatches[0].FullName) -ceq
        'c316505491f3bcb69b854e7fd5550246c9a801e37119bd354d79ed10fb89a98a') `
    'phase3b2_physical_p0_filter_revision_reproduction_invalid'

$members = @(
    [pscustomobject]@{
        RoleCode = 'physical_p0_apply'
        SourceName = 'prepare-phase3b2-physical-p0-in-micron.ps1'
        DestinationName = 'Prepare-Phase3B2-Physical-P0.ps1'
        OldLength = 32642L
        OldSha256 = 'cb5bfc9157ca3bc77379c81853913601c88ded9e8134be3b6d284bc0ad4d9d33'
        NewLength = 32665L
        NewSha256 = 'bd69c84df28dc6519c1bc717a95117c3943470d725fd5d2f5eb7776287b76c5e'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p0_workflow'
        SourceName = 'start-phase3b2-physical-p0-in-micron.ps1'
        DestinationName = 'Start-Phase3B2-Physical-P0.ps1'
        OldLength = 7285L
        OldSha256 = 'f69e0e978732cfaec3502b4377f3118ce24f3ec6b6dcf20fdd4341d4f549d41b'
        NewLength = 7285L
        NewSha256 = 'cc115886fd743c2b80547128ed692cd711ec359b6fed9253e5714d3ef81a35ce'
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
        'phase3b2_physical_p0_filter_revision_tool_pin_mismatch'
}
$unchangedPins = @(
    [pscustomobject]@{ Path = (Join-Path $MicronToolRoot 'Verify-Phase3B2-Physical-P0.ps1'); Length = 19059L; Sha256 = '5ecb3cc57f2b035444853acf135e834f89ba53e49529b5f934a298d7e563ee04' },
    [pscustomobject]@{ Path = (Join-Path $MicronToolRoot 'Rollback-Phase3B2-Physical-P0.ps1'); Length = 7822L; Sha256 = 'b75f68d1b948e9ffed21b02b86d3af71c8c76379bab51b98111ab1d5e451a81c' }
)
foreach ($pin in $unchangedPins) {
    Assert-True ((Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
        (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
        'phase3b2_physical_p0_filter_revision_unchanged_pin_mismatch'
}

$temporaryRoot = Join-Path $MicronToolRoot (
    '.phase3b2-physical-p0-filter-revision-' + [Guid]::NewGuid().ToString('N'))
$toolRootFull = [IO.Path]::GetFullPath($MicronToolRoot).TrimEnd('\')
$temporaryRootFull = [IO.Path]::GetFullPath($temporaryRoot)
Assert-True ($temporaryRootFull.StartsWith($toolRootFull + '\',
        [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $temporaryRootFull).StartsWith(
        '.phase3b2-physical-p0-filter-revision-',
        [StringComparison]::Ordinal)) `
    'phase3b2_physical_p0_filter_revision_temporary_path_invalid'

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
            'phase3b2_physical_p0_filter_revision_staging_failed'
    }
    foreach ($member in $members) {
        $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
        $stagedPath = Join-Path $temporaryRoot $member.DestinationName
        Copy-Item -LiteralPath $stagedPath -Destination $destinationPath -Force
        Assert-True ((Get-Item -LiteralPath $destinationPath).Length -eq
                $member.NewLength -and
            (Get-Sha256Hex $destinationPath) -ceq $member.NewSha256) `
            'phase3b2_physical_p0_filter_revision_replacement_failed'
    }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-powershell51-filter-revision/v1'
        revisedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $failedAssessmentUid
        failureReceiptSha256 =
            '20d9931ae1900983af01b4240546144b2628a170c16cf71760872f1920643db5'
        causeCode = 'windows_powershell_51_filter_star_dot_exe_legacy_match'
        compatibilityOnlyMatchRelativePath =
            'NIKKE/game/wesight/crashsight_data/NIKKE.exe_crashsight_data_db'
        legacyFilterMatchCount = 16
        exactExtensionMatchCount = 15
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
