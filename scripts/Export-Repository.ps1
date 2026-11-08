
param(
    [string]$Owner = "swapna880",
    [string]$Repo = "testing-app"
)

$ErrorActionPreference = "Stop"

$ProjectPath = "C:\GitHub-Migration-POC"
$ExportPath = "$ProjectPath\exports"
$LogPath = "$ProjectPath\logs"
$ReportPath = "$ProjectPath\reports"

New-Item -ItemType Directory -Force -Path $ExportPath, $LogPath, $ReportPath | Out-Null

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$LogFile = "$LogPath\Export-$Timestamp.log"
$ReportFile = "$ReportPath\Export-Summary-$Timestamp.json"

$Results = [System.Collections.Generic.List[object]]::new()

function Export-GitHubData {
    param(
        [string]$Name,
        [string]$Endpoint,
        [string]$OutputFile
    )

    Write-Host "Exporting $Name..." -ForegroundColor Cyan

    try {
        $Response = gh api --paginate $Endpoint 2>&1

        if ($LASTEXITCODE -ne 0) {
            $ErrorMessage = $Response -join "`n"

            if ($ErrorMessage -match "403") {
                $Status = "Restricted"
            }
            else {
                $Status = "Failed"
            }

            throw $ErrorMessage
        }

        $JsonText = $Response -join "`n"
        $Data = $JsonText | ConvertFrom-Json -ErrorAction Stop

        if ($Name -eq "Repository") {
            $Data.PSObject.Properties.Remove("temp_clone_token")
        }

        $Data |
            ConvertTo-Json -Depth 100 |
            Set-Content -Path $OutputFile -Encoding utf8

        $Results.Add([PSCustomObject]@{
            Item = $Name
            Status = "Success"
            Details = "Export completed"
        })

        Write-Host "$Name exported successfully." -ForegroundColor Green
    }
    catch {
        if (-not $Status) {
            $Status = "Failed"
        }

        $Results.Add([PSCustomObject]@{
            Item = $Name
            Status = $Status
            Details = $_.Exception.Message
        })

        Write-Host "$Name : $Status" -ForegroundColor Yellow
        Write-Host $_.Exception.Message

        Remove-Item $OutputFile -Force -ErrorAction SilentlyContinue
    }
    finally {
        $Status = $null
    }
}

Write-Host "Starting repository export..." -ForegroundColor Cyan

gh auth switch --user $Owner

if ($LASTEXITCODE -ne 0) {
    throw "Unable to switch to source account."
}

$CurrentUser = gh api user --jq .login

if ($LASTEXITCODE -ne 0 -or $CurrentUser -ne $Owner) {
    throw "Source account verification failed."
}

Export-GitHubData "Repository" "repos/$Owner/$Repo" "$ExportPath\repository.json"
Export-GitHubData "Branches" "repos/$Owner/$Repo/branches" "$ExportPath\branches.json"
Export-GitHubData "Tags" "repos/$Owner/$Repo/tags" "$ExportPath\tags.json"
Export-GitHubData "Collaborators" "repos/$Owner/$Repo/collaborators" "$ExportPath\collaborators.json"
Export-GitHubData "Rulesets" "repos/$Owner/$Repo/rulesets" "$ExportPath\rulesets.json"

$Results |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path $ReportFile -Encoding utf8

$Results | Format-Table -AutoSize

$Results | Out-String | Set-Content -Path $LogFile

Write-Host "Export process completed."
Write-Host "Summary: $ReportFile"
Write-Host "Log: $LogFile"
