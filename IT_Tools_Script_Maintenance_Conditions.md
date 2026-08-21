# IT Tools Script Maintenance Conditions

These conditions must be respected whenever `IT_Tools_Database_Translations_and_Server_Checks.ps1` is edited.

## Safety and rollback
- Before any feature changes existing database data, create a full backup of every target table that will be edited.
- Backup table names must use the exact source table name followed by `yyyyMMddHHmmss`, for example `LanguageTranslations20260707143015`.
- Do not modify `RootTranslation` unless the user explicitly asks for that table to be changed.
- Never overwrite, drop, or reuse an existing backup table name.
- For destructive or broad operations, show a preview and require a typed confirmation such as `IMPORT`, `MIGRATE`, `COMMIT`, `DELETE`, `RESTORE`, or `ROLLBACK`.
- Rollback-compatible changes should use the standard backup naming convention so the `Rollback script changes` feature can discover them.

## User flow
- Every menu or prompt must allow the user to type `q` to return to the previous menu. Existing `b` and `back` support may remain, but visible prompts should prefer `q`.
- After displaying results, errors, or completion messages, prompt the user to press any key before returning to the previous menu.
- Keep menus numbered and easy to scan. Avoid hidden actions.
- Show the target server, database, file path, table name, or folder path before applying changes.
- If user input references a table, column, folder, or file, validate that it exists before continuing.
- Refuse dangerous table names or identifiers. Use safe SQL quoting helpers for table and column names.

## Logging and errors
- Export full errors to the daily log file under the script `Logs` folder.
- Before any persistent database write, require the operator's full name and verify that `C:\Users\edit_log.txt` is writable. Record one concise line containing the intervention date/time, operator name, intervention name, selected non-sensitive variables, and a success or failure result. Read-only database operations must not prompt for an operator name.
- Never include database passwords, credentials, connection strings, tokens, full SQL text, or other secrets in the shared IT Tools action log.
- Record confirmed monitoring creation and monitoring configuration-update actions in `C:\Users\edit_log.txt` using the same timestamp, Windows identity, action, non-sensitive variables, and success/failure structure. Creation entries must include site hostnames, schedule frequency, and daily-monitoring status; update entries must identify newly added hostnames and notification addresses.
- Short errors can be shown in the PowerShell window. Long errors should be summarized in the window and point to the log file.
- Prefer `Show-LoggedError` for catch blocks in database features.
- Do not let raw exceptions close the session without a readable message and a pause.

## Progress and output
- Use `Write-StreamingLog` for operations that may take time, especially file reads, SQL file execution, backup creation, bulk imports, migrations, deletes, restores, and synchronization steps.
- For server checks involving deep directory scans, massive file counts, or heavy WMI/CIM queries, enforce execution timeouts to prevent the script from hanging indefinitely.
- SSL and network health checks must use finite connection and request timeouts, and must report certificate trust findings rather than bypassing them.
- Show readable previews before data-changing actions. For large datasets, show summaries and `top 20` style previews.
- After changes complete, print a concise success message with rows affected and backup table name.
- For per-item operations, show success in green and failures in red with the encountered error line.

## Database patterns
- Use existing connection helpers, SSL-tolerant SQL helpers, and table/column existence checks.
- Prefer `New-DatabaseTableBackup` for generic table backups and `New-LanguageTranslationsBackupTable` only where existing translation-specific behavior requires it.
- Use transactions for multi-step database writes when feasible.
- Do not update or insert rows with blank translated content.
- Avoid duplicate inserts by checking existing rows when copying or importing mapped data.
- When executing external SQL files, create backups for detected existing target tables before execution whenever possible.
- Keep database-wide searches read-only. Quote or parameterize user text, show the database size, offer large-table exclusions for databases over 2 GB, and use a finite query timeout for deep scans.
- Keep database performance diagnostics read-only and use finite query timeouts. If a diagnostic requires a SQL permission change, show the affected account and require an explicit confirmation before applying it.

## File editing and validation
- Keep the working copy in `C:\Users\kbarbar\Documents\D4A random tasks`, validate it, then publish the release to the `main` branch of `https://github.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools`.
- Do not use `PowerShell scripts` as the deployment source after the GitHub release workflow is available.
- Do not create a local backup of IT Tools when the automatic updater replaces the script. The GitHub release history is the distribution rollback source.
- Validate PowerShell syntax before committing and after replacing the local script during release verification.
- Do not execute real database changes while editing unless the user explicitly asks for a live run.
- Preserve existing user changes and do not revert unrelated work.

