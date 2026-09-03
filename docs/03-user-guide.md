# Technical User Guide

## Purpose and audience

This guide is an operator runbook for Level 1 and Level 2 Support technicians using the D4A IT Automation and Operations Toolkit. It explains what each area is for, how to run common workflows, what safeguards to expect, and when to stop and escalate.

The script helps execute approved work consistently. It does not grant authorization to make a production change.

## Before you begin

### Requirements

- Windows PowerShell 5.1.
- Network access to the target SQL Server or D4A site.
- A SQL login with permission for the selected database operation.
- A user-writable folder for IT Tools.
- Administrator rights for service permissions, disk MFT scans, and Scheduled Task deployment or updates.
- Node.js and npm when deploying email-enabled site monitoring.

The script offers to install these PowerShell modules for the current user when required:

- `SqlServer` for database tools;
- `ImportExcel` for XLSX imports.

### Installation

1. Download or clone the complete repository to `Desktop\IT Tools`, `Documents\IT Tools`, or another approved user-writable folder.
2. Keep the main script, manifest, version file, and companion files together.
3. Open Windows PowerShell. Use **Run as Administrator** for operations that require elevation.
4. Change to the toolkit folder and start the script.

```powershell
Set-Location 'C:\Users\YourUser\Desktop\IT Tools'
.\IT_Tools_Database_Translations_and_Server_Checks.ps1
```

If Windows has marked a downloaded file as blocked:

```powershell
Unblock-File -LiteralPath '.\IT_Tools_Database_Translations_and_Server_Checks.ps1'
```

### Automatic updates

At startup, IT Tools resolves the latest `main` commit through GitHub, then compares its embedded version with that commit's `version.txt`. If an update exists, it downloads the manifest and release files from that immutable commit to a temporary folder, validates SHA-256 hashes, parses the new main script, installs only verified files, verifies the version and hash written to disk, and shows an update summary. If the GitHub API is unavailable, it falls back to the `main` URL with finite verified retries. This works when the installed release is several versions behind. The summary remains visible until you press a key; IT Tools then reloads the verified version in the same PowerShell window. Right-click **Run with PowerShell** remains supported because the updater resolves and replaces the executed script path.

Deployed monitoring scripts update independently. New deployments use `D4A-ScheduledMonitor.ps1`. At the beginning of every scheduled or manual monitor run, the monitor compares its embedded version with `monitor-version.txt`, then verifies its matching definition and file hash in `update-manifest.json`. A newer verified monitor replaces the installed script at the same path after backing up its script, configuration, and related Scheduled Task definitions. Existing `D4A-ScheduledMonitor-v5.ps1`, `v6`, and other versioned filenames remain supported and update in place without changing their Scheduled Task path. The current health check finishes with the existing code; the next scheduled run uses the new version. Use `-SkipAutomaticUpdate` only for a troubleshooting run.

To verify healthy operation in Discord without sending an email, use **Site Monitoring > Execute Monitoring Commands > Run monitoring and send concise Discord status**. The action runs the full scan and sends endpoint availability, service status, and CPU, memory, and disk usage to the configured webhook.

During **Add New Site Monitoring**, enter the Discord webhook URL after the email recipients, or press Enter to skip Discord. The wizard accepts `P` to return to the previous answer before deployment begins; use `q` to cancel safely. The webhook is stored only in `monitor-logs\D4A-ScheduledMonitor.config.json` and is not displayed in the deployment summary or written to logs.

If the script folder is not writable, run PowerShell as Administrator or move the full toolkit to a user-owned folder. Do not manually combine files from different releases.

Before a planned production rollout, review [`CHANGELOG.md`](../CHANGELOG.md) for significant new features, behavior changes, and corrections. The changelog is informational; the updater relies on `version.txt` and `update-manifest.json` for version and integrity decisions.

To skip the network update check for one troubleshooting run:

```powershell
.\IT_Tools_Database_Translations_and_Server_Checks.ps1 -SkipAutomaticUpdate
```

## Navigation and common behavior

The main menu has five areas:

1. Database Tools
2. Local server and file tools
3. Troubleshooting
4. Site Monitoring
5. Logs

Type the displayed number to select an action. Type `q` at a visible prompt to return to the previous menu. After results or errors, press any key when prompted.

