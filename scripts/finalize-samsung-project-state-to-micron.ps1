#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$MigrationUid = '265861b9-9ff0-4e01-b409-7ce97c53aad1'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Finalize {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-Utf8Json {
    param([string]$Path, $Value)
    $json = ($Value | ConvertTo-Json -Depth 10) + "`n"
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Invoke-ExactMirror {
    param([string]$Source, [string]$Target)

    Assert-Finalize (Test-Path -LiteralPath $Source -PathType Container) `
        "samsung_to_micron_final_source_missing:$Source"
    Assert-Finalize (Test-Path -LiteralPath $Target -PathType Container) `
        "samsung_to_micron_final_target_missing:$Target"
    $common = @(
        $Source, $Target,
        '/MIR', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/SL', '/Z',
        '/R:1', '/W:1', '/J', '/MT:8', '/NP', '/NFL', '/NDL', '/NJH', '/BYTES'
    )
    & $script:Robocopy @common | Out-Null
    $copyExitCode = $LASTEXITCODE
    Assert-Finalize ($copyExitCode -le 7) `
        "samsung_to_micron_final_robocopy_failed:${copyExitCode}:$Source"

    $audit = @($Source, $Target, '/MIR', '/L', '/COPY:DAT', '/DCOPY:DAT', '/XJ', '/SL',
        '/R:0', '/W:0', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    & $script:Robocopy @audit | Out-Null
    $auditExitCode = $LASTEXITCODE
    Assert-Finalize ($auditExitCode -eq 0) `
        "samsung_to_micron_final_mirror_audit_failed:${auditExitCode}:$Source"

    [pscustomobject]@{
        source = $Source
        target = $Target
        sourcePresentDuringFinalDelta = $true
        stagedTargetPreserved = $false
        copyExitCode = $copyExitCode
        mirrorAuditExitCode = $auditExitCode
    }
}

