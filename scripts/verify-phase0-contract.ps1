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

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$ConfigPath = Join-Path $RepositoryRoot "config/appsettings.example.json"
$FixturePath = Join-Path $RepositoryRoot "tests/fixtures/synthetic/character-build.combat-max-v1.json"
$SchemaPath = Join-Path $RepositoryRoot "contracts/character-build.schema.json"

$Config = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
$Fixture = Get-Content -Raw -LiteralPath $FixturePath | ConvertFrom-Json
Get-Content -Raw -LiteralPath $SchemaPath | ConvertFrom-Json | Out-Null

$Defaults = $Config.characterBuildDefaults
Assert-True ($Defaults.policyId -eq "combat-max/v1") "Default policy must be combat-max/v1."
Assert-True ($Defaults.limitBreak -eq "max_supported") "Limit break must default to max_supported."
Assert-True ($Defaults.bond -eq "max_for_character") "Bond must default to max_for_character."
Assert-True ($Defaults.equipmentTier -eq 10) "Equipment must default to Tier 10."
Assert-True ($null -eq $Defaults.equipmentEnhancementLevel) "Equipment enhancement level must remain unresolved in Phase 0."
Assert-True ($Defaults.cubeLevel -eq 15) "Cube must default to Level 15."
Assert-True ($Defaults.cubeSelection -eq "unresolved") "Cube selection must not be guessed."
Assert-True ($Defaults.skillLevels.skill1 -eq 10) "Skill 1 must default to Level 10."
Assert-True ($Defaults.skillLevels.skill2 -eq 10) "Skill 2 must default to Level 10."
Assert-True ($Defaults.skillLevels.burst -eq 10) "Burst must default to Level 10."
Assert-True ($Defaults.overloadValidationMode -eq "research") "Overload must default to research write mode."
Assert-True ($Defaults.collectionItem -eq "max_if_applicable") "Collection item policy mismatch."
Assert-True ($Defaults.favoriteItem -eq "max_if_applicable") "Favorite item policy mismatch."

Assert-True ($Fixture.defaultPolicy -eq "combat-max/v1") "Synthetic fixture policy mismatch."
Assert-True ($Fixture.validationMode -eq "research") "Synthetic fixture must exercise research write mode."
Assert-True ($Fixture.state.limitBreak.policy -eq "max_supported") "Synthetic limit-break policy mismatch."
Assert-True ($Fixture.state.bond.policy -eq "max_for_character") "Synthetic bond policy mismatch."
Assert-True ($Fixture.state.equipment.Count -eq 4) "Synthetic fixture must contain four equipment slots."

$ExpectedSlots = @("arms", "head", "legs", "torso")
$ActualSlots = @($Fixture.state.equipment | ForEach-Object { $_.slot } | Sort-Object -Unique)
Assert-True (($ActualSlots -join ",") -eq ($ExpectedSlots -join ",")) "Equipment slots must be unique and complete."

foreach ($Equipment in $Fixture.state.equipment) {
    Assert-True ($Equipment.tier -eq 10) "Every equipment slot must default to Tier 10."
    Assert-True ($Equipment.overloadLines.Count -le 3) "An equipment slot cannot contain more than three overload lines."
    $LineIndexes = @($Equipment.overloadLines | ForEach-Object { $_.lineIndex })
    Assert-True (($LineIndexes | Sort-Object -Unique).Count -eq $LineIndexes.Count) "Overload line indexes must be unique within a slot."
    foreach ($Line in $Equipment.overloadLines) {
        Assert-True ($Line.exactValue -is [string]) "Overload exactValue must round-trip as a string."
        Assert-True ($Line.exactValue -match '^-?(0|[1-9][0-9]*)(\.[0-9]+)?$') "Overload exactValue is not an exact decimal string."
    }
}

Assert-True ($Fixture.state.cube.level -eq 15) "Synthetic cube must be Level 15."
Assert-True ($null -eq $Fixture.state.cube.cubeUid) "Cube UID must remain unresolved until a cube is selected."
Assert-True ($Fixture.state.skills.skill1 -eq 10) "Synthetic Skill 1 mismatch."
Assert-True ($Fixture.state.skills.skill2 -eq 10) "Synthetic Skill 2 mismatch."
Assert-True ($Fixture.state.skills.burst -eq 10) "Synthetic Burst mismatch."
Assert-True ($Fixture.state.collectionItem.policy -eq "max_available") "Synthetic collection item must use max_available."
Assert-True ($Fixture.state.favoriteItem.applicability -eq "not_applicable") "Synthetic favorite item must demonstrate not_applicable."
Assert-True ($Fixture.readiness.status -eq "incomplete") "Unresolved combat inputs must keep the fixture incomplete."

Write-Output "Phase 0 character-build contract passed."
