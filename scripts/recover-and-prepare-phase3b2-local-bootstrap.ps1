[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [Management.Automation.PSCredential]$GuestCredential,

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
    [IO.File]::WriteAllText($Path,
        (($Value | ConvertTo-Json -Depth 8) + "`n"),
        [Text.UTF8Encoding]::new($false))
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
    throw "phase3b2_local_bootstrap_powershell_direct_unavailable"
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
    throw "phase3b2_local_bootstrap_vm_not_running"
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
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    $bundledRoot = Join-Path $env:USERPROFILE ".cache\codex-runtimes"
    $bundled = if (Test-Path -LiteralPath $bundledRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $bundledRoot -Recurse -File `
                -Filter pwsh.exe -ErrorAction SilentlyContinue |
            Where-Object FullName -Like `
                "*\dependencies\native\powershell\pwsh.exe" |
            Sort-Object FullName)
    } else { @() }
    Assert-True ($bundled.Count -ge 1) `
        "phase3b2_local_bootstrap_pwsh_not_found"
    return $bundled[0].FullName
}

Assert-True ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) `
    "administrator_required"

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$failedAssessmentUid = "6899bf08-ee37-4c3a-9901-241bd22c3e9b"
$workflowRoot = Join-Path $CompatibilityRoot `
    "evidence\phase3b2-local-bootstrap-v1"
$failurePath = Join-Path $workflowRoot `
    "launcher-integrity-failure-v6.extracted.json"
$extractionPath = Join-Path $EvidenceRoot `
    "local-bootstrap-v6-failure-extraction.receipt.json"
$restorePath = Join-Path $EvidenceRoot `
    "local-bootstrap-v6-checkpoint9-restore.receipt.json"
$transferPath = Join-Path $EvidenceRoot `
    "local-bootstrap-run-tool-transfer-v1.receipt.json"
$checkpointPath = Join-Path $EvidenceRoot `
    "p0-private-local-bootstrap-checkpoint-v1.json"
$projectionTranscriptPath = Join-Path $workflowRoot `
    "ready-projection.transcript.json"
$workflowReceiptPath = Join-Path $EvidenceRoot `
    "local-bootstrap-ready-workflow-v1.receipt.json"
$buildRoot = Join-Path $CompatibilityRoot `
    "external\phase3b2-local-bootstrap-v1"
$buildReceiptPath = Join-Path $buildRoot `
    "local-bootstrap-build.receipt.json"
$artifactManifestPath = Join-Path $buildRoot "evidence\artifact.manifest.tsv"
$artifactRoot = Join-Path $buildRoot "artifact"
$parentCheckpointPath = Join-Path $EvidenceRoot `
    "p0-private-sqlite-reset-checkpoint-v1.json"

New-Item -ItemType Directory -Path $workflowRoot -Force | Out-Null
Assert-True ((Get-Item -LiteralPath $parentCheckpointPath).Length -eq 1887 -and
    (Get-Sha256Hex $parentCheckpointPath) -ceq
        "d92ee1498ab276ad41aa52967a024368dc47c41f93e472f3c76e6c34270211b8") `
    "phase3b2_local_bootstrap_parent_checkpoint_receipt_drift"
Assert-True ((Get-Item -LiteralPath $buildReceiptPath).Length -eq 1200 -and
    (Get-Sha256Hex $buildReceiptPath) -ceq
        "5b22169e01d395966baee89e2a74f6a54fa8033786e7de46917709febedf3d11" -and
    (Get-Item -LiteralPath $artifactManifestPath).Length -eq 561 -and
    (Get-Sha256Hex $artifactManifestPath) -ceq
        "b323d1c3f2957b21cf02e163c11c406162cd11de2401a895b600de16d7270d70") `
    "phase3b2_local_bootstrap_build_evidence_drift"

$vm = Get-VM -Name $VMName -ErrorAction Stop
$privateSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction Stop
$adapters = @(Get-VMNetworkAdapter -VM $vm)
$switchMembers = @(Get-VM | Get-VMNetworkAdapter |
        Where-Object { $_.SwitchName -ceq $SwitchName })
$managementAdapters = @(Get-VMNetworkAdapter -ManagementOS |
        Where-Object { $_.SwitchName -ceq $SwitchName })
Assert-True ([string]$vm.Id -ceq
        "77d6f113-2f74-49e4-8fbf-0dc381232810" -and
    $privateSwitch.SwitchType -eq
        [Microsoft.HyperV.PowerShell.VMSwitchType]::Private -and
    $adapters.Count -eq 1 -and
    $adapters[0].SwitchName -ceq $SwitchName -and
    $switchMembers.Count -eq 1 -and
    [string]$switchMembers[0].VMId -ceq [string]$vm.Id -and
    $managementAdapters.Count -eq 0) `
    "phase3b2_local_bootstrap_hyperv_isolation_mismatch"
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"
$guestService = @(Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId",
                [StringComparison]::OrdinalIgnoreCase) })
