$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.BossPublication.ps1')
$script:originalRegistryWriter = (Get-Command Write-NllBossPublicationRegistry).ScriptBlock
$script:publicationFailure = ''
function Write-NllBossPublicationRegistry([string]$Path, [byte[]]$Bytes) {
    if ($script:publicationFailure -ceq 'before_registry') { throw 'synthetic_before_registry' }
    & $script:originalRegistryWriter $Path $Bytes
    if ($script:publicationFailure -ceq 'after_registry') { throw 'synthetic_after_registry' }
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('NLL-Boss-Publication-Test-' + [guid]::NewGuid().ToString('N'))
$testRoot = [IO.Path]::GetFullPath($testRoot)
$null = New-Item -ItemType Directory -Path $testRoot
$script:checks = 0
$script:fixtureCount = 0
function Check([bool]$Condition) {
    if (-not $Condition) { throw 'boss_publication_test_assertion_failed' }
    $script:checks++
}
function Reject([scriptblock]$Action, [string]$Code) {
    $observed = $null
    try { & $Action | Out-Null } catch { $observed = $_.Exception.Message }
    Check ($observed -ceq $Code)
}
function Write-TestJson([string]$Path, [object]$Value) {
    [IO.File]::WriteAllText($Path, (($Value | ConvertTo-Json -Depth 15) + "`n"), [Text.UTF8Encoding]::new($false))
}
function New-Fixture {
    $script:fixtureCount++
    $root = Join-Path $testRoot ([string]$script:fixtureCount)
    $registryRoot = Join-Path $root 'registry'
    $null = New-Item -ItemType Directory -Path $registryRoot -Force
    $profilePath = Join-Path $root 'candidate.json'
    $profile = [ordered]@{ schemaVersion = 2; contractId = 'nll/boss-runtime-variant-profile/v2'
        profileCode = 'synthetic-boss'; seasonNumber = 9; elementShield = @{ modeCode = 'none' } }
    Write-TestJson $profilePath $profile
    $hash = (Read-NllBossPublicationFile $profilePath).sha256
    Write-TestJson (Join-Path $registryRoot 'registry.json') ([ordered]@{
        schemaVersion = 1; contractId = 'nll/boss-runtime-variant-registry/v1'; profiles = @()
    })
    $validation = [pscustomobject]@{ contractId = 'nll/boss-runtime-variant-profile-validation/v1'
        skillClosureResolved = $true; behaviorAssemblyResolved = $true; elementShieldModeCode = 'none'
        seasonNumber = 9; profileCode = 'synthetic-boss'; profileSha256 = $hash }
    $targets = @{ fire = 'wind'; water = 'fire'; wind = 'iron'; electric = 'water'; iron = 'electric' }
    $variants = @($targets.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{
        weaknessCode = $_; targetBossElementCode = $targets[$_]; receiptSha256 = 'a' * 64
        variantRequired = $_ -cne 'iron'; modifiedMonsterRecordCount = 1; modifiedFunctionRecordCount = 0
    } })
    $pins = @{}
    foreach ($variant in $variants) {
        $artifact = Join-Path $root ($variant.weaknessCode + '.receipt.json')
        Write-TestJson $artifact @{ synthetic = $variant.weaknessCode }
        $variant.receiptSha256 = (Read-NllBossPublicationFile $artifact).sha256
        $pins[$artifact] = $variant.receiptSha256
    }
    @{ ProfilePath = $profilePath; RegistryRoot = $registryRoot; Validation = $validation; VariantReceipts = $variants
        ArtifactPins = $pins
        ExpectedRegistrySha256 = (Read-NllBossPublicationFile (Join-Path $registryRoot 'registry.json')).sha256
        AdmissionReceiptPath = Join-Path $root 'admission.json' }
}
function Registry-Hash([hashtable]$Fixture) {
    (Read-NllBossPublicationFile (Join-Path $Fixture.RegistryRoot 'registry.json')).sha256
}
try {
    $f = New-Fixture
    $r = Publish-NllBossProfile @f
    $registry = (Read-NllBossPublicationFile (Join-Path $f.RegistryRoot 'registry.json')).value
    Check ($registry.profiles.Count -eq 1)
    Check ($registry.profiles[0].profileRelativePath -ceq ('synthetic-boss.' + $f.Validation.profileSha256 + '.json'))
    Check ((Read-NllBossPublicationFile (Join-Path $f.RegistryRoot $registry.profiles[0].profileRelativePath)).sha256 -ceq $f.Validation.profileSha256)
    Check ($r.registrySha256 -ceq (Registry-Hash $f))
    $receiptBefore = (Read-NllBossPublicationFile $f.AdmissionReceiptPath).sha256
    $r2 = Publish-NllBossProfile @f
    Check ($r2.admittedAtUtc -ceq $r.admittedAtUtc)
    Check ((Read-NllBossPublicationFile $f.AdmissionReceiptPath).sha256 -ceq $receiptBefore)
    $tampered = (Read-NllBossPublicationFile $f.AdmissionReceiptPath).value
    $tampered.fiveAffinityVariantStatusCode = 'not_assessed'
    Write-TestJson $f.AdmissionReceiptPath $tampered
    Reject { Publish-NllBossProfile @f } 'boss_publication_receipt_conflict'

    $f = New-Fixture
    $artifact = @($f.ArtifactPins.Keys)[0]
    Write-TestJson $artifact @{ changed = $true }
    Reject { Publish-NllBossProfile @f } 'boss_publication_artifact_drift'
    Check ((Registry-Hash $f) -ceq $f.ExpectedRegistrySha256)

    foreach ($where in @('before_registry', 'after_registry')) {
        $f = New-Fixture
        $script:publicationFailure = $where
        Reject { Publish-NllBossProfile @f } ('synthetic_' + $where)
        Check (-not (Test-Path -LiteralPath $f.AdmissionReceiptPath))
        $unchanged = (Registry-Hash $f) -ceq $f.ExpectedRegistrySha256
        Check ($unchanged -eq ($where -ceq 'before_registry'))
        $script:publicationFailure = ''
        $r = Publish-NllBossProfile @f
        Check ($r.registrySha256 -ceq (Registry-Hash $f))
        Check (@((Read-NllBossPublicationFile (Join-Path $f.RegistryRoot 'registry.json')).value.profiles).Count -eq 1)
    }

    $f = New-Fixture
    $lease = [IO.File]::Open((Join-Path $f.RegistryRoot '.publication.lock'), [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Reject { Publish-NllBossProfile @f } 'boss_publication_busy' } finally { $lease.Dispose() }
    Check ((Registry-Hash $f) -ceq $f.ExpectedRegistrySha256)
    $null = Publish-NllBossProfile @f # Persistent lock filename is not a stale owner.
    Check (Test-Path -LiteralPath $f.AdmissionReceiptPath)

    $f = New-Fixture
    $f.ExpectedRegistrySha256 = '0' * 64
    Reject { Publish-NllBossProfile @f } 'boss_publication_registry_changed'
    Check (@(Get-ChildItem -LiteralPath $f.RegistryRoot -Filter 'synthetic-boss.*.json').Count -eq 0)

    $f = New-Fixture
    $f.Validation.profileSha256 = '0' * 64
    Reject { Publish-NllBossProfile @f } 'boss_publication_validation_mismatch'
    Check ((Registry-Hash $f) -ceq $f.ExpectedRegistrySha256)

    $f = New-Fixture
    $f.VariantReceipts[0].targetBossElementCode = 'unresolved'
    Reject { Publish-NllBossProfile @f } 'boss_publication_affinities_invalid'
    Check ((Registry-Hash $f) -ceq $f.ExpectedRegistrySha256)

    $f = New-Fixture
    $f.VariantReceipts = $f.VariantReceipts[0..3]
    Reject { Publish-NllBossProfile @f } 'boss_publication_affinities_invalid'

    $f = New-Fixture
    $p = (Read-NllBossPublicationFile $f.ProfilePath).value
    $p.schemaVersion = 3
    $p.contractId = 'nll/boss-runtime-variant-profile/v3'
    Write-TestJson $f.ProfilePath $p
    $f.Validation.profileSha256 = (Read-NllBossPublicationFile $f.ProfilePath).sha256
    Reject { Publish-NllBossProfile @f } 'boss_publication_runtime_delivery_required'
    Check ((Registry-Hash $f) -ceq $f.ExpectedRegistrySha256)

    $f = New-Fixture
    $oldPath = Join-Path $f.RegistryRoot 'legacy.json'
    Write-TestJson $oldPath @{ synthetic = 'old active profile' }
    $oldHash = (Read-NllBossPublicationFile $oldPath).sha256
    $registry = (Read-NllBossPublicationFile (Join-Path $f.RegistryRoot 'registry.json')).value
    $registry.profiles = @(@{ seasonNumber = 9; profileCode = 'synthetic-boss'; profileRelativePath = 'legacy.json'
        profileSha256 = $oldHash; operationalStatusCode = 'enabled' })
    Write-TestJson (Join-Path $f.RegistryRoot 'registry.json') $registry
    $f.ExpectedRegistrySha256 = Registry-Hash $f
    Reject { Publish-NllBossProfile @f } 'boss_publication_replacement_not_authorized'
    Check ((Read-NllBossPublicationFile $oldPath).sha256 -ceq $oldHash)
    $null = Publish-NllBossProfile @f -ReplaceExistingProfile
    Check ((Read-NllBossPublicationFile $oldPath).sha256 -ceq $oldHash)
    Check ((Registry-Hash $f) -cne $f.ExpectedRegistrySha256)

    $f = New-Fixture
    $registry = (Read-NllBossPublicationFile (Join-Path $f.RegistryRoot 'registry.json')).value
    $registry.profiles = @(@{ seasonNumber = 8; profileCode = 'synthetic-boss'; profileRelativePath = 'other.json'
        profileSha256 = 'c' * 64; operationalStatusCode = 'enabled' })
    Write-TestJson (Join-Path $f.RegistryRoot 'registry.json') $registry
    $f.ExpectedRegistrySha256 = Registry-Hash $f
    Reject { Publish-NllBossProfile @f -ReplaceExistingProfile } 'boss_publication_identity_conflict'
    Check ((Registry-Hash $f) -ceq $f.ExpectedRegistrySha256)

    $f = New-Fixture
    Write-TestJson $f.AdmissionReceiptPath @{ unrelated = $true }
    Reject { Publish-NllBossProfile @f } 'boss_publication_receipt_conflict'
    Check ((Registry-Hash $f) -ceq $f.ExpectedRegistrySha256)

    $f = New-Fixture
    $immutable = Join-Path $f.RegistryRoot ('synthetic-boss.' + $f.Validation.profileSha256 + '.json')
    Write-TestJson $immutable @{ unrelated = $true }
    $before = (Read-NllBossPublicationFile $immutable).sha256
    Reject { Publish-NllBossProfile @f } 'boss_publication_immutable_profile_drift'
    Check ((Registry-Hash $f) -ceq $f.ExpectedRegistrySha256)
    Check ((Read-NllBossPublicationFile $immutable).sha256 -ceq $before)

    [ordered]@{ status = 'passed'; checks = $script:checks; syntheticOnly = $true; installedRegistryModified = $false
        nativeClientExecuted = $false; v3AdmissionClaimed = $false } | ConvertTo-Json -Compress
} finally {
    # Delete only this helper's exact, newly created synthetic fixture directory.
    $resolved = (Resolve-Path -LiteralPath $testRoot).ProviderPath
    if ($resolved -ine $testRoot -or -not (Split-Path -Leaf $resolved).StartsWith('NLL-Boss-Publication-Test-')) {
        throw 'boss_publication_test_cleanup_scope_invalid'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