For a database session, the script first detects active Decide4Action Data Collector services and lists the configured D4A application databases. Select the numbered database to connect with the existing encrypted application credential; the password is decrypted only in memory using the server's existing `D4AKEY` and `D4AIV` environment variables and is never displayed or logged.

Type `M` at that selection prompt when automatic discovery is unavailable or when a different SQL account is required. Manual mode asks for:

- SQL Server name or instance, for example `localhost` or `SERVER\INSTANCE`;
- database username, default `sa`;
- password, with paste support;
- database selected from the available list.

Always verify the `Connected to: server / database` line before continuing.

Before the first persistent database write in an action, enter your full name when prompted. The tool will not perform the write unless it can append the intervention result to `C:\Users\edit_log.txt`. Read-only searches and diagnostics do not request a name.

## Safety rules for operators

Before confirming a database change:

1. Verify the server, database, table, language, machine, file, and row preview.
2. Confirm that the request or change approval covers this action.
3. Read the typed confirmation word carefully. Do not confirm if the preview is unexpected.
4. Record the backup table name shown after the operation.
5. Review the final counts or sample rows.
6. If an error occurs after a backup or staging table is created, leave it in place and review the daily error log before retrying.

After a database-writing action, verify the confirmation that the intervention was recorded. Use **Logs > Last Actions done by this script** to display the ten newest entries, including operator, action, selected variables, and result.

Confirmed monitoring deployments and configuration changes are recorded in the same action history using the current Windows identity. Monitoring creation records the selected hostnames, recurring frequency, and whether daily monitoring was created; updates record newly added hostnames and notification addresses.

Do not manually delete timestamped backup tables until the retention and rollback need has been reviewed.

## Common workflows

### Translate missing French content

1. Database Tools > Import/Export operations > Export Language File.
2. Select French and choose missing translations only.
3. Translate the target column without changing RootId.
4. Return to Import new Language with a translated CSV file.
5. Select French, choose the translated CSV, review counts, and type `IMPORT`.
6. Review the preview and commit only when the sample is correct.

### Investigate a slow application

1. Run Database Performance > Pending SQL queries.
2. Inspect heavy queries in a relevant time window.
3. Review SQL Server CPU history and table disk usage.
4. Run Local server and file tools > Check system health.
5. Review the monitor's current run/error logs and Nginx evidence.
6. Collect timestamps, session IDs, query text, resource readings, and relevant log samples before escalation.

### Investigate a monitoring alert

1. Read the issue key and timestamp in the notification.
2. Review the matching `error_log` and `run_log` entries.
3. Check the current monitoring configuration and state.
4. Verify the reported site, API, service, or resource independently.
5. Review Watchdog or application-log evidence when referenced.
6. Use a temporary cooldown only for a known issue under active management; otherwise collect the evidence and escalate.

### Investigate missing Data Collector events

1. Trace events in Data Collector for the affected date.
2. Set the incident time window.
3. Search the machine, event, or activity identifier.
4. Exclude known noisy terms if needed.
5. Run `Find-LogGaps.ps1` separately when checking for timestamp gaps over 60 seconds.
6. Compare with monitor and Watchdog evidence before escalation.

### Recover a toolkit database change

1. Stop further changes to the target table.
2. Open Database Tools > Rollback script changes.
3. Select the source feature/table and the correct timestamp.
4. Compare counts and preview.
5. Obtain approval and type `ROLLBACK`.
6. Record the restored backup and the new safety backup.

## Database Tools

### 1. Import/Export operations

#### Export Language File

Purpose: export English root content and one or more selected language columns for translation or review.

Use it when:

- creating a language file for external translation;
- exporting only rows whose target translation is `NULL` or empty;
- comparing several configured languages.

Procedure:

1. Select the export format offered by the menu.
2. Review the language list and select target language IDs.
3. Choose whether to export all content or missing translations only.
4. Choose the output action and location when prompted.
5. Review the generated CSV headers before translation begins.

Expected result: a timestamped language CSV containing `RootId`, English source text, and selected target-language columns.

#### Import new Language with a translated CSV file

Purpose: stage translated CSV rows and migrate non-empty translations into `LanguageTranslations`.

Prerequisites:

- CSV contains a RootId column, an English column, and a target-language column;
- translated cells to import are not blank;
- the selected language ID matches the intended target language.

