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
    
    function Get-PinnedProcess {
        param([int]$ProcessId, [string]$ExpectedName)
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process -or $process.ProcessName -cne $ExpectedName) {
            return $null
        }
        $process
    }
    
    function Stop-PinnedProcess {
        param([int]$ProcessId, [string]$ExpectedName)
        $process = Get-PinnedProcess $ProcessId $ExpectedName
        if ($null -eq $process) { return }
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        for ($attempt = 0; $attempt -lt 40; $attempt++) {
            if ($null -eq (Get-PinnedProcess $ProcessId $ExpectedName)) { return }
            Start-Sleep -Milliseconds 250
        }
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
    
    $baseFirewallGroup = 'NLL Phase3B2 Physical Isolation'
    $baseRules = @(Get-NetFirewallRule -Group $baseFirewallGroup `
        -ErrorAction SilentlyContinue)
    Assert-True (
        $baseRules.Count -eq 17 -and
        @($baseRules | Where-Object {
            $_.Direction -ne 'Outbound' -or $_.Action -ne 'Block' -or
            $_.Enabled -ne 'True'
        }).Count -eq 0 -and
        @(Get-NetFirewallRule -Group $extensionFirewallGroup `
            -ErrorAction SilentlyContinue).Count -eq 0
    ) 'phase3b2_epinel_minimal_start_firewall_precondition_invalid'
    
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
    $measurementPath = Join-Path $runRoot 'startup.measurement.json'
    $runStartPath = Join-Path $runRoot 'run-start.receipt.json'
    $runFailurePath = Join-Path $runRoot 'run-failure.receipt.json'
    $bootstrapStartPath = Join-Path $bootstrapRunRoot `
        'bootstrap-start.receipt.json'
    $bootstrapFailurePath = Join-Path $bootstrapRunRoot `
        'bootstrap-failure.receipt.json'
    
    $hostsApplied = $false
    $firewallApplied = $false
    $databaseBackupCreated = $false
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
        $databaseBackupCreated = $true
        Assert-True (
            (Get-Sha256Hex $dbBeforePath) -ceq $expectedDbSha256 -and
            (Get-Sha256Hex $hostsBeforePath) -ceq $expectedHostsSha256
        ) 'phase3b2_epinel_minimal_start_backup_failed'
    
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
        $hostsApplied = $true
        Assert-True ((Get-Sha256Hex $hostsPath) -ceq $expectedAppliedHostsSha256) `
            'phase3b2_epinel_minimal_start_hosts_apply_failed'
    
        New-NetFirewallRule `
            -Name 'NLL.Phase3B2.EpinelMinimal.BootstrapBlock' `
            -DisplayName 'NLL Phase3B2 Epinel Minimal Bootstrap Outbound Block' `
            -Group $extensionFirewallGroup -Direction Outbound -Action Block `
            -Enabled True -Profile Any -Program $bootstrapPath | Out-Null
        $firewallApplied = $true
        if ($Specification.clientBuildCode -ceq 'build_151.8.5') {
            New-NetFirewallRule -Name 'NLL.PhaseD.RuntimeServerBlock' -DisplayName 'NLL Phase D local runtime server' -Group $extensionFirewallGroup -Direction Outbound -Action Block -Enabled True -Profile Any -Program $serverPath | Out-Null
        }
        $extensionRules = @(Get-NetFirewallRule -Group $extensionFirewallGroup)
        $extensionPrograms = @(
            $extensionRules | Get-NetFirewallApplicationFilter
        )
        Assert-True (
            $extensionRules.Count -eq $(if ($Specification.clientBuildCode -ceq 'build_151.8.5') { 2 } else { 1 }) -and
            $extensionPrograms.Count -eq $extensionRules.Count -and
            (@($extensionPrograms.Program) -ccontains $bootstrapPath) -and
            ($Specification.clientBuildCode -cne 'build_151.8.5' -or (@($extensionPrograms.Program) -ccontains $serverPath))
        ) 'phase3b2_epinel_minimal_start_firewall_apply_failed'
    
        $stageCode = 'server_start_and_listener_observation'
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
    
        if ($Specification.resourcePreflightRequired) {
            $stageCode = 'required_resource_catalog_set_loopback_preflight'
            Invoke-PhaseDRunnerResourcePreflight -Specification $Specification
        }
    
        $stageCode = 'physical_bootstrap_and_sail_observation'
        $env:NLL_PHASE3B2_ASSESSMENT_UID = $assessmentUid
        $env:NLL_PHASE3B2_EVIDENCE_LANE = $BootstrapEvidenceLane
        try {
            $bootstrapProcess = Start-Process -FilePath $bootstrapPath `
                -WorkingDirectory (Split-Path -Parent $bootstrapPath) -PassThru -WindowStyle Hidden
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
    
        $stageCode = 'thirty_second_interactive_health_observation'
        $samples = @()
        $deadline = New-PhaseDRunnerStopwatch
        while ($deadline.Elapsed.TotalSeconds -lt 30) {
            $client = Get-PinnedProcess $clientProcessId 'nikke'
            $server = Get-PinnedProcess $serverProcess.Id 'EpinelPS'
            $bootstrap = Get-PinnedProcess $bootstrapProcess.Id `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
            Assert-True ($null -ne $client -and $null -ne $server -and
                $null -ne $bootstrap) `
                'phase3b2_epinel_minimal_start_process_lost_during_measurement'
            $connections = @(
                foreach ($observedProcessId in @($clientProcessId, $serverProcess.Id,
                    $bootstrapProcess.Id)) {
                    Get-NetTCPConnection -OwningProcess $observedProcessId `
                        -State Established `
                        -ErrorAction SilentlyContinue
                }
            )
            $nonLoopback = @($connections | Where-Object {
                $_.RemoteAddress -notin @('127.0.0.1', '::1')
            })
            $samples += [ordered]@{
                offsetMilliseconds = [long]$deadline.Elapsed.TotalMilliseconds
                clientResponding = [bool]$client.Responding
                nonLoopbackConnectionCount = $nonLoopback.Count
            }
            Start-Sleep -Seconds 2
        }
        Write-AtomicUtf8NoBom $measurementPath `
            (($samples | ConvertTo-Json -Depth 4) + "`n")
        $measurementElapsedMilliseconds = if ($samples.Count -gt 0) {
            [long]$samples[-1].offsetMilliseconds
        } else { 0L }
        Assert-True (
            $samples.Count -ge 10 -and
            $measurementElapsedMilliseconds -ge 28000 -and
            @($samples | Where-Object { -not $_.clientResponding }).Count -eq 0 -and
            @($samples | Where-Object {
                $_.nonLoopbackConnectionCount -ne 0
            }).Count -eq 0
        ) 'phase3b2_epinel_minimal_start_health_or_network_invalid'
    
        $receipt = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-epinel-solo-raid-ranking-prefix-start/v9'
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
            thirtySecondMeasurementCompleted = $true
            measurementSampleCount = $samples.Count
            measurementElapsedMilliseconds = $measurementElapsedMilliseconds
            minimumAcceptedSampleCount = 10
            minimumAcceptedElapsedMilliseconds = 28000
            successfulNonLoopbackConnectionCount = 0
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
        $failureMessage = $_.Exception.Message
        if ($clientProcessId -gt 0) {
            Stop-PinnedProcess $clientProcessId 'nikke'
        }
        if ($null -ne $bootstrapProcess) {
            Stop-PinnedProcess $bootstrapProcess.Id `
                'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        }
        if ($null -ne $serverProcess) {
            Stop-PinnedProcess $serverProcess.Id 'EpinelPS'
        }
        $redactedServerLogMatchCount = Protect-ServerLog $stdoutPath
        if ($databaseBackupCreated -and
            (Test-Path -LiteralPath $dbBeforePath -PathType Leaf)) {
            [IO.File]::WriteAllBytes(
                $dbPath, [IO.File]::ReadAllBytes($dbBeforePath)
            )
            foreach ($name in @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal')) {
                $path = Join-Path $ServerRoot $name
                if (Test-Path -LiteralPath $path) {
                    Remove-Item -LiteralPath $path -Force
                }
            }
        }
        if ($hostsApplied -and
            (Test-Path -LiteralPath $hostsBeforePath -PathType Leaf)) {
            [IO.File]::WriteAllBytes(
                $hostsPath, [IO.File]::ReadAllBytes($hostsBeforePath)
            )
        }
        if ($firewallApplied) {
            Get-NetFirewallRule -Group $extensionFirewallGroup `
                -ErrorAction SilentlyContinue | Remove-NetFirewallRule
        }
        $failure = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-epinel-solo-raid-ranking-prefix-failure/v9'
            failedAtUtc = [DateTimeOffset]::UtcNow.ToString(
                "yyyy-MM-dd'T'HH:mm:ss'Z'"
            )
            assessmentUid = $assessmentUid
            failedStageCode = $stageCode
            failureMessage = $failureMessage
            automaticRollbackCompleted = $true
            redactedServerLogMatchCount = $redactedServerLogMatchCount
            rawSensitiveServerLogPersisted = $false
            officialLauncherExecutionStarted = $false
            officialOutboundFallbackUsed = $false
            requiredLocalAssetPreflightPerformed = `
                $requiredLocalAssetPreflightPerformed
            clientExecutionStarted = $clientProcessId -gt 0
        }
        Write-AtomicUtf8NoBom $runFailurePath `
            (($failure | ConvertTo-Json -Depth 5) + "`n")
        throw "phase3b2_epinel_minimal_reference_failed:${stageCode}:$failureMessage"
    }
}
