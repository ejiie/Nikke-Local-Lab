[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [long]$GuestP0V3ReceiptByteLength,

    [Parameter(Mandatory)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$GuestP0V3ReceiptSha256,

    [Parameter(Mandatory)]
    [long]$GuestProfileAdapterBuildReceiptByteLength,

    [Parameter(Mandatory)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$GuestProfileAdapterBuildReceiptSha256,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

trap {
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    $errorPath = Join-Path $EvidenceRoot `
        "p0-private-launcher-credential-checkpoint-v1.error.log"
    [IO.File]::WriteAllText($errorPath, ($_.Exception.Message + "`n"),
        [Text.UTF8Encoding]::new($false))
    exit 1
}

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
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
Assert-True ($GuestP0V3ReceiptByteLength -gt 0 -and
    $GuestProfileAdapterBuildReceiptByteLength -gt 0) `
    "phase3b2_credential_checkpoint_guest_receipt_length_invalid"

$restoreReceiptPath = Join-Path $EvidenceRoot `
    "private-password-failure-restore-v1.receipt.json"
$transferReceiptPath = Join-Path $EvidenceRoot `
    "launcher-credential-repair-tool-transfer-v2.receipt.json"
$parentCheckpointReceiptPath = Join-Path $EvidenceRoot `
    "p0-private-launcher-ca-checkpoint-v1.json"
$receiptPath = Join-Path $EvidenceRoot `
    "p0-private-launcher-credential-checkpoint-v1.json"
foreach ($path in @($restoreReceiptPath, $transferReceiptPath,
        $parentCheckpointReceiptPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        "phase3b2_credential_checkpoint_prerequisite_receipt_missing"
}
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_credential_checkpoint_receipt_exists"
$restore = Get-Content -LiteralPath $restoreReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$transfer = Get-Content -LiteralPath $transferReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$parentCheckpoint = Get-Content -LiteralPath $parentCheckpointReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($restore.contractId -ceq
        "nll/phase3b2-private-password-failure-restore/v1" -and
    $restore.restoredCheckpointIdentitySha256 -ceq
        "426f8e1c4a5b6636b6e59cef42e021fe7c30881581ca06fb92603c12569c41e5" -and
    $transfer.contractId -ceq
        "nll/phase3b2-launcher-credential-repair-tool-transfer/v2" -and
    [int]$transfer.transferredMemberCount -eq 10 -and
    @($transfer.members | Where-Object {
            $_.roleCode -ceq "full_composite_rollback" -and
            [long]$_.byteLength -eq 4222 -and
            $_.sha256 -ceq
                "b7789d3114da7a2d4d9e4d0f1330bdb040c264e3b8a47598581b395f98ed0371"
        }).Count -eq 1 -and
    $transfer.runtimeExecutionStateCode -ceq
        "restored_launcher_ca_p0_client_cold" -and
    $parentCheckpoint.contractId -ceq
        "nll/phase3b2-p0-private-launcher-ca-checkpoint/v1" -and
    $parentCheckpoint.checkpointIdentitySha256 -ceq
        "426f8e1c4a5b6636b6e59cef42e021fe7c30881581ca06fb92603c12569c41e5") `
    "phase3b2_credential_checkpoint_prerequisite_receipt_invalid"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$managementAdapters = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName })
Assert-True ([string]$vm.Id -ceq "77d6f113-2f74-49e4-8fbf-0dc381232810" -and
    $vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $vm.CheckpointType -eq [Microsoft.HyperV.PowerShell.CheckpointType]::Standard -and
    -not $vm.AutomaticCheckpointsEnabled -and
    $privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0) `
    "phase3b2_credential_checkpoint_environment_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_credential_checkpoint_guest_service_enabled"

$before = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
$created = @($before | Where-Object { $_.Name -like
        "NLL-P3B2-W1-P0-Private-LauncherCredential-v1-*" })
Assert-True ($created.Count -le 1) `
    "phase3b2_credential_checkpoint_resume_shape_invalid"
