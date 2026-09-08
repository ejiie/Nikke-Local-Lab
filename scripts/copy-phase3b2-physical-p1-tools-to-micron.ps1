[CmdletBinding()]
param(
    [string]$RepositoryRoot =
        'C:\Users\zih44\Documents\Github\Nikke-Local-Lab',
    [string]$MicronToolRoot = 'E:\NLL\Tools',
    [string]$MicronP0EvidenceRoot =
        'E:\NLL\Evidence\Phase3B2\Physical\p0-v1',
    [string]$MicronP1EvidenceRoot =
        'E:\NLL\Evidence\Phase3B2\Physical\p1-server-only-v1',
    [string]$SamsungP0ProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP0',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP1'
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

function Test-PathDigest {
    param([string]$Path, [long]$Length, [string]$Sha256)
    return ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $Length -and
        (Get-Sha256Hex $Path) -ceq $Sha256)
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    'phase3b2_physical_p1_transfer_administrator_required'
$bootDisk = Get-DiskForDriveLetter 'C'
$targetDisk = Get-DiskForDriveLetter 'E'
Assert-True ($bootDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
    $bootDisk.IsBoot -and $bootDisk.IsSystem -and
    $targetDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
    -not $targetDisk.IsBoot -and -not $targetDisk.IsSystem) `
    'phase3b2_physical_p1_transfer_samsung_boot_required'

$p0Pins = @(
    [pscustomobject]@{
        Path = (Join-Path $MicronP0EvidenceRoot 'applied-verification.receipt.json')
        Length = 2081L
        Sha256 = '833f98e28ba60af0abc90e4f53cf2dc9904e07ceee87f78545a73d55ec650a5e'
    },
    [pscustomobject]@{
        Path = (Join-Path $MicronP0EvidenceRoot 'post-apply-verification.receipt.json')
        Length = 1617L
        Sha256 = '3c966bbb23a19e9e8251172eddf498c7afe541bb13f50df64fd7d8e570a778c5'
    },
    [pscustomobject]@{
        Path = (Join-Path $MicronP0EvidenceRoot 'workflow.receipt.json')
        Length = 814L
        Sha256 = '879fe329353f477b8dec3e4216cd5d397f7a1de0c2284a301b86f19f8b52518d'
    },
    [pscustomobject]@{
        Path = (Join-Path (Join-Path $SamsungP0ProtectedRoot `
                '73f05d4f-b0e6-411d-b471-072b8ef3158b') 'workflow.receipt.json')
        Length = 814L
        Sha256 = '879fe329353f477b8dec3e4216cd5d397f7a1de0c2284a301b86f19f8b52518d'
    }
)
foreach ($pin in $p0Pins) {
    Assert-True (Test-PathDigest $pin.Path $pin.Length $pin.Sha256) `
        'phase3b2_physical_p1_transfer_p0_pin_mismatch'
}
$runtimePins = @(
    [pscustomobject]@{ Path = 'E:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\EpinelPS.exe'; Length = 162304L; Sha256 = '648876d076c6f7f5e73d33dc533cd089a36785318c33b923b277e550a975777f' },
    [pscustomobject]@{ Path = 'E:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64\db.json'; Length = 413327L; Sha256 = 'c103b44b7bc3dc4f1a317fd272253e2c8d827ca3ff174f07e0ecb6dfc298e194' },
    [pscustomobject]@{ Path = 'E:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\server-build.manifest.tsv'; Length = 63280L; Sha256 = '24032641b70072004948dd9e442b4751d70093d1012c74e7e512e2b79f9113c3' },
    [pscustomobject]@{ Path = 'E:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\synthetic-context.json'; Length = 279L; Sha256 = 'cc84781bc0df8d8705ac237f19763808e8925c7706de231b24470469ca446cc2' },
    [pscustomobject]@{ Path = 'E:\NLL\Evidence\Phase3B2\Physical\server-profile-v1\identity\offline-synthetic-profile.receipt.json'; Length = 1260L; Sha256 = 'bca519531ead1c3d360e28d5b1515acb48d6681a3162d2e5bff67884a1678701' },
    [pscustomobject]@{ Path = 'E:\NLL\Runtime\LocalBootstrap-v1\artifact\NikkeLocalLab.Phase3B2.LocalBootstrap.exe'; Length = 162816L; Sha256 = '4b6a8c844f291bdc956d0907f5898cb4b4fd54b0d95671ee1a75873867012773' },
    [pscustomobject]@{ Path = 'E:\NLL\Runtime\LocalBootstrap-v1\local-bootstrap-build.receipt.json'; Length = 1200L; Sha256 = '5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11' },
    [pscustomobject]@{ Path = 'E:\NLL\Runtime\LocalBootstrap-v1\evidence\artifact.manifest.tsv'; Length = 561L; Sha256 = 'b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70' }
)
foreach ($pin in $runtimePins) {
    Assert-True (Test-PathDigest $pin.Path $pin.Length $pin.Sha256) `
        'phase3b2_physical_p1_transfer_runtime_pin_mismatch'
}
Assert-True ((Test-Path -LiteralPath $MicronToolRoot -PathType Container) -and
    -not (Test-Path -LiteralPath $MicronP1EvidenceRoot) -and
    -not (Test-Path -LiteralPath $SamsungProtectedRoot)) `
    'phase3b2_physical_p1_transfer_destination_not_cold'

$members = @(
    [pscustomobject]@{
        RoleCode = 'physical_p1_server_only_measurement'
        SourceName = 'measure-phase3b2-physical-p1-server-in-micron.ps1'
        DestinationName = 'Measure-Phase3B2-Physical-P1.ps1'
        Length = 44496L
        Sha256 = 'e77ef0de066c1bb5c78641546aa3b95153e5a2488c493f3a1c89f045843ce6bd'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p1_post_measurement_verification'
        SourceName = 'verify-phase3b2-physical-p1-in-micron.ps1'
        DestinationName = 'Verify-Phase3B2-Physical-P1.ps1'
        Length = 26046L
        Sha256 = '38076797f0331d6d1212bee4d3dc8c052fb7ed0c8aac404c83d8887f88c84d1e'
    },
    [pscustomobject]@{
        RoleCode = 'physical_p1_workflow'
        SourceName = 'start-phase3b2-physical-p1-in-micron.ps1'
        DestinationName = 'Start-Phase3B2-Physical-P1.ps1'
        Length = 7966L
        Sha256 = '042a7add5c74b3890e540dab9731c08c1286972458249270618a21a0872d5981'
    }
)

$temporaryRoot = Join-Path $MicronToolRoot (
    '.phase3b2-physical-p1-transfer-' + [Guid]::NewGuid().ToString('N'))
$micronToolRootFullPath = [IO.Path]::GetFullPath($MicronToolRoot).TrimEnd('\')
$temporaryRootFullPath = [IO.Path]::GetFullPath($temporaryRoot)
Assert-True ($temporaryRootFullPath.StartsWith(
        $micronToolRootFullPath + '\',
        [StringComparison]::OrdinalIgnoreCase) -and
    (Split-Path -Leaf $temporaryRootFullPath).StartsWith(
        '.phase3b2-physical-p1-transfer-',
        [StringComparison]::Ordinal)) `
    'phase3b2_physical_p1_transfer_temporary_path_invalid'
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
            'phase3b2_physical_p1_transfer_source_or_destination_invalid'
    }

    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    foreach ($member in $members) {
        $sourcePath = Join-Path (Join-Path $RepositoryRoot 'scripts') `
            $member.SourceName
        $stagedPath = Join-Path $temporaryRoot $member.DestinationName
        Copy-Item -LiteralPath $sourcePath -Destination $stagedPath
        Assert-True ((Get-Item -LiteralPath $stagedPath).Length -eq $member.Length -and
            (Get-Sha256Hex $stagedPath) -ceq $member.Sha256) `
            'phase3b2_physical_p1_transfer_staging_verification_failed'
        $tokens = $null
        $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile(
            $stagedPath, [ref]$tokens, [ref]$parseErrors)
        Assert-True (@($parseErrors).Count -eq 0) `
            'phase3b2_physical_p1_transfer_script_parse_failed'
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
            'phase3b2_physical_p1_transfer_final_verification_failed'
    }

    New-Item -ItemType Directory -Path $SamsungProtectedRoot | Out-Null
    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-physical-p1-tool-transfer/v1'
        transferredAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        preparationBootDisk = 'Samsung SSD 980 1TB'
        targetOfflineDisk = 'Micron_2200_MTFDHBA512TCK'
        p0AssessmentUid = '73f05d4f-b0e6-411d-b471-072b8ef3158b'
        p0WorkflowReceiptSha256 =
            '879fe329353f477b8dec3e4216cd5d397f7a1de0c2284a301b86f19f8b52518d'
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
        physicalP0StateModified = $false
        physicalClientCloneModified = $false
        primaryInstallModified = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'boot_micron_and_run_physical_p1_server_only_once'
    }
    $receiptPath = Join-Path $SamsungProtectedRoot `
        'physical-p1-tool-transfer.receipt.json'
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
