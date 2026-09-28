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

    [switch]$ReplaceExistingProfile,

    [switch]$CandidateOnly,
    [object]$NativeConfiguration = $null,
    [string]$FxSourceCacheRoot = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Onboarding([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw $Code }
}

function Get-Sha256Lower([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-PlainPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            Assert-Onboarding (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) `
                'boss_onboarding_reparse_forbidden'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
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
$originalAssetCacheRoot = $AssetCacheRoot
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
$fxCandidateTool = Join-Path $PSScriptRoot 'materialize-nll-shield-fx-candidate.py'
$candidateVerifier = Join-Path $PSScriptRoot 'verify-nll-boss-onboarding-candidate.py'
$registryPath = Join-Path $RegistryRoot 'registry.json'
$publisherPath = Join-Path $PSScriptRoot 'Nll.BossPublication.ps1'
foreach ($path in @($behaviorInspector, $profileAssembler, $registryPath, $publisherPath)) {
    Assert-Onboarding (Test-Path -LiteralPath $path -PathType Leaf) `
        'boss_onboarding_pipeline_input_missing'
}
$registryInitialSha256 = Get-Sha256Lower $registryPath
$publisherSha256 = Get-Sha256Lower $publisherPath
$sourceStaticSha256 = Get-Sha256Lower $StaticDataPackPath

Assert-Onboarding (-not ($CandidateOnly -and $ReplaceExistingProfile)) `
    'boss_onboarding_candidate_cannot_replace'
$inputPins = @{}
if ($CandidateOnly) {
    Assert-PlainPath $OutputRoot
    Assert-Onboarding (-not (Test-Path -LiteralPath $OutputRoot)) 'boss_onboarding_output_exists'
    foreach ($protected in @($AssetCacheRoot, $RegistryRoot, $UnityPyRoot,
            (Split-Path -Parent $StaticDataPackPath), (Split-Path -Parent $SourceDatabasePath))) {
        Assert-PlainPath $protected
        $left = $OutputRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $right = $protected.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        Assert-Onboarding (-not $left.StartsWith($right, [StringComparison]::OrdinalIgnoreCase) -and
            -not $right.StartsWith($left, [StringComparison]::OrdinalIgnoreCase)) `
            'boss_onboarding_output_overlaps_input'
    }
    $pinPaths = @($MaterializerPath, $StaticDataPackPath, $GameConfigPath, $SourceDatabasePath,
        $PythonPath, $PSCommandPath, $behaviorInspector, $profileAssembler, $fxCandidateTool,
        $candidateVerifier, $publisherPath, (Join-Path $PSScriptRoot 'materialize-nll-shield-fx-transform-variant.py'),
        (Join-Path $PSScriptRoot 'nll-shield-fx-assessment.py'),
        (Join-Path $PSScriptRoot 'nll-shield-fx-recipes.py'))
    if ($MaterializerHostPath) { $pinPaths += $MaterializerHostPath }
    if ($null -ne $NativeConfiguration) {
        $pinPaths += @((Join-Path $PSScriptRoot 'acquire-nll-boss-fx.py'),
            (Join-Path $PSScriptRoot 'acquire-nll-boss-behavior.py'),
            (Join-Path $PSScriptRoot 'stage-nll-native-fx.py'),
            $NativeConfiguration.inputPlanPath, $NativeConfiguration.catalogToolPath, $NativeConfiguration.dotnetPath)
    }
    $pinPaths += @(Get-ChildItem -LiteralPath $RegistryRoot -File | ForEach-Object { $_.FullName })
    foreach ($path in $pinPaths) {
        Assert-PlainPath $path
        $inputPins[$path] = Get-Sha256Lower $path
    }
    # New-Item without Force exclusively reserves this run; retries use a new root.
    New-Item -ItemType Directory -Path $OutputRoot | Out-Null
}
else {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}
$discoveryPath = Join-Path $OutputRoot 'content-discovery.receipt.json'
$behaviorReceiptPath = Join-Path $OutputRoot 'behavior-assembly.receipt.json'
$candidateProfilePath = Join-Path $OutputRoot 'boss-runtime-variant.profile.json'
$candidateReceiptPath = Join-Path $OutputRoot 'onboarding-candidate.receipt.json'
$shieldAssessmentPath = Join-Path $OutputRoot 'shield-pattern-fx-assessment.receipt.json'
$admissionReceiptPath = Join-Path $OutputRoot 'onboarding-admission.receipt.json'
$variantRoot = Join-Path $OutputRoot 'five-affinity-variants'
$privateDiscoveryPath = Join-Path ([IO.Path]::GetTempPath()) `
    ('nll-boss-private-' + [guid]::NewGuid().ToString('N') + '.json')
foreach ($path in @(
        $discoveryPath, $behaviorReceiptPath, $candidateProfilePath,
        $candidateReceiptPath, $shieldAssessmentPath, $admissionReceiptPath, $privateDiscoveryPath)) {
    Assert-Onboarding (-not (Test-Path -LiteralPath $path)) `
        'boss_onboarding_output_exists'
}
Assert-Onboarding (-not (Test-Path -LiteralPath $variantRoot)) `
    'boss_onboarding_output_exists'
Assert-Onboarding (-not (Test-Path -LiteralPath (Join-Path $OutputRoot 'shield-fx-preparation'))) `
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

    $behaviorCache = $AssetCacheRoot
    if ($null -ne $NativeConfiguration) {
        Assert-Onboarding (-not [string]::IsNullOrWhiteSpace($FxSourceCacheRoot)) 'boss_onboarding_fx_cache_missing'
        Assert-Onboarding ((Get-Sha256Lower $NativeConfiguration.dotnetPath) -ceq $NativeConfiguration.dotnetSha256) `
            'boss_onboarding_native_host_drifted'
        $behaviorCache = Join-Path $OutputRoot 'acquired-behavior'
        & $PythonPath -B (Join-Path $PSScriptRoot 'acquire-nll-boss-behavior.py') `
            --input-plan $NativeConfiguration.inputPlanPath --input-plan-sha256 $NativeConfiguration.inputPlanSha256 `
            --catalog-tool $NativeConfiguration.catalogToolPath --catalog-tool-sha256 $NativeConfiguration.catalogToolSha256 `
            --dotnet-path $NativeConfiguration.dotnetPath `
            --cache-root (Join-Path (Split-Path -Parent $FxSourceCacheRoot) 'behavior-source-cache') `
            --output-root $behaviorCache | Out-Null
        Assert-Onboarding ($LASTEXITCODE -eq 0) 'boss_onboarding_behavior_acquisition_failed'
    }
    $behaviorBundles = @(Get-ChildItem -LiteralPath $behaviorCache -File -Recurse |
        Where-Object { $_.Name -cmatch '^externalbehavior_assets_all_[0-9a-f]+\.bundle$' })
    $behaviorIdentities = @($behaviorBundles | Group-Object {
        ([string]$_.Length) + ':' + (Get-Sha256Lower $_.FullName)
    })
    Assert-Onboarding ($behaviorIdentities.Count -gt 0) `
        'boss_onboarding_behavior_bundle_missing'
    $resolvedBehaviorReceipts = [Collections.Generic.List[string]]::new()
    $behaviorFailureCodes = [Collections.Generic.List[string]]::new()
    foreach ($identity in $behaviorIdentities) {
        $probeReceipt = Join-Path $OutputRoot `
            ('.behavior-probe-' + [guid]::NewGuid().ToString('N') + '.json')
        $probeDiagnostic = @(& $PythonPath -B $behaviorInspector `
            --source-discovery $discoveryPath `
            --private-discovery $privateDiscoveryPath `
            --behavior-bundle $identity.Group[0].FullName `
            --unitypy-root $UnityPyRoot `
            --output $probeReceipt 2>&1)
        if ($LASTEXITCODE -eq 0 -and
            (Test-Path -LiteralPath $probeReceipt -PathType Leaf)) {
            $resolvedBehaviorReceipts.Add($probeReceipt)
        }
        else {
            foreach ($line in $probeDiagnostic) {
                $code = ([string]$line).Trim()
                if ($code -cmatch '^boss_behavior_[a-z_]+$') { $behaviorFailureCodes.Add($code) }
            }
            if (Test-Path -LiteralPath $probeReceipt -PathType Leaf) {
                Remove-Item -LiteralPath $probeReceipt -Force
            }
        }
    }
    if ($resolvedBehaviorReceipts.Count -eq 0) {
        $failureCodes = @($behaviorFailureCodes | Sort-Object -Unique)
        if ($failureCodes.Count -eq 1) { throw $failureCodes[0] }
        throw 'boss_onboarding_behavior_closure_unresolved'
    }
    Assert-Onboarding ($resolvedBehaviorReceipts.Count -eq 1) `
        'boss_onboarding_behavior_closure_not_unique'
    Move-Item -LiteralPath $resolvedBehaviorReceipts[0] `
        -Destination $behaviorReceiptPath

    if ($null -ne $NativeConfiguration) {
        Assert-Onboarding (-not [string]::IsNullOrWhiteSpace($FxSourceCacheRoot)) 'boss_onboarding_fx_cache_missing'
        Assert-Onboarding ((Get-Sha256Lower $NativeConfiguration.dotnetPath) -ceq $NativeConfiguration.dotnetSha256) `
            'boss_onboarding_native_host_drifted'
        $acquiredCache = Join-Path $OutputRoot 'acquired-fx'
        & $PythonPath -B (Join-Path $PSScriptRoot 'acquire-nll-boss-fx.py') `
            --source-discovery $discoveryPath --private-discovery $privateDiscoveryPath `
            --input-plan $NativeConfiguration.inputPlanPath --input-plan-sha256 $NativeConfiguration.inputPlanSha256 `
            --catalog-tool $NativeConfiguration.catalogToolPath --catalog-tool-sha256 $NativeConfiguration.catalogToolSha256 `
            --dotnet-path $NativeConfiguration.dotnetPath --cache-root $FxSourceCacheRoot `
            --output-root $acquiredCache --unitypy-root $UnityPyRoot --existing-cache-root $originalAssetCacheRoot | Out-Null
        Assert-Onboarding ($LASTEXITCODE -eq 0) 'boss_onboarding_fx_acquisition_failed'
        if (Test-Path -LiteralPath $acquiredCache -PathType Container) { $AssetCacheRoot = $acquiredCache }
    }

    $assemblyOptions = @('--unitypy-root', $UnityPyRoot)
    if ($CandidateOnly) { $assemblyOptions += '--allow-v3-candidate' }
    $assemblyDiagnostic = @(& $PythonPath -B $profileAssembler @assemblyOptions `
        --source-discovery $discoveryPath `
        --private-discovery $privateDiscoveryPath `
        --behavior-receipt $behaviorReceiptPath `
        --asset-cache-root $AssetCacheRoot `
        --profile-output $candidateProfilePath `
        --receipt-output $candidateReceiptPath `
        --shield-assessment-output $shieldAssessmentPath 2>&1)
    $assemblyExitCode = $LASTEXITCODE
    if ($assemblyExitCode -eq 0 -or (Test-Path -LiteralPath $shieldAssessmentPath -PathType Leaf)) {
        try {
            $shieldAssessment = Get-Content -LiteralPath $shieldAssessmentPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $assessmentBound = $shieldAssessment.contractId -ceq 'nll/boss-shield-preparation-assessment/v1' -and
                $shieldAssessment.sourceDiscoverySha256 -ceq (Get-Sha256Lower $discoveryPath) -and
                $shieldAssessment.behaviorAssemblySha256 -ceq (Get-Sha256Lower $behaviorReceiptPath) -and
                $shieldAssessment.runtimeAdmissionStatusCode -ceq 'not_assessed'
        } catch { throw 'boss_onboarding_shield_assessment_invalid' }
        Assert-Onboarding $assessmentBound 'boss_onboarding_shield_assessment_invalid'
        if ($shieldAssessment.PSObject.Properties.Name -contains 'fx') {
            $recipeReceiptPath = Join-Path $OutputRoot 'shield-fx-preparation/recipes.receipt.json'
            Assert-Onboarding (($shieldAssessment.PSObject.Properties.Name -contains 'shieldFxRecipesSha256') -and
                (Test-Path -LiteralPath $recipeReceiptPath -PathType Leaf) -and
                $shieldAssessment.shieldFxRecipesSha256 -ceq (Get-Sha256Lower $recipeReceiptPath) -and
                $shieldAssessment.shieldFxRecipeDeliveryStatusCode -ceq 'verified_preparation_candidates') `
                'boss_onboarding_shield_recipe_delivery_invalid'
        }
        Assert-Onboarding ($shieldAssessment.preparationStatusCode -cne 'review_required') `
            'boss_onboarding_shield_preparation_review_required'
        Assert-Onboarding ($shieldAssessment.preparationStatusCode -cin @('not_required', 'prepared')) `
            'boss_onboarding_shield_assessment_invalid'
    }
    if ($assemblyExitCode -ne 0) {
        # Surface the assembler's first controlled code; other diagnostic text stays private.
        $assemblyCodes = @($assemblyDiagnostic | ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ -cmatch '^boss_profile_[a-z0-9_]{1,80}$' })
        if ($assemblyCodes.Count -gt 0) { throw $assemblyCodes[0] }
        throw 'boss_onboarding_profile_assembly_failed'
    }

    $validationOutput = @(& $materializerCommand @materializerPrefix `
        --validate-boss-variant-profile $candidateProfilePath)
    Assert-Onboarding ($LASTEXITCODE -eq 0 -and $validationOutput.Count -gt 0) `
        'boss_onboarding_profile_validation_failed'
    $validation = $validationOutput[-1] | ConvertFrom-Json
    Assert-Onboarding `
        ($validation.contractId -ceq `
            'nll/boss-runtime-variant-profile-validation/v1' -and
         [int]$validation.seasonNumber -eq $SeasonNumber -and
         [string]$validation.profileCode -ceq $ProfileCode -and
         [string]$validation.profileSha256 -ceq (Get-Sha256Lower $candidateProfilePath)) `
        'boss_onboarding_profile_validation_failed'

    New-Item -ItemType Directory -Path $variantRoot | Out-Null
    $targetBossElementByWeakness = @{
        fire = 'wind'; water = 'fire'; wind = 'iron';
        electric = 'water'; iron = 'electric'
    }
    $profile = Get-Content -LiteralPath $candidateProfilePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    # A v3 candidate cannot enter the legacy publication path, even if assembly
    # behavior changes later. Delivery/rollback and execution admission are separate.
    Assert-Onboarding ($CandidateOnly -or [int]$profile.schemaVersion -eq 2) `
        'boss_onboarding_v3_runtime_delivery_required'
    if ($CandidateOnly -and [int]$profile.schemaVersion -eq 3) {
        & $PythonPath -B $fxCandidateTool create --profile $candidateProfilePath `
            --profile-sha256 (Get-Sha256Lower $candidateProfilePath) `
            --asset-cache-root $AssetCacheRoot --unitypy-root $UnityPyRoot `
            --output-root (Join-Path $OutputRoot 'shield-fx-candidate') | Out-Null
        Assert-Onboarding ($LASTEXITCODE -eq 0) 'boss_onboarding_fx_candidate_failed'
    }
    $variantReceipts = [Collections.Generic.List[object]]::new()
    $variantArtifactPins = @{ $StaticDataPackPath = $sourceStaticSha256; $publisherPath = $publisherSha256 }
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
             [string]$receipt.variantProfileCode -ceq $ProfileCode -and
             [string]$receipt.variantProfileSha256 -ceq [string]$validation.profileSha256 -and
             [string]$receipt.sourceStaticDataSha256 -ceq $sourceStaticSha256 -and
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
        if ($expectedVariant) {
            $variantHash = Get-Sha256Lower $variantPath
            Assert-Onboarding ($variantHash -ceq [string]$receipt.variantStaticDataSha256) 'boss_onboarding_variant_pack_drifted'
            $variantArtifactPins[$variantPath] = $variantHash
        } else {
            Assert-Onboarding ($null -eq $receipt.variantStaticDataSha256) 'boss_onboarding_variant_pack_drifted'
        }
        $variantArtifactPins[$receiptPath] = Get-Sha256Lower $receiptPath
        $variantReceipts.Add([ordered]@{
            weaknessCode = $weaknessCode
            targetBossElementCode = [string]$receipt.targetBossElementCode
            variantRequired = [bool]$receipt.variantRequired
            modifiedMonsterRecordCount = [int]$receipt.modifiedMonsterRecordCount
            modifiedFunctionRecordCount = [int]$receipt.modifiedFunctionRecordCount
            receiptSha256 = Get-Sha256Lower $receiptPath
        })
    }

    if ($CandidateOnly) {
        foreach ($path in $inputPins.Keys) {
            Assert-PlainPath $path
            Assert-Onboarding ((Get-Sha256Lower $path) -ceq $inputPins[$path]) `
                'boss_onboarding_input_drifted'
        }
        $inputText = (@($inputPins.Values | Sort-Object) -join "`n")
        $inputSetSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($inputText))).ToLowerInvariant()
        & $PythonPath -B $candidateVerifier --output-root $OutputRoot `
            --source-static-pack $StaticDataPackPath --season-number $SeasonNumber `
            --profile-code $ProfileCode --input-set-sha256 $inputSetSha --asset-cache-root $originalAssetCacheRoot
        Assert-Onboarding ($LASTEXITCODE -eq 0) 'boss_onboarding_candidate_verification_failed'
        Write-Output (Join-Path $OutputRoot 'onboarding-verified-candidate.receipt.json')
        return
    }

    Assert-Onboarding ((Get-Sha256Lower $publisherPath) -ceq $publisherSha256) 'boss_onboarding_publisher_drifted'
    . $publisherPath
    Publish-NllBossProfile -ProfilePath $candidateProfilePath -Validation $validation `
        -ArtifactPins $variantArtifactPins `
        -VariantReceipts $variantReceipts.ToArray() -RegistryRoot $RegistryRoot `
        -ExpectedRegistrySha256 $registryInitialSha256 -AdmissionReceiptPath $admissionReceiptPath `
        -ReplaceExistingProfile:$ReplaceExistingProfile | Out-Null
}
finally {
    if (Test-Path -LiteralPath $privateDiscoveryPath -PathType Leaf) {
        Remove-Item -LiteralPath $privateDiscoveryPath -Force
    }
}

Write-Output $admissionReceiptPath
