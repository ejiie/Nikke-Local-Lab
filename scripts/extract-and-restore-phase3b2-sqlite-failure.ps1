[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCredential]$GuestCredential,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot =
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence",
    [string]$OutputRoot =
        "$env:LOCALAPPDATA\NikkeLocalLab\compatibility\evidence\phase3b2-wave1-hyperv\8c2281d7-c3da-4e74-bb54-09758695fc99"
)

$ErrorActionPreference = "Stop"
$session = $null
$postRestoreSession = $null

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256 {
    param([string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($bytes) |
                ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $algorithm.Dispose() }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"

$assessmentUid = "8c2281d7-c3da-4e74-bb54-09758695fc99"
$guestFailurePath =
    "C:\Users\nlloperator\AppData\Local\NikkeLocalLab\Evidence\Phase3B2\Trusted\reference-private-v3\$assessmentUid\sqlite-credential-binding-failure.receipt.json"
$localFailurePath = Join-Path $OutputRoot `
    "sqlite-credential-binding-failure.v4.powershell-direct.json"
$temporaryFailurePath = $localFailurePath + ".tmp"
$checkpointReceiptPath = Join-Path $EvidenceRoot `
    "p0-private-launcher-credential-checkpoint-v1.json"
$extractionReceiptPath = Join-Path $EvidenceRoot `
    "sqlite-failure-receipt-extraction-v1.receipt.json"
$restoreReceiptPath = Join-Path $EvidenceRoot `
    "private-sqlite-failure-restore-v1.receipt.json"
$readyReceiptPath = Join-Path $OutputRoot `
    "season26-classic-live-preflight.ready.json"

foreach ($path in @($checkpointReceiptPath, $readyReceiptPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        "phase3b2_sqlite_restore_prerequisite_missing"
}
Assert-True ((Get-Item -LiteralPath $checkpointReceiptPath).Length -eq 2305 -and
    (Get-Sha256Hex $checkpointReceiptPath) -ceq
        "6381878760cc14bfd42f40232d3aa9d0cdb21fe133041ac910d63a20034b8cb4") `
    "phase3b2_sqlite_restore_checkpoint_receipt_drift"
Assert-True ((Get-Item -LiteralPath $readyReceiptPath).Length -eq 4889 -and
    (Get-Sha256Hex $readyReceiptPath) -ceq
        "49f65656cb4c07608920c54f3554480e68225c2342c97be57c6e1ad1550d5a62") `
    "phase3b2_sqlite_restore_ready_receipt_drift"
Assert-True (-not (Test-Path -LiteralPath $localFailurePath) -and
    -not (Test-Path -LiteralPath $temporaryFailurePath) -and
    -not (Test-Path -LiteralPath $extractionReceiptPath) -and
    -not (Test-Path -LiteralPath $restoreReceiptPath)) `
    "phase3b2_sqlite_restore_output_exists"

$checkpoint = Get-Content -LiteralPath $checkpointReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($checkpoint.contractId -ceq
        "nll/phase3b2-p0-private-launcher-credential-checkpoint/v1" -and
    $checkpoint.checkpointIdentitySha256 -ceq
        "80f2b7b9562220ac88a76a8f6135069eeb095017a4491713475ffa1c264287a2" -and
    [int]$checkpoint.currentCheckpointCount -eq 8 -and
    [bool]$checkpoint.launcherPasswordRepresentationVerified -and
    [int]$checkpoint.sqliteBaselineMemberCount -eq 3 -and
    [int]$checkpoint.sqliteStateMutationCount -eq 0 -and
    -not [bool]$checkpoint.guestServiceEnabled -and
    -not [bool]$checkpoint.serverExecutionStarted -and
    -not [bool]$checkpoint.clientExecutionStarted) `
    "phase3b2_sqlite_restore_checkpoint_receipt_invalid"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$managementAdapters = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ([string]$vm.Id -ceq
        "77d6f113-2f74-49e4-8fbf-0dc381232810" -and
    $vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $privateSwitch.SwitchType -eq
        [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0 -and
    $guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_sqlite_restore_environment_invalid"

$snapshots = @(Get-VMSnapshot -VM $vm -ErrorAction Stop |
        Where-Object { $_.Name -like
            "NLL-P3B2-W1-P0-Private-LauncherCredential-v1-*" })
Assert-True ($snapshots.Count -eq 1) `
    "phase3b2_sqlite_restore_checkpoint_shape_invalid"
$snapshot = $snapshots[0]
$identityText = @(
    "contractId=nll/phase3b2-hyperv-private-launcher-credential-checkpoint-identity/v1"
    "vmId=$($vm.Id)"
    "checkpointId=$($snapshot.Id)"
    "checkpointName=$($snapshot.Name)"
    "creationTimeUtc=$($snapshot.CreationTime.ToUniversalTime().ToString('o'))"
    "networkModeCode=private_vm_only_no_gateway"
    "switchName=$SwitchName"
    "switchType=Private"
    "parentCheckpointIdentitySha256=426f8e1c4a5b6636b6e59cef42e021fe7c30881581ca06fb92603c12569c41e5"
    "guestP0V3ReceiptByteLength=$($checkpoint.guestP0V3ReceiptByteLength)"
    "guestP0V3ReceiptSha256=$($checkpoint.guestP0V3ReceiptSha256)"
    "guestProfileAdapterBuildReceiptByteLength=$($checkpoint.guestProfileAdapterBuildReceiptByteLength)"
    "guestProfileAdapterBuildReceiptSha256=$($checkpoint.guestProfileAdapterBuildReceiptSha256)"
    "launcherPasswordStorageSchemeCode=md5_lower_hex_legacy_launcher_compatibility"
    "sqliteBaselineMemberCount=3"
    "sqliteStateMutationCount=0"
    "fullCompositeRollbackScriptByteLength=4222"
    "fullCompositeRollbackScriptSha256=b7789d3114da7a2d4d9e4d0f1330bdb040c264e3b8a47598581b395f98ed0371"
    "restoreReceiptSha256=$($checkpoint.restoreReceiptSha256)"
    "toolTransferReceiptSha256=$($checkpoint.toolTransferReceiptSha256)"
    "externalHead=519c3db51ec24ca19307e93e85acde7885928a72"
    "externalTree=b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    "externalBuildManifestSha256=ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
) -join "`n"
Assert-True ((Get-TextSha256 ($identityText + "`n")) -ceq
        [string]$checkpoint.checkpointIdentitySha256) `
    "phase3b2_sqlite_restore_checkpoint_identity_mismatch"

New-Item -ItemType Directory -Path $OutputRoot, $EvidenceRoot -Force | Out-Null
try {
    $session = New-PSSession -VMName $VMName -Credential $GuestCredential
    $remote = Invoke-Command -Session $session -ScriptBlock {
        param([string]$Path)
        $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json
        [pscustomobject]@{
            contractId = [string]$document.contractId
            assessmentUid = [string]$document.assessmentUid
            reasonCode = [string]$document.reasonCode
            causeEvidenceStatusCode = [string]$document.causeEvidenceStatusCode
            byteLength = (Get-Item -LiteralPath $Path).Length
            sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
            retryPerformed = [bool]$document.retryPerformed
            clientExecutionStarted = [bool]$document.clientExecutionStarted
            officialIdentityPersisted = [bool]$document.officialIdentityPersisted
            officialCredentialPersisted = [bool]$document.officialCredentialPersisted
            processCount = @(Get-Process -Name EpinelPS, nikke_launcher, nikke `
                    -ErrorAction SilentlyContinue).Count
        }
    } -ArgumentList $guestFailurePath
    Assert-True ($remote.contractId -ceq
            "nll/phase3b2-private-reference-run-failure/v4" -and
        $remote.assessmentUid -ceq $assessmentUid -and
        $remote.reasonCode -ceq "sqlite_sdk_user_credential_not_rebound" -and
        $remote.causeEvidenceStatusCode -ceq
            "confirmed_by_source_and_sqlite_byte_presence" -and
        [long]$remote.byteLength -eq 3037 -and
        [string]$remote.sha256 -ceq
            "1d952f182719238878d9ca6ba38d92eba0699a2c02877d5d33ace8d890c4e8be" -and
        -not [bool]$remote.retryPerformed -and
        -not [bool]$remote.clientExecutionStarted -and
        -not [bool]$remote.officialIdentityPersisted -and
        -not [bool]$remote.officialCredentialPersisted -and
        [int]$remote.processCount -eq 0) `
        "phase3b2_sqlite_restore_remote_failure_invalid"

    Copy-Item -FromSession $session -LiteralPath $guestFailurePath `
        -Destination $temporaryFailurePath
    Assert-True ((Get-Item -LiteralPath $temporaryFailurePath).Length -eq 3037 -and
        (Get-Sha256Hex $temporaryFailurePath) -ceq
            "1d952f182719238878d9ca6ba38d92eba0699a2c02877d5d33ace8d890c4e8be") `
        "phase3b2_sqlite_restore_failure_copy_drift"
    Move-Item -LiteralPath $temporaryFailurePath -Destination $localFailurePath
}
finally {
    if ($null -ne $session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

$extractionReceipt = [ordered]@{
    contractId = "nll/phase3b2-sqlite-failure-receipt-extraction/v1"
    extractedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    transportCode = "hyperv_powershell_direct"
    sourceContractId = "nll/phase3b2-private-reference-run-failure/v4"
    assessmentUid = $assessmentUid
    extractedByteLength = 3037
    extractedSha256 =
        "1d952f182719238878d9ca6ba38d92eba0699a2c02877d5d33ace8d890c4e8be"
    networkTransportUsed = $false
    guestOsCredentialPersisted = $false
    guestOsCredentialEmitted = $false
    guestServiceEnabled = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($extractionReceiptPath,
    (($extractionReceipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))

Restore-VMSnapshot -VMSnapshot $snapshot -Confirm:$false
for ($attempt = 0; $attempt -lt 90; $attempt++) {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) { break }
    if ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Off -or
        $vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Saved) {
        Start-VM -VM $vm -ErrorAction SilentlyContinue | Out-Null
    }
    Start-Sleep -Seconds 1
}
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) `
    "phase3b2_sqlite_restore_vm_not_running"

