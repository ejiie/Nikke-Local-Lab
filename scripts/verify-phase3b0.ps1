param(
    [switch]$ContractOnly
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

function Test-ClosureJson {
    param(
        [string]$Json,
        [string]$SchemaPath
    )

    return Test-Json -Json $Json -SchemaFile $SchemaPath -ErrorAction SilentlyContinue
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

function Assert-SafeJsonElement {
    param([System.Text.Json.JsonElement]$Element)

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $forbiddenNames = @(
            "assetId",
            "assetName",
            "bossName",
            "decodedValue",
            "fileName",
            "filePath",
            "localPath",
            "managerId",
            "managerName",
            "memberName",
            "monsterId",
            "monsterName",
            "originalId",
            "packVersion",
            "presetId",
            "raidId",
            "rawValue",
            "sourceId",
            "sourcePath",
            "statId",
            "waveId"
        )

        foreach ($property in $Element.EnumerateObject()) {
            Assert-True ($names.Add($property.Name)) "phase3b0_duplicate_json_property"
            Assert-True ($forbiddenNames -cnotcontains $property.Name) "phase3b0_forbidden_evidence_property"
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
            -not $value.StartsWith('file:', [System.StringComparison]::OrdinalIgnoreCase)) "phase3b0_local_path_value_exposed"
    }
}

function Get-CanonicalObservationManifest {
    param([object[]]$Observations)

    $normalized = @($Observations | Sort-Object -CaseSensitive -Property @(
        @{ Expression = { [string]$_.roleCode }; Ascending = $true },
        @{ Expression = { [string]$_.artifactKind }; Ascending = $true },
        @{ Expression = { [string]$_.sha256 }; Ascending = $true },
        @{ Expression = { [long]$_.byteLength }; Ascending = $true }
    ))

    $tuples = @($normalized | ForEach-Object {
        "$($_.roleCode)`0$($_.artifactKind)`0$($_.sha256)`0$($_.byteLength)"
    })
    Assert-True (($tuples | Sort-Object -CaseSensitive -Unique).Count -eq $normalized.Count) "phase3b0_duplicate_observation_tuple"

    $lines = @(
        "nll/dataset-input-manifest/v1",
        "count=$($normalized.Count.ToString([System.Globalization.CultureInfo]::InvariantCulture))"
    )
    $lines += @($normalized | ForEach-Object {
        $length = ([long]$_.byteLength).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        "$($_.roleCode)`t$($_.artifactKind)`t$($_.sha256)`t$length"
    })

    $text = $lines -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    return [pscustomobject]@{
        Text = $text
        ByteLength = $bytes.Length
        Sha256 = Get-Sha256Hex $bytes
    }
}

function Get-ExpectedManifestText {
    return @(
        "nll/dataset-input-manifest/v1",
        "count=14",
        "behavior_bundle`tasset_bundle_observation`t4adb06ddb6b325a64c536377c5f7554c26b89524af920f0bf9e4208f9935819a`t2415189",
        "challenge_behavior_graph`tnormalized_behavior_graph`t5a730e21ef76856763552ef200b64cf405ba7f1798420f120f793549f2b90e72`t915929",
        "challenge_catalog`tnormalized_challenge_catalog`t5158f410eae7ec806501ff047b21fbad3c9cc97385cc8f1a0cd95fbc4535a3f9`t84078",
        "challenge_timeline_routes`tnormalized_timeline_routes`tb7b08e489701f300317821baeeba0100f17ca13f5abae42023fd027298ecf835`t91354",
        "client_catalog_core`taddressables_catalog_observation`ta1dc8425ca034447a1e495d02f02e10fcbf92a772453aebfc214c3a88dd21d52`t10552026",
        "client_catalog_data_pack`taddressables_catalog_observation`t326c029414ccf06ff429dd2e017a8bbae6dc39fd295682c67f333a8611a6e5cb`t8630492",
        "client_catalog_field`taddressables_catalog_observation`taf0307449ddb4455357c7d2e4e9bf363f5bb2d4a8615e11e37939629b2acc04c`t337379",
        "client_executable`texecutable_observation`t2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30`t794152",
        "client_runtime_binary`truntime_binary_observation`ta4f0b9560ab0c00c9ab4f7ac64eb8e2631c7b70ab9e92ec18bb4944ce3c66954`t265846312",
        "client_unity_runtime`truntime_binary_observation`t3f696bcf12b9bc6a4efe26193bdc7f209aee48d9a717e415c773cc5de155b5b3`t29605288",
        "spotmonster_bundle`tasset_bundle_observation`t080b8ec6a0e1829bffa35fadce729a92ec8d06612f754ed6d315d0eaaf361f0e`t16240238",
        "staticdata_archive_comparison`tstaticdata_archive_observation`tebfc46d57cdbe1414553bf7891c734c018236ed924daf5b98f713de7b2809ae9`t17176417",
        "staticdata_archive_target`tstaticdata_archive_observation`t925762cd3ef56601916b2e2ae58f929d4dd389055b0d8bcd2176e9abd9b29e69`t17176616",
        "staticdata_package_target`tstaticdata_package_observation`t8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3`t17177168"
    ) -join "`n"
}

function Assert-CanonicalReadyAssessment {
    param(
        [string]$JsonText,
        [string]$SchemaPath
    )

    Assert-True (Test-ClosureJson $JsonText $SchemaPath) "phase3b0_ready_assessment_schema_invalid"

    $document = [System.Text.Json.JsonDocument]::Parse($JsonText)
    try {
        Assert-SafeJsonElement $document.RootElement
        $assessment = $JsonText | ConvertFrom-Json -Depth 100
        $assessmentInstant = $document.RootElement.GetProperty("assessedAtUtc").GetString()

        Assert-True ($assessment.contractId -ceq "nll/season26-classic-solo-raid-closure/v1") "phase3b0_contract_id_mismatch"
        Assert-True ($assessment.assessmentUid -ceq "3b000000-0000-4000-8000-000000000026") "phase3b0_assessment_uid_mismatch"
        Assert-True ($assessmentInstant -ceq "2026-08-20T13:57:53Z") "phase3b0_assessment_instant_mismatch"
        Assert-True (Test-UtcSecondInstant $assessmentInstant) "phase3b0_assessment_instant_invalid"
        Assert-True ($assessment.verdict -ceq "ready_for_selected_manager_patch_with_timing_analysis_blocker") "phase3b0_verdict_mismatch"

        Assert-True ($assessment.target.clientBuildVersion -ceq "150.6.9") "phase3b0_client_build_mismatch"
        Assert-True ($assessment.target.seasonNumber -eq 26) "phase3b0_season_mismatch"
        Assert-True ($assessment.target.modeCode -ceq "classic_solo_raid") "phase3b0_classic_mode_required"
        Assert-True ($assessment.target.museumAllowed -eq $false) "phase3b0_museum_allowed"
        Assert-True ($assessment.target.fallbackPolicyCode -ceq "none") "phase3b0_fallback_allowed"
        Assert-True ($assessment.dependencyPin.commitSha -ceq "28b2f5413a0a1e3521a11ae162f91851335c8b40") "phase3b0_upstream_commit_mismatch"

        Assert-True ($assessment.staticClosure.statusCode -ceq "exact") "phase3b0_static_closure_not_exact"
        Assert-True ($assessment.staticClosure.byteIdenticalRequiredStaticEntryCount -le $assessment.staticClosure.requiredStaticEntryCount) "phase3b0_static_entry_equivalence_overflow"
        Assert-True ($assessment.staticClosure.byteIdenticalRequiredStaticEntryCount -eq $assessment.staticClosure.requiredStaticEntryCount) "phase3b0_static_entry_equivalence_incomplete"
        Assert-True ($assessment.staticClosure.requiredStaticEntryCount -eq 7) "phase3b0_required_static_entry_count_mismatch"
        Assert-True ($assessment.staticClosure.targetArchiveEntryCount -eq 9380) "phase3b0_target_archive_entry_count_mismatch"
        Assert-True ($assessment.staticClosure.exactSelectedRowCount -le $assessment.staticClosure.selectedRowCount) "phase3b0_selected_row_exact_overflow"
        Assert-True ($assessment.staticClosure.exactSelectedRowCount -eq $assessment.staticClosure.selectedRowCount) "phase3b0_selected_row_exact_incomplete"
        Assert-True ($assessment.staticClosure.selectedRowCount -eq 6) "phase3b0_selected_row_count_mismatch"
        Assert-True (-not $assessment.staticClosure.latestManagerFallbackUsed -and
            -not $assessment.staticClosure.alternateSeasonFallbackUsed -and
            -not $assessment.staticClosure.museumFallbackUsed) "phase3b0_static_closure_fallback_used"

        $behaviorReferenceTotal = [int]$assessment.behaviorGraph.exactActiveSkillReferenceCount +
            [int]$assessment.behaviorGraph.ambiguousActiveSkillReferenceCount +
            [int]$assessment.behaviorGraph.unresolvedActiveSkillReferenceCount
        Assert-True ($behaviorReferenceTotal -eq $assessment.behaviorGraph.activeSkillReferenceCount) "phase3b0_behavior_reference_sum_mismatch"
        Assert-True ($assessment.behaviorGraph.exactActiveSkillReferenceCount -eq $assessment.behaviorGraph.activeSkillReferenceCount) "phase3b0_behavior_reference_closure_incomplete"
        Assert-True ($assessment.behaviorGraph.seasonMonsterSkillRowCount -eq 15) "phase3b0_behavior_season_row_count_mismatch"
        Assert-True ($assessment.behaviorGraph.exactEquivalentSeasonMonsterSkillRowCount -le $assessment.behaviorGraph.seasonMonsterSkillRowCount) "phase3b0_behavior_season_row_equivalence_overflow"
        Assert-True ($assessment.behaviorGraph.exactEquivalentSeasonMonsterSkillRowCount -eq $assessment.behaviorGraph.seasonMonsterSkillRowCount) "phase3b0_behavior_season_row_equivalence_incomplete"
        Assert-True ($assessment.behaviorGraph.byteIdenticalMonsterPartsTableEntryCount -le $assessment.behaviorGraph.monsterPartsTableEntryCount) "phase3b0_behavior_parts_entry_equivalence_overflow"
        Assert-True ($assessment.behaviorGraph.byteIdenticalMonsterPartsTableEntryCount -eq $assessment.behaviorGraph.monsterPartsTableEntryCount) "phase3b0_behavior_parts_entry_equivalence_incomplete"
        Assert-True ($assessment.behaviorGraph.monsterPartsTableEntryCount -eq 1) "phase3b0_behavior_parts_entry_count_mismatch"
        Assert-True ($assessment.behaviorGraph.derivationStaticArchiveRoleCode -ceq "staticdata_archive_comparison" -and
            $assessment.behaviorGraph.targetStaticArchiveRoleCode -ceq "staticdata_archive_target") "phase3b0_behavior_archive_roles_mismatch"
        Assert-True (-not $assessment.behaviorGraph.fixedLinearOrderClaimed -and -not $assessment.behaviorGraph.fixedSeedUsed) "phase3b0_behavior_graph_overclaimed"

        $timingRouteTotal = [int]$assessment.timingClosure.exactTimelineMarkerSkillCount +
            [int]$assessment.timingClosure.unresolvedRuntimeCallbackActiveSkillCount +
            [int]$assessment.timingClosure.routedWithoutExactAttackMarkerSkillCount
        Assert-True ($timingRouteTotal -eq $assessment.timingClosure.activeSkillCount) "phase3b0_timing_active_skill_sum_mismatch"
        Assert-True ($assessment.timingClosure.activeSkillCount -eq 14) "phase3b0_timing_active_skill_count_mismatch"
        Assert-True ($assessment.timingClosure.exactTimelineMarkerSkillCount -eq 7) "phase3b0_timing_marker_skill_count_mismatch"
        Assert-True ($assessment.timingClosure.unresolvedRuntimeCallbackActiveSkillCount -eq 5) "phase3b0_timing_runtime_callback_count_mismatch"
        Assert-True ($assessment.timingClosure.routedWithoutExactAttackMarkerSkillCount -eq 2) "phase3b0_timing_without_marker_count_mismatch"
        Assert-True (-not $assessment.timingClosure.blocksStaticClosure -and
            $assessment.timingClosure.blocksAbsoluteBattleTimingAnalysis) "phase3b0_timing_block_scope_mismatch"

        $routeClassifiedTotal = [int]$assessment.routeAudit.requestManagerSelectionPathCount +
            [int]$assessment.routeAudit.latestManagerFallbackPathCount +
            [int]$assessment.routeAudit.managerStatelessPathCount
        Assert-True ($routeClassifiedTotal -eq $assessment.routeAudit.classicHandlerCount) "phase3b0_route_audit_sum_mismatch"
        Assert-True ($assessment.routeAudit.classicHandlerCount -eq 19 -and
            $assessment.routeAudit.requestManagerSelectionPathCount -eq 6 -and
            $assessment.routeAudit.latestManagerFallbackPathCount -eq 9 -and
            $assessment.routeAudit.managerStatelessPathCount -eq 4) "phase3b0_route_audit_counts_mismatch"
        Assert-True ($assessment.routeAudit.selectedManagerPatchRequired -and
            $assessment.routeAudit.classicLatestManagerFallbackPresent -and
            -not $assessment.routeAudit.museumRouteRequired) "phase3b0_route_audit_state_mismatch"

        Assert-True (@($assessment.staticClosureBlockingReasonCodes).Count -eq 0) "phase3b0_static_blocking_reason_present"
        Assert-True ((@($assessment.timingAnalysisBlockingReasonCodes) -join "`n") -ceq "native_scheduler_rebind_required") "phase3b0_timing_blocking_reason_mismatch"
        Assert-True ((@($assessment.nextStepRequirementCodes) -join "`n") -ceq "classic_selected_manager_patch_required") "phase3b0_next_step_reason_mismatch"

        $targetPackageObservations = @($assessment.observations | Where-Object { $_.roleCode -ceq "staticdata_package_target" })
        Assert-True ($targetPackageObservations.Count -eq 1) "phase3b0_target_package_observation_count_mismatch"
        Assert-True ($targetPackageObservations[0].artifactKind -ceq "staticdata_package_observation" -and
            $targetPackageObservations[0].byteLength -eq 17177168 -and
            $targetPackageObservations[0].sha256 -ceq "8c0dfdcaf17446d0d25ecf2c5910272b1c1fc906191e6926037a81d94ef858e3") "phase3b0_target_package_observation_mismatch"

        $manifest = Get-CanonicalObservationManifest @($assessment.observations)
        $expectedManifestText = Get-ExpectedManifestText
        Assert-True ($manifest.Text -ceq $expectedManifestText) "phase3b0_observation_set_mismatch"
        Assert-True ($manifest.ByteLength -eq 1775) "phase3b0_manifest_byte_length_mismatch"
        Assert-True ($manifest.Sha256 -ceq "b358e284fc18953c65f50a3799c8efeb27f5a99b6a3f375303152b46388a2b09") "phase3b0_manifest_sha256_mismatch"
        Assert-True ($assessment.canonicalManifest.contractId -ceq "nll/dataset-input-manifest/v1") "phase3b0_manifest_contract_mismatch"
        Assert-True ($assessment.canonicalManifest.canonicalizationCode -ceq "role_kind_sha256_length_lf_ordinal/v1") "phase3b0_manifest_canonicalization_mismatch"
        Assert-True ($assessment.canonicalManifest.memberCount -eq @($assessment.observations).Count) "phase3b0_manifest_member_count_mismatch"
        Assert-True ($assessment.canonicalManifest.canonicalByteLength -eq $manifest.ByteLength) "phase3b0_declared_manifest_length_mismatch"
        Assert-True ($assessment.canonicalManifest.sha256 -ceq $manifest.Sha256) "phase3b0_declared_manifest_sha256_mismatch"
    }
    finally {
        $document.Dispose()
    }
}

function Test-CanonicalReadyAssessment {
    param(
        [string]$JsonText,
        [string]$SchemaPath
    )

    try {
        Assert-CanonicalReadyAssessment $JsonText $SchemaPath
        return $true
    }
    catch {
        return $false
    }
}

function Get-RepositoryInventoryPaths {
    param([string]$RepositoryRoot)

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "git"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        "-c", "safe.directory=$RepositoryRoot",
        "-c", "core.excludesFile=",
        "-C", $RepositoryRoot,
        "ls-files", "--cached", "--others", "--exclude-standard", "-z"
    )) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        Assert-True ($process.Start()) "phase3b0_repository_file_inventory_start_failed"
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $memory = [System.IO.MemoryStream]::new()
        try {
            $process.StandardOutput.BaseStream.CopyTo($memory)
            $process.WaitForExit()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            Assert-True ($process.ExitCode -eq 0) "phase3b0_repository_file_inventory_failed"
            $encoding = [System.Text.UTF8Encoding]::new($false, $true)
            $text = $encoding.GetString($memory.ToArray())
            return @($text.Split([char]0, [System.StringSplitOptions]::RemoveEmptyEntries))
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Test-FileContainsToken {
    param(
        [string]$Path,
        [string]$Token
    )

    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    $reader = [System.IO.StreamReader]::new($Path, $encoding, $true, 4096)
    try {
        $buffer = [char[]]::new(4096)
        $tail = ""
        while (($count = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $chunk = $tail + [string]::new($buffer, 0, $count)
            if ($chunk.IndexOf($Token, [System.StringComparison]::Ordinal) -ge 0) {
                return $true
            }

            $tailLength = [Math]::Min($Token.Length - 1, $chunk.Length)
            $tail = if ($tailLength -gt 0) { $chunk.Substring($chunk.Length - $tailLength) } else { "" }
        }

        return $false
    }
    finally {
        $reader.Dispose()
    }
}

function Assert-RepositoryReadyAssessmentInventory {
    param(
        [string]$RepositoryRoot,
        [string]$SchemaPath,
        [string]$CanonicalRelativePath,
        [long]$CanonicalByteLength,
        [string]$CanonicalSha256
    )

    $readyCount = 0
    $repositoryPrefix = $RepositoryRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    $encoding = [System.Text.UTF8Encoding]::new($false, $true)
    foreach ($pathEntry in Get-RepositoryInventoryPaths $RepositoryRoot) {
        $relativePath = $pathEntry.Replace('\', '/')
        if ([System.IO.Path]::GetExtension($relativePath) -ine ".json") {
            continue
        }

        $fullPath = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $relativePath))
        Assert-True ($fullPath.StartsWith($repositoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) "phase3b0_repository_path_escape"
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            continue
        }

        $item = Get-Item -LiteralPath $fullPath -Force
        Assert-True (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) "phase3b0_repository_assessment_reparse_point"
        if ($item.Length -gt 1MB) {
            Assert-True (-not (Test-FileContainsToken $fullPath "nll/season26-classic-solo-raid-closure/v1")) "phase3b0_oversized_repository_assessment"
            continue
        }

        try {
            $text = [System.IO.File]::ReadAllText($fullPath, $encoding)
        }
        catch {
            throw "phase3b0_repository_json_read_failed"
        }
        if ($text.IndexOf("nll/season26-classic-solo-raid-closure/v1", [System.StringComparison]::Ordinal) -lt 0) {
            continue
        }

        try {
            $document = [System.Text.Json.JsonDocument]::Parse($text)
        }
        catch {
            throw "phase3b0_repository_assessment_json_invalid"
        }
        try {
            Assert-SafeJsonElement $document.RootElement
            if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
                continue
            }

            $contractId = $null
            $verdict = $null
            foreach ($property in $document.RootElement.EnumerateObject()) {
                if ($property.Name -ceq "contractId" -and $property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                    $contractId = $property.Value.GetString()
                }
                elseif ($property.Name -ceq "verdict" -and $property.Value.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
                    $verdict = $property.Value.GetString()
                }
            }

            if ($contractId -cne "nll/season26-classic-solo-raid-closure/v1") {
                continue
            }

            Assert-True ($verdict -ceq "ready_for_selected_manager_patch_with_timing_analysis_blocker") "phase3b0_repository_assessment_verdict_invalid"
            $readyCount++
            Assert-True ($relativePath -ceq $CanonicalRelativePath) "phase3b0_noncanonical_ready_assessment_path"
            Assert-True ($item.Length -eq $CanonicalByteLength) "phase3b0_ready_assessment_file_length_mismatch"
            $bytes = [System.IO.File]::ReadAllBytes($fullPath)
            Assert-True ((Get-Sha256Hex $bytes) -ceq $CanonicalSha256) "phase3b0_ready_assessment_file_sha256_mismatch"
            Assert-CanonicalReadyAssessment $text $SchemaPath
        }
        finally {
            $document.Dispose()
        }
    }

    Assert-True ($readyCount -eq 1) "phase3b0_ready_assessment_inventory_count_mismatch"
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$Phase3A = Join-Path $ScriptDirectory "verify-phase3a.ps1"
$SchemaPath = Join-Path $RepositoryRoot "contracts/season26-classic-solo-raid-closure.schema.json"
$EvidenceManifestPath = Join-Path $RepositoryRoot "tests/fixtures/evidence/manifest.json"
$ReadyFixturePath = Join-Path $RepositoryRoot "tests/fixtures/evidence/season26-classic-solo-raid-closure.ready.json"
$CanonicalReadyRelativePath = "tests/fixtures/evidence/season26-classic-solo-raid-closure.ready.json"
$CanonicalReadyByteLength = 6968
$CanonicalReadySha256 = "6f1593c2218830d24a2f4eb1d20729545b73b87d2ec5fd7f48f8e8cfef9e3439"

foreach ($requiredPath in @($SchemaPath, $EvidenceManifestPath, $ReadyFixturePath)) {
    Assert-True (Test-Path -LiteralPath $requiredPath -PathType Leaf) "phase3b0_required_artifact_missing"
}

if (-not $ContractOnly) {
    Invoke-Checked pwsh @("-NoProfile", "-File", $Phase3A)
}

$EvidenceManifestText = [System.IO.File]::ReadAllText($EvidenceManifestPath)
$EvidenceManifest = $EvidenceManifestText | ConvertFrom-Json
Assert-True ($EvidenceManifest.classification -ceq "source_free_evidence") "phase3b0_evidence_classification_mismatch"
Assert-True ($EvidenceManifest.source -ceq "local_read_only_measurement") "phase3b0_evidence_source_mismatch"
Assert-True (-not $EvidenceManifest.containsGameContent -and
    -not $EvidenceManifest.containsRealAccountData -and
    -not $EvidenceManifest.containsRawIdentifiers -and
    -not $EvidenceManifest.containsLocalPaths) "phase3b0_evidence_manifest_boundary_mismatch"
$EvidenceFixtures = @($EvidenceManifest.fixtures)
Assert-True ($EvidenceFixtures -ccontains "season26-classic-solo-raid-closure.ready.json") "phase3b0_evidence_manifest_fixture_missing"
$CanonicalEvidenceFixtures = @($EvidenceFixtures | Sort-Object -CaseSensitive -Unique)
Assert-True (($EvidenceFixtures -join "`n") -ceq ($CanonicalEvidenceFixtures -join "`n")) "phase3b0_evidence_manifest_fixture_order_mismatch"

$ReadyFixtureBytes = [System.IO.File]::ReadAllBytes($ReadyFixturePath)
Assert-True ($ReadyFixtureBytes.Length -eq $CanonicalReadyByteLength) "phase3b0_ready_fixture_length_mismatch"
Assert-True ((Get-Sha256Hex $ReadyFixtureBytes) -ceq $CanonicalReadySha256) "phase3b0_ready_fixture_sha256_mismatch"
$ReadyFixtureText = [System.Text.UTF8Encoding]::new($false, $true).GetString($ReadyFixtureBytes)
Assert-CanonicalReadyAssessment $ReadyFixtureText $SchemaPath

$ArbitraryReady = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$ArbitraryReady.assessmentUid = "3b000000-0000-4000-8000-000000000027"
$ArbitraryReadyText = $ArbitraryReady | ConvertTo-Json -Depth 100
Assert-True (Test-ClosureJson $ArbitraryReadyText $SchemaPath) "phase3b0_schema_cannot_represent_distinct_assessment_identity"
Assert-True (-not (Test-CanonicalReadyAssessment $ArbitraryReadyText $SchemaPath)) "phase3b0_arbitrary_ready_assessment_accepted"

$MuseumCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$MuseumCandidate.target.museumAllowed = $true
Assert-True (-not (Test-ClosureJson ($MuseumCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_museum_candidate_accepted"

$FallbackCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$FallbackCandidate.target.fallbackPolicyCode = "latest_manager"
Assert-True (-not (Test-ClosureJson ($FallbackCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_fallback_candidate_accepted"

$StaticCountCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$StaticCountCandidate.staticClosure.byteIdenticalRequiredStaticEntryCount = 6
Assert-True (-not (Test-ClosureJson ($StaticCountCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_partial_static_entry_equivalence_accepted"

$BehaviorCountCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$BehaviorCountCandidate.behaviorGraph.exactEquivalentSeasonMonsterSkillRowCount = 14
Assert-True (-not (Test-ClosureJson ($BehaviorCountCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_partial_behavior_row_equivalence_accepted"

$LinearPatternCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$LinearPatternCandidate.behaviorGraph.fixedLinearOrderClaimed = $true
Assert-True (-not (Test-ClosureJson ($LinearPatternCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_fixed_linear_pattern_claim_accepted"

$InactiveTimingCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$InactiveTimingCandidate.timingClosure.unresolvedRuntimeCallbackActiveSkillCount = 6
Assert-True (-not (Test-ClosureJson ($InactiveTimingCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_inactive_skill_counted_as_active_timing_gap"

$RouteCountCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$RouteCountCandidate.routeAudit.latestManagerFallbackPathCount = 8
Assert-True (-not (Test-ClosureJson ($RouteCountCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_partial_route_audit_accepted"

$ObservationCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$ObservationCandidate.observations[2].sha256 = "9399a9f51862ddb65660e740b44a2b1e7ce177a39373d218589d9ede3163379c"
Assert-True (-not (Test-ClosureJson ($ObservationCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_stale_challenge_catalog_observation_accepted"

$TargetPackageCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$TargetPackageCandidate.observations[13].sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-ClosureJson ($TargetPackageCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_tampered_target_package_observation_accepted"

$ManifestCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$ManifestCandidate.canonicalManifest.sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
Assert-True (-not (Test-ClosureJson ($ManifestCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_tampered_manifest_accepted"

$ExtraPropertyCandidate = $ReadyFixtureText | ConvertFrom-Json -Depth 100
$ExtraPropertyCandidate | Add-Member -NotePropertyName "sourcePath" -NotePropertyValue "synthetic"
Assert-True (-not (Test-ClosureJson ($ExtraPropertyCandidate | ConvertTo-Json -Depth 100) $SchemaPath)) "phase3b0_source_path_property_accepted"

$DuplicatePropertyCandidate = $ReadyFixtureText.Replace(
    '"schemaVersion": 1,',
    '"schemaVersion": 1,' + "`n  " + '"schemaVersion": 1,')
Assert-True (-not (Test-CanonicalReadyAssessment $DuplicatePropertyCandidate $SchemaPath)) "phase3b0_duplicate_property_assessment_accepted"

Assert-RepositoryReadyAssessmentInventory `
    $RepositoryRoot `
    $SchemaPath `
    $CanonicalReadyRelativePath `
    $CanonicalReadyByteLength `
    $CanonicalReadySha256

$mode = if ($ContractOnly) { "contract-only" } else { "full baseline and contract" }
Write-Output "Phase 3B-0 $mode verification passed; static closure is exact, its historical next step was the classic selected-manager patch, and absolute timing analysis remains blocked on native scheduler rebinding."
