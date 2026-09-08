#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [switch]$AuditOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        (($algorithm.ComputeHash($Bytes) | ForEach-Object {
                    $_.ToString('x2')
                }) -join '')
    }
    finally { $algorithm.Dispose() }
}

function Test-Digest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText(
        $Path, $Text, [Text.UTF8Encoding]::new($false)
    )
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    try {
        Write-Utf8NoBom $temporary `
            (($Value | ConvertTo-Json -Depth 16) + [Environment]::NewLine)
        Move-Item -LiteralPath $temporary -Destination $Path
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Assert-PowerShellSyntax {
    param([string]$Path, [string]$FailureCode)
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors
    ) | Out-Null
    Assert-True (@($errors).Count -eq 0) $FailureCode
}

function Replace-ExactOnce {
    param(
        [string]$Text,
        [string]$OldValue,
        [string]$NewValue,
        [string]$FailureCode
    )
    $count = ([regex]::Matches(
            $Text, [regex]::Escape($OldValue)
        )).Count
    Assert-True ($count -eq 1) ($FailureCode + ':match_count=' + $count)
    $Text.Replace($OldValue, $NewValue)
}

function Get-DerivedToolText {
    param(
        [string]$SourcePath,
        [System.Collections.IDictionary]$Replacements
    )
    $text = [IO.File]::ReadAllText(
        $SourcePath, [Text.Encoding]::UTF8
    ).Replace("`r`n", "`n")
    foreach ($oldValue in @($Replacements.Keys | Sort-Object)) {
        $text = Replace-ExactOnce $text $oldValue `
            ([string]$Replacements[$oldValue]) `
            'phase3b2_regroup_v3_tool_projection_invalid'
    }
    $text
}

function Get-CanonicalManifest {
    param([string]$Root)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $prefix = $resolvedRoot + '\'
    $membersByPath =
        [Collections.Generic.SortedDictionary[string, object]]::new(
            [StringComparer]::Ordinal
        )
    foreach ($entry in @(Get-ChildItem -LiteralPath $resolvedRoot -Force)) {
        if ($entry.Name -in @('cache', 'logs')) { continue }
        if ($entry.PSIsContainer) {
            Assert-True (-not $entry.LinkType) `
                'phase3b2_regroup_v3_unexpected_runtime_link'
            foreach ($file in @(Get-ChildItem -LiteralPath $entry.FullName `
                    -File -Recurse -Force)) {
                $relative = $file.FullName.Substring($prefix.Length).
                    Replace('\', '/')
                $membersByPath.Add($relative, [pscustomobject]@{
                        relativePath = $relative
                        byteLength = [long]$file.Length
                        sha256 = Get-Sha256Hex $file.FullName
                    })
            }
        }
        elseif ($entry.Name -notin @(
                'epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal'
            )) {
            $relative = $entry.FullName.Substring($prefix.Length).
                Replace('\', '/')
            $membersByPath.Add($relative, [pscustomobject]@{
                    relativePath = $relative
                    byteLength = [long]$entry.Length
                    sha256 = Get-Sha256Hex $entry.FullName
                })
        }
    }

    $members = @($membersByPath.Values)
    $text = (@($members | ForEach-Object {
                '{0}`t{1}`t{2}' -f
                    $_.relativePath, $_.byteLength, $_.sha256
            }) -join "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    [pscustomobject]@{
        members = $members
        text = $text
        memberCount = $members.Count
        contentByteLength = [long](
            ($members | Measure-Object byteLength -Sum).Sum
        )
        manifestByteLength = [long]$bytes.Length
        manifestSha256 = Get-BytesSha256Hex $bytes
    }
}

