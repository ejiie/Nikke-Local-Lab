[CmdletBinding()]
param(
    [string]$EpinelRoot = 'C:\NLL\EpinelPS',
    [string]$ClientCloneRoot = 'C:\NLL\Clients\NIKKE-150.6.9-Physical',
    [string]$RuntimeRoot = 'C:\NLL\Runtime\LocalBootstrap-v1',
    [string]$BackupRoot = 'C:\NLL\Backups\Phase3B2\Physical-P0-v1',
    [string]$EvidenceRoot = 'C:\NLL\Evidence\Phase3B2\Physical\p0-v1',
    [string]$SamsungProtectedRoot = 'E:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP0',
    [string]$SamsungRepositoryRoot = 'E:\Users\zih44\Documents\Github\Nikke-Local-Lab'
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

$bootDisk = Get-DiskForDriveLetter 'C'
$samsungDisk = Get-DiskForDriveLetter 'E'
Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p0_verify_administrator_required'
Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem) `
    'phase3b2_physical_p0_verify_micron_boot_required'
$computerSystem = Get-CimInstance Win32_ComputerSystem
$deviceGuard = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
    -ClassName Win32_DeviceGuard
$runningSecurityServices = @($deviceGuard.SecurityServicesRunning |
    Where-Object { $null -ne $_ -and [int]$_ -ne 0 })
Assert-True (-not [bool]$computerSystem.HypervisorPresent -and
    [int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 0 -and
    $runningSecurityServices.Count -eq 0) `
    'phase3b2_physical_p0_verify_virtualization_boundary_invalid'
Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
        'NikkeLocalLab.Phase3B2.LocalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p0_verify_runtime_not_cold'

$pointerPath = Join-Path $SamsungProtectedRoot 'latest-attempt.pointer.json'
$localReceiptPath = Join-Path $EvidenceRoot 'applied-verification.receipt.json'
$localManifestPath = Join-Path $EvidenceRoot 'trusted-applied-manifest.json'
$verificationPath = Join-Path $EvidenceRoot 'post-apply-verification.receipt.json'
Assert-True ((Test-Path -LiteralPath $pointerPath -PathType Leaf) -and
    (Test-Path -LiteralPath $localReceiptPath -PathType Leaf) -and
    (Test-Path -LiteralPath $localManifestPath -PathType Leaf) -and
    -not (Test-Path -LiteralPath $verificationPath)) `
    'phase3b2_physical_p0_verify_evidence_shape_invalid'

$pointer = Get-Content -LiteralPath $pointerPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($pointer.contractId -ceq 'nll/phase3b2-physical-p0-pointer/v1' -and
    $pointer.statusCode -ceq 'succeeded' -and
    -not $pointer.serverExecutionStarted -and
    -not $pointer.clientExecutionStarted) `
    'phase3b2_physical_p0_verify_pointer_invalid'
$assessmentUid = [string]$pointer.assessmentUid
$attemptRoot = Join-Path $SamsungProtectedRoot $assessmentUid
$protectedReceiptPath = Join-Path $attemptRoot 'applied-verification.receipt.json'
$protectedManifestPath = Join-Path $attemptRoot 'trusted-applied-manifest.json'
$protectedVerificationPath = Join-Path $attemptRoot `
    'post-apply-verification.receipt.json'
Assert-True ((Test-PathDigest $protectedReceiptPath `
        ([long]$pointer.receiptByteLength) ([string]$pointer.receiptSha256)) -and
    (Get-Sha256Hex $localReceiptPath) -ceq (Get-Sha256Hex $protectedReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedVerificationPath)) `
    'phase3b2_physical_p0_verify_protected_receipt_mismatch'

$receipt = Get-Content -LiteralPath $localReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($receipt.contractId -ceq
        'nll/phase3b2-physical-p0-applied-verification/v1' -and
    $receipt.assessmentUid -ceq $assessmentUid -and
    $receipt.p0AppliedVerified -and
    $receipt.clientBuild -ceq '150.6.9' -and
    $receipt.externalHead -ceq '519c3db51ec24ca19307e93e85acde7885928a72' -and
    $receipt.externalTree -ceq 'b9e8bfb1b1e065427a48d40cb2bcf2f30215436a' -and
    $receipt.cleanBuildManifestSha256 -ceq
        '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3' -and
    $receipt.materializationReceiptSha256 -ceq
        '21be2e57a222833ce29128f58d6eb15e598e563c256cbbe3eb615e8e2803a774' -and
    [int]$receipt.mappedDomainCount -eq 17 -and
    [int]$receipt.rootCaInstalledCount -eq 1 -and
    [int]$receipt.firewallRuleCount -eq 17 -and
    [int]$receipt.firewallProgramCount -eq 17 -and
    $receipt.networkIsolationModeCode -ceq
        'program_scoped_outbound_block_with_loopback_hosts' -and
    $receipt.clientBootstrapModeCode -ceq
        'source_built_sail_abi_local_bootstrap' -and
    -not $receipt.officialLauncherModified -and
    -not $receipt.officialLauncherExecutionPermitted -and
    -not $receipt.antiCheatSubstitutionApplied -and
    -not $receipt.primaryInstallModified -and
    $receipt.physicalClientCloneModified -and
    -not $receipt.credentialBearingSourceCopiedToMicron -and
    -not $receipt.officialIdentityPersisted -and
    -not $receipt.officialCredentialPersisted -and
    -not $receipt.serverExecutionStarted -and
    -not $receipt.clientExecutionStarted) `
    'phase3b2_physical_p0_verify_applied_receipt_invalid'
