# PowerBI Workspace Monitoring Script using Service Principal
# This script connects to Power BI API using a service principal and lists all workspaces

param(
    [Parameter(Mandatory = $true)]
    [string]$TenantId,
    
    [Parameter(Mandatory = $true)]
    [string]$ClientId,
    
    [Parameter(Mandatory = $true)]
    [string]$ClientSecret,
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportToCSV,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\PowerBI_Workspaces.csv",
    
    [Parameter(Mandatory = $false)]
    [switch]$DetailedUserReport,
    
    [Parameter(Mandatory = $false)]
    [string]$UserReportPath = ".\PowerBI_Users.csv",
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportToExcel,
    
    [Parameter(Mandatory = $false)]
    [string]$ExcelOutputPath = ".\PowerBI_Report.xlsx"
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

# Function to get Power BI workspaces
function Get-PowerBIWorkspaces {
    param(
        [string]$AccessToken
    )
    
    try {
        Write-Host "Retrieving Power BI workspaces..." -ForegroundColor Yellow
        
        # Power BI REST API endpoint for groups (workspaces)
        $apiUrl = "https://api.powerbi.com/v1.0/myorg/groups"
        
        # Headers for the API request
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }
        
        # Make the API request
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
        
        Write-Host "Successfully retrieved $($response.value.Count) workspaces!" -ForegroundColor Green
        return $response.value
    }
    catch {
        Write-Error "Failed to retrieve workspaces: $($_.Exception.Message)"
        if ($_.Exception.Response) {
            $streamReader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
            $errorResponse = $streamReader.ReadToEnd()
            Write-Error "API Error Response: $errorResponse"
        }
        throw
    }
}

# Function to get workspace users
function Get-WorkspaceUsers {
    param(
        [string]$AccessToken,
        [string]$WorkspaceId
    )
    
    try {
        # Power BI REST API endpoint for workspace users
        $apiUrl = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/users"
        
        # Headers for the API request
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }
        
        # Make the API request
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
        
        return $response.value
    }
    catch {
        # Some workspaces may not allow user enumeration, return empty array
        Write-Warning "Could not retrieve users for workspace $WorkspaceId : $($_.Exception.Message)"
        return @()
    }
}

# Function to get workspace reports
function Get-WorkspaceReports {
    param(
        [string]$AccessToken,
        [string]$WorkspaceId
    )
    
    try {
        # Power BI REST API endpoint for workspace reports
        $apiUrl = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/reports"
        
        # Headers for the API request
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }
        
        # Make the API request
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
        
        return $response.value
    }
    catch {
        # Some workspaces may not allow report enumeration, return empty array
        Write-Warning "Could not retrieve reports for workspace $WorkspaceId : $($_.Exception.Message)"
        return @()
    }
}

# Function to get report datasources and gateway info
function Get-ReportDatasources {
    param(
        [string]$AccessToken,
        [string]$WorkspaceId,
        [string]$ReportId
    )
    
    try {
        # Power BI REST API endpoint for report datasources
        $apiUrl = "https://api.powerbi.com/v1.0/myorg/groups/$WorkspaceId/reports/$ReportId/datasources"
        
        # Headers for the API request
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }
        
        # Make the API request
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
        
        return $response.value
    }
    catch {
        # Some reports may not allow datasource enumeration, return empty array
        Write-Warning "Could not retrieve datasources for report $ReportId : $($_.Exception.Message)"
        return @()
    }
}

# Function to get gateway details
function Get-GatewayDetails {
    param(
        [string]$AccessToken,
        [string]$GatewayId
    )
    
    try {
        # Power BI REST API endpoint for gateway details
        $apiUrl = "https://api.powerbi.com/v1.0/myorg/gateways/$GatewayId"
        
        # Headers for the API request
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }
        
        # Make the API request
        $response = Invoke-RestMethod -Uri $apiUrl -Headers $headers -Method Get
        
        return $response
    }
    catch {
        # Gateway may not be accessible, return null
        Write-Warning "Could not retrieve gateway details for $GatewayId : $($_.Exception.Message)"
        return $null
    }
}

