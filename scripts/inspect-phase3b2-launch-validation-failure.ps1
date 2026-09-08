[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Management.Automation.PSCredential]$GuestCredential,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$OutputRoot =
        "$env:LOCALAPPDATA\NikkeLocalLab\compatibility\evidence\phase3b2-wave1-hyperv\6899bf08-ee37-4c3a-9901-241bd22c3e9b"
)

$ErrorActionPreference = "Stop"
$session = $null

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"

$assessmentUid = "6899bf08-ee37-4c3a-9901-241bd22c3e9b"
$outputPath = Join-Path $OutputRoot `
    "launch-validation-failure.diagnostic.json"
$temporaryPath = $outputPath + ".tmp"
$readyPath = Join-Path $OutputRoot `
    "season26-classic-live-preflight.ready.json"
Assert-True ((Get-Item -LiteralPath $readyPath).Length -eq 4889 -and
    (Get-Sha256Hex $readyPath) -ceq
        "be4a5c90bdf0307d777de3c9492c20cbe668651ac04701eebd92af0e44182c6b") `
    "phase3b2_launch_validation_diagnostic_ready_drift"
Assert-True (-not (Test-Path -LiteralPath $outputPath) -and
    -not (Test-Path -LiteralPath $temporaryPath)) `
    "phase3b2_launch_validation_diagnostic_output_exists"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$managementAdapters = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object SwitchName -CEQ $SwitchName)
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $privateSwitch.SwitchType -eq
        [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $managementAdapters.Count -eq 0 -and
    $guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_launch_validation_diagnostic_environment_invalid"

try {
    $session = New-PSSession -VMName $VMName -Credential $GuestCredential
    $observation = Invoke-Command -Session $session -ScriptBlock {
        param([string]$AssessmentUid)

        $ErrorActionPreference = "Stop"
        function Assert-Guest {
            param([bool]$Condition, [string]$FailureCode)
            if (-not $Condition) { throw $FailureCode }
        }

        function Get-FileDigest {
            param([string]$Path)
            [ordered]@{
                byteLength = (Get-Item -LiteralPath $Path).Length
                sha256 = (Get-FileHash -LiteralPath $Path `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }

        function Get-TextDigest {
            param([string]$Text)
            $algorithm = [Security.Cryptography.SHA256]::Create()
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
                return (($algorithm.ComputeHash($bytes) |
                        ForEach-Object { $_.ToString("x2") }) -join "")
            }
            finally { $algorithm.Dispose() }
        }

        function Get-SanitizedFileSummary {
            param(
                [string]$RoleCode,
                [string]$Root,
                [DateTime]$NotBeforeUtc,
                [switch]$RecentOnly
            )

            if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
                return [ordered]@{
                    roleCode = $RoleCode
                    candidateFileCount = 0
                    matchedFileCount = 0
                    errorCodeMatchCount = 0
                    integrityTermFileCount = 0
                    sodiumTermFileCount = 0
                    certificateTermFileCount = 0
                    canonicalByteLength = 0
                    canonicalSha256 =
                        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                }
            }

            $allowedExtensions = @(
                ".log", ".txt", ".json", ".xml", ".ini", ".cfg",
                ".conf", ".manifest", ".dat", ".db"
            )
            $candidates = @(Get-ChildItem -LiteralPath $Root -Recurse -File `
                    -Force -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.Length -le 16MB -and
                    $allowedExtensions -contains $_.Extension.ToLowerInvariant() -and
                    (-not $RecentOnly -or $_.LastWriteTimeUtc -ge $NotBeforeUtc)
                })
            $members = [Collections.Generic.List[string]]::new()
            $matchedFileCount = 0
            $errorCodeMatchCount = 0
            $integrityTermFileCount = 0
            $sodiumTermFileCount = 0
            $certificateTermFileCount = 0
            foreach ($file in $candidates) {
                try {
                    $bytes = [IO.File]::ReadAllBytes($file.FullName)
                    $text = [Text.Encoding]::UTF8.GetString($bytes)
                }
                catch { continue }
                $errorCount = @([regex]::Matches($text, "1400003",
                        [Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
                $integrity = $text -match
                    "integrity|verify|verification|validation|file check|auth fail"
                $sodium = $text -match "sodium\.dll|libsodium"
                $certificate = $text -match
                    "intl_cacert\.pem|cacert\.pem|Good SSL Ca"
                if ($errorCount -gt 0 -or $integrity -or $sodium -or $certificate) {
                    $matchedFileCount++
                    $errorCodeMatchCount += $errorCount
                    if ($integrity) { $integrityTermFileCount++ }
                    if ($sodium) { $sodiumTermFileCount++ }
                    if ($certificate) { $certificateTermFileCount++ }
                    $relative = $file.FullName.Substring($Root.Length).
                        TrimStart("\")
                    $relativeDigest = Get-TextDigest ($relative.ToLowerInvariant())
                    $members.Add((@(
                                $relativeDigest,
                                [string]$file.Length,
                                (Get-FileHash -LiteralPath $file.FullName `
                                    -Algorithm SHA256).Hash.ToLowerInvariant(),
                                [string]$errorCount,
                                $integrity.ToString().ToLowerInvariant(),
                                $sodium.ToString().ToLowerInvariant(),
                                $certificate.ToString().ToLowerInvariant()
                            ) -join "`t"))
                }
            }
            $canonical = if ($members.Count -eq 0) { "" }
                else { (($members | Sort-Object) -join "`n") + "`n" }
            [ordered]@{
                roleCode = $RoleCode
                candidateFileCount = $candidates.Count
                matchedFileCount = $matchedFileCount
                errorCodeMatchCount = $errorCodeMatchCount
                integrityTermFileCount = $integrityTermFileCount
                sodiumTermFileCount = $sodiumTermFileCount
                certificateTermFileCount = $certificateTermFileCount
                canonicalByteLength =
                    [Text.UTF8Encoding]::new($false).GetByteCount($canonical)
                canonicalSha256 = Get-TextDigest $canonical
            }
        }

        $trustedRoot = Join-Path $env:LOCALAPPDATA `
            "NikkeLocalLab\Evidence\Phase3B2\Trusted"
        $runRoot = Join-Path $trustedRoot `
            "reference-private-v5\$AssessmentUid"
        $runStartPath = Join-Path $runRoot "run-start.receipt.json"
        $authPath = Join-Path $runRoot `
            "launcher-authenticated.receipt.json"
        $failurePath = Join-Path $runRoot `
            "client-launch-validation-failure.receipt.json"
        $p1Root = Join-Path $trustedRoot "p1-private-v4"
        $serverPidPath = Join-Path $p1Root "server.pid"
        foreach ($path in @($runStartPath, $authPath, $failurePath,
                $serverPidPath)) {
            Assert-Guest (Test-Path -LiteralPath $path -PathType Leaf) `
                "phase3b2_launch_validation_diagnostic_guest_evidence_missing"
        }

        $failure = Get-Content -LiteralPath $failurePath -Raw -Encoding UTF8 |
            ConvertFrom-Json
        Assert-Guest ($failure.contractId -ceq
                "nll/phase3b2-private-reference-run-failure/v6" -and
            $failure.assessmentUid -ceq $AssessmentUid -and
            [int]$failure.displayedErrorCode -eq 1400003 -and
            -not [bool]$failure.retryPerformed -and
            -not [bool]$failure.clientExecutionStarted) `
            "phase3b2_launch_validation_diagnostic_failure_invalid"

        $serverPid = [int](Get-Content -LiteralPath $serverPidPath -Raw).Trim()
        $server = @(Get-Process -Name EpinelPS -ErrorAction SilentlyContinue)
        $launcher = @(Get-Process -Name nikke_launcher `
                -ErrorAction SilentlyContinue)
        $client = @(Get-Process -Name nikke -ErrorAction SilentlyContinue)
        Assert-Guest ($server.Count -eq 1 -and $server[0].Id -eq $serverPid -and
            $launcher.Count -eq 1 -and $client.Count -eq 0) `
            "phase3b2_launch_validation_diagnostic_runtime_invalid"

        $processRows = @(Get-CimInstance Win32_Process -ErrorAction Stop |
            Select-Object ProcessId, ParentProcessId, Name)
        $treeIds = [Collections.Generic.HashSet[int]]::new()
        [void]$treeIds.Add([int]$launcher[0].Id)
        do {
            $added = 0
            foreach ($row in $processRows) {
                if ($treeIds.Contains([int]$row.ParentProcessId) -and
                    $treeIds.Add([int]$row.ProcessId)) { $added++ }
            }
        } while ($added -gt 0)
        $tree = @($processRows | Where-Object {
                $treeIds.Contains([int]$_.ProcessId)
            })
        $antiCheatNamePattern =
            "ACE|AntiCheat|TQM|TenProtect|SGuard|GameGuard"
        $antiCheatProcesses = @($processRows | Where-Object {
                $_.Name -match $antiCheatNamePattern
            })
        $antiCheatTreeMembers = @($tree | Where-Object {
                $_.Name -match $antiCheatNamePattern
            })
        $antiCheatServices = @(Get-CimInstance Win32_Service `
                -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match $antiCheatNamePattern -or
                $_.DisplayName -match $antiCheatNamePattern -or
                $_.PathName -match $antiCheatNamePattern
            })

        $notBefore = [DateTime]::Parse(
            "2026-08-22T04:53:00Z",
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal)
        $recentRoots = [ordered]@{
            launcher = "E:\Launcher"
            anti_cheat = "E:\NIKKE\game\AntiCheatExpert"
            tiny_cache = "E:\.tiny_cache"
        }
        $recentSummaries = @()
        foreach ($entry in $recentRoots.GetEnumerator()) {
            $recentSummaries += Get-SanitizedFileSummary `
                -RoleCode ([string]$entry.Key) -Root ([string]$entry.Value) `
                -NotBeforeUtc $notBefore -RecentOnly
        }
        $manifestSummaries = @(
            Get-SanitizedFileSummary -RoleCode "launcher_manifest_candidates" `
                -Root "E:\Launcher" -NotBeforeUtc $notBefore
            Get-SanitizedFileSummary -RoleCode "tiny_cache_manifest_candidates" `
                -Root "E:\.tiny_cache" -NotBeforeUtc $notBefore
        )

        $tcp = @(Get-NetTCPConnection -OwningProcess $serverPid -State Listen)
        $launcherConnections = @(Get-NetTCPConnection `
                -OwningProcess $launcher[0].Id -State Established `
                -ErrorAction SilentlyContinue)
        [ordered]@{
            contractId =
                "nll/phase3b2-launch-validation-diagnostic-observation/v1"
            observedAtUtc = [DateTimeOffset]::UtcNow.ToString(
                "yyyy-MM-dd'T'HH:mm:ss'Z'")
            assessmentUid = $AssessmentUid
            failureReceipt = Get-FileDigest $failurePath
            runStartReceipt = Get-FileDigest $runStartPath
            launcherAuthenticatedReceipt = Get-FileDigest $authPath
            serverProcessCount = $server.Count
            launcherProcessCount = $launcher.Count
            clientProcessCount = $client.Count
            launcherProcessTreeMemberCount = $tree.Count
            antiCheatProcessCount = $antiCheatProcesses.Count
            antiCheatLauncherTreeMemberCount = $antiCheatTreeMembers.Count
            antiCheatServiceCount = $antiCheatServices.Count
            runningAntiCheatServiceCount = @($antiCheatServices |
                    Where-Object State -EQ "Running").Count
            serverHttpLoopbackListenerCount = @($tcp | Where-Object {
                    $_.LocalAddress -eq "127.0.0.1" -and $_.LocalPort -eq 80
                }).Count
            serverHttpsLoopbackListenerCount = @($tcp | Where-Object {
                    $_.LocalAddress -eq "127.0.0.1" -and $_.LocalPort -eq 443
                }).Count
            launcherLoopbackConnectionCount = @($launcherConnections |
                    Where-Object RemoteAddress -In @("127.0.0.1", "::1")).Count
            launcherNonLoopbackConnectionCount = @($launcherConnections |
                    Where-Object RemoteAddress -NotIn @("127.0.0.1", "::1")).Count
            ipv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 `
                    -DestinationPrefix "0.0.0.0/0" `
                    -ErrorAction SilentlyContinue).Count
            ipv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 `
                    -DestinationPrefix "::/0" `
                    -ErrorAction SilentlyContinue).Count
            recentLogSummaries = $recentSummaries
            manifestCandidateSummaries = $manifestSummaries
            rawLogContentEmitted = $false
            rawLocalPathEmitted = $false
            serverRunning = $true
            launcherRunning = $true
            clientExecutionStarted = $false
            officialIdentityPersisted = $false
            officialCredentialPersisted = $false
        }
    } -ArgumentList $assessmentUid
}
finally {
    if ($null -ne $session) {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }
}

Assert-True ($observation.contractId -ceq
        "nll/phase3b2-launch-validation-diagnostic-observation/v1" -and
    $observation.assessmentUid -ceq $assessmentUid -and
    [int]$observation.serverProcessCount -eq 1 -and
    [int]$observation.launcherProcessCount -eq 1 -and
    [int]$observation.clientProcessCount -eq 0 -and
    [int]$observation.serverHttpLoopbackListenerCount -eq 1 -and
    [int]$observation.serverHttpsLoopbackListenerCount -eq 1 -and
    [int]$observation.launcherNonLoopbackConnectionCount -eq 0 -and
    [int]$observation.ipv4DefaultRouteCount -eq 0 -and
    [int]$observation.ipv6DefaultRouteCount -eq 0 -and
    -not [bool]$observation.rawLogContentEmitted -and
    -not [bool]$observation.rawLocalPathEmitted -and
    -not [bool]$observation.clientExecutionStarted) `
    "phase3b2_launch_validation_diagnostic_observation_invalid"

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
[IO.File]::WriteAllText(
    $temporaryPath,
    (($observation | ConvertTo-Json -Depth 8) + "`n"),
    [Text.UTF8Encoding]::new($false)
)
$saved = Get-Content -LiteralPath $temporaryPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($saved.contractId -ceq $observation.contractId -and
    $saved.assessmentUid -ceq $assessmentUid -and
    -not [bool]$saved.clientExecutionStarted) `
    "phase3b2_launch_validation_diagnostic_write_invalid"
Move-Item -LiteralPath $temporaryPath -Destination $outputPath

[pscustomobject]@{
    contractId = "nll/phase3b2-launch-validation-diagnostic/v1"
    assessmentUid = $assessmentUid
    outputByteLength = (Get-Item -LiteralPath $outputPath).Length
    outputSha256 = Get-Sha256Hex $outputPath
    launcherProcessTreeMemberCount =
        [int]$observation.launcherProcessTreeMemberCount
    antiCheatProcessCount = [int]$observation.antiCheatProcessCount
    antiCheatLauncherTreeMemberCount =
        [int]$observation.antiCheatLauncherTreeMemberCount
    antiCheatServiceCount = [int]$observation.antiCheatServiceCount
    runningAntiCheatServiceCount =
        [int]$observation.runningAntiCheatServiceCount
    recentLogSummaries = $observation.recentLogSummaries
    manifestCandidateSummaries = $observation.manifestCandidateSummaries
    serverRunning = $true
    launcherRunning = $true
    clientExecutionStarted = $false
    nextStepCode = "classify_launcher_vs_anticheat_integrity_gate"
} | ConvertTo-Json -Depth 8
