[CmdletBinding()]
param(
    [string]$MigrationUid = '265861b9-9ff0-4e01-b409-7ce97c53aad1',
    [switch]$PreflightOnly,
    [ValidatePattern('^[A-Za-z]:$')]
    [string]$TargetSystemDrive = 'C:'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Materialize {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-Utf8Json {
    param([string]$Path, $Value)
    $json = ($Value | ConvertTo-Json -Depth 10) + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Assert-DirectoryTargetAvailable {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        Assert-Materialize ($item.PSIsContainer -and
            -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) `
            "micron_materialization_target_not_plain_directory:$Path"
        return
    }

    $ancestor = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while ($ancestor -and -not (Test-Path -LiteralPath $ancestor)) {
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    Assert-Materialize ($ancestor -and
        (Test-Path -LiteralPath $ancestor -PathType Container)) `
        "micron_materialization_target_parent_invalid:$Path"
}

function Assert-JunctionPathAvailable {
    param([string]$Path, [string]$Target)

    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Item -LiteralPath $Path -Force
        Assert-Materialize (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            @($existing.Target) -contains $Target) `
            "micron_materialization_junction_path_occupied:$Path"
        return
    }

    $ancestor = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while ($ancestor -and -not (Test-Path -LiteralPath $ancestor)) {
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    Assert-Materialize ($ancestor -and
        (Test-Path -LiteralPath $ancestor -PathType Container)) `
        "micron_materialization_junction_parent_invalid:$Path"
}

function Get-RoleManifestRows {
    param([string]$Role)
    @($script:ActiveManifestRows | Where-Object { $_.role -ceq $Role })
}

function Assert-ManifestBackedSourceShape {
    param([string]$Role, [string]$Source)

    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $rows = @(Get-RoleManifestRows $Role)
    $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File -ErrorAction Stop)
    Assert-Materialize ($rows.Count -eq $files.Count) `
        "micron_materialization_source_manifest_count_mismatch:$Role"
    foreach ($row in $rows) {
        $relative = $row.relativePath.Replace('/', '\')
        $sourceFile = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relative))
        Assert-Materialize ($sourceFile.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) `
            "micron_materialization_source_manifest_path_escaped:$Role"
        Assert-Materialize (Test-Path -LiteralPath $sourceFile -PathType Leaf) `
            "micron_materialization_source_manifest_member_missing:${Role}:$relative"
        Assert-Materialize ((Get-Item -LiteralPath $sourceFile -Force).Length -eq $row.byteLength) `
            "micron_materialization_source_manifest_length_mismatch:${Role}:$relative"
    }
    [long](($rows | Measure-Object byteLength -Sum).Sum)
}

function Assert-ManifestBackedTargetContent {
    param([string]$Role, [string]$Target)

    $targetRoot = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    $rows = @(Get-RoleManifestRows $Role)
    $files = @(Get-ChildItem -LiteralPath $targetRoot -Recurse -Force -File -ErrorAction Stop)
    Assert-Materialize ($rows.Count -eq $files.Count) `
        "micron_materialization_target_manifest_count_mismatch:$Role"
    $verifiedBytes = [long]0
    foreach ($row in $rows) {
        $relative = $row.relativePath.Replace('/', '\')
        $targetFile = [IO.Path]::GetFullPath((Join-Path $targetRoot $relative))
        Assert-Materialize ($targetFile.StartsWith($targetRoot + '\', [StringComparison]::OrdinalIgnoreCase)) `
            "micron_materialization_target_manifest_path_escaped:$Role"
        Assert-Materialize (Test-Path -LiteralPath $targetFile -PathType Leaf) `
            "micron_materialization_target_manifest_member_missing:${Role}:$relative"
        $targetItem = Get-Item -LiteralPath $targetFile -Force
        $targetSha256 = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Materialize ($targetItem.Length -eq $row.byteLength -and
            $targetSha256 -ceq $row.sha256) `
            "micron_materialization_target_manifest_hash_mismatch:${Role}:$relative"
        $verifiedBytes += [long]$targetItem.Length
    }
    [pscustomobject]@{
        verifiedFileCount = $rows.Count
        verifiedByteLength = $verifiedBytes
        allTargetMembersSha256Verified = $true
    }
}

