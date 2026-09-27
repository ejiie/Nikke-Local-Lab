# Compose the already verified assembly into the common preparer's private input.
# This function neither writes a client file nor changes the active registry.
function New-NllCommonBossDelivery {
    param([string]$CandidateRoot, [string]$NativeRoot, [object]$NativeStore,
        [string]$MaterializerPath, [string]$OutputRoot)
    $ErrorActionPreference = 'Stop'
    function Pin([string]$Path) {
        [ordered]@{path=[IO.Path]::GetFullPath($Path);length=(Get-Item -LiteralPath $Path).Length;
            sha256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
    }
    if (Test-Path -LiteralPath $OutputRoot) { throw 'boss_common_delivery_output_exists' }
    $profilePath = Join-Path $CandidateRoot 'boss-runtime-variant.profile.json'
    $profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    $adjusted = @()
    if ($profile.PSObject.Properties.Name -contains 'shieldFxPreparation' -and $null -ne $profile.shieldFxPreparation) {
        $adjusted = @($profile.shieldFxPreparation.variants | Where-Object operationCode -CEQ 'adjust_candidate')
    }
    $descriptor = [ordered]@{ contractId='nll/common-boss-delivery/v1';profileSha256=(Pin $profilePath).sha256
        candidateSeal=(Pin (Join-Path $CandidateRoot 'onboarding-verified-candidate.receipt.json'))
        nativeChunkReceipt=$null; nativeStore=$null }
    if ($adjusted.Count -gt 0) {
        $descriptor.nativeChunkReceipt = Pin (Join-Path $NativeRoot 'native-chunks/receipt.json')
        $descriptor.nativeStore = $NativeStore
    }
    $null = New-Item -ItemType Directory -Path $OutputRoot
    $path = Join-Path $OutputRoot 'delivery.private.json'
    [IO.File]::WriteAllText($path, ($descriptor | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    $pin = Pin $path
    foreach ($weakness in @('fire','water','wind','electric','iron')) {
        $output = @(& $MaterializerPath --validate-common-boss-delivery true --delivery-path $path `
            --delivery-sha256 $pin.sha256 --boss-variant-profile $profilePath --weakness-code $weakness 2>&1)
        if ($LASTEXITCODE -ne 0) { throw 'boss_common_delivery_validation_failed' }
        $ready = ($output -join "`n") | ConvertFrom-Json
        if ($ready.statusCode -cne 'prepared' -or $ready.profileSha256 -cne $descriptor.profileSha256) {
            throw 'boss_common_delivery_validation_failed'
        }
    }
    return $pin
}
