# PowerBI Activity Logs Script using Service Principal
# This script retrieves Power BI activity logs to show who accessed which reports and when

# Use .env file to store sensitive information like TenantId, ClientId, and ClientSecret
# Example .env file content:
# [Entra]
# TenantId=your-tenant-id
# ClientId=your-client-id
# ClientSecret=your-client-secret

# Load environment variables from .env file if it exists
# $envFilePath = ".env"
# if (Test-Path $envFilePath) {
#     Write-Host "Loading environment variables from $envFilePath" -ForegroundColor Yellow
#     $envContent = Get-Content $envFilePath | Where-Object { $_ -and -not $_.StartsWith('#') }
#     foreach ($line in $envContent) {
#         if ($line -match '^\s*([^=]+?)\s*=\s*(.+?)\s*$') {
#             $key = $matches[1]
#             $value = $matches[2]
#             [System.Environment]::SetEnvironmentVariable($key, $value)
#         }
#     }
# } else {
#     Write-Host "No .env file found. Proceeding with provided parameters." -ForegroundColor Yellow
# }

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,
    
    [Parameter(Mandatory = $true)]
    [string]$ClientId,
    
    [Parameter(Mandatory = $true)]
    [string]$ClientSecret,
    
    [Parameter(Mandatory = $false)]
    [datetime]$StartDate = (Get-Date).AddDays(-7),
    
    [Parameter(Mandatory = $false)]
    [datetime]$EndDate = (Get-Date),
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportToExcel,
    
    [Parameter(Mandatory = $false)]
    [string]$ExcelOutputPath = ".\PowerBI_ActivityLogs.xlsx",
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportToCSV,
    
    [Parameter(Mandatory = $false)]
    [string]$CSVOutputPath = ".\PowerBI_ActivityLogs.csv"
)

# Function to get access token using service principal
function Get-PowerBIAccessToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )
    
    try {
        Write-Host "Obtaining access token..." -ForegroundColor Yellow
        
        # Azure AD token endpoint
        $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        
        # Request body for service principal authentication
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "https://analysis.windows.net/powerbi/api/.default"
        }
        
        # Make the token request
        $response = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $body -ContentType "application/x-www-form-urlencoded"
        
        Write-Host "Access token obtained successfully!" -ForegroundColor Green
        return $response.access_token
    }
    catch {
        Write-Error "Failed to obtain access token: $($_.Exception.Message)"
        throw
    }
}

# Function to get activity events for a specific date
function Get-PowerBIActivityEvents {
    param(
        [string]$AccessToken,
        [datetime]$Date
    )
    
    try {
        $dateString = $Date.ToString("yyyy-MM-dd")
        Write-Host "Retrieving activity events for $dateString..." -ForegroundColor Yellow
        
        # Power BI REST API endpoint for activity events
        $apiUrl = "https://api.powerbi.com/v1.0/myorg/admin/activityevents?startDateTime='$($dateString)T00:00:00.000Z'&endDateTime='$($dateString)T23:59:59.999Z'"
        
        # Headers for the API request
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }
        
        $allEvents = @()
        $continuationUri = $apiUrl
        
        do {
            # Make the API request
            $response = Invoke-RestMethod -Uri $continuationUri -Headers $headers -Method Get
            
            if ($response.activityEventEntities) {
                $allEvents += $response.activityEventEntities
            }
            
            # Check if there are more results
            $continuationUri = $response.continuationUri
            
        } while ($continuationUri)
        
        Write-Host "Retrieved $($allEvents.Count) events for $dateString" -ForegroundColor Green
        return $allEvents
    }
    catch {
        Write-Warning "Failed to retrieve activity events for $dateString : $($_.Exception.Message)"
        return @()
    }
}

# Function to get all activity events within date range
function Get-PowerBIActivityEventsRange {
    param(
        [string]$AccessToken,
        [datetime]$StartDate,
        [datetime]$EndDate
    )
    
    $allEvents = @()
    $currentDate = $StartDate.Date
    
    while ($currentDate -le $EndDate.Date) {
        $dailyEvents = Get-PowerBIActivityEvents -AccessToken $AccessToken -Date $currentDate
        $allEvents += $dailyEvents
        
        $currentDate = $currentDate.AddDays(1)
        Start-Sleep -Milliseconds 500  # Rate limiting
    }
    
    return $allEvents
}

