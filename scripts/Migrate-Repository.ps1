
param(
    [string]$SourceOwner = "swapna880",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "testing-app"
)

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$MirrorPath = Join-Path $ProjectPath "$Repo-mirror.git"

$SourceUrl = "https://github.com/$SourceOwner/$Repo.git"
$DestinationUrl = "https://github.com/$DestinationOwner/$Repo.git"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "       GitHub Repository Migration        " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

# STEP 1: Verify source account
Write-Host "`nSTEP 1: Verifying source account..." -ForegroundColor Yellow

gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch to source account."
}

gh auth setup-git
if ($LASTEXITCODE -ne 0) {
    throw "Git authentication setup failed for source account."
}

$SourceUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $SourceUser -ne $SourceOwner) {
    throw "Source account verification failed."
}

Write-Host "Source account verified: $SourceUser" -ForegroundColor Green

# STEP 2: Verify source repository access
Write-Host "`nSTEP 2: Checking source repository access..." -ForegroundColor Yellow

git ls-remote $SourceUrl | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Cannot access source repository."
}

Write-Host "Source repository access verified." -ForegroundColor Green

# STEP 3: Verify destination account
Write-Host "`nSTEP 3: Verifying destination account..." -ForegroundColor Yellow

gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch to destination account."
}

gh auth setup-git
if ($LASTEXITCODE -ne 0) {
    throw "Git authentication setup failed for destination account."
}

$DestinationUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $DestinationUser -ne $DestinationOwner) {
    throw "Destination account verification failed."
}

Write-Host "Destination account verified: $DestinationUser" -ForegroundColor Green

# STEP 4: Verify destination repository exists
Write-Host "`nSTEP 4: Checking destination repository..." -ForegroundColor Yellow

gh api "repos/$DestinationOwner/$Repo" --silent
if ($LASTEXITCODE -ne 0) {
    throw "Destination repository does not exist or is inaccessible."
}

Write-Host "Destination repository verified." -ForegroundColor Green

# STEP 5: Check destination is empty
Write-Host "`nSTEP 5: Checking destination branches and tags..." -ForegroundColor Yellow

$DestinationRefs = @(git ls-remote $DestinationUrl 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Cannot access destination repository through Git."
}

if ($DestinationRefs.Count -gt 0) {
    throw "Destination is not empty. Migration stopped to prevent overwriting refs."
}

Write-Host "Destination repository is empty." -ForegroundColor Green

# STEP 6: Check mirror directory
Write-Host "`nSTEP 6: Checking local mirror directory..." -ForegroundColor Yellow

if (Test-Path $MirrorPath) {
    throw "Mirror directory already exists: $MirrorPath. Inspect it before retrying."
}

# STEP 7: Clone source repository as a mirror
Write-Host "`nSTEP 7: Cloning source repository..." -ForegroundColor Yellow

gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch back to source account."
}

gh auth setup-git
if ($LASTEXITCODE -ne 0) {
    throw "Git authentication setup failed for source account."
}

git clone --mirror $SourceUrl $MirrorPath
if ($LASTEXITCODE -ne 0) {
    throw "Source mirror clone failed."
}

Write-Host "Source repository cloned successfully." -ForegroundColor Green

# STEP 8: Push mirror to destination
Write-Host "`nSTEP 8: Pushing repository to destination..." -ForegroundColor Yellow

gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch to destination account."
}

gh auth setup-git
if ($LASTEXITCODE -ne 0) {
    throw "Git authentication setup failed for destination account."
}

git -C $MirrorPath push --mirror $DestinationUrl
if ($LASTEXITCODE -ne 0) {
    throw "Mirror push failed. Review Git output before retrying."
}

Write-Host "`n==========================================" -ForegroundColor Green
Write-Host "     Repository Migration Completed!      " -ForegroundColor Green
Write-Host "Source: $SourceOwner/$Repo"
Write-Host "Destination: $DestinationOwner/$Repo"
Write-Host "==========================================" -ForegroundColor Green
