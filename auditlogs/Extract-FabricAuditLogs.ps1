# WARNING: This script is not licensed or endorsed by any person or organization.
# Use it with caution and at your own risk.

<#
.SYNOPSIS
    Extracts Microsoft Fabric / Power BI unified audit logs from the Office 365
    Management Activity API and writes per-Administrative-Unit CSV files to each
    agency's shared drive, ready for Power BI consumption.

.DESCRIPTION
    Single-file, app-only (client id + secret) extractor. No Exchange module,
    no certificate, no interactive sign-in.

    Flow:
      1. Acquire app-only tokens (Management API + Microsoft Graph).
      2. Ensure a subscription is started for every feed in audit.contentTypes.
      3. Pull all content blobs since the last watermark and keep the records
         matching audit.workloads / audit.recordTypes.
      4. Append them to a central daily raw store (de-duplicated by record Id).
      5. Resolve each Administrative Unit's members via Graph and, for every AU
         that is due today (Daily / Weekly / Monthly), write a CSV covering that
         AU's period into the agency's configured share, plus a trigger file so
         Power BI can refresh as soon as the file lands.

    The 'audit' config block sets what is collected. Omit it for the shipped
    Fabric / Power BI scope:
      contentTypes : Audit.General | Audit.AzureActiveDirectory | Audit.Exchange
                     | Audit.SharePoint | DLP.All        (default: Audit.General)
      workloads    : Workload values to keep    (default: PowerBI, Fabric, OneLake,
                                                 MicrosoftFabric)
      recordTypes  : RecordType ids to keep     (default: 20, 261, 262, 357)
    A record is kept when it matches workloads OR recordTypes. Setting both to []
    disables filtering and stores every record in the subscribed feeds.

    'schedule' sets the cadence; the optional per-AU 'periodMode' sets the window:
      Weekly  : PreviousWeek (default) | WeekToDate | Last7Days | Last7DaysExcludingToday
      Monthly : PreviousMonth (default) | MonthToDate | Last30Days | Last30DaysExcludingToday
      any     : RollingDays, sized by 'rollingDays' / 'rollingIncludesToday'
    Leaving Weekly and Monthly AUs on their defaults keeps their windows disjoint;
    pairing e.g. WeekToDate with MonthToDate makes the weekly file a subset of the
    monthly one by design.

.REQUIRED APP PERMISSIONS (application, admin-consented — least privilege)
    Office 365 Management APIs : ActivityFeed.Read
    Microsoft Graph            : AdministrativeUnit.Read.All
                                 User.Read.All          (REQUIRED - without it Graph returns AU
                                                         members with no userPrincipalName and
                                                         every record lands in Unassigned)
                                 GroupMember.Read.All   (only if AUs contain groups)
    No Azure RBAC role and no Exchange/Entra directory role is required.

.EXAMPLE
    $env:FABRIC_AUDIT_CLIENT_SECRET = '<secret>'
    .\Extract-FabricAuditLogs.ps1 -ConfigPath .\config.json

.EXAMPLE
    # Backfill a specific window and ignore the saved watermark
    .\Extract-FabricAuditLogs.ps1 -StartUtc '2026-08-01' -EndUtc '2026-08-08' -Force

.EXAMPLE
    # Validation run - exports cover the last COMPLETED period (Daily = yesterday),
    # so a first run often writes nothing. -IncludeToday extends it to today.
    .\Extract-FabricAuditLogs.ps1 -Force -IncludeToday

.EXAMPLE
    # Re-export one agency from the existing raw store. Other AUs are left alone,
    # keeping their recorded export state untouched.
    .\Extract-FabricAuditLogs.ps1 -AdministrativeUnit SolnArc -Force

.EXAMPLE
    # Register the daily automation (runs 02:00, covers all schedules)
    .\Extract-FabricAuditLogs.ps1 -RegisterScheduledTask -RunTime 02:00
#>
[CmdletBinding()]
param(
    [string]   $ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [datetime] $StartUtc,
    [datetime] $EndUtc,
    [string[]] $AdministrativeUnit,    # restrict exports to these config names; default = all
    [switch]   $Force,                 # ignore watermark / schedule gating
    [switch]   $WhatIfExport,          # do everything except write agency CSVs
    [switch]   $IncludeToday,         # extend the period to today for AUs with no periodMode
    [switch]   $DiagnoseAu,            # probe AU membership via Graph, then exit
    [switch]   $RegisterScheduledTask,
    [string]   $RunTime = '02:00'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- logging ---
$script:LogFile = $null
function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO')
    $line = '{0}  {1,-5}  {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 } catch { }
    }
}

function New-Folder { param([string]$Path) if ($Path -and -not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null } }

# Safe property access - Graph omits properties the app has no permission to read.
function Get-Prop { param($Obj, [string]$Name) if ($null -eq $Obj) { return $null }; if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] } return $null }; $p = $Obj.PSObject.Properties[$Name]; if ($p) { $p.Value } else { $null } }

