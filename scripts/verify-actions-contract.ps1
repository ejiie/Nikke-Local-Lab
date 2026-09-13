$ErrorActionPreference = "Stop"

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )
    if ($Text -notmatch $Pattern) {
        throw $Message
    }
}

function Assert-NotContains {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )
    if ($Text -match $Pattern) {
        throw $Message
    }
}

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $ScriptDirectory ".."))
$WorkflowPath = Join-Path $RepositoryRoot ".github/workflows/agent-branch-automerge.yml"

if (-not (Test-Path -LiteralPath $WorkflowPath -PathType Leaf)) {
    throw "Agent branch automation workflow is missing."
}

$Workflow = Get-Content -Raw -LiteralPath $WorkflowPath
$HookPath = Join-Path $RepositoryRoot ".githooks/pre-commit"
$Hook = Get-Content -Raw -LiteralPath $HookPath
$Phase3B1Path = Join-Path $RepositoryRoot "scripts/verify-phase3b1.ps1"
if (-not (Test-Path -LiteralPath $Phase3B1Path -PathType Leaf)) {
    throw "Phase 3B-1 verification script is missing."
}
$Phase3B1 = Get-Content -Raw -LiteralPath $Phase3B1Path
$Phase3B2Path = Join-Path $RepositoryRoot "scripts/verify-phase3b2.ps1"
if (-not (Test-Path -LiteralPath $Phase3B2Path -PathType Leaf)) {
    throw "Phase 3B-2 verification script is missing."
}
$Phase3B2 = Get-Content -Raw -LiteralPath $Phase3B2Path

