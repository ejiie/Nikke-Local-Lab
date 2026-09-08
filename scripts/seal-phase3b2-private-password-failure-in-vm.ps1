[CmdletBinding()]
param(
    [string]$AssessmentUid = "812c585b-2849-474f-a9ff-dfb59feaea87",
    [string]$EpinelRoot = "C:\NLL\EpinelPS",
    [string]$LauncherRoot = "E:\Launcher"
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-DescendantProcessIds {
    param([int[]]$RootIds, [object[]]$Processes)
    $result = [Collections.Generic.HashSet[int]]::new()
    foreach ($id in $RootIds) { $null = $result.Add($id) }
    do {
        $changed = $false
        foreach ($process in $Processes) {
            if ($result.Contains([int]$process.ParentProcessId) -and
                $result.Add([int]$process.ProcessId)) {
                $changed = $true
            }
        }
    } while ($changed)
    return @($result)
}

function Get-WfpEventFacts {
    param([DateTime]$StartTime, [int[]]$ProcessIds, [string]$PathPrefix)
    $allowedLoopback = 0
    $blockedLoopback = 0
    $allowedNonLoopback = 0
    $blockedNonLoopback = 0
    $events = @(Get-WinEvent -FilterHashtable @{
            LogName = "Security"
            Id = @(5156, 5157)
            StartTime = $StartTime
        } -ErrorAction SilentlyContinue)
    foreach ($event in $events) {
        [xml]$xml = $event.ToXml()
        $data = @{}
        foreach ($node in $xml.Event.EventData.Data) {
            $data[[string]$node.Name] = [string]$node.'#text'
        }
        $processId = 0
        $processIdMatched = [int]::TryParse([string]$data.ProcessID, [ref]$processId) -and
            $ProcessIds -contains $processId
        $application = [string]$data.Application
        $pathMatched = -not [string]::IsNullOrWhiteSpace($application) -and
            $application.StartsWith($PathPrefix, [StringComparison]::OrdinalIgnoreCase)
        if (-not $processIdMatched -and -not $pathMatched) { continue }
        $remote = [string]$data.DestAddress
        if ([string]::IsNullOrWhiteSpace($remote)) { $remote = [string]$data.RemoteAddress }
        $loopback = $remote -in @("127.0.0.1", "::1", "0.0.0.0", "::", "-")
        if ($event.Id -eq 5156) {
            if ($loopback) { $allowedLoopback++ } else { $allowedNonLoopback++ }
        }
        else {
            if ($loopback) { $blockedLoopback++ } else { $blockedNonLoopback++ }
        }
    }
    return [ordered]@{
        allowedLoopback = $allowedLoopback
        blockedLoopback = $blockedLoopback
        allowedNonLoopback = $allowedNonLoopback
        blockedNonLoopback = $blockedNonLoopback
    }
}

Assert-True ($AssessmentUid -cmatch
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') `
    "phase3b2_password_failure_assessment_uid_invalid"
Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) "administrator_required"

$trustedRoot = Join-Path $env:LOCALAPPDATA "NikkeLocalLab\Evidence\Phase3B2\Trusted"
$identityRoot = Join-Path $trustedRoot "identity"
$contextPath = Join-Path $identityRoot "synthetic-context.json"
$serverRoot = Join-Path $EpinelRoot "EpinelPS\bin\Release\net10.0\win-x64"
$dbPath = Join-Path $serverRoot "db.json"
$priorP1Path = Join-Path $trustedRoot `
    "p1-private-v2\server-only-measurement.receipt.json"
$outputRoot = Join-Path $trustedRoot "reference-failures\$AssessmentUid"
$outputPath = Join-Path $outputRoot "password-representation-mismatch.receipt.json"
Assert-True (-not (Test-Path -LiteralPath $outputPath)) `
    "phase3b2_password_failure_receipt_exists"
Assert-True ((Get-Item -LiteralPath $priorP1Path).Length -eq 2761 -and
    (Get-FileHash -LiteralPath $priorP1Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
        "bae2087dcca0ce6645a5079418301ced1eff7d1df5546fccf04e0e4e913bf342") `
    "phase3b2_password_failure_prior_p1_receipt_drift"
$priorP1 = Get-Content -LiteralPath $priorP1Path -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($priorP1.contractId -ceq
        "nll/phase3b2-p1-private-server-only-measurement/v2" -and
    [bool]$priorP1.serverExecutionStarted -and [bool]$priorP1.serverRunning -and
    -not [bool]$priorP1.clientExecutionStarted -and
    [int]$priorP1.httpIpv4LoopbackListenerCount -eq 1 -and
    [int]$priorP1.httpsIpv4LoopbackListenerCount -eq 1 -and
    [int]$priorP1.nonLoopbackAttemptCount -eq 0 -and
    [int]$priorP1.nonLoopbackSuccessfulConnectionCount -eq 0) `
    "phase3b2_password_failure_prior_p1_receipt_invalid"

$context = Get-Content -LiteralPath $contextPath -Raw -Encoding UTF8 | ConvertFrom-Json
$db = Get-Content -LiteralPath $dbPath -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($context.contractId -ceq "nll/phase3b2-synthetic-runtime-context/v1" -and
    @($db.Users).Count -eq 1 -and
    [string]$db.Users[0].Username -ceq [string]$context.username) `
    "phase3b2_password_failure_synthetic_identity_shape_invalid"
$contextPassword = [string]$context.password
$databasePassword = [string]$db.Users[0].Password
$decoded = $null
try { $decoded = [Convert]::FromBase64String($contextPassword) } catch { $decoded = $null }
$md5 = [Security.Cryptography.MD5]::Create()
try {
    $expectedLauncherHash = (($md5.ComputeHash(
                    [Text.Encoding]::ASCII.GetBytes($contextPassword)) |
                ForEach-Object { $_.ToString("x2") }) -join "")
}
finally { $md5.Dispose() }
Assert-True ($contextPassword.Length -eq 44 -and $null -ne $decoded -and
    $decoded.Length -eq 32 -and $databasePassword -ceq $contextPassword -and
    $databasePassword -cne $expectedLauncherHash -and
    $expectedLauncherHash -cmatch '^[0-9a-f]{32}$') `
    "phase3b2_password_failure_representation_mismatch_not_reproduced"

$serverProcesses = @(Get-Process -Name EpinelPS -ErrorAction SilentlyContinue)
$launcherRoots = @(Get-Process -Name nikke_launcher -ErrorAction SilentlyContinue)
$gameProcesses = @(Get-Process -Name nikke -ErrorAction SilentlyContinue)
Assert-True ($serverProcesses.Count -eq 0 -and $launcherRoots.Count -eq 1 -and
    $gameProcesses.Count -eq 0) "phase3b2_password_failure_runtime_shape_invalid"
$processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
$launcherProcessIds = @(Get-DescendantProcessIds @($launcherRoots[0].Id) $processes)

$tcp = @(Get-NetTCPConnection -ErrorAction SilentlyContinue)
$serverListeners = @()
$http = @($serverListeners | Where-Object {
        $_.LocalAddress -ceq "127.0.0.1" -and $_.LocalPort -eq 80
    })
$https = @($serverListeners | Where-Object {
        $_.LocalAddress -ceq "127.0.0.1" -and $_.LocalPort -eq 443
    })
$unexpectedListeners = @($serverListeners | Where-Object {
        -not ($_.LocalAddress -ceq "127.0.0.1" -and $_.LocalPort -in @(80, 443))
    })
$launcherConnections = @($tcp | Where-Object {
        $launcherProcessIds -contains [int]$_.OwningProcess -and $_.State -notin @("Listen", "Closed")
    })
$loopbackConnections = @($launcherConnections | Where-Object {
        $_.RemoteAddress -in @("127.0.0.1", "::1")
    })
$nonLoopbackConnections = @($launcherConnections | Where-Object {
        $_.RemoteAddress -notin @("127.0.0.1", "::1", "0.0.0.0", "::")
    })
$ipv4Routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive")
$ipv6Routes = @(Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" `
        -ErrorAction SilentlyContinue | Where-Object State -EQ "Alive")
Assert-True ($http.Count -eq 0 -and $https.Count -eq 0 -and
    $unexpectedListeners.Count -eq 0 -and $nonLoopbackConnections.Count -eq 0 -and
    $ipv4Routes.Count -eq 0 -and $ipv6Routes.Count -eq 0) `
    "phase3b2_password_failure_isolation_drift"

$startedAt = [DateTimeOffset]::Parse("2026-08-22T01:59:49Z").LocalDateTime
$wfp = Get-WfpEventFacts $startedAt $launcherProcessIds `
    ([IO.Path]::GetFullPath($LauncherRoot).TrimEnd('\') + '\')
Assert-True ($wfp.allowedNonLoopback -eq 0 -and $wfp.blockedNonLoopback -eq 0) `
    "phase3b2_password_failure_nonloopback_event_observed"

$receipt = [ordered]@{
    contractId = "nll/phase3b2-private-reference-run-failure/v3"
    failedAtUtc = [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    assessmentUid = $AssessmentUid
    failedTransitionCode = "local_login_submission"
    reasonCode = "launcher_password_representation_mismatch"
    displayedResultCode = 5
    displayedBackendCode = 2002
    retryPerformed = $false
    networkModeCode = "private_vm_only_no_gateway"
    ipv4DefaultRouteCount = 0
    ipv6DefaultRouteCount = 0
    launcherProcessTreeMemberCount = $launcherProcessIds.Count
    launcherCurrentLoopbackConnectionCount = $loopbackConnections.Count
    launcherCurrentNonLoopbackConnectionCount = 0
    launcherAllowedLoopbackEventCount = $wfp.allowedLoopback
    launcherBlockedLoopbackEventCount = $wfp.blockedLoopback
    launcherAllowedNonLoopbackEventCount = 0
    launcherBlockedNonLoopbackEventCount = 0
    priorP1ReceiptByteLength = 2761
    priorP1ReceiptSha256 =
        "bae2087dcca0ce6645a5079418301ced1eff7d1df5546fccf04e0e4e913bf342"
    priorP1ServerRunning = $true
    priorP1HttpLoopbackListenerCount = 1
    priorP1HttpsLoopbackListenerCount = 1
    currentServerProcessCount = 0
    currentServerHttpLoopbackListenerCount = 0
    currentServerHttpsLoopbackListenerCount = 0
    serverContinuityLostAfterDisplayedFailure = $true
    launcherCertificateBundlePatched = $true
    actualLauncherReachedLocalAccountLogin = $true
    syntheticContextPasswordLength = $contextPassword.Length
    syntheticContextPasswordDecodesToByteLength = $decoded.Length
    databasePasswordEqualsContextPlaintext = $true
    databasePasswordMatchesLauncherMd5 = $false
    diagnosedStorageSchemeCode = "plaintext_instead_of_md5_lower_hex"
    operatorScreenshotAttachedExternally = $true
    serverRunning = $false
    launcherExecutionStarted = $true
    clientExecutionStarted = $false
    officialIdentityPersisted = $false
    officialCredentialPersisted = $false
    nextStepCode = "restore_launcher_ca_p0_repair_synthetic_credential_reseal"
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
Write-Utf8NoBom $outputPath (($receipt | ConvertTo-Json -Depth 5) + "`n")
$receipt | ConvertTo-Json -Depth 5