Assert-True ((Test-PathDigest $localManifestPath `
        ([long]$receipt.appliedManifestByteLength) `
        ([string]$receipt.appliedManifestSha256)) -and
    (Test-PathDigest $protectedManifestPath `
        ([long]$receipt.appliedManifestByteLength) `
        ([string]$receipt.appliedManifestSha256))) `
    'phase3b2_physical_p0_verify_applied_manifest_mismatch'

$backupManifestPath = Join-Path $BackupRoot 'trusted-backup-manifest.json'
$protectedBackupRoot = Join-Path $attemptRoot 'rollback'
$protectedBackupManifestPath = Join-Path $protectedBackupRoot `
    'trusted-backup-manifest.json'
Assert-True ((Test-PathDigest $backupManifestPath `
        ([long]$receipt.backupManifestByteLength) `
        ([string]$receipt.backupManifestSha256)) -and
    (Test-PathDigest $protectedBackupManifestPath `
        ([long]$receipt.backupManifestByteLength) `
        ([string]$receipt.backupManifestSha256))) `
    'phase3b2_physical_p0_verify_backup_manifest_mismatch'
$backupManifest = Get-Content -LiteralPath $backupManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($backupManifest.contractId -ceq
        'nll/phase3b2-physical-p0-trusted-backup-manifest/v1' -and
    $backupManifest.assessmentUid -ceq $assessmentUid -and
    $backupManifest.clientCloneRoot -ceq $ClientCloneRoot -and
    $backupManifest.protectedAttemptRoot -ceq $attemptRoot -and
    -not $backupManifest.rootCaPreviouslyPresent -and
    [int]$backupManifest.firewallRuleCountBefore -eq 0) `
    'phase3b2_physical_p0_verify_backup_manifest_invalid'