Assert-True ($guestService.Count -eq 1 -and -not $guestService[0].Enabled) `
    "phase3b2_local_bootstrap_guest_service_enabled"

$snapshots = @(Get-VMSnapshot -VM $vm -ErrorAction Stop)
$parentSnapshot = @($snapshots | Where-Object { $_.Name -like
        "NLL-P3B2-W1-P0-Private-SQLiteCredential-v1-*" })
Assert-True ($parentSnapshot.Count -eq 1) `
    "phase3b2_local_bootstrap_parent_checkpoint_missing"

# Seal the current launcher-integrity failure before restoring checkpoint 9.
if (-not (Test-Path -LiteralPath $extractionPath)) {
    $session = New-GuestSession $VMName $GuestCredential
    try {
        $failureBase64 = Invoke-Command -Session $session -ScriptBlock {
            param($AssessmentUid)
            $path = Join-Path $env:LOCALAPPDATA `
                "NikkeLocalLab\Evidence\Phase3B2\Trusted\reference-private-v5\$AssessmentUid\client-launch-validation-failure.receipt.json"
            $runtime = [pscustomobject]@{
                Server = @(Get-Process -Name EpinelPS `
                        -ErrorAction SilentlyContinue).Count
                Launcher = @(Get-Process -Name nikke_launcher `
                        -ErrorAction SilentlyContinue).Count
                Client = @(Get-Process -Name nikke `
                        -ErrorAction SilentlyContinue).Count
            }
            $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            $receipt = $text | ConvertFrom-Json
            if ($receipt.contractId -cne
                    "nll/phase3b2-private-reference-run-failure/v6" -or
                $receipt.assessmentUid -cne
                    "6899bf08-ee37-4c3a-9901-241bd22c3e9b" -or
                [int]$receipt.displayedErrorCode -ne 1400003 -or
                [bool]$receipt.retryPerformed -or
                [bool]$receipt.clientExecutionStarted -or
                $runtime.Server -ne 1 -or $runtime.Launcher -ne 1 -or
                $runtime.Client -ne 0) {
                throw "phase3b2_local_bootstrap_v6_guest_state_invalid"
            }
            return [Convert]::ToBase64String(
                [IO.File]::ReadAllBytes($path))
        } -ArgumentList $failedAssessmentUid
    }
    finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
    }
    [byte[]]$failureBytes = [Convert]::FromBase64String(
        ($failureBase64 | Out-String).Trim())
    $failureText = [Text.UTF8Encoding]::new($false, $true).GetString(
        $failureBytes)
    $failure = $failureText | ConvertFrom-Json
    Assert-True ($failure.contractId -ceq
            "nll/phase3b2-private-reference-run-failure/v6" -and
        $failure.assessmentUid -ceq $failedAssessmentUid -and
        [int]$failure.displayedErrorCode -eq 1400003 -and
        -not [bool]$failure.retryPerformed -and
        -not [bool]$failure.clientExecutionStarted) `
        "phase3b2_local_bootstrap_v6_extraction_invalid"
    [IO.File]::WriteAllBytes($failurePath, $failureBytes)
    $extraction = [ordered]@{
        contractId = "nll/phase3b2-launch-integrity-failure-extraction/v1"
        extractedAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        sourceContractId = [string]$failure.contractId
        assessmentUid = $failedAssessmentUid
        failureReceiptByteLength = (Get-Item -LiteralPath $failurePath).Length
        failureReceiptSha256 = Get-Sha256Hex $failurePath
        displayedErrorCode = 1400003
        retryPerformed = $false
        transportCode = "hyperv_powershell_direct"
        networkTransportUsed = $false
        officialIdentityPersisted = $false
        officialCredentialPersisted = $false
        clientExecutionStarted = $false
    }
    Write-JsonFile $extractionPath $extraction
}
$extraction = Get-Content -LiteralPath $extractionPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($extraction.contractId -ceq
        "nll/phase3b2-launch-integrity-failure-extraction/v1" -and
    $extraction.assessmentUid -ceq $failedAssessmentUid -and
    (Get-Item -LiteralPath $failurePath).Length -eq
        [long]$extraction.failureReceiptByteLength -and
    (Get-Sha256Hex $failurePath) -ceq
        [string]$extraction.failureReceiptSha256 -and
    -not [bool]$extraction.clientExecutionStarted) `
    "phase3b2_local_bootstrap_extraction_receipt_invalid"

