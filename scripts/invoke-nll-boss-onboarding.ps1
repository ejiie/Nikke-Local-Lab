[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 1000000)]
    [int]$SeasonNumber,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z][a-z0-9._-]{0,63}$')]
    [string]$ProfileCode,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z][a-z0-9._-]{0,63}$')]
    [string]$DisplayNameCode,

    [Parameter(Mandatory = $true)]
    [string]$MaterializerPath,

    [string]$MaterializerHostPath = '',

    [Parameter(Mandatory = $true)]
    [string]$StaticDataPackPath,

    [Parameter(Mandatory = $true)]
    [string]$GameConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$SourceDatabasePath,

    [Parameter(Mandatory = $true)]
    [string]$AssetCacheRoot,

    [Parameter(Mandatory = $true)]
    [string]$PythonPath,

    [Parameter(Mandatory = $true)]
    [string]$UnityPyRoot,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot,

    [string]$RegistryRoot = (Join-Path $PSScriptRoot '..\config\boss-runtime-variants'),

    [switch]$ReplaceExistingProfile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Onboarding([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw $Code }
}

function Get-Sha256Lower([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicUtf8([string]$Path, [string]$Text) {
    $temporary = $Path + '.partial-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary, $Text, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $Path, $true)
}

foreach ($name in @(
        'MaterializerPath', 'StaticDataPackPath', 'GameConfigPath',
        'SourceDatabasePath', 'PythonPath')) {
    $resolved = [IO.Path]::GetFullPath((Get-Variable -Name $name -ValueOnly))
    Set-Variable -Name $name -Value $resolved
    Assert-Onboarding (Test-Path -LiteralPath $resolved -PathType Leaf) `
        'boss_onboarding_input_missing'
}
if (-not [string]::IsNullOrWhiteSpace($MaterializerHostPath)) {
    $MaterializerHostPath = [IO.Path]::GetFullPath($MaterializerHostPath)
    Assert-Onboarding (Test-Path -LiteralPath $MaterializerHostPath -PathType Leaf) `
        'boss_onboarding_input_missing'
}
$materializerCommand = if ([string]::IsNullOrWhiteSpace($MaterializerHostPath)) {
    $MaterializerPath
}
else {
    $MaterializerHostPath
}
[string[]]$materializerPrefix = if ([string]::IsNullOrWhiteSpace($MaterializerHostPath)) {
    @()
}
else {
    @($MaterializerPath)
}
$AssetCacheRoot = [IO.Path]::GetFullPath($AssetCacheRoot)
$UnityPyRoot = [IO.Path]::GetFullPath($UnityPyRoot)
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$RegistryRoot = [IO.Path]::GetFullPath($RegistryRoot)
Assert-Onboarding `
    ((Test-Path -LiteralPath $AssetCacheRoot -PathType Container) -and
     (Test-Path -LiteralPath $UnityPyRoot -PathType Container) -and
     (Test-Path -LiteralPath $RegistryRoot -PathType Container)) `
    'boss_onboarding_input_missing'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$behaviorInspector = Join-Path $repositoryRoot `
    'scripts\inspect-nll-boss-behavior-assets.py'
$profileAssembler = Join-Path $repositoryRoot `
    'scripts\materialize-nll-boss-runtime-profile.py'
$registryPath = Join-Path $RegistryRoot 'registry.json'
foreach ($path in @($behaviorInspector, $profileAssembler, $registryPath)) {
    Assert-Onboarding (Test-Path -LiteralPath $path -PathType Leaf) `
        'boss_onboarding_pipeline_input_missing'
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$discoveryPath = Join-Path $OutputRoot 'content-discovery.receipt.json'
$behaviorReceiptPath = Join-Path $OutputRoot 'behavior-assembly.receipt.json'
$candidateProfilePath = Join-Path $OutputRoot 'boss-runtime-variant.profile.json'
$candidateReceiptPath = Join-Path $OutputRoot 'onboarding-candidate.receipt.json'
$admissionReceiptPath = Join-Path $OutputRoot 'onboarding-admission.receipt.json'
$variantRoot = Join-Path $OutputRoot 'five-affinity-variants'
$privateDiscoveryPath = Join-Path ([IO.Path]::GetTempPath()) `
    ('nll-boss-private-' + [guid]::NewGuid().ToString('N') + '.json')
foreach ($path in @(
        $discoveryPath, $behaviorReceiptPath, $candidateProfilePath,
        $candidateReceiptPath, $admissionReceiptPath, $privateDiscoveryPath)) {
    Assert-Onboarding (-not (Test-Path -LiteralPath $path)) `
        'boss_onboarding_output_exists'
}
Assert-Onboarding (-not (Test-Path -LiteralPath $variantRoot)) `
    'boss_onboarding_output_exists'

try {
    & $materializerCommand @materializerPrefix `
        --discover-boss-content $discoveryPath `
        --private-discovery-output $privateDiscoveryPath `
        --static-pack $StaticDataPackPath `
        --game-config $GameConfigPath `
        --season-number ([string]$SeasonNumber) `
        --profile-code $ProfileCode `
        --display-name-code $DisplayNameCode | Out-Null
    Assert-Onboarding ($LASTEXITCODE -eq 0) 'boss_onboarding_static_discovery_failed'

    $behaviorBundles = @(Get-ChildItem -LiteralPath $AssetCacheRoot -File -Recurse |
        Where-Object { $_.Name -cmatch '^externalbehavior_assets_all_[0-9a-f]+\.bundle$' })
    $behaviorIdentities = @($behaviorBundles | Group-Object {
        ([string]$_.Length) + ':' + (Get-Sha256Lower $_.FullName)
    })
    Assert-Onboarding ($behaviorIdentities.Count -gt 0) `
        'boss_onboarding_behavior_bundle_missing'
    $resolvedBehaviorReceipts = [Collections.Generic.List[string]]::new()
    foreach ($identity in $behaviorIdentities) {
        $probeReceipt = Join-Path $OutputRoot `
            ('.behavior-probe-' + [guid]::NewGuid().ToString('N') + '.json')
        & $PythonPath $behaviorInspector `
            --source-discovery $discoveryPath `
            --private-discovery $privateDiscoveryPath `
            --behavior-bundle $identity.Group[0].FullName `
            --unitypy-root $UnityPyRoot `
            --output $probeReceipt 2>$null
        if ($LASTEXITCODE -eq 0 -and
            (Test-Path -LiteralPath $probeReceipt -PathType Leaf)) {
            $resolvedBehaviorReceipts.Add($probeReceipt)
        }
        elseif (Test-Path -LiteralPath $probeReceipt -PathType Leaf) {
            Remove-Item -LiteralPath $probeReceipt -Force
        }
    }
    Assert-Onboarding ($resolvedBehaviorReceipts.Count -eq 1) `
        'boss_onboarding_behavior_closure_not_unique'
    Move-Item -LiteralPath $resolvedBehaviorReceipts[0] `
        -Destination $behaviorReceiptPath

    & $PythonPath $profileAssembler `
        --source-discovery $discoveryPath `
        --private-discovery $privateDiscoveryPath `
        --behavior-receipt $behaviorReceiptPath `
        --asset-cache-root $AssetCacheRoot `
        --profile-output $candidateProfilePath `
        --receipt-output $candidateReceiptPath
    Assert-Onboarding ($LASTEXITCODE -eq 0) 'boss_onboarding_profile_assembly_failed'

    $validationOutput = @(& $materializerCommand @materializerPrefix `
        --validate-boss-variant-profile $candidateProfilePath)
    Assert-Onboarding ($LASTEXITCODE -eq 0 -and $validationOutput.Count -gt 0) `
        'boss_onboarding_profile_validation_failed'
    $validation = $validationOutput[-1] | ConvertFrom-Json
    Assert-Onboarding `
        ($validation.contractId -ceq `
            'nll/boss-runtime-variant-profile-validation/v1' -and
         [int]$validation.seasonNumber -eq $SeasonNumber -and
         [string]$validation.profileCode -ceq $ProfileCode) `
        'boss_onboarding_profile_validation_failed'

    New-Item -ItemType Directory -Path $variantRoot | Out-Null
    $targetBossElementByWeakness = @{
        fire = 'wind'; water = 'fire'; wind = 'iron';
        electric = 'water'; iron = 'electric'
    }
    $profile = Get-Content -LiteralPath $candidateProfilePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $variantReceipts = [Collections.Generic.List[object]]::new()
    foreach ($weaknessCode in @('fire', 'water', 'wind', 'electric', 'iron')) {
        $variantPath = Join-Path $variantRoot ($weaknessCode + '.pack')
        $receiptPath = Join-Path $variantRoot ($weaknessCode + '.receipt.json')
        & $materializerCommand @materializerPrefix `
            --create-static-data-variant $variantPath `
            --source-db $SourceDatabasePath `
            --game-config $GameConfigPath `
            --boss-variant-profile $candidateProfilePath `
            --weakness-code $weaknessCode `
            --source-static-pack $StaticDataPackPath `
            --variant-static-pack $variantPath `
            --variant-static-data-receipt $receiptPath | Out-Null
        Assert-Onboarding ($LASTEXITCODE -eq 0) `
            'boss_onboarding_affinity_variant_failed'
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $expectedVariant = $weaknessCode -cne `
            [string]$profile.sourceAffinity.weaknessCode
        $expectedFunctionMinimum = if (
            $expectedVariant -and
            [string]$profile.elementShield.modeCode -ceq 'dynamic_affinity_linked') {
            1
        }
        else { 0 }
        $expectedModifiedMonsterCount = if ($expectedVariant) { 1 } else { 0 }
        $shieldReceiptValid = $true
        if ([string]$profile.elementShield.modeCode -ceq 'dynamic_affinity_linked') {
            $targetFxVariants = @($profile.elementShield.fxVariants | Where-Object {
                [string]$_.bossElementCode -ceq `
                    [string]$targetBossElementByWeakness[$weaknessCode]
            })
            $shieldReceiptValid = $targetFxVariants.Count -eq 1
            if ($shieldReceiptValid) {
                $receiptBundles = @($receipt.shieldFxAssetBundles)
                $expectedBundles = @($targetFxVariants[0].mappings |
                    ForEach-Object { $_.assetBundles } |
                    Group-Object { ([string]$_.byteLength) + ':' + [string]$_.sha256 } |
                    ForEach-Object { $_.Group[0] })
                $shieldReceiptValid =
                    [string]$receipt.shieldFxMappingSetSha256 -ceq `
                        [string]$targetFxVariants[0].mappingSetSha256 -and
                    $receiptBundles.Count -eq $expectedBundles.Count
                foreach ($expectedBundle in $expectedBundles) {
                    $shieldReceiptValid = $shieldReceiptValid -and @(
                        $receiptBundles | Where-Object {
                            [string]$_.sha256 -ceq [string]$expectedBundle.sha256 -and
                            [long]$_.byteLength -eq [long]$expectedBundle.byteLength
                        }).Count -eq 1
                }
            }
        }
        Assert-Onboarding `
            ($receipt.contractId -ceq `
                'nll/boss-affinity-static-data-variant/v1' -and
             [int]$receipt.seasonNumber -eq $SeasonNumber -and
             [string]$receipt.weaknessCode -ceq $weaknessCode -and
             [string]$receipt.targetBossElementCode -ceq `
                [string]$targetBossElementByWeakness[$weaknessCode] -and
             [bool]$receipt.variantRequired -eq $expectedVariant -and
             [int]$receipt.modifiedMonsterRecordCount -eq `
                $expectedModifiedMonsterCount -and
             [int]$receipt.modifiedFunctionRecordCount -ge `
                $expectedFunctionMinimum -and
             $shieldReceiptValid -and
             [bool]$receipt.rawSourceIdentifierPersisted -eq $false -and
             [bool]$receipt.officialInstallModified -eq $false -and
             (Test-Path -LiteralPath $variantPath -PathType Leaf) -eq `
                $expectedVariant) `
            'boss_onboarding_affinity_variant_receipt_invalid'
        $variantReceipts.Add([ordered]@{
            weaknessCode = $weaknessCode
            targetBossElementCode = [string]$receipt.targetBossElementCode
            variantRequired = [bool]$receipt.variantRequired
            modifiedMonsterRecordCount = [int]$receipt.modifiedMonsterRecordCount
            modifiedFunctionRecordCount = [int]$receipt.modifiedFunctionRecordCount
            receiptSha256 = Get-Sha256Lower $receiptPath
        })
    }

    $installedProfilePath = Join-Path $RegistryRoot ($ProfileCode + '.json')
    $existingProfile = Test-Path -LiteralPath $installedProfilePath -PathType Leaf
    Assert-Onboarding (-not $existingProfile -or $ReplaceExistingProfile) `
        'boss_onboarding_profile_already_registered'
    Copy-Item -LiteralPath $candidateProfilePath -Destination $installedProfilePath `
        -Force:$ReplaceExistingProfile
    $installedProfileSha256 = Get-Sha256Lower $installedProfilePath

    $registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-Onboarding `
        ($registry.contractId -ceq 'nll/boss-runtime-variant-registry/v1' -and
         [int]$registry.schemaVersion -eq 1) `
        'boss_onboarding_registry_invalid'
    $otherProfiles = @($registry.profiles | Where-Object {
        [int]$_.seasonNumber -ne $SeasonNumber -and
        [string]$_.profileCode -cne $ProfileCode
    })
    Assert-Onboarding `
        ($otherProfiles.Count -eq @($registry.profiles).Count -or
         $ReplaceExistingProfile) `
        'boss_onboarding_registry_entry_exists'
    $entry = [ordered]@{
        seasonNumber = $SeasonNumber
        profileCode = $ProfileCode
        profileRelativePath = $ProfileCode + '.json'
        profileSha256 = $installedProfileSha256
        operationalStatusCode = 'enabled'
    }
    $updatedProfiles = @($otherProfiles) + @($entry) |
        Sort-Object { [int]$_.seasonNumber }, { [string]$_.profileCode }
    $updatedRegistry = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/boss-runtime-variant-registry/v1'
        profiles = @($updatedProfiles)
    }
    Write-AtomicUtf8 $registryPath `
        (($updatedRegistry | ConvertTo-Json -Depth 12) + "`n")

    $admission = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/boss-onboarding-admission/v1'
        admittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        profileCode = $ProfileCode
        seasonNumber = $SeasonNumber
        profileSha256 = $installedProfileSha256
        registrySha256 = Get-Sha256Lower $registryPath
        skillClosureStatusCode = 'resolved'
        behaviorClosureStatusCode = 'resolved'
        elementShieldModeCode = [string]$profile.elementShield.modeCode
        fiveAffinityVariantStatusCode = 'passed'
        affinityVariants = @($variantReceipts)
        operationalStatusCode = 'enabled'
        rawSourceIdentifiersPersisted = $false
        officialInstallModified = $false
    }
    Write-AtomicUtf8 $admissionReceiptPath `
        (($admission | ConvertTo-Json -Depth 12) + "`n")
}
finally {
    if (Test-Path -LiteralPath $privateDiscoveryPath -PathType Leaf) {
        Remove-Item -LiteralPath $privateDiscoveryPath -Force
    }
}

Write-Output $admissionReceiptPath
