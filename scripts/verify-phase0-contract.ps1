$ErrorActionPreference = "Stop"

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Test-Uuid {
    param([object]$Value)
    return (($Value -is [string]) -and ($Value -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
}

function Assert-Sha256 {
    param(
        [object]$Value,
        [string]$Message
    )
    Assert-True (($Value -is [string]) -and ($Value -match '^[0-9a-f]{64}$')) $Message
}

function Get-TextSha256 {
    param([string]$Value)
    $Algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $Digest = $Algorithm.ComputeHash($Bytes)
        return [System.BitConverter]::ToString($Digest).Replace("-", "").ToLowerInvariant()
    } finally {
        $Algorithm.Dispose()
    }
}

function Assert-CharacterFixture {
    param(
        [object]$Fixture,
        [bool]$ExpectCubeEquipped
    )

    Assert-True ($Fixture.defaultPolicy -eq "combat-max/v1") "Synthetic fixture policy mismatch."
    Assert-True ($Fixture.validationMode -eq "research") "Synthetic fixture must exercise research write mode."
    Assert-True ($Fixture.state.characterLevelPolicy -eq "explicit") "Character level must use explicit policy."
    Assert-True (($Fixture.state.characterLevel -is [int]) -or ($Fixture.state.characterLevel -is [long])) "Character level must be an integer."
    Assert-True ($Fixture.state.characterLevel -ge 1) "Character level must be positive."
    Assert-True ($Fixture.state.limitBreak.policy -eq "max_supported") "Synthetic limit-break policy mismatch."
    Assert-True ($Fixture.state.limitBreak.resolved -eq $true) "Synthetic limit break must be resolved."
    Assert-True ($Fixture.state.bond.policy -eq "max_for_character") "Synthetic bond policy mismatch."
    Assert-True ($Fixture.state.bond.resolved -eq $true) "Synthetic bond must be resolved."
    Assert-True ($Fixture.state.equipment.Count -eq 4) "Synthetic fixture must contain four equipment slots."

    $ExpectedSlots = @("arms", "head", "legs", "torso")
    $ActualSlots = @($Fixture.state.equipment | ForEach-Object { $_.slot } | Sort-Object -Unique)
    Assert-True (($ActualSlots -join ",") -eq ($ExpectedSlots -join ",")) "Equipment slots must be unique and complete."

    foreach ($Equipment in $Fixture.state.equipment) {
        Assert-True (Test-Uuid $Equipment.equipmentDefinitionUid) "Equipment definition must use a synthetic UUID."
        Assert-True ($Equipment.tier -eq 10) "Every equipment slot must default to Tier 10."
        Assert-True ($Equipment.enhancementLevel -eq 5) "Every equipment slot must default to enhancement Level 5."
        Assert-True ($Equipment.overloadLines.Count -le 3) "An equipment slot cannot contain more than three overload lines."
        $LineIndexes = @($Equipment.overloadLines | ForEach-Object { $_.lineIndex })
        Assert-True (($LineIndexes | Sort-Object -Unique).Count -eq $LineIndexes.Count) "Overload line indexes must be unique within a slot."
        foreach ($Line in $Equipment.overloadLines) {
            Assert-True ($Line.exactValue -is [string]) "Overload exactValue must round-trip as a string."
            Assert-True ($Line.exactValue -match '^-?(0|[1-9][0-9]*)(\.[0-9]+)?$') "Overload exactValue is not an exact decimal string."
        }
    }

    Assert-True ($Fixture.state.cube.equipped -eq $ExpectCubeEquipped) "Synthetic cube equipped state mismatch."
    if ($ExpectCubeEquipped) {
        Assert-True (Test-Uuid $Fixture.state.cube.cubeUid) "Equipped cube must use a synthetic UUID."
        Assert-True ($Fixture.state.cube.level -eq 15) "Equipped synthetic cube must default to Level 15."
    } else {
        Assert-True ($null -eq $Fixture.state.cube.cubeUid) "Detached cube UID must be null."
        Assert-True ($null -eq $Fixture.state.cube.level) "Detached cube level must be null."
    }

    Assert-True ($Fixture.state.skills.skill1 -eq 10) "Synthetic Skill 1 mismatch."
    Assert-True ($Fixture.state.skills.skill2 -eq 10) "Synthetic Skill 2 mismatch."
    Assert-True ($Fixture.state.skills.burst -eq 10) "Synthetic Burst mismatch."
    Assert-True ($Fixture.state.collectionItem.policy -eq "max_available") "Synthetic collection item must use max_available."
    Assert-True ($Fixture.state.favoriteItem.applicability -eq "applicable") "Synthetic favorite item must be applicable."
    Assert-True ($Fixture.state.favoriteItem.policy -eq "max_available") "Synthetic favorite item must default to max_available."
    Assert-True ($Fixture.state.favoriteItem.resolved -eq $true) "Synthetic favorite item must be resolved."
    Assert-True ($Fixture.readiness.status -eq "ready") "Resolved synthetic combat inputs must be ready."
    Assert-True (@($Fixture.readiness.warnings).Count -eq 0) "Ready character fixture cannot contain warnings."
}

function New-RaidVariantJson {
    param(
        [int]$SeasonNumber,
        [string]$Rule,
        [string]$BossElement,
        [string]$WeaknessCode
    )

    $Variant = $RaidFixtureText | ConvertFrom-Json
    $Variant.seasonNumber = $SeasonNumber
    $Variant.admission.rule = $Rule
    $Variant.admission.bossElement = $BossElement
    $Variant.admission.weaknessCode = $WeaknessCode
    return $Variant | ConvertTo-Json -Depth 100
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$ConfigPath = Join-Path $RepositoryRoot "config/appsettings.example.json"
$EquippedFixturePath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/character-build.combat-max-v1.json"
$DetachedFixturePath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/character-build.cube-detached.json"
$RaidFixturePath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/raid-snapshot.challenge.json"
$CharacterSchemaPath = Join-Path $RepositoryRoot "contracts/character-build.schema.json"
$RaidSchemaPath = Join-Path $RepositoryRoot "contracts/raid-snapshot.schema.json"

$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$EquippedFixture = Get-Content -Raw -LiteralPath $EquippedFixturePath | ConvertFrom-Json
$DetachedFixture = Get-Content -Raw -LiteralPath $DetachedFixturePath | ConvertFrom-Json
$RaidFixtureText = Get-Content -Raw -LiteralPath $RaidFixturePath
$RaidFixture = $RaidFixtureText | ConvertFrom-Json
Get-Content -Raw -LiteralPath $CharacterSchemaPath | ConvertFrom-Json | Out-Null
Get-Content -Raw -LiteralPath $RaidSchemaPath | ConvertFrom-Json | Out-Null

Assert-True ($PSVersionTable.PSVersion -ge [Version]"7.4") "Phase 0 schema validation requires PowerShell 7.4 or later (pwsh)."
Assert-True ($null -ne (Get-Command Test-Json -ErrorAction SilentlyContinue)) "Test-Json is required for Draft 2020-12 validation."
Assert-True (Test-Json -LiteralPath $EquippedFixturePath -SchemaFile $CharacterSchemaPath) "Equipped character fixture does not satisfy its JSON Schema."
Assert-True (Test-Json -LiteralPath $DetachedFixturePath -SchemaFile $CharacterSchemaPath) "Detached character fixture does not satisfy its JSON Schema."
Assert-True (Test-Json -LiteralPath $RaidFixturePath -SchemaFile $RaidSchemaPath) "Challenge raid fixture does not satisfy its JSON Schema."

$InvalidCubeFixtureText = [regex]::Replace(
    (Get-Content -Raw -LiteralPath $DetachedFixturePath),
    '("cubeUid": null,\s*"level": )null',
    { param($Match) $Match.Groups[1].Value + "15" }
)
Assert-True (-not (Test-Json -Json $InvalidCubeFixtureText -SchemaFile $CharacterSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject a detached cube with a non-null level."
$InvalidUuidFixtureText = (Get-Content -Raw -LiteralPath $EquippedFixturePath).Replace(
    "00000000-0000-4000-8000-000000000101",
    "not-a-canonical-uuid"
)
Assert-True (-not (Test-Json -Json $InvalidUuidFixtureText -SchemaFile $CharacterSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject a non-canonical UUID."
$InvalidRuntimeTierText = $RaidFixtureText.Replace(
    '"runtimeRelation": "current_runtime_match"',
    '"runtimeRelation": "not_evaluated"'
)
Assert-True (-not (Test-Json -Json $InvalidRuntimeTierText -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject a current-runtime tier without a current runtime match."

$Defaults = $Config.characterBuildDefaults
Assert-True ($Defaults.policyId -eq "combat-max/v1") "Default policy must be combat-max/v1."
Assert-True ($Defaults.characterLevel -eq "explicit_required") "Character level must require an explicit value."
Assert-True ($Defaults.limitBreak -eq "max_supported") "Limit break must default to max_supported."
Assert-True ($Defaults.bond -eq "max_for_character") "Bond must default to max_for_character."
Assert-True ($Defaults.equipmentTier -eq 10) "Equipment must default to Tier 10."
Assert-True ($Defaults.equipmentEnhancementLevel -eq 5) "Equipment enhancement level must default to 5."
Assert-True ($Defaults.cubeInitialState -eq "unequipped") "Cube must initially be unequipped when no kind was selected."
Assert-True ($Defaults.cubeSelection -eq "explicit_required") "Cube selection must not be guessed."
Assert-True ($Defaults.cubeLevelWhenEquipped -eq 15) "An equipped cube must default to Level 15."
Assert-True ($Defaults.skillLevels.skill1 -eq 10) "Skill 1 must default to Level 10."
Assert-True ($Defaults.skillLevels.skill2 -eq 10) "Skill 2 must default to Level 10."
Assert-True ($Defaults.skillLevels.burst -eq 10) "Burst must default to Level 10."
Assert-True ($Defaults.overloadValidationMode -eq "research") "Overload must default to research write mode."
Assert-True ($Defaults.collectionItem -eq "max_if_applicable") "Collection item policy mismatch."
Assert-True ($Defaults.favoriteItem -eq "max_if_applicable") "Favorite item policy mismatch."

Assert-True ($Config.network.allowOfficialOutbound -eq $false) "Official outbound must be disabled."
Assert-True ($Config.network.localAuthenticationRequiredForLan -eq $true) "LAN must require local authentication."
Assert-True ($Config.sources.gameFilesReadOnly -eq $true) "Game files must remain read-only."
Assert-True ($Config.sources.allowOfficialNetwork -eq $false) "Official network sources must be disabled."
Assert-True ($Config.sources.allowAuthenticatedSources -eq $false) "Authenticated sources must be disabled."
Assert-True ($Config.originalClientCompatibility.enabled -eq $false) "Original client compatibility must be gated off."
Assert-True ($Config.originalClientCompatibility.status -eq "blocked") "Original client compatibility status must be blocked."
Assert-True ($Config.originalClientCompatibility.allowEndpointMutation -eq $false) "Endpoint mutation must remain disabled."
Assert-True ($Config.originalClientCompatibility.allowAuthBypass -eq $false) "Auth bypass must remain disabled."
Assert-True ($Config.originalClientCompatibility.allowAntiCheatBypass -eq $false) "Anti-cheat bypass must remain disabled."

Assert-CharacterFixture $EquippedFixture $true
Assert-CharacterFixture $DetachedFixture $false
Assert-True ($EquippedFixture.buildUid -eq $DetachedFixture.buildUid) "Cube detach must create a new revision of the same build."
Assert-True ($EquippedFixture.revisionUid -ne $DetachedFixture.revisionUid) "Build revisions must use distinct UUIDs."
Assert-True ($DetachedFixture.revisionNumber -eq ($EquippedFixture.revisionNumber + 1)) "Cube detach revision number must increment."

$SoloRaid = $Config.soloRaid
Assert-True ($SoloRaid.enabled -eq $true) "Solo Raid must be enabled."
Assert-True (($SoloRaid.supportedModes.Count -eq 1) -and ($SoloRaid.supportedModes[0] -eq "challenge")) "Only Challenge mode may be supported."
Assert-True ($SoloRaid.challengeCompatibility.difficultyType -eq 2) "Challenge difficulty selector mismatch."
Assert-True ($SoloRaid.challengeCompatibility.waveOrder -eq 8) "Challenge wave selector mismatch."
Assert-True ($SoloRaid.normalStages.implemented -eq $false) "Normal Solo Raid battles must not be implemented."
Assert-True ($SoloRaid.normalStages.unlockStateOnly -eq $true) "Normal stages may only supply unlock state."
Assert-True ($SoloRaid.normalStages.lastClearLevel -eq 7) "Challenge unlock stub must report lastClearLevel 7."
Assert-True ($SoloRaid.unionRaidEnabled -eq $false) "Union Raid must remain disabled in Phase 0."
Assert-True ($SoloRaid.requireRuntimeMatchForOriginalClientExecution -eq $true) "Original-client execution must require a runtime match."

$Policy = $SoloRaid.supportPolicy
Assert-True ($Policy.policyId -eq "challenge-boss-support/v1") "Solo Raid support policy mismatch."
Assert-True ((@($Policy.excludedSeasonNumbers) -join ",") -eq "14,39") "Excluded seasons must be exactly 14 and 39."
Assert-True (-not ($Policy.PSObject.Properties.Name -contains "currentDerivedSeasonAllowlist")) "A dataset-derived allowlist must not become a second config constraint."
Assert-True ($Policy.rejectUnresolvedCandidates -eq $true) "Unresolved Challenge candidates must be rejected."
Assert-True (@($Policy.rules).Count -eq 2) "Support policy must contain exactly two rules."
$ElementRule = @($Policy.rules | Where-Object { $_.kind -eq "element_weakness" })
$SeasonRule = @($Policy.rules | Where-Object { $_.kind -eq "explicit_season" })
Assert-True (($ElementRule.Count -eq 1) -and ($ElementRule[0].bossElement -eq "electric") -and ($ElementRule[0].weaknessCode -eq "iron")) "Electric/Iron support rule mismatch."
Assert-True (($SeasonRule.Count -eq 1) -and ($SeasonRule[0].seasonNumber -eq 40)) "Season 40 explicit rule mismatch."

Assert-True ($RaidFixture.mode -eq "challenge") "Raid snapshot must be Challenge-only."
Assert-True ($RaidFixture.schemaVersion -eq 2) "Published RaidSnapshot must use schema version 2."
Assert-True ($RaidFixture.seasonNumber -eq 40) "Synthetic raid fixture must exercise Season 40."
Assert-True ($RaidFixture.challengeCompatibility.difficultyType -eq 2) "Raid snapshot difficulty selector mismatch."
Assert-True ($RaidFixture.challengeCompatibility.waveOrder -eq 8) "Raid snapshot wave selector mismatch."
Assert-True ($RaidFixture.admission.policyId -eq "challenge-boss-support/v1") "Raid snapshot admission policy mismatch."
Assert-True ($RaidFixture.admission.rule -eq "season_40_explicit") "Season 40 admission rule mismatch."
Assert-True (($RaidFixture.admission.bossElement -eq "wind") -and ($RaidFixture.admission.weaknessCode -eq "fire")) "Season 40 normalized element/weakness mismatch."
Assert-True (-not ($RaidFixture.PSObject.Properties.Name -contains "normalStageUnlockStub")) "Normal-stage unlock state must not be embedded in RaidSnapshot."
Assert-True (-not ($RaidFixture.PSObject.Properties.Name -contains "execution")) "Live execution state must not be embedded in RaidSnapshot."

$AcceptedElectricSeasons = @(7, 13, 26, 29, 34)
$AcceptedFutureElectric = New-RaidVariantJson 41 "electric_weak_to_iron" "electric" "iron"
$ExcludedSeason14 = New-RaidVariantJson 14 "electric_weak_to_iron" "electric" "iron"
$ExcludedSeason39 = New-RaidVariantJson 39 "electric_weak_to_iron" "electric" "iron"
$InvalidElement = New-RaidVariantJson 7 "electric_weak_to_iron" "wind" "fire"
$InvalidSeason40Rule = New-RaidVariantJson 40 "electric_weak_to_iron" "electric" "iron"
$Season40IndependentOfElement = New-RaidVariantJson 40 "season_40_explicit" "water" "electric"
foreach ($Season in $AcceptedElectricSeasons) {
    $AcceptedElectric = New-RaidVariantJson $Season "electric_weak_to_iron" "electric" "iron"
    Assert-True (Test-Json -Json $AcceptedElectric -SchemaFile $RaidSchemaPath) "Schema must accept current Electric/Iron Season $Season."
}
Assert-True (Test-Json -Json $AcceptedFutureElectric -SchemaFile $RaidSchemaPath) "Schema must preserve the rule for a future Electric/Iron season."
Assert-True (-not (Test-Json -Json $ExcludedSeason14 -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject excluded Season 14."
Assert-True (-not (Test-Json -Json $ExcludedSeason39 -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject excluded Season 39."
Assert-True (-not (Test-Json -Json $InvalidElement -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject a non-Electric admission under the Electric/Iron rule."
Assert-True (-not (Test-Json -Json $InvalidSeason40Rule -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Schema must require Season 40's explicit admission rule."
Assert-True (Test-Json -Json $Season40IndependentOfElement -SchemaFile $RaidSchemaPath) "Season 40 admission must be explicit and independent of its current element facts."

$NullMapFixture = $RaidFixtureText | ConvertFrom-Json
$NullMapFixture.compatibilityMapUid = $null
$NullMapFixtureText = $NullMapFixture | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $NullMapFixtureText -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Published RaidSnapshot must require a compatibility map UUID."
$IncompleteFixture = $RaidFixtureText | ConvertFrom-Json
$IncompleteFixture.readiness.status = "incomplete"
$IncompleteFixtureText = $IncompleteFixture | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $IncompleteFixtureText -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Published RaidSnapshot must reject incomplete candidates."

Assert-True (Test-Uuid $RaidFixture.raidSnapshotUid) "Raid snapshot must use an own UUID."
Assert-True (Test-Uuid $RaidFixture.challengeEncounterUid) "Challenge encounter must use an own UUID."
Assert-True (Test-Uuid $RaidFixture.bossVariantUid) "Boss variant must use an own UUID."
Assert-Sha256 $RaidFixture.provenance.staticData.sha256 "StaticData provenance hash mismatch."
Assert-Sha256 $RaidFixture.provenance.assetBundleSetSha256 "Asset bundle set hash mismatch."
Assert-Sha256 $RaidFixture.provenance.behavior.sha256 "Behavior provenance hash mismatch."
Assert-Sha256 $RaidFixture.provenance.clientRuntime.sha256 "Client runtime provenance hash mismatch."
Assert-True (Test-Uuid $RaidFixture.provenance.clientRuntime.buildUid) "Client runtime must use an own build UUID."

$BundleHashes = @($RaidFixture.provenance.selectedAssetBundles | ForEach-Object { $_.sha256 })
Assert-True ($BundleHashes.Count -ge 1) "Raid snapshot must bind at least one selected asset bundle."
Assert-True (($BundleHashes | Sort-Object -Unique).Count -eq $BundleHashes.Count) "Selected asset bundle hashes must be unique."
Assert-True (($BundleHashes -join ",") -eq (($BundleHashes | Sort-Object) -join ",")) "Selected asset bundle hashes must be canonically sorted."
foreach ($Hash in $BundleHashes) {
    Assert-Sha256 $Hash "Selected asset bundle hash mismatch."
}
$CanonicalBundleSet = $BundleHashes -join "`n"
$ComputedBundleSetHash = Get-TextSha256 $CanonicalBundleSet
Assert-True ($RaidFixture.provenance.assetBundleSetSha256 -eq $ComputedBundleSetHash) "Asset bundle set hash does not match the canonical sorted hash list."
$BundleArtifactUids = @($RaidFixture.provenance.selectedAssetBundles | ForEach-Object { $_.artifactUid })
Assert-True (($BundleArtifactUids | Sort-Object -Unique).Count -eq $BundleArtifactUids.Count) "Selected asset bundle artifact UUIDs must be unique."
foreach ($ArtifactUid in $BundleArtifactUids) {
    Assert-True (Test-Uuid $ArtifactUid) "Selected asset bundle must use an own artifact UUID."
}
foreach ($Timeline in @($RaidFixture.provenance.timelines)) {
    Assert-Sha256 $Timeline.sha256 "Timeline provenance hash mismatch."
}

$AllowedTiers = @(
    "static_exact",
    "behavior_exact",
    "asset_exact_runtime_current",
    "historical_runtime_exact"
)
Assert-True ($AllowedTiers -contains $RaidFixture.compatibility.tier) "Unknown raid compatibility tier."
Assert-True ($RaidFixture.compatibility.runtimeRelation -eq "current_runtime_match") "Synthetic asset-exact fixture must bind the current runtime."
Assert-True ($RaidFixture.readiness.status -eq "ready") "Synthetic raid evidence fixture must be data-ready."

$ForbiddenRaidKeys = '(?i)"(monster(_?id)?|spot(_?ai)?|preset(_?id)?|wave(_?id)?|asset(path|_?id)|source(path|_?id)|file(name)?)"\s*:'
Assert-True ($RaidFixtureText -notmatch $ForbiddenRaidKeys) "Raid fixture exposes a forbidden raw source key."

Write-Output "Phase 0 character-build and restricted Challenge raid contracts passed."
