param([Parameter(Mandatory)][string]$PlanPath)
# CLIENT_UPDATE step 10a: seal the new runtime bundle (plan.runtimeRoot) next to the selected one. Run from the main
# checkout after the build-admission PR is merged and fast-forwarded (the materializer and bootstrap are built here).
# Creates only the new root and selection candidate in the staging folder; selection, client, firewall, registry and
# database are not touched and nothing is started.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ClientUpdate.ps1')
$plan = Read-NllClientUpdatePlan $PlanPath
$repo = $plan.repositoryRoot
. "$repo/scripts/Nll.ResourceNative.ps1"
. "$repo/scripts/Nll.PhaseDRuntimeBundle.ps1"
$old = Read-PdRuntimeBundle 'C:\NLL\ControlCenter\runtime-selection.private.json' -FilePinsOnly
$root = $plan.runtimeRoot
$clientRoot = $plan.clientRoot
$exeSha = Get-RnHash "$clientRoot/NIKKE/game/nikke.exe"
Assert-Rn ($old.client.path -ieq "$($plan.previousClientRoot)\NIKKE\game\nikke.exe") 'selected_bundle_not_previous_build'
Assert-Rn (-not (Test-Path $root)) 'bundle_root_exists'
if (@(Get-Process nikke, nikke_launcher, EpinelPS -ErrorAction SilentlyContinue).Count) { throw 'runtime_not_cold' }
$staticReceipt = Get-Content (Join-Path $plan.stagingRoot 'staticdata.receipt.json') -Raw | ConvertFrom-Json
Assert-Rn ($staticReceipt.status -ceq 'fetched_signature_and_crc_verified' -and (Get-RnHash $plan.staticDataPackPath) -ceq $staticReceipt.packSha256) 'pack_not_verified'
Assert-Rn ((Get-RnHash $plan.gameConfigPath) -ceq $plan.gameConfigSha256) 'config_drifted'

New-RnPrivateDirectory $root
$server = Join-Path $root 'server'; $materializer = Join-Path $root 'materializer'; $bootstrap = Join-Path $root 'bootstrap'
foreach ($dir in @($server, $materializer, "$bootstrap/artifact", "$root/overlay")) { New-RnPrivateDirectory $dir }

