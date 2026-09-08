[CmdletBinding()]
param(
    [string]$RepositoryRoot =
        'C:\Users\zih44\Documents\Github\Nikke-Local-Lab',
    [string]$MicronToolRoot = 'E:\NLL\Tools',
    [string]$MicronP1EvidenceRoot =
        'E:\NLL\Evidence\Phase3B2\Physical\p1-server-only-v1',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP1'
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

function Test-PathDigest {
    param([string]$Path, [long]$Length, [string]$Sha256)
    return ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $Length -and
        (Get-Sha256Hex $Path) -ceq $Sha256)
}

$failedAssessmentUid = 'a81c714d-d431-4794-a2ca-8f086093440e'
$attemptRoot = Join-Path $SamsungProtectedRoot $failedAssessmentUid
$pointerPath = Join-Path $SamsungProtectedRoot 'latest-attempt.pointer.json'
$pointerSnapshotPath = Join-Path $attemptRoot 'failure.pointer.snapshot.json'
$initialTransferReceiptPath = Join-Path $SamsungProtectedRoot `
    'physical-p1-tool-transfer.receipt.json'
$failureReceiptPath = Join-Path $attemptRoot 'measurement-failure.receipt.json'
$workflowFailurePath = Join-Path $attemptRoot 'workflow.failure.receipt.json'
$diagnosticRoot = Join-Path $attemptRoot 'diagnostics-from-failed-attempt'
$toolBackupRoot = Join-Path $attemptRoot 'tools-before-shared-json-revision'
$evidenceParent = Split-Path -Parent $MicronP1EvidenceRoot
$archivedEvidenceRoot = Join-Path $evidenceParent (
    'p1-server-only-failed-' + $failedAssessmentUid)
$revisionReceiptPath = Join-Path $SamsungProtectedRoot `
    'physical-p1-shared-json-revision.receipt.json'

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p1_revision_administrator_required'
$bootDisk = Get-DiskForDriveLetter 'C'
$targetDisk = Get-DiskForDriveLetter 'E'
Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $targetDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $targetDisk.IsBoot -and -not $targetDisk.IsSystem) `
    'phase3b2_physical_p1_revision_samsung_boot_required'

$normalizedEvidenceParent = [IO.Path]::GetFullPath($evidenceParent).TrimEnd('\')
$normalizedSourceEvidence = [IO.Path]::GetFullPath($MicronP1EvidenceRoot)
$normalizedArchivedEvidence = [IO.Path]::GetFullPath($archivedEvidenceRoot)
Assert-True ($normalizedSourceEvidence.StartsWith(
        $normalizedEvidenceParent + '\', [StringComparison]::OrdinalIgnoreCase) -and
    $normalizedArchivedEvidence.StartsWith(
        $normalizedEvidenceParent + '\', [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $normalizedSourceEvidence) -ceq 'p1-server-only-v1' -and
    (Split-Path -Leaf $normalizedArchivedEvidence) -ceq
        ('p1-server-only-failed-' + $failedAssessmentUid)) `
    'phase3b2_physical_p1_revision_archive_path_invalid'