Procedure:

1. Select an existing language or create a new one when authorized.
2. Select the folder and translated CSV file.
3. Review detected columns, row counts, blank cells, invalid RootIds, and collapsed duplicates.
4. Type `IMPORT` only if the summary is correct.
5. Review the staging-table confirmation and migration preview.
6. Commit or cancel as prompted.

Expected result: existing translations are updated and missing language rows are inserted. Blank translations are not written. A timestamped `LanguageTranslations` backup is retained.

Common errors:

- Missing target column: verify the CSV header and selected language spelling.
- Invalid RootId: correct or remove the affected source row.
- Identity or unique-index failure: keep the staging table and collect the daily error log before escalation.
- Wrong language selected: cancel before commit and restart the import.

#### Import CSV/Excel to database

Purpose: load a CSV or XLSX worksheet into a newly created staging table.

Procedure:

1. Enter a file path, or enter a folder and select a numbered file.
2. Enter a new staging-table name.
3. If the name already exists, choose another name. The tool never overwrites it.
4. Review detected columns and data.
5. Confirm creation and import.
6. Choose whether to migrate a column from the new table to another table.

For XLSX files, approve current-user installation of `ImportExcel` if required.

#### Migrate data between database tables

Purpose: update one destination column from one source column under an operator-supplied SQL relationship or condition.

Procedure:

1. Enter and validate source table and column.
2. Enter and validate destination table and column.
3. Enter the SQL condition that safely joins or filters the rows.
4. Review the preview.
5. Type the requested confirmation.

Expected result: the destination table is backed up before rows are updated.

Escalate if the correct SQL condition is uncertain. Do not guess a join condition in production.

### 2. Danone Features

#### Import Luleburgas System Settings

Purpose: compare and copy standard Luleburgas `AssemblyRules` numeric settings to a newly installed Danone site.

The feature uses `AssemblyRules_Luleburgas.sql`. If missing, IT Tools downloads and verifies the official repository copy only after this feature is selected.

Procedure:

1. Read the deployment description and confirm the selected database.
2. Let the SQL file create and populate the staging table.
3. Review current versus new values.
4. Confirm only when the comparison is appropriate for the site.
5. The tool backs up `AssemblyRules`, applies changes, and removes the staging table.
6. Sign out and back in to the D4A frontend.

#### Import Luleburgas User Roles and Privileges

Purpose: import the approved standard role-administration configuration from `RoleAdminLuleburgaz-DanoneStandard-090426.sql`.

The script identifies existing tables that the SQL may modify and creates timestamped backups before execution. Review the target database and confirmation carefully.

### 3. Check or clean translation data

Available checks:

- Show record counts.
- Find missing translations.
- Review or remove disconnected translation rows.

Disconnected rows exist in `LanguageTranslations` without a matching `RootTranslation` row. Use display or CSV export before considering deletion. Deletion requires `DELETE` and creates a full `LanguageTranslations` backup first.

### 4. Copy activities between machines

Purpose: copy P4A activities from one source machine to one or more destination machines while avoiding duplicate Description/StatusCode combinations.

Procedure:

1. Enter the source machine ID.
2. Enter one or more destination machine IDs separated by commas.
3. Enter one maintenance code or `all`.
4. Review diagnostics and proposed rows.
5. Type `COMMIT` to back up `P4A_LineEquipmentMasterDowntimeCodes` and apply the copy.

Press another key to restart the process or `q` to return without committing.

### 5. Enable Line Detailed View

Purpose: add or repair the database configuration required for the Line Detailed View frontend feature.

The workflow detects every target table, creates timestamped backups, executes the setup transaction, and validates the resulting menu link. After success, enable Line Detailed View for the appropriate role in Role Administration, then sign out and back in.

### 6. Rollback script changes

Purpose: restore a table from a timestamped backup created by IT Tools.

Procedure:

1. Select the originating feature/source table group.
2. Select the backup date and time, newest first.
3. Review source and backup row counts and the preview.
4. Type `ROLLBACK` when certain.

The tool first creates a safety backup of the table's current state. Record both backup names.

### 8. Database Performance

Available diagnostics:

