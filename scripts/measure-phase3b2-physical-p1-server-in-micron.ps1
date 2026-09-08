[CmdletBinding()]
param(
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$ClientCloneRoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical',
    [string]$P0EvidenceRoot = 'C:\NLL\Evidence\Phase3B2\Physical\p0-v1',
    [string]$P1EvidenceRoot =
        'C:\NLL\Evidence\Phase3B2\Physical\p1-server-only-v1',
    [string]$SamsungProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP1',
    [string]$SamsungP0ProtectedRoot =
        'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP0'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$serverProcess = $null
$serverStarted = $false
$serverStopped = $false
$databaseBackupCreated = $false
$databaseRestored = $false
$sqliteRuntimeRemoved = $false
$measurementCompleted = $false
$stageCode = 'initialization'
$tcp = @()
$udp = @()
$assessmentUid = [Guid]::NewGuid().ToString('D')
$attemptRoot = Join-Path $SamsungProtectedRoot $assessmentUid
$latestPointerPath = Join-Path $SamsungProtectedRoot 'latest-attempt.pointer.json'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-ByteSha256Hex {
    param([byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($Bytes) |
                    ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $algorithm.Dispose() }
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

function Read-SharedFileBytes {
    param([string]$Path)
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    $memory = [IO.MemoryStream]::new()
    try {
        $stream.CopyTo($memory)
        return ,$memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $stream.Dispose()
    }
}

function Get-StableSharedFileObservation {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) `
        'phase3b2_physical_p1_log_missing'
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        [byte[]]$first = Read-SharedFileBytes $Path
        Start-Sleep -Milliseconds 100
        [byte[]]$second = Read-SharedFileBytes $Path
        $firstSha256 = Get-ByteSha256Hex $first
        $secondSha256 = Get-ByteSha256Hex $second
        if ($first.Length -eq $second.Length -and
            $firstSha256 -ceq $secondSha256) {
            return [pscustomobject]@{
                Bytes = $second
                ByteLength = [long]$second.Length
                Sha256 = $secondSha256
            }
        }
    }
    throw 'phase3b2_physical_p1_log_not_stable'
}

function Get-SharedJsonDocument {
    param(
        [string]$Path,
        [int]$AttemptCount = 40,
        [switch]$ReturnNullOnExhaustion
    )
    for ($attempt = 0; $attempt -lt $AttemptCount; $attempt++) {
        try {
            [byte[]]$bytes = Read-SharedFileBytes $Path
            $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
            return ($text | ConvertFrom-Json)
        }
        catch {
            if ($attempt + 1 -lt $AttemptCount) {
                Start-Sleep -Milliseconds 100
            }
        }
    }
    if ($ReturnNullOnExhaustion) { return $null }
    throw 'phase3b2_physical_p1_shared_json_not_stable'
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

function Get-ProcessTreeMembers {
    param([int]$RootProcessId, [DateTimeOffset]$NotBeforeUtc)
    $all = @(Get-CimInstance -ClassName Win32_Process)
    $ids = [Collections.Generic.List[int]]::new()
    $members = [Collections.Generic.List[object]]::new()
    $ids.Add($RootProcessId)
    $root = @($all | Where-Object ProcessId -EQ $RootProcessId)
    Assert-True ($root.Count -eq 1) `
        'phase3b2_physical_p1_server_process_snapshot_missing'
    $members.Add($root[0])
    for ($index = 0; $index -lt $ids.Count; $index++) {
        $parent = $ids[$index]
        foreach ($child in @($all | Where-Object ParentProcessId -EQ $parent)) {
            $createdAtUtc = if ($null -eq $child.CreationDate) {
                $null
            }
            else { ([DateTimeOffset]$child.CreationDate).ToUniversalTime() }
            if (($null -eq $createdAtUtc -or $createdAtUtc -ge $NotBeforeUtc) -and
                -not $ids.Contains([int]$child.ProcessId)) {
                $ids.Add([int]$child.ProcessId)
                $members.Add($child)
            }
        }
    }
    return @($members)
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
        'phase3b2_physical_p1_hosts_state_invalid'
    Assert-True (Test-PathDigest $CertificatePath 213860L `
            '1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9') `
        'phase3b2_physical_p1_certificate_state_invalid'
    Assert-True (Test-PathDigest $SodiumPath 358400L `
            '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662') `
        'phase3b2_physical_p1_shim_state_invalid'
    Assert-True ((Test-PathDigest $CaPath 1266L `
                '6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda') -and
        (Get-RootCaCount $CaPath) -eq 1) `
        'phase3b2_physical_p1_root_ca_state_invalid'
    $rules = @(Get-NetFirewallRule -Group $FirewallGroup -ErrorAction Stop)
    Assert-True ($rules.Count -eq 17 -and
        @($rules | Where-Object {
                $_.Enabled -ne 'True' -or $_.Direction -ne 'Outbound' -or
                $_.Action -ne 'Block'
            }).Count -eq 0) `
        'phase3b2_physical_p1_firewall_rule_state_invalid'
    $actualPrograms = @($rules | ForEach-Object {
            (Get-NetFirewallApplicationFilter `
                -AssociatedNetFirewallRule $_).Program
        } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
    Assert-True ($actualPrograms.Count -eq 17 -and
        $ExpectedFirewallPrograms.Count -eq 17) `
        'phase3b2_physical_p1_firewall_program_count_invalid'
    foreach ($program in $ExpectedFirewallPrograms) {
        Assert-True (@($actualPrograms | Where-Object {
                    $_.Equals($program, [StringComparison]::OrdinalIgnoreCase)
                }).Count -eq 1) `
            'phase3b2_physical_p1_firewall_program_state_invalid'
    }
}

$serverRoot = Join-Path $EpinelRoot `
    'EpinelPS\bin\Release\net10.0\win-x64'
$serverExePath = Join-Path $serverRoot 'EpinelPS.exe'
$dbPath = Join-Path $serverRoot 'db.json'
$sqlitePaths = @('epinelps.db', 'epinelps.db-shm', 'epinelps.db-wal') |
    ForEach-Object { Join-Path $serverRoot $_ }
$contextPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'
$profileReceiptPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\offline-synthetic-profile.receipt.json'
$serverBuildManifestPath =
    'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\server-build.manifest.tsv'
$localBootstrapPath =
    'C:\NLL\Runtime\LocalBootstrap-v1\artifact\NikkeLocalLab.Phase3B2.LocalBootstrap.exe'
$localBootstrapReceiptPath =
    'C:\NLL\Runtime\LocalBootstrap-v1\local-bootstrap-build.receipt.json'
$localBootstrapManifestPath =
    'C:\NLL\Runtime\LocalBootstrap-v1\evidence\artifact.manifest.tsv'
$clientGameRoot = Join-Path $ClientCloneRoot 'NIKKE\game'
$clientExePath = Join-Path $clientGameRoot 'nikke.exe'
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

try {
    $stageCode = 'physical_boundary_preflight'
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_physical_p1_administrator_required'
    $bootDisk = Get-DiskForDriveLetter 'C'
    $samsungDisk = Get-DiskForDriveLetter 'E'
    Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem -and
        $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem) `
        'phase3b2_physical_p1_micron_boot_required'
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $deviceGuard = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
        -ClassName Win32_DeviceGuard
    $runningSecurityServices = @($deviceGuard.SecurityServicesRunning |
        Where-Object { $null -ne $_ -and [int]$_ -ne 0 })
    Assert-True (-not [bool]$computerSystem.HypervisorPresent -and
        [int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 0 -and
        $runningSecurityServices.Count -eq 0) `
        'phase3b2_physical_p1_virtualization_boundary_invalid'
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.LocalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p1_runtime_not_cold'
    Assert-True (-not (Test-Path -LiteralPath $P1EvidenceRoot) -and
        -not (Test-Path -LiteralPath $attemptRoot)) `
        'phase3b2_physical_p1_destination_not_cold'
    New-Item -ItemType Directory -Path $SamsungProtectedRoot, $attemptRoot -Force |
        Out-Null

    $stageCode = 'p0_contract_and_runtime_preflight'
    $p0Pins = @(
        [pscustomobject]@{ Path = (Join-Path $P0EvidenceRoot 'applied-verification.receipt.json'); Length = 2081L; Sha256 = '833f98e28ba60af0abc90e4f53cf2dc9904e07ceee87f78545a73d55ec650a5e' },
        [pscustomobject]@{ Path = (Join-Path $P0EvidenceRoot 'post-apply-verification.receipt.json'); Length = 1617L; Sha256 = '3c966bbb23a19e9e8251172eddf498c7afe541bb13f50df64fd7d8e570a778c5' },
        [pscustomobject]@{ Path = (Join-Path $P0EvidenceRoot 'trusted-applied-manifest.json'); Length = 1755L; Sha256 = '93b0308ea7777b70a4a246aef5c37eeec8f448ccb06ec8f109c7e68096d6d072' },
        [pscustomobject]@{ Path = (Join-Path $P0EvidenceRoot 'workflow.receipt.json'); Length = 814L; Sha256 = '879fe329353f477b8dec3e4216cd5d397f7a1de0c2284a301b86f19f8b52518d' },
        [pscustomobject]@{ Path = (Join-Path (Join-Path $SamsungP0ProtectedRoot '73f05d4f-b0e6-411d-b471-072b8ef3158b') 'workflow.receipt.json'); Length = 814L; Sha256 = '879fe329353f477b8dec3e4216cd5d397f7a1de0c2284a301b86f19f8b52518d' }
    )
    foreach ($pin in $p0Pins) {
        Assert-True (Test-PathDigest $pin.Path $pin.Length $pin.Sha256) `
            'phase3b2_physical_p1_p0_receipt_pin_mismatch'
    }
    $p0 = Get-Content -LiteralPath $p0Pins[1].Path -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($p0.contractId -ceq
            'nll/phase3b2-physical-p0-post-apply-verification/v1' -and
        $p0.assessmentUid -ceq '73f05d4f-b0e6-411d-b471-072b8ef3158b' -and
        $p0.p0AppliedVerified -and
        [int]$p0.mappedDomainCount -eq 17 -and
        [int]$p0.rootCaInstalledCount -eq 1 -and
        [int]$p0.firewallRuleCount -eq 17 -and
        [int]$p0.firewallProgramCount -eq 17 -and
        -not $p0.primaryInstallModified -and
        -not $p0.officialLauncherModified -and
        -not $p0.serverExecutionStarted -and
        -not $p0.clientExecutionStarted) `
        'phase3b2_physical_p1_p0_receipt_invalid'
    Assert-P0RuntimeState $hostsPath $certificatePath $sodiumPath $caPath `
        $firewallGroup $expectedFirewallPrograms
    $networkBefore = Get-NetworkObservation
    Assert-True ($networkBefore.SystemNetworkAvailable -and
        $networkBefore.UpPhysicalNetworkAdapterCount -eq 1 -and
        $networkBefore.NetworkProfileCount -eq 1 -and
        $networkBefore.Ipv4DefaultRouteCount -eq 1 -and
        $networkBefore.Ipv6DefaultRouteCount -eq 0) `
        'phase3b2_physical_p1_network_shape_invalid'

    $stageCode = 'server_profile_preflight'
    $profilePins = @(
        [pscustomobject]@{ Path = $serverExePath; Length = 162304L; Sha256 = '648876d076c6f7f5e73d33dc533cd089a36785318c33b923b277e550a975777f' },
        [pscustomobject]@{ Path = $dbPath; Length = 413327L; Sha256 = 'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' },
        [pscustomobject]@{ Path = $contextPath; Length = 279L; Sha256 = 'cc84781bc0df8d8705ac237f19763808e8925c7706de231b24470469ca446cc2' },
        [pscustomobject]@{ Path = $profileReceiptPath; Length = 1260L; Sha256 = 'bca519531ead1c3d360e28d5b1515acb48d6681a3162d2e5bff67884a1678701' },
        [pscustomobject]@{ Path = $serverBuildManifestPath; Length = 63280L; Sha256 = '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3' },
        [pscustomobject]@{ Path = $localBootstrapPath; Length = 162816L; Sha256 = '4b6a8c844f291bdc956d0907f5898cb4b4fd54b0d95671ee1a75873867012773' },
        [pscustomobject]@{ Path = $localBootstrapReceiptPath; Length = 1200L; Sha256 = '5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11' },
        [pscustomobject]@{ Path = $localBootstrapManifestPath; Length = 561L; Sha256 = 'b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70' },
        [pscustomobject]@{ Path = $clientExePath; Length = 794152L; Sha256 = '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30' },
        [pscustomobject]@{ Path = 'C:\NIKKE\NIKKE\game\nikke.exe'; Length = 794152L; Sha256 = '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30' },
        [pscustomobject]@{ Path = 'C:\NIKKE\NIKKE\game\nikke_Data\Plugins\x86_64\intl_cacert.pem'; Length = 212549L; Sha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d' },
        [pscustomobject]@{ Path = 'C:\NIKKE\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll'; Length = 304128L; Sha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888' },
        [pscustomobject]@{ Path = (Join-Path $ClientCloneRoot 'Launcher\intl_service\intl_cacert.pem'); Length = 209309L; Sha256 = '86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65' }
    )
    foreach ($pin in $profilePins) {
        Assert-True (Test-PathDigest $pin.Path $pin.Length $pin.Sha256) `
            'phase3b2_physical_p1_profile_pin_mismatch'
    }
    Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq
            '519c3db51ec24ca19307e93e85acde7885928a72' -and
        (git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq
            'b9e8bfb1b1e065427a48d40cb2bcf2f30215436a' -and
        @(git -C $EpinelRoot status --porcelain=v1 `
            --untracked-files=all).Count -eq 0) `
        'phase3b2_physical_p1_external_checkout_invalid'
    Assert-True (@($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0) `
        'phase3b2_physical_p1_sqlite_precondition_invalid'
    Assert-True (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object LocalPort -In 80, 443).Count -eq 0 -and
        @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
            Where-Object LocalPort -EQ 443).Count -eq 0) `
        'phase3b2_physical_p1_listener_precondition_invalid'
    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $profile = Get-Content -LiteralPath $profileReceiptPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $dbBefore = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $usersBefore = @($dbBefore.Users)
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $expectedPasswordHash = (($md5.ComputeHash(
                    [Text.Encoding]::ASCII.GetBytes([string]$context.password)) |
                ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $md5.Dispose() }
    Assert-True ($context.contractId -ceq
            'nll/phase3b2-synthetic-runtime-context/v1' -and
        $profile.contractId -ceq 'nll/phase3b2-offline-synthetic-profile/v1' -and
        [int]$profile.characterCount -eq 193 -and
        [int]$profile.launcherPasswordPlaintextLength -eq 20 -and
        [int]$profile.launcherPasswordStorageLength -eq 32 -and
        -not $profile.launcherPasswordPlaintextPersistedInDatabase -and
        $usersBefore.Count -eq 1 -and
        [uint64]$usersBefore[0].ID -eq [uint64]$context.accountId -and
        [string]$usersBefore[0].Username -ceq [string]$context.username -and
        [string]$usersBefore[0].Password -ceq $expectedPasswordHash -and
        $null -eq $usersBefore[0].SelectedClassicSoloRaidManagerId -and
        -not $profile.officialIdentityPersisted -and
        -not $profile.officialCredentialPersisted) `
        'phase3b2_physical_p1_profile_binding_invalid'

    $stageCode = 'evidence_and_database_backup'
    New-Item -ItemType Directory -Path $P1EvidenceRoot | Out-Null
    $dbBackupPath = Join-Path $P1EvidenceRoot 'db.before.bin'
    $dbAfterPath = Join-Path $P1EvidenceRoot 'db.after-selection.bin'
    $stdoutPath = Join-Path $P1EvidenceRoot 'server.stdout.log'
    $stderrPath = Join-Path $P1EvidenceRoot 'server.stderr.log'
    $listenerPath = Join-Path $P1EvidenceRoot 'listener-observation.json'
    $processTreePath = Join-Path $P1EvidenceRoot 'process-tree-observation.json'
    $sqliteObservationPath = Join-Path $P1EvidenceRoot `
        'sqlite-runtime-observation.json'
    $measurementPath = Join-Path $P1EvidenceRoot `
        'server-only-measurement.receipt.json'
    $failurePath = Join-Path $P1EvidenceRoot 'measurement-failure.receipt.json'
    [IO.File]::WriteAllBytes($dbBackupPath, [IO.File]::ReadAllBytes($dbPath))
    Assert-True ((Get-Item -LiteralPath $dbBackupPath).Length -eq 413327L -and
        (Get-Sha256Hex $dbBackupPath) -ceq
            'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
        'phase3b2_physical_p1_database_backup_failed'
    $databaseBackupCreated = $true

    $stageCode = 'server_start'
    $startedAtUtc = [DateTimeOffset]::UtcNow
    $env:EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID = [string]$context.accountId
    $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID = [string]$context.managerId
    $frameworkLogVariables = [ordered]@{
        Logging__LogLevel__Microsoft = 'Warning'
        Logging__LogLevel__System = 'Warning'
    }
    $previousFrameworkLogValues = @{}
    foreach ($name in $frameworkLogVariables.Keys) {
        $previousFrameworkLogValues[$name] =
            [Environment]::GetEnvironmentVariable(
                $name, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable($name,
            $frameworkLogVariables[$name],
            [EnvironmentVariableTarget]::Process)
    }
    try {
        $serverProcess = Start-Process -FilePath $serverExePath `
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
        foreach ($name in $frameworkLogVariables.Keys) {
            [Environment]::SetEnvironmentVariable($name,
                $previousFrameworkLogValues[$name],
                [EnvironmentVariableTarget]::Process)
        }
    }

    $stageCode = 'selection_and_listener_observation'
    $selectionObservedAt = $null
    $listenerObservedAt = $null
    for ($attempt = 0; $attempt -lt 480; $attempt++) {
        Start-Sleep -Milliseconds 250
        $serverProcess.Refresh()
        if ($serverProcess.HasExited) {
            throw 'phase3b2_physical_p1_server_exited_before_listener'
        }
        if ($null -eq $selectionObservedAt) {
            $candidate = Get-SharedJsonDocument -Path $dbPath -AttemptCount 1 `
                -ReturnNullOnExhaustion
            if ($null -ne $candidate) {
                $candidateUsers = @($candidate.Users)
                if ($candidateUsers.Count -eq 1 -and
                    $null -ne $candidateUsers[0].SelectedClassicSoloRaidManagerId) {
                    Assert-True ([int]$candidateUsers[0].SelectedClassicSoloRaidManagerId `
                            -eq [int]$context.managerId) `
                        'phase3b2_physical_p1_runtime_selection_mismatch'
                    $selectionObservedAt = [DateTimeOffset]::UtcNow
                }
            }
        }
        $tcpCandidate = @(Get-NetTCPConnection -State Listen `
            -ErrorAction SilentlyContinue | Where-Object {
                $_.OwningProcess -eq $serverProcess.Id -and
                $_.LocalPort -in 80, 443
            })
        if ($tcpCandidate.Count -eq 2) {
            $listenerObservedAt = [DateTimeOffset]::UtcNow
            break
        }
    }
    Assert-True ($null -ne $selectionObservedAt -and
        $null -ne $listenerObservedAt -and
        $selectionObservedAt -le $listenerObservedAt) `
        'phase3b2_physical_p1_selection_listener_order_invalid'
    Start-Sleep -Seconds 2
    $tcp = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object {
            $_.OwningProcess -eq $serverProcess.Id -and
            $_.LocalPort -in 80, 443
        })
    $udp = @(Get-NetUDPEndpoint -ErrorAction Stop | Where-Object {
            $_.OwningProcess -eq $serverProcess.Id -and $_.LocalPort -eq 443
        })
    Assert-True (@($tcp | Where-Object {
                $_.LocalAddress -eq '127.0.0.1' -and $_.LocalPort -eq 80
            }).Count -eq 1 -and
        @($tcp | Where-Object {
                $_.LocalAddress -eq '127.0.0.1' -and $_.LocalPort -eq 443
            }).Count -eq 1 -and
        @($tcp | Where-Object LocalAddress -NE '127.0.0.1').Count -eq 0 -and
        $udp.Count -eq 0) `
        'phase3b2_physical_p1_listener_shape_invalid'
    $listener = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p1-listener-observation/v1'
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        tcpBindings = @($tcp | Sort-Object LocalPort | ForEach-Object {
                "tcp:$($_.LocalAddress):$($_.LocalPort)"
            })
        udpBindings = @()
        serverExecutionStarted = $true
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $listenerPath `
        (($listener | ConvertTo-Json -Depth 5) + "`n")

    $stageCode = 'server_settle_and_process_observation'
    Start-Sleep -Seconds 10
    $serverProcess.Refresh()
    Assert-True (-not $serverProcess.HasExited -and
        @(Get-Process -Name nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.LocalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p1_server_or_client_runtime_drift'
    $networkSettled = Get-NetworkObservation
    Assert-True ($networkSettled.SystemNetworkAvailable -and
        $networkSettled.UpPhysicalNetworkAdapterCount -eq 1 -and
        $networkSettled.NetworkProfileCount -eq 1 -and
        $networkSettled.Ipv4DefaultRouteCount -eq 1 -and
        $networkSettled.Ipv6DefaultRouteCount -eq 0) `
        'phase3b2_physical_p1_network_drift'
    $processTree = @(Get-ProcessTreeMembers $serverProcess.Id $startedAtUtc)
    Assert-True ($processTree.Count -eq 1 -and
        [string]$processTree[0].Name -ceq 'EpinelPS.exe') `
        'phase3b2_physical_p1_unexpected_server_child_process'
    $processTreeIds = @($processTree | ForEach-Object { [int]$_.ProcessId })
    $connections = @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object OwningProcess -In $processTreeIds)
    $nonLoopbackConnections = @($connections | Where-Object {
            $_.RemoteAddress -and
            $_.RemoteAddress -notin @('0.0.0.0', '127.0.0.1', '::', '::1')
        })
    Assert-True ($nonLoopbackConnections.Count -eq 0) `
        'phase3b2_physical_p1_nonloopback_connection_observed'
    $treeReceipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p1-process-tree-observation/v1'
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        members = @($processTree | ForEach-Object {
                [ordered]@{
                    processId = [int]$_.ProcessId
                    parentProcessId = [int]$_.ParentProcessId
                    executableName = [string]$_.Name
                }
            })
        nonLoopbackSuccessfulConnectionCount = $nonLoopbackConnections.Count
        serverExecutionStarted = $true
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $processTreePath `
        (($treeReceipt | ConvertTo-Json -Depth 5) + "`n")

    $stageCode = 'controlled_synthetic_login_observation'
    $loginBody = [ordered]@{
        account = [string]$context.username
        password = $expectedPasswordHash
    } | ConvertTo-Json -Compress
    $loginRaw = Invoke-RestMethod `
        -Uri 'http://127.0.0.1/account/login?seq=nll_phase3b2_physical_p1' `
        -Method Post -ContentType 'application/json' -Body $loginBody
    $loginDocument = if ($loginRaw -is [string]) {
        $loginRaw | ConvertFrom-Json
    }
    else { $loginRaw }
    Assert-True ([int]$loginDocument.ret -eq 0 -and
        [bool]$loginDocument.is_login -and
        ([string]$loginDocument.token).StartsWith(
            'v4.local.', [StringComparison]::Ordinal) -and
        [string]$loginDocument.uid -ceq [string]$context.accountId) `
        'phase3b2_physical_p1_controlled_login_rejected'
    $loginBody = $null
    $loginRaw = $null
    $loginDocument = $null

    $stageCode = 'database_and_log_observation'
    $dbAfter = Get-SharedJsonDocument -Path $dbPath -AttemptCount 40
    $usersAfter = @($dbAfter.Users)
    Assert-True ($usersAfter.Count -eq 1 -and
        [uint64]$usersAfter[0].ID -eq [uint64]$context.accountId -and
        [int]$usersAfter[0].SelectedClassicSoloRaidManagerId -eq
            [int]$context.managerId -and
        [string]$usersAfter[0].Password -ceq $expectedPasswordHash) `
        'phase3b2_physical_p1_selection_binding_mismatch'
    $activeRunCount = if ($usersAfter[0].SoloRaidData) {
        @($usersAfter[0].SoloRaidData.PSObject.Properties | Where-Object {
                $_.Value.LevelData -and
                @($_.Value.LevelData | Where-Object IsOpened).Count -gt 0
            }).Count
    }
    else { 0 }
    Assert-True ($activeRunCount -eq 0) `
        'phase3b2_physical_p1_active_run_present'
    [IO.File]::WriteAllBytes($dbAfterPath, [IO.File]::ReadAllBytes($dbPath))
    $stdoutLive = Get-StableSharedFileObservation $stdoutPath
    $stderrLive = Get-StableSharedFileObservation $stderrPath
    $stdoutText = [Text.UTF8Encoding]::new($false, $true).GetString(
        $stdoutLive.Bytes)
    $stderrText = [Text.UTF8Encoding]::new($false, $true).GetString(
        $stderrLive.Bytes)
    $combinedLog = $stdoutText + "`n" + $stderrText
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
        'phase3b2_physical_p1_sensitive_log_exposure'

    $stageCode = 'server_stop_and_runtime_cleanup'
    Stop-Process -Id $serverProcess.Id -Force
    Wait-Process -Id $serverProcess.Id -Timeout 15 -ErrorAction SilentlyContinue
    $serverProcess.Refresh()
    Assert-True ($serverProcess.HasExited) `
        'phase3b2_physical_p1_server_stop_failed'
    $serverStopped = $true
    Start-Sleep -Milliseconds 500
    $stdoutFinal = Get-StableSharedFileObservation $stdoutPath
    $stderrFinal = Get-StableSharedFileObservation $stderrPath
    $sqliteMembers = @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_ -PathType Leaf
        } | ForEach-Object {
            [ordered]@{
                roleCode = switch ([IO.Path]::GetFileName($_)) {
                    'epinelps.db' { 'sqlite_main' }
                    'epinelps.db-shm' { 'sqlite_shared_memory' }
                    'epinelps.db-wal' { 'sqlite_write_ahead_log' }
                }
                byteLength = (Get-Item -LiteralPath $_).Length
                sha256 = Get-Sha256Hex $_
            }
        })
    Assert-True (@($sqliteMembers | Where-Object roleCode -EQ 'sqlite_main').Count `
            -eq 1) 'phase3b2_physical_p1_sqlite_runtime_not_observed'
    $sqliteObservation = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p1-sqlite-observation/v1'
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        memberCount = $sqliteMembers.Count
        members = $sqliteMembers
        cleanupPlanned = $true
        serverExecutionStarted = $true
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $sqliteObservationPath `
        (($sqliteObservation | ConvertTo-Json -Depth 6) + "`n")
    foreach ($path in $sqlitePaths) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    Assert-True (@($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0) `
        'phase3b2_physical_p1_sqlite_cleanup_failed'
    $sqliteRuntimeRemoved = $true
    [IO.File]::WriteAllBytes($dbPath, [IO.File]::ReadAllBytes($dbBackupPath))
    Assert-True (Test-PathDigest $dbPath 413327L `
            'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194') `
        'phase3b2_physical_p1_database_restore_failed'
    $databaseRestored = $true
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.LocalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0 -and
        @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object LocalPort -In 80, 443).Count -eq 0 -and
        @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
            Where-Object LocalPort -EQ 443).Count -eq 0) `
        'phase3b2_physical_p1_runtime_cleanup_invalid'
    Assert-P0RuntimeState $hostsPath $certificatePath $sodiumPath $caPath `
        $firewallGroup $expectedFirewallPrograms

    $stageCode = 'measurement_seal'
    $measurement = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p1-server-only-measurement/v1'
        measuredAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
        clientBuild = '150.6.9'
        externalHead = '519c3db51ec24ca19307e93e85acde7885928a72'
        externalTree = 'b9e8bfb1b1e065427a48d40cb2bcf2f30215436a'
        cleanBuildManifestSha256 =
            '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3'
        headlessEnabled = $true
        localOnlyEnabled = $true
        officialAssetAutoFetchEnabled = $false
        localeAutoFetchEnabled = $false
        gitUpdateEnabled = $false
        interactiveUpdateSurfaceEnabled = $false
        frameworkInformationLoggingEnabled = $false
        localOnlyHttp3Enabled = $false
        localOnlyAssetCachePathLoggingEnabled = $false
        clientBootstrapModeCode = 'source_built_sail_abi_local_bootstrap'
        networkIsolationModeCode =
            'program_scoped_outbound_block_with_loopback_hosts'
        systemNetworkAvailable = $networkSettled.SystemNetworkAvailable
        upPhysicalNetworkAdapterCount =
            $networkSettled.UpPhysicalNetworkAdapterCount
        networkProfileCount = $networkSettled.NetworkProfileCount
        ipv4DefaultRouteCount = $networkSettled.Ipv4DefaultRouteCount
        ipv6DefaultRouteCount = $networkSettled.Ipv6DefaultRouteCount
        mappedDomainCount = 17
        rootCaInstalledCount = 1
        firewallRuleCount = 17
        firewallProgramCount = 17
        httpIpv4LoopbackListenerCount = 1
        httpsIpv4LoopbackListenerCount = 1
        http3UdpListenerCount = 0
        wildcardListenerCount = 0
        lanListenerCount = 0
        unexpectedListenerCount = 0
        nonLoopbackAttemptObservationCode =
            'not_measured_no_audit_policy_mutation'
        nonLoopbackSuccessfulConnectionCount = $nonLoopbackConnections.Count
        processTreeMemberCount = $processTree.Count
        selectionObservedNoLaterThanListener = $true
        selectionRuntimeMutationCount = 0
        activeRunCount = $activeRunCount
        controlledSyntheticLoginAccepted = $true
        controlledLoginPasswordRepresentationCode =
            'md5_lower_hex_legacy_launcher_compatibility'
        sqliteCredentialBindingVerified = $true
        sqliteRuntimeObservedMemberCount = $sqliteMembers.Count
        rawSensitiveLogMatchCount = 0
        p0VerificationByteLength = (Get-Item -LiteralPath $p0Pins[1].Path).Length
        p0VerificationSha256 = Get-Sha256Hex $p0Pins[1].Path
        syntheticContextByteLength = (Get-Item -LiteralPath $contextPath).Length
        syntheticContextSha256 = Get-Sha256Hex $contextPath
        databaseBeforeByteLength = (Get-Item -LiteralPath $dbBackupPath).Length
        databaseBeforeSha256 = Get-Sha256Hex $dbBackupPath
        databaseAfterSelectionByteLength =
            (Get-Item -LiteralPath $dbAfterPath).Length
        databaseAfterSelectionSha256 = Get-Sha256Hex $dbAfterPath
        sqliteObservationByteLength =
            (Get-Item -LiteralPath $sqliteObservationPath).Length
        sqliteObservationSha256 = Get-Sha256Hex $sqliteObservationPath
        serverStdoutByteLength = $stdoutFinal.ByteLength
        serverStdoutSha256 = $stdoutFinal.Sha256
        serverStderrByteLength = $stderrFinal.ByteLength
        serverStderrSha256 = $stderrFinal.Sha256
        serverExecutionStarted = $true
        serverStoppedAfterMeasurement = $true
        databaseRestored = $true
        sqliteRuntimeRemoved = $true
        p0StillApplied = $true
        primaryInstallModified = $false
        officialLauncherModified = $false
        officialLauncherExecutionPermitted = $false
        antiCheatSubstitutionApplied = $false
        clientExecutionStarted = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        nextStepCode =
            'return_to_samsung_and_verify_physical_p1_server_only'
    }
    Write-AtomicUtf8NoBom $measurementPath `
        (($measurement | ConvertTo-Json -Depth 8) + "`n")
    $protectedMembers = @($dbBackupPath, $dbAfterPath, $stdoutPath,
        $stderrPath, $listenerPath, $processTreePath, $sqliteObservationPath,
        $measurementPath)
    foreach ($path in $protectedMembers) {
        Copy-Item -LiteralPath $path -Destination $attemptRoot
        $copyPath = Join-Path $attemptRoot (Split-Path -Leaf $path)
        Assert-True ((Get-Item -LiteralPath $copyPath).Length -eq
                (Get-Item -LiteralPath $path).Length -and
            (Get-Sha256Hex $copyPath) -ceq (Get-Sha256Hex $path)) `
            'phase3b2_physical_p1_protected_copy_failed'
    }
    $pointer = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p1-pointer/v1'
        assessmentUid = $assessmentUid
        p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
        statusCode = 'measured_and_runtime_restored'
        receiptRelativePath =
            "$assessmentUid/server-only-measurement.receipt.json"
        receiptByteLength = (Get-Item -LiteralPath (Join-Path $attemptRoot `
                'server-only-measurement.receipt.json')).Length
        receiptSha256 = Get-Sha256Hex (Join-Path $attemptRoot `
            'server-only-measurement.receipt.json')
        serverExecutionStarted = $true
        serverStoppedAfterMeasurement = $true
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $latestPointerPath `
        (($pointer | ConvertTo-Json -Depth 5) + "`n")
    $measurementCompleted = $true
    [pscustomobject]@{
        Receipt = $measurement
        ProtectedReceiptPath = Join-Path $attemptRoot `
            'server-only-measurement.receipt.json'
        ProtectedReceiptByteLength = $pointer.receiptByteLength
        ProtectedReceiptSha256 = $pointer.receiptSha256
    } | ConvertTo-Json -Depth 10
}
catch {
    $failureRecord = $_
    $safeFailureCode = if ($failureRecord.Exception.Message -cmatch
        '^phase3b2_[a-z0-9_:-]+$') {
        $failureRecord.Exception.Message
    }
    else { 'phase3b2_physical_p1_unexpected_error_redacted' }
    $exceptionTypeCode = $failureRecord.Exception.GetType().FullName
    $innerExceptionTypeCode = if ($null -ne
        $failureRecord.Exception.InnerException) {
        $failureRecord.Exception.InnerException.GetType().FullName
    }
    else { $null }
    if ($null -ne $serverProcess) {
        try {
            $serverProcess.Refresh()
            if (-not $serverProcess.HasExited) {
                Stop-Process -Id $serverProcess.Id -Force `
                    -ErrorAction SilentlyContinue
                Wait-Process -Id $serverProcess.Id -Timeout 15 `
                    -ErrorAction SilentlyContinue
            }
            $serverStopped = $true
        }
        catch { $serverStopped = $false }
    }
    foreach ($path in $sqlitePaths) {
        try {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        catch { }
    }
    $sqliteRuntimeRemoved = @($sqlitePaths | Where-Object {
            Test-Path -LiteralPath $_
        }).Count -eq 0
    if ($databaseBackupCreated) {
        try {
            [IO.File]::WriteAllBytes($dbPath,
                [IO.File]::ReadAllBytes($dbBackupPath))
            $databaseRestored = Test-PathDigest $dbPath 413327L `
                'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194'
        }
        catch { $databaseRestored = $false }
    }
    Remove-Item Env:\EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID,
        Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID -ErrorAction SilentlyContinue
    try {
        if (-not (Test-Path -LiteralPath $attemptRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $attemptRoot -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $P1EvidenceRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $P1EvidenceRoot -Force | Out-Null
        }
        $failure = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-p1-server-only-failure/v1'
            failedAtUtc =
                [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            assessmentUid = $assessmentUid
            p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
            failedStageCode = $stageCode
            failureCode = $safeFailureCode
            exceptionTypeCode = $exceptionTypeCode
            innerExceptionTypeCode = $innerExceptionTypeCode
            observedTcpBindings = @($tcp | Sort-Object LocalPort | ForEach-Object {
                    "tcp:$($_.LocalAddress):$($_.LocalPort)"
                })
            observedUdpBindings = @($udp | Sort-Object LocalPort | ForEach-Object {
                    "udp:$($_.LocalAddress):$($_.LocalPort)"
                })
            serverExecutionStarted = $serverStarted
            serverStopped = $serverStopped
            databaseBackupCreated = $databaseBackupCreated
            databaseRestored = $databaseRestored
            sqliteRuntimeRemoved = $sqliteRuntimeRemoved
            p0RollbackPerformed = $false
            clientExecutionStarted = $false
            nextStepCode = 'return_to_samsung_and_inspect_physical_p1_failure'
        }
        $localFailurePath = Join-Path $P1EvidenceRoot `
            'measurement-failure.receipt.json'
        $protectedFailurePath = Join-Path $attemptRoot `
            'measurement-failure.receipt.json'
        Write-AtomicUtf8NoBom $localFailurePath `
            (($failure | ConvertTo-Json -Depth 8) + "`n")
        Copy-Item -LiteralPath $localFailurePath -Destination $protectedFailurePath `
            -Force
        foreach ($variableName in @('dbBackupPath', 'stdoutPath', 'stderrPath',
                'listenerPath', 'processTreePath', 'sqliteObservationPath')) {
            $diagnosticPath = Get-Variable -Name $variableName -ValueOnly `
                -ErrorAction SilentlyContinue
            if ($diagnosticPath -and
                (Test-Path -LiteralPath $diagnosticPath -PathType Leaf)) {
                Copy-Item -LiteralPath $diagnosticPath -Destination $attemptRoot `
                    -Force
            }
        }
        $pointer = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-p1-pointer/v1'
            assessmentUid = $assessmentUid
            p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
            statusCode = 'failed_runtime_restoration_recorded'
            receiptRelativePath =
                "$assessmentUid/measurement-failure.receipt.json"
            receiptByteLength = (Get-Item -LiteralPath $protectedFailurePath).Length
            receiptSha256 = Get-Sha256Hex $protectedFailurePath
            serverExecutionStarted = $serverStarted
            serverStoppedAfterMeasurement = $serverStopped
            clientExecutionStarted = $false
        }
        Write-AtomicUtf8NoBom $latestPointerPath `
            (($pointer | ConvertTo-Json -Depth 5) + "`n")
    }
    catch { }
    throw "phase3b2_physical_p1_measurement_failed:$stageCode"
}
finally {
    if (-not $measurementCompleted) {
        Remove-Item Env:\EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID,
            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID `
            -ErrorAction SilentlyContinue
    }
}
