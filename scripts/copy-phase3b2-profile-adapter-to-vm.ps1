[CmdletBinding()]
param(
    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [Parameter(Mandatory = $true)]
    [string]$CredentialBearingSourcePath,
    [Parameter(Mandatory = $true)]
    [long]$ExpectedSourceByteLength,
    [Parameter(Mandatory = $true)]
    [ValidatePattern("^[0-9a-f]{64}$")]
    [string]$ExpectedSourceSha256
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

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
Assert-True (Test-Path -LiteralPath $CredentialBearingSourcePath -PathType Leaf) "credential_bearing_source_missing"
$source = Get-Item -LiteralPath $CredentialBearingSourcePath
Assert-True ($source.Length -eq $ExpectedSourceByteLength) "credential_bearing_source_length_mismatch"
Assert-True ((Get-Sha256Hex $source.FullName) -ceq $ExpectedSourceSha256) "credential_bearing_source_hash_mismatch"

$vm = Get-VM -Name $VMName -ErrorAction Stop
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) "phase3b2_vm_not_running"
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(
    Get-VMIntegrationService -VMName $VMName |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1) "guest_service_interface_shape_invalid"
if (-not $guestService[0].Enabled) {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$adapterRoot = Join-Path $repoRoot "tools\NikkeLocalLab.Phase3B2.ProfileAdapter"
$runnerPath = Join-Path $PSScriptRoot "invoke-phase3b2-hyperv-profile-adapter.ps1"
$updatePath = Join-Path $PSScriptRoot "update-phase3b2-epinelps-v2-in-vm.ps1"
$members = @(
    @{ Source = $source.FullName; Destination = "C:\NLL\Inputs\credential-bearing\source.json" },
    @{ Source = (Join-Path $adapterRoot "NikkeLocalLab.Phase3B2.ProfileAdapter.csproj"); Destination = "C:\NLL\Tools\ProfileAdapter\NikkeLocalLab.Phase3B2.ProfileAdapter.csproj" },
    @{ Source = (Join-Path $adapterRoot "Program.cs"); Destination = "C:\NLL\Tools\ProfileAdapter\Program.cs" },
    @{ Source = (Join-Path $adapterRoot "global.json"); Destination = "C:\NLL\Tools\ProfileAdapter\global.json" },
    @{ Source = (Join-Path $adapterRoot "NuGet.config"); Destination = "C:\NLL\Tools\ProfileAdapter\NuGet.config" },
    @{ Source = $runnerPath; Destination = "C:\NLL\Tools\invoke-phase3b2-hyperv-profile-adapter.ps1" },
    @{ Source = $updatePath; Destination = "C:\NLL\Tools\update-phase3b2-epinelps-v2-in-vm.ps1" }
)

try {
    foreach ($member in $members) {
        Assert-True (Test-Path -LiteralPath $member.Source -PathType Leaf) "phase3b2_transfer_member_missing"
        Copy-VMFile -VMName $VMName -SourcePath $member.Source -DestinationPath $member.Destination `
            -FileSource Host -CreateFullPath -Force
    }
}
finally {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name
}
$verifiedGuestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($verifiedGuestService.Count -eq 1 -and -not $verifiedGuestService[0].Enabled) `
    "guest_service_interface_disable_failed"

[pscustomobject]@{
    ContractId             = "nll/phase3b2-profile-adapter-transfer/v1"
    VMName                 = $VMName
    TransferredMemberCount = $members.Count
    GuestServiceEnabled    = $false
    ServerExecutionStarted = $false
    ClientExecutionStarted = $false
}