# ------------------------------------------------------------ period modes ---
# 'schedule' says how often an AU is exported; 'periodMode' says which window that
# export covers. Named aliases exist so config.json can state the intent literally
# ("Last7Days") rather than encode it as a mode plus two flags.
#   Applies      Alias                       Window (today = T)
#   Weekly       PreviousWeek*               last complete week, per weekStartsOn
#   Weekly       WeekToDate                  current week start .. T
#   Weekly       Last7Days                   T-6 .. T
#   Weekly       Last7DaysExcludingToday     T-7 .. T-1
#   Monthly      PreviousMonth*              1st .. last of the previous month
#   Monthly      MonthToDate                 1st of this month .. T
#   Monthly      Last30Days                  T-29 .. T
#   Monthly      Last30DaysExcludingToday    T-30 .. T-1
#   any          RollingDays                 N days from rollingDays / rollingIncludesToday
#   (* PreviousPeriod / PeriodToDate are the schedule-agnostic spellings.)
$script:PeriodModes = [ordered]@{
    'PreviousPeriod'           = @{ Kind = 'PreviousPeriod' }
    'PreviousWeek'             = @{ Kind = 'PreviousPeriod'; Schedule = 'Weekly' }
    'PreviousMonth'            = @{ Kind = 'PreviousPeriod'; Schedule = 'Monthly' }
    'PeriodToDate'             = @{ Kind = 'PeriodToDate' }
    'WeekToDate'               = @{ Kind = 'PeriodToDate';  Schedule = 'Weekly' }
    'MonthToDate'              = @{ Kind = 'PeriodToDate';  Schedule = 'Monthly' }
    'RollingDays'              = @{ Kind = 'RollingDays' }
    'Last7Days'                = @{ Kind = 'RollingDays'; Schedule = 'Weekly';  Days = 7;  IncludesToday = $true }
    'Last7DaysExcludingToday'  = @{ Kind = 'RollingDays'; Schedule = 'Weekly';  Days = 7;  IncludesToday = $false }
    'Last30Days'               = @{ Kind = 'RollingDays'; Schedule = 'Monthly'; Days = 30; IncludesToday = $true }
    'Last30DaysExcludingToday' = @{ Kind = 'RollingDays'; Schedule = 'Monthly'; Days = 30; IncludesToday = $false }
}
# Resolved once per AU and reused by validation, window calculation, and logging, so a
# bad periodMode fails at startup rather than after the API pull.
function Resolve-PeriodMode {
    param($Au, [string]$Schedule)
    $raw = [string](Get-Prop $Au 'periodMode')
    $explicit = [bool]$raw
    if (-not $explicit) { $raw = 'PreviousPeriod' }

    $name = @($script:PeriodModes.Keys | Where-Object { $_ -eq $raw }) | Select-Object -First 1
    if (-not $name) {
        throw "AU '$($Au.name)': unknown periodMode '$raw'. Valid values: $($script:PeriodModes.Keys -join ', ')."
    }
    $spec = $script:PeriodModes[$name]

    # A week-shaped alias on a Monthly AU (or the reverse) is always a config mistake.
    if ($spec.ContainsKey('Schedule') -and $Schedule -in 'Weekly', 'Monthly' -and $spec.Schedule -ne $Schedule) {
        throw "AU '$($Au.name)': periodMode '$name' describes a $($spec.Schedule) window but schedule is '$Schedule'."
    }

    $days = if ($spec.ContainsKey('Days')) { [int]$spec.Days } else { switch ($Schedule) { 'Monthly' { 30 } 'Weekly' { 7 } default { 1 } } }
    $incl = if ($spec.ContainsKey('IncludesToday')) { [bool]$spec.IncludesToday } else { $true }
    # rollingDays / rollingIncludesToday tune the generic mode only - honouring them for
    # Last7Days would let config contradict the name it just chose.
    if ($name -eq 'RollingDays') {
        $n = Get-Prop $Au 'rollingDays'
        if ($null -ne $n -and "$n" -ne '') {
            $days = [int]$n
            if ($days -lt 1) { throw "AU '$($Au.name)': rollingDays must be 1 or greater, got '$n'." }
        }
        $i = Get-Prop $Au 'rollingIncludesToday'
        if ($null -ne $i) { $incl = [bool]$i }
    }
    @{ Name = $name; Kind = $spec.Kind; Days = $days; IncludesToday = $incl; Explicit = $explicit }
}

