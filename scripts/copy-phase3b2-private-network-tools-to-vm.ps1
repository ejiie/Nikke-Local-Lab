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
$resetReceiptPath = Join-Path $EvidenceRoot "private-switch-reset-v1.receipt.json"
$receiptPath = Join-Path $EvidenceRoot "private-network-tool-transfer-v1.receipt.json"
Assert-True ((Get-Item -LiteralPath $resetReceiptPath).Length -eq 814 -and
    (Get-Sha256Hex $resetReceiptPath) -ceq
        "780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748") `
    "phase3b2_private_tool_transfer_reset_receipt_drift"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_private_tool_transfer_receipt_exists"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$connectedAdapters = @(
    Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $connectedAdapters.Count -eq 1 -and
    [string]$connectedAdapters[0].VMId -ceq [string]$vm.Id) `
    "phase3b2_private_tool_transfer_isolation_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_private_tool_transfer_guest_service_precondition_mismatch"

$members = @(
    [ordered]@{
        Source = Join-Path $PSScriptRoot "prepare-phase3b2-private-network-in-vm.ps1"
        Destination = "C:\NLL\Tools\prepare-phase3b2-private-network-in-vm.ps1"
    },
    [ordered]@{
        Source = Join-Path $PSScriptRoot "verify-phase3b2-p0-applied-in-vm.ps1"
        Destination = "C:\NLL\Tools\verify-phase3b2-p0-applied-in-vm.ps1"
    },
    [ordered]@{
        Source = Join-Path $PSScriptRoot "measure-phase3b2-p1-server-in-vm.ps1"
        Destination = "C:\NLL\Tools\measure-phase3b2-p1-server-in-vm.ps1"
    }
)
try {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
    foreach ($member in $members) {
        Assert-True (Test-Path -LiteralPath $member.Source -PathType Leaf) `
            "phase3b2_private_tool_transfer_source_missing"
        Copy-VMFile -VM $vm -SourcePath $member.Source -DestinationPath $member.Destination `
            -FileSource Host -CreateFullPath -Force
    }
}
finally {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name -ErrorAction SilentlyContinue
}

$vmAfter = Get-VM -Name $VMName -ErrorAction Stop
$adapterAfter = @(Get-VMNetworkAdapter -VM $vmAfter)
$guestServiceAfter = @(
    Get-VMIntegrationService -VM $vmAfter |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($vmAfter.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $adapterAfter.Count -eq 1 -and $adapterAfter[0].SwitchName -ceq $SwitchName -and
    $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_private_tool_transfer_postcondition_failed"

$memberDigests = @($members | ForEach-Object {
        [ordered]@{
            roleCode = switch -Wildcard ($_.Destination) {
                "*prepare-phase3b2-private-network*" { "private_network_preparation" }
                "*verify-phase3b2-p0*" { "p0_private_verification" }
                default { "p1_private_measurement" }
            }
            byteLength = (Get-Item -LiteralPath $_.Source).Length
            sha256 = Get-Sha256Hex $_.Source
        }
    })
$receipt = [ordered]@{
    contractId = "nll/phase3b2-private-network-tool-transfer/v1"
    transferredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    hostPrivateSwitchReceiptSha256 = "780e09d4dbe75180862f9347163a9e4058441cd5b3d025aaf38dee7b345f6748"
    transferredMemberCount = $members.Count
    members = $memberDigests
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    vmRunning = $true
    guestServiceEnabled = $false
    runtimeExecutionStateCode = "expected_cold_from_restored_checkpoint"
}
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 5) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 5