## GitHub distribution and versioning
- The `main` branch of `https://github.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools` is the canonical distribution source for IT Tools and its companion files.
- Every release must update `version.txt`, `update-manifest.json`, and the embedded `$Script:ToolVersion` value in `IT_Tools_Database_Translations_and_Server_Checks.ps1` together.
- Start this release line at `7.0.0`. During the same ISO calendar week, increment the patch segment (`7.0.1`, `7.0.2`). In a later week, increment the minor segment and reset the patch (`7.1.0`, `7.2.0`). Increment the major segment only for a substantial breaking or architectural change, or when explicitly requested.
- The manifest must list every automatically distributed file with a SHA-256 hash. Do not include site-specific configuration, logs, credentials, or `monitor-logs` content.
- Automatic update checks must use HTTPS, download to a temporary folder, validate every SHA-256 hash and the PowerShell parser before replacing files, and leave the current version running if an update cannot be safely applied. The automatic updater may update companion files that already exist locally, but must not download missing companion files.
- After an automatic update, revalidate the installed main-script hash and embedded version, keep the update summary visible until the user presses a key, then reload the verified script in the same PowerShell session. The old script must not continue to its menu.
- Treat temporarily inconsistent GitHub `version.txt` and update-manifest responses as a release-synchronization delay: show retry progress and use finite retry limits before reporting a logged update error.
- If an official companion SQL or PowerShell file required by a feature is missing beside IT Tools, download it only after the user selects the feature that requires it. Download from the GitHub raw release URL to a temporary folder, validate its SHA-256 against `update-manifest.json`, then copy it locally only after verification. Clearly explain the download to the user; never overwrite an existing companion file or leave a partial file behind.
- When a local script directory is not writable, instruct the user to run as Administrator or from a user-owned Desktop or Documents folder instead of attempting a partial update.

## Site monitoring releases and configuration
- Validate Node.js, npm, and nodemailer before creating files for a new monitoring deployment. Resolve installed runtimes from both `PATH` and standard Windows installation metadata, record an absolute `node.exe` path in configuration, and never leave a new monitor/configuration pair solely because a prerequisite was missing.
- Never overwrite an existing monitor while retrying setup. Resume only a positively identified incomplete deployment, preserve its settings, and back up the JSON configuration before repairing runtime paths.
- Keep site-specific monitoring settings in `monitor-logs\D4A-ScheduledMonitor.config.json`; do not inject them into the monitoring script source.
- Read and write monitoring JSON explicitly as UTF-8. Preserve non-ASCII site names in subjects and configuration updates; repair known UTF-8/Windows-1252 mojibake only in user-facing monitoring name fields.
- Command-line monitor parameters must override JSON configuration values, and JSON values must override built-in defaults.
- Preserve each deployed monitor filename because production files may use names such as `D4A-ScheduledMonitor-v5.ps1`, `D4A-ScheduledMonitor-v6.ps1`, or `D4A-ScheduledMonitor-v7.1.2.ps1`.
- Store the monitoring version and release date in machine-readable header comments inside the monitoring script so IT Tools can display and compare them.
- Keep the current major release at `6.0`. Future feature releases use `6.1.0`, `6.2.0`, and so on. Same-day minor corrections may use a patch version such as `6.2.1`. Do not change the major version to `7.0` or above without an explicit user request.
- Monitoring version updates must back up the installed script, JSON configuration, and related Scheduled Task definitions before replacement.
- Monitoring version updates must preserve site settings, logs, ignore rules, installed filename, Scheduled Task triggers, frequency, task identity, and background-execution settings.
- Before comparing an installed monitor version, IT Tools must download and verify the current official monitoring release. Never use only the companion file beside IT Tools to conclude that an installed monitor is current; refresh an outdated local template without requiring the user to delete it.
- When a manual monitoring version update finds a related Scheduled Task running, wait and refresh its state every five seconds, show elapsed progress, and continue automatically when it finishes. Enforce a finite timeout so a stuck task cannot block IT Tools indefinitely.
- Every monitoring execution must check the verified GitHub release for a newer monitoring version unless `-SkipAutomaticUpdate` is explicitly used. Validate the manifest SHA-256, version metadata, release-date metadata, and PowerShell syntax before replacement; if any check fails, keep the installed version and continue the monitoring run.
- Monitoring self-updates must bypass HTTP caches, prevent simultaneous Scheduled Tasks from installing the same update, validate the current JSON configuration with the downloaded release, update installed-version metadata, and restore both script and configuration backups if installation fails.
- Keep Windows-event warnings and errors as log-only evidence; service availability checks are the authority for immediate service alerts.
- Do not send disk-space warning emails. Send a critical disk alert only at 5 GB free or less, or 95 percent used or more.
- Persist only successfully emailed notification-eligible issues for recovery tracking. Send one recovery email only after the same check explicitly returns `OK`; never infer recovery merely because a check or result is missing.
- For normal alert emails, use a component-and-level subject for one issue and `Multiple Alerts detected` when more than one distinct notifiable issue is present.
