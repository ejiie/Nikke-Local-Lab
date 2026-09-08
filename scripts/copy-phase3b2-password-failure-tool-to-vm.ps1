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

$source = Join-Path $PSScriptRoot "seal-phase3b2-private-password-failure-in-vm.ps1"
$destination = "C:\NLL\Tools\seal-phase3b2-private-password-failure-in-vm.ps1"
$receiptPath = Join-Path $EvidenceRoot "password-failure-tool-transfer-v2.receipt.json"
Assert-True (Test-Path -LiteralPath $source -PathType Leaf) `
    "phase3b2_password_failure_transfer_source_missing"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_password_failure_transfer_receipt_exists"

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
    $managementAdapters.Count -eq 0) "phase3b2_password_failure_transfer_isolation_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_password_failure_transfer_guest_service_precondition_mismatch"

try {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
    $copied = $false
    $copyFailure = $null
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        try {
            Copy-VMFile -VM $vm -SourcePath $source -DestinationPath $destination `
                -FileSource Host -CreateFullPath -Force
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
finally {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name `
        -ErrorAction SilentlyContinue
}

$guestServiceAfter = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_password_failure_transfer_guest_service_postcondition_failed"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-password-failure-tool-transfer/v2"
    transferredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    sourceByteLength = (Get-Item -LiteralPath $source).Length
    sourceSha256 = Get-Sha256Hex $source
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    vmRunning = $true
    guestServiceEnabled = $false
    runtimeExecutionStateCode = "server_stopped_launcher_running_client_cold"
    clientExecutionStarted = $false
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
