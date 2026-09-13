param(
    [switch]$ContractOnly,
    [string]$LocalObservationSetPath,
    [string]$LocalPreflightAssessmentPath
)

$ErrorActionPreference = "Stop"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"

function Invoke-Checked {
    param(
        [string]$Command,
        [string[]]$Arguments
    )

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed with exit code $LASTEXITCODE."
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$FailureCode
    )

    if (-not $Condition) {
        throw $FailureCode
    }
}

function Test-UtcSecondInstant {
    param([string]$Value)

    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParseExact(
        $Value,
        "yyyy-MM-dd'T'HH:mm:ss'Z'",
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal,
        [ref]$parsed
    )
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    return [Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData($Bytes)
    ).ToLowerInvariant()
}

function Write-CanonicalJsonElement {
    param(
        [System.Text.Json.JsonElement]$Element,
        [System.Text.Json.Utf8JsonWriter]$Writer
    )

    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($property in $Element.EnumerateObject()) {
                $names.Add($property.Name)
            }
            $names.Sort([System.StringComparer]::Ordinal)

            $Writer.WriteStartObject()
            foreach ($name in $names) {
                $Writer.WritePropertyName($name)
                Write-CanonicalJsonElement ($Element.GetProperty($name)) $Writer
            }
            $Writer.WriteEndObject()
            break
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            $Writer.WriteStartArray()
            foreach ($item in $Element.EnumerateArray()) {
                Write-CanonicalJsonElement $item $Writer
            }
            $Writer.WriteEndArray()
            break
        }
        ([System.Text.Json.JsonValueKind]::String) {
            $Writer.WriteStringValue($Element.GetString())
            break
        }
        ([System.Text.Json.JsonValueKind]::Number) {
            $integer = [long]0
            $decimal = [decimal]0
            if ($Element.TryGetInt64([ref]$integer)) {
                $Writer.WriteNumberValue($integer)
            }
            elseif ($Element.TryGetDecimal([ref]$decimal)) {
                $Writer.WriteNumberValue($decimal)
            }
            else {
                throw "phase3b2_noncanonical_observation_number"
            }
            break
        }
        ([System.Text.Json.JsonValueKind]::True) {
            $Writer.WriteBooleanValue($true)
            break
        }
        ([System.Text.Json.JsonValueKind]::False) {
            $Writer.WriteBooleanValue($false)
            break
        }
        ([System.Text.Json.JsonValueKind]::Null) {
            $Writer.WriteNullValue()
            break
        }
        default {
            throw "phase3b2_unsupported_observation_json_kind"
        }
    }
}