# ------------------------------------------------- scheduled task bootstrap ---
if ($RegisterScheduledTask) {
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $PSCommandPath, $ConfigPath)
    $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Parse($RunTime))
    $set     = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
        -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)
    Register-ScheduledTask -TaskName 'FabricAuditExtract' -Action $action -Trigger $trigger `
        -Settings $set -Description 'Daily Fabric/Power BI unified audit log extract by Administrative Unit' -Force | Out-Null
    Write-Host "Registered scheduled task 'FabricAuditExtract' at $RunTime daily." -ForegroundColor Green
    Write-Host "Set the secret for the task account: setx FABRIC_AUDIT_CLIENT_SECRET <secret> /M" -ForegroundColor Yellow
    return
}

# ----------------------------------------------------------------- config ---
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
$cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

foreach ($k in 'tenantId', 'clientId', 'clientSecretEnvVar', 'centralPath', 'stateFile', 'administrativeUnits') {
    if (-not ($cfg.PSObject.Properties.Name -contains $k)) { throw "config.json is missing required key '$k'." }
}

# AU selection narrows only the export stage. Membership resolution always covers every
# enabled AU, otherwise unselected agencies' records would be written to the shared raw
# store tagged 'Unassigned'.
$script:AuFilter = $null
if ($AdministrativeUnit) {
    $known   = @($cfg.administrativeUnits | ForEach-Object { [string]$_.name })
    $unknown = @($AdministrativeUnit | Where-Object { $known -notcontains $_ })
    if ($unknown.Count) {
        throw "Unknown administrative unit name(s): $($unknown -join ', '). Configured names: $($known -join ', ')."
    }
    $script:AuFilter = @($AdministrativeUnit)
}
function Test-AuSelected { param($Au) (-not $script:AuFilter) -or ($script:AuFilter -contains [string]$Au.name) }

# Caught here rather than in Get-Period, where an unrecognised value would silently
# fall through to the Daily branch.
foreach ($a in @($cfg.administrativeUnits)) {
    $m = if ($a.PSObject.Properties.Name -contains 'schedule' -and $a.schedule) { [string]$a.schedule } else { 'Daily' }
    if ($m -notin 'Daily', 'Weekly', 'Monthly', 'Custom') {
        throw "AU '$($a.name)': unknown schedule '$m'. Valid values: Daily, Weekly, Monthly, Custom."
    }
    $pm = [string](Get-Prop $a 'periodMode')
    if ($m -eq 'Custom' -and $pm) {
        throw "AU '$($a.name)': schedule 'Custom' exports periodStart..periodEnd verbatim - remove periodMode '$pm'."
    }
    if ($m -ne 'Custom') { Resolve-PeriodMode -Au $a -Schedule $m | Out-Null }
    $ws = [string](Get-Prop $a 'weekStartsOn')
    if ($ws) {
        $dowRef = [DayOfWeek]::Monday
        if (-not [enum]::TryParse([DayOfWeek], $ws, $true, [ref]$dowRef)) {
            throw "AU '$($a.name)': weekStartsOn '$ws' is not a day name (Sunday..Saturday)."
        }
    }
}

$secret = [Environment]::GetEnvironmentVariable($cfg.clientSecretEnvVar, 'Process')
if (-not $secret) { $secret = [Environment]::GetEnvironmentVariable($cfg.clientSecretEnvVar, 'User') }
if (-not $secret) { $secret = [Environment]::GetEnvironmentVariable($cfg.clientSecretEnvVar, 'Machine') }
if (-not $secret) { throw "Client secret not found in environment variable '$($cfg.clientSecretEnvVar)'." }

$lookbackHours  = if ($cfg.PSObject.Properties.Name -contains 'lookbackHours')   { [int]$cfg.lookbackHours }   else { 26 }
$retentionDays  = if ($cfg.PSObject.Properties.Name -contains 'retentionDays')   { [int]$cfg.retentionDays }   else { 400 }
$inclUnassigned = if ($cfg.PSObject.Properties.Name -contains 'includeUnassigned') { [bool]$cfg.includeUnassigned } else { $true }
$skipEmpty      = if ($cfg.PSObject.Properties.Name -contains 'skipEmptyExports')  { [bool]$cfg.skipEmptyExports }  else { $true }
# Exports normally cover the last COMPLETED period. Set includeCurrentDay (or pass
# -IncludeToday) to extend the window to the partial current day. Ignored for any AU
# that declares its own periodMode.
$inclToday      = $IncludeToday.IsPresent -or ($(if ($cfg.PSObject.Properties.Name -contains 'includeCurrentDay') { [bool]$cfg.includeCurrentDay } else { $false }))

# ------------------------------------------------------------ audit scope ---
# Which Management Activity API feeds to subscribe to, and which of their records to
# keep. Defaults reproduce the Fabric / Power BI scope this script shipped with, so a
# config.json without an 'audit' block behaves exactly as before.
$auditCfg = if ($cfg.PSObject.Properties.Name -contains 'audit') { $cfg.audit } else { $null }
function Get-AuditList {
    param([string]$Name, [string[]]$Default)
    if (-not $auditCfg) { return $Default }
    # Presence is tested on the property, not the value: ConvertFrom-Json turns an
    # explicit [] into an empty array that a bare return would unroll to $null, which
    # would silently reinstate the defaults the empty list was meant to clear.
    if ($auditCfg.PSObject.Properties.Name -notcontains $Name) { return $Default }
    $v = $auditCfg.$Name
    if ($null -eq $v) { return $Default }
    , @(@($v) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}
$ValidContentTypes = @('Audit.General', 'Audit.AzureActiveDirectory', 'Audit.Exchange', 'Audit.SharePoint', 'DLP.All')
$contentTypes = Get-AuditList 'contentTypes' @('Audit.General')
if (-not $contentTypes) { throw "audit.contentTypes must list at least one feed. Valid values: $($ValidContentTypes -join ', ')." }
foreach ($ct in $contentTypes) {
    if ($ValidContentTypes -notcontains $ct) {
        throw "audit.contentTypes: '$ct' is not a Management Activity API feed. Valid values: $($ValidContentTypes -join ', ')."
    }
}

# A record is kept when its Workload OR its RecordType is listed. Both lists empty
# means no filter at all - every record in the subscribed feeds is kept, which is
# orders of magnitude more data, so it is called out in the log.
# https://learn.microsoft.com/en-us/office/office-365-management-api/office-365-management-activity-api-schema
$auditWorkloads   = Get-AuditList 'workloads'   @('PowerBI', 'Fabric', 'DataGovernance', 'SensitiveInfoDiscovered', 'AuditSearch', 'DataSecurityInvestigation', 'OneLake', 'MicrosoftFabric', 'TrainableClassifier', 'DataScanClassification', 'P4AIAssessmentFabricScannerRecord', 'PowerBIAudit')
$auditRecordTypes = Get-AuditList 'recordTypes' @('20', '261', '38', '291', '295', '333', '357', '358', '361', '385')   # PowerBIAudit, PowerBIDlp, PowerBIMetadata, FabricAudit
$wlFilter = @{}; foreach ($w in $auditWorkloads)   { $wlFilter[$w] = $true }
$rtFilter = @{}; foreach ($r in $auditRecordTypes) { $rtFilter[$r] = $true }
$filterOff = ($wlFilter.Count -eq 0 -and $rtFilter.Count -eq 0)

$rawPath = Join-Path $cfg.centralPath 'Raw'
New-Folder $cfg.centralPath; New-Folder $rawPath
New-Folder (Split-Path -Parent $cfg.stateFile)
if ($cfg.PSObject.Properties.Name -contains 'logFile' -and $cfg.logFile) {
    New-Folder (Split-Path -Parent $cfg.logFile); $script:LogFile = $cfg.logFile
}

Write-Log "=== Fabric audit extract started ===" 'OK'
Write-Log "Tenant $($cfg.tenantId) | client $($cfg.clientId) | config $ConfigPath"
Write-Log "Feeds: $($contentTypes -join ', ')"
if ($filterOff) {
    Write-Log 'Record filter is OFF (audit.workloads and audit.recordTypes are both empty) - every record in these feeds will be stored.' 'WARN'
}
else {
    Write-Log ("Keeping workloads [{0}] or recordTypes [{1}]" -f ($auditWorkloads -join ', '), ($auditRecordTypes -join ', '))
}

# ------------------------------------------------------------------ auth ---
$script:Tokens = @{}
function Get-AppToken {
    param([Parameter(Mandatory)][string]$Resource)   # e.g. https://graph.microsoft.com
    $now = Get-Date
    if ($script:Tokens.ContainsKey($Resource) -and $script:Tokens[$Resource].Expires -gt $now.AddMinutes(5)) {
        return $script:Tokens[$Resource].Token
    }
    $body = @{
        client_id     = $cfg.clientId
        client_secret = $secret
        scope         = "$Resource/.default"
        grant_type    = 'client_credentials'
    }
    $uri = "https://login.microsoftonline.com/$($cfg.tenantId)/oauth2/v2.0/token"
    $r = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded'
    $script:Tokens[$Resource] = @{ Token = $r.access_token; Expires = $now.AddSeconds([int]$r.expires_in) }
    Write-Log "Token acquired for $Resource"
    return $r.access_token
}

function Invoke-Api {
    <# Resilient REST call with throttling/retry. Returns @{ Content; Headers } #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Resource,
        $Body,
        [int]$MaxRetries = 5
    )
    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $headers = @{ Authorization = "Bearer $(Get-AppToken -Resource $Resource)"; Accept = 'application/json' }
            $p = @{ Uri = $Uri; Method = $Method; Headers = $headers; UseBasicParsing = $true; TimeoutSec = 300 }
            if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 10); $p.ContentType = 'application/json' }
            $resp = Invoke-WebRequest @p
            $content = if ($resp.Content) { $resp.Content | ConvertFrom-Json } else { $null }
            return @{ Content = $content; Headers = $resp.Headers }
        }
        catch {
            $status = -1
            if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) {
                try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            }
            # AF20024 = subscription already enabled; treat as success upstream
            if ($status -in 429, 500, 502, 503, 504 -and $attempt -lt $MaxRetries) {
                $wait = [math]::Pow(2, $attempt) * 2
                Write-Log "HTTP $status on $Uri - retry $attempt/$MaxRetries in ${wait}s" 'WARN'
                Start-Sleep -Seconds $wait; continue
            }
            throw
        }
    }
}

$MgmtRes  = 'https://manage.office.com'
$GraphRes = 'https://graph.microsoft.com'
$MgmtBase = "$MgmtRes/api/v1.0/$($cfg.tenantId)/activity/feed"

# ------------------------------------------------------- AU diagnostics ---
if ($DiagnoseAu) {
    Write-Log '=== Administrative Unit diagnostics ===' 'OK'
    foreach ($au in @($cfg.administrativeUnits | Where-Object { $_.enabled } | Where-Object { Test-AuSelected $_ })) {
        Write-Host ''
        Write-Host "AU: $($au.name)  [$($au.auId)]" -ForegroundColor Cyan

        try {
            $meta = (Invoke-Api -Uri "$GraphRes/v1.0/directory/administrativeUnits/$($au.auId)" -Resource $GraphRes).Content
            Write-Host "  Exists in directory as: '$($meta.displayName)'" -ForegroundColor Green
            if ($meta.displayName -ne $au.name) {
                Write-Host "  NOTE: config name differs from directory name. Only auId is used for lookup, so this is cosmetic." -ForegroundColor Yellow
            }
        }
        catch { Write-Host "  CANNOT READ AU: $($_.Exception.Message)" -ForegroundColor Red; continue }

        foreach ($probe in @(
            @{ Label = 'members (untyped)';  Uri = "$GraphRes/v1.0/directory/administrativeUnits/$($au.auId)/members?`$top=999" }
            @{ Label = 'members/user cast';  Uri = "$GraphRes/v1.0/directory/administrativeUnits/$($au.auId)/members/microsoft.graph.user?`$top=999" }
            @{ Label = 'members/group cast'; Uri = "$GraphRes/v1.0/directory/administrativeUnits/$($au.auId)/members/microsoft.graph.group?`$top=999" }
        )) {
            try {
                $r = (Invoke-Api -Uri $probe.Uri -Resource $GraphRes).Content
                $v = @($r.value)
                Write-Host ("  {0,-20} -> {1} object(s)" -f $probe.Label, $v.Count) -ForegroundColor $(if ($v.Count) { 'Green' } else { 'Yellow' })
                foreach ($m in $v | Select-Object -First 10) {
                    $lbl = @((Get-Prop $m 'userPrincipalName'), (Get-Prop $m 'displayName'), (Get-Prop $m 'id') | Where-Object { $_ })
                    $lbl = if ($lbl.Count) { $lbl[0] } else { '(no readable property)' }
                    Write-Host ("      {0,-45} type={1} upn={2}" -f $lbl,
                        ([string](Get-Prop $m '@odata.type') -replace '#microsoft.graph.', ''),
                        $(if (Get-Prop $m 'userPrincipalName') { 'yes' } else { 'MISSING' }))
                }
            }
            catch { Write-Host ("  {0,-20} -> ERROR {1}" -f $probe.Label, $_.Exception.Message) -ForegroundColor Red }
        }
    }
    Write-Host ''
    Write-Log 'Diagnostics complete. If every probe shows 0 objects but the portal shows members, the app is missing AdministrativeUnit.Read.All as an APPLICATION permission (delegated will not work) or admin consent was never granted.' 'WARN'
    return
}

