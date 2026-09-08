[CmdletBinding()]
param([switch]$UseSourceBaseline)
# Offline synthetic comparison of the deployed ASodium wrapper with the stock
# client library. No official key/session, server listener or game execution.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object {$_.Name -match '^(nikke|nikke_launcher|EpinelPS)\.exe$'}).Count -eq 0) 'runtime_not_cold'
$serverRoot=Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\resource-probe-151\epinel-server-v2'
$stock='C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll'
$wrapper=Join-Path $serverRoot 'ASodium.dll'
$serverNative=Join-Path $serverRoot 'libsodium.dll'
foreach($entry in @(
    @($stock,'11a42045b328e74dc03e69be574c38f0004c515d364383f230ea4dba30414f6f'),
    @($wrapper,'dc8f18e9eb7319be94a98dc9d33f87a6e0923c15d03fa4187035c8ed26e38ab3'),
    @($serverNative,'64a1f143868309069f0a0a3c8141c0853c4f17243ddf734e92b11c5411739771'))){
    Assert-Rn ((Get-RnHash $entry[0]) -ceq $entry[1]) 'server_crypto_input_drift'
}
if ($UseSourceBaseline) {
    $buildPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'artifacts\resource-probe-151\native-key-compat-v1\build.private.json'
    $build=Read-RnJson $buildPath 'cd26d9a1f59c95efffd4a0128a4ea241eaac77b1d23dd850e96e639a255ad9d8'
    Assert-RnPin $build.baselinePin
    Assert-Rn ($build.baselinePin.sha256 -ceq 'e42dd6eda126ce4fe5e65254d9dd77b2ec86545513ec4c5db0fd7c4cd754b8ba') 'source_baseline_drift'
    $stock=$build.baselinePin.path
}
$null=[Reflection.Assembly]::LoadFrom($wrapper)
# ASodium targets .NET 8 while the deployed server/test host uses .NET 10.
# Suppress only that reviewed reference-unification compiler warning.
Add-Type -CompilerOptions '/nowarn:1701' -ReferencedAssemblies @($wrapper,'System.Runtime.dll','System.Runtime.InteropServices.dll','System.Security.Cryptography.dll','System.Text.Json.dll','System.Collections.dll') -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using ASodium;
public static class NllServerCryptoProbe {
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Init();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Pair([Out] byte[] pk,[Out] byte[] sk);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Kx([Out] byte[] rx,[Out] byte[] tx,byte[] pk,byte[] sk,byte[] peer);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Seal([Out] byte[] c,out ulong len,byte[] m,ulong mlen,byte[] aad,ulong aadlen,IntPtr secret,byte[] nonce,byte[] key);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Open([Out] byte[] m,out ulong len,IntPtr secret,byte[] c,ulong clen,byte[] aad,ulong aadlen,byte[] nonce,byte[] key);
    static T Fn<T>(IntPtr h,string n) where T:Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(h,n));
    static void Check(bool ok,string name,List<string> checks){if(!ok)throw new InvalidOperationException("server_crypto_"+name);checks.Add(name);}
    static bool Same(byte[] a,byte[] b)=>CryptographicOperations.FixedTimeEquals(a,b);
    public static string[] Run(string stockPath,string serverNativePath){
        // Resolver affects this short-lived test process and this wrapper only.
        var serverHandle=NativeLibrary.Load(serverNativePath);
        NativeLibrary.SetDllImportResolver(typeof(SodiumKeyExchange).Assembly,(name,assembly,searchPath)=>
            name.IndexOf("sodium",StringComparison.OrdinalIgnoreCase)>=0?serverHandle:IntPtr.Zero);
        var stock=NativeLibrary.Load(stockPath);
        var checks=new List<string>();
        byte[] clientPk=new byte[32],clientSk=new byte[32],rx=new byte[32],tx=new byte[32];
        byte[] serverSk=Array.Empty<byte>();
        try {
            Check(Fn<Init>(stock,"sodium_init")()>=0,"stock_init",checks);
            Check(Fn<Pair>(stock,"crypto_kx_keypair")(clientPk,clientSk)==0,"synthetic_client_pair",checks);
            var serverPair=SodiumKeyExchange.GenerateRevampedKeyPair();serverSk=serverPair.PrivateKey;
            var server=SodiumKeyExchange.CalculateServerSharedSecret(serverPair.PublicKey,serverSk,clientPk,false);
            Check(Fn<Kx>(stock,"crypto_kx_client_session_keys")(rx,tx,clientPk,clientSk,serverPair.PublicKey)==0,"stock_client_kx",checks);
            Check(Same(tx,server.ReadSharedSecret),"client_tx_equals_server_rx",checks);
            Check(Same(rx,server.TransferSharedSecret),"client_rx_equals_server_tx",checks);
            var encoded=JsonSerializer.Serialize(server);
            var restored=JsonSerializer.Deserialize<SodiumKeyExchangeSharedSecretBox>(encoded);
            Check(restored!=null&&Same(restored.ReadSharedSecret,server.ReadSharedSecret)&&Same(restored.TransferSharedSecret,server.TransferSharedSecret),"json_key_roundtrip",checks);
            byte[] message={0x82,1,7,1,2,3,4},aad={0x82,1,0x59,0,4,0x74,0x65,0x73,0x74};
            byte[] nonce=RandomNumberGenerator.GetBytes(24),cipher=new byte[message.Length+16];
            Check(Fn<Seal>(stock,"crypto_aead_xchacha20poly1305_ietf_encrypt")(cipher,out var clen,message,(ulong)message.Length,aad,(ulong)aad.Length,IntPtr.Zero,nonce,tx)==0,"stock_encrypt",checks);
            Check(Same(SodiumSecretAeadXChaCha20Poly1305IETF.Decrypt(cipher,nonce,restored.ReadSharedSecret,aad,null,false),message),"server_decrypt_after_json",checks);
            var response=SodiumSecretAeadXChaCha20Poly1305IETF.Encrypt(message,nonce,server.TransferSharedSecret,aad,null,false);
            var plain=new byte[message.Length];
            Check(Fn<Open>(stock,"crypto_aead_xchacha20poly1305_ietf_decrypt")(plain,out var mlen,IntPtr.Zero,response,(ulong)response.Length,aad,(ulong)aad.Length,nonce,rx)==0&&Same(plain,message),"stock_decrypt_server_response",checks);
            var savedRx=(byte[])restored.ReadSharedSecret.Clone();
            // Production omits optional ClearKey; check that default separately.
            Check(Same(SodiumSecretAeadXChaCha20Poly1305IETF.Decrypt(cipher,nonce,restored.ReadSharedSecret,aad),message),"default_decrypt",checks);
            Check(Same(savedRx,restored.ReadSharedSecret),"default_decrypt_preserves_key",checks);
            bool rejected=false;
            try {SodiumSecretAeadXChaCha20Poly1305IETF.Decrypt(cipher,nonce,server.TransferSharedSecret,aad,null,false);}catch(CryptographicException){rejected=true;}
            Check(rejected,"wrong_direction_rejected",checks);
            rejected=false;var wrongAad=(byte[])aad.Clone();wrongAad[1]^=1;
            try {SodiumSecretAeadXChaCha20Poly1305IETF.Decrypt(cipher,nonce,server.ReadSharedSecret,wrongAad,null,false);}catch(CryptographicException){rejected=true;}
            Check(rejected,"wrong_aad_rejected",checks);
            rejected=false;cipher[0]^=1;
            try {SodiumSecretAeadXChaCha20Poly1305IETF.Decrypt(cipher,nonce,server.ReadSharedSecret,aad,null,false);}catch(CryptographicException){rejected=true;}
            Check(rejected,"tamper_rejected",checks);
            return checks.ToArray();
        } finally {
            CryptographicOperations.ZeroMemory(clientSk);CryptographicOperations.ZeroMemory(serverSk);
            CryptographicOperations.ZeroMemory(rx);CryptographicOperations.ZeroMemory(tx);
            NativeLibrary.Free(stock);
            // The wrapper resolver can still reference its handle until process exit.
        }
    }
}
'@
$checks=[NllServerCryptoProbe]::Run($stock,$serverNative)
[ordered]@{contractId='nll/resource-server-crypto-synthetic/v1';status='passed';checks=$checks.Count;passed=$checks;
    stockClientLibrary=(-not $UseSourceBaseline);sourceBaselineLibrary=[bool]$UseSourceBaseline;
    librarySha256=(Get-RnHash $stock);testScriptSha256=(Get-RnHash $PSCommandPath);
    deployedServerWrapper=$true;syntheticKeysOnly=$true;keyMaterialEmitted=$false;
    clientStarted=$false;serverStarted=$false;systemChangesApplied=$false;
    nativeWireCompatibilityVerified=$false} | ConvertTo-Json -Depth 4