if (-not (Test-Path -LiteralPath $restorePath)) {
    Restore-VMSnapshot -VMSnapshot $parentSnapshot[0] -Confirm:$false
    $vm = Wait-VMRunning $VMName
    $session = New-GuestSession $VMName $GuestCredential
    try {
        $restored = Invoke-Command -Session $session -ScriptBlock {
            $trustedRoot = Join-Path $env:LOCALAPPDATA `
                "NikkeLocalLab\Evidence\Phase3B2\Trusted"
            $p0Path = Join-Path $trustedRoot `
                "p0\applied-verification-private-v4.receipt.json"
            $serverRoot =
                "C:\NLL\EpinelPS\EpinelPS\bin\Release\net10.0\win-x64"
            [pscustomobject]@{
                P0ByteLength = (Get-Item -LiteralPath $p0Path).Length
                P0Sha256 = (Get-FileHash -LiteralPath $p0Path `
                        -Algorithm SHA256).Hash.ToLowerInvariant()
                RuntimeCount = @(Get-Process -Name EpinelPS, nikke_launcher,
                        nikke, NikkeLocalLab.Phase3B2.LocalBootstrap `
                        -ErrorAction SilentlyContinue).Count
                SqliteRuntimeMemberCount = @(
                    "epinelps.db", "epinelps.db-shm", "epinelps.db-wal" |
                        Where-Object {
                            Test-Path -LiteralPath (Join-Path $serverRoot $_)
                        }).Count
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
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
    }
    Assert-True ([long]$restored.P0ByteLength -eq 2210 -and
        [string]$restored.P0Sha256 -ceq
            "3c2397c58fc59e5bfafdde2fee79054ce9d58af7cc25efb9d7b0ddf702a3698f" -and
        [int]$restored.RuntimeCount -eq 0 -and
        [int]$restored.SqliteRuntimeMemberCount -eq 0 -and
        [int]$restored.Ipv4DefaultRouteCount -eq 0 -and
        [int]$restored.Ipv6DefaultRouteCount -eq 0) `
        "phase3b2_local_bootstrap_checkpoint9_restore_invalid"
    $restore = [ordered]@{
        contractId = "nll/phase3b2-launch-integrity-checkpoint9-restore/v1"
        restoredAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        failedAssessmentUid = $failedAssessmentUid
        failureReceiptByteLength = [long]$extraction.failureReceiptByteLength
        failureReceiptSha256 = [string]$extraction.failureReceiptSha256
        restoredCheckpointReceiptByteLength = 1887
        restoredCheckpointReceiptSha256 =
            "d92ee1498ab276ad41aa52967a024368dc47c41f93e472f3c76e6c34270211b8"
        restoredCheckpointIdentitySha256 =
            "89251c58622331d18a0580e2eceb234cb973ecbac17fcbe04a08762c45876e80"
        checkpointPreserved = $true
        networkModeCode = "private_vm_only_no_gateway"
        guestServiceEnabled = $false
        serverExecutionStarted = $false
        launcherExecutionStarted = $false
        clientExecutionStarted = $false
        nextStepCode = "stage_source_built_local_bootstrap_p0_v5"
    }
    Write-JsonFile $restorePath $restore
}

# Stage only the five source-built artifacts and the audited local tools.
$artifactNames = @(
    "NikkeLocalLab.Phase3B2.LocalBootstrap.deps.json",
    "NikkeLocalLab.Phase3B2.LocalBootstrap.dll",
    "NikkeLocalLab.Phase3B2.LocalBootstrap.exe",
    "NikkeLocalLab.Phase3B2.LocalBootstrap.runtimeconfig.json",
    "sail_api_impl64.dll"
)
$members = [Collections.Generic.List[object]]::new()
$members.Add([pscustomobject]@{
        Role = "local_bootstrap_build_receipt"; Source = $buildReceiptPath
        Destination = "C:\NLL\Staging\LocalBootstrap-v1\local-bootstrap-build.receipt.json"
    })
$members.Add([pscustomobject]@{
        Role = "local_bootstrap_artifact_manifest"; Source = $artifactManifestPath
        Destination = "C:\NLL\Staging\LocalBootstrap-v1\evidence\artifact.manifest.tsv"
    })
foreach ($name in $artifactNames) {
    $members.Add([pscustomobject]@{
            Role = "local_bootstrap_artifact"
            Source = Join-Path $artifactRoot $name
            Destination = Join-Path `
                "C:\NLL\Staging\LocalBootstrap-v1\artifact" $name
        })
}
$toolNames = @(
    "prepare-phase3b2-local-bootstrap-p0-v5-in-vm.ps1",
    "verify-phase3b2-p0-local-bootstrap-applied-in-vm.ps1",
    "rollback-phase3b2-p0-with-local-bootstrap-in-vm.ps1",
    "measure-phase3b2-p1-server-in-vm.ps1",
    "new-phase3b2-hyperv-ready-projection-in-vm.ps1",
    "start-phase3b2-private-v5-p1-and-ready-in-vm.ps1",
    "start-phase3b2-local-bootstrap-reference-in-vm.ps1"
)
foreach ($name in $toolNames) {
    $members.Add([pscustomobject]@{
            Role = "local_bootstrap_guest_tool"
            Source = Join-Path $PSScriptRoot $name
            Destination = Join-Path "C:\NLL\Tools" $name
        })
}
foreach ($member in $members) {
    Assert-True (Test-Path -LiteralPath $member.Source -PathType Leaf) `
        "phase3b2_local_bootstrap_transfer_source_missing"
}

if (-not (Test-Path -LiteralPath $transferPath)) {
    $session = New-GuestSession $VMName $GuestCredential
    try {
        Invoke-Command -Session $session -ScriptBlock {
            New-Item -ItemType Directory -Path `
                "C:\NLL\Staging\LocalBootstrap-v1\artifact",
                "C:\NLL\Staging\LocalBootstrap-v1\evidence",
                "C:\NLL\Tools" -Force | Out-Null
        }
        foreach ($member in $members) {
            Copy-Item -LiteralPath $member.Source `
                -Destination $member.Destination -ToSession $session -Force
        }
        $guestState = Invoke-Command -Session $session -ScriptBlock {
            [pscustomobject]@{
                RuntimeCount = @(Get-Process -Name EpinelPS, nikke_launcher,
                        nikke, NikkeLocalLab.Phase3B2.LocalBootstrap `
                        -ErrorAction SilentlyContinue).Count
                CredentialBearingGuestCopyPresent = Test-Path -LiteralPath `
                    "C:\NLL\Inputs\credential-bearing\source.json"
            }
        }
    }
    finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
    }
    Assert-True ([int]$guestState.RuntimeCount -eq 0 -and
        -not [bool]$guestState.CredentialBearingGuestCopyPresent) `
        "phase3b2_local_bootstrap_transfer_guest_state_invalid"
    $transfer = [ordered]@{
        contractId = "nll/phase3b2-local-bootstrap-run-tool-transfer/v1"
        transferredAtUtc =
            [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        restoredFailureReceiptSha256 =
            [string]$extraction.failureReceiptSha256
        buildReceiptSha256 = Get-Sha256Hex $buildReceiptPath
        artifactManifestSha256 = Get-Sha256Hex $artifactManifestPath
        transferredMemberCount = $members.Count
        members = @($members | ForEach-Object {
                [ordered]@{
                    roleCode = [string]$_.Role
                    byteLength = (Get-Item -LiteralPath $_.Source).Length
                    sha256 = Get-Sha256Hex $_.Source
                }
            })
        networkModeCode = "private_vm_only_no_gateway"
        switchTypeCode = "private_vm_only"
        connectedVmAdapterCount = 1
        vmRunning = $true
        guestServiceEnabled = $false
        runtimeExecutionStateCode =
            "local_bootstrap_artifacts_and_tools_staged_client_cold"
        serverExecutionStarted = $false
        clientExecutionStarted = $false
    }
    Write-JsonFile $transferPath $transfer
}

