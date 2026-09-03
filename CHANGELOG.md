# Changelog

This file records significant changes to the D4A IT Automation and Operations Toolkit. Small wording, formatting, and other minor adjustments are intentionally omitted.

The main IT Tools script and the scheduled monitoring component use separate versions because monitor code can be upgraded independently while preserving site-specific configuration and Scheduled Tasks.

For project context, architecture, and operating procedures, see the [project overview](docs/01-project-overview.md), [technical design](docs/02-technical-design.md), and [technical user guide](docs/03-user-guide.md). `version.txt` and `update-manifest.json` remain the machine-readable sources used by the automatic updater; this changelog is the human-readable release history.

## 7.4.8 - 2026-09-03

- Fixed DBConfig Diagnostic 1.5.1 so the detailed scan report is rendered in the same PowerShell window after interactive launch instead of being lost in a child process.

## 7.4.7 - 2026-09-03

- Updated DBConfig Diagnostic to 1.5.0. It discovers D4A `dbconfig.js` files from active Data Collector service executable paths, lists multiple detected installations by full path, and retains manual selection when discovery is unavailable.

## 7.4.6 - 2026-09-02

- Added **Troubleshooting** as the third top-level menu and the on-demand **DBConfig.js Diagnostic** feature. It downloads `Test-DBConfigFile.ps1` only when selected, verifies its manifest hash and PowerShell syntax before launch, and automatically refreshes an existing downloaded copy through future IT Tools releases.
- Added DBConfig Diagnostic 1.4.1 with `q` support at the interactive configuration-path prompt.

## 7.4.5 - 2026-09-02

### Monitoring 7.4.2 - 2026-09-02

- Added the editable `LocalApiAddress` setting for the Direct API performance probe. New deployments write `http://127.0.0.1:32167/`; existing canonical and legacy monitoring configurations add it automatically with a one-time pre-migration backup, preserving all public site and API endpoint settings.

## 7.4.4 - 2026-09-02

- Corrected automatic-update integrity validation to use the exact LF byte stream published by GitHub rather than local Windows line endings. The updater now provides the SHA-256 verification reason while it retries a temporarily inconsistent release.

## 7.4.3 - 2026-09-02

### Monitoring 7.4.1 - 2026-09-02

- Added configurable API endpoints aligned with each frontend site in `D4A-ScheduledMonitor.config.json`. New deployments and site-addition workflows prompt for an API endpoint per site, with Enter retaining the established derived default. Existing configurations are migrated safely to their current derived API endpoints and can be updated through **Update Existing Monitoring Settings**.

## Monitoring 7.4.0 - 2026-09-02

- Added Windows-service monitoring for detected Node-RED, Nginx, reverse proxy, IIS, World Wide Web Publishing Service, and Internet Information Services services. A service outside `Running/OK` uses the established alert and recovery notification workflow.

## 7.4.2 - 2026-09-01

- Simplified automatic D4A database selection: the connection screen now refers to active Decide4Action installations and displays only numbered database names.

## 7.4.1 - 2026-09-01

- Added automatic Database Tools connection discovery for active Decide4Action Data Collector installations. The toolkit resolves each installation's `Services\API\dbconfig.js`, selects its configured database, decrypts the existing password only in memory using the installed `D4AKEY` and `D4AIV` environment variables, and verifies the connection before starting the session.
- Retained the existing username/password workflow as an explicit manual fallback available by typing `M` at the automatic database-selection prompt.

## 7.4.0 - 2026-09-01

- Extended user-initiated file searches, Data Collector event tracing, and recent-file scans to a finite 10-minute timeout, with clear progress messaging for large folders and logs.
- Removed duplicate Monitoring release headings from the changelog.

### Monitoring 7.3.0 - 2026-09-01

- Added automatic database service monitoring for installed SQL Server Database Engine instances, SQL Server Agent instances, and SQL Server Browser. A detected service that is not `Running/OK` sends the existing service alert and recovery notification. SQL CEIP telemetry and SQL VSS Writer are excluded.