function Get-SourceManifest {
    param([string]$Root, [string[]]$RelativePaths)
    $membersByPath =
        [Collections.Generic.SortedDictionary[string, object]]::new(
            [StringComparer]::Ordinal
        )
    foreach ($relativePath in $RelativePaths) {
        $path = Join-Path $Root $relativePath
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
            'phase3b2_regroup_v3_source_member_missing'
        $normalizedPath = $relativePath.Replace('\', '/')
        $membersByPath.Add($normalizedPath, [pscustomobject]@{
                relativePath = $normalizedPath
                byteLength = [long](Get-Item -LiteralPath $path).Length
                sha256 = Get-Sha256Hex $path
            })
    }
    $members = @($membersByPath.Values)
    $text = (@($members | ForEach-Object {
                '{0}`t{1}`t{2}' -f
                    $_.relativePath, $_.byteLength, $_.sha256
            }) -join "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    [pscustomobject]@{
        members = $members
        text = $text
        memberCount = $members.Count
        byteLength = [long]$bytes.Length
        sha256 = Get-BytesSha256Hex $bytes
    }
}

function Get-StoredManifest {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) `
        'phase3b2_regroup_v3_stored_manifest_missing'
    $membersByPath =
        [Collections.Generic.SortedDictionary[string, object]]::new(
            [StringComparer]::Ordinal
        )
    foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8)) {
        if (-not $line) { continue }
        $parts = $line.Split(
            [string[]]@('`t'), [StringSplitOptions]::None
        )
        Assert-True ($parts.Count -eq 3 -and
            $parts[0] -and $parts[1] -cmatch '^\d+$' -and
            $parts[2] -cmatch '^[0-9a-f]{64}$') `
            'phase3b2_regroup_v3_stored_manifest_shape_invalid'
        $membersByPath.Add([string]$parts[0], [pscustomobject]@{
                relativePath = [string]$parts[0]
                byteLength = [long]$parts[1]
                sha256 = [string]$parts[2]
            })
    }
    $members = @($membersByPath.Values)
    $text = (@($members | ForEach-Object {
                '{0}`t{1}`t{2}' -f
                    $_.relativePath, $_.byteLength, $_.sha256
            }) -join "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    [pscustomobject]@{
        members = $members
        text = $text
        memberCount = $members.Count
        manifestByteLength = [long]$bytes.Length
        manifestSha256 = Get-BytesSha256Hex $bytes
    }
}

function New-ExactJunction {
    param([string]$Path, [string]$Target, [string]$FailureCode)
    & $env:ComSpec /d /c mklink /J $Path $Target | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) $FailureCode
    $item = Get-Item -LiteralPath $Path -Force
    Assert-True (
        $item.LinkType -ceq 'Junction' -and
        [string]$item.Target -ceq $Target
    ) ($FailureCode + '_verification_failed')
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($AuditOnly -or $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_regroup_v3_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_regroup_v3_wrong_samsung_boundary'

$micronDrive = $MicronDriveLetter + ':'
if ($AuditOnly) {
    Assert-True (
        $micronDrive -cne $env:SystemDrive -and
        (Test-Path -LiteralPath ($micronDrive + '\') -PathType Container)
    ) 'phase3b2_regroup_v3_audit_volume_boundary_invalid'
}
else {
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
    Assert-True (
        $micronDrive -cne $env:SystemDrive -and
        $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
        $micronDisk.FriendlyName -like 'Micron_2200*'
    ) 'phase3b2_regroup_v3_physical_boundary_invalid'
}
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_regroup_v3_runtime_not_cold'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$candidateDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$v2RuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v2'
$v3RuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v3'
$v2EvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRTP2'
$v3EvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRTP3'
$v3DeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRTP3D'
$v2DeploymentReceiptPath = Join-Path $micronDrive `
    'NLL\E\P3SRTP2D\deployment.receipt.json'
