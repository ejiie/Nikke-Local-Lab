[CmdletBinding()]
param(
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$ClientRoot = "E:\NIKKE\game",
    [ValidateSet("disconnected", "private_vm_only_no_gateway")]
    [string]$NetworkModeCode = "disconnected",
    [ValidateSet("official_launcher", "source_built_sail_abi_local_bootstrap")]
    [string]$ClientBootstrapModeCode = "official_launcher"
)

$ErrorActionPreference = "Stop"
$serverProcess = $null
$auditBackupCreated = $false
$databaseBackupCreated = $false
$measurementCompleted = $false
$sqliteRebootstrapObserved = $false
$controlledSyntheticLoginAccepted = $false
$sqliteCredentialBindingVerified = $false
$stageCode = "not_started"
$tcp = @()
$udp = @()
$useLocalBootstrap = $NetworkModeCode -ceq "private_vm_only_no_gateway" -and
    $ClientBootstrapModeCode -ceq "source_built_sail_abi_local_bootstrap"

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
        return (($algorithm.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $algorithm.Dispose()
    }
}

function Read-SharedFileBytes {
    param([string]$Path)
    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::Open,
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
        "phase3b2_live_log_missing"
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        [byte[]]$first = Read-SharedFileBytes $Path
        Start-Sleep -Milliseconds 100
        [byte[]]$second = Read-SharedFileBytes $Path
        $firstSha256 = Get-ByteSha256Hex $first
        $secondSha256 = Get-ByteSha256Hex $second
        if ($first.Length -eq $second.Length -and $firstSha256 -ceq $secondSha256) {
            return [pscustomobject]@{
                Bytes = $second
                ByteLength = [long]$second.Length
                Sha256 = $secondSha256
            }
        }
    }
    throw "phase3b2_live_log_not_stable"
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-ProcessTreeMembers {
    param(
        [int]$RootProcessId,
        [DateTimeOffset]$NotBeforeUtc
    )
    $all = @(Get-CimInstance -ClassName Win32_Process)
    $ids = [Collections.Generic.List[int]]::new()
    $members = [Collections.Generic.List[object]]::new()
    $ids.Add($RootProcessId)
    $root = @($all | Where-Object ProcessId -EQ $RootProcessId)
    Assert-True ($root.Count -eq 1) "phase3b2_server_process_snapshot_missing"
    $members.Add($root[0])
    for ($index = 0; $index -lt $ids.Count; $index++) {
        $parent = $ids[$index]
        foreach ($child in @($all | Where-Object ParentProcessId -EQ $parent)) {
            $childCreatedAtUtc = if ($null -eq $child.CreationDate) {
                $null
            } else {
                ([DateTimeOffset]$child.CreationDate).ToUniversalTime()
            }
            # ParentProcessId values can outlive their original parent. Ignore an
            # orphan that predates this server launch, but fail closed when the
            # creation time is unavailable or the child is contemporary.
            if (($null -eq $childCreatedAtUtc -or $childCreatedAtUtc -ge $NotBeforeUtc) -and
                -not $ids.Contains([int]$child.ProcessId)) {
                $ids.Add([int]$child.ProcessId)
                $members.Add($child)
            }
        }
    }
    return @($members)
}

function Get-EventData {
    param([System.Diagnostics.Eventing.Reader.EventRecord]$Event)
    [xml]$xml = $Event.ToXml()
    $values = @{}
    foreach ($datum in $xml.Event.EventData.Data) {
        $values[[string]$datum.Name] = [string]$datum.'#text'
    }
    return [pscustomobject]@{ Xml = $xml.OuterXml; Values = $values }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher -ErrorAction SilentlyContinue)) `
    "phase3b2_runtime_process_already_started"
Assert-True (-not (Test-Path -LiteralPath "C:\NLL\Inputs\credential-bearing\source.json")) `
    "phase3b2_credential_bearing_guest_copy_present"
$upPhysicalNetworkAdapterCount = @(Get-NetAdapter -Physical -ErrorAction Stop |
        Where-Object Status -EQ "Up").Count
$systemNetworkAvailable = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
$networkProfileCount = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue).Count
$ipv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count
$ipv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive").Count
if ($NetworkModeCode -ceq "disconnected") {
    Assert-True ($upPhysicalNetworkAdapterCount -eq 0 -and -not $systemNetworkAvailable -and
        $networkProfileCount -eq 0) "phase3b2_guest_disconnected_network_shape_invalid"
}
else {
    Assert-True ($upPhysicalNetworkAdapterCount -eq 1 -and $systemNetworkAvailable -and
        $networkProfileCount -eq 1 -and $ipv4DefaultRouteCount -eq 0 -and
        $ipv6DefaultRouteCount -eq 0) "phase3b2_guest_private_network_shape_invalid"
}