## 7.3.1 - 2026-08-31

### Monitoring 7.2.0 - 2026-09-01

- Corrected mojibake in recovery notifications by repairing historical alert state before rendering the check name, category, alert value, and current value.

### Monitoring 7.1.2 - 2026-08-31

- Recovery notifications now display the alert-time value and the current recovered value for resource, endpoint, and service checks. Existing alert state created by an earlier version remains compatible and identifies when an original measurement is unavailable.

### Monitoring 7.1.1 - 2026-08-31

- Corrected Discord embed rendering so line breaks and Markdown markers are sent as actual Discord formatting rather than literal PowerShell escape text.
- Standardized the notification time as `DAY HH:MM:SS` and strengthened legacy UTF-8/Windows-1252 name repair for accented monitoring names.
- Added a safe Discord webhook placeholder and explanatory note to new and automatically updated local monitoring configurations. The placeholder is not treated as a configured credential.

## 7.3.0 - 2026-08-31

### Monitoring 7.1.0 - 2026-08-31

- Reworked Discord embeds with preserved line breaks, readable sections, and Discord-rendered severity markers for alerts, warnings, site/API outages, and recovery notifications.
- Added an optional Discord webhook step to the new-monitor deployment wizard. The URL is validated, stored only in the local JSON configuration, and never displayed, logged, or committed.
- Added `P` navigation to return to the previous answer during the safe monitoring-deployment selection wizard before files, packages, or Scheduled Tasks are changed.

## 7.2.3 - 2026-08-28

### Monitoring 7.0.1 - 2026-08-28

- Added a **Run monitoring and send concise Discord status** command under Site Monitoring > Execute Monitoring Commands.
- The Discord-only status runs the full health check and sends a compact summary even when healthy, with endpoint availability, D4A and Mosquitto service status, and CPU, memory, and disk usage. It does not send an email or change alert cooldown and recovery state.

## 7.2.2 - 2026-08-28

### Monitoring 7.0.0 - 2026-08-28

- Renamed the canonical monitoring release to `D4A-ScheduledMonitor.ps1` for all new deployments.
- Added a two-channel verified update definition: the canonical file is used by new deployments, while `D4A-ScheduledMonitor-v5.ps1` remains an identical compatibility payload for installed versioned monitors.
- Existing monitor files continue to update in place with their current filename and Scheduled Task path, including older `v5`, `v6`, and custom versioned filenames; no manual rename is required.

## 7.2.1 - 2026-08-25

### Monitoring 6.10.3 - 2026-08-28

- Added optional Discord webhook delivery alongside the existing email path for alerts, recovery notices, test runs, and daily summaries.
- Discord uses compact native embeds that identify the site, notification type, affected component, server, timestamp, diagnostic details, rule key, and monitoring log; webhook credentials stay only in the local JSON configuration and are never written to logs or release files.
- Email and Discord deliveries are isolated so an issue in one channel does not block the other. Existing cooldown and recovery state remains tied to successful email delivery to preserve the established alert policy.

### Corrected

- SSL Checker now uses an explicit TLS 1.2 handshake rather than the legacy-incompatible `SslProtocols.None` value.

### Monitoring 6.10.2

- Automatic monitoring-update backups are now created only after the downloaded release and local configuration validate. Only successful updates retain a backup, the newest three folders are kept, and a failed-update backup is removed after a successful restore.
- Safely handle Scheduled Task action types that do not expose an `Arguments` property, preventing the prior automatic-update warning.

### Monitoring 6.10.1

- Certificate inspections now explicitly negotiate TLS 1.2. SSPI and legacy TLS-runtime inspection failures are recorded as non-notifiable warnings because endpoint availability is checked independently.

## 7.2.0 - 2026-08-25

### Corrected

