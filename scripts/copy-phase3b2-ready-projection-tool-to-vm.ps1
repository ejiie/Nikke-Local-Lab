[CmdletBinding()]
param(
    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [ValidateSet("disconnected", "private_vm_only_no_gateway")]
    [string]$NetworkModeCode = "disconnected",
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
$source = Join-Path $PSScriptRoot "new-phase3b2-hyperv-ready-projection-in-vm.ps1"
$destination = "C:\NLL\Tools\new-phase3b2-hyperv-ready-projection-in-vm.ps1"
$receiptPath = Join-Path $EvidenceRoot $(if ($NetworkModeCode -ceq "disconnected") {
        "ready-projection-tool-transfer.receipt.json"
    } else {
        "ready-projection-private-tool-transfer.receipt.json"
    })
Assert-True (Test-Path -LiteralPath $source -PathType Leaf) "phase3b2_ready_projection_tool_missing"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) "phase3b2_ready_projection_transfer_receipt_exists"

$vm = Get-VM -Name $VMName -ErrorAction Stop
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) "phase3b2_vm_not_running"
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$privateSwitch = if ($NetworkModeCode -ceq "private_vm_only_no_gateway") {
    Get-VMSwitch -Name $SwitchName -ErrorAction Stop
} else { $null }
$switchMembers = if ($null -ne $privateSwitch) {
    @(Get-VM | Get-VMNetworkAdapter | Where-Object SwitchName -CEQ $SwitchName)
} else { @() }
Assert-True ($adapters.Count -eq 1 -and $(if ($NetworkModeCode -ceq "disconnected") {
        $null -eq $adapters[0].SwitchName
    } else {
        $privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
        $adapters[0].SwitchName -ceq $SwitchName -and $switchMembers.Count -eq 1 -and
        [string]$switchMembers[0].VMId -ceq [string]$vm.Id
    })) `
    "phase3b2_vm_network_not_isolated"
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_guest_service_precondition_mismatch"

try {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
    Copy-VMFile -VM $vm -SourcePath $source -DestinationPath $destination `
        -FileSource Host -CreateFullPath -Force
}
finally {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name -ErrorAction SilentlyContinue
}

$vmAfter = Get-VM -Name $VMName -ErrorAction Stop
$adaptersAfter = @(Get-VMNetworkAdapter -VM $vmAfter)
$guestServiceAfter = @(
    Get-VMIntegrationService -VM $vmAfter |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($vmAfter.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) `
    "phase3b2_vm_state_changed_during_tool_transfer"
Assert-True ($adaptersAfter.Count -eq 1 -and $(if ($NetworkModeCode -ceq "disconnected") {
        $null -eq $adaptersAfter[0].SwitchName
    } else {
        $adaptersAfter[0].SwitchName -ceq $SwitchName
    })) `
    "phase3b2_vm_network_changed_during_tool_transfer"
Assert-True ($guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_guest_service_disable_failed"

$receipt = [ordered]@{
    contractId = if ($NetworkModeCode -ceq "disconnected") {
        "nll/phase3b2-ready-projection-tool-transfer/v1"
    } else {
        "nll/phase3b2-private-ready-projection-tool-transfer/v1"
    }
    transferredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    transferredMemberCount = 1
    sourceByteLength = (Get-Item -LiteralPath $source).Length
    sourceSha256 = Get-Sha256Hex $source
    vmRunning = $true
    networkModeCode = $NetworkModeCode
    connectedSwitchCount = if ($NetworkModeCode -ceq "disconnected") { 0 } else { 1 }
    switchTypeCode = if ($NetworkModeCode -ceq "disconnected") { "none" } else { "private_vm_only" }
    connectedVmAdapterCount = 1
    guestServiceEnabled = $false
    serverExecutionStateCode = "preserved_running_unobserved_by_host"
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"), [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