$backupPins = @(
    [pscustomobject]@{ Name = 'hosts.original.bin'; Length = 1054L; Sha256 = '565955a47a890e8090a2987a234ba05e2624c84a587ba86e8648f912678984b9' },
    [pscustomobject]@{ Name = 'game-certificate.original.bin'; Length = 212549L; Sha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d' },
    [pscustomobject]@{ Name = 'sodium.original.bin'; Length = 304128L; Sha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888' }
)
foreach ($pin in $backupPins) {
    $localPath = Join-Path $BackupRoot $pin.Name
    $protectedPath = Join-Path $protectedBackupRoot $pin.Name
    Assert-True ((Test-PathDigest $localPath $pin.Length $pin.Sha256) -and
        (Test-PathDigest $protectedPath $pin.Length $pin.Sha256)) `
        'phase3b2_physical_p0_verify_backup_pin_mismatch'
}

$serverRoot = Join-Path $EpinelRoot 'EpinelPS\bin\Release\net10.0\win-x64'
$contextPath = 'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'
$profileReceiptPath = 'C:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\offline-synthetic-profile.receipt.json'
$dbPath = Join-Path $serverRoot 'db.json'
$envPath = Join-Path $SamsungRepositoryRoot '.env'
$identityPins = @(
    [pscustomobject]@{ Path = $contextPath; Length = 279L; Sha256 = 'cc84781bc0df8d8705ac237f19763808e8925c7706de231b24470469ca446cc2' },
    [pscustomobject]@{ Path = $profileReceiptPath; Length = 1260L; Sha256 = 'bca519531ead1c3d360e28d5b1515acb48d6681a3162d2e5bff67884a1678701' },
    [pscustomobject]@{ Path = $dbPath; Length = 413327L; Sha256 = 'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' },
    [pscustomobject]@{ Path = $envPath; Length = 207L; Sha256 = 'cdf4f2cf778281ad992e1023b9198db4eb6d3bdefebd3497c5b48bc7cd009ff0' }
)
foreach ($pin in $identityPins) {
    Assert-True (Test-PathDigest $pin.Path $pin.Length $pin.Sha256) `
        'phase3b2_physical_p0_verify_identity_pin_mismatch'
}
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$db = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
$envValues = @{}
foreach ($line in Get-Content -LiteralPath $envPath -Encoding UTF8) {
    $parts = $line -split '=', 2
    Assert-True ($parts.Count -eq 2) 'phase3b2_physical_p0_verify_operator_env_invalid'
    $envValues[$parts[0]] = $parts[1]
}
$md5 = [Security.Cryptography.MD5]::Create()
try {
    $passwordHash = (($md5.ComputeHash([Text.Encoding]::ASCII.GetBytes(
                    [string]$context.password)) |
                ForEach-Object { $_.ToString('x2') }) -join '')
}
finally { $md5.Dispose() }
Assert-True ($context.contractId -ceq 'nll/phase3b2-synthetic-runtime-context/v1' -and
    @($db.Users).Count -eq 1 -and
    [string]$db.Users[0].Username -ceq [string]$context.username -and
    [string]$db.Users[0].Password -ceq $passwordHash -and
    $null -eq $db.Users[0].SelectedClassicSoloRaidManagerId -and
    $envValues['NLL_PHASE3B2_ASSESSMENT_UID'] -ceq
        'a0598477-ed67-4122-b8b0-55a8c159c98b' -and
    $envValues['NLL_PHASE3B2_SYNTHETIC_USERNAME'] -ceq [string]$context.username -and
    $envValues['NLL_PHASE3B2_SYNTHETIC_PASSWORD'] -ceq [string]$context.password) `
    'phase3b2_physical_p0_verify_identity_binding_invalid'
Assert-True (@(Get-ChildItem -LiteralPath $serverRoot -File -Force `
        -Filter 'epinelps.db*' -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase3b2_physical_p0_verify_server_runtime_residue_present'

$clientGameRoot = Join-Path $ClientCloneRoot 'NIKKE\game'
$pluginsRoot = Join-Path $clientGameRoot 'nikke_Data\Plugins\x86_64'
$clientPins = @(
    [pscustomobject]@{ Path = (Join-Path $clientGameRoot 'nikke.exe'); Length = 794152L; Sha256 = '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30' },
    [pscustomobject]@{ Path = (Join-Path $pluginsRoot 'intl_cacert.pem'); Length = 213860L; Sha256 = '1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9' },
    [pscustomobject]@{ Path = (Join-Path $pluginsRoot 'sodium.dll'); Length = 358400L; Sha256 = '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662' },
    [pscustomobject]@{ Path = (Join-Path $ClientCloneRoot 'Launcher\intl_service\intl_cacert.pem'); Length = 209309L; Sha256 = '86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65' },
    [pscustomobject]@{ Path = 'C:\NIKKE\NIKKE\game\nikke.exe'; Length = 794152L; Sha256 = '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30' },
    [pscustomobject]@{ Path = 'C:\NIKKE\NIKKE\game\nikke_Data\Plugins\x86_64\intl_cacert.pem'; Length = 212549L; Sha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d' },
    [pscustomobject]@{ Path = 'C:\NIKKE\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll'; Length = 304128L; Sha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888' }
)
foreach ($pin in $clientPins) {
    Assert-True (Test-PathDigest $pin.Path $pin.Length $pin.Sha256) `
        'phase3b2_physical_p0_verify_client_or_primary_pin_mismatch'
}
Assert-True (Test-Path -LiteralPath (Join-Path $ClientCloneRoot `
        'Unity\com_proximabeta_NIKKE') -PathType Container) `
    'phase3b2_physical_p0_verify_resource_path_missing'

$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
Assert-True (Test-PathDigest $hostsPath 1690L `
        'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') `
    'phase3b2_physical_p0_verify_hosts_mismatch'
$caCerPath = Join-Path $EpinelRoot 'ServerSelector\myCA.cer'
Assert-True (Test-PathDigest $caCerPath 1266L `
        '6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda') `
    'phase3b2_physical_p0_verify_ca_source_mismatch'
$ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caCerPath)
$store = New-Object Security.Cryptography.X509Certificates.X509Store(
    [Security.Cryptography.X509Certificates.StoreName]::Root,
    [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
$store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
try {
    $rootCaCount = @($store.Certificates |
        Where-Object Thumbprint -CEQ $ca.Thumbprint).Count
}
finally { $store.Close() }
Assert-True ($rootCaCount -eq 1) 'phase3b2_physical_p0_verify_root_ca_mismatch'

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
        @((Join-Path $serverRoot 'EpinelPS.exe'),
            (Join-Path $RuntimeRoot `
                'artifact\NikkeLocalLab.Phase3B2.LocalBootstrap.exe')) |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Sort-Object -Unique
)
$firewallGroup = 'NLL Phase3B2 Physical Isolation'
$rules = @(Get-NetFirewallRule -Group $firewallGroup -ErrorAction Stop)
Assert-True ($rules.Count -eq 17 -and
    @($rules | Where-Object {
            $_.Enabled -ne 'True' -or $_.Direction -ne 'Outbound' -or
            $_.Action -ne 'Block'
        }).Count -eq 0) `
    'phase3b2_physical_p0_verify_firewall_rule_shape_invalid'
$actualFirewallPrograms = @($rules | ForEach-Object {
        (Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $_).Program
    } | ForEach-Object { [IO.Path]::GetFullPath($_) } | Sort-Object -Unique)
Assert-True ($actualFirewallPrograms.Count -eq 17 -and
    $expectedFirewallPrograms.Count -eq 17) `
    'phase3b2_physical_p0_verify_firewall_program_count_invalid'