# ------------------------------------------------- ensure subscription on ---
foreach ($ct in $contentTypes) {
    try {
        Invoke-Api -Uri "$MgmtBase/subscriptions/start?contentType=$ct" -Method POST -Resource $MgmtRes -Body @{} | Out-Null
        Write-Log "$ct subscription started." 'OK'
    }
    catch {
        if ("$_" -match 'AF20024|already enabled') { Write-Log "$ct subscription already active." }
        else { throw "Failed to start the $ct subscription. Verify ActivityFeed.Read app permission + admin consent. $_" }
    }
}

# ------------------------------------------------------ resolve the window ---
$state = @{ lastRunUtc = $null }
if (Test-Path -LiteralPath $cfg.stateFile) {
    try { $state = Get-Content -LiteralPath $cfg.stateFile -Raw | ConvertFrom-Json } catch { Write-Log 'State file unreadable - starting from lookback.' 'WARN' }
}

$nowUtc = (Get-Date).ToUniversalTime()
if ($EndUtc)   { $winEnd = $EndUtc.ToUniversalTime() }   else { $winEnd = $nowUtc }
if ($StartUtc) { $winStart = $StartUtc.ToUniversalTime() }
elseif (-not $Force -and $state.PSObject.Properties.Name -contains 'lastRunUtc' -and $state.lastRunUtc) {
    $winStart = ([datetime]$state.lastRunUtc).ToUniversalTime().AddMinutes(-10)   # small overlap; dedupe handles it
}
else { $winStart = $winEnd.AddHours(-$lookbackHours) }

if ($winStart -lt $nowUtc.AddDays(-7)) {
    Write-Log 'Window start older than 7 days (API limit) - clamping.' 'WARN'
    $winStart = $nowUtc.AddDays(-7)
}
Write-Log ("Window UTC {0:yyyy-MM-dd HH:mm} -> {1:yyyy-MM-dd HH:mm}" -f $winStart, $winEnd)

# Without this an inverted window skips the fetch loop entirely and reports
# 'Fetched 0 records', which reads as 'no tenant activity' rather than a bad argument.
if ($winEnd -le $winStart) {
    throw ("Window end {0:yyyy-MM-dd HH:mm} is not after window start {1:yyyy-MM-dd HH:mm}. Check -StartUtc / -EndUtc." -f $winEnd, $winStart)
}

# ------------------------------------------------------- fetch audit blobs ---
$records = New-Object System.Collections.Generic.List[object]

foreach ($ct in $contentTypes) {
    # API caps each list request at a 24h span
    $cursor = $winStart
    while ($cursor -lt $winEnd) {
        $sliceEnd = $cursor.AddHours(24)
        if ($sliceEnd -gt $winEnd) { $sliceEnd = $winEnd }

        $uri = "$MgmtBase/subscriptions/content?contentType=$ct" +
               "&startTime=$($cursor.ToString('yyyy-MM-ddTHH:mm:ss'))" +
               "&endTime=$($sliceEnd.ToString('yyyy-MM-ddTHH:mm:ss'))"

        $blobCount = 0
        while ($uri) {
            $page = Invoke-Api -Uri $uri -Resource $MgmtRes
            foreach ($blob in @($page.Content)) {
                if (-not $blob.contentUri) { continue }
                $blobCount++
                $data = (Invoke-Api -Uri $blob.contentUri -Resource $MgmtRes).Content
                foreach ($rec in @($data)) {
                    $wl = if ($rec.PSObject.Properties.Name -contains 'Workload') { [string]$rec.Workload } else { '' }
                    $rt = if ($rec.PSObject.Properties.Name -contains 'RecordType') { [string]$rec.RecordType } else { '' }
                    if ($filterOff -or ($wl -and $wlFilter.ContainsKey($wl)) -or ($rt -and $rtFilter.ContainsKey($rt))) {
                        $records.Add($rec)
                    }
                }
                Start-Sleep -Milliseconds 120
            }
            $next = $null
            if ($page.Headers.ContainsKey('NextPageUri')) { $next = @($page.Headers['NextPageUri'])[0] }
            $uri = $next
        }
        Write-Log ("{0} slice {1:MM-dd HH:mm} : {2} blobs, running total {3} matching records" -f $ct, $cursor, $blobCount, $records.Count)
        $cursor = $sliceEnd
    }
}
Write-Log "Fetched $($records.Count) matching audit records." 'OK'

# ------------------------------------------------------- flatten to a row ---
$Columns = @(
    'Id','CreationTimeUtc','Date','Hour','Operation','RecordType','Workload','Activity',
    'UserId','UserType','UserKey','UserAgent','ClientIP','ClientIPCountry',
    'AdministrativeUnit','AuId','Department','JobTitle','DisplayName','IsGuest','IsServicePrincipal',
    'WorkspaceId','WorkspaceName','CapacityId','CapacityName',
    'ObjectId','ItemName','ArtifactId','ArtifactName','ArtifactKind',
    'DatasetId','DatasetName','ReportId','ReportName','ReportType',
    'DashboardId','DashboardName','DataflowId','DataflowName',
    'FolderObjectId','FolderDisplayName','AppId','AppName',
    'GatewayId','GatewayName','DatasourceId',
    'SharingAction','SharingScope','SharingRecipients','DistributionMethod','ConsumptionMethod',
    'SensitivityLabelId','SwitchState','RefreshType','ImportSource','ImportType',
    'IsSuccess','ResultStatus','ErrorMessage','RequestId','ActivityId','OrganizationId',
    'Category','RiskScore','RawJson'
)