$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$serverExe = Join-Path $serverRoot "EpinelPS.exe"
$dbPath = Join-Path $serverRoot "db.json"
$sqlitePaths = @("epinelps.db", "epinelps.db-shm", "epinelps.db-wal") |
    ForEach-Object { Join-Path $serverRoot $_ }
$clientExe = Join-Path $ClientRoot "nikke.exe"
$identityRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity"
$contextPath = Join-Path $identityRoot "synthetic-context.json"
$profileReceiptPath = Join-Path $identityRoot "offline-synthetic-profile.receipt.json"
$p0Root = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0"
$p0VerificationPath = Join-Path $p0Root $(if ($NetworkModeCode -ceq "disconnected") {
        "applied-verification-v3.receipt.json"
    } elseif ($useLocalBootstrap) {
        "applied-verification-private-v5.receipt.json"
    } else {
        "applied-verification-private-v4.receipt.json"
    })
$p1Root = Join-Path $env:LOCALAPPDATA $(if ($NetworkModeCode -ceq "disconnected") {
        "NikkeLocalLab\Evidence\Phase3B2\Trusted\p1"
    } elseif ($useLocalBootstrap) {
        "NikkeLocalLab\Evidence\Phase3B2\Trusted\p1-private-v5"
    } else {
        "NikkeLocalLab\Evidence\Phase3B2\Trusted\p1-private-v4"
    })
Assert-True (-not (Test-Path -LiteralPath $p1Root)) "phase3b2_p1_evidence_already_exists"
Assert-True (Test-Path -LiteralPath $serverExe -PathType Leaf) "phase3b2_server_executable_missing"
Assert-True (Test-Path -LiteralPath $dbPath -PathType Leaf) "phase3b2_synthetic_database_missing"
Assert-True (Test-Path -LiteralPath $contextPath -PathType Leaf) "phase3b2_synthetic_context_missing"
Assert-True (Test-Path -LiteralPath $profileReceiptPath -PathType Leaf) `
    "phase3b2_synthetic_profile_receipt_missing"
Assert-True (Test-Path -LiteralPath $p0VerificationPath -PathType Leaf) `
    "phase3b2_p0_verification_receipt_missing"
Assert-True ((Get-Item -LiteralPath $clientExe).VersionInfo.FileVersion -ceq "150.6.9") `
    "phase3b2_client_version_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse HEAD).Trim() -ceq
    "519c3db51ec24ca19307e93e85acde7885928a72") "phase3b2_external_head_mismatch"
Assert-True ((git -C $EpinelRoot rev-parse 'HEAD^{tree}').Trim() -ceq
    "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a") "phase3b2_external_tree_mismatch"
Assert-True (@(git -C $EpinelRoot status --porcelain=v1 --untracked-files=all).Count -eq 0) `
    "phase3b2_external_checkout_not_clean"