$v2RuntimeManifestPath = Join-Path $micronDrive `
    'NLL\E\P3SRTP2D\v2-runtime.manifest.tsv'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$protectedBase =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidRegroupSemantics-v3'
$dBackupSealPath =
    'D:\NikkeLocalLab\Backups\phase3b2-lobby-en-d830a90d-20260826T103327Z\metadata\backup.seal.receipt.json'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'

$v2ToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v2.ps1'
    innerStart =
        'start-phase3b2-epinel-solo-raid-trial-practice-v2-in-micron.ps1'
    outerCompletion =
        'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v2.ps1'
    innerCompletion =
        'complete-phase3b2-epinel-solo-raid-trial-practice-v2-in-micron.ps1'
}
$v3ToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1'
    innerStart =
        'start-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1'
    outerCompletion =
        'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1'
    innerCompletion =
        'complete-phase3b2-epinel-solo-raid-trial-practice-v3-in-micron.ps1'
}

$expectedDatabaseByteLength = 1396709L
$expectedDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedServerExeByteLength = 162304L
$expectedServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedV2ServerDllByteLength = 15377408L
$expectedV2ServerDllSha256 =
    '2366129e5974291ce7ae61d5c10f12991b01fc6b5752b6dcb2d60a551177cd33'
$expectedCandidateDllByteLength = 15377920L
$expectedCandidateDllSha256 =
    '79e499169b42e58e73677fc99c77217f15d6056529bd6f583ce2152127ec28be'
$expectedSourceManifestSha256 =
    'b1061afda20654421c527330ae5bd739efb78f027fe6ae66d48d7a276999c66c'
$expectedExternalHead =
    '317c4f352b91e76470e2b035ada426ff443f9de4'
$expectedV2RuntimeManifestSha256 =
    '53dfe3b3e0b7d626277ef73a4b09620376d0ec7ce536c6905a8bd6196e7358ec'
$expectedV2DeploymentReceiptSha256 =
    '2b83efb0f45ae3c78a2511702986c453f59a86b64849b9b353c062a3c125aa8f'
$expectedV2CompletionReceiptSha256 =
    'b4670f1bc7760a3fe415d16044bb2ebeb20d166d74dc6f5b34c02f282fd6de64'
$expectedDBackupSealSha256 =
    'e4c1f9af044387f1624a828421800b29c9a0aa4c015f4e82f3534f70484ea613'
$expectedV2ToolDigests = [ordered]@{
    outerStart = 'a4cbbe8b5ee131b10a299696b6fe4bc11e461daf4daec14452f97100fff1a618'
    innerStart = '329a95da91adbe2dccec00407b958f68c2a3805b70a5a650888b414c34c17b2a'
    outerCompletion = 'a515c179ad5d8abf75b2a164045769504e0691603e227e27c5667f2926a81f87'
    innerCompletion = '1713c0f54f05514ad6c07dd7b86517f44e075b7633822ad185e5f1bcb2a8e86e'
}

$sourcePaths = @(
    'EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidPeriodProvider.cs',
    'EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidRouteExecutor.cs',
    'EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidRoutePolicy.cs',
    'EpinelPS/LobbyServer/Soloraid/ClosePractice.cs',
    'EpinelPS/LobbyServer/Soloraid/GetLevelPractice.cs',
    'EpinelPS/LobbyServer/Soloraid/OpenPractice.cs',
    'EpinelPS/LobbyServer/Soloraid/SetDamagePractice.cs',
    'EpinelPS/LobbyServer/Soloraid/SoloRaidHelper.cs',
    'EpinelPS/SoloRaidSelection/SoloRaidManagerSelectionResolver.cs',
    'tests/EpinelPS.SelectedManager.Tests/BaselineRouteAuditTests.cs',
    'tests/EpinelPS.SelectedManager.Tests/ClassicSoloRaidPeriodProviderTests.cs',
    'tests/EpinelPS.SelectedManager.Tests/RoutePolicyFixture.cs',
    'tests/EpinelPS.SelectedManager.Tests/RoutePolicyRedTests.cs',
    'tests/EpinelPS.SelectedManager.Tests/SelectionPersistenceTests.cs',
    'tests/EpinelPS.SelectedManager.Tests/SoloRaidCompatibilityProjectionTests.cs',
    'tests/EpinelPS.SelectedManager.Tests/SoloRaidRetrySemanticsTests.cs',
    'tests/EpinelPS.SelectedManager.Tests/TrialPracticeWireOrderCharacterizationTests.cs',
    'tests/EpinelPS.SelectedManager.Tests/WireShapeCharacterizationTests.cs'
)

$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
$gitCandidates = @(@(
    $(if ($gitCommand) { $gitCommand.Source }),
    'C:\Users\zih44\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe',
    (Join-Path $env:ProgramFiles 'Git\cmd\git.exe')
) | Where-Object {
    $_ -and (Test-Path -LiteralPath $_ -PathType Leaf)
} | Select-Object -Unique)
Assert-True (@($gitCandidates).Count -ge 1) `
    'phase3b2_regroup_v3_git_missing'