function Invoke-ProfileCopy {
    param([string]$Role, [string]$Source, [string]$Target)

    Write-Host "Materializing profile mapping: $Target"
    Assert-Materialize (Test-Path -LiteralPath $Source -PathType Container) `
        "micron_materialization_source_missing:$Source"
    [IO.Directory]::CreateDirectory($Target) | Out-Null
    & $script:Robocopy $Source $Target /MIR /COPY:DAT /DCOPY:DAT /XJ /SL /Z /R:1 /W:1 /J /MT:8 /NP /NFL /NDL /NJH /BYTES | Out-Null
    $copyExitCode = $LASTEXITCODE
    Assert-Materialize ($copyExitCode -le 7) `
        "micron_materialization_copy_failed:${copyExitCode}:$Source"

    & $script:Robocopy $Source $Target /MIR /L /COPY:DAT /DCOPY:DAT /XJ /SL /R:0 /W:0 /NP /NFL /NDL /NJH /NJS | Out-Null
    $auditExitCode = $LASTEXITCODE
    Assert-Materialize ($auditExitCode -eq 0) `
        "micron_materialization_audit_failed:${auditExitCode}:$Source"
    $contentVerification = Assert-ManifestBackedTargetContent $Role $Target
    [pscustomobject]@{
        role = $Role
        source = $Source
        target = $Target
        copyExitCode = $copyExitCode
        mirrorAuditExitCode = $auditExitCode
        verifiedFileCount = $contentVerification.verifiedFileCount
        verifiedByteLength = $contentVerification.verifiedByteLength
        allTargetMembersSha256Verified = $contentVerification.allTargetMembersSha256Verified
    }
}

function New-ApprovedJunction {
    param([string]$Path, [string]$Target)

    Assert-Materialize (Test-Path -LiteralPath $Target -PathType Container) `
        "micron_materialization_junction_target_missing:$Target"
    if (Test-Path -LiteralPath $Path) {
        $existing = Get-Item -LiteralPath $Path -Force
        Assert-Materialize (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            @($existing.Target) -contains $Target) `
            "micron_materialization_junction_path_occupied:$Path"
        return
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
}

$TargetSystemDrive = $TargetSystemDrive.ToUpperInvariant()
$targetVolumeRoot = $TargetSystemDrive + '\'
Assert-Materialize (Test-Path -LiteralPath (Join-Path $targetVolumeRoot 'Windows\System32') -PathType Container) `
    'micron_materialization_target_windows_missing'
if (-not $PreflightOnly) {
    Assert-Materialize (Test-IsAdministrator) `
        'micron_materialization_administrator_required'
    Assert-Materialize ($env:SystemDrive -ceq $TargetSystemDrive) `
        'micron_materialization_system_drive_invalid'
    Assert-Materialize ($env:USERNAME -ceq 'nlloperator') `
        'micron_materialization_user_invalid'
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -match '(?i)^(chatgpt|codex|codex-code-mode-host|codex-command-runner.*)$'
    })
    Assert-Materialize ($running.Count -eq 0) 'micron_materialization_codex_process_running'
}

$migrationRoot = [IO.Path]::GetFullPath(
    (Join-Path $targetVolumeRoot "NLL\Migrations\SamsungToMicron\v1\$MigrationUid")).TrimEnd('\')
$approvedParent = [IO.Path]::GetFullPath(
    (Join-Path $targetVolumeRoot 'NLL\Migrations\SamsungToMicron\v1')).TrimEnd('\')
Assert-Materialize ($migrationRoot.StartsWith($approvedParent + '\', [StringComparison]::OrdinalIgnoreCase)) `
    'micron_materialization_root_outside_approved_parent'
$finalReceiptPath = Join-Path $migrationRoot 'final-delta.receipt.json'
Assert-Materialize (Test-Path -LiteralPath $finalReceiptPath -PathType Leaf) `
    'micron_materialization_final_delta_receipt_missing'
$finalReceipt = Get-Content -LiteralPath $finalReceiptPath -Raw | ConvertFrom-Json
Assert-Materialize ($finalReceipt.contractId -ceq 'nll/samsung-project-state-to-micron-final-delta/v1' -and
    $finalReceipt.migrationUid -ceq $MigrationUid -and
    $finalReceipt.allActiveMembersSha256Verified -eq $true -and
    $finalReceipt.sourceDeletionPerformed -eq $false -and
    $finalReceipt.materializationPending -eq $true) `
    'micron_materialization_final_delta_receipt_invalid'
$stableReceiptPath = Join-Path $migrationRoot 'stable-content.verification.receipt.json'
Assert-Materialize (Test-Path -LiteralPath $stableReceiptPath -PathType Leaf) `
    'micron_materialization_stable_receipt_missing'
$stableReceipt = Get-Content -LiteralPath $stableReceiptPath -Raw | ConvertFrom-Json
Assert-Materialize ($stableReceipt.contractId -ceq 'nll/samsung-project-state-to-micron-stable-content-verification/v1' -and
    $stableReceipt.migrationUid -ceq $MigrationUid -and
    $stableReceipt.allStableMembersSha256Verified -eq $true -and
    (Get-FileHash -LiteralPath $stableReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
        [string]$finalReceipt.stableVerificationReceiptSha256) `
    'micron_materialization_stable_receipt_invalid'
$activeManifest = Join-Path $migrationRoot 'final-active-content.manifest.tsv'
Assert-Materialize (Test-Path -LiteralPath $activeManifest -PathType Leaf) `
    'micron_materialization_active_manifest_missing'
Assert-Materialize ((Get-FileHash -LiteralPath $activeManifest -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
    [string]$finalReceipt.activeManifestSha256) 'micron_materialization_active_manifest_drifted'

$script:ActiveManifestRows = New-Object System.Collections.Generic.List[object]
$manifestKeys = @{}
foreach ($line in @(Get-Content -LiteralPath $activeManifest -Encoding UTF8 | Where-Object { $_ })) {
    $parts = $line.Split("`t")
    Assert-Materialize ($parts.Count -eq 4) `
        'micron_materialization_active_manifest_row_invalid'
    $role = [string]$parts[0]
    $relativePath = [string]$parts[1]
    $byteLength = [long]0
    Assert-Materialize ($role -match '^[a-z0-9_]+$' -and
        -not [string]::IsNullOrWhiteSpace($relativePath) -and
        -not [IO.Path]::IsPathRooted($relativePath) -and
        $relativePath -notmatch '(^|/)\.\.(/|$)' -and
        [long]::TryParse([string]$parts[2], [ref]$byteLength) -and
        $byteLength -ge 0 -and [string]$parts[3] -match '^[0-9a-f]{64}$') `
        'micron_materialization_active_manifest_row_shape_invalid'
    $key = ($role + "`t" + $relativePath).ToLowerInvariant()
    Assert-Materialize (-not $manifestKeys.ContainsKey($key)) `
        'micron_materialization_active_manifest_duplicate_member'
    $manifestKeys[$key] = $true
    $script:ActiveManifestRows.Add([pscustomobject]@{
        role = $role
        relativePath = $relativePath
        byteLength = $byteLength
        sha256 = [string]$parts[3]
    })
}
Assert-Materialize ($script:ActiveManifestRows.Count -eq
    [long]$finalReceipt.activeManifestMemberCount) `
    'micron_materialization_active_manifest_member_count_invalid'

$profileRoot = Join-Path $targetVolumeRoot 'Users\nlloperator'
Assert-Materialize (Test-Path -LiteralPath $profileRoot -PathType Container) `
    'micron_materialization_profile_root_missing'
$githubTarget = Join-Path $profileRoot 'Documents\Github'
$repoTarget = Join-Path $githubTarget 'Nikke-Local-Lab'
$codexHomeTarget = Join-Path $profileRoot '.codex'
$documentsCodexTarget = Join-Path $profileRoot 'Documents\Codex'
$openAiLocalTarget = Join-Path $profileRoot 'AppData\Local\OpenAI'
$powerShellHistoryTarget = Join-Path $profileRoot 'AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine'
$importedDesktopTarget = Join-Path $profileRoot 'Desktop\Samsung-Imported-Desktop'
$importRoot = Join-Path $profileRoot 'Downloads\NLL-Imported-Samsung'
$nugetTargetRoot = Join-Path $profileRoot 'AppData\Roaming\NuGet'
$profileMappings = @(
    [pscustomobject]@{ role = 'github_workspaces'; source = Join-Path $migrationRoot 'Operational\Github'; target = $githubTarget },
    [pscustomobject]@{ role = 'codex_home'; source = Join-Path $migrationRoot 'Codex\CODEX_HOME'; target = $codexHomeTarget },
    [pscustomobject]@{ role = 'codex_documents'; source = Join-Path $migrationRoot 'Codex\DocumentsCodex'; target = $documentsCodexTarget },
    [pscustomobject]@{ role = 'openai_local'; source = Join-Path $migrationRoot 'Codex\AppDataLocalOpenAI'; target = $openAiLocalTarget },
    [pscustomobject]@{ role = 'powershell_history'; source = Join-Path $migrationRoot 'Sensitive\DeveloperProfile\PowerShell\PSReadLine'; target = $powerShellHistoryTarget },
    [pscustomobject]@{ role = 'desktop_auxiliary'; source = Join-Path $migrationRoot 'AuxiliaryProfile\Desktop'; target = $importedDesktopTarget }
)
$profilePreflight = New-Object System.Collections.Generic.List[object]
$requiredCopyBytes = [long]0
foreach ($mapping in $profileMappings) {
    Assert-Materialize (Test-Path -LiteralPath $mapping.source -PathType Container) `
        "micron_materialization_source_missing:$($mapping.source)"
    Assert-DirectoryTargetAvailable $mapping.target
    $sourceBytes = Assert-ManifestBackedSourceShape $mapping.role $mapping.source
    $requiredCopyBytes += $sourceBytes
    $profilePreflight.Add([pscustomobject]@{
        role = $mapping.role
        source = $mapping.source
        target = $mapping.target
        sourceByteLength = $sourceBytes
        sourceManifestShapeVerified = $true
    })
}

$directFileMappings = @(
    [pscustomobject]@{ role = 'raw_profile'; source = Join-Path $migrationRoot 'RawInputs\nikke_full_scroll_result.json'; target = Join-Path $importRoot 'nikke_full_scroll_result.json' },
    [pscustomobject]@{ role = 'raw_fetch_tool'; source = Join-Path $migrationRoot 'RawInputs\getFromBlaLink.py'; target = Join-Path $importRoot 'getFromBlaLink.py' },
    [pscustomobject]@{ role = 'switch_cmd'; source = Join-Path $migrationRoot 'SwitchTools\NLL-Switch-To-Micron.cmd'; target = Join-Path $profileRoot 'Desktop\NLL-Switch-To-Micron.cmd' },
    [pscustomobject]@{ role = 'switch_ps1'; source = Join-Path $migrationRoot 'SwitchTools\NLL-Switch-To-Micron.ps1'; target = Join-Path $profileRoot 'Desktop\NLL-Switch-To-Micron.ps1' },
    [pscustomobject]@{ role = 'nuget_config'; source = Join-Path $migrationRoot 'Sensitive\DeveloperProfile\NuGet\NuGet.Config'; target = Join-Path $nugetTargetRoot 'NuGet.Config' }
)
Assert-DirectoryTargetAvailable $importRoot
Assert-DirectoryTargetAvailable $nugetTargetRoot
Assert-DirectoryTargetAvailable (Join-Path $profileRoot 'Desktop')
$directFilePreflight = New-Object System.Collections.Generic.List[object]
foreach ($mapping in $directFileMappings) {
    Assert-Materialize (Test-Path -LiteralPath $mapping.source -PathType Leaf) `
        "micron_materialization_direct_source_missing:$($mapping.source)"
    if (Test-Path -LiteralPath $mapping.target) {
        $targetItem = Get-Item -LiteralPath $mapping.target -Force
        Assert-Materialize (-not $targetItem.PSIsContainer -and
            -not ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) `
            "micron_materialization_direct_target_invalid:$($mapping.target)"
    }
    $sourceItem = Get-Item -LiteralPath $mapping.source -Force
    $directFilePreflight.Add([pscustomobject]@{
        role = $mapping.role
        source = $mapping.source
        target = $mapping.target
        byteLength = [long]$sourceItem.Length
        sha256 = (Get-FileHash -LiteralPath $mapping.source -Algorithm SHA256).Hash.ToLowerInvariant()
    })
    $requiredCopyBytes += [long]$sourceItem.Length
}

$nugetManifestRows = @(Get-RoleManifestRows 'nuget_profile' | Where-Object {
    $_.relativePath -ceq 'NuGet.Config'
})
Assert-Materialize ($nugetManifestRows.Count -eq 1 -and
    $nugetManifestRows[0].byteLength -eq $directFilePreflight[4].byteLength -and
    $nugetManifestRows[0].sha256 -ceq $directFilePreflight[4].sha256) `
    'micron_materialization_nuget_manifest_binding_invalid'

$junctionMappings = @(
    [pscustomobject]@{ path = Join-Path $targetVolumeRoot 'Users\zih44\Documents\Github\Nikke-Local-Lab'; target = $repoTarget },
    [pscustomobject]@{ path = Join-Path $targetVolumeRoot 'Users\zih44\.codex'; target = $codexHomeTarget },
    [pscustomobject]@{ path = Join-Path $targetVolumeRoot 'Users\zih44\Documents\Codex'; target = $documentsCodexTarget },
    [pscustomobject]@{ path = Join-Path $targetVolumeRoot 'Recovered_OldSSD\NLL_PreWipe_20260822'; target = Join-Path $migrationRoot 'Protected\NLL_PreWipe_20260822' }
)
foreach ($mapping in $junctionMappings) {
    $targetAvailable = Test-Path -LiteralPath $mapping.target -PathType Container
    if (-not $targetAvailable) {
        $futureProfileMapping = @($profileMappings | Where-Object {
            $mapping.target -ceq $_.target -or
            $mapping.target.StartsWith($_.target.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
        if ($futureProfileMapping.Count -eq 1) {
            $futureRelativePath = $mapping.target.Substring(
                $futureProfileMapping[0].target.TrimEnd('\').Length).TrimStart('\')
            $futureSourcePath = if ($futureRelativePath) {
                Join-Path $futureProfileMapping[0].source $futureRelativePath
            }
            else {
                $futureProfileMapping[0].source
            }
            $targetAvailable = Test-Path -LiteralPath $futureSourcePath -PathType Container
        }
    }
    Assert-Materialize $targetAvailable `
        "micron_materialization_junction_target_unavailable:$($mapping.target)"
    Assert-JunctionPathAvailable $mapping.path $mapping.target
}