Assert-Contains $Workflow '(?m)^\s*push:\s*$' "Workflow must run from a push event."
Assert-Contains $Workflow '(?m)^\s*-\s+"agent/\*\*"\s*$' "Workflow must be limited to agent/** branches."
Assert-Contains $Workflow 'github\.actor\s*==\s*github\.repository_owner' "Workflow must be restricted to the repository owner."
Assert-Contains $Workflow '(?m)^permissions:\s*\r?\n\s+contents:\s*read\s*$' "Workflow default token must be read-only."
Assert-Contains $Workflow '(?m)^\s*group:\s*agent-publish-main\s*$' "Agent workflows must serialize against the main integration target."
Assert-Contains $Workflow 'needs:\s*\[validate,\s*postgres\]' "Publish job must depend on Windows and PostgreSQL validation."
Assert-Contains $Workflow 'verify-repository\.ps1\s+-Mode\s+tracked\s+-AllowRemote' "Workflow must enforce the repository boundary with explicit remote allowance."
Assert-Contains $Workflow 'verify-phase0-contract\.ps1' "Workflow must run Phase 0 contract checks."
Assert-Contains $Workflow 'verify-phase3b1\.ps1' "Workflow must run the Phase 3B-1 selected-manager contract and completed baseline checks."
Assert-Contains $Workflow 'verify-phase3b2\.ps1\s+-ContractOnly' "Workflow must validate the Phase 3B-2 source-free contracts without claiming a live proof."
Assert-Contains $Workflow 'verify-automation-boss-weakness-variant\.ps1' "Workflow must validate the source-free boss weakness variant automation contract."
Assert-Contains $Workflow 'verify-phase2b\.ps1\s+-Integration' "Workflow must run live PostgreSQL integration checks."
Assert-Contains $Workflow 'name:\s*Verify Phase 2B with PostgreSQL' "PostgreSQL validation job must name the Phase 2B gate."
Assert-Contains $Workflow 'verify-actions-contract\.ps1' "Workflow must validate its own automation contract."
Assert-Contains $Workflow 'gh\s+pr\s+create' "Workflow must create or reuse a pull request."
Assert-Contains $Workflow 'gh\s+pr\s+merge' "Workflow must merge through the pull request."
Assert-Contains $Workflow '--match-head-commit\s+"\$EXPECTED_SHA"' "Merge must be bound to the commit that passed validation."
Assert-Contains $Workflow 'EXPECTED_BASE_SHA:\s*\$\{\{\s*needs\.validate\.outputs\.base_sha\s*\}\}' "Publish job must receive the base SHA used for validation."
Assert-Contains $Workflow 'EXPECTED_POSTGRES_BASE_SHA:\s*\$\{\{\s*needs\.postgres\.outputs\.base_sha\s*\}\}' "Publish job must receive the base SHA used for PostgreSQL validation."
Assert-Contains $Workflow 'EXPECTED_BASE_SHA.*EXPECTED_POSTGRES_BASE_SHA' "Publish job must reject validation jobs that used different bases."
Assert-Contains $Workflow 'current_base_sha.*EXPECTED_BASE_SHA' "Publish job must fail when main moves after validation."
Assert-Contains $Workflow '--squash\s+--delete-branch' "Workflow must squash merge and remove the remote feature branch."
Assert-Contains $Workflow 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1e' "Checkout action must remain pinned to the reviewed commit."
Assert-Contains $Workflow 'actions/setup-dotnet@26b0ec14cb23fa6904739307f278c14f94c95bf1' "The .NET setup action must remain pinned to the reviewed commit."
if ([regex]::Matches($Workflow, '(?m)^\s*dotnet-version:\s*8\.0\.407\s*$').Count -ne 2) {
    throw "Both validation jobs must install the exact reviewed .NET SDK."
}
Assert-Contains $Workflow 'postgres:17\.6-bookworm@sha256:f3bd19c606e442c3d7bdfa8002e03fe260a1023351e0ea4598032022b68dd6e3' "The PostgreSQL service image must remain pinned by digest."
Assert-Contains $Workflow '(?m)^\s*persist-credentials:\s*false\s*$' "Validation checkout must not persist even a read token."
$mergePattern = 'git\s+-c\s+user\.name=github-actions\[bot\]\s+-c\s+user\.email=41898282\+github-actions\[bot\]@users\.noreply\.github\.com\s+merge\s+--no-commit\s+--no-ff\s+\$BaseRef'
if ([regex]::Matches($Workflow, $mergePattern).Count -ne 2) {
    throw 'Both validation jobs must test the merge result with command-local Git identity.'
}
foreach ($testScript in @('test-nll-boss-profile-qte.py', 'test-nll-boss-onboarding-candidate.py', 'test-nll-shield-fx-candidate.py', 'test-nll-execution-fx.py', 'test-nll-native-fx.py', 'test-nll-native-fx-layout.py', 'test-nll-native-fx-store.py', 'test-nll-actions-merge.py', 'test-nll-boss-catalog-images.py')) {
    if ([regex]::Matches($Workflow, [regex]::Escape("python -B scripts/$testScript")).Count -ne 2) {
        throw 'Both validation jobs must run the source-only Python behavior checks.'
    }
}
if ([regex]::Matches($Workflow, [regex]::Escape('pwsh -NoProfile -File scripts/test-nll-boss-publication.ps1')).Count -ne 2) {
    throw 'Both validation jobs must run atomic boss publication failure/retry checks.'
}
if ([regex]::Matches($Workflow, [regex]::Escape('pwsh -NoProfile -File scripts/test-nll-boss-native-composition.ps1')).Count -ne 2) {
    throw 'Both validation jobs must run the offline native composition failure checks.'
}
if ([regex]::Matches($Workflow, [regex]::Escape('pwsh -NoProfile -File scripts/test-nll-control-center-app-package.ps1')).Count -ne 2) {
    throw 'Both validation jobs must run full app/UI package rollback and added-file retirement checks.'
}
if ([regex]::Matches($Workflow, [regex]::Escape('pwsh -NoProfile -File scripts/test-nll-control-center-maintenance.ps1')).Count -ne 2) {
    throw 'Both validation jobs must run startup/deployment lease and activation checks.'
}
if ([regex]::Matches($Workflow, [regex]::Escape('pwsh -NoProfile -File scripts/test-nll-control-center-delivery.ps1')).Count -ne 2) {
    throw 'Both validation jobs must run app/startup/activation transaction and interrupted recovery checks.'
}

Assert-NotContains $Workflow '(?m)^\s*pull_request_target:\s*$' "Privileged pull_request_target execution is forbidden."
Assert-NotContains $Workflow 'secrets\.' "Automation must not depend on a PAT or repository secret."
Assert-NotContains $Workflow '--admin' "Automation must not bypass branch protection."
Assert-NotContains $Workflow 'curl\s+.*github\.com' "Automation must use the scoped GitHub CLI token, not custom credential transport."
Assert-NotContains $Workflow 'character-catalog-(inspect|import)' "Actions must never read an actual local character source."
Assert-NotContains $Workflow 'raid-catalog-(inspect|import)' "Actions must never read an actual local raid source."
Assert-NotContains $Workflow 'combat-support-catalog-(inspect|import)' "Actions must never read an actual local combat-support source."
Assert-NotContains $Workflow 'NIKKE_LAB_ID_SECRET' "Actions must not receive a local identity secret."
Assert-NotContains $Workflow 'LocalAssessmentPath|NIKKE_LAB_.*EVIDENCE|ready_for_phase3b' "Actions must not receive or assert local original-client evidence."
Assert-NotContains $Workflow 'upload-artifact' "Actions must not upload import outputs or source-derived artifacts."

