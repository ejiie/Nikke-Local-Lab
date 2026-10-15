param([Parameter(Mandatory)][string]$PlanPath, [switch]$ExecuteOnce, [switch]$SkipCdnRequest)
# CLIENT_UPDATE step 6, after the first run of the newly selected bundle stops at 4/7 (DownloadPatch - Initialize failed).
#  1. The exact guidance file the client requested is read from its Player log; no number is guessed.
#  2. That one file is fetched once from the public CDN (SECURITY_BOUNDARY update static inputs) and used only when its
#     seven publications equal the sealed clone's .patch_state.json.
#  3. Otherwise the file is derived from the sealed clone itself (operator decision 2026-10-16): installed publications,
#     NLL-derived revision folder names, the installed catalog pairs in those folders.
# The guidance and 14 catalog files are served from the selected bundle, which is resealed with the selection pointer.
# Without -ExecuteOnce only the request and the derived local content are reported (no network, no writes).
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ClientUpdate.ps1')
$plan = Read-NllClientUpdatePlan $PlanPath
. (Join-Path $plan.repositoryRoot 'scripts/Nll.ResourceNative.ps1')
. (Join-Path $plan.repositoryRoot 'scripts/Nll.PhaseDRuntimeBundle.ps1')
$selection = 'C:\NLL\ControlCenter\runtime-selection.private.json'
$b = Read-PdRuntimeBundle $selection -FullVerification
Assert-NllClientUpdate ($b.clientBuildCode -ceq ('build_' + $plan.build)) 'selected_bundle_not_plan_build'
$patch = Join-Path $plan.clientRoot 'Unity\com_proximabeta_NIKKE\com.shiftup.patch'
$base = ((Get-Content (Join-Path $b.serverRoot 'gameconfig.json') -Raw | ConvertFrom-Json).ResourceBaseURL).Replace('{Platform}', 'StandaloneWindows64').TrimEnd('/') + '/pck/'
$baseUri = [Uri]$base
Assert-NllClientUpdate ($baseUri.Scheme -ceq 'https' -and $baseUri.Host -ceq 'cloud.nikke-kr.com' -and -not $baseUri.Query) 'resource_base_invalid'

