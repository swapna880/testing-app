
param(
    [string]$SourceOwner = "swapna880",
    [string]$SourceRepo = "testing-app",
    [string]$DestinationOwner = "swapnakuntala",
    [string]$DestinationRepo = "migration-automation-test",
    [string]$ProjectPath = "C:\github-migration\post-migration-validation",
    [switch]$AllowDestinationPrivate,
    [SecureString]$SourceToken,
    [SecureString]$DestinationToken
)

$ErrorActionPreference = "Stop"

$AllowedBranches = @("main", "develop", "feature/login")
$ReportPath = Join-Path $ProjectPath "reports\Migration-Validation-Report.json"

$SourcePlainToken = $null
$DestinationPlainToken = $null

$OwnSourceToken = $false
$OwnDestinationToken = $false

$Results = [System.Collections.Generic.List[object]]::new()

function Convert-SecureToken {
    param([SecureString]$SecureValue)

    if ($null -eq $SecureValue) {
        throw "A required GitHub token was not supplied."
    }

    $Bstr = [IntPtr]::Zero

    try {
        $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
    }
    finally {
        if ($Bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
        }
    }
}

function Get-GitHubHeaders {
    param([string]$Token)

    return @{
        Authorization = "Bearer $Token"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
}

function Invoke-GitHubGet {
    param(
        [string]$Uri,
        [hashtable]$Headers
    )

    return Invoke-RestMethod `
        -Uri $Uri `
        -Headers $Headers `
        -Method GET `
        -ErrorAction Stop
}

function Add-ValidationResult {
    param(
        [string]$Check,
        [string]$Status,
        [string]$Details
    )

    $Results.Add([PSCustomObject]@{
        Check = $Check
        Status = $Status
        Details = $Details
    })

    switch ($Status) {
        "Passed"  { $Color = "Green" }
        "Warning" { $Color = "Yellow" }
        default   { $Color = "Red" }
    }

    Write-Host "$Check : $Status - $Details" -ForegroundColor $Color
}

function Get-BranchComparison {
    param(
        [string]$Branch,
        [string]$SourceSHA,
        [string]$DestinationSHA,
        [hashtable]$Headers
    )

    $Uri = "https://api.github.com/repos/$SourceOwner/$SourceRepo/compare/$DestinationSHA...$SourceSHA"

    try {
        $Comparison = Invoke-GitHubGet -Uri $Uri -Headers $Headers

        if ($Comparison.status -eq "identical") {
            Add-ValidationResult "Branch: $Branch" "Passed" "Commit histories match."
        }
        elseif ($Comparison.status -eq "ahead") {
            Add-ValidationResult "Branch: $Branch" "Warning" `
                "Source is ahead by $($Comparison.ahead_by) commits."
        }
        elseif ($Comparison.status -eq "behind") {
            Add-ValidationResult "Branch: $Branch" "Warning" `
                "Destination is ahead by $($Comparison.behind_by) commits."
        }
        elseif ($Comparison.status -eq "diverged") {
            Add-ValidationResult "Branch: $Branch" "Failed" `
                "Source and destination histories have diverged. Ahead: $($Comparison.ahead_by); Behind: $($Comparison.behind_by)."
        }
        else {
            Add-ValidationResult "Branch: $Branch" "Failed" `
                "Unexpected comparison status: $($Comparison.status)"
        }
    }
    catch {
        Add-ValidationResult "Branch: $Branch" "Failed" `
            "Unable to compare commit histories: $($_.Exception.Message)"
    }
}

function Get-GitAuthorizationHeader {
    param([string]$Token)

    $Bytes = [Text.Encoding]::UTF8.GetBytes("x-access-token:$Token")
    $Encoded = [Convert]::ToBase64String($Bytes)

    return "AUTHORIZATION: basic $Encoded"
}

function Get-GitRefs {
    param(
        [string]$Url,
        [string]$Token,
        [ValidateSet("heads", "tags")]
        [string]$RefType
    )

    $Header = Get-GitAuthorizationHeader -Token $Token

    if ($RefType -eq "heads") {
        $Output = @(
            & git -c "http.extraheader=$Header" ls-remote --heads $Url
        )
    }
    else {
        $Output = @(
            & git -c "http.extraheader=$Header" ls-remote --tags --refs $Url
        )
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to retrieve $RefType from $Url"
    }

    $RefMap = @{}

    foreach ($Line in $Output) {
        if ($Line -match '^([0-9a-fA-F]+)\s+(.+)$') {
            $RefMap[$Matches[2]] = $Matches[1].ToLowerInvariant()
        }
    }

    return $RefMap
}

function Get-ExpectedBranches {
    param([hashtable]$AllBranches)

    $Expected = @{}

    foreach ($Branch in $AllowedBranches) {
        $RefName = "refs/heads/$Branch"

        if (-not $AllBranches.ContainsKey($RefName)) {
            throw "Required source branch is missing: $Branch"
        }

        $Expected[$RefName] = $AllBranches[$RefName]
    }

    return $Expected
}

function Compare-ReferenceMaps {
    param(
        [string]$Label,
        [hashtable]$SourceMap,
        [hashtable]$DestinationMap,
        [switch]$SkipShaComparison
    )

    $Missing = @(
        $SourceMap.Keys |
            Where-Object { -not $DestinationMap.ContainsKey($_) }
    )

    $Extra = @(
        $DestinationMap.Keys |
            Where-Object { -not $SourceMap.ContainsKey($_) }
    )

    if ($Missing.Count -eq 0 -and $Extra.Count -eq 0) {
        Add-ValidationResult "$Label names" "Passed" "All intended names match."
    }
    else {
        Add-ValidationResult "$Label names" "Failed" `
            "Missing: $($Missing -join ', '); Extra: $($Extra -join ', ')"
    }

    if (-not $SkipShaComparison) {
        foreach ($Ref in $SourceMap.Keys) {
            if (
                $DestinationMap.ContainsKey($Ref) -and
                $SourceMap[$Ref] -eq $DestinationMap[$Ref]
            ) {
                Add-ValidationResult "$Label SHA: $Ref" "Passed" "SHA matches."
            }
            else {
                Add-ValidationResult "$Label SHA: $Ref" "Failed" `
                    "SHA differs or destination reference is missing."
            }
        }
    }
}

try {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host " GitHub Repository Migration Validation" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed or is not available in PATH."
    }

    New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force |
        Out-Null

    if (-not $SourceToken) {
        $SourceToken = Read-Host "Enter SOURCE GitHub token" -AsSecureString
        $OwnSourceToken = $true
    }

    if (-not $DestinationToken) {
        $DestinationToken = Read-Host "Enter DESTINATION GitHub token" -AsSecureString
        $OwnDestinationToken = $true
    }

    $SourcePlainToken = Convert-SecureToken $SourceToken
    $DestinationPlainToken = Convert-SecureToken $DestinationToken

    $SourceHeaders = Get-GitHubHeaders $SourcePlainToken
    $DestinationHeaders = Get-GitHubHeaders $DestinationPlainToken

    Write-Host "`nSTEP 1: Verifying source account..." -ForegroundColor Yellow

    $SourceUser = Invoke-GitHubGet `
        -Uri "https://api.github.com/user" `
        -Headers $SourceHeaders

    if ($SourceUser.login -ne $SourceOwner) {
        throw "Source token belongs to '$($SourceUser.login)', not '$SourceOwner'."
    }

    Write-Host "Source account verified: $($SourceUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 2: Retrieving source repository..." -ForegroundColor Yellow

    $SourceRepository = Invoke-GitHubGet `
        -Uri "https://api.github.com/repos/$SourceOwner/$SourceRepo" `
        -Headers $SourceHeaders

    Write-Host "Source repository verified: $($SourceRepository.full_name)" -ForegroundColor Green

    Write-Host "`nSTEP 3: Verifying destination account..." -ForegroundColor Yellow

    $DestinationUser = Invoke-GitHubGet `
        -Uri "https://api.github.com/user" `
        -Headers $DestinationHeaders

    if ($DestinationUser.login -ne $DestinationOwner) {
        throw "Destination token belongs to '$($DestinationUser.login)', not '$DestinationOwner'."
    }

    Write-Host "Destination account verified: $($DestinationUser.login)" -ForegroundColor Green

    Write-Host "`nSTEP 4: Retrieving destination repository..." -ForegroundColor Yellow

    $DestinationRepository = Invoke-GitHubGet `
        -Uri "https://api.github.com/repos/$DestinationOwner/$DestinationRepo" `
        -Headers $DestinationHeaders

    Write-Host "Destination repository verified: $($DestinationRepository.full_name)" -ForegroundColor Green

    Add-ValidationResult "Repository existence" "Passed" `
        "Both repositories are accessible."

    Write-Host "`nSTEP 5: Comparing repository visibility..." -ForegroundColor Yellow

    if ($DestinationRepository.private) {
        Add-ValidationResult "Repository visibility" "Passed" `
            "Destination repository is private as required."
    }
    else {
        Add-ValidationResult "Repository visibility" "Failed" `
            "Destination repository must be private."
    }

    Write-Host "`nSTEP 6: Comparing default branch..." -ForegroundColor Yellow

    if ($SourceRepository.default_branch -eq $DestinationRepository.default_branch) {
        Add-ValidationResult "Default branch" "Passed" $SourceRepository.default_branch
    }
    else {
        Add-ValidationResult "Default branch" "Failed" `
            "Source: $($SourceRepository.default_branch); Destination: $($DestinationRepository.default_branch)"
    }

    Write-Host "`nSTEP 7: Comparing repository settings..." -ForegroundColor Yellow

    $SettingNames = @(
        "description",
        "homepage",
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
        $SourceProperty = $SourceRepository.PSObject.Properties[$Setting]
        $DestinationProperty = $DestinationRepository.PSObject.Properties[$Setting]

        if ($null -eq $SourceProperty -or $null -eq $DestinationProperty) {
            Add-ValidationResult "Setting: $Setting" "Warning" `
                "Property unavailable in source or destination API response. Comparison skipped."
            continue
        }

        $SourceValue = $SourceProperty.Value
        $DestinationValue = $DestinationProperty.Value

        if ([string]$SourceValue -ceq [string]$DestinationValue) {
            Add-ValidationResult "Setting: $Setting" "Passed" "Values match."
        }
        elseif ($Setting -eq "description") {
            Add-ValidationResult "Setting: $Setting" "Warning" `
                "Descriptions differ. Source: '$SourceValue'; Destination: '$DestinationValue'."
        }
        else {
            Add-ValidationResult "Setting: $Setting" "Failed" `
                "Source: '$SourceValue'; Destination: '$DestinationValue'"
        }
    }

    Write-Host "`nSTEP 8: Comparing intended Git branches..." -ForegroundColor Yellow

    $SourceUrl = "https://github.com/$SourceOwner/$SourceRepo.git"
    $DestinationUrl = "https://github.com/$DestinationOwner/$DestinationRepo.git"

    $AllSourceBranchRefs = Get-GitRefs `
        -Url $SourceUrl `
        -Token $SourcePlainToken `
        -RefType heads

    $AllDestinationBranchRefs = Get-GitRefs `
        -Url $DestinationUrl `
        -Token $DestinationPlainToken `
        -RefType heads

    $SourceBranchRefs = Get-ExpectedBranches -AllBranches $AllSourceBranchRefs

    $DestinationBranchRefs = @{}
    foreach ($RefName in $AllDestinationBranchRefs.Keys) {
        if ($RefName -ne "refs/heads/migration-automation") {
            $DestinationBranchRefs[$RefName] = $AllDestinationBranchRefs[$RefName]
        }
    }


    Compare-ReferenceMaps `
        -Label "Branch" `
        -SourceMap $SourceBranchRefs `
        -DestinationMap $DestinationBranchRefs `
        -SkipShaComparison

    Write-Host "`nSTEP 9: Comparing Git tags..." -ForegroundColor Yellow

    $SourceTagRefs = Get-GitRefs `
        -Url $SourceUrl `
        -Token $SourcePlainToken `
        -RefType tags

    $DestinationTagRefs = Get-GitRefs `
        -Url $DestinationUrl `
        -Token $DestinationPlainToken `
        -RefType tags

    Compare-ReferenceMaps `
        -Label "Tag" `
        -SourceMap $SourceTagRefs `
        -DestinationMap $DestinationTagRefs

    Write-Host "`nSTEP 10: Comparing intended branch commit histories..." -ForegroundColor Yellow

    foreach ($Branch in $AllowedBranches) {
        $RefName = "refs/heads/$Branch"

        if (-not $AllDestinationBranchRefs.ContainsKey($RefName)) {
            Add-ValidationResult "Branch: $RefName" "Failed" `
                "Branch is missing in destination."
        }
        elseif ($SourceBranchRefs[$RefName] -eq $AllDestinationBranchRefs[$RefName]) {
            Add-ValidationResult "Branch: $RefName" "Passed" `
                "Commit IDs match."
        }
        else {
            Get-BranchComparison `
                -Branch $RefName `
                -SourceSHA $SourceBranchRefs[$RefName] `
                -DestinationSHA $AllDestinationBranchRefs[$RefName] `
                -Headers $SourceHeaders
        }
    }

    Write-Host "`nSTEP 11: Generating validation report..." -ForegroundColor Yellow

    $Passed = @($Results | Where-Object { $_.Status -eq "Passed" }).Count
    $Warnings = @($Results | Where-Object { $_.Status -eq "Warning" }).Count
    $Failed = @($Results | Where-Object { $_.Status -eq "Failed" }).Count

    $OverallStatus = if ($Failed -gt 0) {
        "Failed"
    }
    elseif ($Warnings -gt 0) {
        "CompletedWithWarnings"
    }
    else {
        "Passed"
    }

    $FinalReport = [PSCustomObject]@{
        SourceRepository = "$SourceOwner/$SourceRepo"
        DestinationRepository = "$DestinationOwner/$DestinationRepo"
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        IntendedBranches = $AllowedBranches
        ExcludedSourceBranches = @(
            $AllSourceBranchRefs.Keys |
                Where-Object { $_ -notin @(
                    "refs/heads/main",
                    "refs/heads/develop",
                    "refs/heads/feature/login"
                ) }
        )
        TotalChecks = $Results.Count
        Passed = $Passed
        Warnings = $Warnings
        Failed = $Failed
        OverallStatus = $OverallStatus
        Results = @($Results)
    }

    $FinalReport | ConvertTo-Json -Depth 10 |
        Set-Content -Path $ReportPath -Encoding UTF8

    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host " VALIDATION SUMMARY" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Passed   : $Passed" -ForegroundColor Green
    Write-Host "Warnings : $Warnings" -ForegroundColor Yellow
    Write-Host "Failed   : $Failed" -ForegroundColor Red
    Write-Host "Overall  : $OverallStatus" -ForegroundColor Cyan
    Write-Host "Report   : $ReportPath" -ForegroundColor Cyan

    if ($Failed -gt 0) {
        throw "Migration validation failed. Review the JSON report."
    }

    Write-Host "`nValidation completed successfully." -ForegroundColor Green
}
catch {
    Write-Host "`nVALIDATION FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    $SourcePlainToken = $null
    $DestinationPlainToken = $null

    if ($OwnSourceToken -and $SourceToken) {
        $SourceToken.Dispose()
    }

    if ($OwnDestinationToken -and $DestinationToken) {
        $DestinationToken.Dispose()
    }

    [GC]::Collect()

    Write-Host "`nAuthentication variables cleared." -ForegroundColor DarkGray
}



