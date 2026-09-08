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
        return (($algorithm.ComputeHash($Bytes) | ForEach-Object {
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
    Assert-True ($count -eq 1) $FailureCode
    $Text.Replace($OldValue, $NewValue)
}

function Replace-RegexOnce {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Replacement,
        [string]$FailureCode
    )
    $regex = [regex]::new(
        $Pattern,
        [Text.RegularExpressions.RegexOptions]::Multiline -bor
            [Text.RegularExpressions.RegexOptions]::Singleline
    )
    $matchCount = $regex.Matches($Text).Count
    Assert-True ($matchCount -eq 1) ($FailureCode + ':match_count=' + $matchCount)
    $regex.Replace(
        $Text,
        [Text.RegularExpressions.MatchEvaluator]{
            param([Text.RegularExpressions.Match]$Match)
            $Replacement
        },
        1
    )
}

function Get-CanonicalManifest {
    param([string]$Root, [string[]]$RelativePaths)
    $members = [Collections.Generic.List[object]]::new()
    foreach ($relativePath in @($RelativePaths | Sort-Object)) {
        $path = Join-Path $Root $relativePath
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
            'phase3b2_trial_practice_manifest_member_missing'
        $members.Add([pscustomobject]@{
                relativePath = $relativePath.Replace('\', '/')
                byteLength = [long](Get-Item -LiteralPath $path).Length
                sha256 = Get-Sha256Hex $path
            })
    }
    $text = (@($members | ForEach-Object {
                '{0}`t{1}`t{2}' -f $_.relativePath, $_.byteLength, $_.sha256
            }) -join "`n") + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    [pscustomobject]@{
        members = @($members)
        text = $text
        byteLength = [long]$bytes.Length
        sha256 = Get-BytesSha256Hex $bytes
    }
}

function Get-RuntimeManifest {
    param([string]$Root)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $prefix = $resolvedRoot + '\'
    $relativePaths = @(
        Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -Force |
            Where-Object {
                $relative = $_.FullName.Substring($prefix.Length).
                    Replace('\', '/')
                -not $relative.StartsWith(
                    'cache/', [StringComparison]::OrdinalIgnoreCase
                ) -and
                -not $relative.StartsWith(
                    'logs/', [StringComparison]::OrdinalIgnoreCase
                ) -and
                $relative -notin @(
                    'epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal'
                )
            } |
            ForEach-Object {
                $_.FullName.Substring($prefix.Length).Replace('\', '/')
            }
    )
    Get-CanonicalManifest -Root $resolvedRoot -RelativePaths $relativePaths
}

function Get-DerivedInnerStartText {
    param([string]$SourcePath)
    $text = [IO.File]::ReadAllText($SourcePath, [Text.Encoding]::UTF8).
        Replace("`r`n", "`n")

    $text = Replace-ExactOnce $text @'
    [string]$RequiredLocalSausContractPath = '',
    [string]$RequiredLocalSausContractSha256 = ''
)
'@ @'
    [string]$RequiredLocalSausContractPath = '',
    [string]$RequiredLocalSausContractSha256 = '',
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$DerivedSourceManifestSha256 = '',
    [ValidateSet('challenge', 'practice')]
    [string]$RunIntentCode = 'challenge'
)
'@ 'phase3b2_trial_practice_inner_start_parameter_shape_invalid'

    $text = Replace-ExactOnce $text `
        'C:\NLL\Runtime\EpinelPS-SoloRaidUnlock-v1' `
        'C:\NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1' `
        'phase3b2_trial_practice_inner_start_runtime_root_invalid'
    $text = Replace-ExactOnce $text `
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-solo-raid-unlock-v1' `
        'C:\NLL\E\P3SRTP1' `
        'phase3b2_trial_practice_inner_start_evidence_root_invalid'
    $text = Replace-ExactOnce $text `
        'f602c58985a7a90cd206e2b58d793a4c7c2c0f1ea6ba778d0d74d61d68f9635b' `
        'a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef' `
        'phase3b2_trial_practice_inner_start_dll_digest_invalid'
    $text = Replace-ExactOnce $text `
        'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee' `
        'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019' `
        'phase3b2_trial_practice_inner_start_database_digest_invalid'

    $text = Replace-RegexOnce $text `
        '^\$expectedPreflightSha256 = .*?^\$expectedServerExeSha256 =' `
        '$expectedServerExeSha256 =' `
        'phase3b2_trial_practice_inner_start_historical_digest_block_invalid'
    $text = Replace-RegexOnce $text `
        '^\$expectedExternalHead = .*?^\$expectedParentServerDllSha256 =' `
        '$expectedParentServerDllSha256 =' `
        'phase3b2_trial_practice_inner_start_external_binding_block_invalid'
    $text = Replace-RegexOnce $text `
        '^\$preflightPath =.*?\) ''phase3b2_epinel_minimal_start_input_shape_invalid''\n' @'
$contextPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'
$serverPath = Join-Path $ServerRoot 'EpinelPS.exe'
$serverDllPath = Join-Path $ServerRoot 'EpinelPS.dll'
$dbPath = Join-Path $ServerRoot 'db.json'
$bootstrapPath = Join-Path $BootstrapRoot `
    'artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$activePointerPath = Join-Path $EvidenceRoot 'active-run.pointer.json'

Assert-True (
    @($contextPath, $serverPath, $serverDllPath, $dbPath,
        $bootstrapPath, $hostsPath | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0 -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $ServerRoot $_) }
    ).Count -eq 0 -and
    $DerivedSourceManifestSha256 -cmatch '^[0-9a-f]{64}$'
) 'phase3b2_epinel_minimal_start_input_shape_invalid'
'@ 'phase3b2_trial_practice_inner_start_input_block_invalid'
    $text = Replace-ExactOnce $text @'
Assert-True (
    (Get-Sha256Hex $preflightPath) -ceq $expectedPreflightSha256 -and
    (Get-Sha256Hex $deploymentPath) -ceq $expectedDeploymentSha256 -and
    (Get-Sha256Hex $samplingLogRepairPath) -ceq `
        $expectedSamplingLogRepairSha256 -and
    (Get-Sha256Hex $serverPath) -ceq $expectedServerExeSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedHostsSha256 -and
    (Get-Sha256Hex $bootstrapPath) -ceq $expectedBootstrapSha256
) 'phase3b2_epinel_minimal_start_digest_invalid'
'@ @'
Assert-True (
    (Get-Sha256Hex $serverPath) -ceq $expectedServerExeSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedHostsSha256 -and
    (Get-Sha256Hex $bootstrapPath) -ceq $expectedBootstrapSha256
) 'phase3b2_epinel_minimal_start_digest_invalid'
'@ 'phase3b2_trial_practice_inner_start_digest_check_invalid'
    $text = Replace-RegexOnce $text `
        '^\$preflight = Get-Content .*?''phase3b2_epinel_minimal_start_contract_invalid''\n' @'
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $context.contractId -ceq
        'nll/phase3b2-synthetic-runtime-context/v1' -and
    [long]$context.accountId -gt 0 -and [long]$context.managerId -gt 0
) 'phase3b2_epinel_minimal_start_contract_invalid'
'@ 'phase3b2_trial_practice_inner_start_contract_block_invalid'
    $text = Replace-ExactOnce $text @'
        contractId = 'nll/phase3b2-epinel-minimal-reference-start/v1'
'@ @'
        contractId = 'nll/phase3b2-epinel-solo-raid-trial-practice-start/v1'
'@ 'phase3b2_trial_practice_inner_start_contract_id_invalid'
    $text = Replace-ExactOnce $text @'
        preflightReceiptSha256 = $expectedPreflightSha256
        deploymentReceiptSha256 = $expectedDeploymentSha256
        samplingLogRepairReceiptSha256 = `
            $expectedSamplingLogRepairSha256
        externalHead = $expectedExternalHead
        externalTree = $expectedExternalTree
'@ @'
        derivedSourceManifestSha256 = $DerivedSourceManifestSha256
        runIntentCode = $RunIntentCode
        historicalReceiptBindingApplied = $false
        selfHashBindingApplied = $false
'@ 'phase3b2_trial_practice_inner_start_receipt_binding_fields_invalid'
    $text = Replace-ExactOnce $text `
        "contractId = 'nll/phase3b2-epinel-minimal-reference-failure/v1'" `
        "contractId = 'nll/phase3b2-epinel-solo-raid-trial-practice-failure/v1'" `
        'phase3b2_trial_practice_inner_start_failure_contract_invalid'
    $text = Replace-ExactOnce $text `
        "nextStepCode = 'select_global_observe_or_play_close_client_then_complete'" `
        "nextStepCode = 'enter_requested_solo_raid_mode_close_client_then_complete'" `
        'phase3b2_trial_practice_inner_start_next_step_invalid'

    Assert-True (
        $text.IndexOf('deployment.receipt.json',
            [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        $text.IndexOf('preflight.receipt.json',
            [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        $text.IndexOf('sampling-log-repair',
            [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
        $text.IndexOf('$expectedPreflightSha256',
            [StringComparison]::Ordinal) -lt 0 -and
        $text.IndexOf('$expectedDeploymentSha256',
            [StringComparison]::Ordinal) -lt 0
    ) 'phase3b2_trial_practice_inner_start_binding_residue_present'
    $text
}

function Get-DerivedInnerCompletionText {
    param([string]$SourcePath)
    $text = [IO.File]::ReadAllText($SourcePath, [Text.Encoding]::UTF8).
        Replace("`r`n", "`n")
    $text = Replace-RegexOnce $text `
        '\[ValidateSet\(\n        ''startup_only''.*?''battle_result''\n    \)\]' @'
[ValidateSet(
        'startup_only', 'server_selection', 'catalogue_path', 'lobby',
        'solo_raid_menu', 'season26_challenge_squad',
        'season26_challenge_battle', 'season26_practice_squad',
        'season26_practice_battle', 'battle_result'
    )]
'@ 'phase3b2_trial_practice_inner_completion_stage_shape_invalid'
    $text = Replace-ExactOnce $text `
        'C:\NLL\Runtime\EpinelPS-SoloRaidUnlock-v1' `
        'C:\NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1' `
        'phase3b2_trial_practice_inner_completion_runtime_root_invalid'
    $text = Replace-ExactOnce $text `
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-solo-raid-unlock-v1' `
        'C:\NLL\E\P3SRTP1' `
        'phase3b2_trial_practice_inner_completion_evidence_root_invalid'
    $text = Replace-ExactOnce $text `
        'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee' `
        'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019' `
        'phase3b2_trial_practice_inner_completion_database_digest_invalid'
    $text = Replace-ExactOnce $text `
        "'nll/phase3b2-epinel-solo-raid-unlock-completion/v1'" `
        "'nll/phase3b2-epinel-solo-raid-trial-practice-completion/v1'" `
        'phase3b2_trial_practice_inner_completion_contract_id_invalid'
    $text = Replace-ExactOnce $text @'
$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
'@ @'
$pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
'@ 'phase3b2_trial_practice_inner_completion_pointer_shape_invalid'
    $text = Replace-ExactOnce $text @'
Assert-True (
    @($runStartPath, $dbBeforePath, $hostsBeforePath |
'@ @'
$runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $runStart.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-trial-practice-start/v1' -and
    [string]$runStart.runIntentCode -in @('challenge', 'practice') -and
    -not $runStart.historicalReceiptBindingApplied -and
    -not $runStart.selfHashBindingApplied
) 'phase3b2_solo_raid_trial_practice_completion_start_shape_invalid'

Assert-True (
    @($runStartPath, $dbBeforePath, $hostsBeforePath |
'@ 'phase3b2_trial_practice_inner_completion_start_parse_invalid'
    $text = Replace-ExactOnce $text @'
    observedStageCode = $ObservedStageCode
    outcomeCode = $OutcomeCode
'@ @'
    runIntentCode = [string]$runStart.runIntentCode
    observedStageCode = $ObservedStageCode
    outcomeCode = $OutcomeCode
    historicalReceiptBindingApplied = $false
    selfHashBindingApplied = $false
'@ 'phase3b2_trial_practice_inner_completion_receipt_fields_invalid'
    $text = Replace-RegexOnce $text `
        '    nextStepCode = if \(\$ObservedStageCode -eq ''battle_result''.*?    \}\n' @'
    nextStepCode = if ($OutcomeCode -ne 'success') {
        'return_to_samsung_classify_without_automatic_retry'
    } elseif ([string]$runStart.runIntentCode -ceq 'challenge' -and
        $ObservedStageCode -in @(
            'season26_challenge_squad',
            'season26_challenge_battle',
            'battle_result'
        )) {
        'return_to_samsung_then_run_practice_validation'
    } elseif ([string]$runStart.runIntentCode -ceq 'practice' -and
        $ObservedStageCode -in @(
            'season26_practice_squad',
            'season26_practice_battle',
            'battle_result'
        )) {
        'return_to_samsung_and_seal_actual_play_evidence'
    } else {
        'return_to_samsung_classify_without_automatic_retry'
    }
'@ 'phase3b2_trial_practice_inner_completion_next_step_invalid'
    $text
}

$expectedParentDatabaseByteLength = 1396709L
$expectedParentDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedParentServerExeByteLength = 162304L
$expectedParentServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedParentServerDllByteLength = 15366144L
$expectedParentServerDllSha256 =
    'f602c58985a7a90cd206e2b58d793a4c7c2c0f1ea6ba778d0d74d61d68f9635b'
$expectedDerivedServerDllByteLength = 15377408L
$expectedDerivedServerDllSha256 =
    'a28965089f0fcf68d063e6d36fe137e19e68b8618bc01e2e1008c51b18fc64ef'
$expectedParentCompletionSha256 =
    'ac80709ec236fd9a7c5cf6c2a2e4d67c0324ea94559742ceb28e9f124d453d1c'
$expectedStep6ManifestSha256 =
    '1c58deb41bef14e2d8c64699198e291898238319155c3cbd1b05f9d4f2fd54e5'
$expectedSourceContentManifestSha256 =
    '8f5fe28c76ead30b4f435afaf66762a4b3f255c0efd555f2ffaabb922b1d530c'
$expectedGoldenBundleSha256 =
    'd3206ec8c2070f06943b0f4d2959ae18d45d689efd959b16eb576721572f519e'
$expectedGoldenReceiptSha256 =
    'ebf5c2f7692e7de7ec9b8bcf3acba112cdb8efbfbb888967acde7e429e877f9c'
$expectedDBackupSealSha256 =
    'e4c1f9af044387f1624a828421800b29c9a0aa4c015f4e82f3534f70484ea613'
$expectedGoldenHead = 'aa01ad90b807be1c2ceffe958519cb529622d472'
$expectedSourceBaseHead = '317c4f352b91e76470e2b035ada426ff443f9de4'

Assert-True ($env:SystemDrive -ceq 'C:') `
    'phase3b2_trial_practice_deploy_wrong_samsung_boundary'
$micronDrive = $MicronDriveLetter + ':'
if (-not $AuditOnly) {
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronDisk = Get-Partition -DriveLetter $MicronDriveLetter | Get-Disk
    Assert-True (
        $micronDrive -cne $env:SystemDrive -and
        $systemDisk.FriendlyName -like 'Samsung SSD 980*' -and
        $micronDisk.FriendlyName -like 'Micron_2200*'
    ) 'phase3b2_trial_practice_deploy_physical_boundary_invalid'
}
Assert-True (@(Get-Process -Name @(
            'NIKKE', 'EpinelPS', 'nikke_launcher',
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        ) -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_trial_practice_deploy_runtime_not_cold'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$sourceToolRoot = Join-Path $repositoryRoot 'scripts'
$builtDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$parentRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidLevel-v1'
$derivedRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1'
$offlineCacheTarget = Join-Path $micronDrive `
    'NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$shortRunEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRTP1'
$shortDeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRTP1D'
$parentCompletionPath = Join-Path $micronDrive `
    'NLL\E\P3SRL1\6e859a33-e6c2-4d68-bf1e-15931ec282c1\completion.receipt.json'
$micronGoldenReceiptPath = Join-Path $micronDrive `
    'NLL\Evidence\Phase3B2\Physical\epinel-lobby-golden-baseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\golden-baseline.receipt.json'
$micronGoldenBundlePath = Join-Path $micronDrive `
    'NLL\Backups\Phase3B2\EpinelLobbyGoldenBaseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\epinel-source.bundle'
$dGoldenRoot =
    'D:\NikkeLocalLab\Backups\phase3b2-lobby-en-d830a90d-20260826T103327Z'
$dBackupSealPath = Join-Path $dGoldenRoot 'metadata\backup.seal.receipt.json'
$dGoldenReceiptPath = Join-Path $dGoldenRoot `
    'protected-evidence\PhysicalP2\EpinelLobbyGoldenBaseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\golden-baseline.receipt.json'
$dGoldenBundlePath = Join-Path $dGoldenRoot `
    'protected-evidence\PhysicalP2\EpinelLobbyGoldenBaseline-v1\15089f3e-92f2-4833-ab1b-348d1463f9fc\artifacts\epinel-source.bundle'
$protectedRoot =
    'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\EpinelSoloRaidTrialPractice-v1'

$parentDbPath = Join-Path $parentRuntimeRoot 'db.json'
$parentExePath = Join-Path $parentRuntimeRoot 'EpinelPS.exe'
$parentDllPath = Join-Path $parentRuntimeRoot 'EpinelPS.dll'
$sourceInnerStartPath = Join-Path $sourceToolRoot `
    'start-phase3b2-epinel-solo-raid-unlock-v1-in-micron.ps1'
$sourceInnerCompletionPath = Join-Path $sourceToolRoot `
    'complete-phase3b2-epinel-solo-raid-unlock-v1-in-micron.ps1'
$sourceOuterStartPath = Join-Path $sourceToolRoot `
    'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1'
$sourceOuterCompletionPath = Join-Path $sourceToolRoot `
    'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1'

Assert-True (
    (Test-Digest $parentDbPath $expectedParentDatabaseByteLength `
        $expectedParentDatabaseSha256) -and
    (Test-Digest $parentExePath $expectedParentServerExeByteLength `
        $expectedParentServerExeSha256) -and
    (Test-Digest $parentDllPath $expectedParentServerDllByteLength `
        $expectedParentServerDllSha256) -and
    (Test-Digest $builtDllPath $expectedDerivedServerDllByteLength `
        $expectedDerivedServerDllSha256) -and
    (Test-Digest $parentCompletionPath 1753L `
        $expectedParentCompletionSha256) -and
    (Test-Digest $micronGoldenReceiptPath 2596L `
        $expectedGoldenReceiptSha256) -and
    (Test-Digest $micronGoldenBundlePath 23426980L `
        $expectedGoldenBundleSha256) -and
    (Test-Digest $dBackupSealPath 2177L $expectedDBackupSealSha256) -and
    (Test-Digest $dGoldenReceiptPath 2596L `
        $expectedGoldenReceiptSha256) -and
    (Test-Digest $dGoldenBundlePath 23426980L `
        $expectedGoldenBundleSha256) -and
    @($sourceInnerStartPath, $sourceInnerCompletionPath,
        $sourceOuterStartPath, $sourceOuterCompletionPath |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
    ).Count -eq 0
) 'phase3b2_trial_practice_deploy_input_invalid'

$parentCompletion = Get-Content -LiteralPath $parentCompletionPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True (
    $parentCompletion.contractId -ceq
        'nll/phase3b2-epinel-solo-raid-commander-level-completion/v1' -and
    $parentCompletion.assessmentUid -ceq
        '6e859a33-e6c2-4d68-bf1e-15931ec282c1' -and
    $parentCompletion.observedStageCode -ceq 'solo_raid_menu' -and
    $parentCompletion.outcomeCode -ceq 'success' -and
    $parentCompletion.databaseRestored -and
    $parentCompletion.hostsRestored -and
    $parentCompletion.extensionFirewallRemoved -and
    $parentCompletion.runtimeColdAfterCompletion
) 'phase3b2_trial_practice_deploy_parent_completion_invalid'

$expectedSourcePaths = @(
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
$gitCandidates = @(
    (Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object `
        -ExpandProperty Source -ErrorAction SilentlyContinue),
    'C:\Users\zih44\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\git\cmd\git.exe'
)
$gitPath = @($gitCandidates | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and
        (Test-Path -LiteralPath $_ -PathType Leaf)
    } | Select-Object -First 1)
Assert-True ($gitPath.Count -eq 1) `
    'phase3b2_trial_practice_deploy_git_missing'
$sourceHead = (& $gitPath[0] -c "safe.directory=$externalRoot" `
        -C $externalRoot rev-parse HEAD | Out-String).Trim()
Assert-True ($LASTEXITCODE -eq 0 -and $sourceHead -ceq $expectedSourceBaseHead) `
    'phase3b2_trial_practice_deploy_source_head_invalid'
$changedPaths = @(
    @(& $gitPath[0] -c "safe.directory=$externalRoot" `
            -C $externalRoot diff --name-only $expectedGoldenHead --)
    @(& $gitPath[0] -c "safe.directory=$externalRoot" `
            -C $externalRoot ls-files --others --exclude-standard)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique
Assert-True (
    $LASTEXITCODE -eq 0 -and
    $changedPaths.Count -eq $expectedSourcePaths.Count -and
    @(Compare-Object $expectedSourcePaths $changedPaths).Count -eq 0
) 'phase3b2_trial_practice_deploy_source_drift_invalid'
$sourceManifest = Get-CanonicalManifest -Root $externalRoot `
    -RelativePaths $changedPaths
Assert-True ($sourceManifest.sha256 -ceq
    $expectedSourceContentManifestSha256) `
    'phase3b2_trial_practice_deploy_source_manifest_invalid'

$parentManifestBefore = Get-RuntimeManifest $parentRuntimeRoot
$goldenDigestsBefore = [ordered]@{
    micronReceipt = Get-Sha256Hex $micronGoldenReceiptPath
    micronBundle = Get-Sha256Hex $micronGoldenBundlePath
    dBackupSeal = Get-Sha256Hex $dBackupSealPath
    dReceipt = Get-Sha256Hex $dGoldenReceiptPath
    dBundle = Get-Sha256Hex $dGoldenBundlePath
}

$toolStagingRoot = Join-Path $env:TEMP (
    'NLL-P3SRTP1-' + [Guid]::NewGuid().ToString('N')
)
New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
try {
    $innerStartStagingPath = Join-Path $toolStagingRoot `
        'start-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1'
    $innerCompletionStagingPath = Join-Path $toolStagingRoot `
        'complete-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1'
    Write-Utf8NoBom $innerStartStagingPath `
        (Get-DerivedInnerStartText $sourceInnerStartPath)
    Write-Utf8NoBom $innerCompletionStagingPath `
        (Get-DerivedInnerCompletionText $sourceInnerCompletionPath)
    foreach ($path in @(
            $sourceOuterStartPath, $sourceOuterCompletionPath,
            $innerStartStagingPath, $innerCompletionStagingPath
        )) {
        Assert-PowerShellSyntax $path `
            'phase3b2_trial_practice_deploy_tool_syntax_invalid'
    }

    if ($AuditOnly) {
        [pscustomobject]@{
            schemaVersion = 1
            contractId =
                'nll/phase3b2-epinel-solo-raid-trial-practice-deployment-audit/v1'
            auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            parentAssessmentUid = [string]$parentCompletion.assessmentUid
            parentDatabaseSha256 = $expectedParentDatabaseSha256
            parentServerDllSha256 = $expectedParentServerDllSha256
            derivedServerDllSha256 = $expectedDerivedServerDllSha256
            goldenSourceHead = $expectedGoldenHead
            sourceBaseHead = $expectedSourceBaseHead
            sourceDriftFileCount = $changedPaths.Count
            step6CanonicalSourceManifestSha256 =
                $expectedStep6ManifestSha256
            sourceContentManifestSha256 = $sourceManifest.sha256
            historicalReceiptBindingApplied = $false
            wrapperSelfHashBindingApplied = $false
            goldenAndParentReadOnlyPreflightPassed = $true
            deployable = $true
        } | ConvertTo-Json -Depth 6
        return
    }

    Assert-True (
        -not (Test-Path -LiteralPath $derivedRuntimeRoot) -and
        -not (Test-Path -LiteralPath $shortRunEvidenceRoot) -and
        -not (Test-Path -LiteralPath $shortDeploymentRoot) -and
        @(
            'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1',
            'start-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1',
            'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1',
            'complete-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1' |
            Where-Object { Test-Path -LiteralPath (Join-Path $toolRoot $_) }
        ).Count -eq 0
    ) 'phase3b2_trial_practice_deploy_target_collision'

    $deploymentUid = [Guid]::NewGuid().ToString('D')
    $runtimeStagingRoot = $derivedRuntimeRoot + '.staging-' +
        [Guid]::NewGuid().ToString('N')
    $protectedRunRoot = Join-Path $protectedRoot $deploymentUid
    $installedToolPaths = [Collections.Generic.List[string]]::new()
    $runtimeActivated = $false
    $cacheJunctionCreated = $false
    $deploymentEvidenceActivated = $false
    $protectedEvidenceActivated = $false
    try {
        New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
        foreach ($entry in @(Get-ChildItem -LiteralPath $parentRuntimeRoot -Force)) {
            if ($entry.Name -in @('cache', 'logs')) { continue }
            if (-not $entry.PSIsContainer -and $entry.Name -in @(
                    'db.json', 'epinelps.db', 'epinelps.db-shm',
                    'epinelps.db-wal', 'EpinelPS.dll'
                )) { continue }
            Copy-Item -LiteralPath $entry.FullName `
                -Destination $runtimeStagingRoot -Recurse
        }
        Copy-Item -LiteralPath $parentDbPath -Destination `
            (Join-Path $runtimeStagingRoot 'db.json')
        Copy-Item -LiteralPath $builtDllPath -Destination `
            (Join-Path $runtimeStagingRoot 'EpinelPS.dll')
        New-Item -ItemType Directory -Path `
            (Join-Path $runtimeStagingRoot 'logs') | Out-Null
        Assert-True (
            (Test-Digest (Join-Path $runtimeStagingRoot 'db.json') `
                $expectedParentDatabaseByteLength `
                $expectedParentDatabaseSha256) -and
            (Test-Digest (Join-Path $runtimeStagingRoot 'EpinelPS.exe') `
                $expectedParentServerExeByteLength `
                $expectedParentServerExeSha256) -and
            (Test-Digest (Join-Path $runtimeStagingRoot 'EpinelPS.dll') `
                $expectedDerivedServerDllByteLength `
                $expectedDerivedServerDllSha256)
        ) 'phase3b2_trial_practice_deploy_runtime_staging_invalid'

        Move-Item -LiteralPath $runtimeStagingRoot `
            -Destination $derivedRuntimeRoot
        $runtimeActivated = $true
        $cacheJunctionPath = Join-Path $derivedRuntimeRoot 'cache'
        & $env:ComSpec /d /c mklink /J `
            $cacheJunctionPath $bootCacheTarget | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) `
            'phase3b2_trial_practice_deploy_cache_junction_create_failed'
        $cacheJunction = Get-Item -LiteralPath $cacheJunctionPath -Force
        Assert-True (
            $cacheJunction.LinkType -ceq 'Junction' -and
            [string]$cacheJunction.Target -ceq $bootCacheTarget
        ) 'phase3b2_trial_practice_deploy_cache_junction_target_invalid'
        $cacheJunctionCreated = $true

        $toolSourceMap = [ordered]@{
            'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' =
                $sourceOuterStartPath
            'start-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1' =
                $innerStartStagingPath
            'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' =
                $sourceOuterCompletionPath
            'complete-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1' =
                $innerCompletionStagingPath
        }
        foreach ($entry in $toolSourceMap.GetEnumerator()) {
            $destination = Join-Path $toolRoot $entry.Key
            Copy-Item -LiteralPath $entry.Value -Destination $destination
            $installedToolPaths.Add($destination)
        }

        New-Item -ItemType Directory -Path $shortRunEvidenceRoot | Out-Null
        New-Item -ItemType Directory -Path $shortDeploymentRoot | Out-Null
        $deploymentEvidenceActivated = $true
        New-Item -ItemType Directory -Path $protectedRunRoot -Force | Out-Null
        $protectedEvidenceActivated = $true

        $derivedManifest = Get-RuntimeManifest $derivedRuntimeRoot
        $parentMembers = @{}
        foreach ($member in @($parentManifestBefore.members)) {
            $parentMembers[[string]$member.relativePath] = $member
        }
        $derivedMembers = @{}
        foreach ($member in @($derivedManifest.members)) {
            $derivedMembers[[string]$member.relativePath] = $member
        }
        $runtimeDrift = @(
            $parentMembers.Keys + $derivedMembers.Keys | Sort-Object -Unique |
                Where-Object {
                    -not $parentMembers.ContainsKey($_) -or
                    -not $derivedMembers.ContainsKey($_) -or
                    [string]$parentMembers[$_].sha256 -cne
                        [string]$derivedMembers[$_].sha256 -or
                    [long]$parentMembers[$_].byteLength -ne
                        [long]$derivedMembers[$_].byteLength
                }
        )
        Assert-True (
            $runtimeDrift.Count -eq 1 -and
            $runtimeDrift[0] -ceq 'EpinelPS.dll'
        ) 'phase3b2_trial_practice_deploy_runtime_drift_invalid'

        $parentManifestAfter = Get-RuntimeManifest $parentRuntimeRoot
        $goldenDigestsAfter = [ordered]@{
            micronReceipt = Get-Sha256Hex $micronGoldenReceiptPath
            micronBundle = Get-Sha256Hex $micronGoldenBundlePath
            dBackupSeal = Get-Sha256Hex $dBackupSealPath
            dReceipt = Get-Sha256Hex $dGoldenReceiptPath
            dBundle = Get-Sha256Hex $dGoldenBundlePath
        }
        Assert-True (
            $parentManifestAfter.sha256 -ceq $parentManifestBefore.sha256 -and
            ($goldenDigestsAfter | ConvertTo-Json -Compress) -ceq
                ($goldenDigestsBefore | ConvertTo-Json -Compress)
        ) 'phase3b2_trial_practice_deploy_parent_or_golden_modified'

        $sourceManifestPath = Join-Path $shortDeploymentRoot `
            'source-drift.manifest.tsv'
        Write-Utf8NoBom $sourceManifestPath $sourceManifest.text
        $runtimeDriftText = @(
            'relative_path`tparent_byte_length`tparent_sha256' +
                '`tderived_byte_length`tderived_sha256',
            ('EpinelPS.dll`t{0}`t{1}`t{2}`t{3}' -f
                $expectedParentServerDllByteLength,
                $expectedParentServerDllSha256,
                $expectedDerivedServerDllByteLength,
                $expectedDerivedServerDllSha256)
        ) -join "`n"
        $runtimeDriftText += "`n"
        $runtimeDriftPath = Join-Path $shortDeploymentRoot `
            'runtime-drift.manifest.tsv'
        Write-Utf8NoBom $runtimeDriftPath $runtimeDriftText

        $rollbackPlan = [ordered]@{
            schemaVersion = 1
            contractId =
                'nll/phase3b2-epinel-solo-raid-trial-practice-rollback/v1'
            deploymentUid = $deploymentUid
            condition = 'runtime_cold_and_no_active_pointer'
            removeDerivedRuntimeRoot =
                'C:\NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1'
            removeShortEvidenceRoots = @(
                'C:\NLL\E\P3SRTP1', 'C:\NLL\E\P3SRTP1D'
            )
            removeToolLeaves = @($toolSourceMap.Keys)
            parentRuntimeRestoreRequired = $false
            lobbyGoldenRestoreRequired = $false
            dDriveRestoreRequired = $false
        }
        $rollbackPath = Join-Path $shortDeploymentRoot 'rollback.plan.json'
        Write-AtomicJson $rollbackPath $rollbackPlan

        $receipt = [ordered]@{
            schemaVersion = 1
            contractId =
                'nll/phase3b2-epinel-solo-raid-trial-practice-deployment/v1'
            deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            deploymentUid = $deploymentUid
            parentAssessmentUid = [string]$parentCompletion.assessmentUid
            parentCompletionReceiptSha256 = $expectedParentCompletionSha256
            parentRuntimeRoot =
                'C:\NLL\Runtime\EpinelPS-SoloRaidLevel-v1'
            derivedRuntimeRoot =
                'C:\NLL\Runtime\EpinelPS-SoloRaidTrialPractice-v1'
            parentDatabaseByteLength = $expectedParentDatabaseByteLength
            parentDatabaseSha256 = $expectedParentDatabaseSha256
            parentServerExeSha256 = $expectedParentServerExeSha256
            parentServerDllSha256 = $expectedParentServerDllSha256
            derivedServerDllByteLength = $expectedDerivedServerDllByteLength
            derivedServerDllSha256 = $expectedDerivedServerDllSha256
            goldenSourceHead = $expectedGoldenHead
            sourceBaseHead = $expectedSourceBaseHead
            sourceDriftFileCount = $changedPaths.Count
            step6CanonicalSourceManifestSha256 =
                $expectedStep6ManifestSha256
            sourceContentManifestByteLength = $sourceManifest.byteLength
            sourceContentManifestSha256 = $sourceManifest.sha256
            sourceManifestReceiptBindingApplied = $false
            deploymentReceiptBindingApplied = $false
            wrapperSelfHashBindingApplied = $false
            derivedRuntimeDriftCount = $runtimeDrift.Count
            derivedRuntimeDriftLeaves = @($runtimeDrift)
            parentRuntimeManifestBeforeSha256 = $parentManifestBefore.sha256
            parentRuntimeManifestAfterSha256 = $parentManifestAfter.sha256
            parentRuntimeModified = $false
            micronLobbyGoldenModified = $false
            dLobbyGoldenModified = $false
            goldenStartToolsModified = $false
            cacheCopied = $false
            cacheModified = $false
            databaseModified = $false
            officialOutboundUsed = $false
            serverExecutionStarted = $false
            clientExecutionStarted = $false
            maximumValidationRunCount = 2
            validationOrder = @('challenge', 'practice')
            stopAfterAnyFailure = $true
            rollbackPlanSha256 = Get-Sha256Hex $rollbackPath
            sourceDriftManifestSha256 = Get-Sha256Hex $sourceManifestPath
            runtimeDriftManifestSha256 = Get-Sha256Hex $runtimeDriftPath
            startWrapperSha256 = Get-Sha256Hex (Join-Path $toolRoot `
                'Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1')
            innerStartSha256 = Get-Sha256Hex (Join-Path $toolRoot `
                'start-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1')
            completionWrapperSha256 = Get-Sha256Hex (Join-Path $toolRoot `
                'Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1')
            innerCompletionSha256 = Get-Sha256Hex (Join-Path $toolRoot `
                'complete-phase3b2-epinel-solo-raid-trial-practice-v1-in-micron.ps1')
            nextStepCode =
                'boot_micron_nlloperator_run_challenge_validation_once'
        }
        $receiptPath = Join-Path $shortDeploymentRoot `
            'deployment.receipt.json'
        Write-AtomicJson $receiptPath $receipt
        foreach ($path in @(
                $receiptPath, $rollbackPath,
                $sourceManifestPath, $runtimeDriftPath
            )) {
            Copy-Item -LiteralPath $path -Destination $protectedRunRoot
        }

        [pscustomobject]@{
            Receipt = $receipt
            MicronReceiptPath = $receiptPath
            MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
            MicronReceiptSha256 = Get-Sha256Hex $receiptPath
            ProtectedReceiptPath = Join-Path $protectedRunRoot `
                'deployment.receipt.json'
            MicronChallengeStartCommand =
                "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' -ValidationKind Challenge"
            MicronCompletionCommand =
                "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' -ObservedStageCode <stage> -OutcomeCode <outcome>"
            MicronPracticeStartCommand =
                "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidTrialPractice-v1.ps1' -ValidationKind Practice"
        } | ConvertTo-Json -Depth 10
    }
    catch {
        foreach ($path in @($installedToolPaths)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        if ($cacheJunctionCreated) {
            $cachePath = Join-Path $derivedRuntimeRoot 'cache'
            if (Test-Path -LiteralPath $cachePath) {
                Remove-Item -LiteralPath $cachePath -Force
            }
        }
        if ($runtimeActivated -and
            (Test-Path -LiteralPath $derivedRuntimeRoot -PathType Container)) {
            Remove-Item -LiteralPath $derivedRuntimeRoot -Recurse -Force
        }
        if (Test-Path -LiteralPath $runtimeStagingRoot -PathType Container) {
            Remove-Item -LiteralPath $runtimeStagingRoot -Recurse -Force
        }
        if ($deploymentEvidenceActivated) {
            if (Test-Path -LiteralPath $shortRunEvidenceRoot) {
                Remove-Item -LiteralPath $shortRunEvidenceRoot -Recurse -Force
            }
            if (Test-Path -LiteralPath $shortDeploymentRoot) {
                Remove-Item -LiteralPath $shortDeploymentRoot -Recurse -Force
            }
        }
        if ($protectedEvidenceActivated -and
            (Test-Path -LiteralPath $protectedRunRoot)) {
            Remove-Item -LiteralPath $protectedRunRoot -Recurse -Force
        }
        throw
    }
}
finally {
    if (Test-Path -LiteralPath $toolStagingRoot -PathType Container) {
        Remove-Item -LiteralPath $toolStagingRoot -Recurse -Force
    }
}