function Get-CanonicalObservationManifest {
    param([System.Text.Json.JsonElement]$ObservationSetRoot)

    $members = @($ObservationSetRoot.GetProperty("observations").EnumerateArray())
    $orderedMembers = @($members | Sort-Object { $_.GetProperty("ordinal").GetInt32() })
    $stream = [System.IO.MemoryStream]::new()
    try {
        foreach ($member in $orderedMembers) {
            $memberStream = [System.IO.MemoryStream]::new()
            try {
                $writer = [System.Text.Json.Utf8JsonWriter]::new(
                    $memberStream,
                    [System.Text.Json.JsonWriterOptions]@{ Indented = $false }
                )
                try {
                    Write-CanonicalJsonElement $member $writer
                    $writer.Flush()
                }
                finally {
                    $writer.Dispose()
                }

                $memberBytes = $memberStream.ToArray()
                $stream.Write($memberBytes, 0, $memberBytes.Length)
                $stream.WriteByte(0x0A)
            }
            finally {
                $memberStream.Dispose()
            }
        }

        $bytes = $stream.ToArray()
        return [pscustomobject]@{
            MemberCount = $orderedMembers.Count
            ByteLength = $bytes.Length
            Sha256 = Get-Sha256Hex $bytes
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-SafeJsonElement {
    param([System.Text.Json.JsonElement]$Element)

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $forbiddenNames = @(
            "accountId",
            "assetId",
            "assetName",
            "backupPath",
            "certificatePath",
            "characterId",
            "decodedValue",
            "executablePath",
            "fileName",
            "filePath",
            "fullPath",
            "gameRoot",
            "localPath",
            "managerId",
            "managerName",
            "memberName",
            "modelId",
            "monsterId",
            "monsterName",
            "originalId",
            "originalPath",
            "partId",
            "presetId",
            "raidId",
            "rawId",
            "rawIdentifier",
            "rawValue",
            "sourceId",
            "sourcePath",
            "spotId",
            "stageId",
            "statId",
            "userId",
            "waveId"
        )

        foreach ($property in $Element.EnumerateObject()) {
            Assert-True ($names.Add($property.Name)) "phase3b2_duplicate_json_property"
            Assert-True ($forbiddenNames -cnotcontains $property.Name) "phase3b2_forbidden_evidence_property"
            Assert-SafeJsonElement $property.Value
        }

        return
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            Assert-SafeJsonElement $item
        }

        return
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
        $value = $Element.GetString()
        Assert-True ($value -notmatch '^[A-Za-z]:[\\/]' -and
            -not $value.StartsWith('\\', [System.StringComparison]::Ordinal) -and
            -not $value.StartsWith('//', [System.StringComparison]::Ordinal) -and
            $value -notmatch '^/(home|mnt|private|root|tmp|Users|var)/' -and
            -not $value.StartsWith('file:', [System.StringComparison]::OrdinalIgnoreCase)) "phase3b2_local_path_value_exposed"
        Assert-True ($value -notmatch '-----BEGIN (CERTIFICATE|[^-]*PRIVATE KEY)-----' -and
            $value -notmatch '(?i)^Bearer\s+' -and
            $value -notmatch '^eyJ[A-Za-z0-9_-]*\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' -and
            $value -notmatch '^[A-Za-z0-9+/_-]{160,}={0,2}$') "phase3b2_credential_or_binary_value_exposed"
    }
}

function Test-CanonicalAssessment {
    param(
        [string]$Json,
        [string]$SchemaPath
    )

    if (-not (Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        try {
            Assert-SafeJsonElement $document.RootElement
            $assessedAtUtc = $document.RootElement.GetProperty("assessedAtUtc").GetString()
            return Test-UtcSecondInstant $assessedAtUtc
        }
        finally {
            $document.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Assert-FixedTarget {
    param([object]$Assessment)

    Assert-True ($Assessment.target.clientBuildVersion -ceq "150.6.9") "phase3b2_client_build_mismatch"
    Assert-True ($Assessment.target.seasonNumber -eq 26) "phase3b2_season_mismatch"
    Assert-True ($Assessment.target.modeCode -ceq "classic_solo_raid_challenge") "phase3b2_classic_mode_required"
    Assert-True ($Assessment.target.wireModeCode -ceq "trial") "phase3b2_trial_wire_required"
    Assert-True ($Assessment.target.challengeRaidLevel -eq 8) "phase3b2_challenge_level_mismatch"
    Assert-True ($Assessment.target.museumAllowed -eq $false) "phase3b2_museum_allowed"
    Assert-True ($Assessment.target.fallbackPolicyCode -ceq "none") "phase3b2_fallback_allowed"
}

function Assert-FixedExternalLineage {
    param([object]$Assessment)

    $lineage = $Assessment.externalLineage
    Assert-True ($lineage.repositoryCode -ceq "epinelps_epinelps") "phase3b2_external_repository_mismatch"
    Assert-True ($lineage.licenseCode -ceq "agpl-3.0-only") "phase3b2_external_license_mismatch"
    Assert-True ($lineage.sourceBoundaryCode -ceq "external_agpl_checkout") "phase3b2_external_source_boundary_mismatch"
    Assert-True ($lineage.upstreamBaseCommitSha -ceq "28b2f5413a0a1e3521a11ae162f91851335c8b40") "phase3b2_upstream_base_pin_mismatch"
    Assert-True ($lineage.selectedManagerIntegrationCommitSha -ceq "92a6ca228aeb580988907b96189b2857dff2c62d") "phase3b2_selected_manager_pin_mismatch"
    Assert-True ($lineage.preflightSealCommitSha -ceq "e32e5f900775974d5736e7fb2b50f8c62638a004") "phase3b2_preflight_seal_pin_mismatch"
    Assert-True ($lineage.preflightHardeningCommitSha -ceq "4f7bd5b5eb2b9a6e03af503f1c09adc4c4f7f16f") "phase3b2_preflight_hardening_pin_mismatch"
    Assert-True ($lineage.latestExternalCommitSha -ceq "519c3db51ec24ca19307e93e85acde7885928a72") "phase3b2_latest_external_commit_pin_mismatch"
    Assert-True ($lineage.latestExternalTreeCommitSha -ceq "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a") "phase3b2_latest_external_tree_pin_mismatch"
}

function Assert-ProhibitedMaterialBoundary {
    param([object]$Assessment)

    $properties = @($Assessment.prohibitedMaterial.PSObject.Properties)
    Assert-True ($properties.Count -eq 11) "phase3b2_prohibited_material_shape_mismatch"
    foreach ($property in $properties) {
        Assert-True ($property.Value -eq $false) "phase3b2_prohibited_material_claimed_present"
    }
}

function Assert-ExternalRegularJsonPath {
    param(
        [string]$Path,
        [string]$RepositoryRoot,
        [string]$FailurePrefix
    )

    Assert-True ([System.IO.Path]::IsPathFullyQualified($Path)) "${FailurePrefix}_path_not_absolute"
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $repositoryPrefix = $RepositoryRoot.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    Assert-True (-not $fullPath.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) "${FailurePrefix}_path_inside_repository"
    Assert-True (Test-Path -LiteralPath $fullPath -PathType Leaf) "${FailurePrefix}_file_missing"
    $current = Get-Item -LiteralPath $fullPath -Force
    while ($null -ne $current) {
        Assert-True (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "${FailurePrefix}_reparse_point_rejected"
        $current = $current.Parent
    }
    return $fullPath
}

function Assert-ObservationRoleOrder {
    param([System.Text.Json.JsonElement]$ObservationSetRoot)

    $expectedRoles = @(
        "disposable_environment",
        "primary_install",
        "client_build_content",
        "external_lineage_build",
        "runtime_pack_staticdata",
        "locale_bgm",
        "locale_character",
        "locale_costume",
        "locale_item",
        "synthetic_identity",
        "process_tree_egress",
        "mutation_backup_rollback",
        "local_only_config",
        "loopback_listeners",
        "target_binding",
        "prelistener_bootstrap",
        "active_run_state",
        "log_safety"
    )
    $expectedStatuses = @(
        "verified",
        "unchanged",
        "exact",
        "exact",
        "exact",
        "exact",
        "exact",
        "exact",
        "exact",
        "verified",
        "verified",
        "prepared",
        "effective",
        "verified",
        "exact",
        "verified",
        "verified",
        "verified"
    )

    $observations = @($ObservationSetRoot.GetProperty("observations").EnumerateArray())
    Assert-True ($observations.Count -eq $expectedRoles.Count) "phase3b2_observation_count_mismatch"
    for ($index = 0; $index -lt $expectedRoles.Count; $index++) {
        Assert-True ($observations[$index].GetProperty("ordinal").GetInt32() -eq ($index + 1)) "phase3b2_observation_ordinal_mismatch"
        Assert-True ($observations[$index].GetProperty("roleCode").GetString() -ceq $expectedRoles[$index]) "phase3b2_observation_role_order_mismatch"
        Assert-True ($observations[$index].GetProperty("statusCode").GetString() -ceq $expectedStatuses[$index]) "phase3b2_observation_status_mismatch"
    }

    $canonicalization = $ObservationSetRoot.GetProperty("canonicalization")
    Assert-True ($canonicalization.GetProperty("canonicalizationCode").GetString() -ceq "role_ordered_ordinal_json_members_lf_v1") "phase3b2_observation_canonicalization_mismatch"
    Assert-True ($canonicalization.GetProperty("encodingCode").GetString() -ceq "utf8_no_bom") "phase3b2_observation_encoding_mismatch"
    Assert-True ($canonicalization.GetProperty("memberSerializationCode").GetString() -ceq "recursive_ordinal_keys_compact_json") "phase3b2_observation_member_serialization_mismatch"
    Assert-True ($canonicalization.GetProperty("terminalLf").GetBoolean()) "phase3b2_observation_terminal_lf_required"
    Assert-True ($canonicalization.GetProperty("memberCount").GetInt32() -eq $expectedRoles.Count) "phase3b2_observation_canonical_member_count_mismatch"
    $declaredRoles = @($canonicalization.GetProperty("roleOrder").EnumerateArray() | ForEach-Object { $_.GetString() })
    Assert-True (($declaredRoles -join "`n") -ceq ($expectedRoles -join "`n")) "phase3b2_observation_declared_role_order_mismatch"
}

function Test-CanonicalObservationSet {
    param(
        [string]$Json,
        [string]$SchemaPath,
        [string]$ExpectedContractId
    )

    if (-not (Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
        try {
            $root = $document.RootElement
            Assert-SafeJsonElement $root
            Assert-True (Test-UtcSecondInstant ($root.GetProperty("observedAtUtc").GetString())) "phase3b2_observation_set_timestamp_invalid"
            Assert-True ($root.GetProperty("contractId").GetString() -ceq $ExpectedContractId) "phase3b2_observation_set_contract_id_mismatch"
            Assert-True ($root.GetProperty("statusCode").GetString() -ceq "measured_complete") "phase3b2_observation_set_status_mismatch"
            Assert-True ($root.GetProperty("observationCount").GetInt32() -eq 18) "phase3b2_observation_set_declared_count_mismatch"
            Assert-ObservationRoleOrder $root

            $computedManifest = Get-CanonicalObservationManifest $root
            $declaredManifest = $root.GetProperty("canonicalManifest")
            Assert-True ($declaredManifest.GetProperty("contractId").GetString() -ceq $ExpectedContractId) "phase3b2_observation_set_manifest_contract_mismatch"
            Assert-True ($declaredManifest.GetProperty("canonicalizationCode").GetString() -ceq "role_ordered_ordinal_json_members_lf_v1") "phase3b2_observation_set_manifest_canonicalization_mismatch"
            Assert-True ($declaredManifest.GetProperty("memberCount").GetInt32() -eq $computedManifest.MemberCount) "phase3b2_observation_set_manifest_count_mismatch"
            Assert-True ($declaredManifest.GetProperty("canonicalByteLength").GetInt64() -eq $computedManifest.ByteLength) "phase3b2_observation_set_manifest_length_mismatch"
            Assert-True ($declaredManifest.GetProperty("sha256").GetString() -ceq $computedManifest.Sha256) "phase3b2_observation_set_manifest_sha_mismatch"

            $sourceFreeSet = $Json | ConvertFrom-Json -Depth 100
            Assert-ProhibitedMaterialBoundary $sourceFreeSet
            return $true
        }
        finally {
            $document.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Assert-ManifestMatches {
    param(
        [object]$Manifest,
        [object]$ComputedManifest,
        [string]$ExpectedContractId,
        [string]$FailurePrefix
    )

    Assert-True ($null -ne $Manifest) "${FailurePrefix}_missing"
    Assert-True ($Manifest.contractId -ceq $ExpectedContractId) "${FailurePrefix}_contract_mismatch"
    Assert-True ($Manifest.canonicalizationCode -ceq "role_ordered_ordinal_json_members_lf_v1") "${FailurePrefix}_canonicalization_mismatch"
    Assert-True ($Manifest.memberCount -eq $ComputedManifest.MemberCount) "${FailurePrefix}_member_count_mismatch"
    Assert-True ($Manifest.canonicalByteLength -eq $ComputedManifest.ByteLength) "${FailurePrefix}_byte_length_mismatch"
    Assert-True ($Manifest.sha256 -ceq $ComputedManifest.Sha256) "${FailurePrefix}_sha_mismatch"
}

function Assert-ReadyPreflightObservationBinding {
    param(
        [string]$ObservationSetJson,
        [string]$PreflightJson,
        [string]$ObservationSetSchemaPath,
        [string]$PreflightSchemaPath,
        [string]$ObservationSetContractId
    )

    Assert-True (Test-CanonicalObservationSet $ObservationSetJson $ObservationSetSchemaPath $ObservationSetContractId) "phase3b2_local_observation_set_invalid"
    Assert-True (Test-CanonicalAssessment $PreflightJson $PreflightSchemaPath) "phase3b2_local_preflight_assessment_invalid"

    $observationDocument = [System.Text.Json.JsonDocument]::Parse($ObservationSetJson)
    try {
        $observationRoot = $observationDocument.RootElement
        $computedManifest = Get-CanonicalObservationManifest $observationRoot
        $observationAssessmentUid = $observationRoot.GetProperty("assessmentUid").GetString()
        $observedAtUtc = [DateTimeOffset]::ParseExact(
            $observationRoot.GetProperty("observedAtUtc").GetString(),
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
        $observationMembers = @($observationRoot.GetProperty("observations").EnumerateArray())

        $externalBuildObservation = $observationMembers[3]
        Assert-True ($externalBuildObservation.GetProperty("dotnetSdkVersion").GetString() -ceq "10.0.400") "phase3b2_local_external_sdk_mismatch"
        Assert-True ($externalBuildObservation.GetProperty("selectedManagerPassedCount").GetInt32() -eq 64 -and
            $externalBuildObservation.GetProperty("handlerIsolationPassedCount").GetInt32() -eq 5 -and
            $externalBuildObservation.GetProperty("focusedTestFailedCount").GetInt32() -eq 0 -and
            -not $externalBuildObservation.GetProperty("localOnlyHttp3Enabled").GetBoolean() -and
            -not $externalBuildObservation.GetProperty("localOnlyAssetCachePathLoggingEnabled").GetBoolean()) `
            "phase3b2_local_external_focused_test_mismatch"

        $http3Listener = $observationMembers[13].GetProperty("http3Listener")
        Assert-True ($http3Listener.GetProperty("protocolCode").GetString() -ceq "http3" -and
            $http3Listener.GetProperty("transportCode").GetString() -ceq "udp" -and
            $http3Listener.GetProperty("statusCode").GetString() -ceq "disabled_local_only" -and
            $http3Listener.GetProperty("port").GetInt32() -eq 443 -and
            $http3Listener.GetProperty("listenerCount").GetInt32() -eq 0) "phase3b2_local_http3_listener_mismatch"

        $preflightDocument = [System.Text.Json.JsonDocument]::Parse($PreflightJson)
        try {
            $preflightAssessmentUid = $preflightDocument.RootElement.GetProperty("assessmentUid").GetString()
            $preflightAssessedAtUtc = $preflightDocument.RootElement.GetProperty("assessedAtUtc").GetString()
        }
        finally {
            $preflightDocument.Dispose()
        }

        $preflight = $PreflightJson | ConvertFrom-Json -Depth 100
        Assert-True ($preflightAssessmentUid -ceq $observationAssessmentUid) "phase3b2_local_assessment_uid_binding_mismatch"
        $assessedAtUtc = [DateTimeOffset]::ParseExact(
            $preflightAssessedAtUtc,
            "yyyy-MM-dd'T'HH:mm:ss'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
        Assert-True ($assessedAtUtc -ge $observedAtUtc) "phase3b2_local_assessment_precedes_observation"
        Assert-True ($preflight.verdict -ceq "ready_to_start_isolated_season26_reference_run") "phase3b2_local_preflight_not_ready"
        Assert-FixedTarget $preflight
        Assert-FixedExternalLineage $preflight
        Assert-ProhibitedMaterialBoundary $preflight

        Assert-True ($preflight.environment.environmentKindCode -ceq $observationMembers[0].GetProperty("environmentKindCode").GetString()) "phase3b2_local_environment_kind_binding_mismatch"
        Assert-True ($preflight.environment.snapshotStatusCode -ceq "ready") "phase3b2_local_snapshot_not_ready"
        Assert-True ($preflight.environment.systemTrustIsolationStatusCode -ceq "disposable_environment_only") "phase3b2_local_system_trust_not_isolated"
        Assert-True ($preflight.environment.primaryInstallIntegrityStatusCode -ceq "unchanged") "phase3b2_local_primary_install_not_unchanged"
        Assert-True ($preflight.environment.syntheticLocalAccountOnly -eq $true -and
            $preflight.environment.officialAccountMaterialPresent -eq $false -and
            $preflight.environment.clientExecutionStarted -eq $false) "phase3b2_local_environment_identity_or_execution_violation"

        Assert-True ($preflight.runtimeInputs.clientBuildStatusCode -ceq "exact" -and
            $preflight.runtimeInputs.externalLineageStatusCode -ceq "exact" -and
            $preflight.runtimeInputs.reviewedRuntimeInputStatusCode -ceq "exact" -and
            $preflight.runtimeInputs.reviewedRuntimeInputExpectedMemberCount -eq 4 -and
            $preflight.runtimeInputs.reviewedRuntimeInputObservedMemberCount -eq 4) "phase3b2_local_runtime_inputs_not_exact"
        Assert-True ($preflight.networkIsolation.processTreeScopeStatusCode -ceq "complete" -and
            $preflight.networkIsolation.loopbackBindStatusCode -ceq "exact_127_0_0_1" -and
            $preflight.networkIsolation.nonLoopbackEgressStatusCode -ceq "blocked" -and
            $preflight.networkIsolation.coversIpv4 -eq $true -and
            $preflight.networkIsolation.coversIpv6 -eq $true -and
            $preflight.networkIsolation.coversDns -eq $true -and
            $preflight.networkIsolation.coversTcp -eq $true -and
            $preflight.networkIsolation.coversUdp -eq $true) "phase3b2_local_network_isolation_incomplete"
        Assert-True ($preflight.mutationRollback.statusCode -ceq "prepared") "phase3b2_local_mutation_rollback_not_prepared"
        $mutationObservation = $observationMembers[11]
        $mutationBindings = @(
            @($preflight.mutationRollback.systemHostsStatusCode, $mutationObservation.GetProperty("systemHosts").GetProperty("statusCode").GetString()),
            @($preflight.mutationRollback.rootCaStatusCode, $mutationObservation.GetProperty("rootCa").GetProperty("statusCode").GetString()),
            @($preflight.mutationRollback.clientCertificateBundleStatusCode, $mutationObservation.GetProperty("clientCertificateBundle").GetProperty("statusCode").GetString()),
            @($preflight.mutationRollback.nativeCompatibilityShimStatusCode, $mutationObservation.GetProperty("nativeCompatibilityShim").GetProperty("statusCode").GetString())
        )
        foreach ($binding in $mutationBindings) {
            Assert-True ($binding[0] -ceq $binding[1]) "phase3b2_local_mutation_member_binding_mismatch"
            Assert-True ($binding[0] -ceq "not_applicable" -or $binding[0] -ceq "sealed_with_backup_and_rollback") "phase3b2_local_mutation_member_not_prepared"
        }
        Assert-True ($preflight.measuredEvidence.statusCode -ceq "measured_complete" -and
            $preflight.measuredEvidence.observationCount -eq 18) "phase3b2_local_measured_evidence_incomplete"
        Assert-True (@($preflight.blockingReasonCodes).Count -eq 0) "phase3b2_local_ready_preflight_has_blockers"
        $expectedNextSteps = @(
            "start_exact_bound_reference_run_once",
            "preserve_assessment_pins_until_client_start",
            "do_not_restart_or_restore_before_reference_run"
        )
        Assert-True ((@($preflight.nextStepRequirementCodes) -join "`n") -ceq ($expectedNextSteps -join "`n")) "phase3b2_local_next_step_contract_mismatch"

        Assert-ManifestMatches $preflight.runtimeInputs.canonicalManifest $computedManifest $ObservationSetContractId "phase3b2_local_runtime_manifest"
        Assert-ManifestMatches $preflight.networkIsolation.canonicalManifest $computedManifest $ObservationSetContractId "phase3b2_local_network_manifest"
        Assert-ManifestMatches $preflight.mutationRollback.canonicalManifest $computedManifest $ObservationSetContractId "phase3b2_local_mutation_manifest"
        Assert-ManifestMatches $preflight.measuredEvidence.canonicalManifest $computedManifest $ObservationSetContractId "phase3b2_local_measured_manifest"
    }
    finally {
        $observationDocument.Dispose()
    }
}

function Get-RepositoryJsonPaths {
    param([string]$RepositoryRoot)

    $paths = @(& git -C $RepositoryRoot ls-files --cached --others --exclude-standard "*.json")
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_repository_json_inventory_failed"
    return @($paths | ForEach-Object { $_.Replace("\", "/") })
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$PreflightSchemaPath = Join-Path $RepositoryRoot "contracts/season26-classic-live-preflight.schema.json"
$ReferenceRunSchemaPath = Join-Path $RepositoryRoot "contracts/season26-classic-reference-run.schema.json"
$ObservationSetSchemaPath = Join-Path $RepositoryRoot "contracts/season26-classic-live-preflight-observation-set.schema.json"
$TargetObservationV2SchemaPath = Join-Path $RepositoryRoot "contracts/season26-classic-target-observation-v2.schema.json"
$PreflightRelativePath = "tests/fixtures/synthetic/season26-classic-live-preflight.blocked.json"
$ReferenceRunRelativePath = "tests/fixtures/synthetic/season26-classic-reference-run.not-executed.json"
$ObservationSetRelativePath = "tests/fixtures/synthetic/season26-classic-live-preflight-observation-set.valid.json"
$PreflightPath = Join-Path $RepositoryRoot $PreflightRelativePath
$ReferenceRunPath = Join-Path $RepositoryRoot $ReferenceRunRelativePath
$ObservationSetPath = Join-Path $RepositoryRoot $ObservationSetRelativePath
$PreflightContractId = "nll/season26-classic-live-preflight/v1"
$ReferenceRunContractId = "nll/season26-classic-reference-run/v1"
$ObservationSetContractId = "nll/season26-classic-live-preflight-observation-set/v1"

$hasLocalObservationSet = -not [string]::IsNullOrWhiteSpace($LocalObservationSetPath)
$hasLocalPreflightAssessment = -not [string]::IsNullOrWhiteSpace($LocalPreflightAssessmentPath)
Assert-True ($hasLocalObservationSet -eq $hasLocalPreflightAssessment) "phase3b2_local_pair_paths_required_together"

if ($ContractOnly) {
    Invoke-Checked "pwsh" @("-NoProfile", "-File", (Join-Path $ScriptDirectory "verify-phase3b1.ps1"), "-ContractOnly")
}
else {
    Invoke-Checked "pwsh" @("-NoProfile", "-File", (Join-Path $ScriptDirectory "verify-phase3b1.ps1"))
}

# The service lifecycle test uses synthetic snapshots and mocks all OS mutations.
Invoke-Checked "pwsh" @("-NoProfile", "-File", (Join-Path $ScriptDirectory "test-nll-native-fx-managed-service.ps1"))

Assert-True (Test-Path -LiteralPath $PreflightSchemaPath -PathType Leaf) "phase3b2_preflight_schema_missing"
Assert-True (Test-Path -LiteralPath $ReferenceRunSchemaPath -PathType Leaf) "phase3b2_reference_run_schema_missing"
Assert-True (Test-Path -LiteralPath $ObservationSetSchemaPath -PathType Leaf) "phase3b2_observation_set_schema_missing"
Assert-True (Test-Path -LiteralPath $TargetObservationV2SchemaPath -PathType Leaf) "phase3b2_target_observation_v2_schema_missing"
Assert-True (Test-Path -LiteralPath $PreflightPath -PathType Leaf) "phase3b2_blocked_preflight_fixture_missing"
Assert-True (Test-Path -LiteralPath $ReferenceRunPath -PathType Leaf) "phase3b2_not_executed_reference_run_fixture_missing"
Assert-True (Test-Path -LiteralPath $ObservationSetPath -PathType Leaf) "phase3b2_observation_set_fixture_missing"

$localBootstrapSourcePath = Join-Path $RepositoryRoot `
    "tools/Phase3B2/LocalBootstrap/Program.cs"
$localBootstrapProjectPath = Join-Path $RepositoryRoot `
    "tools/Phase3B2/LocalBootstrap/NikkeLocalLab.Phase3B2.LocalBootstrap.csproj"
$localBootstrapGlobalJsonPath = Join-Path $RepositoryRoot `
    "tools/Phase3B2/LocalBootstrap/global.json"
$localBootstrapLockPath = Join-Path $RepositoryRoot `
    "tools/Phase3B2/LocalBootstrap/packages.lock.json"
$localBootstrapBuildPath = Join-Path $ScriptDirectory `
    "build-phase3b2-local-bootstrap.ps1"
$localBootstrapPreparePath = Join-Path $ScriptDirectory `
    "prepare-phase3b2-local-bootstrap-p0-v5-in-vm.ps1"
$localBootstrapRollbackPath = Join-Path $ScriptDirectory `
    "rollback-phase3b2-p0-with-local-bootstrap-in-vm.ps1"
$localBootstrapReferencePath = Join-Path $ScriptDirectory `
    "start-phase3b2-local-bootstrap-reference-in-vm.ps1"
$localBootstrapWorkflowPath = Join-Path $ScriptDirectory `
    "recover-and-prepare-phase3b2-local-bootstrap.ps1"
$localBootstrapVirtualEnvironmentRecoveryPath = Join-Path $ScriptDirectory `
    "recover-phase3b2-after-virtual-environment-rejection.ps1"
$localBootstrapPaths = @(
    $localBootstrapSourcePath,
    $localBootstrapProjectPath,
    $localBootstrapGlobalJsonPath,
    $localBootstrapLockPath,
    $localBootstrapBuildPath,
    $localBootstrapPreparePath,
    $localBootstrapRollbackPath,
    $localBootstrapReferencePath,
    $localBootstrapWorkflowPath,
    $localBootstrapVirtualEnvironmentRecoveryPath
)
Assert-True (@($localBootstrapPaths | Where-Object {
            -not (Test-Path -LiteralPath $_ -PathType Leaf)
        }).Count -eq 0) "phase3b2_local_bootstrap_contract_file_missing"
$localBootstrapSourceText = [IO.File]::ReadAllText(
    $localBootstrapSourcePath)
$localBootstrapProjectText = [IO.File]::ReadAllText(
    $localBootstrapProjectPath)
$localBootstrapBuildText = [IO.File]::ReadAllText(
    $localBootstrapBuildPath)
$localBootstrapPrepareText = [IO.File]::ReadAllText(
    $localBootstrapPreparePath)
$localBootstrapReferenceText = [IO.File]::ReadAllText(
    $localBootstrapReferencePath)
$localBootstrapWorkflowText = [IO.File]::ReadAllText(
    $localBootstrapWorkflowPath)
$localBootstrapVirtualEnvironmentRecoveryText = [IO.File]::ReadAllText(
    $localBootstrapVirtualEnvironmentRecoveryPath)
$localBootstrapCombinedImplementation = @(
    $localBootstrapSourceText,
    $localBootstrapReferenceText,
    $localBootstrapWorkflowText,
    $localBootstrapVirtualEnvironmentRecoveryText
) -join "`n"
Assert-True ($localBootstrapProjectText -match
        '<TargetFramework>net10\.0</TargetFramework>' -and
    $localBootstrapProjectText -match
        '<TreatWarningsAsErrors>true</TreatWarningsAsErrors>' -and
    $localBootstrapBuildText -match
        '3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3' -and
    $localBootstrapBuildText -match
        '54b85eb6fbaa74feae0c6b441d66a5a703073ba3' -and
    $localBootstrapBuildText -match '--locked-mode' -and
    $localBootstrapBuildText -match
        'officialLauncherBuilt\s*=\s*\$false' -and
    $localBootstrapBuildText -match
        'antiCheatSubstitutionApplied\s*=\s*\$false') `
    "phase3b2_local_bootstrap_build_contract_invalid"
Assert-True ($localBootstrapSourceText -match
        'Sail\.SharedMemory\.\{GameId\}' -and
    $localBootstrapSourceText -match 'NamedPipeServerStream\(' -and
    $localBootstrapSourceText -match
        'E:\\NIKKE\\game\\nikke\.exe' -and
    $localBootstrapSourceText -match
        'officialLauncherExecutionStarted.*false' -and
    $localBootstrapCombinedImplementation -notmatch
        'CreateRemoteThread|WriteProcessMemory|ReadProcessMemory|VirtualAllocEx|SetWindowsHookEx|MinHook|Detour|DangerousAcceptAnyServerCertificateValidator|ServerCertificateCustomValidationCallback') `
    "phase3b2_local_bootstrap_runtime_boundary_invalid"
Assert-True ($localBootstrapPrepareText -match
        'NLL-P3B2-Block-017' -and
    $localBootstrapPrepareText -match
        'source_built_sail_abi_local_bootstrap' -and
    $localBootstrapPrepareText -match
        'officialLauncherExecutionPermitted\s*=\s*\$false' -and
    $localBootstrapReferenceText -match
        'Get-NetRoute[\s\S]*0\.0\.0\.0/0' -and
    $localBootstrapReferenceText -match
        'Get-NetRoute[\s\S]*::/0' -and
    $localBootstrapReferenceText -match
        'retryPerformed\s*=\s*\$false' -and
    $localBootstrapWorkflowText -match
        'NLL-P3B2-W1-P0-Private-SQLiteCredential-v1-' -and
    $localBootstrapWorkflowText -match
        'new-phase3b2-private-p0-local-bootstrap-checkpoint\.ps1' -and
    $localBootstrapVirtualEnvironmentRecoveryText -match
        'runtime_blocked_virtualized_environment' -and
    $localBootstrapVirtualEnvironmentRecoveryText -match
        'original_client_rejected_virtualized_environment_before_sail_pipe_connection' -and
    $localBootstrapVirtualEnvironmentRecoveryText -match
        'antiVirtualizationBypassAttempted\s*=\s*\$false' -and
    $localBootstrapVirtualEnvironmentRecoveryText -match
        'processInjectionOrHookingAttempted\s*=\s*\$false' -and
    $localBootstrapVirtualEnvironmentRecoveryText -match
        'NLL-P3B2-W1-P0-Private-LocalBootstrap-v1-[\s\S]*Restore-VMSnapshot' -and
    $localBootstrapVirtualEnvironmentRecoveryText -notmatch
        'DisableAC|hypervisor.*hide|anti.?vm.*bypass') `
    "phase3b2_local_bootstrap_operational_contract_invalid"

$preflightText = [System.IO.File]::ReadAllText($PreflightPath, [System.Text.UTF8Encoding]::new($false, $true))
$referenceRunText = [System.IO.File]::ReadAllText($ReferenceRunPath, [System.Text.UTF8Encoding]::new($false, $true))
$observationSetText = [System.IO.File]::ReadAllText($ObservationSetPath, [System.Text.UTF8Encoding]::new($false, $true))
Assert-True (Test-CanonicalAssessment $preflightText $PreflightSchemaPath) "phase3b2_blocked_preflight_fixture_invalid"
Assert-True (Test-CanonicalAssessment $referenceRunText $ReferenceRunSchemaPath) "phase3b2_not_executed_reference_run_fixture_invalid"
Assert-True (Test-CanonicalObservationSet $observationSetText $ObservationSetSchemaPath $ObservationSetContractId) "phase3b2_observation_set_fixture_invalid"

$targetObservationV2 = [ordered]@{
    schemaVersion = 2
    contractId = "nll/season26-classic-target-observation/v2"
    sourceClosureContractId = "nll/season26-classic-solo-raid-closure/v1"
    sourceObservationRoleCode = "staticdata_archive_target"
    sourceObservationSha256 = "925762cd3ef56601916b2e2ae58f929d4dd389055b0d8bcd2176e9abd9b29e69"
    clientBuildVersion = "150.6.9"
    seasonNumber = 26
    modeCode = "classic_solo_raid"
    museumAllowed = $false
    projectionCode = "exact_target_and_containing_spawn_source_order/v1"
    recordRoleCount = 6
    canonicalLineCount = 150
    canonicalByteLength = 6689
    sha256 = "095eebce4f244f9326aa558302318f85547697b165eb6458735527bd2b0f6d10"
    recomputedMatch = $true
}
Assert-True (Test-Json -Json ($targetObservationV2 | ConvertTo-Json -Depth 10 -Compress) -SchemaFile $TargetObservationV2SchemaPath -ErrorAction SilentlyContinue) "phase3b2_target_observation_v2_contract_invalid"

$preflight = $preflightText | ConvertFrom-Json -Depth 100
$referenceRun = $referenceRunText | ConvertFrom-Json -Depth 100
Assert-True ($preflight.contractId -ceq $PreflightContractId) "phase3b2_preflight_contract_id_mismatch"
Assert-True ($referenceRun.contractId -ceq $ReferenceRunContractId) "phase3b2_reference_run_contract_id_mismatch"
Assert-True ($preflight.verdict -ceq "blocked_preflight_incomplete") "phase3b2_preflight_fixture_not_blocked"
Assert-True ($referenceRun.verdict -ceq "not_executed_contract_scaffold_only") "phase3b2_reference_run_fixture_not_scaffold_only"
Assert-FixedTarget $preflight
Assert-FixedTarget $referenceRun
Assert-FixedExternalLineage $preflight
Assert-FixedExternalLineage $referenceRun
Assert-ProhibitedMaterialBoundary $preflight
Assert-ProhibitedMaterialBoundary $referenceRun

Assert-True ($preflight.measuredEvidence.statusCode -ceq "not_measured") "phase3b2_preflight_evidence_already_measured"
Assert-True ($preflight.measuredEvidence.observationCount -eq 0) "phase3b2_preflight_observation_present"
Assert-True ($null -eq $preflight.measuredEvidence.canonicalManifest) "phase3b2_preflight_manifest_present"
Assert-True ($referenceRun.execution.statusCode -ceq "not_executed") "phase3b2_reference_run_already_executed"
Assert-True ($null -eq $referenceRun.execution.startedAtUtc -and
    $null -eq $referenceRun.execution.completedAtUtc) "phase3b2_reference_run_execution_time_present"
Assert-True ($referenceRun.execution.observationCount -eq 0) "phase3b2_reference_run_observation_present"
Assert-True ($null -eq $referenceRun.execution.canonicalManifest) "phase3b2_reference_run_manifest_present"
Assert-True ($referenceRun.originalClientResult.statusCode -ceq "not_observed" -and
    -not $referenceRun.originalClientResult.battleRuntimeStarted -and
    -not $referenceRun.originalClientResult.hudObserved -and
    -not $referenceRun.originalClientResult.damageObserved -and
    -not $referenceRun.originalClientResult.resultReturned) "phase3b2_original_client_result_overclaimed"

$readyPreflightCandidate = $preflightText | ConvertFrom-Json -Depth 100
$readyPreflightCandidate.verdict = "ready_to_start_isolated_season26_reference_run"
Assert-True (-not (Test-Json -Json ($readyPreflightCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_unmeasured_preflight_ready_verdict_accepted"

$unsupportedEnvironmentVerdictCandidate = $preflightText | ConvertFrom-Json -Depth 100
$unsupportedEnvironmentVerdictCandidate.verdict = "blocked_environment_violation"
Assert-True (-not (Test-Json -Json ($unsupportedEnvironmentVerdictCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_environment_violation_without_observation_accepted"

$officialMaterialCandidate = $preflightText | ConvertFrom-Json -Depth 100
$officialMaterialCandidate.verdict = "blocked_environment_violation"
$officialMaterialCandidate.environment.syntheticLocalAccountOnly = $false
$officialMaterialCandidate.environment.officialAccountMaterialPresent = $true
Assert-True (Test-Json -Json ($officialMaterialCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue) "phase3b2_controlled_official_material_violation_rejected"

$verifiedRunCandidate = $referenceRunText | ConvertFrom-Json -Depth 100
$verifiedRunCandidate.verdict = "verified_isolated_season26_original_client_result"
Assert-True (-not (Test-Json -Json ($verifiedRunCandidate | ConvertTo-Json -Depth 100) -SchemaFile $ReferenceRunSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_not_executed_verified_verdict_accepted"

$preflightPinCandidate = $preflightText | ConvertFrom-Json -Depth 100
$preflightPinCandidate.externalLineage.latestExternalTreeCommitSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-Json -Json ($preflightPinCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_preflight_external_pin_drift_accepted"

$preflightHeadCandidate = $preflightText | ConvertFrom-Json -Depth 100
$preflightHeadCandidate.externalLineage.latestExternalCommitSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-Json -Json ($preflightHeadCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_preflight_external_head_drift_accepted"

$referencePinCandidate = $referenceRunText | ConvertFrom-Json -Depth 100
$referencePinCandidate.externalLineage.latestExternalTreeCommitSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-Json -Json ($referencePinCandidate | ConvertTo-Json -Depth 100) -SchemaFile $ReferenceRunSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_reference_run_external_pin_drift_accepted"

$pathCandidate = $preflightText | ConvertFrom-Json -Depth 100
$pathCandidate.runtimeInputs | Add-Member -NotePropertyName "sourcePath" -NotePropertyValue "synthetic"
Assert-True (-not (Test-Json -Json ($pathCandidate | ConvertTo-Json -Depth 100) -SchemaFile $PreflightSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_source_path_property_accepted"

$rawIdCandidate = $referenceRunText | ConvertFrom-Json -Depth 100
$rawIdCandidate.target | Add-Member -NotePropertyName "managerId" -NotePropertyValue 1
Assert-True (-not (Test-Json -Json ($rawIdCandidate | ConvertTo-Json -Depth 100) -SchemaFile $ReferenceRunSchemaPath -ErrorAction SilentlyContinue)) "phase3b2_raw_manager_id_property_accepted"

$timestampCandidate = $referenceRunText | ConvertFrom-Json -Depth 100
$timestampCandidate.assessedAtUtc = "2026-02-31T00:00:00Z"
Assert-True (-not (Test-CanonicalAssessment ($timestampCandidate | ConvertTo-Json -Depth 100) $ReferenceRunSchemaPath)) "phase3b2_invalid_timestamp_accepted"

$observationContractCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$observationContractCandidate.contractId = "nll/season26-classic-live-preflight-observation-set/v2"
Assert-True (-not (Test-CanonicalObservationSet ($observationContractCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_observation_contract_drift_accepted"

$observationOrderCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$firstObservation = $observationOrderCandidate.observations[0]
$observationOrderCandidate.observations[0] = $observationOrderCandidate.observations[1]
$observationOrderCandidate.observations[1] = $firstObservation
Assert-True (-not (Test-CanonicalObservationSet ($observationOrderCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_observation_role_reorder_accepted"

$runtimePackCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$runtimePackCandidate.observations[4] = $runtimePackCandidate.observations[5]
Assert-True (-not (Test-CanonicalObservationSet ($runtimePackCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_distinct_runtime_pack_missing_accepted"

$egressCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$egressCandidate.observations[10].nonLoopbackAttemptCount = 1
Assert-True (-not (Test-CanonicalObservationSet ($egressCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_non_loopback_attempt_accepted"

$wildcardListenerCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$wildcardListenerCandidate.observations[13].wildcardListenerCount = 1
Assert-True (-not (Test-CanonicalObservationSet ($wildcardListenerCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_wildcard_listener_accepted"

$http3ListenerCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$http3ListenerCandidate.observations[13].http3Listener.listenerCount = 1
Assert-True (-not (Test-CanonicalObservationSet ($http3ListenerCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_http3_listener_drift_accepted"

$http3ConfigCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$http3ConfigCandidate.observations[12].http3Enabled = $true
Assert-True (-not (Test-CanonicalObservationSet ($http3ConfigCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_local_only_http3_enabled_accepted"

$externalSdkCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$externalSdkCandidate.observations[3].dotnetSdkVersion = "10.0.401"
Assert-True (-not (Test-CanonicalObservationSet ($externalSdkCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_external_sdk_drift_accepted"

$externalTestCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$externalTestCandidate.observations[3].focusedTestFailedCount = 1
Assert-True (-not (Test-CanonicalObservationSet ($externalTestCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_external_focused_test_failure_accepted"

$externalTestCountCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$externalTestCountCandidate.observations[3].selectedManagerPassedCount = 63
Assert-True (-not (Test-CanonicalObservationSet ($externalTestCountCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_external_focused_test_count_drift_accepted"

$externalPathLogCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$externalPathLogCandidate.observations[3].localOnlyAssetCachePathLoggingEnabled = $true
Assert-True (-not (Test-CanonicalObservationSet ($externalPathLogCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_local_only_asset_path_logging_accepted"

$targetObservationCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$targetObservationCandidate.observations[14].targetObservationContractId = "nll/season26-classic-target-observation/v1"
Assert-True (-not (Test-CanonicalObservationSet ($targetObservationCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_target_observation_v1_accepted"

$targetDigestCandidate = $targetObservationV2 | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
$targetDigestCandidate.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-Json -Json ($targetDigestCandidate | ConvertTo-Json -Depth 10 -Compress) -SchemaFile $TargetObservationV2SchemaPath -ErrorAction SilentlyContinue)) "phase3b2_target_observation_v2_digest_drift_accepted"

$observationManifestCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$observationManifestCandidate.canonicalManifest.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-CanonicalObservationSet ($observationManifestCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_observation_manifest_drift_accepted"

$observationPathCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$observationPathCandidate.observations[0] | Add-Member -NotePropertyName "localPath" -NotePropertyValue "C:\synthetic"
Assert-True (-not (Test-CanonicalObservationSet ($observationPathCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_observation_local_path_accepted"

$observationProhibitedCandidate = $observationSetText | ConvertFrom-Json -Depth 100
$observationProhibitedCandidate.prohibitedMaterial.certificateMaterialIncluded = $true
Assert-True (-not (Test-CanonicalObservationSet ($observationProhibitedCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $ObservationSetContractId)) "phase3b2_observation_certificate_material_accepted"

if ($hasLocalObservationSet) {
    $resolvedLocalObservationSetPath = Assert-ExternalRegularJsonPath $LocalObservationSetPath $RepositoryRoot "phase3b2_local_observation_set"
    $resolvedLocalPreflightAssessmentPath = Assert-ExternalRegularJsonPath $LocalPreflightAssessmentPath $RepositoryRoot "phase3b2_local_preflight_assessment"
    $localObservationSetText = [System.IO.File]::ReadAllText($resolvedLocalObservationSetPath, [System.Text.UTF8Encoding]::new($false, $true))
    $localPreflightAssessmentText = [System.IO.File]::ReadAllText($resolvedLocalPreflightAssessmentPath, [System.Text.UTF8Encoding]::new($false, $true))
    Assert-ReadyPreflightObservationBinding $localObservationSetText $localPreflightAssessmentText $ObservationSetSchemaPath $PreflightSchemaPath $ObservationSetContractId

    $manifestMutationCandidate = $localPreflightAssessmentText | ConvertFrom-Json -Depth 100
    $manifestMutationCandidate.measuredEvidence.canonicalManifest.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    $manifestMutationRejected = $false
    try {
        Assert-ReadyPreflightObservationBinding $localObservationSetText ($manifestMutationCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $PreflightSchemaPath $ObservationSetContractId
    }
    catch {
        $manifestMutationRejected = $true
    }
    Assert-True $manifestMutationRejected "phase3b2_local_manifest_mutation_accepted"

    $clientStartMutationCandidate = $localPreflightAssessmentText | ConvertFrom-Json -Depth 100
    $clientStartMutationCandidate.environment.clientExecutionStarted = $true
    $clientStartMutationRejected = $false
    try {
        Assert-ReadyPreflightObservationBinding $localObservationSetText ($clientStartMutationCandidate | ConvertTo-Json -Depth 100 -Compress) $ObservationSetSchemaPath $PreflightSchemaPath $ObservationSetContractId
    }
    catch {
        $clientStartMutationRejected = $true
    }
    Assert-True $clientStartMutationRejected "phase3b2_local_premature_client_start_accepted"
}

$inventory = Get-RepositoryJsonPaths $RepositoryRoot
$preflightMatchingPaths = [System.Collections.Generic.List[string]]::new()
$referenceRunMatchingPaths = [System.Collections.Generic.List[string]]::new()
$observationSetMatchingPaths = [System.Collections.Generic.List[string]]::new()
foreach ($candidatePath in $inventory) {
    $fullPath = Join-Path $RepositoryRoot $candidatePath
    try {
        $candidateText = [System.IO.File]::ReadAllText($fullPath, [System.Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($candidateText)
        try {
            if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                continue
            }

            $contractIdElement = [System.Text.Json.JsonElement]::new()
            if (-not $document.RootElement.TryGetProperty("contractId", [ref]$contractIdElement)) {
                continue
            }

            $contractId = $contractIdElement.GetString()
            if ($contractId -ceq $PreflightContractId) {
                Assert-SafeJsonElement $document.RootElement
                $preflightMatchingPaths.Add($candidatePath)
            }
            elseif ($contractId -ceq $ReferenceRunContractId) {
                Assert-SafeJsonElement $document.RootElement
                $referenceRunMatchingPaths.Add($candidatePath)
            }
            elseif ($contractId -ceq $ObservationSetContractId) {
                Assert-SafeJsonElement $document.RootElement
                $observationSetMatchingPaths.Add($candidatePath)
            }
        }
        finally {
            $document.Dispose()
        }
    }
    catch {
        if ($candidatePath -ceq $PreflightRelativePath -or $candidatePath -ceq $ReferenceRunRelativePath) {
            throw
        }
    }
}

Assert-True ($preflightMatchingPaths.Count -eq 1) "phase3b2_preflight_assessment_inventory_count_mismatch"
Assert-True ($preflightMatchingPaths[0] -ceq $PreflightRelativePath) "phase3b2_preflight_assessment_inventory_path_mismatch"
Assert-True ($referenceRunMatchingPaths.Count -eq 1) "phase3b2_reference_run_assessment_inventory_count_mismatch"
Assert-True ($referenceRunMatchingPaths[0] -ceq $ReferenceRunRelativePath) "phase3b2_reference_run_assessment_inventory_path_mismatch"
Assert-True ($observationSetMatchingPaths.Count -eq 1) "phase3b2_observation_set_inventory_count_mismatch"
Assert-True ($observationSetMatchingPaths[0] -ceq $ObservationSetRelativePath) "phase3b2_observation_set_inventory_path_mismatch"

$mode = if ($ContractOnly) { "contract-only" } else { "full baseline and contract" }
$localMode = if ($hasLocalObservationSet) {
    " A Git-external measured observation set and ready preflight candidate were also validated; neither was copied into tracked evidence."
}
else {
    ""
}
Write-Output "Phase 3B-2 $mode scaffold verification passed; tracked preflight remains blocked and the tracked reference run remains not executed.$localMode"
