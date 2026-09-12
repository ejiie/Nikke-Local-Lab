param([string]$BaselineRoot = '')
# Golden semantic tokens come from the FINAL derived tools of the operator-
# accepted run, not raw v9. Parse only: no legacy script is ever executed here.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
function Assert-Test($Value,$Code) { if (-not $Value) { throw $Code } }
function Parse-TestScript($Path) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tokens,[ref]$errors)
    Assert-Test ($errors.Count -eq 0) 'runner_parse_failed'
    $ast
}
function Get-TestAssignment($Ast,$Name) {
    $nodes=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $Name},$true))
    Assert-Test ($nodes.Count -eq 1) 'runner_oracle_assignment_ambiguous'
    $nodes[0].Extent.Text
}
function Get-TestCompletionTail($Ast) {
    $start=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$redactedServerLogMatchCount'},$true))[0]
    $end=@($Ast.FindAll({param($n) $n -is [Management.Automation.Language.PipelineAst] -and $n.Extent.Text -match '^\$receipt \| ConvertTo-Json'},$true))[-1]
    $Ast.Extent.Text.Substring($start.Extent.StartOffset,$end.Extent.EndOffset-$start.Extent.StartOffset)
}
function Get-TestTokenHash($Text) {
    $tokens=$null; $errors=$null
    $null=[Management.Automation.Language.Parser]::ParseInput($Text,[ref]$tokens,[ref]$errors)
    Assert-Test ($errors.Count -eq 0) 'runner_oracle_parse_failed'
    $canonical=(@($tokens | Where-Object { $_.Kind -notin @('NewLine','EndOfInput','Comment','LineContinuation') } | ForEach-Object { $_.Kind.ToString()+':'+$_.Text }) -join "`n")
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
$start=Parse-TestScript (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerStart.ps1')
$complete=Parse-TestScript (Join-Path $PSScriptRoot 'Nll.PhaseDRunnerComplete.ps1')
$actual=[ordered]@{
    startReceipt=Get-TestTokenHash (Get-TestAssignment $start '$receipt')
    startPointer=Get-TestTokenHash (Get-TestAssignment $start '$pointer')
    startFailure=Get-TestTokenHash (Get-TestAssignment $start '$failure')
    completionTail=Get-TestTokenHash (Get-TestCompletionTail $complete)
}
$golden=@{
    startReceipt='f8205c23b1e37404a4350a87085bf508549d6a4b0348257d45a366f7712907ed'
    startPointer='6b67318848e2fa66833d73227f60cb2b764254d6c17b5c8803a97ec91bc43033'
    startFailure='8684fb5bc28a2e1debae6e513eccddfea846da1acc2deed96f0b7b6cdcddff25'
    completionTail='301ae176f9108f7c822d40fd3c48866b34662a3d3119ae5dbf24fc49ecd553aa'
}
if ($BaselineRoot) {
    $startPath=Join-Path $BaselineRoot 'Start-PhaseD-Derived.ps1'
    $completePath=Join-Path $BaselineRoot 'Complete-PhaseD-Derived.ps1'
    Assert-Test ((Get-FileHash -LiteralPath $startPath).Hash.ToLowerInvariant() -ceq '0d322821ef27fa2dc9069b004ea4f48cbc3835da072a8d3931ca5ef2d9e2ff74') 'runner_start_baseline_pin_mismatch'
    Assert-Test ((Get-FileHash -LiteralPath $completePath).Hash.ToLowerInvariant() -ceq '588cd7d0f531eba76761c21c5bd5986f8cf001ee60b9dbe3904da1cf4dff046c') 'runner_complete_baseline_pin_mismatch'
    $oldStart=Parse-TestScript $startPath; $oldComplete=Parse-TestScript $completePath
    $reference=@{
        startReceipt=Get-TestTokenHash (Get-TestAssignment $oldStart '$receipt')
        startPointer=Get-TestTokenHash (Get-TestAssignment $oldStart '$pointer')
        startFailure=Get-TestTokenHash (Get-TestAssignment $oldStart '$failure')
        completionTail=Get-TestTokenHash (Get-TestCompletionTail $oldComplete)
    }
    foreach ($key in $actual.Keys) { Assert-Test ($actual[$key] -ceq $reference[$key]) ('runner_differential_failed_'+$key) }
}
foreach ($key in $golden.Keys) { Assert-Test ($actual[$key] -ceq $golden[$key]) ('runner_golden_changed_'+$key) }
$actual | ConvertTo-Json
