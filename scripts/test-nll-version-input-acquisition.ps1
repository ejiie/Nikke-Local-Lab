[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$collector = Join-Path $PSScriptRoot 'invoke-nll-version-input-acquisition.ps1'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('nll-version-input-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
$path = Join-Path $temporary 'synthetic-config.json'
function Fixture {
    # Synthetic paths only. Tests never invoke ExecuteApprovedAcquisition.
    [ordered]@{
        TargetVersion = '999.1.2'
        StaticDataMpk = @{ Url = 'https://cloud.nikke-kr.com/prdenv/synthetic/static/mpk/StaticData.pack' }
        ResourceBaseURL = 'https://cloud.nikke-kr.com/prdenv/synthetic/{Platform}'
        ResourceDataPackVersion = '123'
    }
}
function Save-Config([object]$Config) {
    [IO.File]::WriteAllText($path, ($Config | ConvertTo-Json -Depth 4))
    (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()
}
function Fail([scriptblock]$Action, [string]$Code) {
    try { $null = & $Action } catch {
        if ($_.Exception.Message -ceq $Code) { return }
        throw
    }
    throw ('expected_failure_missing:' + $Code)
}
try {
    $hash = Save-Config (Fixture)
    $result = & $collector -ConfigPath $path -ExpectedConfigSha256 $hash -ApprovedClientBuild '999.1.2' | ConvertFrom-Json
    if ($result.status -cne 'plan_validated_no_network' -or $result.memberCount -ne 2 -or $result.totalByteLimit -ne 268500992) {
        throw 'synthetic_plan_shape_invalid'
    }
    Fail { & $collector -ConfigPath $path -ExpectedConfigSha256 ('0' * 64) -ApprovedClientBuild '999.1.2' } 'version_input_config_hash_drift'
    Fail { & $collector -ConfigPath $path -ExpectedConfigSha256 $hash -ApprovedClientBuild '999.1.3' } 'version_input_build_mismatch'
    foreach ($url in @(
        'http://cloud.nikke-kr.com/prdenv/synthetic/mpk/StaticData.pack',
        'https://example.invalid/prdenv/synthetic/mpk/StaticData.pack',
        'https://user@cloud.nikke-kr.com/prdenv/synthetic/mpk/StaticData.pack',
        'https://cloud.nikke-kr.com:8443/prdenv/synthetic/mpk/StaticData.pack',
        'https://cloud.nikke-kr.com/prdenv/synthetic/mpk/StaticData.pack?token=synthetic',
        'https://cloud.nikke-kr.com/prdenv/synthetic/mpk/StaticData.pack#fragment',
        'https://cloud.nikke-kr.com/prdenv/synthetic/../mpk/StaticData.pack',
        'https://cloud.nikke-kr.com/prdenv/synthetic%2fmpk/StaticData.pack'
    )) {
        $config = Fixture
        $config.StaticDataMpk.Url = $url
        $hash = Save-Config $config
        Fail { & $collector -ConfigPath $path -ExpectedConfigSha256 $hash -ApprovedClientBuild '999.1.2' } 'version_input_uri_boundary'
    }
    $config = Fixture
    $config.ResourceBaseURL = 'https://cloud.nikke-kr.com/prdenv/synthetic/not-a-platform'
    $hash = Save-Config $config
    Fail { & $collector -ConfigPath $path -ExpectedConfigSha256 $hash -ApprovedClientBuild '999.1.2' } 'version_input_resource_base_invalid'
    $config = Fixture
    $config.ResourceDataPackVersion = '../123'
    $hash = Save-Config $config
    Fail { & $collector -ConfigPath $path -ExpectedConfigSha256 $hash -ApprovedClientBuild '999.1.2' } 'version_input_data_version_invalid'
    'version_input_plan_tests_passed=13; network_used=false; actual_install_changed=false'
}
finally {
    # Only this test's one exact generated file and unique directory.
    if (Test-Path -LiteralPath $path) { [IO.File]::Delete($path) }
    [IO.Directory]::Delete($temporary)
}