for ($attempt = 0; $attempt -lt 90; $attempt++) {
    try {
        $postRestoreSession = New-PSSession -VMName $VMName `
            -Credential $GuestCredential -ErrorAction Stop
        break
    }
    catch { Start-Sleep -Seconds 1 }
}
Assert-True ($null -ne $postRestoreSession) `
    "phase3b2_sqlite_restore_powershell_direct_unavailable"
try {
    $postRestore = Invoke-Command -Session $postRestoreSession -ScriptBlock {
        $trustedRoot = Join-Path $env:LOCALAPPDATA `
            "NikkeLocalLab\Evidence\Phase3B2\Trusted"
        $context = Get-Content -LiteralPath (Join-Path $trustedRoot `
                "identity\synthetic-context.json") -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $db = Get-Content -LiteralPath `
            "C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json" `
            -Raw -Encoding UTF8 | ConvertFrom-Json
        $password = [string]$context.password
        $md5 = [Security.Cryptography.MD5]::Create()
        try {
            $expectedHash = (($md5.ComputeHash(
                            [Text.Encoding]::ASCII.GetBytes($password)) |
                        ForEach-Object { $_.ToString("x2") }) -join "")
        }
        finally { $md5.Dispose() }
        [pscustomobject]@{
            processCount = @(Get-Process -Name EpinelPS, nikke_launcher, nikke `
                    -ErrorAction SilentlyContinue).Count
            contextPasswordShapeValid = $password -cmatch '^[0-9a-f]{20}$'
            dbJsonPasswordMatchesMd5 =
                [string]$db.Users[0].Password -ceq $expectedHash
            ipv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 `
                    -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                    Where-Object State -EQ "Alive").Count
            ipv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 `
                    -DestinationPrefix "::/0" -ErrorAction SilentlyContinue |
                    Where-Object State -EQ "Alive").Count
        }
    }
}
finally {
    Remove-PSSession -Session $postRestoreSession -ErrorAction SilentlyContinue
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
$guestServiceAfter = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
$snapshotAfter = @(Get-VMSnapshot -VM $vm -ErrorAction Stop |
        Where-Object { [string]$_.Id -ceq [string]$snapshot.Id })
Assert-True ([int]$postRestore.processCount -eq 0 -and
    [bool]$postRestore.contextPasswordShapeValid -and
    [bool]$postRestore.dbJsonPasswordMatchesMd5 -and
    [int]$postRestore.ipv4DefaultRouteCount -eq 0 -and
    [int]$postRestore.ipv6DefaultRouteCount -eq 0 -and
    $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled -and
    $snapshotAfter.Count -eq 1) `
    "phase3b2_sqlite_restore_postcondition_failed"

$restoreReceipt = [ordered]@{
    contractId = "nll/phase3b2-private-sqlite-failure-restore/v1"
    restoredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    failedAssessmentUid = $assessmentUid
    failureReceiptByteLength = 3037
    failureReceiptSha256 =
        "1d952f182719238878d9ca6ba38d92eba0699a2c02877d5d33ace8d890c4e8be"
    restoredCheckpointReceiptByteLength = 2305
    restoredCheckpointReceiptSha256 =
        "6381878760cc14bfd42f40232d3aa9d0cdb21fe133041ac910d63a20034b8cb4"
    restoredCheckpointIdentitySha256 =
        "80f2b7b9562220ac88a76a8f6135069eeb095017a4491713475ffa1c264287a2"
    rollbackStatusCode =
        "private_launcher_credential_p0_checkpoint_restored_verified"
    checkpointPreserved = $true
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    hostVirtualAdapterPresent = $false
    externalUplinkPresent = $false
    natConfigured = $false
    vmRunning = $true
    guestServiceEnabled = $false
    dbJsonPasswordMatchesMd5 = $true
    sqliteCredentialBindingRepaired = $false
    serverExecutionStarted = $false
    launcherExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = "repair_sqlite_sdk_user_credential_and_reseal"
}
[IO.File]::WriteAllText($restoreReceiptPath,
    (($restoreReceipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))

$extractionReceipt | ConvertTo-Json
$restoreReceipt | ConvertTo-Json
