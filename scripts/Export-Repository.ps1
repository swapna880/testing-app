
param(
    [string]$Owner = "swapna880",
    [string]$Repo = "testing-app",
    [System.Security.SecureString]$SourceToken
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

$ProjectPath = "C:\GitHub-Migration-POC"
$ExportPath = Join-Path $ProjectPath "exports"
$LogPath = Join-Path $ProjectPath "logs"
$ReportPath = Join-Path $ProjectPath "reports"

New-Item -ItemType Directory -Force `
    -Path $ExportPath, $LogPath, $ReportPath | Out-Null

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"

$LogFile = Join-Path $LogPath "Export-$Timestamp.log"
$ReportFile = Join-Path $ReportPath "Export-Summary-$Timestamp.json"

$Results = [System.Collections.Generic.List[object]]::new()

$script:PlainToken = $null

# ------------------------------------------------------------
# SECURE TOKEN CONVERSION
# ------------------------------------------------------------

function Convert-SecureToken {
    param(
        [System.Security.SecureString]$SecureToken
    )

    $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
}

# ------------------------------------------------------------
# GITHUB API HEADERS
# ------------------------------------------------------------

function Get-GitHubHeaders {

    return @{
        Authorization = "Bearer $script:PlainToken"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
}

# ------------------------------------------------------------
# GITHUB API REQUEST
# ------------------------------------------------------------

function Invoke-GitHubGet {
    param(
        [string]$Uri
    )

    return Invoke-RestMethod `
        -Uri $Uri `
        -Headers (Get-GitHubHeaders) `
        -Method Get
}

# ------------------------------------------------------------
# EXPORT PAGINATED DATA
# ------------------------------------------------------------

function Export-PaginatedData {
    param(
        [string]$Endpoint
    )

    $AllData = [System.Collections.Generic.List[object]]::new()

    for ($Page = 1; $Page -le 100; $Page++) {

        $Uri = "https://api.github.com/$Endpoint" +
               "?per_page=100&page=$Page"

        $Response = Invoke-GitHubGet -Uri $Uri

        if ($null -eq $Response) {
            break
        }

        $PageItems = @($Response)

        if ($PageItems.Count -eq 0) {
            break
        }

        foreach ($Item in $PageItems) {
            $AllData.Add($Item)
        }

        if ($PageItems.Count -lt 100) {
            break
        }
    }

    return ,@($AllData.ToArray())
}

# ------------------------------------------------------------
# SAVE EXPORT DATA AND RESULT
# ------------------------------------------------------------

