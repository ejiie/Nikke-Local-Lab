[CmdletBinding()]
param(
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$ClientCloneRoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical',
    [string]$P0EvidenceRoot = 'C:\NLL\Evidence\Phase3B2\Physical\p0-v1',
    [string]$P1EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p1-server-only-v1',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP1'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, $Text,
            [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-DiskForDriveLetter {
    param([char]$DriveLetter)
    return (Get-Partition -DriveLetter $DriveLetter | Get-Disk)
}

function Test-PathDigest {
    param([string]$Path, [long]$Length, [string]$Sha256)
    return ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $Length -and
        (Get-Sha256Hex $Path) -ceq $Sha256)
}

function Get-RootCaCount {
    param([string]$CaPath)
    $ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2(
        $CaPath)
    $store = New-Object Security.Cryptography.X509Certificates.X509Store(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
        return @($store.Certificates |
            Where-Object Thumbprint -CEQ $ca.Thumbprint).Count
    }
    finally { $store.Close() }
}

function Get-NetworkObservation {
    $upPhysical = @(Get-NetAdapter -Physical -ErrorAction Stop |
        Where-Object Status -EQ 'Up').Count
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue).Count
    $ipv4 = @(Get-NetRoute -AddressFamily IPv4 `
        -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Where-Object State -EQ 'Alive').Count
    $ipv6 = @(Get-NetRoute -AddressFamily IPv6 `
        -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
        Where-Object State -EQ 'Alive').Count
    return [pscustomobject]@{
        SystemNetworkAvailable =
            [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
        UpPhysicalNetworkAdapterCount = $upPhysical
        NetworkProfileCount = $profiles
        Ipv4DefaultRouteCount = $ipv4
        Ipv6DefaultRouteCount = $ipv6
    }
}

function Assert-P0RuntimeState {
    param(
        [string]$HostsPath,
        [string]$CertificatePath,
        [string]$SodiumPath,
        [string]$CaPath,
        [string]$FirewallGroup,
        [string[]]$ExpectedFirewallPrograms
    )
    Assert-True (Test-PathDigest $HostsPath 1690L `
            'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') `
        'phase3b2_physical_p1_verify_hosts_state_invalid'
    Assert-True (Test-PathDigest $CertificatePath 213860L `
            '1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9') `
        'phase3b2_physical_p1_verify_certificate_state_invalid'
    Assert-True (Test-PathDigest $SodiumPath 358400L `
            '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662') `
        'phase3b2_physical_p1_verify_shim_state_invalid'
    Assert-True ((Test-PathDigest $CaPath 1266L `
                '6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda') -and
        (Get-RootCaCount $CaPath) -eq 1) `
        'phase3b2_physical_p1_verify_root_ca_state_invalid'
    $rules = @(Get-NetFirewallRule -Group $FirewallGroup -ErrorAction Stop)
    Assert-True ($rules.Count -eq 17 -and
        @($rules | Where-Object {
                $_.Enabled -ne 'True' -or $_.Direction -ne 'Outbound' -or
                $_.Action -ne 'Block'
            }).Count -eq 0) `
        'phase3b2_physical_p1_verify_firewall_rule_state_invalid'
    $actualPrograms = @($rules | ForEach-Object {
            (Get-NetFirewallApplicationFilter `
                -AssociatedNetFirewallRule $_).Program
        } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
    Assert-True ($actualPrograms.Count -eq 17 -and
        $ExpectedFirewallPrograms.Count -eq 17) `
        'phase3b2_physical_p1_verify_firewall_program_count_invalid'
    foreach ($program in $ExpectedFirewallPrograms) {
        Assert-True (@($actualPrograms | Where-Object {
                    $_.Equals($program, [StringComparison]::OrdinalIgnoreCase)
                }).Count -eq 1) `
            'phase3b2_physical_p1_verify_firewall_program_state_invalid'
    }
}

$serverRoot = Join-Path $EpinelRoot 'EpinelPS\bin\Release\net10.0\win-x64'
$serverExePath = Join-Path $serverRoot 'EpinelPS.exe'
$dbPath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $serverRoot $_ }
$contextPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'
$serverBuildManifestPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\server-build.manifest.tsv'
$localBootstrapPath =
    'C:\NLL\Runtime\LocalBootstrap-v1\artifact\NikkeLocalLab.Phase3B2.LocalBootstrap.exe'
$localBootstrapReceiptPath =
    'C:\NLL\Runtime\LocalBootstrap-v1\local-bootstrap-build.receipt.json'
$localBootstrapManifestPath =
    'C:\NLL\Runtime\LocalBootstrap-v1\evidence\artifact.manifest.tsv'
$clientGameRoot = Join-Path $ClientCloneRoot 'NIKKE\game'
$pluginsRoot = Join-Path $clientGameRoot 'nikke_Data\Plugins\x86_64'
$certificatePath = Join-Path $pluginsRoot 'intl_cacert.pem'
$sodiumPath = Join-Path $pluginsRoot 'sodium.dll'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$caPath = Join-Path $EpinelRoot 'ServerSelector\myCA.cer'
$firewallGroup = 'NLL Phase3B2 Physical Isolation'
$relativePrograms = @(
    'Launcher\Assistant.exe',
    'Launcher\common_apps\dependency_shared(999998)\vc2015-2022x64\VC_redist.x64.exe',
    'Launcher\intl_service\intl_service.exe',
    'Launcher\intl_service\INTLWebViewHelper.exe',
    'Launcher\intl_service\tbs_browser.exe',
    'Launcher\nikke_launcher.exe',
    'Launcher\startup_runner.exe',
    'Launcher\uninst.exe',
    'Launcher\VersionService.exe',
    'NIKKE\game\AntiCheatExpert\ACE-Service64.exe',
    'NIKKE\game\AntiCheatExpert\ACE-Setup64.exe',
    'NIKKE\game\nikke_Data\Plugins\x86_64\INTLWebViewHelper.exe',
    'NIKKE\game\nikke.exe',
    'NIKKE\game\TQM64\TQMCenter_64.exe',
    'NIKKE\game\UnityCrashHandler64.exe'
)
$expectedFirewallPrograms = @(
    @($relativePrograms | ForEach-Object { Join-Path $ClientCloneRoot $_ }) +
        @($serverExePath, $localBootstrapPath) |
        ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique
)

$stageCode = 'verification_preflight'
$assessmentUid = $null
$attemptRoot = $null
try {
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_physical_p1_verify_administrator_required'
    $bootDisk = Get-DiskForDriveLetter 'C'
    $samsungDisk = Get-DiskForDriveLetter 'E'
    Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem -and
        $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem) `
        'phase3b2_physical_p1_verify_micron_boot_required'
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $deviceGuard = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
        -ClassName Win32_DeviceGuard
    $runningSecurityServices = @($deviceGuard.SecurityServicesRunning |
        Where-Object { $null -ne $_ -and [int]$_ -ne 0 })
    Assert-True (-not [bool]$computerSystem.HypervisorPresent -and
        [int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 0 -and
        $runningSecurityServices.Count -eq 0) `
        'phase3b2_physical_p1_verify_virtualization_boundary_invalid'

    $stageCode = 'pointer_and_receipt_verification'
    $pointerPath = Join-Path $SamsungProtectedRoot 'latest-attempt.pointer.json'
    Assert-True (Test-Path -LiteralPath $pointerPath -PathType Leaf) `
        'phase3b2_physical_p1_verify_pointer_missing'
    $pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $assessmentUid = [string]$pointer.assessmentUid
    Assert-True ($pointer.contractId -ceq 'nll/phase3b2-physical-p1-pointer/v1' -and
        $assessmentUid -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and
        $pointer.p0AssessmentUid -ceq '73f05d4f-b0e6-411d-b471-072b8ef3158b' -and
        $pointer.statusCode -ceq 'measured_and_runtime_restored' -and
        $pointer.serverExecutionStarted -and
        $pointer.serverStoppedAfterMeasurement -and
        -not $pointer.clientExecutionStarted) `
        'phase3b2_physical_p1_verify_pointer_invalid'
    $attemptRoot = Join-Path $SamsungProtectedRoot $assessmentUid
    $measurementPath = Join-Path $P1EvidenceRoot `
        'server-only-measurement.receipt.json'
    $protectedMeasurementPath = Join-Path $attemptRoot `
        'server-only-measurement.receipt.json'
    Assert-True ((Test-PathDigest $protectedMeasurementPath `
                ([long]$pointer.receiptByteLength) ([string]$pointer.receiptSha256)) -and
        (Test-PathDigest $measurementPath ([long]$pointer.receiptByteLength) `
            ([string]$pointer.receiptSha256))) `
        'phase3b2_physical_p1_verify_measurement_pin_mismatch'
    $measurement = Get-Content -LiteralPath $measurementPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($measurement.contractId -ceq
            'nll/phase3b2-physical-p1-server-only-measurement/v1' -and
        $measurement.assessmentUid -ceq $assessmentUid -and
        $measurement.p0AssessmentUid -ceq
            '73f05d4f-b0e6-411d-b471-072b8ef3158b' -and
        $measurement.clientBuild -ceq '150.6.9' -and
        $measurement.externalHead -ceq
            '519c3db51ec24ca19307e93e85acde7885928a72' -and
        $measurement.externalTree -ceq
            'b9e8bfb1b1e065427a48d40cb2bcf2f30215436a' -and
        $measurement.headlessEnabled -and $measurement.localOnlyEnabled -and
        -not $measurement.officialAssetAutoFetchEnabled -and
        -not $measurement.localeAutoFetchEnabled -and
        -not $measurement.gitUpdateEnabled -and
        -not $measurement.interactiveUpdateSurfaceEnabled -and
        -not $measurement.frameworkInformationLoggingEnabled -and
        -not $measurement.localOnlyHttp3Enabled -and
        -not $measurement.localOnlyAssetCachePathLoggingEnabled -and
        [int]$measurement.mappedDomainCount -eq 17 -and
        [int]$measurement.rootCaInstalledCount -eq 1 -and
        [int]$measurement.firewallRuleCount -eq 17 -and
        [int]$measurement.firewallProgramCount -eq 17 -and
        [int]$measurement.httpIpv4LoopbackListenerCount -eq 1 -and
        [int]$measurement.httpsIpv4LoopbackListenerCount -eq 1 -and
        [int]$measurement.http3UdpListenerCount -eq 0 -and
        [int]$measurement.wildcardListenerCount -eq 0 -and
        [int]$measurement.lanListenerCount -eq 0 -and
        [int]$measurement.unexpectedListenerCount -eq 0 -and
        [int]$measurement.nonLoopbackSuccessfulConnectionCount -eq 0 -and
        [int]$measurement.processTreeMemberCount -eq 1 -and
        $measurement.selectionObservedNoLaterThanListener -and
        [int]$measurement.selectionRuntimeMutationCount -eq 0 -and
        [int]$measurement.activeRunCount -eq 0 -and
        $measurement.controlledSyntheticLoginAccepted -and
        $measurement.sqliteCredentialBindingVerified -and
        [int]$measurement.rawSensitiveLogMatchCount -eq 0 -and
        $measurement.serverExecutionStarted -and
        $measurement.serverStoppedAfterMeasurement -and
        $measurement.databaseRestored -and
        $measurement.sqliteRuntimeRemoved -and
        $measurement.p0StillApplied -and
        -not $measurement.primaryInstallModified -and
        -not $measurement.officialLauncherModified -and
        -not $measurement.officialLauncherExecutionPermitted -and
        -not $measurement.antiCheatSubstitutionApplied -and
        -not $measurement.clientExecutionStarted -and
        -not $measurement.officialIdentityPersisted -and
        -not $measurement.officialCredentialPersisted) `
        'phase3b2_physical_p1_verify_measurement_invalid'

    $stageCode = 'evidence_member_verification'
    $memberNames = @(
        'db.before.bin',
        'db.after-selection.bin',
        'server.stdout.log',
        'server.stderr.log',
        'listener-observation.json',
        'process-tree-observation.json',
        'sqlite-runtime-observation.json',
        'server-only-measurement.receipt.json'
    )
    foreach ($name in $memberNames) {
        $localPath = Join-Path $P1EvidenceRoot $name
        $protectedPath = Join-Path $attemptRoot $name
        Assert-True ((Test-Path -LiteralPath $localPath -PathType Leaf) -and
            (Test-Path -LiteralPath $protectedPath -PathType Leaf) -and
            (Get-Item -LiteralPath $localPath).Length -eq
                (Get-Item -LiteralPath $protectedPath).Length -and
            (Get-Sha256Hex $localPath) -ceq (Get-Sha256Hex $protectedPath)) `
            'phase3b2_physical_p1_verify_protected_member_mismatch'
    }
    $dbBeforePath = Join-Path $P1EvidenceRoot 'db.before.bin'
    $dbAfterPath = Join-Path $P1EvidenceRoot 'db.after-selection.bin'
    $stdoutPath = Join-Path $P1EvidenceRoot 'server.stdout.log'
    $stderrPath = Join-Path $P1EvidenceRoot 'server.stderr.log'
    $listenerPath = Join-Path $P1EvidenceRoot 'listener-observation.json'
    $processTreePath = Join-Path $P1EvidenceRoot 'process-tree-observation.json'
    $sqliteObservationPath = Join-Path $P1EvidenceRoot `
        'sqlite-runtime-observation.json'
    Assert-True ((Test-PathDigest $dbBeforePath `
                ([long]$measurement.databaseBeforeByteLength) `
                ([string]$measurement.databaseBeforeSha256)) -and
        (Test-PathDigest $dbAfterPath `
            ([long]$measurement.databaseAfterSelectionByteLength) `
            ([string]$measurement.databaseAfterSelectionSha256)) -and
        (Test-PathDigest $stdoutPath `
            ([long]$measurement.serverStdoutByteLength) `
            ([string]$measurement.serverStdoutSha256)) -and
        (Test-PathDigest $stderrPath `
            ([long]$measurement.serverStderrByteLength) `
            ([string]$measurement.serverStderrSha256)) -and
        (Test-PathDigest $sqliteObservationPath `
            ([long]$measurement.sqliteObservationByteLength) `
            ([string]$measurement.sqliteObservationSha256))) `
        'phase3b2_physical_p1_verify_measured_member_pin_mismatch'

    $listener = Get-Content -LiteralPath $listenerPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $tree = Get-Content -LiteralPath $processTreePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $sqliteObservation = Get-Content -LiteralPath $sqliteObservationPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($listener.contractId -ceq
            'nll/phase3b2-physical-p1-listener-observation/v1' -and
        @($listener.tcpBindings).Count -eq 2 -and
        @($listener.tcpBindings | Where-Object { $_ -ceq 'tcp:127.0.0.1:80' }).Count -eq 1 -and
        @($listener.tcpBindings | Where-Object { $_ -ceq 'tcp:127.0.0.1:443' }).Count -eq 1 -and
        @($listener.udpBindings).Count -eq 0 -and
        $listener.serverExecutionStarted -and
        -not $listener.clientExecutionStarted) `
        'phase3b2_physical_p1_verify_listener_evidence_invalid'
    Assert-True ($tree.contractId -ceq
            'nll/phase3b2-physical-p1-process-tree-observation/v1' -and
        @($tree.members).Count -eq 1 -and
        $tree.members[0].executableName -ceq 'EpinelPS.exe' -and
        [int]$tree.nonLoopbackSuccessfulConnectionCount -eq 0 -and
        $tree.serverExecutionStarted -and
        -not $tree.clientExecutionStarted) `
        'phase3b2_physical_p1_verify_process_tree_evidence_invalid'
    Assert-True ($sqliteObservation.contractId -ceq
            'nll/phase3b2-physical-p1-sqlite-observation/v1' -and
        [int]$sqliteObservation.memberCount -ge 1 -and
        @($sqliteObservation.members | Where-Object {
                $_.roleCode -ceq 'sqlite_main'
            }).Count -eq 1 -and
        $sqliteObservation.cleanupPlanned -and
        $sqliteObservation.serverExecutionStarted -and
        -not $sqliteObservation.clientExecutionStarted) `
        'phase3b2_physical_p1_verify_sqlite_evidence_invalid'

    $stageCode = 'sensitive_log_verification'
    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $expectedPasswordHash = (($md5.ComputeHash(
                    [Text.Encoding]::ASCII.GetBytes([string]$context.password)) |
                ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $md5.Dispose() }
    $combinedLog = [IO.File]::ReadAllText($stdoutPath,
        [Text.UTF8Encoding]::new($false, $true)) + "`n" +
        [IO.File]::ReadAllText($stderrPath,
            [Text.UTF8Encoding]::new($false, $true))
    $sensitiveValues = @(
        [string]$context.accountId,
        [string]$context.managerId,
        [string]$context.username,
        [string]$context.password,
        $expectedPasswordHash,
        'C:\NLL',
        'C:\NIKKE',
        'E:\Recovered_OldSSD'
    )
    Assert-True (@($sensitiveValues | Where-Object {
                $_ -and $combinedLog.IndexOf($_,
                    [StringComparison]::OrdinalIgnoreCase) -ge 0
            }).Count -eq 0) `
        'phase3b2_physical_p1_verify_sensitive_log_exposure'

    $stageCode = 'restored_runtime_verification'
    Assert-True (Test-PathDigest $dbPath 413327L `
            'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
        'phase3b2_physical_p1_verify_database_not_restored'
    Assert-True (@($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0 -and
        @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.LocalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0 -and
        @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object LocalPort -In 80, 443).Count -eq 0 -and
        @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
            Where-Object LocalPort -EQ 443).Count -eq 0) `
        'phase3b2_physical_p1_verify_runtime_not_cold'
    Assert-P0RuntimeState $hostsPath $certificatePath $sodiumPath $caPath `
        $firewallGroup $expectedFirewallPrograms
    $postNetwork = Get-NetworkObservation
    Assert-True ($postNetwork.SystemNetworkAvailable -and
        $postNetwork.UpPhysicalNetworkAdapterCount -eq 1 -and
        $postNetwork.NetworkProfileCount -eq 1 -and
        $postNetwork.Ipv4DefaultRouteCount -eq 1 -and
        $postNetwork.Ipv6DefaultRouteCount -eq 0) `
        'phase3b2_physical_p1_verify_network_shape_invalid'
    $immutablePins = @(
        [pscustomobject]@{ Path = $serverExePath; Length = 162304L; Sha256 = '648876d076c6f7f5e73d33dc533cd089a36785318c33b923b277e550a975777f' },
        [pscustomobject]@{ Path = $serverBuildManifestPath; Length = 63280L; Sha256 = '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3' },
        [pscustomobject]@{ Path = $localBootstrapPath; Length = 162816L; Sha256 = '4b6a8c844f291bdc956d0907f5898cb4b4fd54b0d95671ee1a75873867012773' },
        [pscustomobject]@{ Path = $localBootstrapReceiptPath; Length = 1200L; Sha256 = '5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11' },
        [pscustomobject]@{ Path = $localBootstrapManifestPath; Length = 561L; Sha256 = 'b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70' },
        [pscustomobject]@{ Path = 'C:\NIKKE\NIKKE\game\nikke.exe'; Length = 794152L; Sha256 = '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30' },
        [pscustomobject]@{ Path = 'C:\NIKKE\NIKKE\game\nikke_Data\Plugins\x86_64\intl_cacert.pem'; Length = 212549L; Sha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d' },
        [pscustomobject]@{ Path = 'C:\NIKKE\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll'; Length = 304128L; Sha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888' },
        [pscustomobject]@{ Path = (Join-Path $ClientCloneRoot 'Launcher\intl_service\intl_cacert.pem'); Length = 209309L; Sha256 = '86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65' },
        [pscustomobject]@{ Path = (Join-Path $P0EvidenceRoot 'post-apply-verification.receipt.json'); Length = 1617L; Sha256 = '3c966bbb23a19e9e8251172eddf498c7afe541bb13f50df64fd7d8e570a778c5' }
    )
    foreach ($pin in $immutablePins) {
        Assert-True (Test-PathDigest $pin.Path $pin.Length $pin.Sha256) `
            'phase3b2_physical_p1_verify_immutable_pin_mismatch'
    }

    $stageCode = 'verification_seal'
    $verification = [ordered]@{
        schemaVersion = 1
        contractId =
            'nll/phase3b2-physical-p1-post-measurement-verification/v1'
        verifiedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
        measurementReceiptByteLength =
            (Get-Item -LiteralPath $measurementPath).Length
        measurementReceiptSha256 = Get-Sha256Hex $measurementPath
        protectedEvidenceMemberCount = $memberNames.Count
        physicalBoundaryVerified = $true
        serverOnlyMeasurementVerified = $true
        controlledSyntheticLoginAccepted = $true
        sqliteCredentialBindingVerified = $true
        rawSensitiveLogMatchCount = 0
        serverExecutionStarted = $true
        serverStoppedAfterMeasurement = $true
        databaseRestored = $true
        sqliteRuntimeRemoved = $true
        p0StillApplied = $true
        primaryInstallModified = $false
        officialLauncherModified = $false
        officialLauncherExecutionPermitted = $false
        clientExecutionStarted = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        nextStepCode = 'return_to_samsung_and_prepare_physical_p2_client_start'
    }
    $localVerificationPath = Join-Path $P1EvidenceRoot `
        'post-measurement-verification.receipt.json'
    $protectedVerificationPath = Join-Path $attemptRoot `
        'post-measurement-verification.receipt.json'
    Assert-True (-not (Test-Path -LiteralPath $localVerificationPath) -and
        -not (Test-Path -LiteralPath $protectedVerificationPath)) `
        'phase3b2_physical_p1_verify_receipt_destination_not_cold'
    Write-AtomicUtf8NoBom $localVerificationPath `
        (($verification | ConvertTo-Json -Depth 8) + "`n")
    Copy-Item -LiteralPath $localVerificationPath `
        -Destination $protectedVerificationPath
    Assert-True ((Get-Item -LiteralPath $localVerificationPath).Length -eq
            (Get-Item -LiteralPath $protectedVerificationPath).Length -and
        (Get-Sha256Hex $localVerificationPath) -ceq
            (Get-Sha256Hex $protectedVerificationPath)) `
        'phase3b2_physical_p1_verify_receipt_protection_failed'
    [pscustomobject]@{
        Receipt = $verification
        ProtectedReceiptPath = $protectedVerificationPath
        ProtectedReceiptByteLength =
            (Get-Item -LiteralPath $protectedVerificationPath).Length
        ProtectedReceiptSha256 = Get-Sha256Hex $protectedVerificationPath
    } | ConvertTo-Json -Depth 10
}
catch {
    $safeFailureCode = if ($_.Exception.Message -cmatch
        '^phase3b2_[a-z0-9_:-]+$') {
        $_.Exception.Message
    }
    else { 'phase3b2_physical_p1_verify_unexpected_error_redacted' }
    try {
        if ($attemptRoot -and
            (Test-Path -LiteralPath $attemptRoot -PathType Container)) {
            $failure = [ordered]@{
                schemaVersion = 1
                contractId =
                    'nll/phase3b2-physical-p1-post-measurement-verification-failure/v1'
                failedAtUtc =
                    [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                assessmentUid = $assessmentUid
                failedStageCode = $stageCode
                failureCode = $safeFailureCode
                mutationPerformed = $false
                serverExecutionStartedByVerifier = $false
                clientExecutionStarted = $false
                nextStepCode =
                    'return_to_samsung_and_inspect_physical_p1_verification_failure'
            }
            $failurePath = Join-Path $attemptRoot `
                'post-measurement-verification.failure.receipt.json'
            if (-not (Test-Path -LiteralPath $failurePath)) {
                Write-AtomicUtf8NoBom $failurePath `
                    (($failure | ConvertTo-Json -Depth 6) + "`n")
            }
        }
    }
    catch { }
    throw "phase3b2_physical_p1_verification_failed:$stageCode"
}