$gitPath = [string]$gitCandidates[0]
$gitSafeDirectoryArgument = 'safe.directory=' +
    $externalRoot.Replace('\', '/')
$observedExternalHeadLines = @(& $gitPath -c $gitSafeDirectoryArgument `
        -C $externalRoot rev-parse HEAD)
Assert-True ($LASTEXITCODE -eq 0 -and
    $observedExternalHeadLines.Count -eq 1) `
    'phase3b2_regroup_v3_external_head_read_failed'
$observedExternalHead = [string]$observedExternalHeadLines[0]
Assert-True ($observedExternalHead -ceq $expectedExternalHead) `
    'phase3b2_regroup_v3_external_head_invalid'
$changedExternalPaths = @(& $gitPath -c $gitSafeDirectoryArgument `
        -C $externalRoot status --porcelain `
        --untracked-files=all | ForEach-Object {
            if ($_.Length -ge 4) {
                $_.Substring(3).Replace('\', '/')
            }
        } | Where-Object { $_ } | Sort-Object -Unique)
Assert-True ($LASTEXITCODE -eq 0 -and
    @($changedExternalPaths | Where-Object {
            $_ -notin $sourcePaths
        }).Count -eq 0 -and
    'EpinelPS/LobbyServer/Soloraid/SoloRaidHelper.cs' -in
        $changedExternalPaths -and
    'EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidRouteExecutor.cs' -in
        $changedExternalPaths -and
    'tests/EpinelPS.SelectedManager.Tests/SoloRaidRetrySemanticsTests.cs' -in
        $changedExternalPaths) `
    'phase3b2_regroup_v3_external_change_scope_invalid'
$sourceManifest = Get-SourceManifest -Root $externalRoot `
    -RelativePaths $sourcePaths
Assert-True (
    $sourceManifest.memberCount -eq 18 -and
    $sourceManifest.sha256 -ceq $expectedSourceManifestSha256
) 'phase3b2_regroup_v3_source_manifest_invalid'

$v2ToolPaths = [ordered]@{}
foreach ($role in $v2ToolNames.Keys) {
    $path = Join-Path $toolRoot $v2ToolNames[$role]
    Assert-True (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Sha256Hex $path) -ceq $expectedV2ToolDigests[$role]
    ) 'phase3b2_regroup_v3_v2_tool_drifted'
    $v2ToolPaths[$role] = $path
}

Assert-True (
    (Test-Digest $candidateDllPath $expectedCandidateDllByteLength `
        $expectedCandidateDllSha256) -and
    (Test-Digest (Join-Path $v2RuntimeRoot 'db.json') `
        $expectedDatabaseByteLength $expectedDatabaseSha256) -and
    (Test-Digest (Join-Path $v2RuntimeRoot 'EpinelPS.exe') `
        $expectedServerExeByteLength $expectedServerExeSha256) -and
    (Test-Digest (Join-Path $v2RuntimeRoot 'EpinelPS.dll') `
        $expectedV2ServerDllByteLength $expectedV2ServerDllSha256) -and
    (Test-Digest $v2DeploymentReceiptPath 5262L `
        $expectedV2DeploymentReceiptSha256) -and
    (Test-Digest $dBackupSealPath 2177L $expectedDBackupSealSha256) -and
    (Test-Path -LiteralPath $v2EvidenceRoot -PathType Container) -and
    -not (Test-Path -LiteralPath (Join-Path $v2EvidenceRoot `
            'active-run.pointer.json')) -and
    @(Get-ChildItem -LiteralPath $v2RuntimeRoot -File | Where-Object {
            $_.Name -in @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal')
        }).Count -eq 0
) 'phase3b2_regroup_v3_input_missing_or_drifted'

$v2Cache = Get-Item -LiteralPath (Join-Path $v2RuntimeRoot 'cache') -Force
Assert-True (
    $v2Cache.LinkType -ceq 'Junction' -and
    [string]$v2Cache.Target -ceq $bootCacheTarget
) 'phase3b2_regroup_v3_v2_cache_link_invalid'

$v2Runs = @(Get-ChildItem -LiteralPath $v2EvidenceRoot -Directory)
Assert-True ($v2Runs.Count -eq 1) `
    'phase3b2_regroup_v3_v2_run_cardinality_invalid'
$v2CompletionPath = Join-Path $v2Runs[0].FullName 'completion.receipt.json'
Assert-True (Test-Digest $v2CompletionPath 1891L `
        $expectedV2CompletionReceiptSha256) `
    'phase3b2_regroup_v3_v2_completion_missing_or_drifted'
$v2Completion = Get-Content -LiteralPath $v2CompletionPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $v2Completion.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-materialization-repair-completion/v2' -and
    $v2Completion.observedStageCode -ceq 'season26_challenge_battle' -and
    $v2Completion.outcomeCode -ceq 'success' -and
    $v2Completion.databaseRestored -and
    $v2Completion.runtimeColdAfterCompletion
) 'phase3b2_regroup_v3_v2_completion_invalid'

$v2ManifestBefore = Get-CanonicalManifest $v2RuntimeRoot
$v2StoredManifest = Get-StoredManifest $v2RuntimeManifestPath
Assert-True (
    (Get-Sha256Hex $v2RuntimeManifestPath) -ceq
        $expectedV2RuntimeManifestSha256 -and
    $v2StoredManifest.memberCount -eq $v2ManifestBefore.memberCount -and
    $v2StoredManifest.manifestSha256 -ceq
        $v2ManifestBefore.manifestSha256
) `
    'phase3b2_regroup_v3_v2_runtime_manifest_invalid'
$dSealBefore = Get-Sha256Hex $dBackupSealPath

$toolStagingRoot = Join-Path $env:TEMP (
    'NLL-P3SRTP3-' + [Guid]::NewGuid().ToString('N')
)
$runtimeStagingRoot = $null
$deploymentStagingRoot = $null
New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
try {
    $toolReplacements = [ordered]@{
        'EpinelPS-SoloRaidTrialPractice-v2' =
            'EpinelPS-SoloRaidTrialPractice-v3'
        'P3SRTP2' = 'P3SRTP3'
        '2366129e5974291ce7ae61d5c10f12991b01fc6b5752b6dcb2d60a551177cd33' =
            $expectedCandidateDllSha256
        '15377408L' = '15377920L'
        'a81d45a6af9d94095cf1ca3400150ccee7a650796be4f2c8379c418de7d66bb2' =
            $expectedSourceManifestSha256
        'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v2.ps1' =
            $v3ToolNames.outerStart
        'start-phase3b2-epinel-solo-raid-trial-practice-v2-in-micron.ps1' =
            $v3ToolNames.innerStart
        'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v2.ps1' =
            $v3ToolNames.outerCompletion
        'complete-phase3b2-epinel-solo-raid-trial-practice-v2-in-micron.ps1' =
            $v3ToolNames.innerCompletion
        'nll/phase3b2-epinel-solo-raid-materialization-repair-start/v2' =
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-start/v3'
        'nll/phase3b2-epinel-solo-raid-materialization-repair-completion/v2' =
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-completion/v3'
        'nll/phase3b2-epinel-solo-raid-materialization-repair-validation/v2' =
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-validation/v3'
        'nll/phase3b2-epinel-solo-raid-materialization-repair-failure/v2' =
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-failure/v3'
    }
    $roleReplacements = [ordered]@{
        outerStart = @(
            'EpinelPS-SoloRaidTrialPractice-v2', 'P3SRTP2',
            '2366129e5974291ce7ae61d5c10f12991b01fc6b5752b6dcb2d60a551177cd33',
            '15377408L',
            'a81d45a6af9d94095cf1ca3400150ccee7a650796be4f2c8379c418de7d66bb2',
            'start-phase3b2-epinel-solo-raid-trial-practice-v2-in-micron.ps1',
            'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v2.ps1',
            'nll/phase3b2-epinel-solo-raid-materialization-repair-start/v2',
            'nll/phase3b2-epinel-solo-raid-materialization-repair-completion/v2',
            'nll/phase3b2-epinel-solo-raid-materialization-repair-validation/v2'
        )
        innerStart = @(
            'EpinelPS-SoloRaidTrialPractice-v2', 'P3SRTP2',
            '2366129e5974291ce7ae61d5c10f12991b01fc6b5752b6dcb2d60a551177cd33',
            'nll/phase3b2-epinel-solo-raid-materialization-repair-start/v2',
            'nll/phase3b2-epinel-solo-raid-materialization-repair-failure/v2'
        )
        outerCompletion = @(
            'complete-phase3b2-epinel-solo-raid-trial-practice-v2-in-micron.ps1'
        )
        innerCompletion = @(
            'EpinelPS-SoloRaidTrialPractice-v2', 'P3SRTP2',
            'nll/phase3b2-epinel-solo-raid-materialization-repair-start/v2',
            'nll/phase3b2-epinel-solo-raid-materialization-repair-completion/v2'
        )
    }

    $stagedToolPaths = [ordered]@{}
    foreach ($role in $v2ToolNames.Keys) {
        $replacements = [ordered]@{}
        foreach ($oldValue in $roleReplacements[$role]) {
            $replacements[$oldValue] = $toolReplacements[$oldValue]
        }
        $stagedPath = Join-Path $toolStagingRoot $v3ToolNames[$role]
        Write-Utf8NoBom $stagedPath `
            (Get-DerivedToolText $v2ToolPaths[$role] $replacements)
        Assert-PowerShellSyntax $stagedPath `
            'phase3b2_regroup_v3_tool_syntax_invalid'
        $stagedToolPaths[$role] = $stagedPath
    }

    $toolManifest = @($stagedToolPaths.Keys | ForEach-Object {
            $path = $stagedToolPaths[$_]
            [pscustomobject]@{
                roleCode = $_
                leaf = [IO.Path]::GetFileName($path)
                byteLength = [long](Get-Item -LiteralPath $path).Length
                sha256 = Get-Sha256Hex $path
            }
        })

    if ($AuditOnly) {
        [pscustomobject]@{
            schemaVersion = 1
            contractId =
                'nll/phase3b2-epinel-solo-raid-regroup-semantics-deployment-audit/v3'
            auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            parentCompletionOutcomeCode = [string]$v2Completion.outcomeCode
            candidateServerDllByteLength = $expectedCandidateDllByteLength
            candidateServerDllSha256 = $expectedCandidateDllSha256
            sourceManifestMemberCount = $sourceManifest.memberCount
            sourceManifestSha256 = $sourceManifest.sha256
            projectedToolCount = $toolManifest.Count
            projectedTools = $toolManifest
            retryBattleResultCode = 4
            retryStateMutationExpected = $false
            newestFirstLogProjectionExpected = $true
            selectedManagerPassedCount = 100
            v2RuntimeModified = $false
            goldenRuntimeModified = $false
            dGoldenModified = $false
            deployable = $true
        } | ConvertTo-Json -Depth 8
        return
    }

    Assert-True (
        -not (Test-Path -LiteralPath $v3RuntimeRoot) -and
        -not (Test-Path -LiteralPath $v3EvidenceRoot) -and
        -not (Test-Path -LiteralPath $v3DeploymentRoot) -and
        @($v3ToolNames.Values | Where-Object {
                Test-Path -LiteralPath (Join-Path $toolRoot $_)
            }).Count -eq 0
    ) 'phase3b2_regroup_v3_target_collision'

    $deploymentUid = [Guid]::NewGuid().ToString('D')
    $runtimeStagingRoot = $v3RuntimeRoot + '.staging-' +
        [Guid]::NewGuid().ToString('N')
    $deploymentStagingRoot = $v3DeploymentRoot + '.staging-' +
        [Guid]::NewGuid().ToString('N')
    $protectedRoot = Join-Path $protectedBase $deploymentUid

    New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $v2RuntimeRoot -Force)) {
        if ($entry.Name -in @('cache', 'logs', 'EpinelPS.dll')) { continue }
        Copy-Item -LiteralPath $entry.FullName `
            -Destination $runtimeStagingRoot -Recurse
    }
    Copy-Item -LiteralPath $candidateDllPath -Destination `
        (Join-Path $runtimeStagingRoot 'EpinelPS.dll')
    New-Item -ItemType Directory -Path `
        (Join-Path $runtimeStagingRoot 'logs') | Out-Null
    New-ExactJunction -Path (Join-Path $runtimeStagingRoot 'cache') `
        -Target $bootCacheTarget `
        -FailureCode 'phase3b2_regroup_v3_cache_link_create_failed'

    $v3Manifest = Get-CanonicalManifest $runtimeStagingRoot
    $v2ByPath = @{}
    foreach ($member in $v2ManifestBefore.members) {
        $v2ByPath[[string]$member.relativePath] = $member
    }
    $v3ByPath = @{}
    foreach ($member in $v3Manifest.members) {
        $v3ByPath[[string]$member.relativePath] = $member
    }
    $allPaths = @($v2ByPath.Keys + $v3ByPath.Keys | Sort-Object -Unique)
    $driftPaths = @($allPaths | Where-Object {
            -not $v2ByPath.ContainsKey($_) -or
            -not $v3ByPath.ContainsKey($_) -or
            [long]$v2ByPath[$_].byteLength -ne
                [long]$v3ByPath[$_].byteLength -or
            [string]$v2ByPath[$_].sha256 -cne
                [string]$v3ByPath[$_].sha256
        })
    Assert-True (
        $driftPaths.Count -eq 1 -and
        $driftPaths[0] -ceq 'EpinelPS.dll' -and
        (Test-Digest (Join-Path $runtimeStagingRoot 'EpinelPS.dll') `
            $expectedCandidateDllByteLength $expectedCandidateDllSha256)
    ) 'phase3b2_regroup_v3_runtime_drift_invalid'

    New-Item -ItemType Directory -Path $deploymentStagingRoot | Out-Null
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot `
        'source.manifest.tsv') $sourceManifest.text
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot `
        'v2-runtime.manifest.tsv') $v2ManifestBefore.text
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot `
        'v3-runtime.manifest.tsv') $v3Manifest.text

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-regroup-semantics-deployment/v3'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        parentLaneCode =
            'epinel_solo_raid_trial_practice_materialization_repair_v2'
        derivedLaneCode =
            'epinel_solo_raid_regroup_semantics_v3'
        failureCauseCode =
            'retry_result_treated_as_completed_trial_and_logs_projected_oldest_first'
        repairCode =
            'battle_result_4_validate_only_and_newest_first_log_projection'
        parentAssessmentUid = [string]$v2Completion.assessmentUid
        parentCompletionReceiptSha256 = Get-Sha256Hex $v2CompletionPath
        parentDeploymentReceiptSha256 = Get-Sha256Hex $v2DeploymentReceiptPath
        v2DeploymentRuntimeManifestSha256 =
            Get-Sha256Hex $v2RuntimeManifestPath
        v2RuntimeNormalizedManifestSha256 = $v2ManifestBefore.manifestSha256
        v3RuntimeManifestSha256 = $v3Manifest.manifestSha256
        runtimeDriftCount = $driftPaths.Count
        runtimeDriftRoleCodes = @('server_dll')
        databaseByteLength = $expectedDatabaseByteLength
        databaseSha256 = $expectedDatabaseSha256
        parentServerDllSha256 = $expectedV2ServerDllSha256
        derivedServerDllByteLength = $expectedCandidateDllByteLength
        derivedServerDllSha256 = $expectedCandidateDllSha256
        sourceManifestMemberCount = $sourceManifest.memberCount
        sourceManifestSha256 = $sourceManifest.sha256
        selectedManagerPassedCount = 100
        selectedManagerFailedCount = 0
        retryBattleResultCode = 4
        retryRoutePersistenceCode = 'validate_only_no_commit'
        retryUserStateMutationExpected = $false
        retryRecordCreationExpected = $false
        retryJoinCountConsumptionExpected = $false
        retryTeamConsumptionExpected = $false
        battleLogProjectionCode = 'active_then_closed_each_newest_first'
        normalBattleResultCommitPreserved = $true
        installedToolCount = $toolManifest.Count
        installedTools = $toolManifest
        cacheJunctionTarget = $bootCacheTarget
        cacheContentCopied = $false
        cacheContentModified = $false
        v2RuntimeModified = $false
        v2EvidenceModified = $false
        micronLobbyGoldenModified = $false
        dLobbyGoldenModified = $false
        historicalReceiptBindingApplied = $false
        wrapperSelfHashBindingApplied = $false
        sourceManifestRuntimeBindingApplied = $false
        rollbackCode = 'leave_v3_inert_and_select_untouched_v2'
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        nextStepCode =
            'boot_micron_nlloperator_run_v3_regroup_validation_once'
    }
    Write-AtomicJson (Join-Path $deploymentStagingRoot `
        'deployment.receipt.json') $receipt

    Move-Item -LiteralPath $runtimeStagingRoot -Destination $v3RuntimeRoot
    $runtimeStagingRoot = $null
    New-Item -ItemType Directory -Path $v3EvidenceRoot | Out-Null
    Move-Item -LiteralPath $deploymentStagingRoot `
        -Destination $v3DeploymentRoot
    $deploymentStagingRoot = $null
    foreach ($role in $stagedToolPaths.Keys) {
        Copy-Item -LiteralPath $stagedToolPaths[$role] -Destination `
            (Join-Path $toolRoot $v3ToolNames[$role])
    }

    New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $v3DeploymentRoot `
        'deployment.receipt.json') -Destination `
        (Join-Path $protectedRoot 'deployment.receipt.json')
    Copy-Item -LiteralPath (Join-Path $v3DeploymentRoot `
        'source.manifest.tsv') -Destination $protectedRoot
    Copy-Item -LiteralPath (Join-Path $v3DeploymentRoot `
        'v2-runtime.manifest.tsv') -Destination $protectedRoot
    Copy-Item -LiteralPath (Join-Path $v3DeploymentRoot `
        'v3-runtime.manifest.tsv') -Destination $protectedRoot

    $v2ManifestAfter = Get-CanonicalManifest $v2RuntimeRoot
    Assert-True (
        $v2ManifestAfter.manifestSha256 -ceq
            $v2ManifestBefore.manifestSha256 -and
        (Get-Sha256Hex $dBackupSealPath) -ceq $dSealBefore -and
        -not (Test-Path -LiteralPath (Join-Path $v3EvidenceRoot `
                'active-run.pointer.json')) -and
        @($v3ToolNames.Values | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $toolRoot $_) `
                    -PathType Leaf)
            }).Count -eq 0
    ) 'phase3b2_regroup_v3_post_deploy_invalid'

    $receiptPath = Join-Path $v3DeploymentRoot 'deployment.receipt.json'
    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRoot `
            'deployment.receipt.json'
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1' -ValidationKind Challenge"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v3.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
    } | ConvertTo-Json -Depth 10
}
finally {
    if ($runtimeStagingRoot -and
        (Test-Path -LiteralPath $runtimeStagingRoot -PathType Container)) {
        Remove-Item -LiteralPath $runtimeStagingRoot -Recurse -Force
    }
    if ($deploymentStagingRoot -and
        (Test-Path -LiteralPath $deploymentStagingRoot -PathType Container)) {
        Remove-Item -LiteralPath $deploymentStagingRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $toolStagingRoot -PathType Container) {
        Remove-Item -LiteralPath $toolStagingRoot -Recurse -Force
    }
}