function Save-Export {
    param(
        [string]$Name,
        [string]$OutputFile,
        [scriptblock]$Action,
        [bool]$IsCollection = $false
    )

    Write-Host "`nExporting $Name..." -ForegroundColor Cyan

    try {

        $Data = & $Action

        if ($Name -eq "Repository" -and $null -ne $Data) {
            $Data.PSObject.Properties.Remove("temp_clone_token")
        }

        if ($IsCollection) {
            $Json = ConvertTo-Json -InputObject @($Data) -Depth 100
        }
        else {
            $Json = ConvertTo-Json -InputObject $Data -Depth 100
        }

        Set-Content -Path $OutputFile -Value $Json -Encoding utf8

        $Results.Add([PSCustomObject]@{
            Item = $Name
            Status = "Success"
            Details = "Export completed"
            File = $OutputFile
        })

        Write-Host "$Name exported successfully." -ForegroundColor Green
    }
    catch {

        $ErrorMessage = $_.Exception.Message
        $Status = "Failed"

        try {
            $StatusCode = [int]$_.Exception.Response.StatusCode

            if ($StatusCode -eq 403) {
                $Status = "Restricted"
            }
        }
        catch {
            if ($ErrorMessage -match "403|Forbidden") {
                $Status = "Restricted"
            }
        }

        $Results.Add([PSCustomObject]@{
            Item = $Name
            Status = $Status
            Details = $ErrorMessage
            File = $null
        })

        Write-Host "$Name : $Status" -ForegroundColor Yellow
        Write-Host $ErrorMessage

        Remove-Item $OutputFile -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------
# MAIN EXPORT PROCESS
# ------------------------------------------------------------

try {

    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "       GITHUB REPOSITORY EXPORT" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    # STEP 1: Collect source token securely.

    if (-not $SourceToken) {
        $SourceToken = Read-Host "Enter Source GitHub Token" -AsSecureString
    }

    if ($SourceToken.Length -eq 0) {
        throw "Source token cannot be empty."
    }

    $script:PlainToken = Convert-SecureToken -SecureToken $SourceToken

    # STEP 2: Verify source account.

    Write-Host "`nStep 1: Verifying source account..." -ForegroundColor Cyan

    $CurrentUser = Invoke-GitHubGet `
        -Uri "https://api.github.com/user"

    if ($CurrentUser.login -ne $Owner) {
        throw "Source token belongs to $($CurrentUser.login), not $Owner."
    }

    Write-Host "Source verified: $($CurrentUser.login)" -ForegroundColor Green

    # STEP 3: Verify source repository.

    Write-Host "`nStep 2: Checking source repository..." -ForegroundColor Cyan

    $RepositoryData = Invoke-GitHubGet `
        -Uri "https://api.github.com/repos/$Owner/$Repo"

    Write-Host "Repository access confirmed: $($RepositoryData.full_name)" -ForegroundColor Green

    # STEP 4: Export repository details.

    Save-Export `
        -Name "Repository" `
        -OutputFile (Join-Path $ExportPath "repository.json") `
        -Action {
            Invoke-GitHubGet -Uri "https://api.github.com/repos/$Owner/$Repo"
        }

    # STEP 5: Export branches.

    Save-Export `
        -Name "Branches" `
        -OutputFile (Join-Path $ExportPath "branches.json") `
        -Action {
            Export-PaginatedData "repos/$Owner/$Repo/branches"
        } `
        -IsCollection $true

    # STEP 6: Export tags.

    Save-Export `
        -Name "Tags" `
        -OutputFile (Join-Path $ExportPath "tags.json") `
        -Action {
            Export-PaginatedData "repos/$Owner/$Repo/tags"
        } `
        -IsCollection $true

    # STEP 7: Export collaborators.

    Save-Export `
        -Name "Collaborators" `
        -OutputFile (Join-Path $ExportPath "collaborators.json") `
        -Action {
            Export-PaginatedData "repos/$Owner/$Repo/collaborators"
        } `
        -IsCollection $true

    # STEP 8: Export rulesets.

    Save-Export `
        -Name "Rulesets" `
        -OutputFile (Join-Path $ExportPath "rulesets.json") `
        -Action {
            Export-PaginatedData "repos/$Owner/$Repo/rulesets"
        } `
        -IsCollection $true

    # STEP 9: Generate summary.

    $Successful = @(
        $Results | Where-Object { $_.Status -eq "Success" }
    ).Count

    $Restricted = @(
        $Results | Where-Object { $_.Status -eq "Restricted" }
    ).Count

    $Failed = @(
        $Results | Where-Object { $_.Status -eq "Failed" }
    ).Count

    if ($Failed -gt 0) {
        $OverallStatus = "Completed with failures"
    }
    elseif ($Restricted -gt 0) {
        $OverallStatus = "Completed with restrictions"
    }
    else {
        $OverallStatus = "Success"
    }

    $Summary = [PSCustomObject]@{
        SourceRepository = "$Owner/$Repo"
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        TotalItems = $Results.Count
        Successful = $Successful
        Restricted = $Restricted
        Failed = $Failed
        OverallStatus = $OverallStatus
        Results = $Results
    }

    $Summary |
        ConvertTo-Json -Depth 20 |
        Set-Content -Path $ReportFile -Encoding utf8

    # STEP 10: Display summary.

    Write-Host "`n==========================================" -ForegroundColor Cyan
    Write-Host "       EXPORT SUMMARY" -ForegroundColor Cyan
    Write-Host "==========================================" -ForegroundColor Cyan

    $Results | Format-Table Item, Status, Details -Wrap -AutoSize

    Write-Host "Successful: $Successful"
    Write-Host "Restricted: $Restricted"
    Write-Host "Failed: $Failed"
    Write-Host "Overall status: $OverallStatus"

    Write-Host "`nSummary file: $ReportFile"
    Write-Host "Export folder: $ExportPath"
    Write-Host "Log file: $LogFile"

    $Summary |
        ConvertTo-Json -Depth 20 |
        Set-Content -Path $LogFile -Encoding utf8

    if ($Failed -gt 0) {
        throw "One or more export operations failed. Review the summary report."
    }

}
catch {

    Write-Host "`nEXPORT PROCESS FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw

}
finally {

    $script:PlainToken = $null
    $SourceToken = $null

    Write-Host "`nSource authentication variables cleared from the script." -ForegroundColor DarkGray
}