function Get-Prop { param($Obj, [string]$Name) if ($null -eq $Obj) { return $null }; if ($Obj -is [System.Collections.IDictionary]) { if ($Obj.Contains($Name)) { return $Obj[$Name] } return $null }; $p = $Obj.PSObject.Properties[$Name]; if ($p) { $p.Value } else { $null } }

function Get-Category {
    param([string]$Op)
    switch -Regex ($Op) {
        '^(Share|Update.*Permission|AddGroupMembers|DeleteGroupMembers|UpdateGroupUsers|Add.*Access|Remove.*Access)' { 'Access & Sharing'; break }
        '(Export|Download|AnalyzedByExternalApplication|GenerateScreenshot|PrintReport|PrintDashboard)'               { 'Data Egress'; break }
        '^(Delete|Remove)'                                                                                            { 'Deletion'; break }
        '^(Create|Post|Import|Publish|Clone|Copy)'                                                                    { 'Creation'; break }
        '(AdminFeatureSwitch|TenantSetting|UpdateCapacity|UpdatedAdmin|Capacity)'                                      { 'Admin & Governance'; break }
        '(Gateway|Datasource|Connection)'                                                                             { 'Gateway & Datasource'; break }
        '(Refresh|Dataflow|Pipeline|Notebook|Lakehouse|Warehouse|Job)'                                                 { 'Data Engineering'; break }
        '(SensitivityLabel|Dlp|Protection)'                                                                           { 'Information Protection'; break }
        '(View|Get|Read|Open|Render)'                                                                                  { 'Consumption'; break }
        default { 'Other' }
    }
}

function Get-RiskScore {
    param($Row)
    $s = 0
    if ($Row.Category -eq 'Data Egress')          { $s += 40 }
    if ($Row.Category -eq 'Deletion')             { $s += 35 }
    if ($Row.Category -eq 'Admin & Governance')   { $s += 30 }
    if ($Row.Category -eq 'Access & Sharing')     { $s += 25 }
    if ($Row.IsGuest -eq $true)                   { $s += 25 }
    if ($Row.SharingScope -match 'External|Anyone|EntireOrganization') { $s += 25 }
    if ($Row.IsSuccess -eq $false)                { $s += 10 }
    if ($Row.Hour -lt 6 -or $Row.Hour -ge 21)     { $s += 10 }
    [math]::Min($s, 100)
}

function ConvertTo-Row {
    param($R)
    $ct = [datetime]::Parse($R.CreationTime, [cultureinfo]::InvariantCulture,
            ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal))
    $sharing = Get-Prop $R 'SharingInformation'
    $row = [ordered]@{}
    foreach ($c in $Columns) { $row[$c] = $null }

    $row.Id                = Get-Prop $R 'Id'
    $row.CreationTimeUtc   = $ct.ToString('yyyy-MM-dd HH:mm:ss')
    $row.Date              = $ct.ToString('yyyy-MM-dd')
    $row.Hour              = $ct.Hour
    $row.Operation         = Get-Prop $R 'Operation'
    $row.RecordType        = Get-Prop $R 'RecordType'
    $row.Workload          = Get-Prop $R 'Workload'
    $row.Activity          = Get-Prop $R 'Activity'
    $row.UserId            = (Get-Prop $R 'UserId')
    $row.UserType          = Get-Prop $R 'UserType'
    $row.UserKey           = Get-Prop $R 'UserKey'
    $row.UserAgent         = Get-Prop $R 'UserAgent'
    $row.ClientIP          = Get-Prop $R 'ClientIP'
    $row.WorkspaceId       = Get-Prop $R 'WorkspaceId'
    $row.WorkspaceName     = Get-Prop $R 'WorkSpaceName'
    $row.CapacityId        = Get-Prop $R 'CapacityId'
    $row.CapacityName      = Get-Prop $R 'CapacityName'
    $row.ObjectId          = Get-Prop $R 'ObjectId'
    $row.ItemName          = Get-Prop $R 'ItemName'
    $row.ArtifactId        = Get-Prop $R 'ArtifactId'
    $row.ArtifactName      = Get-Prop $R 'ArtifactName'
    $row.ArtifactKind      = Get-Prop $R 'ArtifactKind'
    $row.DatasetId         = Get-Prop $R 'DatasetId'
    $row.DatasetName       = Get-Prop $R 'DatasetName'
    $row.ReportId          = Get-Prop $R 'ReportId'
    $row.ReportName        = Get-Prop $R 'ReportName'
    $row.ReportType        = Get-Prop $R 'ReportType'
    $row.DashboardId       = Get-Prop $R 'DashboardId'
    $row.DashboardName     = Get-Prop $R 'DashboardName'
    $row.DataflowId        = Get-Prop $R 'DataflowId'
    $row.DataflowName      = Get-Prop $R 'DataflowName'
    $row.FolderObjectId    = Get-Prop $R 'FolderObjectId'
    $row.FolderDisplayName = Get-Prop $R 'FolderDisplayName'
    $row.AppId             = Get-Prop $R 'AppId'
    $row.AppName           = Get-Prop $R 'AppName'
    $row.GatewayId         = Get-Prop $R 'GatewayId'
    $row.GatewayName       = Get-Prop $R 'GatewayName'
    $row.DatasourceId      = Get-Prop $R 'DatasourceId'
    $row.DistributionMethod = Get-Prop $R 'DistributionMethod'
    $row.ConsumptionMethod  = Get-Prop $R 'ConsumptionMethod'
    $row.SensitivityLabelId = Get-Prop $R 'SensitivityLabelId'
    $row.SwitchState        = Get-Prop $R 'SwitchState'
    $row.RefreshType        = Get-Prop $R 'RefreshType'
    $row.ImportSource       = Get-Prop $R 'ImportSource'
    $row.ImportType         = Get-Prop $R 'ImportType'
    $row.RequestId          = Get-Prop $R 'RequestId'
    $row.ActivityId         = Get-Prop $R 'ActivityId'
    $row.OrganizationId     = Get-Prop $R 'OrganizationId'

    if ($sharing) {
        $si = @($sharing)
        $row.SharingAction     = ($si | ForEach-Object { Get-Prop $_ 'SharingAction' }) -join ';'
        $row.SharingScope      = ($si | ForEach-Object { Get-Prop $_ 'ResharePermission' }) -join ';'
        $row.SharingRecipients = ($si | ForEach-Object { Get-Prop $_ 'RecipientEmail' }) -join ';'
    }

    $ok = Get-Prop $R 'IsSuccess'
    $rs = Get-Prop $R 'ResultStatus'
    $row.IsSuccess    = if ($null -ne $ok) { [bool]$ok } elseif ($rs) { $rs -match '^(Succe|True)' } else { $true }
    $row.ResultStatus = $rs
    $row.ErrorMessage = Get-Prop $R 'ErrorMessage'

    $ut = [string]$row.UserType
    $uid = [string]$row.UserId
    $row.IsGuest            = ($uid -match '#EXT#')
    $row.IsServicePrincipal = ($ut -eq '4' -or $ut -eq 'Application' -or $uid -match '^[0-9a-f]{8}-')
    $row.Category  = Get-Category ([string]$row.Operation)
    $row.RawJson   = ($R | ConvertTo-Json -Depth 10 -Compress)
    $row.RiskScore = Get-RiskScore ([pscustomobject]$row)
    [pscustomobject]$row
}

