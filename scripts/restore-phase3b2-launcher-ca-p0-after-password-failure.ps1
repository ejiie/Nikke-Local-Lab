[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FailureReceiptPath,

    [Parameter(Mandatory)]
    [long]$FailureReceiptByteLength,

    [Parameter(Mandatory)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$FailureReceiptSha256,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

trap {
    New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
    $errorPath = Join-Path $EvidenceRoot `
        "private-password-failure-restore-v1.error.log"
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
Assert-True ($FailureReceiptByteLength -gt 0) `
    "phase3b2_password_restore_failure_receipt_length_invalid"
Assert-True (Test-Path -LiteralPath $FailureReceiptPath -PathType Leaf) `
    "phase3b2_password_restore_failure_receipt_missing"
Assert-True ((Get-Item -LiteralPath $FailureReceiptPath).Length -eq
        $FailureReceiptByteLength -and
    (Get-Sha256Hex $FailureReceiptPath) -ceq $FailureReceiptSha256) `
    "phase3b2_password_restore_failure_receipt_drift"

$checkpointReceiptPath = Join-Path $EvidenceRoot `
    "p0-private-launcher-ca-checkpoint-v1.json"
$restoreReceiptPath = Join-Path $EvidenceRoot `
    "private-password-failure-restore-v1.receipt.json"
Assert-True ((Get-Item -LiteralPath $checkpointReceiptPath).Length -eq 2360 -and
    (Get-Sha256Hex $checkpointReceiptPath) -ceq
        "279475d15b9bcdd9ff3b0c46d4d4c8b6ab0afc9586b6e5fe282dbe4f2a6e1846") `
    "phase3b2_password_restore_checkpoint_receipt_drift"
Assert-True (-not (Test-Path -LiteralPath $restoreReceiptPath)) `
    "phase3b2_password_restore_receipt_exists"

$failure = Get-Content -LiteralPath $FailureReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$checkpoint = Get-Content -LiteralPath $checkpointReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($failure.contractId -ceq
        "nll/phase3b2-private-reference-run-failure/v3" -and
    $failure.assessmentUid -ceq "812c585b-2849-474f-a9ff-dfb59feaea87" -and
    $failure.failedTransitionCode -ceq "local_login_submission" -and
    $failure.reasonCode -ceq "launcher_password_representation_mismatch" -and
    [int]$failure.displayedResultCode -eq 5 -and
    [int]$failure.displayedBackendCode -eq 2002 -and
    -not [bool]$failure.retryPerformed -and
    [bool]$failure.priorP1ServerRunning -and
    [int]$failure.currentServerProcessCount -eq 0 -and
    [bool]$failure.serverContinuityLostAfterDisplayedFailure -and
    [bool]$failure.launcherCertificateBundlePatched -and
    [bool]$failure.databasePasswordEqualsContextPlaintext -and
    -not [bool]$failure.databasePasswordMatchesLauncherMd5 -and
    -not [bool]$failure.clientExecutionStarted -and
    -not [bool]$failure.officialIdentityPersisted -and
    -not [bool]$failure.officialCredentialPersisted -and
    $failure.nextStepCode -ceq
        "restore_launcher_ca_p0_repair_synthetic_credential_reseal") `
    "phase3b2_password_restore_failure_receipt_invalid"
Assert-True ($checkpoint.contractId -ceq
        "nll/phase3b2-p0-private-launcher-ca-checkpoint/v1" -and
    $checkpoint.checkpointIdentitySha256 -ceq
        "426f8e1c4a5b6636b6e59cef42e021fe7c30881581ca06fb92603c12569c41e5" -and
    $checkpoint.networkModeCode -ceq "private_vm_only_no_gateway" -and
    $checkpoint.switchTypeCode -ceq "private_vm_only" -and
    [int]$checkpoint.connectedVmAdapterCount -eq 1 -and
    -not [bool]$checkpoint.hostVirtualAdapterPresent -and
    -not [bool]$checkpoint.guestServiceEnabled -and
    -not [bool]$checkpoint.serverExecutionStarted -and
    -not [bool]$checkpoint.clientExecutionStarted) `
    "phase3b2_password_restore_checkpoint_receipt_invalid"

$vm = Get-VM -Name $VMName -ErrorAction Stop
Assert-True ([string]$vm.Id -ceq "77d6f113-2f74-49e4-8fbf-0dc381232810") `
    "phase3b2_password_restore_vm_identity_mismatch"
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$managementAdapters = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName })
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0) `
    "phase3b2_password_restore_network_precondition_failed"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_password_restore_guest_service_enabled"

$snapshots = @(Get-VMSnapshot -VM $vm -ErrorAction Stop |
        Where-Object { $_.Name -like
            "NLL-P3B2-W1-P0-Private-LauncherCA-v1-*" })
Assert-True ($snapshots.Count -eq 1) `
    "phase3b2_password_restore_checkpoint_shape_invalid"
$snapshot = $snapshots[0]
$identityText = @(
    "contractId=nll/phase3b2-hyperv-private-launcher-ca-checkpoint-identity/v1"
    "vmId=$($vm.Id)"
    "checkpointId=$($snapshot.Id)"
    "checkpointName=$($snapshot.Name)"
    "creationTimeUtc=$($snapshot.CreationTime.ToUniversalTime().ToString('o'))"
    "networkModeCode=private_vm_only_no_gateway"
    "switchName=$SwitchName"
    "switchType=Private"
    "guestP0V2ReceiptByteLength=$($checkpoint.guestP0V2ReceiptByteLength)"
    "guestP0V2ReceiptSha256=$($checkpoint.guestP0V2ReceiptSha256)"
    "launcherCertificateAppliedSha256=6d871b31c354f4099977f164e7d289db6a6830611d6c8011a14f946c99a6719c"
    "compositeRollbackScriptSha256=83df6aac274fe78960032eead2d1f2da418d0d2969ee57d430132c0c5b248586"
    "externalHead=519c3db51ec24ca19307e93e85acde7885928a72"
    "externalTree=b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    "externalBuildManifestSha256=ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
) -join "`n"
Assert-True ((Get-TextSha256 ($identityText + "`n")) -ceq
        [string]$checkpoint.checkpointIdentitySha256) `
    "phase3b2_password_restore_checkpoint_identity_mismatch"

Restore-VMSnapshot -VMSnapshot $snapshot -Confirm:$false
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) { break }
    if ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Off) {
        Start-VM -VM $vm | Out-Null
    }
    Start-Sleep -Seconds 1
}
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) `
    "phase3b2_password_restore_vm_not_running_after_restore"

$privateSwitchAfter = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adaptersAfter = @(Get-VMNetworkAdapter -VM $vm)
$switchMembersAfter = @(Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$managementAdaptersAfter = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$guestServiceAfter = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
$snapshotAfter = @(Get-VMSnapshot -VM $vm -ErrorAction Stop |
        Where-Object { [string]$_.Id -ceq [string]$snapshot.Id })
Assert-True ($privateSwitchAfter.SwitchType -eq
        [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adaptersAfter.Count -eq 1 -and $adaptersAfter[0].SwitchName -ceq $SwitchName -and
    $switchMembersAfter.Count -eq 1 -and
    [string]$switchMembersAfter[0].VMId -ceq [string]$vm.Id -and
    $managementAdaptersAfter.Count -eq 0 -and
    $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled -and
    $snapshotAfter.Count -eq 1) `
    "phase3b2_password_restore_postcondition_failed"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-private-password-failure-restore/v1"
    restoredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    failedAssessmentUid = "812c585b-2849-474f-a9ff-dfb59feaea87"
    failureReceiptByteLength = $FailureReceiptByteLength
    failureReceiptSha256 = $FailureReceiptSha256
    restoredCheckpointReceiptByteLength = 2360
    restoredCheckpointReceiptSha256 =
        "279475d15b9bcdd9ff3b0c46d4d4c8b6ab0afc9586b6e5fe282dbe4f2a6e1846"
    restoredCheckpointIdentitySha256 = [string]$checkpoint.checkpointIdentitySha256
    rollbackStatusCode = "private_launcher_ca_p0_checkpoint_restored_verified"
    checkpointPreserved = $true
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    hostVirtualAdapterPresent = $false
    externalUplinkPresent = $false
    natConfigured = $false
    vmRunning = $true
    guestServiceEnabled = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = "repair_synthetic_launcher_credential_and_reseal"
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[IO.File]::WriteAllText($restoreReceiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
