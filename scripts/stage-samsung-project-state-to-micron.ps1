[CmdletBinding()]
param(
    [string]$MigrationUid = '265861b9-9ff0-4e01-b409-7ce97c53aad1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Stage {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-Utf8Json {
    param([string]$Path, $Value)
    $json = ($Value | ConvertTo-Json -Depth 12) + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Invoke-DirectoryStage {
    param(
        [string]$Source,
        [string]$Target,
        [bool]$AllowLiveDrift,
        [string[]]$ExcludeDirectories = @()
    )

    Assert-Stage (Test-Path -LiteralPath $Source -PathType Container) `
        "samsung_to_micron_source_missing:$Source"
    [IO.Directory]::CreateDirectory($Target) | Out-Null
    $arguments = @(
        $Source, $Target,
        '/E', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/SL', '/Z',
        '/R:1', '/W:1', '/J', '/MT:8', '/NP', '/NFL', '/NDL', '/NJH', '/BYTES'
    )
    if ($ExcludeDirectories.Count -gt 0) {
        $arguments += '/XD'
        $arguments += $ExcludeDirectories
    }
    & $script:Robocopy @arguments | Out-Null
    $exitCode = $LASTEXITCODE
    if (-not $AllowLiveDrift) {
        Assert-Stage ($exitCode -le 7) "samsung_to_micron_robocopy_failed:${exitCode}:$Source"
    }
    [pscustomobject]@{
        source = $Source
        target = $Target
        kind = 'directory'
        allowLiveDrift = $AllowLiveDrift
        robocopyExitCode = $exitCode
        copyAccepted = ($exitCode -le 7)
        excludedDirectories = @($ExcludeDirectories)
    }
}

function Invoke-FileStage {
    param([string]$Source, [string]$Target)

    Assert-Stage (Test-Path -LiteralPath $Source -PathType Leaf) `
        "samsung_to_micron_source_file_missing:$Source"
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Target)) | Out-Null
    [IO.File]::Copy($Source, $Target, $true)
    $sourceItem = Get-Item -LiteralPath $Source -Force
    $targetItem = Get-Item -LiteralPath $Target -Force
    $sourceSha256 = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLowerInvariant()
    $targetSha256 = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Stage ($sourceItem.Length -eq $targetItem.Length -and $sourceSha256 -ceq $targetSha256) `
        "samsung_to_micron_source_file_copy_drifted:$Source"
    [pscustomobject]@{
        source = $Source
        target = $Target
        kind = 'file'
        allowLiveDrift = $false
        robocopyExitCode = $null
        byteLength = [long]$targetItem.Length
        sha256 = $targetSha256
        copyAccepted = $true
    }
}

Assert-Stage ($MigrationUid -match '^[0-9a-fA-F-]{36}$') `
    'samsung_to_micron_migration_uid_invalid'
