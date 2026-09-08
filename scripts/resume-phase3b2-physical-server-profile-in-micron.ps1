[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$preparationTool = 'C:\NLL\Tools\Prepare-Phase3B2-Physical-Server-Profile.ps1'
if (-not (Test-Path -LiteralPath $preparationTool -PathType Leaf)) {
    throw 'phase3b2_physical_materialization_resume_tool_missing'
}

& $preparationTool `
    -ResumeValidatedCleanBuild `
    -ResumeAssessmentUid '83a280d0-7568-4ced-9133-a500ae65b3d7'