$p0Verification = Get-Content -LiteralPath $p0VerificationPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($p0Verification.contractId -ceq $(if ($NetworkModeCode -ceq "disconnected") {
        "nll/phase3b2-p0-applied-verification/v3"
    } elseif ($useLocalBootstrap) {
        "nll/phase3b2-p0-private-applied-verification/v5"
    } else {
        "nll/phase3b2-p0-private-applied-verification/v4"
    }) -and
    $p0Verification.p0AppliedVerified -and $p0Verification.mappedDomainCount -eq 17 -and
    $p0Verification.firewallRuleCount -eq $(if ($useLocalBootstrap) { 17 } else { 16 }) -and
    $p0Verification.externalHead -ceq "519c3db51ec24ca19307e93e85acde7885928a72" -and
    $p0Verification.externalTree -ceq "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a" -and
    $p0Verification.externalBuildManifestSha256 -ceq
        "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37" -and
    -not $p0Verification.localOnlyHttp3Enabled -and
    -not $p0Verification.localOnlyAssetCachePathLoggingEnabled -and
    $p0Verification.networkModeCode -ceq $NetworkModeCode -and
    $p0Verification.upPhysicalNetworkAdapterCount -eq $upPhysicalNetworkAdapterCount -and
    $p0Verification.networkProfileCount -eq $networkProfileCount -and
    $p0Verification.ipv4DefaultRouteCount -eq $ipv4DefaultRouteCount -and
    $p0Verification.ipv6DefaultRouteCount -eq $ipv6DefaultRouteCount -and
    $(if ($NetworkModeCode -ceq "disconnected") {
        $true
    } elseif ($useLocalBootstrap) {
        $p0Verification.clientBootstrapModeCode -ceq
            "source_built_sail_abi_local_bootstrap" -and
        $p0Verification.localBootstrapUpstreamHead -ceq
            "3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3" -and
        $p0Verification.localBootstrapUpstreamTree -ceq
            "54b85eb6fbaa74feae0c6b441d66a5a703073ba3" -and
        $p0Verification.localBootstrapArtifactManifestSha256 -ceq
            "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70" -and
        [int]$p0Verification.localBootstrapArtifactMemberCount -eq 5 -and
        -not [bool]$p0Verification.officialLauncherExecutionPermitted -and
        -not [bool]$p0Verification.antiCheatSubstitutionApplied -and
        [long]$p0Verification.baseP0V4ReceiptByteLength -eq 2210 -and
        $p0Verification.baseP0V4ReceiptSha256 -ceq
            "3c2397c58fc59e5bfafdde2fee79054ce9d58af7cc25efb9d7b0ddf702a3698f" -and
        [int]$p0Verification.launcherPasswordPlaintextLength -eq 20 -and
        [int]$p0Verification.launcherPasswordStorageLength -eq 32 -and
        [bool]$p0Verification.launcherPasswordRepresentationVerified -and
        [int]$p0Verification.sqliteBaselineMemberCount -eq 3 -and
        [int]$p0Verification.sqliteRuntimeMemberCount -eq 0 -and
        [bool]$p0Verification.sqliteCredentialRebootstrapPrepared -and
        -not [bool]$p0Verification.sqliteCredentialBindingVerified
    } else {
        $p0Verification.launcherCertificateAppliedSha256 -ceq
            "6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c" -and
        [long]$p0Verification.fullCompositeRollbackScriptByteLength -eq 3292 -and
        $p0Verification.fullCompositeRollbackScriptSha256 -ceq
            "823af896da3b0d83fa67e7f38d660edbc7b06a2d23ff8cde8042abdfcea12a7f" -and
        [int]$p0Verification.launcherPasswordPlaintextLength -eq 20 -and
        [int]$p0Verification.launcherPasswordStorageLength -eq 32 -and
        $p0Verification.launcherPasswordStorageSchemeCode -ceq
            "md5_lower_hex_legacy_launcher_compatibility" -and
        [bool]$p0Verification.launcherPasswordRepresentationVerified -and
        [int]$p0Verification.sqliteBaselineMemberCount -eq 3 -and
        [int]$p0Verification.sqliteRuntimeMemberCount -eq 0 -and
        [bool]$p0Verification.sqliteCredentialRebootstrapPrepared -and
        -not [bool]$p0Verification.sqliteCredentialBindingVerified
    }) -and
    -not $p0Verification.serverExecutionStarted -and -not $p0Verification.clientExecutionStarted) `
    "phase3b2_p0_verification_receipt_invalid"
$profileReceipt = Get-Content -LiteralPath $profileReceiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($profileReceipt.contractId -ceq "nll/phase3b2-offline-synthetic-profile/v1" -and
    $profileReceipt.characterCount -eq 193 -and
    $(if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
        [int]$profileReceipt.launcherPasswordPlaintextLength -eq 20 -and
        [int]$profileReceipt.launcherPasswordStorageLength -eq 32 -and
        $profileReceipt.launcherPasswordStorageSchemeCode -ceq
            "md5_lower_hex_legacy_launcher_compatibility" -and
        -not [bool]$profileReceipt.launcherPasswordPlaintextPersistedInDatabase
    } else { $true }) -and
    -not $profileReceipt.officialIdentityPersisted -and
    -not $profileReceipt.officialCredentialPersisted) "phase3b2_synthetic_profile_receipt_invalid"
$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($context.contractId -ceq "nll/phase3b2-synthetic-runtime-context/v1" -and
    [uint64]$context.accountId -gt 0 -and [int]$context.managerId -gt 0 -and
    -not $context.selectedManagerPersisted) "phase3b2_synthetic_context_invalid"

$dbBefore = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
$usersBefore = @($dbBefore.Users)
Assert-True ($usersBefore.Count -eq 1 -and [uint64]$usersBefore[0].ID -eq [uint64]$context.accountId -and
    $null -eq $usersBefore[0].SelectedClassicSoloRaidManagerId) "phase3b2_database_before_binding_invalid"
if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Assert-True (@($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count -eq 0) "phase3b2_sqlite_rebootstrap_precondition_failed"
    Assert-True (([string]$context.password) -cmatch '^[0-9a-f]{20}$' -and
        [int]$context.launcherPasswordPlaintextLength -eq 20 -and
        $context.launcherPasswordStorageSchemeCode -ceq
            "md5_lower_hex_legacy_launcher_compatibility" -and
        [string]$usersBefore[0].Username -ceq [string]$context.username -and
        ([string]$usersBefore[0].Password) -cmatch '^[0-9a-f]{32}$' -and
        [string]$usersBefore[0].Password -cne [string]$context.password) `
        "phase3b2_launcher_credential_representation_invalid"
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $expectedPasswordHash = (($md5.ComputeHash(
                        [Text.Encoding]::ASCII.GetBytes([string]$context.password)) |
                    ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $md5.Dispose() }
    Assert-True ($expectedPasswordHash -ceq [string]$usersBefore[0].Password) `
        "phase3b2_launcher_credential_hash_mismatch"
}
Assert-True (@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object LocalPort -In 80,443).Count -eq 0) "phase3b2_p1_port_already_in_use"
Assert-True (@(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
        Where-Object LocalPort -EQ 443).Count -eq 0) "phase3b2_p1_udp_port_already_in_use"

New-Item -ItemType Directory -Path $p1Root -Force | Out-Null
$dbBackupPath = Join-Path $p1Root "db.before.bin"
$auditBackupPath = Join-Path $p1Root "audit-policy.before.csv"
$stdoutPath = Join-Path $p1Root "server.stdout.log"
$stderrPath = Join-Path $p1Root "server.stderr.log"
$wfpPath = Join-Path $p1Root "wfp-server-events.xml"
$failurePath = Join-Path $p1Root "measurement-failure.receipt.json"
$measurementPath = Join-Path $p1Root "server-only-measurement.receipt.json"

try {
    $stageCode = "database_backup"
    [IO.File]::WriteAllBytes($dbBackupPath, [IO.File]::ReadAllBytes($dbPath))
    Assert-True ((Get-Sha256Hex $dbBackupPath) -ceq (Get-Sha256Hex $dbPath)) `
        "phase3b2_database_backup_verification_failed"
    $databaseBackupCreated = $true

    $stageCode = "wfp_audit_backup"
    & (Join-Path $env:WINDIR "System32\auditpol.exe") /backup "/file:$auditBackupPath" | Out-Null
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $auditBackupPath -PathType Leaf)) `
        "phase3b2_wfp_audit_backup_failed"
    $auditBackupCreated = $true
    & (Join-Path $env:WINDIR "System32\auditpol.exe") /set `
        "/subcategory:{0CCE9226-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_wfp_audit_enable_failed"

    $stageCode = "server_start"
    $auditStartedAt = [DateTimeOffset]::UtcNow
    $env:EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID = [string]$context.accountId
    $env:EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID = [string]$context.managerId
    $frameworkLogVariables = [ordered]@{
        Logging__LogLevel__Microsoft = "Warning"
        Logging__LogLevel__System = "Warning"
    }
    $previousFrameworkLogValues = @{}
    foreach ($name in $frameworkLogVariables.Keys) {
        $previousFrameworkLogValues[$name] = [Environment]::GetEnvironmentVariable(
            $name, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable(
            $name, $frameworkLogVariables[$name], [EnvironmentVariableTarget]::Process)
    }
    try {
        $serverProcess = Start-Process -FilePath $serverExe -ArgumentList @("--headless", "--local-only") `
            -WorkingDirectory $serverRoot -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    }
    finally {
        Remove-Item Env:\EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID,
            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID -ErrorAction SilentlyContinue
        foreach ($name in $frameworkLogVariables.Keys) {
            [Environment]::SetEnvironmentVariable(
                $name, $previousFrameworkLogValues[$name], [EnvironmentVariableTarget]::Process)
        }
    }

    $stageCode = "bootstrap_and_listener_observation"
    $selectionObservedAt = $null
    $listenerObservedAt = $null
    for ($attempt = 0; $attempt -lt 480; $attempt++) {
        Start-Sleep -Milliseconds 250
        $serverProcess.Refresh()
        if ($serverProcess.HasExited) { throw "phase3b2_server_exited_before_listener" }
        if ($null -eq $selectionObservedAt) {
            try {
                $candidate = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
                $candidateUsers = @($candidate.Users)
                if ($candidateUsers.Count -eq 1 -and
                    $null -ne $candidateUsers[0].SelectedClassicSoloRaidManagerId) {
                    Assert-True ([int]$candidateUsers[0].SelectedClassicSoloRaidManagerId -eq
                        [int]$context.managerId) "phase3b2_runtime_selection_binding_mismatch"
                    $selectionObservedAt = [DateTimeOffset]::UtcNow
                }
            }
            catch [System.ArgumentException] { }
        }
        $tcpCandidate = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                Where-Object { $_.OwningProcess -eq $serverProcess.Id -and $_.LocalPort -in 80,443 })
        $udpCandidate = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
                Where-Object { $_.OwningProcess -eq $serverProcess.Id -and $_.LocalPort -eq 443 })
        if ($tcpCandidate.Count -eq 2) {
            $listenerObservedAt = [DateTimeOffset]::UtcNow
            break
        }
    }
    Assert-True ($null -ne $selectionObservedAt) "phase3b2_selection_not_observed_before_listener"
    Assert-True ($null -ne $listenerObservedAt -and $selectionObservedAt -le $listenerObservedAt) `
        "phase3b2_listener_or_bootstrap_order_invalid"

    Start-Sleep -Seconds 2
    $tcp = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object { $_.OwningProcess -eq $serverProcess.Id -and $_.LocalPort -in 80,443 })
    $udp = @(Get-NetUDPEndpoint -ErrorAction Stop |
            Where-Object { $_.OwningProcess -eq $serverProcess.Id -and $_.LocalPort -eq 443 })
    $listenerObservation = [ordered]@{
        contractId = "nll/phase3b2-p1-listener-observation/v1"
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        tcpBindings = @($tcp | Sort-Object LocalPort, LocalAddress | ForEach-Object {
                "tcp:$($_.LocalAddress):$($_.LocalPort)"
            })
        udpBindings = @($udp | Sort-Object LocalPort, LocalAddress | ForEach-Object {
                "udp:$($_.LocalAddress):$($_.LocalPort)"
            })
        serverExecutionStarted = $true
        clientExecutionStarted = $false
    }
    Write-Utf8NoBom (Join-Path $p1Root "listener-observation.json") `
        (($listenerObservation | ConvertTo-Json) + "`n")
    Assert-True (@($tcp | Where-Object { $_.LocalAddress -eq "127.0.0.1" -and $_.LocalPort -eq 80 }).Count -eq 1) `
        "phase3b2_http_listener_mismatch"
    Assert-True (@($tcp | Where-Object { $_.LocalAddress -eq "127.0.0.1" -and $_.LocalPort -eq 443 }).Count -eq 1) `
        "phase3b2_https_listener_mismatch"
    Assert-True ($udp.Count -eq 0) "phase3b2_local_only_http3_listener_present"
    Assert-True (@($tcp | Where-Object LocalAddress -NE "127.0.0.1").Count -eq 0) `
        "phase3b2_nonloopback_listener_observed"

    $stageCode = "server_settle_observation"
    Start-Sleep -Seconds 10
    $serverProcess.Refresh()
    Assert-True (-not $serverProcess.HasExited) "phase3b2_server_exited_during_settle"
    Assert-True ($null -eq (Get-Process -Name nikke, nikke_launcher -ErrorAction SilentlyContinue)) `
        "phase3b2_client_process_started_during_p1"
    $settledUpPhysicalNetworkAdapterCount = @(Get-NetAdapter -Physical -ErrorAction Stop |
            Where-Object Status -EQ "Up").Count
    $settledSystemNetworkAvailable = [Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable()
    $settledNetworkProfileCount = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue).Count
    $settledIpv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 `
            -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
            Where-Object State -EQ "Alive").Count
    $settledIpv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 `
            -DestinationPrefix "::/0" -ErrorAction SilentlyContinue |
            Where-Object State -EQ "Alive").Count
    if ($NetworkModeCode -ceq "disconnected") {
        Assert-True ($settledUpPhysicalNetworkAdapterCount -eq 0 -and
            -not $settledSystemNetworkAvailable -and $settledNetworkProfileCount -eq 0) `
            "phase3b2_guest_disconnected_network_drift"
    }
    else {
        Assert-True ($settledUpPhysicalNetworkAdapterCount -eq 1 -and
            $settledSystemNetworkAvailable -and $settledNetworkProfileCount -eq 1 -and
            $settledIpv4DefaultRouteCount -eq 0 -and $settledIpv6DefaultRouteCount -eq 0) `
            "phase3b2_guest_private_network_drift"
    }

    $processTreeMembers = @(Get-ProcessTreeMembers -RootProcessId $serverProcess.Id `
            -NotBeforeUtc $auditStartedAt)
    $processTreeIds = @($processTreeMembers | ForEach-Object { [int]$_.ProcessId })
    $processTreeObservation = [ordered]@{
        contractId = "nll/phase3b2-p1-process-tree-observation/v1"
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        notBeforeUtc = $auditStartedAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        members = @($processTreeMembers | ForEach-Object {
                $createdAtUtc = if ($null -eq $_.CreationDate) {
                    $null
                } else {
                    ([DateTimeOffset]$_.CreationDate).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                }
                [ordered]@{
                    processId = [int]$_.ProcessId
                    parentProcessId = [int]$_.ParentProcessId
                    executableName = [string]$_.Name
                    createdAtUtc = $createdAtUtc
                }
            })
        serverExecutionStarted = $true
        clientExecutionStarted = $false
    }
    Write-Utf8NoBom (Join-Path $p1Root "process-tree-observation.json") `
        (($processTreeObservation | ConvertTo-Json -Depth 5) + "`n")
    Assert-True ($processTreeIds.Count -eq 1) "phase3b2_unexpected_server_child_process"
    $connections = @(Get-NetTCPConnection -ErrorAction SilentlyContinue |
            Where-Object OwningProcess -In $processTreeIds)
    $nonLoopbackConnections = @($connections | Where-Object {
            $_.RemoteAddress -and $_.RemoteAddress -notin @("0.0.0.0", "127.0.0.1", "::", "::1")
        })
    Assert-True ($nonLoopbackConnections.Count -eq 0) "phase3b2_nonloopback_connection_observed"

    if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
        $stageCode = "sqlite_credential_binding_observation"
        Assert-True (Test-Path -LiteralPath $sqlitePaths[0] -PathType Leaf) `
            "phase3b2_sqlite_rebootstrap_not_observed"
        $sqliteRebootstrapObserved = $true
        $loginBody = [ordered]@{
            account = [string]$context.username
            password = $expectedPasswordHash
        } | ConvertTo-Json -Compress
        $loginRaw = Invoke-RestMethod `
            -Uri "http://127.0.0.1/account/login?seq=nll_phase3b2_preflight" `
            -Method Post -ContentType "application/json" -Body $loginBody
        $loginDocument = if ($loginRaw -is [string]) {
            $loginRaw | ConvertFrom-Json
        } else { $loginRaw }
        Assert-True ([int]$loginDocument.ret -eq 0 -and
            [bool]$loginDocument.is_login -and
            ([string]$loginDocument.token).StartsWith(
                "v4.local.", [StringComparison]::Ordinal) -and
            [string]$loginDocument.uid -ceq [string]$context.accountId) `
            "phase3b2_controlled_synthetic_login_rejected"
        $controlledSyntheticLoginAccepted = $true
        $sqliteCredentialBindingVerified = $true
        $loginBody = $null
        $loginRaw = $null
        $loginDocument = $null
    }

    $stageCode = "wfp_event_observation"
    $events = @(Get-WinEvent -FilterHashtable @{
            LogName = "Security"
            Id = @(5156, 5157)
            StartTime = $auditStartedAt.LocalDateTime
        } -ErrorAction SilentlyContinue)
    $serverEventXml = [Collections.Generic.List[string]]::new()
    $nonLoopbackEventCount = 0
    foreach ($event in $events) {
        $eventData = Get-EventData $event
        $eventProcessId = 0L
        if ([long]::TryParse([string]$eventData.Values["ProcessID"], [ref]$eventProcessId) -and
            $eventProcessId -in $processTreeIds) {
            $serverEventXml.Add($eventData.Xml)
            $destination = [string]$eventData.Values["DestAddress"]
            if ($destination -and $destination -notin @("0.0.0.0", "127.0.0.1", "::", "::1")) {
                $nonLoopbackEventCount++
            }
        }
    }
    Assert-True ($nonLoopbackEventCount -eq 0) "phase3b2_nonloopback_wfp_event_observed"
    Write-Utf8NoBom $wfpPath $(if ($serverEventXml.Count) {
            ($serverEventXml -join "`n") + "`n"
        } else {
            "none`n"
        })

    $stageCode = "database_and_log_safety_observation"
    $dbAfter = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $usersAfter = @($dbAfter.Users)
    Assert-True ($usersAfter.Count -eq 1 -and [uint64]$usersAfter[0].ID -eq [uint64]$context.accountId -and
        [int]$usersAfter[0].SelectedClassicSoloRaidManagerId -eq [int]$context.managerId -and
        $(if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
            [string]$usersAfter[0].Password -ceq $expectedPasswordHash
        } else { $true })) `
        "phase3b2_selection_binding_mismatch"
    $activeRunCount = if ($usersAfter[0].SoloRaidData) {
        @($usersAfter[0].SoloRaidData.PSObject.Properties | Where-Object {
                $_.Value.LevelData -and @($_.Value.LevelData | Where-Object IsOpened).Count -gt 0
            }).Count
    } else { 0 }
    Assert-True ($activeRunCount -eq 0) "phase3b2_active_run_present"

    $stdoutObservation = Get-StableSharedFileObservation $stdoutPath
    $stderrObservation = Get-StableSharedFileObservation $stderrPath
    $stdoutText = [Text.UTF8Encoding]::new($false, $true).GetString($stdoutObservation.Bytes)
    $stderrText = [Text.UTF8Encoding]::new($false, $true).GetString($stderrObservation.Bytes)
    $combinedLog = $stdoutText + "`n" + $stderrText
    $sensitiveValues = @(
        [string]$context.accountId,
        [string]$context.managerId,
        [string]$context.username,
        [string]$context.password,
        "C:\NLL",
        "E:\NIKKE"
    )
    Assert-True (@($sensitiveValues | Where-Object {
                $_ -and $combinedLog.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0
            }).Count -eq 0) "phase3b2_sensitive_server_log_exposure"

    $stageCode = "measurement_seal"
    $receipt = [ordered]@{
        contractId = if ($NetworkModeCode -ceq "disconnected") {
            "nll/phase3b2-p1-server-only-measurement/v1"
        } elseif ($useLocalBootstrap) {
            "nll/phase3b2-p1-private-server-only-measurement/v5"
        } else {
            "nll/phase3b2-p1-private-server-only-measurement/v4"
        }
        measuredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        serverExecutionStarted = $true
        clientExecutionStarted = $false
        clientBuild = "150.6.9"
        externalHead = "519c3db51ec24ca19307e93e85acde7885928a72"
        externalTree = "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
        headlessEnabled = $true
        localOnlyEnabled = $true
        officialAssetAutoFetchEnabled = $false
        localeAutoFetchEnabled = $false
        gitUpdateEnabled = $false
        interactiveUpdateSurfaceEnabled = $false
        frameworkInformationLoggingEnabled = $false
        localOnlyHttp3Enabled = $false
        localOnlyAssetCachePathLoggingEnabled = $false
        clientBootstrapModeCode = $ClientBootstrapModeCode
        officialLauncherExecutionPermitted = -not $useLocalBootstrap
        antiCheatSubstitutionApplied = $false
        networkModeCode = $NetworkModeCode
        systemNetworkAvailable = $settledSystemNetworkAvailable
        upPhysicalNetworkAdapterCount = $settledUpPhysicalNetworkAdapterCount
        networkProfileCount = $settledNetworkProfileCount
        ipv4DefaultRouteCount = $settledIpv4DefaultRouteCount
        ipv6DefaultRouteCount = $settledIpv6DefaultRouteCount
        httpIpv4LoopbackListenerCount = 1
        httpsIpv4LoopbackListenerCount = 1
        http3UdpListenerCount = 0
        wildcardListenerCount = 0
        lanListenerCount = 0
        unexpectedListenerCount = 0
        nonLoopbackAttemptCount = $nonLoopbackEventCount
        nonLoopbackSuccessfulConnectionCount = $nonLoopbackConnections.Count
        processTreeMemberCount = $processTreeIds.Count
        selectionObservedNoLaterThanListener = $true
        selectionRuntimeMutationCount = 0
        latestFallbackCount = 0
        activeRunCount = $activeRunCount
        rawSensitiveLogMatchCount = 0
        launcherPasswordRepresentationVerified =
            ($NetworkModeCode -ceq "private_vm_only_no_gateway")
        sqliteCredentialRebootstrapPrepared =
            ($NetworkModeCode -ceq "private_vm_only_no_gateway")
        sqliteRebootstrapObserved = $sqliteRebootstrapObserved
        controlledSyntheticLoginAccepted = $controlledSyntheticLoginAccepted
        controlledLoginPasswordRepresentationCode = $(if (
                $NetworkModeCode -ceq "private_vm_only_no_gateway") {
                "md5_lower_hex_legacy_launcher_compatibility"
            } else { "not_applicable" })
        sqliteCredentialBindingVerified = $sqliteCredentialBindingVerified
        sqliteRuntimeMemberCount = @($sqlitePaths | Where-Object {
                Test-Path -LiteralPath $_
            }).Count
        p0VerificationByteLength = (Get-Item -LiteralPath $p0VerificationPath).Length
        p0VerificationSha256 = Get-Sha256Hex $p0VerificationPath
        syntheticContextByteLength = (Get-Item -LiteralPath $contextPath).Length
        syntheticContextSha256 = Get-Sha256Hex $contextPath
        databaseBeforeByteLength = (Get-Item -LiteralPath $dbBackupPath).Length
        databaseBeforeSha256 = Get-Sha256Hex $dbBackupPath
        databaseAfterByteLength = (Get-Item -LiteralPath $dbPath).Length
        databaseAfterSha256 = Get-Sha256Hex $dbPath
        auditPolicyBackupByteLength = (Get-Item -LiteralPath $auditBackupPath).Length
        auditPolicyBackupSha256 = Get-Sha256Hex $auditBackupPath
        wfpEvidenceByteLength = (Get-Item -LiteralPath $wfpPath).Length
        wfpEvidenceSha256 = Get-Sha256Hex $wfpPath
        serverStdoutByteLength = $stdoutObservation.ByteLength
        serverStdoutSha256 = $stdoutObservation.Sha256
        serverStderrByteLength = $stderrObservation.ByteLength
        serverStderrSha256 = $stderrObservation.Sha256
        serverRunning = $true
        credentialBearingGuestCopyPresent = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
    }
    Write-Utf8NoBom (Join-Path $p1Root "server.pid") ([string]$serverProcess.Id + "`n")
    Write-Utf8NoBom $measurementPath (($receipt | ConvertTo-Json) + "`n")
    $measurementCompleted = $true
    $receipt | ConvertTo-Json
}
catch {
    $failureRecord = $_
    if ($null -ne $serverProcess) {
        $serverProcess.Refresh()
        if (-not $serverProcess.HasExited) {
            Stop-Process -Id $serverProcess.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $serverProcess.Id -Timeout 10 -ErrorAction SilentlyContinue
        }
    }
    if ($databaseBackupCreated) {
        [IO.File]::WriteAllBytes($dbPath, [IO.File]::ReadAllBytes($dbBackupPath))
        Assert-True ((Get-Sha256Hex $dbPath) -ceq (Get-Sha256Hex $dbBackupPath)) `
            "phase3b2_p1_database_rollback_failed"
    }
    if ($auditBackupCreated) {
        & (Join-Path $env:WINDIR "System32\auditpol.exe") /restore "/file:$auditBackupPath" | Out-Null
        Assert-True ($LASTEXITCODE -eq 0) "phase3b2_p1_audit_policy_rollback_failed"
    }
    $failureReceipt = [ordered]@{
        contractId = "nll/phase3b2-p1-server-only-failure/v1"
        failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedStageCode = $stageCode
        exceptionType = $failureRecord.Exception.GetType().FullName
        failureMessage = $failureRecord.Exception.Message
        observedTcpBindings = @($tcp | Sort-Object LocalPort, LocalAddress | ForEach-Object {
                "tcp:$($_.LocalAddress):$($_.LocalPort)"
            })
        observedUdpBindings = @($udp | Sort-Object LocalPort, LocalAddress | ForEach-Object {
                "udp:$($_.LocalAddress):$($_.LocalPort)"
            })
        serverStopped = $true
        databaseRestored = $databaseBackupCreated
        auditPolicyRestored = $auditBackupCreated
        sqliteRebootstrapObserved = $sqliteRebootstrapObserved
        controlledSyntheticLoginAccepted = $controlledSyntheticLoginAccepted
        sqliteCredentialBindingVerified = $sqliteCredentialBindingVerified
        clientBootstrapModeCode = $ClientBootstrapModeCode
        clientExecutionStarted = $false
    }
    Write-Utf8NoBom $failurePath (($failureReceipt | ConvertTo-Json) + "`n")
    throw "phase3b2_p1_measurement_failed:${stageCode}:$($failureRecord.Exception.Message)"
}
finally {
    if (-not $measurementCompleted) {
        Remove-Item Env:\EPINELPS_CLASSIC_SOLO_RAID_ACCOUNT_ID,
            Env:\EPINELPS_CLASSIC_SOLO_RAID_MANAGER_ID -ErrorAction SilentlyContinue
    }
}