foreach ($program in $expectedFirewallPrograms) {
    Assert-True (@($actualFirewallPrograms | Where-Object {
                $_.Equals($program, [StringComparison]::OrdinalIgnoreCase)
            }).Count -eq 1) `
        'phase3b2_physical_p0_verify_firewall_program_mismatch'
}

$verification = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p0-post-apply-verification/v1'
    verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $assessmentUid
    p0AppliedVerified = $true
    clientBuild = '150.6.9'
    externalHead = '519c3db51ec24ca19307e93e85acde7885928a72'
    cleanBuildManifestSha256 = '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3'
    appliedReceiptByteLength = (Get-Item -LiteralPath $localReceiptPath).Length
    appliedReceiptSha256 = Get-Sha256Hex $localReceiptPath
    backupManifestSha256 = Get-Sha256Hex $backupManifestPath
    appliedManifestSha256 = Get-Sha256Hex $localManifestPath
    protectedBackupVerified = $true
    mappedDomainCount = 17
    rootCaInstalledCount = 1
    firewallRuleCount = 17
    firewallProgramCount = 17
    networkIsolationModeCode = 'program_scoped_outbound_block_with_loopback_hosts'
    systemNetworkAvailable =
        [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    ipv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 `
        -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count
    ipv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 `
        -DestinationPrefix '::/0' -ErrorAction SilentlyContinue).Count
    primaryInstallModified = $false
    officialLauncherModified = $false
    officialLauncherExecutionPermitted = $false
    antiCheatSubstitutionApplied = $false
    credentialBearingSourceCopiedToMicron = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'return_to_samsung_and_prepare_physical_p1_server_only'
}
Write-AtomicUtf8NoBom $verificationPath `
    (($verification | ConvertTo-Json -Depth 8) + "`n")
Copy-Item -LiteralPath $verificationPath -Destination $protectedVerificationPath
Assert-True ((Get-Item -LiteralPath $verificationPath).Length -eq
        (Get-Item -LiteralPath $protectedVerificationPath).Length -and
    (Get-Sha256Hex $verificationPath) -ceq
        (Get-Sha256Hex $protectedVerificationPath)) `
    'phase3b2_physical_p0_verify_receipt_protection_failed'

[pscustomobject]@{
    Receipt = $verification
    ProtectedReceiptPath = $protectedVerificationPath
    ProtectedReceiptByteLength = (Get-Item -LiteralPath $protectedVerificationPath).Length
    ProtectedReceiptSha256 = Get-Sha256Hex $protectedVerificationPath
} | ConvertTo-Json -Depth 10
