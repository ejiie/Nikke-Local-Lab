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
$launcherTransferReceiptPath = Join-Path $EvidenceRoot `
    "launcher-ca-tool-transfer-v1.receipt.json"
$receiptPath = Join-Path $EvidenceRoot `
    "launcher-ca-verification-tool-transfer-v1.receipt.json"
Assert-True ((Get-Item -LiteralPath $launcherTransferReceiptPath).Length -eq 1157 -and
    (Get-Sha256Hex $launcherTransferReceiptPath) -ceq
        "7287a317bf916fc39b11b87eb7689ab989fc13602dac2c2819cd26157c1f1fe9") `
    "phase3b2_launcher_ca_verification_transfer_prior_receipt_drift"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_launcher_ca_verification_transfer_receipt_exists"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(
    Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
$managementAdapters = @(
    Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName }
)
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0) `
    "phase3b2_launcher_ca_verification_transfer_isolation_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_launcher_ca_verification_transfer_guest_service_precondition_mismatch"

$members = @(
    [ordered]@{
        roleCode = "p0_launcher_ca_verification"
        Source = Join-Path $PSScriptRoot `
            "verify-phase3b2-p0-launcher-ca-applied-in-vm.ps1"
        Destination = "C:\NLL\Tools\verify-phase3b2-p0-launcher-ca-applied-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "p1_private_v2_measurement"
        Source = Join-Path $PSScriptRoot "measure-phase3b2-p1-server-in-vm.ps1"
        Destination = "C:\NLL\Tools\measure-phase3b2-p1-server-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "private_v2_ready_projection"
        Source = Join-Path $PSScriptRoot "new-phase3b2-hyperv-ready-projection-in-vm.ps1"
        Destination = "C:\NLL\Tools\new-phase3b2-hyperv-ready-projection-in-vm.ps1"
    }
)
try {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
    foreach ($member in $members) {
        Assert-True (Test-Path -LiteralPath $member.Source -PathType Leaf) `
            "phase3b2_launcher_ca_verification_transfer_source_missing"
        Copy-VMFile -VM $vm -SourcePath $member.Source `
            -DestinationPath $member.Destination -FileSource Host -CreateFullPath -Force
    }
}
finally {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name `
        -ErrorAction SilentlyContinue
}

$vmAfter = Get-VM -Name $VMName -ErrorAction Stop
$adaptersAfter = @(Get-VMNetworkAdapter -VM $vmAfter)
$guestServiceAfter = @(
    Get-VMIntegrationService -VM $vmAfter |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($vmAfter.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $adaptersAfter.Count -eq 1 -and $adaptersAfter[0].SwitchName -ceq $SwitchName -and
    $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_launcher_ca_verification_transfer_postcondition_failed"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-launcher-ca-verification-tool-transfer/v1"
    transferredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    priorLauncherCaToolTransferSha256 =
        "7287a317bf916fc39b11b87eb7689ab989fc13602dac2c2819cd26157c1f1fe9"
    transferredMemberCount = $members.Count
    members = @($members | ForEach-Object {
            [ordered]@{
                roleCode = $_.roleCode
                byteLength = (Get-Item -LiteralPath $_.Source).Length
                sha256 = Get-Sha256Hex $_.Source
            }
        })
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    vmRunning = $true
    guestServiceEnabled = $false
    runtimeExecutionStateCode = "launcher_ca_extended_client_cold"
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 5) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 5
