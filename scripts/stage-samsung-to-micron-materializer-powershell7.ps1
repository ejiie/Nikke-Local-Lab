#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$RuntimeSource = 'C:\Users\zih44\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell',
    [string]$TargetRoot = 'E:\Users\nlloperator\Desktop\NLL-Samsung-To-Micron-Materializer'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Stage {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-Utf8Text {
    param([string]$Path, [string]$Value)
    [IO.File]::WriteAllText($Path, $Value, [Text.UTF8Encoding]::new($false))
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$targetRootFull = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\')
$approvedParent = [IO.Path]::GetFullPath('E:\Users\nlloperator\Desktop').TrimEnd('\')
Assert-Stage ($targetRootFull.StartsWith($approvedParent + '\', [StringComparison]::OrdinalIgnoreCase)) `
    'materializer_powershell7_target_outside_micron_desktop'
Assert-Stage ($env:SystemDrive -ceq 'C:') `
    'materializer_powershell7_not_running_on_samsung'
Assert-Stage (Test-Path -LiteralPath 'E:\Windows\System32' -PathType Container) `
    'materializer_powershell7_micron_windows_missing'
Assert-Stage (Test-Path -LiteralPath $RuntimeSource -PathType Container) `
    'materializer_powershell7_source_missing'
Assert-Stage (Test-Path -LiteralPath (Join-Path $RuntimeSource 'pwsh.exe') -PathType Leaf) `
    'materializer_powershell7_source_engine_missing'
Assert-Stage (Test-Path -LiteralPath $targetRootFull -PathType Container) `
    'materializer_powershell7_target_package_missing'

$invokeSource = Join-Path $PSScriptRoot 'invoke-materialize-samsung-state-on-micron-elevated.ps1'
$materializeSource = Join-Path $PSScriptRoot 'materialize-samsung-project-state-on-micron.ps1'
Assert-Stage ((Test-Path -LiteralPath $invokeSource -PathType Leaf) -and
    (Test-Path -LiteralPath $materializeSource -PathType Leaf)) `
    'materializer_powershell7_updated_scripts_missing'

$runtimeTarget = Join-Path $targetRootFull 'PowerShell7'
$stagingRoot = Join-Path $approvedParent (
    '.NLL-Materializer-PowerShell7-Staging-' + [guid]::NewGuid().ToString('N'))
Assert-Stage (-not (Test-Path -LiteralPath $stagingRoot)) `
    'materializer_powershell7_staging_collision'
[IO.Directory]::CreateDirectory($stagingRoot) | Out-Null

$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
& $robocopy $RuntimeSource $stagingRoot /E /COPY:DAT /DCOPY:DAT /XJ /SL /Z /R:1 /W:1 /J /MT:8 /NP /NFL /NDL /NJH /BYTES | Out-Null
Assert-Stage ($LASTEXITCODE -le 7) `
    "materializer_powershell7_runtime_copy_failed:$LASTEXITCODE"

$sourceRootFull = [IO.Path]::GetFullPath($RuntimeSource).TrimEnd('\')
$sourceFiles = @(Get-ChildItem -LiteralPath $sourceRootFull -Recurse -Force -File -ErrorAction Stop |
    Sort-Object FullName)
$stagedFiles = @(Get-ChildItem -LiteralPath $stagingRoot -Recurse -Force -File -ErrorAction Stop)
Assert-Stage ($sourceFiles.Count -eq $stagedFiles.Count) `
    'materializer_powershell7_staging_member_count_mismatch'
foreach ($sourceFile in $sourceFiles) {
    $relative = $sourceFile.FullName.Substring($sourceRootFull.Length).TrimStart('\')
    $stagedFile = Join-Path $stagingRoot $relative
    Assert-Stage (Test-Path -LiteralPath $stagedFile -PathType Leaf) `
        "materializer_powershell7_staging_member_missing:$relative"
    $stagedItem = Get-Item -LiteralPath $stagedFile -Force
    Assert-Stage ($sourceFile.Length -eq $stagedItem.Length -and
        (Get-Sha256Hex $sourceFile.FullName) -ceq (Get-Sha256Hex $stagedFile)) `
        "materializer_powershell7_staging_member_drifted:$relative"
}

if (Test-Path -LiteralPath $runtimeTarget) {
    $targetFiles = @(Get-ChildItem -LiteralPath $runtimeTarget -Recurse -Force -File -ErrorAction Stop)
    Assert-Stage ($targetFiles.Count -eq $sourceFiles.Count) `
        'materializer_powershell7_existing_runtime_count_invalid'
    foreach ($sourceFile in $sourceFiles) {
        $relative = $sourceFile.FullName.Substring($sourceRootFull.Length).TrimStart('\')
        $targetFile = Join-Path $runtimeTarget $relative
        Assert-Stage (Test-Path -LiteralPath $targetFile -PathType Leaf) `
            "materializer_powershell7_existing_member_missing:$relative"
        Assert-Stage ($sourceFile.Length -eq (Get-Item -LiteralPath $targetFile -Force).Length -and
            (Get-Sha256Hex $sourceFile.FullName) -ceq (Get-Sha256Hex $targetFile)) `
            "materializer_powershell7_existing_member_drifted:$relative"
    }
    $stagingRootFull = [IO.Path]::GetFullPath($stagingRoot)
    Assert-Stage ($stagingRootFull.StartsWith($approvedParent + '\', [StringComparison]::OrdinalIgnoreCase)) `
        'materializer_powershell7_staging_cleanup_outside_parent'
    [IO.Directory]::Delete($stagingRootFull, $true)
}
else {
    Move-Item -LiteralPath $stagingRoot -Destination $runtimeTarget
}

$backupRoot = Join-Path $targetRootFull (
    'Backups\' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' +
    [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($backupRoot) | Out-Null
foreach ($leaf in @(
        'invoke-materialize-samsung-state-on-micron-elevated.ps1',
        'materialize-samsung-project-state-on-micron.ps1')) {
    $prior = Join-Path $targetRootFull $leaf
    Assert-Stage (Test-Path -LiteralPath $prior -PathType Leaf) `
        "materializer_powershell7_prior_script_missing:$leaf"
    [IO.File]::Copy($prior, (Join-Path $backupRoot $leaf), $false)
}
[IO.File]::Copy($invokeSource,
    (Join-Path $targetRootFull 'invoke-materialize-samsung-state-on-micron-elevated.ps1'), $true)
[IO.File]::Copy($materializeSource,
    (Join-Path $targetRootFull 'materialize-samsung-project-state-on-micron.ps1'), $true)
Assert-Stage ((Get-Sha256Hex $invokeSource) -ceq
    (Get-Sha256Hex (Join-Path $targetRootFull 'invoke-materialize-samsung-state-on-micron-elevated.ps1')) -and
    (Get-Sha256Hex $materializeSource) -ceq
    (Get-Sha256Hex (Join-Path $targetRootFull 'materialize-samsung-project-state-on-micron.ps1'))) `
    'materializer_powershell7_script_update_drifted'

$builder = [Text.StringBuilder]::new()
$runtimeFiles = @(Get-ChildItem -LiteralPath $runtimeTarget -Recurse -Force -File -ErrorAction Stop |
    Sort-Object FullName)
$runtimeTargetFull = [IO.Path]::GetFullPath($runtimeTarget).TrimEnd('\')
$totalBytes = [long]0
foreach ($file in $runtimeFiles) {
    $relative = $file.FullName.Substring($runtimeTargetFull.Length).TrimStart('\').Replace('\', '/')
    $sha256 = Get-Sha256Hex $file.FullName
    [void]$builder.Append($relative).Append("`t").Append([long]$file.Length).Append("`t").
        Append($sha256).Append("`n")
    $totalBytes += [long]$file.Length
}
$manifestPath = Join-Path $targetRootFull 'powershell7.content.manifest.tsv'
Write-Utf8Text $manifestPath $builder.ToString()
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/samsung-to-micron-materializer-powershell7-staging/v1'
    stagedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    runtimeTarget = $runtimeTarget
    memberCount = $runtimeFiles.Count
    contentByteLength = $totalBytes
    manifestSha256 = Get-Sha256Hex $manifestPath
    invokeScriptSha256 = Get-Sha256Hex (Join-Path $targetRootFull 'invoke-materialize-samsung-state-on-micron-elevated.ps1')
    materializeScriptSha256 = Get-Sha256Hex (Join-Path $targetRootFull 'materialize-samsung-project-state-on-micron.ps1')
    priorScriptsBackupRoot = $backupRoot
    allTargetMembersSha256Verified = $true
    sourceDeletionPerformed = $false
    nextStepCode = 'run_finalizer_then_require_offline_micron_preflight'
}
$receiptPath = Join-Path $targetRootFull 'powershell7.staging.receipt.json'
Write-Utf8Text $receiptPath (($receipt | ConvertTo-Json -Depth 6) + "`n")

[ordered]@{
    ReceiptPath = $receiptPath
    ReceiptSha256 = Get-Sha256Hex $receiptPath
    MemberCount = $receipt.memberCount
    ContentByteLength = $receipt.contentByteLength
    ManifestSha256 = $receipt.manifestSha256
} | ConvertTo-Json -Depth 5
