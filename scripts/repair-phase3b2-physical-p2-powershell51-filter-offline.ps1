[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2'
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath, $Text, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

Assert-True ((Get-Partition -DriveLetter C | Get-Disk).FriendlyName -ceq
    'Samsung SSD 980 1TB') `
    'phase3b2_physical_p2_filter_repair_must_run_from_samsung'
$micronLetter = $MicronDrive.TrimEnd(':')
$micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
Assert-True ($micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
    'phase3b2_physical_p2_filter_repair_offline_micron_not_verified'

$sourceTool = Join-Path $RepositoryRoot `
    'scripts\prepare-phase3b2-physical-p2-in-micron.ps1'
$destinationTool = Join-Path $MicronDrive `
    'NLL\Tools\prepare-phase3b2-physical-p2-in-micron.ps1'
$transferRoot = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v1'
$receiptPath = Join-Path $transferRoot 'deployment.receipt.json'
$priorReceiptPath = Join-Path $transferRoot `
    'deployment.before-powershell51-filter-fix.receipt.json'
$repairReceiptPath = Join-Path $transferRoot `
    'powershell51-filter-fix.receipt.json'
$preparationEvidence = Join-Path $MicronDrive `
    'NLL\Evidence\Phase3B2\Physical\p2-preparation-v1'
$protectedReceiptPath = Join-Path $SamsungProtectedRoot `
    'offline-deployment.receipt.json'
$protectedPriorReceiptPath = Join-Path $SamsungProtectedRoot `
    'offline-deployment.before-powershell51-filter-fix.receipt.json'
$protectedRepairReceiptPath = Join-Path $SamsungProtectedRoot `
    'powershell51-filter-fix.receipt.json'
$protectedFailureReceiptPath = Join-Path $SamsungProtectedRoot `
    'powershell51-root-ca-filter-failure.receipt.json'

foreach ($path in @($sourceTool, $destinationTool, $receiptPath,
        $protectedReceiptPath)) {
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) `
        'phase3b2_physical_p2_filter_repair_input_missing'
}
Assert-True (-not (Test-Path -LiteralPath $preparationEvidence) -and
    -not (Test-Path -LiteralPath $priorReceiptPath) -and
    -not (Test-Path -LiteralPath $repairReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedPriorReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedRepairReceiptPath) -and
    -not (Test-Path -LiteralPath $protectedFailureReceiptPath)) `
    'phase3b2_physical_p2_filter_repair_destination_not_cold'
Assert-True ((Get-Item $receiptPath).Length -eq 2582L -and
    (Get-Sha256Hex $receiptPath) -ceq
        '8429e57bc2d62550627a76e40c53cb30bdf7cf4fe8913fca8acda7f05a29cbfa' -and
    (Get-Sha256Hex $protectedReceiptPath) -ceq
        '8429e57bc2d62550627a76e40c53cb30bdf7cf4fe8913fca8acda7f05a29cbfa' -and
    (Get-Item $destinationTool).Length -eq 14580L -and
    (Get-Sha256Hex $destinationTool) -ceq
        '9690ac3fb231ede66e68ca15dc59f98c2995c850839029a7e856dafb2e26b095') `
    'phase3b2_physical_p2_filter_repair_prior_pin_mismatch'

$tokens = $null
$errors = $null
[Management.Automation.Language.Parser]::ParseFile(
    $sourceTool, [ref]$tokens, [ref]$errors) | Out-Null
Assert-True (@($errors).Count -eq 0) `
    'phase3b2_physical_p2_filter_repair_source_parse_failed'
Assert-True (@(Select-String -LiteralPath $sourceTool -SimpleMatch `
        'Where-Object Thumbprint -CEQ').Count -eq 0 -and
    @(Select-String -LiteralPath $sourceTool -SimpleMatch `
        '$_.Thumbprint -ceq $certificate.Thumbprint').Count -eq 1) `
    'phase3b2_physical_p2_filter_repair_source_shape_invalid'

Copy-Item -LiteralPath $receiptPath -Destination $priorReceiptPath
Copy-Item -LiteralPath $protectedReceiptPath `
    -Destination $protectedPriorReceiptPath
Copy-Item -LiteralPath $sourceTool -Destination $destinationTool -Force
Assert-True ((Get-Sha256Hex $destinationTool) -ceq
    (Get-Sha256Hex $sourceTool)) `
    'phase3b2_physical_p2_filter_repair_tool_copy_failed'

$receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$toolMember = @($receipt.tools | Where-Object {
    $_.name -ceq 'prepare-phase3b2-physical-p2-in-micron.ps1'
})
Assert-True ($toolMember.Count -eq 1 -and
    [string]$receipt.contractId -ceq
        'nll/phase3b2-physical-p2-offline-deployment/v1') `
    'phase3b2_physical_p2_filter_repair_receipt_shape_invalid'
$toolMember[0].byteLength = (Get-Item $destinationTool).Length
$toolMember[0].sha256 = Get-Sha256Hex $destinationTool
$receipt | Add-Member -NotePropertyName revisionCode `
    -NotePropertyValue 'powershell51_root_ca_filter_scriptblock_fix' -Force
$receipt | Add-Member -NotePropertyName priorDeploymentReceiptByteLength `
    -NotePropertyValue 2582 -Force
$receipt | Add-Member -NotePropertyName priorDeploymentReceiptSha256 `
    -NotePropertyValue `
        '8429e57bc2d62550627a76e40c53cb30bdf7cf4fe8913fca8acda7f05a29cbfa' `
    -Force
$receipt.deployedAtUtc =
    [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
Write-AtomicUtf8NoBom $receiptPath `
    (($receipt | ConvertTo-Json -Depth 9) + "`n")
Copy-Item -LiteralPath $receiptPath -Destination $protectedReceiptPath -Force
Assert-True ((Get-Sha256Hex $protectedReceiptPath) -ceq
    (Get-Sha256Hex $receiptPath)) `
    'phase3b2_physical_p2_filter_repair_receipt_copy_failed'

$failureReceipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-preparation-failure/v1'
    recordedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    failedStageCode = 'root_ca_preflight'
    reasonCode = 'powershell51_where_object_value_linebreak'
    preparationEvidenceCreated = $false
    extensionFirewallRuleApplied = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    retryPerformed = $false
}
Write-AtomicUtf8NoBom $protectedFailureReceiptPath `
    (($failureReceipt | ConvertTo-Json -Depth 6) + "`n")

$repairReceipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase3b2-physical-p2-powershell51-filter-fix/v1'
    repairedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    priorDeploymentReceiptByteLength = 2582
    priorDeploymentReceiptSha256 =
        '8429e57bc2d62550627a76e40c53cb30bdf7cf4fe8913fca8acda7f05a29cbfa'
    repairedToolByteLength = (Get-Item $destinationTool).Length
    repairedToolSha256 = Get-Sha256Hex $destinationTool
    currentDeploymentReceiptByteLength = (Get-Item $receiptPath).Length
    currentDeploymentReceiptSha256 = Get-Sha256Hex $receiptPath
    priorPreparationFailureReceiptByteLength =
        (Get-Item $protectedFailureReceiptPath).Length
    priorPreparationFailureReceiptSha256 =
        Get-Sha256Hex $protectedFailureReceiptPath
    preparationEvidenceCreated = $false
    extensionFirewallRuleApplied = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
    nextStepCode = 'boot_micron_and_retry_physical_p2_once'
}
Write-AtomicUtf8NoBom $repairReceiptPath `
    (($repairReceipt | ConvertTo-Json -Depth 7) + "`n")
Copy-Item -LiteralPath $repairReceiptPath `
    -Destination $protectedRepairReceiptPath
Assert-True ((Get-Sha256Hex $protectedRepairReceiptPath) -ceq
    (Get-Sha256Hex $repairReceiptPath)) `
    'phase3b2_physical_p2_filter_repair_protected_copy_failed'

[pscustomobject]@{
    Receipt = $repairReceipt
    CurrentDeploymentReceiptPath = $receiptPath
    CurrentDeploymentReceiptByteLength = (Get-Item $receiptPath).Length
    CurrentDeploymentReceiptSha256 = Get-Sha256Hex $receiptPath
} | ConvertTo-Json -Depth 9