$rows = @($records | ForEach-Object { ConvertTo-Row $_ })

# --------------------------------------------- Administrative Unit mapping ---
Write-Log 'Resolving Administrative Unit membership from Microsoft Graph...'
$userToAu = @{}   # upn(lower) -> @{ Name; AuId; Department; JobTitle; DisplayName }
$script:UserCache   = @{}
$script:NeedUserRead = $false
$auEnabled = @($cfg.administrativeUnits | Where-Object { $_.enabled })

function Get-GraphAll {
    param([string]$Uri)
    $out = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $r = (Invoke-Api -Uri $Uri -Resource $GraphRes).Content
        if ($r.PSObject.Properties.Name -contains 'value') { foreach ($v in $r.value) { $out.Add($v) } }
        $Uri = if ($r.PSObject.Properties.Name -contains '@odata.nextLink') { $r.'@odata.nextLink' } else { $null }
    }
    # Return a plain array. Do NOT use ,$out - the comma wrapper survives @(...) and
    # yields the List itself as a single element instead of its members.
    $out.ToArray()
}

foreach ($au in $auEnabled) {
    $auId = [string]$au.auId
    $guidRef = [guid]::Empty
    if (-not [guid]::TryParse($auId, [ref]$guidRef) -or $guidRef -eq [guid]::Empty) {
        Write-Log "AU '$($au.name)': auId '$auId' is not a valid GUID - skipped. Get the correct value with: Get-MgDirectoryAdministrativeUnit | Select Id,DisplayName" 'ERROR'
        continue
    }
    try {
        $sel = 'id,userPrincipalName,displayName,department,jobTitle,mail,userType'
        $users  = New-Object System.Collections.Generic.List[object]
        $groups = New-Object System.Collections.Generic.List[object]

        # Preferred: OData cast segments. Fast and returns exactly the properties we want.
        try {
            foreach ($u in (Get-GraphAll "$GraphRes/v1.0/directory/administrativeUnits/$auId/members/microsoft.graph.user?`$select=$sel&`$top=999")) { $users.Add($u) }
            foreach ($g in (Get-GraphAll "$GraphRes/v1.0/directory/administrativeUnits/$auId/members/microsoft.graph.group?`$select=id,displayName&`$top=999")) { $groups.Add($g) }
        }
        catch { Write-Log "AU '$($au.name)': cast query failed ($($_.Exception.Message)) - falling back." 'WARN' }

        # Fallback: some tenants return an empty set from the cast segment even though
        # the AU has members. Read the untyped collection and partition on @odata.type.
        if ($users.Count -eq 0) {
            Write-Log "AU '$($au.name)': user cast returned nothing - retrying via untyped /members." 'WARN'
            $all = @(Get-GraphAll "$GraphRes/v1.0/directory/administrativeUnits/$auId/members?`$top=999")
            Write-Log "AU '$($au.name)': untyped /members returned $($all.Count) object(s)."
            $groups.Clear()
            foreach ($m in $all) {
                $t = [string](Get-Prop $m '@odata.type')
                if ($t -match 'group')  { $groups.Add($m); continue }
                if ($t -match 'user' -or (Get-Prop $m 'userPrincipalName') -or (Get-Prop $m 'id')) { $users.Add($m); continue }
                Write-Log "AU '$($au.name)': ignoring member of type '$t'."
            }
        }
        Write-Log "AU '$($au.name)': directory returned $($users.Count) user object(s), $($groups.Count) group object(s)."

        # Graph silently omits properties the app cannot read. If a member object has an
        # id but no userPrincipalName, the app is missing User.Read.All - re-read the user
        # directly so we can either recover the UPN or surface a precise error.
        for ($i = 0; $i -lt $users.Count; $i++) {
            if (Get-Prop $users[$i] 'userPrincipalName') { continue }
            $uid = [string](Get-Prop $users[$i] 'id')
            if (-not $uid) { continue }
            if ($script:UserCache.ContainsKey($uid)) { $users[$i] = $script:UserCache[$uid]; continue }
            try {
                $full = (Invoke-Api -Uri "$GraphRes/v1.0/users/$uid`?`$select=$sel" -Resource $GraphRes).Content
                $script:UserCache[$uid] = $full
                $users[$i] = $full
            }
            catch {
                $script:NeedUserRead = $true
                Write-Log "AU '$($au.name)': cannot read user $uid - $($_.Exception.Message)" 'ERROR'
            }
        }

        # AUs may contain groups; expand them transitively
        foreach ($g in $groups) {
            $gid = [string](Get-Prop $g 'id')
            if (-not $gid) { continue }
            $gname = [string](Get-Prop $g 'displayName')
            try {
                $gm = @(Get-GraphAll "$GraphRes/v1.0/groups/$gid/transitiveMembers/microsoft.graph.user?`$select=$sel&`$top=999")
                Write-Log "AU '$($au.name)': group '$gname' expanded to $($gm.Count) user(s)."
                foreach ($u in $gm) { $users.Add($u) }
            }
            catch {
                Write-Log "AU '$($au.name)': cannot expand group '$gname' ($gid) - add GroupMember.Read.All as an application permission. $($_.Exception.Message)" 'ERROR'
            }
        }

        $added = 0; $noUpn = 0
        foreach ($u in $users) {
            $upn = ([string](Get-Prop $u 'userPrincipalName')).ToLowerInvariant()
            if (-not $upn) { $noUpn++; continue }
            if ($userToAu.ContainsKey($upn)) { continue }
            $userToAu[$upn] = @{
                Name = $au.name; AuId = $auId
                Department  = (Get-Prop $u 'department')
                JobTitle    = (Get-Prop $u 'jobTitle')
                DisplayName = (Get-Prop $u 'displayName')
            }
            $added++
            $mail = ([string](Get-Prop $u 'mail')).ToLowerInvariant()
            if ($mail -and -not $userToAu.ContainsKey($mail)) { $userToAu[$mail] = $userToAu[$upn] }
        }
        if ($noUpn) { Write-Log "AU '$($au.name)': $noUpn object(s) had no readable userPrincipalName and were skipped." 'WARN' }
        if ($added -eq 0) {
            Write-Log "AU '$($au.name)': 0 members mapped." 'WARN'
        }
        else { Write-Log "AU '$($au.name)': $added members mapped." 'OK' }
    }
    catch { Write-Log "Failed to read AU '$($au.name)' ($auId): $($_.Exception.Message)" 'ERROR' }
}

