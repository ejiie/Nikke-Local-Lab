[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$MicronDrive = 'E:',
    [string]$SamsungProtectedRoot =
        'C:\Recovered_OldSSD\NLL_PreWipe_20260822\PhysicalOS\Micron-PrePhysicalLane-20260823\PhysicalP2\V2Deployment'
)

$ErrorActionPreference = 'Stop'
$backupCreated = $false
$mutationStarted = $false

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PathDigest {
    param([string]$Path, [long]$ByteLength, [string]$Sha256)
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $ByteLength -and
        (Get-Sha256Hex $Path) -ceq $Sha256
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

function Get-ManifestLines {
    param([string[]]$Paths, [string]$BasePath)
    $canonicalBase = [IO.Path]::GetFullPath($BasePath).TrimEnd('\') + '\'
    @($Paths | Sort-Object | ForEach-Object {
        $item = Get-Item -LiteralPath $_
        $canonicalPath = [IO.Path]::GetFullPath($item.FullName)
        Assert-True ($canonicalPath.StartsWith(
                $canonicalBase, [StringComparison]::OrdinalIgnoreCase)) `
            'phase3b2_p2_v2_operator_repair_manifest_member_outside_base'
        $relative = $canonicalPath.Substring($canonicalBase.Length).
            Replace('\', '/')
        "{0}`t{1}`t{2}" -f $relative, $item.Length,
            (Get-Sha256Hex $item.FullName)
    })
}

try {
    Assert-True ([Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) `
        'phase3b2_p2_v2_operator_repair_requires_administrator'
    $systemDisk = Get-Partition -DriveLetter C | Get-Disk
    $micronLetter = $MicronDrive.TrimEnd(':')
    $micronDisk = Get-Partition -DriveLetter $micronLetter | Get-Disk
    Assert-True ($systemDisk.FriendlyName -ceq 'Samsung SSD 980 1TB' -and
        $systemDisk.IsBoot -and $systemDisk.IsSystem -and
        $micronDisk.FriendlyName -ceq 'Micron_2200_MTFDHBA512TCK' -and
        -not $micronDisk.IsBoot -and -not $micronDisk.IsSystem) `
        'phase3b2_p2_v2_operator_repair_disk_boundary_invalid'

    $sourcePath = Join-Path $RepositoryRoot `
        'scripts\New-Phase3B2-Micron-Operator.ps1'
    $toolRoot = Join-Path $MicronDrive 'NLL\Tools'
    $targetPath = Join-Path $toolRoot 'New-Phase3B2-Micron-Operator.ps1'
    $transferRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\p2-tool-transfer-v2'
    $deploymentPath = Join-Path $transferRoot 'deployment.receipt.json'
    $manifestPath = Join-Path $MicronDrive `
        'NLL\Runtime\PhysicalBootstrap-v2\evidence\tools.manifest.tsv'
    $protectedDeploymentPath = Join-Path $SamsungProtectedRoot `
        'offline-deployment.receipt.json'
    $backupRoot = Join-Path $MicronDrive `
        'NLL\Backups\Phase3B2\PhysicalP2-v2-OperatorDescription-v1'
    $repairReceiptPath = Join-Path $transferRoot `
        'operator-description-repair.receipt.json'
    $protectedRepairPath = Join-Path $SamsungProtectedRoot `
        'operator-description-repair.receipt.json'
    $operatorEvidenceRoot = Join-Path $MicronDrive `
        'NLL\Evidence\Phase3B2\Physical\operator-profile-v1'

    Assert-True ((Test-PathDigest $targetPath 5805L `
            'ab237fa986a17d6c89e300a649f25b7a9ade502a80b344eb9246d9d5eaeabb02') -and
        (Test-PathDigest $deploymentPath 4829L `
            '19da48f181849adca919c196f01f4a7cf4e9946ab9e50623d7332a12f224dd22') -and
        (Test-PathDigest $protectedDeploymentPath 4829L `
            '19da48f181849adca919c196f01f4a7cf4e9946ab9e50623d7332a12f224dd22') -and
        (Test-PathDigest $manifestPath 799L `
            '5fb8879bc7097e7dd0a16473f66878978625e2ca63127f6fa170ab62c3d63c70')) `
        'phase3b2_p2_v2_operator_repair_baseline_invalid'
    Assert-True ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
        (Get-Content -LiteralPath $sourcePath -Raw) -cmatch
            "-Description 'NLL isolated physical client operator'" -and
        (Get-Content -LiteralPath $sourcePath -Raw) -cmatch
            'Get-Credential -UserName \$AccountName' -and
        -not (Test-Path -LiteralPath $backupRoot) -and
        -not (Test-Path -LiteralPath $repairReceiptPath) -and
        -not (Test-Path -LiteralPath $protectedRepairPath) -and
        -not (Test-Path -LiteralPath $operatorEvidenceRoot) -and
        @(Get-Process -Name EpinelPS, nikke, nikke_launcher,
            'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
            -ErrorAction SilentlyContinue).Count -eq 0) `
        'phase3b2_p2_v2_operator_repair_precondition_invalid'

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backupCreated = $true
    Copy-Item -LiteralPath $targetPath, $deploymentPath, $manifestPath,
        $protectedDeploymentPath -Destination $backupRoot
    $backupToolPath = Join-Path $backupRoot `
        'New-Phase3B2-Micron-Operator.ps1'
    $backupDeploymentPath = Join-Path $backupRoot 'deployment.receipt.json'
    $backupManifestPath = Join-Path $backupRoot 'tools.manifest.tsv'
    $backupProtectedPath = Join-Path $backupRoot `
        'offline-deployment.receipt.json'
    Assert-True ((Get-Sha256Hex $backupToolPath) -ceq
            (Get-Sha256Hex $targetPath) -and
        (Get-Sha256Hex $backupDeploymentPath) -ceq
            (Get-Sha256Hex $deploymentPath) -and
        (Get-Sha256Hex $backupManifestPath) -ceq
            (Get-Sha256Hex $manifestPath) -and
        (Get-Sha256Hex $backupProtectedPath) -ceq
            (Get-Sha256Hex $protectedDeploymentPath)) `
        'phase3b2_p2_v2_operator_repair_backup_failed'

    $mutationStarted = $true
    Copy-Item -LiteralPath $sourcePath -Destination $targetPath -Force
    $deployment = Get-Content -LiteralPath $deploymentPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($deployment.contractId -ceq
            'nll/phase3b2-physical-p2-v2-offline-deployment/v1' -and
        [int]$deployment.transferredToolCount -eq 7) `
        'phase3b2_p2_v2_operator_repair_deployment_invalid'
    $toolEntry = @($deployment.tools | Where-Object {
        $_.name -ceq 'New-Phase3B2-Micron-Operator.ps1'
    })
    Assert-True ($toolEntry.Count -eq 1 -and
        [string]$toolEntry[0].sha256 -ceq
            'ab237fa986a17d6c89e300a649f25b7a9ade502a80b344eb9246d9d5eaeabb02') `
        'phase3b2_p2_v2_operator_repair_tool_entry_invalid'
    $toolEntry[0].byteLength = (Get-Item $targetPath).Length
    $toolEntry[0].sha256 = Get-Sha256Hex $targetPath

    $toolPaths = @($deployment.tools | ForEach-Object {
        Join-Path $toolRoot ([string]$_.name)
    })
    Assert-True (@($toolPaths | Where-Object {
        -not (Test-Path -LiteralPath $_ -PathType Leaf)
    }).Count -eq 0) 'phase3b2_p2_v2_operator_repair_tool_shape_invalid'
    $manifestText = (Get-ManifestLines $toolPaths $toolRoot) -join "`n"
    Write-AtomicUtf8NoBom $manifestPath ($manifestText + "`n")
    $deployment.toolManifestByteLength = (Get-Item $manifestPath).Length
    $deployment.toolManifestSha256 = Get-Sha256Hex $manifestPath
    $deployment | Add-Member -NotePropertyName operatorDescriptionRepairApplied `
        -NotePropertyValue $true
    $deployment | Add-Member -NotePropertyName operatorDescriptionLength `
        -NotePropertyValue 37
    $deployment | Add-Member -NotePropertyName operatorDescriptionRepairAtUtc `
        -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'"))
    Write-AtomicUtf8NoBom $deploymentPath `
        (($deployment | ConvertTo-Json -Depth 9) + "`n")
    Copy-Item -LiteralPath $deploymentPath `
        -Destination $protectedDeploymentPath -Force

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase3b2-p2-v2-operator-description-repair/v1'
        repairedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failureCode = 'new_local_user_description_length_49_exceeded_48'
        credentialPromptUserNameCode = 'bare_local_account_name'
        replacementDescriptionLength = 37
        previousToolByteLength = 5805
        previousToolSha256 =
            'ab237fa986a17d6c89e300a649f25b7a9ade502a80b344eb9246d9d5eaeabb02'
        repairedToolByteLength = (Get-Item $targetPath).Length
        repairedToolSha256 = Get-Sha256Hex $targetPath
        previousDeploymentReceiptSha256 =
            '19da48f181849adca919c196f01f4a7cf4e9946ab9e50623d7332a12f224dd22'
        repairedDeploymentReceiptByteLength =
            (Get-Item $deploymentPath).Length
        repairedDeploymentReceiptSha256 = Get-Sha256Hex $deploymentPath
        repairedToolManifestByteLength = (Get-Item $manifestPath).Length
        repairedToolManifestSha256 = Get-Sha256Hex $manifestPath
        accountCreationReached = $false
        operatorProfileCreated = $false
        existingOperatorLocalLowReadPerformed = $false
        existingOperatorNikkeCacheMutationPerformed = $false
        serverExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = 'boot_micron_and_create_nlloperator_once'
    }
    Write-AtomicUtf8NoBom $repairReceiptPath `
        (($receipt | ConvertTo-Json -Depth 7) + "`n")
    Copy-Item -LiteralPath $repairReceiptPath -Destination $protectedRepairPath
    Assert-True ((Get-Sha256Hex $protectedRepairPath) -ceq
        (Get-Sha256Hex $repairReceiptPath)) `
        'phase3b2_p2_v2_operator_repair_protected_copy_failed'
    $receipt | ConvertTo-Json -Depth 8
}
catch {
    if ($mutationStarted -and $backupCreated) {
        Copy-Item -LiteralPath (Join-Path $backupRoot `
                'New-Phase3B2-Micron-Operator.ps1') `
            -Destination $targetPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $backupRoot `
                'deployment.receipt.json') `
            -Destination $deploymentPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $backupRoot `
                'tools.manifest.tsv') `
            -Destination $manifestPath -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath (Join-Path $backupRoot `
                'offline-deployment.receipt.json') `
            -Destination $protectedDeploymentPath -Force `
            -ErrorAction SilentlyContinue
    }
    throw
}