$ValidateBlock = [regex]::Match($Workflow, '(?ms)^  validate:\s*$.*?(?=^  postgres:\s*$)').Value
$PostgresBlock = [regex]::Match($Workflow, '(?ms)^  postgres:\s*$.*?(?=^  publish:\s*$)').Value
$PublishBlock = [regex]::Match($Workflow, '(?ms)^  publish:\s*$.*$').Value
Assert-Contains $ValidateBlock '(?m)^\s+contents:\s*read\s*$' "Validation job must receive only contents: read."
Assert-NotContains $ValidateBlock '(?m)^\s+\S+:\s*write\s*$' "Validation job must not receive a write token."
Assert-Contains $PostgresBlock '(?m)^\s+contents:\s*read\s*$' "PostgreSQL validation must receive only contents: read."
Assert-NotContains $PostgresBlock '(?m)^\s+\S+:\s*write\s*$' "PostgreSQL validation must not receive a write token."
Assert-Contains $PostgresBlock 'NIKKE_LAB_TEST_RESET_TOKEN:\s*allow-phase1a-disposable-schema-reset' "PostgreSQL schema reset must require the reviewed disposable-test token."
Assert-Contains $PublishBlock '(?m)^\s+contents:\s*write\s*$' "Publish job needs contents: write."
Assert-Contains $PublishBlock '(?m)^\s+pull-requests:\s*write\s*$' "Publish job needs pull-requests: write."
Assert-Contains $PublishBlock "github\.event_name\s*==\s*'push'.*github\.actor\s*==\s*github\.repository_owner.*startsWith\(github\.ref,\s*'refs/heads/agent/'\)" "Publish must remain limited to owner pushes on agent branches."
Assert-NotContains $PublishBlock 'actions/checkout' "Write-enabled publish job must not check out feature-branch code."

Assert-Contains $Hook '(?m)^set -eu\s*$' "Pre-commit hook must stop on the first failed check."
Assert-Contains $Hook 'verify-repository\.ps1.*-AllowRemote' "Pre-commit hook must verify the repository boundary."
Assert-Contains $Hook 'verify-phase0-contract\.ps1' "Pre-commit hook must verify Phase 0 contracts."
Assert-Contains $Hook 'verify-phase3b1\.ps1' "Pre-commit hook must verify Phase 3B-1 and the completed baseline locally."
Assert-Contains $Hook 'verify-phase3b2\.ps1\s+-ContractOnly' "Pre-commit hook must verify the Phase 3B-2 source-free contracts without claiming a live run."
Assert-Contains $Hook 'verify-automation-boss-weakness-variant\.ps1' "Pre-commit hook must verify the boss weakness variant automation contract."
Assert-Contains $Hook 'verify-actions-contract\.ps1' "Pre-commit hook must verify Actions automation."
Assert-Contains $Phase3B1 'verify-phase3b0\.ps1' "Phase 3B-1 must preserve the Phase 3B-0, historical Phase 3A, and completed baseline chain."
Assert-Contains $Phase3B1 'test-nll-execution-fx-retirement\.ps1' "Windows full baseline must verify real Job / synthetic FX retirement after building Automation."
$phase2A2 = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'scripts/verify-phase2a2.ps1') -Raw
Assert-Contains $phase2A2 'test-nll-phase-d-job\.ps1' "Windows baseline must exercise atomic Job creation, handoff and same-job zero proof."
Assert-Contains $Phase3B2 'verify-phase3b1\.ps1' "Phase 3B-2 must preserve the Phase 3B-1 and completed baseline chain."
Assert-Contains $Phase3B2 'not_executed_contract_scaffold_only' "Phase 3B-2 Wave 0 must explicitly preserve the not-executed scaffold verdict."

Write-Output "GitHub Actions owner-only validate/PR/merge contract passed."
