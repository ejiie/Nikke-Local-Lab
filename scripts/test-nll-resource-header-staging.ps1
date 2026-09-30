[CmdletBinding()]
param()
# Synthetic files only; no network, game, server, registry or production data.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Nll.ResourceHeader.ps1')
$checks=0
$taskTemporaryBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
$taskTestRoot=Join-Path $taskTemporaryBase ('nll-resource-header-tests-' + [Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $taskTestRoot
function Assert-Test([bool]$Condition,[string]$Code) {
    if (-not $Condition) { throw ('resource_header_test_' + $Code) }
    $script:checks++
}
function Write-TestJson([string]$Path,[object]$Value) {
    [IO.File]::WriteAllText($Path,($Value | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
}
function Test-Digest([string]$Path) { Get-NllHeaderDigest ([IO.File]::ReadAllBytes($Path)) }
function New-TestFixture([string]$Build='999.9.7',[string]$Selector='98765',[string]$Platform='StandaloneWindows64') {
    $root=Join-Path $taskTestRoot ([Guid]::NewGuid().ToString('N'))
    $inputRoot=Join-Path $root 'inputs'
    $runtimeRoot=Join-Path $root 'runtime'
    $null=New-Item -ItemType Directory -Path $inputRoot,$runtimeRoot
    $config=[pscustomobject]@{TargetVersion=$Build;ResourceBaseURL='https://fixture.invalid/prdenv/synthetic-build/{Platform}';ResourceDataPackVersion=$Selector}
    $configPath=Join-Path $root 'config.json'
    Write-TestJson $configPath $config
    $configHash=Test-Digest $configPath
    $metadataPath=Join-Path $inputRoot 'version-metadata.txt'
    $text="synthetic`ncore:999.9.b1,1`ndp:synthetic,2`nfd:synthetic,3`nsaus:synthetic,4`nko:synthetic,5`nen:synthetic,6`nja:synthetic,7`n"
    [IO.File]::WriteAllText($metadataPath,$text,[Text.UTF8Encoding]::new($false))
    $headerHash=Test-Digest $metadataPath
    $request=[pscustomobject]@{contract='nll/cold-version-input-request/v1';build=$Build;configSha256=$configHash
        redirects=$false;proxy=$false;credentials=$false;members=@(
            [pscustomobject]@{role='static_pack';uri='https://fixture.invalid/prdenv/synthetic/StaticData.pack';file='StaticData.pack';maxBytes=268435456}
            [pscustomobject]@{role='version_metadata';uri=(Get-NllResourceHeaderUri $config $Platform).AbsoluteUri;file='version-metadata.txt';maxBytes=65536})}
    $requestPath=Join-Path $inputRoot 'request.private.json'
    Write-TestJson $requestPath $request
    $receipt=[pscustomobject]@{contract='nll/cold-version-input-acquisition/v1';build=$Build;configSha256=$configHash
        requestSha256=(Test-Digest $requestPath);failure=$null;tls='system_hostname_and_certificate_validation';installationChanged=$false;databaseChanged=$false
        members=@([pscustomobject]@{role='static_pack';status='acquired_hash_sealed';httpStatus=200;byteLength=10;sha256=('a'*64)}
            [pscustomobject]@{role='version_metadata';status='acquired_hash_sealed';httpStatus=200;byteLength=(Get-Item -LiteralPath $metadataPath).Length;sha256=$headerHash})}
    $receiptPath=Join-Path $inputRoot 'acquisition.receipt.json'
    Write-TestJson $receiptPath $receipt
    @{Config=$config;SourceConfigSha256=$configHash;InputDirectory=$inputRoot;ExpectedAcquisitionReceiptSha256=(Test-Digest $receiptPath)
        ExpectedMetadataSha256=$headerHash;Platform=$Platform;RuntimeRoot=$runtimeRoot;Request=$request;Receipt=$receipt}
}
function Get-TestPlan([hashtable]$Fixture) {
    Get-NllResourceHeaderPlan -Config $Fixture.Config -SourceConfigSha256 $Fixture.SourceConfigSha256 `
        -InputDirectory $Fixture.InputDirectory -ExpectedAcquisitionReceiptSha256 $Fixture.ExpectedAcquisitionReceiptSha256 `
        -ExpectedMetadataSha256 $Fixture.ExpectedMetadataSha256 -Platform $Fixture.Platform
}
function Repin-TestEvidence([hashtable]$Fixture) {
    $requestPath=Join-Path $Fixture.InputDirectory 'request.private.json'
    Write-TestJson $requestPath $Fixture.Request
    $Fixture.Receipt.requestSha256=Test-Digest $requestPath
    $receiptPath=Join-Path $Fixture.InputDirectory 'acquisition.receipt.json'
    Write-TestJson $receiptPath $Fixture.Receipt
    $Fixture.ExpectedAcquisitionReceiptSha256=Test-Digest $receiptPath
}
function Assert-Rejected([scriptblock]$Action,[string]$Code) {
    $caught=$false
    try { $null=& $Action } catch {
        Assert-Test ($_.Exception.Message -ceq ('resource_header_'+$Code)) ('wrong_failure_' + $Code)
        $caught=$true
    }
    Assert-Test $caught ('accepted_' + $Code)
}
function New-TestPin([object]$Plan) { [pscustomobject]@{path=$Plan.relativePath;length=$Plan.length;sha256=$Plan.sha256} }
try {
    foreach ($spec in @(@('999.9.7','98765','StandaloneWindows64'),@('888.2.3','12','SyntheticPlatform'))) {
        $fixture=New-TestFixture $spec[0] $spec[1] $spec[2]
        $plan=Get-TestPlan $fixture
        Assert-Test ($plan.relativePath -ceq ('cache/prdenv/synthetic-build/' + $spec[2] + '/pck/latest-' + $spec[1] + '.txt')) 'derived_path'
        Copy-NllResourceHeader $fixture.RuntimeRoot $plan
        $target=Join-Path $fixture.RuntimeRoot $plan.relativePath
        Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ceq
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($plan.sourcePath))) 'exact_bytes'
        Assert-NllResourceHeaderManifest $fixture.RuntimeRoot $plan @((New-TestPin $plan))
        Assert-Test $true 'manifest_valid'
        Assert-Rejected { Copy-NllResourceHeader $fixture.RuntimeRoot $plan } 'target_exists'
        Assert-Rejected { Assert-NllResourceHeaderManifest $fixture.RuntimeRoot $plan @() } 'manifest_member_missing_or_duplicate'
        Assert-Rejected { Assert-NllResourceHeaderManifest $fixture.RuntimeRoot $plan @((New-TestPin $plan),(New-TestPin $plan)) } 'manifest_member_missing_or_duplicate'
        $wrongPin=New-TestPin $plan; $wrongPin.sha256='b'*64
        Assert-Rejected { Assert-NllResourceHeaderManifest $fixture.RuntimeRoot $plan @($wrongPin) } 'manifest_member_drift'
        [IO.File]::WriteAllText($target,'synthetic drift')
        Assert-Rejected { Assert-NllResourceHeaderManifest $fixture.RuntimeRoot $plan @((New-TestPin $plan)) } 'content_drift'
    }
    # Serving port changes do not change origin provenance or cache path.
    $fixture=New-TestFixture
    $normal=Get-TestPlan $fixture
    $fixture.Config.ResourceBaseURL=$fixture.Config.ResourceBaseURL.Replace('fixture.invalid/','fixture.invalid:8443/')
    Assert-Test ((Get-TestPlan $fixture).relativePath -ceq $normal.relativePath) 'local_port_path'
    # Header delivery has no voice/quality dependency (including no audio).
    foreach ($language in @('ko','en','ja','none')) {
        foreach ($scope in @('Minimal','Full','None')) {
            $fixture.Config | Add-Member -NotePropertyName VoiceLanguage -NotePropertyValue $language -Force
            $fixture.Config | Add-Member -NotePropertyName VoiceScope -NotePropertyValue $scope -Force
            Assert-Test ((Get-TestPlan $fixture).relativePath -ceq $normal.relativePath) 'voice_independent_header'
        }
    }
    foreach ($base in @('http://fixture.invalid/prdenv/synthetic/{Platform}',
        'https://fixture.invalid:444/prdenv/synthetic/{Platform}',
        'https://user:secret@fixture.invalid/prdenv/synthetic/{Platform}',
        'https://fixture.invalid/prdenv/../synthetic/{Platform}',
        'https://fixture.invalid/prdenv/%2e%2e/synthetic/{Platform}',
        'https://fixture.invalid/prdenv//synthetic/{Platform}',
        'https://fixture.invalid/prdenv/synthetic/{Platform}?x=y',
        'https://fixture.invalid/prdenv/{Unknown}/{Platform}',
        'https://fixture.invalid/unknown/synthetic/{Platform}')) {
        $fixture=New-TestFixture; $fixture.Config.ResourceBaseURL=$base
        Assert-Rejected { Get-TestPlan $fixture } 'base_invalid'
    }
    $fixture=New-TestFixture; $fixture.Config.ResourceDataPackVersion='../secret'
    Assert-Rejected { Get-TestPlan $fixture } 'selector_invalid'
    $fixture=New-TestFixture; $fixture.Platform='../secret'
    Assert-Rejected { Get-TestPlan $fixture } 'platform_invalid'
    $fixture=New-TestFixture; $fixture.Config.TargetVersion='777.1.1'
    Assert-Rejected { Get-TestPlan $fixture } 'config_binding_invalid'
    $fixture=New-TestFixture; $fixture.Config.ResourceDataPackVersion='1'
    Assert-Rejected { Get-TestPlan $fixture } 'request_binding_invalid'
    $fixture=New-TestFixture; $fixture.SourceConfigSha256='c'*64
    Assert-Rejected { Get-TestPlan $fixture } 'config_binding_invalid'
    $fixture=New-TestFixture; $fixture.ExpectedAcquisitionReceiptSha256='c'*64
    Assert-Rejected { Get-TestPlan $fixture } 'receipt_drift'
    $fixture=New-TestFixture
    [IO.File]::AppendAllText((Join-Path $fixture.InputDirectory 'request.private.json'),' ')
    Assert-Rejected { Get-TestPlan $fixture } 'request_drift'
    foreach ($field in @('failure','tls','installationChanged','databaseChanged')) {
        $fixture=New-TestFixture
        $fixture.Receipt.$field=if($field -in 'installationChanged','databaseChanged'){$true}else{'synthetic_invalid'}
        Repin-TestEvidence $fixture
        Assert-Rejected { Get-TestPlan $fixture } 'acquisition_invalid'
    }
    foreach ($field in @('redirects','proxy','credentials')) {
        $fixture=New-TestFixture; $fixture.Request.$field=$true; Repin-TestEvidence $fixture
        Assert-Rejected { Get-TestPlan $fixture } 'acquisition_invalid'
    }
    $fixture=New-TestFixture; $fixture.Request.members += $fixture.Request.members[1]; Repin-TestEvidence $fixture
    Assert-Rejected { Get-TestPlan $fixture } 'members_invalid'
    $fixture=New-TestFixture; $fixture.Receipt.databaseChanged='False'; Repin-TestEvidence $fixture
    Assert-Rejected { Get-TestPlan $fixture } 'acquisition_invalid'
    $fixture=New-TestFixture; $fixture.Receipt.members[1].httpStatus=404; Repin-TestEvidence $fixture
    Assert-Rejected { Get-TestPlan $fixture } 'acquisition_member_invalid'
    $fixture=New-TestFixture; $fixture.Receipt.members[1].byteLength++; Repin-TestEvidence $fixture
    Assert-Rejected { Get-TestPlan $fixture } 'content_drift'
    $fixture=New-TestFixture; $fixture.Request.members[1].file='../outside.txt'; Repin-TestEvidence $fixture
    Assert-Rejected { Get-TestPlan $fixture } 'request_binding_invalid'
    $fixture=New-TestFixture; $plan=Get-TestPlan $fixture
    [IO.File]::WriteAllText($plan.sourcePath,'synthetic source drift')
    Assert-Rejected { Copy-NllResourceHeader $fixture.RuntimeRoot $plan } 'content_drift'
    Assert-Test (@(Get-ChildItem -LiteralPath $fixture.RuntimeRoot -Recurse -File).Count -eq 0) 'invalid_input_wrote_cache'
    foreach ($size in @(0,65537)) {
        $fixture=New-TestFixture; $plan=Get-TestPlan $fixture
        [IO.File]::WriteAllBytes($plan.sourcePath,[byte[]]::new($size))
        Assert-Rejected { Get-TestPlan $fixture } 'size_invalid'
    }
    $fixture=New-TestFixture; $plan=Get-TestPlan $fixture
    $fixture.Request.members[1].file='synthetic-missing.txt'; Repin-TestEvidence $fixture
    Assert-Rejected { Get-TestPlan $fixture } 'input_read_failed'
    $fixture=New-TestFixture; $plan=Get-TestPlan $fixture
    $plan.relativePath='cache/prdenv/../../outside/pck/latest-1.txt'
    Assert-Rejected { Copy-NllResourceHeader $fixture.RuntimeRoot $plan } 'target_invalid'
    $fixture=New-TestFixture; $plan=Get-TestPlan $fixture
    [IO.File]::WriteAllText((Join-Path $fixture.RuntimeRoot 'resource-probe-runtime.private.json'),'synthetic sealed marker')
    Assert-Rejected { Copy-NllResourceHeader $fixture.RuntimeRoot $plan } 'runtime_already_sealed'
    $fixture=New-TestFixture; $plan=Get-TestPlan $fixture
    $null=New-Item -ItemType Junction -Path (Join-Path $fixture.RuntimeRoot 'cache') -Target $fixture.InputDirectory
    Assert-Rejected { Copy-NllResourceHeader $fixture.RuntimeRoot $plan } 'path_reparse'
    $candidate=Join-Path (Split-Path -Parent $PSScriptRoot) '.external\EpinelPS-151-candidate\EpinelPS'
    $asset=Get-Content -LiteralPath (Join-Path $candidate 'Utils\AssetDownloadUtil.cs') -Raw
    $program=Get-Content -LiteralPath (Join-Path $candidate 'Program.cs') -Raw
    Assert-Test ($program.Contains('AppDomain.CurrentDomain.BaseDirectory + "cache/" + path')) 'normal_cache_contract'
    Assert-Test ($asset.Contains(".TrimStart('/');") -and $asset.Contains('Program.GetCachePathForPath(rawUrl)')) 'normal_path_contract'
    Assert-Test ($asset.Contains('context.Response.StatusCode = 404;') -and
        $asset.Contains('Results.Stream(new FileStream(targetFile, FileMode.Open, FileAccess.Read, FileShare.Read)')) 'normal_file_response_contract'
    [ordered]@{status='passed';checks=$checks;clientStarted=$false;serverStarted=$false;networkUsed=$false;productionDataChanged=$false} | ConvertTo-Json
} finally {
    $resolvedRoot=[IO.Path]::GetFullPath($taskTestRoot)
    if ($resolvedRoot.StartsWith($taskTemporaryBase,[StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedRoot) -cmatch '^nll-resource-header-tests-[a-f0-9]{32}$') {
        # Remove only junction entries first; never recursively follow a link.
        Get-ChildItem -LiteralPath $resolvedRoot -Recurse -Directory -Attributes ReparsePoint |
            ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    } else { throw 'resource_header_test_cleanup_boundary_invalid' }
}
