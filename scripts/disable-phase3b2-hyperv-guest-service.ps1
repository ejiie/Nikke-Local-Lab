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
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1) "guest_service_shape_invalid"
if ($guestService[0].Enabled) {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name
}
$verified = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($verified.Count -eq 1 -and -not $verified[0].Enabled) "guest_service_disable_failed"

[pscustomobject]@{
    VMState = [string]$vm.State
    GuestServiceEnabled = $false
    ServerExecutionStarted = $false
    ClientExecutionStarted = $false
}
