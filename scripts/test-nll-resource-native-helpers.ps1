param([switch]$RegistryRoundTrip)
# Only a new synthetic registry key is writable; never NIKKE PlayerPrefs/hosts.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$count=0
function Check([bool]$Value) {if (-not $Value) {throw 'native_helper_test_failed'}; $script:count++}
function Reject([scriptblock]$Action) { $failed=$false; try {& $Action} catch {$failed=$true}; Check $failed }
$uid=[Guid]::NewGuid().ToString('D')
$syntheticProcess=[pscustomobject]@{ExecutablePath='C:\SyntheticService\service.exe';ProcessId=42;ParentProcessId=7;CreationDate=[DateTime]::UtcNow}
$observed=@(Get-RnBlockedProgramObservations @('C:\NIKKE\synthetic.exe','C:\SyntheticService\service.exe') @($syntheticProcess))
Check ($observed.Count -eq 1 -and $observed[0].programIndex -eq 1 -and $observed[0].role -ceq 'installed_related_service')
Check ($observed[0].processId -eq 42 -and $observed[0].parentProcessId -eq 7)
Check (($observed | ConvertTo-Json -Depth 4) -notmatch 'ExecutablePath|SyntheticService|commandLine')
$syntheticProcess.ExecutablePath='c:\nikke\synthetic.exe'
$observed=@(Get-RnBlockedProgramObservations @('C:\NIKKE\synthetic.exe') @($syntheticProcess))
Check ($observed[0].programIndex -eq 0 -and $observed[0].role -ceq 'official_install_program')
Reject {Get-RnBlockedProgramObservations @('C:\SyntheticService\service.exe') @($syntheticProcess)}
$original=[Text.Encoding]::UTF8.GetBytes("# fixture`r`n127.0.0.1 localhost`r`n")
$bytes=New-RnHostsBytes $original @('fixture.example') $uid
Check ([Text.Encoding]::UTF8.GetString($bytes).Contains('127.0.0.1 fixture.example'))
Check ([Convert]::ToBase64String($bytes[0..($original.Length-1)]) -ceq [Convert]::ToBase64String($original))
Reject {New-RnHostsBytes ([Text.Encoding]::ASCII.GetBytes('192.0.2.1 fixture.example')) @('fixture.example') $uid}
Reject {New-RnHostsBytes $original @("fixture.example`nother.example") $uid}
Reject {New-RnHostsBytes $bytes @('fixture.example') $uid}
$binary=[pscustomobject]@{name='voiceLocale_h4098423835';kind='Binary';value='ZW4A'}
$ko=ConvertTo-RnVoicePreference $binary 'ko'
Check ($ko.kind -ceq 'Binary' -and $ko.value -ceq 'a28A')
Check ($binary.value -ceq 'ZW4A')
$string=[pscustomobject]@{name='voiceDownloadType_h2535520031';kind='String';value='Full'}
$minimum=ConvertTo-RnVoicePreference $string 'Minimal'
Check ($minimum.kind -ceq 'String' -and $minimum.value -ceq 'Minimal')
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('nll-native-helper-'+[Guid]::NewGuid().ToString('D'))
New-Item -ItemType Directory -Path $temporary | Out-Null
try {
    $before=Join-Path $temporary 'before'; $target=Join-Path $temporary 'target'; $after=Join-Path $temporary 'after'
    Write-RnNewBytes $before ([byte[]]@(1,2,3))
    Copy-RnNew $before $target
    Write-RnNewBytes $after ([byte[]]@(4,5,6))
    $old=Get-RnPin $target
    $new=Get-RnPin $after
    Set-RnPinnedFile $old $new
    Check ((Get-RnHash $target) -ceq $new.sha256)
    Reject {Set-RnPinnedFile $old (Get-RnPin $before)}
    Set-RnPinnedFile (Get-RnPin $target) (Get-RnPin $before)
    Check ((Get-RnHash $target) -ceq $old.sha256)
    Reject {Write-RnNewBytes $before ([byte[]]@(7))}
} finally {
    $resolved=[IO.Path]::GetFullPath($temporary)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -cnotmatch '^nll-native-helper-[a-f0-9-]{36}$') {throw 'test_cleanup_boundary'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Output "Native helper synthetic checks passed: $count"
if ($RegistryRoundTrip) {
    $testKey='Software\NikkeLocalLab\SyntheticTests\'+[Guid]::NewGuid().ToString('D')
    $key=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($testKey)
    try {
        Set-RnPreferenceValue $key $binary
        Check ($key.GetValueKind($binary.name) -eq [Microsoft.Win32.RegistryValueKind]::Binary)
        Check ([Convert]::ToBase64String($key.GetValue($binary.name)) -ceq $binary.value)
        Set-RnPreferenceValue $key $ko
        Check ([Convert]::ToBase64String($key.GetValue($binary.name)) -ceq $ko.value)
        Set-RnPreferenceValue $key $binary
        Check ([Convert]::ToBase64String($key.GetValue($binary.name)) -ceq $binary.value)
        Set-RnPreferenceValue $key $string
        Check ($key.GetValueKind($string.name) -eq [Microsoft.Win32.RegistryValueKind]::String)
        Set-RnPreferenceValue $key $minimum
        Check ($key.GetValue($string.name) -ceq 'Minimal')
        Set-RnPreferenceValue $key $string
        Check ($key.GetValue($string.name) -ceq 'Full')
        Reject {Set-RnPreferenceValue $key ([pscustomobject]@{name='invalid';kind='DWord';value='1'})}
    } finally {
        $key.Dispose()
        if ($testKey -cnotmatch '^Software\\NikkeLocalLab\\SyntheticTests\\[a-f0-9-]{36}$') {throw 'test_registry_cleanup_boundary'}
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testKey)
    }
    Check ($null -eq [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($testKey))
    Write-Output "Native helpers with real synthetic registry roundtrip passed: $count"
}