$systemDrive = Get-PSDrive -Name $TargetSystemDrive.Substring(0, 1) -ErrorAction Stop
$freeByteLengthBefore = [long]$systemDrive.Free
$reserveBytes = [long]5GB
Assert-Materialize ($freeByteLengthBefore -gt ($requiredCopyBytes + $reserveBytes)) `
    'micron_materialization_space_insufficient'
Write-Host ("Materialization preflight passed: {0} mappings, {1:N2} GiB, {2:N2} GiB free" -f
    $profileMappings.Count, ($requiredCopyBytes / 1GB), ($freeByteLengthBefore / 1GB))

$preflightResult = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/samsung-project-state-micron-materialization-preflight/v1'
    preflightAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    migrationUid = $MigrationUid
    targetSystemDrive = $TargetSystemDrive
    migrationRoot = $migrationRoot
    activeManifestSha256 = [string]$finalReceipt.activeManifestSha256
    activeManifestMemberCount = $script:ActiveManifestRows.Count
    profileMappingCount = $profileMappings.Count
    requiredCopyByteLength = $requiredCopyBytes
    reserveByteLength = $reserveBytes
    freeByteLength = $freeByteLengthBefore
    profilePreflight = $profilePreflight.ToArray()
    directFilePreflight = $directFilePreflight.ToArray()
    junctionPreflightPassed = $true
    mutationPerformed = $false
    verdictCode = 'ready_for_micron_materialization'
}
if ($PreflightOnly) {
    $preflightResult | ConvertTo-Json -Depth 8
    return
}

$script:Robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
$copyResultsList = New-Object System.Collections.Generic.List[object]
foreach ($mapping in $profileMappings) {
    $copyResultsList.Add((Invoke-ProfileCopy $mapping.role $mapping.source $mapping.target))
}
$copyResults = $copyResultsList.ToArray()

[IO.Directory]::CreateDirectory($importRoot) | Out-Null
[IO.Directory]::CreateDirectory($nugetTargetRoot) | Out-Null
$directFileResults = New-Object System.Collections.Generic.List[object]
foreach ($mapping in $directFilePreflight) {
    [IO.File]::Copy($mapping.source, $mapping.target, $true)
    $targetItem = Get-Item -LiteralPath $mapping.target -Force
    $targetSha256 = (Get-FileHash -LiteralPath $mapping.target -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Materialize ($targetItem.Length -eq $mapping.byteLength -and
        $targetSha256 -ceq $mapping.sha256) `
        "micron_materialization_direct_target_hash_mismatch:$($mapping.role)"
    $directFileResults.Add([pscustomobject]@{
        role = $mapping.role
        source = $mapping.source
        target = $mapping.target
        byteLength = $mapping.byteLength
        sha256 = $mapping.sha256
        targetSha256Verified = $true
    })
}