$approvedParent = [IO.Path]::GetFullPath(
    'E:\NLL\Migrations\SamsungToMicron\v1').TrimEnd('\')
$migrationRoot = [IO.Path]::GetFullPath((Join-Path $approvedParent $MigrationUid)).TrimEnd('\')
Assert-Stage ($migrationRoot.StartsWith($approvedParent + '\', [StringComparison]::OrdinalIgnoreCase)) `
    'samsung_to_micron_target_outside_approved_parent'

$systemImageSource = [IO.Path]::GetFullPath(
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\WindowsImageBackup').TrimEnd('\')
$systemImageReceipt = 'D:\NikkeLocalLab\Backups\SystemImage\Micron-PrePhysicalLane-20260823\staging.receipt.json'
Assert-Stage (Test-Path -LiteralPath $systemImageReceipt -PathType Leaf) `
    'samsung_to_micron_system_image_hdd_receipt_missing'
$systemReceipt = Get-Content -LiteralPath $systemImageReceipt -Raw | ConvertFrom-Json
Assert-Stage ($systemReceipt.contractId -ceq 'nll/samsung-to-micron-system-image-hdd-staging/v1' -and
    $systemReceipt.allTargetMembersSha256Verified -eq $true -and
    $systemReceipt.sourceDeletionPerformed -eq $false) `
    'samsung_to_micron_system_image_hdd_receipt_invalid'

$minimumRequired = 135GB
$existingStagingByteLength = if (Test-Path -LiteralPath $migrationRoot -PathType Container) {
    [long]((Get-ChildItem -LiteralPath $migrationRoot -Recurse -Force -File -ErrorAction Stop |
        Measure-Object Length -Sum).Sum)
}
else {
    [long]0
}
$effectiveAvailable = [long](Get-PSDrive -Name E).Free + $existingStagingByteLength
Assert-Stage ($effectiveAvailable -gt $minimumRequired) `
    'samsung_to_micron_micron_space_insufficient'
[IO.Directory]::CreateDirectory($migrationRoot) | Out-Null
$script:Robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
$results = New-Object System.Collections.Generic.List[object]

$results.Add((Invoke-DirectoryStage `
    'C:\Users\zih44\Documents\Github' `
    (Join-Path $migrationRoot 'Operational\Github') `
    $true))
$results.Add((Invoke-DirectoryStage `
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822' `
    (Join-Path $migrationRoot 'Protected\NLL_PreWipe_20260822') `
    $false `
    @($systemImageSource)))
$results.Add((Invoke-DirectoryStage `
    'C:\NIKKE' `
    (Join-Path $migrationRoot 'ReadOnlyMainInstall\NIKKE') `
    $false))
$results.Add((Invoke-DirectoryStage `
    'C:\Users\zih44\AppData\LocalLow\com.proximabeta\NIKKE' `
    (Join-Path $migrationRoot 'Sensitive\SamsungProfile\AppData\LocalLow\com.proximabeta\NIKKE') `
    $false))

$results.Add((Invoke-DirectoryStage `
    'C:\Users\zih44\.codex' `
    (Join-Path $migrationRoot 'Codex\CODEX_HOME') `
    $true))
$results.Add((Invoke-DirectoryStage `
    'C:\Users\zih44\AppData\Local\Codex' `
    (Join-Path $migrationRoot 'Codex\AppDataLocalCodex') `
    $true))
$results.Add((Invoke-DirectoryStage `
    'C:\Users\zih44\AppData\Local\OpenAI' `
    (Join-Path $migrationRoot 'Codex\AppDataLocalOpenAI') `
    $true))
$results.Add((Invoke-DirectoryStage `
    'C:\Users\zih44\AppData\Roaming\Codex' `
    (Join-Path $migrationRoot 'Codex\AppDataRoamingCodex') `
    $true))
$results.Add((Invoke-DirectoryStage `
    'C:\Users\zih44\Documents\Codex' `
    (Join-Path $migrationRoot 'Codex\DocumentsCodex') `
    $true))
$results.Add((Invoke-DirectoryStage `
    'C:\Users\zih44\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine' `
    (Join-Path $migrationRoot 'Sensitive\DeveloperProfile\PowerShell\PSReadLine') `
    $true))
$results.Add((Invoke-FileStage `
    'C:\Users\zih44\AppData\Roaming\NuGet\NuGet.Config' `
    (Join-Path $migrationRoot 'Sensitive\DeveloperProfile\NuGet\NuGet.Config')))
$results.Add((Invoke-DirectoryStage `
    'C:\Users\zih44\Desktop' `
    (Join-Path $migrationRoot 'AuxiliaryProfile\Desktop') `
    $true))

$results.Add((Invoke-FileStage `
    'C:\Users\zih44\Downloads\nikke_full_scroll_result.json' `
    (Join-Path $migrationRoot 'RawInputs\nikke_full_scroll_result.json')))
$results.Add((Invoke-FileStage `
    'C:\Users\zih44\Downloads\getFromBlaLink.py' `
    (Join-Path $migrationRoot 'RawInputs\getFromBlaLink.py')))
$results.Add((Invoke-FileStage `
    'C:\Users\zih44\Desktop\NLL-Switch-To-Micron.cmd' `
    (Join-Path $migrationRoot 'SwitchTools\NLL-Switch-To-Micron.cmd')))
$results.Add((Invoke-FileStage `
    'C:\Users\zih44\Desktop\NLL-Switch-To-Micron.ps1' `
    (Join-Path $migrationRoot 'SwitchTools\NLL-Switch-To-Micron.ps1')))

$tempTarget = Join-Path $migrationRoot 'TempNLL'
$tempItems = @(Get-ChildItem -LiteralPath 'C:\Users\zih44\AppData\Local\Temp' -Force |
    Where-Object { $_.Name -match '(?i)^(nll|nikke)' })
foreach ($tempItem in $tempItems) {
    $tempDestination = Join-Path $tempTarget $tempItem.Name
    if ($tempItem.PSIsContainer) {
        $results.Add((Invoke-DirectoryStage $tempItem.FullName $tempDestination $false))
    }
    else {
        $results.Add((Invoke-FileStage $tempItem.FullName $tempDestination))
    }
}

$clipboardTarget = Join-Path $migrationRoot 'Codex\TempClipboard'
$clipboardItems = @(Get-ChildItem -LiteralPath 'C:\Users\zih44\AppData\Local\Temp' -Force -File |
    Where-Object { $_.Name -match '^codex-clipboard-.*\.(png|jpg|jpeg|txt)$' })
foreach ($clipboardItem in $clipboardItems) {
    $results.Add((Invoke-FileStage $clipboardItem.FullName (Join-Path $clipboardTarget $clipboardItem.Name)))
}

$targetFiles = @(Get-ChildItem -LiteralPath $migrationRoot -Recurse -Force -File -ErrorAction Stop)
$activeCopyFailures = @($results | Where-Object { $_.allowLiveDrift -eq $true -and $_.copyAccepted -ne $true })
$stableCopyFailures = @($results | Where-Object { $_.allowLiveDrift -ne $true -and $_.copyAccepted -ne $true })
Assert-Stage ($stableCopyFailures.Count -eq 0) 'samsung_to_micron_stable_copy_failed'
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/samsung-project-state-to-micron-live-staging/v1'
    stagedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    migrationUid = $MigrationUid
    migrationRoot = $migrationRoot
    systemImageHddReceiptSha256 = (Get-FileHash -LiteralPath $systemImageReceipt -Algorithm SHA256).Hash.ToLowerInvariant()
    mappingCount = $results.Count
    stableCopyFailureCount = $stableCopyFailures.Count
    activeCopyFailureCount = $activeCopyFailures.Count
    copiedFileCount = $targetFiles.Count
    copiedByteLength = [long](($targetFiles | Measure-Object Length -Sum).Sum)
    codexWasRunningDuringStage = $true
    finalDeltaRequired = $true
    targetAclHardeningPending = $true
    sourceDeletionPerformed = $false
    sourceNikkeMainInstallReadOnly = $true
    systemImageExcludedFromMicron = $true
    mappings = $results.ToArray()
    nextStepCode = 'close_codex_then_run_final_delta_and_micron_materialization'
}
$receiptPath = Join-Path $migrationRoot 'live-staging.receipt.json'
Write-Utf8Json $receiptPath $receipt

[ordered]@{
    MigrationRoot = $migrationRoot
    ReceiptPath = $receiptPath
    ReceiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    MappingCount = $results.Count
    ActiveCopyFailureCount = $activeCopyFailures.Count
    CopiedFileCount = $targetFiles.Count
    CopiedByteLength = $receipt.copiedByteLength
    FinalDeltaRequired = $true
} | ConvertTo-Json -Depth 5
