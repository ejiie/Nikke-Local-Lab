[CmdletBinding()]
param(
    [string]$MaterializerPath = (Join-Path $PSScriptRoot 'materialize-samsung-project-state-on-micron.ps1')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Verify {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Write-Utf8Json {
    param([string]$Path, $Value)
    Write-Utf8File $Path (($Value | ConvertTo-Json -Depth 8) + "`n")
}

Assert-Verify (Test-Path -LiteralPath $MaterializerPath -PathType Leaf) `
    'samsung_to_micron_tool_verification_materializer_missing'

$driveLetter = @('Z', 'Y', 'X', 'W') | Where-Object {
    -not (Test-Path -LiteralPath ($_ + ':\'))
} | Select-Object -First 1
Assert-Verify (-not [string]::IsNullOrWhiteSpace($driveLetter)) `
    'samsung_to_micron_tool_verification_no_test_drive_available'

$temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$temporaryRoot = Join-Path $temporaryParent ('NLL-Materializer-Test-' + [guid]::NewGuid().ToString('N'))
$testDrive = $driveLetter + ':'
$driveRoot = $testDrive + '\'
$migrationUid = '00000000-0000-0000-0000-000000000001'
$substCreated = $false

try {
    [IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
    & "$env:SystemRoot\System32\subst.exe" $testDrive $temporaryRoot
    Assert-Verify ($LASTEXITCODE -eq 0) 'samsung_to_micron_tool_verification_subst_failed'
    $substCreated = $true
    Assert-Verify (Test-Path -LiteralPath $driveRoot -PathType Container) `
        'samsung_to_micron_tool_verification_test_drive_missing'

    foreach ($directory in @(
        (Join-Path $driveRoot 'Windows\System32'),
        (Join-Path $driveRoot 'Users\nlloperator\Desktop'),
        (Join-Path $driveRoot 'Users\zih44'),
        (Join-Path $driveRoot 'Recovered_OldSSD'),
        (Join-Path $driveRoot "NLL\Migrations\SamsungToMicron\v1\$migrationUid\Protected\NLL_PreWipe_20260822")
    )) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    $migrationRoot = Join-Path $driveRoot "NLL\Migrations\SamsungToMicron\v1\$migrationUid"
    $manifestRows = New-Object System.Collections.Generic.List[string]
    $fixtureMembers = @(
        [pscustomobject]@{ role='github_workspaces'; relative='Nikke-Local-Lab/repo.txt'; path='Operational\Github\Nikke-Local-Lab\repo.txt'; content='repo' },
        [pscustomobject]@{ role='codex_home'; relative='state.txt'; path='Codex\CODEX_HOME\state.txt'; content='codex-home' },
        [pscustomobject]@{ role='codex_documents'; relative='notes.txt'; path='Codex\DocumentsCodex\notes.txt'; content='documents-codex' },
        [pscustomobject]@{ role='openai_local'; relative='state.txt'; path='Codex\AppDataLocalOpenAI\state.txt'; content='openai-local' },
        [pscustomobject]@{ role='powershell_history'; relative='ConsoleHost_history.txt'; path='Sensitive\DeveloperProfile\PowerShell\PSReadLine\ConsoleHost_history.txt'; content='history' },
        [pscustomobject]@{ role='desktop_auxiliary'; relative='readme.txt'; path='AuxiliaryProfile\Desktop\readme.txt'; content='desktop' },
        [pscustomobject]@{ role='nuget_profile'; relative='NuGet.Config'; path='Sensitive\DeveloperProfile\NuGet\NuGet.Config'; content='<configuration />' }
    )
    foreach ($member in $fixtureMembers) {
        $path = Join-Path $migrationRoot $member.path
        Write-Utf8File $path $member.content
        $item = Get-Item -LiteralPath $path
        $sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifestRows.Add(($member.role + "`t" + $member.relative + "`t" + $item.Length + "`t" + $sha256))
    }

    foreach ($directFile in @(
        [pscustomobject]@{ path='RawInputs\nikke_full_scroll_result.json'; content='{}' },
        [pscustomobject]@{ path='RawInputs\getFromBlaLink.py'; content='pass' },
        [pscustomobject]@{ path='SwitchTools\NLL-Switch-To-Micron.cmd'; content='@echo off' },
        [pscustomobject]@{ path='SwitchTools\NLL-Switch-To-Micron.ps1'; content='Write-Output ok' }
    )) {
        Write-Utf8File (Join-Path $migrationRoot $directFile.path) $directFile.content
    }

    $activeManifestPath = Join-Path $migrationRoot 'final-active-content.manifest.tsv'
    Write-Utf8File $activeManifestPath (($manifestRows -join "`n") + "`n")
    $activeManifestSha256 = (Get-FileHash -LiteralPath $activeManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $stableReceiptPath = Join-Path $migrationRoot 'stable-content.verification.receipt.json'
    Write-Utf8Json $stableReceiptPath ([ordered]@{
        contractId = 'nll/samsung-project-state-to-micron-stable-content-verification/v1'
        migrationUid = $migrationUid
        allStableMembersSha256Verified = $true
    })
    $stableReceiptSha256 = (Get-FileHash -LiteralPath $stableReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Utf8Json (Join-Path $migrationRoot 'final-delta.receipt.json') ([ordered]@{
        contractId = 'nll/samsung-project-state-to-micron-final-delta/v1'
        migrationUid = $migrationUid
        allActiveMembersSha256Verified = $true
        sourceDeletionPerformed = $false
        materializationPending = $true
        stableVerificationReceiptSha256 = $stableReceiptSha256
        activeManifestSha256 = $activeManifestSha256
        activeManifestMemberCount = $manifestRows.Count
    })

    $positiveJson = & $MaterializerPath -MigrationUid $migrationUid -PreflightOnly -TargetSystemDrive $testDrive
    $positive = $positiveJson | ConvertFrom-Json
    Assert-Verify ($positive.verdictCode -ceq 'ready_for_micron_materialization' -and
        $positive.mutationPerformed -eq $false -and
        $positive.profileMappingCount -eq 6) `
        'samsung_to_micron_tool_verification_positive_preflight_failed'
    Assert-Verify (-not (Test-Path -LiteralPath (Join-Path $driveRoot 'Users\nlloperator\.codex'))) `
        'samsung_to_micron_tool_verification_preflight_mutated_target'

    $occupiedPath = Join-Path $driveRoot 'Users\zih44\.codex'
    [IO.Directory]::CreateDirectory($occupiedPath) | Out-Null
    $negativeFailure = $null
    try {
        & $MaterializerPath -MigrationUid $migrationUid -PreflightOnly -TargetSystemDrive $testDrive | Out-Null
    }
    catch {
        $negativeFailure = $_.Exception.Message
    }
    Assert-Verify ($negativeFailure -like 'micron_materialization_junction_path_occupied:*') `
        'samsung_to_micron_tool_verification_occupied_junction_not_rejected'

    [pscustomobject]@{
        schemaVersion = 1
        contractId = 'nll/samsung-to-micron-migration-tool-verification/v1'
        verifiedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        materializerPath = [IO.Path]::GetFullPath($MaterializerPath)
        positivePreflightPassed = $true
        preflightMutationCount = 0
        occupiedJunctionRejected = $true
        verdictCode = 'materializer_preflight_regression_passed'
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($substCreated) {
        & "$env:SystemRoot\System32\subst.exe" $testDrive /D
    }
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot).TrimEnd('\')
    if ($resolvedTemporaryRoot.StartsWith($temporaryParent + '\', [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTemporaryRoot) -like 'NLL-Materializer-Test-*' -and
        (Test-Path -LiteralPath $resolvedTemporaryRoot)) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