# Function to get all workspaces with their users, reports, and gateway info
function Get-PowerBIWorkspacesWithUsersAndReports {
    param(
        [string]$AccessToken
    )
    
    try {
        # Get all workspaces first
        $workspaces = Get-PowerBIWorkspaces -AccessToken $AccessToken
        
        Write-Host "Retrieving users, reports, and gateway info for each workspace..." -ForegroundColor Yellow
        $workspacesWithData = @()
        
        $counter = 0
        foreach ($workspace in $workspaces) {
            $counter++
            Write-Progress -Activity "Getting workspace data" -Status "Processing workspace $($workspace.name)" -PercentComplete (($counter / $workspaces.Count) * 100)
            
            # Get users for this workspace
            $users = Get-WorkspaceUsers -AccessToken $AccessToken -WorkspaceId $workspace.id
            
            # Get reports for this workspace
            $reports = Get-WorkspaceReports -AccessToken $AccessToken -WorkspaceId $workspace.id
            
            # Get datasources and gateway info for each report
            $reportsWithGatewayInfo = @()
            foreach ($report in $reports) {
                # Get datasources for this report
                $datasources = Get-ReportDatasources -AccessToken $AccessToken -WorkspaceId $workspace.id -ReportId $report.id
                
                # Process gateway information
                $gatewayInfo = @()
                $gatewayNames = @()
                $datasourceTypes = @()
                $datasourceConnections = @()
                
                foreach ($datasource in $datasources) {
                    # Collect datasource type
                    if ($datasource.datasourceType) {
                        $datasourceTypes += $datasource.datasourceType
                    }
                    
                    # Collect datasource connection details
                    $connectionDetails = @()
                    if ($datasource.connectionDetails) {
                        # Extract server/database info
                        if ($datasource.connectionDetails.server) {
                            $connectionDetails += "Server: $($datasource.connectionDetails.server)"
                        }
                        if ($datasource.connectionDetails.database) {
                            $connectionDetails += "DB: $($datasource.connectionDetails.database)"
                        }
                        if ($datasource.connectionDetails.url) {
                            $connectionDetails += "URL: $($datasource.connectionDetails.url)"
                        }
                    }
                    
                    # If datasource has gateway information
                    if ($datasource.gatewayId) {
                        $gateway = Get-GatewayDetails -AccessToken $AccessToken -GatewayId $datasource.gatewayId
                        if ($gateway) {
                            $gatewayInfo += "$($gateway.name) (Type: $($gateway.type))"
                            $gatewayNames += $gateway.name
                            
                            # Add connection details if available
                            if ($connectionDetails.Count -gt 0) {
                                $datasourceConnections += "$($gateway.name): $($connectionDetails -join ', ')"
                            } else {
                                $datasourceConnections += "$($gateway.name): Connection details unavailable"
                            }
                        } else {
                            $gatewayInfo += "Gateway: $($datasource.gatewayId) (Details unavailable)"
                            $gatewayNames += $datasource.gatewayId
                            $datasourceConnections += "Gateway: $($datasource.gatewayId)"
                        }
                    } else {
                        # No gateway - direct cloud connection
                        if ($connectionDetails.Count -gt 0) {
                            $datasourceConnections += "Cloud: $($connectionDetails -join ', ')"
                        }
                    }
                }
                
                # Add gateway info to report object
                $report | Add-Member -MemberType NoteProperty -Name "gatewayInfo" -Value ($gatewayInfo -join "; ")
                $report | Add-Member -MemberType NoteProperty -Name "gatewayNames" -Value ($gatewayNames -join "; ")
                $report | Add-Member -MemberType NoteProperty -Name "datasourceTypes" -Value ($datasourceTypes -join "; ")
                $report | Add-Member -MemberType NoteProperty -Name "datasourcesCount" -Value $datasources.Count
                $report | Add-Member -MemberType NoteProperty -Name "datasourceConnections" -Value ($datasourceConnections -join "; ")
                
                $reportsWithGatewayInfo += $report
            }
            
            # Add users and reports with gateway info to workspace object
            $workspace | Add-Member -MemberType NoteProperty -Name "users" -Value $users
            $workspace | Add-Member -MemberType NoteProperty -Name "reports" -Value $reportsWithGatewayInfo
            $workspacesWithData += $workspace
            
            # Small delay to avoid rate limiting
            Start-Sleep -Milliseconds 300
        }
        
        Write-Progress -Activity "Getting workspace data" -Completed
        Write-Host "Successfully retrieved users, reports, and gateway info for all workspaces!" -ForegroundColor Green
        return $workspacesWithData
    }
    catch {
        Write-Error "Failed to retrieve workspaces with users, reports, and gateway info: $($_.Exception.Message)"
        throw
    }
}