# Function to filter and format activity logs for report access
function Format-ReportAccessLogs {
    param(
        [array]$ActivityEvents
    )
    
    # Filter for report-related activities
    $reportActivities = $ActivityEvents | Where-Object {
        $_.Activity -in @(
            'ViewReport',
            'ExportReport', 
            'PrintReport',
            'ShareReport',
            'ViewReportPage',
            'RefreshReport',
            'DownloadReport'
        )
    }
    
    Write-Host "Found $($reportActivities.Count) report access events" -ForegroundColor Green
    
    $formattedLogs = @()
    
    foreach ($event in $reportActivities) {
        $logEntry = [PSCustomObject]@{
            DateTime          = if ($event.CreationTime) { [datetime]$event.CreationTime } else { "Unknown" }
            UserEmail         = if ($event.UserInformation.UserEmail) { $event.UserInformation.UserEmail } else { "Unknown" }
            UserDisplayName   = if ($event.UserInformation.UserDisplayName) { $event.UserInformation.UserDisplayName } else { "Unknown" }
            Activity          = $event.Activity
            ReportName        = if ($event.ReportName) { $event.ReportName } else { "Unknown" }
            ReportId          = if ($event.ReportId) { $event.ReportId } else { "Unknown" }
            WorkspaceName     = if ($event.WorkSpaceName) { $event.WorkSpaceName } else { "Unknown" }
            WorkspaceId       = if ($event.WorkspaceId) { $event.WorkspaceId } else { "Unknown" }
            DatasetName       = if ($event.DatasetName) { $event.DatasetName } else { "Unknown" }
            DatasetId         = if ($event.DatasetId) { $event.DatasetId } else { "Unknown" }
            ClientIP          = if ($event.ClientIP) { $event.ClientIP } else { "Unknown" }
            UserAgent         = if ($event.UserAgent) { $event.UserAgent } else { "Unknown" }
            RequestId         = if ($event.RequestId) { $event.RequestId } else { "Unknown" }
            ActivityId        = if ($event.ActivityId) { $event.ActivityId } else { "Unknown" }
        }
        $formattedLogs += $logEntry
    }
    
    # Sort by DateTime descending (most recent first)
    return $formattedLogs | Sort-Object DateTime -Descending
}

# Function to export to Excel
function Export-ActivityLogsToExcel {
    param(
        [array]$Data,
        [string]$OutputPath
    )
    
    try {
        # Check if ImportExcel module is available
        if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
            Write-Warning "ImportExcel module not found. Installing ImportExcel module..."
            Install-Module -Name ImportExcel -Force -Scope CurrentUser
            Import-Module ImportExcel
        } else {
            Import-Module ImportExcel -Force
        }
        
        # Export to Excel with formatting
        $Data | Export-Excel -Path $OutputPath -AutoSize -BoldTopRow -FreezeTopRow -TableStyle Medium2 -WorksheetName "PowerBI_Activity_Logs"
        
        # Get and display the full path
        $fullPath = Resolve-Path -Path $OutputPath
        Write-Host "Activity logs exported to Excel: $OutputPath" -ForegroundColor Green
        Write-Host "Full path: $($fullPath.Path)" -ForegroundColor Cyan
        Write-Host "Report contains $($Data.Count) activity log entries" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to export to Excel: $($_.Exception.Message)"
        Write-Host "Falling back to CSV export..." -ForegroundColor Yellow
        
        # Fallback to CSV if Excel export fails
        $csvPath = $OutputPath -replace '\.xlsx$', '.csv'
        $Data | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
        Write-Host "Data exported to CSV instead: $csvPath" -ForegroundColor Yellow
    }
}

# Function to export to CSV
function Export-ActivityLogsToCSV {
    param(
        [array]$Data,
        [string]$OutputPath
    )
    
    try {
        $Data | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Host "Activity logs exported to CSV: $OutputPath" -ForegroundColor Green
        
        # Get and display the full path
        $fullPath = Resolve-Path -Path $OutputPath
        Write-Host "Full path: $($fullPath.Path)" -ForegroundColor Cyan
    }
    catch {
        Write-Error "Failed to export to CSV: $($_.Exception.Message)"
    }
}

