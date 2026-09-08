[CmdletBinding()]
param([string]$VMName = "NLL-Phase3B2-Client150.6.9")

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"
$vm = Get-VM -Name $VMName -ErrorAction Stop
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) "phase3b2_vm_not_running"
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1) "guest_service_interface_shape_invalid"
if (-not $guestService[0].Enabled) {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
}

$members = @(
    @{
        Source = Join-Path $PSScriptRoot "inspect-phase3b2-p0-targets-in-vm.ps1"
        Destination = "C:\NLL\Tools\inspect-phase3b2-p0-targets-in-vm.ps1"
    },
    @{
        Source = Join-Path $PSScriptRoot "rollback-phase3b2-p0-in-vm.ps1"
        Destination = "C:\NLL\Tools\rollback-phase3b2-p0-in-vm.ps1"
    },
    @{
        Source = Join-Path $PSScriptRoot "prepare-phase3b2-p0-mutations-in-vm.ps1"
        Destination = "C:\NLL\Tools\prepare-phase3b2-p0-mutations-in-vm.ps1"
    },
    @{
        Source = Join-Path $PSScriptRoot "verify-phase3b2-p0-applied-in-vm.ps1"
        Destination = "C:\NLL\Tools\verify-phase3b2-p0-applied-in-vm.ps1"
    },
    @{
        Source = Join-Path $PSScriptRoot "measure-phase3b2-p1-server-in-vm.ps1"
        Destination = "C:\NLL\Tools\measure-phase3b2-p1-server-in-vm.ps1"
    },
    @{
        Source = Join-Path $PSScriptRoot "update-phase3b2-epinelps-v4-in-vm.ps1"
        Destination = "C:\NLL\Tools\update-phase3b2-epinelps-v4-in-vm.ps1"
    }
)
try {
    foreach ($member in $members) {
        Assert-True (Test-Path -LiteralPath $member.Source -PathType Leaf) "phase3b2_p0_tool_missing"
        Copy-VMFile -VM $vm -SourcePath $member.Source -DestinationPath $member.Destination `
            -FileSource Host -CreateFullPath -Force
    }
}
finally {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name
}
$verified = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($verified.Count -eq 1 -and -not $verified[0].Enabled) "guest_service_disable_failed"

[pscustomobject]@{
    ContractId = "nll/phase3b2-p0-tool-transfer/v1"
    TransferredMemberCount = $members.Count
    GuestServiceEnabled = $false
    ServerExecutionStarted = $false
    ClientExecutionStarted = $false
}
