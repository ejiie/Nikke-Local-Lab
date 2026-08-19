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

function Assert-ControlledCode {
    param(
        [object]$Value,
        [string]$Message
    )
    Assert-True (($Value -is [string]) -and ($Value -match '^[a-z][a-z0-9._-]{0,63}$')) $Message
}

function Assert-ReadyIntegerFact {
    param(
        [object]$Fact,
        [int]$Expected,
        [string]$Message
    )
    Assert-True ($Fact.status -eq "ready") "$Message status mismatch."
    Assert-True ((($Fact.value -is [int]) -or ($Fact.value -is [long])) -and ($Fact.value -eq $Expected)) "$Message value mismatch."
}

function Assert-SupportReference {
    param(
        [object]$Reference,
        [string]$ExpectedKind,
        [string]$ExpectedDatasetUid,
        [string]$Message
    )
    Assert-True (Test-Uuid $Reference.definitionUid) "$Message definition UID mismatch."
    Assert-True (Test-Uuid $Reference.definitionVersionUid) "$Message version UID mismatch."
    Assert-True ($Reference.datasetSnapshotUid -eq $ExpectedDatasetUid) "$Message dataset binding mismatch."
    Assert-True ($Reference.kind -eq $ExpectedKind) "$Message kind mismatch."
    Assert-Sha256 $Reference.contentSha256 "$Message content hash mismatch."
}