# Main script execution
try {
    Write-Host "Starting Power BI Activity Logs Retrieval..." -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "Date Range: $($StartDate.ToString('yyyy-MM-dd')) to $($EndDate.ToString('yyyy-MM-dd'))" -ForegroundColor White
    
    # Validate parameters
    if ([string]::IsNullOrWhiteSpace($TenantId) -or 
        [string]::IsNullOrWhiteSpace($ClientId) -or 
        [string]::IsNullOrWhiteSpace($ClientSecret)) {
        throw "TenantId, ClientId, and ClientSecret are required parameters."
    }
    
    # Validate date range
    if ($StartDate -gt $EndDate) {
        throw "StartDate cannot be greater than EndDate."
    }
    
    # Check if date range is too large (API limitation)
    $daysDiff = ($EndDate - $StartDate).Days
    if ($daysDiff -gt 30) {
        Write-Warning "Date range is larger than 30 days. This may take a long time and could hit API limits."
    }
    
    # Get access token
    $accessToken = Get-PowerBIAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    
    # Get activity events
    $activityEvents = Get-PowerBIActivityEventsRange -AccessToken $accessToken -StartDate $StartDate -EndDate $EndDate
    
    Write-Host "`nTotal activity events retrieved: $($activityEvents.Count)" -ForegroundColor Green
    
    # Format report access logs
    $reportAccessLogs = Format-ReportAccessLogs -ActivityEvents $activityEvents
    
    # Display summary
    Write-Host "`nActivity Summary:" -ForegroundColor Cyan
    Write-Host "=================" -ForegroundColor Cyan
    Write-Host "Total report access events: $($reportAccessLogs.Count)" -ForegroundColor Green
    
    # Show activity breakdown
    if ($reportAccessLogs.Count -gt 0) {
        $activityBreakdown = $reportAccessLogs | Group-Object Activity | Sort-Object Count -Descending
        Write-Host "`nActivity Breakdown:" -ForegroundColor Yellow
        foreach ($activity in $activityBreakdown) {
            Write-Host "  $($activity.Name): $($activity.Count)" -ForegroundColor White
        }
        
        # Show top users
        $topUsers = $reportAccessLogs | Group-Object UserEmail | Sort-Object Count -Descending | Select-Object -First 10
        Write-Host "`nTop 10 Active Users:" -ForegroundColor Yellow
        foreach ($user in $topUsers) {
            Write-Host "  $($user.Name): $($user.Count) activities" -ForegroundColor White
        }
        
        # Show top reports
        $topReports = $reportAccessLogs | Where-Object { $_.ReportName -ne "Unknown" } | Group-Object ReportName | Sort-Object Count -Descending | Select-Object -First 10
        Write-Host "`nTop 10 Accessed Reports:" -ForegroundColor Yellow
        foreach ($report in $topReports) {
            Write-Host "  $($report.Name): $($report.Count) accesses" -ForegroundColor White
        }
        
        # Show recent activity sample
        Write-Host "`nRecent Activity Sample (Last 5):" -ForegroundColor Yellow
        $recentSample = $reportAccessLogs | Select-Object -First 5
        $recentSample | Format-Table DateTime, UserEmail, Activity, ReportName, WorkspaceName -AutoSize
    }
    
    # Export to Excel if requested
    if ($ExportToExcel) {
        Export-ActivityLogsToExcel -Data $reportAccessLogs -OutputPath $ExcelOutputPath
    }
    
    # Export to CSV if requested
    if ($ExportToCSV) {
        Export-ActivityLogsToCSV -Data $reportAccessLogs -OutputPath $CSVOutputPath
    }
    
    Write-Host "`nScript completed successfully!" -ForegroundColor Green
}
catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    exit 1
}

# Usage Examples:
<#
# Basic usage - last 7 days:
.\PowerBIActivityLogs.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret"

# Specific date range:
.\PowerBIActivityLogs.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret" -StartDate "2024-01-01" -EndDate "2024-01-07"

# Export to Excel:
.\PowerBIActivityLogs.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret" -ExportToExcel

# Export to both Excel and CSV:
.\PowerBIActivityLogs.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret" -ExportToExcel -ExportToCSV

# Custom date range with custom output path:
.\PowerBIActivityLogs.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret" -StartDate "2024-01-01" -EndDate "2024-01-31" -ExportToExcel -ExcelOutputPath "C:\Reports\PowerBI_Logs_January.xlsx"
#>
