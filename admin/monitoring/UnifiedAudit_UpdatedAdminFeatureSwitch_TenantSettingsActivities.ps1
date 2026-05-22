<#
.SYNOPSIS
  Interactive auth to Exchange Online and search Unified Audit Log for UpdatedAdminFeatureSwitch.

.DESCRIPTION
  Connects with interactive (modern) authentication and searches the unified audit log
  for UpdatedAdminFeatureSwitch operations for the last N days.
  Uses ReturnLargeSet paging to retrieve as many results as the service returns (up to ~50,000).

.REQUIREMENTS
  - ExchangeOnlineManagement module
  - Permissions to search the Unified Audit Log (Purview Audit / Audit Logs)
#>

#region Prereqs
$ErrorActionPreference = "Stop"

# Ensure module is installed
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host "Installing ExchangeOnlineManagement module..." -ForegroundColor Yellow
    Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
}

Import-Module ExchangeOnlineManagement
#endregion Prereqs

#region Inputs
$upn = Read-Host "Enter your admin UPN (e.g., admin@contoso.com) for interactive sign-in"

$daysBackInput = Read-Host "Enter how many days back to search (default: 7)"
if ([string]::IsNullOrWhiteSpace($daysBackInput)) { $daysBack = 7 } else { $daysBack = [int]$daysBackInput }

# Optional: filter to specific user who performed the action (leave blank for all)
$userFilter = Read-Host "Optional: Filter by actor UserId (leave blank for all)"

# Optional: Result cap for safety (leave blank = no artificial cap; service cap still applies)
$maxResultsInput = Read-Host "Optional: Max results to retrieve (blank = no cap, service still limits)"
$maxResults = if ([string]::IsNullOrWhiteSpace($maxResultsInput)) { [int]::MaxValue } else { [int]$maxResultsInput }

# Date window (local time); Search-UnifiedAuditLog expects ExDateTime and works fine with DateTime objects
$endDate   = Get-Date
$startDate = (Get-Date).AddDays(-$daysBack)

Write-Host "`nSearch window: $startDate  -->  $endDate`n" -ForegroundColor Cyan
#endregion Inputs

#region Connect (Interactive)
Write-Host "Connecting to Exchange Online (interactive auth)..." -ForegroundColor Yellow
Connect-ExchangeOnline -UserPrincipalName $upn -ShowBanner:$false
#endregion Connect

#region Search (Paged)
$operation = "UpdatedAdminFeatureSwitch"
$sessionId = [Guid]::NewGuid().ToString()

$all = New-Object System.Collections.Generic.List[object]
$batch = 0

Write-Host "Searching Unified Audit Log for operation: $operation" -ForegroundColor Yellow
Write-Host "Using paging (ReturnLargeSet) to retrieve maximum available results..." -ForegroundColor Yellow

do {
    $batch++
    Write-Host "Fetching batch #$batch ..." -ForegroundColor Gray

    $params = @{
        StartDate      = $startDate
        EndDate        = $endDate
        Operations     = $operation
        SessionId      = $sessionId
        SessionCommand = "ReturnLargeSet"
        ResultSize     = 5000
    }

    if (-not [string]::IsNullOrWhiteSpace($userFilter)) {
        $params["UserIds"] = $userFilter
    }

    $results = Search-UnifiedAuditLog @params

    if ($results) {
        foreach ($r in $results) {
            $all.Add($r) | Out-Null
            if ($all.Count -ge $maxResults) { break }
        }
    }

    $countThisBatch = if ($results) { $results.Count } else { 0 }
    Write-Host "  Batch returned: $countThisBatch | Total collected: $($all.Count)" -ForegroundColor Gray

} while ($results.Count -gt 0 -and $all.Count -lt $maxResults)

Write-Host "`nTotal results collected: $($all.Count)`n" -ForegroundColor Green
#endregion Search

#region Transform + Output
# Parse AuditData JSON and flatten a few useful fields
$flattened = $all | ForEach-Object {
    $audit = $null
    try { $audit = $_.AuditData | ConvertFrom-Json } catch { }

    [PSCustomObject]@{
        CreationDate  = $_.CreationDate
        UserIds       = $_.UserIds
        Operations    = $_.Operations
        RecordType    = $_.RecordType
        ResultIndex   = $_.ResultIndex
        ResultCount   = $_.ResultCount

        # Common fields inside AuditData (presence varies by record)
        ActorUPN      = $audit.UserId
        Workload      = $audit.Workload
        Operation     = $audit.Operation
        ClientIP      = $audit.ClientIP
        UserAgent     = $audit.UserAgent
        ObjectId      = $audit.ObjectId

        # Keep the raw JSON too (handy for deep investigation)
        AuditData     = $_.AuditData
    }
}

# Display on screen
$flattened |
    Sort-Object CreationDate -Descending |
    Format-Table CreationDate, UserIds, Operations, ActorUPN, Workload, ClientIP -AutoSize

# Export to CSV
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$outFile = Join-Path -Path $PWD -ChildPath "UnifiedAudit_UpdatedAdminFeatureSwitch_$timestamp.csv"

$flattened | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $outFile
Write-Host "`nExported CSV: $outFile`n" -ForegroundColor Cyan
#endregion Transform + Output

#region Disconnect
Disconnect-ExchangeOnline -Confirm:$false
#endregion Disconnect
