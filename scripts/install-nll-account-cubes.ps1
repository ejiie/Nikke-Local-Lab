[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$install = 'C:\NLL\ControlCenter'
$prepared = Join-Path $repo 'artifacts\phase-d\cube-presentation'
$app = Join-Path $repo 'artifacts\phase-d\cube-app'
$maintenance = Join-Path $repo 'artifacts\phase-d\cube-maintenance\NikkeLocalLab.AccountCubeMaintenance.dll'
$materializer = Join-Path $repo 'tools\NikkeLocalLab.PhaseD.RuntimeMaterializer\bin\Release\net10.0\win-x64'
$runtimeTarget = Join-Path $repo 'artifacts\phase-d\runtime-materializer'
$statusPath = Join-Path $prepared 'installation-status.json'
$backup = $null
$pgStarted = $false
function Require-Cube([bool]$Condition, [string]$Code) { if (-not $Condition) { throw $Code } }
function Cube-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Cube-Pg([string[]]$Arguments) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_ctl.exe'
    $info.Arguments = (($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($info)
    $process.WaitForExit()
    $code = $process.ExitCode
    $process.Dispose()
    return $code
}
function Cube-Status([string]$State, [string]$Failure = '') {
    [IO.File]::WriteAllText($statusPath, (@{ status=$State; failureCode=$Failure; backupRoot=$backup; utc=[DateTimeOffset]::UtcNow.ToString('o') } | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}
try {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    Require-Cube ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and $env:USERNAME -eq 'nlloperator') 'cube_install_admin_required'
    Require-Cube (-not @(Get-Process NIKKE,EpinelPS -ErrorAction SilentlyContinue).Count) 'cube_install_game_must_be_closed'
    foreach ($port in @(17878,55433)) {
        $tcp = New-Object Net.Sockets.TcpClient
        try { try { $live=$tcp.ConnectAsync('127.0.0.1',$port).Wait(500) -and $tcp.Connected } catch { $live=$false } }
        finally { $tcp.Dispose() }
        Require-Cube (-not $live) 'cube_install_control_center_must_be_closed'
    }
    $pairs = New-Object 'Collections.Generic.List[object]'
    foreach ($leaf in @('NikkeLocalLab.Admin.Api.dll','NikkeLocalLab.Domain.Profile.dll','NikkeLocalLab.Persistence.PostgreSql.dll')) {
        $pairs.Add(@{source=(Join-Path $app $leaf);target=(Join-Path $install ('app\'+$leaf))})
    }
    foreach ($leaf in @('index.html','editor.js','editor.css')) {
        $pairs.Add(@{source=(Join-Path $app ('wwwroot\editor\'+$leaf));target=(Join-Path $install ('app\wwwroot\editor\'+$leaf))})
    }
    $pairs.Add(@{source=(Join-Path $prepared 'presentation.json');target=(Join-Path $install 'app\wwwroot\editor\presentation.json')})
    foreach ($leaf in @('NikkeLocalLab.PhaseD.RuntimeMaterializer.exe','NikkeLocalLab.PhaseD.RuntimeMaterializer.dll','NikkeLocalLab.PhaseD.RuntimeMaterializer.deps.json','NikkeLocalLab.PhaseD.RuntimeMaterializer.runtimeconfig.json')) {
        $pairs.Add(@{source=(Join-Path $materializer $leaf);target=(Join-Path $runtimeTarget $leaf)})
    }
    $receipt = Get-Content -LiteralPath (Join-Path $prepared 'assets\support-assets.receipt.json') -Raw | ConvertFrom-Json
    Require-Cube ($receipt.assetCount -eq 17) 'cube_install_asset_count_invalid'
    foreach ($member in $receipt.members) {
        Require-Cube ($member.kindCode -eq 'cubes' -and $member.definitionUid -match '^[0-9a-f-]{36}$') 'cube_install_asset_identity_invalid'
        $source = Join-Path $prepared ('assets\cubes\'+$member.definitionUid+'.webp')
        Require-Cube ((Cube-Hash $source) -eq $member.sha256) 'cube_install_asset_hash_invalid'
        $pairs.Add(@{source=$source;target=(Join-Path $install ('app\wwwroot\editor\assets\cubes\'+$member.definitionUid+'.webp'))})
    }
    Require-Cube (Test-Path -LiteralPath $maintenance -PathType Leaf) 'cube_install_maintenance_missing'
    foreach ($pair in $pairs) { Require-Cube (Test-Path -LiteralPath $pair.source -PathType Leaf) 'cube_install_source_missing' }
    $backup = Join-Path $install ('deployment-backups\account-cubes-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $backup 'files') -Force | Out-Null
    $members = @()
    for ($index=0; $index -lt $pairs.Count; $index++) {
        $pair=$pairs[$index]
        $before=Test-Path -LiteralPath $pair.target -PathType Leaf
        $beforeImage=Join-Path $backup ('files\'+$index)
        if ($before) { Copy-Item -LiteralPath $pair.target -Destination $beforeImage }
        $members += @{target=$pair.target;existed=$before;backup=$beforeImage;beforeSha256=$(if($before){Cube-Hash $beforeImage}else{$null});afterSha256=(Cube-Hash $pair.source)}
    }
    [IO.File]::WriteAllText((Join-Path $backup 'files.manifest.json'), ($members | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Cube-Status 'backing_up_database'
    $protected=[IO.File]::ReadAllBytes((Join-Path $install 'secrets\database-password.dpapi'))
    $entropy=[Text.Encoding]::UTF8.GetBytes('nll/control-center/dpapi/v1')
    $plain=[Security.Cryptography.ProtectedData]::Unprotect($protected,$entropy,[Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { $password=[Text.Encoding]::UTF8.GetString($plain) } finally { [Array]::Clear($plain,0,$plain.Length) }
    $env:PGPASSWORD=$password
    $env:NIKKE_LAB_DB="Host=127.0.0.1;Port=55433;Database=nll_control_center;Username=nll_control_center;Password=$password;SSL Mode=Disable;Include Error Detail=false"
    $code = Cube-Pg @('start','-D',(Join-Path $install 'postgresql\data'),'-l',(Join-Path $backup 'postgresql.log'),'-w','-t','30')
    Require-Cube ($code -eq 0) 'cube_install_database_start_failed'
    $pgStarted=$true
    $dump=Join-Path $backup 'before-cubes.pgbackup'
    & 'C:\NLL\Runtime\PostgreSQL-17-native\bin\pg_dump.exe' -h 127.0.0.1 -p 55433 -U nll_control_center -d nll_control_center -Fc -f $dump
    Require-Cube ($LASTEXITCODE -eq 0 -and (Get-Item -LiteralPath $dump).Length -gt 0) 'cube_install_database_backup_failed'
    Cube-Status 'applying_inventory'
    & 'C:\Program Files\dotnet\dotnet.exe' $maintenance --apply 1> (Join-Path $backup 'inventory-apply.json') 2> (Join-Path $backup 'inventory-apply.error')
    Require-Cube ($LASTEXITCODE -eq 0) 'cube_install_inventory_apply_failed'
    & 'C:\Program Files\dotnet\dotnet.exe' $maintenance --verify 1> (Join-Path $backup 'inventory-verify.json') 2> (Join-Path $backup 'inventory-verify.error')
    Require-Cube ($LASTEXITCODE -eq 0) 'cube_install_inventory_verify_failed'
    foreach ($pair in $pairs) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $pair.target) -Force | Out-Null
        Copy-Item -LiteralPath $pair.source -Destination $pair.target -Force
        Require-Cube ((Cube-Hash $pair.source) -eq (Cube-Hash $pair.target)) 'cube_install_copy_verify_failed'
    }
    Cube-Status 'installed'
} catch {
    $code = if ($_.Exception.Message -match '^cube_install_[a-z_]+$') { $_.Exception.Message } else { 'cube_install_failed' }
    Cube-Status 'failed' $code
    throw $code
} finally {
    if ($pgStarted) {
        $stopCode = Cube-Pg @('stop','-D',(Join-Path $install 'postgresql\data'),'-m','fast','-w','-t','30')
        if ($stopCode -ne 0) { Cube-Status 'failed' 'cube_install_database_stop_failed' }
    }
    $env:PGPASSWORD=$null
    $env:NIKKE_LAB_DB=$null
    $password=$null
}
