[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EvidenceRoot
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

function Invoke-RobocopyExact {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    Assert-True ($LASTEXITCODE -ge 0 -and $LASTEXITCODE -le 7) "phase3b2_guest_copy_failed"
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

function Invoke-Checked {
    param([string]$FilePath, [string[]]$ArgumentList, [string]$FailureCode, [string]$OutputPath)
    $startArguments = @{
        FilePath = $FilePath
        ArgumentList = $ArgumentList
        Wait = $true
        PassThru = $true
        NoNewWindow = $true
        RedirectStandardOutput = $OutputPath + ".stdout"
        RedirectStandardError = $OutputPath + ".stderr"
    }
    $process = Start-Process @startArguments
    Assert-True ($process.ExitCode -eq 0) $FailureCode
}

$trustedRoot = Join-Path $EvidenceRoot "trusted"
New-Item -ItemType Directory -Path $trustedRoot -Force | Out-Null
$workRoot = "C:\Phase3B2"
Assert-True (-not (Test-Path -LiteralPath $workRoot)) "phase3b2_guest_work_root_already_exists"
New-Item -ItemType Directory -Path $workRoot | Out-Null

try {
    Write-Status "running" 2 "guest_boundary_verification"
    foreach ($path in @("C:\HostLabRepo", "C:\HostPrimary", "C:\HostEpinelPS", "C:\HostInputs", "C:\HostDotnet", "C:\HostGit", "C:\HostNuget", $EvidenceRoot)) {
        Assert-True (Test-Path -LiteralPath $path -PathType Container) "phase3b2_guest_mapping_missing"
    }
    Assert-True ($null -eq (Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq "Up")) "phase3b2_guest_network_adapter_enabled"

    $hostProjection = Get-Content -Raw -LiteralPath (Join-Path $EvidenceRoot "host-input-projection.json") | ConvertFrom-Json
    Assert-True ($hostProjection.contractId -ceq "nll/phase3b2-host-input-projection/v1") "phase3b2_guest_input_projection_mismatch"

    Write-Status "running" 5 "primary_manifest_hashing"
    $primaryManifest = New-CanonicalFileManifest "C:\HostPrimary" (Join-Path $trustedRoot "primary-before.manifest.tsv")

    Write-Status "running" 18 "disposable_client_copy"
    $clientRoot = Join-Path $workRoot "ClientRoot"
    Invoke-RobocopyExact "C:\HostPrimary" $clientRoot

    Write-Status "running" 42 "disposable_client_manifest_hashing"
    $clientManifest = New-CanonicalFileManifest $clientRoot (Join-Path $trustedRoot "disposable-client.manifest.tsv")
    Assert-True ($clientManifest.fileCount -eq $primaryManifest.fileCount -and
        $clientManifest.byteLength -eq $primaryManifest.byteLength -and
        $clientManifest.sha256 -ceq $primaryManifest.sha256) "phase3b2_guest_client_copy_manifest_mismatch"

    Write-Status "running" 55 "epinelps_source_copy"
    $epinelRoot = Join-Path $workRoot "EpinelPS"
    Invoke-RobocopyExact "C:\HostEpinelPS" $epinelRoot
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
    Assert-True ((& $dotnet --version).Trim() -ceq "10.0.400") "phase3b2_guest_dotnet_sdk_mismatch"
    Push-Location $epinelRoot
    try {
        Assert-True ((& $git rev-parse HEAD).Trim() -ceq "6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6") "phase3b2_guest_external_head_mismatch"
        Assert-True ((& $git rev-parse "HEAD^{tree}").Trim() -ceq "ede7be7d5290339f7e3844a542a4055e0de8151b") "phase3b2_guest_external_tree_mismatch"
        Assert-True (@(& $git status --porcelain=v1 --untracked-files=all).Count -eq 0) "phase3b2_guest_external_checkout_dirty"
        foreach ($ancestor in @(
            "28b2f5413a0a1e3521a11ae162f91851335c8b40",
            "92a6ca228aeb580988907b96189b2857dff2c62d",
            "e32e5f900775974d5736e7fb2b50f8c62638a004")) {
            & $git merge-base --is-ancestor $ancestor HEAD
            Assert-True ($LASTEXITCODE -eq 0) "phase3b2_guest_external_ancestry_mismatch"
        }

        $buildLogRoot = Join-Path $trustedRoot "build"
        New-Item -ItemType Directory -Path $buildLogRoot -Force | Out-Null
        $nugetConfigPath = "C:\HostLabRepo\scripts\NuGet.phase3b2.sandbox.config"
        Assert-True (Test-Path -LiteralPath $nugetConfigPath -PathType Leaf) "phase3b2_guest_offline_nuget_config_missing"
        Write-Status "running" 60 "epinelps_restore"
        $restoreLogBase = Join-Path $buildLogRoot "restore"
        Invoke-Checked $dotnet @("restore", ".\EpinelPS.sln", "--nologo", "--configfile", $nugetConfigPath) "phase3b2_guest_restore_failed" $restoreLogBase
        $restoreText = ([System.IO.File]::ReadAllText($restoreLogBase + ".stdout") + "`n" + [System.IO.File]::ReadAllText($restoreLogBase + ".stderr"))
        Assert-True ($restoreText -notmatch "NU1801|NU1603|api\.nuget\.org" -and
            (Get-Item -LiteralPath ($restoreLogBase + ".stderr")).Length -eq 0) "phase3b2_guest_restore_boundary_violation"
        Write-Status "running" 66 "epinelps_release_build"
        Invoke-Checked $dotnet @("build", ".\EpinelPS.sln", "-c", "Release", "--no-restore", "--nologo") "phase3b2_guest_build_failed" (Join-Path $buildLogRoot "build")
        Write-Status "running" 74 "epinelps_focused_tests"
        $selectedResults = Join-Path $workRoot "test-selected"
        $isolationResults = Join-Path $workRoot "test-isolation"
        New-Item -ItemType Directory -Path $selectedResults, $isolationResults -Force | Out-Null
        Invoke-Checked $dotnet @("test", ".\tests\EpinelPS.SelectedManager.Tests\EpinelPS.SelectedManager.Tests.csproj", "-c", "Release", "--no-build", "--nologo", "--logger", "trx;LogFileName=selected.trx", "--results-directory", $selectedResults) "phase3b2_guest_selected_tests_failed" (Join-Path $buildLogRoot "selected-tests")
        Invoke-Checked $dotnet @("test", ".\tests\EpinelPS.HandlerIsolation.Tests\EpinelPS.HandlerIsolation.Tests.csproj", "-c", "Release", "--no-build", "--nologo", "--logger", "trx;LogFileName=isolation.trx", "--results-directory", $isolationResults) "phase3b2_guest_isolation_tests_failed" (Join-Path $buildLogRoot "isolation-tests")
    }
    finally { Pop-Location }

    [xml]$selectedTrx = Get-Content -Raw -LiteralPath (Join-Path $selectedResults "selected.trx")
    [xml]$isolationTrx = Get-Content -Raw -LiteralPath (Join-Path $isolationResults "isolation.trx")
    $selectedCounters = $selectedTrx.TestRun.ResultSummary.Counters
    $isolationCounters = $isolationTrx.TestRun.ResultSummary.Counters
    Assert-True ([int]$selectedCounters.passed -eq 64 -and [int]$selectedCounters.failed -eq 0) "phase3b2_guest_selected_test_count_mismatch"
    Assert-True ([int]$isolationCounters.passed -eq 5 -and [int]$isolationCounters.failed -eq 0) "phase3b2_guest_isolation_test_count_mismatch"

    $serverOutput = Join-Path $epinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
    $selectorOutput = Join-Path $epinelRoot "ServerSelector.Desktop\bin\Release\net10.0\win-x64"
    Assert-True (Test-Path -LiteralPath (Join-Path $serverOutput "EpinelPS.exe") -PathType Leaf) "phase3b2_guest_server_output_missing"
    Assert-True (Test-Path -LiteralPath (Join-Path $selectorOutput "ServerSelector.dll") -PathType Leaf) "phase3b2_guest_selector_output_missing"

    Write-Status "running" 78 "runtime_input_staging"
    $gameConfig = Get-Content -Raw -LiteralPath (Join-Path $serverOutput "gameconfig.json") | ConvertFrom-Json
    $staticUrl = [string]$gameConfig.StaticDataMpk.Url
    $staticRelative = $staticUrl.Replace("https://cloud.nikke-kr.com/", "").Replace("/", "\")
    Assert-True (-not [System.IO.Path]::IsPathRooted($staticRelative) -and $staticRelative -notmatch "\.\.") "phase3b2_guest_staticdata_cache_path_invalid"
    $staticTarget = Join-Path (Join-Path $serverOutput "cache") $staticRelative
    New-Item -ItemType Directory -Path (Split-Path -Parent $staticTarget) -Force | Out-Null
    Copy-Item -LiteralPath "C:\HostInputs\staticdata\553116\StaticData.pack" -Destination $staticTarget -Force
    $localeTarget = Join-Path $serverOutput "cache\local-locale"
    New-Item -ItemType Directory -Path $localeTarget -Force | Out-Null
    foreach ($name in @("Locale_Bgm.lsc", "Locale_Character.lsc", "Locale_CharacterCostume.lsc", "Locale_Item.lsc")) {
        Copy-Item -LiteralPath (Join-Path "C:\HostInputs\locale\150.6.9" $name) -Destination (Join-Path $localeTarget $name) -Force
    }

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
    Write-AtomicUtf8 (Join-Path $trustedRoot "failure.json") ($failure | ConvertTo-Json -Depth 4)
    Write-Status "blocked" 0 "guest_preparation_failed"
    throw
}
