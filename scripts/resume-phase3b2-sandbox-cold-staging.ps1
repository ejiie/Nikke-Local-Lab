[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot,

    [switch]$ContinuePreflight
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

function Get-FileEvidence {
    param([string]$Path)
    Assert-True (Test-Path -LiteralPath $Path -PathType Leaf) "phase3b2_resume_evidence_file_missing"
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return [ordered]@{ byteLength = $bytes.Length; sha256 = Get-Sha256Hex $bytes }
}

function Assert-ProjectedFile {
    param([object]$Projection, [string]$RoleCode, [string]$Path)
    $members = @($Projection.inputs | Where-Object roleCode -CEQ $RoleCode)
    Assert-True ($members.Count -eq 1) "phase3b2_resume_input_projection_role_mismatch"
    $actual = Get-FileEvidence $Path
    Assert-True ($actual.byteLength -eq [long]$members[0].byteLength -and
        $actual.sha256 -ceq [string]$members[0].sha256) "phase3b2_resume_staged_input_digest_mismatch"
}

function Write-AtomicUtf8 {
    param([string]$Path, [string]$Text)
    $temporary = $Path + ".tmp"
    [System.IO.File]::WriteAllText($temporary, $Text, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-Status {
    param([string]$StatusCode, [int]$Percent, [string]$DetailCode)
    $document = [ordered]@{
        schemaVersion = 1
        statusCode = $StatusCode
        progressPercent = $Percent
        detailCode = $DetailCode
        clientExecutionStarted = $false
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    }
    Write-AtomicUtf8 (Join-Path $EvidenceRoot "status.json") ($document | ConvertTo-Json)
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
    return [ordered]@{ fileCount = $paths.Count; byteLength = $bytes.Length; sha256 = Get-Sha256Hex $bytes }
}

function New-CanonicalTextEvidence {
    param([string]$OutputPath, [string[]]$Lines)
    $text = (($Lines | ForEach-Object { $_.Normalize([Text.NormalizationForm]::FormC) }) -join "`n") + "`n"
    Write-AtomicUtf8 $OutputPath $text
    $bytes = [System.IO.File]::ReadAllBytes($OutputPath)
    return [ordered]@{ byteLength = $bytes.Length; sha256 = Get-Sha256Hex $bytes }
}

$trustedRoot = Join-Path $EvidenceRoot "trusted"
$workRoot = "C:\Phase3B2"
$epinelRoot = Join-Path $workRoot "EpinelPS"
$serverOutput = Join-Path $epinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$selectorOutput = Join-Path $epinelRoot "ServerSelector.Desktop\bin\Release\net10.0\win-x64"

try {
    $status = Get-Content -Raw -LiteralPath (Join-Path $EvidenceRoot "status.json") | ConvertFrom-Json
    $failure = Get-Content -Raw -LiteralPath (Join-Path $trustedRoot "failure.json") | ConvertFrom-Json
    Assert-True ($status.statusCode -ceq "blocked" -and
        $status.detailCode -ceq "guest_preparation_failed" -and
        -not $status.clientExecutionStarted) "phase3b2_resume_source_status_mismatch"
    Assert-True ($failure.message -ceq "phase3b2_guest_selected_test_count_mismatch") "phase3b2_resume_source_failure_mismatch"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $EvidenceRoot "cold-staging.json"))) "phase3b2_resume_cold_staging_already_exists"
    Assert-True ($null -eq (Get-Process -Name EpinelPS, nikke, nikke_launcher -ErrorAction SilentlyContinue)) "phase3b2_resume_process_already_running"
    Assert-True ($null -eq (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq "Up")) "phase3b2_resume_network_adapter_enabled"
    Assert-True ((Test-Path -LiteralPath $serverOutput -PathType Container) -and
        (Test-Path -LiteralPath $selectorOutput -PathType Container)) "phase3b2_resume_build_output_missing"

    Write-Status "running" 75 "focused_test_receipt_revalidation"
    $selectedTrxPath = Join-Path $workRoot "test-selected\selected.trx"
    $isolationTrxPath = Join-Path $workRoot "test-isolation\isolation.trx"
    [xml]$selectedTrx = Get-Content -Raw -LiteralPath $selectedTrxPath
    [xml]$isolationTrx = Get-Content -Raw -LiteralPath $isolationTrxPath
    $selectedCounters = $selectedTrx.TestRun.ResultSummary.Counters
    $isolationCounters = $isolationTrx.TestRun.ResultSummary.Counters
    Assert-True ([int]$selectedCounters.passed -eq 64 -and [int]$selectedCounters.failed -eq 0 -and
        [int]$selectedCounters.notExecuted -eq 0) "phase3b2_resume_selected_test_count_mismatch"
    Assert-True ([int]$isolationCounters.passed -eq 5 -and [int]$isolationCounters.failed -eq 0 -and
        [int]$isolationCounters.notExecuted -eq 0) "phase3b2_resume_isolation_test_count_mismatch"

    $git = "C:\HostGit\cmd\git.exe"
    $dotnet = "C:\HostDotnet\dotnet.exe"
    $env:DOTNET_CLI_HOME = Join-Path $workRoot "dotnet-home"
    $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = "1"
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
    $env:DOTNET_NOLOGO = "1"
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = "false"
    $env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = "false"
    $env:MSBUILDDISABLENODEREUSE = "1"
    $env:NUGET_PACKAGES = "C:\HostNuget"
    Assert-True ((& $dotnet --version).Trim() -ceq "10.0.400") "phase3b2_resume_dotnet_sdk_mismatch"
    Push-Location $epinelRoot
    try {
        Assert-True ((& $git rev-parse HEAD).Trim() -ceq "6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6") "phase3b2_resume_external_head_mismatch"
        Assert-True ((& $git rev-parse "HEAD^{tree}").Trim() -ceq "ede7be7d5290339f7e3844a542a4055e0de8151b") "phase3b2_resume_external_tree_mismatch"
        Assert-True (@(& $git status --porcelain=v1 --untracked-files=all).Count -eq 0) "phase3b2_resume_external_checkout_dirty"
    }
    finally { Pop-Location }

    $primaryManifestPath = Join-Path $trustedRoot "primary-before.manifest.tsv"
    $clientManifestPath = Join-Path $trustedRoot "disposable-client.manifest.tsv"
    $primaryManifestBytes = [System.IO.File]::ReadAllBytes($primaryManifestPath)
    $clientManifestBytes = [System.IO.File]::ReadAllBytes($clientManifestPath)
    Assert-True ($primaryManifestBytes.Length -eq $clientManifestBytes.Length -and
        (Get-Sha256Hex $primaryManifestBytes) -ceq (Get-Sha256Hex $clientManifestBytes)) "phase3b2_resume_client_copy_manifest_mismatch"
    $fileCount = 0
    foreach ($line in [System.IO.File]::ReadLines($primaryManifestPath)) { if ($line.Length) { $fileCount++ } }
    $primaryManifest = [ordered]@{ fileCount = $fileCount; byteLength = $primaryManifestBytes.Length; sha256 = Get-Sha256Hex $primaryManifestBytes }
    $clientManifest = [ordered]@{ fileCount = $fileCount; byteLength = $clientManifestBytes.Length; sha256 = Get-Sha256Hex $clientManifestBytes }

    Write-Status "running" 78 "runtime_input_staging"
    $hostProjection = Get-Content -Raw -LiteralPath (Join-Path $EvidenceRoot "host-input-projection.json") | ConvertFrom-Json
    Assert-True ($hostProjection.contractId -ceq "nll/phase3b2-host-input-projection/v1") "phase3b2_resume_input_projection_mismatch"
    $gameConfig = Get-Content -Raw -LiteralPath (Join-Path $serverOutput "gameconfig.json") | ConvertFrom-Json
    $staticUrl = [string]$gameConfig.StaticDataMpk.Url
    $staticRelative = $staticUrl.Replace("https://cloud.nikke-kr.com/", "").Replace("/", "\")
    Assert-True (-not [System.IO.Path]::IsPathRooted($staticRelative) -and $staticRelative -notmatch "\.\.") "phase3b2_resume_staticdata_cache_path_invalid"
    $staticTarget = Join-Path (Join-Path $serverOutput "cache") $staticRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $staticTarget) -Force | Out-Null
    Copy-Item -LiteralPath "C:\HostInputs\staticdata\553116\StaticData.pack" -Destination $staticTarget -Force
    $localeTarget = Join-Path $serverOutput "cache\local-locale"
    New-Item -ItemType Directory -Path $localeTarget -Force | Out-Null
    foreach ($name in @("Locale_Bgm.lsc", "Locale_Character.lsc", "Locale_CharacterCostume.lsc", "Locale_Item.lsc")) {
        Copy-Item -LiteralPath (Join-Path "C:\HostInputs\locale\150.6.9" $name) -Destination (Join-Path $localeTarget $name) -Force
    }
    Assert-ProjectedFile $hostProjection "runtime_pack_staticdata" $staticTarget
    Assert-ProjectedFile $hostProjection "locale_bgm" (Join-Path $localeTarget "Locale_Bgm.lsc")
    Assert-ProjectedFile $hostProjection "locale_character" (Join-Path $localeTarget "Locale_Character.lsc")
    Assert-ProjectedFile $hostProjection "locale_costume" (Join-Path $localeTarget "Locale_CharacterCostume.lsc")
    Assert-ProjectedFile $hostProjection "locale_item" (Join-Path $localeTarget "Locale_Item.lsc")

    $buildManifest = New-CanonicalFileManifest $serverOutput (Join-Path $trustedRoot "server-build.manifest.tsv")
    $toolchainEvidence = New-CanonicalTextEvidence (Join-Path $trustedRoot "toolchain.txt") @(
        "dotnetSdkVersion=10.0.400",
        "externalHead=6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6",
        "externalTree=ede7be7d5290339f7e3844a542a4055e0de8151b",
        "checkoutClean=true"
    )
    $focusedEvidence = New-CanonicalTextEvidence (Join-Path $trustedRoot "focused-tests.txt") @(
        "selectedManagerPassedCount=64",
        "handlerIsolationPassedCount=5",
        "focusedTestFailedCount=0"
    )
    $coldSummary = [ordered]@{
        schemaVersion = 1
        contractId = "nll/phase3b2-sandbox-cold-staging/v1"
        assessmentUid = $hostProjection.assessmentUid
        environmentKindCode = "separate_disposable_os"
        snapshotRestoreReady = $true
        clientExecutionStarted = $false
        serverExecutionStarted = $false
        primaryManifest = $primaryManifest
        clientManifest = $clientManifest
        buildManifest = $buildManifest
        toolchainEvidence = $toolchainEvidence
        focusedEvidence = $focusedEvidence
        selectedManagerPassedCount = 64
        handlerIsolationPassedCount = 5
        focusedTestFailedCount = 0
    }
    Write-AtomicUtf8 (Join-Path $EvidenceRoot "cold-staging.json") ($coldSummary | ConvertTo-Json -Depth 8)
    Write-Status "cold_staging_complete" 82 "server_and_client_cold"

}
catch {
    $failure = [ordered]@{
        exceptionType = $_.Exception.GetType().FullName
        message = $_.Exception.Message
        hresult = $_.Exception.HResult
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString("o")
    }
    Write-AtomicUtf8 (Join-Path $trustedRoot "resume-failure.json") ($failure | ConvertTo-Json -Depth 4)
    Write-Status "blocked" 0 "guest_resume_failed"
    throw
}

if ($ContinuePreflight) {
    & "C:\HostLabRepo\scripts\continue-phase3b2-sandbox-preflight.ps1" -EvidenceRoot $EvidenceRoot
}
