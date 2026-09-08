#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$MigrationUid = '265861b9-9ff0-4e01-b409-7ce97c53aad1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Verify {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-Utf8Json {
    param([string]$Path, $Value)
    $json = ($Value | ConvertTo-Json -Depth 10) + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Add-VerifiedTree {
    param(
        [string]$Role,
        [string]$Source,
        [string]$Target,
        [string[]]$ExcludedSourceRoots,
        [Text.StringBuilder]$Builder
    )

    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $targetRoot = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    $excluded = @($ExcludedSourceRoots | ForEach-Object {
        [IO.Path]::GetFullPath($_).TrimEnd('\')
    })
    $sourceFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File -ErrorAction Stop |
        Where-Object {
            $candidate = $_.FullName
            -not @($excluded | Where-Object {
                $candidate.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase)
            }).Count
        } | Sort-Object FullName)
    $targetFiles = @(Get-ChildItem -LiteralPath $targetRoot -Recurse -Force -File -ErrorAction Stop)
    Assert-Verify ($sourceFiles.Count -eq $targetFiles.Count) `
        "samsung_to_micron_stable_tree_member_count_mismatch:$Role"

    $verifiedBytes = [long]0
    foreach ($sourceFile in $sourceFiles) {
        $relative = $sourceFile.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $targetFile = [IO.Path]::GetFullPath((Join-Path $targetRoot $relative))
        Assert-Verify ($targetFile.StartsWith($targetRoot + '\', [StringComparison]::OrdinalIgnoreCase)) `
            'samsung_to_micron_stable_target_escaped'
        Assert-Verify (Test-Path -LiteralPath $targetFile -PathType Leaf) `
            "samsung_to_micron_stable_target_missing:${Role}:$relative"
        $targetItem = Get-Item -LiteralPath $targetFile -Force
        Assert-Verify ($sourceFile.Length -eq $targetItem.Length) `
            "samsung_to_micron_stable_length_mismatch:${Role}:$relative"
        $sourceSha256 = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $targetSha256 = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Verify ($sourceSha256 -ceq $targetSha256) `
            "samsung_to_micron_stable_sha256_mismatch:${Role}:$relative"
        [void]$Builder.Append($Role).Append("`t").Append($relative.Replace('\', '/')).Append("`t").
            Append([long]$sourceFile.Length).Append("`t").Append($targetSha256).Append("`n")
        $verifiedBytes += [long]$sourceFile.Length
    }

    [pscustomobject]@{
        role = $Role
        memberCount = $sourceFiles.Count
        verifiedByteLength = $verifiedBytes
    }
}

function Add-VerifiedFile {
    param(
        [string]$Role,
        [string]$Source,
        [string]$Target,
        [Text.StringBuilder]$Builder
    )

    Assert-Verify (Test-Path -LiteralPath $Source -PathType Leaf) `
        "samsung_to_micron_stable_source_file_missing:$Role"
    Assert-Verify (Test-Path -LiteralPath $Target -PathType Leaf) `
        "samsung_to_micron_stable_target_file_missing:$Role"
    $sourceItem = Get-Item -LiteralPath $Source -Force
    $targetItem = Get-Item -LiteralPath $Target -Force
    $sourceSha256 = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    $targetSha256 = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Verify ($sourceItem.Length -eq $targetItem.Length -and $sourceSha256 -ceq $targetSha256) `
        "samsung_to_micron_stable_file_drifted:$Role"
    [void]$Builder.Append($Role).Append("`t").Append([IO.Path]::GetFileName($Target)).Append("`t").
        Append([long]$targetItem.Length).Append("`t").Append($targetSha256).Append("`n")
    [pscustomobject]@{
        role = $Role
        memberCount = 1
        verifiedByteLength = [long]$targetItem.Length
    }
}

