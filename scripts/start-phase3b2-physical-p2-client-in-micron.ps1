[CmdletBinding()]
param(
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$RuntimeRoot = 'C:\NLL\Runtime\PhysicalBootstrap-v1',
    [string]$PreparationRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-preparation-v1',
    [string]$P2EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v1',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\Runs'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$stageCode = 'initialization'
$serverProcess = $null
$bootstrapProcess = $null
$databaseBackupCreated = $false
$serverStarted = $false
$bootstrapStarted = $false
$clientStarted = $false
$clientProcessId = 0
$assessmentUid = [Guid]::NewGuid().ToString('D')
$runRoot = Join-Path $P2EvidenceRoot $assessmentUid
$protectedRunRoot = Join-Path $SamsungProtectedRoot $assessmentUid
$activePointerPath = Join-Path $P2EvidenceRoot 'active-run.pointer.json'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-ExactExecutableProcesses {
    param([string]$ExecutablePath)
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ExecutablePath -and $_.ExecutablePath.Equals(
                $ExecutablePath, [StringComparison]::OrdinalIgnoreCase)
        })
}

function Stop-ExactExecutableProcesses {
    param([string]$ExecutablePath)
    foreach ($member in @(Get-ExactExecutableProcesses $ExecutablePath)) {
        Stop-Process -Id ([int]$member.ProcessId) -Force `
            -ErrorAction SilentlyContinue
    }
}

function Get-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    if ($ProcessId -le 0) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process -or
        $process.ProcessName -cne $ExpectedName) { return $null }
    return $process
}

function Stop-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    $process = Get-PinnedProcess $ProcessId $ExpectedName
    if ($null -ne $process) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

$serverRoot = Join-Path $EpinelRoot 'EpinelPS\bin\Release\net10.0\win-x64'
$serverPath = Join-Path $serverRoot 'EpinelPS.exe'
$serverDllPath = Join-Path $serverRoot 'EpinelPS.dll'
$dbPath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $serverRoot $_ }
$contextPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'
$bootstrapPath = Join-Path $RuntimeRoot `
    'artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
$clientPath =
    'C:\NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\nikke.exe'
$preparationPath = Join-Path $PreparationRoot 'preparation.receipt.json'
$stdoutPath = Join-Path $runRoot 'server.stdout.log'
$stderrPath = Join-Path $runRoot 'server.stderr.log'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$failurePath = Join-Path $runRoot 'run-failure.receipt.json'

try {
    $stageCode = 'physical_boundary_and_contract_preflight'
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_physical_p2_start_requires_administrator'
    $bootDisk = Get-Partition -DriveLetter C | Get-Disk
    $samsungDisk = Get-Partition -DriveLetter E | Get-Disk
    Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem -and
        $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem) `
        'phase3b2_physical_p2_micron_boot_required'
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $deviceGuard = Get-CimInstance `
        -Namespace root\Microsoft\Windows\DeviceGuard `
        -ClassName Win32_DeviceGuard
    $runningSecurityServices = @($deviceGuard.SecurityServicesRunning |
        Where-Object { $null -ne $_ -and [int]$_ -ne 0 })
    Assert-True (-not [bool]$computerSystem.HypervisorPresent -and
        [int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 0 -and
        $runningSecurityServices.Count -eq 0) `
        'phase3b2_physical_p2_virtualization_boundary_invalid'
    Assert-True (-not (Test-Path -LiteralPath $activePointerPath) -and
        -not (Test-Path -LiteralPath $runRoot) -and
        -not (Test-Path -LiteralPath $protectedRunRoot)) `
        'phase3b2_physical_p2_active_or_duplicate_run_present'
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0 -and
        @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object LocalPort -In 80, 443).Count -eq 0 -and
        @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
            Where-Object LocalPort -EQ 443).Count -eq 0) `
        'phase3b2_physical_p2_runtime_not_cold'

    Assert-True (Test-Path -LiteralPath $preparationPath -PathType Leaf) `
        'phase3b2_physical_p2_preparation_receipt_missing'
    $preparation = Get-Content -LiteralPath $preparationPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($preparation.contractId -ceq
            'nll/phase3b2-physical-p2-preparation/v1' -and
        $preparation.p0AssessmentUid -ceq
            '73f05d4f-b0e6-411d-b471-072b8ef3158b' -and
        $preparation.p1AssessmentUid -ceq
            '0e71964a-f07b-49e1-81de-78439e4b5b9e' -and
        [int]$preparation.baseFirewallRuleCount -eq 17 -and
        [int]$preparation.extensionFirewallRuleCount -eq 1 -and
        -not $preparation.serverExecutionStarted -and
        -not $preparation.clientExecutionStarted) `
        'phase3b2_physical_p2_preparation_receipt_invalid'
    $extensionRules = @(Get-NetFirewallRule `
        -Group 'NLL Phase3B2 Physical Bootstrap Extension' `
        -ErrorAction SilentlyContinue)
    $extensionPrograms = @($extensionRules | Get-NetFirewallApplicationFilter)
    Assert-True ($extensionRules.Count -eq 1 -and
        $extensionRules[0].Direction -eq 'Outbound' -and
        $extensionRules[0].Action -eq 'Block' -and
        $extensionPrograms.Count -eq 1 -and
        $extensionPrograms[0].Program -ceq $bootstrapPath -and
        @(Get-NetFirewallRule -Group 'NLL Phase3B2 Physical Isolation' `
            -ErrorAction SilentlyContinue).Count -eq 17) `
        'phase3b2_physical_p2_firewall_state_invalid'

    Assert-True ((Test-PathDigest $serverPath 162304L `
                '648876d076c6f7f5e73d33dc533cd089a36785318c33b923b277e550a975777f') -and
        (Test-PathDigest $serverDllPath `
                ([long]$preparation.serverDllByteLength) `
                ([string]$preparation.serverDllSha256)) -and
        (Test-PathDigest $dbPath 413327L `
                'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') -and
        (Test-PathDigest $contextPath 279L `
                'cc84781bc0df8d8705ac237f19763808e8925c7706de231b24470469ca446cc2') -and
        (Test-PathDigest $clientPath 794152L `
                '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30') -and
        (Test-PathDigest $bootstrapPath `
                ([long]$preparation.physicalBootstrapExeByteLength) `
                ([string]$preparation.physicalBootstrapExeSha256))) `
        'phase3b2_physical_p2_runtime_pin_mismatch'
    Assert-True (@($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0) `
        'phase3b2_physical_p2_sqlite_precondition_invalid'
    Assert-True (@(Get-Process -Name nikke_launcher `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p2_official_launcher_present'

    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($context.contractId -ceq
            'nll/phase3b2-synthetic-runtime-context/v1' -and
        ([string]$context.username).StartsWith(
            'synthetic-', [StringComparison]::Ordinal) -and
        ([string]$context.password).Length -eq 20) `
        'phase3b2_physical_p2_synthetic_context_invalid'

    $stageCode = 'evidence_and_database_backup'
    New-Item -ItemType Directory -Path $runRoot, $protectedRunRoot -Force |
        Out-Null
    [IO.File]::WriteAllBytes(
        $databaseBeforePath, [IO.File]::ReadAllBytes($dbPath))
    Assert-True (Test-PathDigest $databaseBeforePath 413327L `
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
        'phase3b2_physical_p2_database_backup_failed'
    $databaseBackupCreated = $true

    $stageCode = 'server_start_and_listener_observation'
    $env:EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID = [string]$context.accountId
    $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID = [string]$context.managerId
    $previousMicrosoftLog = $env:Logging__LogLevel__Microsoft
    $previousSystemLog = $env:Logging__LogLevel__System
    $env:Logging__LogLevel__Microsoft = 'Warning'
    $env:Logging__LogLevel__System = 'Warning'
    try {
        $serverProcess = Start-Process -FilePath $serverPath `
            -ArgumentList @('--headless', '--local-only') `
            -WorkingDirectory $serverRoot -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath
        $serverStarted = $true
    }
    finally {
        Remove-Item Env:\EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID,
            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID `
            -ErrorAction SilentlyContinue
        $env:Logging__LogLevel__Microsoft = $previousMicrosoftLog
        $env:Logging__LogLevel__System = $previousSystemLog
    }

    $listenerReady = $false
    for ($attempt = 0; $attempt -lt 240; $attempt++) {
        Start-Sleep -Milliseconds 250
        $serverProcess.Refresh()
        if ($serverProcess.HasExited) {
            throw 'phase3b2_physical_p2_server_exited_before_listener'
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
        'phase3b2_physical_p2_loopback_listener_not_ready'

    $stageCode = 'physical_bootstrap_and_sail_observation'
    $env:NLL_PHASE3B2_ASSESSMENT_UID = $assessmentUid
    try {
        $bootstrapProcess = Start-Process -FilePath $bootstrapPath `
            -WorkingDirectory (Split-Path -Parent $bootstrapPath) `
            -PassThru
        $bootstrapStarted = $true
    }
    finally {
        Remove-Item Env:\NLL_PHASE3B2_ASSESSMENT_UID `
            -ErrorAction SilentlyContinue
    }

    $bootstrapStartPath = Join-Path $runRoot 'bootstrap-start.receipt.json'
    $bootstrapFailurePath = Join-Path $runRoot 'bootstrap-failure.receipt.json'
    for ($attempt = 0; $attempt -lt 600; $attempt++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $bootstrapFailurePath -PathType Leaf) {
            $failure = Get-Content -LiteralPath $bootstrapFailurePath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            throw "phase3b2_physical_p2_bootstrap_failed_$($failure.reasonCode)"
        }
        if (Test-Path -LiteralPath $bootstrapStartPath -PathType Leaf) { break }
        $bootstrapProcess.Refresh()
        if ($bootstrapProcess.HasExited) {
            throw 'phase3b2_physical_p2_bootstrap_exited_before_sail'
        }
    }
    Assert-True (Test-Path -LiteralPath $bootstrapStartPath -PathType Leaf) `
        'phase3b2_physical_p2_sail_pipe_connection_not_observed'
    $bootstrapStart = Get-Content -LiteralPath $bootstrapStartPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($bootstrapStart.contractId -ceq
            'nll/phase3b2-physical-bootstrap-client-start/v1' -and
        $bootstrapStart.assessmentUid -ceq $assessmentUid -and
        $bootstrapStart.accountLoginAccepted -and
        $bootstrapStart.intlAuthenticationAccepted -and
        $bootstrapStart.sailSharedMemoryCreated -and
        $bootstrapStart.sailNamedPipeConnected -and
        [int]$bootstrapStart.clientProcessCount -eq 1 -and
        [int]$bootstrapStart.clientProcessId -gt 0 -and
        $bootstrapStart.clientProcessObservationSourceCode -ceq
            'process_start_returned_pid' -and
        $bootstrapStart.clientExecutionStarted -and
        -not $bootstrapStart.officialLauncherExecutionStarted -and
        -not $bootstrapStart.antiCheatSubstitutionApplied) `
        'phase3b2_physical_p2_bootstrap_start_receipt_invalid'
    $clientStarted = $true
    $clientProcessId = [int]$bootstrapStart.clientProcessId
    $clientMember = Get-PinnedProcess $clientProcessId 'nikke'
    Assert-True ($null -ne $clientMember -and
        @(Get-Process -Name nikke_launcher `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p2_client_process_shape_invalid'

    $stageCode = 'runtime_network_observation'
    $observedIds = @(
        [int]$serverProcess.Id,
        [int]$bootstrapProcess.Id,
        $clientProcessId
    )
    $connections = @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object OwningProcess -In $observedIds)
    $successfulNonLoopback = @($connections | Where-Object {
        $_.State -eq 'Established' -and $_.RemoteAddress -and
        $_.RemoteAddress -notin @('0.0.0.0', '127.0.0.1', '::', '::1')
    })
    Assert-True ($successfulNonLoopback.Count -eq 0) `
        'phase3b2_physical_p2_nonloopback_connection_observed'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-client-start/v1'
        startedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
        p1AssessmentUid = '0e71964a-f07b-49e1-81de-78439e4b5b9e'
        preparationReceiptByteLength = (Get-Item $preparationPath).Length
        preparationReceiptSha256 = Get-Sha256Hex $preparationPath
        bootstrapStartReceiptByteLength =
            (Get-Item $bootstrapStartPath).Length
        bootstrapStartReceiptSha256 = Get-Sha256Hex $bootstrapStartPath
        clientBuild = '150.6.9'
        clientBootstrapModeCode =
            'source_built_sail_abi_physical_clone_bootstrap'
        networkIsolationModeCode =
            'program_scoped_outbound_block_with_loopback_hosts'
        serverProcessId = [int]$serverProcess.Id
        bootstrapProcessId = [int]$bootstrapProcess.Id
        clientProcessId = $clientProcessId
        clientProcessObservationSourceCode =
            'bootstrap_process_start_returned_pid'
        httpIpv4LoopbackListenerCount = 1
        httpsIpv4LoopbackListenerCount = 1
        http3UdpListenerCount = 0
        successfulNonLoopbackConnectionCount = 0
        sailSharedMemoryCreated = $true
        sailNamedPipeConnected = $true
        serverRunning = $true
        physicalBootstrapRunning = $true
        clientExecutionStarted = $true
        originalClientRuntimeEntered = $true
        officialLauncherExecutionStarted = $false
        antiCheatSubstitutionApplied = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        nextStepCode = 'operator_observe_original_client_then_run_completion_tool'
    }
    Write-AtomicUtf8NoBom $runStartPath `
        (($receipt | ConvertTo-Json -Depth 7) + "`n")
    $pointer = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-active-run-pointer/v1'
        assessmentUid = $assessmentUid
        runStartReceiptByteLength = (Get-Item $runStartPath).Length
        runStartReceiptSha256 = Get-Sha256Hex $runStartPath
        serverProcessId = [int]$serverProcess.Id
        bootstrapProcessId = [int]$bootstrapProcess.Id
        clientProcessId = $clientProcessId
        serverRunning = $true
        clientExecutionStarted = $true
    }
    New-Item -ItemType Directory -Path $P2EvidenceRoot -Force | Out-Null
    Write-AtomicUtf8NoBom $activePointerPath `
        (($pointer | ConvertTo-Json -Depth 6) + "`n")
    foreach ($path in @($databaseBeforePath, $bootstrapStartPath,
            $runStartPath, $activePointerPath)) {
        Copy-Item -LiteralPath $path -Destination $protectedRunRoot
        $copy = Join-Path $protectedRunRoot (Split-Path -Leaf $path)
        Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
            'phase3b2_physical_p2_start_protected_copy_failed'
    }
    $receipt | ConvertTo-Json -Depth 8
}
catch {
    $failureRecord = $_
    $safeFailureCode = if ($failureRecord.Exception.Message -cmatch
        '^phase3b2_[a-z0-9_:-]+$') {
        $failureRecord.Exception.Message
    }
    else { 'phase3b2_physical_p2_unexpected_error_redacted' }
    Stop-PinnedProcess $clientProcessId 'nikke'
    if ($null -ne $bootstrapProcess) {
        Stop-PinnedProcess ([int]$bootstrapProcess.Id) `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    }
    if ($null -ne $serverProcess) {
        Stop-PinnedProcess ([int]$serverProcess.Id) 'EpinelPS'
    }
    Stop-ExactExecutableProcesses $clientPath
    Stop-ExactExecutableProcesses $bootstrapPath
    Stop-ExactExecutableProcesses $serverPath
    Start-Sleep -Milliseconds 500
    foreach ($path in $sqlitePaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    $databaseRestored = $false
    if ($databaseBackupCreated -and
        (Test-Path -LiteralPath $databaseBeforePath -PathType Leaf)) {
        [IO.File]::WriteAllBytes(
            $dbPath, [IO.File]::ReadAllBytes($databaseBeforePath))
        $databaseRestored = Test-PathDigest $dbPath 413327L `
            'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
    }
    $extensionRules = @(Get-NetFirewallRule `
        -Group 'NLL Phase3B2 Physical Bootstrap Extension' `
        -ErrorAction SilentlyContinue)
    $extensionRules | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    $extensionRolledBack = @(Get-NetFirewallRule `
        -Group 'NLL Phase3B2 Physical Bootstrap Extension' `
        -ErrorAction SilentlyContinue).Count -eq 0
    try {
        New-Item -ItemType Directory -Path $runRoot, $protectedRunRoot -Force |
            Out-Null
        $failure = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-p2-client-start-failure/v1'
            failedAtUtc =
                [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            assessmentUid = $assessmentUid
            failedStageCode = $stageCode
            failureCode = $safeFailureCode
            serverExecutionStarted = $serverStarted
            physicalBootstrapExecutionStarted = $bootstrapStarted
            clientExecutionStarted = $clientStarted
            clientProcessId = $clientProcessId
            runtimeStopped =
                $null -eq (Get-PinnedProcess $clientProcessId 'nikke') -and
                ($null -eq $bootstrapProcess -or
                    $null -eq (Get-PinnedProcess `
                        ([int]$bootstrapProcess.Id) `
                        'NikkeLocalLab.Phase3B2.PhysicalBootstrap')) -and
                ($null -eq $serverProcess -or
                    $null -eq (Get-PinnedProcess `
                        ([int]$serverProcess.Id) 'EpinelPS'))
            databaseBackupCreated = $databaseBackupCreated
            databaseRestored = $databaseRestored
            sqliteRuntimeRemoved = @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0
            extensionFirewallRolledBack = $extensionRolledBack
            baseP0Preserved = $true
            officialLauncherExecutionStarted = $false
            officialIdentityPersisted = $false
            officialCredentialPersisted = $false
            nextStepCode = 'return_to_samsung_and_inspect_physical_p2_failure'
        }
        Write-AtomicUtf8NoBom $failurePath `
            (($failure | ConvertTo-Json -Depth 7) + "`n")
        Copy-Item -LiteralPath $failurePath -Destination $protectedRunRoot -Force
        foreach ($path in @($databaseBeforePath, $bootstrapStartPath,
                $stdoutPath, $stderrPath,
                (Join-Path $runRoot 'bootstrap-failure.receipt.json'))) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Copy-Item -LiteralPath $path -Destination $protectedRunRoot -Force
            }
        }
        if (Test-Path -LiteralPath $activePointerPath) {
            Remove-Item -LiteralPath $activePointerPath -Force
        }
    }
    catch { }
    throw "phase3b2_physical_p2_client_start_failed:$stageCode"
}
