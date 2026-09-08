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

function Get-CanonicalManifest {
    param([string]$Root)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $prefix = $resolvedRoot + '\'
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($entry in @(Get-ChildItem -LiteralPath $resolvedRoot -Force)) {
        if ($entry.Name -in @('cache', 'logs')) { continue }
        if ($entry.PSIsContainer) {
            Assert-True (-not $entry.LinkType) `
                'phase3b2_materialization_repair_unexpected_runtime_link'
            foreach ($file in @(Get-ChildItem -LiteralPath $entry.FullName `
                    -File -Recurse -Force)) {
                $files.Add($file)
            }
        }
        elseif ($entry.Name -notin @(
                'epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal'
            )) {
            $files.Add($entry)
        }
    }

    $members = @($files | ForEach-Object {
            $relative = $_.FullName.Substring($prefix.Length).
                Replace('\', '/')
            [pscustomobject]@{
                relativePath = $relative
                byteLength = [long]$_.Length
                sha256 = Get-Sha256Hex $_.FullName
            }
        } | Sort-Object relativePath)
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
    $members = @($RelativePaths | Sort-Object | ForEach-Object {
            $path = Join-Path $Root $_
            Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
                'phase3b2_materialization_repair_source_member_missing'
            [pscustomobject]@{
                relativePath = $_.Replace('\', '/')
                byteLength = [long](Get-Item -LiteralPath $path).Length
                sha256 = Get-Sha256Hex $path
            }
        })
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
            'phase3b2_materialization_repair_tool_projection_invalid'
    }
    $text
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True ($AuditOnly -or $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_materialization_repair_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_materialization_repair_wrong_samsung_boundary'

$micronDrive = $MicronDriveLetter + ':'
if ($AuditOnly) {
    Assert-True (
        $micronDrive -cne $env:SystemDrive -and
        (Test-Path -LiteralPath ($micronDrive + '\') -PathType Container)
    ) 'phase3b2_materialization_repair_audit_volume_boundary_invalid'
}
else {
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
    Assert-True (
        $micronDrive -cne $env:SystemDrive -and
        $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
        $micronDisk.FriendlyName -like 'Micron_2200*'
    ) 'phase3b2_materialization_repair_physical_boundary_invalid'
}
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_materialization_repair_runtime_not_cold'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$candidateDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$v1RuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1'
$v2RuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v2'
$v1EvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRTP1'
$v2EvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRTP2'
$v2DeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRTP2D'
$v1DeploymentReceiptPath = Join-Path $micronDrive `
    'NLL\E\P3SRTP1D\deployment.receipt.json'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$protectedBase =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidTrialPracticeMaterializationRepair-v2'
$dBackupSealPath =
    'D:\NikkeLocalLab\Backups\phase3b2-lobby-en-d830a90d-20260826T103327Z\metadata\backup.seal.receipt.json'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'

$v1ToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1'
    innerStart =
        'start-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1'
    outerCompletion =
        'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1'
    innerCompletion =
        'complete-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1'
}
$v2ToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v2.ps1'
    innerStart =
        'start-phase3b2-epinel-solo-raid-trial-practice-v2-in-micron.ps1'
    outerCompletion =
        'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v2.ps1'
    innerCompletion =
        'complete-phase3b2-epinel-solo-raid-trial-practice-v2-in-micron.ps1'
}

$expectedV1DatabaseByteLength = 1396709L
$expectedV1DatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedV1ServerExeByteLength = 162304L
$expectedV1ServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedV1ServerDllByteLength = 15377408L
$expectedV1ServerDllSha256 =
    'a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef'
$expectedCandidateDllByteLength = 15377408L
$expectedCandidateDllSha256 =
    '2366129e5974291ce7ae61d5c10f12991b01fc6b5752b6dcb2d60a551177cd33'
$expectedSourceManifestSha256 =
    'a81d45a6af9d94095cf1ca3400150ccee7a650796be4f2c8379c418de7d66bb2'
$expectedExternalHead =
    '317c4f352b91e76470e2b035ada426ff443f9de4'
$expectedV1DeploymentReceiptSha256 =
    '51a47dfe74b3147aa2c621cc1ff63b86edd3b1edb4868780e2d986bfc3589584'
$expectedDBackupSealSha256 =
    'e4c1f9af044387f1624a828421800b29c9a0aa4c015f4e82f3534f70484ea613'
$expectedV1ToolDigests = [ordered]@{
    outerStart = '7080829d67ae4da1bb447c4610be320d309e48b8b8b14f53371807e0309b2ecc'
    innerStart = '2d4aca11cf289bcb020efa3ef6373d12a1a9a5f309623f29462a6377851f5a72'
    outerCompletion = 'b794a5cfd5c0bdf7effcb382f0f9abbfb72122edf4a651c733ccdf4a69c1face'
    innerCompletion = 'd806772bf01b2d432745b33f05c1c74c50e2d4f4843b312bc8e88dce8eca3988'
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
    'phase3b2_materialization_repair_git_missing'
$gitPath = [string]$gitCandidates[0]
$gitSafeDirectoryArgument = 'safe.directory=' +
    $externalRoot.Replace('\', '/')
$observedExternalHeadLines = @(& $gitPath -c $gitSafeDirectoryArgument `
        -C $externalRoot rev-parse HEAD)
Assert-True ($LASTEXITCODE -eq 0 -and
    $observedExternalHeadLines.Count -eq 1) `
    'phase3b2_materialization_repair_external_head_read_failed'
$observedExternalHead = [string]$observedExternalHeadLines[0]
Assert-True (
    $observedExternalHead -ceq $expectedExternalHead) `
    'phase3b2_materialization_repair_external_head_invalid'
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
        $changedExternalPaths) `
    'phase3b2_materialization_repair_external_change_scope_invalid'
$sourceManifest = Get-SourceManifest -Root $externalRoot `
    -RelativePaths $sourcePaths
Assert-True (
    $sourceManifest.memberCount -eq 17 -and
    $sourceManifest.sha256 -ceq $expectedSourceManifestSha256
) 'phase3b2_materialization_repair_source_manifest_invalid'

$v1ToolPaths = [ordered]@{}
foreach ($role in $v1ToolNames.Keys) {
    $path = Join-Path $toolRoot $v1ToolNames[$role]
    Assert-True (
        (Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Sha256Hex $path) -ceq $expectedV1ToolDigests[$role]
    ) 'phase3b2_materialization_repair_v1_tool_drifted'
    $v1ToolPaths[$role] = $path
}

Assert-True (
    (Test-Digest $candidateDllPath $expectedCandidateDllByteLength `
        $expectedCandidateDllSha256) -and
    (Test-Digest (Join-Path $v1RuntimeRoot 'db.json') `
        $expectedV1DatabaseByteLength $expectedV1DatabaseSha256) -and
    (Test-Digest (Join-Path $v1RuntimeRoot 'EpinelPS.exe') `
        $expectedV1ServerExeByteLength $expectedV1ServerExeSha256) -and
    (Test-Digest (Join-Path $v1RuntimeRoot 'EpinelPS.dll') `
        $expectedV1ServerDllByteLength $expectedV1ServerDllSha256) -and
    (Test-Digest $v1DeploymentReceiptPath 3369L `
        $expectedV1DeploymentReceiptSha256) -and
    (Test-Digest $dBackupSealPath 2177L $expectedDBackupSealSha256) -and
    (Test-Path -LiteralPath $v1EvidenceRoot -PathType Container) -and
    -not (Test-Path -LiteralPath (Join-Path $v1EvidenceRoot `
            'active-run.pointer.json')) -and
    @(Get-ChildItem -LiteralPath $v1RuntimeRoot -File | Where-Object {
            $_.Name -in @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal')
        }).Count -eq 0
) 'phase3b2_materialization_repair_input_missing_or_drifted'

$v1Cache = Get-Item -LiteralPath (Join-Path $v1RuntimeRoot 'cache') -Force
Assert-True (
    $v1Cache.LinkType -ceq 'Junction' -and
    [string]$v1Cache.Target -ceq $bootCacheTarget
) 'phase3b2_materialization_repair_v1_cache_link_invalid'

$v1Runs = @(Get-ChildItem -LiteralPath $v1EvidenceRoot -Directory)
Assert-True ($v1Runs.Count -eq 1) `
    'phase3b2_materialization_repair_v1_run_cardinality_invalid'
$v1CompletionPath = Join-Path $v1Runs[0].FullName 'completion.receipt.json'
Assert-True (Test-Path -LiteralPath $v1CompletionPath -PathType Leaf) `
    'phase3b2_materialization_repair_v1_completion_missing'
$v1Completion = Get-Content -LiteralPath $v1CompletionPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $v1Completion.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-trial-practice-completion/v1' -and
    $v1Completion.observedStageCode -ceq 'solo_raid_menu' -and
    $v1Completion.outcomeCode -ceq 'system_error' -and
    $v1Completion.databaseRestored -and
    $v1Completion.runtimeColdAfterCompletion
) 'phase3b2_materialization_repair_v1_completion_invalid'

