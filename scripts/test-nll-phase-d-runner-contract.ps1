$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerContract.ps1')
function Assert-Test([bool]$Value) { if (-not $Value) { throw 'runner_contract_test_failed' } }
$root = Join-Path ([IO.Path]::GetTempPath()) ('nll-runner-contract-' + [guid]::NewGuid().ToString('N'))
$id = '11111111-1111-4111-8111-111111111111'
$spec = [ordered]@{
    schemaVersion = 1; contractId = 'nll/phase-d-runner-input/v1'; engineCode = 'parameterized/v1'
    launchContextUid = $id; launchRoot = (Join-Path $root $id); preparationBindingSha256 = ('a' * 64)
    accountUid = '22222222-2222-4222-8222-222222222222'; accountRevisionSetSha256 = ('b' * 64)
    seasonNumber = 26; raidSnapshotUid = '33333333-3333-4333-8333-333333333333'
    raidSnapshotSha256 = ('c' * 64); expectedSoloRaidHeadRevisionUid = 'none'
    clientBuildCode = 'build_151.8.5'; clientExecutableSha256 = ('d' * 64)
    runtimeDbSha256 = ('e' * 64); serverExeSha256 = ('f' * 64); serverDllSha256 = ('1' * 64)
    bootstrapRoot = (Join-Path $root 'bootstrap'); bootstrapSha256 = ('2' * 64)
    bossRuntimeVariantProfile = (Join-Path $root "operator's profile.json")
    bossRuntimeVariantProfileSha256 = ('3' * 64)
    staticDataVariantRequired = $false; variantStaticDataPack = $null; variantStaticDataSha256 = $null
    resourcePreflightRequired = $false; resourcePreflightHelper = $null; resourcePreflightHelperSha256 = $null
    resourcePreflightTool = $null; resourcePreflightToolSha256 = $null
    resourceCatalogReceiptPath = $null; resourceCatalogReceiptSha256 = $null
    runtimeMaterializer = (Join-Path $root 'materializer.exe')
    soloRaidPendingPath = (Join-Path $root 'pending/payload.pending.json')
    soloRaidCaptureReceiptPath = (Join-Path $root 'pending/capture.receipt.json')
    secretEnvironmentVariable = 'SYNTHETIC_SECRET_REFERENCE'
    derivedSourceManifestSha256 = ('4' * 64); runIntentCode = 'challenge'
}
$count = 0
foreach ($build in @('build_150.6.9', 'build_151.8.5')) {
    foreach ($variant in @($false, $true)) {
        $candidate = [ordered]@{}; foreach ($key in $spec.Keys) { $candidate[$key] = $spec[$key] }
        $candidate.clientBuildCode = $build
        $candidate.resourcePreflightRequired = $build -ceq 'build_150.6.9'
        if ($candidate.resourcePreflightRequired) {
            foreach ($field in @('resourcePreflightHelper', 'resourcePreflightTool', 'resourceCatalogReceiptPath')) { $candidate[$field] = Join-Path $root $field }
            foreach ($field in @('resourcePreflightHelperSha256', 'resourcePreflightToolSha256', 'resourceCatalogReceiptSha256')) { $candidate[$field] = '5' * 64 }
        }
        $candidate.staticDataVariantRequired = $variant
        if ($variant) { $candidate.variantStaticDataPack = Join-Path $root 'pack'; $candidate.variantStaticDataSha256 = '6' * 64 }
        Assert-PhaseDRunnerSpecification $candidate
        # Round-tripping the data must never turn strings into executable code.
        Assert-PhaseDRunnerSpecification ($candidate | ConvertTo-Json -Depth 5 | ConvertFrom-Json)
        $launchInput = [ordered]@{}
        foreach ($field in @('launchRoot','accountUid','accountRevisionSetSha256','raidSnapshotUid','raidSnapshotSha256',
            'expectedSoloRaidHeadRevisionUid','clientBuildCode','clientExecutableSha256','runtimeDbSha256',
            'bossRuntimeVariantProfile','staticDataVariantRequired','variantStaticDataPack','variantStaticDataSha256',
            'resourcePreflightHelper','resourcePreflightHelperSha256','resourcePreflightTool','resourcePreflightToolSha256',
            'resourceCatalogReceiptPath','resourceCatalogReceiptSha256','runtimeMaterializer','soloRaidPendingPath',
            'soloRaidCaptureReceiptPath','secretEnvironmentVariable')) { $launchInput[$field]=$candidate[$field] }
        $launchInput.LaunchContextUid=$candidate.launchContextUid; $launchInput.SeasonNumber=$candidate.seasonNumber
        $launchInput.expectedWeaknessVariantServerDllSha256=$candidate.serverDllSha256
        $launchInput.runtimeBundle=if ($build -eq 'build_151.8.5') {
            @{bootstrapRoot=$candidate.bootstrapRoot; bootstrap=@{sha256=$candidate.bootstrapSha256};serverExe=@{sha256=$candidate.serverExeSha256}}
        } else { $null }
        $mapped=New-PhaseDRunnerSpecification $launchInput $candidate.preparationBindingSha256 $candidate.bossRuntimeVariantProfileSha256 $candidate.derivedSourceManifestSha256 $candidate.runIntentCode
        foreach ($field in $candidate.Keys) {
            if ($build -eq 'build_150.6.9' -and $field -in @('bootstrapRoot','bootstrapSha256','serverExeSha256')) { continue }
            Assert-Test ($mapped[$field] -ceq $candidate[$field])
        }
        if ($build -eq 'build_150.6.9') {
            Assert-Test ($mapped.bootstrapRoot -ceq 'C:\NLL\Runtime\PhysicalBootstrap-v2' -and
                $mapped.bootstrapSha256 -ceq 'ff7371b3e20119030c0f3a8e2f6ba9482094c4118f06dbcc4e0e7f137f8e404f' -and
                $mapped.serverExeSha256 -ceq 'a28c7ff227a74d260a29389b82caeed3fe196f91eef3d28cabe9977b5ed9d07b')
        }
        $count++
    }
}
foreach ($change in @(
    @{field='contractId'; value='unknown'}, @{field='engineCode'; value='fallback'},
    @{field='schemaVersion'; value=2}, @{field='schemaVersion'; value='1'},
    @{field='launchContextUid'; value='not-a-guid'}, @{field='seasonNumber'; value=0},
    @{field='seasonNumber'; value='26'}, @{field='staticDataVariantRequired'; value='false'},
    @{field='staticDataVariantRequired'; value=$true}, @{field='variantStaticDataSha256'; value=('6' * 64)},
    @{field='resourcePreflightRequired'; value=$true}, @{field='resourceCatalogReceiptPath'; value=(Join-Path $root 'forbidden')},
    @{field='secretEnvironmentVariable'; value='secret value'}, @{field='clientBuildCode'; value='build_unknown'},
    @{field='launchRoot'; value='relative'}, @{field='launchRoot'; value=$root},
    @{field='parentStartText'; value='Write-Output injected'}, @{field='serverDllSha256'; value='bad'},
    @{field='expectedSoloRaidHeadRevisionUid'; value=''}, @{field='runIntentCode'; value='museum'}
)) {
    $bad = [ordered]@{}; foreach ($key in $spec.Keys) { $bad[$key] = $spec[$key] }
    $bad[$change.field] = $change.value
    $rejected = $false
    try { Assert-PhaseDRunnerSpecification $bad } catch { $rejected = $_.Exception.Message -ceq 'phase_d_runner_input_invalid' }
    Assert-Test $rejected; $count++
}
foreach ($key in @($spec.Keys)) {
    $bad = [ordered]@{}; foreach ($name in $spec.Keys) { if ($name -cne $key) { $bad[$name] = $spec[$name] } }
    $rejected = $false
    try { Assert-PhaseDRunnerSpecification $bad } catch { $rejected = $_.Exception.Message -ceq 'phase_d_runner_input_invalid' }
    Assert-Test $rejected; $count++
}
Assert-Test (-not (Test-Path -LiteralPath $root))
Write-Output "Runner input: $count data-only, version/variant, round-trip, missing/extra field and invalid-input checks passed; no I/O."
