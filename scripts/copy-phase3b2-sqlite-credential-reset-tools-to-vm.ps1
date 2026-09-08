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

$restorePath = Join-Path $EvidenceRoot `
    "private-sqlite-failure-restore-v1.receipt.json"
$receiptPath = Join-Path $EvidenceRoot `
    "sqlite-credential-reset-tool-transfer-v1.receipt.json"
Assert-True ((Get-Item -LiteralPath $restorePath).Length -eq 1306 -and
    (Get-Sha256Hex $restorePath) -ceq
        "73f961a4d70e4f459be46d6769e8ba539dd7cfbbada83698e84e618d027b3d59") `
    "phase3b2_sqlite_reset_transfer_restore_receipt_drift"
Assert-True (-not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_sqlite_reset_transfer_receipt_exists"
$restore = Get-Content -LiteralPath $restorePath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($restore.contractId -ceq
        "nll/phase3b2-private-sqlite-failure-restore/v1" -and
    $restore.failedAssessmentUid -ceq
        "8c2281d7-c3da-4e74-bb54-09758695fc99" -and
    $restore.restoredCheckpointIdentitySha256 -ceq
        "80f2b7b9562220ac88a76a8f6135069eeb095017a4491713475ffa1c264287a2" -and
    -not [bool]$restore.sqliteCredentialBindingRepaired -and
    -not [bool]$restore.serverExecutionStarted -and
    -not [bool]$restore.clientExecutionStarted) `
    "phase3b2_sqlite_reset_transfer_restore_receipt_invalid"

$members = @(
    [ordered]@{
        roleCode = "sqlite_reset_preparation"
        source = Join-Path $PSScriptRoot `
            "prepare-phase3b2-sqlite-credential-reset-in-vm.ps1"
        destination =
            "C:\NLL\Tools\prepare-phase3b2-sqlite-credential-reset-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "sqlite_reset_rollback"
        source = Join-Path $PSScriptRoot `
            "rollback-phase3b2-sqlite-credential-reset-in-vm.ps1"
        destination =
            "C:\NLL\Tools\rollback-phase3b2-sqlite-credential-reset-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "sqlite_reset_full_composite_rollback"
        source = Join-Path $PSScriptRoot `
            "rollback-phase3b2-p0-with-launcher-ca-credential-and-sqlite-reset-in-vm.ps1"
        destination =
            "C:\NLL\Tools\rollback-phase3b2-p0-with-launcher-ca-credential-and-sqlite-reset-in-vm.ps1"
    },
    [ordered]@{
        roleCode = "sqlite_reset_p0_verification"
        source = Join-Path $PSScriptRoot `
            "verify-phase3b2-p0-sqlite-reset-applied-in-vm.ps1"
        destination =
            "C:\NLL\Tools\verify-phase3b2-p0-sqlite-reset-applied-in-vm.ps1"
    }
)
foreach ($member in $members) {
    Assert-True (Test-Path -LiteralPath $member.source -PathType Leaf) `
        "phase3b2_sqlite_reset_transfer_source_missing"
}

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
    $managementAdapters.Count -eq 0) "phase3b2_sqlite_reset_transfer_isolation_mismatch"

$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_sqlite_reset_transfer_guest_service_precondition_mismatch"
try {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
    foreach ($member in $members) {
        $copied = $false
        $copyFailure = $null
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            try {
                Copy-VMFile -VM $vm -SourcePath $member.source `
                    -DestinationPath $member.destination -FileSource Host `
                    -CreateFullPath -Force
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
}
finally {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name `
        -ErrorAction SilentlyContinue
}

$guestServiceAfter = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_sqlite_reset_transfer_guest_service_postcondition_failed"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-sqlite-credential-reset-tool-transfer/v1"
    transferredAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    restoredFailureReceiptByteLength = 1306
    restoredFailureReceiptSha256 =
        "73f961a4d70e4f459be46d6769e8ba539dd7cfbbada83698e84e618d027b3d59"
    transferredMemberCount = $members.Count
    members = @($members | ForEach-Object {
            [ordered]@{
                roleCode = $_.roleCode
                byteLength = (Get-Item -LiteralPath $_.source).Length
                sha256 = Get-Sha256Hex $_.source
            }
        })
    networkModeCode = "private_vm_only_no_gateway"
    switchTypeCode = "private_vm_only"
    connectedVmAdapterCount = 1
    vmRunning = $true
    guestServiceEnabled = $false
    runtimeExecutionStateCode = "restored_launcher_credential_p0_client_cold"
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($receiptPath,
    (($receipt | ConvertTo-Json -Depth 5) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json -Depth 5
