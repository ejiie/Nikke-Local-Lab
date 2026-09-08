[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Stage {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-Utf8Json {
    param([string]$Path, $Value)
    $json = ($Value | ConvertTo-Json -Depth 10) + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

$sourceParent = [IO.Path]::GetFullPath(
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823').TrimEnd('\')
$sourceImageRoot = Join-Path $sourceParent 'WindowsImageBackup'
$sourceManifest = Join-Path $sourceParent 'windows-image-backup.manifest.tsv'
$targetParent = [IO.Path]::GetFullPath(
    'D:\NikkeLocalLab\Backups\SystemImage\Micron-PrePhysicalLane-20260823').TrimEnd('\')
$approvedTargetParent = [IO.Path]::GetFullPath(
    'D:\NikkeLocalLab\Backups\SystemImage').TrimEnd('\')

Assert-Stage ($targetParent.StartsWith($approvedTargetParent + '\', [StringComparison]::OrdinalIgnoreCase)) `
    'samsung_micron_system_image_target_outside_approved_parent'
Assert-Stage (Test-Path -LiteralPath $sourceImageRoot -PathType Container) `
    'samsung_micron_system_image_source_missing'
Assert-Stage (Test-Path -LiteralPath $sourceManifest -PathType Leaf) `
    'samsung_micron_system_image_manifest_missing'

$manifestLines = @(Get-Content -LiteralPath $sourceManifest | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
})
Assert-Stage ($manifestLines.Count -eq 16) 'samsung_micron_system_image_manifest_count_invalid'
$expectedByteLength = [long]0
foreach ($line in $manifestLines) {
    $parts = $line -split "`t"
    Assert-Stage ($parts.Count -eq 3) 'samsung_micron_system_image_manifest_line_invalid'
    Assert-Stage (-not [IO.Path]::IsPathRooted($parts[0]) -and $parts[0] -notmatch '(^|/|\\)\.\.(/|\\|$)') `
        'samsung_micron_system_image_manifest_path_invalid'
    $expectedByteLength += [long]$parts[1]
}
Assert-Stage ((Get-PSDrive -Name D).Free -gt ($expectedByteLength + 2GB)) `
    'samsung_micron_system_image_hdd_space_insufficient'

[IO.Directory]::CreateDirectory($targetParent) | Out-Null
$targetImageRoot = Join-Path $targetParent 'WindowsImageBackup'
[IO.Directory]::CreateDirectory($targetImageRoot) | Out-Null

$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
& $robocopy $sourceImageRoot $targetImageRoot /E /COPY:DAT /DCOPY:DAT /XJ /SL /R:1 /W:1 /J /MT:8 /NP /NFL /NDL
$robocopyExitCode = $LASTEXITCODE
Assert-Stage ($robocopyExitCode -le 7) "samsung_micron_system_image_robocopy_failed:$robocopyExitCode"

$verifiedByteLength = [long]0
foreach ($line in $manifestLines) {
    $parts = $line -split "`t"
    $relative = $parts[0].Replace('/', '\')
    $targetMember = [IO.Path]::GetFullPath((Join-Path $targetImageRoot $relative))
    Assert-Stage ($targetMember.StartsWith($targetImageRoot + '\', [StringComparison]::OrdinalIgnoreCase)) `
        'samsung_micron_system_image_target_member_escaped'
    Assert-Stage (Test-Path -LiteralPath $targetMember -PathType Leaf) `
        'samsung_micron_system_image_target_member_missing'
    $targetItem = Get-Item -LiteralPath $targetMember -Force
    $targetSha256 = (Get-FileHash -LiteralPath $targetMember -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Stage ($targetItem.Length -eq [long]$parts[1] -and $targetSha256 -ceq $parts[2]) `
        'samsung_micron_system_image_target_member_drifted'
    $verifiedByteLength += [long]$targetItem.Length
}

$targetManifest = Join-Path $targetParent 'windows-image-backup.manifest.tsv'
[IO.File]::Copy($sourceManifest, $targetManifest, $true)
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/samsung-to-micron-system-image-hdd-staging/v1'
    stagedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    sourceImageRoot = $sourceImageRoot
    targetImageRoot = $targetImageRoot
    manifestMemberCount = $manifestLines.Count
    manifestByteLength = (Get-Item -LiteralPath $targetManifest).Length
    manifestSha256 = (Get-FileHash -LiteralPath $targetManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    expectedByteLength = $expectedByteLength
    verifiedByteLength = $verifiedByteLength
    allTargetMembersSha256Verified = $true
    robocopyExitCode = $robocopyExitCode
    sourceDeletionPerformed = $false
    sourceRecoverabilityPreserved = $true
    nextStepCode = 'stage_non_backup_samsung_project_state_to_micron'
}
$receiptPath = Join-Path $targetParent 'staging.receipt.json'
Write-Utf8Json $receiptPath $receipt

[ordered]@{
    ReceiptPath = $receiptPath
    ReceiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    TargetImageRoot = $targetImageRoot
    VerifiedByteLength = $verifiedByteLength
    ManifestSha256 = $receipt.manifestSha256
} | ConvertTo-Json -Depth 5