$log = Join-Path $env:USERPROFILE 'AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
$text = Get-Content -LiteralPath $log -Raw
Assert-NllClientUpdate ($text.Contains($plan.clientRoot) -or $text.Contains($plan.clientRoot.Replace('\', '/'))) 'player_log_not_plan_client'
$hits = @([regex]::Matches($text, [regex]::Escape($baseUri.AbsolutePath.TrimStart('/')) + '(latest-[0-9]{3,4}\.txt)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Assert-NllClientUpdate ($hits.Count -eq 1) 'request_not_unique'
$name = $hits[0]
$statePath = Join-Path $patch '.patch_state.json'
$state = Get-Content $statePath -Raw | ConvertFrom-Json
$catalogs = @{}; foreach ($role in 'core', 'dp', 'en', 'ja', 'ko', 'fd', 'saus') { $catalogs[$role] = Get-NllClientUpdateHash (Join-Path $patch "$role\catalog.ndb") }
$local = New-NllLocalResourceGuidance $plan.build $state (Get-NllClientUpdateHash $statePath) $catalogs
if (-not $ExecuteOnce) { [ordered]@{ request = $base + $name; cdnRequest = -not $SkipCdnRequest; localFallback = $local.lines } | ConvertTo-Json; return }

if (@(Get-Process nikke, nikke_launcher, EpinelPS -ErrorAction SilentlyContinue).Count) { throw 'client_update_runtime_not_cold' }
$out = Join-Path $plan.stagingRoot ('guidance-' + $name.Replace('.txt', ''))
Assert-NllClientUpdate (-not (Test-Path $out)) 'guidance_already_supplied'
New-Item -ItemType Directory -Path $out | Out-Null
Copy-Item -LiteralPath $log -Destination (Join-Path $out 'Player.private.log')
$origin = 'nll_local_from_sealed_patch_state'; $bytes = $null; $httpStatus = $null; $revisions = $local.revisions
if (-not $SkipCdnRequest) {
    Write-NllClientUpdateJson (Join-Path $out 'request.started.json') @{ url = $base + $name; startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o') }
    $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false; $handler.UseCookies = $false; $handler.UseProxy = $false; $handler.UseDefaultCredentials = $false
    $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [TimeSpan]::FromSeconds(30)
    try {
        $response = $client.GetAsync($base + $name).GetAwaiter().GetResult()
        try {
            $httpStatus = [int]$response.StatusCode
            if ($httpStatus -eq 200) {
                $official = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                if ($official.Length -gt 0 -and $official.Length -le 65536) {
                    [IO.File]::WriteAllBytes((Join-Path $out ($name + '.cdn')), $official)
                    $rows = Read-NllResourceGuidance $official
                    if (Test-NllGuidanceMatchesPatchState $rows $state) {
                        $bytes = $official; $origin = 'cdn_exact_request_matching_patch_state'
                        $revisions = [ordered]@{}; foreach ($role in 'core', 'dp', 'en', 'ja', 'ko', 'fd', 'saus') { $revisions[$role] = $rows[$role].revision }
                    }
                }
            }
        } finally { $response.Dispose() }
    } finally { $client.Dispose(); $handler.Dispose() }
}
if ($null -eq $bytes) { $bytes = [Text.UTF8Encoding]::new($false).GetBytes($local.lines -join "`n") }
[IO.File]::WriteAllBytes((Join-Path $out $name), $bytes)

$pck = Join-Path $b.serverRoot ('cache\' + $baseUri.AbsolutePath.TrimStart('/').Replace('/', '\'))
Assert-NllClientUpdate (-not (Test-Path (Join-Path $pck $name))) 'guidance_exists'
New-Item -ItemType Directory -Path $pck -Force | Out-Null
Copy-RnNew (Join-Path $out $name) (Join-Path $pck $name)
foreach ($role in $revisions.Keys) {
    $dest = Join-Path $pck ($role + '\' + $revisions[$role])
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    foreach ($leaf in 'catalog.ndb', 'catalog.ndb.nds') { if (-not (Test-Path (Join-Path $dest $leaf))) { Copy-RnNew (Join-Path $patch "$role\$leaf") (Join-Path $dest $leaf) } }
}

$manifestPath = [string]$b.manifestPath
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $out 'bundle.before.json')
Copy-Item -LiteralPath $selection -Destination (Join-Path $out 'selection.before.json')
$bundle = Get-Content $manifestPath -Raw | ConvertFrom-Json
$before = @($bundle.files).Count
$root = Split-Path $manifestPath -Parent
$bundle.files = @(Get-ChildItem $root -Recurse -File | Where-Object FullName -NE $manifestPath | Sort-Object FullName | ForEach-Object { Get-RnPin $_.FullName })
Assert-NllClientUpdate (@($bundle.files).Count -eq $before + 15) 'bundle_file_count_invalid'
Write-NllClientUpdateJson $manifestPath $bundle
Write-NllClientUpdateJson $selection @{ contractId = 'nll/phase-d-runtime-selection/v1'; manifest = (Get-RnPin $manifestPath) }
$null = Read-PdRuntimeBundle $selection -FullVerification
$receipt = [ordered]@{ status = 'guidance_supplied'; request = $name; origin = $origin; cdnHttpStatus = $httpStatus
    guidanceSha256 = (Get-NllClientUpdateHash (Join-Path $out $name)); patchStateSha256 = (Get-NllClientUpdateHash $statePath)
    servedFiles = 15; bundle = (Get-RnPin $manifestPath); clientStarted = $false }
Write-NllClientUpdateJson (Join-Path $out 'supply.receipt.json') $receipt
$receipt | ConvertTo-Json -Depth 5