# Function to format workspace information
function Format-WorkspaceInfo {
    param(
        [array]$Workspaces
    )
    
    $formattedWorkspaces = @()
    
    foreach ($workspace in $Workspaces) {
        # Format users information
        $usersList = @()
        $adminUsers = @()
        $memberUsers = @()
        $contributorUsers = @()
        $viewerUsers = @()
        
        foreach ($user in $workspace.users) {
            $userInfo = "$($user.displayName) ($($user.emailAddress)) - $($user.groupUserAccessRight)"
            $usersList += $userInfo
            
            # Categorize users by role
            switch ($user.groupUserAccessRight) {
                "Admin" { $adminUsers += "$($user.displayName) ($($user.emailAddress))" }
                "Member" { $memberUsers += "$($user.displayName) ($($user.emailAddress))" }
                "Contributor" { $contributorUsers += "$($user.displayName) ($($user.emailAddress))" }
                "Viewer" { $viewerUsers += "$($user.displayName) ($($user.emailAddress))" }
            }
        }
        
        $workspaceInfo = [PSCustomObject]@{
            Id                = $workspace.id
            Name              = $workspace.name
            Type              = $workspace.type
            State             = $workspace.state
            IsReadOnly        = $workspace.isReadOnly
            IsOnDedicatedCapacity = $workspace.isOnDedicatedCapacity
            CapacityId        = $workspace.capacityId
            Description       = $workspace.description
            TotalUsers        = $workspace.users.Count
            TotalReports      = $workspace.reports.Count
            ReportNames       = ($workspace.reports.name -join "; ")
            AdminUsers        = ($adminUsers -join "; ")
            MemberUsers       = ($memberUsers -join "; ")
            ContributorUsers  = ($contributorUsers -join "; ")
            ViewerUsers       = ($viewerUsers -join "; ")
            AllUsers          = ($usersList -join "; ")
        }
        $formattedWorkspaces += $workspaceInfo
    }
    
    return $formattedWorkspaces
}

# Function to create detailed user report
function Create-DetailedUserReport {
    param(
        [array]$Workspaces
    )
    
    $userReport = @()
    
    foreach ($workspace in $Workspaces) {
        foreach ($user in $workspace.users) {
            $userEntry = [PSCustomObject]@{
                WorkspaceId       = $workspace.id
                WorkspaceName     = $workspace.name
                WorkspaceType     = $workspace.type
                WorkspaceState    = $workspace.state
                UserDisplayName   = $user.displayName
                UserEmail         = $user.emailAddress
                UserRole          = $user.groupUserAccessRight
                UserType          = $user.principalType
                UserId            = $user.identifier
            }
            $userReport += $userEntry
        }
    }
    
    return $userReport
}

# Function to export results to CSV
function Export-WorkspacesToCSV {
    param(
        [array]$Workspaces,
        [string]$OutputPath
    )
    
    try {
        $Workspaces | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Host "Workspaces exported to: $OutputPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to export to CSV: $($_.Exception.Message)"
    }
}

