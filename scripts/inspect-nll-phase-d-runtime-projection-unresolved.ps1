[CmdletBinding()]
param(
    [string]$InstallRoot = 'C:\NLL\ControlCenter',
    [string]$RepositoryRoot = 'C:\Users\nlloperator\Documents\Github\Nikke-Local-Lab',
    [ValidateRange(1024, 65535)] [int]$DatabasePort = 55433,
    [ValidateRange(1024, 65535)] [int]$AdminPort = 17878
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

function Assert-Inspection {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

function Test-InspectionBooleanProperty {
    param(
        [object]$Value,
        [string[]]$PropertyNames
    )
    foreach ($propertyName in $PropertyNames) {
        $property = $Value.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $property.Value -eq $true) {
            return $true
        }
    }
    return $false
}

function Unprotect-InspectionSecret {
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

function Test-InspectionPort {
    param([int]$Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync('127.0.0.1', $Port)
        $task.Wait(800) -and $client.Connected
    }
    catch { $false }
    finally { $client.Dispose() }
}

function Get-CharacterName {
    param([Collections.IDictionary]$Names, [string]$CharacterUid)
    if ($Names.Contains($CharacterUid)) { return [string]$Names[$CharacterUid] }
    '이름 매핑 없음'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
Assert-Inspection (
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and
    $env:USERNAME -ceq 'nlloperator' -and
    $env:SystemDrive -ceq 'C:') 'phase_d_unresolved_inspection_boundary_invalid'
Assert-Inspection (
    @(Get-Process -Name postgres,EpinelPS,nikke -ErrorAction SilentlyContinue).Count -eq 0) `
    'phase_d_unresolved_inspection_runtime_not_cold'
Assert-Inspection (
    -not (Test-InspectionPort $DatabasePort) -and
    -not (Test-InspectionPort $AdminPort)) 'phase_d_unresolved_inspection_port_in_use'

$pgCtl = 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
$dataRoot = Join-Path $InstallRoot 'postgresql\data'
$postgresLog = Join-Path $InstallRoot 'logs\postgresql.log'
$bootstrapPath = Join-Path $InstallRoot 'session\unresolved-inspection-bootstrap.secret'
$adminStdout = Join-Path $InstallRoot 'logs\unresolved-inspection-admin.stdout.log'
$adminStderr = Join-Path $InstallRoot 'logs\unresolved-inspection-admin.stderr.log'
$presentationPath = Join-Path $InstallRoot 'app\wwwroot\editor\presentation.json'
$databasePassword = Unprotect-InspectionSecret (
    Join-Path $InstallRoot 'secrets\database-password.dpapi')
$identitySecret = Unprotect-InspectionSecret (
    Join-Path $InstallRoot 'secrets\identity-secret.dpapi')
$postgresStarted = $false
$admin = $null
$accountInspections = @()

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
    Assert-Inspection ($LASTEXITCODE -eq 0) 'phase_d_unresolved_inspection_postgresql_start_failed'
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
    Assert-Inspection (
        -not $admin.HasExited -and
        (Test-Path -LiteralPath $bootstrapPath -PathType Leaf)) `
        'phase_d_unresolved_inspection_admin_start_failed'

    $bootstrapCode = (Get-Content -LiteralPath $bootstrapPath -Raw).Trim()
    Assert-Inspection (
        -not [string]::IsNullOrWhiteSpace($bootstrapCode)) `
        'phase_d_unresolved_inspection_bootstrap_missing'
    Remove-Item -LiteralPath $bootstrapPath -Force

    $baseUri = "http://127.0.0.1:$AdminPort"
    $webSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $bootstrapResponse = Invoke-WebRequest `
        -UseBasicParsing `
        -Uri ($baseUri + '/admin-auth/v1/bootstrap') `
        -Method Post `
        -ContentType 'application/json' `
        -Headers @{ Origin = $baseUri } `
        -Body (@{ code = $bootstrapCode } | ConvertTo-Json -Compress) `
        -WebSession $webSession
    Assert-Inspection (
        $bootstrapResponse.StatusCode -eq 204) `
        'phase_d_unresolved_inspection_bootstrap_exchange_failed'
    $sessionMatch = [regex]::Match(
        [string]$bootstrapResponse.Headers['Set-Cookie'],
        '(?:^|,\s*)nll_admin_session=([^;]+)')
    Assert-Inspection $sessionMatch.Success 'phase_d_unresolved_inspection_session_cookie_missing'
    $sessionCookie = New-Object Net.Cookie(
        'nll_admin_session',
        $sessionMatch.Groups[1].Value,
        '/admin-api',
        '127.0.0.1')
    $sessionCookie.HttpOnly = $true
    $webSession.Cookies.Add($sessionCookie)

    $presentation = Get-Content -LiteralPath $presentationPath -Raw | ConvertFrom-Json
    $characterNames = @{}
    foreach ($character in $presentation.characters) {
        $characterNames[[string]$character.characterUid] = [string]$character.displayName
    }

    $accountResponse = Invoke-RestMethod `
        -Uri ($baseUri + '/admin-api/v1/accounts') `
        -WebSession $webSession
    $accounts = @($accountResponse | ForEach-Object { $_ })
    foreach ($account in $accounts) {
        $accountUid = [string]$account.accountUid
        $escapedAccountUid = [Uri]::EscapeDataString($accountUid)
        $profile = Invoke-RestMethod `
            -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/profile") `
            -WebSession $webSession
        $bootstrap = $null
        $bootstrapReadCode = 'ready'
        try {
            $bootstrap = Invoke-RestMethod `
                -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/bootstrap") `
                -WebSession $webSession
        }
        catch {
            $bootstrapReadCode = 'bootstrap_projection_unavailable'
            if ($null -ne $_.Exception.Response) {
                $responseStream = $_.Exception.Response.GetResponseStream()
                if ($null -ne $responseStream) {
                    $reader = [IO.StreamReader]::new($responseStream)
                    try {
                        $errorPayload = $reader.ReadToEnd() | ConvertFrom-Json
                        if (-not [string]::IsNullOrWhiteSpace([string]$errorPayload.code)) {
                            $bootstrapReadCode = [string]$errorPayload.code
                        }
                    }
                    finally {
                        $reader.Dispose()
                        $responseStream.Dispose()
                    }
                }
            }
        }
        $candidate = Invoke-RestMethod `
            -Uri ($baseUri + "/admin-api/v1/accounts/$escapedAccountUid/runtime-projection-candidate") `
            -WebSession $webSession
        $values = @($candidate.values)
        $unresolved = @($values | Where-Object { $_.status -ceq 'unresolved' })
        $negativeOverloadApplicationValues = @($values | Where-Object {
            $_.status -ceq 'ready' -and
            [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.overload\.[1-3]\.value$' -and
            $null -ne $_.unscaledValue -and
            [long]$_.unscaledValue -lt 0
        })
        $manufacturer = @($unresolved | Where-Object {
            [string]$_.fieldCode -match '^equipment\.(head|torso|arms|legs)\.manufacturer_matched$'
        })
        $bond = @($unresolved | Where-Object { [string]$_.fieldCode -ceq 'bond_level' })
        $bootstrapRoster = @()
        $bootstrapSquad = $null
        if ($null -ne $bootstrap) {
            $bootstrapRoster = @($bootstrap.roster)
            $bootstrapSquad = $bootstrap.squad
        }

        $accountInspections += [pscustomobject]@{
            accountUid = $accountUid
            accountLabel = [string]$account.accountLabel
            validationStatusCode = [string]$candidate.validationStatusCode
            validationReasonCodes = @($candidate.validationReasonCodes)
            profileIsSelectionReady = [bool]$profile.isSelectionReady
            profileHasCompleteCombatSemantics = [bool]$profile.hasCompleteCombatSemantics
            profileIsGameLegalReady = [bool]$profile.isGameLegalReady
            profileIssueCount = @($profile.issues).Count
            profileIssuesByCode = @($profile.issues |
                Group-Object code |
                Sort-Object Name |
                ForEach-Object {
                    [pscustomobject]@{ issueCode = $_.Name; count = $_.Count }
                })
            bootstrapReadCode = $bootstrapReadCode
            rosterCount = $bootstrapRoster.Count
            rosterSelectionReadyCount = @($bootstrapRoster | Where-Object {
                Test-InspectionBooleanProperty $_ @('isSelectionReady')
            }).Count
            rosterCombatSemanticsReadyCount = @($bootstrapRoster | Where-Object {
                Test-InspectionBooleanProperty $_ @(
                    'hasCombatSemantics',
                    'hasCompleteCombatSemantics')
            }).Count
            squadConfigured = if ($null -eq $bootstrap) { $null } else { $null -ne $bootstrapSquad }
            squadMemberCount = if ($null -eq $bootstrapSquad) {
                0
            }
            else {
                @($bootstrapSquad.members).Count
            }
            valueCount = $values.Count
            readyCount = @($values | Where-Object { $_.status -ceq 'ready' }).Count
            notApplicableCount = @($values | Where-Object {
                $_.status -ceq 'not_applicable'
            }).Count
            unresolvedCount = $unresolved.Count
            negativeOverloadApplicationValueCount =
                $negativeOverloadApplicationValues.Count
            unresolvedByReason = @($unresolved |
                Group-Object reasonCode |
                Sort-Object Name |
                ForEach-Object {
                    [pscustomobject]@{ reasonCode = $_.Name; count = $_.Count }
                })
            unresolvedByField = @($unresolved |
                Group-Object fieldCode |
                Sort-Object Name |
                ForEach-Object {
                    [pscustomobject]@{ fieldCode = $_.Name; count = $_.Count }
                })
            bondCharacters = @($bond | ForEach-Object {
                [pscustomobject]@{
                    characterUid = [string]$_.subjectUid
                    characterName = Get-CharacterName $characterNames ([string]$_.subjectUid)
                    reasonCode = [string]$_.reasonCode
                }
            } | Sort-Object characterName,characterUid)
            manufacturerCharacterCount = @(
                $manufacturer |
                ForEach-Object { [string]$_.subjectUid } |
                Sort-Object -Unique).Count
            manufacturerBySlot = @($manufacturer |
                ForEach-Object {
                    [regex]::Match([string]$_.fieldCode, '^equipment\.([^.]+)\.').Groups[1].Value
                } |
                Group-Object |
                Sort-Object Name |
                ForEach-Object { [pscustomobject]@{ slot = $_.Name; count = $_.Count } })
            manufacturerCharacters = @($manufacturer |
                Group-Object subjectUid |
                ForEach-Object {
                    $characterUid = [string]$_.Name
                    [pscustomobject]@{
                        characterUid = $characterUid
                        characterName = Get-CharacterName $characterNames $characterUid
                        slots = @($_.Group | ForEach-Object {
                            [regex]::Match(
                                [string]$_.fieldCode,
                                '^equipment\.([^.]+)\.').Groups[1].Value
                        } | Sort-Object)
                    }
                } | Sort-Object characterName,characterUid)
        }
    }
}
finally {
    if ($null -ne $admin -and -not $admin.HasExited) {
        Stop-Process -Id $admin.Id -Force -ErrorAction SilentlyContinue
        [void]$admin.WaitForExit(10000)
    }
    foreach ($logPath in @($adminStdout,$adminStderr)) {
        if (Test-Path -LiteralPath $logPath) {
            Remove-Item -LiteralPath $logPath -Force
        }
    }
    if (Test-Path -LiteralPath $bootstrapPath) {
        Remove-Item -LiteralPath $bootstrapPath -Force
    }
    if ($postgresStarted -or (Test-Path -LiteralPath (Join-Path $dataRoot 'postmaster.pid'))) {
        & $pgCtl stop -D $dataRoot -m fast -w -t 60 2>$null
    }
    foreach ($name in @(
        'NIKKE_LAB_DB','NIKKE_LAB_ID_SECRET','NIKKE_LAB_HOME','NIKKE_LAB_PROFILE_RAW',
        'NLL_CONTROL_CENTER_BOOTSTRAP_PATH','NLL_CONTROL_CENTER_PG_CTL',
        'NLL_CONTROL_CENTER_PG_DATA','NLL_CONTROL_CENTER_PG_LOG','NLL_PHASE_D_CONTROL_CENTER')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $databasePassword = $null
    $identitySecret = $null
}

Assert-Inspection (
    @(Get-Process -Name postgres -ErrorAction SilentlyContinue).Count -eq 0 -and
    -not (Test-InspectionPort $DatabasePort) -and
    -not (Test-InspectionPort $AdminPort)) 'phase_d_unresolved_inspection_cleanup_failed'

$inspectionUid = [guid]::NewGuid().ToString('D')
$receiptRoot = Join-Path $InstallRoot ('source-free\unresolved-inspections\' + $inspectionUid)
New-Item -ItemType Directory -Path $receiptRoot -Force | Out-Null
$receipt = [ordered]@{
    schemaVersion = 1
    contractId = 'nll/phase-d-runtime-projection-unresolved-inspection/v1'
    inspectedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    inspectionUid = $inspectionUid
    accounts = $accountInspections
    accountCount = $accountInspections.Count
    databaseModified = $false
    gameRuntimeStarted = $false
    officialOutboundUsed = $false
    credentialPersisted = $false
    runtimeColdAfterInspection = $true
}
$receiptPath = Join-Path $receiptRoot 'inspection.receipt.json'
[IO.File]::WriteAllText(
    $receiptPath,
    (($receipt | ConvertTo-Json -Depth 10) + "`n"),
    [Text.UTF8Encoding]::new($false))
[pscustomobject]@{
    Receipt = $receipt
    ReceiptPath = $receiptPath
    ReceiptSha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
} | ConvertTo-Json -Depth 11