foreach ($r in $rows) {
    $key = ([string]$r.UserId).ToLowerInvariant()
    if ($key -and $userToAu.ContainsKey($key)) {
        $m = $userToAu[$key]
        $r.AdministrativeUnit = $m.Name; $r.AuId = $m.AuId
        $r.Department = $m.Department;  $r.JobTitle = $m.JobTitle; $r.DisplayName = $m.DisplayName
    }
    else {
        $r.AdministrativeUnit = 'Unassigned'; $r.AuId = ''
    }
}
Write-Log ("Mapped {0} of {1} records to an Administrative Unit." -f (@($rows | Where-Object AdministrativeUnit -ne 'Unassigned').Count), $rows.Count)

if ($userToAu.Count -eq 0) {
    Write-Log '' 'ERROR'
    Write-Log 'NO AU MEMBERS COULD BE RESOLVED.' 'ERROR'
    if ($script:NeedUserRead) {
        Write-Log "Graph returned member objects but withheld userPrincipalName. The app registration is missing the Microsoft Graph APPLICATION permission 'User.Read.All'." 'ERROR'
    }
    else {
        Write-Log "Graph returned member objects without a readable userPrincipalName. This is almost always the missing Microsoft Graph APPLICATION permission 'User.Read.All' - AdministrativeUnit.Read.All alone reveals that a member exists, but not who they are." 'ERROR'
    }
    Write-Log "Fix: Entra portal -> App registrations -> your app -> API permissions -> Add -> Microsoft Graph -> Application permissions -> User.Read.All -> Add -> Grant admin consent." 'ERROR'
}

# Show who could not be matched - the fastest way to spot a UPN/alias mismatch.
$unmatched = @($rows | Where-Object AdministrativeUnit -eq 'Unassigned' |
                Select-Object -ExpandProperty UserId -Unique | Where-Object { $_ })
if ($unmatched.Count) {
    $g = [guid]::Empty
    $spns  = @($unmatched | Where-Object { [guid]::TryParse($_, [ref]$g) -or $_ -notmatch '@' })
    $human = @($unmatched | Where-Object { $_ -notin $spns })
    Write-Log "$($human.Count) unmatched user(s), $($spns.Count) service principal(s)/system account(s). AU directory holds $($userToAu.Count) identity key(s)." 'WARN'
    foreach ($u in ($human | Select-Object -First 15)) { Write-Log "    unmatched user: $u" }
    if ($human.Count -gt 15) { Write-Log "    ... and $($human.Count - 15) more." }
    if ($spns.Count) { Write-Log "    (service principals never belong to an AU - this is expected)" }
}

# ------------------------------------ append to central raw store (deduped) ---
$touchedDates = @{}
foreach ($grp in ($rows | Group-Object Date)) {
    $file = Join-Path $rawPath ("{0}.csv" -f $grp.Name)
    $existingIds = @{}
    if (Test-Path -LiteralPath $file) {
        foreach ($e in (Import-Csv -LiteralPath $file)) { $existingIds[$e.Id] = $true }
    }
    $new = @($grp.Group | Where-Object { -not $existingIds.ContainsKey($_.Id) })
    if ($new.Count -eq 0) { Write-Log "Raw $($grp.Name): no new records."; continue }
    if (Test-Path -LiteralPath $file) { $new | Export-Csv -LiteralPath $file -NoTypeInformation -Append -Encoding UTF8 }
    else                              { $new | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8 }
    $touchedDates[$grp.Name] = $true
    Write-Log "Raw $($grp.Name): +$($new.Count) records." 'OK'
}

# ------------------------------------------- per-AU export, schedule-gated ---
$localNow = Get-Date
function Get-ConfigDate {
    param([string]$Value, [string]$Field, $Au)
    $d = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($Value, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
        throw "AU '$($Au.name)': '$Field' must be an ISO date (yyyy-MM-dd), got '$Value'."
    }
    $d.Date
}
function Get-WeekStart {
    param([datetime]$Date, [string]$StartsOn)
    $target = [DayOfWeek]::Monday
    if ($StartsOn -and -not [enum]::TryParse([DayOfWeek], $StartsOn, $true, [ref]$target)) {
        throw "weekStartsOn '$StartsOn' is not a day name (Sunday..Saturday)."
    }
    $Date.Date.AddDays(-(((([int]$Date.DayOfWeek) - [int]$target) + 7) % 7))
}
function Get-Period {
    param([string]$Mode, [datetime]$Now, $Au)
    $today = $Now.Date

    # Explicit range from config. Returns before every other branch: the range was
    # stated by hand, so it is exported verbatim and never widened.
    if ($Mode -eq 'Custom') {
        $cs = [string](Get-Prop $Au 'periodStart')
        $ce = [string](Get-Prop $Au 'periodEnd')
        if (-not $cs) { throw "AU '$($Au.name)': schedule 'Custom' requires 'periodStart' (yyyy-MM-dd) in config.json." }
        $s = Get-ConfigDate -Value $cs -Field 'periodStart' -Au $Au
        $e = if ($ce) { Get-ConfigDate -Value $ce -Field 'periodEnd' -Au $Au } else { $today }
        if ($e -lt $s) { throw "AU '$($Au.name)': periodEnd '$ce' is before periodStart '$cs'." }
        return @{ Start = $s; End = $e; Mode = 'Custom' }
    }

    $weekStart = [string](Get-Prop $Au 'weekStartsOn')
    $spec      = Resolve-PeriodMode -Au $Au -Schedule $Mode

    switch ($spec.Kind) {
        # N days back from today (or from yesterday), regardless of calendar boundaries.
        'RollingDays' {
            $e = if ($spec.IncludesToday) { $today } else { $today.AddDays(-1) }
            return @{ Start = $e.AddDays(-($spec.Days - 1)); End = $e; Mode = $spec.Name }
        }
        # Current calendar week/month so far.
        'PeriodToDate' {
            $s = switch ($Mode) {
                'Weekly'  { Get-WeekStart -Date $today -StartsOn $weekStart }
                'Monthly' { (Get-Date -Year $today.Year -Month $today.Month -Day 1).Date }
                default   { $today }
            }
            return @{ Start = $s; End = $today; Mode = $spec.Name }
        }
    }

    # PreviousPeriod: the last COMPLETE calendar period. Fixed boundaries, not a
    # rolling window, so the same period is recognisable as 'already exported'.
    switch ($Mode) {
        'Weekly'  { $ws = Get-WeekStart -Date $today -StartsOn $weekStart; $s = $ws.AddDays(-7); $e = $ws.AddDays(-1) }
        'Monthly' { $f = (Get-Date -Year $today.Year -Month $today.Month -Day 1).AddMonths(-1); $s = $f.Date; $e = $f.AddMonths(1).AddDays(-1).Date }
        default   { $s = $today.AddDays(-1); $e = $today.AddDays(-1) }
    }
    # -IncludeToday / includeCurrentDay is a blunt convenience for AUs that never chose
    # a periodMode: it promotes the default window to period-to-date. An AU that states
    # its own periodMode is left exactly as configured, so 'PreviousMonth' never
    # silently becomes month-to-date and overlaps a weekly export.
    if ($inclToday -and -not $spec.Explicit -and $e -lt $today) {
        $e = $today
        $name = 'PeriodToDate'
        switch ($Mode) {
            'Weekly'  { $s = Get-WeekStart -Date $today -StartsOn $weekStart }
            'Monthly' { $s = (Get-Date -Year $today.Year -Month $today.Month -Day 1).Date }
            default   { $s = $today }
        }
        return @{ Start = $s; End = $e; Mode = $name }
    }
    @{ Start = $s; End = $e; Mode = $spec.Name }
}
# An AU is due whenever the period it would export has not been exported yet.
# This is deliberately NOT "is today Monday / the 1st": a missed run (server down,
# holiday, task disabled) would silently lose that period forever. Keying on the
# period itself makes the job self-healing - it catches up on the next run - and
# still writes each period exactly once.
$exportState = @{}
if ($state.PSObject.Properties.Name -contains 'exports' -and $state.exports) {
    foreach ($p in $state.exports.PSObject.Properties) { $exportState[$p.Name] = [string]$p.Value }
}
function Get-ExportKey { param($Au, [string]$Mode) "$($Au.name)|$Mode" }
# Both ends identify the period, so editing a Custom range re-triggers its export.
function Get-PeriodToken { param($Period) '{0:yyyy-MM-dd}_{1:yyyy-MM-dd}' -f $Period.Start, $Period.End }