# Function to create Excel format report with reports and gateway info
function Create-ExcelFormatReport {
    param(
        [array]$Workspaces
    )
    
    $excelReport = @()
    
    foreach ($workspace in $Workspaces) {
        # If workspace has users and reports, create entries for each user-report combination
        if ($workspace.users.Count -gt 0 -and $workspace.reports.Count -gt 0) {
            foreach ($user in $workspace.users) {
                foreach ($report in $workspace.reports) {
                    $excelEntry = [PSCustomObject]@{
                        Workspace           = $workspace.name
                        "AADGroup/Users"    = "$($user.displayName) ($($user.emailAddress))"
                        AccessRight         = $user.groupUserAccessRight
                        ReportName          = $report.name
                        GatewayConnection   = if ($report.gatewayInfo) { $report.gatewayInfo } else { "No gateway" }
                        DatasourceConnections = if ($report.datasourceConnections) { $report.datasourceConnections } else { "No connections" }
                        DatasourceTypes     = if ($report.datasourceTypes) { $report.datasourceTypes } else { "Unknown" }
                        DatasourcesCount    = $report.datasourcesCount
                    }
                    $excelReport += $excelEntry
                }
            }
        }
        # If workspace has users but no reports
        elseif ($workspace.users.Count -gt 0 -and $workspace.reports.Count -eq 0) {
            foreach ($user in $workspace.users) {
                $excelEntry = [PSCustomObject]@{
                    Workspace           = $workspace.name
                    "AADGroup/Users"    = "$($user.displayName) ($($user.emailAddress))"
                    AccessRight         = $user.groupUserAccessRight
                    ReportName          = "No reports"
                    GatewayConnection   = "N/A"
                    DatasourceConnections = "N/A"
                    DatasourceTypes     = "N/A"
                    DatasourcesCount    = 0
                }
                $excelReport += $excelEntry
            }
        }
        # If workspace has reports but no users
        elseif ($workspace.users.Count -eq 0 -and $workspace.reports.Count -gt 0) {
            foreach ($report in $workspace.reports) {
                $excelEntry = [PSCustomObject]@{
                    Workspace           = $workspace.name
                    "AADGroup/Users"    = "No users assigned"
                    AccessRight         = "N/A"
                    ReportName          = $report.name
                    GatewayConnection   = if ($report.gatewayInfo) { $report.gatewayInfo } else { "No gateway" }
                    DatasourceConnections = if ($report.datasourceConnections) { $report.datasourceConnections } else { "No connections" }
                    DatasourceTypes     = if ($report.datasourceTypes) { $report.datasourceTypes } else { "Unknown" }
                    DatasourcesCount    = $report.datasourcesCount
                }
                $excelReport += $excelEntry
            }
        }
        # If workspace has neither users nor reports
        else {
            $excelEntry = [PSCustomObject]@{
                Workspace           = $workspace.name
                "AADGroup/Users"    = "No users assigned"
                AccessRight         = "N/A"
                ReportName          = "No reports"
                GatewayConnection   = "N/A"
                DatasourceConnections = "N/A"
                DatasourceTypes     = "N/A"
                DatasourcesCount    = 0
            }
            $excelReport += $excelEntry
        }
    }
    
    return $excelReport
}

