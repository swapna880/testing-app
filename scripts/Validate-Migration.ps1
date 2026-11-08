
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


# STEP 8: Compare Git branches and tags, including SHA values

function Get-GitRefs {
    param(
        [string]$Url,
        [ValidateSet("heads", "tags")]
        [string]$RefType
    )

    if ($RefType -eq "heads") {
        $Output = @(git ls-remote --heads $Url)
    }
    else {
        $Output = @(git ls-remote --tags --refs $Url)
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to retrieve $RefType from $Url"
    }

    $RefMap = @{}

    foreach ($Line in $Output) {
        if ($Line -match '^([0-9a-f]+)\s+(.+)$') {
            $RefMap[$Matches[2]] = $Matches[1]
        }
    }

    return $RefMap
}

# Retrieve source references
gh auth switch --user $SourceOwner
if ($LASTEXITCODE -ne 0) {
    throw "Unable to switch to source account."
}

gh auth setup-git

$SourceBranchRefs = Get-GitRefs `
    -Url "https://github.com/$SourceOwner/$Repo.git" `
    -RefType "heads"

$SourceTagRefs = Get-GitRefs `
    -Url "https://github.com/$SourceOwner/$Repo.git" `
    -RefType "tags"

# Retrieve destination references
gh auth switch --user $DestinationOwner
if ($LASTEXITCODE -ne 0) {
    throw "Unable to switch to destination account."
}

gh auth setup-git

$DestinationBranchRefs = Get-GitRefs `
    -Url "https://github.com/$DestinationOwner/$Repo.git" `
    -RefType "heads"

$DestinationTagRefs = Get-GitRefs `
    -Url "https://github.com/$DestinationOwner/$Repo.git" `
    -RefType "tags"

# Compare branch names
$MissingBranches = @(
    $SourceBranchRefs.Keys |
    Where-Object { $_ -notin $DestinationBranchRefs.Keys }
)

$ExtraBranches = @(
    $DestinationBranchRefs.Keys |
    Where-Object { $_ -notin $SourceBranchRefs.Keys }
)

if ($MissingBranches.Count -eq 0 -and $ExtraBranches.Count -eq 0) {
    Add-ValidationResult "Branch comparison" "Passed" "All branch names match."
}
else {
    Add-ValidationResult "Branch comparison" "Failed" "Missing: $($MissingBranches -join ', '); Extra: $($ExtraBranches -join ', ')"
}

# Compare branch SHA values
foreach ($Ref in $SourceBranchRefs.Keys) {
    if ($DestinationBranchRefs.ContainsKey($Ref) -and
        $SourceBranchRefs[$Ref] -eq $DestinationBranchRefs[$Ref]) {

        Add-ValidationResult "Branch SHA: $Ref" "Passed" "Commit SHA matches."
    }
    else {
        Add-ValidationResult "Branch SHA: $Ref" "Failed" "Commit SHA differs or branch is missing."
    }
}

# Compare tag names
$MissingTags = @(
    $SourceTagRefs.Keys |
    Where-Object { $_ -notin $DestinationTagRefs.Keys }
)

$ExtraTags = @(
    $DestinationTagRefs.Keys |
    Where-Object { $_ -notin $SourceTagRefs.Keys }
)

if ($MissingTags.Count -eq 0 -and $ExtraTags.Count -eq 0) {
    Add-ValidationResult "Tag comparison" "Passed" "All tag names match."
}
else {
    Add-ValidationResult "Tag comparison" "Failed" "Missing: $($MissingTags -join ', '); Extra: $($ExtraTags -join ', ')"
}

# Compare tag SHA values
foreach ($Ref in $SourceTagRefs.Keys) {
    if ($DestinationTagRefs.ContainsKey($Ref) -and
        $SourceTagRefs[$Ref] -eq $DestinationTagRefs[$Ref]) {

        Add-ValidationResult "Tag SHA: $Ref" "Passed" "Tag object SHA matches."
    }
    else {
        Add-ValidationResult "Tag SHA: $Ref" "Failed" "Tag object SHA differs or tag is missing."
    }
}

# STEP 9: Compare commit IDs for each branch
foreach ($Branch in $SourceBranchRefs.Keys) {

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

if ($Failed -gt 0) {
    Write-Host "Migration validation failed. Review the JSON report." -ForegroundColor Red
    exit 1
}
else {
    Write-Host "All migration validation checks passed." -ForegroundColor Green
    exit 0
}