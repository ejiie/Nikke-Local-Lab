[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Management.Automation.PSCredential]$GuestCredential,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

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

$transferPath = Join-Path $EvidenceRoot `
    "sqlite-rebootstrap-run-tool-transfer-v1.receipt.json"
$parentPath = Join-Path $EvidenceRoot `
    "p0-private-launcher-credential-checkpoint-v1.json"
$receiptPath = Join-Path $EvidenceRoot `
    "p0-private-sqlite-reset-checkpoint-v1.json"
Assert-True (Test-Path -LiteralPath $transferPath -PathType Leaf) `
    "phase3b2_sqlite_checkpoint_transfer_receipt_missing"
Assert-True ((Get-Item -LiteralPath $parentPath).Length -eq 2305 -and
    (Get-Sha256Hex $parentPath) -ceq
        "6381878760cc14bfd42f40232d3aa9d0cdb21fe133041ac910d63a20034b8cb4") `
    "phase3b2_sqlite_checkpoint_parent_receipt_drift"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_sqlite_checkpoint_receipt_exists"
$transfer = Get-Content -LiteralPath $transferPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($transfer.contractId -ceq
        "nll/phase3b2-sqlite-rebootstrap-run-tool-transfer/v1" -and
    [int]$transfer.transferredMemberCount -eq 3 -and
    $transfer.runtimeExecutionStateCode -ceq
        "sqlite_reset_prepared_client_cold" -and
    -not [bool]$transfer.guestServiceEnabled -and
    -not [bool]$transfer.serverExecutionStarted -and
    -not [bool]$transfer.clientExecutionStarted) `
    "phase3b2_sqlite_checkpoint_transfer_receipt_invalid"

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
    $managementAdapters.Count -eq 0) "phase3b2_sqlite_checkpoint_environment_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_sqlite_checkpoint_guest_service_enabled"

$guestObservation = Invoke-Command -VMName $VMName -Credential $GuestCredential `
    -ScriptBlock {
        $p0Path = Join-Path $env:LOCALAPPDATA `
            "NikkeLocalLab\Evidence\Phase3B2\Trusted\p0\applied-verification-private-v4.receipt.json"
        $resetPath = Join-Path $env:LOCALAPPDATA `
            "NikkeLocalLab\Evidence\Phase3B2\Trusted\identity\sqlite-credential-reset-v1\reset-preparation.receipt.json"
        $p0 = Get-Content -LiteralPath $p0Path -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $reset = Get-Content -LiteralPath $resetPath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $serverRoot = "C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64"
        [pscustomobject]@{
            P0ContractId = [string]$p0.contractId
            P0AppliedVerified = [bool]$p0.p0AppliedVerified
            P0ByteLength = (Get-Item -LiteralPath $p0Path).Length
            P0Sha256 = (Get-FileHash -LiteralPath $p0Path -Algorithm SHA256).Hash.ToLowerInvariant()
            ResetContractId = [string]$reset.contractId
            ResetByteLength = (Get-Item -LiteralPath $resetPath).Length
            ResetSha256 = (Get-FileHash -LiteralPath $resetPath -Algorithm SHA256).Hash.ToLowerInvariant()
            SqliteRuntimeMemberCount = @("epinelps.db", "epinelps.db-shm", "epinelps.db-wal" |
                Where-Object { Test-Path -LiteralPath (Join-Path $serverRoot $_) }).Count
            ServerProcessCount = @(Get-Process -Name EpinelPS -ErrorAction SilentlyContinue).Count
            LauncherProcessCount = @(Get-Process -Name nikke_launcher -ErrorAction SilentlyContinue).Count
            ClientProcessCount = @(Get-Process -Name nikke -ErrorAction SilentlyContinue).Count
        }
    }
Assert-True (@($guestObservation).Count -eq 1 -and
    $guestObservation.P0ContractId -ceq
        "nll/phase3b2-p0-private-applied-verification/v4" -and
    [bool]$guestObservation.P0AppliedVerified -and
    $guestObservation.ResetContractId -ceq
        "nll/phase3b2-sqlite-credential-reset-preparation/v1" -and
    [int]$guestObservation.SqliteRuntimeMemberCount -eq 0 -and
    [int]$guestObservation.ServerProcessCount -eq 0 -and
    [int]$guestObservation.LauncherProcessCount -eq 0 -and
    [int]$guestObservation.ClientProcessCount -eq 0) `
    "phase3b2_sqlite_checkpoint_guest_state_invalid"