# Function to export to Excel
function Export-ToExcel {
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
        $Data | Export-Excel -Path $OutputPath -AutoSize -BoldTopRow -FreezeTopRow -TableStyle Medium2 -WorksheetName "PowerBI_Reports_Gateways"
        
        # Get and display the full path
        $fullPath = Resolve-Path -Path $OutputPath
        Write-Host "Excel report exported to: $OutputPath" -ForegroundColor Green
        Write-Host "Full path: $($fullPath.Path)" -ForegroundColor Cyan
        Write-Host "Report contains $($Data.Count) user-workspace-report-gateway assignments" -ForegroundColor Green
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

# Function to export detailed user report to CSV
function Export-UserReportToCSV {
    param(
        [array]$UserReport,
        [string]$OutputPath
    )
    
    try {
        $UserReport | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
        Write-Host "User report exported to: $OutputPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to export user report to CSV: $($_.Exception.Message)"
    }
}

# Main script execution
try {
    Write-Host "Starting Power BI Workspace Monitoring Script..." -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    
    # Validate parameters
    if ([string]::IsNullOrWhiteSpace($TenantId) -or 
        [string]::IsNullOrWhiteSpace($ClientId) -or 
        [string]::IsNullOrWhiteSpace($ClientSecret)) {
        throw "TenantId, ClientId, and ClientSecret are required parameters."
    }
    
    # Get access token
    $accessToken = Get-PowerBIAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
    
    # Get workspaces with users and reports
    $workspaces = Get-PowerBIWorkspacesWithUsersAndReports -AccessToken $accessToken
    
    # Format workspace information
    $formattedWorkspaces = Format-WorkspaceInfo -Workspaces $workspaces
    
    # Display results
    Write-Host "`nWorkspace Summary:" -ForegroundColor Cyan
    Write-Host "==================" -ForegroundColor Cyan
    $formattedWorkspaces | Format-Table Id, Name, Type, State, TotalUsers, TotalReports, AdminUsers -AutoSize
    
    # Display detailed user information
    Write-Host "`nDetailed Workspace Information:" -ForegroundColor Cyan
    Write-Host "===============================" -ForegroundColor Cyan
    foreach ($workspace in $formattedWorkspaces) {
        Write-Host "`nWorkspace: $($workspace.Name)" -ForegroundColor Yellow
        Write-Host "  ID: $($workspace.Id)"
        Write-Host "  Type: $($workspace.Type)"
        Write-Host "  State: $($workspace.State)"
        Write-Host "  Total Users: $($workspace.TotalUsers)"
        Write-Host "  Total Reports: $($workspace.TotalReports)"
        
        if ($workspace.ReportNames) {
            Write-Host "  Reports: $($workspace.ReportNames)" -ForegroundColor Magenta
        }
        
        # Show gateway information for reports
        if ($workspace.reports) {
            $reportsWithGateways = $workspace.reports | Where-Object { $_.gatewayInfo -and $_.gatewayInfo -ne "" }
            if ($reportsWithGateways) {
                Write-Host "  Gateway Connections:" -ForegroundColor Cyan
                foreach ($report in $reportsWithGateways) {
                    Write-Host "    $($report.name): $($report.gatewayInfo)" -ForegroundColor DarkCyan
                }
            }
        }
        
        if ($workspace.AdminUsers) {
            Write-Host "  Admins: $($workspace.AdminUsers)" -ForegroundColor Red
        }
        if ($workspace.MemberUsers) {
            Write-Host "  Members: $($workspace.MemberUsers)" -ForegroundColor Green
        }
        if ($workspace.ContributorUsers) {
            Write-Host "  Contributors: $($workspace.ContributorUsers)" -ForegroundColor Blue
        }
        if ($workspace.ViewerUsers) {
            Write-Host "  Viewers: $($workspace.ViewerUsers)" -ForegroundColor Gray
        }
    }
    
    # Create detailed user report if requested
    $userReport = $null
    if ($DetailedUserReport) {
        $userReport = Create-DetailedUserReport -Workspaces $workspaces
        
        Write-Host "`nDetailed User Report:" -ForegroundColor Cyan
        Write-Host "====================" -ForegroundColor Cyan
        $userReport | Format-Table WorkspaceName, UserDisplayName, UserEmail, UserRole -AutoSize
    }
    
    # Export to CSV if requested
    if ($ExportToCSV) {
        Export-WorkspacesToCSV -Workspaces $formattedWorkspaces -OutputPath $OutputPath
    }
    
    # Export user report to CSV if requested
    if ($DetailedUserReport -and $userReport) {
        Export-UserReportToCSV -UserReport $userReport -OutputPath $UserReportPath
    }
    
    # Export to Excel if requested
    if ($ExportToExcel) {
        Write-Host "`nCreating Excel report..." -ForegroundColor Yellow
        $excelData = Create-ExcelFormatReport -Workspaces $workspaces
        
        Write-Host "Excel data prepared with $($excelData.Count) entries" -ForegroundColor Yellow
        Export-ToExcel -Data $excelData -OutputPath $ExcelOutputPath
        
        Write-Host "`nExcel Report Summary:" -ForegroundColor Cyan
        Write-Host "Total entries: $($excelData.Count)" -ForegroundColor Green
        
        # Show summary by access rights
        $accessRightSummary = $excelData | Where-Object { $_."AADGroup/Users" -ne "No users assigned" } | Group-Object AccessRight | Sort-Object Name
        foreach ($group in $accessRightSummary) {
            Write-Host "$($group.Name): $($group.Count) user-report assignments" -ForegroundColor White
        }
        
        # Show summary by reports
        $reportSummary = $excelData | Where-Object { $_.ReportName -ne "No reports" } | Group-Object ReportName | Sort-Object Count -Descending | Select-Object -First 10
        if ($reportSummary.Count -gt 0) {
            Write-Host "`nTop 10 Reports by User Access:" -ForegroundColor Cyan
            foreach ($report in $reportSummary) {
                Write-Host "$($report.Name): $($report.Count) user assignments" -ForegroundColor White
            }
        }
        
        # Show gateway usage summary
        $gatewayReports = $excelData | Where-Object { $_.GatewayConnection -ne "No gateway" -and $_.GatewayConnection -ne "N/A" }
        if ($gatewayReports.Count -gt 0) {
            Write-Host "`nGateway Usage Summary:" -ForegroundColor Cyan
            $gatewaySummary = $gatewayReports | Group-Object GatewayConnection | Sort-Object Count -Descending
            foreach ($gateway in $gatewaySummary) {
                Write-Host "$($gateway.Name): $($gateway.Count) report assignments" -ForegroundColor White
            }
        }
        
        # Show datasource types summary
        $datasourceReports = $excelData | Where-Object { $_.DatasourceTypes -ne "Unknown" -and $_.DatasourceTypes -ne "N/A" }
        if ($datasourceReports.Count -gt 0) {
            Write-Host "`nDatasource Types Summary:" -ForegroundColor Cyan
            $datasourceSummary = $datasourceReports | ForEach-Object { $_.DatasourceTypes.Split(';') | ForEach-Object { $_.Trim() } } | Group-Object | Sort-Object Count -Descending
            foreach ($datasource in $datasourceSummary) {
                Write-Host "$($datasource.Name): $($datasource.Count) occurrences" -ForegroundColor White
            }
        }
    } else {
        Write-Host "`nNote: Use -ExportToExcel parameter to export data to Excel format" -ForegroundColor Yellow
    }
    
    Write-Host "`nScript completed successfully!" -ForegroundColor Green
    Write-Host "Total workspaces found: $($formattedWorkspaces.Count)" -ForegroundColor Green
}
catch {
    Write-Error "Script execution failed: $($_.Exception.Message)"
    exit 1
}

# Usage Examples:
<#
# Basic usage with users, reports, and gateway info:
.\PowerBIMonitoring.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret"

# Export workspace summary to CSV:
.\PowerBIMonitoring.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret" -ExportToCSV

# Export to Excel with gateway mapping (Workspace, AADGroup/Users, AccessRight, ReportName, GatewayConnection):
.\PowerBIMonitoring.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret" -ExportToExcel

# Generate detailed user report:
.\PowerBIMonitoring.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret" -DetailedUserReport

# Export both CSV and Excel reports:
.\PowerBIMonitoring.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret" -ExportToCSV -ExportToExcel

# Custom output paths:
.\PowerBIMonitoring.ps1 -TenantId "your-tenant-id" -ClientId "your-client-id" -ClientSecret "your-client-secret" -ExportToExcel -ExcelOutputPath "C:\Reports\PowerBI_Gateway_Report.xlsx"
#>