- Forced TLS 1.2, and TLS 1.3 where supported, before GitHub API and release-file requests. This resolves companion-script download failures on Windows PowerShell sessions that inherit obsolete TLS defaults, without bypassing certificate validation.
- Applied the same verified download path to on-demand companion files, including the monitoring template used by **Add Site Monitoring**.

### Monitoring 6.10.0

- Monitoring self-updates now explicitly enable TLS 1.2, and TLS 1.3 where available, before contacting GitHub.

## 7.1.16 - 2026-08-21

### Corrected

- Automatic updaters now resolve the current `main` commit through GitHub and download the manifest, IT Tools, and monitoring files from that immutable commit. This prevents CDN cache skew between individual release files; a verified retry fallback remains available if the API cannot be reached.

### Monitoring 6.9.2

- Monitoring now resolves the same immutable GitHub commit for its release metadata and script download, avoiding mixed monitoring-version responses during an update.

## 7.1.15 - 2026-08-21

### Corrected

- Corrected GitHub release SHA-256 values to hash the exact `LF` files distributed by GitHub rather than local `CRLF` working copies. This resolves false integrity failures for the IT Tools script and companion files.
- IT Tools now retries each manifest-listed file download with a fresh cache-busting request until its verified hash matches, so a temporary GitHub/CDN mismatch cannot block a multi-version update.

### Monitoring 6.9.1

- Monitoring release downloads now use a fresh cache-busting URL on every retry and require a matching SHA-256 before installation, supporting safe upgrades from older monitor releases.

## 7.1.14 - 2026-08-21

### Changed

- Updated the main menu title to display the installed IT Tools version and release date, and reordered Local server and file tools so recent-file review is option 7 and Data Collector event tracing is option 8.

## 7.1.13 - 2026-08-21

### Corrected

- Simplified SSL Checker to one domain/subdomain or HTTPS URL prompt. The supplied hostname now drives DNS, TCP, and SNI validation; redirect and mixed-content checks always run automatically. A plain hostname uses port 443, while an HTTPS URL may retain an explicitly specified port.

## 7.1.12 - 2026-08-21

### Corrected

- Defined independent update channels for IT Tools and Monitoring. `version.txt` now applies only to IT Tools, while `monitor-version.txt` and the manifest `monitoring` definition identify the monitor release.
- Monitoring runs now require the monitor version, manifest definition, script filename, release date, and SHA-256 values to agree before code is downloaded or installed. Inconsistent GitHub/CDN responses are retried every five seconds for up to one minute and recorded in the monitor run log.

### Monitoring 6.9.0

- Added an explicit Monitoring release definition and independent version check so scheduled monitor executions can reliably detect and install a newer release while preserving site-specific configuration, logs, filename, and Scheduled Tasks.

## 7.1.11 - 2026-08-21

### Corrected

- Corrected automatic updates during GitHub/CDN propagation. When `version.txt` and `update-manifest.json` temporarily come from different releases, IT Tools now shows five-second retry progress for up to one minute instead of immediately continuing with the outdated menu.
- Added no-cache request headers to the update check and retained a finite retry limit with full daily error logging if the release never becomes consistent.

## 7.1.10 - 2026-08-21

### Corrected

- Corrected the automatic IT Tools update flow so it verifies the copied main-script hash and embedded version, keeps the update summary visible until a key press, and reloads the verified release in the same PowerShell window. The older script session can no longer proceed to its stale main menu after an update.
- The update summary now shows the previous and installed versions, release date, and number of verified files. Its feature overview is read from the installed release rather than the in-memory older script.

## 7.1.9 - 2026-08-21

### Added

- Added **SSL Checker** to Local server and file tools. It performs DNS, TCP, TLS/SNI, certificate identity and validity, Windows chain trust and CRL/OCSP, TLS protocol, HTTPS redirect, and static mixed-content checks without requiring a module, OpenSSL, or administrator rights.
- Reorganized Local server and file tools into health/connectivity, storage/SQL backups, and file/application-log groups.

### Safety

- Added finite 15-second network timeouts to the SSL diagnostic so unreachable hosts cannot leave the interactive session waiting indefinitely.

