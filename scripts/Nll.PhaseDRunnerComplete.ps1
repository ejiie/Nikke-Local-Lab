# Fixed completion implementation; optional observations never grant cleanup/gameplay success.
function Invoke-PhaseDRunnerComplete {
    param([object]$Specification,
        [ValidateSet('startup_only','server_selection','catalogue_path','lobby','solo_raid_menu',
            'season26_challenge_squad','season26_challenge_battle','season26_practice_squad','season26_practice_battle','battle_result')]
        [string]$ObservedStageCode = 'startup_only',
        [ValidateSet('success','system_error','operator_abort','client_exit')][string]$OutcomeCode = 'client_exit')
    Assert-PhaseDRunnerSpecification $Specification
    $ServerRoot = Join-Path $Specification.launchRoot 'runtime'
    $EvidenceRoot = Join-Path $Specification.launchRoot 'evidence'
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    
    function Assert-True {
        param([bool]$Condition, [string]$FailureCode)
        if (-not $Condition) { throw $FailureCode }
    }
    
    function Get-Sha256Hex {
        param([string]$Path)
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    
    function Get-PinnedProcess {
        param([int]$ProcessId, [string]$ExpectedName)
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.ProcessName -cne $ExpectedName) {
            return $null
        }
        $process
    }

    function Write-AtomicUtf8NoBom {
        param([string]$Path, [string]$Text)
        $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText(
            $temporary, $Text, [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    
    function Protect-ServerLog {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0 }
        $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
        $pattern = '(?m)^(?<prefix>\s*authtoken:\s*)\S+\s*$'
        $matchCount = [regex]::Matches($text, $pattern).Count
        if ($matchCount -gt 0) {
            $protected = [regex]::Replace(
                $text, $pattern, '${prefix}[REDACTED]'
            )
            Write-AtomicUtf8NoBom $Path $protected
        }
        return $matchCount
    }
    
    function Get-TrialRecordMetrics {
        param([string]$Path)
        $database = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $levels = @(
            foreach ($user in @($database.Users)) {
                if ($null -eq $user.SoloRaidData) { continue }
                foreach ($manager in @($user.SoloRaidData.PSObject.Properties)) {
                    foreach ($level in @($manager.Value.SoloRaidLevels)) {
                        if ([int]$level.Type -eq 2 -and [int]$level.RaidLevel -eq 8) {
                            $level
                        }
                    }
                }
            }
        )
        $raidJoinCount = 0L
        $recordCount = 0L
        $totalDamage = 0L
        foreach ($level in $levels) {
            $raidJoinCount += [long]$level.RaidJoinCount
            $recordCount += [long]@($level.Logs).Count
            $totalDamage += [long]$level.TotalDamage
        }
        [ordered]@{
            levelCount = $levels.Count
            raidJoinCount = $raidJoinCount
            recordCount = $recordCount
            totalDamage = $totalDamage
        }
    }
    
    $expectedDbSha256 = $Specification.runtimeDbSha256
    $hostPins = Get-PhaseDRunnerHostPins
    $expectedBaseHostsSha256 = $hostPins.base
    $expectedAppliedHostsSha256 = $hostPins.applied
    $extensionFirewallGroup = 'NLL Phase3B2 Epinel Minimal Extension'
    
    Assert-PhaseDRunnerHost -Phase completion
    
    $activePointerPath = Join-Path $EvidenceRoot 'active-run.pointer.json'
    Assert-True (Test-Path -LiteralPath $activePointerPath -PathType Leaf) `
        'phase3b2_epinel_minimal_completion_pointer_missing'
    $pointer = Get-Content -LiteralPath $activePointerPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True (
        $pointer.contractId -ceq `
            'nll/phase3b2-epinel-minimal-active-run-pointer/v1' -and
        [Guid]::Parse([string]$pointer.assessmentUid) -ne [Guid]::Empty
    ) 'phase3b2_epinel_minimal_completion_pointer_invalid'
    
    $runRoot = [string]$pointer.runRoot
    $runStartPath = Join-Path $runRoot 'run-start.receipt.json'
    $completionPath = Join-Path $runRoot 'completion.receipt.json'
    $dbBeforePath = Join-Path $runRoot 'db.before.bin'
    $hostsBeforePath = Join-Path $runRoot 'hosts.before.bin'
    $stdoutPath = Join-Path $runRoot 'server.stdout.log'
    $stderrPath = Join-Path $runRoot 'server.stderr.log'
    $dbPath = Join-Path $ServerRoot 'db.json'
    $hostsPath = Get-PhaseDRunnerHostsPath
    
    $runStart = Get-Content -LiteralPath $runStartPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True (
        $runStart.contractId -ceq
            'nll/phase3b2-epinel-solo-raid-ranking-prefix-start/v9' -and
        [string]$runStart.runIntentCode -in @('challenge', 'practice') -and
        -not $runStart.historicalReceiptBindingApplied -and
        -not $runStart.selfHashBindingApplied
    ) 'phase3b2_solo_raid_trial_practice_completion_start_shape_invalid'
    
    Assert-True (
        @($runStartPath, $dbBeforePath, $hostsBeforePath |
            Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
        ).Count -eq 0 -and
        -not (Test-Path -LiteralPath $completionPath) -and
        (Get-Sha256Hex $runStartPath) -ceq `
            ([string]$pointer.runStartReceiptSha256) -and
        (Get-Sha256Hex $dbBeforePath) -ceq $expectedDbSha256 -and
        (Get-Sha256Hex $hostsBeforePath) -ceq $expectedBaseHostsSha256 -and
        (Get-Sha256Hex $hostsPath) -ceq $expectedAppliedHostsSha256
    ) 'phase3b2_epinel_minimal_completion_evidence_or_hosts_invalid'
    
    $clientId = [int]$pointer.clientProcessId
    Assert-True ($null -eq (Get-PinnedProcess $clientId 'nikke')) `
        'phase3b2_epinel_minimal_completion_client_still_running_close_game_first'
    
    $bootstrapForcedStop = $false
    $serverForcedStop = $false

    Invoke-PhaseDRunnerCapture -Specification $Specification -SourceDatabasePath $dbPath
    
    $redactedServerLogMatchCount = Protect-ServerLog $stdoutPath
    
    $appLogRoot = Join-Path $ServerRoot 'logs'
    $markerEvidencePath = Join-Path $runRoot 'regroup.observations.json'
    $appLogPaths = @(Get-ChildItem -LiteralPath $appLogRoot -Filter 'app-*.log' `
        -File -ErrorAction SilentlyContinue)
    $debugLineCount = 0
    $rawPayloadPatternCount = 0
    if ($appLogPaths.Count -gt 0) {
        $appLogText = (($appLogPaths | ForEach-Object {
                    Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
                }) -join "`n")
        $debugLineCount = [regex]::Matches($appLogText, '(?m)\sDEBUG\s').Count
        $rawPayloadPatternCount = [regex]::Matches(
            $appLogText,
            '(?i)Reading ReqSetSoloRaidTrialDamage|antiCheatBattleData|"characters"'
        ).Count
        $markerPattern =
            'NLL_BATTLE_RESULT_OBSERVATION/v1\s+' +
            'utc=(?<utc>\S+)\s+sequence=(?<sequence>\d+)\s+' +
            'route=(?<route>\S+)\s+battleResult=(?<battleResult>-?\d+)'
        $observations = @(
            foreach ($match in [regex]::Matches($appLogText, $markerPattern)) {
                [ordered]@{
                    utc = [string]$match.Groups['utc'].Value
                    sequence = [long]$match.Groups['sequence'].Value
                    route = [string]$match.Groups['route'].Value
                    battleResult = [int]$match.Groups['battleResult'].Value
                }
            }
        )
        $scoreObservations = @()
        $setDamageScorePattern =
            'NLL_SOLO_RAID_SCORE_RESPONSE/v1\s+' +
            'utc=(?<utc>\S+)\s+sequence=(?<sequence>\d+)\s+' +
            'route=soloraid_trial_setdamage\s+' +
            'battleResult=(?<battleResult>-?\d+)\s+' +
            'infoDamage=(?<infoDamage>\d+)\s+' +
            'userDamage=(?<userDamage>\d+)\s+' +
            'totalUserCount=(?<totalUserCount>\d+)'
        foreach ($match in [regex]::Matches($appLogText, $setDamageScorePattern)) {
            $scoreObservations += [ordered]@{
                utc = [string]$match.Groups['utc'].Value
                sequence = [long]$match.Groups['sequence'].Value
                route = 'soloraid_trial_setdamage'
                battleResult = [int]$match.Groups['battleResult'].Value
                infoDamage = [long]$match.Groups['infoDamage'].Value
                userDamage = [long]$match.Groups['userDamage'].Value
                totalUserCount = [int]$match.Groups['totalUserCount'].Value
            }
        }
        $getInfoScorePattern =
            'NLL_SOLO_RAID_SCORE_RESPONSE/v1\s+' +
            'utc=(?<utc>\S+)\s+route=soloraid_get\s+' +
            'trialDamage=(?<trialDamage>\d+)'
        foreach ($match in [regex]::Matches($appLogText, $getInfoScorePattern)) {
            $scoreObservations += [ordered]@{
                utc = [string]$match.Groups['utc'].Value
                sequence = 0L
                route = 'soloraid_get'
                trialDamage = [long]$match.Groups['trialDamage'].Value
            }
        }
        $rankingScorePattern =
            'NLL_SOLO_RAID_SCORE_RESPONSE/v1\s+' +
            'utc=(?<utc>\S+)\s+route=soloraid_getranking\s+' +
            'rankingDamage=(?<rankingDamage>\d+)\s+' +
            'userDamage=(?<userDamage>\d+)\s+' +
            'totalUserCount=(?<totalUserCount>\d+)'
        foreach ($match in [regex]::Matches($appLogText, $rankingScorePattern)) {
            $scoreObservations += [ordered]@{
                utc = [string]$match.Groups['utc'].Value
                sequence = 0L
                route = 'soloraid_getranking'
                rankingDamage = [long]$match.Groups['rankingDamage'].Value
                userDamage = [long]$match.Groups['userDamage'].Value
                totalUserCount = [int]$match.Groups['totalUserCount'].Value
            }
        }
        $rankerSquadScorePattern =
            'NLL_SOLO_RAID_SCORE_RESPONSE/v1\s+' +
            'utc=(?<utc>\S+)\s+route=soloraid_getrankersquad\s+' +
            'logCount=(?<logCount>\d+)\s+' +
            'logDamageSum=(?<logDamageSum>\d+)'
        foreach ($match in [regex]::Matches($appLogText, $rankerSquadScorePattern)) {
            $scoreObservations += [ordered]@{
                utc = [string]$match.Groups['utc'].Value
                sequence = 0L
                route = 'soloraid_getrankersquad'
                logCount = [int]$match.Groups['logCount'].Value
                logDamageSum = [long]$match.Groups['logDamageSum'].Value
            }
        }
        $damageSourceObservations = @()
        $damageSourcePattern =
            'NLL_SOLO_RAID_DAMAGE_SOURCE_OBSERVATION/v1\s+' +
            'utc=(?<utc>\S+)\s+sequence=(?<sequence>\d+)\s+' +
            'route=soloraid_trial_setdamage\s+' +
            'battleResult=(?<battleResult>-?\d+)\s+' +
            'requestDamage=(?<requestDamage>\d+)\s+' +
            'characterCount=(?<characterCount>\d+)\s+' +
            'characterAttackDamage=(?<characterAttackDamage>\d+)\s+' +
            'characterAttackActualDamage=(?<characterAttackActualDamage>\d+)\s+' +
            'characterSkillDamage=(?<characterSkillDamage>\d+)\s+' +
            'characterSkillActualDamage=(?<characterSkillActualDamage>\d+)\s+' +
            'characterStatFunctionDamage=(?<characterStatFunctionDamage>\d+)\s+' +
            'characterStatFunctionActualDamage=(?<characterStatFunctionActualDamage>\d+)\s+' +
            'monsterCount=(?<monsterCount>\d+)\s+' +
            'monsterHpDamageReceived=(?<monsterHpDamageReceived>\d+)\s+' +
            'monsterHpActualDamageReceived=(?<monsterHpActualDamageReceived>\d+)\s+' +
            'monsterPartsDamageReceived=(?<monsterPartsDamageReceived>\d+)\s+' +
            'monsterProjectileDamageReceived=(?<monsterProjectileDamageReceived>\d+)\s+' +
            'reportDataByteLength=(?<reportDataByteLength>\d+)'
        foreach ($match in [regex]::Matches($appLogText, $damageSourcePattern)) {
            $damageSourceObservations += [ordered]@{
                utc = [string]$match.Groups['utc'].Value
                sequence = [long]$match.Groups['sequence'].Value
                battleResult = [int]$match.Groups['battleResult'].Value
                requestDamage = [long]$match.Groups['requestDamage'].Value
                characterCount = [int]$match.Groups['characterCount'].Value
                characterAttackDamage = [long]$match.Groups['characterAttackDamage'].Value
                characterAttackActualDamage = [long]$match.Groups['characterAttackActualDamage'].Value
                characterSkillDamage = [long]$match.Groups['characterSkillDamage'].Value
                characterSkillActualDamage = [long]$match.Groups['characterSkillActualDamage'].Value
                characterStatFunctionDamage = [long]$match.Groups['characterStatFunctionDamage'].Value
                characterStatFunctionActualDamage = [long]$match.Groups['characterStatFunctionActualDamage'].Value
                monsterCount = [int]$match.Groups['monsterCount'].Value
                monsterHpDamageReceived = [long]$match.Groups['monsterHpDamageReceived'].Value
                monsterHpActualDamageReceived = [long]$match.Groups['monsterHpActualDamageReceived'].Value
                monsterPartsDamageReceived = [long]$match.Groups['monsterPartsDamageReceived'].Value
                monsterProjectileDamageReceived = [long]$match.Groups['monsterProjectileDamageReceived'].Value
                reportDataByteLength = [int]$match.Groups['reportDataByteLength'].Value
            }
        }
        $markerEvidence = [ordered]@{
            schemaVersion = 1
            contractId =
                'nll/phase3b2-epinel-solo-raid-ranking-prefix-marker-evidence/v9'
            assessmentUid = [string]$pointer.assessmentUid
            observationCount = $observations.Count
            observations = $observations
            scoreObservationCount = $scoreObservations.Count
            scoreObservations = $scoreObservations
            damageSourceObservationCount = $damageSourceObservations.Count
            damageSourceObservations = $damageSourceObservations
            rawRequestPayloadPersisted = $false
        }
        Write-AtomicUtf8NoBom $markerEvidencePath `
            (($markerEvidence | ConvertTo-Json -Depth 6) + "`n")
    }
    elseif (Test-Path -LiteralPath $markerEvidencePath -PathType Leaf) {
        $markerEvidence = Get-Content -LiteralPath $markerEvidencePath -Raw `
            -Encoding UTF8 | ConvertFrom-Json
        Assert-True (
            $markerEvidence.contractId -ceq
                'nll/phase3b2-epinel-solo-raid-ranking-prefix-marker-evidence/v9' -and
            [string]$markerEvidence.assessmentUid -ceq
                [string]$pointer.assessmentUid -and
            -not $markerEvidence.rawRequestPayloadPersisted
        ) 'phase3b2_ranking_prefix_v9_existing_marker_invalid'
        $observations = @($markerEvidence.observations)
        $scoreObservations = @($markerEvidence.scoreObservations)
        $damageSourceObservations = @($markerEvidence.damageSourceObservations)
    }
    else {
        # No application log and no previous observation receipt means unobserved,
        # not failed cleanup or successful gameplay verification. Never enable raw logging.
        $observations = @()
        $scoreObservations = @()
        $damageSourceObservations = @()
        $markerEvidence = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-epinel-solo-raid-ranking-prefix-marker-evidence/v9'
            assessmentUid = [string]$pointer.assessmentUid
            observationCount = 0; observations = @()
            scoreObservationCount = 0; scoreObservations = @()
            damageSourceObservationCount = 0; damageSourceObservations = @()
            diagnosticObservationStatus = 'not_observed'
            rawRequestPayloadPersisted = $false
        }
        Write-AtomicUtf8NoBom $markerEvidencePath `
            (($markerEvidence | ConvertTo-Json -Depth 6) + "`n")
    }
    $markerEvidenceSha256 = Get-Sha256Hex $markerEvidencePath
    $markerEvidenceSafe = $debugLineCount -eq 0 -and
        $rawPayloadPatternCount -eq 0
    foreach ($appLogPath in $appLogPaths) {
        Remove-Item -LiteralPath $appLogPath.FullName -Force
    }
    $runtimeAppLogsRemoved = @(
        Get-ChildItem -LiteralPath $appLogRoot -Filter 'app-*.log' -File `
            -ErrorAction SilentlyContinue
    ).Count -eq 0
    
    $trialMetricsBefore = Get-TrialRecordMetrics $dbBeforePath
    $trialMetricsAfter = Get-TrialRecordMetrics $dbPath
    $observedCompletedCount = @($observations | Where-Object {
            [int]$_.battleResult -eq 1
        }).Count
    $observedRegroupCount = @($observations | Where-Object {
            [int]$_.battleResult -eq 6
        }).Count
    $observedLegacyRetryCount = @($observations | Where-Object {
            [int]$_.battleResult -eq 4
        }).Count
    $unsupportedBattleResultCount = @($observations | Where-Object {
            [int]$_.battleResult -notin @(1, 4, 6)
        }).Count
    $battleResultClassificationValid = $observations.Count -gt 0 -and $unsupportedBattleResultCount -eq 0
    $regroupNonConsumptionVerified = $markerEvidenceSafe -and
        $observedRegroupCount -gt 0 -and
        $unsupportedBattleResultCount -eq 0 -and
        [long]$trialMetricsAfter.raidJoinCount -eq
            [long]$trialMetricsBefore.raidJoinCount -and
        [long]$trialMetricsAfter.recordCount -eq
            [long]$trialMetricsBefore.recordCount -and
        [long]$trialMetricsAfter.totalDamage -eq
            [long]$trialMetricsBefore.totalDamage
    
    $authoritativeScore = [long]$trialMetricsAfter.totalDamage
    $rankingWirePrefix = 1130781186L
    Assert-True (
        $authoritativeScore -le ([long]::MaxValue - $rankingWirePrefix)
    ) 'phase3b2_ranking_prefix_v9_wire_overflow'
    $expectedRankingWireScore = $authoritativeScore + $rankingWirePrefix
    $completedScoreResponses = @($scoreObservations | Where-Object {
            [string]$_.route -ceq 'soloraid_trial_setdamage' -and
            [int]$_.battleResult -eq 1
        } | Sort-Object { [long]$_.sequence })
    $finalCompletedScoreResponse = if ($completedScoreResponses.Count -gt 0) {
        $completedScoreResponses[-1]
    } else { $null }
    $setDamageScoreConsistent = $null -ne $finalCompletedScoreResponse -and
        $authoritativeScore -gt 0 -and
        [long]$finalCompletedScoreResponse.infoDamage -eq $authoritativeScore -and
        [long]$finalCompletedScoreResponse.userDamage -eq $expectedRankingWireScore -and
        [int]$finalCompletedScoreResponse.totalUserCount -eq 1
    function ConvertTo-ScoreObservationUtc {
        param([object]$Value)
        if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
        if ($Value -is [DateTime]) { return [DateTimeOffset]$Value }
        return [DateTimeOffset]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    $finalCompletedScoreUtc = if ($null -ne $finalCompletedScoreResponse) {
        ConvertTo-ScoreObservationUtc $finalCompletedScoreResponse.utc
    } else { [DateTimeOffset]::MinValue }
    $infoScoreResponses = @($scoreObservations | Where-Object {
            [string]$_.route -ceq 'soloraid_get' -and
            (ConvertTo-ScoreObservationUtc $_.utc) -ge $finalCompletedScoreUtc
        })
    $infoScoreConsistent = $infoScoreResponses.Count -gt 0 -and
        @($infoScoreResponses | Where-Object {
            [long]$_.trialDamage -ne $expectedRankingWireScore
        }).Count -eq 0
    $rankingScoreResponses = @($scoreObservations | Where-Object {
            [string]$_.route -ceq 'soloraid_getranking' -and
            (ConvertTo-ScoreObservationUtc $_.utc) -ge $finalCompletedScoreUtc
        })
    $rankingScoreConsistent = $rankingScoreResponses.Count -gt 0 -and
        @($rankingScoreResponses | Where-Object {
            [long]$_.rankingDamage -ne $expectedRankingWireScore -or
            [long]$_.userDamage -ne $expectedRankingWireScore -or
            [int]$_.totalUserCount -ne 1
        }).Count -eq 0
    $rankerSquadScoreResponses = @($scoreObservations | Where-Object {
            [string]$_.route -ceq 'soloraid_getrankersquad' -and
            (ConvertTo-ScoreObservationUtc $_.utc) -ge $finalCompletedScoreUtc
        })
    $rankerSquadScoreConsistent = $rankerSquadScoreResponses.Count -gt 0 -and
        @($rankerSquadScoreResponses | Where-Object {
            [int]$_.logCount -ne 5 -or
            [long]$_.logDamageSum -ne $authoritativeScore
        }).Count -eq 0
    $scoreProjectionRequired = $OutcomeCode -ceq 'success' -and
        $ObservedStageCode -ceq 'battle_result'
    $scoreProjectionVerified = $markerEvidenceSafe -and
        $setDamageScoreConsistent -and $infoScoreConsistent -and
        $rankingScoreConsistent -and $rankerSquadScoreConsistent
    if ($scoreProjectionRequired) {
        Assert-True $scoreProjectionVerified `
            'phase3b2_ranking_prefix_v9_projection_verification_failed'
    }
    function Get-DamageSourceSum {
        param([object[]]$Rows, [string]$Property)
        [long]$sum = 0
        foreach ($row in @($Rows)) {
            if ($row -is [Collections.IDictionary]) {
                Assert-True $row.Contains($Property) `
                    ('phase3b2_ranking_prefix_v9_property_missing:' +
                        $Property)
                $value = $row[$Property]
            }
            else {
                $propertyValue = $row.PSObject.Properties[$Property]
                Assert-True ($null -ne $propertyValue) `
                    ('phase3b2_ranking_prefix_v9_property_missing:' +
                        $Property)
                $value = $propertyValue.Value
            }
            $sum += [long]$value
        }
        return $sum
    }
    $completedDamageSources = @($damageSourceObservations | Where-Object {
            [int]$_.battleResult -eq 1
        } | Sort-Object { [long]$_.sequence })
    $damageSourceSums = [ordered]@{
        requestDamage = Get-DamageSourceSum $completedDamageSources 'requestDamage'
        characterAttackDamage = Get-DamageSourceSum $completedDamageSources 'characterAttackDamage'
        characterAttackActualDamage = Get-DamageSourceSum $completedDamageSources 'characterAttackActualDamage'
        characterSkillDamage = Get-DamageSourceSum $completedDamageSources 'characterSkillDamage'
        characterSkillActualDamage = Get-DamageSourceSum $completedDamageSources 'characterSkillActualDamage'
        characterStatFunctionDamage = Get-DamageSourceSum $completedDamageSources 'characterStatFunctionDamage'
        characterStatFunctionActualDamage = Get-DamageSourceSum $completedDamageSources 'characterStatFunctionActualDamage'
        monsterHpDamageReceived = Get-DamageSourceSum $completedDamageSources 'monsterHpDamageReceived'
        monsterHpActualDamageReceived = Get-DamageSourceSum $completedDamageSources 'monsterHpActualDamageReceived'
        monsterPartsDamageReceived = Get-DamageSourceSum $completedDamageSources 'monsterPartsDamageReceived'
        monsterProjectileDamageReceived = Get-DamageSourceSum $completedDamageSources 'monsterProjectileDamageReceived'
    }
    $damageSourceObservationComplete = $completedDamageSources.Count -eq 5 -and
        [long]$damageSourceSums.requestDamage -eq $authoritativeScore
    $damageSourceObservationRequired = $OutcomeCode -ceq 'success' -and
        $ObservedStageCode -ceq 'battle_result'
    if ($damageSourceObservationRequired) {
        Assert-True $damageSourceObservationComplete `
            'phase3b2_ranking_prefix_v9_observation_incomplete'
    }
    $databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length
    $databaseAfterSha256 = Get-Sha256Hex $dbPath
    $sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        ForEach-Object { Join-Path $ServerRoot $_ })
    $sqliteObservedCount = @($sqlitePaths | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    }).Count
    
    [IO.File]::WriteAllBytes($dbPath, [IO.File]::ReadAllBytes($dbBeforePath))
    foreach ($path in $sqlitePaths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    [IO.File]::WriteAllBytes(
        $hostsPath, [IO.File]::ReadAllBytes($hostsBeforePath)
    )
    Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    
    Assert-True (
        (Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and
        @($sqlitePaths | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0 -and
        (Get-Sha256Hex $hostsPath) -ceq $expectedBaseHostsSha256 -and
        @(Get-NetFirewallRule -Group $extensionFirewallGroup `
            -ErrorAction SilentlyContinue).Count -eq 0
    ) 'phase3b2_epinel_minimal_completion_rollback_verification_failed'
    
    $stdoutLength = if (Test-Path -LiteralPath $stdoutPath) {
        (Get-Item -LiteralPath $stdoutPath).Length
    } else { 0L }
    $stdoutSha256 = if ($stdoutLength -ge 0 -and
        (Test-Path -LiteralPath $stdoutPath)) {
        Get-Sha256Hex $stdoutPath
    } else { '' }
    $stderrLength = if (Test-Path -LiteralPath $stderrPath) {
        (Get-Item -LiteralPath $stderrPath).Length
    } else { 0L }
    $stderrSha256 = if ($stderrLength -ge 0 -and
        (Test-Path -LiteralPath $stderrPath)) {
        Get-Sha256Hex $stderrPath
    } else { '' }
    
    $playerLogPath = Join-Path $env:USERPROFILE `
        'AppData\LocalLow\com.proximabeta\NIKKE\Player.log'
    $playerLogPresent = Test-Path -LiteralPath $playerLogPath -PathType Leaf
    $playerLogLength = if ($playerLogPresent) {
        (Get-Item -LiteralPath $playerLogPath).Length
    } else { 0L }
    $playerLogSha256 = if ($playerLogPresent) {
        Get-Sha256Hex $playerLogPath
    } else { '' }
    
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-solo-raid-ranking-prefix-completion/v9'
        completedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        assessmentUid = [string]$pointer.assessmentUid
        runStartReceiptSha256 = [string]$pointer.runStartReceiptSha256
        runIntentCode = [string]$runStart.runIntentCode
        observedStageCode = $ObservedStageCode
        outcomeCode = $OutcomeCode
        historicalReceiptBindingApplied = $false
        selfHashBindingApplied = $false
        databaseAfterByteLength = $databaseAfterByteLength
        databaseAfterSha256 = $databaseAfterSha256
        databaseRestored = $true
        sqliteRuntimeObservedMemberCount = $sqliteObservedCount
        sqliteRuntimeRemoved = $true
        hostsRestored = $true
        extensionFirewallRemoved = $true
        clientClosedByOperator = $true
        bootstrapForcedStop = $bootstrapForcedStop
        serverForcedStop = $serverForcedStop
        serverStdoutByteLength = $stdoutLength
        serverStdoutSha256 = $stdoutSha256
        redactedServerLogMatchCount = $redactedServerLogMatchCount
        rawSensitiveServerLogPersisted = $false
        diagnosticObservationStatus = if ($observations.Count -gt 0 -or
            $scoreObservations.Count -gt 0 -or $damageSourceObservations.Count -gt 0) {
            'observed'
        } else { 'not_observed' }
        markerOnlyEvidencePersisted = $true
        markerEvidenceSha256 = $markerEvidenceSha256
        regroupObservationCount = $observations.Count
        observedCompletedResultCount = $observedCompletedCount
        observedRegroupResultCount = $observedRegroupCount
        observedLegacyRetryResultCount = $observedLegacyRetryCount
        unsupportedBattleResultCount = $unsupportedBattleResultCount
        battleResultClassificationValid = $battleResultClassificationValid
        battleResultPolicyCode = 'completed_1_consuming_retry_4_or_regroup_6_nonconsuming'
        observedBattleResults = @($observations | ForEach-Object {
                [int]$_.battleResult
            })
        debugRuntimeLogLineCount = $debugLineCount
        rawRequestPayloadPatternCount = $rawPayloadPatternCount
        rawRequestPayloadPersistedAfterCompletion = $false
        runtimeAppLogsRemoved = $runtimeAppLogsRemoved
        trialMetricsBefore = $trialMetricsBefore
        trialMetricsAfter = $trialMetricsAfter
        regroupNonConsumptionVerified = $regroupNonConsumptionVerified
        scoreObservationCount = $scoreObservations.Count
        completedScoreResponseCount = $completedScoreResponses.Count
        authoritativeFiveDeckScore = $authoritativeScore
        rankingWirePrefix = $rankingWirePrefix
        expectedRankingWireScore = $expectedRankingWireScore
        finalSetDamageInfoScore = if ($null -ne $finalCompletedScoreResponse) {
            [long]$finalCompletedScoreResponse.infoDamage
        } else { 0L }
        finalSetDamageUserScore = if ($null -ne $finalCompletedScoreResponse) {
            [long]$finalCompletedScoreResponse.userDamage
        } else { 0L }
        finalSetDamageTotalUserCount = if ($null -ne $finalCompletedScoreResponse) {
            [int]$finalCompletedScoreResponse.totalUserCount
        } else { 0 }
        getInfoObservationCount = $infoScoreResponses.Count
        getRankingObservationCount = $rankingScoreResponses.Count
        getRankerSquadObservationCount = $rankerSquadScoreResponses.Count
        setDamageScoreConsistent = $setDamageScoreConsistent
        infoScoreConsistent = $infoScoreConsistent
        rankingScoreConsistent = $rankingScoreConsistent
        rankerSquadScoreConsistent = $rankerSquadScoreConsistent
        scoreProjectionRequired = $scoreProjectionRequired
        scoreProjectionVerified = $scoreProjectionVerified
        damageSourceObservationCount = $damageSourceObservations.Count
        completedDamageSourceObservationCount = $completedDamageSources.Count
        damageSourceObservationRequired = $damageSourceObservationRequired
        damageSourceObservationComplete = $damageSourceObservationComplete
        damageSourceSums = $damageSourceSums
        rawDamageRequestPayloadPersisted = $false
        scoreAuthorityCode = 'best_completed_challenge_five_deck_total_damage'
        serverStderrByteLength = $stderrLength
        serverStderrSha256 = $stderrSha256
        playerLogPresent = $playerLogPresent
        playerLogByteLength = $playerLogLength
        playerLogSha256 = $playerLogSha256
        rawPlayerLogCopied = $false
        officialLauncherExecutionStarted = $false
        officialOutboundFallbackUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $true
        clientExecutionStarted = $true
        runtimeColdAfterCompletion = $true
        nextStepCode = if ($OutcomeCode -ne 'success') {
            'return_to_samsung_classify_without_automatic_retry'
        } elseif ([string]$runStart.runIntentCode -ceq 'challenge' -and
            $ObservedStageCode -in @(
                'season26_challenge_squad',
                'season26_challenge_battle',
                'battle_result'
            )) {
            'return_to_samsung_then_run_practice_validation'
        } elseif ([string]$runStart.runIntentCode -ceq 'practice' -and
            $ObservedStageCode -in @(
                'season26_practice_squad',
                'season26_practice_battle',
                'battle_result'
            )) {
            'return_to_samsung_and_seal_actual_play_evidence'
        } else {
            'return_to_samsung_classify_without_automatic_retry'
        }}
    Write-AtomicUtf8NoBom $completionPath `
        (($receipt | ConvertTo-Json -Depth 6) + "`n")
    $archivedPointerPath = Join-Path $runRoot 'active-run.pointer.archived.json'
    Move-Item -LiteralPath $activePointerPath -Destination $archivedPointerPath
    
    $receipt | ConvertTo-Json -Depth 6
}
