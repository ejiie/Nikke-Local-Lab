# Offline composition only. An exported/native/chunk candidate is not a delivery
# or admission receipt. No original store is written and no client is launched.
function New-NllBossNativeCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Configuration,
        [Parameter(Mandatory)][string]$JobRoot,
        [Parameter(Mandatory)][string]$CandidateRoot,
        [Parameter(Mandatory)][string]$CandidateReceiptSha256,
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$UnityPyRoot,
        [string]$CacheRoot)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    function Check([bool]$Value, [string]$Code) { if (-not $Value) { throw ('boss_native_' + $Code) } }
    function Digest([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
    $sealPath = Join-Path $CandidateRoot 'onboarding-verified-candidate.receipt.json'
    Check ((Digest $sealPath) -ceq $CandidateReceiptSha256) 'candidate_drifted'
    $seal = Get-Content -LiteralPath $sealPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($seal.contractId -ceq 'nll/boss-onboarding-verified-candidate/v1' -and
        $seal.affinityVariantCount -eq 5 -and $seal.fiveAffinityVariantStatusCode -ceq 'passed' -and
        $seal.runtimeAdmissionStatusCode -ceq 'not_assessed' -and $seal.clientStarted -eq $false) 'candidate_invalid'
    $fxRoot = Join-Path $CandidateRoot 'shield-fx-candidate'
    $profilePath = Join-Path $CandidateRoot 'boss-runtime-variant.profile.json'
    Check ((Digest $profilePath) -ceq $seal.profileSha256) 'profile_drifted'
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $extra = @()
    $fxHash = $seal.shieldFxCandidateManifestSha256
    if ($profile.schemaVersion -eq 4) {
        $fxRoot = Join-Path $CandidateRoot 'shield-fx-preparation'
        $fxHash = $seal.shieldFxPreparationManifestSha256
        Check ((Digest (Join-Path $fxRoot 'recipes.receipt.json')) -ceq $fxHash -and
            -not [string]::IsNullOrEmpty($CacheRoot)) 'fx_binding_invalid'
        $extra = @('--profile-path', $profilePath, '--profile-sha256', $seal.profileSha256, '--cache-root', $CacheRoot)
    } else {
        Check ((Digest (Join-Path $fxRoot 'manifest.json')) -ceq $fxHash) 'fx_binding_invalid'
    }
    Check ((Digest $Configuration.inputPlanPath) -ceq $Configuration.inputPlanSha256 -and
        (Digest $Configuration.catalogToolPath) -ceq $Configuration.catalogToolSha256 -and
        (Digest $Configuration.dotnetPath) -ceq $Configuration.dotnetSha256) 'tool_drifted'
    # stage-nll-native-fx invokes dotnet by name. Pin and bind just this process's
    # PATH so it resolves the reviewed host, then restore PATH even on failure.
    $priorPath = $env:PATH
    $nativeRoot = Join-Path $JobRoot 'native-candidate'
    $layoutRoot = Join-Path $JobRoot 'native-fixed-layout'
    $chunkRoot = Join-Path $JobRoot 'native-chunks'
    try {
        $env:PATH = (Split-Path -Parent $Configuration.dotnetPath) + [IO.Path]::PathSeparator + $priorPath
        & $PythonPath -B (Join-Path $PSScriptRoot 'stage-nll-native-fx.py') `
            --input-plan $Configuration.inputPlanPath --input-plan-sha256 $Configuration.inputPlanSha256 `
            --catalog-tool $Configuration.catalogToolPath --catalog-tool-sha256 $Configuration.catalogToolSha256 `
            --fx-candidate-root $fxRoot --fx-manifest-sha256 $fxHash `
            --output-root $nativeRoot --unitypy-root $UnityPyRoot @extra | Out-Null
        Check ($LASTEXITCODE -eq 0) 'export_failed'
        & $PythonPath -B (Join-Path $PSScriptRoot 'materialize-nll-native-fx-layout.py') `
            --source-root $nativeRoot --source-sha256 (Digest (Join-Path $nativeRoot 'receipt.json')) `
            --output-root $layoutRoot --unitypy-root $UnityPyRoot | Out-Null
        Check ($LASTEXITCODE -eq 0) 'layout_failed'
        & $Configuration.dotnetPath $Configuration.catalogToolPath stage-native-fx-chunks $nativeRoot $layoutRoot `
            (Digest (Join-Path $layoutRoot 'receipt.json')) $chunkRoot | Out-Null
        Check ($LASTEXITCODE -eq 0) 'chunks_failed'
    }
    finally { $env:PATH = $priorPath }
    $receiptPath = Join-Path $chunkRoot 'receipt.json'
    $chunks = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Check ($chunks.contractId -ceq 'nll/native-fx-chunk-candidate/v1' -and
        $chunks.statusCode -ceq 'offline_chunk_candidate_verified' -and
        $chunks.nativeClientExecuted -eq $false -and $chunks.installedFilesModified -eq $false -and
        $chunks.oldChunkDigestsMatch -eq $false -and $chunks.sourceFilesUnchanged -eq $true -and
        $chunks.runtimeAdmissionStatusCode -ceq 'not_assessed') 'chunks_invalid'
    Check ((Digest $sealPath) -ceq $CandidateReceiptSha256) 'candidate_drifted'
    [ordered]@{ contractId = 'nll/boss-native-candidate-composition/v1'; candidateReceiptSha256 = $CandidateReceiptSha256
        chunkReceiptSha256 = Digest $receiptPath; runtimeAdmissionStatusCode = 'not_assessed'; nativeClientExecuted = $false }
}