$approvedParent = [IO.Path]::GetFullPath('E:\NLL\Migrations\SamsungToMicron\v1').TrimEnd('\')
$migrationRoot = [IO.Path]::GetFullPath((Join-Path $approvedParent $MigrationUid)).TrimEnd('\')
Assert-Verify ($migrationRoot.StartsWith($approvedParent + '\', [StringComparison]::OrdinalIgnoreCase)) `
    'samsung_to_micron_stable_root_outside_approved_parent'
$liveReceiptPath = Join-Path $migrationRoot 'live-staging.receipt.json'
Assert-Verify (Test-Path -LiteralPath $liveReceiptPath -PathType Leaf) `
    'samsung_to_micron_stable_live_receipt_missing'
$liveReceipt = Get-Content -LiteralPath $liveReceiptPath -Raw | ConvertFrom-Json
Assert-Verify ($liveReceipt.contractId -ceq 'nll/samsung-project-state-to-micron-live-staging/v1' -and
    $liveReceipt.migrationUid -ceq $MigrationUid -and
    $liveReceipt.stableCopyFailureCount -eq 0 -and
    $liveReceipt.sourceDeletionPerformed -eq $false) 'samsung_to_micron_stable_live_receipt_invalid'

$systemImageReceipt = 'D:\NikkeLocalLab\Backups\SystemImage\Micron-PrePhysicalLane-20260823\staging.receipt.json'
$systemReceipt = Get-Content -LiteralPath $systemImageReceipt -Raw | ConvertFrom-Json
Assert-Verify ($systemReceipt.contractId -ceq 'nll/samsung-to-micron-system-image-hdd-staging/v1' -and
    $systemReceipt.allTargetMembersSha256Verified -eq $true) `
    'samsung_to_micron_stable_system_image_receipt_invalid'

$protectedSource = 'C:\Recovered_OldSSD\NLL_PreWipe_20260822'
$excludedImage = Join-Path $protectedSource 'PhysicalOS\Micron-PrePhysicalLane-20260823\WindowsImageBackup'
$builder = [Text.StringBuilder]::new()
$results = @(
    Add-VerifiedTree 'protected_evidence' $protectedSource `
        (Join-Path $migrationRoot 'Protected\NLL_PreWipe_20260822') @($excludedImage) $builder
    Add-VerifiedTree 'read_only_main_install' 'C:\NIKKE' `
        (Join-Path $migrationRoot 'ReadOnlyMainInstall\NIKKE') @() $builder
    Add-VerifiedTree 'samsung_locallow' 'C:\Users\zih44\AppData\LocalLow\com.proximabeta\NIKKE' `
        (Join-Path $migrationRoot 'Sensitive\SamsungProfile\AppData\LocalLow\com.proximabeta\NIKKE') @() $builder
    Add-VerifiedFile 'raw_profile_capture' 'C:\Users\zih44\Downloads\nikke_full_scroll_result.json' `
        (Join-Path $migrationRoot 'RawInputs\nikke_full_scroll_result.json') $builder
    Add-VerifiedFile 'raw_fetch_tool' 'C:\Users\zih44\Downloads\getFromBlaLink.py' `
        (Join-Path $migrationRoot 'RawInputs\getFromBlaLink.py') $builder
)

$manifestPath = Join-Path $migrationRoot 'stable-content.manifest.tsv'
[IO.File]::WriteAllText($manifestPath, $builder.ToString(), [Text.UTF8Encoding]::new($false))
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/samsung-project-state-to-micron-stable-content-verification/v1'
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    migrationUid = $MigrationUid
    liveStagingReceiptSha256 = (Get-FileHash -LiteralPath $liveReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    systemImageHddReceiptSha256 = (Get-FileHash -LiteralPath $systemImageReceipt -Algorithm SHA256).Hash.ToLowerInvariant()
    manifestMemberCount = [long](($results.memberCount | Measure-Object -Sum).Sum)
    manifestByteLength = (Get-Item -LiteralPath $manifestPath).Length
    manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    verifiedByteLength = [long](($results.verifiedByteLength | Measure-Object -Sum).Sum)
    allStableMembersSha256Verified = $true
    activeContentVerificationPending = $true
    volatileTempPreservedBestEffort = $true
    sourceDeletionPerformed = $false
    results = $results
    nextStepCode = 'close_codex_then_run_final_active_delta'
}
$receiptPath = Join-Path $migrationRoot 'stable-content.verification.receipt.json'
Write-Utf8Json $receiptPath $receipt

[ordered]@{
    ReceiptPath = $receiptPath
    ReceiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    ManifestSha256 = $receipt.manifestSha256
    ManifestMemberCount = $receipt.manifestMemberCount
    VerifiedByteLength = $receipt.verifiedByteLength
    AllStableMembersSha256Verified = $true
} | ConvertTo-Json -Depth 5
