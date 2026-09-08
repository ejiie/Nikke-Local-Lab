# Shared, side-effect-free-on-import helpers for the bounded native observation.
Set-StrictMode -Version Latest
function Assert-Rn([bool]$Value, [string]$Code) {
    if (-not $Value) { throw ('resource_native_' + $Code) }
}
function Assert-RnPath([string]$Path) {
    $cursor=[IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            Assert-Rn (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'reparse_path'
        }
        $parent=Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }; $cursor=$parent
    }
}
function Get-RnHash([string]$Path) {
    Assert-RnPath $Path
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Get-RnPin([string]$Path) {
    [ordered]@{path=[IO.Path]::GetFullPath($Path);length=(Get-Item -LiteralPath $Path).Length;sha256=(Get-RnHash $Path)}
}
function Get-RnBlockOnlyProgramPaths {
    $paths=@(Get-ChildItem -LiteralPath 'C:\NIKKE' -Recurse -File -Filter '*.exe' | Select-Object -ExpandProperty FullName)
    foreach ($service in @(Get-CimInstance Win32_Service | Where-Object {$_.Name -match '^(ACE|AntiCheat|TQM)' -or $_.PathName -match 'AntiCheatExpert|TQM64|NIKKE'})) {
        Assert-Rn ($service.State -ceq 'Stopped') 'related_service_running'
        $match=[regex]::Match($service.PathName,'^(?:"(?<exe>[^"]+\.exe)"|(?<exe>\S+\.exe))(?:\s|$)','IgnoreCase')
        Assert-Rn $match.Success 'service_program_unresolved'
        $paths += $match.Groups['exe'].Value
    }
    foreach ($path in @($paths | Sort-Object -Unique)) {Assert-RnPath $path; [IO.Path]::GetFullPath($path)}
}
function Assert-RnPin([object]$Pin) {
    Assert-Rn ((Get-RnHash $Pin.path) -ceq $Pin.sha256 -and (Get-Item -LiteralPath $Pin.path).Length -eq $Pin.length) 'file_drift'
}
function Assert-RnEpinelProvided([object]$Binding) {
    # Operator approval on 2026-09-06 covers this unchanged upstream DLL,
    # including its built-in patching, only in the isolated 151 clone trial.
    # This is provenance admission, NOT a claim of 151 native compatibility.
    Assert-Rn ($Binding.authorizationId -ceq 'operator-2026-09-06-epinel-provided-151/v1' -and
        $Binding.libraryPin.sha256 -ceq '54ee18f5ee3d16fea8bb6c3407a880727aa3b848f6a55908e6bf90f8635e5662' -and
        $Binding.libraryPin.length -eq 358400) 'epinel_package_unreviewed'
    Assert-RnPin $Binding.libraryPin
}
function Assert-RnLocalKeyBinding([object]$Binding) {
    # Exact reviewed source-built package, not a switch for arbitrary native DLLs.
    foreach ($pin in @($Binding.libraryPin,$Binding.buildReceiptPin,$Binding.testReceiptPin)) { Assert-RnPin $pin }
    Assert-Rn ($Binding.libraryPin.sha256 -ceq '01c569e72ad2ead6567a9f69a733551875f6d00f36674ffd312ca15388a59889') 'key_library_unreviewed'
    $build=Read-RnJson $Binding.buildReceiptPin.path $Binding.buildReceiptPin.sha256
    $test=Read-RnJson $Binding.testReceiptPin.path $Binding.testReceiptPin.sha256
    Assert-Rn ($build.contractId -ceq 'nll/resource-key-compat-build/v1' -and
        $build.sourceCommit -ceq '77e1ce5d6dee871c49ef211222ba18ef0c486bda' -and
        $build.sourcePatchSha256 -ceq '4330442a750237485de429f7be750c3d88156dfd039b248e1c765390361f5508' -and
        $build.libraryPin.sha256 -ceq $Binding.libraryPin.sha256 -and
        $build.stockPin.sha256 -ceq '11a42045b328e74dc03e69be574c38f0004c515d364383f230ea4dba30414f6f' -and
        $build.exportCount -eq 756 -and $build.exportsMatchStock -eq $true -and
        $build.exportsMatchBaseline -eq $true -and $build.unreviewedImportsAbsent -eq $true -and
        $build.macValidationChanged -eq $false) 'key_build_receipt_invalid'
    Assert-Rn ($test.contractId -ceq 'nll/resource-key-compat-synthetic/v1' -and $test.status -ceq 'passed' -and
        $test.checks -eq 15 -and $test.candidateChecked -eq $true -and
        $test.librarySha256 -ceq $Binding.libraryPin.sha256 -and $test.buildReceiptSha256 -ceq $Binding.buildReceiptPin.sha256 -and
        $test.testScriptSha256 -ceq 'b16ef328200c6d27cba93d5ca6f6dc91af75c26e2f02b22051690d407b88d3ad' -and
        $test.tamperRejected -eq $true -and $test.differentStockPeerRejected -eq $true) 'key_test_receipt_invalid'
}
function Assert-RnSourceBaseline([object]$Binding) {
    # Control experiment only: exact prior baseline build, without peer changes.
    foreach ($pin in @($Binding.libraryPin,$Binding.buildReceiptPin,$Binding.testReceiptPin)) {Assert-RnPin $pin}
    Assert-Rn ($Binding.libraryPin.sha256 -ceq 'e42dd6eda126ce4fe5e65254d9dd77b2ec86545513ec4c5db0fd7c4cd754b8ba' -and
        $Binding.buildReceiptPin.sha256 -ceq 'cd26d9a1f59c95efffd4a0128a4ea241eaac77b1d23dd850e96e639a255ad9d8') 'baseline_package_unreviewed'
    $build=Read-RnJson $Binding.buildReceiptPin.path $Binding.buildReceiptPin.sha256
    $test=Read-RnJson $Binding.testReceiptPin.path $Binding.testReceiptPin.sha256
    Assert-Rn ($build.baselinePin.sha256 -ceq $Binding.libraryPin.sha256 -and $build.exportCount -eq 756 -and
        $build.exportsMatchStock -eq $true -and $build.exportsMatchBaseline -eq $true) 'baseline_build_invalid'
    Assert-Rn ($test.contractId -ceq 'nll/resource-server-crypto-synthetic/v1' -and $test.status -ceq 'passed' -and
        $test.checks -eq 14 -and $test.sourceBaselineLibrary -eq $true -and $test.stockClientLibrary -eq $false -and
        $test.librarySha256 -ceq $Binding.libraryPin.sha256 -and
        $test.testScriptSha256 -ceq '6d032dc2f1745c61730532d762a9f085ccd779f4b571ffb2c61078f17377416b' -and
        $test.syntheticKeysOnly -eq $true -and $test.systemChangesApplied -eq $false -and
        @($test.passed).Count -eq 14 -and 'wrong_direction_rejected' -cin $test.passed -and
        'wrong_aad_rejected' -cin $test.passed -and 'tamper_rejected' -cin $test.passed) 'baseline_test_invalid'
}
function Get-RnBlockedProgramObservations([string[]]$PinnedPaths,[object[]]$Processes) {
    foreach ($entry in $Processes) {
        $index=-1
        for ($i=0;$i -lt $PinnedPaths.Count;$i++) {
            if ($entry.ExecutablePath -ieq $PinnedPaths[$i]) {$index=$i;break}
        }
        Assert-Rn ($index -ge 0 -and $entry.ProcessId -gt 0) 'blocked_program_identity_invalid'
        [ordered]@{programIndex=$index
            role=$(if ($PinnedPaths[$index].StartsWith('C:\NIKKE\',[StringComparison]::OrdinalIgnoreCase)) {'official_install_program'} else {'installed_related_service'})
            processId=$entry.ProcessId;parentProcessId=$entry.ParentProcessId
            createdAtUtc=$entry.CreationDate.ToUniversalTime()}
    }
}
function New-RnPrivateDirectory([string]$Path) {
    Assert-RnPath $Path
    Assert-Rn (-not (Test-Path -LiteralPath $Path)) 'destination_exists'
    New-Item -ItemType Directory -Path $Path | Out-Null
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($sid)
    foreach ($principal in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
    Assert-Rn (Get-Acl -LiteralPath $Path).AreAccessRulesProtected 'acl_invalid'
}
function Write-RnNewBytes([string]$Path,[byte[]]$Bytes) {
    Assert-RnPath $Path
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Write-RnNewJson([string]$Path,[object]$Value) {
    Write-RnNewBytes $Path ([Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 12)))
}
function Read-RnJson([string]$Path,[string]$Sha256) {
    Assert-Rn ((Get-RnHash $Path) -ceq $Sha256 -and (Get-Item -LiteralPath $Path).Length -le 2097152) 'plan_drift'
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function Copy-RnNew([string]$Source,[string]$Target) {
    $pin=Get-RnPin $Source
    Assert-RnPath $Target
    Assert-Rn (-not (Test-Path -LiteralPath $Target)) 'destination_exists'
    Copy-Item -LiteralPath $Source -Destination $Target
    Assert-RnPin $pin
    Assert-Rn ((Get-RnHash $Target) -ceq $pin.sha256) 'copy_drift'
}
function Set-RnPinnedFile([object]$Current,[object]$Replacement) {
    # Used both to apply and to restore. Never overwrite an unexpected new state.
    Assert-RnPin $Current
    Assert-RnPin $Replacement
    $attributes=(Get-Item -LiteralPath $Current.path).Attributes
    Assert-Rn (($attributes -band [IO.FileAttributes]::ReadOnly) -eq 0) 'target_readonly'
    Copy-Item -LiteralPath $Replacement.path -Destination $Current.path
    Assert-Rn ((Get-RnHash $Current.path) -ceq $Replacement.sha256) 'write_drift'
}
function New-RnHostsBytes([byte[]]$Original,[string[]]$Hosts,[string]$Uid) {
    Assert-Rn ($Uid -cmatch '^[a-f0-9-]{36}$' -and $Hosts.Count -gt 0 -and $Hosts.Count -le 16) 'hosts_plan_invalid'
    $text=[Text.Encoding]::UTF8.GetString($Original)
    Assert-Rn (-not $text.Contains('NLL Resource Native')) 'hosts_stale_marker'
    foreach ($name in $Hosts) {
        Assert-Rn ($name -cmatch '^[a-z0-9.-]+$' -and -not $name.Contains('..')) 'host_invalid'
        foreach ($line in ($text -split '\r?\n')) {
            $fields=@(($line -split '#',2)[0].Trim() -split '\s+' | Where-Object {$_})
            if ($fields.Count -gt 1 -and $name -in $fields[1..($fields.Count-1)]) {
                Assert-Rn ($fields[0] -ceq '127.0.0.1') 'hosts_conflict'
            }
        }
    }
    $block="`r`n# begin NLL Resource Native $Uid`r`n" + (($Hosts | ForEach-Object {"127.0.0.1 $_"}) -join "`r`n") + "`r`n# end NLL Resource Native $Uid`r`n"
    return ,([byte[]]($Original + [Text.Encoding]::ASCII.GetBytes($block)))
}
function Get-RnVoicePreferences {
    # Read only the two already established values, never unrelated PlayerPrefs.
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\com.proximabeta\NIKKE',$false)
    Assert-Rn ($null -ne $key) 'preferences_missing'
    try {
        foreach ($name in @('voiceLocale_h4098423835','voiceDownloadType_h2535520031')) {
            $value=$key.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Assert-Rn ($value -is [byte[]] -or $value -is [string]) 'preference_type_unresolved'
            $kind=$key.GetValueKind($name).ToString()
            Assert-Rn ($kind -in 'Binary','String') 'preference_type_unresolved'
            [ordered]@{name=$name;kind=$kind;value=$(if ($value -is [byte[]]) {[Convert]::ToBase64String($value)} else {$value})}
        }
    } finally { $key.Dispose() }
}
function ConvertTo-RnVoicePreference([object]$Original,[string]$Text) {
    [ordered]@{name=$Original.name;kind=$Original.kind;value=$(if ($Original.kind -ceq 'Binary') {[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text + [char]0))} else {$Text})}
}
function Set-RnPreferenceValue([Microsoft.Win32.RegistryKey]$Key,[object]$Item) {
    # Preserve byte[] at the .NET call boundary, not through pipeline assignment.
    if ($Item.kind -ceq 'Binary') {
        $Key.SetValue($Item.name,[Convert]::FromBase64String($Item.value),[Microsoft.Win32.RegistryValueKind]::Binary)
    } elseif ($Item.kind -ceq 'String') {
        $Key.SetValue($Item.name,[string]$Item.value,[Microsoft.Win32.RegistryValueKind]::String)
    } else {Assert-Rn $false 'preference_type_unresolved'}
}
function Set-RnVoicePreferences([object[]]$Expected,[object[]]$Replacement) {
    $current=@(Get-RnVoicePreferences)
    Assert-Rn ($Expected.Count -eq 2 -and $Replacement.Count -eq 2) 'preference_plan_invalid'
    for ($i=0;$i -lt 2;$i++) {
        Assert-Rn ($current[$i].name -ceq $Expected[$i].name -and $current[$i].kind -ceq $Expected[$i].kind -and $current[$i].value -ceq $Expected[$i].value -and $Replacement[$i].name -ceq $Expected[$i].name) 'preference_drift'
    }
    $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Software\com.proximabeta\NIKKE',$true)
    try {
        foreach ($item in $Replacement) {
            Set-RnPreferenceValue $key $item
        }
        $key.Flush()
    } finally { $key.Dispose() }
    $actual=@(Get-RnVoicePreferences)
    for ($i=0;$i -lt 2;$i++) { Assert-Rn ($actual[$i].value -ceq $Replacement[$i].value -and $actual[$i].kind -ceq $Replacement[$i].kind) 'preference_write_failed' }
}
