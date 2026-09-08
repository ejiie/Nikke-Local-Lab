[CmdletBinding()]
param(
    [string]$RepositoryRoot =
        'C:\Users\zih44\Documents\Github\Nikke-Local-Lab',
    [string]$MicronToolRoot = 'E:\NLL\Tools',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP0'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-AtomicUtf8NoBom {
    param([string]$Path, [string]$Text)
    $temporaryPath = $Path + '.tmp.' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, $Text,
            [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-DiskForDriveLetter {
    param([char]$DriveLetter)
    return (Get-Partition -DriveLetter $DriveLetter | Get-Disk)
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p0_transfer_administrator_required'
$bootDisk = Get-DiskForDriveLetter 'C'
$targetDisk = Get-DiskForDriveLetter 'E'
Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $targetDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $targetDisk.IsBoot -and -not $targetDisk.IsSystem) `
    'phase3b2_physical_p0_transfer_samsung_boot_required'
Assert-True ((Test-Path -LiteralPath $MicronToolRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $SamsungProtectedRoot)) `
    'phase3b2_physical_p0_transfer_destination_not_cold'

$members = @(
    [pscustomobject]@{
        RoleCode = 'physical_p0_apply'
        SourceName = 'prepare-phase3b2-physical-p0-in-micron.ps1'
        DestinationName = 'Prepare-Phase3B2-Physical-P0.ps1'
        Length = 32665L
        Sha256 = 'bd69c84df28dc6519c1bc717a95117c3943470d725fd5d2f5eb7776287b76c5e'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p0_post_apply_verification'
        SourceName = 'verify-phase3b2-physical-p0-in-micron.ps1'
        DestinationName = 'Verify-Phase3B2-Physical-P0.ps1'
        Length = 19059L
        Sha256 = '5ecb3cc57f2b035444853acf135e834f89ba53e49529b5f934a298d7e563ee04'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p0_rollback'
        SourceName = 'rollback-phase3b2-physical-p0-in-micron.ps1'
        DestinationName = 'Rollback-Phase3B2-Physical-P0.ps1'
        Length = 7822L
        Sha256 = 'b75f68d1b948e9ffed21b02b86d3af71c8c76379bab51b98111ab1d5e451a81c'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p0_workflow'
        SourceName = 'start-phase3b2-physical-p0-in-micron.ps1'
        DestinationName = 'Start-Phase3B2-Physical-P0.ps1'
        Length = 7285L
        Sha256 = 'cc115886fd743c2b80547128ed692cd711ec359b6fed9253e5714d3ef81a35ce'
    }
)

$temporaryRoot = Join-Path $MicronToolRoot (
    '.phase3b2-physical-p0-transfer-' + [Guid]::NewGuid().ToString('N'))
$micronToolRootFullPath = [IO.Path]::GetFullPath($MicronToolRoot).TrimEnd('\')
$temporaryRootFullPath = [IO.Path]::GetFullPath($temporaryRoot)
Assert-True ($temporaryRootFullPath.StartsWith(
        $micronToolRootFullPath + '\',
        [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $temporaryRootFullPath).StartsWith(
        '.phase3b2-physical-p0-transfer-',
        [StringComparison]::Ordinal)) `
    'phase3b2_physical_p0_transfer_temporary_path_invalid'
$createdDestinations = [Collections.Generic.List[string]]::new()
try {
    foreach ($member in $members) {
        $sourcePath = Join-Path (Join-Path $RepositoryRoot 'scripts') `
            $member.SourceName
        $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
        Assert-True ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            (Get-Item -LiteralPath $sourcePath).Length -eq $member.Length -and
            (Get-Sha256Hex $sourcePath) -ceq $member.Sha256 -and
            -not (Test-Path -LiteralPath $destinationPath)) `
            'phase3b2_physical_p0_transfer_source_or_destination_invalid'
    }

    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    foreach ($member in $members) {
        $sourcePath = Join-Path (Join-Path $RepositoryRoot 'scripts') `
            $member.SourceName
        $stagedPath = Join-Path $temporaryRoot $member.DestinationName
        Copy-Item -LiteralPath $sourcePath -Destination $stagedPath
        Assert-True ((Get-Item -LiteralPath $stagedPath).Length -eq $member.Length -and
            (Get-Sha256Hex $stagedPath) -ceq $member.Sha256) `
            'phase3b2_physical_p0_transfer_staging_verification_failed'
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $stagedPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True (@($parseErrors).Count -eq 0) `
            'phase3b2_physical_p0_transfer_script_parse_failed'
    }

    foreach ($member in $members) {
        $stagedPath = Join-Path $temporaryRoot $member.DestinationName
        $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
        Move-Item -LiteralPath $stagedPath -Destination $destinationPath
        $createdDestinations.Add($destinationPath)
    }
    Remove-Item -LiteralPath $temporaryRoot -Force

    foreach ($member in $members) {
        $destinationPath = Join-Path $MicronToolRoot $member.DestinationName
        Assert-True ((Get-Item -LiteralPath $destinationPath).Length -eq
                $member.Length -and
            (Get-Sha256Hex $destinationPath) -ceq $member.Sha256) `
            'phase3b2_physical_p0_transfer_final_verification_failed'
    }

    New-Item -ItemType Directory -Path $SamsungProtectedRoot | Out-Null
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p0-tool-transfer/v1'
        transferredAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        preparationBootDisk = 'Samsung SSD 980 1TB'
        targetOfflineDisk = 'Micron_2200_MTFDHBA512TCK'
        targetToolRootObserved = $MicronToolRoot
        targetToolRootAtMicronBoot = 'C:\NLL\Tools'
        transferredMemberCount = $members.Count
        members = @($members | ForEach-Object {
                [ordered]@{
                    roleCode = $_.RoleCode
                    destinationName = $_.DestinationName
                    byteLength = $_.Length
                    sha256 = $_.Sha256
                }
            })
        micronSystemModified = $false
        physicalClientCloneModified = $false
        primaryInstallModified = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'boot_micron_and_run_physical_p0_workflow_once'
    }
    $receiptPath = Join-Path $SamsungProtectedRoot `
        'physical-p0-tool-transfer.receipt.json'
    Write-AtomicUtf8NoBom $receiptPath (($receipt | ConvertTo-Json -Depth 8) + "`n")
    [pscustomobject]@{
        Receipt = $receipt
        ReceiptPath = $receiptPath
        ReceiptByteLength = (Get-Item -LiteralPath $receiptPath).Length
        ReceiptSha256 = Get-Sha256Hex $receiptPath
    } | ConvertTo-Json -Depth 10
}
catch {
    foreach ($destinationPath in $createdDestinations) {
        if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
            Remove-Item -LiteralPath $destinationPath -Force
        }
    }
    if (Test-Path -LiteralPath $temporaryRoot -PathType Container) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
    throw
}
