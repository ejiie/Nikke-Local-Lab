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

Assert-Contains $Workflow '(?m)^\s*push:\s*$' "Workflow must run from a push event."
Assert-Contains $Workflow '(?m)^\s*-\s+"agent/\*\*"\s*$' "Workflow must be limited to agent/** branches."
Assert-Contains $Workflow 'github\.actor\s*==\s*github\.repository_owner' "Workflow must be restricted to the repository owner."
Assert-Contains $Workflow '(?m)^permissions:\s*\r?\n\s+contents:\s*read\s*$' "Workflow default token must be read-only."
Assert-Contains $Workflow '(?m)^\s*group:\s*agent-publish-main\s*$' "Agent workflows must serialize against the main integration target."
Assert-Contains $Workflow 'needs:\s*\[validate,\s*postgres\]' "Publish job must depend on Windows and PostgreSQL validation."
Assert-Contains $Workflow 'verify-repository\.ps1\s+-Mode\s+tracked\s+-AllowRemote' "Workflow must enforce the repository boundary with explicit remote allowance."
Assert-Contains $Workflow 'verify-phase0-contract\.ps1' "Workflow must run Phase 0 contract checks."
Assert-Contains $Workflow 'verify-phase1a\.ps1' "Workflow must run Phase 1A build and test checks."
Assert-Contains $Workflow 'verify-phase1a\.ps1\s+-Integration' "Workflow must run live PostgreSQL integration checks."
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
Assert-Contains $Workflow 'git\s+merge\s+--no-commit\s+--no-ff\s+\$BaseRef' "Validation must test the feature/main merge result."

Assert-NotContains $Workflow '(?m)^\s*pull_request_target:\s*$' "Privileged pull_request_target execution is forbidden."
Assert-NotContains $Workflow 'secrets\.' "Automation must not depend on a PAT or repository secret."
Assert-NotContains $Workflow '--admin' "Automation must not bypass branch protection."
Assert-NotContains $Workflow 'curl\s+.*github\.com' "Automation must use the scoped GitHub CLI token, not custom credential transport."

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
Assert-Contains $Hook 'verify-phase1a\.ps1' "Pre-commit hook must verify Phase 1A locally."
Assert-Contains $Hook 'verify-actions-contract\.ps1' "Pre-commit hook must verify Actions automation."

Write-Output "GitHub Actions owner-only validate/PR/merge contract passed."