## 7.1.8 - 2026-08-20

### Corrected

- Corrected monitoring JSON reads under Windows PowerShell 5.1 to use UTF-8 explicitly, preserving accented friendly site names such as `Salé` in email subjects and configuration updates.
- Added safe repair for existing UTF-8/Windows-1252 mojibake such as `SalÃ©` and double-encoded variants when loading user-facing monitoring names.
- Changed all monitor email delivery paths to display `D4A Monitoring` as the sender name while preserving the configured sender address.

### Monitoring 6.8.0

- Added Unicode-safe configuration loading and sender-name normalization for Node.js/Nodemailer and PowerShell SMTP delivery.

## 7.1.7 - 2026-08-19

### Corrected

- Replaced the immediate **Monitoring version update** failure when a related Scheduled Task is running with a fault-tolerant wait loop.
- IT Tools now refreshes related task state every five seconds, displays the running task names, elapsed time, next check, and timeout, then starts the verified update automatically as soon as execution finishes.
- Added a 15-minute timeout with full daily error logging so an abnormally stuck monitoring task cannot leave the interactive session waiting indefinitely.

## 7.1.6 - 2026-08-19

### Corrected

- Corrected **Update monitoring script version** so it downloads and verifies the current GitHub release before comparing versions. An outdated companion file beside IT Tools is refreshed automatically instead of being mistaken for the latest release.
- Added cache-busting release requests so GitHub/CDN cache state cannot leave IT Tools or the installed monitor comparing against an older manifest or script.
- Strengthened scheduled monitor self-updates with a cross-process update lock, configuration compatibility validation, installed-version metadata updates, and restoration of both the script and JSON configuration after an installation failure.

### Monitoring 6.7.1

- Scheduled and stand-alone runs now install a newer verified monitor release directly into the currently executed script path while preserving filenames such as `D4A-ScheduledMonitor-v5.ps1`, `D4A-ScheduledMonitor-v6.ps1`, or versioned variants.
- Concurrent recurring and daily Scheduled Tasks cannot race to install the same release; one process updates while the other continues its health check.

## 7.1.5 - 2026-08-19

### Changed

- Reduced non-actionable monitoring email: relevant Windows event warnings and errors remain in `error_log` and daily/test reports, while independent Windows-service checks determine whether a service outage needs an immediate alert.
- Removed disk-space warning notifications. Disk space now alerts only at 5 GB free or less, or 95 percent used or more.
- Added one-time recovery emails for previously notified issues after the same check explicitly returns healthy; missing or failed checks cannot create a false recovery.
- Updated normal alert subjects to identify the affected component and notification level, including `API Alert` and `Disk Space Critical`; more than one distinct issue uses `Multiple Alerts detected`.

### Monitoring 6.7.0

- Added backward-compatible notification history to the monitor state file so successful alert delivery and later recovery can be correlated without changing site configuration.
- Added component-aware alert and recovery subjects and documented the notification policy in generated `monitor-logs\README.txt` files.

## 7.1.4 - 2026-08-18

### Added

- Added monitoring creation and configuration-update results to the shared `C:\Users\edit_log.txt` action history using the current Windows identity, timestamp, selected non-sensitive values, and success or failure status.
- Monitoring creation entries identify the site hostnames, recurring schedule frequency, recurring-task status, and daily-monitoring status.
- Monitoring update entries identify only newly added site hostnames and notification email addresses; persistent site additions from **Execute Monitoring Commands** are also recorded.

### Changed

- Generalized **Logs > Last Actions done by this script** so its ten-line view describes both database interventions and monitoring changes.

## 7.1.3 - 2026-08-18

### Corrected

- Corrected the PowerShell 5.1 nodemailer installation job so informational `npm notice` output on stderr does not become a false failure when npm returns exit code `0`.
- npm installation success and failure are now determined from the native exit code; real failures retain a concise portion of npm output in the full daily error log.
- Extended safe `RESUME` detection to a deployment where nodemailer completed before the false job failure but Scheduled Tasks were not yet created.