$v1ManifestBefore = Get-CanonicalManifest $v1RuntimeRoot
$dSealBefore = Get-Sha256Hex $dBackupSealPath
$toolStagingRoot = Join-Path $env:TEMP (
    'NLL-P3SRTP2-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
try {
    $toolReplacements = [ordered]@{
        'EpinelPS-SoloRaidTrialPractice-v1' =
            'EpinelPS-SoloRaidTrialPractice-v2'
        'P3SRTP1' = 'P3SRTP2'
        'a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef' =
            $expectedCandidateDllSha256
        '1c58deb41bef14e2d8c64699198e291898238319155c3cbd1b05f9d4f2fd54e5' =
            $expectedSourceManifestSha256
        'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' =
            $v2ToolNames.outerStart
        'start-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1' =
            $v2ToolNames.innerStart
        'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' =
            $v2ToolNames.outerCompletion
        'complete-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1' =
            $v2ToolNames.innerCompletion
        'nll/phase3b2-epinel-solo-raid-trial-practice-start/v1' =
            'nll/phase3b2-epinel-solo-raid-materialization-repair-start/v2'
        'nll/phase3b2-epinel-solo-raid-trial-practice-completion/v1' =
            'nll/phase3b2-epinel-solo-raid-materialization-repair-completion/v2'
        'nll/phase3b2-epinel-solo-raid-trial-practice-validation/v1' =
            'nll/phase3b2-epinel-solo-raid-materialization-repair-validation/v2'
        'nll/phase3b2-epinel-solo-raid-trial-practice-failure/v1' =
            'nll/phase3b2-epinel-solo-raid-materialization-repair-failure/v2'
    }
    $roleReplacements = [ordered]@{
        outerStart = @(
            'EpinelPS-SoloRaidTrialPractice-v1', 'P3SRTP1',
            'a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef',
            '1c58deb41bef14e2d8c64699198e291898238319155c3cbd1b05f9d4f2fd54e5',
            'start-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1',
            'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1',
            'nll/phase3b2-epinel-solo-raid-trial-practice-start/v1',
            'nll/phase3b2-epinel-solo-raid-trial-practice-completion/v1',
            'nll/phase3b2-epinel-solo-raid-trial-practice-validation/v1'
        )
        innerStart = @(
            'EpinelPS-SoloRaidTrialPractice-v1', 'P3SRTP1',
            'a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef',
            'nll/phase3b2-epinel-solo-raid-trial-practice-start/v1',
            'nll/phase3b2-epinel-solo-raid-trial-practice-failure/v1'
        )
        outerCompletion = @(
            'complete-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1'
        )
        innerCompletion = @(
            'EpinelPS-SoloRaidTrialPractice-v1', 'P3SRTP1',
            'nll/phase3b2-epinel-solo-raid-trial-practice-start/v1',
            'nll/phase3b2-epinel-solo-raid-trial-practice-completion/v1'
        )
    }

    $stagedToolPaths = [ordered]@{}
    foreach ($role in $v1ToolNames.Keys) {
        $replacements = [ordered]@{}
        foreach ($oldValue in $roleReplacements[$role]) {
            $replacements[$oldValue] = $toolReplacements[$oldValue]
        }
        $stagedPath = Join-Path $toolStagingRoot $v2ToolNames[$role]
        Write-Utf8NoBom $stagedPath `
            (Get-DerivedToolText $v1ToolPaths[$role] $replacements)
        Assert-PowerShellSyntax $stagedPath `
            'phase3b2_materialization_repair_tool_syntax_invalid'
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
                'nll/phase3b2-epinel-solo-raid-materialization-repair-deployment-audit/v2'
            auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            v1RuntimeManifestSha256 = $v1ManifestBefore.manifestSha256
            v1RunOutcomeCode = [string]$v1Completion.outcomeCode
            candidateServerDllByteLength = $expectedCandidateDllByteLength
            candidateServerDllSha256 = $expectedCandidateDllSha256
            sourceManifestMemberCount = $sourceManifest.memberCount
            sourceManifestSha256 = $sourceManifest.sha256
            projectedToolCount = $toolManifest.Count
            projectedTools = $toolManifest
            historicalReceiptBindingApplied = $false
            wrapperSelfHashBindingApplied = $false
            v1RuntimeModified = $false
            goldenRuntimeModified = $false
            dGoldenModified = $false
            deployable = $true
        } | ConvertTo-Json -Depth 8
        return
    }

    Assert-True (
        -not (Test-Path -LiteralPath $v2RuntimeRoot) -and
        -not (Test-Path -LiteralPath $v2EvidenceRoot) -and
        -not (Test-Path -LiteralPath $v2DeploymentRoot) -and
        @($v2ToolNames.Values | Where-Object {
                Test-Path -LiteralPath (Join-Path $toolRoot $_)
            }).Count -eq 0
    ) 'phase3b2_materialization_repair_target_collision'

    $deploymentUid = [Guid]::NewGuid().ToString('D')
    $runtimeStagingRoot = $v2RuntimeRoot + '.staging-' +
        [Guid]::NewGuid().ToString('N')
    $deploymentStagingRoot = $v2DeploymentRoot + '.staging-' +
        [Guid]::NewGuid().ToString('N')
    $protectedRoot = Join-Path $protectedBase $deploymentUid

    New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $v1RuntimeRoot -Force)) {
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
        -FailureCode 'phase3b2_materialization_repair_cache_link_create_failed'

    $v2Manifest = Get-CanonicalManifest $runtimeStagingRoot
    $v1ByPath = @{}
    foreach ($member in $v1ManifestBefore.members) {
        $v1ByPath[[string]$member.relativePath] = $member
    }
    $v2ByPath = @{}
    foreach ($member in $v2Manifest.members) {
        $v2ByPath[[string]$member.relativePath] = $member
    }
    $allPaths = @($v1ByPath.Keys + $v2ByPath.Keys | Sort-Object -Unique)
    $driftPaths = @($allPaths | Where-Object {
            -not $v1ByPath.ContainsKey($_) -or
            -not $v2ByPath.ContainsKey($_) -or
            [long]$v1ByPath[$_].byteLength -ne
                [long]$v2ByPath[$_].byteLength -or
            [string]$v1ByPath[$_].sha256 -cne
                [string]$v2ByPath[$_].sha256
        })
    Assert-True (
        $driftPaths.Count -eq 1 -and
        $driftPaths[0] -ceq 'EpinelPS.dll' -and
        (Test-Digest (Join-Path $runtimeStagingRoot 'EpinelPS.dll') `
            $expectedCandidateDllByteLength $expectedCandidateDllSha256)
    ) 'phase3b2_materialization_repair_runtime_drift_invalid'

    New-Item -ItemType Directory -Path $deploymentStagingRoot | Out-Null
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot `
        'source.manifest.tsv') $sourceManifest.text
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot `
        'v1-runtime.manifest.tsv') $v1ManifestBefore.text
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot `
        'v2-runtime.manifest.tsv') $v2Manifest.text

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-materialization-repair-deployment/v2'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        parentLaneCode = 'epinel_solo_raid_trial_practice_v1'
        derivedLaneCode =
            'epinel_solo_raid_trial_practice_materialization_repair_v2'
        failureCauseCode =
            'shared_static_monster_skill_data_cleared_during_open'
        repairCode =
            'remove_destructive_monster_skill_data_assignment'
        failedAssessmentUid = [string]$v1Completion.assessmentUid
        failedCompletionReceiptSha256 = Get-Sha256Hex $v1CompletionPath
        v1DeploymentReceiptSha256 = Get-Sha256Hex $v1DeploymentReceiptPath
        v1RuntimeManifestSha256 = $v1ManifestBefore.manifestSha256
        v2RuntimeManifestSha256 = $v2Manifest.manifestSha256
        runtimeDriftCount = $driftPaths.Count
        runtimeDriftRoleCodes = @('server_dll')
        databaseByteLength = $expectedV1DatabaseByteLength
        databaseSha256 = $expectedV1DatabaseSha256
        parentServerDllSha256 = $expectedV1ServerDllSha256
        derivedServerDllByteLength = $expectedCandidateDllByteLength
        derivedServerDllSha256 = $expectedCandidateDllSha256
        exactSeason26PackSha256 =
            '8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3'
        exactRoleCountsBeforeOpen = @(3, 13, 13, 96, 12, 12)
        exactRoleCountsAfterOpen = @(3, 13, 13, 96, 12, 12)
        skillTotalCountBeforeOpen = 30
        skillTotalCountAfterOpen = 30
        nonzeroSkillCountBeforeOpen = 15
        nonzeroSkillCountAfterOpen = 15
        targetObservationBeforeOpenCode = 'trusted_target'
        targetObservationAfterOpenCode = 'trusted_target'
        materializationInspectionVerdictCode =
            'exact_materialization_and_replay_verified'
        selectedManagerFocusedPassedCount = 97
        selectedManagerFocusedFailedCount = 0
        sourceManifestMemberCount = $sourceManifest.memberCount
        sourceManifestSha256 = $sourceManifest.sha256
        installedToolCount = $toolManifest.Count
        installedTools = $toolManifest
        cacheJunctionTarget = $bootCacheTarget
        cacheContentCopied = $false
        cacheContentModified = $false
        v1RuntimeModified = $false
        v1EvidenceModified = $false
        micronLobbyGoldenModified = $false
        dLobbyGoldenModified = $false
        historicalReceiptBindingApplied = $false
        wrapperSelfHashBindingApplied = $false
        sourceManifestRuntimeBindingApplied = $false
        rollbackCode = 'leave_v2_inert_and_select_untouched_v1'
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        nextStepCode =
            'boot_micron_nlloperator_run_v2_challenge_validation_once'
    }
    Write-AtomicJson (Join-Path $deploymentStagingRoot `
        'deployment.receipt.json') $receipt

    Move-Item -LiteralPath $runtimeStagingRoot -Destination $v2RuntimeRoot
    New-Item -ItemType Directory -Path $v2EvidenceRoot | Out-Null
    Move-Item -LiteralPath $deploymentStagingRoot `
        -Destination $v2DeploymentRoot
    foreach ($role in $stagedToolPaths.Keys) {
        Copy-Item -LiteralPath $stagedToolPaths[$role] -Destination `
            (Join-Path $toolRoot $v2ToolNames[$role])
    }

    New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $v2DeploymentRoot `
        'deployment.receipt.json') -Destination `
        (Join-Path $protectedRoot 'deployment.receipt.json')
    Copy-Item -LiteralPath (Join-Path $v2DeploymentRoot `
        'source.manifest.tsv') -Destination $protectedRoot
    Copy-Item -LiteralPath (Join-Path $v2DeploymentRoot `
        'v1-runtime.manifest.tsv') -Destination $protectedRoot
    Copy-Item -LiteralPath (Join-Path $v2DeploymentRoot `
        'v2-runtime.manifest.tsv') -Destination $protectedRoot

    $v1ManifestAfter = Get-CanonicalManifest $v1RuntimeRoot
    Assert-True (
        $v1ManifestAfter.manifestSha256 -ceq
            $v1ManifestBefore.manifestSha256 -and
        (Get-Sha256Hex $dBackupSealPath) -ceq $dSealBefore -and
        -not (Test-Path -LiteralPath (Join-Path $v2EvidenceRoot `
                'active-run.pointer.json')) -and
        @($v2ToolNames.Values | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $toolRoot $_) `
                    -PathType Leaf)
            }).Count -eq 0
    ) 'phase3b2_materialization_repair_post_deploy_invalid'

    $receiptPath = Join-Path $v2DeploymentRoot 'deployment.receipt.json'
    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRoot `
            'deployment.receipt.json'
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidTrialPractice-v2.ps1' -ValidationKind Challenge"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v2.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $toolStagingRoot -PathType Container) {
        Remove-Item -LiteralPath $toolStagingRoot -Recurse -Force
    }
}
