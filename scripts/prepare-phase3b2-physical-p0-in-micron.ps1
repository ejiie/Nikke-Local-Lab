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
        [IO.File]::WriteAllText($temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-BytesMeasured {
    param([string]$Path, [byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $expectedSha256 = [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace(
            '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
    [IO.File]::WriteAllBytes($Path, $Bytes)
    Assert-True ((Get-Item -LiteralPath $Path).Length -eq $Bytes.Length -and
        (Get-Sha256Hex $Path) -ceq $expectedSha256) `
        'phase3b2_physical_p0_measured_write_failed'
}

function Get-DiskForDriveLetter {
    param([char]$DriveLetter)
    return (Get-Partition -DriveLetter $DriveLetter | Get-Disk)
}

$stageCode = 'initialization'
$assessmentUid = [Guid]::NewGuid().ToString('D')
$attemptRoot = Join-Path $SamsungProtectedRoot $assessmentUid
$latestPointerPath = Join-Path $SamsungProtectedRoot 'latest-attempt.pointer.json'
$rollbackPath = 'C:\NLL\Tools\Rollback-Phase3B2-Physical-P0.ps1'
$mutationStarted = $false
$automaticRollbackCompleted = $false

try {
    $stageCode = 'physical_boundary_preflight'
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_physical_p0_administrator_required'
    $bootDisk = Get-DiskForDriveLetter 'C'
    $samsungDisk = Get-DiskForDriveLetter 'E'
    Assert-True ($bootDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        $bootDisk.IsBoot -and $bootDisk.IsSystem -and
        $samsungDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        -not $samsungDisk.IsBoot -and -not $samsungDisk.IsSystem) `
        'phase3b2_physical_p0_micron_boot_required'
    $computerSystem = Get-CimInstance Win32_ComputerSystem
    $deviceGuard = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard `
        -ClassName Win32_DeviceGuard
    $runningSecurityServices = @($deviceGuard.SecurityServicesRunning |
        Where-Object { $null -ne $_ -and [int]$_ -ne 0 })
    Assert-True (-not [bool]$computerSystem.HypervisorPresent -and
        [int]$deviceGuard.VirtualizationBasedSecurityStatus -eq 0 -and
        $runningSecurityServices.Count -eq 0) `
        'phase3b2_physical_p0_virtualization_boundary_invalid'
    Assert-True (@(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.LocalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p0_runtime_not_cold'
    Assert-True (-not (Test-Path -LiteralPath $BackupRoot) -and
        -not (Test-Path -LiteralPath $EvidenceRoot) -and
        -not (Test-Path -LiteralPath $attemptRoot) -and
        (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) `
        'phase3b2_physical_p0_destination_not_cold'
    New-Item -ItemType Directory -Path $SamsungProtectedRoot, $attemptRoot -Force |
        Out-Null

    $stageCode = 'materialization_and_identity_verification'
    $materializationRoot = Join-Path (Split-Path -Parent $SamsungProtectedRoot) `
        'PhysicalP0Materialization'
    $materializationReceiptPath = Join-Path (Join-Path $materializationRoot `
            'a0598477-ed67-4122-b8b0-55a8c159c98b') `
        'physical-server-profile-materialization.receipt.json'
    Assert-True ((Get-Item -LiteralPath $materializationReceiptPath).Length -eq 2721L -and
        (Get-Sha256Hex $materializationReceiptPath) -ceq
            '21be2e57a222833ce29128f58d6eb15e598e563c256cbbe3eb615e8e2803a774') `
        'phase3b2_physical_p0_materialization_receipt_mismatch'
    $materializationReceipt = Get-Content -LiteralPath $materializationReceiptPath `
        -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($materializationReceipt.contractId -ceq
            'nll/phase3b2-physical-server-profile-materialization/v2' -and
        $materializationReceipt.externalCheckoutClean -and
        $materializationReceipt.cleanBuildManifestSha256 -ceq
            '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3' -and
        -not $materializationReceipt.physicalClientCloneModified -and
        -not $materializationReceipt.systemTrustModified -and
        -not $materializationReceipt.serverExecutionStarted -and
        -not $materializationReceipt.clientExecutionStarted) `
        'phase3b2_physical_p0_materialization_receipt_invalid'

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
        Assert-True ((Test-Path -LiteralPath $pin.Path -PathType Leaf) -and
            (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
            (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
            'phase3b2_physical_p0_identity_pin_mismatch'
    }
    $context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    $db = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $envValues = @{}
    foreach ($line in Get-Content -LiteralPath $envPath -Encoding UTF8) {
        $parts = $line -split '=', 2
        Assert-True ($parts.Count -eq 2) 'phase3b2_physical_p0_operator_env_invalid'
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
        'phase3b2_physical_p0_identity_binding_invalid'

    $stageCode = 'client_clone_and_source_verification'
    $clientGameRoot = Join-Path $ClientCloneRoot 'NIKKE\game'
    $clientExePath = Join-Path $clientGameRoot 'nikke.exe'
    $pluginsRoot = Join-Path $clientGameRoot 'nikke_Data\Plugins\x86_64'
    $certificatePath = Join-Path $pluginsRoot 'intl_cacert.pem'
    $sodiumPath = Join-Path $pluginsRoot 'sodium.dll'
    $launcherCertificatePath = Join-Path $ClientCloneRoot `
        'Launcher\intl_service\intl_cacert.pem'
    $mainGameRoot = 'C:\NIKKE\NIKKE\game'
    $mainExePath = Join-Path $mainGameRoot 'nikke.exe'
    $mainCertificatePath = Join-Path $mainGameRoot `
        'nikke_Data\Plugins\x86_64\intl_cacert.pem'
    $mainSodiumPath = Join-Path $mainGameRoot `
        'nikke_Data\Plugins\x86_64\sodium.dll'
    $criticalPins = @(
        [pscustomobject]@{ Path = $clientExePath; Length = 794152L; Sha256 = '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30' },
        [pscustomobject]@{ Path = $certificatePath; Length = 212549L; Sha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d' },
        [pscustomobject]@{ Path = $sodiumPath; Length = 304128L; Sha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888' },
        [pscustomobject]@{ Path = $launcherCertificatePath; Length = 209309L; Sha256 = '86695b1be9225c3cf882d283f05c944e3aabbc1df6428a4424269a93e997dc65' },
        [pscustomobject]@{ Path = $mainExePath; Length = 794152L; Sha256 = '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30' },
        [pscustomobject]@{ Path = $mainCertificatePath; Length = 212549L; Sha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d' },
        [pscustomobject]@{ Path = $mainSodiumPath; Length = 304128L; Sha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888' }
    )
    foreach ($pin in $criticalPins) {
        Assert-True ((Test-Path -LiteralPath $pin.Path -PathType Leaf) -and
            (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
            (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
            'phase3b2_physical_p0_client_pin_mismatch'
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $ClientCloneRoot `
            'Unity\com_proximabeta_NIKKE') -PathType Container) `
        'phase3b2_physical_p0_resource_path_missing'

    $caCerPath = Join-Path $EpinelRoot 'ServerSelector\myCA.cer'
    $caPemPath = Join-Path $EpinelRoot 'ServerSelector\myCA.pem'
    $shimPath = Join-Path $EpinelRoot `
        'ServerSelector.Desktop\bin\Release\net10.0\win-x64\sodium.dll'
    $bootstrapExePath = Join-Path $RuntimeRoot `
        'artifact\NikkeLocalLab.Phase3B2.LocalBootstrap.exe'
    $serverExePath = Join-Path $serverRoot 'EpinelPS.exe'
    $sourcePins = @(
        [pscustomobject]@{ Path = $caCerPath; Length = 1266L; Sha256 = '6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda' },
        [pscustomobject]@{ Path = $caPemPath; Length = 1266L; Sha256 = '6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda' },
        [pscustomobject]@{ Path = $shimPath; Length = 358400L; Sha256 = '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662' },
        [pscustomobject]@{ Path = $bootstrapExePath; Length = 162816L; Sha256 = '4b6a8c844f291bdc956d0907f5898cb4b4fd54b0d95671ee1a75873867012773' },
        [pscustomobject]@{ Path = $serverExePath; Length = 162304L; Sha256 = '648876d076c6f7f5e73d33dc533cd089a36785318c33b923b277e550a975777f' },
        [pscustomobject]@{ Path = $rollbackPath; Length = 7822L; Sha256 = 'b75f68d1b948e9ffed21b02b86d3af71c8c76379bab51b98111ab1d5e451a81c' }
    )
    foreach ($pin in $sourcePins) {
        Assert-True ((Test-Path -LiteralPath $pin.Path -PathType Leaf) -and
            (Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
            (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
            'phase3b2_physical_p0_source_pin_mismatch'
    }

    $expectedPrograms = [ordered]@{
        'Launcher/Assistant.exe' = 'de363fd65ca1d29c6b322a3d11748a17d7e88688d57b4da88cf4e8f3fd436056'
        'Launcher/common_apps/dependency_shared(999998)/vc2015-2022x64/VC_redist.x64.exe' = 'a9f5d2eaf67bf0db0178b6552a71c523c707df0e2cc66c06bfbc08bdc53387e7'
        'Launcher/intl_service/intl_service.exe' = '4414dd30a9b2dc6b36f2b4da0aa16fa7a9b56716756b96d33cd2df64d004fc42'
        'Launcher/intl_service/INTLWebViewHelper.exe' = '3fe46d539e60c7063453f8f8bb7bffb471f29e0da7d2b972f62c8a205ceeec01'
        'Launcher/intl_service/tbs_browser.exe' = 'b026d674915a414a862c644b43ed1fc45c13e8f3b1b078db9d5b994af9a9e802'
        'Launcher/nikke_launcher.exe' = 'd836b2c1b27a832f81d65c6133ac5fc21c7ea01ff00a2dbdf1a7f67509e7afc6'
        'Launcher/startup_runner.exe' = '7219813a4bdeb995cac0e1053e3e23aa57f1a88bd613c69b04a30b8978c2ba3c'
        'Launcher/uninst.exe' = 'ff2ea43265c089fcde024413371932efd93a5b9764792825a4d29e14cc993d19'
        'Launcher/VersionService.exe' = '4c8842940c1f447f0e29d0eeaa81bb5887c503804631bfd3f44f4644012a2bd1'
        'NIKKE/game/AntiCheatExpert/ACE-Service64.exe' = '6cfed38df64fcbb4a9863c4684ff7b1ccc1baa1ac45923f603f4969ad8a96777'
        'NIKKE/game/AntiCheatExpert/ACE-Setup64.exe' = 'd7186923f18b2e6356c3b93e3262c49351bc9e98803a51051400f84b7ffde4ee'
        'NIKKE/game/nikke_Data/Plugins/x86_64/INTLWebViewHelper.exe' = 'bbb821b2132f8a4643f0a85666f8b943d1f89ed6233c76d9f1c3c65a14d7dc2a'
        'NIKKE/game/nikke.exe' = '2cfaa12b7d708aa6a741faee17c3ac14d8e9cd6be1b5e4e773ee1535b6ddaa30'
        'NIKKE/game/TQM64/TQMCenter_64.exe' = 'f9a69d21321bed941667c619132d0e61b1348c43c06e18bd65721fbc3edce1d2'
        'NIKKE/game/UnityCrashHandler64.exe' = 'e8f6c201d3758fdd7859e6c53f9bc5de1d17ae9d01ba014e13c5ae4d240d1405'
    }
    $clonePrograms = @(Get-ChildItem -LiteralPath $ClientCloneRoot -Recurse -File `
        -Force | Where-Object Extension -IEQ '.exe')
    Assert-True ($clonePrograms.Count -eq $expectedPrograms.Count) `
        'phase3b2_physical_p0_program_inventory_count_mismatch'
    foreach ($program in $clonePrograms) {
        $relative = $program.FullName.Substring($ClientCloneRoot.Length + 1).Replace('\', '/')
        Assert-True ($expectedPrograms.Contains($relative) -and
            (Get-Sha256Hex $program.FullName) -ceq [string]$expectedPrograms[$relative]) `
            'phase3b2_physical_p0_program_inventory_mismatch'
    }
    $firewallPrograms = @(
        @($clonePrograms | Select-Object -ExpandProperty FullName) +
            @($serverExePath, $bootstrapExePath) |
            Sort-Object -Unique
    )
    Assert-True ($firewallPrograms.Count -eq 17) `
        'phase3b2_physical_p0_firewall_program_count_mismatch'

    $stageCode = 'system_and_backup_preflight'
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    Assert-True ((Get-Item -LiteralPath $hostsPath).Length -eq 1054L -and
        (Get-Sha256Hex $hostsPath) -ceq
            '565955a47a890e8090a2987a234ba05e2624c84a587ba86e8648f912678984b9') `
        'phase3b2_physical_p0_hosts_baseline_mismatch'
    $targetDomains = @(
        'global-lobby.nikke-kr.com', 'cloud.nikke-kr.com', 'jp-lobby.nikke-kr.com',
        'us-lobby.nikke-kr.com', 'kr-lobby.nikke-kr.com', 'sea-lobby.nikke-kr.com',
        'hmt-lobby.nikke-kr.com', 'aws-na-dr.intlgame.com', 'sg-vas.intlgame.com',
        'aws-na.intlgame.com', 'na-community.playerinfinite.com', 'common-web.intlgame.com',
        'li-sg.intlgame.com', 'na.fleetlogd.com', 'www.jupiterlauncher.com',
        'data-aws-na.intlgame.com', 'sentry.io'
    )
    $hostsText = Get-Content -LiteralPath $hostsPath -Raw -Encoding UTF8
    Assert-True (@($targetDomains | Where-Object { $hostsText.Contains($_) }).Count -eq 0) `
        'phase3b2_physical_p0_hosts_target_already_present'
    Assert-True (-not (Get-Content -LiteralPath $certificatePath -Raw -Encoding UTF8).Contains(
            'Good SSL Ca')) 'phase3b2_physical_p0_certificate_already_patched'
    $firewallGroup = 'NLL Phase3B2 Physical Isolation'
    Assert-True (@(Get-NetFirewallRule -Group $firewallGroup `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_physical_p0_firewall_already_present'
    $ca = New-Object Security.Cryptography.X509Certificates.X509Certificate2($caCerPath)
    $store = New-Object Security.Cryptography.X509Certificates.X509Store(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
        $rootCaBefore = @($store.Certificates |
            Where-Object Thumbprint -CEQ $ca.Thumbprint).Count
    }
    finally { $store.Close() }
    Assert-True ($rootCaBefore -eq 0) 'phase3b2_physical_p0_root_ca_already_present'

    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    $hostsBackup = Join-Path $BackupRoot 'hosts.original.bin'
    $certificateBackup = Join-Path $BackupRoot 'game-certificate.original.bin'
    $sodiumBackup = Join-Path $BackupRoot 'sodium.original.bin'
    [IO.File]::WriteAllBytes($hostsBackup, [IO.File]::ReadAllBytes($hostsPath))
    [IO.File]::WriteAllBytes($certificateBackup, [IO.File]::ReadAllBytes($certificatePath))
    [IO.File]::WriteAllBytes($sodiumBackup, [IO.File]::ReadAllBytes($sodiumPath))
    $backupPins = @(
        [pscustomobject]@{ Path = $hostsBackup; Length = 1054L; Sha256 = '565955a47a890e8090a2987a234ba05e2624c84a587ba86e8648f912678984b9' },
        [pscustomobject]@{ Path = $certificateBackup; Length = 212549L; Sha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d' },
        [pscustomobject]@{ Path = $sodiumBackup; Length = 304128L; Sha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888' }
    )
    foreach ($pin in $backupPins) {
        Assert-True ((Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
            (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
            'phase3b2_physical_p0_backup_verification_failed'
    }
    $backupManifest = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-trusted-backup-manifest/v1'
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        clientCloneRoot = $ClientCloneRoot
        protectedAttemptRoot = $attemptRoot
        hostsOriginalAttributes = [int](Get-Item -LiteralPath $hostsPath).Attributes
        gameCertificateOriginalAttributes = [int](Get-Item -LiteralPath $certificatePath).Attributes
        sodiumOriginalAttributes = [int](Get-Item -LiteralPath $sodiumPath).Attributes
        rootCaPreviouslyPresent = $false
        firewallRuleCountBefore = 0
        hostsBackupByteLength = 1054L
        hostsBackupSha256 = Get-Sha256Hex $hostsBackup
        gameCertificateBackupByteLength = 212549L
        gameCertificateBackupSha256 = Get-Sha256Hex $certificateBackup
        sodiumBackupByteLength = 304128L
        sodiumBackupSha256 = Get-Sha256Hex $sodiumBackup
        rollbackScriptByteLength = (Get-Item -LiteralPath $rollbackPath).Length
        rollbackScriptSha256 = Get-Sha256Hex $rollbackPath
    }
    $backupManifestPath = Join-Path $BackupRoot 'trusted-backup-manifest.json'
    Write-AtomicUtf8NoBom $backupManifestPath (($backupManifest | ConvertTo-Json) + "`n")
    $protectedBackupRoot = Join-Path $attemptRoot 'rollback'
    New-Item -ItemType Directory -Path $protectedBackupRoot -Force | Out-Null
    Copy-Item -LiteralPath $hostsBackup, $certificateBackup, $sodiumBackup,
        $backupManifestPath -Destination $protectedBackupRoot
    Assert-True (@(Get-ChildItem -LiteralPath $protectedBackupRoot -File -Force).Count -eq 4) `
        'phase3b2_physical_p0_protected_backup_copy_failed'

    $mutationStarted = $true
    $stageCode = 'system_hosts_apply'
    $hostsBlock = "`r`n# begin NLL Phase3B2 Physical entries`r`n" +
        (($targetDomains | ForEach-Object { "127.0.0.1 $_" }) -join "`r`n") +
        "`r`n# end NLL Phase3B2 Physical entries`r`n"
    $hostsBytes = [IO.File]::ReadAllBytes($hostsPath)
    $hostsAppendBytes = [Text.Encoding]::ASCII.GetBytes($hostsBlock)
    $newHostsBytes = [byte[]]::new($hostsBytes.Length + $hostsAppendBytes.Length)
    [Array]::Copy($hostsBytes, 0, $newHostsBytes, 0, $hostsBytes.Length)
    [Array]::Copy($hostsAppendBytes, 0, $newHostsBytes, $hostsBytes.Length,
        $hostsAppendBytes.Length)
    Write-BytesMeasured $hostsPath $newHostsBytes

    $stageCode = 'root_ca_apply'
    $store = New-Object Security.Cryptography.X509Certificates.X509Store(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $store.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { $store.Add($ca) } finally { $store.Close() }

    $stageCode = 'client_clone_certificate_and_shim_apply'
    $certificateBytes = [IO.File]::ReadAllBytes($certificatePath)
    $markerBytes = [Text.Encoding]::ASCII.GetBytes(
        "`nGood SSL Ca`n===============================`n")
    $pemBytes = [IO.File]::ReadAllBytes($caPemPath)
    $newCertificateBytes = [byte[]]::new(
        $certificateBytes.Length + $markerBytes.Length + $pemBytes.Length)
    [Array]::Copy($certificateBytes, 0, $newCertificateBytes, 0,
        $certificateBytes.Length)
    [Array]::Copy($markerBytes, 0, $newCertificateBytes,
        $certificateBytes.Length, $markerBytes.Length)
    [Array]::Copy($pemBytes, 0, $newCertificateBytes,
        $certificateBytes.Length + $markerBytes.Length, $pemBytes.Length)
    Write-BytesMeasured $certificatePath $newCertificateBytes
    Write-BytesMeasured $sodiumPath ([IO.File]::ReadAllBytes($shimPath))

    $stageCode = 'program_scoped_outbound_isolation_apply'
    $ordinal = 0
    foreach ($program in $firewallPrograms) {
        $ordinal++
        New-NetFirewallRule -Name ('NLL-P3B2-PHY-Block-{0:D3}' -f $ordinal) `
            -DisplayName ('NLL Phase3B2 physical outbound block {0:D3}' -f $ordinal) `
            -Group $firewallGroup -Direction Outbound -Action Block -Enabled True `
            -Profile Any -Program $program | Out-Null
    }

    $stageCode = 'applied_state_verification'
    Assert-True ((Get-Item -LiteralPath $hostsPath).Length -eq 1690L -and
        (Get-Sha256Hex $hostsPath) -ceq
            'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0') `
        'phase3b2_physical_p0_hosts_apply_failed'
    Assert-True ((Get-Item -LiteralPath $certificatePath).Length -eq 213860L -and
        (Get-Sha256Hex $certificatePath) -ceq
            '1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9') `
        'phase3b2_physical_p0_certificate_apply_failed'
    Assert-True ((Get-Item -LiteralPath $sodiumPath).Length -eq 358400L -and
        (Get-Sha256Hex $sodiumPath) -ceq
            '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662') `
        'phase3b2_physical_p0_shim_apply_failed'
    $verifyStore = New-Object Security.Cryptography.X509Certificates.X509Store(
        [Security.Cryptography.X509Certificates.StoreName]::Root,
        [Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
    $verifyStore.Open([Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly)
    try {
        $rootCaCount = @($verifyStore.Certificates |
            Where-Object Thumbprint -CEQ $ca.Thumbprint).Count
    }
    finally { $verifyStore.Close() }
    Assert-True ($rootCaCount -eq 1) 'phase3b2_physical_p0_root_ca_apply_failed'
    $rules = @(Get-NetFirewallRule -Group $firewallGroup -ErrorAction Stop)
    Assert-True ($rules.Count -eq 17) 'phase3b2_physical_p0_firewall_apply_failed'
    $appliedPrograms = @($rules | ForEach-Object {
            (Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $_).Program
        })
    foreach ($program in $firewallPrograms) {
        Assert-True (@($appliedPrograms | Where-Object {
                [IO.Path]::GetFullPath($_).Equals([IO.Path]::GetFullPath($program),
                    [StringComparison]::OrdinalIgnoreCase)
            }).Count -eq 1) 'phase3b2_physical_p0_firewall_program_mismatch'
    }
    foreach ($pin in $criticalPins | Where-Object {
            $_.Path -in @($launcherCertificatePath, $mainExePath,
                $mainCertificatePath, $mainSodiumPath)
        }) {
        Assert-True ((Get-Item -LiteralPath $pin.Path).Length -eq $pin.Length -and
            (Get-Sha256Hex $pin.Path) -ceq $pin.Sha256) `
            'phase3b2_physical_p0_protected_target_modified'
    }

    $stageCode = 'success_seal'
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    $appliedManifest = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-applied-manifest/v1'
        assessmentUid = $assessmentUid
        systemHosts = [ordered]@{ originalSha256 = '565955a47a890e8090a2987a234ba05e2624c84a587ba86e8648f912678984b9'; appliedSha256 = 'dda2e817ccdc7426508cfcb30ef63b8907fd3e9ac5a1826456cd9091b2e2c1f0'; mappedDomainCount = 17 }
        rootCa = [ordered]@{ sourceSha256 = '6228094602b86c0f3481f1a8c6e4e4964c2a324b609bc3eda4c2be05c08cfeda'; installedCount = 1 }
        clientCloneCertificate = [ordered]@{ originalSha256 = '921b28ebf4a2e5efd9aab1fbe9107e557db7396ab2ed27409eb4ff28553b099d'; appliedSha256 = '1b639977bb70416e8ab46d9b2d1acfc0130d99eb25738b230453151a104016a9' }
        clientCloneNativeShim = [ordered]@{ originalSha256 = '0dc8da22b601265d4405a4f49c475b049fedd2bf75c113776f1414af6df99888'; appliedSha256 = '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662' }
        firewall = [ordered]@{ groupCode = 'nll_phase3b2_physical_isolation'; ruleCount = 17; programCount = 17 }
        networkIsolationModeCode = 'program_scoped_outbound_block_with_loopback_hosts'
        officialLauncherExecutionPermitted = $false
        primaryInstallModified = $false
        rollbackScriptSha256 = Get-Sha256Hex $rollbackPath
    }
    $appliedManifestPath = Join-Path $EvidenceRoot 'trusted-applied-manifest.json'
    Write-AtomicUtf8NoBom $appliedManifestPath `
        (($appliedManifest | ConvertTo-Json -Depth 8) + "`n")
    $systemNetworkAvailable = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-applied-verification/v1'
        appliedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $assessmentUid
        p0AppliedVerified = $true
        clientBuild = '150.6.9'
        externalHead = '519c3db51ec24ca19307e93e85acde7885928a72'
        externalTree = 'b9e8bfb1b1e065427a48d40cb2bcf2f30215436a'
        cleanBuildManifestSha256 = '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3'
        materializationReceiptSha256 = '21be2e57a222833ce29128f58d6eb15e598e563c256cbbe3eb615e8e2803a774'
        clientCloneRoot = $ClientCloneRoot
        primaryInstallRoot = 'C:\NIKKE'
        mappedDomainCount = 17
        rootCaInstalledCount = 1
        firewallRuleCount = 17
        firewallProgramCount = 17
        networkIsolationModeCode = 'program_scoped_outbound_block_with_loopback_hosts'
        systemNetworkAvailable = $systemNetworkAvailable
        ipv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 `
            -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue).Count
        ipv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 `
            -DestinationPrefix '::/0' -ErrorAction SilentlyContinue).Count
        clientBootstrapModeCode = 'source_built_sail_abi_local_bootstrap'
        localBootstrapBuildReceiptSha256 = '5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11'
        sailAbiShimLoadMechanismCode = 'game_owned_shared_memory_plugin_abi'
        officialLauncherModified = $false
        officialLauncherExecutionPermitted = $false
        antiCheatSubstitutionApplied = $false
        primaryInstallModified = $false
        physicalClientCloneModified = $true
        backupManifestByteLength = (Get-Item $backupManifestPath).Length
        backupManifestSha256 = Get-Sha256Hex $backupManifestPath
        appliedManifestByteLength = (Get-Item $appliedManifestPath).Length
        appliedManifestSha256 = Get-Sha256Hex $appliedManifestPath
        credentialBearingSourceCopiedToMicron = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'measure_physical_p1_server_only'
    }
    $receiptPath = Join-Path $EvidenceRoot 'applied-verification.receipt.json'
    Write-AtomicUtf8NoBom $receiptPath (($receipt | ConvertTo-Json -Depth 8) + "`n")
    Copy-Item -LiteralPath $appliedManifestPath, $receiptPath -Destination $attemptRoot
    $pointer = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-pointer/v1'
        assessmentUid = $assessmentUid
        statusCode = 'succeeded'
        receiptRelativePath = "$assessmentUid/applied-verification.receipt.json"
        receiptByteLength = (Get-Item -LiteralPath (Join-Path $attemptRoot `
                'applied-verification.receipt.json')).Length
        receiptSha256 = Get-Sha256Hex (Join-Path $attemptRoot `
            'applied-verification.receipt.json')
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-AtomicUtf8NoBom $latestPointerPath (($pointer | ConvertTo-Json) + "`n")
    [pscustomobject]@{
        Receipt = $receipt
        ProtectedReceiptPath = Join-Path $attemptRoot 'applied-verification.receipt.json'
        ProtectedReceiptByteLength = $pointer.receiptByteLength
        ProtectedReceiptSha256 = $pointer.receiptSha256
    } | ConvertTo-Json -Depth 10
}
catch {
    $caughtException = $_
    $safeFailureCode = if ($caughtException.Exception.Message -cmatch
        '^phase3b2_[a-z0-9_:-]+$') { $caughtException.Exception.Message }
    else { 'phase3b2_physical_p0_unexpected_error_redacted' }
    if ($mutationStarted) {
        try {
            & $rollbackPath -EpinelRoot $EpinelRoot -ClientCloneRoot $ClientCloneRoot `
                -BackupRoot $BackupRoot -AutomaticFailureRollback | Out-Null
            $automaticRollbackCompleted = $true
        }
        catch { $automaticRollbackCompleted = $false }
    }
    try {
        if (-not (Test-Path -LiteralPath $attemptRoot)) {
            New-Item -ItemType Directory -Path $attemptRoot -Force | Out-Null
        }
        $failure = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-p0-failure/v1'
            failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            assessmentUid = $assessmentUid
            failedStageCode = $stageCode
            failureCode = $safeFailureCode
            mutationStarted = $mutationStarted
            automaticRollbackCompleted = $automaticRollbackCompleted
            primaryInstallModified = $false
            officialLauncherModified = $false
            serverExecutionStarted = $false
            clientExecutionStarted = $false
            nextStepCode = 'inspect_physical_p0_failure_before_server_start'
        }
        $failurePath = Join-Path $attemptRoot 'physical-p0.failure.receipt.json'
        Write-AtomicUtf8NoBom $failurePath (($failure | ConvertTo-Json) + "`n")
        $pointer = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase3b2-physical-p0-pointer/v1'
            assessmentUid = $assessmentUid
            statusCode = 'failed'
            receiptRelativePath = "$assessmentUid/physical-p0.failure.receipt.json"
            receiptByteLength = (Get-Item $failurePath).Length
            receiptSha256 = Get-Sha256Hex $failurePath
            serverExecutionStarted = $false
            clientExecutionStarted = $false
        }
        Write-AtomicUtf8NoBom $latestPointerPath (($pointer | ConvertTo-Json) + "`n")
    }
    catch { }
    throw "phase3b2_physical_p0_failed:$stageCode"
}