## 7.1.2 - 2026-08-18

### Corrected

- Corrected Add New Site Monitoring so Node.js and npm are resolved from the current command path, standard Windows installation folders, environment variables, and registry installation data.
- Added a guided, progress-visible installation or repair of the official `OpenJS.NodeJS.LTS` package through Windows Package Manager when Node.js/npm are genuinely absent.
- Moved Node.js/npm and nodemailer validation before creation of new monitoring files, preventing the missing-npm error from leaving another partial deployment.
- Added safe `RESUME` handling for an incomplete deployment left by the previous failure, preserving its monitor and JSON settings while backing up and recording absolute Node.js/nodemailer paths.

## 7.1.1 - 2026-08-18

### Added

- Added a mandatory operator-name prompt before persistent database changes and a centralized intervention audit at `C:\Users\edit_log.txt` with timestamp, operator, action, selected non-sensitive variables, and success or failure result.
- Added a fourth main menu, **Logs**, with a **Last Actions done by this script** view for the ten newest database intervention entries.
- Added autonomous monitoring updates on every execution, with manifest and SHA-256 verification, release metadata validation, PowerShell syntax validation, and safe continuation when an update cannot be applied.

### Monitoring 6.6.0

- The monitor now checks its own GitHub release independently of IT Tools and safely installs newer verified monitor code.
- Before replacement, the monitor backs up its installed script, external JSON configuration, and related Scheduled Task definitions while preserving the deployed filename and all site-specific behavior.
- Added `-SkipAutomaticUpdate` for a temporary troubleshooting run without a network update check.

## 7.1.0 - 2026-08-18

### Corrected

- Corrected Add New Site Monitoring so each site can receive a friendly name without attempting to overwrite PowerShell's read-only `$Host` automatic variable.

## 7.0.9 - 2026-08-12

### Added

- Introduced a three-layer documentation model:
  - project case study for recruiters, managers, and non-technical readers;
  - technical architecture and engineering design reference;
  - Level 1/Level 2 operator guide with workflows, expected results, troubleshooting, and escalation boundaries.
- Reworked the root README into a concise repository landing page.
- Documented the project's evolution from recurring manual tasks to a centralized team-enablement toolkit.

### Corrected

- Corrected the main script header to state that the toolkit contains three tool groups.
- Synchronized the monitoring script's runtime version with its machine-readable header.

### Monitoring 6.5.1

- Corrected runtime version reporting so configuration, validation, and logs identify the installed monitor accurately.

## 7.0.8 - 2026-08-12

### Added

- Added one friendly display name per monitored frontend site.
- Added `SiteDisplayNames` to external monitor configuration while preserving compatibility with older installations.
- Updated configuration display and settings management to show site-to-name associations.

### Monitoring 6.5.0

- Monitoring results and email subjects can identify multiple configured sites by their individual friendly names.

## 7.0.5 - 2026-08-12

### Changed

- Separated **Add New Site Monitoring** from **Update Existing Monitoring Settings**.
- Added independent paths for updating site settings, monitor code, and Scheduled Tasks.
- Preserved production configuration, logs, ignore rules, filenames, task triggers, frequency, and task identity during monitor updates.

## 7.0.3 - 2026-08-12

### Corrected

- Reduced false endpoint alerts: frontend and API response time is logged above 4,500 ms but only unreachability can trigger email.
- Required two consecutive executions at 90 percent or more before CPU or memory email alerts.
- Excluded known harmless NSSM output-rotation and ended-pipe events.
- Added retry and persistence logic for Data Collector SQL health checks while its Windows service is running.
- Added LastHealthy warning and critical evaluation for Data Collector evidence.
- Required a sustained Nginx error rate above 20 errors per minute for two consecutive minutes before alerting.

### Monitoring 6.4.0

- Added stateful alert evaluation, recovery handling, and lower-noise operational notifications.
- Added ignore-rule rotation on the 3rd, 13th, and 23rd of each month while retaining active rules and only three archives.

