[CmdletBinding()]
param([switch]$VerifyExistingBuild)
# Offline, source-built local-peer binding. Never installs or launches a client.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.ResourceNative.ps1')
$repository = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repository '.external\libsodium-151-key-compat'
$output = Join-Path $repository 'artifacts\resource-probe-151\native-key-compat-v1'
$stock = 'C:\NLL\Clients\NIKKE-151.8.5-ResourceProbe\NIKKE\game\nikke_Data\Plugins\x86_64\sodium.dll'
$msbuild = 'C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe'
$dumpbin = 'C:\Program Files\Microsoft Visual Studio\18\Community\VC\Tools\MSVC\14.51.36231\bin\Hostx64\x64\dumpbin.exe'
$commit = '77e1ce5d6dee871c49ef211222ba18ef0c486bda'
$patchHash = '4330442a750237485de429f7be750c3d88156dfd039b248e1c765390361f5508'
Assert-Rn ((& git -C $source rev-parse HEAD) -ceq $commit) 'source_commit_drift'
Assert-Rn ((Get-RnHash (Join-Path $source 'src\libsodium\crypto_kx\crypto_kx.c')) -ceq $patchHash) 'source_patch_drift'
$changed = @(& git -C $source diff --name-only HEAD)
Assert-Rn ($changed.Count -eq 1 -and $changed[0] -ceq 'src/libsodium/crypto_kx/crypto_kx.c') 'unreviewed_source_change'
Assert-Rn ((Get-RnHash $stock) -ceq '11a42045b328e74dc03e69be574c38f0004c515d364383f230ea4dba30414f6f') 'stock_library_drift'
Assert-Rn (@(Get-CimInstance Win32_Process | Where-Object {$_.Name -match '^(nikke|nikke_launcher|EpinelPS)\.exe$'}).Count -eq 0) 'runtime_not_cold'
if ($VerifyExistingBuild) { Assert-RnPath $output; Assert-Rn (Test-Path -LiteralPath $output -PathType Container) 'build_missing' }
else { New-RnPrivateDirectory $output }
$serverSource = Get-Content -LiteralPath (Join-Path $repository '.external\EpinelPS-151-candidate\EpinelPS\Database\JsonDb.cs') -Raw
$match = [regex]::Match($serverSource, 'ServerPublicKey\s*=\s*Convert\.FromBase64String\("(?<value>[A-Za-z0-9+/=]+)"\)')
Assert-Rn $match.Success 'local_peer_binding_unresolved'
$publicKey = [Convert]::FromBase64String($match.Groups['value'].Value)
Assert-Rn ($publicKey.Length -eq 32) 'local_peer_shape_invalid'
$header = Join-Path $output 'local-peer.generated.h'
$bytes = ($publicKey | ForEach-Object { '0x{0:x2}' -f $_ }) -join ','
$headerBytes = [Text.Encoding]::ASCII.GetBytes("#define NLL_LOCAL_SERVER_PUBLIC_KEY {$bytes}`n")
if ($VerifyExistingBuild) {
    Assert-Rn ((Get-RnHash $header) -ceq [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($headerBytes)).ToLowerInvariant()) 'generated_binding_drift'
} else { Write-RnNewBytes $header $headerBytes }
$oldCompilerOptions = [Environment]::GetEnvironmentVariable('CL', 'Process')
$oldCompilerTail = [Environment]::GetEnvironmentVariable('_CL_', 'Process')
try {
    [Environment]::SetEnvironmentVariable('_CL_', $null, 'Process')
    foreach ($role in $(if ($VerifyExistingBuild) { @() } else { @('baseline', 'local') })) {
        $buildRoot = Join-Path $output $role
        New-RnPrivateDirectory $buildRoot
        [Environment]::SetEnvironmentVariable('CL', $(if ($role -ceq 'local') { '/FI"' + $header + '"' } else { $null }), 'Process')
        & $msbuild (Join-Path $source 'builds\msvc\vs2026\libsodium\libsodium.vcxproj') /nologo /m:2 /v:quiet /t:Build `
            /p:Configuration=ReleaseDLL /p:Platform=x64 /p:TargetName=sodium `
            ('/p:OutDir=' + $buildRoot + '\') ('/p:IntDir=' + $buildRoot + '\obj\')
        Assert-Rn ($LASTEXITCODE -eq 0) 'native_source_build_failed'
    }
} finally {
    [Environment]::SetEnvironmentVariable('CL', $oldCompilerOptions, 'Process')
    [Environment]::SetEnvironmentVariable('_CL_', $oldCompilerTail, 'Process')
}
function Get-Exports([string]$Path) {
    $lines = @(& $dumpbin /nologo /exports $Path)
    Assert-Rn ($LASTEXITCODE -eq 0) 'export_inspection_failed'
    @($lines | ForEach-Object { if ($_ -match '^\s+\d+\s+[0-9A-F]+\s+[0-9A-F]+\s+(\w+)(?:\s+=\s+.*)?\s*$') { $Matches[1] } } | Sort-Object)
}
$stockExports = @(Get-Exports $stock)
$baseline = Join-Path $output 'baseline\sodium.dll'
$library = Join-Path $output 'local\sodium.dll'
$baselineExports = @(Get-Exports $baseline)
$localExports = @(Get-Exports $library)
Assert-Rn ($stockExports.Count -ge 700) 'stock_export_shape_invalid'
Assert-Rn (@(Compare-Object $stockExports $localExports).Count -eq 0) 'stock_export_mismatch'
Assert-Rn (@(Compare-Object $baselineExports $localExports).Count -eq 0) 'baseline_export_mismatch'
$imports = (& $dumpbin /nologo /imports $library) -join "`n"
Assert-Rn ($LASTEXITCODE -eq 0) 'import_inspection_failed'
Assert-Rn ($imports -notmatch '(?i)USER32\.dll|WINHTTP\.dll|WININET\.dll|WS2_32\.dll|CreateThread|OpenProcess|WriteProcessMemory|ReadProcessMemory|FlushInstructionCache|SetWindowsHook') 'unreviewed_native_capability'
$receipt = [ordered]@{contractId='nll/resource-key-compat-build/v1';status='built_not_installed';sourceCommit=$commit;sourcePatchSha256=$patchHash
    stockPin=(Get-RnPin $stock);baselinePin=(Get-RnPin $baseline);libraryPin=(Get-RnPin $library);generatedPublicBindingSha256=(Get-RnHash $header)
    exportCount=$localExports.Count;exportsMatchStock=$true;exportsMatchBaseline=$true;unreviewedImportsAbsent=$true
    clientStarted=$false;serverStarted=$false;systemChangesApplied=$false;macValidationChanged=$false}
Write-RnNewJson (Join-Path $output 'build.private.json') $receipt
[pscustomobject]$receipt | Select-Object contractId,status,sourceCommit,sourcePatchSha256,exportCount,exportsMatchStock,exportsMatchBaseline,unreviewedImportsAbsent,clientStarted,systemChangesApplied,macValidationChanged | ConvertTo-Json
