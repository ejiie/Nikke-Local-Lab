[CmdletBinding()]
param()
# Offline comparison of reviewed native libraries; never loads into the game.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object {$_.Name -match '^(nikke|nikke_launcher|EpinelPS)\.exe$'}).Count -eq 0) 'runtime_not_cold'
$buildRoot=Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\resource-probe-151\native-key-compat-v1'
$build=Read-RnJson (Join-Path $buildRoot 'build.private.json') 'cd26d9a1f59c95efffd4a0128a4ea241eaac77b1d23dd850e96e639a255ad9d8'
foreach($pin in @($build.stockPin,$build.baselinePin,$build.libraryPin)){Assert-RnPin $pin}
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class NllNativeAbiProbe {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int IntValue();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate UIntPtr SizeValue();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr StringValue();
    static T Fn<T>(IntPtr h, string n) where T: Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(h,n));
    public static Dictionary<string,object> Read(string path) {
        var h=NativeLibrary.Load(path);
        try {
            var result=new Dictionary<string,object>();
            result["sodium_init"]=Fn<IntValue>(h,"sodium_init")();
            result["sodium_version_string"]=Marshal.PtrToStringAnsi(Fn<StringValue>(h,"sodium_version_string")());
            foreach(var name in new[]{"sodium_library_version_major","sodium_library_version_minor",
                "sodium_library_minimal","sodium_runtime_has_aesni","sodium_runtime_has_avx2"})
                result[name]=Fn<IntValue>(h,name)();
            foreach(var name in new[]{"crypto_generichash_statebytes","crypto_generichash_bytes",
                "crypto_generichash_blake2b_statebytes","crypto_hash_sha256_statebytes","crypto_hash_sha512_statebytes",
                "crypto_auth_hmacsha256_statebytes","crypto_auth_hmacsha512_statebytes","crypto_sign_statebytes",
                "crypto_secretstream_xchacha20poly1305_statebytes","crypto_aead_aes256gcm_statebytes",
                "crypto_kx_publickeybytes","crypto_kx_secretkeybytes","crypto_kx_sessionkeybytes",
                "crypto_aead_xchacha20poly1305_ietf_keybytes","crypto_aead_xchacha20poly1305_ietf_npubbytes",
                "crypto_aead_xchacha20poly1305_ietf_abytes","crypto_sign_publickeybytes","crypto_sign_bytes"})
                result[name]=Fn<SizeValue>(h,name)().ToUInt64();
            return result;
        } finally {NativeLibrary.Free(h);}
    }
}
'@
$rows=@()
foreach($role in @('stock','baseline','local')){
    $pin=switch($role){stock {$build.stockPin};baseline {$build.baselinePin};local {$build.libraryPin}}
    $rows += [pscustomobject]@{role=$role;values=[NllNativeAbiProbe]::Read($pin.path)}
}
$differences=@(foreach($name in $rows[0].values.Keys){
    $values=@($rows | ForEach-Object {$_.values[$name]})
    if(@($values | Select-Object -Unique).Count -gt 1){[pscustomobject]@{field=$name;stock=$values[0];baseline=$values[1];local=$values[2]}}
})
[ordered]@{contractId='nll/resource-native-abi-comparison/v1';status='observed';libraries=$rows;
    differences=$differences;clientStarted=$false;serverStarted=$false;systemChangesApplied=$false;
    note='Matching constants do not prove binary or native-client compatibility.'} | ConvertTo-Json -Depth 6