## 7.0.2 - 2026-08-11

### Changed

- Restricted companion-file downloads to the moment a user selects the feature that requires the missing file.
- Prevented the automatic updater from downloading unused companion scripts or SQL files.

## 7.0.1 - 2026-08-11

### Added

- Added verified on-demand download support for official companion PowerShell and SQL files.
- Required companion files to match SHA-256 values in the release manifest before being saved locally.
- Added user-facing download progress and safe handling for non-writable script folders.

## 7.0.0 - 2026-08-11

### Added

- Established GitHub `main` as the canonical distribution source.
- Added automatic startup version checks using `version.txt`.
- Added `update-manifest.json` as the release allowlist and integrity source.
- Added HTTPS staging downloads, SHA-256 validation, PowerShell syntax validation, safe replacement, and automatic relaunch.
- Preserved the installed version when any update validation fails.

### Changed

- Introduced semantic release versioning for IT Tools.
- Kept site-specific monitoring configuration, credentials, logs, state, and ignore rules outside release payloads.

## Monitoring 6.3.0 and earlier toolkit evolution

Before the public `7.0.x` release workflow, the project evolved through repeated operational requirements and production corrections.

### Central toolkit and user experience

- Consolidated stand-alone scripts into numbered **Database Tools**, **Local server and file tools**, and **Site Monitoring** menus.
- Standardized `q` navigation, readable results, press-any-key return behavior, and persistent timestamped progress for long operations.
- Added clipboard-compatible hidden password entry.
- Added daily full error logs with operation context, exception details, and stack information.
- Added finite timeouts for deep scans and expensive WMI/CIM or SQL operations.

### Database translation and import capabilities

- Added language-file export for all content or only missing translations.
- Added translated CSV staging, preview, update, and insert workflows.
- Added case-insensitive column detection, Unicode-safe text, apostrophe handling, blank-translation skipping, invalid RootId reporting, and duplicate RootId consolidation.
- Corrected SQL connection failures caused by wrapped PowerShell objects being passed to connection-string builders.
- Corrected duplicate-key migration failures caused by duplicate RootIds in source data.
- Added identity-column detection for environments where `TranslationId` is database-generated.
- Added generic CSV/XLSX staging imports and controlled table-to-table migrations.

### Database safety and diagnostics

- Standardized timestamped table backups using `TableNameyyyyMMddHHmmss`.
- Added transactions, previews, explicit confirmation words, post-change validation, and blank-value protection.
- Added a global rollback menu that discovers and restores backups created by toolkit features while first backing up current state.
- Added database text, column-name, and stored-procedure searches.
- Added table-size, SQL error-log, pending-query, heavy-query, cached-resource, and SQL CPU diagnostics.
- Added activity copying between machines with duplicate avoidance.
- Added Line Detailed View configuration and Luleburgas system-settings and role-permission workflows.

### Server and file operations

- Added system health reports, recent-file discovery, recursive text search, TCP port tests, and SQL backup-folder permission management.
- Added Data Collector log tracing by date, time range, required text, and exclusions.
- Corrected active-log access by opening files with read/write sharing.
- Integrated the stand-alone visual disk analyzer while keeping it independently executable.

### Site monitoring

- Added scheduled monitoring for frontend sites, derived API endpoints, TLS certificates, D4A services, Mosquitto/MQTT, API listeners, CPU, memory, disks, Nginx, Windows events, and Watchdog evidence.
- Added silent Scheduled Tasks running as `SYSTEM` when no user is logged in.
- Moved site-specific settings to `monitor-logs\D4A-ScheduledMonitor.config.json`.
- Added test, normal, daily-summary, validation, temporary-site, no-email, and cooldown management commands.
- Added daily run/error logs, five-day retention, monitoring state, recovery detection, and issue cooldowns.
- Added monitor version updates that back up code, configuration, and Scheduled Task definitions before replacement.
