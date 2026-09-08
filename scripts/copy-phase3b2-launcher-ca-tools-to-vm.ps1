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
    "private-reference-failure-restore-v1.receipt.json"
$transferReceiptPath = Join-Path $EvidenceRoot `
    "launcher-ca-tool-transfer-v1.receipt.json"
Assert-True ((Get-Item -LiteralPath $restoreReceiptPath).Length -eq 1159 -and
    (Get-Sha256Hex $restoreReceiptPath) -ceq
        "6c7c4f3796bd3a64efd1d577dd7595bb61dbb459f60797ada1e519cb954bdf2a") `
    "phase3b2_launcher_ca_transfer_restore_receipt_drift"
Assert-True (-not (Test-Path -LiteralPath $transferReceiptPath)) `
    "phase3b2_launcher_ca_transfer_receipt_exists"

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
    $managementAdapters.Count -eq 0) "phase3b2_launcher_ca_transfer_isolation_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_launcher_ca_transfer_guest_service_precondition_mismatch"

$members = @(
    [ordered]@{
        roleCode = "launcher_ca_extension"
        Source = Join-Path $PSScriptRoot "extend-phase3b2-p0-launcher-ca-in-vm.ps1"
        Destination = "C:\NLL\Tools\extend-phase3b2-p0-launcher-ca-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "composite_rollback"
        Source = Join-Path $PSScriptRoot `
            "rollback-phase3b2-p0-with-launcher-ca-in-vm.ps1"
        Destination = "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-in-vm.ps1"
    }
)
try {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
    foreach ($member in $members) {
        Assert-True (Test-Path -LiteralPath $member.Source -PathType Leaf) `
            "phase3b2_launcher_ca_transfer_source_missing"
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
    "phase3b2_launcher_ca_transfer_postcondition_failed"

$memberDigests = @(
    $members | ForEach-Object {
        [ordered]@{
            roleCode = $_.roleCode
            byteLength = (Get-Item -LiteralPath $_.Source).Length
            sha256 = Get-Sha256Hex $_.Source
        }
    }
)
$receipt = [ordered]@{
    contractId = "nll/phase3b2-launcher-ca-tool-transfer/v1"
    transferredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    restoredFailureReceiptSha256 =
        "6c7c4f3796bd3a64efd1d577dd7595bb61dbb459f60797ada1e519cb954bdf2a"
    transferredMemberCount = $members.Count
    members = $memberDigests
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    vmRunning = $true
    guestServiceEnabled = $false
    runtimeExecutionStateCode = "restored_private_p0_client_cold"
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($transferReceiptPath, (($receipt | ConvertTo-Json -Depth 5) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 5
