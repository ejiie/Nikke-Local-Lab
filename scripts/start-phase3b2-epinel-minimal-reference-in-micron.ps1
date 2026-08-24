param(
    [string]$ServerRoot =
        'C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64',
    [string]$BootstrapRoot = 'C:\NLL\Runtime\PhysicalBootstrap-v2',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-reference-v1',
    [string]$BootstrapEvidenceLane = 'p2-client-start-v2'
)

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

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporary = $Path + '.partial-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText(
        $temporary, $Text, [Text.UTF8Encoding]::new($false)
    )
    Move-Item -LiteralPath $temporary -Destination $Path
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

$expectedPreflightSha256 = `
    'f6699da26a55c95ab0d5ed250930910896b098b245907ac73d852fd700f36b0a'
$expectedDeploymentSha256 = `
    '101a43a90791bf79f62ac661f35802ed53261cda37d22d7d68b6d4bff487befa'
$expectedServerExeSha256 = `
    'f7aa2dc342e93157b620408b887603f62188c8d4a3ad75e94ab3b5b76547bc2d'
$expectedServerDllSha256 = `
    '25b7251f860518418ae8f50c59c311f25cf3a2615ded34a12f07ab845168bb38'
$expectedDbSha256 = `
    'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
$expectedHostsSha256 = `
    'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
$expectedAppliedHostsSha256 = `
    '3b0dcc4396373e9e9d623ef05c345f89330427ad5128727290c9f76138e22f64'
$expectedBootstrapSha256 = `
    'ff7371b3e20119030c0f3a8e2f6ba9482094c4118f06dbcc4e0e7f137f8e404f'
$extensionFirewallGroup = 'NLL Phase3B2 Epinel Minimal Extension'

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-True (
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
) 'phase3b2_epinel_minimal_start_requires_administrator'
Assert-True ($env:SystemDrive -ceq 'C:' -and $env:USERNAME -ceq 'nlloperator') `
    'phase3b2_epinel_minimal_start_wrong_operator_or_boot_boundary'

$preflightPath =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-preflight-v1\preflight.receipt.json'
$deploymentPath =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-deployment-v1\deployment.receipt.json'
$contextPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'
$serverPath = Join-Path $ServerRoot 'EpinelPS.exe'
$serverDllPath = Join-Path $ServerRoot 'EpinelPS.dll'
$dbPath = Join-Path $ServerRoot 'db.json'
$bootstrapPath = Join-Path $BootstrapRoot `
    'artifact\NikkeLocalLab.Phase3B2.PhysicalBootstrap.exe'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$activePointerPath = Join-Path $EvidenceRoot 'active-run.pointer.json'

Assert-True (
    @($preflightPath, $deploymentPath, $contextPath, $serverPath,
        $serverDllPath, $dbPath, $bootstrapPath, $hostsPath |
        Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
    ).Count -eq 0 -and
    -not (Test-Path -LiteralPath $activePointerPath) -and
    @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal' |
        Where-Object { Test-Path -LiteralPath (Join-Path $ServerRoot $_) }
    ).Count -eq 0
) 'phase3b2_epinel_minimal_start_input_shape_invalid'
Assert-True (
    (Get-Sha256Hex $preflightPath) -ceq $expectedPreflightSha256 -and
    (Get-Sha256Hex $deploymentPath) -ceq $expectedDeploymentSha256 -and
    (Get-Sha256Hex $serverPath) -ceq $expectedServerExeSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedHostsSha256 -and
    (Get-Sha256Hex $bootstrapPath) -ceq $expectedBootstrapSha256
) 'phase3b2_epinel_minimal_start_digest_invalid'

$preflight = Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $preflight.contractId -ceq `
        'nll/phase3b2-epinel-minimal-source-free-preflight/v1' -and
    $preflight.verdict -ceq `
        'ready_to_stage_single_micron_reference_run_tools' -and
    -not $preflight.officialOutboundFallbackPermitted -and
    $context.contractId -ceq `
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
$bootstrapRunRoot = Join-Path (
    'C:\NLL\Evidence\Phase3B2\Physical\' + $BootstrapEvidenceLane
) $assessmentUid
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
    $extensionRules = @(Get-NetFirewallRule -Group $extensionFirewallGroup)
    $extensionPrograms = @(
        $extensionRules | Get-NetFirewallApplicationFilter
    )
    Assert-True (
        $extensionRules.Count -eq 1 -and
        $extensionPrograms.Count -eq 1 -and
        $extensionPrograms[0].Program -ceq $bootstrapPath
    ) 'phase3b2_epinel_minimal_start_firewall_apply_failed'

    $stageCode = 'server_start_and_listener_observation'
    $env:EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID = [string]$context.accountId
    $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID = [string]$context.managerId
    try {
        $serverProcess = Start-Process -FilePath $serverPath `
            -ArgumentList @('--headless', '--local-only') `
            -WorkingDirectory $ServerRoot -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath
    }
    finally {
        Remove-Item Env:\EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID,
            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID `
            -ErrorAction SilentlyContinue
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
    $env:NLL_PHASE3B2_ASSESSMENT_UID = $assessmentUid
    $env:NLL_PHASE3B2_EVIDENCE_LANE = $BootstrapEvidenceLane
    try {
        $bootstrapProcess = Start-Process -FilePath $bootstrapPath `
            -WorkingDirectory (Split-Path -Parent $bootstrapPath) -PassThru
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
    $deadline = [Diagnostics.Stopwatch]::StartNew()
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
    Assert-True (
        $samples.Count -ge 15 -and
        @($samples | Where-Object { -not $_.clientResponding }).Count -eq 0 -and
        @($samples | Where-Object {
            $_.nonLoopbackConnectionCount -ne 0
        }).Count -eq 0
    ) 'phase3b2_epinel_minimal_start_health_or_network_invalid'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-epinel-minimal-reference-start/v1'
        startedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        assessmentUid = $assessmentUid
        preflightReceiptSha256 = $expectedPreflightSha256
        deploymentReceiptSha256 = $expectedDeploymentSha256
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
        successfulNonLoopbackConnectionCount = 0
        globalMatchLoopbackMappingApplied = $true
        bootstrapOutboundBlockApplied = $true
        selectedManagerRuntimeBindingApplied = $true
        officialLauncherExecutionStarted = $false
        officialOutboundFallbackUsed = $false
        antiCheatSubstitutionApplied = $false
        serverRunning = $true
        physicalBootstrapRunning = $true
        clientExecutionStarted = $true
        nextStepCode = 'select_global_observe_or_play_close_client_then_complete'
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
        contractId = 'nll/phase3b2-epinel-minimal-reference-failure/v1'
        failedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        assessmentUid = $assessmentUid
        failedStageCode = $stageCode
        failureMessage = $failureMessage
        automaticRollbackCompleted = $true
        officialLauncherExecutionStarted = $false
        officialOutboundFallbackUsed = $false
        clientExecutionStarted = $clientProcessId -gt 0
    }
    Write-AtomicUtf8NoBom $runFailurePath `
        (($failure | ConvertTo-Json -Depth 5) + "`n")
    throw "phase3b2_epinel_minimal_reference_failed:${stageCode}:$failureMessage"
}
