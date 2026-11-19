
param(
    [string]$DestinationOwner = "swapnakuntala",
    [string]$Repo = "migration-automation-test",
    [string]$Description = "Migrated repository - GitHub Migration POC",
    [System.Security.SecureString]$DestinationToken
)

$ErrorActionPreference = "Stop"
$OwnDestinationToken = $false

$PlainToken = $null
$BSTR = $null

try {
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "GITHUB DESTINATION REPOSITORY CREATION" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Securely request destination token if not supplied.
    if (-not $DestinationToken) {
    $DestinationToken = Read-Host "Enter Destination GitHub Token" -AsSecureString
    $OwnDestinationToken = $true
    }

    if ($DestinationToken.Length -eq 0) {
        throw "Destination token cannot be empty."
    }

    $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($DestinationToken)
    $PlainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)

    $Headers = @{
        Authorization = "Bearer $PlainToken"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    # STEP 1: Verify destination identity.
    Write-Host "`nStep 1: Verifying destination account..." -ForegroundColor Cyan

    $CurrentUser = Invoke-RestMethod `
        -Uri "https://api.github.com/user" `
        -Headers $Headers `
        -Method Get

    if ($CurrentUser.login -ne $DestinationOwner) {
        throw "Token belongs to $($CurrentUser.login), not $DestinationOwner."
    }

    Write-Host "Destination verified: $($CurrentUser.login)" -ForegroundColor Green

    # STEP 2: Check if repository already exists.
    Write-Host "`nStep 2: Checking destination repository..." -ForegroundColor Cyan

    $RepositoryUri = "https://api.github.com/repos/$DestinationOwner/$Repo"

    $ExistingRepository = $null

    try {
        $ExistingRepository = Invoke-RestMethod `
            -Uri $RepositoryUri `
            -Headers $Headers `
            -Method Get
    }
    catch {
        $StatusCode = $null

        try {
            $StatusCode = [int]$_.Exception.Response.StatusCode
        }
        catch {
            $StatusCode = $null
        }

        if ($StatusCode -ne 404) {
            throw "Unable to check destination repository. $($_.Exception.Message)"
        }
    }

    if ($null -ne $ExistingRepository) {
        Write-Host "Repository already exists: $($ExistingRepository.full_name)" -ForegroundColor Yellow

        [PSCustomObject]@{
            Repository = $ExistingRepository.full_name
            Status = "AlreadyExists"
            Visibility = $ExistingRepository.visibility
            Url = $ExistingRepository.html_url
        }

        return
    }

    # STEP 3: Create private repository.
    Write-Host "`nStep 3: Creating private destination repository..." -ForegroundColor Cyan

    $Body = @{
        name = $Repo
        description = $Description
        private = $true
        has_issues = $true
        has_projects = $true
        has_wiki = $false
    } | ConvertTo-Json

    $CreatedRepository = Invoke-RestMethod `
        -Uri "https://api.github.com/user/repos" `
        -Headers $Headers `
        -Method Post `
        -Body $Body `
        -ContentType "application/json"

    Write-Host "`nDestination repository created successfully!" -ForegroundColor Green

    [PSCustomObject]@{
        Repository = $CreatedRepository.full_name
        Status = "Created"
        Visibility = $CreatedRepository.visibility
        Url = $CreatedRepository.html_url
    }
}
catch {
    Write-Host "`nREPOSITORY CREATION FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    $PlainToken = $null
    $Headers = $null
    $Body = $null

    if ($BSTR -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }

    if ($OwnDestinationToken -and $DestinationToken) {
        $DestinationToken.Dispose()
    }

    $DestinationToken = $null

    Write-Host "`nDestination authentication variables cleared." -ForegroundColor DarkGray
}