# 1. Server publish (upstream version files on the deployed NLL source), settings and certificate of the selected bundle.
foreach ($file in Get-ChildItem $plan.serverPublishRoot -File) {
    if ($file.Extension -in '.dll', '.exe' -or $file.Name -in 'EpinelPS.deps.json', 'EpinelPS.runtimeconfig.json', 'gameversion.json') {
        Copy-RnNew $file.FullName (Join-Path $server $file.Name)
    }
}
foreach ($name in @('appsettings.json', 'site.pfx')) { Copy-RnNew (Join-Path $old.serverRoot $name) (Join-Path $server $name) }
# The pinned upstream gameconfig is used unchanged; the local server reads only local locales.
Copy-RnNew $plan.gameConfigPath "$server/gameconfig.json"
$config = Get-Content "$server/gameconfig.json" -Raw | ConvertFrom-Json
Assert-Rn ($config.TargetVersion -ceq $plan.build -and $config.StaticDataMpk.Version -ceq $staticReceipt.version) 'config_invalid'
$destination = Join-Path "$server/cache" ([Uri]$config.StaticDataMpk.Url).AbsolutePath.TrimStart('/')
New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
Copy-RnNew $plan.staticDataPackPath $destination
$localeReceipt = Get-Content (Join-Path $plan.localeStagingRoot 'locales.receipt.json') -Raw | ConvertFrom-Json
$locales = @(Get-ChildItem $plan.localeStagingRoot -File -Filter 'Locale_*.lsc')
Assert-Rn ($locales.Count -eq 4 -and $localeReceipt.status -ceq 'four_local_server_inputs_verified') 'locales_invalid'
New-Item -ItemType Directory -Path "$server/cache/local-locale" | Out-Null
foreach ($file in $locales) {
    Assert-Rn (@($localeReceipt.members | Where-Object { $_.sha256 -ceq (Get-RnHash $file.FullName) }).Count -eq 1) 'locale_drift'
    Copy-RnNew $file.FullName (Join-Path "$server/cache/local-locale" $file.Name)
}
# Named behavior/FX inputs carried bundle to bundle; old guidance, catalogs and packs are not copied.
foreach ($pin in $old.files | Where-Object { $_.path.StartsWith($old.serverRoot + '\cache\', [StringComparison]::OrdinalIgnoreCase) -and $_.path.EndsWith('.bundle') }) {
    Assert-PdBundlePin $pin
    $dest = Join-Path $server ([IO.Path]::GetRelativePath($old.serverRoot, $pin.path))
    New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
    Copy-RnNew $pin.path $dest
}

# 2. Materializer against this server's EpinelPS assembly; tool folders carry their own global.json (SDK 10).
$build = Join-Path $plan.stagingRoot 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$matOut = Join-Path $build 'materializer'
Assert-Rn (-not (Test-Path $matOut)) 'materializer_output_exists'
Push-Location (Join-Path $repo 'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer')
try {
    & dotnet publish '.\NikkeLocalLab.PhaseD.RuntimeMaterializer.csproj' -c Release --self-contained false `
        ('-p:EpinelReferenceRoot=' + $server) -o $matOut *> (Join-Path $build 'materializer-publish.log')
    Assert-Rn ($LASTEXITCODE -eq 0) 'materializer_publish_failed'
} finally { Pop-Location }
foreach ($file in Get-ChildItem $matOut -File | Where-Object { $_.Extension -in '.dll', '.exe', '.json' }) { Copy-RnNew $file.FullName (Join-Path $materializer $file.Name) }
Assert-Rn (@(Get-ChildItem $matOut -Directory).Count -eq 0) 'materializer_layout_changed'
$migration = & (Join-Path $materializer 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe') --verify-runtime-migration true | Out-String
Assert-Rn ($LASTEXITCODE -eq 0 -and $migration -match '"status":"passed"') 'materializer_self_check_failed'

# 3. Physical bootstrap, manifest-client variant, bound to this client executable.
$bootOut = Join-Path $build 'bootstrap'
Assert-Rn (-not (Test-Path $bootOut)) 'bootstrap_output_exists'
Push-Location (Join-Path $repo 'tools\Phase3B2\PhysicalBootstrap')
try {
    & dotnet publish '.\NikkeLocalLab.Phase3B2.PhysicalBootstrap.csproj' -c Release `
        '-p:DefineConstants=PHYSICAL_BOOTSTRAP%3BPHASE_D_MANIFEST_CLIENT' -o $bootOut *> (Join-Path $build 'bootstrap-publish.log')
    Assert-Rn ($LASTEXITCODE -eq 0) 'bootstrap_publish_failed'
} finally { Pop-Location }
foreach ($file in Get-ChildItem $bootOut -File | Where-Object { $_.Extension -in '.dll', '.exe', '.json' }) { Copy-RnNew $file.FullName (Join-Path "$bootstrap/artifact" $file.Name) }
Write-RnNewBytes "$bootstrap/artifact/client-binding.json" ([Text.UTF8Encoding]::new($false).GetBytes((@{ executableSha256 = $exeSha; build = $plan.build } | ConvertTo-Json) + "`n"))
Copy-RnNew (Join-Path $old.bootstrapRoot 'artifact/sail_api_impl64.dll') "$bootstrap/artifact/sail_api_impl64.dll"
$inspect = & "$bootstrap/artifact/NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe" --inspect-client-binding | Out-String
Assert-Rn ($LASTEXITCODE -eq 0 -and $inspect -match 'client_binding_verified' -and $inspect -match '"clientStarted":false') 'bootstrap_binding_failed'

# 4. Overlay: the approved DLL and certificate replacements of the selected bundle (clone originals must be unchanged).
$overlay = @()
foreach ($change in $old.overlay) {
    $leaf = Split-Path $change.before.path -Leaf
    $target = Join-Path $clientRoot ('NIKKE/game/nikke_Data/Plugins/x86_64/' + $leaf)
    Assert-Rn ((Get-RnHash $target) -ceq $change.before.sha256) 'overlay_original_changed'
    Assert-PdBundlePin $change.replacement
    Copy-RnNew $target "$root/overlay/$leaf.original"
    Copy-RnNew $change.replacement.path "$root/overlay/$leaf.replacement"
    $overlay += @{ before = (Get-RnPin $target); backup = (Get-RnPin "$root/overlay/$leaf.original"); replacement = (Get-RnPin "$root/overlay/$leaf.replacement") }
}
$native = Get-RnPin "$root/overlay/sodium.dll.replacement"; $native.path = ($overlay | Where-Object { $_.before.path.EndsWith('\sodium.dll') }).before.path
$certificate = Get-RnPin "$root/overlay/intl_cacert.pem.replacement"; $certificate.path = ($overlay | Where-Object { $_.before.path.EndsWith('\intl_cacert.pem') }).before.path
Assert-Rn ($native.sha256 -ceq '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662') 'native_not_approved'

# 5. Isolation inventory: clone programs move to the new clone; shared official programs stay under the official root.
$programs = @($old.clientPrograms | ForEach-Object { Get-RnPin ($_.path.Replace($plan.previousClientRoot, $clientRoot)) })
$blockOnly = @($old.blockOnlyPrograms | ForEach-Object {
    if ($_.StartsWith('C:\NIKKE\', [StringComparison]::OrdinalIgnoreCase)) { $plan.officialRoot + '\' + $_.Substring(9) } else { $_ } })
foreach ($path in $blockOnly) { Assert-Rn (Test-Path -LiteralPath $path -PathType Leaf) 'block_only_program_missing' }

# 6. Server source manifest and build record.
$sourceNames = @(Get-Content $old.serverSourceManifest.path | Where-Object { $_ } | ForEach-Object { ($_ -split "`t")[0] })
$sourceLines = @($sourceNames | Sort-Object -Unique | ForEach-Object { $p = Join-Path $plan.serverSourceRoot $_
    Assert-Rn (Test-Path $p) 'server_source_missing'; $_ + "`t" + (Get-Item $p).Length + "`t" + (Get-RnHash $p) })
Write-RnNewBytes "$root/server-source.manifest.tsv" ([Text.Encoding]::UTF8.GetBytes(($sourceLines -join "`n") + "`n"))
Write-RnNewJson "$root/server-build.private.json" @{ upstreamVersionCommit = $plan.upstreamCommit; upstreamExcluded = @($plan.upstreamExcluded)
    resourceHostResponse = 'upstream_base_url_and_version_only'; serverDll = (Get-RnPin "$server/EpinelPS.dll"); clientStarted = $false }

# 7. Bundle and selection candidate (not activated).
$storePath = Join-Path $clientRoot 'Unity/com_proximabeta_NIKKE/com.shiftup.patch/core/chunk/store.cdb'
$store = [ordered]@{ path = [IO.Path]::GetFullPath($storePath); length = (Get-Item $storePath).Length; sha256 = (Get-RnHash $storePath) }
$bundle = [ordered]@{ contractId = 'nll/phase-d-runtime-bundle/v1'; clientBuildCode = ('build_' + $plan.build); serverRoot = $server; bootstrapRoot = $bootstrap
    materializerRoot = $materializer; referenceAssessmentUid = $old.referenceAssessmentUid; client = (Get-RnPin "$clientRoot/NIKKE/game/nikke.exe")
    native = $native; certificate = $certificate; serverExe = (Get-RnPin "$server/EpinelPS.exe"); serverDll = (Get-RnPin "$server/EpinelPS.dll")
    serverSourceManifest = (Get-RnPin "$root/server-source.manifest.tsv"); bootstrap = (Get-RnPin "$bootstrap/artifact/NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe")
    files = @(Get-ChildItem $root -Recurse -File | Sort-Object FullName | ForEach-Object { Get-RnPin $_.FullName })
    overlay = $overlay; clientPrograms = $programs; blockOnlyPrograms = $blockOnly; preserveExistingAccount = $true; syntheticRegistration = $false
    httpDiagnosticLayer = $false; progressionSourceSha256 = $old.progressionSourceSha256; nativeGameplayValidated = $false
    parentManifest = (Get-RnPin $old.manifestPath); commonBossRegistryRoot = 'C:\NLL\RuntimeInputs\CommonBossExecution\profiles'; commonNativeStore = $store }
Write-RnNewJson "$root/bundle.private.json" $bundle
$selection = Join-Path $plan.stagingRoot "selection-$($plan.build).private.json"
Write-RnNewJson $selection @{ contractId = 'nll/phase-d-runtime-selection/v1'; manifest = (Get-RnPin "$root/bundle.private.json") }
# Fails here until the build is admitted (RuntimeVersionBinding, bundle reader, runner contract, preparation, bootstrap).
$null = Read-PdRuntimeBundle $selection -BeforeActivation
Write-RnNewJson (Join-Path $plan.stagingRoot 'bundle-preparation.receipt.json') @{ status = 'sealed_not_activated'; manifest = (Get-RnPin "$root/bundle.private.json")
    fileCount = @($bundle.files).Count; resourceGuidance = 'not_supplied'; clientChanged = $false; clientStarted = $false
    repositoryHead = (git -C $repo rev-parse HEAD).Trim() }
Get-Content (Join-Path $plan.stagingRoot 'bundle-preparation.receipt.json') -Raw