foreach ($mapping in $junctionMappings) {
    New-ApprovedJunction $mapping.path $mapping.target
}

[Environment]::SetEnvironmentVariable('CODEX_HOME', $codexHomeTarget, 'User')
[Environment]::SetEnvironmentVariable('CODEX_SQLITE_HOME', $codexHomeTarget, 'User')
Assert-Materialize ([Environment]::GetEnvironmentVariable('CODEX_HOME', 'User') -ceq $codexHomeTarget) `
    'micron_materialization_codex_home_environment_failed'
Assert-Materialize ([Environment]::GetEnvironmentVariable('CODEX_SQLITE_HOME', 'User') -ceq $codexHomeTarget) `
    'micron_materialization_codex_sqlite_home_environment_failed'

$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
foreach ($target in @($githubTarget, $codexHomeTarget, $documentsCodexTarget, $openAiLocalTarget,
        $powerShellHistoryTarget, $importedDesktopTarget, $importRoot, $nugetTargetRoot)) {
    & $icacls $target /inheritance:e /grant:r "${env:USERDOMAIN}\${env:USERNAME}:(OI)(CI)F" /T /C /Q | Out-Null
    Assert-Materialize ($LASTEXITCODE -eq 0) "micron_materialization_acl_failed:$target"
}

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/samsung-project-state-micron-materialization/v1'
    materializedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    migrationUid = $MigrationUid
    finalDeltaReceiptSha256 = (Get-FileHash -LiteralPath $finalReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    repoPath = $repoTarget
    codexHomePath = $codexHomeTarget
    codexSqliteHomePath = $codexHomeTarget
    codexAuthCopied = (Test-Path -LiteralPath (Join-Path $codexHomeTarget 'auth.json') -PathType Leaf)
    codexSessionFileCount = if (Test-Path -LiteralPath (Join-Path $codexHomeTarget 'sessions') -PathType Container) {
        @(Get-ChildItem -LiteralPath (Join-Path $codexHomeTarget 'sessions') -Recurse -File).Count
    }
    else { 0 }
    compatibilityJunctionCount = 4
    materializationPreflightPassed = $true
    requiredCopyByteLength = $requiredCopyBytes
    reserveByteLength = $reserveBytes
    freeByteLengthBeforeMaterialization = $freeByteLengthBefore
    profilePreflight = $profilePreflight.ToArray()
    allProfileTargetMembersSha256Verified = (@($copyResults | Where-Object {
        $_.allTargetMembersSha256Verified -ne $true
    }).Count -eq 0)
    allDirectFileTargetsSha256Verified = (@($directFileResults | Where-Object {
        $_.targetSha256Verified -ne $true
    }).Count -eq 0)
    appWebStateImported = $false
    appWebStatePreservedInMigration = $true
    micronExistingNikkeModified = $false
    micronExistingNllRuntimeModified = $false
    samsungSourceDeletionPerformed = $false
    copyResults = $copyResults
    directFileResults = $directFileResults.ToArray()
    nextStepCode = 'install_or_start_codex_relogin_if_required_and_verify_threads'
}
$receiptPath = Join-Path $migrationRoot 'micron-materialization.receipt.json'
Write-Utf8Json $receiptPath $receipt

[ordered]@{
    ReceiptPath = $receiptPath
    ReceiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    RepoPath = $repoTarget
    CodexHomePath = $codexHomeTarget
    CodexSessionFileCount = $receipt.codexSessionFileCount
    NextStepCode = $receipt.nextStepCode
} | ConvertTo-Json -Depth 5
