. (Join-Path $PSScriptRoot 'Nll.PhaseDProcessIdentity.ps1')
function Invoke-PhaseDRunnerStart {
    param([object]$Specification)
    Assert-PhaseDRunnerSpecification $Specification
    $ServerRoot = Join-Path $Specification.launchRoot 'runtime'
    $EvidenceRoot = Join-Path $Specification.launchRoot 'evidence'
    $BootstrapRoot = $Specification.bootstrapRoot
    $BootstrapEvidenceLane = 'p2-client-start-v2'
    $DerivedSourceManifestSha256 = $Specification.derivedSourceManifestSha256
    $RunIntentCode = $Specification.runIntentCode
    # Historical opt-in HTTP diagnostic options are not inputs to Control Center.
    # Keep their receipt fields at the same not-requested values; never enable them.
    $RequiredLocalAssetUrl = ''; $RequiredLocalCatalogContractPath = ''; $RequiredLocalSausContractPath = ''
    $RequiredLocalCatalogContractSha256 = ''; $RequiredLocalSausContractSha256 = ''
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    Add-Type -AssemblyName System.Net.Http
    
    function Assert-True {
        param([bool]$Condition, [string]$FailureCode)
        if (-not $Condition) { throw $FailureCode }
    }
    
    function Get-Sha256Hex {
        param([string]$Path)
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    
    function Get-ByteArraySha256Hex {
        param([byte[]]$Bytes)
    
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try {
            return ($algorithm.ComputeHash($Bytes) | ForEach-Object {
                    $_.ToString('x2')
                }) -join ''
        }
        finally {
            $algorithm.Dispose()
        }
    }
    
    function Get-Crc32Unsigned {
        param([byte[]]$Bytes)
    
        [uint32]$crc = [uint32]::MaxValue
        foreach ($value in $Bytes) {
            $crc = $crc -bxor [uint32]$value
            for ($bit = 0; $bit -lt 8; $bit++) {
                if (($crc -band 1) -ne 0) {
                    $crc = ($crc -shr 1) -bxor [uint32]3988292384
                }
                else {
                    $crc = $crc -shr 1
                }
            }
        }
        return [uint32]($crc -bxor [uint32]::MaxValue)
    }
    
    function Write-AtomicUtf8NoBom {
        param([string]$Path, [string]$Text)
        $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText(
            $temporary, $Text, [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }
    
    function Write-AtomicUtf8Bom {
        param([string]$Path, [string]$Text)
        $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText(
            $temporary, $Text, [Text.UTF8Encoding]::new($true)
        )
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    }

    function Get-PinnedProcess {
        param([int]$ProcessId, [string]$ExpectedName)
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.ProcessName -cne $ExpectedName) {
            return $null
        }
        $process
    }

    $expectedServerExeSha256 = $Specification.serverExeSha256
    $expectedServerDllSha256 = $Specification.serverDllSha256
    $expectedParentServerDllSha256 = `
        'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
    $expectedParentExternalHead = `
        'aa01ad90b807be1c2ceffe958519cb529622d472'
    $expectedParentExternalTree = `
        'c324c11d32365b1524f266cba6bc014e89545204'
    $expectedDbSha256 = $Specification.runtimeDbSha256
    $hostPins = Get-PhaseDRunnerHostPins
    $expectedHostsSha256 = $hostPins.base
    $expectedAppliedHostsSha256 = $hostPins.applied
    $expectedBootstrapSha256 = $Specification.bootstrapSha256
    $extensionFirewallGroup = 'NLL Phase3B2 Epinel Minimal Extension'
    
    Assert-PhaseDRunnerHost -Phase start
    
    $contextPath = Get-PhaseDRunnerContextPath
    $serverPath = Join-Path $ServerRoot 'EpinelPS.exe'
    $serverDllPath = Join-Path $ServerRoot 'EpinelPS.dll'
    $dbPath = Join-Path $ServerRoot 'db.json'
    $bootstrapPath = Join-Path $BootstrapRoot `
        'artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
    $hostsPath = Get-PhaseDRunnerHostsPath
    $activePointerPath = Join-Path $EvidenceRoot 'active-run.pointer.json'
    
    Assert-True (
        @($contextPath, $serverPath, $serverDllPath, $dbPath,
            $bootstrapPath, $hostsPath | Where-Object {
                -not (Test-Path -LiteralPath $_ -PathType Leaf)
            }).Count -eq 0 -and
        -not (Test-Path -LiteralPath $activePointerPath) -and
        @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
            Where-Object { Test-Path -LiteralPath (Join-Path $ServerRoot $_) }
        ).Count -eq 0 -and
        $DerivedSourceManifestSha256 -cmatch '^[0-9a-f]{64}$'
    ) 'phase3b2_epinel_minimal_start_input_shape_invalid'
    Assert-True (
        (Get-Sha256Hex $serverPath) -ceq $expectedServerExeSha256 -and
        (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
        (Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and
        (Get-Sha256Hex $hostsPath) -ceq $expectedHostsSha256 -and
        (Get-Sha256Hex $bootstrapPath) -ceq $expectedBootstrapSha256
    ) 'phase3b2_epinel_minimal_start_digest_invalid'
    
    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True (
        $context.contractId -ceq
            'nll/phase3b2-synthetic-runtime-context/v1' -and
        [long]$context.accountId -gt 0 -and [long]$context.managerId -gt 0
    ) 'phase3b2_epinel_minimal_start_contract_invalid'
    $runtime = @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        NikkeLocalLab.Phase3B2.PhysicalBootstrap -ErrorAction SilentlyContinue)
    Assert-True ($runtime.Count -eq 0) `
        'phase3b2_epinel_minimal_start_runtime_not_cold'
    
    $assessmentUid = [Guid]::NewGuid().ToString('D')
    $runRoot = Join-Path $EvidenceRoot $assessmentUid
    $bootstrapRunRoot = Join-Path (Get-PhaseDRunnerBootstrapEvidenceRoot $BootstrapEvidenceLane) $assessmentUid
    Assert-True (
        -not (Test-Path -LiteralPath $runRoot) -and
        -not (Test-Path -LiteralPath $bootstrapRunRoot)
    ) 'phase3b2_epinel_minimal_start_assessment_collision'
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    
    $dbBeforePath = Join-Path $runRoot 'db.before.bin'
    $hostsBeforePath = Join-Path $runRoot 'hosts.before.bin'
    $stdoutPath = Join-Path $runRoot 'server.stdout.log'
    $stderrPath = Join-Path $runRoot 'server.stderr.log'
    $runStartPath = Join-Path $runRoot 'run-start.receipt.json'
    $runFailurePath = Join-Path $runRoot 'run-failure.receipt.json'
    $bootstrapStartPath = Join-Path $bootstrapRunRoot `
        'bootstrap-start.receipt.json'
    $bootstrapFailurePath = Join-Path $bootstrapRunRoot `
        'bootstrap-failure.receipt.json'

    $serverProcess = $null
    $bootstrapProcess = $null
    $clientProcessId = 0
    $requiredLocalAssetPreflightPerformed = $false
    $requiredLocalAssetLoopbackResolved = $false
    $requiredLocalAssetHttpStatusCode = 0
    $requiredLocalAssetObservedByteLength = 0L
    $requiredLocalAssetObservedSha256 = ''
    $requiredLocalCatalogPreflightPerformed = $false
    $requiredLocalCatalogBodyCount = 0
    $requiredLocalCatalogSignatureCount = 0
    $requiredLocalCatalogAllSqlite = $false
    $requiredLocalSausPreflightPerformed = $false
    $requiredLocalSausBodyCount = 0
    $requiredLocalSausSignatureCount = 0
    $requiredLocalSausBodyCrc32Matched = $false
    $stageCode = 'mutation_preparation'
    
    try {
        [IO.File]::WriteAllBytes($dbBeforePath, [IO.File]::ReadAllBytes($dbPath))
        [IO.File]::WriteAllBytes(
            $hostsBeforePath, [IO.File]::ReadAllBytes($hostsPath)
        )

        Assert-True (
            (Get-Sha256Hex $dbBeforePath) -ceq $expectedDbSha256 -and
            (Get-Sha256Hex $hostsBeforePath) -ceq $expectedHostsSha256
        ) 'phase3b2_epinel_minimal_start_backup_failed'
        # Publish rollback baseline BEFORE the first operational mutation.
        # Start failure cannot clean up its own Job; an outside owner does it.
        Write-AtomicUtf8NoBom $activePointerPath (([ordered]@{
            schemaVersion=1; contractId='nll/phase3b2-epinel-minimal-active-run-pointer/v1'
            assessmentUid=$assessmentUid; runRoot=$runRoot; serverProcessId=0; bootstrapProcessId=0; clientProcessId=0
            databaseBeforeSha256=(Get-Sha256Hex $dbBeforePath); hostsBeforeSha256=(Get-Sha256Hex $hostsBeforePath)
        } | ConvertTo-Json) + "`n")
    
        $hostsText = [Text.UTF8Encoding]::new($true, $true).GetString(
            [IO.File]::ReadAllBytes($hostsPath)
        ).TrimStart([char]0xFEFF)
        Assert-True (
            $hostsText.IndexOf(
                'global-match.nikke-kr.com',
                [StringComparison]::OrdinalIgnoreCase
            ) -lt 0 -and
            ([regex]::Matches(
                $hostsText,
                '(?m)^# end NLL Phase3B2 Physical entries\r?$'
            )).Count -eq 1
        ) 'phase3b2_epinel_minimal_start_hosts_precondition_invalid'
        $hostsAppliedText = $hostsText.Replace(
            '# end NLL Phase3B2 Physical entries',
            "127.0.0.1 global-match.nikke-kr.com`r`n" +
            '# end NLL Phase3B2 Physical entries'
        )
        Write-AtomicUtf8Bom $hostsPath $hostsAppliedText

        Assert-True ((Get-Sha256Hex $hostsPath) -ceq $expectedAppliedHostsSha256) `
            'phase3b2_epinel_minimal_start_hosts_apply_failed'
    
        if ($null -ne $Specification.executionFx) {
            $stageCode = 'native_fx_apply'
            Write-PhaseDProgress $Specification.launchRoot 'fx_apply'
            $runnerManifest = Join-Path $Specification.launchRoot 'tools/runner/runner.bundle.json'
            $fxOutput = @(& $Specification.runtimeMaterializer --apply-common-native-fx true `
                --launch-root $Specification.launchRoot --expected-bundle-sha256 (Get-Sha256Hex $runnerManifest) 2>&1)
            Assert-True ($LASTEXITCODE -eq 0) 'phase_d_native_fx_apply_failed'
        }
        $stageCode = 'server_start_and_listener_observation'
        Write-PhaseDProgress $Specification.launchRoot 'server_start'
        $env:EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID = [string]$context.accountId
        $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID = [string]$context.managerId
        $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_SELECTION = 'profile_trusted_unique/v1'
        $env:EPINELPS_CLASSIC_SOLO_RAID_TARGET_PROFILE_PATH = $Specification.bossRuntimeVariantProfile
        if ($Specification.staticDataVariantRequired) {
            $env:EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH = $Specification.variantStaticDataPack
            $env:EPINELPS_CLIENT_STATIC_DATA_VARIANT_SHA256 = $Specification.variantStaticDataSha256
        }
        try {
            $serverProcess = Start-Process -FilePath $serverPath `
                -ArgumentList @('--headless', '--local-only') `
                -WorkingDirectory $ServerRoot -PassThru -NoNewWindow `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath
            Assert-PhaseDRunnerJobProcess -Specification $Specification -ProcessId $serverProcess.Id
            try { Write-PhaseDProgress $Specification.launchRoot 'server_created' ([DateTimeOffset]$serverProcess.StartTime.ToUniversalTime()) }
            catch { Write-Verbose 'phase_d_progress_process_timestamp_unavailable' }
        }
        finally {
            Remove-Item Env:\EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID,
                Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID,
                Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_SELECTION,
                Env:\EPINELPS_CLASSIC_SOLO_RAID_TARGET_PROFILE_PATH -ErrorAction SilentlyContinue
            if ($Specification.staticDataVariantRequired) {
                Remove-Item Env:\EPINELPS_CLIENT_STATIC_DATA_VARIANT_PATH,
                    Env:\EPINELPS_CLIENT_STATIC_DATA_VARIANT_SHA256 -ErrorAction SilentlyContinue
            }
        }
        $listenerReady = $false
        for ($attempt = 0; $attempt -lt 240; $attempt++) {
            Start-Sleep -Milliseconds 250
            if ($null -eq (Get-PinnedProcess $serverProcess.Id 'EpinelPS')) {
                break
            }
            $tcp = @(Get-NetTCPConnection -OwningProcess $serverProcess.Id `
                -State Listen -ErrorAction SilentlyContinue)
            $udp443 = @(Get-NetUDPEndpoint -OwningProcess $serverProcess.Id `
                -ErrorAction SilentlyContinue | Where-Object LocalPort -EQ 443)
            if (@($tcp | Where-Object {
                $_.LocalAddress -eq '127.0.0.1' -and $_.LocalPort -eq 80
            }).Count -eq 1 -and
                @($tcp | Where-Object {
                    $_.LocalAddress -eq '127.0.0.1' -and $_.LocalPort -eq 443
                }).Count -eq 1 -and
                @($tcp | Where-Object LocalAddress -NE '127.0.0.1').Count -eq 0 -and
                $udp443.Count -eq 0) {
                $listenerReady = $true
                break
            }
        }
        Assert-True $listenerReady `
            'phase3b2_epinel_minimal_start_loopback_listener_not_ready'

        $stageCode = 'physical_bootstrap_and_sail_observation'
        Write-PhaseDProgress $Specification.launchRoot 'game_start'
        $env:NLL_PHASE3B2_ASSESSMENT_UID = $assessmentUid
        $env:NLL_PHASE3B2_EVIDENCE_LANE = $BootstrapEvidenceLane
        try {
            $bootstrapProcess = Start-PhaseDRunnerBootstrap -Specification $Specification -Path $bootstrapPath
            Assert-PhaseDRunnerJobProcess -Specification $Specification -ProcessId $bootstrapProcess.Id
        }
        finally {
            Remove-Item Env:\NLL_PHASE3B2_ASSESSMENT_UID,
                Env:\NLL_PHASE3B2_EVIDENCE_LANE -ErrorAction SilentlyContinue
        }
        for ($attempt = 0; $attempt -lt 600; $attempt++) {
            Start-Sleep -Milliseconds 250
            if (Test-Path -LiteralPath $bootstrapStartPath -PathType Leaf) { break }
            if (Test-Path -LiteralPath $bootstrapFailurePath -PathType Leaf) {
                $bootstrapFailure = Get-Content -LiteralPath $bootstrapFailurePath `
                    -Raw -Encoding UTF8 | ConvertFrom-Json
                throw "bootstrap_$($bootstrapFailure.reasonCode)"
            }
            if ($null -eq (Get-PinnedProcess $bootstrapProcess.Id `
                    'NikkeLocalLab.Phase3B2.PhysicalBootstrap')) {
                throw 'bootstrap_exited_before_receipt'
            }
        }
        Assert-True (Test-Path -LiteralPath $bootstrapStartPath -PathType Leaf) `
            'phase3b2_epinel_minimal_start_bootstrap_receipt_missing'
        $bootstrapStart = Get-Content -LiteralPath $bootstrapStartPath -Raw `
            -Encoding UTF8 | ConvertFrom-Json
        $clientProcessId = [int]$bootstrapStart.clientProcessId
        Assert-PhaseDRunnerJobProcess -Specification $Specification -ProcessId $clientProcessId
        Assert-True (
            $bootstrapStart.contractId -ceq `
                'nll/phase3b2-physical-bootstrap-client-start/v1' -and
            $bootstrapStart.assessmentUid -ceq $assessmentUid -and
            $bootstrapStart.sailNamedPipeConnected -and
            $bootstrapStart.sailNamedPipePayloadWritten -and
            $bootstrapStart.sailNamedPipeClosedAfterPayload -and
            $bootstrapStart.sailSharedMemoryRetainedForClientLifetime -and
            $clientProcessId -gt 0 -and
            $null -ne (Get-PinnedProcess $clientProcessId 'nikke')
        ) 'phase3b2_epinel_minimal_start_bootstrap_contract_invalid'
        $observedClient=$null
        try {
            $observedClient=Get-PinnedProcess $clientProcessId 'nikke'
            if ($null -ne $observedClient) {
                Write-PhaseDProgress $Specification.launchRoot 'game_spawned' ([DateTimeOffset]$observedClient.StartTime.ToUniversalTime())
            }
        } catch { Write-Verbose 'phase_d_progress_process_timestamp_unavailable' }
        finally { if ($observedClient -is [Diagnostics.Process]) { $observedClient.Dispose() } }
    
        $stageCode = 'publish_start_receipt'
        Write-PhaseDProgress $Specification.launchRoot 'running'
    
        $receipt = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-epinel-solo-raid-ranking-prefix-start/v10'
            startedAtUtc = [DateTimeOffset]::UtcNow.ToString(
                "yyyy-MM-dd'T'HH:mm:ss'Z'"
            )
            assessmentUid = $assessmentUid
            derivedSourceManifestSha256 = $DerivedSourceManifestSha256
            runIntentCode = $RunIntentCode
            historicalReceiptBindingApplied = $false
            selfHashBindingApplied = $false
            serverArguments = @('--headless', '--local-only')
            serverProcessId = $serverProcess.Id
            bootstrapProcessId = $bootstrapProcess.Id
            clientProcessId = $clientProcessId
            listenerHttpLoopbackCount = 1
            listenerHttpsLoopbackCount = 1
            listenerHttp3UdpCount = 0
            sailNamedPipeConnected = $true
            sailNamedPipeClosedAfterPayload = $true
            globalMatchLoopbackMappingApplied = $true
            bootstrapOutboundBlockApplied = $true
            selectedManagerRuntimeBindingApplied = $true
            requiredLocalAssetPreflightPerformed = `
                $requiredLocalAssetPreflightPerformed
            requiredLocalAssetLoopbackResolved = `
                $requiredLocalAssetLoopbackResolved
            requiredLocalAssetHttpStatusCode = `
                $requiredLocalAssetHttpStatusCode
            requiredLocalAssetObservedByteLength = `
                $requiredLocalAssetObservedByteLength
            requiredLocalAssetObservedSha256 = `
                $requiredLocalAssetObservedSha256
            requiredLocalCatalogContractSha256 = `
                $RequiredLocalCatalogContractSha256
            requiredLocalCatalogPreflightPerformed = `
                $requiredLocalCatalogPreflightPerformed
            requiredLocalCatalogBodyCount = $requiredLocalCatalogBodyCount
            requiredLocalCatalogSignatureCount = `
                $requiredLocalCatalogSignatureCount
            requiredLocalCatalogAllSqlite = $requiredLocalCatalogAllSqlite
            requiredLocalSausContractSha256 = `
                $RequiredLocalSausContractSha256
            requiredLocalSausPreflightPerformed = `
                $requiredLocalSausPreflightPerformed
            requiredLocalSausBodyCount = $requiredLocalSausBodyCount
            requiredLocalSausSignatureCount = `
                $requiredLocalSausSignatureCount
            requiredLocalSausBodyCrc32Matched = `
                $requiredLocalSausBodyCrc32Matched
            officialLauncherExecutionStarted = $false
            officialOutboundFallbackUsed = $false
            antiCheatSubstitutionApplied = $false
            serverRunning = $true
            physicalBootstrapRunning = $true
            clientExecutionStarted = $true
            nextStepCode = 'enter_requested_solo_raid_mode_close_client_then_complete'
        }
        Write-AtomicUtf8NoBom $runStartPath `
            (($receipt | ConvertTo-Json -Depth 6) + "`n")
        $pointer = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-epinel-minimal-active-run-pointer/v1'
            assessmentUid = $assessmentUid
            runRoot = $runRoot
            bootstrapRunRoot = $bootstrapRunRoot
            runStartReceiptSha256 = Get-Sha256Hex $runStartPath
            serverProcessId = $serverProcess.Id
            bootstrapProcessId = $bootstrapProcess.Id
            clientProcessId = $clientProcessId
            databaseBeforeSha256 = Get-Sha256Hex $dbBeforePath
            hostsBeforeSha256 = Get-Sha256Hex $hostsBeforePath
            serverRunning = $true
            clientExecutionStarted = $true
        }
        New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
        Write-AtomicUtf8NoBom $activePointerPath `
            (($pointer | ConvertTo-Json -Depth 5) + "`n")
        $receipt | ConvertTo-Json -Depth 6
    }
    catch {
        Write-PhaseDProgress $Specification.launchRoot 'recovery_required'
        # Cleanup belongs to the owner outside the execution Job.
        Write-AtomicUtf8NoBom $runFailurePath (([ordered]@{
            contractId='nll/phase-d-job-start-failure/v1'; failedStageCode=$stageCode
            automaticRollbackCompleted=$false; recoveryOwnerCode='outside_execution_job'
        } | ConvertTo-Json) + "`n")
        throw 'phase_d_job_start_failed'
    }
}
