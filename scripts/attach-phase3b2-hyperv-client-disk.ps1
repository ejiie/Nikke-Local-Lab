[CmdletBinding()]
param(
    [string]$VmName = "NLL-Phase3B2-Client150.6.9",
    [string]$ClientDiskPath = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Disks\NikkeClient-150.6.9-active.vhdx",
    [string]$ClientBasePath = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Disks\NikkeClient-150.6.9-base.vhdx"
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
Assert-True ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) "phase3b2_hyperv_administrator_required"

$vm = Get-VM -Name $VmName -ErrorAction Stop
Assert-True ($vm.State -eq "Off") "phase3b2_vm_must_be_off_for_disk_attach"
Assert-True (Test-Path -LiteralPath $ClientDiskPath -PathType Leaf) "phase3b2_client_difference_missing"
Assert-True (Test-Path -LiteralPath $ClientBasePath -PathType Leaf) "phase3b2_client_base_missing"

$clientVhd = Get-VHD -Path $ClientDiskPath -ErrorAction Stop
$expectedParent = [IO.Path]::GetFullPath($ClientBasePath)
Assert-True ($clientVhd.VhdType -eq "Differencing") "phase3b2_client_disk_not_differencing"
Assert-True ([IO.Path]::GetFullPath($clientVhd.ParentPath) -ceq $expectedParent) "phase3b2_client_difference_parent_mismatch"
$baseItem = Get-Item -LiteralPath $ClientBasePath
Assert-True $baseItem.IsReadOnly "phase3b2_client_base_not_read_only"

$vmAccount = "NT VIRTUAL MACHINE\$($vm.Id.ToString('D'))"
$icacls = Join-Path $env:SystemRoot "System32\icacls.exe"
& $icacls $ClientDiskPath "/grant:r" "${vmAccount}:(F)" | Out-Null
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_client_difference_acl_failed"
& $icacls $ClientBasePath "/grant:r" "${vmAccount}:(R)" | Out-Null
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_client_base_acl_failed"

$attached = @(Get-VMHardDiskDrive -VM $vm | Where-Object { $_.Path -ceq $ClientDiskPath })
Assert-True ($attached.Count -le 1) "phase3b2_client_disk_attached_multiple"
if ($attached.Count -eq 0) {
    Add-VMHardDiskDrive -VM $vm -ControllerType SCSI -Path $ClientDiskPath | Out-Null
}

$disks = @(Get-VMHardDiskDrive -VM $vm)
$osDisk = @($disks | Where-Object { $_.Path -cne $ClientDiskPath })
Assert-True ($osDisk.Count -eq 1) "phase3b2_os_disk_shape_invalid"
Set-VMFirmware -VM $vm -FirstBootDevice $osDisk[0]

[pscustomobject]@{
    contractId = "nll/phase3b2-hyperv-client-disk-attachment/v1"
    vmState = [string]$vm.State
    diskCount = $disks.Count
    dvdDetached = ((Get-VMDvdDrive -VM $vm).Path -eq $null)
    osFirstBoot = $true
    clientDiskLocationCode = "host_nvme_c_active_difference"
    clientDifferenceParentVerified = $true
    clientBaseReadOnly = $baseItem.IsReadOnly
    activeDiskAclCode = "vm_sid_full_control"
    baseDiskAclCode = "vm_sid_read_only"
} | ConvertTo-Json
