[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Management.Automation.PSCredential]$GuestCredential,

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot =
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence",
    [string]$CompatibilityEvidenceRoot =
        "$env:LOCALAPPDATA\NikkeLocalLab\compatibility\evidence\phase3b2-wave1-hyperv",
    [string]$OperatorTranscriptPath =
        "C:\Users\ccccc\.codex\attachments\59e1e803-6f86-4ade-ba40-dcb40646501b\pasted-text.txt"
)

$ErrorActionPreference = "Stop"
$preRestoreSession = $null
$postRestoreSession = $null

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

function Get-Sha256Hex {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-TextSha256 {
    param([string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return (($algorithm.ComputeHash($bytes) |
                ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally { $algorithm.Dispose() }
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 8) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function Wait-VMRunning {
    param([string]$Name)
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        $candidate = Get-VM -Name $Name -ErrorAction Stop
        if ($candidate.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running) {
            return $candidate
        }
        if ($candidate.State -eq [Microsoft.HyperV.PowerShell.VMState]::Off -or
            $candidate.State -eq [Microsoft.HyperV.PowerShell.VMState]::Saved) {
            Start-VM -VM $candidate -ErrorAction SilentlyContinue | Out-Null
        }
        Start-Sleep -Seconds 1
    }
    throw "phase3b2_operator_close_restore_vm_not_running"
}

function New-GuestSession {
    param([string]$Name, [Management.Automation.PSCredential]$Credential)
    for ($attempt = 0; $attempt -lt 90; $attempt++) {
        try {
            return New-PSSession -VMName $Name -Credential $Credential `
                -ErrorAction Stop
        }
        catch { Start-Sleep -Seconds 1 }
    }
    throw "phase3b2_operator_close_powershell_direct_unavailable"
}

function Resolve-Pwsh {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $command) { return $command.Source }

    $candidates = @(
        "C:\Program Files\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Programs\PowerShell\7\pwsh.exe",
        (Join-Path $env:USERPROFILE `
            ".cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe")
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    $bundledRoot = Join-Path $env:USERPROFILE ".cache\codex-runtimes"
    $bundled = if (Test-Path -LiteralPath $bundledRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $bundledRoot -Recurse -File `
                -Filter pwsh.exe -ErrorAction SilentlyContinue |
            Where-Object FullName -Like "*\dependencies\native\powershell\pwsh.exe" |
            Sort-Object FullName)
    }
    else { @() }
    Assert-True ($bundled.Count -ge 1) "phase3b2_operator_close_pwsh_not_found"
    return $bundled[0].FullName
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$failedAssessmentUid = "e9ffbb20-2e97-4488-977f-cb1554b32c84"
$failedAssessmentRoot = Join-Path $CompatibilityEvidenceRoot $failedAssessmentUid
$failedReadyPath = Join-Path $failedAssessmentRoot `
    "season26-classic-live-preflight.ready.json"
$localRunStartPath = Join-Path $failedAssessmentRoot `
    "reference-run-start.overwritten-observation.json"
$localFailurePath = Join-Path $failedAssessmentRoot `
    "reference-run-operator-close.failure.json"
$projectionTranscriptPath = Join-Path $failedAssessmentRoot `
    "post-restore-ready-projection.transcript.json"
$checkpointReceiptPath = Join-Path $EvidenceRoot `
    "p0-private-sqlite-reset-checkpoint-v1.json"
$transferReceiptPath = Join-Path $EvidenceRoot `
    "sqlite-rebootstrap-run-tool-transfer-v1.receipt.json"
$extractionReceiptPath = Join-Path $EvidenceRoot `
    "operator-close-failure-extraction-e9ffbb20.receipt.json"
$restoreReceiptPath = Join-Path $EvidenceRoot `
    "operator-close-failure-restore-e9ffbb20.receipt.json"

Assert-True ((Get-Item -LiteralPath $checkpointReceiptPath).Length -eq 1887 -and
    (Get-Sha256Hex $checkpointReceiptPath) -ceq
        "d92ee1498ab276ad41aa52967a024368dc47c41f93e472f3c76e6c34270211b8") `
    "phase3b2_operator_close_checkpoint_receipt_drift"
Assert-True ((Get-Item -LiteralPath $failedReadyPath).Length -eq 4889 -and
    (Get-Sha256Hex $failedReadyPath) -ceq
        "2e6f13c4c81913f9ec5a72070675fbd4bf42e140ba9bd904d411c8a9ecd2d6b9") `
    "phase3b2_operator_close_ready_receipt_drift"
Assert-True ((Get-Item -LiteralPath $OperatorTranscriptPath).Length -eq 6305 -and
    (Get-Sha256Hex $OperatorTranscriptPath) -ceq
        "227a06d2726662cf81c049f52051a2060d5a683a1b0ce5c6bc1220dbe6c9cac2") `
    "phase3b2_operator_close_transcript_drift"

$checkpoint = Get-Content -LiteralPath $checkpointReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($checkpoint.contractId -ceq
        "nll/phase3b2-p0-private-sqlite-credential-checkpoint/v1" -and
    $checkpoint.checkpointIdentitySha256 -ceq
        "89251c58622331d18a0580e2eceb234cb973ecbac17fcbe04a08762c45876e80" -and
    [int]$checkpoint.currentCheckpointCount -eq 9 -and
    [int]$checkpoint.sqliteRuntimeMemberCount -eq 0 -and
    [bool]$checkpoint.sqliteCredentialRebootstrapPrepared -and
    -not [bool]$checkpoint.sqliteCredentialBindingVerified -and
    -not [bool]$checkpoint.guestServiceEnabled -and
    -not [bool]$checkpoint.serverExecutionStarted -and
    -not [bool]$checkpoint.clientExecutionStarted) `
    "phase3b2_operator_close_checkpoint_receipt_invalid"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(Get-VM | Get-VMNetworkAdapter |
        Where-Object SwitchName -CEQ $SwitchName)
$managementAdapters = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object SwitchName -CEQ $SwitchName)
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ([string]$vm.Id -ceq
        "77d6f113-2f74-49e4-8fbf-0dc381232810" -and
    $vm.State -eq [Microsoft.HyperV.PowerShell.VMState]::Running -and
    $privateSwitch.SwitchType -eq
        [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0 -and
    $guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_operator_close_environment_invalid"

$snapshots = @(Get-VMSnapshot -VM $vm -ErrorAction Stop |
        Where-Object {
            $_.Name -like
                "NLL-P3B2-W1-P0-Private-SQLiteCredential-v1-*"
        })
Assert-True ($snapshots.Count -eq 1) `
    "phase3b2_operator_close_checkpoint_shape_invalid"
$snapshot = $snapshots[0]
$identityText = @(
    "contractId=nll/phase3b2-hyperv-private-sqlite-credential-checkpoint-identity/v1"
    "vmId=$($vm.Id)"
    "checkpointId=$($snapshot.Id)"
    "checkpointName=$($snapshot.Name)"
    "creationTimeUtc=$($snapshot.CreationTime.ToUniversalTime().ToString('o'))"
    "parentCheckpointIdentitySha256=80f2b7b9562220ac88a76a8f6135069eeb095017a4491713475ffa1c264287a2"
    "guestP0V4ReceiptByteLength=$($checkpoint.guestP0V4ReceiptByteLength)"
    "guestP0V4ReceiptSha256=$($checkpoint.guestP0V4ReceiptSha256)"
    "guestResetReceiptByteLength=$($checkpoint.guestResetReceiptByteLength)"
    "guestResetReceiptSha256=$($checkpoint.guestResetReceiptSha256)"
    "runToolTransferReceiptSha256=$(Get-Sha256Hex $transferReceiptPath)"
    "sqliteCredentialRebootstrapPrepared=true"
    "sqliteRuntimeMemberCount=0"
    "networkModeCode=private_vm_only_no_gateway"
) -join "`n"
Assert-True ((Get-TextSha256 ($identityText + "`n")) -ceq
        [string]$checkpoint.checkpointIdentitySha256) `
    "phase3b2_operator_close_checkpoint_identity_mismatch"

New-Item -ItemType Directory -Path $failedAssessmentRoot, $EvidenceRoot `
    -Force | Out-Null

# Seal and extract the operator-close failure once. A completed extraction is
# accepted on a resume, but a partial/unbound copy is not.
if (-not (Test-Path -LiteralPath $extractionReceiptPath)) {
    Assert-True (-not (Test-Path -LiteralPath $localFailurePath) -and
        -not (Test-Path -LiteralPath $localRunStartPath)) `
        "phase3b2_operator_close_partial_extraction_present"
    try {
        $preRestoreSession = New-GuestSession $VMName $GuestCredential
        $remote = Invoke-Command -Session $preRestoreSession -ScriptBlock {
            param(
                [string]$AssessmentUid,
                [long]$TranscriptByteLength,
                [string]$TranscriptSha256
            )

            $ErrorActionPreference = "Stop"
            function Assert-Guest {
                param([bool]$Condition, [string]$FailureCode)
                if (-not $Condition) { throw $FailureCode }
            }

            $trustedRoot = Join-Path $env:LOCALAPPDATA `
                "NikkeLocalLab\Evidence\Phase3B2\Trusted"
            $p1Root = Join-Path $trustedRoot "p1-private-v4"
            $p1Path = Join-Path $p1Root `
                "server-only-measurement.receipt.json"
            $serverPidPath = Join-Path $p1Root "server.pid"
            $runRoot = Join-Path $trustedRoot "reference-private-v4"
            $runStartPath = Join-Path $runRoot "run-start.receipt.json"
            $correctionPath = Join-Path $runRoot `
                "run-start-correction.receipt.json"
            $failurePath = Join-Path $runRoot `
                "operator-close-failure.receipt.json"

            Assert-Guest ((Get-Item -LiteralPath $p1Path).Length -eq 3138 -and
                (Get-FileHash -LiteralPath $p1Path -Algorithm SHA256).Hash.ToLowerInvariant() -ceq
                    "c698ef1275d169d52ca09f17b9821fd342d4d922387d6732b798d10219255a32") `
                "phase3b2_operator_close_guest_p1_drift"
            Assert-Guest ((Test-Path -LiteralPath $runStartPath -PathType Leaf) -and
                -not (Test-Path -LiteralPath $correctionPath) -and
                -not (Test-Path -LiteralPath $failurePath)) `
                "phase3b2_operator_close_guest_evidence_shape_invalid"

            $p1 = Get-Content -LiteralPath $p1Path -Raw -Encoding UTF8 |
                ConvertFrom-Json
            $runStart = Get-Content -LiteralPath $runStartPath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            $serverPid = [int](Get-Content -LiteralPath $serverPidPath -Raw).Trim()
            $server = @(Get-Process -Name EpinelPS -ErrorAction SilentlyContinue)
            $launcher = @(Get-Process -Name nikke_launcher `
                    -ErrorAction SilentlyContinue)
            $client = @(Get-Process -Name nikke -ErrorAction SilentlyContinue)
            Assert-Guest ($p1.contractId -ceq
                    "nll/phase3b2-p1-private-server-only-measurement/v4" -and
                $p1.serverRunning -and -not $p1.clientExecutionStarted -and
                $p1.sqliteCredentialBindingVerified -and
                $runStart.contractId -ceq
                    "nll/phase3b2-private-reference-launcher-start/v4" -and
                $runStart.assessmentUid -ceq $AssessmentUid -and
                $runStart.readyPreflightReceiptSha256 -ceq
                    "2e6f13c4c81913f9ec5a72070675fbd4bf42e140ba9bd904d411c8a9ecd2d6b9" -and
                $runStart.p0ReceiptSha256 -ceq
                    "3c2397c58fc59e5bfafdde2fee79054ce9d58af7cc25efb9d7b0ddf702a3698f" -and
                $runStart.p1ReceiptSha256 -ceq
                    "c698ef1275d169d52ca09f17b9821fd342d4d922387d6732b798d10219255a32" -and
                $runStart.sqliteCredentialBindingVerified -and
                $server.Count -eq 1 -and $server[0].Id -eq $serverPid -and
                $launcher.Count -eq 0 -and $client.Count -eq 0) `
                "phase3b2_operator_close_guest_runtime_shape_invalid"

            $tcp = @(Get-NetTCPConnection -OwningProcess $serverPid -State Listen)
            $udp443 = @(Get-NetUDPEndpoint -OwningProcess $serverPid `
                    -ErrorAction SilentlyContinue |
                Where-Object LocalPort -EQ 443)
            Assert-Guest (@($tcp | Where-Object {
                        $_.LocalAddress -eq "127.0.0.1" -and $_.LocalPort -eq 80
                    }).Count -eq 1 -and
                @($tcp | Where-Object {
                        $_.LocalAddress -eq "127.0.0.1" -and $_.LocalPort -eq 443
                    }).Count -eq 1 -and
                @($tcp | Where-Object LocalAddress -NE "127.0.0.1").Count -eq 0 -and
                $udp443.Count -eq 0) `
                "phase3b2_operator_close_guest_listener_shape_invalid"

            $runStartItem = Get-Item -LiteralPath $runStartPath
            $runStartSha = (Get-FileHash -LiteralPath $runStartPath `
                    -Algorithm SHA256).Hash.ToLowerInvariant()
            $receipt = [ordered]@{
                contractId = "nll/phase3b2-private-reference-run-failure/v5"
                failedAtUtc = [DateTimeOffset]::UtcNow.ToString(
                    "yyyy-MM-dd'T'HH:mm:ss'Z'")
                assessmentUid = $AssessmentUid
                failedTransitionCode = "launcher_start_continuity"
                reasonCode = "operator_closed_launcher_before_login"
                operatorAttestationCode = "manual_window_close_confirmed"
                retryPerformed = $false
                loginSubmitted = $false
                runStartReceiptMayHaveBeenOverwritten = $true
                runStartReceiptByteLength = $runStartItem.Length
                runStartReceiptSha256 = $runStartSha
                operatorCommandTranscriptByteLength = $TranscriptByteLength
                operatorCommandTranscriptSha256 = $TranscriptSha256
                priorP1ReceiptByteLength = 3138
                priorP1ReceiptSha256 =
                    "c698ef1275d169d52ca09f17b9821fd342d4d922387d6732b798d10219255a32"
                serverProcessId = $serverPid
                serverProcessContinuityVerified = $true
                currentServerProcessCount = 1
                currentLauncherProcessCount = 0
                currentClientProcessCount = 0
                currentHttpLoopbackListenerCount = 1
                currentHttpsLoopbackListenerCount = 1
                currentHttp3UdpListenerCount = 0
                sqliteCredentialBindingVerified = $true
                serverRunning = $true
                launcherExecutionStarted = $true
                launcherRunning = $false
                clientExecutionStarted = $false
                officialIdentityPersisted = $false
                officialCredentialPersisted = $false
                nextStepCode =
                    "restore_sqlite_reset_p0_create_new_assessment"
            }
            [IO.File]::WriteAllText(
                $failurePath,
                (($receipt | ConvertTo-Json) + "`n"),
                [Text.UTF8Encoding]::new($false)
            )
            [pscustomobject]@{
                FailurePath = $failurePath
                FailureByteLength = (Get-Item -LiteralPath $failurePath).Length
                FailureSha256 = (Get-FileHash -LiteralPath $failurePath `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                RunStartPath = $runStartPath
                RunStartByteLength = $runStartItem.Length
                RunStartSha256 = $runStartSha
            }
        } -ArgumentList $failedAssessmentUid, 6305,
            "227a06d2726662cf81c049f52051a2060d5a683a1b0ce5c6bc1220dbe6c9cac2"

        $failureTemp = $localFailurePath + ".tmp"
        $runStartTemp = $localRunStartPath + ".tmp"
        Copy-Item -FromSession $preRestoreSession -LiteralPath $remote.FailurePath `
            -Destination $failureTemp
        Copy-Item -FromSession $preRestoreSession -LiteralPath $remote.RunStartPath `
            -Destination $runStartTemp
        Assert-True ((Get-Item -LiteralPath $failureTemp).Length -eq
                [long]$remote.FailureByteLength -and
            (Get-Sha256Hex $failureTemp) -ceq [string]$remote.FailureSha256 -and
            (Get-Item -LiteralPath $runStartTemp).Length -eq
                [long]$remote.RunStartByteLength -and
            (Get-Sha256Hex $runStartTemp) -ceq [string]$remote.RunStartSha256) `
            "phase3b2_operator_close_extracted_copy_drift"
        Move-Item -LiteralPath $failureTemp -Destination $localFailurePath
        Move-Item -LiteralPath $runStartTemp -Destination $localRunStartPath
    }
    finally {
        if ($null -ne $preRestoreSession) {
            Remove-PSSession -Session $preRestoreSession `
                -ErrorAction SilentlyContinue
            $preRestoreSession = $null
        }
    }

    $failure = Get-Content -LiteralPath $localFailurePath -Raw -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($failure.contractId -ceq
            "nll/phase3b2-private-reference-run-failure/v5" -and
        $failure.assessmentUid -ceq $failedAssessmentUid -and
        $failure.reasonCode -ceq "operator_closed_launcher_before_login" -and
        -not [bool]$failure.retryPerformed -and
        -not [bool]$failure.loginSubmitted -and
        [bool]$failure.serverRunning -and
        -not [bool]$failure.launcherRunning -and
        -not [bool]$failure.clientExecutionStarted) `
        "phase3b2_operator_close_failure_receipt_invalid"
    $extractionReceipt = [ordered]@{
        contractId = "nll/phase3b2-operator-close-failure-extraction/v1"
        extractedAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'")
        sourceContractId = [string]$failure.contractId
        assessmentUid = $failedAssessmentUid
        failureReceiptByteLength = (Get-Item -LiteralPath $localFailurePath).Length
        failureReceiptSha256 = Get-Sha256Hex $localFailurePath
        runStartReceiptByteLength = (Get-Item -LiteralPath $localRunStartPath).Length
        runStartReceiptSha256 = Get-Sha256Hex $localRunStartPath
        operatorCommandTranscriptByteLength = 6305
        operatorCommandTranscriptSha256 =
            "227a06d2726662cf81c049f52051a2060d5a683a1b0ce5c6bc1220dbe6c9cac2"
        transportCode = "hyperv_powershell_direct"
        networkTransportUsed = $false
        guestOsCredentialPersisted = $false
        guestOsCredentialEmitted = $false
        clientExecutionStarted = $false
    }
    Write-JsonFile $extractionReceiptPath $extractionReceipt
}

$extraction = Get-Content -LiteralPath $extractionReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($extraction.contractId -ceq
        "nll/phase3b2-operator-close-failure-extraction/v1" -and
    $extraction.assessmentUid -ceq $failedAssessmentUid -and
    (Get-Item -LiteralPath $localFailurePath).Length -eq
        [long]$extraction.failureReceiptByteLength -and
    (Get-Sha256Hex $localFailurePath) -ceq
        [string]$extraction.failureReceiptSha256 -and
    -not [bool]$extraction.clientExecutionStarted) `
    "phase3b2_operator_close_extraction_receipt_invalid"

# Restore checkpoint 9 exactly once. If a verified restore receipt exists, the
# later P1/seal stages can resume without another restore.
if (-not (Test-Path -LiteralPath $restoreReceiptPath)) {
    Restore-VMSnapshot -VMSnapshot $snapshot -Confirm:$false
    $vm = Wait-VMRunning $VMName
    $postRestoreSession = New-GuestSession $VMName $GuestCredential
    try {
        $postRestore = Invoke-Command -Session $postRestoreSession -ScriptBlock {
            $trustedRoot = Join-Path $env:LOCALAPPDATA `
                "NikkeLocalLab\Evidence\Phase3B2\Trusted"
            $p0Path = Join-Path $trustedRoot `
                "p0\applied-verification-private-v4.receipt.json"
            $resetPath = Join-Path $trustedRoot `
                "identity\sqlite-credential-reset-v1\reset-preparation.receipt.json"
            $serverRoot =
                "C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64"
            [pscustomobject]@{
                ProcessCount = @(Get-Process -Name EpinelPS, nikke_launcher, nikke `
                        -ErrorAction SilentlyContinue).Count
                P0ByteLength = (Get-Item -LiteralPath $p0Path).Length
                P0Sha256 = (Get-FileHash -LiteralPath $p0Path `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                ResetByteLength = (Get-Item -LiteralPath $resetPath).Length
                ResetSha256 = (Get-FileHash -LiteralPath $resetPath `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                SqliteRuntimeMemberCount = @(
                    "epinelps.db", "epinelps.db-shm", "epinelps.db-wal" |
                        Where-Object {
                            Test-Path -LiteralPath (Join-Path $serverRoot $_)
                        }
                ).Count
                Ipv4DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv4 `
                        -DestinationPrefix "0.0.0.0/0" `
                        -ErrorAction SilentlyContinue).Count
                Ipv6DefaultRouteCount = @(Get-NetRoute -AddressFamily IPv6 `
                        -DestinationPrefix "::/0" `
                        -ErrorAction SilentlyContinue).Count
            }
        }
    }
    finally {
        Remove-PSSession -Session $postRestoreSession `
            -ErrorAction SilentlyContinue
        $postRestoreSession = $null
    }
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $snapshotAfter = @(Get-VMSnapshot -VM $vm -ErrorAction Stop |
            Where-Object { [string]$_.Id -ceq [string]$snapshot.Id })
    $guestServiceAfter = @(Get-VMIntegrationService -VM $vm |
            Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                    [StringComparison]::OrdinalIgnoreCase) })
    Assert-True ([int]$postRestore.ProcessCount -eq 0 -and
        [long]$postRestore.P0ByteLength -eq 2210 -and
        [string]$postRestore.P0Sha256 -ceq
            "3c2397c58fc59e5bfafdde2fee79054ce9d58af7cc25efb9d7b0ddf702a3698f" -and
        [long]$postRestore.ResetByteLength -eq 1071 -and
        [string]$postRestore.ResetSha256 -ceq
            "5b610e93c3f560f384a55602fd2d1ba9c7ae21efc5086b3be8daafff2f054f7f" -and
        [int]$postRestore.SqliteRuntimeMemberCount -eq 0 -and
        [int]$postRestore.Ipv4DefaultRouteCount -eq 0 -and
        [int]$postRestore.Ipv6DefaultRouteCount -eq 0 -and
        $snapshotAfter.Count -eq 1 -and
        $guestServiceAfter.Count -eq 1 -and
        -not $guestServiceAfter[0].Enabled) `
        "phase3b2_operator_close_restore_postcondition_failed"

    $restoreReceipt = [ordered]@{
        contractId = "nll/phase3b2-private-operator-close-restore/v1"
        restoredAtUtc = [DateTimeOffset]::UtcNow.ToString(
            "yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $failedAssessmentUid
        failureReceiptByteLength = [long]$extraction.failureReceiptByteLength
        failureReceiptSha256 = [string]$extraction.failureReceiptSha256
        restoredCheckpointReceiptByteLength = 1887
        restoredCheckpointReceiptSha256 =
            "d92ee1498ab276ad41aa52967a024368dc47c41f93e472f3c76e6c34270211b8"
        restoredCheckpointIdentitySha256 =
            "89251c58622331d18a0580e2eceb234cb973ecbac17fcbe04a08762c45876e80"
        rollbackStatusCode =
            "private_sqlite_reset_p0_checkpoint_restored_verified"
        checkpointPreserved = $true
        networkModeCode = "private_vm_only_no_gateway"
        switchTypeCode = "private_vm_only"
        connectedVmAdapterCount = 1
        hostVirtualAdapterPresent = $false
        externalUplinkPresent = $false
        natConfigured = $false
        guestServiceEnabled = $false
        sqliteCredentialRebootstrapPrepared = $true
        sqliteRuntimeMemberCount = 0
        serverExecutionStarted = $false
        launcherExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = "measure_p1_and_seal_new_assessment"
    }
    Write-JsonFile $restoreReceiptPath $restoreReceipt
}

$restore = Get-Content -LiteralPath $restoreReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($restore.contractId -ceq
        "nll/phase3b2-private-operator-close-restore/v1" -and
    $restore.failedAssessmentUid -ceq $failedAssessmentUid -and
    $restore.restoredCheckpointIdentitySha256 -ceq
        "89251c58622331d18a0580e2eceb234cb973ecbac17fcbe04a08762c45876e80" -and
    [bool]$restore.checkpointPreserved -and
    -not [bool]$restore.clientExecutionStarted) `
    "phase3b2_operator_close_restore_receipt_invalid"

# Re-measure P1 and generate a fresh ready projection. This stage is resumable:
# a prior successful P1 may be reused, but the launcher/client must remain cold.
if (-not (Test-Path -LiteralPath $projectionTranscriptPath)) {
    $postRestoreSession = New-GuestSession $VMName $GuestCredential
    try {
        $runtime = Invoke-Command -Session $postRestoreSession -ScriptBlock {
            $p1Path = Join-Path $env:LOCALAPPDATA `
                "NikkeLocalLab\Evidence\Phase3B2\Trusted\p1-private-v4\server-only-measurement.receipt.json"
            [pscustomobject]@{
                ServerCount = @(Get-Process -Name EpinelPS `
                        -ErrorAction SilentlyContinue).Count
                LauncherCount = @(Get-Process -Name nikke_launcher `
                        -ErrorAction SilentlyContinue).Count
                ClientCount = @(Get-Process -Name nikke `
                        -ErrorAction SilentlyContinue).Count
                P1Present = Test-Path -LiteralPath $p1Path -PathType Leaf
            }
        }
        Assert-True ([int]$runtime.LauncherCount -eq 0 -and
            [int]$runtime.ClientCount -eq 0) `
            "phase3b2_operator_close_post_restore_client_not_cold"

        $remoteResult = if ([int]$runtime.ServerCount -eq 0 -and
                -not [bool]$runtime.P1Present) {
            Invoke-Command -Session $postRestoreSession -ScriptBlock {
                Set-ExecutionPolicy -Scope Process Bypass -Force
                $result = & "C:\NLL\Tools\start-phase3b2-private-v4-p1-and-ready-in-vm.ps1" `
                    -CheckpointReceiptByteLength 1887 `
                    -CheckpointReceiptSha256 `
                        "d92ee1498ab276ad41aa52967a024368dc47c41f93e472f3c76e6c34270211b8"
                return ($result | Out-String)
            }
        }
        elseif ([int]$runtime.ServerCount -eq 1 -and [bool]$runtime.P1Present) {
            Invoke-Command -Session $postRestoreSession -ScriptBlock {
                Set-ExecutionPolicy -Scope Process Bypass -Force
                $result = & "C:\NLL\Tools\new-phase3b2-hyperv-ready-projection-in-vm.ps1" `
                    -NetworkModeCode private_vm_only_no_gateway `
                    -PrivateCheckpointReceiptByteLength 1887 `
                    -PrivateCheckpointReceiptSha256 `
                        "d92ee1498ab276ad41aa52967a024368dc47c41f93e472f3c76e6c34270211b8"
                return ($result | Out-String)
            }
        }
        else { throw "phase3b2_operator_close_p1_resume_shape_invalid" }
    }
    finally {
        Remove-PSSession -Session $postRestoreSession `
            -ErrorAction SilentlyContinue
        $postRestoreSession = $null
    }
    $projectionText = ($remoteResult | Out-String).Trim()
    $projection = $projectionText | ConvertFrom-Json
    Assert-True ($projection.contractId -ceq
            "nll/phase3b2-hyperv-ready-projection/v1" -and
        $projection.assessmentUid -cmatch
            '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' -and
        $projection.assessmentUid -cne $failedAssessmentUid -and
        $projection.serverRunning -and
        -not $projection.clientExecutionStarted) `
        "phase3b2_operator_close_new_projection_invalid"
    [IO.File]::WriteAllText(
        $projectionTranscriptPath,
        ($projectionText + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

$projection = Get-Content -LiteralPath $projectionTranscriptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$newAssessmentUid = [string]$projection.assessmentUid
Assert-True ($projection.contractId -ceq
        "nll/phase3b2-hyperv-ready-projection/v1" -and
    $newAssessmentUid -cne $failedAssessmentUid -and
    $projection.serverRunning -and -not $projection.clientExecutionStarted) `
    "phase3b2_operator_close_saved_projection_invalid"

$pwsh = Resolve-Pwsh
$env:PATH = (Split-Path -Parent $pwsh) + [IO.Path]::PathSeparator + $env:PATH
$observationPath = Join-Path (Join-Path $CompatibilityEvidenceRoot `
        $newAssessmentUid) "season26-classic-live-preflight-observation-set.json"
$readyPath = Join-Path (Join-Path $CompatibilityEvidenceRoot `
        $newAssessmentUid) "season26-classic-live-preflight.ready.json"
if (-not (Test-Path -LiteralPath $observationPath)) {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $PSScriptRoot "new-phase3b2-hyperv-observation-set.ps1") `
        -NetworkModeCode private_vm_only_no_gateway `
        -ProjectionTranscriptPath $projectionTranscriptPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) `
        "phase3b2_operator_close_observation_generation_failed"
}
Assert-True (Test-Path -LiteralPath $observationPath -PathType Leaf) `
    "phase3b2_operator_close_observation_missing"

if (-not (Test-Path -LiteralPath $readyPath)) {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $PSScriptRoot "seal-phase3b2-preflight.ps1") `
        -ObservationSetPath $observationPath -OutputPath $readyPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) `
        "phase3b2_operator_close_preflight_seal_failed"
}
& $pwsh -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot "verify-phase3b2.ps1") -ContractOnly `
    -LocalObservationSetPath $observationPath `
    -LocalPreflightAssessmentPath $readyPath | Out-Null
Assert-True ($LASTEXITCODE -eq 0) `
    "phase3b2_operator_close_final_verification_failed"

$observation = Get-Content -LiteralPath $observationPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
$ready = Get-Content -LiteralPath $readyPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($ready.contractId -ceq "nll/season26-classic-live-preflight/v1" -and
    $ready.assessmentUid -ceq $newAssessmentUid -and
    $ready.verdict -ceq "ready_to_start_isolated_season26_reference_run" -and
    -not $ready.clientExecutionStarted -and
    -not $ready.referenceRunExecuted) `
    "phase3b2_operator_close_final_ready_receipt_invalid"

[pscustomobject]@{
    contractId = "nll/phase3b2-operator-close-recovery/v1"
    failedAssessmentUid = $failedAssessmentUid
    failureReasonCode = "operator_closed_launcher_before_login"
    failureReceiptByteLength = (Get-Item -LiteralPath $localFailurePath).Length
    failureReceiptSha256 = Get-Sha256Hex $localFailurePath
    restoredCheckpointIdentitySha256 =
        "89251c58622331d18a0580e2eceb234cb973ecbac17fcbe04a08762c45876e80"
    newAssessmentUid = $newAssessmentUid
    observationCount = [int]$observation.canonicalManifest.memberCount
    canonicalSha256 = [string]$observation.canonicalManifest.sha256
    readyReceiptByteLength = (Get-Item -LiteralPath $readyPath).Length
    readyReceiptSha256 = Get-Sha256Hex $readyPath
    serverRunning = $true
    launcherRunning = $false
    clientExecutionStarted = $false
    copyInstallOrBuildRepeated = $false
    nextStepCode = "start_launcher_once_and_submit_synthetic_login"
} | ConvertTo-Json
