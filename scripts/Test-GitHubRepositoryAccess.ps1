
param(
    [string]$SourceAccountId = "swapna880",
    [string]$DestinationAccountId = "swapnakuntala"
)

$ErrorActionPreference = "Stop"
$ApiBase = "https://api.github.com"

function Get-GitHubApiData {
    param(
        [string]$Token,
        [string]$Endpoint
    )

    $Headers = @{
        Authorization = "Bearer $Token"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    Invoke-RestMethod -Uri "$ApiBase$Endpoint" -Headers $Headers -Method Get
}

function Test-RepositoryAccess {
    param(
        [string]$AccountId,
        [securestring]$Token,
        [string]$Repository,
        [string]$AccountType
    )

    $BSTR = [IntPtr]::Zero
    $PlainToken = $null

    try {
        $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        $PlainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)

        Write-Host "`n========== $AccountType Repository Checks ==========" -ForegroundColor Cyan
        Write-Host "Account: $AccountId"
        Write-Host "Repository: $AccountId/$Repository"

        $RepoData = Get-GitHubApiData -Token $PlainToken -Endpoint "/repos/$AccountId/$Repository"

        Write-Host "Repository details: PASSED" -ForegroundColor Green
        Write-Host "Visibility: $($RepoData.visibility)"
        Write-Host "Default branch: $($RepoData.default_branch)"

        $Branches = @(Get-GitHubApiData -Token $PlainToken -Endpoint "/repos/$AccountId/$Repository/branches?per_page=100")

        Write-Host "Branch access: PASSED" -ForegroundColor Green
        Write-Host "Branches found: $($Branches.Count)"

        foreach ($Branch in $Branches) {
            Write-Host " - $($Branch.name)"
        }

        $Tags = @(Get-GitHubApiData -Token $PlainToken -Endpoint "/repos/$AccountId/$Repository/tags?per_page=100")

        Write-Host "Tag access: PASSED" -ForegroundColor Green
        Write-Host "Tags found: $($Tags.Count)"

        try {
            $Rulesets = @(Get-GitHubApiData -Token $PlainToken -Endpoint "/repos/$AccountId/$Repository/rulesets?per_page=100")

            Write-Host "Ruleset access: PASSED" -ForegroundColor Green
            Write-Host "Rulesets found: $($Rulesets.Count)"
        }
        catch {
            Write-Host "Ruleset access: NOT AVAILABLE" -ForegroundColor Yellow
            Write-Host "Details: $($_.Exception.Message)"
        }

        Write-Host "$AccountType repository read checks completed." -ForegroundColor Green
    }
    catch {
        Write-Host "$AccountType repository access FAILED." -ForegroundColor Red
        throw $_
    }
    finally {
        $PlainToken = $null

        if ($BSTR -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        }
    }
}

try {
    Write-Host "GITHUB MIGRATION - REPOSITORY ACCESS TEST" -ForegroundColor Cyan

    $SourceToken = Read-Host "Enter Source Account Token" -AsSecureString
    $DestinationToken = Read-Host "Enter Destination Account Token" -AsSecureString

    Test-RepositoryAccess -AccountId $SourceAccountId -Token $SourceToken -Repository "testing-app" -AccountType "SOURCE"

    Test-RepositoryAccess -AccountId $DestinationAccountId -Token $DestinationToken -Repository "testing-app" -AccountType "DESTINATION"

    Write-Host "`nRepository access tests completed." -ForegroundColor Green
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    $SourceToken = $null
    $DestinationToken = $null
}
