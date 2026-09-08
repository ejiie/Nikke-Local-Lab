[CmdletBinding()]
param(
    [ValidateRange(30, 1800)]
    [int]$MeasurementSeconds = 600,
    [ValidateRange(2, 30)]
    [int]$SampleIntervalSeconds = 5,
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$RuntimeRoot = 'C:\NLL\Runtime\PhysicalBootstrap-v2',
    [string]$PreparationRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-preparation-v2',
    [string]$P2EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-client-start-v2',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\RunsV2'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$stageCode = 'initialization'
$assessmentUid = [Guid]::NewGuid().ToString('D')
$runRoot = Join-Path $P2EvidenceRoot $assessmentUid
$protectedRunRoot = Join-Path $SamsungProtectedRoot $assessmentUid
$activePointerPath = Join-Path $P2EvidenceRoot 'active-run.pointer.json'
$serverProcess = $null
$bootstrapProcess = $null
$clientProcessId = 0
$databaseBackupCreated = $false
$auditBackupCreated = $false
$auditRestored = $false
$dnsOriginalEnabled = $null
$dnsChannelRestored = $false
$serverStarted = $false
$bootstrapStarted = $false
$clientStarted = $false
$catalogProjectionRolledBack = $false
$samples = [Collections.Generic.List[object]]::new()
$measurementDurationMilliseconds = 0L
$measurementExpectedSampleCount = 0
$measurementQualityStatusCode = 'not_started'
$dnsObservation = $null
$wfpObservation = $null
$playerLogObservation = $null
$timer = $null
$observationStartedAt = $null
$playerLogPath = $null
$baselineBackedInteractiveMode = $MeasurementSeconds -lt 600
$catalogSetPointerPath =
    'C:\NLL\Evidence\Phase3B2\Physical\catalog-set-v1\latest.pointer.json'
$catalogProjectionAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-version-projection-repair.receipt.json'
$catalogParserExactAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-parser-exact-repair.receipt.json'
$resourceHostMapAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\resource-host-map-repair.receipt.json'
$dataPackVersionHeaderAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\datapack-version-header-repair.receipt.json'
$catalogHeaderFollowupAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\exact-catalog-header-followup.receipt.json'
$catalogSqliteTransportAuthorizationPath =
    'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-sqlite-transport-repair.receipt.json'
$catalogSetRetryMode = $baselineBackedInteractiveMode -and
    (Test-Path -LiteralPath $catalogSetPointerPath -PathType Leaf)
$catalogHeaderFollowupMode = $catalogSetRetryMode -and
    (Test-Path -LiteralPath $catalogHeaderFollowupAuthorizationPath `
        -PathType Leaf)
$catalogSqliteTransportMode = $catalogHeaderFollowupMode -and
    (Test-Path -LiteralPath $catalogSqliteTransportAuthorizationPath `
        -PathType Leaf)
$dataPackVersionHeaderRetryMode = $baselineBackedInteractiveMode -and
    -not $catalogSetRetryMode -and
    (Test-Path -LiteralPath $dataPackVersionHeaderAuthorizationPath `
        -PathType Leaf)
$resourceHostMapRetryMode = $baselineBackedInteractiveMode -and
    -not $catalogSetRetryMode -and
    -not $dataPackVersionHeaderRetryMode -and
    (Test-Path -LiteralPath $resourceHostMapAuthorizationPath -PathType Leaf)
$catalogParserExactRetryMode = $baselineBackedInteractiveMode -and
    -not $catalogSetRetryMode -and
    -not $resourceHostMapRetryMode -and
    (Test-Path -LiteralPath $catalogParserExactAuthorizationPath -PathType Leaf)
$catalogProjectionRetryMode = $baselineBackedInteractiveMode -and
    -not $catalogSetRetryMode -and
    -not $catalogParserExactRetryMode -and
    (Test-Path -LiteralPath $catalogProjectionAuthorizationPath -PathType Leaf)
$catalogParserExactFormatMode = $catalogHeaderFollowupMode -or
    $dataPackVersionHeaderRetryMode -or
    $resourceHostMapRetryMode -or
    $catalogParserExactRetryMode
$catalogProjectionAnyRetryMode = $catalogParserExactFormatMode -or
    $catalogProjectionRetryMode
$catalogProjectionExpectedByteLength = if ($catalogHeaderFollowupMode -or
        $dataPackVersionHeaderRetryMode) {
    139L
}
elseif ($catalogParserExactFormatMode) {
    131L
}
else { 132L }
$catalogProjectionExpectedSha256 = if ($catalogHeaderFollowupMode -or
        $dataPackVersionHeaderRetryMode) {
    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
}
elseif ($catalogParserExactFormatMode) {
    'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805'
}
else { '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502' }
$measurementModeCode = if ($baselineBackedInteractiveMode) {
    'verified_ten_minute_baseline_backed_interactive_startup'
}
else { 'full_ten_minute_baseline' }
$measurementTargetMilliseconds = [long]$MeasurementSeconds * 1000L
$maximumSampleGapMilliseconds = 0L
$dnsChannelName = 'Microsoft-Windows-DNS-Client/Operational'
$extensionFirewallGroup = 'NLL Phase3B2 Physical P2 V2 Extension'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringSha256Hex {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) |
            ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-SharedReadFileObservation {
    param([string]$Path)
    $fileStream = $null
    $memoryStream = $null
    $sha = $null
    $bytes = $null
    $buffer = New-Object byte[] 65536
    try {
        $shareMode = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $fileStream = [IO.File]::Open($Path, [IO.FileMode]::Open,
            [IO.FileAccess]::Read, $shareMode)
        $targetByteLength = [long]$fileStream.Length
        $remaining = $targetByteLength
        $memoryStream = New-Object IO.MemoryStream
        while ($remaining -gt 0) {
            $requested = [int][Math]::Min([long]$buffer.Length, $remaining)
            $read = $fileStream.Read($buffer, 0, $requested)
            if ($read -le 0) { break }
            $memoryStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
        Assert-True ($memoryStream.Length -eq $targetByteLength) `
            'phase3b2_live_player_log_snapshot_incomplete'
        $bytes = $memoryStream.ToArray()
        $sha = [Security.Cryptography.SHA256]::Create()
        $digest = (($sha.ComputeHash($bytes) | ForEach-Object {
            $_.ToString('x2')
        }) -join '')
        [pscustomobject]@{
            present = $true
            byteLength = $targetByteLength
            sha256 = $digest
            observationModeCode =
                'shared_read_bounded_in_memory_digest_no_raw_persistence'
        }
    }
    finally {
        if ($null -ne $bytes -and $bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
        [Array]::Clear($buffer, 0, $buffer.Length)
        if ($null -ne $sha) { $sha.Dispose() }
        if ($null -ne $memoryStream) { $memoryStream.Dispose() }
        if ($null -ne $fileStream) { $fileStream.Dispose() }
    }
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
}

function Get-ContainedPath {
    param([string]$Root, [string]$RelativePath, [string]$FailureCode)
    $normalized = $RelativePath.Replace('/', '\')
    Assert-True (-not [IO.Path]::IsPathRooted($normalized) -and
        $normalized -notmatch '(^|\\)\.\.(\\|$)' -and
        $normalized -notmatch ':') $FailureCode
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $fullPath = [IO.Path]::GetFullPath((Join-Path $fullRoot $normalized))
    Assert-True ($fullPath.StartsWith(
        $fullRoot + '\', [StringComparison]::OrdinalIgnoreCase)) $FailureCode
    $fullPath
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

function Get-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    if ($ProcessId -le 0) { return $null }
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $process -or $process.ProcessName -cne $ExpectedName) {
        return $null
    }
    $process
}

function Stop-PinnedProcess {
    param([int]$ProcessId, [string]$ExpectedName)
    $process = Get-PinnedProcess $ProcessId $ExpectedName
    if ($null -ne $process) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $ProcessId -Timeout 15 -ErrorAction SilentlyContinue
    }
}

function Get-EventData {
    param($Event)
    $values = @{}
    $xml = [xml]$Event.ToXml()
    foreach ($item in @($xml.Event.EventData.Data)) {
        if ($null -ne $item.Name) {
            $values[[string]$item.Name] = [string]$item.'#text'
        }
    }
    $values
}

function Get-DnsChannelEnabled {
    param([string]$ChannelName)
    $configuration = New-Object -TypeName `
        'System.Diagnostics.Eventing.Reader.EventLogConfiguration' `
        -ArgumentList $ChannelName
    try { [bool]$configuration.IsEnabled }
    finally { $configuration.Dispose() }
}

function Set-DnsChannelEnabled {
    param([string]$ChannelName, [bool]$Enabled)
    $configuration = New-Object -TypeName `
        'System.Diagnostics.Eventing.Reader.EventLogConfiguration' `
        -ArgumentList $ChannelName
    try {
        $configuration.IsEnabled = $Enabled
        $configuration.SaveChanges()
    }
    finally { $configuration.Dispose() }
}

function Restore-ObservationPolicy {
    if ($script:auditBackupCreated -and -not $script:auditRestored) {
        & (Join-Path $env:WINDIR 'System32\auditpol.exe') /restore `
            "/file:$script:auditBackupPath" | Out-Null
        $script:auditRestored = $LASTEXITCODE -eq 0
    }
    if ($null -ne $script:dnsOriginalEnabled -and
        -not $script:dnsChannelRestored) {
        try {
            Set-DnsChannelEnabled $script:dnsChannelName `
                ([bool]$script:dnsOriginalEnabled)
            $script:dnsChannelRestored =
                (Get-DnsChannelEnabled $script:dnsChannelName) -eq
                    [bool]$script:dnsOriginalEnabled
        }
        catch { $script:dnsChannelRestored = $false }
    }
}

function Get-SanitizedDnsObservation {
    param([DateTimeOffset]$NotBeforeUtc)
    $knownDomains = @(
        'global-lobby.nikke-kr.com', 'cloud.nikke-kr.com',
        'jp-lobby.nikke-kr.com', 'us-lobby.nikke-kr.com',
        'kr-lobby.nikke-kr.com', 'sea-lobby.nikke-kr.com',
        'hmt-lobby.nikke-kr.com', 'aws-na-dr.intlgame.com',
        'sg-vas.intlgame.com', 'aws-na.intlgame.com',
        'na-community.playerinfinite.com', 'common-web.intlgame.com',
        'li-sg.intlgame.com', 'na.fleetlogd.com',
        'www.jupiterlauncher.com', 'data-aws-na.intlgame.com', 'sentry.io'
    )
    $events = @(Get-WinEvent -FilterHashtable @{
            LogName = $dnsChannelName
            StartTime = $NotBeforeUtc.LocalDateTime
        } -ErrorAction SilentlyContinue)
    $observed = [Collections.Generic.List[object]]::new()
    foreach ($event in $events) {
        $data = Get-EventData $event
        $queryName = $null
        foreach ($name in @('QueryName', 'HostName', 'Name')) {
            if ($data.ContainsKey($name) -and [string]$data[$name]) {
                $queryName = ([string]$data[$name]).Trim().TrimEnd('.').ToLowerInvariant()
                break
            }
        }
        if (-not $queryName -or $queryName -notmatch
            '^[a-z0-9][a-z0-9.-]*[a-z0-9]$') { continue }
        $roleCode = if ($queryName -ceq 'global-match.nikke-kr.com') {
            'admitted_global_match_endpoint'
        }
        elseif ($queryName -in $knownDomains) { 'base_loopback_contract_endpoint' }
        else { 'other_name_sha256_' + (Get-StringSha256Hex $queryName) }
        $status = $null
        foreach ($statusName in @('QueryStatus', 'Status')) {
            if ($data.ContainsKey($statusName)) {
                $status = [string]$data[$statusName]
                break
            }
        }
        $observed.Add([pscustomobject]@{
            RoleCode = $roleCode
            StatusCode = if ($status) { $status } else { 'not_reported' }
        })
    }
    $groups = @($observed | Group-Object RoleCode, StatusCode |
        Sort-Object Name | ForEach-Object {
            [ordered]@{
                roleCode = [string]$_.Group[0].RoleCode
                statusCode = [string]$_.Group[0].StatusCode
                count = $_.Count
            }
        })
    [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-v2-dns-observation/v1'
        eventCount = $events.Count
        classifiedQueryCount = $observed.Count
        admittedGlobalMatchQueryCount = @($observed | Where-Object {
                $_.RoleCode -ceq 'admitted_global_match_endpoint'
            }).Count
        rawQueryNamePersisted = $false
        groups = $groups
    }
}

function Get-SanitizedWfpObservation {
    param([DateTimeOffset]$NotBeforeUtc, [hashtable]$PidRoles)
    $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Security'
            Id = @(5156, 5157)
            StartTime = $NotBeforeUtc.LocalDateTime
        } -ErrorAction SilentlyContinue)
    $observed = [Collections.Generic.List[object]]::new()
    foreach ($event in $events) {
        $data = Get-EventData $event
        $pidText = [string]$data['ProcessID']
        $pidValue = 0
        if (-not [int]::TryParse($pidText, [ref]$pidValue) -or
            -not $PidRoles.ContainsKey($pidValue)) { continue }
        $destination = [string]$data['DestAddress']
        $destinationClass = if ($destination -in @(
                '0.0.0.0', '127.0.0.1', '::', '::1')) {
            'loopback_or_unspecified'
        }
        else { 'non_loopback' }
        $observed.Add([pscustomobject]@{
            ProgramRoleCode = [string]$PidRoles[$pidValue]
            ActionCode = if ($event.Id -eq 5157) { 'blocked' } else { 'allowed' }
            DestinationClassCode = $destinationClass
            DestinationPort = [string]$data['DestPort']
            DirectionCode = [string]$data['Direction']
        })
    }
    $groups = @($observed | Group-Object ProgramRoleCode, ActionCode,
        DestinationClassCode, DestinationPort, DirectionCode |
        Sort-Object Name | ForEach-Object {
            [ordered]@{
                programRoleCode = [string]$_.Group[0].ProgramRoleCode
                actionCode = [string]$_.Group[0].ActionCode
                destinationClassCode =
                    [string]$_.Group[0].DestinationClassCode
                destinationPort = [string]$_.Group[0].DestinationPort
                directionCode = [string]$_.Group[0].DirectionCode
                count = $_.Count
            }
        })
    [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-v2-wfp-observation/v1'
        matchingEventCount = $observed.Count
        allowedLoopbackCount = @($observed | Where-Object {
                $_.ActionCode -eq 'allowed' -and
                $_.DestinationClassCode -eq 'loopback_or_unspecified'
            }).Count
        allowedNonLoopbackCount = @($observed | Where-Object {
                $_.ActionCode -eq 'allowed' -and
                $_.DestinationClassCode -eq 'non_loopback'
            }).Count
        blockedNonLoopbackCount = @($observed | Where-Object {
                $_.ActionCode -eq 'blocked' -and
                $_.DestinationClassCode -eq 'non_loopback'
            }).Count
        rawAddressPersisted = $false
        groups = $groups
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
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsBackupPath =
    'C:\NLL\Backups\Phase3B2\PhysicalP2-v2\hosts.before.bin'
$stdoutPath = Join-Path $runRoot 'server.stdout.log'
$stderrPath = Join-Path $runRoot 'server.stderr.log'
$requestStagePath = Join-Path $runRoot 'server-request-stage.jsonl'
$databaseBeforePath = Join-Path $runRoot 'db.before.bin'
$runStartPath = Join-Path $runRoot 'run-start.receipt.json'
$measurementPath = Join-Path $runRoot 'ten-minute-measurement.receipt.json'
$healthPath = Join-Path $runRoot 'client-health-samples.json'
$dnsPath = Join-Path $runRoot 'dns-observation.json'
$wfpPath = Join-Path $runRoot 'wfp-observation.json'
$requestSummaryPath = Join-Path $runRoot 'server-request-stage-summary.json'
$failurePath = Join-Path $runRoot 'run-failure.receipt.json'
$auditBackupPath = Join-Path $runRoot 'audit-policy.before.csv'
    $fullRetryAuthorizationPath =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\live-log-seal-repair.receipt.json'
    $interactiveAuthorizationPath =
        'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\baseline-backed-interactive-repair.receipt.json'
    $retryAuthorizationPath = if ($catalogSetRetryMode) {
        $catalogSetPointerPath
    }
    elseif ($dataPackVersionHeaderRetryMode) {
        $dataPackVersionHeaderAuthorizationPath
    }
    elseif ($resourceHostMapRetryMode) {
        $resourceHostMapAuthorizationPath
    }
    elseif ($catalogParserExactRetryMode) {
        $catalogParserExactAuthorizationPath
    }
    elseif ($catalogProjectionRetryMode) {
        $catalogProjectionAuthorizationPath
    }
    elseif ($baselineBackedInteractiveMode) {
        $interactiveAuthorizationPath
    }
    else { $fullRetryAuthorizationPath }
    $retryConsumptionPath = Join-Path $P2EvidenceRoot $(if (
            $catalogSqliteTransportMode) {
            'catalog-sqlite-transport-retry.consumed.json'
        }
        elseif ($catalogSetRetryMode) {
            'exact-catalog-set-retry.consumed.json'
        }
        elseif ($dataPackVersionHeaderRetryMode) {
            'datapack-version-header-retry.consumed.json'
        }
        elseif ($resourceHostMapRetryMode) {
            'resource-host-map-retry.consumed.json'
        }
        elseif ($catalogParserExactRetryMode) {
            'catalog-parser-exact-retry.consumed.json'
        }
        elseif ($catalogProjectionRetryMode) {
            'catalog-version-projection-retry.consumed.json'
        }
        elseif ($baselineBackedInteractiveMode) {
            'baseline-backed-interactive-retry.consumed.json'
        }
        else { 'live-log-seal-retry.consumed.json' })

try {
    $stageCode = 'physical_boundary_profile_and_contract_preflight'
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_physical_p2_v2_start_requires_administrator'
    $bootDisk = Get-Partition -DriveLetter C | Get-Disk
    $samsungDisk = Get-Partition -DriveLetter E | Get-Disk
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $deviceGuard = Get-CimInstance `
        -Namespace root\Microsoft\Windows\DeviceGuard `
        -ClassName Win32_DeviceGuard
    $runningSecurityServices = @($deviceGuard.SecurityServicesRunning |
        Where-Object { $null -ne $_ -and [int]$_ -ne 0 })
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $profileRoot = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile)
    $localLowRoot = Join-Path $profileRoot 'AppData\LocalLow'
    $playerLogPath = Join-Path $localLowRoot `
        'com.proximabeta\NIKKE\Player.log'
    Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem -and
        $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        -not [bool]$computerSystem.HypervisorPresent -and
        [int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 0 -and
        $runningSecurityServices.Count -eq 0 -and
        (($identity.Name -split '\\')[-1] -ceq 'nlloperator') -and
        [IO.Path]::GetFullPath($profileRoot).TrimEnd('\') -ceq
            'C:\Users\nlloperator' -and
        (Test-Path -LiteralPath $localLowRoot -PathType Container)) `
        'phase3b2_physical_p2_v2_boundary_or_profile_invalid'
    $dedicatedCacheDirectories = @(Get-ChildItem -LiteralPath $localLowRoot `
        -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '(?i)nikke|shift[ _-]*up|level[ _-]*infinite'
        })
    Assert-True ($dedicatedCacheDirectories.Count -gt 0 -and
        @($dedicatedCacheDirectories | Where-Object {
            $_.Attributes -band [IO.FileAttributes]::ReparsePoint
        }).Count -eq 0 -and
        (Test-Path -LiteralPath $retryAuthorizationPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath $retryConsumptionPath)) `
        'phase3b2_physical_p2_v2_retry_authorization_or_cache_invalid'
    $retryAuthorization = Get-Content -LiteralPath $retryAuthorizationPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($baselineBackedInteractiveMode) {
        $baselineRunRoot = Join-Path $P2EvidenceRoot `
            '78c37245-ea49-442d-becf-b1e871f98d68'
        $baselineMeasurementPath = Join-Path $baselineRunRoot `
            'ten-minute-measurement.receipt.json'
        $baselineRunStartPath = Join-Path $baselineRunRoot `
            'run-start.receipt.json'
        $baselineFailurePath = Join-Path $baselineRunRoot `
            'run-failure.receipt.json'
        Assert-True ($MeasurementSeconds -eq 30 -and
            $SampleIntervalSeconds -eq 2 -and
            (Test-PathDigest $baselineMeasurementPath 2696L `
                '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538') -and
            (Test-PathDigest $baselineRunStartPath 2096L `
                '777657d03588a4c8a32d35f350f1faaee74eb1a50ce99cb8407d2b33dd06f5ac') -and
            (Test-PathDigest $baselineFailurePath 1717L `
                '2ea848a0e066226701a635441ec9b94f55f313c9cf2194789f068b2b2fa3a782')) `
            'phase3b2_physical_p2_v2_interactive_baseline_invalid'
        if ($catalogSetRetryMode) {
            Assert-True (Test-PathDigest $catalogSetPointerPath 707L `
                '5b015177c6b17339cb13989f9056d024831c1b03ff6544c4bcaeb4d676fc47a8') `
                'phase3b2_physical_p2_v2_catalog_set_pointer_digest_invalid'
            Assert-True ($retryAuthorization.contractId -ceq
                    'nll/phase3b2-exact-catalog-offline-deployment-pointer/v1' -and
                $retryAuthorization.deploymentUid -ceq
                    'bf669c3c-fcc8-4d57-9f18-32fee1288862' -and
                [long]$retryAuthorization.deploymentReceiptByteLength -eq
                    1464L -and
                $retryAuthorization.deploymentReceiptSha256 -ceq
                    '27ec27253b56fae39967a5714a315a862908a268a62a7083d45f85df9de592f6' -and
                [long]$retryAuthorization.privateManifestByteLength -eq
                    2677L -and
                $retryAuthorization.privateManifestSha256 -ceq
                    '919a8f6c658a839aa882e3f2e12a9bbedce6e7bec765a8765a160e52adecf39c') `
                'phase3b2_physical_p2_v2_catalog_set_pointer_invalid'

            $catalogEvidenceRoot = Split-Path -Parent $catalogSetPointerPath
            $catalogDeploymentRoot = Get-ContainedPath $catalogEvidenceRoot `
                ([string]$retryAuthorization.deploymentUid) `
                'phase3b2_physical_p2_v2_catalog_set_deployment_path_invalid'
            $catalogDeploymentReceiptPath = Join-Path $catalogDeploymentRoot `
                'deployment.receipt.json'
            $catalogPrivateManifestPath = Join-Path $catalogDeploymentRoot `
                'deployment.private.json'
            Assert-True ((Test-PathDigest $catalogDeploymentReceiptPath `
                    ([long]$retryAuthorization.deploymentReceiptByteLength) `
                    ([string]$retryAuthorization.deploymentReceiptSha256)) -and
                (Test-PathDigest $catalogPrivateManifestPath `
                    ([long]$retryAuthorization.privateManifestByteLength) `
                    ([string]$retryAuthorization.privateManifestSha256))) `
                'phase3b2_physical_p2_v2_catalog_set_receipt_digest_invalid'

            $catalogDeploymentReceipt = Get-Content -LiteralPath `
                $catalogDeploymentReceiptPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $catalogPrivateManifest = Get-Content -LiteralPath `
                $catalogPrivateManifestPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            Assert-True ($catalogDeploymentReceipt.contractId -ceq
                    'nll/phase3b2-exact-catalog-offline-deployment/v1' -and
                $catalogDeploymentReceipt.deploymentUid -ceq
                    'bf669c3c-fcc8-4d57-9f18-32fee1288862' -and
                $catalogDeploymentReceipt.acquisitionAssessmentUid -ceq
                    '3307c851-bd77-4f38-8808-91ddb3b7800d' -and
                $catalogDeploymentReceipt.acquisitionReceiptSha256 -ceq
                    '87d22ab630bea3851ad3af6b8a2b3be009c7f49b9320529186261bb38c24ae92' -and
                $catalogDeploymentReceipt.analysisReceiptSha256 -ceq
                    '97ffd73c26c24b2e8bd54170b42c4f163336bc3df56d172cd60c62e43184ce4b' -and
                $catalogDeploymentReceipt.privateDeploymentManifestSha256 -ceq
                    '919a8f6c658a839aa882e3f2e12a9bbedce6e7bec765a8765a160e52adecf39c' -and
                [int]$catalogDeploymentReceipt.catalogBodyCount -eq 3 -and
                [int]$catalogDeploymentReceipt.detachedSignatureCount -eq 3 -and
                [int]$catalogDeploymentReceipt.appliedMemberCount -eq 6 -and
                [long]$catalogDeploymentReceipt.appliedContentByteLength -eq
                    19520185L -and
                [int]$catalogDeploymentReceipt.preexistingTargetCount -eq 0 -and
                [int]$catalogDeploymentReceipt.exactAppliedTargetCount -eq 6 -and
                $catalogDeploymentReceipt.runtimeCacheModified -and
                -not $catalogDeploymentReceipt.physicalClientModified -and
                -not $catalogDeploymentReceipt.primaryInstallModified -and
                -not $catalogDeploymentReceipt.officialLauncherModified -and
                -not $catalogDeploymentReceipt.officialOutboundUsed -and
                -not $catalogDeploymentReceipt.serverExecutionStarted -and
                -not $catalogDeploymentReceipt.clientExecutionStarted -and
                $catalogDeploymentReceipt.verdictCode -ceq
                    'exact_six_member_catalog_set_staged_and_applied') `
                'phase3b2_physical_p2_v2_catalog_set_deployment_invalid'
            Assert-True ($catalogPrivateManifest.contractId -ceq
                    'nll/phase3b2-exact-catalog-offline-deployment-private/v1' -and
                $catalogPrivateManifest.deploymentUid -ceq
                    'bf669c3c-fcc8-4d57-9f18-32fee1288862' -and
                $catalogPrivateManifest.acquisitionAssessmentUid -ceq
                    '3307c851-bd77-4f38-8808-91ddb3b7800d' -and
                @($catalogPrivateManifest.members).Count -eq 6) `
                'phase3b2_physical_p2_v2_catalog_set_private_manifest_invalid'

            $expectedCatalogMembers = [ordered]@{
                core_body = @(
                    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\core\150.6.b15\catalog.db',
                    10552026L,
                    'a1dc8425ca034447a1e495d02f02e10fcbf92a772453aebfc214c3a88dd21d52')
                core_signature = @(
                    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\core\150.6.b15\catalog.db.nds',
                    96L,
                    '9c1ea4e701f0ca770d95dfa4607af233b2d7123cd1d3db6897155f107740f966')
                dp_body = @(
                    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\dp\1d5645e\catalog.db',
                    8630492L,
                    '326c029414ccf06ff429dd2e017a8bbae6dc39fd295682c67f333a8611a6e5cb')
                dp_signature = @(
                    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\dp\1d5645e\catalog.db.nds',
                    96L,
                    '16b319314a4ba278e9ae229b51f7ec462819a6566c595050ccf55e2f1b7fbfbc')
                fd_body = @(
                    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\fd\85b12fc\catalog.db',
                    337379L,
                    'af0307449ddb4455357c7d2e4e9bf363f5bb2d4a8615e11e37939629b2acc04c')
                fd_signature = @(
                    'prdenv\150-b059c3f36c\StandaloneWindows64\pck\fd\85b12fc\catalog.db.nds',
                    96L,
                    '876618c9a45663c60b09683f6c090b952edc76b7e9c9997d13085e30e8d9427c')
            }
            $serverCacheRoot = Join-Path $serverRoot 'cache'
            foreach ($roleCode in $expectedCatalogMembers.Keys) {
                $matchingMembers = @($catalogPrivateManifest.members |
                    Where-Object roleCode -CEQ $roleCode)
                Assert-True ($matchingMembers.Count -eq 1) `
                    'phase3b2_physical_p2_v2_catalog_set_member_shape_invalid'
                $member = $matchingMembers[0]
                $expected = $expectedCatalogMembers[$roleCode]
                Assert-True ($member.relativePath -ceq $expected[0] -and
                    [long]$member.byteLength -eq [long]$expected[1] -and
                    $member.sha256 -ceq $expected[2] -and
                    -not $member.targetPreexisting -and
                    [long]$member.backupByteLength -eq 0L -and
                    [string]::IsNullOrEmpty([string]$member.backupSha256)) `
                    'phase3b2_physical_p2_v2_catalog_set_member_invalid'
                $runtimeCatalogPath = Get-ContainedPath $serverCacheRoot `
                    ([string]$member.relativePath) `
                    'phase3b2_physical_p2_v2_catalog_set_runtime_path_invalid'
                Assert-True (Test-PathDigest $runtimeCatalogPath `
                    ([long]$member.byteLength) ([string]$member.sha256)) `
                    'phase3b2_physical_p2_v2_catalog_set_runtime_digest_invalid'
            }

            if ($catalogHeaderFollowupMode) {
                $catalogHeaderFollowup = Get-Content -LiteralPath `
                    $catalogHeaderFollowupAuthorizationPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json
                $catalogProjectionPath = Join-Path $serverRoot `
                    'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
                Assert-True ($catalogHeaderFollowup.contractId -ceq
                        'nll/phase3b2-exact-catalog-header-followup/v1' -and
                    $catalogHeaderFollowup.failedAssessmentUid -ceq
                        '29083a6a-3f4e-4eec-a57a-4d28b1459524' -and
                    $catalogHeaderFollowup.failureRequestPathCode -ceq
                        'prdenv_150_b059c3f36c_standalonewindows64_pck_latest_651' -and
                    $catalogHeaderFollowup.playerLogSha256 -ceq
                        '268ed945f33b0fcbbc72c3889810ca282f6656d43cba020347f5f8a65865779f' -and
                    $catalogHeaderFollowup.catalogDeploymentUid -ceq
                        'bf669c3c-fcc8-4d57-9f18-32fee1288862' -and
                    [long]$catalogHeaderFollowup.sourceLcvByteLength -eq 3775L -and
                    $catalogHeaderFollowup.sourceLcvSha256 -ceq
                        'ede45120d1531ea1639dc4237bb8ff0061b356ccefdf8fd53d9edcd98f2e9054' -and
                    [long]$catalogHeaderFollowup.projectedHeaderByteLength -eq 139L -and
                    $catalogHeaderFollowup.projectedHeaderSha256 -ceq
                        '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a' -and
                    $catalogHeaderFollowup.databaseRestored -and
                    $catalogHeaderFollowup.sqliteRuntimeRemoved -and
                    $catalogHeaderFollowup.activePointerArchived -and
                    $catalogHeaderFollowup.exactRetryConsumptionArchived -and
                    $catalogHeaderFollowup.priorCompletionPointerPreserved -and
                    $catalogHeaderFollowup.singleFollowupRetryAuthorized -and
                    -not $catalogHeaderFollowup.officialOutboundUsed -and
                    $catalogHeaderFollowup.appliedStartToolSha256 -ceq
                        (Get-Sha256Hex $MyInvocation.MyCommand.Path) -and
                    (Test-PathDigest $catalogProjectionPath 139L `
                        '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a')) `
                    'phase3b2_physical_p2_v2_catalog_header_followup_invalid'
            }

            if ($catalogSqliteTransportMode) {
                $catalogSqliteTransport = Get-Content -LiteralPath `
                    $catalogSqliteTransportAuthorizationPath -Raw -Encoding UTF8 |
                    ConvertFrom-Json
                Assert-True ($catalogSqliteTransport.contractId -ceq
                        'nll/phase3b2-p2-v2-catalog-sqlite-transport-repair/v1' -and
                    $catalogSqliteTransport.failedAssessmentUid -ceq
                        '083d46b5-696f-407a-9d1c-0f8a5c86a4e1' -and
                    $catalogSqliteTransport.failureReasonCode -ceq
                        'encrypted_nkdb_served_as_sqlite_catalog_db' -and
                    [int]$catalogSqliteTransport.encryptedCatalogBodyCount -eq 3 -and
                    [int]$catalogSqliteTransport.decryptedSqliteBodyCount -eq 3 -and
                    [int]$catalogSqliteTransport.dedicatedCatalogCacheBackupCount -eq 6 -and
                    [int]$catalogSqliteTransport.dedicatedCatalogCacheResetCount -eq 6 -and
                    $catalogSqliteTransport.localOnlyCatalogProjectionEnabled -and
                    $catalogSqliteTransport.catalogProjectionScopeCode -ceq
                        'local_only_catalog_db_nkdb_magic_only' -and
                    $catalogSqliteTransport.exactCatalogSetPreserved -and
                    $catalogSqliteTransport.projectedHeaderApplied -and
                    $catalogSqliteTransport.databaseRestored -and
                    $catalogSqliteTransport.sqliteRuntimeRemoved -and
                    $catalogSqliteTransport.singleTransportRetryAuthorized -and
                    -not $catalogSqliteTransport.retryConsumed -and
                    -not $catalogSqliteTransport.officialOutboundUsed -and
                    -not $catalogSqliteTransport.officialIdentityPersisted -and
                    -not $catalogSqliteTransport.officialCredentialPersisted -and
                    (Test-PathDigest $serverDllPath `
                        ([long]$catalogSqliteTransport.appliedServerDllByteLength) `
                        ([string]$catalogSqliteTransport.appliedServerDllSha256)) -and
                    (Test-PathDigest $preparationPath `
                        ([long]$catalogSqliteTransport.appliedPreparationReceiptByteLength) `
                        ([string]$catalogSqliteTransport.appliedPreparationReceiptSha256)) -and
                    (Test-PathDigest $catalogProjectionPath 139L `
                        '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a') -and
                    $catalogSqliteTransport.appliedStartToolSha256 -ceq
                        (Get-Sha256Hex $MyInvocation.MyCommand.Path)) `
                    'phase3b2_physical_p2_v2_catalog_sqlite_transport_invalid'
            }
        }
        elseif ($dataPackVersionHeaderRetryMode) {
            $mapFailurePath = Join-Path $P2EvidenceRoot `
                'deafa3e3-d889-4a09-8a66-fc7dc3e27305\resource-host-map-failure.receipt.json'
            $mapRecoveryPath = Join-Path $P2EvidenceRoot `
                'deafa3e3-d889-4a09-8a66-fc7dc3e27305\resource-host-map-cold-recovery.receipt.json'
            $priorMapConsumptionPath = Join-Path $P2EvidenceRoot `
                'resource-host-map-retry.consumed.json'
            $catalogProjectionPath = Join-Path $serverRoot `
                'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
            $projectionReceiptPath =
                'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\datapack-version-header-projection.receipt.json'
            $staticAnalysisPath =
                'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\datapack-version-header-static-analysis.receipt.json'
            $rollbackManifestPath =
                'C:\NLL\Backups\Phase3B2\PhysicalP2-DataPackVersionHeader-v1\rollback.manifest.json'
            $lcvPath =
                'C:\NLL\Clients\NIKKE-150.6.9-Physical\Unity\com_proximabeta_NIKKE\.lcv.dat'
            Assert-True ((Test-PathDigest $mapFailurePath `
                    ([long]$retryAuthorization.failureReceiptByteLength) `
                    ([string]$retryAuthorization.failureReceiptSha256)) -and
                (Test-PathDigest $mapRecoveryPath `
                    ([long]$retryAuthorization.recoveryReceiptByteLength) `
                    ([string]$retryAuthorization.recoveryReceiptSha256)) -and
                (Test-PathDigest $priorMapConsumptionPath 1065L `
                    '003e7c815adff246d29f31c348ecd3d0775dc793c74b9657d1dd978f6e2a3779') -and
                (Test-PathDigest $lcvPath 3775L `
                    'ede45120d1531ea1639dc4237bb8ff0061b356ccefdf8fd53d9edcd98f2e9054') -and
                (Test-PathDigest $catalogProjectionPath 139L `
                    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a') -and
                (Test-PathDigest $projectionReceiptPath `
                    ([long]$retryAuthorization.projectionReceiptByteLength) `
                    ([string]$retryAuthorization.projectionReceiptSha256)) -and
                (Test-PathDigest $staticAnalysisPath `
                    ([long]$retryAuthorization.staticAnalysisReceiptByteLength) `
                    ([string]$retryAuthorization.staticAnalysisReceiptSha256)) -and
                (Test-PathDigest $rollbackManifestPath `
                    ([long]$retryAuthorization.rollbackManifestByteLength) `
                    ([string]$retryAuthorization.rollbackManifestSha256)) -and
                (Test-PathDigest $serverDllPath 15371264L `
                    'af7a4165e9ff2da5f4e0f4117ab546e04ddfc095d4e1e9916b4bc83458f8c58c') -and
                $retryAuthorization.contractId -ceq
                    'nll/phase3b2-p2-v2-datapack-version-header-repair/v1' -and
                $retryAuthorization.failedAssessmentUid -ceq
                    'deafa3e3-d889-4a09-8a66-fc7dc3e27305' -and
                $retryAuthorization.failureReasonCode -ceq
                    'first_line_consumed_as_standalone_version_core_entry_omitted' -and
                $retryAuthorization.standaloneVersionHeader -ceq '1c27990' -and
                [int]$retryAuthorization.projectedLineCount -eq 8 -and
                [long]$retryAuthorization.projectedByteLength -eq 139L -and
                $retryAuthorization.projectedSha256 -ceq
                    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a' -and
                $retryAuthorization.nativeFirstLineConsumedAsVersion -and
                $retryAuthorization.nativeRemainingLinesParsedAsEntries -and
                $retryAuthorization.coreEntryPresentAfterHeader -and
                $retryAuthorization.resourceHostMapMutationRolledBack -and
                $retryAuthorization.singleDataPackVersionHeaderRetryAuthorized -and
                -not $retryAuthorization.retryConsumed -and
                -not $retryAuthorization.endpointContractChanged -and
                [int]$retryAuthorization.interactiveMeasurementSeconds -eq 30) `
                'phase3b2_physical_p2_v2_datapack_header_authorization_invalid'
            $mapFailure = Get-Content -LiteralPath $mapFailurePath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            $mapRecovery = Get-Content -LiteralPath $mapRecoveryPath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            $projectionReceipt = Get-Content -LiteralPath $projectionReceiptPath `
                -Raw -Encoding UTF8 | ConvertFrom-Json
            $staticAnalysis = Get-Content -LiteralPath $staticAnalysisPath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            Assert-True ($mapFailure.contractId -ceq
                    'nll/phase3b2-p2-v2-resource-host-map-failure/v1' -and
                $mapFailure.resourceHostVersionMapHypothesisFalsified -and
                $mapFailure.missingDictionaryKeyCode -ceq 'core' -and
                $mapRecovery.contractId -ceq
                    'nll/phase3b2-p2-v2-resource-host-map-cold-recovery/v1' -and
                $mapRecovery.databaseRestored -and
                $mapRecovery.sqliteRuntimeRemoved -and
                $mapRecovery.resourceHostMapMutationRolledBack -and
                $projectionReceipt.contractId -ceq
                    'nll/phase3b2-local-content-version-projection/v3' -and
                $projectionReceipt.standaloneVersionHeader -ceq '1c27990' -and
                [int]$projectionReceipt.projectedLineCount -eq 8 -and
                [int]$projectionReceipt.entryCount -eq 7 -and
                -not $projectionReceipt.standaloneVersionMatchesLatestPostfix -and
                [long]$projectionReceipt.projectedByteLength -eq 139L -and
                $projectionReceipt.projectedSha256 -ceq
                    '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a' -and
                $staticAnalysis.contractId -ceq
                    'nll/phase3b2-datapack-version-header-static-analysis/v1' -and
                $staticAnalysis.runtimeHelpersMethodCode -ceq
                    'RuntimeHelpers.GetSubArray<object>' -and
                $staticAnalysis.runtimeHelpersMethodRva -ceq '0x12fb150' -and
                $staticAnalysis.firstLineRoleCode -ceq
                    'standalone_datapack_version' -and
                $staticAnalysis.remainingLineRoleCode -ceq
                    'named_subentry') `
                'phase3b2_physical_p2_v2_datapack_header_evidence_invalid'
        }
        elseif ($resourceHostMapRetryMode) {
            $coreFailurePath = Join-Path $P2EvidenceRoot `
                'cf8433fe-ea3d-4594-94d3-863bd0846cd3\core-key-failure.receipt.json'
            $coreRecoveryPath = Join-Path $P2EvidenceRoot `
                'cf8433fe-ea3d-4594-94d3-863bd0846cd3\core-key-cold-recovery.receipt.json'
            $priorExactConsumptionPath = Join-Path $P2EvidenceRoot `
                'catalog-parser-exact-retry.consumed.json'
            $catalogProjectionPath = Join-Path $serverRoot `
                'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
            $deploymentReceiptPath =
                'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\deployment.receipt.json'
            $gameConfigPath = Join-Path $serverRoot 'gameconfig.json'
            Assert-True ((Test-PathDigest $coreFailurePath `
                    ([long]$retryAuthorization.failureReceiptByteLength) `
                    ([string]$retryAuthorization.failureReceiptSha256)) -and
                (Test-PathDigest $coreRecoveryPath `
                    ([long]$retryAuthorization.recoveryReceiptByteLength) `
                    ([string]$retryAuthorization.recoveryReceiptSha256)) -and
                (Test-PathDigest $priorExactConsumptionPath 1022L `
                    'da5c1a73d878b6c5eb2c11d0bb2063a2f1d51eb10c9320bfc4c9fad112a8099e') -and
                (Test-PathDigest $catalogProjectionPath 131L `
                    'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805') -and
                (Test-PathDigest $serverDllPath `
                    ([long]$retryAuthorization.appliedServerDllByteLength) `
                    ([string]$retryAuthorization.appliedServerDllSha256)) -and
                (Test-PathDigest $gameConfigPath `
                    ([long]$retryAuthorization.appliedGameConfigByteLength) `
                    ([string]$retryAuthorization.appliedGameConfigSha256)) -and
                (Test-PathDigest $deploymentReceiptPath `
                    ([long]$retryAuthorization.deploymentReceiptByteLength) `
                    ([string]$retryAuthorization.deploymentReceiptSha256)) -and
                $retryAuthorization.contractId -ceq
                    'nll/phase3b2-p2-v2-resource-host-map-repair/v1' -and
                $retryAuthorization.failedAssessmentUid -ceq
                    'cf8433fe-ea3d-4594-94d3-863bd0846cd3' -and
                $retryAuthorization.failureReasonCode -ceq
                    'addressable_catalog_group_core_key_missing' -and
                $retryAuthorization.resourceCoreVersion -ceq '150.6.b15' -and
                $retryAuthorization.resourceDataPackVersion -ceq '651' -and
                $retryAuthorization.externalHead -ceq
                    '7fdff8f4341a240e85259b5a1e5fd9be415f5a46' -and
                $retryAuthorization.externalTree -ceq
                    'f042e5843638233b5fb4708829409179669ae934' -and
                [int]$retryAuthorization.handlerIsolationPassedCount -eq 15 -and
                [int]$retryAuthorization.selectedManagerPassedCount -eq 64 -and
                $retryAuthorization.coreVersionMapProjected -and
                $retryAuthorization.dataPackVersionMapProjected -and
                $retryAuthorization.priorCatalogParserExactRetryConsumptionSha256 -ceq
                    'da5c1a73d878b6c5eb2c11d0bb2063a2f1d51eb10c9320bfc4c9fad112a8099e' -and
                $retryAuthorization.singleResourceHostMapRetryAuthorized -and
                -not $retryAuthorization.retryConsumed -and
                -not $retryAuthorization.endpointContractChanged -and
                [int]$retryAuthorization.interactiveMeasurementSeconds -eq 30) `
                'phase3b2_physical_p2_v2_resource_host_map_authorization_invalid'
            $coreFailure = Get-Content -LiteralPath $coreFailurePath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            $coreRecovery = Get-Content -LiteralPath $coreRecoveryPath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            $gameConfig = Get-Content -LiteralPath $gameConfigPath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            Assert-True ($coreFailure.contractId -ceq
                    'nll/phase3b2-p2-v2-core-key-failure/v1' -and
                $coreFailure.missingDictionaryKeyCode -ceq 'core' -and
                $coreRecovery.contractId -ceq
                    'nll/phase3b2-p2-v2-core-key-cold-recovery/v1' -and
                $coreRecovery.databaseRestored -and
                $coreRecovery.sqliteRuntimeRemoved -and
                $gameConfig.ResourceCoreVersion -ceq '150.6.b15' -and
                $gameConfig.ResourceDataPackVersion -ceq '651') `
                'phase3b2_physical_p2_v2_resource_host_map_evidence_invalid'
        }
        elseif ($catalogParserExactRetryMode) {
            $formatFailurePath = Join-Path $P2EvidenceRoot `
                'f7e2bb4a-e661-42bf-b055-d0b2c8a536d3\projection-format-failure.receipt.json'
            $formatRecoveryPath = Join-Path $P2EvidenceRoot `
                'f7e2bb4a-e661-42bf-b055-d0b2c8a536d3\projection-format-cold-recovery.receipt.json'
            $priorProjectionConsumptionPath = Join-Path $P2EvidenceRoot `
                'catalog-version-projection-retry.consumed.json'
            $catalogProjectionPath = Join-Path $serverRoot `
                'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
            $catalogProjectionReceiptPath =
                'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-parser-exact-projection.receipt.json'
            $catalogStaticAnalysisPath =
                'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-parser-static-analysis.receipt.json'
            $catalogRollbackManifestPath =
                'C:\NLL\Backups\Phase3B2\PhysicalP2-CatalogParserExact-v1\rollback.manifest.json'
            $gameAssemblyPath =
                'C:\NLL\Clients\NIKKE-150.6.9-Physical\NIKKE\game\GameAssembly.dll'
            Assert-True ((Test-PathDigest $formatFailurePath 1504L `
                    '44abdcc725b9ba99d4b82aa930e629fdac6c6d117e12e68367b1d5890be51562') -and
                (Test-PathDigest $formatRecoveryPath 1904L `
                    'e5ea78f3dda1f80ad736dfc56e93aac5b273554e000414cf54efb9920b9967aa') -and
                (Test-PathDigest $priorProjectionConsumptionPath 980L `
                    '093892d750f3640e39c51bced08d3f441365357fab61adc685bab15df7b947a8') -and
                (Test-PathDigest $gameAssemblyPath 265846312L `
                    'a4f0b9560ab0c00c9ab4f7ac64eb8e2631c7b70ab9e92ec18bb4944ce3c66954') -and
                (Test-PathDigest $catalogProjectionPath 131L `
                    'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805') -and
                (Test-PathDigest $catalogProjectionReceiptPath `
                    ([long]$retryAuthorization.projectionReceiptByteLength) `
                    ([string]$retryAuthorization.projectionReceiptSha256)) -and
                (Test-PathDigest $catalogStaticAnalysisPath `
                    ([long]$retryAuthorization.staticAnalysisReceiptByteLength) `
                    ([string]$retryAuthorization.staticAnalysisReceiptSha256)) -and
                (Test-PathDigest $catalogRollbackManifestPath `
                    ([long]$retryAuthorization.rollbackManifestByteLength) `
                    ([string]$retryAuthorization.rollbackManifestSha256)) -and
                $retryAuthorization.contractId -ceq
                    'nll/phase3b2-p2-v2-catalog-parser-exact-repair/v1' -and
                $retryAuthorization.failedAssessmentUid -ceq
                    'f7e2bb4a-e661-42bf-b055-d0b2c8a536d3' -and
                $retryAuthorization.failureReceiptSha256 -ceq
                    '44abdcc725b9ba99d4b82aa930e629fdac6c6d117e12e68367b1d5890be51562' -and
                $retryAuthorization.recoveryReceiptSha256 -ceq
                    'e5ea78f3dda1f80ad736dfc56e93aac5b273554e000414cf54efb9920b9967aa' -and
                $retryAuthorization.gameAssemblySha256 -ceq
                    'a4f0b9560ab0c00c9ab4f7ac64eb8e2631c7b70ab9e92ec18bb4944ce3c66954' -and
                $retryAuthorization.parserMethodRva -ceq '0x648bc80' -and
                $retryAuthorization.parserCanonicalizationCode -ceq
                    'entry_name_colon_tag_comma_revision_lf_between_no_terminal_newline_v1' -and
                $retryAuthorization.secondFieldInt32ParseObserved -and
                $retryAuthorization.terminalEmptyLineRejected -and
                [long]$retryAuthorization.projectedByteLength -eq 131L -and
                $retryAuthorization.projectedSha256 -ceq
                    'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805' -and
                $retryAuthorization.priorCatalogProjectionRetryConsumptionSha256 -ceq
                    '093892d750f3640e39c51bced08d3f441365357fab61adc685bab15df7b947a8' -and
                $retryAuthorization.singleCatalogParserExactRetryAuthorized -and
                -not $retryAuthorization.retryConsumed -and
                -not $retryAuthorization.endpointContractChanged -and
                $retryAuthorization.liveRuntimeFilesDeferredToCompletion -and
                [int]$retryAuthorization.interactiveMeasurementSeconds -eq 30) `
                'phase3b2_physical_p2_v2_catalog_parser_exact_authorization_invalid'
            $projectionReceipt = Get-Content `
                -LiteralPath $catalogProjectionReceiptPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $staticAnalysis = Get-Content `
                -LiteralPath $catalogStaticAnalysisPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $rollbackManifest = Get-Content `
                -LiteralPath $catalogRollbackManifestPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            Assert-True ($projectionReceipt.contractId -ceq
                    'nll/phase3b2-local-content-version-projection/v2' -and
                [int]$projectionReceipt.entryCount -eq 7 -and
                $projectionReceipt.parserOrderVerified -and
                $projectionReceipt.noTerminalNewlineVerified -and
                [long]$projectionReceipt.projectedByteLength -eq 131L -and
                $projectionReceipt.projectedSha256 -ceq
                    'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805' -and
                -not $projectionReceipt.officialOutboundUsed -and
                $staticAnalysis.contractId -ceq
                    'nll/phase3b2-catalog-parser-static-analysis/v1' -and
                $staticAnalysis.analysisModeCode -ceq
                    'offline_static_il2cpp_disassembly' -and
                $staticAnalysis.parserMethodRva -ceq '0x648bc80' -and
                $staticAnalysis.splitSeparatorCode -ceq 'lf_char_0x0a' -and
                $staticAnalysis.secondFieldInt32ParseObserved -and
                $staticAnalysis.terminalEmptyLineRejected -and
                -not $staticAnalysis.clientExecutionStarted -and
                $rollbackManifest.contractId -ceq
                    'nll/phase3b2-local-content-version-projection-rollback/v2' -and
                $rollbackManifest.targetWasAbsentBeforeProjection -and
                $rollbackManifest.projectedByteLength -eq 131L -and
                $rollbackManifest.projectedSha256 -ceq
                    'd7898079fa23b140396a952afc3881b51876827a852aa723492f2a6149ead805') `
                'phase3b2_physical_p2_v2_catalog_parser_exact_evidence_invalid'
        }
        elseif ($catalogProjectionRetryMode) {
            $coldRecoveryPath = Join-Path $P2EvidenceRoot `
                'bba01e6c-b457-4705-b251-4959006e0bef\cold-recovery-and-catalog-extraction.receipt.json'
            $priorInteractiveConsumptionPath = Join-Path $P2EvidenceRoot `
                'baseline-backed-interactive-retry.consumed.json'
            $catalogProjectionPath = Join-Path $serverRoot `
                'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
            $catalogProjectionReceiptPath =
                'C:\NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2\catalog-version-projection.receipt.json'
            $catalogRollbackManifestPath =
                'C:\NLL\Backups\Phase3B2\PhysicalP2-CatalogVersionProjection-v1\rollback.manifest.json'
            Assert-True ((Test-PathDigest $coldRecoveryPath 1605L `
                    '0f79f2e295635c5b39bb2523c7cff55403e48d6b10a64e228faa1c05e7029b6d') -and
                (Test-PathDigest $priorInteractiveConsumptionPath 825L `
                    '9a31e53b91fe3c4da4c3c0929573e27f2d946ab5bc985ea76925cb703c32e304') -and
                (Test-PathDigest $catalogProjectionPath 132L `
                    '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502') -and
                (Test-PathDigest $catalogProjectionReceiptPath `
                    ([long]$retryAuthorization.projectionReceiptByteLength) `
                    ([string]$retryAuthorization.projectionReceiptSha256)) -and
                (Test-PathDigest $catalogRollbackManifestPath `
                    ([long]$retryAuthorization.rollbackManifestByteLength) `
                    ([string]$retryAuthorization.rollbackManifestSha256)) -and
                $retryAuthorization.contractId -ceq
                    'nll/phase3b2-p2-v2-catalog-version-projection-repair/v1' -and
                $retryAuthorization.failedAssessmentUid -ceq
                    'bba01e6c-b457-4705-b251-4959006e0bef' -and
                $retryAuthorization.baselineAssessmentUid -ceq
                    '78c37245-ea49-442d-becf-b1e871f98d68' -and
                $retryAuthorization.baselineTenMinuteMeasurementVerified -and
                $retryAuthorization.sourceCacheMissConfirmed -and
                $retryAuthorization.localProjectionVerified -and
                [long]$retryAuthorization.projectedByteLength -eq 132L -and
                $retryAuthorization.projectedSha256 -ceq
                    '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502' -and
                $retryAuthorization.priorInteractiveRetryConsumptionSha256 -ceq
                    '9a31e53b91fe3c4da4c3c0929573e27f2d946ab5bc985ea76925cb703c32e304' -and
                $retryAuthorization.singleCatalogProjectionRetryAuthorized -and
                -not $retryAuthorization.retryConsumed -and
                -not $retryAuthorization.endpointContractChanged -and
                $retryAuthorization.liveRuntimeFilesDeferredToCompletion -and
                [int]$retryAuthorization.interactiveMeasurementSeconds -eq 30) `
                'phase3b2_physical_p2_v2_catalog_projection_authorization_invalid'
            $projectionReceipt = Get-Content `
                -LiteralPath $catalogProjectionReceiptPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $rollbackManifest = Get-Content `
                -LiteralPath $catalogRollbackManifestPath -Raw -Encoding UTF8 |
                ConvertFrom-Json
            Assert-True ($projectionReceipt.contractId -ceq
                    'nll/phase3b2-local-content-version-projection/v1' -and
                [int]$projectionReceipt.entryCount -eq 7 -and
                $projectionReceipt.aggregateRevisionMatchesDp -and
                [long]$projectionReceipt.projectedByteLength -eq 132L -and
                $projectionReceipt.projectedSha256 -ceq
                    '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502' -and
                -not $projectionReceipt.officialOutboundUsed -and
                $rollbackManifest.contractId -ceq
                    'nll/phase3b2-local-content-version-projection-rollback/v1' -and
                $rollbackManifest.targetWasAbsentBeforeProjection -and
                $rollbackManifest.projectedSha256 -ceq
                    '63f5ddcd289e55717ed0087b44d673837da14423e28bf363fa5f2092ca1a3502') `
                'phase3b2_physical_p2_v2_catalog_projection_evidence_invalid'
        }
        else {
            Assert-True ($retryAuthorization.contractId -ceq
                    'nll/phase3b2-p2-v2-baseline-backed-interactive-repair/v1' -and
                $retryAuthorization.baselineAssessmentUid -ceq
                    '78c37245-ea49-442d-becf-b1e871f98d68' -and
                $retryAuthorization.baselineTenMinuteMeasurementVerified -and
                $retryAuthorization.serverSelectionObserved -and
                $retryAuthorization.singleInteractiveRetryAuthorized -and
                [int]$retryAuthorization.interactiveMeasurementSeconds -eq 30 -and
                -not $retryAuthorization.endpointContractChanged -and
                $retryAuthorization.liveRuntimeFilesDeferredToCompletion) `
                'phase3b2_physical_p2_v2_interactive_authorization_invalid'
        }
    }
    else {
        $priorFailurePath = Join-Path $P2EvidenceRoot `
            '88245ca5-08d2-4b09-a855-e875bf37bc22\run-failure.receipt.json'
        Assert-True ($retryAuthorization.contractId -ceq
                'nll/phase3b2-p2-v2-live-log-seal-repair/v1' -and
            $retryAuthorization.failedAssessmentUid -ceq
                '88245ca5-08d2-4b09-a855-e875bf37bc22' -and
            $retryAuthorization.singleRetryAuthorized -and
            -not $retryAuthorization.endpointContractChanged -and
            $retryAuthorization.serverSelectionObserved -and
            $retryAuthorization.livePlayerLogSharedReadEnabled -and
            -not $retryAuthorization.rawPlayerLogCopied -and
            $retryAuthorization.sailNamedPipePayloadWritten -and
            $retryAuthorization.sailNamedPipeClosedAfterPayload -and
            $retryAuthorization.sailPayloadClearedAfterWrite -and
            $retryAuthorization.sailSharedMemoryRetainedForClientLifetime -and
            $retryAuthorization.sailHandoffLifecycleCode -ceq
                'payload_then_pipe_eof_shared_memory_retained' -and
            $retryAuthorization.blackScreenRegressionCauseCode -ceq
                'sail_named_pipe_eof_withheld_and_payload_zeroization_race' -and
            (Test-PathDigest $priorFailurePath 1606L `
                '7a049da69dcbb077fbb5eeff8f8ab6ddfcbfc7063bda2520a76d8915cd64e139') -and
            [int]$retryAuthorization.admittedEndpointCount -eq 1) `
            'phase3b2_physical_p2_v2_retry_authorization_invalid'
    }
    Assert-True (-not (Test-Path -LiteralPath $activePointerPath) -and
        -not (Test-Path -LiteralPath $runRoot) -and
        -not (Test-Path -LiteralPath $protectedRunRoot) -and
        @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p2_v2_active_or_runtime_present'

    $preparation = Get-Content -LiteralPath $preparationPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($preparation.contractId -ceq
            'nll/phase3b2-physical-p2-v2-preparation/v1' -and
        $preparation.dedicatedWindowsAccountVerified -and
        $preparation.dedicatedLocalLowVerifiedCleanBeforeFirstRun -and
        [int]$preparation.mappedDomainCount -eq 18 -and
        [int]$preparation.extensionFirewallRuleCount -eq 1 -and
        [int]$preparation.minimumMeasurementSeconds -eq 600 -and
        $preparation.requestStageObservationEnabled -and
        -not $preparation.clientExecutionStarted) `
        'phase3b2_physical_p2_v2_preparation_invalid'
    Assert-True ((Test-PathDigest $hostsPath `
            ([long]$preparation.hostsAppliedByteLength) `
            ([string]$preparation.hostsAppliedSha256)) -and
        (Test-PathDigest $hostsBackupPath 1690L `
            'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') -and
        (Test-PathDigest $serverDllPath `
            ([long]$preparation.serverDllByteLength) `
            ([string]$preparation.serverDllSha256)) -and
        (Test-PathDigest $clientPath 794152L `
            '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30')) `
        'phase3b2_physical_p2_v2_runtime_pin_mismatch'
    $extensionRules = @(Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue)
    Assert-True ($extensionRules.Count -eq 1 -and
        @(Get-NetFirewallRule -Group 'NLL Phase3B2 Physical Isolation' `
            -ErrorAction SilentlyContinue).Count -eq 17 -and
        @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object LocalPort -In 80, 443).Count -eq 0 -and
        @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
            Where-Object LocalPort -EQ 443).Count -eq 0 -and
        @(Get-Process -Name nikke_launcher `
            -ErrorAction SilentlyContinue).Count -eq 0 -and
        @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0) `
        'phase3b2_physical_p2_v2_runtime_precondition_invalid'

    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($context.contractId -ceq
            'nll/phase3b2-synthetic-runtime-context/v1' -and
        ([string]$context.username).StartsWith(
            'synthetic-', [StringComparison]::Ordinal) -and
        ([string]$context.password).Length -eq 20) `
        'phase3b2_physical_p2_v2_context_invalid'

    $stageCode = 'evidence_database_and_observation_policy_backup'
    New-Item -ItemType Directory -Path $runRoot, $protectedRunRoot -Force |
        Out-Null
    $retryConsumption = [ordered]@{
        schemaVersion = 1
        contractId = if ($catalogSqliteTransportMode) {
            'nll/phase3b2-p2-v2-catalog-sqlite-transport-retry-consumption/v1'
        }
        elseif ($catalogSetRetryMode) {
            'nll/phase3b2-p2-v2-exact-catalog-set-retry-consumption/v1'
        }
        elseif ($dataPackVersionHeaderRetryMode) {
            'nll/phase3b2-p2-v2-datapack-version-header-retry-consumption/v1'
        }
        elseif ($resourceHostMapRetryMode) {
            'nll/phase3b2-p2-v2-resource-host-map-retry-consumption/v1'
        }
        elseif ($catalogParserExactRetryMode) {
            'nll/phase3b2-p2-v2-catalog-parser-exact-retry-consumption/v1'
        }
        elseif ($catalogProjectionRetryMode) {
            'nll/phase3b2-p2-v2-catalog-version-projection-retry-consumption/v1'
        }
        elseif ($baselineBackedInteractiveMode) {
            'nll/phase3b2-p2-v2-baseline-backed-interactive-retry-consumption/v1'
        }
        else { 'nll/phase3b2-p2-v2-live-log-seal-retry-consumption/v1' }
        consumedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        failedAssessmentUid = if ($catalogSqliteTransportMode) {
            '083d46b5-696f-407a-9d1c-0f8a5c86a4e1'
        }
        elseif ($catalogHeaderFollowupMode) {
            '29083a6a-3f4e-4eec-a57a-4d28b1459524'
        }
        elseif ($catalogSetRetryMode) {
            '31741b96-84e8-407d-b56a-b32ab0b0e630'
        }
        elseif ($dataPackVersionHeaderRetryMode) {
            'deafa3e3-d889-4a09-8a66-fc7dc3e27305'
        }
        elseif ($resourceHostMapRetryMode) {
            'cf8433fe-ea3d-4594-94d3-863bd0846cd3'
        }
        elseif ($catalogParserExactRetryMode) {
            'f7e2bb4a-e661-42bf-b055-d0b2c8a536d3'
        }
        elseif ($catalogProjectionRetryMode) {
            'bba01e6c-b457-4705-b251-4959006e0bef'
        }
        elseif ($baselineBackedInteractiveMode) {
            '78c37245-ea49-442d-becf-b1e871f98d68'
        }
        else { '88245ca5-08d2-4b09-a855-e875bf37bc22' }
        measurementModeCode = $measurementModeCode
        measurementSeconds = $MeasurementSeconds
        baselineTenMinuteMeasurementSha256 = if (
                $baselineBackedInteractiveMode) {
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538'
        }
        else { '' }
        catalogVersionProjectionVerified = $catalogProjectionAnyRetryMode
        catalogVersionProjectionSha256 = if ($catalogProjectionAnyRetryMode) {
            $catalogProjectionExpectedSha256
        }
        else { '' }
        catalogParserExactFormatVerified = $catalogParserExactFormatMode
        dataPackVersionHeaderVerified =
            ($catalogHeaderFollowupMode -or $dataPackVersionHeaderRetryMode)
        resourceHostVersionMapVerified = $resourceHostMapRetryMode
        exactCatalogSetVerified = $catalogSetRetryMode
        catalogSqliteTransportVerified = $catalogSqliteTransportMode
        dedicatedCatalogCacheResetApplied = $catalogSqliteTransportMode
        catalogDeploymentUid = if ($catalogSetRetryMode) {
            [string]$catalogDeploymentReceipt.deploymentUid
        }
        else { '' }
        catalogDeploymentReceiptSha256 = if ($catalogSetRetryMode) {
            [string]$retryAuthorization.deploymentReceiptSha256
        }
        else { '' }
        catalogPrivateManifestSha256 = if ($catalogSetRetryMode) {
            [string]$retryAuthorization.privateManifestSha256
        }
        else { '' }
        dedicatedCacheDirectoryCount = $dedicatedCacheDirectories.Count
        dedicatedCachePreserved = $true
        existingOperatorNikkeCacheMutationPerformed = $false
        endpointContractChanged = $false
        singleRetryConsumed = $true
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $retryConsumptionPath `
        (($retryConsumption | ConvertTo-Json -Depth 6) + "`n")
    [IO.File]::WriteAllBytes($databaseBeforePath,
        [IO.File]::ReadAllBytes($dbPath))
    Assert-True (Test-PathDigest $databaseBeforePath 413327L `
        'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
        'phase3b2_physical_p2_v2_database_backup_failed'
    $databaseBackupCreated = $true
    & (Join-Path $env:WINDIR 'System32\auditpol.exe') /backup `
        "/file:$auditBackupPath" | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and
        (Test-Path -LiteralPath $auditBackupPath -PathType Leaf)) `
        'phase3b2_physical_p2_v2_audit_backup_failed'
    $auditBackupCreated = $true
    & (Join-Path $env:WINDIR 'System32\auditpol.exe') /set `
        '/subcategory:{0CCE9226-69AE-11D9-BED3-505054503030}' `
        /success:enable /failure:enable | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) `
        'phase3b2_physical_p2_v2_wfp_audit_enable_failed'
    $dnsOriginalEnabled = Get-DnsChannelEnabled $dnsChannelName
    if (-not $dnsOriginalEnabled) {
        Set-DnsChannelEnabled $dnsChannelName $true
    }
    Assert-True (Get-DnsChannelEnabled $dnsChannelName) `
        'phase3b2_physical_p2_v2_dns_channel_enable_failed'
    $observationStartedAt = [DateTimeOffset]::UtcNow

    $stageCode = 'server_start_and_listener_observation'
    $env:EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID = [string]$context.accountId
    $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID = [string]$context.managerId
    $env:NLL_PHASE3B2_REQUEST_STAGE_LOG = $requestStagePath
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
            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID,
            Env:\NLL_PHASE3B2_REQUEST_STAGE_LOG -ErrorAction SilentlyContinue
        $env:Logging__LogLevel__Microsoft = $previousMicrosoftLog
        $env:Logging__LogLevel__System = $previousSystemLog
    }
    $listenerReady = $false
    for ($attempt = 0; $attempt -lt 240; $attempt++) {
        Start-Sleep -Milliseconds 250
        $serverProcess.Refresh()
        if ($serverProcess.HasExited) {
            throw 'phase3b2_physical_p2_v2_server_exited_before_listener'
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
        'phase3b2_physical_p2_v2_loopback_listener_not_ready'

    $stageCode = 'physical_bootstrap_and_sail_observation'
    $env:NLL_PHASE3B2_ASSESSMENT_UID = $assessmentUid
    $env:NLL_PHASE3B2_EVIDENCE_LANE = 'p2-client-start-v2'
    try {
        $bootstrapProcess = Start-Process -FilePath $bootstrapPath `
            -WorkingDirectory (Split-Path -Parent $bootstrapPath) -PassThru
        $bootstrapStarted = $true
    }
    finally {
        Remove-Item Env:\NLL_PHASE3B2_ASSESSMENT_UID,
            Env:\NLL_PHASE3B2_EVIDENCE_LANE `
            -ErrorAction SilentlyContinue
    }
    $bootstrapStartPath = Join-Path $runRoot 'bootstrap-start.receipt.json'
    $bootstrapFailurePath = Join-Path $runRoot 'bootstrap-failure.receipt.json'
    for ($attempt = 0; $attempt -lt 600; $attempt++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $bootstrapFailurePath -PathType Leaf) {
            $failure = Get-Content -LiteralPath $bootstrapFailurePath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            throw "phase3b2_physical_p2_v2_bootstrap_failed_$($failure.reasonCode)"
        }
        if (Test-Path -LiteralPath $bootstrapStartPath -PathType Leaf) { break }
        $bootstrapProcess.Refresh()
        if ($bootstrapProcess.HasExited) {
            throw 'phase3b2_physical_p2_v2_bootstrap_exited_before_sail'
        }
    }
    $bootstrapStart = Get-Content -LiteralPath $bootstrapStartPath -Raw `
        -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($bootstrapStart.contractId -ceq
            'nll/phase3b2-physical-bootstrap-client-start/v1' -and
        $bootstrapStart.assessmentUid -ceq $assessmentUid -and
        $bootstrapStart.sailSharedMemoryCreated -and
        $bootstrapStart.sailNamedPipeConnected -and
        $bootstrapStart.sailNamedPipePayloadWritten -and
        $bootstrapStart.sailNamedPipeClosedAfterPayload -and
        $bootstrapStart.sailPayloadClearedAfterWrite -and
        $bootstrapStart.sailSharedMemoryRetainedForClientLifetime -and
        $bootstrapStart.sailHandoffLifecycleCode -ceq
            'payload_then_pipe_eof_shared_memory_retained' -and
        [int]$bootstrapStart.clientProcessId -gt 0 -and
        $bootstrapStart.clientExecutionStarted -and
        -not $bootstrapStart.officialLauncherExecutionStarted) `
        'phase3b2_physical_p2_v2_bootstrap_receipt_invalid'
    $clientStarted = $true
    $clientProcessId = [int]$bootstrapStart.clientProcessId
    Assert-True ($null -ne (Get-PinnedProcess $clientProcessId 'nikke')) `
        'phase3b2_physical_p2_v2_client_process_missing'

    $pointer = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-v2-active-run-pointer/v1'
        assessmentUid = $assessmentUid
        serverProcessId = [int]$serverProcess.Id
        bootstrapProcessId = [int]$bootstrapProcess.Id
        clientProcessId = $clientProcessId
        observationStartedAtUtc =
            $observationStartedAt.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        measurementModeCode = $measurementModeCode
        minimumMeasurementSeconds = $MeasurementSeconds
        baselineTenMinuteMeasurementVerified =
            $baselineBackedInteractiveMode
        baselineTenMinuteMeasurementSha256 = if (
                $baselineBackedInteractiveMode) {
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538'
        }
        else { '' }
        catalogVersionProjectionVerified = $catalogProjectionAnyRetryMode
        catalogVersionProjectionSha256 = if ($catalogProjectionAnyRetryMode) {
            $catalogProjectionExpectedSha256
        }
        else { '' }
        catalogParserExactFormatVerified = $catalogParserExactFormatMode
        dataPackVersionHeaderVerified =
            ($catalogHeaderFollowupMode -or $dataPackVersionHeaderRetryMode)
        resourceHostVersionMapVerified = $resourceHostMapRetryMode
        exactCatalogSetVerified = $catalogSetRetryMode
        catalogSqliteTransportVerified = $catalogSqliteTransportMode
        dedicatedCatalogCacheResetApplied = $catalogSqliteTransportMode
        catalogDeploymentUid = if ($catalogSetRetryMode) {
            [string]$catalogDeploymentReceipt.deploymentUid
        }
        else { '' }
        catalogDeploymentReceiptSha256 = if ($catalogSetRetryMode) {
            [string]$retryAuthorization.deploymentReceiptSha256
        }
        else { '' }
        dedicatedWindowsAccountVerified = $true
        serverRunning = $true
        clientExecutionStarted = $true
    }
    New-Item -ItemType Directory -Path $P2EvidenceRoot -Force | Out-Null
    Write-AtomicUtf8NoBom $activePointerPath `
        (($pointer | ConvertTo-Json -Depth 6) + "`n")

    $stageCode = 'startup_health_and_network_observation'
    $samples = [Collections.Generic.List[object]]::new()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $sampleIntervalMilliseconds = [long]$SampleIntervalSeconds * 1000L
    $measurementExpectedSampleCount =
        [int][math]::Floor($measurementTargetMilliseconds /
            $sampleIntervalMilliseconds) + 1
    $nextSampleDueMilliseconds = 0L
    $measurementQualityStatusCode = 'collecting'
    while ($true) {
        $client = Get-PinnedProcess $clientProcessId 'nikke'
        $server = Get-PinnedProcess ([int]$serverProcess.Id) 'EpinelPS'
        $bootstrap = Get-PinnedProcess ([int]$bootstrapProcess.Id) `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
        Assert-True ($null -ne $client -and $null -ne $server -and
            $null -ne $bootstrap) `
            'phase3b2_physical_p2_v2_runtime_lost_during_measurement'
        $client.Refresh()
        $observedIds = @($clientProcessId, [int]$serverProcess.Id,
            [int]$bootstrapProcess.Id)
        $connections = @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Where-Object OwningProcess -In $observedIds)
        $successfulNonLoopback = @($connections | Where-Object {
            $_.State -eq 'Established' -and $_.RemoteAddress -and
            $_.RemoteAddress -notin @(
                '0.0.0.0', '127.0.0.1', '::', '::1')
        })
        Assert-True ($successfulNonLoopback.Count -eq 0) `
            'phase3b2_physical_p2_v2_nonloopback_success_observed'
        $samples.Add([ordered]@{
            offsetMilliseconds = [long]$timer.ElapsedMilliseconds
            observedAtUtc = [DateTimeOffset]::UtcNow.ToString(
                "yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
            responding = [bool]$client.Responding
            totalProcessorTimeMilliseconds =
                [long]$client.TotalProcessorTime.TotalMilliseconds
            workingSetByteLength = [long]$client.WorkingSet64
            privateMemoryByteLength = [long]$client.PrivateMemorySize64
            threadCount = @($client.Threads).Count
            handleCount = [int]$client.HandleCount
            playerLogPresent = Test-Path -LiteralPath $playerLogPath -PathType Leaf
            playerLogByteLength = if (Test-Path -LiteralPath $playerLogPath `
                    -PathType Leaf) {
                (Get-Item -LiteralPath $playerLogPath).Length
            } else { 0 }
            playerLogLastWriteAtUtc = if (Test-Path -LiteralPath $playerLogPath `
                    -PathType Leaf) {
                (Get-Item -LiteralPath $playerLogPath).LastWriteTimeUtc.ToString(
                    "yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
            } else { $null }
            loopbackConnectionCount = @($connections | Where-Object {
                $_.RemoteAddress -in @('127.0.0.1', '::1')
            }).Count
            nonLoopbackConnectionCount = @($connections | Where-Object {
                $_.RemoteAddress -and $_.RemoteAddress -notin @(
                    '0.0.0.0', '127.0.0.1', '::', '::1')
                }).Count
        })
        if ($timer.ElapsedMilliseconds -ge $measurementTargetMilliseconds) {
            break
        }
        $nextSampleDueMilliseconds += $sampleIntervalMilliseconds
        $sleepMilliseconds = [long][math]::Min(
            [math]::Max(0L,
                $nextSampleDueMilliseconds - $timer.ElapsedMilliseconds),
            $measurementTargetMilliseconds - $timer.ElapsedMilliseconds)
        if ($sleepMilliseconds -gt 0) {
            Start-Sleep -Milliseconds ([int]$sleepMilliseconds)
        }
    }
    $timer.Stop()
    $measurementDurationMilliseconds = [long]$timer.ElapsedMilliseconds
    $measurementDurationSeconds = [math]::Round($timer.Elapsed.TotalSeconds, 3)
    $sampleOffsets = @($samples | ForEach-Object {
        [long]$_.offsetMilliseconds
    })
    $maximumSampleGapMilliseconds = 0L
    for ($sampleIndex = 1; $sampleIndex -lt $sampleOffsets.Count; $sampleIndex++) {
        $sampleGap = $sampleOffsets[$sampleIndex] -
            $sampleOffsets[$sampleIndex - 1]
        if ($sampleGap -gt $maximumSampleGapMilliseconds) {
            $maximumSampleGapMilliseconds = $sampleGap
        }
    }
    Write-AtomicUtf8NoBom $healthPath `
        (([ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-p2-v2-health-samples/v1'
            assessmentUid = $assessmentUid
            measurementDurationSeconds = $measurementDurationSeconds
            measurementDurationMilliseconds = $measurementDurationMilliseconds
            sampleIntervalSeconds = $SampleIntervalSeconds
            expectedSampleCount = $measurementExpectedSampleCount
            observedSampleCount = $samples.Count
            maximumSampleGapMilliseconds = $maximumSampleGapMilliseconds
            schedulerCode = 'monotonic_deadline_compensated_interval_v2'
            samples = @($samples)
        } | ConvertTo-Json -Depth 8) + "`n")

    $stageCode = 'dns_wfp_and_server_stage_seal'
    $dnsObservation = Get-SanitizedDnsObservation $observationStartedAt
    $pidRoles = @{
        ([int]$serverProcess.Id) = 'server'
        ([int]$bootstrapProcess.Id) = 'physical_bootstrap'
        $clientProcessId = 'original_client'
    }
    $wfpObservation = Get-SanitizedWfpObservation `
        $observationStartedAt $pidRoles
    Write-AtomicUtf8NoBom $dnsPath `
        (($dnsObservation | ConvertTo-Json -Depth 8) + "`n")
    Write-AtomicUtf8NoBom $wfpPath `
        (($wfpObservation | ConvertTo-Json -Depth 8) + "`n")

    $stageRecords = [Collections.Generic.List[object]]::new()
    if (Test-Path -LiteralPath $requestStagePath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $requestStagePath `
                -Encoding UTF8 | Where-Object { $_ })) {
            $record = $line | ConvertFrom-Json
            Assert-True ([int]$record.schemaVersion -eq 1 -and
                [string]$record.transitionCode -cmatch
                    '^(request|handler)_(started|completed|failed|missing)$' -and
                (-not $record.requestStageCode -or
                    [string]$record.requestStageCode -cmatch '^[a-z0-9_]+$') -and
                (-not $record.handlerTypeCode -or
                    [string]$record.handlerTypeCode -cmatch '^[A-Za-z0-9_.+]+$')) `
                'phase3b2_physical_p2_v2_request_stage_record_invalid'
            $stageRecords.Add($record)
        }
    }
    $stageGroups = @($stageRecords | Group-Object transitionCode,
        requestStageCode, handlerTypeCode | Sort-Object Name | ForEach-Object {
        [ordered]@{
            transitionCode = [string]$_.Group[0].transitionCode
            requestStageCode = [string]$_.Group[0].requestStageCode
            handlerTypeCode = [string]$_.Group[0].handlerTypeCode
            count = $_.Count
        }
    })
    $requestSummary = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-v2-request-stage-summary/v1'
        assessmentUid = $assessmentUid
        recordCount = $stageRecords.Count
        requestStartedCount = @($stageRecords | Where-Object {
            $_.transitionCode -ceq 'request_started'
        }).Count
        requestCompletedCount = @($stageRecords | Where-Object {
            $_.transitionCode -ceq 'request_completed'
        }).Count
        handlerStartedCount = @($stageRecords | Where-Object {
            $_.transitionCode -ceq 'handler_started'
        }).Count
        handlerCompletedCount = @($stageRecords | Where-Object {
            $_.transitionCode -ceq 'handler_completed'
        }).Count
        rawRequestPathPersisted = $false
        requestPayloadPersisted = $false
        accountIdentifierPersisted = $false
        groups = $stageGroups
    }
    Write-AtomicUtf8NoBom $requestSummaryPath `
        (($requestSummary | ConvertTo-Json -Depth 8) + "`n")
    Restore-ObservationPolicy
    Assert-True ($auditRestored -and $dnsChannelRestored) `
        'phase3b2_physical_p2_v2_observation_policy_restore_failed'
    $measurementQualityStatusCode = if (
        $measurementDurationMilliseconds -ge $measurementTargetMilliseconds -and
        $samples.Count -ge $measurementExpectedSampleCount) {
        'minimum_duration_and_sampling_completed'
    }
    else { 'insufficient_duration_or_sampling' }
    Assert-True ($measurementQualityStatusCode -ceq
        'minimum_duration_and_sampling_completed') `
        'phase3b2_physical_p2_v2_measurement_duration_invalid'
    $playerLogObservation = if (Test-Path -LiteralPath $playerLogPath `
            -PathType Leaf) {
        Get-SharedReadFileObservation $playerLogPath
    }
    else {
        [pscustomobject]@{
            present = $false
            byteLength = 0L
            sha256 = Get-StringSha256Hex ''
            observationModeCode = 'absent_no_raw_persistence'
        }
    }

    $firstSample = $samples[0]
    $lastSample = $samples[$samples.Count - 1]
    $measurement = [ordered]@{
        schemaVersion = 1
        contractId = if ($baselineBackedInteractiveMode) {
            'nll/phase3b2-physical-p2-v2-startup-health-measurement/v1'
        }
        else { 'nll/phase3b2-physical-p2-v2-ten-minute-measurement/v1' }
        measuredAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        measurementModeCode = $measurementModeCode
        baselineAssessmentUid = if ($baselineBackedInteractiveMode) {
            '78c37245-ea49-442d-becf-b1e871f98d68'
        }
        else { '' }
        baselineTenMinuteMeasurementVerified =
            $baselineBackedInteractiveMode
        baselineTenMinuteMeasurementSha256 = if (
                $baselineBackedInteractiveMode) {
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538'
        }
        else { '' }
        dedicatedWindowsAccountVerified = $true
        dedicatedLocalLowUsed = $true
        existingOperatorNikkeCacheMutationPerformed = $false
        minimumRequiredSeconds = $MeasurementSeconds
        measuredDurationSeconds = $measurementDurationSeconds
        measuredDurationMilliseconds = $measurementDurationMilliseconds
        sampleIntervalSeconds = $SampleIntervalSeconds
        sampleCount = $samples.Count
        expectedSampleCount = $measurementExpectedSampleCount
        maximumSampleGapMilliseconds = $maximumSampleGapMilliseconds
        measurementSchedulerCode =
            'monotonic_deadline_compensated_interval_v2'
        measurementQualityStatusCode = $measurementQualityStatusCode
        respondingSampleCount = @($samples | Where-Object {
            $_.responding
        }).Count
        unresponsiveSampleCount = @($samples | Where-Object {
            -not $_.responding
        }).Count
        clientCpuTimeDeltaMilliseconds =
            [long]$lastSample.totalProcessorTimeMilliseconds -
            [long]$firstSample.totalProcessorTimeMilliseconds
        clientWorkingSetStartByteLength =
            [long]$firstSample.workingSetByteLength
        clientWorkingSetEndByteLength =
            [long]$lastSample.workingSetByteLength
        playerLogPresent = [bool]$playerLogObservation.present
        playerLogByteLength = [long]$playerLogObservation.byteLength
        playerLogSha256 = [string]$playerLogObservation.sha256
        playerLogObservationModeCode =
            [string]$playerLogObservation.observationModeCode
        rawPlayerLogCopiedToEvidence = $false
        successfulNonLoopbackConnectionCount = 0
        dnsEventCount = [int]$dnsObservation.eventCount
        dnsClassifiedQueryCount = [int]$dnsObservation.classifiedQueryCount
        admittedGlobalMatchQueryCount =
            [int]$dnsObservation.admittedGlobalMatchQueryCount
        wfpMatchingEventCount = [int]$wfpObservation.matchingEventCount
        wfpAllowedNonLoopbackCount =
            [int]$wfpObservation.allowedNonLoopbackCount
        wfpBlockedNonLoopbackCount =
            [int]$wfpObservation.blockedNonLoopbackCount
        serverRequestStageRecordCount = $stageRecords.Count
        serverRequestStartedCount = $requestSummary.requestStartedCount
        serverRequestCompletedCount = $requestSummary.requestCompletedCount
        serverHandlerStartedCount = $requestSummary.handlerStartedCount
        serverHandlerCompletedCount = $requestSummary.handlerCompletedCount
        healthSamplesByteLength = (Get-Item $healthPath).Length
        healthSamplesSha256 = Get-Sha256Hex $healthPath
        dnsObservationByteLength = (Get-Item $dnsPath).Length
        dnsObservationSha256 = Get-Sha256Hex $dnsPath
        wfpObservationByteLength = (Get-Item $wfpPath).Length
        wfpObservationSha256 = Get-Sha256Hex $wfpPath
        requestStageSummaryByteLength = (Get-Item $requestSummaryPath).Length
        requestStageSummarySha256 = Get-Sha256Hex $requestSummaryPath
        requestStageRawByteLength = if (Test-Path $requestStagePath) {
            (Get-Item $requestStagePath).Length
        } else { 0 }
        requestStageRawSha256 = if (Test-Path $requestStagePath) {
            Get-Sha256Hex $requestStagePath
        } else { Get-StringSha256Hex '' }
        auditPolicyRestored = $auditRestored
        dnsChannelRestored = $dnsChannelRestored
        serverRunning = $true
        physicalBootstrapRunning = $true
        clientRunning = $true
        clientExecutionStarted = $true
    }
    Write-AtomicUtf8NoBom $measurementPath `
        (($measurement | ConvertTo-Json -Depth 8) + "`n")

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p2-v2-client-start/v1'
        startedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        preparationReceiptSha256 = Get-Sha256Hex $preparationPath
        bootstrapStartReceiptSha256 = Get-Sha256Hex $bootstrapStartPath
        measurementContractId = [string]$measurement.contractId
        measurementModeCode = $measurementModeCode
        measurementSeconds = $MeasurementSeconds
        measurementReceiptByteLength =
            (Get-Item $measurementPath).Length
        measurementReceiptSha256 = Get-Sha256Hex $measurementPath
        tenMinuteMeasurementReceiptByteLength = if (
                $baselineBackedInteractiveMode) { 2696L }
            else { (Get-Item $measurementPath).Length }
        tenMinuteMeasurementReceiptSha256 = if (
                $baselineBackedInteractiveMode) {
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538'
        }
        else { Get-Sha256Hex $measurementPath }
        clientBuild = '150.6.9'
        operatorAccountCode = 'dedicated_nlloperator'
        localLowIsolationVerified = $true
        mappedDomainCount = 18
        endpointAdmissionCode = 'global_match_returned_by_local_get_server_info'
        serverProcessId = [int]$serverProcess.Id
        bootstrapProcessId = [int]$bootstrapProcess.Id
        clientProcessId = $clientProcessId
        sailSharedMemoryCreated = $true
        sailNamedPipeConnected = $true
        sailNamedPipePayloadWritten = $true
        sailNamedPipeClosedAfterPayload = $true
        sailPayloadClearedAfterWrite = $true
        sailSharedMemoryRetainedForClientLifetime = $true
        sailHandoffLifecycleCode =
            'payload_then_pipe_eof_shared_memory_retained'
        livePlayerLogSharedReadEnabled = $true
        playerLogObservationModeCode =
            [string]$playerLogObservation.observationModeCode
        minimumTenMinuteObservationCompleted =
            (-not $baselineBackedInteractiveMode)
        baselineTenMinuteObservationVerified =
            $baselineBackedInteractiveMode
        measurementSchedulerCode =
            'monotonic_deadline_compensated_interval_v2'
        catalogVersionProjectionVerified = $catalogProjectionAnyRetryMode
        catalogVersionProjectionSha256 = if ($catalogProjectionAnyRetryMode) {
            $catalogProjectionExpectedSha256
        }
        else { '' }
        dataPackVersionHeaderVerified =
            ($catalogHeaderFollowupMode -or $dataPackVersionHeaderRetryMode)
        resourceHostVersionMapVerified = $resourceHostMapRetryMode
        exactCatalogSetVerified = $catalogSetRetryMode
        catalogSqliteTransportVerified = $catalogSqliteTransportMode
        dedicatedCatalogCacheResetApplied = $catalogSqliteTransportMode
        catalogDeploymentUid = if ($catalogSetRetryMode) {
            [string]$catalogDeploymentReceipt.deploymentUid
        }
        else { '' }
        catalogDeploymentReceiptSha256 = if ($catalogSetRetryMode) {
            [string]$retryAuthorization.deploymentReceiptSha256
        }
        else { '' }
        dedicatedCacheStateCode = if ($catalogSqliteTransportMode) {
            'reset_six_malformed_catalog_members_for_sqlite_transport_retry'
        }
        elseif ($catalogHeaderFollowupMode) {
            'preserved_exact_catalog_plus_header_followup_retry'
        }
        elseif ($catalogSetRetryMode) {
            'preserved_exact_catalog_set_retry'
        }
        elseif ($dataPackVersionHeaderRetryMode) {
            'preserved_datapack_version_header_retry'
        }
        elseif ($resourceHostMapRetryMode) {
            'preserved_resource_host_map_retry'
        }
        elseif ($catalogParserExactRetryMode) {
            'preserved_catalog_parser_exact_retry'
        }
        elseif ($catalogProjectionRetryMode) {
            'preserved_catalog_version_projection_retry'
        }
        elseif ($baselineBackedInteractiveMode) {
            'preserved_baseline_backed_interactive_retry'
        }
        else { 'preserved_first_run_cache_authorized_single_retry' }
        liveRuntimeFilesDeferredToCompletion = $true
        successfulNonLoopbackConnectionCount = 0
        serverRunning = $true
        physicalBootstrapRunning = $true
        clientExecutionStarted = $true
        officialLauncherExecutionStarted = $false
        antiCheatSubstitutionApplied = $false
        existingOperatorNikkeCacheMutationPerformed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        nextStepCode = 'operator_observe_or_play_then_run_p2_v2_completion'
    }
    Write-AtomicUtf8NoBom $runStartPath `
        (($receipt | ConvertTo-Json -Depth 8) + "`n")
    $pointer['runStartReceiptSha256'] = Get-Sha256Hex $runStartPath
    $pointer['measurementReceiptSha256'] = Get-Sha256Hex $measurementPath
    $pointer['tenMinuteMeasurementReceiptSha256'] =
        if ($baselineBackedInteractiveMode) {
            '8af3acdf40a741b6998ff0c2f9278a14b7a2c48246798abf1f1e4214d4bf6538'
        }
        else { Get-Sha256Hex $measurementPath }
    Write-AtomicUtf8NoBom $activePointerPath `
        (($pointer | ConvertTo-Json -Depth 7) + "`n")

    $stageCode = 'protected_immutable_evidence_copy'
    foreach ($path in @($databaseBeforePath, $auditBackupPath,
            $bootstrapStartPath, $healthPath, $dnsPath, $wfpPath,
            $requestSummaryPath, $measurementPath, $runStartPath,
            $activePointerPath, $retryConsumptionPath)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Copy-Item -LiteralPath $path -Destination $protectedRunRoot -Force
            $copy = Join-Path $protectedRunRoot (Split-Path -Leaf $path)
            Assert-True ((Get-Sha256Hex $copy) -ceq (Get-Sha256Hex $path)) `
                'phase3b2_physical_p2_v2_protected_copy_failed'
        }
    }
    $receipt | ConvertTo-Json -Depth 9
}
catch {
    $failureRecord = $_
    if ($null -ne $timer -and $timer.IsRunning) {
        $timer.Stop()
    }
    if ($null -ne $timer) {
        $measurementDurationMilliseconds = [long]$timer.ElapsedMilliseconds
    }
    if ($samples.Count -gt 0 -and
        -not (Test-Path -LiteralPath $healthPath -PathType Leaf)) {
        try {
            $sampleOffsets = @($samples | ForEach-Object {
                [long]$_.offsetMilliseconds
            })
            $maximumSampleGapMilliseconds = 0L
            for ($sampleIndex = 1; $sampleIndex -lt $sampleOffsets.Count;
                    $sampleIndex++) {
                $sampleGap = $sampleOffsets[$sampleIndex] -
                    $sampleOffsets[$sampleIndex - 1]
                if ($sampleGap -gt $maximumSampleGapMilliseconds) {
                    $maximumSampleGapMilliseconds = $sampleGap
                }
            }
            Write-AtomicUtf8NoBom $healthPath `
                (([ordered]@{
                    schemaVersion = 1
                    contractId =
                        'nll/phase3b2-physical-p2-v2-health-samples/v1'
                    assessmentUid = $assessmentUid
                    measurementDurationSeconds = [math]::Round(
                        $measurementDurationMilliseconds / 1000.0, 3)
                    measurementDurationMilliseconds =
                        $measurementDurationMilliseconds
                    sampleIntervalSeconds = $SampleIntervalSeconds
                    expectedSampleCount = $measurementExpectedSampleCount
                    observedSampleCount = $samples.Count
                    maximumSampleGapMilliseconds =
                        $maximumSampleGapMilliseconds
                    schedulerCode =
                        'monotonic_deadline_compensated_interval_v2'
                    observationComplete = $false
                    samples = @($samples)
                } | ConvertTo-Json -Depth 8) + "`n")
        }
        catch { }
    }
    if ($null -ne $observationStartedAt) {
        try {
            if (-not (Test-Path -LiteralPath $dnsPath -PathType Leaf)) {
                $dnsObservation = Get-SanitizedDnsObservation `
                    $observationStartedAt
                Write-AtomicUtf8NoBom $dnsPath `
                    (($dnsObservation | ConvertTo-Json -Depth 8) + "`n")
            }
            if (-not (Test-Path -LiteralPath $wfpPath -PathType Leaf) -and
                $null -ne $serverProcess -and
                $null -ne $bootstrapProcess -and $clientProcessId -gt 0) {
                $failurePidRoles = @{
                    ([int]$serverProcess.Id) = 'server'
                    ([int]$bootstrapProcess.Id) = 'physical_bootstrap'
                    $clientProcessId = 'original_client'
                }
                $wfpObservation = Get-SanitizedWfpObservation `
                    $observationStartedAt $failurePidRoles
                Write-AtomicUtf8NoBom $wfpPath `
                    (($wfpObservation | ConvertTo-Json -Depth 8) + "`n")
            }
        }
        catch { }
    }
    try { Restore-ObservationPolicy } catch { }
    Stop-PinnedProcess $clientProcessId 'nikke'
    if ($null -ne $bootstrapProcess) {
        Stop-PinnedProcess ([int]$bootstrapProcess.Id) `
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap'
    }
    if ($null -ne $serverProcess) {
        Stop-PinnedProcess ([int]$serverProcess.Id) 'EpinelPS'
    }
    Start-Sleep -Milliseconds 500
    foreach ($path in $sqlitePaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
    $databaseRestored = $false
    if ($databaseBackupCreated -and
        (Test-Path -LiteralPath $databaseBeforePath -PathType Leaf)) {
        [IO.File]::WriteAllBytes($dbPath,
            [IO.File]::ReadAllBytes($databaseBeforePath))
        $databaseRestored = Test-PathDigest $dbPath 413327L `
            'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
    }
    Get-NetFirewallRule -Group $extensionFirewallGroup `
        -ErrorAction SilentlyContinue | Remove-NetFirewallRule `
        -ErrorAction SilentlyContinue
    $hostsRestored = $false
    if (Test-Path -LiteralPath $hostsBackupPath -PathType Leaf) {
        [IO.File]::WriteAllBytes($hostsPath,
            [IO.File]::ReadAllBytes($hostsBackupPath))
        $hostsRestored = Test-PathDigest $hostsPath 1690L `
            'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'
    }
    if ($catalogProjectionAnyRetryMode) {
        try {
            $catalogProjectionPath = Join-Path $serverRoot `
                'cache\prdenv\150-b059c3f36c\StandaloneWindows64\pck\latest-651.txt'
            if (Test-PathDigest $catalogProjectionPath `
                    $catalogProjectionExpectedByteLength `
                    $catalogProjectionExpectedSha256) {
                Remove-Item -LiteralPath $catalogProjectionPath -Force
            }
            $catalogProjectionRolledBack =
                -not (Test-Path -LiteralPath $catalogProjectionPath)
        }
        catch { $catalogProjectionRolledBack = $false }
    }
    try {
        New-Item -ItemType Directory -Path $runRoot, $protectedRunRoot -Force |
            Out-Null
        $failurePlayerLogObservation = if ($playerLogPath -and
                (Test-Path -LiteralPath $playerLogPath -PathType Leaf)) {
            Get-SharedReadFileObservation $playerLogPath
        }
        else {
            [pscustomobject]@{
                present = $false
                byteLength = 0L
                sha256 = Get-StringSha256Hex ''
                observationModeCode = 'absent_no_raw_persistence'
            }
        }
        $safeFailureCode = if ($failureRecord.Exception.Message -cmatch
            '^phase3b2_[a-z0-9_:-]+$') {
            $failureRecord.Exception.Message
        } else { 'phase3b2_physical_p2_v2_unexpected_error_redacted' }
        $failure = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-p2-v2-client-start-failure/v1'
            failedAtUtc =
                [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            assessmentUid = $assessmentUid
            failedStageCode = $stageCode
            failureCode = $safeFailureCode
            serverExecutionStarted = $serverStarted
            physicalBootstrapExecutionStarted = $bootstrapStarted
            clientExecutionStarted = $clientStarted
            measurementDurationMilliseconds = $measurementDurationMilliseconds
            measurementExpectedSampleCount = $measurementExpectedSampleCount
            measurementObservedSampleCount = $samples.Count
            measurementQualityStatusCode = $measurementQualityStatusCode
            respondingSampleCount = @($samples | Where-Object {
                $_.responding
            }).Count
            unresponsiveSampleCount = @($samples | Where-Object {
                -not $_.responding
            }).Count
            clientPlayerLogPresent =
                [bool]$failurePlayerLogObservation.present
            clientPlayerLogByteLength =
                [long]$failurePlayerLogObservation.byteLength
            clientPlayerLogSha256 =
                [string]$failurePlayerLogObservation.sha256
            clientPlayerLogObservationModeCode =
                [string]$failurePlayerLogObservation.observationModeCode
            rawPlayerLogCopiedToEvidence = $false
            dnsObservationPresent = Test-Path -LiteralPath $dnsPath -PathType Leaf
            wfpObservationPresent = Test-Path -LiteralPath $wfpPath -PathType Leaf
            healthObservationPresent = Test-Path -LiteralPath $healthPath `
                -PathType Leaf
            auditPolicyRestored = $auditRestored
            dnsChannelRestored = $dnsChannelRestored
            runtimeStopped = $true
            databaseRestored = $databaseRestored
            sqliteRuntimeRemoved = @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0
            hostsRestored = $hostsRestored
            extensionFirewallRolledBack = @(Get-NetFirewallRule `
                -Group $extensionFirewallGroup `
                -ErrorAction SilentlyContinue).Count -eq 0
            catalogVersionProjectionRolledBack =
                $catalogProjectionRolledBack
            dedicatedOperatorCachePreservedForInspection = $true
            existingOperatorNikkeCacheMutationPerformed = $false
            officialIdentityPersisted = $false
            officialCredentialPersisted = $false
            nextStepCode = 'return_to_samsung_and_inspect_p2_v2_failure'
        }
        Write-AtomicUtf8NoBom $failurePath `
            (($failure | ConvertTo-Json -Depth 7) + "`n")
        foreach ($path in @($failurePath, $healthPath, $dnsPath, $wfpPath,
                $requestSummaryPath, $requestStagePath, $stdoutPath,
                $stderrPath, $bootstrapStartPath, $bootstrapFailurePath,
                $retryConsumptionPath)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Copy-Item -LiteralPath $path -Destination $protectedRunRoot -Force
            }
        }
        if (Test-Path -LiteralPath $activePointerPath) {
            Remove-Item -LiteralPath $activePointerPath -Force
        }
    }
    catch { }
    throw "phase3b2_physical_p2_v2_client_start_failed:$stageCode"
}
