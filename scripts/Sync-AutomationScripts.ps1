
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DestinationOwner,

    [Parameter(Mandatory = $true)]
    [string]$DestinationRepo,

    [Parameter(Mandatory = $true)]
    [SecureString]$DestinationToken,

    [Parameter(Mandatory = $true)]
    [string]$ScriptsPath,

    [string]$AutomationBranch = 'migration-automation'
)

$ErrorActionPreference = 'Stop'

$PlainToken = $null
$TempPath = Join-Path $env:TEMP ("github-automation-sync-" + [guid]::NewGuid())
$RepositoryPath = Join-Path $TempPath 'repository'

function Convert-SecureToken {
    param([SecureString]$Value)

    if ($null -eq $Value -or $Value.Length -eq 0) {
        throw 'Destination token is empty.'
    }

    $Pointer = [IntPtr]::Zero

    try {
        $Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
    }
    finally {
        if ($Pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
        }
    }
}

function Invoke-AuthenticatedGit {
    param(
        [string[]]$Arguments,
        [string]$Token
    )

    $PreviousCount = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
    $Count = 0

    if ($PreviousCount -match '^\d+$') {
        $Count = [int]$PreviousCount
    }

    $KeyName = "GIT_CONFIG_KEY_$Count"
    $ValueName = "GIT_CONFIG_VALUE_$Count"

    $PreviousKey = [Environment]::GetEnvironmentVariable($KeyName, 'Process')
    $PreviousValue = [Environment]::GetEnvironmentVariable($ValueName, 'Process')

    $Raw = [Text.Encoding]::UTF8.GetBytes("x-access-token:$Token")
    $Header = 'AUTHORIZATION: basic ' + [Convert]::ToBase64String($Raw)

    try {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', ($Count + 1).ToString(), 'Process')
        [Environment]::SetEnvironmentVariable($KeyName, 'http.extraheader', 'Process')
        [Environment]::SetEnvironmentVariable($ValueName, $Header, 'Process')

        & git @Arguments
        $ExitCode = $LASTEXITCODE

        if ($ExitCode -ne 0) {
            throw "Git command failed with exit code $ExitCode."
        }
    }
    finally {
        [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', $PreviousCount, 'Process')
        [Environment]::SetEnvironmentVariable($KeyName, $PreviousKey, 'Process')
        [Environment]::SetEnvironmentVariable($ValueName, $PreviousValue, 'Process')

        $Raw = $null
        $Header = $null
    }
}

try {
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host ' AUTOMATION SCRIPT SYNCHRONIZATION' -ForegroundColor Cyan
    Write-Host '==========================================' -ForegroundColor Cyan

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git is not installed or not available in PATH.'
    }

    if (-not (Test-Path -LiteralPath $ScriptsPath -PathType Container)) {
        throw "Scripts directory does not exist: $ScriptsPath"
    }

    $ScriptFiles = @(
        Get-ChildItem -LiteralPath $ScriptsPath -Filter '*.ps1' -File |
            Where-Object {
                $_.Name -notmatch '\.backup\.ps1$' -and
                $_.Name -notmatch '\.bak\.ps1$'
            }
    )

    if ($ScriptFiles.Count -eq 0) {
        throw 'No approved PowerShell scripts were found.'
    }

    $PlainToken = Convert-SecureToken $DestinationToken

    $RepositoryUrl = "https://github.com/$DestinationOwner/$DestinationRepo.git"

    New-Item -ItemType Directory -Path $RepositoryPath -Force | Out-Null

    & git -C $RepositoryPath init
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to initialize temporary Git repository.'
    }

    & git -C $RepositoryPath config user.name 'GitHub Migration Automation'
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to configure Git author name.'
    }

    & git -C $RepositoryPath config user.email 'migration-automation@users.noreply.github.com'
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to configure Git author email.'
    }

    & git -C $RepositoryPath remote add origin $RepositoryUrl
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to configure destination remote.'
    }

    Write-Host "Checking destination branch: $AutomationBranch" -ForegroundColor Yellow

    $RemoteOutput = Invoke-AuthenticatedGit -Token $PlainToken -Arguments @(
        '-C', $RepositoryPath,
        'ls-remote', '--heads', 'origin', "refs/heads/$AutomationBranch"
    )

    $RemoteBranchExists = @(
        $RemoteOutput | Where-Object {
            $_ -match '\srefs/heads/'
        }
    ).Count -gt 0

    if ($RemoteBranchExists) {
        Write-Host 'Existing automation branch found. Preserving its history.' -ForegroundColor Yellow

        Invoke-AuthenticatedGit -Token $PlainToken -Arguments @(
            '-C', $RepositoryPath,
            'fetch', 'origin', "refs/heads/$AutomationBranch"
        )

        & git -C $RepositoryPath checkout -B $AutomationBranch FETCH_HEAD
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to check out existing automation branch.'
        }
    }
    else {
        Write-Host 'Automation branch does not exist. Creating it.' -ForegroundColor Yellow

        & git -C $RepositoryPath checkout --orphan $AutomationBranch
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to create automation branch.'
        }
    }

    $TargetScriptsPath = Join-Path $RepositoryPath 'scripts'

    if (Test-Path -LiteralPath $TargetScriptsPath) {
        Remove-Item -LiteralPath $TargetScriptsPath -Recurse -Force
    }

    New-Item -ItemType Directory -Path $TargetScriptsPath -Force | Out-Null

    foreach ($File in $ScriptFiles) {
        Copy-Item -LiteralPath $File.FullName `
            -Destination (Join-Path $TargetScriptsPath $File.Name) `
            -Force
    }

    & git -C $RepositoryPath add --all -- scripts
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to stage automation scripts.'
    }

    & git -C $RepositoryPath diff --cached --quiet
    $DiffExitCode = $LASTEXITCODE

    if ($DiffExitCode -eq 0) {
        Write-Host 'Automation scripts are already up to date.' -ForegroundColor Green
    }
    elseif ($DiffExitCode -eq 1) {
        & git -C $RepositoryPath commit -m 'Update GitHub migration automation scripts'
        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to commit automation scripts.'
        }

        Write-Host 'Automation script commit created.' -ForegroundColor Green

        Invoke-AuthenticatedGit -Token $PlainToken -Arguments @(
            '-C', $RepositoryPath,
            'push', 'origin', "HEAD:refs/heads/$AutomationBranch"
        )

        Write-Host 'Automation scripts pushed successfully.' -ForegroundColor Green
    }
    else {
        throw "Git staged-diff check failed with exit code $DiffExitCode."
    }

    Write-Host "`nAutomation synchronization completed." -ForegroundColor Green
    Write-Host "Repository: $DestinationOwner/$DestinationRepo"
    Write-Host "Branch: $AutomationBranch"
    Write-Host "Scripts synchronized: $($ScriptFiles.Count)"
}
catch {
    Write-Host "`nAUTOMATION SYNCHRONIZATION FAILED: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    $PlainToken = $null

    if (Test-Path -LiteralPath $TempPath) {
        Remove-Item -LiteralPath $TempPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Temporary authentication and working files cleaned up.' -ForegroundColor DarkGray
}
