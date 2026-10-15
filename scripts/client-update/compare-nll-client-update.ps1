param([Parameter(Mandatory)][string]$PlanPath)
# CLIENT_UPDATE step 1 (read-only): manifest of the official install with the clone helpers, compared with the
# previous sealed clone's source manifest. Writes only into the plan's staging folder; nothing is started.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ClientUpdate.ps1')
$plan = Read-NllClientUpdatePlan $PlanPath
. (Join-Path $plan.repositoryRoot 'scripts/new-nll-resource-probe-clone.ps1')
New-Item -ItemType Directory -Path $plan.stagingRoot -Force | Out-Null
Assert-NllCloneCold
$started = [DateTime]::UtcNow
$source = Get-NllClonePlan $plan.officialRoot $plan.build
Assert-NllCloneCold
Write-NllCloneNewJson (Join-Path $plan.stagingRoot "source-$($plan.build).private.json") $source
$old = Get-Content -LiteralPath $plan.previousSourceManifestPath -Raw | ConvertFrom-Json
Assert-NllClientUpdate ($old.build -ceq $plan.previousBuild) 'previous_manifest_build_mismatch'
$oldMap = @{}; foreach ($m in $old.members) { $oldMap[$m.relativePath] = $m }
$newMap = @{}; foreach ($m in $source.members) { $newMap[$m.relativePath] = $m }
$changed = @($source.members | Where-Object { $oldMap.ContainsKey($_.relativePath) -and $oldMap[$_.relativePath].sha256 -cne $_.sha256 } |
    ForEach-Object { [ordered]@{ path = $_.relativePath; before = $oldMap[$_.relativePath].byteLength; after = $_.byteLength } })
$added = @($source.members | Where-Object { -not $oldMap.ContainsKey($_.relativePath) } | ForEach-Object { [ordered]@{ path = $_.relativePath; after = $_.byteLength } })
$removed = @($old.members | Where-Object { -not $newMap.ContainsKey($_.relativePath) } | ForEach-Object { [ordered]@{ path = $_.relativePath; before = $_.byteLength } })
$keyFiles = foreach ($p in 'NIKKE/game/nikke.exe', 'NIKKE/game/GameAssembly.dll', 'NIKKE/game/UnityPlayer.dll', 'NIKKE/game/nikkeBase.dll') {
    [ordered]@{ path = $p; before = $(if ($oldMap.ContainsKey($p)) { $oldMap[$p].sha256 }); after = $(if ($newMap.ContainsKey($p)) { $newMap[$p].sha256 }) }
}
$report = [ordered]@{ contractId = 'nll/client-update-compare/v1'; sourceRoot = $plan.officialRoot; build = $plan.build
    planSha256 = $source.planSha256; fileCount = $source.fileCount; byteLength = $source.byteLength
    previousBuild = $old.build; previousPlanSha256 = $old.planSha256; previousFileCount = $old.fileCount; previousByteLength = $old.byteLength
    changedCount = $changed.Count; addedCount = $added.Count; removedCount = $removed.Count
    keyFiles = $keyFiles; changed = $changed; added = $added; removed = $removed
    hashedSeconds = [int]([DateTime]::UtcNow - $started).TotalSeconds; sourceMutationPerformed = $false; clientStarted = $false }
Write-NllCloneNewJson (Join-Path $plan.stagingRoot "compare-$($plan.previousBuild)-$($plan.build).private.json") $report
# The clone step needs these three values (new-nll-resource-probe-clone.ps1 -Expected*).
[ordered]@{ planSha256 = $source.planSha256; fileCount = $source.fileCount; byteLength = $source.byteLength
    executableSha256 = $newMap['NIKKE/game/nikke.exe'].sha256; assemblySha256 = $newMap['NIKKE/game/GameAssembly.dll'].sha256
    changed = $changed.Count; added = $added.Count; removed = $removed.Count } | ConvertTo-Json
