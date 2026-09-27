# Immutable profiles + one atomic registry replacement. Import is side-effect free.
# Native/v3 admission is deliberately NOT supplied by this legacy-v2 publisher.
function Assert-NllBossPublication([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw ('boss_publication_' + $Code) }
}
function Get-NllBossPublicationHash([byte[]]$Bytes) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}
function Get-NllBossPublicationPath([string]$Path) {
    Assert-NllBossPublication ([IO.Path]::IsPathFullyQualified($Path)) 'path_invalid'
    $full = [IO.Path]::GetFullPath($Path)
    Assert-NllBossPublication (-not $full.StartsWith('\\') -and
        -not $full.Substring([IO.Path]::GetPathRoot($full).Length).Contains(':')) 'path_invalid'
    for ($cursor = $full; $cursor; $cursor = [IO.Path]::GetDirectoryName($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            Assert-NllBossPublication (((Get-Item -LiteralPath $cursor -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse_forbidden'
        }
    }
    $full
}
function Read-NllBossPublicationFile([string]$Path) {
    $path = Get-NllBossPublicationPath $Path
    Assert-NllBossPublication ((Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-Item -LiteralPath $path).Length -le 1048576) 'input_invalid'
    $bytes = [IO.File]::ReadAllBytes($path)
    Assert-NllBossPublication ($bytes.Length -gt 0 -and $bytes.Length -le 1048576) 'input_invalid'
    [pscustomobject]@{ bytes = $bytes; sha256 = Get-NllBossPublicationHash $bytes
        value = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json }
}
function Write-NllBossPublicationNew([string]$Path, [byte[]]$Bytes) {
    $path = Get-NllBossPublicationPath $Path
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Write-NllBossPublicationRegistry([string]$Path, [byte[]]$Bytes) {
    $temporary = $Path + '.partial-' + [guid]::NewGuid().ToString('N')
    Write-NllBossPublicationNew $temporary $Bytes
    # The previous registry is not removed first. A failed replacement retains it.
    [IO.File]::Move($temporary, $Path, $true)
}
function Assert-NllBossPublicationPins([System.Collections.IDictionary]$Pins) {
    Assert-NllBossPublication ($Pins.Count -ge 5) 'artifact_pins_invalid'
    foreach ($path in $Pins.Keys) {
        $plain = Get-NllBossPublicationPath $path
        Assert-NllBossPublication ($Pins[$path] -cmatch '^[a-f0-9]{64}$' -and
            (Test-Path -LiteralPath $plain -PathType Leaf) -and
            (Get-FileHash -LiteralPath $plain -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $Pins[$path]) 'artifact_drift'
    }
}
function Publish-NllBossProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [Parameter(Mandatory)][object]$Validation,
        [Parameter(Mandatory)][object[]]$VariantReceipts,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ArtifactPins,
        [Parameter(Mandatory)][string]$RegistryRoot,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedRegistrySha256,
        [Parameter(Mandatory)][string]$AdmissionReceiptPath,
        [switch]$ReplaceExistingProfile,
        [object]$DeliveryPin = $null,
        [string]$MaterializerPath = ''
    )
    Assert-NllBossPublication ($PSVersionTable.PSVersion.Major -ge 7) 'powershell7_required'
    $RegistryRoot = Get-NllBossPublicationPath $RegistryRoot
    Assert-NllBossPublication ((Test-Path -LiteralPath $RegistryRoot -PathType Container) -and
        $RegistryRoot.TrimEnd('\', '/') -cne [IO.Path]::GetPathRoot($RegistryRoot).TrimEnd('\', '/')) 'root_invalid'
    Assert-NllBossPublication (-not ($RegistryRoot -imatch '^C:[\\/]NIKKE([\\/]|$)')) 'official_path_forbidden'
    $AdmissionReceiptPath = Get-NllBossPublicationPath $AdmissionReceiptPath
    $profile = Read-NllBossPublicationFile $ProfilePath
    $value = $profile.value
    Assert-NllBossPublication (($value.schemaVersion -eq 2 -and
        $value.contractId -ceq 'nll/boss-runtime-variant-profile/v2') -or
        ($value.schemaVersion -eq 4 -and $value.contractId -ceq 'nll/boss-runtime-variant-profile/v4' -and
         $null -ne $DeliveryPin)) 'runtime_delivery_required'
    if ($null -ne $DeliveryPin) {
        Assert-NllBossPublication ((Read-NllBossPublicationFile $DeliveryPin.path).sha256 -ceq $DeliveryPin.sha256) 'delivery_drifted'
        foreach ($weakness in @('fire','water','wind','electric','iron')) {
            $lines = @(& $MaterializerPath --validate-common-boss-delivery true --delivery-path $DeliveryPin.path `
                --delivery-sha256 $DeliveryPin.sha256 --boss-variant-profile $ProfilePath --weakness-code $weakness 2>&1)
            Assert-NllBossPublication ($LASTEXITCODE -eq 0) 'delivery_not_prepared'
            $ready = ($lines -join "`n") | ConvertFrom-Json
            Assert-NllBossPublication ($ready.statusCode -ceq 'prepared' -and $ready.profileSha256 -ceq $profile.sha256) 'delivery_not_prepared'
        }
        $ArtifactPins[$DeliveryPin.path] = $DeliveryPin.sha256
    }
    Assert-NllBossPublication ($value.seasonNumber -gt 0 -and
        $value.profileCode -cmatch '^[a-z][a-z0-9._-]{0,63}$' -and
        $Validation.contractId -ceq 'nll/boss-runtime-variant-profile-validation/v1' -and
        $Validation.seasonNumber -eq $value.seasonNumber -and
        $Validation.profileCode -ceq $value.profileCode -and
        $Validation.skillClosureResolved -eq $true -and $Validation.behaviorAssemblyResolved -eq $true -and
        $Validation.elementShieldModeCode -ceq $value.elementShield.modeCode -and
        $Validation.profileSha256 -ceq $profile.sha256) 'validation_mismatch'
    $targets = @{ fire = 'wind'; water = 'fire'; wind = 'iron'; electric = 'water'; iron = 'electric' }
    Assert-NllBossPublication ($VariantReceipts.Count -eq 5 -and
        @($VariantReceipts.weaknessCode | Sort-Object -Unique).Count -eq 5) 'affinities_invalid'
    foreach ($variant in $VariantReceipts) {
        Assert-NllBossPublication ($targets.ContainsKey([string]$variant.weaknessCode) -and
            $variant.targetBossElementCode -ceq $targets[[string]$variant.weaknessCode] -and
            $variant.receiptSha256 -cmatch '^[a-f0-9]{64}$') 'affinities_invalid'
    }
    Assert-NllBossPublicationPins $ArtifactPins
    $registryPath = Join-Path $RegistryRoot 'registry.json'
    # Persistent lock file; exclusivity belongs to this OS handle, not its filename.
    # Owner exit closes the handle. No PID guess or deletion of a stale lock needed.
    $lockPath = Get-NllBossPublicationPath (Join-Path $RegistryRoot '.publication.lock')
    try { $lease = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { throw 'boss_publication_busy' }
    try {
        $registry = Read-NllBossPublicationFile $registryPath
        Assert-NllBossPublication ($registry.value.schemaVersion -eq 1 -and
            $registry.value.contractId -ceq 'nll/boss-runtime-variant-registry/v1') 'registry_invalid'
        $entries = @($registry.value.profiles)
        Assert-NllBossPublication (@($entries | ForEach-Object { $_.seasonNumber } | Sort-Object -Unique).Count -eq $entries.Count -and
            @($entries | ForEach-Object { $_.profileCode } | Sort-Object -Unique).Count -eq $entries.Count) 'registry_ambiguous'
        $matched = @($entries | Where-Object { $_.seasonNumber -eq $value.seasonNumber -or $_.profileCode -ceq $value.profileCode })
        Assert-NllBossPublication ($matched.Count -le 1 -and ($matched.Count -eq 0 -or
            ($matched[0].seasonNumber -eq $value.seasonNumber -and $matched[0].profileCode -ceq $value.profileCode))) 'identity_conflict'
        $relative = $value.profileCode + '.' + $profile.sha256 + '.json'
        $installedPath = Join-Path $RegistryRoot $relative
        $alreadyPresent = $matched.Count -eq 1 -and $matched[0].profileSha256 -ceq $profile.sha256 -and
            $matched[0].profileRelativePath -ceq $relative -and $matched[0].operationalStatusCode -ceq 'enabled'
        if ($alreadyPresent -and $null -ne $DeliveryPin) {
            $alreadyPresent = $matched[0].PSObject.Properties.Name -contains 'delivery' -and
                $matched[0].delivery.sha256 -ceq $DeliveryPin.sha256 -and $matched[0].delivery.path -ceq $DeliveryPin.path
        }
        Assert-NllBossPublication ($alreadyPresent -or $registry.sha256 -ceq $ExpectedRegistrySha256) 'registry_changed'
        Assert-NllBossPublication ($alreadyPresent -or $matched.Count -eq 0 -or $ReplaceExistingProfile) 'replacement_not_authorized'
        Assert-NllBossPublication (-not (Test-Path -LiteralPath $AdmissionReceiptPath) -or $alreadyPresent) 'receipt_conflict'
        # A prior interrupted attempt may have produced this immutable content.
        # Never overwrite the old active profile, including for ReplaceExistingProfile.
        if (Test-Path -LiteralPath $installedPath) {
            Assert-NllBossPublication ((Read-NllBossPublicationFile $installedPath).sha256 -ceq $profile.sha256) 'immutable_profile_drift'
        } else { Write-NllBossPublicationNew $installedPath $profile.bytes }
        Assert-NllBossPublication ((Read-NllBossPublicationFile $ProfilePath).sha256 -ceq $profile.sha256 -and
            (Read-NllBossPublicationFile $installedPath).sha256 -ceq $profile.sha256 -and
            (Read-NllBossPublicationFile $registryPath).sha256 -ceq $registry.sha256) 'input_changed'
        Assert-NllBossPublicationPins $ArtifactPins
        if (-not $alreadyPresent) {
            $entry = [ordered]@{ seasonNumber = $value.seasonNumber; profileCode = $value.profileCode
                profileRelativePath = $relative; profileSha256 = $profile.sha256; operationalStatusCode = 'enabled' }
            if ($null -ne $DeliveryPin) { $entry.delivery = $DeliveryPin }
            $updated = [ordered]@{ schemaVersion = 1; contractId = 'nll/boss-runtime-variant-registry/v1'
                profiles = @(@($entries | Where-Object { $_.seasonNumber -ne $value.seasonNumber }) + @($entry) |
                    Sort-Object { [int]$_.seasonNumber }, { [string]$_.profileCode }) }
            $updatedBytes = [Text.Encoding]::UTF8.GetBytes(($updated | ConvertTo-Json -Depth 12) + "`n")
            Write-NllBossPublicationRegistry $registryPath $updatedBytes
            $registryHash = Get-NllBossPublicationHash $updatedBytes
        } else { $registryHash = $registry.sha256 }
        Assert-NllBossPublication ((Read-NllBossPublicationFile $registryPath).sha256 -ceq $registryHash) 'commit_drift'
        $admission = [ordered]@{
            schemaVersion = 1; contractId = 'nll/boss-onboarding-admission/v1'; admittedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            profileCode = $value.profileCode; seasonNumber = $value.seasonNumber; profileSha256 = $profile.sha256; registrySha256 = $registryHash
            skillClosureStatusCode = 'resolved'; behaviorClosureStatusCode = 'resolved'; elementShieldModeCode = $value.elementShield.modeCode
            fiveAffinityVariantStatusCode = 'passed'; affinityVariants = $VariantReceipts; operationalStatusCode = 'enabled'
            rawSourceIdentifiersPersisted = $false; officialInstallModified = $false
        }
        if (Test-Path -LiteralPath $AdmissionReceiptPath) {
            $existing = (Read-NllBossPublicationFile $AdmissionReceiptPath).value
            Assert-NllBossPublication (@($existing.PSObject.Properties).Count -eq $admission.Count) 'receipt_conflict'
            foreach ($key in $admission.Keys) {
                if ($key -ceq 'admittedAtUtc') { continue }
                $property = $existing.PSObject.Properties[$key]
                Assert-NllBossPublication ($null -ne $property) 'receipt_conflict'
                # Compare complete nested variants as well as every admission flag.
                Assert-NllBossPublication (($property.Value | ConvertTo-Json -Depth 12 -Compress) -ceq
                    ($admission[$key] | ConvertTo-Json -Depth 12 -Compress)) 'receipt_conflict'
            }
            $timestamp = [DateTimeOffset]::MinValue
            Assert-NllBossPublication ([DateTimeOffset]::TryParse([string]$existing.admittedAtUtc, [ref]$timestamp)) 'receipt_conflict'
            return $existing
        }
        Write-NllBossPublicationNew $AdmissionReceiptPath ([Text.Encoding]::UTF8.GetBytes(($admission | ConvertTo-Json -Depth 12) + "`n"))
        $admission
    } finally { $lease.Dispose() }
}