$before = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
$created = @($before | Where-Object { $_.Name -like
        "NLL-P3B2-W1-P0-Private-SQLiteCredential-v1-*" })
Assert-True ($created.Count -le 1) "phase3b2_sqlite_checkpoint_resume_shape_invalid"
$checkpointCreationResumed = $created.Count -eq 1
if ($created.Count -eq 0) {
    $snapshotName = "NLL-P3B2-W1-P0-Private-SQLiteCredential-v1-" +
        [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssZ")
    Checkpoint-VM -VM $vm -SnapshotName $snapshotName
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $after = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
        $created = @($after | Where-Object Name -CEQ $snapshotName)
        if ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) { break }
        Start-Sleep -Milliseconds 500
    }
    Assert-True ($created.Count -eq 1 -and $after.Count -eq $before.Count + 1) `
        "phase3b2_sqlite_checkpoint_creation_not_verified"
    $previousCheckpointCount = $before.Count
}
else {
    $snapshotName = $created[0].Name
    $after = $before
    $previousCheckpointCount = $after.Count - 1
}

$identityText = @(
    "contractId=nll/phase3b2-hyperv-private-sqlite-credential-checkpoint-identity/v1"
    "vmId=$($vm.Id)"
    "checkpointId=$($created[0].Id)"
    "checkpointName=$snapshotName"
    "creationTimeUtc=$($created[0].CreationTime.ToUniversalTime().ToString('o'))"
    "parentCheckpointIdentitySha256=80f2b7b9562220ac88a76a8f6135069eeb095017a4491713475ffa1c264287a2"
    "guestP0V4ReceiptByteLength=$($guestObservation.P0ByteLength)"
    "guestP0V4ReceiptSha256=$($guestObservation.P0Sha256)"
    "guestResetReceiptByteLength=$($guestObservation.ResetByteLength)"
    "guestResetReceiptSha256=$($guestObservation.ResetSha256)"
    "runToolTransferReceiptSha256=$(Get-Sha256Hex $transferPath)"
    "sqliteCredentialRebootstrapPrepared=true"
    "sqliteRuntimeMemberCount=0"
    "networkModeCode=private_vm_only_no_gateway"
) -join "`n"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-private-sqlite-credential-checkpoint/v1"
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    environmentKindCode = "snapshot_capable_disposable_vm"
    checkpointTypeCode = "standard"
    checkpointIdentitySha256 = Get-TextSha256 ($identityText + "`n")
    checkpointCreationResumed = $checkpointCreationResumed
    previousCheckpointCount = $previousCheckpointCount
    currentCheckpointCount = $after.Count
    parentCheckpointIdentitySha256 =
        "80f2b7b9562220ac88a76a8f6135069eeb095017a4491713475ffa1c264287a2"
    guestP0V4ReceiptByteLength = [long]$guestObservation.P0ByteLength
    guestP0V4ReceiptSha256 = [string]$guestObservation.P0Sha256
    guestResetReceiptByteLength = [long]$guestObservation.ResetByteLength
    guestResetReceiptSha256 = [string]$guestObservation.ResetSha256
    runToolTransferReceiptByteLength = (Get-Item -LiteralPath $transferPath).Length
    runToolTransferReceiptSha256 = Get-Sha256Hex $transferPath
    clientBuild = "150.6.9"
    externalHead = "519c3db51ec24ca19307e93e85acde7885928a72"
    externalTree = "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    externalBuildManifestSha256 =
        "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    sqliteCredentialRebootstrapPrepared = $true
    sqliteCredentialBindingVerified = $false
    sqliteRuntimeMemberCount = 0
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    hostVirtualAdapterPresent = $false
    externalUplinkPresent = $false
    natConfigured = $false
    guestServiceEnabled = $false
    guestOsCredentialPersisted = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
