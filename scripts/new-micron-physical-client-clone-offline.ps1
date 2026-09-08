[CmdletBinding()]
param(
    [string]$SourceRoot = 'E:\NIKKE',
    [string]$DestinationRoot = 'E:\NLL\Clients\NIKKE-150.6.9-Physical',
    [string]$ProtectedRoot = 'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\ClientClone'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256HexFromBytes {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $algorithm.Dispose()
    }
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp'
    [IO.File]::WriteAllText($temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Write-Status {
    param(
        [string]$StatusCode,
        [int]$ProgressPercent,
        [string]$StageCode,
        [int]$ProcessedFileCount = 0
    )

    $document = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/micron-physical-client-clone-status/v1'
        assessmentUid = $script:assessmentUid
        statusCode = $StatusCode
        progressPercent = $ProgressPercent
        stageCode = $StageCode
        processedFileCount = $ProcessedFileCount
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    Write-AtomicUtf8NoBom $script:statusPath (($document | ConvertTo-Json) + "`n")

    if (
        $script:lastConsoleStageCode -cne $StageCode -or
        $ProcessedFileCount -eq 0 -or
        ($ProcessedFileCount -gt 0 -and ($ProcessedFileCount % 2500) -eq 0)
    ) {
        Write-Host ("[{0,3}%] {1} (files: {2})" -f $ProgressPercent, $StageCode, $ProcessedFileCount)
        $script:lastConsoleStageCode = $StageCode
    }
}

function New-CanonicalFileManifest {
    param(
        [string]$Root,
        [string]$OutputPath,
        [string]$StageCode,
        [int]$ProgressStart,
        [int]$ProgressEnd
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($path in [IO.Directory]::EnumerateFiles(
        $rootFull,
        '*',
        [IO.SearchOption]::AllDirectories
    )) {
        $paths.Add($path)
    }
    $paths.Sort([StringComparer]::Ordinal)

    $builder = [Text.StringBuilder]::new()
    [long]$contentByteLength = 0
    $processed = 0
    foreach ($path in $paths) {
        $relativePath = $path.Substring($rootFull.Length + 1).Replace('\', '/')
        $item = [IO.FileInfo]::new($path)
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $null = $builder.Append($relativePath).
            Append("`t").Append($item.Length).
            Append("`t").Append($hash).Append("`n")
        $contentByteLength += $item.Length
        $processed++

        if (($processed % 250) -eq 0 -or $processed -eq $paths.Count) {
            $span = $ProgressEnd - $ProgressStart
            $percent = $ProgressStart
            if ($paths.Count -gt 0) {
                $percent += [int][Math]::Floor(($processed / [double]$paths.Count) * $span)
            }
            Write-Status 'running' $percent $StageCode $processed
        }
    }

    Write-AtomicUtf8NoBom $OutputPath $builder.ToString()
    $manifestBytes = [IO.File]::ReadAllBytes($OutputPath)
    return [ordered]@{
        fileCount = $paths.Count
        contentByteLength = $contentByteLength
        manifestByteLength = $manifestBytes.Length
        manifestSha256 = Get-Sha256HexFromBytes $manifestBytes
    }
}

function Get-DiskForDriveLetter {
    param([char]$DriveLetter)
    $partition = Get-Partition -DriveLetter $DriveLetter
    return $partition | Get-Disk
}

$expectedSourceManifest = [ordered]@{
    fileCount = 38670
    contentByteLength = 26745978753
    manifestByteLength = 5397209
    manifestSha256 = '0e9aaf9c69399e81bc3887660f360bd97ae78d0f6a41a5f339fb629e6fa574b4'
}
$expectedRootNames = @('.tiny_cache', 'Launcher', 'NIKKE', 'sail_files', 'Unity')
$physicalVerificationPath = 'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\BCD\physical-test-current-loader-verification-v3.receipt.json'
$expectedPhysicalVerificationSha256 = '07a45ab10cddc37caf97e84ee29137f19b26fb18a064fea2093a9f860cdbf9ba'

$source = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\')
$destination = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
$protected = [IO.Path]::GetFullPath($ProtectedRoot).TrimEnd('\')
Assert-True ($source -ceq 'E:\NIKKE') 'micron_physical_clone_source_path_invalid'
Assert-True ($destination -ceq 'E:\NLL\Clients\NIKKE-150.6.9-Physical') 'micron_physical_clone_destination_path_invalid'
Assert-True ($protected -ceq 'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\ClientClone') 'micron_physical_clone_protected_root_invalid'

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
Assert-True (
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
) 'micron_physical_clone_administrator_required'

$bootDisk = Get-DiskForDriveLetter 'C'
$targetDisk = Get-DiskForDriveLetter 'E'
Assert-True (
    $bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem
) 'micron_physical_clone_samsung_boot_context_required'
Assert-True (
    $targetDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $targetDisk.IsBoot -and -not $targetDisk.IsSystem
) 'micron_physical_clone_offline_micron_target_required'

Assert-True (Test-Path -LiteralPath $source -PathType Container) 'micron_physical_clone_source_missing'
Assert-True (-not (Test-Path -LiteralPath $destination)) 'micron_physical_clone_destination_already_exists'
Assert-True (Test-Path -LiteralPath $physicalVerificationPath -PathType Leaf) 'micron_physical_clone_physical_verification_missing'
$physicalVerificationSha256 = (
    Get-FileHash -LiteralPath $physicalVerificationPath -Algorithm SHA256
).Hash.ToLowerInvariant()
Assert-True (
    $physicalVerificationSha256 -ceq $expectedPhysicalVerificationSha256
) 'micron_physical_clone_physical_verification_hash_mismatch'
$physicalVerification = Get-Content -LiteralPath $physicalVerificationPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $physicalVerification.contractId -ceq 'nll/micron-current-loader-physical-test-verification/v3' -and
    $physicalVerification.readyForPhysicalP0Preparation
) 'micron_physical_clone_physical_verification_invalid'

$runtimeProcesses = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -in @('EpinelPS', 'nikke_launcher', 'nikke') }
)
Assert-True ($runtimeProcesses.Count -eq 0) 'micron_physical_clone_runtime_process_present'

$observedRootNames = @(
    Get-ChildItem -LiteralPath $source -Force |
        Where-Object { $_.PSIsContainer } |
        Sort-Object Name |
        ForEach-Object { $_.Name }
)
Assert-True ($observedRootNames.Count -eq $expectedRootNames.Count) 'micron_physical_clone_root_count_mismatch'
for ($index = 0; $index -lt $expectedRootNames.Count; $index++) {
    Assert-True (
        $observedRootNames[$index] -ceq $expectedRootNames[$index]
    ) 'micron_physical_clone_root_name_mismatch'
}

$reparsePoints = @(
    Get-ChildItem -LiteralPath $source -Recurse -Force -ErrorAction Stop |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }
)
Assert-True ($reparsePoints.Count -eq 0) 'micron_physical_clone_source_reparse_point_present'

$clientExecutablePath = Join-Path $source 'NIKKE\game\nikke.exe'
Assert-True (Test-Path -LiteralPath $clientExecutablePath -PathType Leaf) 'micron_physical_clone_client_executable_missing'
$clientExecutable = Get-Item -LiteralPath $clientExecutablePath
Assert-True (
    $clientExecutable.Length -eq 794152 -and
    $clientExecutable.VersionInfo.FileVersion -ceq '150.6.9' -and
    $clientExecutable.VersionInfo.ProductVersion -ceq '150.6.9'
) 'micron_physical_clone_client_build_mismatch'

$targetVolume = Get-Volume -DriveLetter E
Assert-True (
    $targetVolume.SizeRemaining -ge ($expectedSourceManifest.contentByteLength + 15GB)
) 'micron_physical_clone_insufficient_target_space'

$protectedParent = Split-Path -Parent $protected
Assert-True (Test-Path -LiteralPath $protectedParent -PathType Container) 'micron_physical_clone_protected_parent_missing'
if (-not (Test-Path -LiteralPath $protected)) {
    New-Item -ItemType Directory -Path $protected -Force | Out-Null
}
$stableReceiptPath = Join-Path $protected 'physical-client-clone.receipt.json'
Assert-True (-not (Test-Path -LiteralPath $stableReceiptPath)) 'micron_physical_clone_stable_receipt_already_exists'

$script:assessmentUid = [guid]::NewGuid().ToString('D')
$script:lastConsoleStageCode = ''
$assessmentRoot = Join-Path $protected $script:assessmentUid
Assert-True (-not (Test-Path -LiteralPath $assessmentRoot)) 'micron_physical_clone_assessment_root_already_exists'
New-Item -ItemType Directory -Path $assessmentRoot -Force | Out-Null
$script:statusPath = Join-Path $assessmentRoot 'status.json'

$sourceItemBefore = Get-Item -LiteralPath $source -Force
$stageCode = 'source_manifest_generation'
try {
    Write-Status 'running' 1 $stageCode
    $sourceManifestPath = Join-Path $assessmentRoot 'source-before.manifest.tsv'
    $sourceManifest = New-CanonicalFileManifest `
        -Root $source `
        -OutputPath $sourceManifestPath `
        -StageCode $stageCode `
        -ProgressStart 1 `
        -ProgressEnd 35

    Assert-True (
        $sourceManifest.fileCount -eq $expectedSourceManifest.fileCount -and
        $sourceManifest.contentByteLength -eq $expectedSourceManifest.contentByteLength -and
        $sourceManifest.manifestByteLength -eq $expectedSourceManifest.manifestByteLength -and
        $sourceManifest.manifestSha256 -ceq $expectedSourceManifest.manifestSha256
    ) 'micron_physical_clone_source_manifest_pin_mismatch'

    $stageCode = 'offline_client_copy'
    Write-Status 'running' 40 $stageCode
    $destinationParent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $destinationParent)) {
        New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    }
    $robocopyLogPath = Join-Path $assessmentRoot 'robocopy.log'
    & robocopy.exe $source $destination `
        /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /MT:16 `
        /NFL /NDL /NJH /NJS /NP "/LOG:$robocopyLogPath" | Out-Null
    $robocopyExitCode = $LASTEXITCODE
    Assert-True (
        $robocopyExitCode -ge 0 -and $robocopyExitCode -le 7
    ) 'micron_physical_clone_robocopy_failed'

    $stageCode = 'destination_manifest_generation'
    Write-Status 'running' 55 $stageCode
    $destinationManifestPath = Join-Path $assessmentRoot 'destination-after.manifest.tsv'
    $destinationManifest = New-CanonicalFileManifest `
        -Root $destination `
        -OutputPath $destinationManifestPath `
        -StageCode $stageCode `
        -ProgressStart 55 `
        -ProgressEnd 95

    Assert-True (
        $destinationManifest.fileCount -eq $sourceManifest.fileCount -and
        $destinationManifest.contentByteLength -eq $sourceManifest.contentByteLength -and
        $destinationManifest.manifestByteLength -eq $sourceManifest.manifestByteLength -and
        $destinationManifest.manifestSha256 -ceq $sourceManifest.manifestSha256
    ) 'micron_physical_clone_destination_manifest_mismatch'

    $sourceItemAfter = Get-Item -LiteralPath $source -Force
    $sourceRootMetadataPreserved = (
        $sourceItemAfter.CreationTimeUtc -eq $sourceItemBefore.CreationTimeUtc -and
        $sourceItemAfter.LastWriteTimeUtc -eq $sourceItemBefore.LastWriteTimeUtc -and
        $sourceItemAfter.Attributes -eq $sourceItemBefore.Attributes
    )
    Assert-True $sourceRootMetadataPreserved 'micron_physical_clone_source_root_metadata_changed'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/micron-physical-client-clone-offline/v1'
        preparedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $script:assessmentUid
        preparationBootDisk = 'Samsung SSD 980 1TB'
        targetDisk = 'Micron_2200_MTFDHBA512TCK'
        targetOsOfflineDuringCopy = $true
        sourcePathObserved = $source
        sourcePathAtTargetBoot = 'C:\NIKKE'
        destinationPathObserved = $destination
        destinationPathAtTargetBoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical'
        clientBuild = '150.6.9'
        rootCount = $observedRootNames.Count
        rootNames = $observedRootNames
        sourceFileCount = $sourceManifest.fileCount
        sourceContentByteLength = $sourceManifest.contentByteLength
        sourceManifestByteLength = $sourceManifest.manifestByteLength
        sourceManifestSha256 = $sourceManifest.manifestSha256
        destinationFileCount = $destinationManifest.fileCount
        destinationContentByteLength = $destinationManifest.contentByteLength
        destinationManifestByteLength = $destinationManifest.manifestByteLength
        destinationManifestSha256 = $destinationManifest.manifestSha256
        sourceManifestPinned = $true
        destinationManifestMatched = $true
        sourceRootMetadataPreserved = $sourceRootMetadataPreserved
        sourceDeletionPerformed = $false
        robocopyExitCode = $robocopyExitCode
        physicalVerificationReceiptSha256 = $physicalVerificationSha256
        runtimeProcessCount = $runtimeProcesses.Count
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'verify_clone_from_micron_physical_boot'
    }
    $receiptText = ($receipt | ConvertTo-Json -Depth 8) + "`n"
    $assessmentReceiptPath = Join-Path $assessmentRoot 'physical-client-clone.receipt.json'
    Write-AtomicUtf8NoBom $assessmentReceiptPath $receiptText
    Write-AtomicUtf8NoBom $stableReceiptPath $receiptText
    Write-Status 'complete' 100 'offline_clone_sealed'

    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $stableReceiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $stableReceiptPath).Length
        ReceiptSha256 = (Get-FileHash -LiteralPath $stableReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        AssessmentEvidenceRoot = $assessmentRoot
    } | ConvertTo-Json -Depth 10
}
catch {
    $failure = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/micron-physical-client-clone-offline-failure/v1'
        failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $script:assessmentUid
        failedStageCode = $stageCode
        exceptionType = $_.Exception.GetType().FullName
        failureMessage = $_.Exception.Message
        sourcePath = $source
        destinationPath = $destination
        partialDestinationPresent = Test-Path -LiteralPath $destination
        sourceDeletionPerformed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'inspect_failure_without_reusing_partial_destination'
    }
    $failurePath = Join-Path $assessmentRoot 'failure.receipt.json'
    Write-AtomicUtf8NoBom $failurePath (($failure | ConvertTo-Json -Depth 6) + "`n")
    Write-Status 'blocked' 0 $stageCode
    throw "micron_physical_client_clone_failed:${stageCode}:$($_.Exception.Message)"
}