function Test-Due {
    param([string]$Mode, $Au, [datetime]$Now, $Period)
    if ($Force) { return $true }
    $k = Get-ExportKey -Au $Au -Mode $Mode
    if (-not $exportState.ContainsKey($k)) { return $true }
    return ($exportState[$k] -ne (Get-PeriodToken $Period))
}

$manifest = New-Object System.Collections.Generic.List[object]

if ($script:AuFilter) { Write-Log "Export restricted to: $($script:AuFilter -join ', ')" 'WARN' }

foreach ($au in $auEnabled) {
    if (-not (Test-AuSelected $au)) { continue }
    $mode = if ($au.PSObject.Properties.Name -contains 'schedule' -and $au.schedule) { [string]$au.schedule } else { 'Daily' }
    $p = Get-Period -Mode $mode -Now $localNow -Au $au
    $label = if ($p.Mode -and $p.Mode -ne $mode) { "$mode/$($p.Mode)" } else { $mode }
    if (-not (Test-Due -Mode $mode -Au $au -Now $localNow -Period $p)) {
        Write-Log "AU '$($au.name)' ($label): $($p.Start.ToString('yyyy-MM-dd'))..$($p.End.ToString('yyyy-MM-dd')) already exported - skipped."
        continue
    }
    $days = @(); for ($d = $p.Start; $d -le $p.End; $d = $d.AddDays(1)) { $days += $d.ToString('yyyy-MM-dd') }

    $auRows = New-Object System.Collections.Generic.List[object]
    foreach ($d in $days) {
        $f = Join-Path $rawPath "$d.csv"
        if (Test-Path -LiteralPath $f) {
            foreach ($r in (Import-Csv -LiteralPath $f | Where-Object { $_.AdministrativeUnit -eq $au.name })) { $auRows.Add($r) }
        }
    }

    $fileName = 'FabricAudit_{0}_{1}_{2:yyyyMMdd}_{3:yyyyMMdd}.csv' -f `
        (($au.name -replace '[^\w\-]', '_')), $mode, $p.Start, $p.End
    $dest = Join-Path $au.outputPath $fileName

    if ($WhatIfExport) { Write-Log "[WhatIf] would write $($auRows.Count) rows -> $dest"; continue }

    if ($auRows.Count -eq 0 -and $skipEmpty) {
        Write-Log "AU '$($au.name)' ($label): 0 rows for $($p.Start.ToString('yyyy-MM-dd'))..$($p.End.ToString('yyyy-MM-dd')) - nothing written."
        continue
    }

    try {
        New-Folder $au.outputPath
        $auRows | Export-Csv -LiteralPath $dest -NoTypeInformation -Encoding UTF8
        Write-Log "AU '$($au.name)' ($label): $($auRows.Count) rows for $($p.Start.ToString('yyyy-MM-dd'))..$($p.End.ToString('yyyy-MM-dd')) -> $dest" 'OK'

        # Power BI watch-folder trigger: refresh as soon as the file lands
        $trigger = [pscustomobject]@{
            administrativeUnit = $au.name
            auId               = $au.auId
            schedule           = $mode
            periodMode         = $p.Mode
            periodStart        = $p.Start.ToString('yyyy-MM-dd')
            periodEnd          = $p.End.ToString('yyyy-MM-dd')
            rowCount           = $auRows.Count
            file               = $fileName
            generatedUtc       = (Get-Date).ToUniversalTime().ToString('o')
        }
        $trigger | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $au.outputPath '_LATEST.json') -Encoding UTF8
        $manifest.Add($trigger)

        # Mark the period done only after a successful write. A failed or skipped
        # export stays pending so the next run retries it.
        $exportState[(Get-ExportKey -Au $au -Mode $mode)] = Get-PeriodToken $p

        # retention
        Get-ChildItem -LiteralPath $au.outputPath -Filter 'FabricAudit_*.csv' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $localNow.AddDays(-$retentionDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    catch { Write-Log "AU '$($au.name)': export failed -> $dest : $_" 'ERROR' }
}

if ($inclUnassigned -and -not $script:AuFilter) {
    $un = @($rows | Where-Object AdministrativeUnit -eq 'Unassigned')
    if ($un.Count) {
        $unPath = Join-Path $cfg.centralPath 'Unassigned'
        New-Folder $unPath
        $f = Join-Path $unPath ('FabricAudit_Unassigned_{0:yyyyMMdd}.csv' -f $localNow)
        $un | Export-Csv -LiteralPath $f -NoTypeInformation -Encoding UTF8
        Write-Log "Unassigned: $($un.Count) rows -> $f" 'WARN'
        Get-ChildItem -LiteralPath $unPath -Filter 'FabricAudit_Unassigned_*.csv' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $localNow.AddDays(-$retentionDays) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
}

$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $cfg.centralPath '_manifest.json') -Encoding UTF8

# raw retention
Get-ChildItem -LiteralPath $rawPath -Filter '*.csv' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt $localNow.AddDays(-$retentionDays) } | Remove-Item -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------ save state ---
if (-not $WhatIfExport -and -not $StartUtc) {
    @{ lastRunUtc = $winEnd.ToString('o'); lastRecordCount = $rows.Count; exports = $exportState } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cfg.stateFile -Encoding UTF8
}
Write-Log "=== Completed. $($rows.Count) records processed. ===" 'OK'
