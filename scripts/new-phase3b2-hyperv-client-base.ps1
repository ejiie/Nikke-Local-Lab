[CmdletBinding()]
param(
    [string]$SourceRoot = "C:\NIKKE",
    [string]$SourceManifestPath = "C:\Users\ccccc\AppData\Local\NikkeLocalLab\compatibility\evidence\phase3b2-wave1\assessment-74fedafe-55bc-4446-a2f0-01d5cc62eb3e\trusted\primary-before.manifest.tsv",
    [string]$HyperVRoot = "D:\NikkeLocalLab\HyperV\Phase3B2"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $digest = [System.Security.Cryptography.SHA256]::Create().ComputeHash($Bytes)
    return ([BitConverter]::ToString($digest) -replace "-", "").ToLowerInvariant()
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
        contractId = "nll/phase3b2-hyperv-client-base-preparation/v1"
        statusCode = $StatusCode
        progressPercent = $ProgressPercent
        detailCode = $DetailCode
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    Write-AtomicUtf8 (Join-Path $evidenceRoot "status.json") ($document | ConvertTo-Json)
}

function New-CanonicalFileManifest {
    param([string]$Root, [string]$OutputPath)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($path in [System.IO.Directory]::EnumerateFiles($rootFull, "*", [System.IO.SearchOption]::AllDirectories)) {
        $paths.Add($path)
    }
    $paths.Sort([System.StringComparer]::Ordinal)
    $builder = [System.Text.StringBuilder]::new()
    foreach ($path in $paths) {
        $relative = $path.Substring($rootFull.Length + 1).Replace("\", "/")
        $item = [System.IO.FileInfo]::new($path)
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $null = $builder.Append($relative).Append("`t").Append($item.Length).Append("`t").Append($hash).Append("`n")
    }
    Write-AtomicUtf8 $OutputPath $builder.ToString()
    $bytes = [System.IO.File]::ReadAllBytes($OutputPath)
    return [ordered]@{
        fileCount = $paths.Count
        byteLength = $bytes.Length
        sha256 = Get-Sha256Hex $bytes
    }
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
Assert-True ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) "phase3b2_hyperv_administrator_required"

$sourceFullPath = [System.IO.Path]::GetFullPath($SourceRoot).TrimEnd("\")
$sourceManifestFullPath = [System.IO.Path]::GetFullPath($SourceManifestPath)
$hyperVFullPath = [System.IO.Path]::GetFullPath($HyperVRoot).TrimEnd("\")
Assert-True ($sourceFullPath -ceq "C:\NIKKE") "phase3b2_hyperv_source_root_mismatch"
Assert-True ($hyperVFullPath -ceq "D:\NikkeLocalLab\HyperV\Phase3B2") "phase3b2_hyperv_target_root_mismatch"
Assert-True ((Test-Path -LiteralPath $sourceFullPath -PathType Container) -and
    (Test-Path -LiteralPath $sourceManifestFullPath -PathType Leaf)) "phase3b2_hyperv_source_missing"
Assert-True (-not (Test-Path -LiteralPath $hyperVFullPath)) "phase3b2_hyperv_target_already_exists"

$diskRoot = Join-Path $hyperVFullPath "Disks"
$mountRoot = Join-Path $hyperVFullPath "Mount\ClientBase"
$evidenceRoot = Join-Path $hyperVFullPath "Evidence\ClientBase"
$baseVhdPath = Join-Path $diskRoot "NikkeClient-150.6.9-base.vhdx"
$activeVhdPath = Join-Path $diskRoot "NikkeClient-150.6.9-active.vhdx"
New-Item -ItemType Directory -Path $diskRoot, $mountRoot, $evidenceRoot -Force | Out-Null

$mounted = $false
try {
    Write-Status "running" 5 "creating_base_vhdx"
    New-VHD -Path $baseVhdPath -Dynamic -SizeBytes 80GB -BlockSizeBytes 2MB | Out-Null
    $mountedDisk = Mount-VHD -Path $baseVhdPath -Passthru
    $mounted = $true
    $disk = $mountedDisk | Get-Disk
    Assert-True ($disk.PartitionStyle -eq "RAW") "phase3b2_hyperv_base_disk_not_raw"
    $disk = $disk | Initialize-Disk -PartitionStyle GPT -PassThru
    $partition = $disk | New-Partition -UseMaximumSize
    $null = $partition | Format-Volume -FileSystem NTFS -NewFileSystemLabel "NLL_CLIENT_150_6_9" -Confirm:$false
    Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath $mountRoot

    Write-Status "running" 25 "copying_primary_to_base_vhdx"
    & robocopy.exe $sourceFullPath $mountRoot /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /MT:16 /NFL /NDL /NJH /NJS /NP | Out-Null
    Assert-True ($LASTEXITCODE -ge 0 -and $LASTEXITCODE -le 7) "phase3b2_hyperv_client_copy_failed"

    Write-Status "running" 60 "hashing_base_vhdx_client_manifest"
    $destinationManifestPath = Join-Path $evidenceRoot "client-base.manifest.tsv"
    $destinationManifest = New-CanonicalFileManifest $mountRoot $destinationManifestPath
    $sourceManifestBytes = [System.IO.File]::ReadAllBytes($sourceManifestFullPath)
    $destinationManifestBytes = [System.IO.File]::ReadAllBytes($destinationManifestPath)
    $sourceManifestSha256 = Get-Sha256Hex $sourceManifestBytes
    Assert-True ($sourceManifestBytes.Length -eq $destinationManifestBytes.Length -and
        $sourceManifestSha256 -ceq $destinationManifest.sha256) "phase3b2_hyperv_client_manifest_mismatch"

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = "nll/phase3b2-hyperv-client-base-receipt/v1"
        targetClientBuild = "150.6.9"
        sourceManifest = [ordered]@{
            byteLength = $sourceManifestBytes.Length
            sha256 = $sourceManifestSha256
        }
        baseManifest = $destinationManifest
        manifestMatched = $true
        baseLogicalSizeBytes = 80GB
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    Write-AtomicUtf8 (Join-Path $evidenceRoot "client-base-receipt.json") ($receipt | ConvertTo-Json -Depth 8)

    Write-Status "running" 90 "sealing_base_and_creating_active_difference_disk"
    Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber -AccessPath $mountRoot
    Dismount-VHD -Path $baseVhdPath
    $mounted = $false
    (Get-Item -LiteralPath $baseVhdPath).IsReadOnly = $true
    New-VHD -Path $activeVhdPath -ParentPath $baseVhdPath -Differencing | Out-Null
    Write-Status "complete" 100 "client_base_sealed_active_difference_disk_ready"
}
catch {
    $failure = [ordered]@{
        schemaVersion = 1
        contractId = "nll/phase3b2-hyperv-client-base-failure/v1"
        exceptionType = $_.Exception.GetType().FullName
        message = $_.Exception.Message
        hresult = $_.Exception.HResult
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    }
    Write-AtomicUtf8 (Join-Path $evidenceRoot "failure.json") ($failure | ConvertTo-Json -Depth 4)
    Write-Status "blocked" 0 "client_base_preparation_failed"
    throw
}
finally {
    if ($mounted) {
        Dismount-VHD -Path $baseVhdPath -ErrorAction SilentlyContinue
    }
}
