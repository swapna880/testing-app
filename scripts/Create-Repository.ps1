
param(
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "testing-app",
    [string]$Description = "Migrated repository - GitHub Migration POC"
)

$ErrorActionPreference = "Stop"

Write-Host "========================================"
Write-Host "GitHub Destination Repository Creation"
Write-Host "========================================"

# Verify destination account authentication
gh auth switch --user $DestinationOwner

if ($LASTEXITCODE -ne 0) {
    throw "Unable to switch to destination account."
}

$CurrentUser = gh api user --jq .login

if ($LASTEXITCODE -ne 0 -or $CurrentUser -ne $DestinationOwner) {
    throw "Destination account verification failed."
}

Write-Host "Authenticated account: $CurrentUser"

# Check whether destination repository already exists
gh api "repos/$DestinationOwner/$Repo" --silent 2>$null

if ($LASTEXITCODE -eq 0) {
    Write-Host "Repository already exists: $DestinationOwner/$Repo" -ForegroundColor Yellow
}
else {
    # Create a private repository
    Write-Host "Creating destination repository..."

    $Result = gh api user/repos `
        -f name=$Repo `
        -f description="$Description" `
        -F private=true `
        -F has_issues=true `
        -F has_projects=true `
        -F has_wiki=false `
        --jq '{name: .name, full_name: .full_name, private: .private, html_url: .html_url}'

    if ($LASTEXITCODE -ne 0) {
        throw "Destination repository creation failed."
    }

    Write-Host $Result
    Write-Host "Destination repository created successfully!" -ForegroundColor Green
}