
param(
    [string]$SourceOwner = "swapna880",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "testing-app"
)

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$ReportPath = Join-Path $ProjectPath "reports\Migration-Validation-Report.json"

New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force |
    Out-Null

$Results = @()

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host " GitHub Repository Migration Validation" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

function Add-ValidationResult {
    param(
        [string]$Check,
        [string]$Status,
        [string]$Details
    )

    $script:Results += [PSCustomObject]@{
        Check = $Check
        Status = $Status
        Details = $Details
    }

    Write-Host "$Check : $Status - $Details"
}

# STEP 1: Verify source account
gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) {
    throw "Cannot switch to source account."
}

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser -ne $SourceOwner) {
    throw "Source authentication failed."
}

# STEP 2: Verify source repository
$SourceRepoJson = gh api "repos/$SourceOwner/$Repo"
if ($LASTEXITCODE -ne 0) {
    throw "Source repository cannot be accessed."
}

$SourceRepo = $SourceRepoJson | ConvertFrom-Json

# STEP 3: Verify destination account
gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) {
    throw "Cannot switch to destination account."
}

$CurrentUser = gh api user --jq .login
if ($LASTEXITCODE -ne 0 -or $CurrentUser -ne $DestinationOwner) {
    throw "Destination authentication failed."
}

# STEP 4: Verify destination repository
$DestinationRepoJson = gh api "repos/$DestinationOwner/$Repo"
if ($LASTEXITCODE -ne 0) {
    throw "Destination repository cannot be accessed."
}

$DestinationRepo = $DestinationRepoJson | ConvertFrom-Json

Add-ValidationResult "Repository existence" "Passed" "Both repositories are accessible."

# STEP 5: Compare visibility
if ($SourceRepo.private -eq $DestinationRepo.private) {
    Add-ValidationResult "Repository visibility" "Passed" "Visibility matches."
}
else {
    Add-ValidationResult "Repository visibility" "Failed" "Visibility differs."
}

# STEP 6: Compare default branch
if ($SourceRepo.default_branch -eq $DestinationRepo.default_branch) {
    Add-ValidationResult "Default branch" "Passed" $SourceRepo.default_branch
}
else {
    Add-ValidationResult "Default branch" "Failed" "Default branch differs."
}

# STEP 7: Compare repository settings
$SettingNames = @(
    "description",
    "has_issues",
    "has_projects",
    "has_wiki",
    "allow_squash_merge",
    "allow_merge_commit",
    "allow_rebase_merge",
    "allow_auto_merge",
    "delete_branch_on_merge"
)

foreach ($Setting in $SettingNames) {

    $SourceValue = $SourceRepo.$Setting
    $DestinationValue = $DestinationRepo.$Setting

    if ($SourceValue -eq $DestinationValue) {
        Add-ValidationResult "Setting: $Setting" "Passed" "Values match."
    }
    else {
        Add-ValidationResult "Setting: $Setting" "Failed" "Values differ."
    }
}

# STEP 8: Compare Git branches and tags
gh auth switch --user $SourceOwner
gh auth setup-git

$SourceBranches = @(
    git ls-remote --heads "https://github.com/$SourceOwner/$Repo.git" |
    ForEach-Object { ($_ -split "refs/heads/")[-1] }
)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve source branches."
}

$SourceTags = @(
    git ls-remote --tags --refs "https://github.com/$SourceOwner/$Repo.git" |
    ForEach-Object { ($_ -split "refs/tags/")[-1] }
)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve source tags."
}

gh auth switch --user $DestinationOwner
gh auth setup-git

$DestinationBranches = @(
    git ls-remote --heads "https://github.com/$DestinationOwner/$Repo.git" |
    ForEach-Object { ($_ -split "refs/heads/")[-1] }
)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve destination branches."
}

$DestinationTags = @(
    git ls-remote --tags --refs "https://github.com/$DestinationOwner/$Repo.git" |
    ForEach-Object { ($_ -split "refs/tags/")[-1] }
)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to retrieve destination tags."
}

$MissingBranches = @($SourceBranches | Where-Object { $_ -notin $DestinationBranches })
$ExtraBranches = @($DestinationBranches | Where-Object { $_ -notin $SourceBranches })

if ($MissingBranches.Count -eq 0 -and $ExtraBranches.Count -eq 0) {
    Add-ValidationResult "Branch comparison" "Passed" "All branch names match."
}
else {
    Add-ValidationResult "Branch comparison" "Failed" "Missing: $($MissingBranches -join ', '); Extra: $($ExtraBranches -join ', ')"
}

$MissingTags = @($SourceTags | Where-Object { $_ -notin $DestinationTags })
$ExtraTags = @($DestinationTags | Where-Object { $_ -notin $SourceTags })

if ($MissingTags.Count -eq 0 -and $ExtraTags.Count -eq 0) {
    Add-ValidationResult "Tag comparison" "Passed" "All tag names match."
}
else {
    Add-ValidationResult "Tag comparison" "Failed" "Missing: $($MissingTags -join ', '); Extra: $($ExtraTags -join ', ')"
}

# STEP 9: Compare commit IDs for each branch
foreach ($Branch in $SourceBranches) {

    $SourceCommit = git ls-remote "https://github.com/$SourceOwner/$Repo.git" "refs/heads/$Branch" |
        ForEach-Object { ($_ -split "\s+")[0] }

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read source commit for branch $Branch."
    }

    $DestinationCommit = git ls-remote "https://github.com/$DestinationOwner/$Repo.git" "refs/heads/$Branch" |
        ForEach-Object { ($_ -split "\s+")[0] }

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to read destination commit for branch $Branch."
    }

    if ($SourceCommit -eq $DestinationCommit) {
        Add-ValidationResult "Commit: $Branch" "Passed" "Commit IDs match."
    }
    else {
        Add-ValidationResult "Commit: $Branch" "Failed" "Commit IDs differ."
    }
}

# STEP 10: Generate validation report
$Passed = @($Results | Where-Object { $_.Status -eq "Passed" }).Count
$Failed = @($Results | Where-Object { $_.Status -eq "Failed" }).Count

$FinalReport = [PSCustomObject]@{
    SourceRepository = "$SourceOwner/$Repo"
    DestinationRepository = "$DestinationOwner/$Repo"
    Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    TotalChecks = $Results.Count
    Passed = $Passed
    Failed = $Failed
    OverallStatus = if ($Failed -eq 0) { "Passed" } else { "Failed" }
    Results = $Results
}

$FinalReport |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path $ReportPath -Encoding utf8

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "Validation Summary" -ForegroundColor Cyan
Write-Host "Passed: $Passed"
Write-Host "Failed: $Failed"
Write-Host "Overall: $($FinalReport.OverallStatus)"
Write-Host "Report: $ReportPath"
Write-Host "==========================================" -ForegroundColor Cyan