function Assert-CharacterFixture {
    param(
        [object]$Fixture,
        [string]$ExpectedCollectibleKind
    )

    Assert-True ($Fixture.schemaVersion -eq 2) "Synthetic character fixture must use schema v2."
    Assert-True (Test-Uuid $Fixture.buildUid) "Synthetic build must use a UUID."
    Assert-True (Test-Uuid $Fixture.revisionUid) "Synthetic build revision must use a UUID."
    Assert-True ($Fixture.materializationPolicy -eq "combat-max/v1") "Synthetic fixture materialization policy mismatch."
    Assert-True ($Fixture.validationMode -eq "research") "Synthetic fixture must exercise research write mode."

    $CharacterCatalog = $Fixture.datasetBinding.characterCatalog
    $SupportCatalog = $Fixture.datasetBinding.combatSupportCatalog
    foreach ($Binding in @($CharacterCatalog, $SupportCatalog)) {
        Assert-True (Test-Uuid $Binding.catalogSnapshotUid) "Catalog binding must use a synthetic snapshot UUID."
        Assert-True (Test-Uuid $Binding.datasetSnapshotUid) "Catalog binding must use a synthetic dataset UUID."
        Assert-Sha256 $Binding.catalogManifestSha256 "Catalog binding manifest hash mismatch."
    }
    Assert-True ($CharacterCatalog.catalogSnapshotUid -ne $SupportCatalog.catalogSnapshotUid) "Character and support catalogs must be independently pinned."
    Assert-True ($CharacterCatalog.datasetSnapshotUid -ne $SupportCatalog.datasetSnapshotUid) "Character and support datasets must not be assumed equal."

    Assert-True (Test-Uuid $Fixture.characterDefinition.characterUid) "Character reference must use a synthetic UUID."
    Assert-True (Test-Uuid $Fixture.characterDefinition.definitionVersionUid) "Character version must use a synthetic UUID."
    Assert-True ($Fixture.characterDefinition.datasetSnapshotUid -eq $CharacterCatalog.datasetSnapshotUid) "Character reference must bind to the selected character dataset."
    Assert-Sha256 $Fixture.characterDefinition.contentSha256 "Character definition hash mismatch."

    Assert-ReadyIntegerFact $Fixture.state.investment.characterLevel 400 "Character level"
    Assert-ReadyIntegerFact $Fixture.state.investment.limitBreak 3 "Limit break"
    Assert-ReadyIntegerFact $Fixture.state.investment.coreLevel 7 "Core level"
    Assert-ReadyIntegerFact $Fixture.state.investment.bondLevel 40 "Bond level"
    Assert-ReadyIntegerFact $Fixture.state.skills.skill1 10 "Skill 1"
    Assert-ReadyIntegerFact $Fixture.state.skills.skill2 10 "Skill 2"
    Assert-ReadyIntegerFact $Fixture.state.skills.burst 10 "Burst"

    Assert-True ($Fixture.state.equipment.Count -eq 4) "Synthetic fixture must contain four equipment slots."
    $ExpectedSlots = @("arms", "head", "legs", "torso")
    $ActualSlots = @($Fixture.state.equipment | ForEach-Object { $_.slot } | Sort-Object -Unique)
    Assert-True (($ActualSlots -join ",") -eq ($ExpectedSlots -join ",")) "Equipment slots must be unique and complete."
    $EquipmentSlotUids = @($Fixture.state.equipment | ForEach-Object { $_.equipmentSlotUid })
    Assert-True (($EquipmentSlotUids | Sort-Object -Unique).Count -eq 4) "Equipment slot UUIDs must be unique."

    foreach ($Equipment in $Fixture.state.equipment) {
        Assert-True (Test-Uuid $Equipment.equipmentSlotUid) "Equipment slot must use a local synthetic UUID."
        Assert-True ($Equipment.attachment -eq "attached") "Synthetic default equipment must be attached."
        Assert-SupportReference $Equipment.definition "equipment" $SupportCatalog.datasetSnapshotUid "Equipment definition"
        Assert-ReadyIntegerFact $Equipment.tier 10 "Equipment tier"
        Assert-ReadyIntegerFact $Equipment.enhancementLevel 5 "Equipment enhancement"
        Assert-True ($Equipment.manufacturerMatch.status -eq "unresolved") "Manufacturer match must remain unresolved."
        Assert-True ($null -eq $Equipment.manufacturerMatch.value) "Unresolved manufacturer match cannot carry a value."
        Assert-ControlledCode $Equipment.manufacturerMatch.reasonCode "Manufacturer issue must be a controlled code."
        Assert-True ($Equipment.overloadLines.Count -le 3) "An equipment slot cannot contain more than three overload lines."
        $LineIndexes = @($Equipment.overloadLines | ForEach-Object { $_.lineIndex })
        Assert-True (($LineIndexes | Sort-Object -Unique).Count -eq $LineIndexes.Count) "Overload line indexes must be unique within a slot."
        Assert-True (($LineIndexes -join ",") -eq (($LineIndexes | Sort-Object) -join ",")) "Overload lines must remain in fixed-coordinate order."
        foreach ($Line in $Equipment.overloadLines) {
            Assert-True ($Line.lineIndex -in 1, 2, 3) "Overload line index must be in 1..3."
            Assert-SupportReference $Line.optionDefinition "overload-option" $SupportCatalog.datasetSnapshotUid "OL option definition"
            Assert-True ($Line.optionType.status -eq "ready") "Synthetic OL option type must be ready."
            Assert-True ($Line.unit.status -eq "ready") "Synthetic OL unit must be ready."
            Assert-True (($Line.applicationValue.unscaledValue -is [int]) -or ($Line.applicationValue.unscaledValue -is [long])) "OL unscaled value must be an integer."
            Assert-True (($Line.applicationValue.decimalScale -is [int]) -or ($Line.applicationValue.decimalScale -is [long])) "OL decimal scale must be an integer."
            Assert-True ($Line.applicationValue.decimalScale -in 0..9) "OL decimal scale must be in 0..9."
        }
    }

    $HeadLineIndexes = @($Fixture.state.equipment | Where-Object slot -eq "head" | ForEach-Object { $_.overloadLines.lineIndex })
    Assert-True (($HeadLineIndexes -join ",") -eq "1,3") "Synthetic fixture must preserve sparse OL coordinates {1,3}."

    Assert-True ($Fixture.state.cube.attachment -eq "detached") "combat-max/v1 must leave the cube detached until an explicit selection is made."
    Assert-True ($null -eq $Fixture.state.cube.definition) "Detached cube definition must be null."
    Assert-True (($Fixture.state.cube.level.status -eq "not_applicable") -and ($null -eq $Fixture.state.cube.level.value)) "Detached cube level must be not_applicable."

    Assert-True ($Fixture.state.collectible.kind -eq $ExpectedCollectibleKind) "Synthetic collectible kind mismatch."
    Assert-SupportReference $Fixture.state.collectible.definition $ExpectedCollectibleKind $SupportCatalog.datasetSnapshotUid "Collectible definition"
    Assert-True ($Fixture.state.collectible.level.status -eq "ready") "Selected collectible level must be ready."

    foreach ($Result in @($Fixture.readiness.selection, $Fixture.readiness.combatSemantics)) {
        Assert-True ($Result.status -eq "unresolved") "Synthetic unresolved evidence must not be labeled ready."
        Assert-True (@($Result.issues).Count -ge 1) "Unresolved readiness must expose controlled issues."
        foreach ($Issue in @($Result.issues)) {
            Assert-True ($Issue.kind -in "unresolved", "invalid") "Unknown readiness issue kind."
            Assert-ControlledCode $Issue.fieldCode "Readiness field must be a source-free controlled code."
            Assert-ControlledCode $Issue.reasonCode "Readiness reason must be a source-free controlled code."
        }
    }
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
$CombatMaxFixturePath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/character-build.combat-max-v1.json"
$DetachedFixturePath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/character-build.cube-detached.json"
$RaidFixturePath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/raid-snapshot.challenge.json"
$StaticRaidFixturePath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/raid-snapshot.static-exact.json"
$SyntheticManifestPath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/manifest.json"
$CharacterSchemaPath = Join-Path $RepositoryRoot "contracts/character-build.schema.json"
$RaidSchemaPath = Join-Path $RepositoryRoot "contracts/raid-snapshot.schema.json"

$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$CombatMaxFixture = Get-Content -Raw -LiteralPath $CombatMaxFixturePath | ConvertFrom-Json
$DetachedFixture = Get-Content -Raw -LiteralPath $DetachedFixturePath | ConvertFrom-Json
$RaidFixtureText = Get-Content -Raw -LiteralPath $RaidFixturePath
$RaidFixture = $RaidFixtureText | ConvertFrom-Json
$StaticRaidFixtureText = Get-Content -Raw -LiteralPath $StaticRaidFixturePath
$StaticRaidFixture = $StaticRaidFixtureText | ConvertFrom-Json
$SyntheticManifest = Get-Content -Raw -LiteralPath $SyntheticManifestPath | ConvertFrom-Json
Get-Content -Raw -LiteralPath $CharacterSchemaPath | ConvertFrom-Json | Out-Null
Get-Content -Raw -LiteralPath $RaidSchemaPath | ConvertFrom-Json | Out-Null

Assert-True ($PSVersionTable.PSVersion -ge [Version]"7.4") "Phase 0 schema validation requires PowerShell 7.4 or later (pwsh)."
Assert-True ($null -ne (Get-Command Test-Json -ErrorAction SilentlyContinue)) "Test-Json is required for Draft 2020-12 validation."
Assert-True (Test-Json -LiteralPath $CombatMaxFixturePath -SchemaFile $CharacterSchemaPath) "Combat-max character fixture does not satisfy its JSON Schema."
Assert-True (Test-Json -LiteralPath $DetachedFixturePath -SchemaFile $CharacterSchemaPath) "Detached character fixture does not satisfy its JSON Schema."
Assert-True (Test-Json -LiteralPath $RaidFixturePath -SchemaFile $RaidSchemaPath) "Challenge raid fixture does not satisfy its JSON Schema."
Assert-True (Test-Json -LiteralPath $StaticRaidFixturePath -SchemaFile $RaidSchemaPath) "Static-exact raid fixture does not satisfy its JSON Schema."
Assert-True (@($SyntheticManifest.fixtures) -contains "raid-snapshot.static-exact.json") "Static-exact raid fixture must be registered in the synthetic manifest."

$ExplicitPolicyFixture = (Get-Content -Raw -LiteralPath $DetachedFixturePath) | ConvertFrom-Json
$ExplicitPolicyFixture.materializationPolicy = "explicit/v1"
$ExplicitPolicyFixture.state.cube = [pscustomobject]@{
    attachment = "attached"
    definition = [pscustomobject]@{
        definitionUid = "00000000-0000-4000-8000-000000000321"
        definitionVersionUid = "00000000-0000-4000-8000-000000000421"
        datasetSnapshotUid = $ExplicitPolicyFixture.datasetBinding.combatSupportCatalog.datasetSnapshotUid
        kind = "harmony-cube"
        contentSha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    }
    level = [pscustomobject]@{ status = "ready"; value = 15 }
}
$ExplicitPolicyFixtureText = $ExplicitPolicyFixture | ConvertTo-Json -Depth 100
Assert-True (Test-Json -Json $ExplicitPolicyFixtureText -SchemaFile $CharacterSchemaPath) "Schema must accept an explicit/v1 fixture with an attached cube."
Assert-SupportReference $ExplicitPolicyFixture.state.cube.definition "harmony-cube" $ExplicitPolicyFixture.datasetBinding.combatSupportCatalog.datasetSnapshotUid "Explicit cube definition"
Assert-ReadyIntegerFact $ExplicitPolicyFixture.state.cube.level 15 "Explicit cube level"

$InvalidSimultaneousCollectible = (Get-Content -Raw -LiteralPath $CombatMaxFixturePath) | ConvertFrom-Json
$InvalidSimultaneousCollectible.state | Add-Member -NotePropertyName collectionItem -NotePropertyValue ([pscustomobject]@{
    kind = "generic-collection"
})
$InvalidSimultaneousCollectibleText = $InvalidSimultaneousCollectible | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $InvalidSimultaneousCollectibleText -SchemaFile $CharacterSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject simultaneous legacy collection/favorite paths."

$InvalidDuplicateOlLine = (Get-Content -Raw -LiteralPath $CombatMaxFixturePath) | ConvertFrom-Json
$InvalidDuplicateOlLine.state.equipment[0].overloadLines[1].lineIndex = 1
$InvalidDuplicateOlLineText = $InvalidDuplicateOlLine | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $InvalidDuplicateOlLineText -SchemaFile $CharacterSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject duplicate OL line coordinates."

$InvalidOutOfRangeOlLine = (Get-Content -Raw -LiteralPath $CombatMaxFixturePath) | ConvertFrom-Json
$InvalidOutOfRangeOlLine.state.equipment[0].overloadLines[1].lineIndex = 4
$InvalidOutOfRangeOlLineText = $InvalidOutOfRangeOlLine | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $InvalidOutOfRangeOlLineText -SchemaFile $CharacterSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject OL line coordinates outside 1..3."

$InvalidDetachedCube = (Get-Content -Raw -LiteralPath $DetachedFixturePath) | ConvertFrom-Json
$InvalidDetachedCube.state.cube.level = [pscustomobject]@{ status = "ready"; value = 15 }
$InvalidDetachedCubeText = $InvalidDetachedCube | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $InvalidDetachedCubeText -SchemaFile $CharacterSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject a detached cube carrying an equipped level."

$InvalidUnresolvedCube = $ExplicitPolicyFixtureText | ConvertFrom-Json
$InvalidUnresolvedCube.state.cube.attachment = "unresolved"
$InvalidUnresolvedCubeText = $InvalidUnresolvedCube | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $InvalidUnresolvedCubeText -SchemaFile $CharacterSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject an unresolved cube carrying an attached definition and level."

$ValidUnresolvedCube = (Get-Content -Raw -LiteralPath $CombatMaxFixturePath) | ConvertFrom-Json
$ValidUnresolvedCube.state.cube = [pscustomobject]@{
    attachment = "unresolved"
    definition = $null
    level = [pscustomobject]@{
        status = "unresolved"
        value = $null
        reasonCode = "cube_selection_unresolved"
    }
    reasonCode = "cube_selection_unresolved"
}
$ValidUnresolvedCubeText = $ValidUnresolvedCube | ConvertTo-Json -Depth 100
Assert-True (Test-Json -Json $ValidUnresolvedCubeText -SchemaFile $CharacterSchemaPath) "Schema must accept a well-formed unresolved cube."

$ValidDetachedEquipment = (Get-Content -Raw -LiteralPath $CombatMaxFixturePath) | ConvertFrom-Json
$ValidDetachedEquipment.state.equipment[2] = [pscustomobject]@{
    equipmentSlotUid = "00000000-0000-4000-8000-000000000113"
    slot = "arms"
    attachment = "detached"
    definition = $null
    tier = [pscustomobject]@{ status = "not_applicable"; value = $null }
    enhancementLevel = [pscustomobject]@{ status = "not_applicable"; value = $null }
    manufacturerMatch = [pscustomobject]@{ status = "not_applicable"; value = $null }
    overloadLines = @()
}
$ValidDetachedEquipmentText = $ValidDetachedEquipment | ConvertTo-Json -Depth 100
Assert-True (Test-Json -Json $ValidDetachedEquipmentText -SchemaFile $CharacterSchemaPath) "Schema must accept a well-formed detached equipment slot."

$ValidUnresolvedEquipment = (Get-Content -Raw -LiteralPath $CombatMaxFixturePath) | ConvertFrom-Json
$UnresolvedEquipmentFact = [pscustomobject]@{
    status = "unresolved"
    value = $null
    reasonCode = "equipment_selection_unresolved"
}
$ValidUnresolvedEquipment.state.equipment[3] = [pscustomobject]@{
    equipmentSlotUid = "00000000-0000-4000-8000-000000000114"
    slot = "legs"
    attachment = "unresolved"
    definition = $null
    tier = $UnresolvedEquipmentFact
    enhancementLevel = $UnresolvedEquipmentFact
    manufacturerMatch = $UnresolvedEquipmentFact
    overloadLines = @()
    reasonCode = "equipment_selection_unresolved"
}
$ValidUnresolvedEquipmentText = $ValidUnresolvedEquipment | ConvertTo-Json -Depth 100
Assert-True (Test-Json -Json $ValidUnresolvedEquipmentText -SchemaFile $CharacterSchemaPath) "Schema must accept a well-formed unresolved equipment slot."

$InvalidIssueCode = (Get-Content -Raw -LiteralPath $CombatMaxFixturePath) | ConvertFrom-Json
$InvalidIssueCode.readiness.selection.issues[0].reasonCode = "not controlled/value"
$InvalidIssueCodeText = $InvalidIssueCode | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $InvalidIssueCodeText -SchemaFile $CharacterSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject non-controlled readiness text."

$InvalidUuidFixtureText = (Get-Content -Raw -LiteralPath $CombatMaxFixturePath).Replace(
    "00000000-0000-4000-8000-000000000101",
    "not-a-canonical-uuid"
)
Assert-True (-not (Test-Json -Json $InvalidUuidFixtureText -SchemaFile $CharacterSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject a non-canonical UUID."
$InvalidRuntimeTierText = $RaidFixtureText.Replace(
    '"runtimeRelation": "current_runtime_match"',
    '"runtimeRelation": "not_evaluated"'
)
Assert-True (-not (Test-Json -Json $InvalidRuntimeTierText -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject a current-runtime tier without a current runtime match."
$StaticWithoutEvidenceWarning = $StaticRaidFixtureText | ConvertFrom-Json
$StaticWithoutEvidenceWarning.compatibility.evidenceWarnings = @()
$StaticWithoutEvidenceWarningText = $StaticWithoutEvidenceWarning | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $StaticWithoutEvidenceWarningText -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject static_exact when unresolved higher-tier evidence is hidden."
$StaticPromotedToBehaviorExact = $StaticRaidFixtureText | ConvertFrom-Json
$StaticPromotedToBehaviorExact.compatibility.tier = "behavior_exact"
$StaticPromotedToBehaviorExactText = $StaticPromotedToBehaviorExact | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $StaticPromotedToBehaviorExactText -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject behavior_exact without behavior and selected bundle evidence."
$StaticPromotedToRuntimeExact = $StaticRaidFixtureText | ConvertFrom-Json
$StaticPromotedToRuntimeExact.compatibility.tier = "asset_exact_runtime_current"
$StaticPromotedToRuntimeExact.compatibility.runtimeRelation = "current_runtime_match"
$StaticPromotedToRuntimeExactText = $StaticPromotedToRuntimeExact | ConvertTo-Json -Depth 100
Assert-True (-not (Test-Json -Json $StaticPromotedToRuntimeExactText -SchemaFile $RaidSchemaPath -ErrorAction SilentlyContinue)) "Schema must reject runtime-exact promotion without behavior, bundle, runtime, and scheduler evidence."

$Defaults = $Config.characterBuildDefaults
Assert-True ($Defaults.policyId -eq "combat-max/v1") "Default policy must be combat-max/v1."
Assert-True ($Defaults.characterLevel -eq "explicit_required") "Character level must require an explicit value."
Assert-True ($Defaults.limitBreak -eq "max_supported") "Limit break must default to max_supported."
Assert-True ($Defaults.coreLevel -eq "max_if_applicable") "Core level must default to max_if_applicable."
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
Assert-True ($Defaults.collectibleSelection -eq "favorite_max_if_applicable_else_highest_rarity_collection_max") "Collectible selection policy mismatch."

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

Assert-CharacterFixture $CombatMaxFixture "favorite"
Assert-CharacterFixture $DetachedFixture "generic-collection"
Assert-True ($CombatMaxFixture.buildUid -eq $DetachedFixture.buildUid) "A local edit must create a new revision of the same build."
Assert-True ($CombatMaxFixture.revisionUid -ne $DetachedFixture.revisionUid) "Build revisions must use distinct UUIDs."
Assert-True ($DetachedFixture.revisionNumber -eq ($CombatMaxFixture.revisionNumber + 1)) "A local edit must increment the revision number."
Assert-True ($null -eq $CombatMaxFixture.previousRevisionUid) "Revision one cannot name a predecessor."
Assert-True ($DetachedFixture.previousRevisionUid -eq $CombatMaxFixture.revisionUid) "A later revision must name its exact predecessor."
Assert-True (($CombatMaxFixture.datasetBinding | ConvertTo-Json -Depth 10 -Compress) -eq
    ($DetachedFixture.datasetBinding | ConvertTo-Json -Depth 10 -Compress)) "A local edit must retain the exact dual-catalog binding."

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

Assert-True ($StaticRaidFixture.mode -eq "challenge") "Static-exact fixture must remain Challenge-only."
Assert-True ($StaticRaidFixture.schemaVersion -eq 2) "Static-exact fixture must use RaidSnapshot v2."
Assert-True ($StaticRaidFixture.seasonNumber -eq 7) "Static-exact fixture must exercise an Electric/Iron admitted season."
Assert-True ($StaticRaidFixture.compatibility.tier -eq "static_exact") "Static fixture tier mismatch."
Assert-True ($StaticRaidFixture.compatibility.runtimeRelation -eq "not_evaluated") "Static fixture runtime must remain unevaluated."
Assert-True ((@($StaticRaidFixture.compatibility.evidenceWarnings) -join ",") -eq "behavior_unresolved") "Static fixture must disclose unresolved behavior evidence."
Assert-True ($StaticRaidFixture.readiness.status -eq "ready") "Static-exact evidence may be publish-ready for its declared tier."
Assert-True (@($StaticRaidFixture.readiness.warnings).Count -eq 0) "Static evidence warning belongs to compatibility, not readiness."
Assert-True (@($StaticRaidFixture.provenance.selectedAssetBundles).Count -eq 0) "Static-exact fixture must exercise an empty selected bundle set."
Assert-True ($null -eq $StaticRaidFixture.provenance.assetBundleSetSha256) "An empty selected bundle set must have a null set hash."
Assert-True ($null -eq $StaticRaidFixture.provenance.behavior) "Static-exact fixture must exercise unresolved behavior evidence."
Assert-True (@($StaticRaidFixture.provenance.timelines).Count -eq 0) "Static-exact fixture must exercise an empty timeline set."
Assert-True (($null -eq $StaticRaidFixture.provenance.clientRuntime.buildUid) -and
    ($null -eq $StaticRaidFixture.provenance.clientRuntime.localBuildLabel) -and
    ($null -eq $StaticRaidFixture.provenance.clientRuntime.sha256)) "Static-exact fixture must exercise unresolved client runtime evidence."
Assert-True (@($StaticRaidFixture.provenance.timing.clockBases).Count -eq 4) "Static-exact fixture must represent all four clock bases."
Assert-True (@($StaticRaidFixture.provenance.timing.clockBases | Where-Object { $_.resolution -ne "unresolved" }).Count -eq 0) "Static-exact clock bases must remain unresolved in this fixture."
Assert-True ($StaticRaidFixture.provenance.timing.scheduler.resolution -eq "unresolved") "Static-exact scheduler must remain unresolved in this fixture."
Assert-True (@($StaticRaidFixture.staticRelations.parts).Count -ge 1) "Static-exact fixture must retain normalized part relations."
Assert-True (@($StaticRaidFixture.staticRelations.skills).Count -ge 1) "Static-exact fixture must retain normalized skill relations."
foreach ($Part in @($StaticRaidFixture.staticRelations.parts)) {
    Assert-True (Test-Uuid $Part.partUid) "Static part relation must use an own UUID."
}
foreach ($Skill in @($StaticRaidFixture.staticRelations.skills)) {
    Assert-True (Test-Uuid $Skill.skillUid) "Static skill relation must use an own UUID."
}

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
Assert-True ($StaticRaidFixtureText -notmatch $ForbiddenRaidKeys) "Static-exact raid fixture exposes a forbidden raw source key."

Write-Output "Phase 0 character-build and restricted Challenge raid contracts passed."
