param(
    [string]$ServerRoot =
        'C:\NLL\Runtime\EpinelPS-SoloRaidUnlock-v1',
    [string]$BootstrapRoot = 'C:\NLL\Runtime\PhysicalBootstrap-v2',
    [string]$EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\epinel-solo-raid-unlock-v1',
    [string]$BootstrapEvidenceLane = 'p2-client-start-v2',
    [string]$RequiredLocalAssetUrl = '',
    [long]$RequiredLocalAssetByteLength = 0,
    [string]$RequiredLocalAssetSha256 = '',
    [string]$RequiredLocalCatalogContractPath = '',
    [string]$RequiredLocalCatalogContractSha256 = '',
    [string]$RequiredLocalSausContractPath = '',
    [string]$RequiredLocalSausContractSha256 = ''
)

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

$expectedPreflightSha256 = `
    'f6699da26a55c95ab0d5ed250930910896b098b245907ac73d852fd700f36b0a'
$expectedDeploymentSha256 = `
    '101a43a90791bf79f62ac661f35802ed53261cda37d22d7d68b6d4bff487befa'
$expectedSamplingLogRepairSha256 = `
    'e8fc382f236075a3b96d73c200be9a07ff00536cba4122c2d12118ce98508e2a'
$expectedServerExeSha256 = `
    'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b'
$expectedServerDllSha256 = `
    'f602c58985a7a90cd206e2b58d793a4c7c2c0f1ea6ba778d0d74d61d68f9635b'
$expectedExternalHead = `
    '317c4f352b91e76470e2b035ada426ff443f9de4'
$expectedExternalTree = `
    'e429f0ac08cde7561456e158c9403abb7d9d0362'
$expectedParentServerDllSha256 = `
    'aaa1e49d7a879a6b5ec17ad4c4094ce7d98ce86f860c1529a9ab4d6aecb51f7c'
$expectedParentExternalHead = `
    'aa01ad90b807be1c2ceffe958519cb529622d472'
$expectedParentExternalTree = `
    'c324c11d32365b1524f266cba6bc014e89545204'
$expectedDbSha256 = `
    'd73e92c9e8159b347f42eff5c6c2270e3695e91cd542c05f45bcbb121cd9a1ee'
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
$samplingLogRepairPath =
    'C:\NLL\Evidence\Phase3B2\Physical\epinel-minimal-sampling-log-repair-v1\repair.receipt.json'
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
    @($preflightPath, $deploymentPath, $samplingLogRepairPath,
        $contextPath, $serverPath,
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
    (Get-Sha256Hex $samplingLogRepairPath) -ceq `
        $expectedSamplingLogRepairSha256 -and
    (Get-Sha256Hex $serverPath) -ceq $expectedServerExeSha256 -and
    (Get-Sha256Hex $serverDllPath) -ceq $expectedServerDllSha256 -and
    (Get-Sha256Hex $dbPath) -ceq $expectedDbSha256 -and
    (Get-Sha256Hex $hostsPath) -ceq $expectedHostsSha256 -and
    (Get-Sha256Hex $bootstrapPath) -ceq $expectedBootstrapSha256
) 'phase3b2_epinel_minimal_start_digest_invalid'

