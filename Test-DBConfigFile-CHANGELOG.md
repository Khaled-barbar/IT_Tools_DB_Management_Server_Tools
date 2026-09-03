# D4A DBConfig Diagnostic Changelog

This changelog tracks meaningful changes to `Test-DBConfigFile.ps1`.

Versioning follows semantic versioning in a practical way:
- Major versions are for breaking behavior or a substantially different tool.
- Minor versions are for new diagnostic capabilities or default behavior changes.
- Patch versions are for corrections, compatibility fixes, and output refinements.

## [1.5.1] - 2026-09-03

### Fixed
- Restored the detailed diagnostic report in the same PowerShell window after an interactive launch. The launcher now invokes the scan in-process rather than opening a child PowerShell process whose output could be lost.

## [1.5.0] - 2026-09-03

### Added
- Added automatic `dbconfig.js` discovery from active Decide4Action and D4A Data Collector service executable paths. The diagnostic normalizes each service path, derives the D4A installation root, and checks `Services\API\dbconfig.js`.
- Added numbered selection when multiple D4A installations and dbconfig files are found on the same server, with manual-path and `q` return options retained.

## [1.4.1] - 2026-09-02

### Changed
- Added `q` as an explicit safe return option at the interactive `dbconfig.js` path prompt, matching the IT Tools navigation convention.

## [1.4.0] - 2026-09-02

### Added
- Added embedded script version metadata:
  - `D4A-DBConfigDiagnostic-Version`
  - `D4A-DBConfigDiagnostic-ReleaseDate`
- Added version display to the interactive launcher title and execution banner.
- Added failed SQL batch output for the User Table Settings probe so failing database behavior can be reproduced in SSMS.

### Changed
- Changed the User Table Settings probe to use the same application-style SQL batch used by the API endpoint instead of testing only RPC parameter binding.
- Kept the probe rollback-only so synthetic payload checks do not persist data.
- Refined the interactive prompt text so the default action, custom parameter entry, and help option are clear.

### Fixed
- Fixed the interactive launcher `.Count` failure when custom parameters were parsed into a single scalar value.
- Fixed a probe-wrapper timeout type issue that could surface as `Argument types do not match` before Node or SQL emitted a structured diagnostic.
- Improved wrapper-stage reporting for Node probe startup, execution, and output collection failures.

## [1.3.0] - 2026-09-02

### Added
- Added a right-click friendly interactive launcher with:
  - default recommended scan mode,
  - custom one-line parameter entry,
  - parameter help,
  - rerun and modify-after-run choices.
- Added `-NonInteractive` for scheduled or command-line execution.
- Added selected-checks output so each run clearly shows which checks are enabled or skipped.

### Changed
- Made the User Table Settings probe run by default.
- Added explicit opt-out switches for default-on diagnostics:
  - `-SkipUserTableSettingsProbe`
  - `-SkipUnencryptedSqlDiagnostic`
  - `-SkipExtendedDbConfigSimulations`
- Kept older run/allow switches accepted for compatibility.

## [1.2.0] - 2026-09-01

### Added
- Added automatic D4A database password decryption using existing `D4AKEY` and `D4AIV` environment variables.
- Added support for both encrypted and plaintext database passwords.
- Added Node-side password handling for the User Table Settings probe without exposing decrypted passwords on the command line.
- Added encrypted versus unencrypted SQL transport comparison for controlled troubleshooting of encrypted TDS write failures.
- Added packet-size and dbConfig option simulations to isolate large payload issues involving `node-mssql`, TLS, packet fragmentation, and related options.
- Added runtime reporting for Node.js, `mssql`, effective encryption, trust settings, and negotiated packet size when available.

### Fixed
- Fixed false login failures for encrypted dbconfig passwords by decrypting the stored password before SQL validation.
- Improved local SQL instance resolution for multi-instance servers, including named instances such as `localhost\SALE` and machine-name aliases.

## [1.1.0] - 2026-09-01

### Added
- Added the User Table Settings payload probe based on the requested Node `mssql` command.
- Added local multi-instance SQL connection resolution before running the probe.
- Added raw SMTP credential validation using TCP sockets, `STARTTLS`, and `AUTH LOGIN` without sending an email.
- Added SMTP, HTTP, HTTPS, TLS, certificate reference, constants, variables, and `module.exports` diagnostics.

### Fixed
- Improved SQL connection failure classification for host unreachable, database unavailable, login failure, timeout, and certificate trust scenarios.
- Improved JavaScript syntax validation using `node --check` when Node.js is available.

## [1.0.0] - 2026-09-01

### Added
- Initial DBConfig scanner.
- Added prompt for the `dbconfig.js` file path.
- Added static parsing of database credential objects and exported declarations without executing the JavaScript file.
- Added validation that every `module.exports` reference has a matching declaration.
- Added database credential testing for discovered SQL Server configurations.
- Added summary output with errors, warnings, and successful validation results.