$session = New-GuestSession $VMName $GuestCredential
try {
    $p0State = Invoke-Command -Session $session -ScriptBlock {
        $trustedRoot = Join-Path $env:LOCALAPPDATA `
            "NikkeLocalLab\Evidence\Phase3B2\Trusted"
        [pscustomobject]@{
            P0Present = Test-Path -LiteralPath (Join-Path $trustedRoot `
                "p0\applied-verification-private-v5.receipt.json")
            VerificationPresent = Test-Path -LiteralPath (Join-Path $trustedRoot `
                "p0-local-bootstrap-v1\applied-verification.receipt.json")
        }
    }
    if (-not [bool]$p0State.P0Present) {
        Invoke-Command -Session $session -ScriptBlock {
            Set-ExecutionPolicy -Scope Process Bypass -Force
            & "C:\NLL\Tools\prepare-phase3b2-local-bootstrap-p0-v5-in-vm.ps1" |
                Out-Null
        }
    }
    if (-not [bool]$p0State.VerificationPresent) {
        Invoke-Command -Session $session -ScriptBlock {
            Set-ExecutionPolicy -Scope Process Bypass -Force
            & "C:\NLL\Tools\verify-phase3b2-p0-local-bootstrap-applied-in-vm.ps1" |
                Out-Null
        }
    }
}
finally {
    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    $session = $null
}

if (-not (Test-Path -LiteralPath $checkpointPath)) {
    & (Join-Path $PSScriptRoot `
        "new-phase3b2-private-p0-local-bootstrap-checkpoint.ps1") `
        -GuestCredential $GuestCredential -VMName $VMName `
        -SwitchName $SwitchName -EvidenceRoot $EvidenceRoot | Out-Null
}
$checkpointDigest = [pscustomobject]@{
    ByteLength = (Get-Item -LiteralPath $checkpointPath).Length
    Sha256 = Get-Sha256Hex $checkpointPath
}
$checkpoint = Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($checkpoint.contractId -ceq
        "nll/phase3b2-p0-private-local-bootstrap-checkpoint/v1" -and
    [int]$checkpoint.currentCheckpointCount -eq 10 -and
    $checkpoint.clientBootstrapModeCode -ceq
        "source_built_sail_abi_local_bootstrap" -and
    -not [bool]$checkpoint.clientExecutionStarted) `
    "phase3b2_local_bootstrap_checkpoint_receipt_invalid"

if (-not (Test-Path -LiteralPath $projectionTranscriptPath)) {
    $session = New-GuestSession $VMName $GuestCredential
    try {
        $p1Resume = Invoke-Command -Session $session -ScriptBlock {
            $trustedRoot = Join-Path $env:LOCALAPPDATA `
                "NikkeLocalLab\Evidence\Phase3B2\Trusted"
            $p1Path = Join-Path $trustedRoot `
                "p1-private-v5\server-only-measurement.receipt.json"
            $projectionPath = Join-Path $trustedRoot `
                "ready-seal-private-v5\hyperv-ready-projection.json"
            [pscustomobject]@{
                ServerCount = @(Get-Process -Name EpinelPS `
                        -ErrorAction SilentlyContinue).Count
                LauncherCount = @(Get-Process -Name nikke_launcher `
                        -ErrorAction SilentlyContinue).Count
                ClientCount = @(Get-Process -Name nikke `
                        -ErrorAction SilentlyContinue).Count
                BootstrapCount = @(Get-Process -Name `
                        NikkeLocalLab.Phase3B2.LocalBootstrap `
                        -ErrorAction SilentlyContinue).Count
                P1Present = Test-Path -LiteralPath $p1Path -PathType Leaf
                ProjectionPresent = Test-Path -LiteralPath $projectionPath `
                    -PathType Leaf
            }
        }
        Assert-True ([int]$p1Resume.LauncherCount -eq 0 -and
            [int]$p1Resume.ClientCount -eq 0 -and
            [int]$p1Resume.BootstrapCount -eq 0) `
            "phase3b2_local_bootstrap_p1_resume_client_not_cold"
        if ([int]$p1Resume.ServerCount -eq 0 -and
            -not [bool]$p1Resume.P1Present -and
            -not [bool]$p1Resume.ProjectionPresent) {
            $projectionText = Invoke-Command -Session $session -ScriptBlock {
                param($Length, $Sha256)
                Set-ExecutionPolicy -Scope Process Bypass -Force
                $result = & `
                    "C:\NLL\Tools\start-phase3b2-private-v5-p1-and-ready-in-vm.ps1" `
                    -CheckpointReceiptByteLength $Length `
                    -CheckpointReceiptSha256 $Sha256
                return ($result | Out-String)
            } -ArgumentList $checkpointDigest.ByteLength,
                $checkpointDigest.Sha256
        }
        elseif ([int]$p1Resume.ServerCount -eq 1 -and
            [bool]$p1Resume.P1Present -and
            [bool]$p1Resume.ProjectionPresent) {
            $projectionText = Invoke-Command -Session $session -ScriptBlock {
                $path = Join-Path $env:LOCALAPPDATA `
                    "NikkeLocalLab\Evidence\Phase3B2\Trusted\ready-seal-private-v5\hyperv-ready-projection.json"
                return Get-Content -LiteralPath $path -Raw -Encoding UTF8
            }
        }
        else {
            throw "phase3b2_local_bootstrap_p1_resume_shape_invalid"
        }
    }
    finally {
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        $session = $null
    }
    $projectionText = ($projectionText | Out-String).Trim()
    $projection = $projectionText | ConvertFrom-Json
    Assert-True ($projection.contractId -ceq
            "nll/phase3b2-hyperv-ready-projection/v1" -and
        $projection.clientBootstrapModeCode -ceq
            "source_built_sail_abi_local_bootstrap" -and
        $projection.networkModeCode -ceq "private_vm_only_no_gateway" -and
        $projection.serverRunning -and
        -not $projection.clientExecutionStarted) `
        "phase3b2_local_bootstrap_projection_invalid"
    [IO.File]::WriteAllText($projectionTranscriptPath,
        ($projectionText + "`n"), [Text.UTF8Encoding]::new($false))
}
$projection = Get-Content -LiteralPath $projectionTranscriptPath -Raw `
    -Encoding UTF8 | ConvertFrom-Json
$assessmentUid = [string]$projection.assessmentUid
Assert-True ($assessmentUid -cmatch
        "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$" -and
    $projection.clientBootstrapModeCode -ceq
        "source_built_sail_abi_local_bootstrap" -and
    $projection.serverRunning -and -not $projection.clientExecutionStarted) `
    "phase3b2_local_bootstrap_saved_projection_invalid"

$pwsh = Resolve-Pwsh
$env:PATH = (Split-Path -Parent $pwsh) +
    [IO.Path]::PathSeparator + $env:PATH
$assessmentRoot = Join-Path $CompatibilityRoot `
    "evidence\phase3b2-wave1-hyperv\$assessmentUid"
$observationPath = Join-Path $assessmentRoot `
    "season26-classic-live-preflight-observation-set.json"
$readyPath = Join-Path $assessmentRoot `
    "season26-classic-live-preflight.ready.json"
if (-not (Test-Path -LiteralPath $observationPath)) {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $PSScriptRoot `
            "new-phase3b2-hyperv-observation-set.ps1") `
        -NetworkModeCode private_vm_only_no_gateway `
        -ClientBootstrapModeCode source_built_sail_abi_local_bootstrap `
        -ProjectionTranscriptPath $projectionTranscriptPath `
        -CheckpointReceiptPath $checkpointPath `
        -TransferReceiptPath $transferPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) `
        "phase3b2_local_bootstrap_observation_generation_failed"
}
if (-not (Test-Path -LiteralPath $readyPath)) {
    & $pwsh -NoProfile -ExecutionPolicy Bypass -File `
        (Join-Path $PSScriptRoot "seal-phase3b2-preflight.ps1") `
        -ObservationSetPath $observationPath -OutputPath $readyPath | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) `
        "phase3b2_local_bootstrap_preflight_seal_failed"
}
& $pwsh -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot "verify-phase3b2.ps1") -ContractOnly `
    -LocalObservationSetPath $observationPath `
    -LocalPreflightAssessmentPath $readyPath | Out-Null
Assert-True ($LASTEXITCODE -eq 0) `
    "phase3b2_local_bootstrap_final_verification_failed"

