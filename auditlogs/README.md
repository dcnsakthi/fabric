> [!CAUTION]
> This project is not licensed or endorsed by any person or organization. Use it
> with caution and at your own risk.

Pulls unified audit records from the **Office 365 Management Activity API** using
app-only auth (client ID + secret), maps every event to an **Administrative Unit**,
and drops a CSV into each agency's shared drive on a Daily / Weekly / Monthly cadence
for Power BI to consume. It ships scoped to Microsoft Fabric and Power BI; the feeds
and record types are config, not code — see
[What gets extracted](#what-gets-extracted).

```
config.json                        ← everything configurable: AUs, paths, schedules, audit scope
Extract-FabricAuditLogs.ps1        ← the whole extractor (single file)
config-keyvault.json               ← Key Vault variant config
README.md                          ← you are here
```
---

## Why not `Search-UnifiedAuditLog`?

It only supports app-only auth with a **certificate**, and requires an Exchange
role. The Management Activity API is true client-secret app-only, needs a single
permission, returns the same unified audit content, and doesn't throttle at
5,000 rows. Same data, less privilege.

---

## 1. App registration (one-off, ~5 minutes)

Entra admin center → App registrations → New registration → *Fabric Audit Extract*.

**API permissions** (all **Application**, then Grant admin consent):

| API | Permission | Why |
|---|---|---|
| Office 365 Management APIs | `ActivityFeed.Read` | read the unified audit feed |
| Microsoft Graph | `AdministrativeUnit.Read.All` | list AU members |
| Microsoft Graph | `User.Read.All` | **required** — read each member's `userPrincipalName`. Without it Graph returns the AU member objects but strips every user property, so nothing can be matched and all records land in `Unassigned` |
| Microsoft Graph | `GroupMember.Read.All` | *only* if your AUs contain groups |

That is the full set. **No** Azure RBAC role, **no** Entra directory role, **no**
Exchange role, **no** `Directory.Read.All`.

> **`User.Read.All` is not optional.** This is the single most common setup failure.
> With `AdministrativeUnit.Read.All` alone, Graph happily returns the AU's members —
> but as bare objects carrying only an `id`, with `userPrincipalName`, `mail`,
> `department` and `jobTitle` all stripped. The extract cannot match an audit record
> to a member it cannot name, so every row silently falls through to `Unassigned`.
> The script detects this and fails loudly with
> `cannot read user <guid> - 403 (Forbidden)` followed by
> `NO AU MEMBERS COULD BE RESOLVED.`

Granting it from the CLI instead (needs Global Administrator or Privileged Role
Administrator):

```powershell
$app = '<your-client-id>'
# 00000003-... = Microsoft Graph;  df021288-... = User.Read.All application role
az ad app permission add --id $app `
  --api 00000003-0000-0000-c000-000000000000 `
  --api-permissions 567huti86-bdef-4463-88db-654rtyry65=Role
az ad app permission admin-consent --id $app
```

Consent takes a minute or two to propagate. Confirm every row shows a green check
under **Status** before running the extract.

Certificates & secrets → New client secret → copy the value.

Also confirm unified audit logging is on:
```powershell
Connect-ExchangeOnline; Get-AdminAuditLogConfig | Select UnifiedAuditLogIngestionEnabled
```

---

## 2. Configure

Edit `config.json`:

| Key | Meaning |
|---|---|
| `tenantId`, `clientId` | from the app registration |
| `clientSecretEnvVar` | name of the env var holding the secret — never the secret itself |
| `lookbackHours` | how far back to **fetch** from the API on first run or after a gap, in *hours* (default 26). This sizes the fetch only. It does not cap how much history an export covers |
| `stateFile` | watermark so each run resumes where the last stopped |
| `centralPath` | central store; `<centralPath>\raw\yyyy-MM-dd.csv` is the deduped source of truth |
| `retentionDays` | prunes both raw and agency CSVs |
| `includeUnassigned` | write events whose user matches no AU to a separate file |
| `skipEmptyExports` | `true` (default) — suppress agency CSVs that would have zero rows. Set `false` to always emit a header-only file (useful if a downstream job expects a file every day) |
| `includeCurrentDay` | `false` (default) — exports cover the last *completed* period. Set `true` to extend every export to the partial current day. Equivalent to passing `-IncludeToday` on every run. **Ignored for any AU that sets its own `periodMode`** |
| `audit` | which API feeds to subscribe to and which records to keep — see [What gets extracted](#what-gets-extracted). Omit the block for the Fabric / Power BI defaults |
| `administrativeUnits[]` | `name`, `auId`, `outputPath`, `schedule` (`Daily`/`Weekly`/`Monthly`/`Custom`), `enabled`, and the optional `periodMode` / `weekStartsOn` / `rollingDays` / `rollingIncludesToday` covered below. `Custom` additionally takes `periodStart` and an optional `periodEnd`, both `yyyy-MM-dd` |

Find your AU object IDs:
```powershell
Connect-MgGraph -Scopes AdministrativeUnit.Read.All
Get-MgDirectoryAdministrativeUnit | Select Id, DisplayName
```

`auId` must be a real GUID (8-4-4-4-12 hex). The script validates this up front and
skips any AU whose `auId` is malformed or all-zeros, rather than failing deep inside
a Graph call with an unhelpful error. Copy the **Object ID** from Entra verbatim —
do not retype it.

An AU with no members is fine: it logs `0 members mapped` and, with
`skipEmptyExports` left at `true`, writes nothing.

Add, remove, or re-schedule an agency by editing `administrativeUnits[]` only —
no code change.

### What gets extracted

The `audit` block decides what is collected. Nothing about the scope is hard-coded:

```json
"audit": {
  "contentTypes": [ "Audit.General" ],
  "workloads":    [ "PowerBI", "Fabric", "OneLake", "MicrosoftFabric" ],
  "recordTypes":  [ 20, 261, 262, 357 ]
}
```

| Key | Meaning |
|---|---|
| `contentTypes` | which Management Activity API feeds to subscribe to and poll. One subscription is started per entry |
| `workloads` | keep records whose `Workload` is in this list |
| `recordTypes` | keep records whose `RecordType` is in this list |

A record is kept when it matches `workloads` **OR** `recordTypes` — the two are a
union, not an intersection, so a Fabric event is captured whether it identifies
itself by workload or by record type. Omit the whole `audit` block and the defaults
above apply.

#### Available feeds

`contentTypes` accepts only these five values, validated at startup:

| Content type | Covers |
|---|---|
| `Audit.General` | **everything not covered by the other three feeds** — Power BI, Fabric, OneLake, Teams, Power Platform, Forms, Viva, Copilot, Purview, Defender |
| `Audit.AzureActiveDirectory` | Microsoft Entra ID sign-ins, directory changes, STS logons |
| `Audit.Exchange` | Exchange mailbox and admin activity |
| `Audit.SharePoint` | SharePoint and OneDrive file, sharing, and list activity |
| `DLP.All` | DLP events across all workloads, including full matched-content detail |

Fabric and Power BI live in `Audit.General`, which is why it is the only default.
Add a feed only when you actually want its data — each one is a separate poll of
every 24-hour slice, so the run takes proportionally longer.

#### Record types worth knowing

The defaults are the Fabric / Power BI set:

| Value | Member | Notes |
|---|---|---|
| `20` | `PowerBIAudit` | Power BI events — the bulk of what you get today |
| `357` | `FabricAudit` | Microsoft Fabric events |
| `261` | `PowerBIDlp` | legacy Power BI DLP records, kept for older tenants |
| `262` | `PowerBIMetadata` | legacy Power BI metadata records, kept for older tenants |

Commonly requested additions, all of which arrive on `Audit.General` unless noted:

| Value | Member | Feed |
|---|---|---|
| `25` | `MicrosoftTeams` | `Audit.General` |
| `30` | `MicrosoftFlow` (Power Automate) | `Audit.General` |
| `45` / `46` / `79` | `PowerAppsApp` / `PowerAppsPlan` / `PowerAppsResource` | `Audit.General` |
| `256` | `PowerPlatformAdministratorActivity` | `Audit.General` |
| `66` | `MicrosoftForms` | `Audit.General` |
| `35` | `Project` | `Audit.General` |
| `21` | `CRM` (Dynamics 365) | `Audit.General` |
| `43` | `MIPLabel` — sensitivity labels in transport | `Audit.General` |
| `71` / `72` / `75` | `MipAutoLabelSharePointItem` / `…PolicyLocation` / `…ExchangeItem` | `Audit.General` |
| `310`–`325` | Copilot plugin / workspace / promptbook admin events | `Audit.General` |
| `334` | `TeamCopilotInteraction` | `Audit.General` |
| `4` / `6` / `14` / `36` / `37` | `SharePoint` / `SharePointFileOperation` / `SharePointSharingOperation` / `SharePointListOperation` / `SharePointCommentOperation` | `Audit.SharePoint` |
| `7` | `OneDrive` | `Audit.SharePoint` |
| `1` / `2` / `3` / `19` / `50` | `ExchangeAdmin` / `ExchangeItem` / `ExchangeItemGroup` / `ExchangeAggregatedOperation` / `ExchangeItemAggregated` | `Audit.Exchange` |
| `8` / `15` | `AzureActiveDirectory` / `AzureActiveDirectoryStsLogon` | `Audit.AzureActiveDirectory` |
| `11` / `13` | `ComplianceDLPSharePoint` / `ComplianceDLPExchange` | `DLP.All` |
| `28` / `41` / `47` / `64` | `ThreatIntelligence` / `…Url` / `…AtpContent` / `AirInvestigation` (Defender for Office 365) | `Audit.General` |
| `24` / `31` | `Discovery` / `AeD` (eDiscovery) | `Audit.General` |

Adding a record type without adding its feed collects nothing. Teams, Power
Platform, and Copilot need no extra feed; SharePoint, Exchange, and Entra do.

The full enum is published in the
[Management Activity API schema](https://learn.microsoft.com/office/office-365-management-api/office-365-management-activity-api-schema)
under **AuditLogRecordType**, and the feeds in the
[API reference](https://learn.microsoft.com/office/office-365-management-api/office-365-management-activity-api-reference).

#### Extracting everything

Set both filter lists to `[]` to keep every record in the subscribed feeds:

```json
"audit": {
  "contentTypes": [ "Audit.General", "Audit.SharePoint", "Audit.Exchange", "Audit.AzureActiveDirectory" ],
  "workloads":    [],
  "recordTypes":  []
}
```

The run logs a warning when it does this, because a full-tenant feed is typically
two to three orders of magnitude larger than the Fabric slice. Raise
`lookbackHours` carefully and watch `retentionDays` — the raw store grows daily and
the AU export re-reads every day in the period.

#### What the extra records look like

The 65 typed columns are Fabric-shaped: `WorkspaceName`, `ReportName`,
`DatasetName`, `CapacityName`, `ArtifactKind` and friends stay empty for a Teams or
Exchange record. The workload-neutral columns — `CreationTimeUtc`, `Operation`,
`RecordType`, `Workload`, `UserId`, `ClientIP`, `UserAgent`, `IsSuccess`,
`AdministrativeUnit` — are always populated, and **`RawJson` carries the complete
original record**, so nothing is lost. Parse `RawJson` in Power Query if you need a
field the flattener does not surface.

`Category` and `RiskScore` are derived from Fabric/Power BI operation names.
Operations from other workloads fall into `Other` with a baseline score, so treat
the security page as Fabric-only unless you extend the mapping.

#### Finding out what your tenant actually emits

Run a short unfiltered window into a scratch config, then count what came back:

```powershell
# audit.workloads = [] and audit.recordTypes = [] in the scratch config
.\Extract-FabricAuditLogs.ps1 -ConfigPath .\config.discover.json -StartUtc (Get-Date).AddDays(-1) -Force

Import-Csv .\LogExtracts\General\Raw\*.csv |
    Group-Object Workload, RecordType |
    Sort-Object Count -Descending |
    Select-Object Count, Name -First 30
```

That gives the exact `Workload` / `RecordType` pairs present in your tenant, which
is more reliable than the published enum — first-party services add record types
faster than the docs are updated. Point the scratch config at a throwaway
`centralPath` and `stateFile` so it does not disturb the production watermark.

---

## 3. Run

```powershell
$env:FABRIC_AUDIT_CLIENT_SECRET = '<secret>'

# dry run — fetches and maps, writes nothing to agency shares
.\Extract-FabricAuditLogs.ps1 -WhatIfExport

# diagnose Administrative Unit membership (no audit fetch, no files written)
.\Extract-FabricAuditLogs.ps1 -DiagnoseAu

# normal run
.\Extract-FabricAuditLogs.ps1

# backfill (API retains 7 days of feed content)
.\Extract-FabricAuditLogs.ps1 -StartUtc '2026-08-11' -EndUtc '2026-08-18' -Force

# force every AU to export regardless of its cadence
.\Extract-FabricAuditLogs.ps1 -Force

# re-export a single agency from the existing raw store; other AUs are untouched
.\Extract-FabricAuditLogs.ps1 -AdministrativeUnit AU2 -Force

# re-export several named agencies
.\Extract-FabricAuditLogs.ps1 -AdministrativeUnit AU2,EAGARCH -Force

# validation run — include today's partial day so you get output immediately
.\Extract-FabricAuditLogs.ps1 -Force -IncludeToday
```

### Which day does an export cover?

Two settings decide this, and they are independent:

- **`schedule`** — how often the AU is exported, and what its filename says.
- **`periodMode`** — the window that export covers. Optional; defaults to the last
  completed period.

By default an export covers the **last completed period**, never the day you run it:

| Schedule | Default period exported | Rolls over |
|---|---|---|
| `Daily` | yesterday | every midnight |
| `Weekly` | previous **Mon–Sun** calendar week | Mondays |
| `Monthly` | previous calendar month | the 1st |
| `Custom` | exactly the `periodStart`..`periodEnd` range in config | never. Written once, then re-triggered only when you edit the range |

This is deliberate: a settled period is written exactly once, so an agency file
never changes after it lands and Power BI never sees a half-day.

### Choosing the window: `periodMode`

Set `periodMode` on any `Weekly` or `Monthly` AU to override the default. With
`T` = today, and Monday as the week start:

| `schedule` | `periodMode` | Window | Example, run Tue 2026-08-18 |
|---|---|---|---|
| `Weekly` | `PreviousWeek` *(default)* | last complete calendar week | `2026-08-10 .. 2026-08-16` |
| `Weekly` | `WeekToDate` | this week's start → today | `2026-08-17 .. 2026-08-18` |
| `Weekly` | `Last7Days` | `T-6 .. T` | `2026-08-12 .. 2026-08-18` |
| `Weekly` | `Last7DaysExcludingToday` | `T-7 .. T-1` | `2026-08-11 .. 2026-08-17` |
| `Monthly` | `PreviousMonth` *(default)* | last complete calendar month | `2026-07-01 .. 2026-07-31` |
| `Monthly` | `MonthToDate` | 1st of this month → today | `2026-08-01 .. 2026-08-18` |
| `Monthly` | `Last30Days` | `T-29 .. T` | `2026-07-20 .. 2026-08-18` |
| `Monthly` | `Last30DaysExcludingToday` | `T-30 .. T-1` | `2026-07-19 .. 2026-08-17` |
| either | `RollingDays` | any N days, see below | — |

`PreviousPeriod` and `PeriodToDate` are schedule-agnostic spellings of the first and
second rows — use whichever reads better. A week-shaped mode on a `Monthly` AU (or the
reverse) is rejected at startup rather than silently ignored.

**Week boundaries.** `PreviousWeek` and `WeekToDate` follow `weekStartsOn`, which
defaults to `Monday`. Set it to `Sunday` for a Sunday–Saturday week:

```json
{
  "name": "AU1",
  "schedule": "Weekly",
  "periodMode": "PreviousWeek",
  "weekStartsOn": "Sunday"
}
```

Run on Tue 2026-08-18 that exports `2026-08-09 .. 2026-08-15`; with the default
`Monday` it exports `2026-08-10 .. 2026-08-16`.

**Arbitrary windows.** `RollingDays` takes any length, so a 14-day window is:

```json
{
  "name": "AU2",
  "schedule": "Weekly",
  "periodMode": "RollingDays",
  "rollingDays": 14,
  "rollingIncludesToday": true
}
```

`rollingDays` (default: 7 for `Weekly`, 30 for `Monthly`) and `rollingIncludesToday`
(default `true`) apply to `RollingDays` only. They are ignored by the named modes,
which already state their own length — `Last7Days` is always seven days.

**Weekly and monthly files holding the same rows.** That means the two windows
overlap. `WeekToDate` is by definition a subset of `MonthToDate`, and
`includeCurrentDay: true` used to turn *both* defaults into to-date windows. Keep the
two AUs on `PreviousWeek` + `PreviousMonth` for disjoint, non-overlapping files, or
pair `Last7Days` with `Last30Days` if you want rolling windows and accept that the
last seven days appear in both. Either way, stating `periodMode` explicitly makes the
AU immune to `includeCurrentDay` and `-IncludeToday`.

The resolved mode is echoed in the log and in `_LATEST.json`:

```
AU 'AU2' (Weekly/Last7Days): 412 rows for 2026-08-12..2026-08-18 -> ...
```

### Custom ranges

Set `schedule` to `Custom` to pin an agency to an explicit window, which is useful
for an ad-hoc investigation or a one-off report:

```json
{
  "name": "AU2",
  "auId": "7trrf4536-866b-232-a8e3-9867645323r",
  "outputPath": "LogExtracts\\AU2",
  "schedule": "Custom",
  "periodStart": "2026-08-01",
  "periodEnd": "2026-08-15",
  "enabled": true
}
```

Omit `periodEnd` to run from `periodStart` to today, giving a rolling to-date window.

Both dates must be ISO `yyyy-MM-dd`. Anything else fails immediately rather than
being parsed under the server's locale, where `08/01/2026` silently means different
things on different machines. `periodEnd` before `periodStart` is also rejected.

A `Custom` range is exported verbatim. `includeCurrentDay` and `-IncludeToday` do
**not** widen it, because the range was stated by hand. The export state records both
ends of the range, so editing either date re-triggers the export on the next run
without needing `-Force`.

### How much history does an export contain?

Exports read from the central raw store, not from the API. `lookbackHours` sizes the
*fetch* and has no bearing on export coverage. A `Monthly` export therefore covers
whichever days of the previous month exist under `<centralPath>\raw\`, which builds
up one file per day as the scheduled task runs.

So a `Monthly` AU configured today does not produce a full month on its first run. It
produces only the days already collected. Missing days contribute zero rows silently.
After the daily task has run for a full month, monthly exports are complete.

Backfilling more history is capped at **7 days** by the Management Activity API's feed
retention, so a fresh tenant cannot be back-populated further than that:

```powershell
.\Extract-FabricAuditLogs.ps1 -StartUtc '2026-08-11' -EndUtc '2026-08-18' -Force
```

Keep `retentionDays` comfortably larger than your longest cadence, otherwise raw days
are pruned before a monthly export can read them.

**Scheduling is period-driven, not calendar-driven.** The task runs daily; each AU
exports whenever the period it owns has not been written yet, which is recorded in
`stateFile` under `exports`. A Weekly AU therefore does *not* require the run to
land on a Monday — if Monday's run is missed (server down, task disabled, holiday),
the next run catches up and writes that week. Once written, later runs skip it:

```
AU 'AU2' (Weekly): 2026-08-10..2026-08-16 already exported - skipped.
```

To re-issue a period that was already written, delete its entry from `exports` in
`stateFile`, or run with `-Force`.

`-AdministrativeUnit` narrows a re-export to one or more agencies by their config
`name`, so a correction for a single agency does not rewrite every other agency's
file or disturb its recorded export state. Names are validated against
`config.json` up front, and an unknown name fails immediately with the list of
valid ones rather than silently exporting nothing. The switch scopes the export
stage only: AU membership is still resolved for every enabled AU, because the
central raw store is shared and skipping resolution would tag other agencies'
records as `Unassigned`. While a filter is active the `Unassigned` file is not
rewritten either, keeping the run limited to what you asked for.

The consequence is that a *first* run on a fresh tenant usually writes nothing —
all the audit data it just fetched belongs to today, and today is not exported yet.
The log says so explicitly:

```
AU 'AU2' (Daily): 0 rows for 2026-08-17..2026-08-17 - nothing written.
```

That is correct behaviour, not a failure. To see output right away, add
**`-IncludeToday`**, which extends the window to the current partial day
(`Monthly` becomes month-to-date). Use `-Force` alongside it if the AU's cadence
would not otherwise be due today. Keep both switches **out** of the scheduled task.

If you want that permanently — for example a live dashboard that must show today —
set `"includeCurrentDay": true` in `config.json` instead of passing the switch.
Be aware the current period's file is then rewritten on every run until the period
closes.

Both are blunt, tenant-wide instruments and neither can express "last seven days".
For a per-agency window that survives a scheduled run, set that AU's `periodMode`
instead — an AU with an explicit `periodMode` ignores `includeCurrentDay` and
`-IncludeToday` entirely.

### Output layout

```
<centralPath>\
    raw\yyyy-MM-dd.csv                       deduped source of truth, all AUs
    Unassigned\FabricAudit_Unassigned_*.csv  users matching no AU
    _manifest.json                           what was written where, this run

<au.outputPath>\                             one folder per agency
    FabricAudit_<AU>_<Schedule>_<from>_<to>.csv
    _LATEST.json                             Power BI refresh trigger
```

`Unassigned` sits in its own subfolder so an agency share pointed at `centralPath`
never mixes cross-tenant leftovers in with the raw store. Retention prunes it on
the same `retentionDays` schedule as everything else.

---

## 4. Automate

```powershell
.\Extract-FabricAuditLogs.ps1 -RegisterScheduledTask -RunTime 02:00
```

Creates task `FabricAuditExtract`. Then, as the task's service account:
```powershell
setx FABRIC_AUDIT_CLIENT_SECRET "<secret>" /M
```

Run it **daily even for weekly/monthly agencies** — the script collects daily into
the central raw store and each AU only writes its CSV when its own cadence is due:

| Cadence | Fires | Covers by default |
|---|---|---|
| Daily | every run | yesterday |
| Weekly | Mondays | previous Mon–Sun |
| Monthly | the 1st | the whole previous month |
| Custom | once per configured range | the configured range |

"Fires" shifts with `periodMode`: a rolling window such as `Last7Days` changes every
day, so that AU exports on every run rather than weekly.

The service account needs **write** access to each `outputPath`.
For production, swap the env var for Azure Key Vault or a gMSA-protected store.

---

## 5. What lands in the agency folder

```
FabricAudit_AU1___Health_Daily_20260817_20260817.csv
_LATEST.json          ← trigger + row count, for event-driven Power BI refresh
```

65 columns, including: `CreationTimeUtc`, `Operation`, `Category`, `RiskScore`,
`UserId`, `AdministrativeUnit`, `Department`, `WorkspaceName`, `ReportName`,
`DatasetName`, `CapacityName`, `ArtifactKind`, `SharingRecipients`,
`SharingScope`, `SensitivityLabelId`, `GatewayName`, `ClientIP`, `UserAgent`,
`IsSuccess`, `IsGuest`, `IsServicePrincipal`, `RawJson`.

Two derived columns do most of the analytical work:

- **`Category`** — every operation is bucketed into Access & Sharing, Data Egress,
  Deletion, Creation, Admin & Governance, Gateway & Datasource, Data Engineering,
  Information Protection, Consumption, Other.
- **`RiskScore`** (0–100) — weighted by category, guest identity, external sharing
  scope, failure, and off-hours timing. Drives the security page and the
  conditional formatting.

Then follow `PowerBI-Model.md`.

---

## Design notes

- **Idempotent.** De-duplicated on record `Id` in the raw store, so re-runs and the
  deliberate 10-minute window overlap never double-count.
- **Resumable.** A watermark in `stateFile`; if a run is missed, the next one
  backfills up to the API's 7-day retention limit.
- **Self-healing schedules.** Export eligibility is keyed on the *period*, not on
  the calendar day, and recorded in `stateFile`. A missed Monday or 1st-of-month
  run is caught up automatically instead of losing that period forever, while each
  period is still written exactly once.
- **Resilient.** Exponential backoff on 429/5xx, transparent token refresh.
- **Auditable.** Every run appends to `logFile`; `_manifest.json` records what was
  written where, with row counts.
- **Timezone-correct.** The API emits UTC without a `Z` suffix; the script parses it
  as UTC explicitly rather than as server-local time. `CreationTimeLocal` is derived
  in Power Query so each agency can set its own offset.
- **Robust AU resolution.** Members are read via OData cast segments first, then via
  the untyped `/members` collection if the cast returns nothing (some tenants do).
  Groups inside an AU are expanded transitively. Any member returned without a
  `userPrincipalName` triggers a cached per-user re-read, which either recovers the
  identity or surfaces the exact missing permission instead of silently producing
  empty output. Users are indexed by both `userPrincipalName` and `mail`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `AF20023` / 401 on subscription start | `ActivityFeed.Read` missing or admin consent not granted |
| Subscription starts, zero records | Unified audit logging disabled, or Power BI has genuinely had no activity in the window |
| `audit.contentTypes: 'X' is not a Management Activity API feed` | Only `Audit.General`, `Audit.AzureActiveDirectory`, `Audit.Exchange`, `Audit.SharePoint`, `DLP.All` exist |
| Added a `recordTypes` entry, still nothing collected | That record type ships on a feed you haven't subscribed to. Check the feed column in [Record types worth knowing](#record-types-worth-knowing) and add it to `contentTypes` |
| `Record filter is OFF ...` warning | Both `audit.workloads` and `audit.recordTypes` are empty, so every record in the subscribed feeds is stored. Intentional for discovery runs; a mistake in production |
| New feed added, first run returns nothing | A brand-new subscription can take up to 12 hours to produce its first content blob. Re-run later |
| `cannot read user <guid> - 403 (Forbidden)` <br> `NO AU MEMBERS COULD BE RESOLVED.` | **`User.Read.All` (application) is missing.** This is the #1 cause of everything landing in `Unassigned`. See §1 |
| `AU 'X': N object(s) had no readable userPrincipalName` | Same cause as above — Graph returned the member but withheld its properties |
| `AU 'X': auId is not a valid GUID` | Malformed `auId` in `config.json`. Copy the AU **Object ID** exactly from Entra (8-4-4-4-12 hex) |
| `AU 'X': directory returned 0 user object(s)` | The AU genuinely has no members, or the `auId` points at a different AU. Verify in Entra; run `-DiagnoseAu` |
| Members map, but records still `Unassigned` | Identity mismatch, not permissions. Compare the `unmatched user:` lines in the log against the members' UPNs — the audit `UserId` may be an alias or a different domain |
| `unmatched: 00000009-0000-...` style GUIDs | Service principals / Microsoft first-party apps. They never belong to an AU; the log classifies them separately and this is expected |
| Blank AU membership, no error | `AdministrativeUnit.Read.All` granted as *delegated* instead of *application*, or admin consent never granted |
| `AU 'X' (Daily): 0 rows for <date> - nothing written` | Working as designed — a Daily export covers *yesterday*, and your data is from today. Add `-IncludeToday` (with `-Force` if needed), or set `includeCurrentDay: true` |
| `AU 'X' (Weekly): <period> already exported - skipped` | That period's file was written on an earlier run. Delete its entry from `exports` in `stateFile`, or use `-Force`, to re-issue it |
| Weekly and monthly files contain identical rows | Overlapping windows. Usually `includeCurrentDay: true`, which turns both defaults into to-date windows, or a `WeekToDate` + `MonthToDate` pairing. Set an explicit `periodMode` per AU — `PreviousWeek` + `PreviousMonth` never overlap |
| `AU 'X': periodMode 'WeekToDate' describes a Weekly window but schedule is 'Monthly'` | The mode and the cadence disagree. Use `MonthToDate`, or change `schedule` to `Weekly` |
| `AU 'X': unknown periodMode '...'` | Typo. The message lists every valid value |
| Zero-row agency CSVs appearing | Set `skipEmptyExports` to `true` (the default) to suppress them |
| Missing very recent events | Normal — Microsoft's audit pipeline lags 30 min to ~24 h; the 26-hour default lookback absorbs this |

### Diagnosing AU mapping

```powershell
.\Extract-FabricAuditLogs.ps1 -DiagnoseAu
```

Probes each configured AU three ways — `/members/microsoft.graph.user`,
`/members/microsoft.graph.group`, and the untyped `/members` — and prints what
Graph actually returned, including whether each object carries a readable
`userPrincipalName`. Read it top-down:

| What you see | What it means |
|---|---|
| `0 object(s)` on every probe | Wrong `auId`, or the AU is empty |
| objects returned, `upn=MISSING` | `User.Read.All` not granted |
| objects returned, `upn=yes` | Directory side is healthy — any remaining `Unassigned` rows are an identity-matching problem |

A normal run also prints every unmatched user, so you can diff the audit log's
`UserId` values against the AU members directly.
