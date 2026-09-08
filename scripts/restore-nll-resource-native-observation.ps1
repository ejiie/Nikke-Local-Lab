[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$AssessmentUid,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$PlanSha256,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedScriptSha256
)
# Standalone recovery survives runner failure. Restores only exact applied pins.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
if ((Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedScriptSha256) {throw 'resource_native_recovery_script_drift'}
if (-not [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'resource_native_recovery_administrator_required'}
$uid=[Guid]::Empty
if (-not [Guid]::TryParseExact($AssessmentUid,'D',[ref]$uid)) {throw 'resource_native_recovery_uid_invalid'}
$evidence=Join-Path 'C:\NLL\Staging\ResourceProbeRuns' $AssessmentUid
$path=Join-Path $evidence 'native.private.json'
if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $PlanSha256) {throw 'resource_native_recovery_plan_drift'}
$plan=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$helper=Join-Path $evidence 'Nll.ResourceNative.ps1'
if ((Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash.ToLowerInvariant() -cne $plan.helperSha256) {throw 'resource_native_recovery_helper_drift'}
. $helper
Assert-RnPath $evidence
# Historical recovery remains available; v3/v4/v5 add one pinned DLL target.
Assert-Rn ($plan.assessmentUid -ceq $AssessmentUid -and $plan.contractId -cin @('nll/resource-native-observation-plan/v1','nll/resource-native-observation-plan/v2','nll/resource-native-observation-plan/v3','nll/resource-native-observation-plan/v4','nll/resource-native-observation-plan/v5') -and
    $plan.operatorSid -ceq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) 'recovery_identity_invalid'
$programs=@($plan.programs.path) + @($plan.blockOnlyPrograms.path)
Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object {$_.ExecutablePath -in $programs -or $_.Name -match '^(nikke|nikke_launcher|EpinelPS|ACE-Service64|NikkeLocalLab\.Phase3B2\..*Bootstrap)\.exe$'}).Count -eq 0) 'recovery_runtime_not_cold'
$allowed=@('C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke_Data\Plugins\x86_64\intl_cacert.pem',(Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'))
if ($plan.contractId -cin @('nll/resource-native-observation-plan/v3','nll/resource-native-observation-plan/v4','nll/resource-native-observation-plan/v5')) {
    $expectedMode=if ($plan.contractId -ceq 'nll/resource-native-observation-plan/v5') {'epinel_provided_library_control'} elseif ($plan.contractId -ceq 'nll/resource-native-observation-plan/v4') {'source_built_unmodified_control'} else {'source_built_local_key_binding'}
    Assert-Rn ($plan.nativeCompatibilityMode -ceq $expectedMode -and
        $plan.stockNativePin.path -ceq 'C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll' -and
        $plan.stockNativePin.sha256 -ceq '11a42045b328e74dc03e69be574c38f0004c515d364383f230ea4dba30414f6f') 'recovery_native_boundary_invalid'
    $allowed += $plan.stockNativePin.path
}
Assert-Rn ($plan.fileChanges.Count -eq $allowed.Count -and @(Compare-Object ($allowed | Sort-Object) (@($plan.fileChanges.before.path) | Sort-Object)).Count -eq 0) 'recovery_targets_invalid'
$current=@(Get-RnVoicePreferences)
for ($i=0;$i -lt 2;$i++) {
    Assert-Rn ($current[$i].name -ceq $plan.preferencesBefore[$i].name -and $current[$i].kind -ceq $plan.preferencesBefore[$i].kind -and
        $current[$i].value -cin @($plan.preferencesBefore[$i].value,$plan.preferencesAfter[$i].value)) 'recovery_preferences_conflict'
}
$key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\com.proximabeta\NIKKE',$true)
try {
    for ($i=0;$i -lt 2;$i++) {
        $item=$plan.preferencesBefore[$i]
        if ($current[$i].value -ceq $item.value) {continue}
        if ($item.kind -ceq 'Binary') {$key.SetValue($item.name,[Convert]::FromBase64String($item.value),[Microsoft.Win32.RegistryValueKind]::Binary)}
        else {$key.SetValue($item.name,[string]$item.value,[Microsoft.Win32.RegistryValueKind]::String)}
    }
    $key.Flush()
} finally {$key.Dispose()}
$restored=@(Get-RnVoicePreferences)
for ($i=0;$i -lt 2;$i++) {Assert-Rn ($restored[$i].value -ceq $plan.preferencesBefore[$i].value -and $restored[$i].kind -ceq $plan.preferencesBefore[$i].kind) 'recovery_preferences_failed'}
for ($i=$plan.fileChanges.Count-1;$i -ge 0;$i--) {
    $change=$plan.fileChanges[$i]
    Assert-Rn ($change.backup.path.StartsWith($evidence+'\rollback\',[StringComparison]::OrdinalIgnoreCase) -and $change.backup.sha256 -ceq $change.before.sha256) 'recovery_backup_invalid'
    Assert-RnPin $change.backup
    if ((Get-RnHash $change.before.path) -cne $change.before.sha256) {
        $applied=[pscustomobject]@{path=$change.before.path;length=$change.replacement.length;sha256=$change.replacement.sha256}
        Set-RnPinnedFile $applied $change.backup
    }
    Assert-RnPin $change.before
}
$trustBefore=Join-Path $evidence 'trust-before.receipt.json'
if (Test-Path -LiteralPath $trustBefore) {
    $trust=Get-Content -LiteralPath $trustBefore -Raw | ConvertFrom-Json
    if (-not $trust.previouslyPresent) {
        Assert-RnPin $plan.publicRoot
        $cert=[Security.Cryptography.X509Certificates.X509Certificate2]::new($plan.publicRoot.path)
        Assert-Rn ($trust.thumbprint -ceq $cert.Thumbprint) 'recovery_root_identity_invalid'
        $store=[Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine'); $store.Open('ReadWrite')
        try {
            foreach ($entry in @($store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint)) {$store.Remove($entry)}
            Assert-Rn (@($store.Certificates | Where-Object Thumbprint -eq $cert.Thumbprint).Count -eq 0) 'recovery_root_failed'
        } finally {$store.Dispose();$cert.Dispose()}
    }
}
Assert-RnPin $plan.stockNativePin
Clear-DnsClientCache
Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object ExecutablePath -in $programs).Count -eq 0) 'recovery_runtime_changed'
$group='NLL Resource Native '+$AssessmentUid
Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Assert-Rn (@(Get-NetFirewallRule -Group $group -ErrorAction SilentlyContinue).Count -eq 0) 'recovery_firewall_failed'
Write-RnNewJson (Join-Path $evidence 'recovery.receipt.json') ([ordered]@{contractId='nll/resource-native-recovery/v1';assessmentUid=$AssessmentUid;planSha256=$PlanSha256;status='restored';cleanupVerified=$true;verifiedAtUtc=[DateTimeOffset]::UtcNow;clientStarted=$false;serverStarted=$false})
