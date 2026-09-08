#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$MicronDriveLetter = 'E',
    [switch]$AuditOnly,
    [switch]$RepairExistingCompletion
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
        return ($algorithm.ComputeHash($Bytes) | ForEach-Object {
                $_.ToString('x2')
            }) -join ''
    }
    finally {
        $algorithm.Dispose()
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    Write-Utf8NoBom $temporary (($Value | ConvertTo-Json -Depth 10) + "`n")
    Move-Item -LiteralPath $temporary -Destination $Path -Force
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

function Get-DerivedText {
    param(
        [string]$Path,
        [Collections.Specialized.OrderedDictionary]$Replacements,
        [string]$FailureCode
    )
    $text = (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Replace(
        "`r`n", "`n"
    )
    foreach ($key in $Replacements.Keys) {
        $count = [regex]::Matches($text, [regex]::Escape([string]$key)).Count
        Assert-True ($count -gt 0) ($FailureCode + ':missing=' + $key)
        $text = $text.Replace([string]$key, [string]$Replacements[$key])
    }
    return $text
}

function Replace-ExactlyOnce {
    param(
        [string]$Text,
        [string]$Before,
        [string]$After,
        [string]$FailureCode
    )
    $count = [regex]::Matches($Text, [regex]::Escape($Before)).Count
    Assert-True ($count -eq 1) ($FailureCode + ':count=' + $count)
    $Text.Replace($Before, $After)
}

function Get-CriticalFingerprint {
    param(
        [string]$RuntimeRoot,
        [Collections.Specialized.OrderedDictionary]$ToolPaths,
        [string[]]$ReceiptPaths
    )
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($leaf in @(
            'db.json', 'EpinelPS.exe', 'EpinelPS.dll', 'log4net.config'
        )) {
        $path = Join-Path $RuntimeRoot $leaf
        $rows.Add($path + "`t" + (Get-Sha256Hex $path))
    }
    foreach ($role in $ToolPaths.Keys) {
        $path = [string]$ToolPaths[$role]
        $rows.Add($path + "`t" + (Get-Sha256Hex $path))
    }
    foreach ($path in $ReceiptPaths) {
        $rows.Add($path + "`t" + (Get-Sha256Hex $path))
    }
    $text = (($rows | Sort-Object) -join "`n") + "`n"
    Get-BytesSha256Hex ([Text.UTF8Encoding]::new($false).GetBytes($text))
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
    'phase3b2_regroup_repair_v5_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'zih44') `
    'phase3b2_regroup_repair_v5_wrong_samsung_boundary'

$micronDrive = $MicronDriveLetter + ':'
$systemDisk = Get-PhysicalDisk | Where-Object {
    $_.FriendlyName -ceq 'Samsung SSD 980 1TB'
}
$micronDisk = Get-PhysicalDisk | Where-Object {
    $_.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK'
}
Assert-True (
    $null -ne $systemDisk -and $null -ne $micronDisk -and
    (Test-Path -LiteralPath ($micronDrive + '\NLL') -PathType Container)
) 'phase3b2_regroup_repair_v5_disk_boundary_invalid'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap -ErrorAction SilentlyContinue
    ).Count -eq 0) 'phase3b2_regroup_repair_v5_runtime_not_cold'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$externalRoot = Join-Path $repositoryRoot '.external\EpinelPS'
$candidateDllPath = Join-Path $externalRoot `
    'EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.dll'
$sourceMembers = [ordered]@{
    'EpinelPS/LobbyServer/Soloraid/SetDamageTrial.cs' = [ordered]@{
        byteLength = 768L
        sha256 = '85b2eea58be7ca84ca7dff32a8f22cd0933fe971ea19e7b5631de17c37633d73'
    }
    'EpinelPS/LobbyServer/Soloraid/SoloRaidHelper.cs' = [ordered]@{
        byteLength = 30926L
        sha256 = '58392657b4dd38537cf46903fd25302d421a5181aac04d63cbff2bc67f55908f'
    }
    'EpinelPS/LobbyServer/Soloraid/ClassicSoloRaidRouteExecutor.cs' = [ordered]@{
        byteLength = 12837L
        sha256 = 'ebf52544c64df4de057913600edcf3a364d523c38e2ae37ae379fe4baa419e7c'
    }
    'tests/EpinelPS.SelectedManager.Tests/SoloRaidRetrySemanticsTests.cs' = [ordered]@{
        byteLength = 5318L
        sha256 = '83f2a101a45c2846b83947165de70200d7fb660fab44022ae9390d149c821a1f'
    }
}
$sourceManifestSha256 =
    '1a1cb7b110bcf2ba7cf3c4bb0a3c6f681df4d60112dd9bb523c71d3b3dc83030'
$candidateDllByteLength = 15378432L
$candidateDllSha256 =
    '9f350c9ba11df44365d890439f588fd29734e1ded14026934fea1c02bfed4c42'

$parentRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidBattleResultObserver-v4'
$parentEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SROB4'
$parentDeploymentReceiptPath = Join-Path $micronDrive `
    'NLL\E\P3SROB4D\deployment.receipt.json'
$parentCompletionPath = Join-Path $parentEvidenceRoot `
    '41982aef-b3d7-4ec7-ad90-4bdff1d95500\completion.receipt.json'
$toolRoot = Join-Path $micronDrive 'NLL\Tools'
$parentToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-BattleResultObserver-v4.ps1'
    innerStart = 'start-phase3b2-epinel-battle-result-observer-v4-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-BattleResultObserver-v4.ps1'
    innerCompletion = 'complete-phase3b2-epinel-battle-result-observer-v4-in-micron.ps1'
}
$parentToolPaths = [ordered]@{}
foreach ($role in $parentToolNames.Keys) {
    $parentToolPaths[$role] = Join-Path $toolRoot $parentToolNames[$role]
}
$expectedParentToolDigests = [ordered]@{
    outerStart = '326dc5bbfdf6679815f577527e68532f2b274b32ba5801338ee57fd8c39e5f27'
    innerStart = '6f863c4ddc32e9698f0d147e6baa433394db20238f68b200309e2f2a25bf2bdc'
    outerCompletion = '3740bc20c0cd5293d6faa0937f162cc51657842512f5e3a85310e37f7149962f'
    innerCompletion = 'fc681dbe1f59674fce0f69b9061ebd3df3c94e9b4826d5d512eacb7c0d885a0d'
}

$expectedDatabaseSha256 =
    'dee9c6aa5421287ca030e325b81a90a302a5d9e113d57c3065e5d36f6e7c4019'
$expectedServerExeSha256 =
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedParentDllSha256 =
    'ac93f0333c3a0f495fae4834fb1b8dc5d2ec79f811d72f5872be0bfe63b0bd6c'
$expectedParentLogConfigSha256 =
    'a4a7e9c8eba272dd880766e1518a4272bd82f8a01e120160e0e04e3d51e176ea'
$expectedInfoLogConfigSha256 =
    '31b873b3ad156436f0a55f54f1518fde9e2e6c0059cca3ec2e3b181c08c448b9'
$expectedParentDeploymentSha256 =
    'e1760ecda1f300fa22facffe232663696a74d87aa312fc25191246eaf954061a'
$expectedParentCompletionSha256 =
    'c5d30c72b8954621d79187bb8dd6a919b0055e84693d8c762f4ffdc6d832bde8'
$bootCacheTarget =
    'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\cache'

$requiredPaths = @(
    $candidateDllPath, $parentDeploymentReceiptPath, $parentCompletionPath,
    (Join-Path $parentRuntimeRoot 'db.json'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.exe'),
    (Join-Path $parentRuntimeRoot 'EpinelPS.dll'),
    (Join-Path $parentRuntimeRoot 'log4net.config')
) + @($parentToolPaths.Values)
foreach ($relativePath in $sourceMembers.Keys) {
    $requiredPaths += Join-Path $externalRoot ($relativePath.Replace('/', '\'))
}
Assert-True (@($requiredPaths | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) 'phase3b2_regroup_repair_v5_input_missing'

$sourceRows = [Collections.Generic.List[string]]::new()
foreach ($relativePath in $sourceMembers.Keys) {
    $path = Join-Path $externalRoot ($relativePath.Replace('/', '\'))
    $expected = $sourceMembers[$relativePath]
    Assert-True (
        (Get-Item -LiteralPath $path).Length -eq [long]$expected.byteLength -and
        (Get-Sha256Hex $path) -ceq [string]$expected.sha256
    ) ('phase3b2_regroup_repair_v5_source_drift:' + $relativePath)
    $sourceRows.Add($relativePath + "`t" + $expected.byteLength + "`t" +
        $expected.sha256)
}
$sourceManifestText = (($sourceRows) -join "`n") + "`n"
Assert-True (
    (Get-BytesSha256Hex ([Text.UTF8Encoding]::new($false).GetBytes(
                $sourceManifestText))) -ceq $sourceManifestSha256
) 'phase3b2_regroup_repair_v5_source_manifest_invalid'
Assert-True (
    (Get-Item -LiteralPath $candidateDllPath).Length -eq
        $candidateDllByteLength -and
    (Get-Sha256Hex $candidateDllPath) -ceq $candidateDllSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'db.json')) -ceq
        $expectedDatabaseSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.exe')) -ceq
        $expectedServerExeSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'EpinelPS.dll')) -ceq
        $expectedParentDllSha256 -and
    (Get-Sha256Hex (Join-Path $parentRuntimeRoot 'log4net.config')) -ceq
        $expectedParentLogConfigSha256 -and
    (Get-Sha256Hex $parentDeploymentReceiptPath) -ceq
        $expectedParentDeploymentSha256 -and
    (Get-Sha256Hex $parentCompletionPath) -ceq
        $expectedParentCompletionSha256
) 'phase3b2_regroup_repair_v5_parent_content_invalid'
foreach ($role in $parentToolPaths.Keys) {
    Assert-True (
        (Get-Sha256Hex $parentToolPaths[$role]) -ceq
            $expectedParentToolDigests[$role]
    ) ('phase3b2_regroup_repair_v5_parent_tool_drift:' + $role)
}
$parentCache = Get-Item -LiteralPath (Join-Path $parentRuntimeRoot 'cache') `
    -Force -ErrorAction SilentlyContinue
Assert-True (
    $null -ne $parentCache -and $parentCache.LinkType -ceq 'Junction' -and
    [string]$parentCache.Target -ceq $bootCacheTarget -and
    -not (Test-Path -LiteralPath (Join-Path $parentEvidenceRoot `
                'active-run.pointer.json'))
) 'phase3b2_regroup_repair_v5_parent_not_cold_or_cache_invalid'

$parentFingerprintBefore = Get-CriticalFingerprint `
    -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths `
    -ReceiptPaths @($parentDeploymentReceiptPath, $parentCompletionPath)

$targetRuntimeRoot = Join-Path $micronDrive `
    'NLL\Runtime\EpinelPS-SoloRaidRegroupRepair-v5'
$targetEvidenceRoot = Join-Path $micronDrive 'NLL\E\P3SRGR5'
$targetDeploymentRoot = Join-Path $micronDrive 'NLL\E\P3SRGR5D'
$targetToolNames = [ordered]@{
    outerStart = 'Start-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1'
    innerStart = 'start-phase3b2-epinel-solo-raid-regroup-repair-v5-in-micron.ps1'
    outerCompletion = 'Complete-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1'
    innerCompletion = 'complete-phase3b2-epinel-solo-raid-regroup-repair-v5-in-micron.ps1'
}
$protectedBase = Join-Path $repositoryRoot.Replace(
    'Users\zih44\Documents\Github\Nikke-Local-Lab',
    'Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2'
) 'EpinelSoloRaidRegroupRepair-v5'
Assert-True ($protectedBase -clike 'C:\Recovered_OldSSD\*') `
    'phase3b2_regroup_repair_v5_protected_root_invalid'

$toolStagingRoot = Join-Path $env:TEMP (
    'NLL-P3SRGR5-' + [Guid]::NewGuid().ToString('N')
)
$runtimeStagingRoot = $null
$deploymentStagingRoot = $null
New-Item -ItemType Directory -Path $toolStagingRoot | Out-Null
try {
    $commonReplacements = [ordered]@{
        'EpinelPS-SoloRaidBattleResultObserver-v4' =
            'EpinelPS-SoloRaidRegroupRepair-v5'
        'P3SROB4' = 'P3SRGR5'
        'Complete-Phase3B2-Epinel-BattleResultObserver-v4.ps1' =
            'Complete-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1'
        'complete-phase3b2-epinel-battle-result-observer-v4-in-micron.ps1' =
            'complete-phase3b2-epinel-solo-raid-regroup-repair-v5-in-micron.ps1'
        'Start-Phase3B2-Epinel-BattleResultObserver-v4.ps1' =
            'Start-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1'
        'start-phase3b2-epinel-battle-result-observer-v4-in-micron.ps1' =
            'start-phase3b2-epinel-solo-raid-regroup-repair-v5-in-micron.ps1'
        'ac93f0333c3a0f495fae4834fb1b8dc5d2ec79f811d72f5872be0bfe63b0bd6c' =
            $candidateDllSha256
        'f1baf07687370cab97983458942c3e50b7ee859b92216e4aa384f8697d22c79b' =
            $sourceManifestSha256
        'nll/phase3b2-epinel-battle-result-observer-start/v4' =
            'nll/phase3b2-epinel-solo-raid-regroup-repair-start/v5'
        'nll/phase3b2-epinel-battle-result-observer-validation/v4' =
            'nll/phase3b2-epinel-solo-raid-regroup-repair-validation/v5'
        'nll/phase3b2-epinel-battle-result-observer-failure/v4' =
            'nll/phase3b2-epinel-solo-raid-regroup-repair-failure/v5'
        'nll/phase3b2-epinel-battle-result-observer-completion/v4' =
            'nll/phase3b2-epinel-solo-raid-regroup-repair-completion/v5'
    }
    $derivedTexts = [ordered]@{}
    foreach ($role in $parentToolPaths.Keys) {
        $parentText = (Get-Content -LiteralPath $parentToolPaths[$role] `
            -Raw -Encoding UTF8).Replace("`r`n", "`n")
        $roleReplacements = [ordered]@{}
        foreach ($key in $commonReplacements.Keys) {
            if ($parentText.Contains([string]$key)) {
                $roleReplacements[$key] = $commonReplacements[$key]
            }
        }
        Assert-True ($roleReplacements.Count -gt 0) `
            ('phase3b2_regroup_repair_v5_derive_' + $role + `
                ':no_applicable_replacement')
        $derivedTexts[$role] = Get-DerivedText `
            -Path $parentToolPaths[$role] `
            -Replacements $roleReplacements `
            -FailureCode ('phase3b2_regroup_repair_v5_derive_' + $role)
    }

    $outerStartNeedle = @'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$cacheLinkPath = Join-Path $serverRoot 'cache'
'@
    $outerStartReplacement = @'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$log4netConfigPath = Join-Path $serverRoot 'log4net.config'
$expectedLog4netConfigSha256 =
    '31b873b3ad156436f0a55f54f1518fde9e2e6c0059cca3ec2e3b181c08c448b9'
$cacheLinkPath = Join-Path $serverRoot 'cache'
'@
    $derivedTexts.outerStart = Replace-ExactlyOnce `
        -Text $derivedTexts.outerStart -Before $outerStartNeedle `
        -After $outerStartReplacement `
        -FailureCode 'phase3b2_regroup_repair_v5_outer_config_path_injection'
    $derivedTexts.outerStart = Replace-ExactlyOnce `
        -Text $derivedTexts.outerStart `
        -Before @'
    $innerStartPath, $databasePath, $serverExePath, $serverDllPath,
    $catalogContractPath, $sausContractPath, $headerPath
'@ `
        -After @'
    $innerStartPath, $databasePath, $serverExePath, $serverDllPath,
    $log4netConfigPath, $catalogContractPath, $sausContractPath, $headerPath
'@ `
        -FailureCode 'phase3b2_regroup_repair_v5_outer_config_required_injection'
    $derivedTexts.outerStart = Replace-ExactlyOnce `
        -Text $derivedTexts.outerStart `
        -Before @'
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Item -LiteralPath $headerPath).Length -eq
'@ `
        -After @'
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $log4netConfigPath) -ceq
        $expectedLog4netConfigSha256 -and
    (Get-Item -LiteralPath $headerPath).Length -eq
