
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceAccountId,

    [Parameter(Mandatory = $true)]
    [string]$DestinationAccountId
)

$ErrorActionPreference = "Stop"

function Test-GitHubToken {
    param(
        [string]$AccountId,
        [securestring]$Token,
        [string]$AccountType
    )

    $BSTR = [IntPtr]::Zero
    $PreviousToken = $env:GH_TOKEN
    $PreviousConfig = $env:GH_CONFIG_DIR

    try {
        Write-Host "`nChecking $AccountType account: $AccountId"

        $BSTR = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Token)
        $PlainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($BSTR)

        $env:GH_TOKEN = $PlainToken

        # Use an isolated GitHub CLI configuration directory.
        $ConfigDir = Join-Path $env:TEMP "GitHub-Migration-POC-$AccountType"
        New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
        $env:GH_CONFIG_DIR = $ConfigDir

        $Result = & gh api user --jq .login 2>&1
        $ExitCode = $LASTEXITCODE

        if ($ExitCode -ne 0) {
            throw "GitHub authentication failed. Check the token and its permissions. Details: $Result"
        }

        $AuthenticatedAccount = ($Result | Out-String).Trim()

        if ($AuthenticatedAccount -ne $AccountId) {
            throw "Account mismatch. Expected: $AccountId. Authenticated: $AuthenticatedAccount"
        }

        Write-Host "SUCCESS: $AccountType authentication verified as $AuthenticatedAccount" -ForegroundColor Green
    }
    catch {
        throw "$AccountType authentication error: $($_.Exception.Message)"
    }
    finally {
        $env:GH_TOKEN = $PreviousToken
        $env:GH_CONFIG_DIR = $PreviousConfig

        if ($BSTR -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
        }

        $PlainToken = $null
    }
}

try {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) is not installed or not available in PATH."
    }

    Write-Host "GITHUB MIGRATION - AUTHENTICATION TEST" -ForegroundColor Cyan

    $SourceToken = Read-Host "Enter Source Account Token" -AsSecureString
    $DestinationToken = Read-Host "Enter Destination Account Token" -AsSecureString

    Test-GitHubToken -AccountId $SourceAccountId -Token $SourceToken -AccountType "Source"

    Test-GitHubToken -AccountId $DestinationAccountId -Token $DestinationToken -AccountType "Destination"

    Write-Host "`nBoth GitHub accounts authenticated successfully." -ForegroundColor Green
}
catch {
    Write-Host "`nERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    $SourceToken = $null
    $DestinationToken = $null
}
