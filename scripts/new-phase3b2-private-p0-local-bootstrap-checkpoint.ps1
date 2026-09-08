[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Management.Automation.PSCredential]$GuestCredential,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot =
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
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
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"

$parentPath = Join-Path $EvidenceRoot `
    "p0-private-sqlite-reset-checkpoint-v1.json"
$transferPath = Join-Path $EvidenceRoot `
    "local-bootstrap-run-tool-transfer-v1.receipt.json"
$receiptPath = Join-Path $EvidenceRoot `
    "p0-private-local-bootstrap-checkpoint-v1.json"
Assert-True ((Get-Item -LiteralPath $parentPath).Length -eq 1887 -and
    (Get-Sha256Hex $parentPath) -ceq
        "d92ee1498ab276ad41aa52967a024368dc47c41f93e472f3c76e6c34270211b8") `
    "phase3b2_local_bootstrap_checkpoint_parent_receipt_drift"
Assert-True (Test-Path -LiteralPath $transferPath -PathType Leaf) `
    "phase3b2_local_bootstrap_checkpoint_transfer_receipt_missing"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_local_bootstrap_checkpoint_receipt_exists"

$transfer = Get-Content -LiteralPath $transferPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($transfer.contractId -ceq
        "nll/phase3b2-local-bootstrap-run-tool-transfer/v1" -and
    [int]$transfer.transferredMemberCount -ge 8 -and
    $transfer.networkModeCode -ceq "private_vm_only_no_gateway" -and
    $transfer.switchTypeCode -ceq "private_vm_only" -and
    [int]$transfer.connectedVmAdapterCount -eq 1 -and
    $transfer.runtimeExecutionStateCode -ceq
        "local_bootstrap_artifacts_and_tools_staged_client_cold" -and
    -not [bool]$transfer.guestServiceEnabled -and
    -not [bool]$transfer.serverExecutionStarted -and
    -not [bool]$transfer.clientExecutionStarted) `
    "phase3b2_local_bootstrap_checkpoint_transfer_receipt_invalid"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$managementAdapters = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName })
Assert-True ([string]$vm.Id -ceq
        "77d6f113-2f74-49e4-8fbf-0dc381232810" -and
    $vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $vm.CheckpointType -eq
        [Microsoft.HyperV.PowerShell.CheckpointType]::Standard -and
    -not $vm.AutomaticCheckpointsEnabled -and
    $privateSwitch.SwitchType -eq
        [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and
    $adapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0) `
    "phase3b2_local_bootstrap_checkpoint_environment_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_local_bootstrap_checkpoint_guest_service_enabled"

$guest = Invoke-Command -VMName $VMName -Credential $GuestCredential `
    -ScriptBlock {
        $trustedRoot = Join-Path $env:LOCALAPPDATA `
            "NikkeLocalLab\Evidence\Phase3B2\Trusted"
        $p0Path = Join-Path $trustedRoot `
            "p0\applied-verification-private-v5.receipt.json"
        $verificationPath = Join-Path $trustedRoot `
            "p0-local-bootstrap-v1\applied-verification.receipt.json"
        $p0 = Get-Content -LiteralPath $p0Path -Raw -Encoding UTF8 |
            ConvertFrom-Json
        $verification = Get-Content -LiteralPath $verificationPath -Raw `
            -Encoding UTF8 | ConvertFrom-Json
        $rules = @(Get-NetFirewallRule -Group "NLL Phase3B2 Isolation" `
                -ErrorAction Stop)
        [pscustomobject]@{
            P0ContractId = [string]$p0.contractId
            P0AppliedVerified = [bool]$p0.p0AppliedVerified
            P0ByteLength = (Get-Item -LiteralPath $p0Path).Length
            P0Sha256 = (Get-FileHash -LiteralPath $p0Path `
                    -Algorithm SHA256).Hash.ToLowerInvariant()
            VerificationContractId = [string]$verification.contractId
            VerificationByteLength =
                (Get-Item -LiteralPath $verificationPath).Length
            VerificationSha256 = (Get-FileHash -LiteralPath $verificationPath `
                    -Algorithm SHA256).Hash.ToLowerInvariant()
            ClientBootstrapModeCode = [string]$p0.clientBootstrapModeCode
            ArtifactManifestSha256 =
                [string]$p0.localBootstrapArtifactManifestSha256
            SqliteCredentialRebootstrapPrepared =
                [bool]$p0.sqliteCredentialRebootstrapPrepared
            SqliteCredentialBindingVerified =
                [bool]$p0.sqliteCredentialBindingVerified
            SqliteRuntimeMemberCount = [int]$p0.sqliteRuntimeMemberCount
            FirewallRuleCount = $rules.Count
            RuntimeProcessCount = @(Get-Process -Name EpinelPS,
                    nikke_launcher, nikke,
                    NikkeLocalLab.Phase3B2.LocalBootstrap `
                    -ErrorAction SilentlyContinue).Count
            CredentialBearingGuestCopyPresent = Test-Path -LiteralPath `
                "C:\NLL\Inputs\credential-bearing\source.json"
        }
    }
Assert-True (@($guest).Count -eq 1 -and
    $guest.P0ContractId -ceq
        "nll/phase3b2-p0-private-applied-verification/v5" -and
    [bool]$guest.P0AppliedVerified -and
    $guest.VerificationContractId -ceq
        "nll/phase3b2-p0-local-bootstrap-applied-verification/v1" -and
    $guest.ClientBootstrapModeCode -ceq
        "source_built_sail_abi_local_bootstrap" -and
    $guest.ArtifactManifestSha256 -ceq
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70" -and
    [bool]$guest.SqliteCredentialRebootstrapPrepared -and
    -not [bool]$guest.SqliteCredentialBindingVerified -and
    [int]$guest.SqliteRuntimeMemberCount -eq 0 -and
    [int]$guest.FirewallRuleCount -eq 17 -and
    [int]$guest.RuntimeProcessCount -eq 0 -and
    -not [bool]$guest.CredentialBearingGuestCopyPresent) `
    "phase3b2_local_bootstrap_checkpoint_guest_state_invalid"

$before = @(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue)
$created = @($before | Where-Object { $_.Name -like
        "NLL-P3B2-W1-P0-Private-LocalBootstrap-v1-*" })
Assert-True ($before.Count -eq 9 -and $created.Count -eq 0) `
    "phase3b2_local_bootstrap_checkpoint_precondition_mismatch"
$snapshotName = "NLL-P3B2-W1-P0-Private-LocalBootstrap-v1-" +
    [DateTimeOffset]::UtcNow.ToString("yyyyMMddTHHmmssZ")
Checkpoint-VM -VM $vm -SnapshotName $snapshotName
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    $after = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
    $created = @($after | Where-Object Name -CEQ $snapshotName)
    if ($created.Count -eq 1 -and $after.Count -eq 10) { break }
    Start-Sleep -Milliseconds 500
}
Assert-True ($created.Count -eq 1 -and $after.Count -eq 10) `
    "phase3b2_local_bootstrap_checkpoint_creation_not_verified"

$identityText = (@(
        "contractId=nll/phase3b2-hyperv-private-local-bootstrap-checkpoint-identity/v1"
        "vmId=$($vm.Id)"
        "checkpointId=$($created[0].Id)"
        "checkpointName=$snapshotName"
        "creationTimeUtc=$($created[0].CreationTime.ToUniversalTime().ToString('o'))"
        "parentCheckpointIdentitySha256=89251c58622331d18a0580e2eceb234cb973ecbac17fcbe04a08762c45876e80"
        "guestP0V5ReceiptByteLength=$($guest.P0ByteLength)"
        "guestP0V5ReceiptSha256=$($guest.P0Sha256)"
        "localBootstrapArtifactManifestSha256=$($guest.ArtifactManifestSha256)"
        "transferReceiptSha256=$(Get-Sha256Hex $transferPath)"
        "networkModeCode=private_vm_only_no_gateway"
    ) -join "`n") + "`n"
$receipt = [ordered]@{
    contractId = "nll/phase3b2-p0-private-local-bootstrap-checkpoint/v1"
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    environmentKindCode = "snapshot_capable_disposable_vm"
    checkpointTypeCode = "standard"
    checkpointIdentitySha256 = Get-TextSha256 $identityText
    checkpointCreationResumed = $false
    previousCheckpointCount = 9
    currentCheckpointCount = 10
    parentCheckpointIdentitySha256 =
        "89251c58622331d18a0580e2eceb234cb973ecbac17fcbe04a08762c45876e80"
    guestP0V5ReceiptByteLength = [long]$guest.P0ByteLength
    guestP0V5ReceiptSha256 = [string]$guest.P0Sha256
    guestP0LocalBootstrapVerificationByteLength =
        [long]$guest.VerificationByteLength
    guestP0LocalBootstrapVerificationSha256 =
        [string]$guest.VerificationSha256
    runToolTransferReceiptByteLength = (Get-Item -LiteralPath $transferPath).Length
    runToolTransferReceiptSha256 = Get-Sha256Hex $transferPath
    clientBuild = "150.6.9"
    externalHead = "519c3db51ec24ca19307e93e85acde7885928a72"
    externalTree = "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
    externalBuildManifestSha256 =
        "ab67db81070949781c2802b86e6b411eb020fc59e4f1dc9dd48afd19378d5a37"
    clientBootstrapModeCode = "source_built_sail_abi_local_bootstrap"
    localBootstrapUpstreamHead =
        "3d680453c0a4ca5ab2cdf3eb60e09b4160cb1bb3"
    localBootstrapUpstreamTree =
        "54b85eb6fbaa74feae0c6b441d66a5a703073ba3"
    localBootstrapArtifactManifestSha256 =
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70"
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
    credentialBearingGuestCopyPresent = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    serverExecutionStarted = $false
    launcherExecutionStarted = $false
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[IO.File]::WriteAllText($receiptPath,
    (($receipt | ConvertTo-Json -Depth 5) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 5