'@ `
        -FailureCode 'phase3b2_regroup_repair_v5_outer_config_digest_injection'

    $completionFunctionNeedle = @'
$expectedDbSha256 = `
'@
    $completionFunctionReplacement = @'
function Get-TrialRecordMetrics {
    param([string]$Path)
    $database = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $levels = @(
        foreach ($user in @($database.Users)) {
            if ($null -eq $user.SoloRaidData) { continue }
            foreach ($manager in @($user.SoloRaidData.PSObject.Properties)) {
                foreach ($level in @($manager.Value.SoloRaidLevels)) {
                    if ([int]$level.Type -eq 2 -and [int]$level.RaidLevel -eq 8) {
                        $level
                    }
                }
            }
        }
    )
    $raidJoinCount = 0L
    $recordCount = 0L
    $totalDamage = 0L
    foreach ($level in $levels) {
        $raidJoinCount += [long]$level.RaidJoinCount
        $recordCount += [long]@($level.Logs).Count
        $totalDamage += [long]$level.TotalDamage
    }
    [ordered]@{
        levelCount = $levels.Count
        raidJoinCount = $raidJoinCount
        recordCount = $recordCount
        totalDamage = $totalDamage
    }
}

$expectedDbSha256 = `
'@
    $derivedTexts.innerCompletion = Replace-ExactlyOnce `
        -Text $derivedTexts.innerCompletion -Before $completionFunctionNeedle `
        -After $completionFunctionReplacement `
        -FailureCode 'phase3b2_regroup_repair_v5_completion_metrics_function_injection'

    $completionObservationNeedle = @'
$redactedServerLogMatchCount = Protect-ServerLog $stdoutPath

$databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length
'@
    $completionObservationReplacement = @'
$redactedServerLogMatchCount = Protect-ServerLog $stdoutPath

$appLogRoot = Join-Path $ServerRoot 'logs'
$markerEvidencePath = Join-Path $runRoot 'regroup.observations.json'
$appLogPaths = @(Get-ChildItem -LiteralPath $appLogRoot -Filter 'app-*.log' `
    -File -ErrorAction SilentlyContinue)