$ready = Get-Content -LiteralPath $readyPath -Raw -Encoding UTF8 |
    ConvertFrom-Json
Assert-True ($ready.contractId -ceq
        "nll/season26-classic-live-preflight/v1" -and
    $ready.assessmentUid -ceq $assessmentUid -and
    $ready.verdict -ceq
        "ready_to_start_isolated_season26_reference_run" -and
    $ready.measuredEvidence.statusCode -ceq "measured_complete" -and
    -not $ready.environment.clientExecutionStarted -and
    -not $ready.remainingBoundary.referenceRunExecuted) `
    "phase3b2_local_bootstrap_ready_receipt_invalid"

$session = New-GuestSession $VMName $GuestCredential
try {
    Invoke-Command -Session $session -ScriptBlock {
        $readyRoot = "C:\NLL\Staging\Ready-v5"
        if (Test-Path -LiteralPath $readyRoot) {
            Remove-Item -LiteralPath $readyRoot -Recurse -Force
        }
        New-Item -ItemType Directory -Path $readyRoot | Out-Null
    }
    Copy-Item -LiteralPath $readyPath -Destination (Join-Path `
        "C:\NLL\Staging\Ready-v5" "$assessmentUid.ready.json") `
        -ToSession $session
    $finalGuestState = Invoke-Command -Session $session -ScriptBlock {
        [pscustomobject]@{
            ServerCount = @(Get-Process -Name EpinelPS `
                    -ErrorAction SilentlyContinue).Count
            LauncherCount = @(Get-Process -Name nikke_launcher `
                    -ErrorAction SilentlyContinue).Count
            ClientCount = @(Get-Process -Name nikke `
                    -ErrorAction SilentlyContinue).Count
            BootstrapCount = @(Get-Process -Name `
                    NikkeLocalLab.Phase3B2.LocalBootstrap `
                    -ErrorAction SilentlyContinue).Count
            ReadyCount = @(Get-ChildItem -LiteralPath `
                    "C:\NLL\Staging\Ready-v5" -File `
                    -Filter *.ready.json).Count
        }
    }
}
finally {
    Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    $session = $null
}
Assert-True ([int]$finalGuestState.ServerCount -eq 1 -and
    [int]$finalGuestState.LauncherCount -eq 0 -and
    [int]$finalGuestState.ClientCount -eq 0 -and
    [int]$finalGuestState.BootstrapCount -eq 0 -and
    [int]$finalGuestState.ReadyCount -eq 1) `
    "phase3b2_local_bootstrap_final_guest_state_invalid"

$workflowReceipt = [ordered]@{
    contractId = "nll/phase3b2-local-bootstrap-ready-workflow/v1"
    completedAtUtc =
        [DateTimeOffset]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
    failedAssessmentUid = $failedAssessmentUid
    newAssessmentUid = $assessmentUid
    failureReceiptSha256 = [string]$extraction.failureReceiptSha256
    restoredCheckpointIdentitySha256 =
        "89251c58622331d18a0580e2eceb234cb973ecbac17fcbe04a08762c45876e80"
    newCheckpointIdentitySha256 =
        [string]$checkpoint.checkpointIdentitySha256
    readyReceiptByteLength = (Get-Item -LiteralPath $readyPath).Length
    readyReceiptSha256 = Get-Sha256Hex $readyPath
    clientBootstrapModeCode =
        "source_built_sail_abi_local_bootstrap"
    serverRunning = $true
    officialLauncherRunning = $false
    clientExecutionStarted = $false
    nextStepCode = "run_guest_local_bootstrap_once"
}
Write-JsonFile $workflowReceiptPath $workflowReceipt
$workflowReceipt | ConvertTo-Json
