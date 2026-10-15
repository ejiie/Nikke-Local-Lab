$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Synthetic checks for scripts/client-update (docs/operations/CLIENT_UPDATE.md). No client, network, runtime or registry.
$toolkit = Join-Path $PSScriptRoot 'client-update'
. (Join-Path $toolkit 'Nll.ClientUpdate.ps1')
$count = 0
function Check([bool]$Value, [string]$Name) { if (-not $Value) { throw "client_update_toolkit_test_failed_$Name" }; $script:count++ }
function Rejects([scriptblock]$Block, [string]$Name) { $failed = $false; try { & $Block | Out-Null } catch { $failed = $true }; Check $failed $Name }

foreach ($script in Get-ChildItem $toolkit -File -Filter '*.ps1') {
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$null, [ref]$errors)
    Check (@($errors).Count -eq 0) ('parse_' + $script.BaseName)
}
foreach ($script in Get-ChildItem $toolkit -File -Filter '*.py') {
    & python -B -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" $script.FullName
    Check ($LASTEXITCODE -eq 0) ('python_parse_' + $script.BaseName)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-client-update-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $example = Get-Content (Join-Path (Split-Path -Parent $PSScriptRoot) 'config/client-update.plan.example.json') -Raw | ConvertFrom-Json
    $example.upstreamCommit = 'a' * 40; $example.gameConfigSha256 = 'b' * 64
    function Plan([scriptblock]$Mutation) {
        $plan = $example | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        if ($Mutation) { & $Mutation $plan }
        $path = Join-Path $root ([guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($path, ($plan | ConvertTo-Json -Depth 5))
        Read-NllClientUpdatePlan $path 'C:\Repository'
    }
    $plan = Plan $null
    Check ($plan.clientRoot -ceq 'C:\NLL\Clients\NIKKE-152.8.13-ResourceProbe' -and
        $plan.previousClientRoot -ceq 'C:\NLL\Clients\NIKKE-152.8.11-ResourceProbe' -and
        $plan.workRoot -ceq 'C:\Repository\artifacts\apply-152.8.13-20261015') 'plan_derived_paths'
    Rejects { Plan { param($p) $p.officialRoot = 'C:\NIKKE' } } 'plan_rejects_old_official_root'
    Rejects { Plan { param($p) $p.previousBuild = $p.build } } 'plan_rejects_unchanged_build'
    Rejects { Plan { param($p) $p.runtimeRoot = 'C:\NLL\Runtime\Other' } } 'plan_rejects_runtime_root'
    Rejects { Plan { param($p) $p.stagingRoot = 'C:\Temp\update' } } 'plan_rejects_staging_root'
    Rejects { Plan { param($p) $p.upstreamCommit = 'main' } } 'plan_rejects_branch_name'
    Rejects { Plan { param($p) $p.contractId = 'nll/client-update-plan/v0' } } 'plan_rejects_contract'

    $state = [pscustomobject]@{ coreRevision = 300; subEntryRevisions = @(
        foreach ($row in @(@('core', 300), @('dp', 301), @('en', 302), @('ja', 302), @('ko', 302), @('fd', 250), @('saus', 303))) {
            [pscustomobject]@{ name = $row[0]; revision = $row[1] } }) }
    $catalogs = @{}; $i = 0
    foreach ($role in 'core', 'dp', 'en', 'ja', 'ko', 'fd', 'saus') { $catalogs[$role] = ([string]$i) * 64; $i++ }
    $g = New-NllLocalResourceGuidance '152.8.13' $state ('f' * 64) $catalogs
    Check (($g.lines -join '|') -ceq 'fffffff|core:152.8.c300,300|dp:1111111,301|en:2222222,302|ja:2222222,302|ko:2222222,302|fd:5555555,250|saus:6666666,303') 'local_guidance_lines'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($g.lines -join "`n")
    Check ($bytes[-1] -ne 10) 'local_guidance_no_final_newline'
    $rows = Read-NllResourceGuidance $bytes
    Check (Test-NllGuidanceMatchesPatchState $rows $state) 'guidance_matches_patch_state'
    $older = $state | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $older.subEntryRevisions[5].revision = 251
    Check (-not (Test-NllGuidanceMatchesPatchState $rows $older)) 'guidance_rejects_other_publication'
    $missing = $state | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $missing.subEntryRevisions = @($missing.subEntryRevisions | Where-Object name -NE 'saus')
    Rejects { New-NllLocalResourceGuidance '152.8.13' $missing ('f' * 64) $catalogs } 'local_guidance_rejects_missing_role'
    $core = $state | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $core.coreRevision = 299
    Rejects { New-NllLocalResourceGuidance '152.8.13' $core ('f' * 64) $catalogs } 'local_guidance_rejects_core_mismatch'
    Rejects { Read-NllResourceGuidance ([Text.Encoding]::UTF8.GetBytes("tag`ncore:1.2.c3,3")) } 'guidance_rejects_short_file'
    Rejects { Read-NllResourceGuidance ([Text.Encoding]::UTF8.GetBytes("tag`ncore:x,1`ndp:a,1`nen:a,1`nja:a,1`nko:a,1`nfd:a,1`nSaus:a,1")) } 'guidance_rejects_bad_role'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
"Client update toolkit: $count synthetic parse, plan and guidance checks passed; no client, network or runtime access."