- disk usage per table;
- SQL Server error logs;
- pending SQL queries and start times;
- heavy queries within a selected time window;
- cache-lifetime heaviest queries;
- historical/cached resource-consuming queries;
- SQL Server CPU history from ring buffers.

These actions are read-only unless SQL error-log access is missing and you explicitly approve a permission grant. Query text is abbreviated initially; select a result row when offered to see more.

If a DMV query is denied, provide the SQL username and exact error to the database administrator.

### 9. Database Search Tools

Available searches:

- text in character columns across database tables;
- tables containing a specified column name;
- text inside stored procedure definitions.

For column names, include `%` where partial matching is wanted, for example `%SMTP%`; omit it for an exact match.

Database text search can be expensive. The tool shows database size and recommends excluding tables over 50 MB when the database exceeds 2 GB. Use `0` only when an unrestricted scan is approved and enough time is available.

### 10. Change SQL Server connection

Use this last menu option to disconnect and select another instance or database. Verify the new connection banner before any operation.

## Local server and file tools

### Search for text in files

Searches files below a selected folder using text and file filters. Searches have a finite 10-minute limit for large folders; use a narrow path and extension whenever possible to reduce execution time.

### Check system health

Collects operating system, CPU, memory, disk, and performance information with timestamped progress. CIM and performance operations have finite timeouts. A timeout is recorded in the daily error log instead of hanging the session indefinitely.

### SSL Checker

Enter a domain, subdomain, or full HTTPS URL. The checker validates DNS resolution, TCP reachability, the TLS handshake with SNI, hostname/SAN matching, certificate dates and key strength, Windows chain trust, online CRL/OCSP status, TLS protocol support, HTTPS redirects, HTTP-to-HTTPS behavior, and static mixed-content references. A domain uses port `443`; a full URL can include a non-default HTTPS port. Redirect and mixed-content checks always run. Each network step has a 15-second timeout, and certificate trust errors are reported rather than bypassed.

### Show recently created or changed files

Lists files created or modified within the selected period. Use it to identify recent configuration, log, export, or deployment changes.

### Analyze disk usage (visual report)

IT Tools calls `D4A-DiskSpaceAnalyzer.ps1` from the same folder. If missing, the verified official file is downloaded when this feature is selected.

Choose the disk partition, then optionally narrow the folder. The analyzer returns large folders and files plus a visual report. Run PowerShell as Administrator for fast MFT mode. Auto mode falls back to directory traversal.

Stand-alone examples:

```powershell
.\D4A-DiskSpaceAnalyzer.ps1 -Verbose
.\D4A-DiskSpaceAnalyzer.ps1 -Drive D: -SearchDirectory 'D:\Backups' -ThresholdMB 512
.\D4A-DiskSpaceAnalyzer.ps1 -Drive D: -ThresholdMB 1024 -NoGui -SingleRun
```

### Manage SQL backup folder permissions

Purpose: identify SQL Server Database Engine and Agent service accounts and grant Modify access to an approved backup folder.

Workflow:

1. Enter a valid folder path.
2. Select account-name or full-account detection, or one of the two permission actions.
3. Review the exact folder and account principals.
4. Type `GRANT` only when correct.
5. Review the separate green success or red failure result for each account.

Administrator rights are normally required.

### Check if a port is open

Enter a remote IP/hostname or press Enter for `127.0.0.1`, then enter a TCP port. The result includes reachability details equivalent to `Test-NetConnection`.

### Trace events in Data Collector

Purpose: search large or active Data Collector daily logs without requiring the service to stop. The search keeps visible progress and has a finite 10-minute limit.

Procedure:

1. Confirm the detected `Data Collector\Logs` folder or select a candidate.
2. Press Enter for today's `Log-yyyyMMdd.txt`, choose one of the five newest files, or enter a date as `yyyyMMdd`.
3. Enter the required search word or phrase.
4. Enter start/end times as `HH:mm` or `HH:mm:ss`; press Enter for day boundaries.
5. Enter up to three exclusion terms, pressing Enter when finished.

The file is opened with read/write sharing so a currently active Data Collector log can be searched.

## Troubleshooting

### DBConfig.js Diagnostic

