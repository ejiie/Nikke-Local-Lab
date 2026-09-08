[CmdletBinding()]
param([switch]$CheckCandidate)
# Offline synthetic key-agreement comparison. No game/server, network or file mutation.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$repository = Split-Path -Parent $PSScriptRoot
$stock = 'C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll'
Assert-Rn ((Get-RnHash $stock) -ceq '11a42045b328e74dc03e69be574c38f0004c515d364383f230ea4dba30414f6f') 'stock_library_drift'
Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object { $_.Name -match '^(nikke|nikke_launcher|EpinelPS)\.exe$' }).Count -eq 0) 'runtime_not_cold'
$source = Get-Content -LiteralPath (Join-Path $repository '.external\EpinelPS-151-candidate\EpinelPS\Database\JsonDb.cs') -Raw
$keys = @{}
foreach ($role in @('Public', 'Private')) {
    $match = [regex]::Match($source, ('Server' + $role + 'Key\s*=\s*Convert\.FromBase64String\("(?<value>[A-Za-z0-9+/=]+)"\)'))
    Assert-Rn $match.Success 'local_server_key_binding_unresolved'
    $keys[$role] = [Convert]::FromBase64String($match.Groups['value'].Value)
    Assert-Rn ($keys[$role].Length -eq 32) 'local_server_key_shape_invalid'
}
$candidate = $null
if ($CheckCandidate) {
    $buildRoot = Join-Path $repository 'artifacts\resource-probe-151\native-key-compat-v1'
    $candidate = Get-Content -LiteralPath (Join-Path $buildRoot 'build.private.json') -Raw | ConvertFrom-Json
    Assert-Rn ($candidate.contractId -ceq 'nll/resource-key-compat-build/v1' -and $candidate.exportsMatchStock -and $candidate.unreviewedImportsAbsent) 'candidate_unreviewed'
    Assert-Rn ($candidate.libraryPin.path -ceq (Join-Path $buildRoot 'local\sodium.dll')) 'candidate_path_invalid'
    Assert-RnPin $candidate.stockPin
    Assert-RnPin $candidate.libraryPin
    Assert-RnPin $candidate.baselinePin
}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
public static class NllSyntheticKeyAgreement
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Init();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int KeyPair([Out] byte[] pk, [Out] byte[] sk);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Kx([Out] byte[] rx, [Out] byte[] tx, byte[] pk, byte[] sk, byte[] peer);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Base([Out] byte[] pk, byte[] sk);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Seal([Out] byte[] c, out ulong size, byte[] m, ulong msize, byte[] aad, ulong aadsize, IntPtr secretNonce, byte[] nonce, byte[] key);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Open([Out] byte[] m, out ulong size, IntPtr secretNonce, byte[] c, ulong csize, byte[] aad, ulong aadsize, byte[] nonce, byte[] key);
    static T Function<T>(IntPtr handle, string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(handle, name));
    static int checks;
    static void Check(bool value, string role) { if (!value) throw new InvalidOperationException("synthetic_key_agreement_" + role); checks++; }
    static bool Same(byte[] a, byte[] b) => CryptographicOperations.FixedTimeEquals(a, b);
    public static int Run(string stockPath, string compatPath, byte[] serverPk, byte[] serverSk)
    {
        checks = 0;
        IntPtr stock = NativeLibrary.Load(stockPath), compat = IntPtr.Zero;
        byte[] clientSk = new byte[32], otherSk = new byte[32];
        try {
            Check(Function<Init>(stock, "sodium_init")() >= 0, "stock_init");
            var pk = new byte[32];
            Check(Function<Base>(stock, "crypto_scalarmult_base")(pk, serverSk) == 0 && Same(pk, serverPk), "server_pair");
            byte[] clientPk = new byte[32], otherPk = new byte[32];
            var pair = Function<KeyPair>(stock, "crypto_kx_keypair");
            Check(pair(clientPk, clientSk) == 0 && pair(otherPk, otherSk) == 0, "synthetic_pairs");
            var server = Function<Kx>(stock, "crypto_kx_server_session_keys");
            var client = Function<Kx>(stock, "crypto_kx_client_session_keys");
            byte[] sr = new byte[32], st = new byte[32], cr = new byte[32], ct = new byte[32];
            Check(server(sr, st, serverPk, serverSk, clientPk) == 0, "server_kx");
            Check(client(cr, ct, clientPk, clientSk, serverPk) == 0 && Same(sr, ct) && Same(st, cr), "matching_stock_peer");
            byte[] wrongRx = new byte[32], wrongTx = new byte[32];
            Check(client(wrongRx, wrongTx, clientPk, clientSk, otherPk) == 0 && !Same(sr, wrongTx) && !Same(st, wrongRx), "different_stock_peer");
            if (!string.IsNullOrEmpty(compatPath)) {
                compat = NativeLibrary.Load(compatPath);
                Check(Function<Init>(compat, "sodium_init")() >= 0, "candidate_init");
                var localClient = Function<Kx>(compat, "crypto_kx_client_session_keys");
                Check(localClient(cr, ct, clientPk, clientSk, otherPk) == 0 && Same(sr, ct) && Same(st, cr), "local_peer_binding");
                byte[] localSr = new byte[32], localSt = new byte[32];
                Check(Function<Kx>(compat, "crypto_kx_server_session_keys")(localSr, localSt, serverPk, serverSk, clientPk) == 0 && Same(localSr, sr) && Same(localSt, st), "server_operation_unchanged");
            }
            byte[] message = { 1, 2, 3, 4 }, aad = { 130, 1, 0 }, nonce = RandomNumberGenerator.GetBytes(24);
            byte[] cipher = new byte[message.Length + 16], plain = new byte[message.Length];
            var seal = Function<Seal>(stock, "crypto_aead_xchacha20poly1305_ietf_encrypt");
            var open = Function<Open>(stock, "crypto_aead_xchacha20poly1305_ietf_decrypt");
            Check(seal(cipher, out var csize, message, (ulong)message.Length, aad, (ulong)aad.Length, IntPtr.Zero, nonce, ct) == 0, "seal");
            Check(open(plain, out var msize, IntPtr.Zero, cipher, csize, aad, (ulong)aad.Length, nonce, sr) == 0 && msize == (ulong)message.Length && Same(plain, message), "valid_mac");
            Check(seal(cipher, out csize, message, (ulong)message.Length, aad, (ulong)aad.Length, IntPtr.Zero, nonce, wrongTx) == 0, "wrong_peer_seal");
            Check(open(plain, out msize, IntPtr.Zero, cipher, csize, aad, (ulong)aad.Length, nonce, sr) == -1, "wrong_peer_mac_rejected");
            Check(seal(cipher, out csize, message, (ulong)message.Length, aad, (ulong)aad.Length, IntPtr.Zero, nonce, ct) == 0, "reseal");
            cipher[0] ^= 1;
            Check(open(plain, out msize, IntPtr.Zero, cipher, csize, aad, (ulong)aad.Length, nonce, sr) == -1, "tamper_rejected");
            return checks;
        } finally {
            CryptographicOperations.ZeroMemory(clientSk); CryptographicOperations.ZeroMemory(otherSk);
            if (compat != IntPtr.Zero) NativeLibrary.Free(compat);
            NativeLibrary.Free(stock);
        }
    }
}
'@
try {
    $libraryPath = if ($CheckCandidate) { $candidate.libraryPin.path } else { '' }
    $checks = [NllSyntheticKeyAgreement]::Run($stock, $libraryPath, $keys.Public, $keys.Private)
    $receipt = [ordered]@{contractId='nll/resource-key-compat-synthetic/v1';status='passed';checks=$checks;candidateChecked=[bool]$CheckCandidate;matchingStockPeerAccepted=$true;differentStockPeerRejected=$true;legacyLibraryExecuted=$false;tamperRejected=$true;clientStarted=$false;serverStarted=$false;systemChangesApplied=$false;keyMaterialEmitted=$false}
    if ($CheckCandidate) {
        $receipt['librarySha256']=$candidate.libraryPin.sha256
        $receipt['buildReceiptSha256']=Get-RnHash (Join-Path $buildRoot 'build.private.json')
        $receipt['testScriptSha256']=Get-RnHash $PSCommandPath
        Write-RnNewJson (Join-Path $buildRoot 'synthetic.private.json') $receipt
    }
    $receipt | ConvertTo-Json
} finally {
    [Security.Cryptography.CryptographicOperations]::ZeroMemory($keys.Private)
}