$debugLineCount = 0
$rawPayloadPatternCount = 0
if ($appLogPaths.Count -gt 0) {
    $appLogText = (($appLogPaths | ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
            }) -join "`n")
    $debugLineCount = [regex]::Matches($appLogText, '(?m)\sDEBUG\s').Count
    $rawPayloadPatternCount = [regex]::Matches(
        $appLogText,
        '(?i)Reading ReqSetSoloRaidTrialDamage|antiCheatBattleData|"characters"'
    ).Count
    $markerPattern =
        'NLL_BATTLE_RESULT_OBSERVATION/v1\s+' +
        'utc=(?<utc>\S+)\s+sequence=(?<sequence>\d+)\s+' +
        'route=(?<route>\S+)\s+battleResult=(?<battleResult>-?\d+)'
    $observations = @(
        foreach ($match in [regex]::Matches($appLogText, $markerPattern)) {
            [ordered]@{
                utc = [string]$match.Groups['utc'].Value
                sequence = [long]$match.Groups['sequence'].Value
                route = [string]$match.Groups['route'].Value
                battleResult = [int]$match.Groups['battleResult'].Value
            }
        }
    )
    $markerEvidence = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-regroup-marker-evidence/v5'
        assessmentUid = [string]$pointer.assessmentUid
        observationCount = $observations.Count
        observations = $observations
        rawRequestPayloadPersisted = $false
    }
    Write-AtomicUtf8NoBom $markerEvidencePath `
        (($markerEvidence | ConvertTo-Json -Depth 6) + "`n")
}
else {
    Assert-True (Test-Path -LiteralPath $markerEvidencePath -PathType Leaf) `
        'phase3b2_regroup_repair_v5_marker_missing_after_partial_completion'
    $markerEvidence = Get-Content -LiteralPath $markerEvidencePath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True (
        $markerEvidence.contractId -ceq
            'nll/phase3b2-epinel-solo-raid-regroup-marker-evidence/v5' -and
        [string]$markerEvidence.assessmentUid -ceq
            [string]$pointer.assessmentUid -and
        -not $markerEvidence.rawRequestPayloadPersisted
    ) 'phase3b2_regroup_repair_v5_existing_marker_invalid'
    $observations = @($markerEvidence.observations)
}
$markerEvidenceSha256 = Get-Sha256Hex $markerEvidencePath
$markerEvidenceSafe = $debugLineCount -eq 0 -and
    $rawPayloadPatternCount -eq 0
foreach ($appLogPath in $appLogPaths) {
    Remove-Item -LiteralPath $appLogPath.FullName -Force
}
$runtimeAppLogsRemoved = @(
    Get-ChildItem -LiteralPath $appLogRoot -Filter 'app-*.log' -File `
        -ErrorAction SilentlyContinue
).Count -eq 0

