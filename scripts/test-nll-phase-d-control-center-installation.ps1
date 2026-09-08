[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\NLL\ControlCenter',
    [string]$RepositoryRoot = 'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab',
    [string]$MaterializerBuildRoot =
        'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab\tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\bin\Release\net10.0\win-x64',
    [ValidateRange(1024, 65535)] [int]$DatabasePort = 55433,
    [ValidateRange(1024, 65535)] [int]$AdminPort = 17878
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

function Assert-Smoke { param([bool]$Condition, [string]$Code) if (-not $Condition) { throw $Code } }
function Unprotect-SmokeSecret {
    param([string]$Path)
    $protected = [IO.File]::ReadAllBytes($Path)
    $entropy = [Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            $protected, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        try { [Text.Encoding]::UTF8.GetString($plain) }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
    finally {
        [Array]::Clear($protected, 0, $protected.Length)
        [Array]::Clear($entropy, 0, $entropy.Length)
    }
}
function Test-SmokePort {
    param([int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try { $task = $client.ConnectAsync('127.0.0.1', $Port); $task.Wait(800) -and $client.Connected }
    catch { $false }
    finally { $client.Dispose() }
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-Smoke ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and
    $env:USERNAME -ceq 'nlloperator' -and $env:SystemDrive -ceq 'C:') 'phase_d_smoke_boundary_invalid'
$deploymentPath = Join-Path $InstallRoot 'deployment.receipt.json'
$deployment = Get-Content -LiteralPath $deploymentPath -Raw | ConvertFrom-Json
Assert-Smoke ($deployment.contractId -ceq 'nll/phase-d-control-center-deployment/v1') 'phase_d_smoke_deployment_invalid'
Assert-Smoke (@(Get-Process -Name postgres,EpinelPS,nikke -ErrorAction SilentlyContinue).Count -eq 0) 'phase_d_smoke_runtime_not_cold'
Assert-Smoke (-not (Test-SmokePort $DatabasePort) -and -not (Test-SmokePort $AdminPort)) 'phase_d_smoke_port_in_use'

$pgCtl = 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
$dataRoot = Join-Path $InstallRoot 'postgresql\data'
$postgresLog = Join-Path $InstallRoot 'logs\postgresql.log'
$bootstrapPath = Join-Path $InstallRoot 'session\smoke-bootstrap.secret'
$adminStdout = Join-Path $InstallRoot 'logs\smoke-admin.stdout.log'
$adminStderr = Join-Path $InstallRoot 'logs\smoke-admin.stderr.log'
$databasePassword = Unprotect-SmokeSecret (Join-Path $InstallRoot 'secrets\database-password.dpapi')
$identitySecret = Unprotect-SmokeSecret (Join-Path $InstallRoot 'secrets\identity-secret.dpapi')
$postgresStarted = $false
$admin = $null
$accountCount = 0
$candidateValueCount = 0
$candidateUnresolvedCount = 0
$candidateReasonCount = 0
$candidateStatus = $null
$validatedAccountUid = $null
$deploymentAccountPresent = $false
$loadableWorkspaceCount = 0
$workspaceFailureCount = 0
$soloRaidOperationalBindingVerified = $false
$soloRaidSnapshotUid = $null
$soloRaidSnapshotSha256 = $null
$materializerSmokeRoot = Join-Path $InstallRoot `
    ('staging\installation-smoke-materializer\' + [guid]::NewGuid().ToString('D'))
try {
    $env:NIKKE_LAB_DB = "Host=127.0.0.1;Port=$DatabasePort;Database=nll_control_center;Username=nll_control_center;Password=$databasePassword;SSL Mode=Disable;Include Error Detail=false"
    $env:NIKKE_LAB_ID_SECRET = $identitySecret
    $env:NIKKE_LAB_HOME = Join-Path $InstallRoot 'runtime-home'
    $env:NIKKE_LAB_PROFILE_RAW = 'C:\Users\nlloperator\Database\raw\nikke_full_scroll_result.json'
    $env:NLL_CONTROL_CENTER_BOOTSTRAP_PATH = $bootstrapPath
    $env:NLL_CONTROL_CENTER_PG_CTL = $pgCtl
    $env:NLL_CONTROL_CENTER_PG_DATA = $dataRoot
    $env:NLL_CONTROL_CENTER_PG_LOG = $postgresLog
    $env:NLL_PHASE_D_CONTROL_CENTER = '1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $bootstrapPath) -Force | Out-Null
    & $pgCtl start -D $dataRoot -l $postgresLog -w -t 60
    Assert-Smoke ($LASTEXITCODE -eq 0) 'phase_d_smoke_postgresql_start_failed'
    $postgresStarted = $true
    $admin = Start-Process -FilePath 'C:\Program Files\dotnet\dotnet.exe' `
        -ArgumentList @(
            (Join-Path $InstallRoot 'app\NikkeLocalLab.Admin.Api.dll'),
            '--config', (Join-Path $RepositoryRoot 'config\appsettings.example.json'),
            '--repository-root', $RepositoryRoot,
            '--phase-d-control-center', 'true') `
        -RedirectStandardOutput $adminStdout `
        -RedirectStandardError $adminStderr `
        -WindowStyle Hidden `
        -PassThru
    for ($index = 0; $index -lt 150 -and -not $admin.HasExited -and
        -not (Test-Path -LiteralPath $bootstrapPath); $index++) {
        Start-Sleep -Milliseconds 200
    }
    Assert-Smoke (-not $admin.HasExited -and (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) 'phase_d_smoke_admin_start_failed'
    $bootstrapCode = (Get-Content -LiteralPath $bootstrapPath -Raw).Trim()
    Assert-Smoke (-not [string]::IsNullOrWhiteSpace($bootstrapCode)) 'phase_d_smoke_bootstrap_missing'
    Remove-Item -LiteralPath $bootstrapPath -Force

    $baseUri = "http://127.0.0.1:$AdminPort"
    $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $bootstrapBody = @{ code = $bootstrapCode } | ConvertTo-Json -Compress
    $bootstrapResponse = Invoke-WebRequest `
        -UseBasicParsing `
        -Uri ($baseUri + '/admin-auth/v1/bootstrap') `
        -Method Post `
        -ContentType 'application/json' `
        -Headers @{ Origin = $baseUri } `
        -Body $bootstrapBody `
        -WebSession $webSession
    Assert-Smoke ($bootstrapResponse.StatusCode -eq 204) 'phase_d_smoke_bootstrap_exchange_failed'
    # Windows PowerShell 5.1 does not reliably retain a Set-Cookie header from
    # a 204 response in WebRequestSession. Bind the exact HttpOnly token to the
    # same CookieContainer without persisting it.
    $setCookie = [string]$bootstrapResponse.Headers['Set-Cookie']
    $sessionMatch = [regex]::Match(
        $setCookie,
        '(?:^|,\s*)nll_admin_session=([^;]+)')
    Assert-Smoke ($sessionMatch.Success) 'phase_d_smoke_session_cookie_missing'
    $sessionCookie = New-Object Net.Cookie(
        'nll_admin_session',
        $sessionMatch.Groups[1].Value,
        '/admin-api',
        '127.0.0.1')
    $sessionCookie.HttpOnly = $true
    $webSession.Cookies.Add($sessionCookie)
    # Windows PowerShell 5.1 emits a JSON array returned by Invoke-RestMethod as
    # one non-enumerated pipeline object. Normalize through a second pipeline;
    # otherwise two or more accounts collapse to the string "System.Object[]"
    # when accountUid is read below.
    $accountResponse = Invoke-RestMethod `
        -Uri ($baseUri + '/admin-api/v1/accounts') `
        -WebSession $webSession
    $accounts = @($accountResponse | ForEach-Object { $_ })
    $accountCount = $accounts.Count
    $accountUids = @($accounts | ForEach-Object { [string]$_.accountUid })
    $deployedAccountMatches = @($accounts | Where-Object {
        [string]$_.accountUid -ceq [string]$deployment.accountUid
    })
    Assert-Smoke `
        ($accountCount -ge 1 -and
         @($accountUids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq $accountCount -and
         @($accountUids | Sort-Object -Unique).Count -eq $accountCount -and
         $deployedAccountMatches.Count -le 1) `
        'phase_d_smoke_account_projection_invalid'
    $deploymentAccountPresent = $deployedAccountMatches.Count -eq 1
    $validationOrder = @(
        $accounts | Sort-Object `
            @{ Expression = { [string]$_.accountUid -cne [string]$deployment.accountUid } },
            @{ Expression = { [string]$_.accountUid } }
    )
    $workspace = $null
    foreach ($account in $validationOrder) {
        $candidateAccountUid = [string]$account.accountUid
        $escapedCandidateAccountUid = [Uri]::EscapeDataString($candidateAccountUid)
        try {
            $candidateWorkspace = Invoke-RestMethod `
                -Uri ($baseUri + "/admin-api/v1/accounts/$escapedCandidateAccountUid/workspace") `
                -WebSession $webSession
            if ([string]$candidateWorkspace.accountUid -cne $candidateAccountUid) {
                $workspaceFailureCount++
                continue
            }
            $loadableWorkspaceCount++
            if ($null -eq $workspace) {
                $workspace = $candidateWorkspace
                $validatedAccountUid = $candidateAccountUid
            }
        }
        catch {
            $workspaceFailureCount++
        }
    }
    Assert-Smoke ($loadableWorkspaceCount -ge 1 -and $null -ne $workspace) 'phase_d_smoke_workspace_invalid'
    $accountUid = [Uri]::EscapeDataString($validatedAccountUid)
    $candidate = Invoke-RestMethod -Uri ($baseUri + "/admin-api/v1/accounts/$accountUid/runtime-projection-candidate") -WebSession $webSession
    $candidateStatus = [string]$candidate.validationStatusCode
    $candidateValueCount = @($candidate.values).Count
    $candidateUnresolvedCount = @($candidate.values | Where-Object { $_.status -eq 'unresolved' }).Count
    $candidateReasonCount = @($candidate.validationReasonCodes).Count
    Assert-Smoke `
        ($candidateValueCount -gt 0 -and
         $candidateStatus -ceq 'ready' -and
         $candidateUnresolvedCount -eq 0 -and
         $candidateReasonCount -eq 0) `
        'phase_d_smoke_candidate_not_materializable'
    $materializerArtifactRoot = Join-Path $RepositoryRoot `
        'artifacts\phase-d\runtime-materializer'
    $materializerLeaves = @(
        'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe',
        'NikkeLocalLab.PhaseD.RuntimeMaterializer.dll',
        'NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json',
        'NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')
    foreach ($leaf in $materializerLeaves) {
        $artifactMember = Join-Path $materializerArtifactRoot $leaf
        $buildMember = Join-Path $MaterializerBuildRoot $leaf
        Assert-Smoke `
            ((Test-Path -LiteralPath $artifactMember -PathType Leaf) -and
             (Test-Path -LiteralPath $buildMember -PathType Leaf) -and
             (Get-FileHash -LiteralPath $artifactMember -Algorithm SHA256).Hash -ceq
                (Get-FileHash -LiteralPath $buildMember -Algorithm SHA256).Hash) `
            'phase_d_smoke_materializer_member_invalid'
    }
    Assert-Smoke `
        (Test-Path -LiteralPath (Join-Path $MaterializerBuildRoot 'hostpolicy.dll') `
            -PathType Leaf) `
        'phase_d_smoke_materializer_host_missing'
    New-Item -ItemType Directory -Path $materializerSmokeRoot -Force | Out-Null
    Get-ChildItem -LiteralPath $MaterializerBuildRoot -File |
        Copy-Item -Destination $materializerSmokeRoot -Force
    foreach ($leaf in $materializerLeaves) {
        Copy-Item -LiteralPath (Join-Path $materializerArtifactRoot $leaf) `
            -Destination $materializerSmokeRoot -Force
    }
    $materializer = Join-Path $materializerSmokeRoot `
        'NikkeLocalLab.PhaseD.RuntimeMaterializer.exe'
    $bindingOutput = @(& $materializer '--verify-solo-raid-binding' 'true' `
        '--connection-string-env' 'NIKKE_LAB_DB' `
        '--account-uid' $validatedAccountUid `
        '--season-number' '26' 2>&1)
    Assert-Smoke ($LASTEXITCODE -eq 0) `
        'phase_d_smoke_raid_binding_verification_failed'
    try {
        $binding = ($bindingOutput -join "`n") | ConvertFrom-Json
    }
    catch {
        throw 'phase_d_smoke_raid_binding_receipt_invalid'
    }
    Assert-Smoke `
        ($binding.contractId -ceq
            'nll/phase-d-classic-solo-raid-binding-verification/v1' -and
         [string]$binding.accountUid -ceq $validatedAccountUid -and
         [int]$binding.seasonNumber -eq 26 -and
         [string]$binding.raidSnapshotUid -cmatch '^[0-9a-f-]{36}$' -and
         [string]$binding.raidSnapshotSha256 -cmatch '^[0-9a-f]{64}$' -and
         $binding.databaseModified -eq $false) `
        'phase_d_smoke_raid_binding_receipt_invalid'
    $soloRaidOperationalBindingVerified = $true
    $soloRaidSnapshotUid = [string]$binding.raidSnapshotUid
    $soloRaidSnapshotSha256 = [string]$binding.raidSnapshotSha256
}
finally {
    if ($null -ne $admin -and -not $admin.HasExited) {
        Stop-Process -Id $admin.Id -Force -ErrorAction SilentlyContinue
        [void]$admin.WaitForExit(10000)
    }
    if (Test-Path -LiteralPath $bootstrapPath) { Remove-Item -LiteralPath $bootstrapPath -Force }
    if (Test-Path -LiteralPath $materializerSmokeRoot -PathType Container) {
        Remove-Item -LiteralPath $materializerSmokeRoot -Recurse -Force
    }
    if ($postgresStarted -or (Test-Path -LiteralPath (Join-Path $dataRoot 'postmaster.pid'))) {
        & $pgCtl stop -D $dataRoot -m fast -w -t 60 2>$null
    }
    foreach ($name in @(
        'NIKKE_LAB_DB','NIKKE_LAB_ID_SECRET','NIKKE_LAB_HOME','NIKKE_LAB_PROFILE_RAW',
        'NLL_CONTROL_CENTER_BOOTSTRAP_PATH','NLL_CONTROL_CENTER_PG_CTL',
        'NLL_CONTROL_CENTER_PG_DATA','NLL_CONTROL_CENTER_PG_LOG',
        'NLL_PHASE_D_CONTROL_CENTER')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $databasePassword = $null
    $identitySecret = $null
}

Assert-Smoke (@(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -eq 0 -and
    -not (Test-SmokePort $DatabasePort) -and -not (Test-SmokePort $AdminPort)) 'phase_d_smoke_cleanup_failed'
$smokeUid = [guid]::NewGuid().ToString('D')
$receiptRoot = Join-Path $InstallRoot ('source-free\installation-smoke\' + $smokeUid)
New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase-d-control-center-installation-smoke/v1'
    inspectedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    inspectionUid = $smokeUid
    deploymentReceiptSha256 = (Get-FileHash -LiteralPath $deploymentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    accountUid = $validatedAccountUid
    accountCount = $accountCount
    deploymentAccountPresent = $deploymentAccountPresent
    loadableWorkspaceCount = $loadableWorkspaceCount
    workspaceFailureCount = $workspaceFailureCount
    candidateStatusCode = $candidateStatus
    candidateValueCount = $candidateValueCount
    candidateUnresolvedCount = $candidateUnresolvedCount
    candidateReasonCount = $candidateReasonCount
    soloRaidOperationalBindingVerified = $soloRaidOperationalBindingVerified
    soloRaidSeasonNumber = 26
    soloRaidSnapshotUid = $soloRaidSnapshotUid
    soloRaidSnapshotSha256 = $soloRaidSnapshotSha256
    dpapiSecretFileCount = 2
    postgreSqlStarted = $true
    adminApiStarted = $true
    oneTimeBootstrapExchanged = $true
    authenticatedAccountReadVerified = $true
    runtimeColdAfterSmoke = $true
    databaseModified = $false
    gameRuntimeStarted = $false
    goldenModified = $false
    officialInstallModified = $false
    dBackupModified = $false
    verdictCode = 'phase_d_control_center_installation_operational'
}
$receiptPath = Join-Path $receiptRoot 'smoke.receipt.json'
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $receiptPath
    ReceiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 10