$failurePins = @(
    [pscustomobject]@{ Path = $pointerPath; Length = 623L; Sha256 = 'fca52318ac30c589775d23d3f76a978058eb46c3336f3d6d023be0aace86eb1b' },
    [pscustomobject]@{ Path = $initialTransferReceiptPath; Length = 1960L; Sha256 = '05e6742d644a7e48d539030708ebacc94ee10ad6437f8e9c8f3059c0887e17e4' },
    [pscustomobject]@{ Path = $failureReceiptPath; Length = 860L; Sha256 = '7dbc8c6458549b3c5bbbdb9062a1378a201b547ddbefef6b6ad992940e01eedc' },
    [pscustomobject]@{ Path = $workflowFailurePath; Length = 516L; Sha256 = '005b538843bfd4386414ee75c03bbe863fa3ec65b23bdf9bf83791b4f1414e22' },
    [pscustomobject]@{ Path = (Join-Path $MicronP1EvidenceRoot 'db.before.bin'); Length = 413327L; Sha256 = 'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' },
    [pscustomobject]@{ Path = (Join-Path $MicronP1EvidenceRoot 'server.stdout.log'); Length = 335L; Sha256 = 'ddbe71615de0f75ba5330b7a6790bc2237138d1988b72148301d68a98e635535' },
    [pscustomobject]@{ Path = (Join-Path $MicronP1EvidenceRoot 'server.stderr.log'); Length = 0L; Sha256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' },
    [pscustomobject]@{ Path = (Join-Path $MicronP1EvidenceRoot 'measurement-failure.receipt.json'); Length = 860L; Sha256 = '7dbc8c6458549b3c5bbbdb9062a1378a201b547ddbefef6b6ad992940e01eedc' },
    [pscustomobject]@{ Path = 'E:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'; Length = 413327L; Sha256 = 'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' },
    [pscustomobject]@{ Path = 'E:\Windows\System32\drivers\etc\hosts'; Length = 1690L; Sha256 = 'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0' }
)
foreach ($pin in $failurePins) {
    Assert-True (Test-PathDigest $pin.Path $pin.Length $pin.Sha256) `
        'phase3b2_physical_p1_revision_failure_pin_mismatch'
}
$failure = Get-Content -LiteralPath $failureReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($failure.contractId -ceq
        'nll/phase3b2-physical-p1-server-only-failure/v1' -and
    $failure.assessmentUid -ceq $failedAssessmentUid -and
    $failure.failedStageCode -ceq 'selection_and_listener_observation' -and
    $failure.serverExecutionStarted -and $failure.serverStopped -and
    $failure.databaseBackupCreated -and $failure.databaseRestored -and
    $failure.sqliteRuntimeRemoved -and -not $failure.p0RollbackPerformed -and
    -not $failure.clientExecutionStarted) `
    'phase3b2_physical_p1_revision_failure_receipt_invalid'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object {
        Join-Path 'E:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64' $_
    }
Assert-True (@($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $archivedEvidenceRoot) -and
    -not (Test-Path -LiteralPath $pointerSnapshotPath) -and
    -not (Test-Path -LiteralPath $diagnosticRoot) -and
    -not (Test-Path -LiteralPath $toolBackupRoot) -and
    -not (Test-Path -LiteralPath $revisionReceiptPath)) `
    'phase3b2_physical_p1_revision_destination_not_cold'

$members = @(
    [pscustomobject]@{
        RoleCode = 'physical_p1_server_only_measurement'
        SourceName = 'measure-phase3b2-physical-p1-server-in-micron.ps1'
        DestinationName = 'Measure-Phase3B2-Physical-P1.ps1'
        OldLength = 44496L
        OldSha256 = 'e77ef0de066c1bb5c78641546aa3b95153e5a2488c493f3a1c89f045843ce6bd'
        NewLength = 46004L
        NewSha256 = '66c4d41867927cec5f69cab6c75b2b5c984661195a25a477b224f528e3623470'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p1_post_measurement_verification'
        SourceName = 'verify-phase3b2-physical-p1-in-micron.ps1'
        DestinationName = 'Verify-Phase3B2-Physical-P1.ps1'
        OldLength = 26046L
        OldSha256 = '38076797f0331d6d1212bee4d3dc8c052fb7ed0c8aac404c83d8887f88c84d1e'
        NewLength = 26046L
        NewSha256 = '38076797f0331d6d1212bee4d3dc8c052fb7ed0c8aac404c83d8887f88c84d1e'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p1_workflow'
        SourceName = 'start-phase3b2-physical-p1-in-micron.ps1'
        DestinationName = 'Start-Phase3B2-Physical-P1.ps1'
        OldLength = 7966L
        OldSha256 = '042a7add5c74b3890e540dab9731c08c1286972458249270618a21a0872d5981'
        NewLength = 7966L
        NewSha256 = '1227fdfd23b4482169281c9bcfa302d7456f591e4463d7cd14316b0c063ca687'
    }
)
$temporaryRoot = Join-Path $MicronToolRoot (
    '.phase3b2-physical-p1-revision-' + [Guid]::NewGuid().ToString('N'))
$normalizedToolRoot = [IO.Path]::GetFullPath($MicronToolRoot).TrimEnd('\')
$normalizedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
Assert-True ($normalizedTemporaryRoot.StartsWith(
        $normalizedToolRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $normalizedTemporaryRoot).StartsWith(
        '.phase3b2-physical-p1-revision-', [StringComparison]::Ordinal)) `
    'phase3b2_physical_p1_revision_temporary_path_invalid'

$evidenceArchived = $false
$toolsReplacementStarted = $false
try {
    foreach ($member in $members) {
        $sourcePath = Join-Path (Join-Path $RepositoryRoot 'scripts') `
            $member.SourceName
        $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
        Assert-True ((Test-PathDigest $sourcePath $member.NewLength `
                    $member.NewSha256) -and
            (Test-PathDigest $destinationPath $member.OldLength `
                $member.OldSha256)) `
            'phase3b2_physical_p1_revision_tool_pin_mismatch'
    }

    New-Item -ItemType Directory -Path $temporaryRoot, $diagnosticRoot,
        $toolBackupRoot | Out-Null
    foreach ($member in $members) {
        $sourcePath = Join-Path (Join-Path $RepositoryRoot 'scripts') `
            $member.SourceName
        $stagedPath = Join-Path $temporaryRoot $member.DestinationName
        $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
        $backupPath = Join-Path $toolBackupRoot $member.DestinationName
        Copy-Item -LiteralPath $sourcePath -Destination $stagedPath
        Copy-Item -LiteralPath $destinationPath -Destination $backupPath
        Assert-True ((Test-PathDigest $stagedPath $member.NewLength `
                    $member.NewSha256) -and
            (Test-PathDigest $backupPath $member.OldLength $member.OldSha256)) `
            'phase3b2_physical_p1_revision_staging_or_backup_failed'
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $stagedPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True (@($parseErrors).Count -eq 0) `
            'phase3b2_physical_p1_revision_script_parse_failed'
    }
    Copy-Item -LiteralPath $pointerPath -Destination $pointerSnapshotPath
    Assert-True (Test-PathDigest $pointerSnapshotPath 623L `
            'fca52318ac30c589775d23d3f76a978058eb46c3336f3d6d023be0aace86eb1b') `
        'phase3b2_physical_p1_revision_pointer_snapshot_failed'
    foreach ($name in @('db.before.bin', 'server.stdout.log',
            'server.stderr.log', 'measurement-failure.receipt.json')) {
        Copy-Item -LiteralPath (Join-Path $MicronP1EvidenceRoot $name) `
            -Destination (Join-Path $diagnosticRoot $name)
    }
    foreach ($pin in @($failurePins | Where-Object {
                $_.Path.StartsWith($MicronP1EvidenceRoot + '\',
                    [StringComparison]::OrdinalIgnoreCase)
            })) {
        $copyPath = Join-Path $diagnosticRoot (Split-Path -Leaf $pin.Path)
        Assert-True (Test-PathDigest $copyPath $pin.Length $pin.Sha256) `
            'phase3b2_physical_p1_revision_diagnostic_copy_failed'
    }

    Move-Item -LiteralPath $MicronP1EvidenceRoot `
        -Destination $archivedEvidenceRoot
    $evidenceArchived = $true
    Assert-True ((Test-Path -LiteralPath $archivedEvidenceRoot `
                -PathType Container) -and
        -not (Test-Path -LiteralPath $MicronP1EvidenceRoot)) `
        'phase3b2_physical_p1_revision_evidence_archive_failed'

    $toolsReplacementStarted = $true
    foreach ($member in $members) {
        Copy-Item -LiteralPath (Join-Path $temporaryRoot `
                $member.DestinationName) `
            -Destination (Join-Path $MicronToolRoot $member.DestinationName) `
            -Force
    }
    foreach ($member in $members) {
        Assert-True (Test-PathDigest (Join-Path $MicronToolRoot `
                    $member.DestinationName) $member.NewLength $member.NewSha256) `
            'phase3b2_physical_p1_revision_final_tool_verification_failed'
    }
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p1-shared-json-revision/v1'
        revisedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $failedAssessmentUid
        failureReceiptByteLength = 860
        failureReceiptSha256 =
            '7dbc8c6458549b3c5bbbdb9062a1378a201b547ddbefef6b6ad992940e01eedc'
        failurePointerSha256 =
            'fca52318ac30c589775d23d3f76a978058eb46c3336f3d6d023be0aace86eb1b'
        failurePointerSnapshotPreserved = $true
        failureDiagnosticMemberCount = 4
        failedLocalEvidenceArchived = $true
        archivedEvidencePathObserved = $archivedEvidenceRoot
        archivedEvidencePathAtMicronBoot =
            $archivedEvidenceRoot.Replace('E:\', 'C:\')
        failureClassificationCode =
            'startup_observation_exception_after_jsondb_load_no_server_stderr'
        probableCauseCode =
            'shared_json_observer_transient_read_not_tolerated'
        correctionCode =
            'shared_file_json_retry_and_safe_exception_classification'
        transferredMemberCount = $members.Count
        members = @($members | ForEach-Object {
                [ordered]@{
                    roleCode = $_.RoleCode
                    destinationName = $_.DestinationName
                    byteLength = $_.NewLength
                    sha256 = $_.NewSha256
                }
            })
        p0RollbackPerformed = $false
        micronSystemModified = $false
        physicalP0StateModified = $false
        physicalClientCloneModified = $false
        primaryInstallModified = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'boot_micron_and_retry_physical_p1_server_only_once'
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
    if ($toolsReplacementStarted) {
        foreach ($member in $members) {
            $backupPath = Join-Path $toolBackupRoot $member.DestinationName
            if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                Copy-Item -LiteralPath $backupPath `
                    -Destination (Join-Path $MicronToolRoot `
                        $member.DestinationName) -Force
            }
        }
    }
    if ($evidenceArchived -and
        (Test-Path -LiteralPath $archivedEvidenceRoot -PathType Container) -and
        -not (Test-Path -LiteralPath $MicronP1EvidenceRoot)) {
        Move-Item -LiteralPath $archivedEvidenceRoot `
            -Destination $MicronP1EvidenceRoot
    }
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
    throw
}
