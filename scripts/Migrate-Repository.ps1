
param(
    [string]$SourceOwner = "swapna880",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "testing-app"
)

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$MirrorPath = Join-Path $ProjectPath "$Repo-mirror.git"

Write-Host "=========================================="
Write-Host "GitHub Repository Migration"
Write-Host "=========================================="

# Step 1: Verify source account
Write-Host "Verifying source account..."

gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch to source account."
}

$SourceUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $SourceUser -ne $SourceOwner) {
    throw "Source account verification failed."
}

# Step 2: Verify destination account
Write-Host "Verifying destination account..."

gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) {
    throw "Could not switch to destination account."
}

$DestinationUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $DestinationUser -ne $DestinationOwner) {
    throw "Destination account verification failed."
}

# Step 3: Confirm destination repository exists
gh api "repos/$DestinationOwner/$Repo" --silent

if ($LASTEXITCODE -ne 0) {
    throw "Destination repository does not exist. Run Create-Repository.ps1 first."
}

# Step 4: Mirror clone source repository
Write-Host "Cloning source repository..."

if (Test-Path $MirrorPath) {
    throw "Mirror folder already exists. Stop and inspect it before running again."
}

$SourceUrl = "https://github.com/$SourceOwner/$Repo.git"

git clone --mirror $SourceUrl $MirrorPath

if ($LASTEXITCODE -ne 0) {
    throw "Source mirror clone failed."
}

# Step 5: Push mirror to destination
Write-Host "Pushing repository history to destination..."

$DestinationUrl = "https://github.com/$DestinationOwner/$Repo.git"

git -C $MirrorPath push --mirror $DestinationUrl

if ($LASTEXITCODE -ne 0) {
    throw "Mirror push failed. Check destination access and Git credentials."
}

Write-Host "=========================================="
Write-Host "Repository migration completed!"
Write-Host "Source: $SourceOwner/$Repo"
Write-Host "Destination: $DestinationOwner/$Repo"
Write-Host "==========================================" -ForegroundColor Green
