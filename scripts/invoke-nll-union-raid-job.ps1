param([Parameter(Mandatory)][string]$ConfigurationPath,
      [Parameter(Mandatory)][string]$ExpectedConfigurationSha256,
      [Parameter(Mandatory)][string]$JobRoot)
$ErrorActionPreference = 'Stop'
if ((Get-FileHash -LiteralPath $ConfigurationPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedConfigurationSha256) {
  throw 'boss_union_configuration_changed'
}
$config = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
& $config.pythonPath (Join-Path $config.repositoryRoot 'scripts/assemble-nll-union-raid.py') `
  --configuration $ConfigurationPath --configuration-sha256 $ExpectedConfigurationSha256 --output $JobRoot
if ($LASTEXITCODE -ne 0) {
  $code = Get-Content -LiteralPath (Join-Path $JobRoot 'failure-code.txt') -Raw
  if ($code -cnotmatch '^boss_union_[a-z_]+$') { $code = 'boss_union_assembly_failed' }
  throw $code
}