$trialMetricsBefore = Get-TrialRecordMetrics $dbBeforePath
$trialMetricsAfter = Get-TrialRecordMetrics $dbPath
$observedRegroupCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 6
    }).Count
$observedLegacyRetryCount = @($observations | Where-Object {
        [int]$_.battleResult -eq 4
    }).Count
$unsupportedBattleResultCount = @($observations | Where-Object {
        [int]$_.battleResult -notin @(4, 6)
    }).Count
$regroupNonConsumptionVerified = $markerEvidenceSafe -and
    $observedRegroupCount -gt 0 -and
    $unsupportedBattleResultCount -eq 0 -and
    [long]$trialMetricsAfter.raidJoinCount -eq
        [long]$trialMetricsBefore.raidJoinCount -and
    [long]$trialMetricsAfter.recordCount -eq
        [long]$trialMetricsBefore.recordCount -and
    [long]$trialMetricsAfter.totalDamage -eq
        [long]$trialMetricsBefore.totalDamage

$databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length
'@
    $derivedTexts.innerCompletion = Replace-ExactlyOnce `
        -Text $derivedTexts.innerCompletion -Before $completionObservationNeedle `
        -After $completionObservationReplacement `
        -FailureCode 'phase3b2_regroup_repair_v5_completion_observation_injection'

    $completionReceiptNeedle = @'
    rawSensitiveServerLogPersisted = $false
    serverStderrByteLength = $stderrLength
'@
    $completionReceiptReplacement = @'
    rawSensitiveServerLogPersisted = $false
    markerOnlyEvidencePersisted = $true
    markerEvidenceSha256 = $markerEvidenceSha256
    regroupObservationCount = $observations.Count
    observedRegroupResultCount = $observedRegroupCount
    observedLegacyRetryResultCount = $observedLegacyRetryCount
    unsupportedBattleResultCount = $unsupportedBattleResultCount
    observedBattleResults = @($observations | ForEach-Object {
            [int]$_.battleResult
        })
    debugRuntimeLogLineCount = $debugLineCount
    rawRequestPayloadPatternCount = $rawPayloadPatternCount
    rawRequestPayloadPersistedAfterCompletion = $false
    runtimeAppLogsRemoved = $runtimeAppLogsRemoved
    trialMetricsBefore = $trialMetricsBefore
    trialMetricsAfter = $trialMetricsAfter
    regroupNonConsumptionVerified = $regroupNonConsumptionVerified
    serverStderrByteLength = $stderrLength
'@
    $derivedTexts.innerCompletion = Replace-ExactlyOnce `
        -Text $derivedTexts.innerCompletion -Before $completionReceiptNeedle `
        -After $completionReceiptReplacement `
        -FailureCode 'phase3b2_regroup_repair_v5_completion_receipt_injection'

    $stagedToolPaths = [ordered]@{}
    $toolManifest = @()
    foreach ($role in $targetToolNames.Keys) {
        $path = Join-Path $toolStagingRoot $targetToolNames[$role]
        Write-Utf8NoBom $path ($derivedTexts[$role].TrimEnd() + "`n")
        Assert-PowerShellSyntax $path `
            ('phase3b2_regroup_repair_v5_' + $role + '_syntax_invalid')
        $stagedToolPaths[$role] = $path
        $toolManifest += [ordered]@{
            roleCode = $role
            leaf = $targetToolNames[$role]
            byteLength = (Get-Item -LiteralPath $path).Length
            sha256 = Get-Sha256Hex $path
        }
    }

    if ($AuditOnly -and -not $RepairExistingCompletion) {
        [pscustomobject]@{
            schemaVersion = 1
            contractId =
                'nll/phase3b2-epinel-solo-raid-regroup-repair-deployment-audit/v5'
            auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            parentFingerprintSha256 = $parentFingerprintBefore
            sourceManifestSha256 = $sourceManifestSha256
            candidateServerDllByteLength = $candidateDllByteLength
            candidateServerDllSha256 = $candidateDllSha256
            observedRegroupBattleResult = 6
            legacyRetryBattleResultPreserved = 4
            selectedManagerPassedCount = 101
            selectedManagerFailedCount = 0
            debugFileLoggingDisabled = $true
            markerOnlyEvidencePlanned = $true
            projectedTools = $toolManifest
            deployable = $true
        } | ConvertTo-Json -Depth 8
        return
    }

    if ($RepairExistingCompletion) {
        $incidentAssessmentUid = 'd7d5b339-4b66-4403-9dda-229cab797abf'
        $incidentRunRoot = Join-Path $targetEvidenceRoot $incidentAssessmentUid
        $activePointerPath = Join-Path $targetEvidenceRoot `
            'active-run.pointer.json'
        $runStartPath = Join-Path $incidentRunRoot 'run-start.receipt.json'
        $markerPath = Join-Path $incidentRunRoot 'regroup.observations.json'
        $completionPath = Join-Path $incidentRunRoot `
            'completion.receipt.json'
        $installedInnerCompletionPath = Join-Path $toolRoot `
            $targetToolNames.innerCompletion
        $micronHostsPath = Join-Path $micronDrive `
            'Windows\System32\drivers\etc\hosts'
        $deploymentPath = Join-Path $targetDeploymentRoot `
            'deployment.receipt.json'
        $pointer = Get-Content -LiteralPath $activePointerPath -Raw `
            -Encoding UTF8 | ConvertFrom-Json
        $marker = Get-Content -LiteralPath $markerPath -Raw `
            -Encoding UTF8 | ConvertFrom-Json
        Assert-True (
            (Get-Sha256Hex $deploymentPath) -ceq
                '90179010e5c82fba6ff4d699fb0f913fa0f878b1100938e74645a3555752dc8a' -and
            (Get-Sha256Hex $activePointerPath) -ceq
                '7f346a410c20ec3a6b12af7e63d2728a229d1b5cde62e0249399b7bd41ee2217' -and
            [string]$pointer.assessmentUid -ceq $incidentAssessmentUid -and
            (Get-Sha256Hex $runStartPath) -ceq
                'e75322fd80a98c592edb6db377729b58fa3114c0cb6c3b45bfb67d73ec21f1b3' -and
            (Get-Sha256Hex $markerPath) -ceq
                '94e0237ca0e052a64edd2b80473b2a3195346580c19c393f45e1b80c0dcec047' -and
            $marker.contractId -ceq
                'nll/phase3b2-epinel-solo-raid-regroup-marker-evidence/v5' -and
            [int]$marker.observationCount -eq 6 -and
            @($marker.observations | Where-Object {
                    [int]$_.battleResult -notin @(4, 6)
                }).Count -eq 0 -and
            @($marker.observations | Where-Object {
                    [int]$_.battleResult -eq 6
                }).Count -eq 2 -and
            (Get-Sha256Hex (Join-Path $targetRuntimeRoot 'db.json')) -ceq
                '2e115d568b4f1840f758062eddb96bcea11dc097cfdf60e66478f00908fafe14' -and
            (Get-Sha256Hex $micronHostsPath) -ceq
                '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64' -and
            (Get-Sha256Hex $installedInnerCompletionPath) -ceq
                '2317140e9717ec71fbbcac6a3266723a1889a67869aac26665634cf9ecc4d147' -and
            (Get-Sha256Hex $parentToolPaths.outerStart) -ceq
                $expectedParentToolDigests.outerStart -and
            (Get-Sha256Hex (Join-Path $toolRoot `
                    $targetToolNames.outerCompletion)) -ceq
                '42f0dd1d9af9e34814baa1d7a4f3f760b57df861cb274a8449b872887420db69' -and
            -not (Test-Path -LiteralPath $completionPath) -and
            @(Get-ChildItem -LiteralPath (Join-Path $targetRuntimeRoot 'logs') `
                -Filter 'app-*.log' -File -ErrorAction SilentlyContinue).Count `
                -eq 0 -and
            @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
                NikkeLocalLab.Phase3B2.PhysicalBootstrap `
                -ErrorAction SilentlyContinue).Count -eq 0
        ) 'phase3b2_regroup_repair_v5_existing_completion_repair_input_invalid'

        $correctedInnerCompletionPath = $stagedToolPaths.innerCompletion
        Assert-True (
            (Get-Sha256Hex $correctedInnerCompletionPath) -ceq
                'cbb2fb3dd75ca038e5da8afcd128ef20c07710973eadefa79866353b8b5f1a90'
        ) 'phase3b2_regroup_repair_v5_corrected_completion_projection_invalid'

        if ($AuditOnly) {
            [pscustomobject]@{
                schemaVersion = 1
                contractId =
                    'nll/phase3b2-epinel-solo-raid-regroup-completion-repair-audit/v1'
                auditedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                assessmentUid = $incidentAssessmentUid
                activePointerSha256 = Get-Sha256Hex $activePointerPath
                markerEvidenceSha256 = Get-Sha256Hex $markerPath
                observedBattleResults = @($marker.observations |
                    ForEach-Object { [int]$_.battleResult })
                currentInnerCompletionSha256 =
                    Get-Sha256Hex $installedInnerCompletionPath
                correctedInnerCompletionSha256 =
                    Get-Sha256Hex $correctedInnerCompletionPath
                runtimeCold = $true
                databaseModified = $false
                hostsModified = $false
                activePointerModified = $false
                repairApplicable = $true
            } | ConvertTo-Json -Depth 8
            return
        }

        $repairUid = [Guid]::NewGuid().ToString('D')
        $repairRoot = Join-Path $targetDeploymentRoot `
            ('completion-repair-v1\' + $repairUid)
        $protectedRepairRoot = Join-Path $protectedBase `
            ('CompletionRepair-v1\' + $repairUid)
        New-Item -ItemType Directory -Path $repairRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $protectedRepairRoot -Force |
            Out-Null
        Copy-Item -LiteralPath $installedInnerCompletionPath -Destination `
            (Join-Path $protectedRepairRoot `
                'prior-inner-completion.ps1')
        Copy-Item -LiteralPath $correctedInnerCompletionPath -Destination `
            $installedInnerCompletionPath -Force
        Assert-True (
            (Get-Sha256Hex $installedInnerCompletionPath) -ceq
                'cbb2fb3dd75ca038e5da8afcd128ef20c07710973eadefa79866353b8b5f1a90'
        ) 'phase3b2_regroup_repair_v5_corrected_completion_apply_failed'

        $repairReceipt = [ordered]@{
            schemaVersion = 1
            contractId =
                'nll/phase3b2-epinel-solo-raid-regroup-completion-repair/v1'
            repairedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            repairUid = $repairUid
            assessmentUid = $incidentAssessmentUid
            causeCode = 'empty_baseline_measure_sum_strict_mode_failure'
            recoveryCode =
                'zero_safe_metrics_and_existing_marker_reuse'
            deploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
            activePointerSha256 = Get-Sha256Hex $activePointerPath
            runStartReceiptSha256 = Get-Sha256Hex $runStartPath
            markerEvidenceSha256 = Get-Sha256Hex $markerPath
            observedBattleResults = @($marker.observations | ForEach-Object {
                    [int]$_.battleResult
                })
            observedRegroupResultCount = 2
            observedLegacyRetryResultCount = 4
            priorInnerCompletionSha256 =
                '2317140e9717ec71fbbcac6a3266723a1889a67869aac26665634cf9ecc4d147'
            repairedInnerCompletionSha256 =
                'cbb2fb3dd75ca038e5da8afcd128ef20c07710973eadefa79866353b8b5f1a90'
            outerCompletionModified = $false
            runtimeModified = $false
            databaseModified = $false
            hostsModified = $false
            activePointerModified = $false
            markerEvidenceModified = $false
            goldenModified = $false
            dLobbyGoldenModified = $false
            serverExecutionStarted = $false
            clientExecutionStarted = $false
            nextStepCode =
                'boot_micron_nlloperator_run_completion_only_without_start'
        }
        Write-AtomicJson (Join-Path $repairRoot 'repair.receipt.json') `
            $repairReceipt
        Copy-Item -LiteralPath (Join-Path $repairRoot `
            'repair.receipt.json') -Destination $protectedRepairRoot
        [pscustomobject]@{
            Receipt = $repairReceipt
            MicronReceiptPath = Join-Path $repairRoot 'repair.receipt.json'
            MicronReceiptSha256 = Get-Sha256Hex (Join-Path $repairRoot `
                'repair.receipt.json')
            ProtectedReceiptPath = Join-Path $protectedRepairRoot `
                'repair.receipt.json'
            MicronCompletionCommand =
                "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1' -ObservedStageCode season26_challenge_squad -OutcomeCode operator_abort"
        } | ConvertTo-Json -Depth 10
        return
    }

    Assert-True (
        -not (Test-Path -LiteralPath $targetRuntimeRoot) -and
        -not (Test-Path -LiteralPath $targetEvidenceRoot) -and
        -not (Test-Path -LiteralPath $targetDeploymentRoot) -and
        @($targetToolNames.Values | Where-Object {
                Test-Path -LiteralPath (Join-Path $toolRoot $_)
            }).Count -eq 0
    ) 'phase3b2_regroup_repair_v5_target_collision'

    $deploymentUid = [Guid]::NewGuid().ToString('D')
    $runtimeStagingRoot = $targetRuntimeRoot + '.staging-' +
        [Guid]::NewGuid().ToString('N')
    $deploymentStagingRoot = $targetDeploymentRoot + '.staging-' +
        [Guid]::NewGuid().ToString('N')
    $protectedRoot = Join-Path $protectedBase $deploymentUid

    New-Item -ItemType Directory -Path $runtimeStagingRoot | Out-Null
    foreach ($entry in @(Get-ChildItem -LiteralPath $parentRuntimeRoot -Force)) {
        if ($entry.Name -in @(
                'cache', 'logs', 'EpinelPS.dll', 'log4net.config'
            )) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $runtimeStagingRoot `
            -Recurse
    }
    Copy-Item -LiteralPath $candidateDllPath -Destination `
        (Join-Path $runtimeStagingRoot 'EpinelPS.dll')
    $parentLogConfigText = Get-Content -LiteralPath `
        (Join-Path $parentRuntimeRoot 'log4net.config') -Raw -Encoding UTF8
    Assert-True (
        ([regex]::Matches($parentLogConfigText,
                [regex]::Escape('<level value="DEBUG" />'))).Count -eq 1
    ) 'phase3b2_regroup_repair_v5_log_config_shape_invalid'
    $infoLogConfigText = $parentLogConfigText.Replace(
        '<level value="DEBUG" />', '<level value="INFO" />'
    )
    Write-Utf8NoBom (Join-Path $runtimeStagingRoot 'log4net.config') `
        $infoLogConfigText
    New-Item -ItemType Directory -Path (Join-Path $runtimeStagingRoot 'logs') |
        Out-Null
    New-ExactJunction -Path (Join-Path $runtimeStagingRoot 'cache') `
        -Target $bootCacheTarget `
        -FailureCode 'phase3b2_regroup_repair_v5_cache_link_failed'
    Assert-True (
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'db.json')) -ceq
            $expectedDatabaseSha256 -and
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'EpinelPS.exe')) -ceq
            $expectedServerExeSha256 -and
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'EpinelPS.dll')) -ceq
            $candidateDllSha256 -and
        (Get-Sha256Hex (Join-Path $runtimeStagingRoot 'log4net.config')) -ceq
            $expectedInfoLogConfigSha256 -and
        @(Get-ChildItem -LiteralPath (Join-Path $runtimeStagingRoot 'logs') `
            -Force).Count -eq 0
    ) 'phase3b2_regroup_repair_v5_runtime_staging_invalid'

    New-Item -ItemType Directory -Path $deploymentStagingRoot | Out-Null
    Write-Utf8NoBom (Join-Path $deploymentStagingRoot 'source.manifest.tsv') `
        $sourceManifestText
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-epinel-solo-raid-regroup-repair-deployment/v5'
        deployedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        deploymentUid = $deploymentUid
        parentLaneCode = 'epinel_solo_raid_battle_result_observer_v4'
        derivedLaneCode = 'epinel_solo_raid_regroup_repair_v5'
        parentFingerprintSha256 = $parentFingerprintBefore
        parentCompletionAssessmentUid =
            '41982aef-b3d7-4ec7-ad90-4bdff1d95500'
        parentCompletionReceiptSha256 = $expectedParentCompletionSha256
        sourceManifestMemberCount = $sourceMembers.Count
        sourceManifestSha256 = $sourceManifestSha256
        parentServerDllSha256 = $expectedParentDllSha256
        baselineDatabaseSha256 = $expectedDatabaseSha256
        serverExeSha256 = $expectedServerExeSha256
        appliedServerDllByteLength = $candidateDllByteLength
        appliedServerDllSha256 = $candidateDllSha256
        infoLogConfigSha256 = $expectedInfoLogConfigSha256
        observedRegroupBattleResult = 6
        legacyRetryBattleResultPreserved = 4
        nonConsumingTrialResultPolicyCode =
            'legacy_retry_4_or_observed_regroup_6'
        selectedManagerPassedCount = 101
        selectedManagerFailedCount = 0
        infoOnlyRuntimeFileLogging = $true
        markerOnlyEvidenceEnabled = $true
        rawDebugRequestLoggingEnabled = $false
        battleResultObservationRetained = $true
        practiceSemanticsModified = $false
        databaseModified = $false
        cacheModified = $false
        parentRuntimeModified = $false
        parentToolsModified = $false
        micronLobbyGoldenModified = $false
        dLobbyGoldenModified = $false
        historicalReceiptBindingApplied = $false
        wrapperSelfHashBindingApplied = $false
        installedTools = $toolManifest
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        validationRunConsumed = $false
        rollbackCode = 'leave_v5_inert_and_select_untouched_v4_or_v3'
        nextStepCode =
            'boot_micron_nlloperator_run_one_challenge_regroup_reentry_validation'
    }
    Write-AtomicJson (Join-Path $deploymentStagingRoot `
        'deployment.receipt.json') $receipt

    Move-Item -LiteralPath $runtimeStagingRoot -Destination $targetRuntimeRoot
    $runtimeStagingRoot = $null
    New-Item -ItemType Directory -Path $targetEvidenceRoot | Out-Null
    Move-Item -LiteralPath $deploymentStagingRoot `
        -Destination $targetDeploymentRoot
    $deploymentStagingRoot = $null
    foreach ($role in $stagedToolPaths.Keys) {
        Copy-Item -LiteralPath $stagedToolPaths[$role] -Destination `
            (Join-Path $toolRoot $targetToolNames[$role])
    }
    New-Item -ItemType Directory -Path $protectedRoot -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $targetDeploymentRoot `
        'deployment.receipt.json') -Destination $protectedRoot
    Copy-Item -LiteralPath (Join-Path $targetDeploymentRoot `
        'source.manifest.tsv') -Destination $protectedRoot

    $parentFingerprintAfter = Get-CriticalFingerprint `
        -RuntimeRoot $parentRuntimeRoot -ToolPaths $parentToolPaths `
        -ReceiptPaths @($parentDeploymentReceiptPath, $parentCompletionPath)
    Assert-True (
        $parentFingerprintAfter -ceq $parentFingerprintBefore -and
        -not (Test-Path -LiteralPath (Join-Path $targetEvidenceRoot `
                'active-run.pointer.json')) -and
        @($targetToolNames.Values | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $toolRoot $_) `
                    -PathType Leaf)
            }).Count -eq 0
    ) 'phase3b2_regroup_repair_v5_post_deploy_invalid'

    $receiptPath = Join-Path $targetDeploymentRoot 'deployment.receipt.json'
    [pscustomobject]@{
        Receipt = $receipt
        MicronReceiptPath = $receiptPath
        MicronReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        MicronReceiptSha256 = Get-Sha256Hex $receiptPath
        ProtectedReceiptPath = Join-Path $protectedRoot `
            'deployment.receipt.json'
        MicronStartCommand =
            "& 'C:\NLL\Tools\Start-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1' -ValidationKind Challenge"
        MicronCompletionCommand =
            "& 'C:\NLL\Tools\Complete-Phase3B2-Epinel-SoloRaidRegroupRepair-v5.ps1' -ObservedStageCode season26_challenge_squad -OutcomeCode operator_abort"
    } | ConvertTo-Json -Depth 10
}
finally {
    if (Test-Path -LiteralPath $toolStagingRoot) {
        Remove-Item -LiteralPath $toolStagingRoot -Recurse -Force
    }
    if ($null -ne $runtimeStagingRoot -and
        (Test-Path -LiteralPath $runtimeStagingRoot)) {
        Remove-Item -LiteralPath $runtimeStagingRoot -Recurse -Force
    }
    if ($null -ne $deploymentStagingRoot -and
        (Test-Path -LiteralPath $deploymentStagingRoot)) {
        Remove-Item -LiteralPath $deploymentStagingRoot -Recurse -Force
    }
}
