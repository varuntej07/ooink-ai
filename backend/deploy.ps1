# Deploy gate for the Pig agent: tests must pass before `lk agent deploy` runs.
#   .\deploy.ps1          offline tests (menu allergen data + allergen guard), then deploy
#   .\deploy.ps1 -Eval    also run the live allergen eval first (spends LLM credit)
param([switch]$Eval)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

python -m pytest -q
if ($LASTEXITCODE -ne 0) { Write-Host "Tests failed; not deploying."; exit 1 }

if ($Eval) {
    python -m evals.allergen_eval
    if ($LASTEXITCODE -ne 0) { Write-Host "Allergen eval failed; not deploying."; exit 1 }
}

lk agent deploy
exit $LASTEXITCODE
