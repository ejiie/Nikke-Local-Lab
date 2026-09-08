[CmdletBinding()]
param(
    [string]$VmName = "NLL-Phase3B2-Client150.6.9",
    [string]$VmRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\VMs",
    [string]$IsoPath = "D:\NikkeLocalLab\HyperV\Phase3B2\ISO\Windows11EnterpriseEval-25H2-ko-kr-x64.iso"
)

$ErrorActionPreference = "Stop"
$expectedIsoSha256 = "3098938EDAEA0A5D59E3D966514A4C0D1CBFD4F6CAE9D35CEB079FC3272099A4"
$expectedVmName = "NLL-Phase3B2-Client150.6.9"
$expectedVmRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\VMs"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
Assert-True ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) "phase3b2_hyperv_administrator_required"

$vmRootFullPath = [System.IO.Path]::GetFullPath($VmRoot).TrimEnd("\")
$isoFullPath = [System.IO.Path]::GetFullPath($IsoPath)
Assert-True ($VmName -ceq $expectedVmName) "phase3b2_hyperv_vm_name_mismatch"
Assert-True ($vmRootFullPath -ceq $expectedVmRoot) "phase3b2_hyperv_vm_root_mismatch"
Assert-True (Test-Path -LiteralPath $isoFullPath -PathType Leaf) "phase3b2_hyperv_iso_missing"
Assert-True ((Get-FileHash -LiteralPath $isoFullPath -Algorithm SHA256).Hash -ceq $expectedIsoSha256) "phase3b2_hyperv_iso_hash_mismatch"
Assert-True ($null -eq (Get-VM -Name $VmName -ErrorAction SilentlyContinue)) "phase3b2_hyperv_vm_already_exists"

$switch = Get-VMSwitch -Name "Default Switch" -ErrorAction Stop
Assert-True ($switch.SwitchType -eq "Internal") "phase3b2_hyperv_default_switch_type_mismatch"

$vmPath = Join-Path $vmRootFullPath $VmName
$osDiskPath = Join-Path $vmPath "Virtual Hard Disks\Windows11EnterpriseEval-25H2.vhdx"
Assert-True (-not (Test-Path -LiteralPath $vmPath)) "phase3b2_hyperv_vm_path_already_exists"

New-Item -ItemType Directory -Path (Split-Path -Parent $osDiskPath) -Force | Out-Null
$vm = New-VM `
    -Name $VmName `
    -Generation 2 `
    -Path $vmRootFullPath `
    -MemoryStartupBytes 8GB `
    -NewVHDPath $osDiskPath `
    -NewVHDSizeBytes 128GB `
    -SwitchName $switch.Name

Set-VM -VM $vm `
    -ProcessorCount 4 `
    -AutomaticCheckpointsEnabled $false `
    -AutomaticStartAction Nothing `
    -AutomaticStopAction ShutDown `
    -CheckpointType Standard
Set-VMMemory -VM $vm -DynamicMemoryEnabled $false -StartupBytes 8GB
Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
Set-VMKeyProtector -VM $vm -NewLocalKeyProtector
Enable-VMTPM -VM $vm

$dvd = Add-VMDvdDrive -VM $vm -Path $isoFullPath -Passthru
Set-VMFirmware -VM $vm -FirstBootDevice $dvd
$vm = Get-VM -Name $VmName -ErrorAction Stop

$summary = [ordered]@{
    contractId = "nll/phase3b2-hyperv-vm-shell/v1"
    vmName = $vm.Name
    generation = $vm.Generation
    processorCount = $vm.ProcessorCount
    memoryStartupBytes = $vm.MemoryStartup
    dynamicMemoryEnabled = $vm.DynamicMemoryEnabled
    automaticCheckpointsEnabled = $vm.AutomaticCheckpointsEnabled
    checkpointType = [string]$vm.CheckpointType
    osDiskLocationCode = "host_nvme_c_programdata"
    osDiskLogicalBytes = 128GB
    installationMediaLocationCode = "host_hdd_d_iso_only"
    installationMediaSha256 = $expectedIsoSha256.ToLowerInvariant()
    secureBootEnabled = (Get-VMFirmware -VM $vm).SecureBoot
    tpmEnabled = (Get-VMSecurity -VM $vm).TpmEnabled
    networkStage = "temporary_default_switch_for_os_setup_only"
    clientDiskAttached = $false
    gpuPartitionAttached = $false
    vmStarted = $false
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
}

$evidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence\VmShell"
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$receiptPath = Join-Path $evidenceRoot "vm-shell-receipt.json"
[System.IO.File]::WriteAllText(
    $receiptPath,
    ($summary | ConvertTo-Json -Depth 5),
    [System.Text.UTF8Encoding]::new($false)
)

$summary | ConvertTo-Json -Depth 5