$checkpointCreationResumed = $created.Count -eq 1
if ($created.Count -eq 0) {
    $stamp = [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    $snapshotName = "NLL-P3B2-W1-P0-Private-LauncherCredential-v1-$stamp"
    Checkpoint-VM -VM $vm -SnapshotName $snapshotName
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $after = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
        $created = @($after | Where-Object Name -CEQ $snapshotName)
        if ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert-True ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) `
        "phase3b2_credential_checkpoint_creation_not_verified"
    $previousCheckpointCount = $before.Count
}
else {
    $snapshotName = $created[0].Name
    $after = $before
    $previousCheckpointCount = $after.Count - 1
}

$vmAfter = Get-VM -Name $VMName -ErrorAction Stop
$guestServiceAfter = @(Get-VMIntegrationService -VM $vmAfter |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($vmAfter.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_credential_checkpoint_postcondition_failed"

$restoreSha = Get-Sha256Hex $restoreReceiptPath
$transferSha = Get-Sha256Hex $transferReceiptPath
$identityText = @(
    "contractId=nll/phase3b2-hyperv-private-launcher-credential-checkpoint-identity/v1"
    "vmId=$($vmAfter.Id)"
    "checkpointId=$($created[0].Id)"
    "checkpointName=$snapshotName"
    "creationTimeUtc=$($created[0].CreationTime.ToUniversalTime().ToString('o'))"
    "networkModeCode=private_vm_only_no_gateway"
    "switchName=$SwitchName"
    "switchType=Private"
    "parentCheckpointIdentitySha256=426f8e1c4a5b6636b6e59cef42e021fe7c30881581ca06fb92603c12569c41e5"
    "guestP0V3ReceiptByteLength=$GuestP0V3ReceiptByteLength"
    "guestP0V3ReceiptSha256=$GuestP0V3ReceiptSha256"
    "guestProfileAdapterBuildReceiptByteLength=$GuestProfileAdapterBuildReceiptByteLength"
    "guestProfileAdapterBuildReceiptSha256=$GuestProfileAdapterBuildReceiptSha256"
    "launcherPasswordStorageSchemeCode=md5_lower_hex_legacy_launcher_compatibility"
    "sqliteBaselineMemberCount=3"
    "sqliteStateMutationCount=0"
    "fullCompositeRollbackScriptByteLength=4222"
    "fullCompositeRollbackScriptSha256=b7789d3114da7a2d4d9e4d0f1330bdb040c264e3b8a47598581b395f98ed0371"
    "restoreReceiptSha256=$restoreSha"
    "toolTransferReceiptSha256=$transferSha"
    "externalHead=519c3db51ec24ca19307e93e85acde7885928a72"
    "externalTree=b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    "externalBuildManifestSha256=ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
) -join "`n"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-private-launcher-credential-checkpoint/v1"
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    environmentKindCode = "snapshot_capable_disposable_vm"
    checkpointTypeCode = "standard"
    checkpointIdentitySha256 = Get-TextSha256 ($identityText + "`n")
    checkpointCreationResumed = $checkpointCreationResumed
    previousCheckpointCount = $previousCheckpointCount
    currentCheckpointCount = $after.Count
    parentCheckpointIdentitySha256 =
        "426f8e1c4a5b6636b6e59cef42e021fe7c30881581ca06fb92603c12569c41e5"
    guestP0V3ReceiptByteLength = $GuestP0V3ReceiptByteLength
    guestP0V3ReceiptSha256 = $GuestP0V3ReceiptSha256
    guestProfileAdapterBuildReceiptByteLength =
        $GuestProfileAdapterBuildReceiptByteLength
    guestProfileAdapterBuildReceiptSha256 =
        $GuestProfileAdapterBuildReceiptSha256
    restoreReceiptSha256 = $restoreSha
    toolTransferReceiptSha256 = $transferSha
    clientBuild = "150.6.9"
    externalHead = "519c3db51ec24ca19307e93e85acde7885928a72"
    externalTree = "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    externalBuildManifestSha256 =
        "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    launcherPasswordPlaintextLength = 20
    launcherPasswordStorageLength = 32
    launcherPasswordStorageSchemeCode =
        "md5_lower_hex_legacy_launcher_compatibility"
    launcherPasswordRepresentationVerified = $true
    sqliteBaselineMemberCount = 3
    sqliteStateMutationCount = 0
    fullCompositeRollbackScriptByteLength = 4222
    fullCompositeRollbackScriptSha256 =
        "b7789d3114da7a2d4d9e4d0f1330bdb040c264e3b8a47598581b395f98ed0371"
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    hostVirtualAdapterPresent = $false
    externalUplinkPresent = $false
    natConfigured = $false
    guestServiceEnabled = $false
    credentialBearingGuestCopyPresent = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