$preflight = Get-Content -LiteralPath $preflightPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$samplingLogRepair = Get-Content -LiteralPath $samplingLogRepairPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True (
    $preflight.contractId -ceq `
        'nll/phase3b2-epinel-minimal-source-free-preflight/v1' -and
    $preflight.verdict -ceq `
        'ready_to_stage_single_micron_reference_run_tools' -and
    -not $preflight.officialOutboundFallbackPermitted -and
    $samplingLogRepair.contractId -ceq `
        'nll/phase3b2-epinel-minimal-sampling-log-repair/v1' -and
    $samplingLogRepair.deploymentApplied -and
    $samplingLogRepair.samplingContractCode -ceq `
        'minimum_ten_samples_and_twenty_eight_seconds' -and
    -not $samplingLogRepair.localAuthTokenLoggingEnabled -and
    -not $samplingLogRepair.rawSensitiveServerLogPersisted -and
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

    if (-not [string]::IsNullOrWhiteSpace($RequiredLocalAssetUrl)) {
        $stageCode = 'required_local_asset_loopback_preflight'
        $requiredUri = [Uri]$RequiredLocalAssetUrl
        Assert-True (
            $requiredUri.Scheme -ceq 'https' -and
            $requiredUri.Host -ceq 'cloud.nikke-kr.com' -and
            $requiredUri.AbsolutePath -ceq (
                '/prdenv/150-b059c3f36c/StandaloneWindows64/pck/' +
                'latest-651.txt'
            ) -and
            $RequiredLocalAssetByteLength -eq 139L -and
            $RequiredLocalAssetSha256 -ceq `
                '5914cb58fd2146fe761ab531ecb4e321300527186a54b455e59de962ff6c044a'
        ) 'phase3b2_epinel_minimal_start_local_asset_contract_invalid'

        $resolvedAddresses = @(
            Resolve-DnsName -Name $requiredUri.Host -Type A `
                -ErrorAction Stop | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.IPAddress)
                } | ForEach-Object { [string]$_.IPAddress }
        )
        $requiredLocalAssetLoopbackResolved = (
            $resolvedAddresses.Count -ge 1 -and
            @($resolvedAddresses | Where-Object { $_ -cne '127.0.0.1' }).Count `
                -eq 0
        )
        Assert-True $requiredLocalAssetLoopbackResolved `
            'phase3b2_epinel_minimal_start_local_asset_not_loopback'

        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $httpClient = [Net.Http.HttpClient]::new($handler)
        $httpClient.Timeout = [TimeSpan]::FromSeconds(15)
        try {
            $response = $httpClient.GetAsync($requiredUri).GetAwaiter().GetResult()
            try {
                $requiredLocalAssetHttpStatusCode = [int]$response.StatusCode
                $responseBytes = $response.Content.ReadAsByteArrayAsync().
                    GetAwaiter().GetResult()
            }
            finally {
                $response.Dispose()
            }
        }
        finally {
            $httpClient.Dispose()
            $handler.Dispose()
        }
        $requiredLocalAssetObservedByteLength = [long]$responseBytes.Length
        $requiredLocalAssetObservedSha256 = Get-ByteArraySha256Hex $responseBytes
        Assert-True (
            $requiredLocalAssetHttpStatusCode -eq 200 -and
            $requiredLocalAssetObservedByteLength -eq `
                $RequiredLocalAssetByteLength -and
            $requiredLocalAssetObservedSha256 -ceq `
                $RequiredLocalAssetSha256
        ) 'phase3b2_epinel_minimal_start_local_asset_response_invalid'
        $requiredLocalAssetPreflightPerformed = $true
    }

    if (-not [string]::IsNullOrWhiteSpace(
            $RequiredLocalCatalogContractPath)) {
        $stageCode = 'required_local_catalog_transport_preflight'
        Assert-True (
            (Test-Path -LiteralPath $RequiredLocalCatalogContractPath `
                -PathType Leaf) -and
            $RequiredLocalCatalogContractSha256 -cmatch '^[0-9a-f]{64}$' -and
            (Get-Sha256Hex $RequiredLocalCatalogContractPath) -ceq `
                $RequiredLocalCatalogContractSha256
        ) 'phase3b2_epinel_minimal_start_catalog_contract_digest_invalid'

        $catalogContract = Get-Content `
            -LiteralPath $RequiredLocalCatalogContractPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $catalogMembers = @($catalogContract.members)
        $expectedCatalogPaths = [ordered]@{
            core = '/prdenv/150-b059c3f36c/StandaloneWindows64/pck/' +
                'core/150.6.b15/catalog.db'
            dp = '/prdenv/150-b059c3f36c/StandaloneWindows64/pck/' +
                'dp/1d5645e/catalog.db'
            fd = '/prdenv/150-b059c3f36c/StandaloneWindows64/pck/' +
                'fd/85b12fc/catalog.db'
        }
        Assert-True (
            $catalogContract.contractId -ceq `
                'nll/phase3b2-epinel-native-cache-catalog-transport-contract/v1' -and
            $catalogContract.externalHead -ceq $expectedParentExternalHead -and
            $catalogContract.externalTree -ceq $expectedParentExternalTree -and
            $catalogContract.serverDllSha256 -ceq `
                $expectedParentServerDllSha256 -and
            [int]$catalogContract.memberCount -eq 3 -and
            $catalogMembers.Count -eq 3 -and
            -not $catalogContract.rawDecryptedCatalogPersisted
        ) 'phase3b2_epinel_minimal_start_catalog_contract_invalid'

        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $httpClient = [Net.Http.HttpClient]::new($handler)
        $httpClient.Timeout = [TimeSpan]::FromSeconds(30)
        try {
            foreach ($roleCode in @('core', 'dp', 'fd')) {
                $member = @($catalogMembers | Where-Object {
                        $_.roleCode -ceq $roleCode
                    })
                Assert-True ($member.Count -eq 1) `
                    'phase3b2_epinel_minimal_start_catalog_member_invalid'
                $bodyUri = [Uri][string]$member[0].bodyUrl
                $signatureUri = [Uri][string]$member[0].signatureUrl
                Assert-True (
                    $bodyUri.Scheme -ceq 'https' -and
                    $bodyUri.Host -ceq 'cloud.nikke-kr.com' -and
                    $bodyUri.AbsolutePath -ceq $expectedCatalogPaths[$roleCode] -and
                    $signatureUri.Scheme -ceq 'https' -and
                    $signatureUri.Host -ceq 'cloud.nikke-kr.com' -and
                    $signatureUri.AbsolutePath -ceq `
                        ($expectedCatalogPaths[$roleCode] + '.nds') -and
                    [long]$member[0].encryptedByteLength -gt 4L -and
                    [string]$member[0].encryptedSha256 -cmatch `
                        '^[0-9a-f]{64}$' -and
                    [long]$member[0].decryptedByteLength -gt 100L -and
                    [string]$member[0].decryptedSha256 -cmatch `
                        '^[0-9a-f]{64}$' -and
                    [long]$member[0].signatureByteLength -eq 96L -and
                    [string]$member[0].signatureSha256 -cmatch `
                        '^[0-9a-f]{64}$'
                ) 'phase3b2_epinel_minimal_start_catalog_member_contract_invalid'

                $bodyBytes = $null
                $signatureBytes = $null
                try {
                    $bodyResponse = $httpClient.GetAsync($bodyUri).
                        GetAwaiter().GetResult()
                    try {
                        Assert-True ([int]$bodyResponse.StatusCode -eq 200) `
                            'phase3b2_epinel_minimal_start_catalog_body_status_invalid'
                        $bodyBytes = $bodyResponse.Content.ReadAsByteArrayAsync().
                            GetAwaiter().GetResult()
                    }
                    finally {
                        $bodyResponse.Dispose()
                    }
                    Assert-True (
                        $bodyBytes.Length -eq [long]$member[0].decryptedByteLength -and
                        (Get-ByteArraySha256Hex $bodyBytes) -ceq `
                            [string]$member[0].decryptedSha256 -and
                        $bodyBytes.Length -ge 16 -and
                        [Text.Encoding]::ASCII.GetString($bodyBytes, 0, 16) -ceq `
                            "SQLite format 3$([char]0)"
                    ) 'phase3b2_epinel_minimal_start_catalog_body_response_invalid'
                    $requiredLocalCatalogBodyCount++

                    $signatureResponse = $httpClient.GetAsync($signatureUri).
                        GetAwaiter().GetResult()
                    try {
                        Assert-True ([int]$signatureResponse.StatusCode -eq 200) `
                            'phase3b2_epinel_minimal_start_catalog_signature_status_invalid'
                        $signatureBytes = $signatureResponse.Content.
                            ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    }
                    finally {
                        $signatureResponse.Dispose()
                    }
                    Assert-True (
                        $signatureBytes.Length -eq `
                            [long]$member[0].signatureByteLength -and
                        (Get-ByteArraySha256Hex $signatureBytes) -ceq `
                            [string]$member[0].signatureSha256
                    ) 'phase3b2_epinel_minimal_start_catalog_signature_response_invalid'
                    $requiredLocalCatalogSignatureCount++
                }
                finally {
                    if ($null -ne $bodyBytes) { [Array]::Clear($bodyBytes, 0, $bodyBytes.Length) }
                    if ($null -ne $signatureBytes) {
                        [Array]::Clear($signatureBytes, 0, $signatureBytes.Length)
                    }
                }
            }
        }
        finally {
            $httpClient.Dispose()
            $handler.Dispose()
        }
        $requiredLocalCatalogAllSqlite = (
            $requiredLocalCatalogBodyCount -eq 3 -and
            $requiredLocalCatalogSignatureCount -eq 3
        )
        Assert-True $requiredLocalCatalogAllSqlite `
            'phase3b2_epinel_minimal_start_catalog_preflight_incomplete'
        $requiredLocalCatalogPreflightPerformed = $true
    }

    if (-not [string]::IsNullOrWhiteSpace(
            $RequiredLocalSausContractPath)) {
        $stageCode = 'required_local_saus_pair_preflight'
        Assert-True (
            (Test-Path -LiteralPath $RequiredLocalSausContractPath `
                -PathType Leaf) -and
            $RequiredLocalSausContractSha256 -cmatch '^[0-9a-f]{64}$' -and
            (Get-Sha256Hex $RequiredLocalSausContractPath) -ceq `
                $RequiredLocalSausContractSha256
        ) 'phase3b2_epinel_minimal_start_saus_contract_digest_invalid'

        $sausContract = Get-Content `
            -LiteralPath $RequiredLocalSausContractPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $sausBodyUri = [Uri][string]$sausContract.bodyUrl
        $sausSignatureUri = [Uri][string]$sausContract.signatureUrl
        $expectedSausPath =
            '/prdenv/150-b059c3f36c/StandaloneWindows64/pck/' +
            'saus/19e939d/asset-catalog.cat'
        Assert-True (
            $sausContract.contractId -ceq
                'nll/phase3b2-epinel-saus-http-pair-contract/v1' -and
            $sausContract.sausRevision -ceq '19e939d' -and
            $sausBodyUri.Scheme -ceq 'https' -and
            $sausBodyUri.Host -ceq 'cloud.nikke-kr.com' -and
            $sausBodyUri.AbsolutePath -ceq $expectedSausPath -and
            $sausSignatureUri.Scheme -ceq 'https' -and
            $sausSignatureUri.Host -ceq 'cloud.nikke-kr.com' -and
            $sausSignatureUri.AbsolutePath -ceq ($expectedSausPath + '.nds') -and
            [long]$sausContract.bodyByteLength -eq 13476L -and
            [string]$sausContract.bodySha256 -ceq
                'a8ad0f199f5db1213658c3238369ad472a98db74bb3a15a274931119ca22d0df' -and
            [string]$sausContract.bodyCrc32UnsignedDecimal -ceq
                '2651531605' -and
            [long]$sausContract.signatureByteLength -eq 96L -and
            [string]$sausContract.signatureSha256 -ceq
                '01de2cc79b8f04297faf262666a7701242a942ba74d48b513c0998ab08b91fa2' -and
            $sausContract.targetMappingVerified -and
            $sausContract.signaturePairMappingVerified -and
            -not $sausContract.signatureCryptographicVerificationPerformed -and
            $sausContract.rawEncryptedBodyPreserved
        ) 'phase3b2_epinel_minimal_start_saus_contract_invalid'

        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $httpClient = [Net.Http.HttpClient]::new($handler)
        $httpClient.Timeout = [TimeSpan]::FromSeconds(15)
        $sausBodyBytes = $null
        $sausSignatureBytes = $null
        try {
            $bodyResponse = $httpClient.GetAsync($sausBodyUri).
                GetAwaiter().GetResult()
            try {
                Assert-True ([int]$bodyResponse.StatusCode -eq 200) `
                    'phase3b2_epinel_minimal_start_saus_body_status_invalid'
                $sausBodyBytes = $bodyResponse.Content.ReadAsByteArrayAsync().
                    GetAwaiter().GetResult()
            }
            finally {
                $bodyResponse.Dispose()
            }
            $observedCrc32 = Get-Crc32Unsigned $sausBodyBytes
            Assert-True (
                $sausBodyBytes.Length -eq [long]$sausContract.bodyByteLength -and
                (Get-ByteArraySha256Hex $sausBodyBytes) -ceq
                    [string]$sausContract.bodySha256 -and
                $observedCrc32.ToString() -ceq
                    [string]$sausContract.bodyCrc32UnsignedDecimal
            ) 'phase3b2_epinel_minimal_start_saus_body_response_invalid'
            $requiredLocalSausBodyCount = 1
            $requiredLocalSausBodyCrc32Matched = $true

            $signatureResponse = $httpClient.GetAsync($sausSignatureUri).
                GetAwaiter().GetResult()
            try {
                Assert-True ([int]$signatureResponse.StatusCode -eq 200) `
                    'phase3b2_epinel_minimal_start_saus_signature_status_invalid'
                $sausSignatureBytes = $signatureResponse.Content.
                    ReadAsByteArrayAsync().GetAwaiter().GetResult()
            }
            finally {
                $signatureResponse.Dispose()
            }
            Assert-True (
                $sausSignatureBytes.Length -eq
                    [long]$sausContract.signatureByteLength -and
                (Get-ByteArraySha256Hex $sausSignatureBytes) -ceq
                    [string]$sausContract.signatureSha256
            ) 'phase3b2_epinel_minimal_start_saus_signature_response_invalid'
            $requiredLocalSausSignatureCount = 1
        }
        finally {
            if ($null -ne $sausBodyBytes) {
                [Array]::Clear($sausBodyBytes, 0, $sausBodyBytes.Length)
            }
            if ($null -ne $sausSignatureBytes) {
                [Array]::Clear(
                    $sausSignatureBytes, 0, $sausSignatureBytes.Length
                )
            }
            $httpClient.Dispose()
            $handler.Dispose()
        }
        Assert-True (
            $requiredLocalSausBodyCount -eq 1 -and
            $requiredLocalSausSignatureCount -eq 1 -and
            $requiredLocalSausBodyCrc32Matched
        ) 'phase3b2_epinel_minimal_start_saus_preflight_incomplete'
        $requiredLocalSausPreflightPerformed = $true
    }

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
    # Record a terminal sample after the full observation window so the last
    # pre-sleep sample is never mistaken for the total elapsed duration.
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
                -State Established -ErrorAction SilentlyContinue
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
    Write-AtomicUtf8NoBom $measurementPath `
        (($samples | ConvertTo-Json -Depth 4) + "`n")
    $measurementElapsedMilliseconds = [long]$deadline.Elapsed.TotalMilliseconds
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
        contractId = 'nll/phase3b2-epinel-minimal-reference-start/v1'
        startedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"
        )
        assessmentUid = $assessmentUid
        preflightReceiptSha256 = $expectedPreflightSha256
        deploymentReceiptSha256 = $expectedDeploymentSha256
        samplingLogRepairReceiptSha256 = `
            $expectedSamplingLogRepairSha256
        externalHead = $expectedExternalHead
        externalTree = $expectedExternalTree
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
        contractId = 'nll/phase3b2-epinel-minimal-reference-failure/v1'
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
