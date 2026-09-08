[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Management.Automation.PSCredential]$GuestCredential,

    [string]$OperatorScreenshotPath =
        "C:\Users\ccccc\AppData\Local\Temp\codex-clipboard-ce075a1e-25da-45b9-8bc5-9bcc7faabde3.png",

    [string]$VMName = "NLL-Phase3B2-Client150.6.9",
    [string]$SwitchName = "NLL-Phase3B2-Private",
    [string]$EvidenceRoot =
        "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence",
    [string]$CompatibilityRoot =
        "$env:LOCALAPPDATA\NikkeLocalLab\compatibility"
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

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 8) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
}

function New-GuestSession {
    param([string]$Name, [Management.Automation.PSCredential]$Credential)
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        try {
            return New-PSSession -VMName $Name -Credential $Credential `
                -ErrorAction Stop
        }
        catch { Start-Sleep -Seconds 1 }
    }
    throw "phase3b2_virtual_environment_rejection_powershell_direct_unavailable"
}

function Wait-VMRunning {
    param([string]$Name)
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $candidate = Get-VM -Name $Name -ErrorAction Stop
        if ($candidate.State -eq
            [Microsoft.HyperV.PowerShell.VMState]::Running) {
            return $candidate
        }
        if ($candidate.State -in @(
                [Microsoft.HyperV.PowerShell.VMState]::Off,
                [Microsoft.HyperV.PowerShell.VMState]::Saved)) {
            Start-VM -VM $candidate -ErrorAction SilentlyContinue | Out-Null
        }
        Start-Sleep -Seconds 1
    }
    throw "phase3b2_virtual_environment_rejection_vm_not_running"
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"

$failedAssessmentUid = "31afe0ed-c4a8-4825-b467-f5954d760f09"
$checkpointReceiptPath = Join-Path $EvidenceRoot `
    "p0-private-local-bootstrap-checkpoint-v1.json"
$workflowRoot = Join-Path $CompatibilityRoot `
    "evidence\phase3b2-virtual-environment-block-v1\$failedAssessmentUid"
$admissionPath = Join-Path $workflowRoot `
    "reference-start-admission.extracted.json"
$bootstrapFailurePath = Join-Path $workflowRoot `
    "bootstrap-failure.extracted.json"
$classificationPath = Join-Path $workflowRoot `
    "virtual-environment-rejection.extracted.json"
$extractionReceiptPath = Join-Path $EvidenceRoot `
    "local-bootstrap-virtual-environment-rejection-extraction.receipt.json"
$restoreReceiptPath = Join-Path $EvidenceRoot `
    "local-bootstrap-virtual-environment-checkpoint10-restore.receipt.json"
$workflowReceiptPath = Join-Path $EvidenceRoot `
    "local-bootstrap-virtual-environment-block-workflow.receipt.json"

Assert-True ((Get-Item -LiteralPath $OperatorScreenshotPath).Length -eq 143533 -and
    (Get-Sha256Hex $OperatorScreenshotPath) -ceq
        "bc224c360c1dc71aa300ee5d138a1a63de200c2ba75d2c35a0c53613dfab57f3") `
    "phase3b2_virtual_environment_rejection_screenshot_drift"
Assert-True ((Get-Item -LiteralPath $checkpointReceiptPath).Length -eq 2314 -and
    (Get-Sha256Hex $checkpointReceiptPath) -ceq
        "bbe308fc11584aec02f190a5714270bdfaaaab7df952d909d6c26d452b4391be") `
    "phase3b2_virtual_environment_checkpoint_receipt_drift"
$checkpointReceipt = Get-Content -LiteralPath $checkpointReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($checkpointReceipt.contractId -ceq
        "nll/phase3b2-p0-private-local-bootstrap-checkpoint/v1" -and
    $checkpointReceipt.checkpointIdentitySha256 -ceq
        "2c605c1600a089f0eec6a13c5be561c46b600202cc965536d23b33babb7deb3b" -and
    [int]$checkpointReceipt.currentCheckpointCount -eq 10 -and
    -not [bool]$checkpointReceipt.clientExecutionStarted) `
    "phase3b2_virtual_environment_checkpoint_receipt_invalid"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$managementAdapters = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
$snapshots = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
$checkpoint = @($snapshots | Where-Object { $_.Name -like
        "NLL-P3B2-W1-P0-Private-LocalBootstrap-v1-*" })
Assert-True ([string]$vm.Id -ceq
        "77d6f113-2f74-49e4-8fbf-0dc381232810" -and
    $privateSwitch.SwitchType -eq
        [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and $adapters[0].SwitchName -ceq $SwitchName -and
    $managementAdapters.Count -eq 0 -and
    $guestService.Count -eq 1 -and -not $guestService[0].Enabled -and
    $snapshots.Count -eq 10 -and $checkpoint.Count -eq 1) `
    "phase3b2_virtual_environment_hyperv_shape_invalid"

New-Item -ItemType Directory -Path $workflowRoot -Force | Out-Null

if (-not (Test-Path -LiteralPath $extractionReceiptPath)) {
    Assert-True (-not (Test-Path -LiteralPath $admissionPath) -and
        -not (Test-Path -LiteralPath $bootstrapFailurePath) -and
        -not (Test-Path -LiteralPath $classificationPath)) `
        "phase3b2_virtual_environment_partial_extraction_present"
    $session = New-GuestSession $VMName $GuestCredential
    try {
        $remote = Invoke-Command -Session $session -ScriptBlock {
            param($AssessmentUid, $ScreenshotByteLength, $ScreenshotSha256)

            $ErrorActionPreference = "Stop"
            function Assert-Guest {
                param([bool]$Condition, [string]$FailureCode)
                if (-not $Condition) { throw $FailureCode }
            }
            $trustedRoot = Join-Path $env:LOCALAPPDATA `
                "NikkeLocalLab\Evidence\Phase3B2\Trusted"
            $runRoot = Join-Path $trustedRoot "reference-local-bootstrap-v1"
            $admissionPath = Join-Path $runRoot `
                "reference-start-admission.receipt.json"
            $failurePath = Join-Path $runRoot `
                "bootstrap-failure.receipt.json"
            $classificationPath = Join-Path $runRoot `
                "virtual-environment-rejection.receipt.json"
            Assert-Guest ((Test-Path -LiteralPath $admissionPath -PathType Leaf) -and
                (Test-Path -LiteralPath $failurePath -PathType Leaf) -and
                -not (Test-Path -LiteralPath $classificationPath)) `
                "phase3b2_virtual_environment_guest_evidence_shape_invalid"

            $admission = Get-Content -LiteralPath $admissionPath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            $failure = Get-Content -LiteralPath $failurePath -Raw `
                -Encoding UTF8 | ConvertFrom-Json
            $server = @(Get-Process -Name EpinelPS -ErrorAction SilentlyContinue)
            $launcher = @(Get-Process -Name nikke_launcher `
                    -ErrorAction SilentlyContinue)
            $client = @(Get-Process -Name nikke -ErrorAction SilentlyContinue)
            $bootstrap = @(Get-Process -Name `
                    NikkeLocalLab.Phase3B2.LocalBootstrap `
                    -ErrorAction SilentlyContinue)
            Assert-Guest ($admission.contractId -ceq
                    "nll/phase3b2-local-bootstrap-reference-admission/v1" -and
                $admission.assessmentUid -ceq $AssessmentUid -and
                -not [bool]$admission.clientExecutionStarted -and
                $failure.contractId -ceq
                    "nll/phase3b2-local-bootstrap-failure/v1" -and
                $failure.assessmentUid -ceq $AssessmentUid -and
                $failure.failedStageCode -ceq "sail_abi_bootstrap" -and
                $failure.reasonCode -ceq "sail_pipe_connection_not_observed" -and
                $server.Count -eq 1 -and $launcher.Count -eq 0 -and
                $client.Count -eq 0 -and $bootstrap.Count -eq 0) `
                "phase3b2_virtual_environment_guest_runtime_shape_invalid"

            $serverPid = $server[0].Id
            $tcp = @(Get-NetTCPConnection -OwningProcess $serverPid `
                    -State Listen -ErrorAction Stop)
            Assert-Guest (@($tcp | Where-Object {
                        $_.LocalAddress -ceq "127.0.0.1" -and
                        $_.LocalPort -eq 80
                    }).Count -eq 1 -and
                @($tcp | Where-Object {
                        $_.LocalAddress -ceq "127.0.0.1" -and
                        $_.LocalPort -eq 443
                    }).Count -eq 1 -and
                @($tcp | Where-Object LocalAddress -CNE "127.0.0.1").Count -eq 0) `
                "phase3b2_virtual_environment_guest_listener_shape_invalid"

            $receipt = [ordered]@{
                contractId =
                    "nll/phase3b2-private-reference-run-failure/v7"
                failedAtUtc =
                    [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                assessmentUid = $AssessmentUid
                failedTransitionCode = "original_client_process_start"
                reasonCode =
                    "original_client_rejected_virtualized_environment_before_sail_pipe_connection"
                displayedMessageCode =
                    "virtual_environment_execution_not_permitted"
                displayedErrorCodeComponents = @(3, 1053, 4227072)
                operatorAttestationCode =
                    "original_client_virtual_environment_rejection_ui_observed"
                retryPerformed = $false
                clientProcessCreationObserved = $true
                originalClientRuntimeEntered = $false
                sailNamedPipeConnectionObserved = $false
                serverRunningBeforeRestore = $true
                currentServerProcessCount = 1
                currentOfficialLauncherProcessCount = 0
                currentClientProcessCount = 0
                currentBootstrapProcessCount = 0
                operatorScreenshotEvidence = [ordered]@{
                    byteLength = [long]$ScreenshotByteLength
                    sha256 = [string]$ScreenshotSha256
                    rawScreenshotExternalOnly = $true
                }
                antiVirtualizationBypassAttempted = $false
                antiCheatSubstitutionApplied = $false
                processInjectionOrHookingAttempted = $false
                officialLauncherExecutionStarted = $false
                officialIdentityPersisted = $false
                officialCredentialPersisted = $false
                referenceRunExecuted = $false
                nextStepCode =
                    "restore_local_bootstrap_p0_block_hyperv_use_separate_os"
            }
            [IO.File]::WriteAllText(
                $classificationPath,
                (($receipt | ConvertTo-Json -Depth 6) + "`n"),
                [Text.UTF8Encoding]::new($false)
            )
            [pscustomobject]@{
                AdmissionPath = $admissionPath
                AdmissionByteLength = (Get-Item $admissionPath).Length
                AdmissionSha256 = (Get-FileHash $admissionPath `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                FailurePath = $failurePath
                FailureByteLength = (Get-Item $failurePath).Length
                FailureSha256 = (Get-FileHash $failurePath `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                ClassificationPath = $classificationPath
                ClassificationByteLength = (Get-Item $classificationPath).Length
                ClassificationSha256 = (Get-FileHash $classificationPath `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        } -ArgumentList $failedAssessmentUid, 143533,
            "bc224c360c1dc71aa300ee5d138a1a63de200c2ba75d2c35a0c53613dfab57f3"

        $copies = @(
            [pscustomobject]@{
                Source = [string]$remote.AdmissionPath
                Destination = $admissionPath
                ByteLength = [long]$remote.AdmissionByteLength
                Sha256 = [string]$remote.AdmissionSha256
            },
            [pscustomobject]@{
                Source = [string]$remote.FailurePath
                Destination = $bootstrapFailurePath
                ByteLength = [long]$remote.FailureByteLength
                Sha256 = [string]$remote.FailureSha256
            },
            [pscustomobject]@{
                Source = [string]$remote.ClassificationPath
                Destination = $classificationPath
                ByteLength = [long]$remote.ClassificationByteLength
                Sha256 = [string]$remote.ClassificationSha256
            }
        )
        foreach ($copy in $copies) {
            $temporaryPath = $copy.Destination + ".tmp"
            Copy-Item -FromSession $session -LiteralPath $copy.Source `
                -Destination $temporaryPath
            Assert-True ((Get-Item -LiteralPath $temporaryPath).Length -eq
                    $copy.ByteLength -and
                (Get-Sha256Hex $temporaryPath) -ceq $copy.Sha256) `
                "phase3b2_virtual_environment_extracted_copy_drift"
            Move-Item -LiteralPath $temporaryPath `
                -Destination $copy.Destination
        }
    }
    finally {
        if ($null -ne $session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            $session = $null
        }
    }

    $extraction = [ordered]@{
        contractId =
            "nll/phase3b2-virtual-environment-rejection-extraction/v1"
        extractedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        assessmentUid = $failedAssessmentUid
        admissionReceiptByteLength = (Get-Item $admissionPath).Length
        admissionReceiptSha256 = Get-Sha256Hex $admissionPath
        bootstrapFailureReceiptByteLength = (Get-Item $bootstrapFailurePath).Length
        bootstrapFailureReceiptSha256 = Get-Sha256Hex $bootstrapFailurePath
        classificationReceiptByteLength = (Get-Item $classificationPath).Length
        classificationReceiptSha256 = Get-Sha256Hex $classificationPath
        operatorScreenshotByteLength = 143533
        operatorScreenshotSha256 =
            "bc224c360c1dc71aa300ee5d138a1a63de200c2ba75d2c35a0c53613dfab57f3"
        transportCode = "hyperv_powershell_direct"
        networkTransportUsed = $false
        rawScreenshotCopied = $false
        rawSecretPersisted = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        referenceRunExecuted = $false
    }
    Write-JsonFile $extractionReceiptPath $extraction
}

$extraction = Get-Content -LiteralPath $extractionReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$classification = Get-Content -LiteralPath $classificationPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($extraction.contractId -ceq
        "nll/phase3b2-virtual-environment-rejection-extraction/v1" -and
    $extraction.assessmentUid -ceq $failedAssessmentUid -and
    $classification.contractId -ceq
        "nll/phase3b2-private-reference-run-failure/v7" -and
    $classification.reasonCode -ceq
        "original_client_rejected_virtualized_environment_before_sail_pipe_connection" -and
    [bool]$classification.clientProcessCreationObserved -and
    -not [bool]$classification.originalClientRuntimeEntered -and
    -not [bool]$classification.referenceRunExecuted) `
    "phase3b2_virtual_environment_extraction_invalid"

if (-not (Test-Path -LiteralPath $restoreReceiptPath)) {
    Restore-VMSnapshot -VMSnapshot $checkpoint[0] -Confirm:$false
    $vm = Wait-VMRunning $VMName
    $session = New-GuestSession $VMName $GuestCredential
    try {
        $restored = Invoke-Command -Session $session -ScriptBlock {
            $trustedRoot = Join-Path $env:LOCALAPPDATA `
                "NikkeLocalLab\Evidence\Phase3B2\Trusted"
            $p0Path = Join-Path $trustedRoot `
                "p0\applied-verification-private-v5.receipt.json"
            $verificationPath = Join-Path $trustedRoot `
                "p0-local-bootstrap-v1\applied-verification.receipt.json"
            $serverRoot =
                "C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64"
            [pscustomobject]@{
                P0ByteLength = (Get-Item $p0Path).Length
                P0Sha256 = (Get-FileHash $p0Path `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                VerificationByteLength = (Get-Item $verificationPath).Length
                VerificationSha256 = (Get-FileHash $verificationPath `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                BootstrapExeSha256 = (Get-FileHash `
                        "C:\NLL\LocalBootstrap\v1\NikkeLocalLab.Phase3B2.LocalBootstrap.exe" `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                RuntimeProcessCount = @(Get-Process -Name EpinelPS,
                        nikke_launcher, nikke,
                        NikkeLocalLab.Phase3B2.LocalBootstrap `
                        -ErrorAction SilentlyContinue).Count
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
                FirewallRuleCount = @(Get-NetFirewallRule `
                        -Group "NLL Phase3B2 Isolation" `
                        -ErrorAction Stop).Count
                FailedRunEvidencePresent = Test-Path -LiteralPath `
                    (Join-Path $trustedRoot "reference-local-bootstrap-v1")
            }
        }
    }
    finally {
        if ($null -ne $session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            $session = $null
        }
    }
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    $snapshotAfter = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
    $checkpointAfter = @($snapshotAfter | Where-Object {
            [string]$_.Id -ceq [string]$checkpoint[0].Id })
    $guestServiceAfter = @(Get-VMIntegrationService -VM $vm |
            Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                    [StringComparison]::OrdinalIgnoreCase) })
    Assert-True ([long]$restored.P0ByteLength -eq 3116 -and
        [string]$restored.P0Sha256 -ceq
            "185b7c0387f883d9b4b2c782e84ac2fadaf7ef9c8439d028c08b7f2b53fab584" -and
        [long]$restored.VerificationByteLength -eq 1010 -and
        [string]$restored.VerificationSha256 -ceq
            "d72c50e860c9c418867b28f551eeddcb2bbae0828d65e9b5bb1503ffc4b85bd0" -and
        [string]$restored.BootstrapExeSha256 -ceq
            "4b6a8c844f291bdc956d0907f5898cb4b4fd54b0d95671ee1a75873867012773" -and
        [int]$restored.RuntimeProcessCount -eq 0 -and
        [int]$restored.SqliteRuntimeMemberCount -eq 0 -and
        [int]$restored.Ipv4DefaultRouteCount -eq 0 -and
        [int]$restored.Ipv6DefaultRouteCount -eq 0 -and
        [int]$restored.FirewallRuleCount -eq 17 -and
        -not [bool]$restored.FailedRunEvidencePresent -and
        $snapshotAfter.Count -eq 10 -and $checkpointAfter.Count -eq 1 -and
        $guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
        "phase3b2_virtual_environment_restore_postcondition_failed"

    $restore = [ordered]@{
        contractId =
            "nll/phase3b2-virtual-environment-checkpoint10-restore/v1"
        restoredAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $failedAssessmentUid
        failureReceiptByteLength = (Get-Item $classificationPath).Length
        failureReceiptSha256 = Get-Sha256Hex $classificationPath
        restoredCheckpointReceiptByteLength = 2314
        restoredCheckpointReceiptSha256 =
            "bbe308fc11584aec02f190a5714270bdfaaaab7df952d909d6c26d452b4391be"
        restoredCheckpointIdentitySha256 =
            "2c605c1600a089f0eec6a13c5be561c46b600202cc965536d23b33babb7deb3b"
        rollbackStatusCode =
            "private_local_bootstrap_p0_checkpoint_restored_verified"
        checkpointPreserved = $true
        networkModeCode = "private_vm_only_no_gateway"
        switchTypeCode = "private_vm_only"
        connectedVmAdapterCount = 1
        hostVirtualAdapterPresent = $false
        externalUplinkPresent = $false
        natConfigured = $false
        guestServiceEnabled = $false
        runtimeProcessCount = 0
        serverExecutionStartedAfterRestore = $false
        clientProcessRunningAfterRestore = $false
        failedAttemptClientProcessCreationObserved = $true
        failedAttemptOriginalClientRuntimeEntered = $false
        referenceRunExecuted = $false
        antiVirtualizationBypassAttempted = $false
        nextStepCode =
            "block_hyperv_reference_run_prepare_separate_physical_os"
    }
    Write-JsonFile $restoreReceiptPath $restore
}

$restore = Get-Content -LiteralPath $restoreReceiptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
Assert-True ($restore.contractId -ceq
        "nll/phase3b2-virtual-environment-checkpoint10-restore/v1" -and
    $restore.failedAssessmentUid -ceq $failedAssessmentUid -and
    $restore.restoredCheckpointIdentitySha256 -ceq
        "2c605c1600a089f0eec6a13c5be561c46b600202cc965536d23b33babb7deb3b" -and
    [bool]$restore.checkpointPreserved -and
    -not [bool]$restore.failedAttemptOriginalClientRuntimeEntered -and
    -not [bool]$restore.referenceRunExecuted) `
    "phase3b2_virtual_environment_restore_receipt_invalid"

if (-not (Test-Path -LiteralPath $workflowReceiptPath)) {
    $workflow = [ordered]@{
        contractId =
            "nll/phase3b2-virtual-environment-block-workflow/v1"
        completedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $failedAssessmentUid
        failureReasonCode =
            "original_client_rejected_virtualized_environment_before_sail_pipe_connection"
        classificationReceiptByteLength = (Get-Item $classificationPath).Length
        classificationReceiptSha256 = Get-Sha256Hex $classificationPath
        operatorScreenshotByteLength = 143533
        operatorScreenshotSha256 =
            "bc224c360c1dc71aa300ee5d138a1a63de200c2ba75d2c35a0c53613dfab57f3"
        restoredCheckpointIdentitySha256 =
            "2c605c1600a089f0eec6a13c5be561c46b600202cc965536d23b33babb7deb3b"
        verdict = "runtime_blocked_virtualized_environment"
        clientProcessCreationObserved = $true
        originalClientRuntimeEntered = $false
        referenceRunExecuted = $false
        antiVirtualizationBypassAttempted = $false
        processInjectionOrHookingAttempted = $false
        vmRunning = $true
        runtimeProcessCount = 0
        nextStepCode = "prepare_snapshot_capable_separate_physical_os"
    }
    Write-JsonFile $workflowReceiptPath $workflow
}

Get-Content -LiteralPath $workflowReceiptPath -Raw -Encoding UTF8 |
    ConvertFrom-Json | ConvertTo-Json -Depth 8
