# IT Tools DB Management and Server Tools

Windows PowerShell 5.1 tools for D4A database administration, server checks,
site monitoring, language translations, and Danone setup operations.

Developer: Khaled Barbar

## Install and run

1. Download or clone this complete repository into a folder the user can write
   to, such as `Desktop\IT Tools` or `Documents\IT Tools`.
2. Keep the companion files beside
   `IT_Tools_Database_Translations_and_Server_Checks.ps1`.
3. Run the main script with Windows PowerShell. Run as Administrator when a
   selected tool requires elevated access.

The main script checks `version.txt` when it starts. When a newer release is
available, it downloads the files listed in `update-manifest.json`, validates
their SHA-256 hashes and the PowerShell syntax of the main script, keeps a copy
of the previous main script in `Desktop\IT Tools Backups`, retains only the
newest two backups, then restarts automatically.

Use this command only when an update check must be skipped temporarily:

```powershell
.\IT_Tools_Database_Translations_and_Server_Checks.ps1 -SkipAutomaticUpdate
```

The updater never replaces site-specific monitoring configuration, credentials,
monitor logs, or ignore rules.

## Release files

- `version.txt`: public release version.
- `update-manifest.json`: release file list and SHA-256 integrity hashes.
- `IT_Tools_Database_Translations_and_Server_Checks.ps1`: main menu and tools.
- SQL files and companion PowerShell scripts: automatically refreshed when a
  release manifest includes them.

## Versioning

This release starts at `7.0.0`. Updates made in the same ISO calendar week use
patch versions such as `7.0.1`. Updates made in a later week use the next minor
version such as `7.1.0`. Major versions are reserved for substantial breaking
or architectural changes.

For stronger production assurance, publish signed releases or Authenticode-sign
the PowerShell scripts in addition to the HTTPS and SHA-256 checks used here.