Use **Troubleshooting > DBConfig.js Diagnostic** to inspect a D4A `dbconfig.js` file. The feature downloads `Test-DBConfigFile.ps1` only when it is first selected, verifies its SHA-256 against the release manifest, validates PowerShell syntax, and launches its guided diagnostic. The companion detects active Decide4Action or D4A Data Collector service paths, normalizes the installation root, and finds `Services\API\dbconfig.js`. When multiple D4A installations are found, it lists the full paths and prompts for a number; type `M` to enter a different path manually. It then offers default or custom checks for JavaScript syntax, exported database declarations, certificate paths, SMTP reachability/authentication, and database connectivity. Its detailed report remains visible in the same PowerShell window after the scan finishes. Type `q` or press Enter at its path prompt to return. Once downloaded, the companion is automatically updated whenever a later IT Tools release includes a newer verified version.

## Site Monitoring

### Add New Site Monitoring

Purpose: deploy a configuration-driven D4A health monitor and optional Scheduled Tasks.

Prerequisites:

- run IT Tools as Administrator;
- Node.js/npm available, or Administrator access to approve its guided WinGet installation;
- Decide4Action service installed or a known Configuration folder;
- approved notification recipients;
- outbound email path available and, when Discord delivery is required, outbound HTTPS access to `discord.com`.

Procedure:

1. Enter one or more frontend sites separated by commas. Press Enter for `hostname:1200`.
2. Enter one friendly name for each site, then confirm or override the API health endpoint for each frontend site.
3. Confirm or select the Configuration deployment folder.
4. Enter one or more notification addresses separated by commas. An optional Discord webhook can be added afterward to the local monitoring JSON configuration; keep this credential out of shared files and screenshots.
5. Review the complete deployment summary and type `DEPLOY`.
6. If Node.js/npm are absent, type `INSTALL` to install or repair the official Node.js LTS package. Node.js, npm, and nodemailer are validated before new monitor files are created.
7. Choose a recurring frequency; 5 minutes is the recommended default unless the site requires another interval.
8. Type `CREATE` to register the silent recurring task under `SYSTEM`.
9. Optionally configure the daily healthy-status email and its server-local time.
10. Run the first test email when prompted.

Expected result:

- monitor script copied and unblocked;
- nodemailer installed;
- configuration stored in `monitor-logs\D4A-ScheduledMonitor.config.json`;
- Scheduled Task runs silently, including when users are logged out;
- test email confirms delivery; a configured Discord webhook receives the same test result.

If an earlier deployment stopped after creating the monitor/configuration but before Scheduled Tasks were created, the tool can identify that specific incomplete state even when nodemailer finished installing before the error appeared. It displays **Resume incomplete deployment** and requires `RESUME`; the existing JSON is preserved and backed up while runtime paths are repaired. An active or modified monitor is never treated as an incomplete deployment and must be managed through **Update Existing Monitoring Settings**.

### Update Existing Monitoring Settings

This menu separates three operations:

1. Update sites, friendly names, and notification emails.
2. Update monitoring script version while preserving local configuration and tasks.
3. Update Scheduled Tasks to run silently as `SYSTEM`.

The configuration update creates a settings backup. Version update first retrieves and verifies the current official GitHub monitor, even when an older template already exists beside IT Tools. If a related Scheduled Task is still running after you confirm `UPDATE`, IT Tools checks it every five seconds, displays elapsed progress, and continues automatically when it finishes. The wait has a 15-minute safety timeout. The update then backs up the installed monitor, JSON configuration, and Scheduled Task definitions. You do not need to delete or rename the local template to receive the latest version. Do not delete `monitor-backups` until the new version has completed normal runs.

The monitor also checks GitHub for its own newer verified version whenever it runs, including Scheduled Task and stand-alone executions. It bypasses cached release responses, validates the release manifest, SHA-256, version metadata, release date, PowerShell syntax, and current JSON configuration; then backs up the installed script, configuration, and related task definitions before replacing its own file. A lock prevents two Scheduled Tasks from installing concurrently. The current health check continues with the loaded version, and the new code is used on the next run. Use `-SkipAutomaticUpdate` only for a temporary troubleshooting execution.

