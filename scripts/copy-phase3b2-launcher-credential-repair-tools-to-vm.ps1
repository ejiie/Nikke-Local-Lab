[CmdletBinding()]
param(
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

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"

$restoreReceiptPath = Join-Path $EvidenceRoot `
    "private-password-failure-restore-v1.receipt.json"
$receiptPath = Join-Path $EvidenceRoot `
    "launcher-credential-repair-tool-transfer-v2.receipt.json"
Assert-True (Test-Path -LiteralPath $restoreReceiptPath -PathType Leaf) `
    "phase3b2_credential_tool_transfer_restore_receipt_missing"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_credential_tool_transfer_receipt_exists"
$restoreReceipt = Get-Content -LiteralPath $restoreReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($restoreReceipt.contractId -ceq
        "nll/phase3b2-private-password-failure-restore/v1" -and
    $restoreReceipt.failedAssessmentUid -ceq
        "812c585b-2849-474f-a9ff-dfb59feaea87" -and
    $restoreReceipt.rollbackStatusCode -ceq
        "private_launcher_ca_p0_checkpoint_restored_verified" -and
    $restoreReceipt.restoredCheckpointIdentitySha256 -ceq
        "426f8e1c4a5b6636b6e59cef42e021fe7c30881581ca06fb92603c12569c41e5" -and
    -not [bool]$restoreReceipt.serverExecutionStarted -and
    -not [bool]$restoreReceipt.clientExecutionStarted) `
    "phase3b2_credential_tool_transfer_restore_receipt_invalid"

$adapterRoot = Join-Path (Split-Path -Parent $PSScriptRoot) `
    "tools\NikkeLocalLab.Phase3B2.ProfileAdapter"
$members = @(
    [ordered]@{
        roleCode = "credential_repair"
        source = Join-Path $PSScriptRoot `
            "repair-phase3b2-synthetic-launcher-credential-in-vm.ps1"
        destination = "C:\NLL\Tools\repair-phase3b2-synthetic-launcher-credential-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "credential_rollback"
        source = Join-Path $PSScriptRoot `
            "rollback-phase3b2-synthetic-launcher-credential-in-vm.ps1"
        destination = "C:\NLL\Tools\rollback-phase3b2-synthetic-launcher-credential-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "full_composite_rollback"
        source = Join-Path $PSScriptRoot `
            "rollback-phase3b2-p0-with-launcher-ca-and-credential-in-vm.ps1"
        destination = "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-and-credential-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "credential_p0_verification"
        source = Join-Path $PSScriptRoot `
            "verify-phase3b2-p0-launcher-credential-applied-in-vm.ps1"
        destination = "C:\NLL\Tools\verify-phase3b2-p0-launcher-credential-applied-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "profile_adapter_build_verification"
        source = Join-Path $PSScriptRoot `
            "verify-phase3b2-profile-adapter-launcher-credential-in-vm.ps1"
        destination = "C:\NLL\Tools\verify-phase3b2-profile-adapter-launcher-credential-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "credential_v3_preparation"
        source = Join-Path $PSScriptRoot `
            "prepare-phase3b2-launcher-credential-v3-in-vm.ps1"
        destination = "C:\NLL\Tools\prepare-phase3b2-launcher-credential-v3-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "private_v3_p1_measurement"
        source = Join-Path $PSScriptRoot "measure-phase3b2-p1-server-in-vm.ps1"
        destination = "C:\NLL\Tools\measure-phase3b2-p1-server-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "private_v3_ready_projection"
        source = Join-Path $PSScriptRoot `
            "new-phase3b2-hyperv-ready-projection-in-vm.ps1"
        destination = "C:\NLL\Tools\new-phase3b2-hyperv-ready-projection-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "private_v3_p1_ready_orchestrator"
        source = Join-Path $PSScriptRoot `
            "start-phase3b2-private-v3-p1-and-ready-in-vm.ps1"
        destination = "C:\NLL\Tools\start-phase3b2-private-v3-p1-and-ready-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "profile_adapter_credential_source"
        source = Join-Path $adapterRoot "Program.cs"
        destination = "C:\NLL\Tools\ProfileAdapter\Program.cs"
    }
)
foreach ($member in $members) {
    Assert-True (Test-Path -LiteralPath $member.source -PathType Leaf) `
        "phase3b2_credential_tool_transfer_source_missing"
}

$vm = Get-VM -Name $VMName -ErrorAction Stop
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
    "phase3b2_credential_tool_transfer_isolation_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_credential_tool_transfer_guest_service_precondition_mismatch"
try {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
    foreach ($member in $members) {
        $copied = $false
        $copyFailure = $null
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            try {
                Copy-VMFile -VM $vm -SourcePath $member.source `
                    -DestinationPath $member.destination -FileSource Host `
                    -CreateFullPath -Force
                $copied = $true
                break
            }
            catch {
                $copyFailure = $_
                Start-Sleep -Seconds 1
            }
        }
        if (-not $copied) { throw $copyFailure }
    }
}
finally {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name `
        -ErrorAction SilentlyContinue
}

$guestServiceAfter = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_credential_tool_transfer_guest_service_postcondition_failed"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-launcher-credential-repair-tool-transfer/v2"
    transferredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    restoredFailureReceiptByteLength =
        (Get-Item -LiteralPath $restoreReceiptPath).Length
    restoredFailureReceiptSha256 = Get-Sha256Hex $restoreReceiptPath
    transferredMemberCount = $members.Count
    members = @($members | ForEach-Object {
            [ordered]@{
                roleCode = $_.roleCode
                byteLength = (Get-Item -LiteralPath $_.source).Length
                sha256 = Get-Sha256Hex $_.source
            }
        })
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    vmRunning = $true
    guestServiceEnabled = $false
    runtimeExecutionStateCode = "restored_launcher_ca_p0_client_cold"
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($receiptPath,
    (($receipt | ConvertTo-Json -Depth 5) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 5
