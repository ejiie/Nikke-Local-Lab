# Shared helpers for the client update toolkit (docs/operations/CLIENT_UPDATE.md).
# One private plan file per update names every input; steps read it and never guess paths or versions.
function Assert-NllClientUpdate([bool]$Value, [string]$Code) { if (-not $Value) { throw ('client_update_' + $Code) } }
function Get-NllClientUpdateHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Write-NllClientUpdateJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 90), [Text.UTF8Encoding]::new($false))
}

function Read-NllClientUpdatePlan([string]$PlanPath, [string]$RepositoryRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) {
    $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
    Assert-NllClientUpdate ($plan.contractId -ceq 'nll/client-update-plan/v1') 'plan_contract_invalid'
    foreach ($name in 'build', 'previousBuild') {
        Assert-NllClientUpdate ([string]$plan.$name -cmatch '^[0-9]+\.[0-9]+\.[0-9]+$') ('plan_' + $name + '_invalid')
    }
    Assert-NllClientUpdate ($plan.build -cne $plan.previousBuild) 'plan_build_unchanged'
    # Path authority: the official install is read-only input; everything written lives in the NLL lanes.
    Assert-NllClientUpdate ($plan.officialRoot -ceq 'E:\NIKKE') 'plan_official_root_invalid'
    Assert-NllClientUpdate ([string]$plan.stagingRoot -cmatch '^C:\\NLL\\Staging\\ClientUpdates\\[0-9.]+-[0-9]{8}$') 'plan_staging_root_invalid'
    Assert-NllClientUpdate ([string]$plan.runtimeRoot -cmatch '^C:\\NLL\\Runtime\\PhaseD[0-9]+-v[1-9][0-9]*$') 'plan_runtime_root_invalid'
    Assert-NllClientUpdate ([string]$plan.pipelineInputsRoot -cmatch '^C:\\NLL\\RuntimeInputs\\BossPipeline\\[0-9.]+-v[1-9][0-9]*$') 'plan_inputs_root_invalid'
    Assert-NllClientUpdate ([string]$plan.workName -cmatch '^apply-[0-9.]+-[0-9]{8}$') 'plan_work_name_invalid'
    Assert-NllClientUpdate ([string]$plan.upstreamCommit -cmatch '^[0-9a-f]{40}$') 'plan_upstream_commit_invalid'
    Assert-NllClientUpdate ([string]$plan.installationId -cmatch '^nll-[0-9.]+-[0-9]{8}$') 'plan_installation_id_invalid'
    foreach ($name in 'gameConfigPath', 'staticDataPackPath', 'serverPublishRoot', 'serverSourceRoot', 'localeStagingRoot', 'previousSourceManifestPath') {
        Assert-NllClientUpdate ([IO.Path]::IsPathFullyQualified([string]$plan.$name)) ('plan_' + $name + '_invalid')
    }
    Assert-NllClientUpdate ([string]$plan.gameConfigSha256 -cmatch '^[0-9a-f]{64}$') 'plan_game_config_hash_invalid'
    $plan | Add-Member -NotePropertyName repositoryRoot -NotePropertyValue ([IO.Path]::GetFullPath($RepositoryRoot)) -Force
    $plan | Add-Member -NotePropertyName clientRoot -NotePropertyValue ('C:\NLL\Clients\NIKKE-' + $plan.build + '-ResourceProbe') -Force
    $plan | Add-Member -NotePropertyName previousClientRoot -NotePropertyValue ('C:\NLL\Clients\NIKKE-' + $plan.previousBuild + '-ResourceProbe') -Force
    $plan | Add-Member -NotePropertyName workRoot -NotePropertyValue (Join-Path $plan.repositoryRoot ('artifacts\' + $plan.workName)) -Force
    $plan
}

# Resource guidance served when no published guidance matches the sealed clone (operator decision 2026-10-16).
# Publications are the installed ones; revision folders and the tag are derived from installed files, never guessed
# official names. Layout follows the official file: tag line, then core, dp, en, ja, ko, fd, saus; LF, no final newline.
function New-NllLocalResourceGuidance([string]$Build, [object]$PatchState, [string]$PatchStateSha256, [hashtable]$CatalogSha256) {
    Assert-NllClientUpdate ($Build -cmatch '^([0-9]+\.[0-9]+)\.[0-9]+$') 'build_invalid'
    $prefix = $Matches[1]
    $order = @('core', 'dp', 'en', 'ja', 'ko', 'fd', 'saus')
    $publication = @{}
    foreach ($entry in $PatchState.subEntryRevisions) { $publication[[string]$entry.name] = [long]$entry.revision }
    Assert-NllClientUpdate ($publication.Count -eq 7 -and @($order | Where-Object { -not $publication.ContainsKey($_) }).Count -eq 0) 'patch_state_roles_invalid'
    Assert-NllClientUpdate ([long]$PatchState.coreRevision -eq $publication['core']) 'patch_state_core_invalid'
    foreach ($role in $order) { Assert-NllClientUpdate ([string]$CatalogSha256[$role] -cmatch '^[0-9a-f]{64}$') 'catalog_hash_invalid' }
    Assert-NllClientUpdate ($PatchStateSha256 -cmatch '^[0-9a-f]{64}$') 'patch_state_hash_invalid'
    $language = $CatalogSha256['en'].Substring(0, 7)
    $revision = [ordered]@{ core = ($prefix + '.c' + $publication['core']); dp = $CatalogSha256['dp'].Substring(0, 7); en = $language; ja = $language
        ko = $language; fd = $CatalogSha256['fd'].Substring(0, 7); saus = $CatalogSha256['saus'].Substring(0, 7) }
    [pscustomobject]@{
        lines = @($PatchStateSha256.Substring(0, 7)) + @($order | ForEach-Object { '{0}:{1},{2}' -f $_, $revision[$_], $publication[$_] })
        revisions = $revision; publications = $publication
    }
}

function Read-NllResourceGuidance([byte[]]$Bytes) {
    $lines = @(([Text.UTF8Encoding]::new($false, $true).GetString($Bytes)).Trim() -split '\r?\n')
    Assert-NllClientUpdate ($lines.Count -eq 8 -and $lines[0] -cmatch '^[a-z0-9]+$') 'guidance_format_invalid'
    $rows = @{}
    foreach ($line in $lines | Select-Object -Skip 1) {
        Assert-NllClientUpdate ($line -cmatch '^([a-z]+):([0-9a-z.]+),([0-9]+)$') 'guidance_row_invalid'
        $rows[$Matches[1]] = [pscustomobject]@{ revision = $Matches[2]; publication = [long]$Matches[3] }
    }
    Assert-NllClientUpdate ($rows.Count -eq 7) 'guidance_role_count_invalid'
    $rows
}

function Test-NllGuidanceMatchesPatchState([hashtable]$Rows, [object]$PatchState) {
    @($PatchState.subEntryRevisions).Count -eq 7 -and @($PatchState.subEntryRevisions | Where-Object {
        -not $Rows.ContainsKey([string]$_.name) -or $Rows[[string]$_.name].publication -ne [long]$_.revision }).Count -eq 0
}
