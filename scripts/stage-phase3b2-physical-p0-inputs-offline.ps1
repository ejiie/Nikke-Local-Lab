[CmdletBinding()]
param(
    [string]$StagingRoot = 'E:\NLL\Staging\PhysicalP0-v1',
    [string]$ProtectedRoot = 'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\P0Staging'
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
    $temporaryPath = $Path + '.tmp'
    [IO.File]::WriteAllText($temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-DiskForDriveLetter {
    param([char]$DriveLetter)
    return (Get-Partition -DriveLetter $DriveLetter | Get-Disk)
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$backupRoot = 'C:\Recovered_OldSSD\NLL_PreWipe_20260822'
$clientCloneRoot = Join-Path $backupRoot 'PhysicalOS\Micron-PrePhysicalLane-20260823\ClientClone'
$cloneBootReceiptPath = Join-Path $clientCloneRoot 'physical-client-clone-boot-verification.receipt.json'
$expectedCloneBootReceiptSha256 = '6dc5a79941b8eeabefcbc0a7c4f6b2bfbd59e7081a8147abad041bc50fae37b4'
$rawProfilePath = Join-Path $backupRoot 'PrivateRuntime\NikkeLocalLabImports\credential-bearing\phase3b2-26f65275-2f62-49d4-ba3f-7f50558b1575\credential-bearing-source.json'
$expectedRawProfileByteLength = 964036L
$expectedRawProfileSha256 = 'efb1b38b4557e45cbefc1922649c22f6725071cb8c5cb2ad269650d7807fe605'

$staging = [IO.Path]::GetFullPath($StagingRoot).TrimEnd('\')
$protected = [IO.Path]::GetFullPath($ProtectedRoot).TrimEnd('\')
Assert-True ($staging -ceq 'E:\NLL\Staging\PhysicalP0-v1') 'phase3b2_physical_p0_staging_path_invalid'
Assert-True ($protected -ceq 'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\P0Staging') 'phase3b2_physical_p0_protected_path_invalid'
Assert-True (-not (Test-Path -LiteralPath $staging)) 'phase3b2_physical_p0_staging_already_exists'
Assert-True (-not (Test-Path -LiteralPath $protected)) 'phase3b2_physical_p0_protected_root_already_exists'

$bootDisk = Get-DiskForDriveLetter 'C'
$targetDisk = Get-DiskForDriveLetter 'E'
Assert-True (
    $bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem
) 'phase3b2_physical_p0_samsung_boot_context_required'
Assert-True (
    $targetDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $targetDisk.IsBoot -and -not $targetDisk.IsSystem
) 'phase3b2_physical_p0_offline_micron_target_required'

Assert-True (Test-Path -LiteralPath $cloneBootReceiptPath -PathType Leaf) 'phase3b2_physical_p0_clone_boot_receipt_missing'
$cloneBootReceiptSha256 = Get-Sha256Hex $cloneBootReceiptPath
Assert-True ($cloneBootReceiptSha256 -ceq $expectedCloneBootReceiptSha256) 'phase3b2_physical_p0_clone_boot_receipt_hash_mismatch'
$cloneBootReceipt = Get-Content -LiteralPath $cloneBootReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $cloneBootReceipt.contractId -ceq 'nll/micron-physical-client-clone-boot-verification/v1' -and
    $cloneBootReceipt.readyForPhysicalP0Staging -and
    -not $cloneBootReceipt.clientExecutionStarted
) 'phase3b2_physical_p0_clone_boot_receipt_invalid'

Assert-True (Test-Path -LiteralPath $rawProfilePath -PathType Leaf) 'phase3b2_physical_p0_protected_profile_source_missing'
Assert-True (
    (Get-Item -LiteralPath $rawProfilePath).Length -eq $expectedRawProfileByteLength -and
    (Get-Sha256Hex $rawProfilePath) -ceq $expectedRawProfileSha256
) 'phase3b2_physical_p0_protected_profile_source_pin_mismatch'

$hostArtifacts = Join-Path $backupRoot 'HostArtifacts'
$bootstrapRoot = Join-Path $backupRoot 'PrivateRuntime\NikkeLocalLab\compatibility\external\phase3b2-local-bootstrap-v1'
$bundlePath = Join-Path $hostArtifacts 'Staging\EpinelPS-519c3db51ec24ca19307e93e85acde7885928a72.bundle'
$staticDataPath = Join-Path $hostArtifacts 'Inputs\staticdata\553116\StaticData.pack'
$bootstrapReceiptPath = Join-Path $bootstrapRoot 'local-bootstrap-build.receipt.json'
$bootstrapManifestPath = Join-Path $bootstrapRoot 'evidence\artifact.manifest.tsv'

$pinnedSources = @(
    [pscustomobject]@{ Path = $bundlePath; Length = 23410136L; Sha256 = 'b56305e10adc57b94832bd6e80e112906c7ed9143f4507c548c298fa1860bb71' },
    [pscustomobject]@{ Path = $staticDataPath; Length = 17177168L; Sha256 = '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3' },
    [pscustomobject]@{ Path = $bootstrapReceiptPath; Length = 1200L; Sha256 = '5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11' },
    [pscustomobject]@{ Path = $bootstrapManifestPath; Length = 561L; Sha256 = 'b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70' }
)
foreach ($pin in $pinnedSources) {
    Assert-True (Test-Path -LiteralPath $pin.Path -PathType Leaf) 'phase3b2_physical_p0_pinned_source_missing'
    Assert-True (
        (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
        (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256
    ) 'phase3b2_physical_p0_pinned_source_mismatch'
}

$bootstrapReceipt = Get-Content -LiteralPath $bootstrapReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $bootstrapReceipt.contractId -ceq 'nll/phase3b2-source-built-local-bootstrap/v1' -and
    $bootstrapReceipt.upstreamHead -ceq '3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3' -and
    $bootstrapReceipt.upstreamTree -ceq '54b85eb6fbaa74feae0c6b441d66a5a703073ba3' -and
    $bootstrapReceipt.artifactMemberCount -eq 5 -and
    $bootstrapReceipt.artifactManifestSha256 -ceq 'b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70' -and
    -not $bootstrapReceipt.officialLauncherBuilt -and
    -not $bootstrapReceipt.antiCheatSubstitutionBuilt -and
    -not $bootstrapReceipt.rawCredentialIncluded -and
    -not $bootstrapReceipt.clientExecutionStarted
) 'phase3b2_physical_p0_bootstrap_receipt_invalid'

$members = [Collections.Generic.List[object]]::new()
function Add-Member {
    param([string]$RoleCode, [string]$Source, [string]$RelativeDestination)
    $members.Add([pscustomobject]@{
        RoleCode = $RoleCode
        Source = $Source
        RelativeDestination = $RelativeDestination
    })
}

Add-Member 'epinelps_v4_bundle' $bundlePath 'EpinelPS\EpinelPS-519c3db51ec24ca19307e93e85acde7885928a72.bundle'
Add-Member 'static_data_pack' $staticDataPath 'Inputs\staticdata\553116\StaticData.pack'

$localeRoot = 'E:\NIKKE\Unity\com_proximabeta_NIKKE\saus\saus\lss'
$localePins = @(
    [pscustomobject]@{ Name = 'Locale_Bgm.lsc'; Length = 25498L; Sha256 = '069143db0a70be3947d8bb68ff19a4815efbd3a35fc00401bd0bf93d460fd925' },
    [pscustomobject]@{ Name = 'Locale_Character.lsc'; Length = 5023222L; Sha256 = 'd50727f15317fb09ab7c4bab2eed8f4083efc4cbd9880269d95f2e2b21bc7013' },
    [pscustomobject]@{ Name = 'Locale_CharacterCostume.lsc'; Length = 67547L; Sha256 = '3284a10c92890491e6b138a9c54c9e47d6816413f7e44493d10410b0a90cffa0' },
    [pscustomobject]@{ Name = 'Locale_Item.lsc'; Length = 1193697L; Sha256 = 'e149ac84c9ddf9b428183d4f4ff4d99edc3f665d1ee38b3adccd0e0fa50330ff' }
)
foreach ($locale in $localePins) {
    $path = Join-Path $localeRoot $locale.Name
    Assert-True (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Item -LiteralPath $path).Length -eq $locale.Length -and
        (Get-Sha256Hex $path) -ceq $locale.Sha256
    ) 'phase3b2_physical_p0_locale_pin_mismatch'
    Add-Member 'locale_input' $path (Join-Path 'Inputs\locale' $locale.Name)
}

Add-Member 'local_bootstrap_build_receipt' $bootstrapReceiptPath 'LocalBootstrap-v1\local-bootstrap-build.receipt.json'
Add-Member 'local_bootstrap_artifact_manifest' $bootstrapManifestPath 'LocalBootstrap-v1\evidence\artifact.manifest.tsv'
$bootstrapArtifactNames = @(
    'NikkeLocalLab.Phase3B2.LocalBootstrap.deps.json',
    'NikkeLocalLab.Phase3B2.LocalBootstrap.dll',
    'NikkeLocalLab.Phase3B2.LocalBootstrap.exe',
    'NikkeLocalLab.Phase3B2.LocalBootstrap.runtimeconfig.json',
    'sail_api_impl64.dll'
)
foreach ($name in $bootstrapArtifactNames) {
    Add-Member 'local_bootstrap_artifact' `
        (Join-Path $bootstrapRoot "artifact\$name") `
        (Join-Path 'LocalBootstrap-v1\artifact' $name)
}

$adapterSourceRoot = Join-Path $repositoryRoot 'tools\NikkeLocalLab.Phase3B2.ProfileAdapter'
$adapterSourceNames = @(
    'global.json',
    'NikkeLocalLab.Phase3B2.ProfileAdapter.csproj',
    'NuGet.config',
    'packages.lock.json',
    'Program.cs'
)
foreach ($name in $adapterSourceNames) {
    Add-Member 'profile_adapter_source' `
        (Join-Path $adapterSourceRoot $name) `
        (Join-Path 'ProfileAdapter' $name)
}

Assert-True ($members.Count -eq 18) 'phase3b2_physical_p0_member_count_invalid'
foreach ($member in $members) {
    Assert-True (Test-Path -LiteralPath $member.Source -PathType Leaf) 'phase3b2_physical_p0_member_source_missing'
}

New-Item -ItemType Directory -Path $staging, $protected -Force | Out-Null
$copied = [Collections.Generic.List[object]]::new()
try {
    foreach ($member in $members) {
        $destination = Join-Path $staging $member.RelativeDestination
        $destinationParent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destinationParent)) {
            New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
        }
        Copy-Item -LiteralPath $member.Source -Destination $destination
        $sourceLength = (Get-Item -LiteralPath $member.Source).Length
        $sourceSha256 = Get-Sha256Hex $member.Source
        Assert-True (
            (Get-Item -LiteralPath $destination).Length -eq $sourceLength -and
            (Get-Sha256Hex $destination) -ceq $sourceSha256
        ) 'phase3b2_physical_p0_member_transfer_mismatch'
        $copied.Add([pscustomobject]@{
            RoleCode = $member.RoleCode
            RelativePath = $member.RelativeDestination.Replace('\', '/')
            ByteLength = $sourceLength
            Sha256 = $sourceSha256
        })
    }

    Assert-True (-not (Test-Path -LiteralPath (Join-Path $staging 'credential-bearing-source.json'))) 'phase3b2_physical_p0_raw_profile_copied'
    Assert-True (@(Get-ChildItem -LiteralPath $staging -Recurse -File -Force).Count -eq 18) 'phase3b2_physical_p0_staged_file_count_mismatch'

    $manifestLines = @(
        $copied |
            Sort-Object RelativePath |
            ForEach-Object {
                "$($_.RelativePath)`t$($_.ByteLength)`t$($_.Sha256)"
            }
    )
    $manifestPath = Join-Path $protected 'offline-p0-input-staging.manifest.tsv'
    Write-AtomicUtf8NoBom $manifestPath (($manifestLines -join "`n") + "`n")

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-input-staging-offline/v1'
        stagedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        preparationBootDisk = 'Samsung SSD 980 1TB'
        targetDisk = 'Micron_2200_MTFDHBA512TCK'
        targetOsOfflineDuringStaging = $true
        stagingPathObserved = $staging
        stagingPathAtTargetBoot = 'C:\NLL\Staging\PhysicalP0-v1'
        stagedMemberCount = $copied.Count
        stagedContentByteLength = [long](($copied | Measure-Object ByteLength -Sum).Sum)
        stagingManifestByteLength = (Get-Item -LiteralPath $manifestPath).Length
        stagingManifestSha256 = Get-Sha256Hex $manifestPath
        cloneBootVerificationReceiptSha256 = $cloneBootReceiptSha256
        epinelpsHead = '519c3db51ec24ca19307e93e85acde7885928a72'
        epinelpsTree = 'b9e8bfb1b1e065427a48d40cb2bcf2f30215436a'
        clientBuild = '150.6.9'
        staticDataPackSha256 = '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3'
        localBootstrapBuildReceiptSha256 = '5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11'
        protectedRawProfileByteLength = $expectedRawProfileByteLength
        protectedRawProfileSha256 = $expectedRawProfileSha256
        credentialBearingSourceCopiedToMicron = $false
        officialIdentityPersistedToMicron = $false
        officialCredentialPersistedToMicron = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'build_physical_server_and_materialize_synthetic_profile'
    }
    $receiptPath = Join-Path $protected 'offline-p0-input-staging.receipt.json'
    Write-AtomicUtf8NoBom $receiptPath (($receipt | ConvertTo-Json -Depth 8) + "`n")
    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $receiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $receiptPath
    } | ConvertTo-Json -Depth 10
}
catch {
    $failure = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-input-staging-offline-failure/v1'
        failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failureMessage = $_.Exception.Message
        partialStagingPresent = Test-Path -LiteralPath $staging
        protectedRawProfileCopiedToMicron = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'inspect_partial_staging_without_reuse'
    }
    $failurePath = Join-Path $protected 'offline-p0-input-staging.failure.receipt.json'
    Write-AtomicUtf8NoBom $failurePath (($failure | ConvertTo-Json -Depth 5) + "`n")
    throw
}
