[CmdletBinding()]
param(
    [string]$VmName = "NLL-Phase3B2-Client150.6.9",
    [string]$EpinelRepo = "C:\Users\ccccc\Documents\Github\EpinelPS",
    [string]$StagingRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Staging",
    [string]$EvidenceRoot = "C:\ProgramData\NikkeLocalLab\HyperV\Phase3B2\Evidence"
)

$ErrorActionPreference = "Stop"

function Assert-True {
    param([bool]$Condition, [string]$FailureCode)
    if (-not $Condition) { throw $FailureCode }
}

$expectedBranch = "codex/phase3b2-live-preflight"
$expectedHead = "519c3db51ec24ca19307e93e85acde7885928a72"
$expectedTree = "b9e8bfb1b1e065427a48d40cb2bcf2f30215436a"
$requiredAncestors = @(
    "28b2f5413a0a1e3521a11ae162f91851335c8b40",
    "92a6ca228aeb580988907b96189b2857dff2c62d",
    "e32e5f900775974d5736e7fb2b50f8c62638a004",
    "4f7bd5b5eb2b9a6e03af503f1c09adc4c4f7f16f",
    "6473a41fcdbc7cb4cb5919c31f9b2d1f04b4b5b6",
    "9d22e68d069ec3d832bc3ece084952906c169d79"
)
$guestServiceId = "6c09bb55-d683-4da0-8931-c9bf705f6480"

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
Assert-True ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) "phase3b2_hyperv_administrator_required"
Assert-True (Test-Path -LiteralPath $EpinelRepo -PathType Container) "phase3b2_epinelps_checkout_missing"

$git = (Get-Command git.exe -ErrorAction Stop).Source
$gitPrefix = @("-c", "safe.directory=$EpinelRepo", "-C", $EpinelRepo)

$status = @(& $git @gitPrefix status --porcelain=v1 --untracked-files=all)
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_epinelps_status_failed"
Assert-True ($status.Count -eq 0) "phase3b2_epinelps_checkout_not_clean"

$head = (& $git @gitPrefix rev-parse HEAD).Trim()
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_epinelps_head_failed"
$tree = (& $git @gitPrefix rev-parse "HEAD^{tree}").Trim()
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_epinelps_tree_failed"
$branch = (& $git @gitPrefix branch --show-current).Trim()
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_epinelps_branch_failed"
Assert-True ($head -ceq $expectedHead) "phase3b2_epinelps_head_mismatch"
Assert-True ($tree -ceq $expectedTree) "phase3b2_epinelps_tree_mismatch"
Assert-True ($branch -ceq $expectedBranch) "phase3b2_epinelps_branch_mismatch"

foreach ($ancestor in $requiredAncestors) {
    & $git @gitPrefix merge-base --is-ancestor $ancestor $head
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_epinelps_ancestor_mismatch"
}

New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$bundleName = "EpinelPS-$expectedHead.bundle"
$bundlePath = Join-Path $StagingRoot $bundleName

if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
    & $git @gitPrefix bundle create $bundlePath "refs/heads/$expectedBranch"
    Assert-True ($LASTEXITCODE -eq 0) "phase3b2_epinelps_bundle_create_failed"
}

$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$bundleVerifyOutput = @(& $git @gitPrefix bundle verify $bundlePath 2>&1)
$bundleVerifyExitCode = $LASTEXITCODE
$ErrorActionPreference = $savedErrorActionPreference
Assert-True ($bundleVerifyExitCode -eq 0) "phase3b2_epinelps_bundle_verify_failed"
Assert-True ($bundleVerifyOutput.Count -gt 0) "phase3b2_epinelps_bundle_verify_output_missing"
$bundleHeadLine = (& $git @gitPrefix bundle list-heads $bundlePath "refs/heads/$expectedBranch").Trim()
Assert-True ($LASTEXITCODE -eq 0) "phase3b2_epinelps_bundle_heads_failed"
Assert-True ($bundleHeadLine -ceq "$expectedHead refs/heads/$expectedBranch") "phase3b2_epinelps_bundle_head_mismatch"

$vm = Get-VM -Name $VmName -ErrorAction Stop
Assert-True ($vm.State -eq "Running") "phase3b2_vm_not_running"
$guestService = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestService.Count -eq 1) "phase3b2_guest_service_shape_invalid"
if (-not $guestService[0].Enabled) {
    Enable-VMIntegrationService -VM $vm -Name $guestService[0].Name
}

$guestDestination = "C:\NLL\Staging\$bundleName"
try {
    Copy-VMFile -VM $vm -SourcePath $bundlePath -DestinationPath $guestDestination `
        -FileSource Host -CreateFullPath -Force
}
finally {
    Disable-VMIntegrationService -VM $vm -Name $guestService[0].Name
}
$guestServiceAfter = @(
    Get-VMIntegrationService -VM $vm |
        Where-Object { ([string]$_.Id).EndsWith("\$guestServiceId", [StringComparison]::OrdinalIgnoreCase) }
)
Assert-True ($guestServiceAfter.Count -eq 1 -and -not $guestServiceAfter[0].Enabled) `
    "phase3b2_guest_service_disable_failed"

$bundleItem = Get-Item -LiteralPath $bundlePath
$receipt = [ordered]@{
    contractId = "nll/phase3b2-epinelps-bundle-transfer/v1"
    targetVmState = [string]$vm.State
    externalBranch = $expectedBranch
    externalHead = $expectedHead
    externalTree = $expectedTree
    requiredAncestorCount = $requiredAncestors.Count
    checkoutClean = $true
    bundleByteLength = $bundleItem.Length
    bundleSha256 = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash.ToLowerInvariant()
    guestDestinationCode = "guest_os_nll_staging"
    guestServiceEnabled = $false
    serverExecutionStarted = $false
    clientExecutionStarted = $false
}

$receiptPath = Join-Path $EvidenceRoot "epinelps-bundle-transfer-$expectedHead.json"
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json) + "`n"), $utf8NoBom)
$receipt | ConvertTo-Json
