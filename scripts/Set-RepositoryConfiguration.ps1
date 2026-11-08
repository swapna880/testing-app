
param(
    [string]$SourceOwner = "swapna880",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "testing-app"
)

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$SettingsFile = Join-Path $ProjectPath "config\repository-settings.json"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " Repository Configuration Migration" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# STEP 1: Authenticate to source account
Write-Host "`nChecking source account..." -ForegroundColor Yellow

gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch to source account."
}

$SourceUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $SourceUser -ne $SourceOwner) {
    throw "Source account verification failed."
}

# STEP 2: Export source repository settings
Write-Host "Reading source repository settings..." -ForegroundColor Yellow

$SourceJson = gh api "repos/$SourceOwner/$Repo"
if ($LASTEXITCODE -ne 0) {
    throw "Could not read source repository settings."
}

$SourceSettings = $SourceJson | ConvertFrom-Json

# Select settings supported by the repository update API
$Settings = [ordered]@{
    description = $SourceSettings.description
    homepage = $SourceSettings.homepage
    has_issues = $SourceSettings.has_issues
    has_projects = $SourceSettings.has_projects
    has_wiki = $SourceSettings.has_wiki
    allow_squash_merge = $SourceSettings.allow_squash_merge
    allow_merge_commit = $SourceSettings.allow_merge_commit
    allow_rebase_merge = $SourceSettings.allow_rebase_merge
    allow_auto_merge = $SourceSettings.allow_auto_merge
    delete_branch_on_merge = $SourceSettings.delete_branch_on_merge
}

New-Item -ItemType Directory -Path (Split-Path $SettingsFile) -Force | Out-Null

$Settings | ConvertTo-Json -Depth 5 |
    Set-Content -Path $SettingsFile -Encoding utf8

Write-Host "Source settings exported successfully." -ForegroundColor Green

# STEP 3: Switch to destination account
Write-Host "`nChecking destination account..." -ForegroundColor Yellow

gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch to destination account."
}

$DestinationUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $DestinationUser -ne $DestinationOwner) {
    throw "Destination account verification failed."
}

# STEP 4: Verify destination repository
gh api "repos/$DestinationOwner/$Repo" --silent
if ($LASTEXITCODE -ne 0) {
    throw "Destination repository does not exist or is inaccessible."
}

# STEP 5: Apply settings to destination
Write-Host "`nApplying repository settings..." -ForegroundColor Yellow

gh api -X PATCH "repos/$DestinationOwner/$Repo" --input $SettingsFile
if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply repository settings."
}

Write-Host "`nRepository settings applied successfully." -ForegroundColor Green

# STEP 6: Verify selected settings
$Result = gh api "repos/$DestinationOwner/$Repo" `
    --jq '{description: .description, has_issues: .has_issues, has_projects: .has_projects, has_wiki: .has_wiki, allow_squash_merge: .allow_squash_merge, allow_merge_commit: .allow_merge_commit, allow_rebase_merge: .allow_rebase_merge, allow_auto_merge: .allow_auto_merge, delete_branch_on_merge: .delete_branch_on_merge}'

if ($LASTEXITCODE -ne 0) {
    throw "Destination settings verification failed."
}

Write-Host $Result
Write-Host "`nConfiguration migration completed." -ForegroundColor Green
