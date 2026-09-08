[CmdletBinding()]
param(
    [string]$SourceRoot = "D:\NikkeLocalLab\HyperV\Phase3B2",
    [string]$DestinationRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-AtomicUtf8 {
    param([string]$Path, [string]$Text)
    $temporary = $Path + ".tmp"
    [System.IO.File]::WriteAllText($temporary, $Text, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-Status {
    param([string]$StatusCode, [int]$ProgressPercent, [string]$DetailCode)
    $document = [ordered]@{
        schemaVersion = 1
        contractId = "nll/phase3b2-hyperv-client-base-ssd-copy/v1"
        statusCode = $StatusCode
        progressPercent = $ProgressPercent
        detailCode = $DetailCode
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    Write-AtomicUtf8 (Join-Path $evidenceRoot "status.json") ($document | ConvertTo-Json)
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
Assert-True ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) "phase3b2_hyperv_administrator_required"

$sourceFullPath = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd("\")
$destinationFullPath = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd("\")
Assert-True ($sourceFullPath -ceq "D:\NikkeLocalLab\HyperV\Phase3B2") "phase3b2_hyperv_ssd_source_root_mismatch"
Assert-True ($destinationFullPath -ceq "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2") "phase3b2_hyperv_ssd_target_root_mismatch"
Assert-True (-not (Test-Path -LiteralPath $destinationFullPath)) "phase3b2_hyperv_ssd_target_already_exists"

$sourceBase = Join-Path $sourceFullPath "Disks\NikkeClient-150.6.9-base.vhdx"
$sourceReceipt = Join-Path $sourceFullPath "Evidence\ClientBase\client-base-receipt.json"
Assert-True ((Test-Path -LiteralPath $sourceBase -PathType Leaf) -and
    (Test-Path -LiteralPath $sourceReceipt -PathType Leaf)) "phase3b2_hyperv_ssd_source_missing"
$sourceItem = Get-Item -LiteralPath $sourceBase
Assert-True ($sourceItem.IsReadOnly) "phase3b2_hyperv_ssd_source_base_not_readonly"
$sourceVhd = Get-VHD -Path $sourceBase
Assert-True (-not $sourceVhd.Attached -and $sourceVhd.VhdType -eq "Dynamic") "phase3b2_hyperv_ssd_source_base_state_mismatch"

$diskRoot = Join-Path $destinationFullPath "Disks"
$evidenceRoot = Join-Path $destinationFullPath "Evidence\ClientBase"
$destinationBase = Join-Path $diskRoot "NikkeClient-150.6.9-base.vhdx"
$destinationActive = Join-Path $diskRoot "NikkeClient-150.6.9-active.vhdx"
New-Item -ItemType Directory -Path $diskRoot, $evidenceRoot -Force | Out-Null

try {
    Write-Status "running" 10 "copying_sealed_base_vhdx_to_nvme"
    & robocopy.exe (Split-Path -Parent $sourceBase) $diskRoot (Split-Path -Leaf $sourceBase) /COPY:DAT /R:1 /W:1 /J /NFL /NDL /NJH /NJS /NP | Out-Null
    Assert-True ($LASTEXITCODE -ge 0 -and $LASTEXITCODE -le 7) "phase3b2_hyperv_ssd_base_copy_failed"

    Write-Status "running" 65 "verifying_base_vhdx_container_sha256"
    $sourceHash = (Get-FileHash -LiteralPath $sourceBase -Algorithm SHA256).Hash.ToLowerInvariant()
    $destinationHash = (Get-FileHash -LiteralPath $destinationBase -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-True ((Get-Item -LiteralPath $sourceBase).Length -eq (Get-Item -LiteralPath $destinationBase).Length -and
        $sourceHash -ceq $destinationHash) "phase3b2_hyperv_ssd_base_digest_mismatch"
    (Get-Item -LiteralPath $destinationBase).IsReadOnly = $true
    Copy-Item -LiteralPath $sourceReceipt -Destination (Join-Path $evidenceRoot "client-base-receipt.json") -Force

    Write-Status "running" 90 "creating_nvme_active_difference_disk"
    New-VHD -Path $destinationActive -ParentPath $destinationBase -Differencing | Out-Null
    $active = Get-VHD -Path $destinationActive
    Assert-True ($active.VhdType -eq "Differencing" -and
        $active.ParentPath -ceq $destinationBase -and -not $active.Attached) "phase3b2_hyperv_ssd_active_parent_mismatch"
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = "nll/phase3b2-hyperv-client-base-ssd-receipt/v1"
        sourceContainer = [ordered]@{ byteLength = (Get-Item -LiteralPath $sourceBase).Length; sha256 = $sourceHash }
        destinationContainer = [ordered]@{ byteLength = (Get-Item -LiteralPath $destinationBase).Length; sha256 = $destinationHash }
        containerMatched = $true
        destinationBaseReadOnly = (Get-Item -LiteralPath $destinationBase).IsReadOnly
        activeDifferenceDiskReady = $true
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    Write-AtomicUtf8 (Join-Path $evidenceRoot "ssd-copy-receipt.json") ($receipt | ConvertTo-Json -Depth 6)
    Write-Status "complete" 100 "nvme_client_base_and_active_difference_disk_ready"
}
catch {
    $failure = [ordered]@{
        schemaVersion = 1
        contractId = "nll/phase3b2-hyperv-client-base-ssd-failure/v1"
        exceptionType = $_.Exception.GetType().FullName
        message = $_.Exception.Message
        hresult = $_.Exception.HResult
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    }
    Write-AtomicUtf8 (Join-Path $evidenceRoot "failure.json") ($failure | ConvertTo-Json -Depth 4)
    Write-Status "blocked" 0 "nvme_client_base_preparation_failed"
    throw
}