function Add-TreeHashes {
    param(
        [string]$Role,
        [string]$Source,
        [string]$Target,
        [Text.StringBuilder]$Builder
    )

    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $targetRoot = [IO.Path]::GetFullPath($Target).TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -Force -File -ErrorAction Stop |
        Sort-Object FullName)
    foreach ($sourceFile in $files) {
        $relative = $sourceFile.FullName.Substring($sourceRoot.Length).TrimStart('\')
        $targetFile = [IO.Path]::GetFullPath((Join-Path $targetRoot $relative))
        Assert-Finalize ($targetFile.StartsWith($targetRoot + '\', [StringComparison]::OrdinalIgnoreCase)) `
            'samsung_to_micron_final_hash_target_escaped'
        Assert-Finalize (Test-Path -LiteralPath $targetFile -PathType Leaf) `
            "samsung_to_micron_final_hash_target_missing:$relative"
        $targetItem = Get-Item -LiteralPath $targetFile -Force
        $sourceSha256 = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $targetSha256 = (Get-FileHash -LiteralPath $targetFile -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-Finalize ($sourceFile.Length -eq $targetItem.Length -and $sourceSha256 -ceq $targetSha256) `
            "samsung_to_micron_final_hash_mismatch:${Role}:$relative"
        [void]$Builder.Append($Role).Append("`t").Append($relative.Replace('\', '/')).Append("`t").
            Append([long]$sourceFile.Length).Append("`t").Append($targetSha256).Append("`n")
    }
    $files.Count
}

$running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match '(?i)^(chatgpt|codex|codex-code-mode-host|codex-command-runner.*)$'
})
Assert-Finalize ($running.Count -eq 0) 'samsung_to_micron_codex_process_still_running'

$approvedParent = [IO.Path]::GetFullPath('E:\NLL\Migrations\SamsungToMicron\v1').TrimEnd('\')
$migrationRoot = [IO.Path]::GetFullPath((Join-Path $approvedParent $MigrationUid)).TrimEnd('\')
Assert-Finalize ($migrationRoot.StartsWith($approvedParent + '\', [StringComparison]::OrdinalIgnoreCase)) `
    'samsung_to_micron_final_target_outside_approved_parent'
$liveReceiptPath = Join-Path $migrationRoot 'live-staging.receipt.json'
Assert-Finalize (Test-Path -LiteralPath $liveReceiptPath -PathType Leaf) `
    'samsung_to_micron_live_staging_receipt_missing'
$liveReceipt = Get-Content -LiteralPath $liveReceiptPath -Raw | ConvertFrom-Json
Assert-Finalize ($liveReceipt.contractId -ceq 'nll/samsung-project-state-to-micron-live-staging/v1' -and
    $liveReceipt.migrationUid -ceq $MigrationUid -and
    $liveReceipt.finalDeltaRequired -eq $true -and
    $liveReceipt.sourceDeletionPerformed -eq $false) `
    'samsung_to_micron_live_staging_receipt_invalid'
$stableReceiptPath = Join-Path $migrationRoot 'stable-content.verification.receipt.json'
Assert-Finalize (Test-Path -LiteralPath $stableReceiptPath -PathType Leaf) `
    'samsung_to_micron_stable_verification_receipt_missing'
$stableReceipt = Get-Content -LiteralPath $stableReceiptPath -Raw | ConvertFrom-Json
Assert-Finalize ($stableReceipt.contractId -ceq 'nll/samsung-project-state-to-micron-stable-content-verification/v1' -and
    $stableReceipt.migrationUid -ceq $MigrationUid -and
    $stableReceipt.allStableMembersSha256Verified -eq $true -and
    $stableReceipt.sourceDeletionPerformed -eq $false) `
    'samsung_to_micron_stable_verification_receipt_invalid'

$script:Robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
$activeMappings = @(
    [pscustomobject]@{ role = 'github_workspaces'; source = 'C:\Users\zih44\Documents\Github'; target = Join-Path $migrationRoot 'Operational\Github'; required = $true },
    [pscustomobject]@{ role = 'codex_home'; source = 'C:\Users\zih44\.codex'; target = Join-Path $migrationRoot 'Codex\CODEX_HOME'; required = $true },
    [pscustomobject]@{ role = 'codex_local'; source = 'C:\Users\zih44\AppData\Local\Codex'; target = Join-Path $migrationRoot 'Codex\AppDataLocalCodex'; required = $false },
    [pscustomobject]@{ role = 'openai_local'; source = 'C:\Users\zih44\AppData\Local\OpenAI'; target = Join-Path $migrationRoot 'Codex\AppDataLocalOpenAI'; required = $true },
    [pscustomobject]@{ role = 'codex_roaming'; source = 'C:\Users\zih44\AppData\Roaming\Codex'; target = Join-Path $migrationRoot 'Codex\AppDataRoamingCodex'; required = $false },
    [pscustomobject]@{ role = 'codex_documents'; source = 'C:\Users\zih44\Documents\Codex'; target = Join-Path $migrationRoot 'Codex\DocumentsCodex'; required = $true },
    [pscustomobject]@{ role = 'powershell_history'; source = 'C:\Users\zih44\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine'; target = Join-Path $migrationRoot 'Sensitive\DeveloperProfile\PowerShell\PSReadLine'; required = $true },
    [pscustomobject]@{ role = 'nuget_profile'; source = 'C:\Users\zih44\AppData\Roaming\NuGet'; target = Join-Path $migrationRoot 'Sensitive\DeveloperProfile\NuGet'; required = $true },
    [pscustomobject]@{ role = 'desktop_auxiliary'; source = 'C:\Users\zih44\Desktop'; target = Join-Path $migrationRoot 'AuxiliaryProfile\Desktop'; required = $true }
)
$mappingPreflight = New-Object System.Collections.Generic.List[object]
Write-Host 'Preflighting all active mappings before final-delta mutation'
foreach ($mapping in $activeMappings) {
    $sourcePresent = Test-Path -LiteralPath $mapping.source -PathType Container
    $targetPresent = Test-Path -LiteralPath $mapping.target -PathType Container
    Assert-Finalize ($sourcePresent -or -not $mapping.required) `
        "samsung_to_micron_final_source_missing:$($mapping.source)"
    Assert-Finalize $targetPresent `
        "samsung_to_micron_final_target_missing:$($mapping.target)"
    $mappingPreflight.Add([pscustomobject]@{
        role = $mapping.role
        source = $mapping.source
        target = $mapping.target
        required = $mapping.required
        sourcePresent = $sourcePresent
        targetPresent = $targetPresent
    })
}
$mirrorResults = New-Object System.Collections.Generic.List[object]
$presentMappings = New-Object System.Collections.Generic.List[object]
$optionalSourceAbsentRoles = New-Object System.Collections.Generic.List[string]
foreach ($mapping in $activeMappings) {
    Write-Host "Mirroring active mapping: $($mapping.role)"
    $preflight = @($mappingPreflight | Where-Object { $_.role -ceq $mapping.role })
    Assert-Finalize ($preflight.Count -eq 1) `
        "samsung_to_micron_final_mapping_preflight_missing:$($mapping.role)"
    if (-not $preflight[0].sourcePresent) {
        Write-Host "Preserving staged snapshot for absent optional mapping: $($mapping.role)"
        $optionalSourceAbsentRoles.Add([string]$mapping.role)
        $mirrorResults.Add([pscustomobject]@{
            source = $mapping.source
            target = $mapping.target
            sourcePresentDuringFinalDelta = $false
            stagedTargetPreserved = $true
            copyExitCode = $null
            mirrorAuditExitCode = $null
        })
        continue
    }
    $mirrorResults.Add((Invoke-ExactMirror $mapping.source $mapping.target))
    $presentMappings.Add($mapping)
}

$builder = [Text.StringBuilder]::new()
$hashCounts = [ordered]@{}
foreach ($mapping in $activeMappings) {
    $hashCounts[$mapping.role] = 0
}
foreach ($mapping in $presentMappings) {
    Write-Host "SHA-256 verifying active mapping: $($mapping.role)"
    $hashCounts[$mapping.role] = Add-TreeHashes $mapping.role $mapping.source $mapping.target $builder
}
$activeManifestPath = Join-Path $migrationRoot 'final-active-content.manifest.tsv'
[IO.File]::WriteAllText($activeManifestPath, $builder.ToString(), [Text.UTF8Encoding]::new($false))

$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/samsung-project-state-to-micron-final-delta/v1'
    finalizedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    migrationUid = $MigrationUid
    migrationRoot = $migrationRoot
    liveStagingReceiptSha256 = (Get-FileHash -LiteralPath $liveReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    stableVerificationReceiptSha256 = (Get-FileHash -LiteralPath $stableReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    activeMappingCount = $activeMappings.Count
    mirroredActiveMappingCount = $presentMappings.Count
    optionalSourceAbsentCount = $optionalSourceAbsentRoles.Count
    optionalSourceAbsentRoles = $optionalSourceAbsentRoles.ToArray()
    absentOptionalStagedSnapshotsPreserved = $true
    mappingPreflight = $mappingPreflight.ToArray()
    activeManifestMemberCount = [long](($hashCounts.Values | Measure-Object -Sum).Sum)
    activeManifestByteLength = (Get-Item -LiteralPath $activeManifestPath).Length
    activeManifestSha256 = (Get-FileHash -LiteralPath $activeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    allActiveMembersSha256Verified = $true
    codexProcessCountDuringFinalDelta = 0
    sqliteAndWalCopiedCold = $true
    targetAclHardeningPending = $false
    sourceDeletionPerformed = $false
    materializationPending = $true
    mirrorResults = $mirrorResults.ToArray()
    hashCounts = $hashCounts
    nextStepCode = 'boot_micron_materialize_then_validate_before_samsung_cleanup'
}
$receiptPath = Join-Path $migrationRoot 'final-delta.receipt.json'
Write-Utf8Json $receiptPath $receipt

$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
Write-Host 'Hardening migration staging ACLs'
& $icacls $migrationRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C /Q | Out-Null
Assert-Finalize ($LASTEXITCODE -eq 0) 'samsung_to_micron_final_acl_hardening_failed'

[ordered]@{
    MigrationRoot = $migrationRoot
    ReceiptPath = $receiptPath
    ReceiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    ActiveManifestSha256 = $receipt.activeManifestSha256
    ActiveManifestMemberCount = $receipt.activeManifestMemberCount
    SourceDeletionPerformed = $false
    NextStepCode = $receipt.nextStepCode
} | ConvertTo-Json -Depth 5
