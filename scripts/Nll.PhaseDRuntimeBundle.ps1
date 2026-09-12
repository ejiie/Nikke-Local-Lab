# Local, versioned runtime selection. Importing this file has no side effects.
Set-StrictMode -Version Latest
function Assert-PdBundle([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw ('phase_d_bundle_' + $Code) }
}
function Get-PdBundleHash([string]$Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Assert-PdBundlePin([object]$Pin) {
    Assert-PdBundle ((Test-Path -LiteralPath $Pin.path -PathType Leaf) -and
        (Get-Item -LiteralPath $Pin.path).Length -eq $Pin.length -and
        (Get-PdBundleHash $Pin.path) -ceq $Pin.sha256) 'file_drifted'
}
function Read-PdRuntimeBundle([string]$PointerPath, [switch]$BeforeActivation, [switch]$FilePinsOnly) {
    Assert-PdBundle (-not ($BeforeActivation -and $FilePinsOnly)) 'read_mode_invalid'
    if (-not (Test-Path -LiteralPath $PointerPath)) { return $null }
    $pointer = Get-Content -LiteralPath $PointerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PdBundle ($pointer.contractId -ceq 'nll/phase-d-runtime-selection/v1' -and
        [string]$pointer.manifest.path -cmatch '^C:\\NLL\\Runtime\\PhaseD151-v[1-9][0-9]*\\bundle\.private\.json$') 'selection_invalid'
    Assert-PdBundlePin $pointer.manifest
    $bundle = Get-Content -LiteralPath $pointer.manifest.path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-PdBundle ($bundle.contractId -ceq 'nll/phase-d-runtime-bundle/v1' -and
        $bundle.clientBuildCode -ceq 'build_151.8.5' -and
        $bundle.serverRoot -ceq (Join-Path (Split-Path -Parent $pointer.manifest.path) 'server') -and
        $bundle.bootstrapRoot -ceq (Join-Path (Split-Path -Parent $pointer.manifest.path) 'bootstrap') -and
        $bundle.client.path -ceq 'C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke.exe' -and
        $bundle.client.sha256 -ceq '36fa20306d010087cdb336bbbb8a6718013d4a16838178045b1270af631b1732' -and
        $bundle.native.sha256 -ceq '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662' -and
        $bundle.preserveExistingAccount -eq $true -and $bundle.syntheticRegistration -eq $false -and
        $bundle.httpDiagnosticLayer -eq $false) 'contract_invalid'
    foreach ($pin in @($bundle.files) + @($bundle.client) + @($bundle.clientPrograms)) {
        Assert-PdBundlePin $pin
    }
    if ($BeforeActivation) {
        foreach ($change in $bundle.overlay) { Assert-PdBundlePin $change.before }
    }
    else {
        foreach ($pin in @($bundle.native, $bundle.certificate)) { Assert-PdBundlePin $pin }
        if (-not $FilePinsOnly) {
        $rules = @(Get-NetFirewallRule -Group 'NLL PhaseD 151 Client Isolation' -ErrorAction SilentlyContinue)
        $paths = @($bundle.clientPrograms.path) + @($bundle.blockOnlyPrograms) | Sort-Object -Unique
        Assert-PdBundle ($rules.Count -eq $paths.Count -and @($rules | Where-Object {
            $_.Direction -ne 'Outbound' -or $_.Action -ne 'Block' -or $_.Enabled -ne 'True'
        }).Count -eq 0) 'client_isolation_missing'
        $actual = @($rules | Get-NetFirewallApplicationFilter | Select-Object -ExpandProperty Program)
        Assert-PdBundle (@(Compare-Object @($paths) @($actual)).Count -eq 0) 'client_isolation_changed'
        }
    }
    $bundle | Add-Member -NotePropertyName manifestPath -NotePropertyValue $pointer.manifest.path
    return $bundle
}
