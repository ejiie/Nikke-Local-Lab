[CmdletBinding()]
param(
    [string]$CandidatePath =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\automation\phase-d-executions\787ceb17-2bc6-45cd-829b-8b449ba01ab0\runtime-candidate.json',
    [string]$LobbyPath =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\automation\phase-d-executions\787ceb17-2bc6-45cd-829b-8b449ba01ab0\lobby-projection.json',
    [string]$InstallRoot = 'C:\NLL\ControlCenter',
    [string]$PinnedRuntimeRoot =
        'C:\NLL\Runtime\EpinelPS-SoloRaidRankingPrefix-v9',
    [string]$MaterializerRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\phase-d\runtime-materializer',
    [string]$ReceiptRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\artifacts\phase-d\overload-state-effect-smoke'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

function Assert-Smoke {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

function Unprotect-SmokeSecret {
    param([string]$Path)
    $protected = [IO.File]::ReadAllBytes($Path)
    $entropy = [Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $entropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { [Text.Encoding]::UTF8.GetString($plain) }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
    finally {
        [Array]::Clear($protected, 0, $protected.Length)
        [Array]::Clear($entropy, 0, $entropy.Length)
    }
}

function Invoke-SmokePgCtl {
    param([string[]]$Arguments)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
    $info.Arguments = (($Arguments | ForEach-Object {
        '"' + $_.Replace('"', '\"') + '"'
    }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    $process.WaitForExit()
    $exitCode = [int]$process.ExitCode
    $process.Dispose()
    $exitCode
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-Smoke `
    ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and
     $env:USERNAME -ceq 'nlloperator' -and $env:SystemDrive -ceq 'C:') `
    'phase_d_overload_smoke_boundary_invalid'
Assert-Smoke `
    (@(Get-Process -Name nikke,EpinelPS,'NikkeLocalLab.Phase3B2.PhysicalBootstrap' `
        -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase_d_overload_smoke_runtime_not_cold'

$candidateFullPath = [IO.Path]::GetFullPath($CandidatePath)
$lobbyFullPath = [IO.Path]::GetFullPath($LobbyPath)
$repositoryRoot = 'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab'
Assert-Smoke ($candidateFullPath.StartsWith(
        $repositoryRoot + '\artifacts\automation\phase-d-executions\',
        [StringComparison]::OrdinalIgnoreCase)) `
    'phase_d_overload_smoke_candidate_path_invalid'
Assert-Smoke ($lobbyFullPath.StartsWith(
        $repositoryRoot + '\artifacts\automation\phase-d-executions\',
        [StringComparison]::OrdinalIgnoreCase)) `
    'phase_d_overload_smoke_lobby_path_invalid'
Assert-Smoke (Test-Path -LiteralPath $candidateFullPath -PathType Leaf) `
    'phase_d_overload_smoke_candidate_missing'
Assert-Smoke (Test-Path -LiteralPath $lobbyFullPath -PathType Leaf) `
    'phase_d_overload_smoke_lobby_missing'

$smokeUid = [guid]::NewGuid().ToString()
$stageRoot = Join-Path $InstallRoot ('staging\overload-state-effect-smoke-' + $smokeUid)
$stagePrefix = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'staging')).TrimEnd('\') + '\'
$stageFullPath = [IO.Path]::GetFullPath($stageRoot)
Assert-Smoke ($stageFullPath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) `
    'phase_d_overload_smoke_stage_path_invalid'
$receiptDirectory = Join-Path $ReceiptRoot $smokeUid
$outputDatabasePath = Join-Path $stageFullPath 'db.json'
$materializationReceiptPath = Join-Path $stageFullPath 'materialization.receipt.json'
$databasePassword = $null
$identitySecret = $null
$postgresStartedBySmoke = $false

try {
    New-Item -ItemType Directory -Path $stageFullPath,$receiptDirectory -Force | Out-Null
    Get-ChildItem -LiteralPath $MaterializerRoot -File | Copy-Item -Destination $stageFullPath
    Get-ChildItem -LiteralPath $PinnedRuntimeRoot -File -Filter '*.dll' |
        Copy-Item -Destination $stageFullPath -Force
    Copy-Item -LiteralPath (Join-Path $PinnedRuntimeRoot 'gameconfig.json') `
        -Destination $stageFullPath
    New-Item -ItemType Junction -Path (Join-Path $stageFullPath 'cache') `
        -Target (Join-Path $PinnedRuntimeRoot 'cache') | Out-Null

    $databasePassword = Unprotect-SmokeSecret `
        (Join-Path $InstallRoot 'secrets\database-password.dpapi')
    $identitySecret = Unprotect-SmokeSecret `
        (Join-Path $InstallRoot 'secrets\identity-secret.dpapi')
    $env:NIKKE_LAB_DB =
        "Host=127.0.0.1;Port=55433;Database=nll_control_center;Username=nll_control_center;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_ID_SECRET = $identitySecret

    $pgData = Join-Path $InstallRoot 'postgresql\data'
    $pgLog = Join-Path $InstallRoot 'logs\postgresql.log'
    $pgStatus = Invoke-SmokePgCtl @('status','-D',$pgData)
    if ($pgStatus -ne 0) {
        $pgStart = Invoke-SmokePgCtl @('start','-D',$pgData,'-l',$pgLog,'-w','-t','60')
        Assert-Smoke ($pgStart -eq 0) 'phase_d_overload_smoke_postgresql_start_failed'
        $postgresStartedBySmoke = $true
    }

    $materializer = Join-Path $stageFullPath 'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
    Push-Location $stageFullPath
    try {
        $materializerOutput = @(& $materializer `
            --candidate $candidateFullPath `
            --lobby $lobbyFullPath `
            --source-db (Join-Path $PinnedRuntimeRoot 'db.json') `
            --output-db $outputDatabasePath `
            --receipt $materializationReceiptPath `
            --connection-string-env NIKKE_LAB_DB `
            --identity-secret-env NIKKE_LAB_ID_SECRET 2>&1)
        $materializerExitCode = $LASTEXITCODE
    }
    finally { Pop-Location }
    if ($materializerExitCode -ne 0) {
        $safeMaterializerFailure = @(
            $materializerOutput |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -cmatch '^phase_d_[a-z0-9._-]{3,128}$' }
        ) | Select-Object -Last 1
        if ([string]::IsNullOrWhiteSpace([string]$safeMaterializerFailure)) {
            throw 'phase_d_overload_smoke_materializer_failed'
        }
        throw [string]$safeMaterializerFailure
    }

    $database = Get-Content -LiteralPath $outputDatabasePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-Smoke (@($database.Users).Count -eq 1) `
        'phase_d_overload_smoke_user_cardinality_invalid'
    $user = @($database.Users)[0]
    $synchroLevel = [int]$user.SynchroDeviceLevel
    $characterLevelMismatchCount = @($user.Characters | Where-Object {
        [int]$_.Level -ne $synchroLevel
    }).Count
    Assert-Smoke ($synchroLevel -gt 0 -and $characterLevelMismatchCount -eq 0) `
        'phase_d_synchro_level_projection_mismatch'
    $optionIds = @(
        foreach ($awakening in @($user.EquipmentAwakenings)) {
            foreach ($optionId in @(
                    $awakening.Option.Option1Id,
                    $awakening.Option.Option2Id,
                    $awakening.Option.Option3Id)) {
                if ([int]$optionId -ne 0) { [int]$optionId }
            }
        }
    )
    $parentOptionShapeCount = @($optionIds | Where-Object {
        $_ -ge 1000000 -and $_ -lt 2000000
    }).Count
    Assert-Smoke ($optionIds.Count -gt 0 -and $parentOptionShapeCount -eq 0) `
        'phase_d_overload_smoke_parent_option_id_persisted'

    $receipt = [ordered]@{
        schemaVersion = 1
        contractId = 'nll/phase-d-overload-state-effect-smoke/v1'
        smokeUid = $smokeUid
        observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
        candidateSha256 = (Get-FileHash -LiteralPath $candidateFullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        materializerSha256 = (Get-FileHash -LiteralPath $materializer -Algorithm SHA256).Hash.ToLowerInvariant()
        characterCount = @($user.Characters).Count
        synchroLevel = $synchroLevel
        characterLevelMismatchCount = $characterLevelMismatchCount
        awakeningCount = @($user.EquipmentAwakenings).Count
        populatedOptionCount = $optionIds.Count
        parentOptionShapeCount = $parentOptionShapeCount
        materializerStateEffectAdmissionPassed = $true
        sourceDatabaseModified = $false
        derivedDatabaseRetained = $false
        secretPersisted = $false
        originalClientExecuted = $false
    }
    [IO.File]::WriteAllText(
        (Join-Path $receiptDirectory 'receipt.json'),
        (($receipt | ConvertTo-Json -Depth 5) + "`n"),
        [Text.UTF8Encoding]::new($false))
    $receipt | ConvertTo-Json -Depth 5
}
catch {
    $failureCode = [string]$_.Exception.Message
    if ($failureCode -cnotmatch '^phase_d_[a-z0-9._-]{3,128}$') {
        $failureCode = 'phase_d_overload_smoke_uncontrolled_failure'
    }
    if (Test-Path -LiteralPath $receiptDirectory -PathType Container) {
        $failureReceipt = [ordered]@{
            schemaVersion = 1
            contractId = 'nll/phase-d-overload-state-effect-smoke/v1'
            smokeUid = $smokeUid
            observedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
            statusCode = 'failed'
            failureCode = $failureCode
            sourceDatabaseModified = $false
            derivedDatabaseRetained = $false
            secretPersisted = $false
            originalClientExecuted = $false
        }
        [IO.File]::WriteAllText(
            (Join-Path $receiptDirectory 'receipt.json'),
            (($failureReceipt | ConvertTo-Json -Depth 5) + "`n"),
            [Text.UTF8Encoding]::new($false))
    }
    throw $failureCode
}
finally {
    Remove-Item Env:NIKKE_LAB_DB -ErrorAction SilentlyContinue
    Remove-Item Env:NIKKE_LAB_ID_SECRET -ErrorAction SilentlyContinue
    $databasePassword = $null
    $identitySecret = $null
    if ($postgresStartedBySmoke) {
        $pgStop = Invoke-SmokePgCtl @(
            'stop','-D',(Join-Path $InstallRoot 'postgresql\data'),'-m','fast','-w','-t','60')
        if ($pgStop -ne 0) { throw 'phase_d_overload_smoke_postgresql_stop_failed' }
    }
    if (Test-Path -LiteralPath $stageFullPath -PathType Container) {
        $resolvedStage = [IO.Path]::GetFullPath($stageFullPath)
        Assert-Smoke ($resolvedStage.StartsWith(
                $stagePrefix, [StringComparison]::OrdinalIgnoreCase)) `
            'phase_d_overload_smoke_cleanup_path_invalid'
        Remove-Item -LiteralPath $resolvedStage -Recurse -Force
    }
}