Monitoring configuration is read and written explicitly as UTF-8, so friendly names with accents, such as `Salé`, remain readable in email subjects and Discord messages. Existing corrupted forms such as `SalÃ©` are repaired when loaded. Monitoring emails display **D4A Monitoring** as their sender name while keeping the site’s configured sender address. New and updated configurations include `DiscordWebhookUrl` directly after the email recipients with the safe placeholder `your Discord webhook URL`; replace that value with the site webhook to enable Discord. JSON does not support comments, so `DiscordWebhookUrlNote` documents the setting. The configuration summary reports only `Configured`, never the URL itself. Discord recovery notices show both the alert-time value and the current recovered value. Historical state values, including legacy accented site names, are repaired before display.

Each `SiteAddress` entry has a matching `ApiAddress` entry in `monitor-logs\D4A-ScheduledMonitor.config.json`. During new deployment, IT Tools asks for the API address for every frontend site; press Enter to keep the derived default, such as `https://site-api.example.com/health`, or provide a different API host or full health path. Use **Site Monitoring > Update Existing Monitoring Settings > Update sites, API addresses, monitoring name, and notification emails** to change an installed site's API address. Existing configurations without `ApiAddress` are automatically populated with their current derived endpoints after the updated monitor runs.

`LocalApiAddress` controls the Direct API performance probe run from the monitored server. New configurations use `http://127.0.0.1:32167/`. If the local D4A API listens on another loopback host or port, edit that single value in the same JSON file, then run the monitor with `-ValidateConfiguration`. Existing monitor configurations receive the setting automatically after version 7.4.2 starts, with a one-time pre-migration JSON backup retained beside the configuration.

The monitor automatically discovers and checks local SQL Server Database Engine (`MSSQLSERVER` and `MSSQL$<instance>`), SQL Server Agent (`SQLSERVERAGENT` and `SQLAgent$<instance>`), and SQL Server Browser services. It also checks any detected Node-RED, Nginx, reverse proxy, IIS, World Wide Web Publishing Service, or Internet Information Services Windows service. Each detected service must be `Running/OK` or it produces a service alert and later recovery notification. SQL CEIP telemetry and SQL VSS Writer are intentionally excluded because they do not determine database availability.

### Execute Monitoring Commands

The menu exposes common management and test commands:

| Action | Stand-alone command argument |
|---|---|
| Add site(s) persistently | `-AddSiteAddress 'site1,site2'` |
| Show configuration | `-ShowConfiguration` |
| Run test and send complete notification | `-SendTestResultsEmail` |
| Run normal check | no additional argument |
| Send daily summary now | `-SendDailySummaryEmail` |
| Validate configuration only | `-ValidateConfiguration` |
| Temporarily test site(s) | `-SiteAddress 'site1,site2' -SendTestResultsEmail` |
| Extended CPU test | `-CpuSampleDurationSeconds 120 -SendTestResultsEmail` |
| Run email-only | `-DisableDiscord` |
| Run Discord-only | `-DisableEmail` (requires `DiscordWebhookUrl`) |
| Set cooldown | `-SetIssueCooldown 'issue-key' -IssueCooldownDuration '12h'` |
| Clear cooldown | `-ClearIssueCooldown 'issue-key'` |
| Skip monitor update check once | `-SkipAutomaticUpdate` |

Use the IT Tools menu when possible because it discovers installed monitors, displays the exact command, and records command failures in the main daily error log.

## Understanding monitoring output

The default log folder is `Configuration\monitor-logs`.

| File | Contents |
|---|---|
| `run_log_yyyyMMdd.txt` | Run start/end, configuration, successful checks, warnings, email/Discord actions, and diagnostics |
| `error_log_yyyyMMdd.txt` | Warnings, alerts, errors, and supporting evidence |
| `ignore-rules.txt` | Active temporary, permanent, and automatic notification-suppression rules |
| `D4A-ScheduledMonitor.config.json` | Site-specific settings and schedule metadata |
| `D4A-ScheduledMonitor.state.json` | Consecutive-failure state and successfully notified issue history used for explicit recovery emails |
| `README.txt` | Local monitoring behavior and manual command examples |

The monitor keeps five days of dated monitoring logs by default. Ignore-rule archives rotate on the 3rd, 13th, and 23rd and retain the three newest archives.

Normal endpoint behavior:

