[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCredential]$GuestCredential,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence",
    [string]$OutputRoot =
        "$env:LOCALAPPDATA\NikkeLocalLab\compatibility\evidence\phase3b2-wave1-hyperv\812c585b-2849-474f-a9ff-dfb59feaea87"
)

$ErrorActionPreference = "Stop"
$session = $null

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

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$managementAdapters = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $privateSwitch.SwitchType -eq [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0 -and
    $guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_password_receipt_extraction_isolation_mismatch"

$guestPath =
    "C:\Users\nlloperator\AppData\Local\NikkeLocalLab\Evidence\Phase3B2\Trusted\reference-failures\812c585b-2849-474f-a9ff-dfb59feaea87\password-representation-mismatch.receipt.json"
$outputPath = Join-Path $OutputRoot `
    "password-failure-v3.powershell-direct.json"
$temporaryPath = $outputPath + ".tmp"
$receiptPath = Join-Path $EvidenceRoot `
    "password-failure-receipt-extraction-v1.receipt.json"
Assert-True (-not (Test-Path -LiteralPath $outputPath) -and
    -not (Test-Path -LiteralPath $temporaryPath) -and
    -not (Test-Path -LiteralPath $receiptPath)) `
    "phase3b2_password_receipt_extraction_output_exists"
New-Item -ItemType Directory -Path $OutputRoot, $EvidenceRoot -Force | Out-Null

try {
    $session = New-PSSession -VMName $VMName -Credential $GuestCredential `
        -ErrorAction Stop
    $remoteObservation = Invoke-Command -Session $session -ScriptBlock {
        param([string]$Path)
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
            ConvertFrom-Json
        [pscustomobject]@{
            contractId = [string]$document.contractId
            assessmentUid = [string]$document.assessmentUid
            byteLength = [long]$item.Length
            sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
            clientExecutionStarted = [bool]$document.clientExecutionStarted
            officialIdentityPersisted = [bool]$document.officialIdentityPersisted
            officialCredentialPersisted = [bool]$document.officialCredentialPersisted
        }
    } -ArgumentList $guestPath
    Assert-True ($remoteObservation.contractId -ceq
            "nll/phase3b2-private-reference-run-failure/v3" -and
        $remoteObservation.assessmentUid -ceq
            "812c585b-2849-474f-a9ff-dfb59feaea87" -and
        [long]$remoteObservation.byteLength -gt 0 -and
        [string]$remoteObservation.sha256 -cmatch '^[0-9a-f]{64}$' -and
        -not [bool]$remoteObservation.clientExecutionStarted -and
        -not [bool]$remoteObservation.officialIdentityPersisted -and
        -not [bool]$remoteObservation.officialCredentialPersisted) `
        "phase3b2_password_receipt_extraction_remote_receipt_invalid"

    Copy-Item -FromSession $session -LiteralPath $guestPath `
        -Destination $temporaryPath
    Assert-True ((Get-Item -LiteralPath $temporaryPath).Length -eq
            [long]$remoteObservation.byteLength -and
        (Get-Sha256Hex $temporaryPath) -ceq
            [string]$remoteObservation.sha256) `
        "phase3b2_password_receipt_extraction_copy_drift"
    $localDocument = Get-Content -LiteralPath $temporaryPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($localDocument.contractId -ceq
            "nll/phase3b2-private-reference-run-failure/v3" -and
        $localDocument.assessmentUid -ceq
            "812c585b-2849-474f-a9ff-dfb59feaea87" -and
        -not [bool]$localDocument.retryPerformed -and
        -not [bool]$localDocument.clientExecutionStarted -and
        -not [bool]$localDocument.officialIdentityPersisted -and
        -not [bool]$localDocument.officialCredentialPersisted) `
        "phase3b2_password_receipt_extraction_local_receipt_invalid"
    Move-Item -LiteralPath $temporaryPath -Destination $outputPath
}
finally {
    if ($null -ne $session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

$receipt = [ordered]@{
    contractId = "nll/phase3b2-password-failure-receipt-extraction/v1"
    extractedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    transportCode = "hyperv_powershell_direct"
    sourceContractId = "nll/phase3b2-private-reference-run-failure/v3"
    assessmentUid = "812c585b-2849-474f-a9ff-dfb59feaea87"
    extractedByteLength = (Get-Item -LiteralPath $outputPath).Length
    extractedSha256 = Get-Sha256Hex $outputPath
    networkTransportUsed = $false
    guestOsCredentialPersisted = $false
    guestOsCredentialEmitted = $false
    guestServiceEnabled = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    clientExecutionStarted = $false
}
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"),
    [Text.UTF8Encoding]::new($false))
$receipt | ConvertTo-Json