- slow frontend/API response above 4,500 ms: log only;
- unreachable endpoint after retries: alert if not covered by a rule;
- CPU or RAM at least 90 percent for one run: log only;
- CPU or RAM at least 90 percent for two consecutive runs: alert;
- Data Collector SQL timeout while service runs: degrade/retry before persistent alert;
- Nginx errors: alert only above 20 errors/minute for two consecutive minutes;
- relevant Windows event warning/error while services remain available: `error_log` and daily/test reports only;
- disk space: no warning notification; critical alert at 5 GB free or less, or 95 percent used or more;
- previously notified issue later returns `OK`: one recovery email and, when configured, Discord notification; then its recovery state and automatic cooldown are cleared;
- one immediate issue: subject identifies component and level, such as `API Alert` or `Disk Space Critical`; multiple issues use `Multiple Alerts detected`.

The monitor reports and collects evidence. It does not restart services.

## Logs

### Last Actions done by this script

This read-only menu displays the ten newest lines from `C:\Users\edit_log.txt`. Database intervention entries include the date/time, operator name entered before execution, intervention name, selected non-sensitive variables, and a `Success` or `Failed` result. Monitoring creation and update entries use the current Windows identity and include the relevant hostnames, schedule or daily-monitoring status, and newly added notification addresses. The daily detailed error files remain under the IT Tools `Logs` folder and provide stack traces when troubleshooting is required.

## General troubleshooting

### The script will not start

- Confirm Windows PowerShell 5.1.
- Run from a complete repository folder.
- Use `Unblock-File` if Windows blocked the download.
- Check `Logs\tools_script_error_log_yyyyMMdd.txt`.
- Run once with `-SkipAutomaticUpdate` only to separate startup/update issues.

### Database connection fails

- Verify server/instance, network path, username, and selected database.
- Confirm SQL authentication is allowed for the account.
- Let the tool use optional encryption and trusted-certificate compatibility.
- If `Invoke-Sqlcmd` is missing, type `INSTALL` when offered.
- Escalate repeated login or permission failures with the full daily error entry.

### An import shows no eligible rows

- Verify the target-language header.
- Confirm translated cells are non-empty.
- Check RootId values and selected language.
- Review the skipped-row summary before changing the file.

### A database operation fails after a backup or staging table was created

- Do not delete the backup or staging table.
- Do not immediately rerun the action.
- Record the table names and timestamp.
- Open the daily main error log and provide the full relevant entry to Level 2 or the database administrator.

### Monitoring does not send notifications

- Run Show current monitoring configuration.
- Run Validate monitoring configuration.
- Run the test-notification mode.
- Review both daily logs for nodemailer, SMTP, recipient, Discord, or configuration errors.
- Confirm the Scheduled Task uses the expected script and configuration paths.

### Monitoring reports an alert

- Read the alert details and issue key.
- Review the same timestamp in `error_log` and `run_log`.
- Check whether Watchdog evidence identifies a root cause.
- Verify service state and site/API reachability independently.
- Use a temporary cooldown only when the issue is known and actively managed.

### Update fails

- Keep using the current version; the updater does not intentionally install unverified content.
- Verify access to GitHub and write access to the script folder.
- Review the daily main error log.
- Do not manually overwrite only one release file.

## Escalation checklist

Before escalating, collect what applies:

- server name and database name;
- selected feature and exact target;
- date/time and timezone;
- confirmation word entered;
- backup and staging table names;
- full daily IT Tools error entry;
- monitor version, configuration path, and task name;
- relevant monitor run/error log excerpts;
- service state, URL, port, machine ID, RootId, or SQL session ID;
- expected result versus actual result;
- whether the action was retried and what changed between attempts.

Stop and escalate when:

- the target database or table is uncertain;
- a preview contains unexpected rows;
- the required SQL condition is not fully understood;
- a backup cannot be created;
- permissions would need to be broadened beyond the approved operation;
- a production monitor update cannot preserve its configuration or tasks;
- the same operation fails repeatedly after the cause has been logged;
- the requested work falls outside the approved support procedure.

## Security and operational notes

- Do not commit passwords, SMTP credentials, customer configuration, logs, state, or ignore rules to the repository.
- Store credential files according to the site's approved access controls.
- Prefer least-privilege SQL and Windows accounts.
- Treat generated CSV and Excel files as potentially sensitive database exports.
- Use backup and rollback features as safety mechanisms, not substitutes for approved database retention.
- Validate monitoring recipients before sending test or production alerts.
