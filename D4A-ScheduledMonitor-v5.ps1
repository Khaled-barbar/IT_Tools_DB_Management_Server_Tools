#requires -Version 5.1
# D4A-Monitor-Version: 6.10.1
# D4A-Monitor-Release-Date: 2026-08-25

<#
.SYNOPSIS
    Monitors D4A application and Windows server health and sends D4A email notifications.

.DESCRIPTION
    Runs application, service, resource, TLS, Nginx, and Windows event checks.
    Results are written to daily run_log and error_log files under monitor-logs.
    Monitoring logs are retained for five days by default.

    Site-specific settings are loaded from
    monitor-logs\D4A-ScheduledMonitor.config.json. Command-line parameters take
    precedence over the configuration file, which takes precedence over the
    built-in defaults.

    Ignore rules are stored in monitor-logs\ignore-rules.txt. Rules use the
    format key|temporary|2h| or key|permanent||. A temporary rule is stamped
    with its calculated end time on first use and commented out after expiry.

    In normal mode, an email is sent when a new issue is detected. The monitor
    automatically creates a 24-hour cooldown rule for that issue. Resolved
    issues have their automatic cooldown removed so a recurrence is reported.
    Test and daily-summary modes send the complete scan report even when healthy.

    Frontend and API endpoints alert only when unavailable. Responses above
    4500 ms are recorded in error_log without an email alert. CPU and RAM alert
    only after two consecutive monitor runs at 90% or more. NSSM server.log
    rotation events, plus harmless pipe-ended output-read events, are excluded.

    To change an automatic cooldown, use -SetIssueCooldown with
    -IssueCooldownDuration. The command rewrites both the duration and its
    calculated expiry timestamp; do not edit only one of those values manually.

    Use -AddSiteAddress to persist one or more additional frontend sites in
    the JSON configuration. Their matching D4A API endpoints are derived and
    checked automatically during each normal monitoring run.

    Every execution checks the official GitHub Monitoring release for a newer
    version. monitor-version.txt, the monitoring release definition in
    update-manifest.json, and the downloaded script metadata and SHA-256 must
    agree before installation. Local configuration, logs, script filename, and
    Scheduled Task definitions are preserved and backed up. Use
    -SkipAutomaticUpdate only for a temporary troubleshooting run.

.EXAMPLE
    .\D4A-ScheduledMonitor-v5.ps1 -SiteAddress 'https://akbou.decide4action.com'

.EXAMPLE
    .\D4A-ScheduledMonitor-v5.ps1 `
        -SiteAddress 'https://akbou.decide4action.com' `
        -SendTestResultsEmail

.EXAMPLE
    # Send the daily performance summary even when no issue is detected.
    .\D4A-ScheduledMonitor-v5.ps1 -SendDailySummaryEmail

.EXAMPLE
    # Add a site to the persistent JSON configuration, then view the result.
    .\D4A-ScheduledMonitor-v5.ps1 -AddSiteAddress 'https://newsite.decide4action.com'
    .\D4A-ScheduledMonitor-v5.ps1 -ShowConfiguration

.EXAMPLE
    # Change the automatic cooldown for one issue to 12 hours or 3 days.
    # This recalculates the expiry timestamp from the current time.
    .\D4A-ScheduledMonitor-v5.ps1 -SetIssueCooldown 'server-cpu' -IssueCooldownDuration '12h'
    .\D4A-ScheduledMonitor-v5.ps1 -SetIssueCooldown 'server-cpu' -IssueCooldownDuration '3d'
    .\D4A-ScheduledMonitor-v5.ps1 -ClearIssueCooldown 'server-cpu'

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass `
        -File .\D4A-ScheduledMonitor-v5.ps1 `
        -SiteAddress 'https://akbou.decide4action.com'
#>

[CmdletBinding()]
param(
    [string]$ConfigPath,

    [switch]$SkipAutomaticUpdate,

    [switch]$ValidateConfiguration,

    # Show the effective configuration without running a health scan.
    [switch]$ShowConfiguration,

    # Add one or more comma-separated frontend sites to the persistent JSON
    # configuration without running a health scan.
    [string]$AddSiteAddress,

    # Comma-separated frontend addresses. The corresponding D4A API is always
    # checked automatically for every configured frontend.
    [string]$SiteAddress = 'hostname:1200',

    # Friendly identifier used in email subjects, for example "Akbou".
    [string]$MonitoringName = 'D4A site',

    # Comma-separated friendly names aligned with SiteAddress. This is normally
    # maintained by IT Tools and lets each configured site be identified clearly.
    [string]$SiteDisplayNames = '',

    # Default notification recipient. Change this value if the monitor should
    # always use another mailbox, or override it with -NotificationTo.
    [string]$NotificationTo = 'techsupport@decide4action.com',

    [Alias('SendEmailResults')]
    [switch]$SendTestResultsEmail,

    [switch]$SendDailySummaryEmail,

    [switch]$DisableEmail,

    [string]$LogDirectory,
    [string]$WatchdogLogRoot,

    [ValidateRange(1, 365)]
    [int]$LogRetentionDays = 5,

    [ValidateRange(50, 5000)]
    [int]$WatchdogLogTailLines = 300,

    [string]$D4AInstallRoot,
    [string]$NginxErrorLog,

    [Alias('EmailDbConfigPath')]
    [string]$DbConfigPath,

    [string]$NodeExecutable,
    [string]$NodemailerModulePath,
    [string]$FromAddress,

    # SetIssueCooldown recalculates both duration and expiry from now, without
    # running a full monitor scan. ClearIssueCooldown removes the automatic rule.
    [string]$SetIssueCooldown,
    [string]$ClearIssueCooldown,
    [string]$IssueCooldownDuration = '24h',

    [ValidateRange(5, 300)]
    [int]$EmailTimeoutSeconds = 30,

    # Optional SMTP fallback. It is used only when SmtpServer is explicitly set.
    [string]$SmtpServer = '',

    [ValidateRange(1, 65535)]
    [int]$SmtpPort = 25,

    [switch]$SmtpUseSsl,
    [string]$SmtpCredentialFile,

    [ValidateRange(1, 300)]
    [int]$HttpTimeoutSeconds = 15,

    [ValidateRange(1, 10)]
    [int]$ApplicationAttempts = 2,

    # Retained for compatibility with existing configuration files. Endpoint
    # latency is now logged only above 4500 ms and never sends an email.
    [ValidateRange(1, 60000)]
    [int]$ApplicationWarningMs = 2000,

    [ValidateRange(1, 120000)]
    [int]$ApplicationAlertMs = 5000,

    # Retained for compatibility with existing configuration files. Endpoint
    # latency no longer triggers an email notification.
    [ValidateRange(1, 60000)]
    [int]$ApiHealthWarningMs = 4000,

    [ValidateRange(1, 5)]
    [int]$ApiHealthFailureAttempts = 3,

    [ValidateRange(1, 60)]
    [int]$ApiHealthRetryIntervalSeconds = 5,

    # Safe NSSM log-rotation events are excluded only when their message
    # confirms that they concern an output-file rotation.
    [string]$NssmExcludedLogRotationEventIds = '1063,1077',

    [ValidateRange(1, 240)]
    [int]$CpuSampleDurationSeconds = 60,

    [ValidateRange(1, 30)]
    [int]$CpuSampleIntervalSeconds = 5,

    [ValidateRange(1, 60)]
    [int]$LogLookbackMinutes = 5,

    [ValidateRange(100, 50000)]
    [int]$DiagnosticTailLines = 5000,

    [ValidateRange(1, 10000)]
    [int]$NginxErrorsPerMinuteThreshold = 20,

    [ValidateRange(2, 60)]
    [int]$NginxConsecutiveMinutes = 2,

    [ValidateRange(1, 10)]
    [int]$DataCollectorConsecutiveFailureThreshold = 3,

    [ValidateRange(1, 120)]
    [int]$DataCollectorLastHealthyWarningMinutes = 5,

    [ValidateRange(2, 240)]
    [int]$DataCollectorLastHealthyCriticalMinutes = 10,

    [ValidateRange(1, 50)]
    [int]$MaxRedirects = 10
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
catch {
    # The operating system TLS defaults remain in effect if this is unavailable.
}

$script:ScriptPath = [string]$MyInvocation.MyCommand.Path
$script:MonitorVersion = '6.10.1'
$script:MonitorReleaseDate = '2026-08-25'
$script:MonitorRepositoryRawRoot = 'https://raw.githubusercontent.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools/main'
$script:MonitorGitHubRepository = 'Khaled-barbar/IT_Tools_DB_Management_Server_Tools'
$script:MonitorVersionFileName = 'monitor-version.txt'
$script:MonitorUpdateManifestFileName = 'update-manifest.json'
$script:MonitorReleaseScriptFileName = 'D4A-ScheduledMonitor-v5.ps1'
$script:MonitorUpdateRequestId = '{0}-{1}' -f [DateTime]::UtcNow.Ticks, [guid]::NewGuid().ToString('N')
$script:EndpointSlowLogMs = 4500
$script:ResourceAlertPercent = 90
$script:ResourceConsecutiveRunsRequired = 2
$script:DiskCriticalFreeGb = 5
$script:DiskCriticalUsedPercent = 95
$script:CommandLineParameterNames = @($PSBoundParameters.Keys)
$script:ResolvedConfigPath = $null
$script:ConfigurationLoaded = $false
$script:ScriptDirectory = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
}
else {
    Split-Path -Parent $script:ScriptPath
}
$script:RunStartedAt = Get-Date
$script:Results = [System.Collections.Generic.List[object]]::new()
$script:RunLogPath = $null
$script:ErrorLogPath = $null
$script:IgnoreRulesPath = $null
$script:MonitorLogDirectory = $null
$script:MonitorStatePath = $null
$script:LoggingReady = $false
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)

function Initialize-MonitorWebTls {
    # Windows PowerShell can otherwise inherit obsolete protocol defaults on older servers.
    $protocols = [Net.SecurityProtocolType]::Tls12
    if ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
        $protocols = $protocols -bor [Net.SecurityProtocolType]::Tls13
    }
    [Net.ServicePointManager]::SecurityProtocol = $protocols
}

function Get-MonitorReleaseCommit {
    try {
        Initialize-MonitorWebTls
        $response = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$($script:MonitorGitHubRepository)/commits/main" `
            -TimeoutSec 15 `
            -Headers @{ 'User-Agent' = 'D4A-ScheduledMonitor'; 'Cache-Control' = 'no-cache' } `
            -ErrorAction Stop
        $commit = [string]$response.sha
        if ($commit -notmatch '^[a-fA-F0-9]{40}$') { throw 'The GitHub API did not return a valid main-branch commit SHA.' }
        return $commit
    }
    catch {
        Write-RunLog -Category Update -Color DarkGray -Message 'GitHub commit lookup is unavailable; using the main release URL with verified retry protection.'
        return ''
    }
}

function Get-MonitorAutomaticUpdateUri {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [string]$ReleaseCommit = ''
    )

    if ($RelativePath -match '(?i)(\.\.|^[\\/]|^[A-Za-z]:)') {
        throw "Unsafe monitoring update path: $RelativePath"
    }
    $encodedPath = (@($RelativePath -split '[\\/]' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    $releaseReference = if ([string]::IsNullOrWhiteSpace($ReleaseCommit)) { 'main' } else { $ReleaseCommit }
    return "https://raw.githubusercontent.com/$($script:MonitorGitHubRepository)/$releaseReference/$encodedPath`?releaseCheck=$($script:MonitorUpdateRequestId)-$([DateTime]::UtcNow.Ticks)"
}

function Get-MonitorUpdateText {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [string]$ReleaseCommit = ''
    )

    Initialize-MonitorWebTls
    $response = Invoke-WebRequest `
        -Uri (Get-MonitorAutomaticUpdateUri -RelativePath $RelativePath -ReleaseCommit $ReleaseCommit) `
        -UseBasicParsing `
        -TimeoutSec 15 `
        -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' } `
        -ErrorAction Stop
    return ([string]$response.Content).Trim()
}

function Get-MonitorRemoteReleaseDefinition {
    param(
        [int]$MaximumAttempts = 12,
        [int]$RetrySeconds = 5
    )

    $lastIssue = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $releaseCommit = Get-MonitorReleaseCommit
            $remoteVersion = [version](Get-MonitorUpdateText -RelativePath $script:MonitorVersionFileName -ReleaseCommit $releaseCommit)
            $manifest = (Get-MonitorUpdateText -RelativePath $script:MonitorUpdateManifestFileName -ReleaseCommit $releaseCommit) | ConvertFrom-Json -ErrorAction Stop
            $monitoring = $manifest.monitoring
            if ($null -eq $monitoring) {
                throw 'The update manifest does not define a monitoring release.'
            }
            if ([string]$monitoring.version -ne $remoteVersion.ToString()) {
                throw "Monitoring version '$($monitoring.version)' in the manifest does not match monitor-version.txt '$remoteVersion'."
            }
            if ([string]$monitoring.scriptPath -ine $script:MonitorReleaseScriptFileName) {
                throw "The monitoring manifest script path '$($monitoring.scriptPath)' is not '$($script:MonitorReleaseScriptFileName)'."
            }
            $entries = @($manifest.files | Where-Object { [string]$_.path -ieq $script:MonitorReleaseScriptFileName })
            if ($entries.Count -ne 1) {
                throw "The release manifest does not contain one unique entry for $($script:MonitorReleaseScriptFileName)."
            }
            $expectedHash = ([string]$entries[0].sha256).Trim().ToUpperInvariant()
            if ($expectedHash -notmatch '^[A-F0-9]{64}$') { throw 'The monitoring manifest SHA-256 value is invalid.' }
            if ($expectedHash -ne ([string]$monitoring.sha256).Trim().ToUpperInvariant()) {
                throw 'The monitoring release hash does not match the file entry in the manifest.'
            }
            if ([string]::IsNullOrWhiteSpace([string]$monitoring.releaseDate)) {
                throw 'The monitoring release date is missing from the manifest.'
            }

            return [pscustomobject]@{
                Version = $remoteVersion
                ReleaseDate = [string]$monitoring.releaseDate
                ExpectedHash = $expectedHash
                ReleaseCommit = $releaseCommit
            }
        }
        catch {
            $lastIssue = $_.Exception.Message
        }

        if ($attempt -lt $MaximumAttempts) {
            Write-RunLog -Category Update -Color DarkGray -Message (
                'GitHub monitoring release files are synchronizing (attempt {0}/{1}). Retrying in {2} second(s).' -f
                    $attempt, $MaximumAttempts, $RetrySeconds
            )
            Start-Sleep -Seconds $RetrySeconds
        }
    }

    throw "The GitHub monitoring release did not become consistent after $MaximumAttempts attempt(s). $lastIssue"
}

function Get-MonitorVerifiedReleaseScript {
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [string]$ReleaseCommit = '',
        [int]$MaximumAttempts = 12,
        [int]$RetrySeconds = 5
    )

    $lastIssue = $null
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
            Initialize-MonitorWebTls
            Invoke-WebRequest `
                -Uri (Get-MonitorAutomaticUpdateUri -RelativePath $script:MonitorReleaseScriptFileName -ReleaseCommit $ReleaseCommit) `
                -OutFile $DestinationPath `
                -UseBasicParsing `
                -TimeoutSec 60 `
                -Headers @{ 'Cache-Control' = 'no-cache'; Pragma = 'no-cache' } `
                -ErrorAction Stop

            $downloadedHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
            if ($downloadedHash -eq $ExpectedHash) { return $DestinationPath }
            $lastIssue = "Received SHA-256 $downloadedHash, expected $ExpectedHash."
        }
        catch {
            $lastIssue = $_.Exception.Message
        }

        Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction SilentlyContinue
        if ($attempt -lt $MaximumAttempts) {
            Write-RunLog -Category Update -Color DarkGray -Message (
                'GitHub monitoring script is still synchronizing (attempt {0}/{1}). Retrying in {2} second(s).' -f
                    $attempt, $MaximumAttempts, $RetrySeconds
            )
            Start-Sleep -Seconds $RetrySeconds
        }
    }

    throw "The verified monitoring script could not be downloaded after $MaximumAttempts attempt(s). $lastIssue"
}

function Get-MonitorScriptReleaseMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($content -notmatch '(?m)^# D4A-Monitor-Version:\s*([^\r\n]+)\s*$') {
        throw "Monitoring version metadata is missing from $Path"
    }
    $version = [version]$matches[1].Trim()
    if ($content -notmatch '(?m)^# D4A-Monitor-Release-Date:\s*([^\r\n]+)\s*$') {
        throw "Monitoring release-date metadata is missing from $Path"
    }
    $releaseDate = $matches[1].Trim()

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "Downloaded monitoring script failed PowerShell syntax validation: $($parseErrors[0].Message)"
    }

    return [pscustomobject]@{
        Version     = $version
        ReleaseDate = $releaseDate
    }
}

function Test-MonitorScriptFolderWritable {
    $testPath = Join-Path $script:ScriptDirectory ('.monitor_update_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($testPath, 'monitor update permission check', $script:Utf8NoBom)
        Remove-Item -LiteralPath $testPath -Force -ErrorAction Stop
        return $true
    }
    catch {
        Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Get-MonitorRelatedScheduledTasks {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue) -or
        -not (Get-Command Export-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw 'Scheduled Task cmdlets are unavailable, so monitoring task definitions cannot be backed up safely.'
    }

    return @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
        $task = $_
        @($task.Actions | Where-Object {
            $arguments = [string]$_.Arguments
            -not [string]::IsNullOrWhiteSpace($arguments) -and
            $arguments.IndexOf($script:ScriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        }).Count -gt 0
    })
}

function New-MonitorAutomaticUpdateBackup {
    param([Parameter(Mandatory = $true)][version]$TargetVersion)

    $backupRoot = Join-Path $script:MonitorLogDirectory 'monitor-update-backups'
    $backupFolder = Join-Path $backupRoot ('{0}_to_{1}' -f (Get-Date -Format 'yyyyMMddHHmmss'), $TargetVersion)
    [void](New-Item -Path $backupFolder -ItemType Directory -Force -ErrorAction Stop)

    Copy-Item -LiteralPath $script:ScriptPath -Destination (Join-Path $backupFolder ([IO.Path]::GetFileName($script:ScriptPath))) -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($script:ResolvedConfigPath) -and
        (Test-Path -LiteralPath $script:ResolvedConfigPath -PathType Leaf)) {
        Copy-Item -LiteralPath $script:ResolvedConfigPath -Destination (Join-Path $backupFolder ([IO.Path]::GetFileName($script:ResolvedConfigPath))) -ErrorAction Stop
    }

    $relatedTasks = @(Get-MonitorRelatedScheduledTasks)
    if ($relatedTasks.Count -eq 0) {
        [IO.File]::WriteAllText((Join-Path $backupFolder 'scheduled-tasks.txt'), 'No related Scheduled Tasks were found.', $script:Utf8NoBom)
    }
    else {
        foreach ($task in $relatedTasks) {
            $safeTaskName = ('{0}{1}' -f $task.TaskPath.Trim('\').Replace('\', '_'), $task.TaskName) -replace '[^A-Za-z0-9_.-]', '_'
            $taskXml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            [IO.File]::WriteAllText((Join-Path $backupFolder ($safeTaskName + '.xml')), [string]$taskXml, $script:Utf8NoBom)
        }
    }

    $metadata = @(
        'BackupTime={0}' -f (Get-Date).ToString('o'),
        'InstalledScript={0}' -f $script:ScriptPath,
        'PreviousVersion={0}' -f $script:MonitorVersion,
        'TargetVersion={0}' -f $TargetVersion,
        'Configuration={0}' -f $script:ResolvedConfigPath,
        'ScheduledTasks={0}' -f $relatedTasks.Count
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $backupFolder 'update-details.txt'), $metadata, $script:Utf8NoBom)
    return $backupFolder
}

function Enter-MonitorAutomaticUpdateLock {
    $lockPath = Join-Path $script:MonitorLogDirectory '.monitor-update.lock'
    try {
        return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] {
        return $null
    }
}

function Test-MonitorDownloadedReleaseConfiguration {
    param([Parameter(Mandatory = $true)][string]$DownloadedScriptPath)

    if ([string]::IsNullOrWhiteSpace($script:ResolvedConfigPath) -or
        -not (Test-Path -LiteralPath $script:ResolvedConfigPath -PathType Leaf)) {
        return
    }

    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy', 'Bypass',
        '-File', $DownloadedScriptPath,
        '-ConfigPath', $script:ResolvedConfigPath,
        '-SkipAutomaticUpdate',
        '-ValidateConfiguration'
    )
    $validationOutput = @(& powershell.exe @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $summary = (($validationOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()
        if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) + '...' }
        throw "Downloaded monitoring release rejected the current site configuration: $summary"
    }
}

function Set-MonitorInstalledReleaseMetadata {
    param(
        [Parameter(Mandatory = $true)][version]$Version,
        [Parameter(Mandatory = $true)][string]$ReleaseDate
    )

    if ([string]::IsNullOrWhiteSpace($script:ResolvedConfigPath) -or
        -not (Test-Path -LiteralPath $script:ResolvedConfigPath -PathType Leaf)) {
        return
    }

    $configuration = Read-MonitorConfigurationFile -Path $script:ResolvedConfigPath
    foreach ($property in @(
            [pscustomobject]@{ Name = 'InstalledMonitorVersion'; Value = $Version.ToString() },
            [pscustomobject]@{ Name = 'InstalledMonitorReleaseDate'; Value = $ReleaseDate },
            [pscustomobject]@{ Name = 'LastMonitorUpdate'; Value = (Get-Date).ToString('o') }
        )) {
        if ($null -eq $configuration.PSObject.Properties[$property.Name]) {
            $configuration | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value
        }
        else {
            $configuration.($property.Name) = $property.Value
        }
    }

    $temporaryConfigPath = Join-Path (Split-Path -Parent $script:ResolvedConfigPath) ('.monitor_config_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText(
            $temporaryConfigPath,
            ($configuration | ConvertTo-Json -Depth 12) + [Environment]::NewLine,
            $script:Utf8NoBom
        )
        Copy-Item -LiteralPath $temporaryConfigPath -Destination $script:ResolvedConfigPath -Force -ErrorAction Stop
    }
    finally {
        Remove-Item -LiteralPath $temporaryConfigPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MonitorAutomaticUpdate {
    if ($SkipAutomaticUpdate.IsPresent) {
        Write-RunLog -Category Update -Color DarkGray -Message 'Automatic monitoring update check was skipped for this run.'
        return
    }

    $temporaryFolder = $null
    $backupFolder = $null
    $updateLock = Enter-MonitorAutomaticUpdateLock
    if ($null -eq $updateLock) {
        Write-RunLog -Category Update -Color DarkGray -Message 'Another monitoring process is checking or installing an update; this run will continue without a duplicate update attempt.'
        return
    }
    try {
        Write-RunLog -Category Update -Color DarkGray -Message ('Checking GitHub for a monitoring update. Current version={0}.' -f $script:MonitorVersion)
        $release = Get-MonitorRemoteReleaseDefinition
        $currentVersion = [version]$script:MonitorVersion
        if ($release.Version -le $currentVersion) {
            Write-RunLog -Category Update -Color DarkGray -Message ('Monitoring version {0} is current; no update was required.' -f $currentVersion)
            return
        }
        $expectedHash = $release.ExpectedHash

        $temporaryFolder = Join-Path ([IO.Path]::GetTempPath()) ('D4AMonitorUpdate_{0}' -f [guid]::NewGuid().ToString('N'))
        [void](New-Item -Path $temporaryFolder -ItemType Directory -Force -ErrorAction Stop)
        $downloadedScript = Join-Path $temporaryFolder $script:MonitorReleaseScriptFileName
        [void](Get-MonitorVerifiedReleaseScript -ExpectedHash $expectedHash -DestinationPath $downloadedScript -ReleaseCommit $release.ReleaseCommit)
        $remoteMetadata = Get-MonitorScriptReleaseMetadata -Path $downloadedScript
        if ($remoteMetadata.Version -ne $release.Version -or $remoteMetadata.ReleaseDate -ne $release.ReleaseDate) {
            throw 'The downloaded monitoring script metadata does not match the verified monitoring release definition.'
        }
        if (-not (Test-MonitorScriptFolderWritable)) {
            throw "A newer monitoring version $($remoteMetadata.Version) is available, but the script folder is not writable: $($script:ScriptDirectory)"
        }

        Write-RunLog -Category Update -Color Cyan -Message ('Verified monitoring update {0}, released {1}. Creating backups before installation.' -f $release.Version, $release.ReleaseDate)
        $backupFolder = New-MonitorAutomaticUpdateBackup -TargetVersion $remoteMetadata.Version
        Write-RunLog -Category Update -Color DarkGray -Message 'Validating the downloaded monitoring release against the current site configuration.'
        Test-MonitorDownloadedReleaseConfiguration -DownloadedScriptPath $downloadedScript
        $replacementPath = Join-Path $script:ScriptDirectory ('.monitor_verified_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        try {
            Copy-Item -LiteralPath $downloadedScript -Destination $replacementPath -Force -ErrorAction Stop
            Copy-Item -LiteralPath $replacementPath -Destination $script:ScriptPath -Force -ErrorAction Stop
        }
        finally {
            Remove-Item -LiteralPath $replacementPath -Force -ErrorAction SilentlyContinue
        }

        $installedHash = (Get-FileHash -LiteralPath $script:ScriptPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        if ($installedHash -ne $expectedHash) { throw 'The installed monitoring script failed post-update integrity verification.' }
        $installedMetadata = Get-MonitorScriptReleaseMetadata -Path $script:ScriptPath
        if ($installedMetadata.Version -ne $remoteMetadata.Version -or $installedMetadata.ReleaseDate -ne $remoteMetadata.ReleaseDate) {
            throw 'The installed monitoring script metadata does not match the verified release.'
        }
        Set-MonitorInstalledReleaseMetadata -Version $remoteMetadata.Version -ReleaseDate $remoteMetadata.ReleaseDate
        Write-RunLog -Level OK -Category Update -Color Green -Message (
            'Monitoring version {0} was installed successfully. Backup={1}. The current process will finish with version {2}; the new version starts on the next execution.' -f
                $remoteMetadata.Version, $backupFolder, $script:MonitorVersion
        )
    }
    catch {
        $updateError = $_
        if (-not [string]::IsNullOrWhiteSpace($backupFolder)) {
            $backupScript = Join-Path $backupFolder ([IO.Path]::GetFileName($script:ScriptPath))
            if (Test-Path -LiteralPath $backupScript -PathType Leaf) {
                try { Copy-Item -LiteralPath $backupScript -Destination $script:ScriptPath -Force -ErrorAction Stop }
                catch { Write-RunLog -Level Error -Category Update -Color Red -Message ('Automatic update restore also failed: {0}' -f $_.Exception.Message) }
            }
            if (-not [string]::IsNullOrWhiteSpace($script:ResolvedConfigPath)) {
                $backupConfiguration = Join-Path $backupFolder ([IO.Path]::GetFileName($script:ResolvedConfigPath))
                if (Test-Path -LiteralPath $backupConfiguration -PathType Leaf) {
                    try { Copy-Item -LiteralPath $backupConfiguration -Destination $script:ResolvedConfigPath -Force -ErrorAction Stop }
                    catch { Write-RunLog -Level Error -Category Update -Color Red -Message ('Automatic configuration restore also failed: {0}' -f $_.Exception.Message) }
                }
            }
        }
        Write-RunLog -Level Warning -Category Update -Color Yellow -Message (
            'Automatic monitoring update was not applied; this monitoring run will continue with version {0}. Reason: {1}' -f
                $script:MonitorVersion, $updateError.Exception.Message
        )
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($temporaryFolder)) {
            Remove-Item -LiteralPath $temporaryFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $updateLock) {
            $updateLock.Dispose()
        }
    }
}

function Resolve-MonitorConfigurationPath {
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    }

    return Join-Path (Join-Path $script:ScriptDirectory 'monitor-logs') 'D4A-ScheduledMonitor.config.json'
}

function Get-MonitorConfigurationProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $Configuration.PSObject.Properties[$Name]
}

function Get-MonitorTextMojibakeScore {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return 0 }
    $markers = @([char]0x00C2, [char]0x00C3, [char]0x00E2, [char]0x00F0)
    $score = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($markers -contains $character) { $score++ }
    }
    return $score
}

function Repair-MonitorTextEncoding {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return $Value }
    $repairedValue = $Value
    $legacyEncoding = [Text.Encoding]::GetEncoding(1252)
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $currentScore = Get-MonitorTextMojibakeScore -Value $repairedValue
        if ($currentScore -eq 0) { break }
        try {
            $candidate = $strictUtf8.GetString($legacyEncoding.GetBytes($repairedValue))
        }
        catch {
            break
        }
        if ($candidate -eq $repairedValue -or
            (Get-MonitorTextMojibakeScore -Value $candidate) -ge $currentScore) {
            break
        }
        $repairedValue = $candidate
    }
    return $repairedValue
}

function Repair-MonitorConfigurationTextProperties {
    param([Parameter(Mandatory = $true)][object]$Configuration)

    foreach ($propertyName in @('MonitoringName', 'SiteDisplayNames', 'FromAddress')) {
        $property = $Configuration.PSObject.Properties[$propertyName]
        if ($null -eq $property -or $null -eq $property.Value) { continue }
        if ($property.Value -is [Array]) {
            $property.Value = @($property.Value | ForEach-Object { Repair-MonitorTextEncoding -Value ([string]$_) })
        }
        elseif ($property.Value -is [string]) {
            $property.Value = Repair-MonitorTextEncoding -Value ([string]$property.Value)
        }
    }
    return $Configuration
}

function Read-MonitorConfigurationFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $strictUtf8 = [Text.UTF8Encoding]::new($false, $true)
    try {
        $json = $strictUtf8.GetString($bytes)
    }
    catch {
        # Support legacy ANSI configuration files while all new files remain UTF-8.
        $json = [Text.Encoding]::Default.GetString($bytes)
    }
    $json = $json.TrimStart([char]0xFEFF)
    $configuration = $json | ConvertFrom-Json -ErrorAction Stop
    return (Repair-MonitorConfigurationTextProperties -Configuration $configuration)
}

function Convert-MonitorConfigurationValue {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][ValidateSet('String', 'StringList', 'Int', 'Bool', 'Path')][string]$Type,
        [Parameter(Mandatory = $true)][string]$Name
    )

    switch ($Type) {
        'StringList' {
            $items = @($Value | ForEach-Object { (Repair-MonitorTextEncoding -Value ([string]$_)).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($items.Count -eq 0) { throw "Configuration property '$Name' cannot be empty." }
            return ($items -join ',')
        }
        'Int' {
            $number = 0
            if (-not [int]::TryParse(([string]$Value), [ref]$number)) {
                throw "Configuration property '$Name' must be a whole number."
            }
            return $number
        }
        'Bool' {
            if ($Value -is [bool]) { return [bool]$Value }
            $boolean = $false
            if (-not [bool]::TryParse(([string]$Value), [ref]$boolean)) {
                throw "Configuration property '$Name' must be true or false."
            }
            return $boolean
        }
        'Path' {
            $pathValue = ([string]$Value).Trim()
            if ([string]::IsNullOrWhiteSpace($pathValue)) { return '' }
            return [Environment]::ExpandEnvironmentVariables($pathValue)
        }
        default { return (Repair-MonitorTextEncoding -Value ([string]$Value)).Trim() }
    }
}

function Import-MonitorConfiguration {
    $script:ResolvedConfigPath = Resolve-MonitorConfigurationPath
    if (-not (Test-Path -LiteralPath $script:ResolvedConfigPath -PathType Leaf)) {
        if ($script:CommandLineParameterNames -contains 'ConfigPath') {
            throw "Monitor configuration file not found: $($script:ResolvedConfigPath)"
        }
        return
    }

    try {
        $configuration = Read-MonitorConfigurationFile -Path $script:ResolvedConfigPath
    }
    catch {
        throw "Unable to read monitor configuration '$($script:ResolvedConfigPath)': $($_.Exception.Message)"
    }

    $configurationVersion = Get-MonitorConfigurationProperty -Configuration $configuration -Name 'ConfigurationVersion'
    if ($null -eq $configurationVersion) {
        throw "Monitor configuration is missing ConfigurationVersion: $($script:ResolvedConfigPath)"
    }
    if ([int]$configurationVersion.Value -ne 1) {
        throw "Unsupported monitor ConfigurationVersion '$($configurationVersion.Value)'. Expected version 1."
    }

    $settingMap = [ordered]@{
        SiteAddress                = 'StringList'
        SiteDisplayNames           = 'StringList'
        MonitoringName             = 'String'
        NotificationTo             = 'StringList'
        LogDirectory               = 'Path'
        WatchdogLogRoot            = 'Path'
        LogRetentionDays           = 'Int'
        WatchdogLogTailLines       = 'Int'
        D4AInstallRoot             = 'Path'
        NginxErrorLog              = 'Path'
        DbConfigPath               = 'Path'
        NodeExecutable             = 'Path'
        NodemailerModulePath       = 'Path'
        FromAddress                = 'String'
        EmailTimeoutSeconds        = 'Int'
        SmtpServer                 = 'String'
        SmtpPort                   = 'Int'
        SmtpUseSsl                 = 'Bool'
        SmtpCredentialFile         = 'Path'
        HttpTimeoutSeconds         = 'Int'
        ApplicationAttempts        = 'Int'
        ApplicationWarningMs       = 'Int'
        ApplicationAlertMs         = 'Int'
        ApiHealthWarningMs         = 'Int'
        ApiHealthFailureAttempts   = 'Int'
        ApiHealthRetryIntervalSeconds = 'Int'
        NssmExcludedLogRotationEventIds = 'StringList'
        CpuSampleDurationSeconds   = 'Int'
        CpuSampleIntervalSeconds   = 'Int'
        LogLookbackMinutes         = 'Int'
        DiagnosticTailLines        = 'Int'
        NginxErrorsPerMinuteThreshold = 'Int'
        NginxConsecutiveMinutes       = 'Int'
        DataCollectorConsecutiveFailureThreshold = 'Int'
        DataCollectorLastHealthyWarningMinutes   = 'Int'
        DataCollectorLastHealthyCriticalMinutes  = 'Int'
        MaxRedirects               = 'Int'
    }

    foreach ($settingName in $settingMap.Keys) {
        if ($script:CommandLineParameterNames -contains $settingName) { continue }
        $property = Get-MonitorConfigurationProperty -Configuration $configuration -Name $settingName
        if ($null -eq $property -or $null -eq $property.Value) { continue }

        $convertedValue = Convert-MonitorConfigurationValue -Value $property.Value -Type $settingMap[$settingName] -Name $settingName
        Set-Variable -Name $settingName -Value $convertedValue -Scope Script
    }

    $script:ConfigurationLoaded = $true
}

function Test-MonitorConfigurationValues {
    $ranges = [ordered]@{
        LogRetentionDays         = @(1, 365)
        WatchdogLogTailLines     = @(50, 5000)
        EmailTimeoutSeconds      = @(5, 300)
        SmtpPort                 = @(1, 65535)
        HttpTimeoutSeconds       = @(1, 300)
        ApplicationAttempts      = @(1, 10)
        ApplicationWarningMs     = @(1, 60000)
        ApplicationAlertMs       = @(1, 120000)
        ApiHealthWarningMs       = @(1, 60000)
        ApiHealthFailureAttempts = @(1, 5)
        ApiHealthRetryIntervalSeconds = @(1, 60)
        CpuSampleDurationSeconds = @(1, 240)
        CpuSampleIntervalSeconds = @(1, 30)
        LogLookbackMinutes       = @(1, 60)
        DiagnosticTailLines      = @(100, 50000)
        NginxErrorsPerMinuteThreshold = @(1, 10000)
        NginxConsecutiveMinutes       = @(2, 60)
        DataCollectorConsecutiveFailureThreshold = @(1, 10)
        DataCollectorLastHealthyWarningMinutes   = @(1, 120)
        DataCollectorLastHealthyCriticalMinutes  = @(2, 240)
        MaxRedirects             = @(1, 50)
    }

    foreach ($settingName in $ranges.Keys) {
        $value = [int](Get-Variable -Name $settingName -Scope Script -ValueOnly)
        $minimum = [int]$ranges[$settingName][0]
        $maximum = [int]$ranges[$settingName][1]
        if ($value -lt $minimum -or $value -gt $maximum) {
            throw "Monitor setting '$settingName' must be between $minimum and $maximum. Current value: $value."
        }
    }

    $null = Get-NssmExcludedLogRotationEventIds
    if ($DataCollectorLastHealthyWarningMinutes -ge $DataCollectorLastHealthyCriticalMinutes) {
        throw 'DataCollectorLastHealthyWarningMinutes must be lower than DataCollectorLastHealthyCriticalMinutes.'
    }
    if ([string]::IsNullOrWhiteSpace($MonitoringName)) {
        throw 'MonitoringName cannot be empty.'
    }
    if ([string]::IsNullOrWhiteSpace($NotificationTo)) {
        throw 'NotificationTo cannot be empty.'
    }

    foreach ($address in @($NotificationTo -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        try {
            $parsedAddress = [Net.Mail.MailAddress]::new($address)
            if ($parsedAddress.Address -ine $address) { throw 'Address normalization mismatch.' }
        }
        catch {
            throw "NotificationTo contains an invalid email address: $address"
        }
    }

    $configuredUris = @(ConvertTo-HttpUris -Addresses $SiteAddress)
    if (-not [string]::IsNullOrWhiteSpace($SiteDisplayNames)) {
        $configuredNames = @($SiteDisplayNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($configuredNames.Count -ne $configuredUris.Count) {
            throw 'SiteDisplayNames must contain one friendly name for each SiteAddress entry.'
        }
    }
}

function Get-UniqueMonitorSiteAddresses {
    param([Parameter(Mandatory = $true)][string[]]$Addresses)

    $uniqueAddresses = [System.Collections.Generic.List[string]]::new()
    $seenAddresses = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $addressText = (@($Addresses | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ',')
    foreach ($uri in @(ConvertTo-HttpUris -Addresses $addressText)) {
        $normalizedAddress = $uri.AbsoluteUri.TrimEnd('/')
        if ($seenAddresses.Add($normalizedAddress)) {
            $uniqueAddresses.Add($normalizedAddress) | Out-Null
        }
    }

    return @($uniqueAddresses)
}

function Get-MonitorSiteDisplayNames {
    param([Parameter(Mandatory = $true)][Uri[]]$FrontendUris)

    $configuredNames = @($SiteDisplayNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $configuredUris = @(ConvertTo-HttpUris -Addresses $SiteAddress)
    $isConfiguredSiteSet = $configuredNames.Count -eq $FrontendUris.Count -and $configuredUris.Count -eq $FrontendUris.Count
    if ($isConfiguredSiteSet) {
        for ($index = 0; $index -lt $FrontendUris.Count; $index++) {
            if ($configuredUris[$index].AbsoluteUri.TrimEnd('/') -ine $FrontendUris[$index].AbsoluteUri.TrimEnd('/')) {
                $isConfiguredSiteSet = $false
                break
            }
        }
    }
    if ($isConfiguredSiteSet) {
        return @($configuredNames)
    }

    return @($FrontendUris | ForEach-Object { Get-MonitorEndpointLabel -Uri $_ })
}

function Get-MonitorConfigurationForManagement {
    if (-not $script:ConfigurationLoaded -or -not (Test-Path -LiteralPath $script:ResolvedConfigPath -PathType Leaf)) {
        throw "A persistent monitoring configuration is required: $($script:ResolvedConfigPath)"
    }

    try {
        return (Read-MonitorConfigurationFile -Path $script:ResolvedConfigPath)
    }
    catch {
        throw "Unable to read monitoring configuration '$($script:ResolvedConfigPath)': $($_.Exception.Message)"
    }
}

function Add-MonitorConfiguredSites {
    param([Parameter(Mandatory = $true)][string]$Addresses)

    $configuration = Get-MonitorConfigurationForManagement
    $existingAddresses = @($configuration.SiteAddress | ForEach-Object { [string]$_ })
    $requestedAddresses = @($Addresses -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($requestedAddresses.Count -eq 0) {
        throw 'Enter at least one frontend site address.'
    }

    $allAddresses = @(Get-UniqueMonitorSiteAddresses -Addresses @($existingAddresses + $requestedAddresses))
    $existingNormalizedAddresses = @(Get-UniqueMonitorSiteAddresses -Addresses $existingAddresses)
    $existingSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($address in $existingNormalizedAddresses) { $existingSet.Add($address) | Out-Null }
    $addedAddresses = @($allAddresses | Where-Object { -not $existingSet.Contains($_) })

    if ($addedAddresses.Count -eq 0) {
        Write-Host 'All requested sites are already in the monitoring configuration. No file was changed.' -ForegroundColor Yellow
        return
    }

    $configuration.SiteAddress = @($allAddresses)
    $existingNames = @($configuration.SiteDisplayNames | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($existingNames.Count -ne $existingNormalizedAddresses.Count) {
        $existingNames = @($existingNormalizedAddresses | ForEach-Object {
            $frontendUri = (ConvertTo-HttpUris -Addresses $_ | Select-Object -First 1)
            Get-MonitorEndpointLabel -Uri $frontendUri
        })
    }
    $addedNames = @($addedAddresses | ForEach-Object {
        $frontendUri = (ConvertTo-HttpUris -Addresses $_ | Select-Object -First 1)
        Get-MonitorEndpointLabel -Uri $frontendUri
    })
    if ($null -eq $configuration.PSObject.Properties['SiteDisplayNames']) {
        $configuration | Add-Member -MemberType NoteProperty -Name SiteDisplayNames -Value @($existingNames + $addedNames)
    }
    else {
        $configuration.SiteDisplayNames = @($existingNames + $addedNames)
    }
    $configuration.MonitoringName = (@($configuration.SiteDisplayNames) -join ', ')
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $configurationDirectory = Split-Path -Parent $script:ResolvedConfigPath
    $backupPath = Join-Path $configurationDirectory ('{0}_{1}.bak.json' -f ([IO.Path]::GetFileNameWithoutExtension($script:ResolvedConfigPath)), $timestamp)
    Copy-Item -LiteralPath $script:ResolvedConfigPath -Destination $backupPath -ErrorAction Stop
    $json = $configuration | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($script:ResolvedConfigPath, $json + [Environment]::NewLine, $script:Utf8NoBom)

    Write-Host "Added site(s): $($addedAddresses -join ', ')" -ForegroundColor Green
    foreach ($address in $addedAddresses) {
        $frontendUri = (ConvertTo-HttpUris -Addresses $address | Select-Object -First 1)
        $apiUri = Get-D4AApiUri -FrontendUri $frontendUri
        Write-Host "Automatic API health check: $($apiUri.AbsoluteUri)" -ForegroundColor Green
    }
    Write-Host "Configuration updated: $($script:ResolvedConfigPath)" -ForegroundColor Green
    Write-Host "Configuration backup: $backupPath" -ForegroundColor Yellow
}

function Show-MonitorConfiguration {
    $configuration = Get-MonitorConfigurationForManagement
    $configuredSites = @(Get-UniqueMonitorSiteAddresses -Addresses @($configuration.SiteAddress | ForEach-Object { [string]$_ }))
    $configuredNames = @($configuration.SiteDisplayNames | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($configuredNames.Count -ne $configuredSites.Count) {
        $configuredNames = @($configuredSites | ForEach-Object { $_ })
    }
    $apiSites = @(
        foreach ($site in $configuredSites) {
            $frontendUri = (ConvertTo-HttpUris -Addresses $site | Select-Object -First 1)
            (Get-D4AApiUri -FrontendUri $frontendUri).AbsoluteUri
        }
    )
    $schedule = $configuration.TaskScheduler
    $frequency = if ($null -ne $schedule -and $null -ne $schedule.FrequencyMinutes) { "$($schedule.FrequencyMinutes) minute(s)" } else { 'Not recorded in configuration' }
    $dailySummary = if ($null -ne $schedule -and $schedule.DailySummaryEnabled) { "Enabled at $($schedule.DailySummaryTime)" } else { 'Not enabled' }

    Write-Host ''
    Write-Host 'Current Monitoring Configuration' -ForegroundColor Cyan
    [pscustomobject]@{
        MonitorVersion       = $script:MonitorVersion
        ReleaseDate          = $script:MonitorReleaseDate
        ConfigurationFile    = $script:ResolvedConfigPath
        SiteNames            = (@(for ($index = 0; $index -lt $configuredSites.Count; $index++) { '{0} = {1}' -f $configuredSites[$index], $configuredNames[$index] }) -join '; ')
        FrontendSites        = ($configuredSites -join ', ')
        AutomaticApiSites    = ($apiSites -join ', ')
        NotificationAddresses = $NotificationTo
        ScheduledFrequency   = $frequency
        DailySummary         = $dailySummary
        LogDirectory         = $LogDirectory
        LogRetentionDays     = $LogRetentionDays
        WatchdogLogRoot      = $WatchdogLogRoot
    } | Format-List

    Write-Host 'Important thresholds' -ForegroundColor Cyan
    [pscustomobject]@{
        HttpTimeoutSeconds                  = $HttpTimeoutSeconds
        EndpointSlowLogMs                   = $script:EndpointSlowLogMs
        ResourceAlertPercent                = $script:ResourceAlertPercent
        ResourceConsecutiveRunsRequired     = $script:ResourceConsecutiveRunsRequired
        DiskCriticalFreeGb                  = $script:DiskCriticalFreeGb
        DiskCriticalUsedPercent             = $script:DiskCriticalUsedPercent
        ApiHealthFailureAttempts            = $ApiHealthFailureAttempts
        NginxErrorsPerMinuteThreshold       = $NginxErrorsPerMinuteThreshold
        NginxConsecutiveMinutes             = $NginxConsecutiveMinutes
        DataCollectorFailureAlertThreshold  = $DataCollectorConsecutiveFailureThreshold
        DataCollectorLastHealthyWarningMins = $DataCollectorLastHealthyWarningMinutes
        DataCollectorLastHealthyCriticalMins = $DataCollectorLastHealthyCriticalMinutes
    } | Format-List
}

function Get-IgnoreRulesDescriptionHeader {
    return @'
# ==============================================================================
# DESCRIPTION - AUTOMATIC COOLDOWN COMMANDS
# ==============================================================================
# Automatic rules limit duplicate notifications for the same issue. Use these
# commands from the folder containing D4A-ScheduledMonitor-v5.ps1 instead of
# manually changing only one part of an automatic rule.
#
# Change an automatic cooldown and recalculate BOTH duration and expiry from now:
# .\D4A-ScheduledMonitor-v5.ps1 -SetIssueCooldown 'server-cpu' -IssueCooldownDuration '12h'
# .\D4A-ScheduledMonitor-v5.ps1 -SetIssueCooldown 'server-cpu' -IssueCooldownDuration '3d'
#
# Remove the automatic cooldown immediately:
# .\D4A-ScheduledMonitor-v5.ps1 -ClearIssueCooldown 'server-cpu'
#
# Valid durations include 30m, 2h, 3d, and 1w. The rule key is displayed in
# monitoring emails and daily monitoring logs, for example [rule-key=server-cpu].
# ==============================================================================

'@
}

function Get-IgnoreRulesTemplate {
    return @'
# D4A Scheduled Monitor ignore rules
# Format: rule-key|temporary|duration|ignore-until
#         rule-key|permanent||
#         rule-key|automatic|duration|ignore-until
#
# Temporary durations: 30m, 2h, 3d, or 1w. Leave ignore-until empty when
# adding a temporary rule. The monitor calculates and writes the end time.
# Automatic rules are created after a notification and removed when that
# specific issue is no longer detected. Expired temporary rules are commented
# out automatically.
#
# On the 3rd, 13th, and 23rd of each month the current file is archived and a
# clean file is created with only active rules. The three newest archives are
# retained.
#
# Examples:
# application-frontend-availability|temporary|2h|
# server-api-listener|permanent||
'@
}

function Get-MonitorLogsReadme {
    return @'
D4A SCHEDULED MONITOR - MONITOR LOGS README
===========================================

Purpose
-------
D4A-ScheduledMonitor-v5.ps1 checks D4A site availability and server health.
It can check one or more frontend site addresses, the corresponding API health
endpoints, TLS certificates, local D4A Windows services, the local API listener,
  CPU, memory, disk space, Nginx errors, relevant Windows events, and local
  Decide4Action, Data Collector, MDC, PLC, and Mosquitto/MQTT services.

Email behavior
--------------
Normal scheduled runs send an email only for a notification-eligible issue.
Messages use the display name D4A Monitoring and preserve the configured sender
email address. Friendly site names are read as UTF-8 so accents are retained in
email subjects.
After a successful notification, an automatic 24-hour cooldown is added for
that specific issue. When a later scan explicitly confirms the check is healthy,
the monitor sends a recovery email and removes the automatic cooldown. Test and
daily-summary runs send an email even when the server is healthy.

External configuration
----------------------
D4A-ScheduledMonitor.config.json is stored in monitor-logs. It contains the
site name, frontend addresses, notification recipients, installation paths,
log retention, and optional thresholds. Scheduled Task frequency is recorded
there as deployment metadata but remains controlled by Windows Task Scheduler.
Command-line parameters override JSON values for temporary manual tests.
Endpoint latency is logged only above 4500 ms and never triggers an email.
ApiHealthFailureAttempts (default 3), ApiHealthRetryIntervalSeconds (default
5), and NssmExcludedLogRotationEventIds (default 1063,1077) remain available
through the configuration file.

Automatic updates
-----------------
Each execution checks the official GitHub release. A newer monitor is installed
only after update-manifest.json, SHA-256, and PowerShell syntax validation.
Before replacement, the current script, JSON configuration, and related
Scheduled Task definitions are saved under monitor-update-backups. The local
script filename and all site settings remain unchanged. The installed update
takes effect on the next execution. Use -SkipAutomaticUpdate only for a
temporary troubleshooting run.

DAILY LOG FILES AND WATCHDOG EVIDENCE
=====================================
run_log_yyyyMMdd.txt
  One daily execution log containing monitor start/end records, configuration,
  checks, successful results, warnings, email activity, and diagnostics. Each
  entry keeps its component category, such as Application, Server, Diagnostics,
  Email, or Ignore.

error_log_yyyyMMdd.txt
  One daily error log containing warnings, alerts, errors, and their component
  category. This is the primary file to review when an alert email is received.

ignore-rules.txt
  The single persistent file for notification suppression and automatic
  cooldowns. On the 3rd, 13th, and 23rd of each month, active rules are kept
  in a fresh file and the previous file is archived. Only three archives are
  retained.

Watchdog evidence
  Recent Watchdog TaskSchedulerOutput service logs are read only and added to
  the monitor results when they help explain an issue. The monitor never
  restarts services or changes Watchdog state.

RELIABILITY ALERT POLICY
========================
Data Collector LastEventTime SQL timeouts are retryable while the D4A Data
Collector Windows service is Running. The first failure is logged only, the
second logs diagnostics, and the third consecutive failure alerts. The runtime
state file D4A-ScheduledMonitor.state.json stores this counter and LastHealthy
timestamp. It also stores the rule keys and component labels of successfully
emailed issues so one recovery notification can be sent after an explicit OK.
It is state data, not a component log.

When the service is Running, LastHealthy older than 5 minutes is a warning and
older than 10 minutes is critical. If the Windows service is not Running, the
existing immediate Windows-service alert applies.

Nginx upstream errors notify only when the rate is more than 20 matching errors
per minute for two consecutive minutes. Lower or isolated bursts are recorded
without an email alert.

Frontend and API endpoints notify only when they are unreachable. Slow
responses over 4500 ms are retained in error_log without an email alert. CPU
and memory readings are also retained in error_log; they alert only after two
consecutive monitor runs at 90% or higher. A recovered API retry is included
in daily results but does not send a normal notification. NSSM output-file
rotation events 1063 and 1077, and the known harmless "Failed to read output"
pipe-ended event, are excluded. Windows-event warnings and errors are written
to error_log and appear in daily results, but never trigger an immediate email;
service availability is evaluated independently. Watchdog evidence that a
service was successfully restarted is also daily-only; unresolved Watchdog
failures still notify immediately. Disk space has no warning email: it alerts
only at 5 GB free or less, or when used space reaches 95 percent.

NOTIFICATION AND RECOVERY POLICY
================================
Relevant Windows event warnings and errors are always retained in error_log and
daily/test reports, but they do not cause immediate email. D4A and Mosquitto
service checks independently alert when a Windows service is not Running.

Disk usage does not generate warning emails. A critical alert is sent when a
fixed disk has 5 GB free or less, or reaches 95 percent used, whichever occurs
first.

After an alert email is delivered, its rule key and component are retained in
D4A-ScheduledMonitor.state.json. A later scan sends one recovery email only when
the same check explicitly returns OK. Recovery is not inferred from a missing or
failed check. Single-issue subjects identify the component and level; multiple
simultaneous issues use "Multiple Alerts detected".

All dated .txt monitoring logs are retained for the current day plus the prior
four days. README.txt and ignore-rules.txt are not removed by log retention.

ignore-rules.txt
  Controls notification suppression. Each active rule is one line:
    rule-key|temporary|duration|ignore-until
    rule-key|permanent||
    rule-key|automatic|duration|ignore-until
  Automatic rules are maintained by the monitor. Temporary and permanent rules
  may be maintained manually. Comments begin with # and are ignored. On the
  3rd, 13th, and 23rd the monitor archives the current file (for example,
  ignore-rules-aug13.txt), rebuilds ignore-rules.txt with active rules only,
  and retains no more than three archives.

README.txt
  This guide. The monitor creates it only when it is missing, so local notes in
  this file are preserved.

Temporary email helper files
----------------------------
  While an email is being sent, temporary d4a_monitor_email_*.js and .json files
  can briefly appear under monitor-logs. They are removed after the send attempt. If
  a process is interrupted, they may remain and can be deleted after review.

Watchdog log evidence
---------------------
If the Watchdog uses <D4A install root>\Log\TaskSchedulerOutput, the monitor
checks recent per-service Watchdog entries for errors, stale data, timeouts,
crashes, or restart activity. Evidence that Watchdog successfully restarted a
service is included in daily and test reports only. Unresolved failures and
failed restarts still cause an immediate alert. These entries do not cause any
service restart. Set -WatchdogLogRoot to another
TaskSchedulerOutput folder when a nonstandard path is used.

Manual run examples
-------------------
Add one or more sites permanently to the JSON configuration. The monitor
derives and checks the matching API endpoint automatically:
  .\D4A-ScheduledMonitor-v5.ps1 -AddSiteAddress 'hostname:1200,akbou.decide4action.com'

Show the effective configuration without running a health check:
  .\D4A-ScheduledMonitor-v5.ps1 -ShowConfiguration

Run the monitor with its configured sites and normal alert behavior:
  .\D4A-ScheduledMonitor-v5.ps1

Run a test and send a complete email even when there are no issues:
  .\D4A-ScheduledMonitor-v5.ps1 -SendTestResultsEmail

Run a daily-style complete report manually:
  .\D4A-ScheduledMonitor-v5.ps1 -SendDailySummaryEmail

Test one site temporarily without changing the configured default:
  .\D4A-ScheduledMonitor-v5.ps1 -SiteAddress 'https://akbou.decide4action.com' -SendTestResultsEmail

Test multiple frontend sites. Separate them with commas; each matching API is
added automatically:
  .\D4A-ScheduledMonitor-v5.ps1 -SiteAddress 'hostname:1200,akbou.decide4action.com' -SendTestResultsEmail

Increase CPU sampling during a manual performance test:
  .\D4A-ScheduledMonitor-v5.ps1 -CpuSampleDurationSeconds 120 -SendTestResultsEmail

Ignore rule examples
--------------------
The rule key is included in run_log and notification emails, for example:
  [rule-key=server-cpu]

Recommended: change an automatic cooldown. This recalculates both duration and
expiry timestamp from the current time; do not edit only the duration column:
  .\D4A-ScheduledMonitor-v5.ps1 -SetIssueCooldown 'server-cpu' -IssueCooldownDuration '3d'

Remove an automatic cooldown so a currently recurring issue can notify again:
  .\D4A-ScheduledMonitor-v5.ps1 -ClearIssueCooldown 'server-cpu'

Manually add a temporary ignore rule. Leave the last field empty; the monitor
calculates the expiry on its next run:
  application-frontend-availability|temporary|2h|

Manually add a permanent ignore rule. Use this only for an accepted permanent
condition, because it has no expiry:
  server-api-listener|permanent||

To stop ignoring a manually added rule, delete or comment out its line by adding
# at the beginning, then save ignore-rules.txt.
'@
}

function Get-MonitorLogsReadmeUpdate {
    return @'

DAILY LOG FILES AND WATCHDOG EVIDENCE
=====================================
The monitor uses one daily run log and one daily error log:
  run_log_yyyyMMdd.txt - all execution activity, with a component category.
  error_log_yyyyMMdd.txt - warnings, alerts, and errors, with a category.
  ignore-rules.txt - the single persistent ignore and cooldown rules file.

Only the current day and the prior four days are retained. README.txt and
ignore-rules.txt remain untouched by daily log retention, but ignore rules are
rotated on the 3rd, 13th, and 23rd of each month. The monitor reads Watchdog
TaskSchedulerOutput logs when available to provide root-cause evidence, but it
does not restart services or change the Watchdog state.

RELIABILITY ALERT POLICY
========================
Data Collector LastEventTime SQL timeouts are retried while the Windows service
is Running: log only on failure 1, diagnostics on failure 2, and alert on
failure 3. LastHealthy older than 5 minutes is a warning; older than 10 minutes
is critical. Nginx alerts require more than 20 matching errors per minute for
two consecutive minutes. Frontend and API endpoints notify only when
unreachable; responses over 4500 ms are logged without an email. CPU and RAM
notify only after two consecutive monitor runs at 90% or higher. NSSM
server.log rotation events 1063 and 1077, and the harmless pipe-ended output
read event, are excluded. All relevant Windows events are log-only because
service availability is checked separately. Disk space alerts only at 5 GB
free or less, or 95 percent used. A successfully emailed issue produces one
recovery email after a later check explicitly confirms that it is healthy.
'@
}

function Get-MonitorLogsReadmeNotificationPolicy {
    return @'

NOTIFICATION AND RECOVERY POLICY
================================
Relevant Windows event warnings and errors are always retained in error_log and
daily/test reports, but they do not cause immediate email. D4A and Mosquitto
service checks independently alert when a Windows service is not Running.

Disk usage does not generate warning emails. A critical alert is sent when a
fixed disk has 5 GB free or less, or reaches 95 percent used, whichever occurs
first.

After an alert email is delivered, its rule key and component are retained in
D4A-ScheduledMonitor.state.json. A later scan sends one recovery email only when
the same check explicitly returns OK. Recovery is not inferred from a missing or
failed check. Single-issue subjects identify the component and level; multiple
simultaneous issues use "Multiple Alerts detected".
'@
}

function Get-MonitorLogsReadmeAutomaticUpdate {
    return @'

AUTOMATIC MONITOR UPDATES
========================
Every execution checks the official GitHub release for a newer monitor. The
downloaded script must match update-manifest.json, pass SHA-256 verification,
and parse successfully as PowerShell before it can replace the installed file.
The current script, JSON configuration, and related Scheduled Task definitions
are backed up under monitor-update-backups. Site settings, logs, task schedules,
and the installed script filename are preserved. The new code runs on the next
execution. Use -SkipAutomaticUpdate only for a temporary troubleshooting run.
'@
}

function Get-MonitorLogsReadmeAutomaticUpdateReliability {
    return @'

AUTOMATIC UPDATE RELIABILITY
============================
Release requests bypass web caches. The downloaded monitor is also validated
against the current JSON configuration before replacement. A cross-process
lock prevents recurring and daily Scheduled Tasks from installing the same
release simultaneously. After installation, the JSON records the installed
version and release date. If installation fails after backup, both the prior
script and prior configuration are restored and the health check continues.
'@
}

function Ensure-MonitorLogDocumentation {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$IgnoreRulesPath
    )

    $descriptionHeader = Get-IgnoreRulesDescriptionHeader
    $isNewIgnoreRulesFile = -not (Test-Path -LiteralPath $IgnoreRulesPath -PathType Leaf)
    if ($isNewIgnoreRulesFile) {
        [IO.File]::WriteAllText($IgnoreRulesPath, $descriptionHeader, $script:Utf8NoBom)
    }
    else {
        $existingRules = [IO.File]::ReadAllText($IgnoreRulesPath)
        if ($existingRules -notmatch '(?m)^# DESCRIPTION - AUTOMATIC COOLDOWN COMMANDS$') {
            [IO.File]::WriteAllText($IgnoreRulesPath, $descriptionHeader + $existingRules, $script:Utf8NoBom)
        }
    }

    $readmePath = Join-Path $Directory 'README.txt'
    if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
        $readmeContent = (Get-MonitorLogsReadme) +
            (Get-MonitorLogsReadmeUpdate) +
            (Get-MonitorLogsReadmeAutomaticUpdate) +
            (Get-MonitorLogsReadmeNotificationPolicy) +
            (Get-MonitorLogsReadmeAutomaticUpdateReliability)
        [IO.File]::WriteAllText($readmePath, $readmeContent, $script:Utf8NoBom)
    }
    else {
        $existingReadme = [IO.File]::ReadAllText($readmePath)
        if ($existingReadme -notmatch '(?m)^RELIABILITY ALERT POLICY$') {
            [IO.File]::AppendAllText($readmePath, (Get-MonitorLogsReadmeUpdate), $script:Utf8NoBom)
            $existingReadme = [IO.File]::ReadAllText($readmePath)
        }
        if ($existingReadme -notmatch '(?m)^AUTOMATIC MONITOR UPDATES$') {
            [IO.File]::AppendAllText($readmePath, (Get-MonitorLogsReadmeAutomaticUpdate), $script:Utf8NoBom)
            $existingReadme = [IO.File]::ReadAllText($readmePath)
        }
        if ($existingReadme -notmatch '(?m)^NOTIFICATION AND RECOVERY POLICY$') {
            [IO.File]::AppendAllText($readmePath, (Get-MonitorLogsReadmeNotificationPolicy), $script:Utf8NoBom)
            $existingReadme = [IO.File]::ReadAllText($readmePath)
        }
        if ($existingReadme -notmatch '(?m)^AUTOMATIC UPDATE RELIABILITY$') {
            [IO.File]::AppendAllText($readmePath, (Get-MonitorLogsReadmeAutomaticUpdateReliability), $script:Utf8NoBom)
        }
    }

    return $isNewIgnoreRulesFile
}

function Get-DailyMonitorLogPath {
    param([Parameter(Mandatory = $true)][ValidateSet('Run', 'Error')][string]$Type)

    if ([string]::IsNullOrWhiteSpace($script:MonitorLogDirectory)) {
        throw 'The monitor log directory has not been initialized.'
    }

    $prefix = if ($Type -eq 'Run') { 'run_log' } else { 'error_log' }
    return (Join-Path $script:MonitorLogDirectory ('{0}_{1}.txt' -f $prefix, $script:RunStartedAt.ToString('yyyyMMdd')))
}

function Remove-ExpiredMonitorLogs {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $cutoffDate = (Get-Date).Date.AddDays(-($LogRetentionDays - 1))
    $datePattern = '^(?:run_log_|error_log_)?(?<Date>\d{8})\.txt$'
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Filter '*.txt' -ErrorAction SilentlyContinue)) {
        if ($file.Name -notmatch $datePattern) { continue }

        $fileDate = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact($matches.Date, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$fileDate)) {
            continue
        }
        if ($fileDate -lt $cutoffDate) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-MonitorLogging {
    $directory = if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        Join-Path $script:ScriptDirectory 'monitor-logs'
    }
    else {
        [Environment]::ExpandEnvironmentVariables($LogDirectory)
    }

    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force -ErrorAction Stop | Out-Null
    }

    $directory = (Get-Item -LiteralPath $directory -ErrorAction Stop).FullName
    $script:MonitorLogDirectory = $directory
    Remove-ExpiredMonitorLogs -Directory $directory
    $script:RunLogPath = Get-DailyMonitorLogPath -Type Run
    $script:ErrorLogPath = Get-DailyMonitorLogPath -Type Error
    $script:IgnoreRulesPath = Join-Path $directory 'ignore-rules.txt'
    $script:MonitorStatePath = Join-Path $directory 'D4A-ScheduledMonitor.state.json'

    if (-not (Test-Path -LiteralPath $script:RunLogPath -PathType Leaf)) {
        [IO.File]::WriteAllText($script:RunLogPath, '', $script:Utf8NoBom)
    }
    if (-not (Test-Path -LiteralPath $script:ErrorLogPath -PathType Leaf)) {
        [IO.File]::WriteAllText($script:ErrorLogPath, '', $script:Utf8NoBom)
    }

    $isNewIgnoreRulesFile = Ensure-MonitorLogDocumentation -Directory $directory -IgnoreRulesPath $script:IgnoreRulesPath

    if ($isNewIgnoreRulesFile) {
        [IO.File]::AppendAllText($script:IgnoreRulesPath, (Get-IgnoreRulesTemplate), $script:Utf8NoBom)
    }

    $script:LoggingReady = $true
    Rotate-IgnoreRulesIfDue
}

function Get-MonitorRuntimeState {
    $defaultState = [pscustomobject]@{
        StateVersion = 3
        DataCollectorLastEvent = [pscustomobject]@{
            ConsecutiveFailures = 0
            LastHealthy         = $null
            LastProcessedFailureId = $null
            LastDiagnosticsFailureId = $null
        }
        ResourceUtilization = [pscustomobject]@{
            CpuConsecutiveHigh    = 0
            MemoryConsecutiveHigh = 0
        }
        NotifiedIssues = @()
    }
    if ([string]::IsNullOrWhiteSpace($script:MonitorStatePath) -or -not (Test-Path -LiteralPath $script:MonitorStatePath -PathType Leaf)) {
        return $defaultState
    }

    try {
        $state = Get-Content -LiteralPath $script:MonitorStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $state.DataCollectorLastEvent) {
            $state | Add-Member -MemberType NoteProperty -Name DataCollectorLastEvent -Value $defaultState.DataCollectorLastEvent
        }
        foreach ($propertyName in @('ConsecutiveFailures', 'LastHealthy', 'LastProcessedFailureId', 'LastDiagnosticsFailureId')) {
            if ($null -eq $state.DataCollectorLastEvent.PSObject.Properties[$propertyName]) {
                $state.DataCollectorLastEvent | Add-Member -MemberType NoteProperty -Name $propertyName -Value $defaultState.DataCollectorLastEvent.$propertyName
            }
        }
        if ($null -eq $state.ResourceUtilization) {
            $state | Add-Member -MemberType NoteProperty -Name ResourceUtilization -Value $defaultState.ResourceUtilization
        }
        foreach ($propertyName in @('CpuConsecutiveHigh', 'MemoryConsecutiveHigh')) {
            if ($null -eq $state.ResourceUtilization.PSObject.Properties[$propertyName]) {
                $state.ResourceUtilization | Add-Member -MemberType NoteProperty -Name $propertyName -Value $defaultState.ResourceUtilization.$propertyName
            }
        }
        if ($null -eq $state.PSObject.Properties['NotifiedIssues']) {
            $state | Add-Member -MemberType NoteProperty -Name NotifiedIssues -Value @()
        }
        else {
            $state.NotifiedIssues = @($state.NotifiedIssues)
        }
        if ($null -eq $state.PSObject.Properties['StateVersion']) {
            $state | Add-Member -MemberType NoteProperty -Name StateVersion -Value 3
        }
        else {
            $state.StateVersion = 3
        }
        return $state
    }
    catch {
        Write-RunLog -Level Warning -Category Diagnostics -Color Yellow -Message (
            'Unable to read monitor state. Data Collector retry tracking will restart: {0}' -f $_.Exception.Message
        )
        return $defaultState
    }
}

function Save-MonitorRuntimeState {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [switch]$ThrowOnFailure
    )

    if ([string]::IsNullOrWhiteSpace($script:MonitorStatePath)) { return }
    $temporaryPath = '{0}.{1}.tmp' -f $script:MonitorStatePath, [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, ($State | ConvertTo-Json -Depth 6), $script:Utf8NoBom)
        Move-Item -LiteralPath $temporaryPath -Destination $script:MonitorStatePath -Force -ErrorAction Stop
    }
    catch {
        Write-RunLog -Level Warning -Category Diagnostics -Color Yellow -Message (
            'Unable to save monitor state: {0}' -f $_.Exception.Message
        )
        if ($ThrowOnFailure.IsPresent) { throw }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Add-TextToFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    [IO.File]::AppendAllText(
        $Path,
        $Text + [Environment]::NewLine,
        $script:Utf8NoBom
    )
}

function Write-RunLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = 'INFO',
        [string]$Category = 'Monitor',
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [switch]$NoConsole
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
    $line = '[{0}] [{1}] [{2}] {3}' -f $timestamp, $Level.ToUpperInvariant(), $Category, $Message

    if ($script:LoggingReady) {
        try {
            Add-TextToFile -Path $script:RunLogPath -Text $line
        }
        catch {
            Write-Host ('[LOG ERROR] Unable to write run log: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }

    if (-not $NoConsole.IsPresent) {
        Write-Host $line -ForegroundColor $Color
    }
}

function Write-ErrorLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Level = 'ERROR',
        [string]$Category = 'Monitor'
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
    $line = '[{0}] [{1}] [{2}] {3}' -f $timestamp, $Level.ToUpperInvariant(), $Category, $Message

    if ($script:LoggingReady) {
        try {
            Add-TextToFile -Path $script:ErrorLogPath -Text $line
        }
        catch {
            Write-Host ('[LOG ERROR] Unable to write error log: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }
}

function ConvertTo-IgnoreRuleKey {
    param([Parameter(Mandatory = $true)][string]$Value)

    $key = $Value.Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $key = $key.Trim('-')
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw 'An ignore-rule key cannot be empty.'
    }
    return $key
}

function Add-MonitorResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('OK', 'Warning', 'Alert', 'Error')]
        [string]$Severity,

        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Key,
        [bool]$NotificationEligible = $true
    )

    if ([string]::IsNullOrWhiteSpace($Key)) {
        $Key = ConvertTo-IgnoreRuleKey -Value ('{0}-{1}' -f $Category, $Check)
    }
    else {
        $Key = ConvertTo-IgnoreRuleKey -Value $Key
    }

    $result = [pscustomobject]@{
        Time     = Get-Date
        Severity = $Severity
        Category = $Category
        Check    = $Check
        Message  = $Message
        Key      = $Key
        IgnoreActive = $false
        IgnoreMode = $null
        IgnoreUntil = $null
        NotificationEligible = $NotificationEligible
    }
    $script:Results.Add($result) | Out-Null

    $color = switch ($Severity) {
        'OK' { [ConsoleColor]::Green }
        'Warning' { [ConsoleColor]::Yellow }
        'Alert' { [ConsoleColor]::Red }
        'Error' { [ConsoleColor]::Magenta }
    }

    Write-RunLog -Level $Severity -Category $Category -Color $color -Message (
        '{0} [rule-key={1}]: {2}' -f $Check, $Key, $Message
    )
    if ($Severity -ne 'OK') {
        Write-ErrorLog -Level $Severity -Category $Category -Message (
            '{0} [rule-key={1}]: {2}' -f $Check, $Key, $Message
        )
    }
}

function ConvertTo-IgnoreDuration {
    param([Parameter(Mandatory = $true)][string]$Duration)

    $value = $Duration.Trim().ToLowerInvariant()
    if ($value -notmatch '^(?<Amount>[1-9]\d*)\s*(?<Unit>m|mins?|minutes?|h|hrs?|hours?|d|days?|w|weeks?)$') {
        throw ('Invalid temporary ignore duration "{0}". Use values such as 30m, 2h, 3d, or 1w.' -f $Duration)
    }

    $amount = [int]$matches.Amount
    switch -Regex ($matches.Unit) {
        '^m' { return [TimeSpan]::FromMinutes($amount) }
        '^h' { return [TimeSpan]::FromHours($amount) }
        '^d' { return [TimeSpan]::FromDays($amount) }
        '^w' { return [TimeSpan]::FromDays($amount * 7) }
    }
}

function Get-ActiveIgnoreRules {
    if (-not (Test-Path -LiteralPath $script:IgnoreRulesPath -PathType Leaf)) {
        throw ('Ignore-rules file not found: {0}' -f $script:IgnoreRulesPath)
    }

    $now = Get-Date
    $activeRules = [System.Collections.Generic.List[object]]::new()
    $updatedLines = [System.Collections.Generic.List[string]]::new()
    $changed = $false
    $lineNumber = 0

    foreach ($originalLine in @(Get-Content -LiteralPath $script:IgnoreRulesPath -ErrorAction Stop)) {
        $lineNumber++
        $trimmedLine = $originalLine.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or $trimmedLine.StartsWith('#')) {
            $updatedLines.Add($originalLine) | Out-Null
            continue
        }

        $parts = @($originalLine -split '\|', 4)
        if ($parts.Count -lt 2) {
            Write-RunLog -Level Warning -Category Ignore -Color Yellow -Message (
                'Invalid ignore rule at line {0}; expected key|temporary|duration|ignore-until or key|permanent||.' -f $lineNumber
            )
            Write-ErrorLog -Level Warning -Category Ignore -Message ('Invalid ignore rule at line {0}: {1}' -f $lineNumber, $originalLine)
            $updatedLines.Add($originalLine) | Out-Null
            continue
        }

        try {
            $key = ConvertTo-IgnoreRuleKey -Value $parts[0]
        }
        catch {
            Write-RunLog -Level Warning -Category Ignore -Color Yellow -Message ('Invalid ignore-rule key at line {0}: {1}' -f $lineNumber, $_.Exception.Message)
            Write-ErrorLog -Level Warning -Category Ignore -Message ('Invalid ignore-rule key at line {0}: {1}' -f $lineNumber, $originalLine)
            $updatedLines.Add($originalLine) | Out-Null
            continue
        }

        $mode = $parts[1].Trim().ToLowerInvariant()
        $duration = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
        $untilText = if ($parts.Count -ge 4) { $parts[3].Trim() } else { '' }

        if ($mode -eq 'permanent') {
            $normalizedLine = '{0}|permanent||' -f $key
            if ($originalLine -ne $normalizedLine) { $changed = $true }
            $updatedLines.Add($normalizedLine) | Out-Null
            $activeRules.Add([pscustomobject]@{
                Key         = $key
                Mode        = 'permanent'
                Duration    = $null
                IgnoreUntil = $null
            }) | Out-Null
            continue
        }

        if ($mode -notin @('temporary', 'automatic')) {
            Write-RunLog -Level Warning -Category Ignore -Color Yellow -Message (
                'Invalid ignore-rule mode at line {0}: {1}. Use temporary, automatic, or permanent.' -f $lineNumber, $mode
            )
            Write-ErrorLog -Level Warning -Category Ignore -Message ('Invalid ignore-rule mode at line {0}: {1}' -f $lineNumber, $originalLine)
            $updatedLines.Add($originalLine) | Out-Null
            continue
        }

        try {
            $durationSpan = ConvertTo-IgnoreDuration -Duration $duration
        }
        catch {
            Write-RunLog -Level Warning -Category Ignore -Color Yellow -Message ('Invalid temporary rule at line {0}: {1}' -f $lineNumber, $_.Exception.Message)
            Write-ErrorLog -Level Warning -Category Ignore -Message ('Invalid temporary rule at line {0}: {1}' -f $lineNumber, $originalLine)
            $updatedLines.Add($originalLine) | Out-Null
            continue
        }

        $ignoreUntil = [DateTimeOffset]::MinValue
        if ([string]::IsNullOrWhiteSpace($untilText)) {
            $ignoreUntil = [DateTimeOffset]::new($now.Add($durationSpan))
            $changed = $true
            Write-RunLog -Category Ignore -Color Cyan -Message (
                'Temporary rule {0} activated until {1}.' -f $key, $ignoreUntil.ToString('o')
            )
        }
        elseif (-not [DateTimeOffset]::TryParse($untilText, [ref]$ignoreUntil)) {
            Write-RunLog -Level Warning -Category Ignore -Color Yellow -Message ('Invalid ignore-until date at line {0}: {1}' -f $lineNumber, $untilText)
            Write-ErrorLog -Level Warning -Category Ignore -Message ('Invalid ignore-until date at line {0}: {1}' -f $lineNumber, $originalLine)
            $updatedLines.Add($originalLine) | Out-Null
            continue
        }

        $normalizedTemporaryLine = '{0}|{1}|{2}|{3}' -f $key, $mode, $duration, $ignoreUntil.ToString('o')
        if ($ignoreUntil.LocalDateTime -le $now) {
            $expiredLine = '# EXPIRED {0} | {1}' -f $now.ToString('o'), $normalizedTemporaryLine
            $updatedLines.Add($expiredLine) | Out-Null
            $changed = $true
            Write-RunLog -Category Ignore -Color DarkGray -Message ('Expired temporary rule commented out: {0}' -f $key)
            continue
        }

        if ($originalLine -ne $normalizedTemporaryLine) { $changed = $true }
        $updatedLines.Add($normalizedTemporaryLine) | Out-Null
        $activeRules.Add([pscustomobject]@{
            Key         = $key
            Mode        = $mode
            Duration    = $duration
            IgnoreUntil = $ignoreUntil
        }) | Out-Null
    }

    if ($changed) {
        [IO.File]::WriteAllLines($script:IgnoreRulesPath, $updatedLines.ToArray(), $script:Utf8NoBom)
    }

    return @($activeRules.ToArray())
}

function ConvertTo-ActiveIgnoreRuleLine {
    param([Parameter(Mandatory = $true)][object]$Rule)

    if ([string]$Rule.Mode -eq 'permanent') {
        return ('{0}|permanent||' -f $Rule.Key)
    }
    return ('{0}|{1}|{2}|{3}' -f $Rule.Key, $Rule.Mode, $Rule.Duration, $Rule.IgnoreUntil.ToString('o'))
}

function Rotate-IgnoreRulesIfDue {
    if ([string]::IsNullOrWhiteSpace($script:IgnoreRulesPath) -or -not (Test-Path -LiteralPath $script:IgnoreRulesPath -PathType Leaf)) {
        return
    }

    $now = Get-Date
    if ($now.Day -notin @(3, 13, 23)) { return }

    $month = $now.ToString('MMM', [Globalization.CultureInfo]::InvariantCulture).ToLowerInvariant()
    $archivePath = Join-Path (Split-Path -Parent $script:IgnoreRulesPath) ('ignore-rules-{0}{1}.txt' -f $month, $now.Day)
    if (Test-Path -LiteralPath $archivePath -PathType Leaf) { return }

    try {
        # Normalize expired entries before archiving, then keep only active rules
        # in the fresh file so comments and historical entries cannot accumulate.
        $activeRules = @(Get-ActiveIgnoreRules)
        Copy-Item -LiteralPath $script:IgnoreRulesPath -Destination $archivePath -ErrorAction Stop

        $freshLines = [System.Collections.Generic.List[string]]::new()
        foreach ($line in @((Get-IgnoreRulesDescriptionHeader) -split "\r?\n")) {
            $freshLines.Add($line) | Out-Null
        }
        foreach ($line in @((Get-IgnoreRulesTemplate) -split "\r?\n")) {
            $freshLines.Add($line) | Out-Null
        }
        foreach ($rule in $activeRules) {
            $freshLines.Add((ConvertTo-ActiveIgnoreRuleLine -Rule $rule)) | Out-Null
        }
        [IO.File]::WriteAllLines($script:IgnoreRulesPath, $freshLines.ToArray(), $script:Utf8NoBom)

        $archives = @(Get-ChildItem -LiteralPath (Split-Path -Parent $script:IgnoreRulesPath) -File -Filter 'ignore-rules-*.txt' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^ignore-rules-[a-z]{3}\d{1,2}\.txt$' } |
                Sort-Object -Property LastWriteTime -Descending)
        foreach ($oldArchive in @($archives | Select-Object -Skip 3)) {
            Remove-Item -LiteralPath $oldArchive.FullName -Force -ErrorAction Stop
        }

        Write-RunLog -Category Ignore -Color Cyan -Message (
            'Ignore rules rotated to {0}; active rules retained={1}; archives retained={2}.' -f
                $archivePath, $activeRules.Count, [Math]::Min($archives.Count, 3)
        )
    }
    catch {
        Write-RunLog -Level Warning -Category Ignore -Color Yellow -Message (
            'Unable to rotate ignore rules: {0}' -f $_.Exception.Message
        )
        Write-ErrorLog -Level Warning -Category Ignore -Message (
            'Unable to rotate ignore rules: {0}' -f $_.Exception.Message
        )
    }
}

function Update-MonitorResourceConsecutiveHigh {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Cpu', 'Memory')][string]$Resource,
        [Parameter(Mandatory = $true)][bool]$IsHigh
    )

    $state = Get-MonitorRuntimeState
    $propertyName = '{0}ConsecutiveHigh' -f $Resource
    $property = $state.ResourceUtilization.PSObject.Properties[$propertyName]
    if ($null -eq $property) {
        throw "Monitor state does not contain $propertyName."
    }

    $property.Value = if ($IsHigh) { [int]$property.Value + 1 } else { 0 }
    Save-MonitorRuntimeState -State $state
    return [int]$property.Value
}

function Apply-IgnoreRulesToResults {
    param([object[]]$ActiveRules)

    $rulesByKey = @{}
    foreach ($rule in @($ActiveRules)) {
        if (-not $rulesByKey.ContainsKey($rule.Key)) {
            $rulesByKey[$rule.Key] = $rule
        }
        else {
            Write-RunLog -Level Warning -Category Ignore -Color Yellow -Message (
                'Duplicate active ignore rule found for {0}; the first rule is used.' -f $rule.Key
            )
        }
    }

    foreach ($result in $script:Results) {
        $rule = $null
        if ($result.Severity -ne 'OK' -and $rulesByKey.ContainsKey($result.Key)) {
            $rule = $rulesByKey[$result.Key]
        }

        $result.IgnoreActive = ($null -ne $rule)
        $result.IgnoreMode = if ($null -ne $rule) { $rule.Mode } else { $null }
        $result.IgnoreUntil = if ($null -ne $rule) { $rule.IgnoreUntil } else { $null }
    }
}

function Get-IgnoreRuleEntries {
    param([object[]]$Results)

    $keys = @($Results | Where-Object {
        $_.Severity -ne 'OK' -and $_.NotificationEligible -and -not $_.IgnoreActive
    } |
        Select-Object -ExpandProperty Key -Unique | Sort-Object)
    return @(
        foreach ($key in $keys) {
            [pscustomobject]@{
                Key       = $key
                Temporary = '{0}|temporary|2h|' -f $key
                Permanent = '{0}|permanent||' -f $key
            }
        }
    )
}

function Set-AutomaticIssueCooldown {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Duration = '24h',
        [switch]$Remove
    )

    $normalizedKey = ConvertTo-IgnoreRuleKey -Value $Key
    $durationSpan = $null
    if (-not $Remove.IsPresent) {
        $durationSpan = ConvertTo-IgnoreDuration -Duration $Duration
    }

    $existingLines = if (Test-Path -LiteralPath $script:IgnoreRulesPath -PathType Leaf) {
        @(Get-Content -LiteralPath $script:IgnoreRulesPath -ErrorAction Stop)
    }
    else {
        @()
    }

    $updatedLines = [System.Collections.Generic.List[string]]::new()
    $changed = $false
    foreach ($line in $existingLines) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            $updatedLines.Add($line) | Out-Null
            continue
        }

        $parts = @($line -split '\|', 4)
        try {
            $lineKey = if ($parts.Count -ge 1) { ConvertTo-IgnoreRuleKey -Value $parts[0] } else { '' }
        }
        catch {
            $updatedLines.Add($line) | Out-Null
            continue
        }
        $lineMode = if ($parts.Count -ge 2) { $parts[1].Trim().ToLowerInvariant() } else { '' }
        if ($lineKey -eq $normalizedKey -and $lineMode -eq 'automatic') {
            $changed = $true
            continue
        }

        $updatedLines.Add($line) | Out-Null
    }

    if (-not $Remove.IsPresent) {
        $ignoreUntil = [DateTimeOffset]::new((Get-Date).Add($durationSpan))
        $updatedLines.Add(('{0}|automatic|{1}|{2}' -f $normalizedKey, $Duration, $ignoreUntil.ToString('o'))) | Out-Null
        $changed = $true
        Write-RunLog -Category Ignore -Color Cyan -Message (
            'Automatic cooldown set for {0} until {1}.' -f $normalizedKey, $ignoreUntil.ToString('yyyy-MM-dd HH:mm:ss zzz')
        )
    }
    elseif ($changed) {
        Write-RunLog -Category Ignore -Color Green -Message ('Automatic cooldown removed for {0}.' -f $normalizedKey)
    }

    if ($changed) {
        [IO.File]::WriteAllLines($script:IgnoreRulesPath, $updatedLines.ToArray(), $script:Utf8NoBom)
    }
}

function Remove-ResolvedAutomaticIssueCooldowns {
    param([string[]]$ActiveIssueKeys)

    $activeKeys = @{}
    foreach ($key in @($ActiveIssueKeys)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$key)) {
            $activeKeys[(ConvertTo-IgnoreRuleKey -Value $key)] = $true
        }
    }

    if (-not (Test-Path -LiteralPath $script:IgnoreRulesPath -PathType Leaf)) {
        return
    }

    $updatedLines = [System.Collections.Generic.List[string]]::new()
    $changed = $false
    foreach ($line in @(Get-Content -LiteralPath $script:IgnoreRulesPath -ErrorAction Stop)) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            $updatedLines.Add($line) | Out-Null
            continue
        }

        $parts = @($line -split '\|', 4)
        try {
            $lineKey = if ($parts.Count -ge 1) { ConvertTo-IgnoreRuleKey -Value $parts[0] } else { '' }
        }
        catch {
            $updatedLines.Add($line) | Out-Null
            continue
        }
        $lineMode = if ($parts.Count -ge 2) { $parts[1].Trim().ToLowerInvariant() } else { '' }
        if ($lineMode -eq 'automatic' -and -not $activeKeys.ContainsKey($lineKey)) {
            $changed = $true
            Write-RunLog -Category Ignore -Color Green -Message ('Resolved issue removed from automatic cooldown: {0}.' -f $lineKey)
            continue
        }

        $updatedLines.Add($line) | Out-Null
    }

    if ($changed) {
        [IO.File]::WriteAllLines($script:IgnoreRulesPath, $updatedLines.ToArray(), $script:Utf8NoBom)
    }
}

function Get-RecoveredNotifiedIssues {
    $state = Get-MonitorRuntimeState
    $healthyKeys = @{}
    foreach ($result in @($script:Results | Where-Object { $_.Severity -eq 'OK' })) {
        $healthyKeys[(ConvertTo-IgnoreRuleKey -Value $result.Key)] = $true
    }

    $recovered = [System.Collections.Generic.List[object]]::new()
    foreach ($notifiedIssue in @($state.NotifiedIssues)) {
        if ($null -eq $notifiedIssue -or [string]::IsNullOrWhiteSpace([string]$notifiedIssue.Key)) { continue }
        $key = ConvertTo-IgnoreRuleKey -Value ([string]$notifiedIssue.Key)
        if (-not $healthyKeys.ContainsKey($key)) { continue }

        $lastNotified = if ([string]::IsNullOrWhiteSpace([string]$notifiedIssue.LastNotifiedAt)) {
            'unknown time'
        }
        else {
            [string]$notifiedIssue.LastNotifiedAt
        }
        $recovered.Add([pscustomobject]@{
                Time                 = Get-Date
                Severity             = 'OK'
                Category             = [string]$notifiedIssue.Category
                Check                = [string]$notifiedIssue.Check
                Message              = ('Recovery confirmed after a previous {0} notification sent at {1}.' -f $notifiedIssue.Severity, $lastNotified)
                Key                  = $key
                IgnoreActive         = $false
                IgnoreMode           = $null
                IgnoreUntil          = $null
                NotificationEligible = $true
                IsRecovery           = $true
            }) | Out-Null
        Write-RunLog -Level OK -Category Recovery -Color Green -Message (
            'Previously notified issue is healthy: {0}; component={1}; check={2}.' -f $key, $notifiedIssue.Category, $notifiedIssue.Check
        )
    }
    return $recovered.ToArray()
}

function Update-NotifiedIssueStateAfterDelivery {
    param(
        [object[]]$NewlyNotifiedIssues,
        [object[]]$RecoveredIssues
    )

    $state = Get-MonitorRuntimeState
    $issuesByKey = @{}
    foreach ($issue in @($state.NotifiedIssues)) {
        if ($null -eq $issue -or [string]::IsNullOrWhiteSpace([string]$issue.Key)) { continue }
        $issuesByKey[(ConvertTo-IgnoreRuleKey -Value ([string]$issue.Key))] = $issue
    }

    foreach ($recoveredIssue in @($RecoveredIssues)) {
        if ($null -eq $recoveredIssue -or [string]::IsNullOrWhiteSpace([string]$recoveredIssue.Key)) { continue }
        [void]$issuesByKey.Remove((ConvertTo-IgnoreRuleKey -Value ([string]$recoveredIssue.Key)))
    }

    foreach ($issue in @($NewlyNotifiedIssues)) {
        if ($null -eq $issue -or [string]::IsNullOrWhiteSpace([string]$issue.Key)) { continue }
        $key = ConvertTo-IgnoreRuleKey -Value ([string]$issue.Key)
        $issuesByKey[$key] = [pscustomobject]@{
            Key            = $key
            Category       = [string]$issue.Category
            Check          = [string]$issue.Check
            Severity       = [string]$issue.Severity
            LastNotifiedAt = (Get-Date).ToString('o')
        }
    }

    $state.NotifiedIssues = @($issuesByKey.Values | Sort-Object -Property Key)
    Save-MonitorRuntimeState -State $state -ThrowOnFailure
}

function Invoke-SafeMonitorCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Check,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    try {
        & $Action
    }
    catch {
        $detail = $_.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
            $detail = '{0} | Stack: {1}' -f $detail, (($_.ScriptStackTrace -replace '[\r\n]+', ' ').Trim())
        }
        Add-MonitorResult -Severity Error -Category $Category -Check $Check -Message $detail
    }
}

function ConvertTo-HttpUri {
    param([Parameter(Mandatory = $true)][string]$Address)

    $value = $Address.Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw 'SiteAddress is required.'
    }

    if ($value -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') {
        $localAddress = $value -match '(?i)^(localhost|hostname|127\.0\.0\.1|\[::1\])(?=[:/]|$)'
        $localPort = $value -match ':1200(?=/|$)'
        $scheme = if ($localAddress -or $localPort) { 'http' } else { 'https' }
        $value = '{0}://{1}' -f $scheme, $value
    }

    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        throw ('Invalid site address: {0}' -f $Address)
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        throw ('Only HTTP and HTTPS site addresses are supported: {0}' -f $Address)
    }

    return $uri
}

function ConvertTo-HttpUris {
    param([AllowNull()][string]$Addresses)

    $value = if ([string]::IsNullOrWhiteSpace($Addresses)) { 'hostname:1200' } else { $Addresses }
    $uris = [System.Collections.Generic.List[Uri]]::new()
    foreach ($address in @($value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $uri = ConvertTo-HttpUri -Address $address
        if (@($uris | Where-Object { $_.AbsoluteUri.TrimEnd('/') -ieq $uri.AbsoluteUri.TrimEnd('/') }).Count -eq 0) {
            $uris.Add($uri) | Out-Null
        }
    }

    if ($uris.Count -eq 0) {
        throw 'At least one D4A site address is required.'
    }
    return @($uris.ToArray())
}

function Get-MonitorEndpointLabel {
    param([Parameter(Mandatory = $true)][Uri]$Uri)

    if ($Uri.IsDefaultPort) { return $Uri.DnsSafeHost }
    return ('{0}:{1}' -f $Uri.DnsSafeHost, $Uri.Port)
}

function Test-IsIpAddress {
    param([Parameter(Mandatory = $true)][string]$HostName)

    $parsed = $null
    return [Net.IPAddress]::TryParse($HostName, [ref]$parsed)
}

function Get-D4AApiUri {
    param([Parameter(Mandatory = $true)][Uri]$FrontendUri)

    $hostName = $FrontendUri.DnsSafeHost
    $isLocalName = $hostName -notmatch '\.'
    if ($FrontendUri.Port -eq 1200 -or (Test-IsIpAddress -HostName $hostName) -or $isLocalName) {
        return [UriBuilder]::new($FrontendUri.Scheme, $hostName, 32167, '/health').Uri
    }

    $labels = $hostName.Split('.')
    if ($labels[0] -notmatch '(?i)-api$') {
        $labels[0] = '{0}-api' -f $labels[0]
    }

    $builder = [UriBuilder]::new($FrontendUri.Scheme, ($labels -join '.'))
    $builder.Port = -1
    $builder.Path = '/health'
    $builder.Query = ''
    $builder.Fragment = ''
    return $builder.Uri
}

function Get-AuthorityBaseUri {
    param([Parameter(Mandatory = $true)][Uri]$Uri)

    $builder = [UriBuilder]::new($Uri.Scheme, $Uri.DnsSafeHost, $Uri.Port, '/')
    if ($Uri.IsDefaultPort) {
        $builder.Port = -1
    }
    return $builder.Uri
}

function Invoke-HttpProbe {
    param(
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $response = $null
    try {
        $request = [Net.HttpWebRequest]::Create($Uri)
        $request.Method = 'GET'
        $request.UserAgent = 'D4A-ScheduledMonitor/6.0'
        $request.AllowAutoRedirect = $true
        $request.MaximumAutomaticRedirections = $MaxRedirects
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
        $response = [Net.HttpWebResponse]$request.GetResponse()

        return [pscustomobject]@{
            Uri        = $Uri
            FinalUri   = $response.ResponseUri
            StatusCode = [int]$response.StatusCode
            StatusText = [string]$response.StatusDescription
            Millis     = $stopwatch.ElapsedMilliseconds
            Error      = $null
        }
    }
    catch [Net.WebException] {
        $webResponse = $_.Exception.Response
        $statusCode = $null
        $statusText = $null
        $finalUri = $Uri
        if ($null -ne $webResponse) {
            try {
                $statusCode = [int]$webResponse.StatusCode
                $statusText = [string]$webResponse.StatusDescription
                $finalUri = $webResponse.ResponseUri
            }
            catch {
                # Keep the original WebException details when response parsing fails.
            }
        }

        return [pscustomobject]@{
            Uri        = $Uri
            FinalUri   = $finalUri
            StatusCode = $statusCode
            StatusText = $statusText
            Millis     = $stopwatch.ElapsedMilliseconds
            Error      = $_.Exception.Message
        }
    }
    catch {
        return [pscustomobject]@{
            Uri        = $Uri
            FinalUri   = $Uri
            StatusCode = $null
            StatusText = $null
            Millis     = $stopwatch.ElapsedMilliseconds
            Error      = $_.Exception.Message
        }
    }
    finally {
        $stopwatch.Stop()
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Test-HttpProbeSucceeded {
    param([Parameter(Mandatory = $true)][psobject]$Result)

    return $null -ne $Result.StatusCode -and $Result.StatusCode -ge 200 -and $Result.StatusCode -lt 400
}

function Get-HttpProbeFailureDetail {
    param([Parameter(Mandatory = $true)][psobject]$Result)

    if (-not [string]::IsNullOrWhiteSpace([string]$Result.Error)) {
        return [string]$Result.Error
    }
    if ($null -ne $Result.StatusCode) {
        return 'HTTP {0} {1}' -f $Result.StatusCode, $Result.StatusText
    }
    return 'No HTTP response was received.'
}

function Test-WebEndpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Uri]$Uri,
        [ValidateRange(1, 5)][int]$FailureAttempts = 1,
        [ValidateRange(0, 60)][int]$FailureRetryIntervalSeconds = 0
    )

    $attemptResults = [System.Collections.Generic.List[object]]::new()
    $attemptResults.Add((Invoke-HttpProbe -Uri $Uri -TimeoutSeconds $HttpTimeoutSeconds)) | Out-Null

    # Retry only after an availability failure. A healthy first response never
    # creates extra traffic, and a recovery stops the sequence immediately.
    while (-not (Test-HttpProbeSucceeded -Result ($attemptResults | Select-Object -Last 1)) -and $attemptResults.Count -lt $FailureAttempts) {
        if ($FailureRetryIntervalSeconds -gt 0) {
            Write-RunLog -Category Application -Color DarkGray -Message (
                '{0}: availability attempt {1}/{2} failed; retrying in {3} second(s).' -f
                    $Name, $attemptResults.Count, $FailureAttempts, $FailureRetryIntervalSeconds
            )
            Start-Sleep -Seconds $FailureRetryIntervalSeconds
        }
        $attemptResults.Add((Invoke-HttpProbe -Uri $Uri -TimeoutSeconds $HttpTimeoutSeconds)) | Out-Null
    }

    $result = $attemptResults | Select-Object -Last 1
    $successful = Test-HttpProbeSucceeded -Result $result
    if (-not $successful) {
        Add-MonitorResult -Severity Alert -Category Application -Check $Name -Message (
            '{0}; URL={1}; elapsed={2} ms; {3} consecutive availability attempt(s) failed.' -f
                (Get-HttpProbeFailureDetail -Result $result),
                $Uri.AbsoluteUri,
                $result.Millis,
                $attemptResults.Count
        )
        return
    }

    $message = 'HTTP {0} {1}; URL={2}; final={3}; elapsed={4} ms' -f
        $result.StatusCode,
        $result.StatusText,
        $Uri.AbsoluteUri,
        $result.FinalUri.AbsoluteUri,
        $result.Millis

    if ($attemptResults.Count -gt 1) {
        $firstFailure = Get-HttpProbeFailureDetail -Result ($attemptResults | Select-Object -First 1)
        Add-MonitorResult -Severity Warning -Category Application -Check $Name -Message (
            'Initial availability attempt failed ({0}) but recovered on attempt {1}/{2}. {3}' -f
                $firstFailure, $attemptResults.Count, $FailureAttempts, $message
        ) -NotificationEligible:$false
        return
    }

    if ($result.Millis -gt $script:EndpointSlowLogMs) {
        Add-MonitorResult -Severity Warning -Category Application -Check $Name -Message (
            '{0}; response time exceeded the log-only threshold of {1} ms; no email notification is sent for latency.' -f $message, $script:EndpointSlowLogMs
        ) -NotificationEligible:$false
    }
    else {
        Add-MonitorResult -Severity OK -Category Application -Check $Name -Message $message
    }
}

function Test-ApplicationPerformance {
    param(
        [Parameter(Mandatory = $true)][Uri]$PublicApiBaseUri,
        [Parameter(Mandatory = $true)][string]$TargetLabel
    )

    $targets = @(
        [pscustomobject]@{ Name = 'Direct API'; BaseUri = [Uri]'http://127.0.0.1:32167/' },
        [pscustomobject]@{ Name = 'Public API'; BaseUri = $PublicApiBaseUri }
    )
    $endpoints = @(
        '/Decide4ActionStartup/gettenantinfo',
        '/api/getSystemsAvailable'
    )

    foreach ($target in $targets) {
        foreach ($endpoint in $endpoints) {
            $uri = [Uri]::new($target.BaseUri, $endpoint.TrimStart('/'))
            $attemptResults = [System.Collections.Generic.List[object]]::new()
            for ($attempt = 1; $attempt -le $ApplicationAttempts; $attempt++) {
                $attemptResults.Add((Invoke-HttpProbe -Uri $uri -TimeoutSeconds $HttpTimeoutSeconds)) | Out-Null
            }

            $successful = @($attemptResults | Where-Object {
                $null -ne $_.StatusCode -and $_.StatusCode -ge 200 -and $_.StatusCode -lt 400
            })
            $failedCount = $attemptResults.Count - $successful.Count
            $checkName = '{0} {1} ({2})' -f $target.Name, $endpoint, $TargetLabel

            if ($successful.Count -eq 0) {
                $last = $attemptResults | Select-Object -Last 1
                $detail = if (-not [string]::IsNullOrWhiteSpace([string]$last.Error)) {
                    $last.Error
                }
                elseif ($null -ne $last.StatusCode) {
                    'HTTP {0} {1}' -f $last.StatusCode, $last.StatusText
                }
                else {
                    'No valid response.'
                }
                Add-MonitorResult -Severity Alert -Category 'Application performance' -Check $checkName -Message (
                    'All {0} attempt(s) failed; URL={1}; last result={2}' -f $attemptResults.Count, $uri.AbsoluteUri, $detail
                )
                continue
            }

            $averageMs = [Math]::Round((($successful | Measure-Object -Property Millis -Average).Average), 0)
            $maximumMs = [int](($successful | Measure-Object -Property Millis -Maximum).Maximum)
            $message = 'URL={0}; successful={1}/{2}; average={3} ms; maximum={4} ms' -f
                $uri.AbsoluteUri, $successful.Count, $attemptResults.Count, $averageMs, $maximumMs

            if ($failedCount -gt 0) {
                Add-MonitorResult -Severity Warning -Category 'Application performance' -Check $checkName -Message (
                    '{0}; partial availability failure recorded without an email because at least one request reached the endpoint.' -f $message
                ) -NotificationEligible:$false
            }
            elseif ($maximumMs -gt $script:EndpointSlowLogMs) {
                Add-MonitorResult -Severity Warning -Category 'Application performance' -Check $checkName -Message (
                    '{0}; response time exceeded the log-only threshold of {1} ms; no email notification is sent for latency.' -f $message, $script:EndpointSlowLogMs
                ) -NotificationEligible:$false
            }
            else {
                Add-MonitorResult -Severity OK -Category 'Application performance' -Check $checkName -Message $message
            }
        }
    }
}

function Get-MonitorTlsExceptionDetail {
    param([Parameter(Mandatory = $true)][System.Exception]$Exception)

    $messages = [System.Collections.Generic.List[string]]::new()
    $current = $Exception
    while ($null -ne $current) {
        if (-not [string]::IsNullOrWhiteSpace($current.Message)) { $messages.Add($current.Message) | Out-Null }
        $current = $current.InnerException
    }
    return (($messages | Select-Object -Unique) -join ' -> ')
}

function Test-TlsCertificate {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][Uri]$Uri
    )

    if ($Uri.Scheme -ne 'https') {
        Add-MonitorResult -Severity OK -Category TLS -Check $Name -Message 'Skipped because the endpoint uses HTTP.'
        return
    }

    $tcpClient = [Net.Sockets.TcpClient]::new()
    $sslStream = $null
    $certificate = $null
    try {
        $port = if ($Uri.IsDefaultPort) { 443 } else { $Uri.Port }
        $connect = $tcpClient.BeginConnect($Uri.DnsSafeHost, $port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($HttpTimeoutSeconds * 1000)) {
            throw ('Timed out connecting to {0}:{1}.' -f $Uri.DnsSafeHost, $port)
        }
        $tcpClient.EndConnect($connect)
        $tcpClient.ReceiveTimeout = $HttpTimeoutSeconds * 1000
        $tcpClient.SendTimeout = $HttpTimeoutSeconds * 1000

        $acceptCertificate = [Net.Security.RemoteCertificateValidationCallback]{
            param($Sender, $RemoteCertificate, $Chain, $PolicyErrors)
            return $true
        }
        $sslStream = [Net.Security.SslStream]::new($tcpClient.GetStream(), $false, $acceptCertificate)
        $sslStream.ReadTimeout = $HttpTimeoutSeconds * 1000
        $sslStream.WriteTimeout = $HttpTimeoutSeconds * 1000
        $certificates = [Security.Cryptography.X509Certificates.X509CertificateCollection]::new()
        # Explicit TLS 1.2 avoids inheriting legacy SChannel defaults for SslStream.
        $sslStream.AuthenticateAsClient(
            $Uri.DnsSafeHost,
            $certificates,
            [Security.Authentication.SslProtocols]::Tls12,
            $false
        )
        if ($null -eq $sslStream.RemoteCertificate) {
            throw 'The remote server did not provide a TLS certificate.'
        }

        $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($sslStream.RemoteCertificate)
        $daysRemaining = [Math]::Floor(($certificate.NotAfter.ToUniversalTime() - [DateTime]::UtcNow).TotalDays)
        $message = 'Subject={0}; issuer={1}; expires={2}; days remaining={3}' -f
            $certificate.Subject,
            $certificate.Issuer,
            $certificate.NotAfter.ToString('yyyy-MM-dd HH:mm:ss'),
            $daysRemaining

        if ($daysRemaining -lt 0) {
            Add-MonitorResult -Severity Alert -Category TLS -Check $Name -Message ('Certificate has expired. {0}' -f $message)
        }
        elseif ($daysRemaining -le 7) {
            Add-MonitorResult -Severity Alert -Category TLS -Check $Name -Message ('Certificate expires within 7 days. {0}' -f $message)
        }
        elseif ($daysRemaining -le 30) {
            Add-MonitorResult -Severity Warning -Category TLS -Check $Name -Message ('Certificate expires within 30 days. {0}' -f $message)
        }
        else {
            Add-MonitorResult -Severity OK -Category TLS -Check $Name -Message $message
        }
    }
    catch {
        $detail = Get-MonitorTlsExceptionDetail -Exception $_.Exception
        if ($detail -match '(?i)\bSSPI\b|SslProtocolType|SSL/TLS secure channel') {
            Add-MonitorResult -Severity Warning -Category TLS -Check $Name -Message (
                'Local TLS inspection could not complete for {0}: {1}. Endpoint availability is checked separately; no email notification is sent for this local TLS compatibility warning.' -f $Uri.AbsoluteUri, $detail
            ) -NotificationEligible:$false
        }
        else {
            Add-MonitorResult -Severity Error -Category TLS -Check $Name -Message (
                'Unable to inspect certificate for {0}: {1}' -f $Uri.AbsoluteUri, $detail
            )
        }
    }
    finally {
        if ($null -ne $certificate) { $certificate.Dispose() }
        if ($null -ne $sslStream) { $sslStream.Dispose() }
        $tcpClient.Dispose()
    }
}

function Get-SystemClassInstance {
    param(
        [Parameter(Mandatory = $true)][string]$ClassName,
        [string]$Filter
    )

    if ($null -ne (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)) {
        try {
            if ([string]::IsNullOrWhiteSpace($Filter)) {
                return Get-CimInstance -ClassName $ClassName -ErrorAction Stop
            }
            return Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop
        }
        catch {
            # WMI is retained as a compatibility fallback for older servers.
        }
    }

    if ($null -eq (Get-Command -Name Get-WmiObject -ErrorAction SilentlyContinue)) {
        throw ('Neither CIM nor WMI can query {0}.' -f $ClassName)
    }
    if ([string]::IsNullOrWhiteSpace($Filter)) {
        return Get-WmiObject -Class $ClassName -ErrorAction Stop
    }
    return Get-WmiObject -Class $ClassName -Filter $Filter -ErrorAction Stop
}

function Test-D4AWindowsServices {
    $services = @(Get-SystemClassInstance -ClassName Win32_Service)
    $matching = @(
        foreach ($service in $services) {
            $name = [string]$service.Name
            $displayName = [string]$service.DisplayName
            # D4A services consistently use the D4A or Decide4Action prefix.
            # This includes compact names such as D4AMDCService and D4A_PLC.
            $serviceScopePattern = '(?i)^\s*(?:D4A|Decide4Action)'
            $matchesScope =
                $name -match $serviceScopePattern -or
                $displayName -match $serviceScopePattern

            if ($matchesScope) {
                $service
            }
        }
    )

    if ($matching.Count -eq 0) {
        Add-MonitorResult -Severity Warning -Category Server -Check 'D4A Windows services' -Message (
            'No service matched the D4A service scope.'
        ) -Key 'server-d4a-windows-services'
        return
    }

    foreach ($service in ($matching | Sort-Object -Property DisplayName, Name)) {
        $display = if ([string]::IsNullOrWhiteSpace([string]$service.DisplayName)) {
            [string]$service.Name
        }
        else {
            [string]$service.DisplayName
        }
        $message = '{0} [{1}]; State={2}; Status={3}' -f
            $display, $service.Name, $service.State, $service.Status
        $serviceKey = 'server-windows-service-{0}' -f $service.Name

        if ([string]$service.State -eq 'Running' -and [string]$service.Status -eq 'OK') {
            Add-MonitorResult -Severity OK -Category Server -Check 'Windows service' -Message $message -Key $serviceKey
        }
        else {
            Add-MonitorResult -Severity Alert -Category Server -Check 'Windows service' -Message $message -Key $serviceKey
        }
    }
}

function Test-MosquittoWindowsService {
    $services = @(Get-SystemClassInstance -ClassName Win32_Service)
    $matching = @(
        foreach ($service in $services) {
            $name = [string]$service.Name
            $displayName = [string]$service.DisplayName
            if ($name -match '(?i)(?:\bMosquitto\b|\bMQTT\b)' -or $displayName -match '(?i)(?:\bMosquitto\b|\bMQTT\b)') {
                $service
            }
        }
    )

    if ($matching.Count -eq 0) {
        Add-MonitorResult -Severity OK -Category Server -Check 'Mosquitto/MQTT service' -Message (
            'No Mosquitto or MQTT Windows service was found; broker status check was skipped.'
        ) -Key 'server-mosquitto-mqtt-service'
        return
    }

    foreach ($service in ($matching | Sort-Object -Property DisplayName, Name)) {
        $display = if ([string]::IsNullOrWhiteSpace([string]$service.DisplayName)) {
            [string]$service.Name
        }
        else {
            [string]$service.DisplayName
        }
        $message = '{0} [{1}]; State={2}; Status={3}' -f
            $display, $service.Name, $service.State, $service.Status
        $serviceKey = 'server-mosquitto-mqtt-service-{0}' -f $service.Name

        if ([string]$service.State -eq 'Running' -and [string]$service.Status -eq 'OK') {
            Add-MonitorResult -Severity OK -Category Server -Check 'Mosquitto/MQTT service' -Message $message -Key $serviceKey
        }
        else {
            Add-MonitorResult -Severity Alert -Category Server -Check 'Mosquitto/MQTT service' -Message $message -Key $serviceKey
        }
    }
}

function Test-ApiListener {
    $listeners = @()
    $connectionQueryFailed = $false
    if ($null -ne (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        try {
            $listeners = @(Get-NetTCPConnection -LocalPort 32167 -State Listen -ErrorAction Stop)
        }
        catch {
            $connectionQueryFailed = $true
            Write-ErrorLog -Level Warning -Category Server -Message (
                'Get-NetTCPConnection could not inspect port 32167; trying netstat: {0}' -f $_.Exception.Message
            )
        }
    }

    if ($null -eq (Get-Command -Name Get-NetTCPConnection -ErrorAction SilentlyContinue) -or $connectionQueryFailed) {
        $netstatCommand = Get-Command -Name netstat.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $netstatCommand) {
            throw 'Neither Get-NetTCPConnection nor netstat.exe can inspect port 32167.'
        }

        $netstatRows = @(& $netstatCommand.Source -ano -p tcp 2>$null)
        $listeners = @(
            foreach ($row in $netstatRows) {
                if ([string]$row -match '^\s*TCP\s+\S+:32167\s+\S+\s+LISTENING\s+(?<Pid>\d+)\s*$') {
                    [pscustomobject]@{ OwningProcess = [int]$matches.Pid }
                }
            }
        )
    }

    if ($listeners.Count -eq 0) {
        Add-MonitorResult -Severity Alert -Category Server -Check 'API listener' -Message 'No process is listening on TCP port 32167.'
        return
    }

    $processDetails = @(
        foreach ($listener in $listeners) {
            $process = Get-Process -Id $listener.OwningProcess -ErrorAction SilentlyContinue
            if ($null -ne $process) {
                '{0} (PID {1}, {2:N1} MB)' -f $process.ProcessName, $process.Id, ($process.WorkingSet64 / 1MB)
            }
            else {
                'PID {0}' -f $listener.OwningProcess
            }
        }
    )
    $message = '{0} listener(s) found on port 32167: {1}' -f $listeners.Count, ($processDetails -join '; ')
    if ($listeners.Count -gt 1) {
        Add-MonitorResult -Severity Warning -Category Server -Check 'API listener' -Message $message
    }
    else {
        Add-MonitorResult -Severity OK -Category Server -Check 'API listener' -Message $message
    }
}

function Test-MemoryHealth {
    $operatingSystem = @(Get-SystemClassInstance -ClassName Win32_OperatingSystem) | Select-Object -First 1
    if ($null -eq $operatingSystem -or [double]$operatingSystem.TotalVisibleMemorySize -le 0) {
        throw 'Windows did not return valid memory totals.'
    }

    $totalKb = [double]$operatingSystem.TotalVisibleMemorySize
    $freeKb = [double]$operatingSystem.FreePhysicalMemory
    $usedPercent = [Math]::Round((($totalKb - $freeKb) / $totalKb) * 100, 1)
    $usedGb = [Math]::Round(($totalKb - $freeKb) / 1MB, 2)
    $totalGb = [Math]::Round($totalKb / 1MB, 2)
    $message = '{0}% used ({1} GB of {2} GB)' -f $usedPercent, $usedGb, $totalGb

    if ($usedPercent -ge $script:ResourceAlertPercent) {
        $consecutiveHigh = Update-MonitorResourceConsecutiveHigh -Resource Memory -IsHigh $true
        if ($consecutiveHigh -ge $script:ResourceConsecutiveRunsRequired) {
            Add-MonitorResult -Severity Alert -Category Server -Check Memory -Message (
                '{0}; alert threshold={1}%; consecutive high runs={2}; email notification is eligible.' -f
                    $message, $script:ResourceAlertPercent, $consecutiveHigh
            )
        }
        else {
            Add-MonitorResult -Severity Warning -Category Server -Check Memory -Message (
                '{0}; threshold={1}%; consecutive high runs={2}/{3}; logged without an email notification.' -f
                    $message, $script:ResourceAlertPercent, $consecutiveHigh, $script:ResourceConsecutiveRunsRequired
            ) -NotificationEligible:$false
        }
    }
    elseif ($usedPercent -ge 85) {
        [void](Update-MonitorResourceConsecutiveHigh -Resource Memory -IsHigh $false)
        Add-MonitorResult -Severity Warning -Category Server -Check Memory -Message (
            '{0}; warning threshold=85%; logged without an email notification.' -f $message
        ) -NotificationEligible:$false
    }
    else {
        [void](Update-MonitorResourceConsecutiveHigh -Resource Memory -IsHigh $false)
        Add-MonitorResult -Severity OK -Category Server -Check Memory -Message $message
    }
}

function Get-OneCpuSample {
    try {
        $row = @(Get-SystemClassInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'") |
            Select-Object -First 1
        if ($null -ne $row -and $null -ne $row.PercentProcessorTime) {
            return [double]$row.PercentProcessorTime
        }
    }
    catch {
        # Fall through to the less precise Win32_Processor value.
    }

    $processors = @(Get-SystemClassInstance -ClassName Win32_Processor | Where-Object { $null -ne $_.LoadPercentage })
    if ($processors.Count -eq 0) {
        throw 'Windows did not return a CPU utilization value.'
    }
    return [double](($processors | Measure-Object -Property LoadPercentage -Average).Average)
}

function Test-CpuHealth {
    $sampleCount = [Math]::Max(1, [int][Math]::Ceiling($CpuSampleDurationSeconds / [double]$CpuSampleIntervalSeconds))
    $samples = [System.Collections.Generic.List[double]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()

    Write-RunLog -Category Server -Message (
        'CPU sampling started: {0} sample(s), interval {1} second(s).' -f $sampleCount, $CpuSampleIntervalSeconds
    ) -Color DarkGray

    for ($index = 1; $index -le $sampleCount; $index++) {
        try {
            $samples.Add((Get-OneCpuSample)) | Out-Null
        }
        catch {
            $errors.Add($_.Exception.Message) | Out-Null
        }
        if ($index -lt $sampleCount) {
            Start-Sleep -Seconds $CpuSampleIntervalSeconds
        }
    }

    if ($samples.Count -eq 0) {
        throw ('Every CPU sample failed. {0}' -f ($errors -join ' | '))
    }

    $average = [Math]::Round((($samples | Measure-Object -Average).Average), 1)
    $maximum = [Math]::Round((($samples | Measure-Object -Maximum).Maximum), 1)
    $message = 'Average={0}%; maximum={1}%; successful samples={2}/{3}' -f
        $average, $maximum, $samples.Count, $sampleCount

    if ($average -ge $script:ResourceAlertPercent) {
        $consecutiveHigh = Update-MonitorResourceConsecutiveHigh -Resource Cpu -IsHigh $true
        if ($consecutiveHigh -ge $script:ResourceConsecutiveRunsRequired) {
            Add-MonitorResult -Severity Alert -Category Server -Check CPU -Message (
                '{0}; alert threshold={1}%; consecutive high runs={2}; email notification is eligible.' -f
                    $message, $script:ResourceAlertPercent, $consecutiveHigh
            )
        }
        else {
            Add-MonitorResult -Severity Warning -Category Server -Check CPU -Message (
                '{0}; threshold={1}%; consecutive high runs={2}/{3}; logged without an email notification.' -f
                    $message, $script:ResourceAlertPercent, $consecutiveHigh, $script:ResourceConsecutiveRunsRequired
            ) -NotificationEligible:$false
        }
    }
    elseif ($average -ge 70) {
        [void](Update-MonitorResourceConsecutiveHigh -Resource Cpu -IsHigh $false)
        Add-MonitorResult -Severity Warning -Category Server -Check CPU -Message (
            '{0}; warning threshold=70%; logged without an email notification.' -f $message
        ) -NotificationEligible:$false
    }
    elseif ($errors.Count -gt 0) {
        [void](Update-MonitorResourceConsecutiveHigh -Resource Cpu -IsHigh $false)
        Add-MonitorResult -Severity Warning -Category Server -Check CPU -Message (
            '{0}; failed samples={1}' -f $message, $errors.Count
        ) -NotificationEligible:$false
    }
    else {
        [void](Update-MonitorResourceConsecutiveHigh -Resource Cpu -IsHigh $false)
        Add-MonitorResult -Severity OK -Category Server -Check CPU -Message $message
    }
}

function Test-DiskHealth {
    $disks = @(Get-SystemClassInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' |
        Where-Object { [double]$_.Size -gt 0 } |
        Sort-Object -Property DeviceID)
    if ($disks.Count -eq 0) {
        throw 'Windows did not return any fixed disks.'
    }

    foreach ($disk in $disks) {
        $freeGb = [Math]::Round(([double]$disk.FreeSpace / 1GB), 2)
        $sizeGb = [Math]::Round(([double]$disk.Size / 1GB), 2)
        $freePercent = [Math]::Round(([double]$disk.FreeSpace / [double]$disk.Size) * 100, 1)
        $message = '{0}; free={1} GB of {2} GB ({3}% free)' -f
            $disk.DeviceID, $freeGb, $sizeGb, $freePercent
        $diskKey = 'server-disk-space-{0}' -f $disk.DeviceID

        $usedPercent = [Math]::Round(100 - $freePercent, 1)
        if ($freeGb -le $script:DiskCriticalFreeGb -or $usedPercent -ge $script:DiskCriticalUsedPercent) {
            Add-MonitorResult -Severity Alert -Category Server -Check 'Disk space' -Message (
                '{0}; critical threshold reached: free space <= {1} GB or used space >= {2}%.' -f
                    $message, $script:DiskCriticalFreeGb, $script:DiskCriticalUsedPercent
            ) -Key $diskKey
        }
        else {
            Add-MonitorResult -Severity OK -Category Server -Check 'Disk space' -Message $message -Key $diskKey
        }
    }
}

function Resolve-NginxErrorLog {
    if (-not [string]::IsNullOrWhiteSpace($NginxErrorLog)) {
        return [Environment]::ExpandEnvironmentVariables($NginxErrorLog)
    }

    $roots = @(
        $D4AInstallRoot,
        $env:D4A_HOME,
        'D:\Apps\Decide4Action',
        'C:\Apps\Decide4Action',
        'D:\Apps\Decide4Action-v2',
        'C:\Apps\Decide4Action-v2',
        'C:\Program Files\Decide4Action',
        'C:\Program Files\Decide4Action-v2'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique

    foreach ($root in $roots) {
        $expandedRoot = [Environment]::ExpandEnvironmentVariables([string]$root)
        foreach ($folder in @('Decide4Action-Ngnix', 'Decide4Action-Nginx')) {
            $nginxRoot = Join-Path $expandedRoot $folder
            if (-not (Test-Path -LiteralPath $nginxRoot -PathType Container)) {
                continue
            }
            $candidate = Get-ChildItem -LiteralPath $nginxRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'nginx-*' } |
                Sort-Object -Property LastWriteTime -Descending |
                ForEach-Object { Join-Path $_.FullName 'logs\error.log' } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                return [string]$candidate
            }
        }
    }
    return $null
}

function Test-NginxErrors {
    $path = Resolve-NginxErrorLog
    if ([string]::IsNullOrWhiteSpace($path)) {
        Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Nginx errors' -Message (
            'No Nginx error log was discovered; optional log inspection was skipped.'
        )
        return
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-MonitorResult -Severity Error -Category Diagnostics -Check 'Nginx errors' -Message ('Log file not found: {0}' -f $path)
        return
    }

    $now = Get-Date
    $since = $now.AddMinutes(-[Math]::Max($LogLookbackMinutes, $NginxConsecutiveMinutes + 1))
    $matching = [System.Collections.Generic.List[string]]::new()
    $minuteBuckets = @{}
    foreach ($line in @(Get-Content -LiteralPath $path -Tail $DiagnosticTailLines -ErrorAction Stop)) {
        if ($line -notmatch '(?i)10054|upstream prematurely closed|connect\(\) failed|timed out') {
            continue
        }

        $include = $false
        if ($line -match '^(?<Stamp>\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2})') {
            $parsed = [DateTime]::MinValue
            if ([DateTime]::TryParseExact(
                $matches.Stamp,
                'yyyy/MM/dd HH:mm:ss',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::AssumeLocal,
                [ref]$parsed
            )) {
                $include = $parsed -ge $since
                if ($include) {
                    $minute = [datetime]::new($parsed.Year, $parsed.Month, $parsed.Day, $parsed.Hour, $parsed.Minute, 0)
                    $minuteKey = $minute.ToString('o')
                    if (-not $minuteBuckets.ContainsKey($minuteKey)) { $minuteBuckets[$minuteKey] = 0 }
                    $minuteBuckets[$minuteKey]++
                }
            }
        }
        if ($include) {
            $matching.Add($line) | Out-Null
        }
    }

    if ($matching.Count -eq 0) {
        Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Nginx errors' -Message (
            'No matching upstream errors since {0}; log={1}' -f $since.ToString('yyyy-MM-dd HH:mm:ss'), $path
        )
        return
    }

    $sustainedWindow = $null
    foreach ($minuteKey in @($minuteBuckets.Keys | Sort-Object)) {
        $windowStart = [datetime]::Parse($minuteKey, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $windowMatches = $true
        for ($offset = 0; $offset -lt $NginxConsecutiveMinutes; $offset++) {
            $candidateKey = $windowStart.AddMinutes($offset).ToString('o')
            if (-not $minuteBuckets.ContainsKey($candidateKey) -or [int]$minuteBuckets[$candidateKey] -le $NginxErrorsPerMinuteThreshold) {
                $windowMatches = $false
                break
            }
        }
        if ($windowMatches) {
            $sustainedWindow = $windowStart
            break
        }
    }

    $sample = (($matching | Select-Object -Last 3) -replace '[\r\n]+', ' ') -join ' | '
    if ($sample.Length -gt 1000) { $sample = $sample.Substring(0, 1000) + '...' }
    if ($null -ne $sustainedWindow) {
        $rates = for ($offset = 0; $offset -lt $NginxConsecutiveMinutes; $offset++) {
            $minute = $sustainedWindow.AddMinutes($offset)
            '{0}={1}' -f $minute.ToString('yyyy-MM-dd HH:mm'), $minuteBuckets[$minute.ToString('o')]
        }
        Add-MonitorResult -Severity Alert -Category Diagnostics -Check 'Nginx errors' -Message (
            'Sustained Nginx upstream error rate exceeded {0} errors/minute for {1} consecutive minutes; rates={2}; log={3}; sample={4}' -f
                $NginxErrorsPerMinuteThreshold, $NginxConsecutiveMinutes, ($rates -join ', '), $path, $sample
        )
        return
    }

    Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Nginx errors' -Message (
        '{0} matching upstream error(s) since {1}, but no sustained rate exceeded {2} errors/minute for {3} consecutive minutes; log={4}' -f
            $matching.Count, $since.ToString('yyyy-MM-dd HH:mm:ss'), $NginxErrorsPerMinuteThreshold, $NginxConsecutiveMinutes, $path
    )
}

function Get-NssmExcludedLogRotationEventIds {
    $eventIds = [System.Collections.Generic.List[int]]::new()
    foreach ($value in @($NssmExcludedLogRotationEventIds -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $eventId = 0
        if (-not [int]::TryParse($value, [ref]$eventId) -or $eventId -lt 1) {
            throw ('NssmExcludedLogRotationEventIds contains an invalid event ID: {0}' -f $value)
        }
        if (-not $eventIds.Contains($eventId)) {
            $eventIds.Add($eventId) | Out-Null
        }
    }
    return @($eventIds.ToArray())
}

function Test-IsExcludedNssmLogRotationEvent {
    param(
        [Parameter(Mandatory = $true)][psobject]$Event,
        [Parameter(Mandatory = $true)][int[]]$ExcludedEventIds
    )

    if ([string]$Event.ProviderName -notmatch '(?i)^nssm$' -or [int]$Event.Id -notin $ExcludedEventIds) {
        return $false
    }

    # Do not suppress unrelated NSSM events that happen to reuse an ID. Both
    # configured IDs are safe only for the expected server.log rotation messages.
    return [string]$Event.Message -match '(?i)(?:rotated output file|failed to rotate output file).*server\.log'
}

function Test-IsExcludedNssmPipeEndedOutputEvent {
    param([Parameter(Mandatory = $true)][psobject]$Event)

    if ([string]$Event.ProviderName -notmatch '(?i)^nssm$') {
        return $false
    }

    # NSSM can emit this after a child process ends its output pipe. It is not
    # evidence that the D4A service is unavailable and must not create alerts.
    return [string]$Event.Message -match '(?is)failed\s+to\s+read\s+output\s+for\s+service\b.*readfile\(\):\s*the\s+pipe\s+has\s+been\s+ended'
}

function Test-RelevantWindowsEvents {
    if ($null -eq (Get-Command -Name Get-WinEvent -ErrorAction SilentlyContinue)) {
        throw 'Get-WinEvent is unavailable.'
    }

    $since = (Get-Date).AddMinutes(-$LogLookbackMinutes)
    $excludedNssmEventIds = @(Get-NssmExcludedLogRotationEventIds)
    $events = [System.Collections.Generic.List[object]]::new()
    foreach ($logName in @('Application', 'System')) {
        # Get-WinEvent reports "no matching events" as a non-terminating error.
        # An empty window is healthy, so suppress only that command-level noise.
        foreach ($event in @(Get-WinEvent -FilterHashtable @{ LogName = $logName; StartTime = $since } -ErrorAction SilentlyContinue)) {
            if (Test-IsExcludedNssmLogRotationEvent -Event $event -ExcludedEventIds $excludedNssmEventIds) {
                Write-RunLog -Category Diagnostics -Color DarkGray -Message (
                    'Excluded safe NSSM server.log rotation event: ID={0}; time={1}.' -f $event.Id, $event.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                )
                continue
            }
            if (Test-IsExcludedNssmPipeEndedOutputEvent -Event $event) {
                Write-RunLog -Category Diagnostics -Color DarkGray -Message (
                    'Excluded non-actionable NSSM pipe-ended output event: ID={0}; time={1}.' -f $event.Id, $event.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                )
                continue
            }
            $messageText = [string]$event.Message
            $provider = [string]$event.ProviderName
            $componentMentioned = $messageText -match '(?i)D4A|Decide4Action|node(?:\.exe)?|32167|Data Collector|\bPLC\b|\bMDC\b'
            $providerRelevant = $provider -match '(?i)Application Error|\.NET Runtime|Windows Error Reporting|Node|nssm|Service Control Manager'
            if ($componentMentioned -and $providerRelevant) {
                $events.Add($event) | Out-Null
            }
        }
    }

    if ($events.Count -eq 0) {
        Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Windows events' -Message (
            'No relevant crash or service events since {0}.' -f $since.ToString('yyyy-MM-dd HH:mm:ss')
        )
        return
    }

    foreach ($group in @($events | Group-Object -Property ProviderName, Id)) {
        $latest = $group.Group | Sort-Object -Property TimeCreated -Descending | Select-Object -First 1
        $eventMessage = (([string]$latest.Message -replace '[\r\n]+', ' ').Trim())
        if ($eventMessage.Length -gt 700) {
            $eventMessage = $eventMessage.Substring(0, 700) + '...'
        }
        $severity = if (@($group.Group | Where-Object {
            $_.Level -in @(1, 2) -or $_.LevelDisplayName -match '(?i)critical|error'
        }).Count -gt 0) { 'Alert' } else { 'Warning' }
        $eventKey = 'diagnostics-windows-event-{0}-{1}' -f $latest.ProviderName, $latest.Id
        Add-MonitorResult -Severity $severity -Category Diagnostics -Check 'Windows events' -Message (
            '{0} event(s); provider={1}; ID={2}; latest={3}; message={4}' -f
                $group.Count,
                $latest.ProviderName,
                $latest.Id,
                $latest.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'),
                $eventMessage
        ) -Key $eventKey -NotificationEligible:$false
        Write-RunLog -Category Diagnostics -Color DarkGray -Message (
            'Windows event {0} is log-only. D4A and Mosquitto service availability is evaluated independently by the Windows service checks.' -f $eventKey
        )
    }
}

function Resolve-WatchdogLogRoot {
    $candidates = [System.Collections.Generic.List[string]]::new()
    function Add-WatchdogCandidate {
        param([AllowNull()][string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
        if (-not $candidates.Contains($expandedPath)) {
            $candidates.Add($expandedPath) | Out-Null
        }
    }

    Add-WatchdogCandidate -Path $WatchdogLogRoot
    foreach ($root in @($D4AInstallRoot, $env:D4A_HOME, (Split-Path -Parent $script:ScriptDirectory), 'D:\Apps\Decide4Action', 'C:\Apps\Decide4Action')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$root)) {
            Add-WatchdogCandidate -Path (Join-Path ([Environment]::ExpandEnvironmentVariables([string]$root)) 'Log\TaskSchedulerOutput')
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Get-Item -LiteralPath $candidate -ErrorAction Stop).FullName
        }
    }
    return $null
}

function Get-WatchdogLogEntryTime {
    param(
        # Blank separator lines are valid in TaskSchedulerOutput logs.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line,
        [datetime]$FallbackTime
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $FallbackTime }
    if ($Line -match '^\[(?<Timestamp>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]') {
        $parsedTime = [DateTime]::MinValue
        if ([DateTime]::TryParseExact($matches.Timestamp, 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsedTime)) {
            return $parsedTime
        }
    }
    return $FallbackTime
}

function ConvertTo-MonitorDateTimeOffset {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Value.Trim(), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
        return $parsed
    }
    return $null
}

function Get-DataCollectorWindowsService {
    $services = @(Get-SystemClassInstance -ClassName Win32_Service)
    return @(
        $services | Where-Object {
            $name = [string]$_.Name
            $displayName = [string]$_.DisplayName
            ($name -match '(?i)^\s*(?:D4A|Decide4Action).*Data\s*Collector' -or
             $displayName -match '(?i)^\s*(?:D4A|Decide4Action).*Data\s*Collector')
        } | Select-Object -First 1
    )
}

function Test-IsDataCollectorWatchdogFile {
    param([Parameter(Mandatory = $true)][object]$File)

    $serviceFolderName = Split-Path -Leaf (Split-Path -Parent $File.FullName)
    return $serviceFolderName -match '(?i)data\s*collector|datacollector|^dc$'
}

function Test-DataCollectorWatchdogHealth {
    param([Parameter(Mandatory = $true)][string]$WatchdogRoot)

    $dataCollectorService = @(Get-DataCollectorWindowsService)
    if ($dataCollectorService.Count -eq 0) {
        Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Data Collector SQL health' -Message (
            'No D4A Data Collector Windows service was found; Watchdog LastEventTime retry analysis was skipped.'
        ) -Key 'diagnostics-datacollector-sql-health'
        return
    }

    $service = $dataCollectorService[0]
    if ([string]$service.State -ne 'Running' -or [string]$service.Status -ne 'OK') {
        # Test-D4AWindowsServices has already added the immediate service alert.
        Write-RunLog -Level Alert -Category Diagnostics -Color Red -Message (
            'Data Collector service is not running. SQL LastEventTime retry logic was skipped; service state={0}; status={1}.' -f $service.State, $service.Status
        )
        return
    }

    $todayFileName = '{0}.txt' -f (Get-Date -Format 'yyyyMMdd')
    $dataCollectorLog = @(
        Get-ChildItem -LiteralPath $WatchdogRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)data\s*collector|datacollector|^dc$' } |
            ForEach-Object { Join-Path $_.FullName $todayFileName } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -First 1
    )
    if ($dataCollectorLog.Count -eq 0) {
        Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Data Collector SQL health' -Message (
            'Data Collector service is running, but no current Watchdog Data Collector log was found. SQL LastEventTime retry analysis was skipped.'
        ) -Key 'diagnostics-datacollector-sql-health'
        return
    }

    $logFile = Get-Item -LiteralPath $dataCollectorLog[0] -ErrorAction Stop
    $state = Get-MonitorRuntimeState
    $tracking = $state.DataCollectorLastEvent
    $entryTime = $logFile.LastWriteTime
    $latestFailure = $null
    $latestHealthy = ConvertTo-MonitorDateTimeOffset -Value ([string]$tracking.LastHealthy)
    foreach ($line in @(Get-Content -LiteralPath $logFile.FullName -Tail $WatchdogLogTailLines -ErrorAction Stop)) {
        $entryTime = Get-WatchdogLogEntryTime -Line ([string]$line) -FallbackTime $entryTime
        if ($line -match '(?i)LastHealthy:\s*(?<Value>[^|,\r\n]+)') {
            $candidateHealthy = ConvertTo-MonitorDateTimeOffset -Value $matches.Value
            if ($null -ne $candidateHealthy -and ($null -eq $latestHealthy -or $candidateHealthy -gt $latestHealthy)) {
                $latestHealthy = $candidateHealthy
            }
        }
        if ($line -match '(?i)Data Collector LastEvent healthy') {
            $candidateHealthy = [DateTimeOffset]$entryTime
            if ($null -eq $latestHealthy -or $candidateHealthy -gt $latestHealthy) { $latestHealthy = $candidateHealthy }
        }
        if ($line -match '(?i)Unable to evaluate LastEventTime|Data Collector LastEvent error') {
            $failureId = '{0}|{1}' -f $entryTime.ToUniversalTime().ToString('o'), (([string]$line -replace '\s+', ' ').Trim())
            $failure = [pscustomobject]@{
                Id      = $failureId
                Time    = [DateTimeOffset]$entryTime
                IsSqlTimeout = $line -match '(?i)Execution Timeout Expired|SQL.*timeout|timeout'
                Sample  = (([string]$line -replace '[\r\n]+', ' ').Trim())
            }
            if ($null -eq $latestFailure -or $failure.Time -gt $latestFailure.Time -or
                ($failure.Time -eq $latestFailure.Time -and $failure.IsSqlTimeout -and -not $latestFailure.IsSqlTimeout)) {
                $latestFailure = $failure
            }
        }
    }

    $hasUnresolvedFailure = $null -ne $latestFailure -and ($null -eq $latestHealthy -or $latestFailure.Time -ge $latestHealthy)
    if (-not $hasUnresolvedFailure) {
        $tracking.ConsecutiveFailures = 0
        if ($null -ne $latestHealthy) { $tracking.LastHealthy = $latestHealthy.ToString('o') }
    }
    elseif ($tracking.LastProcessedFailureId -ne $latestFailure.Id) {
        $tracking.ConsecutiveFailures = [int]$tracking.ConsecutiveFailures + 1
        $tracking.LastProcessedFailureId = $latestFailure.Id
    }
    if ($null -ne $latestHealthy) { $tracking.LastHealthy = $latestHealthy.ToString('o') }
    Save-MonitorRuntimeState -State $state

    $failureCount = [int]$tracking.ConsecutiveFailures
    if ($hasUnresolvedFailure) {
        $timeoutLabel = if ($latestFailure.IsSqlTimeout) { 'SQL health check timeout' } else { 'LastEventTime health check failure' }
        if ($failureCount -lt $DataCollectorConsecutiveFailureThreshold) {
            $diagnosticAction = if ($failureCount -ge 2) { 'retry and collect diagnostics' } else { 'retry; do not notify yet' }
            Write-RunLog -Level Warning -Category Diagnostics -Color Yellow -Message (
                'Data Collector status=Degraded / {0}; consecutive failures={1}/{2}; action={3}; service=Running; sample={4}' -f
                    $timeoutLabel, $failureCount, $DataCollectorConsecutiveFailureThreshold, $diagnosticAction, $latestFailure.Sample
            )
            Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Data Collector SQL health' -Message (
                'Status=Degraded / {0}; consecutive failures={1}/{2}; action={3}; no notification sent.' -f
                    $timeoutLabel, $failureCount, $DataCollectorConsecutiveFailureThreshold, $diagnosticAction
            ) -Key 'diagnostics-datacollector-sql-health'
        }
        else {
            Add-MonitorResult -Severity Alert -Category Diagnostics -Check 'Data Collector SQL health' -Message (
                'Status=Alert / {0}; {1} consecutive LastEventTime failures while the service is Running; threshold={2}; sample={3}' -f
                    $timeoutLabel, $failureCount, $DataCollectorConsecutiveFailureThreshold, $latestFailure.Sample
            ) -Key 'diagnostics-datacollector-sql-health'
        }
    }

    if ($null -ne $latestHealthy) {
        $lastHealthyAgeMinutes = [Math]::Round(((Get-Date) - $latestHealthy.LocalDateTime).TotalMinutes, 1)
        if ($lastHealthyAgeMinutes -gt $DataCollectorLastHealthyCriticalMinutes) {
            Add-MonitorResult -Severity Alert -Category Diagnostics -Check 'Data Collector LastHealthy' -Message (
                'Status=Critical; service=Running; LastHealthy={0}; age={1} minutes; critical threshold={2} minutes.' -f
                    $latestHealthy.ToString('o'), $lastHealthyAgeMinutes, $DataCollectorLastHealthyCriticalMinutes
            ) -Key 'diagnostics-datacollector-lasthealthy'
        }
        elseif ($lastHealthyAgeMinutes -gt $DataCollectorLastHealthyWarningMinutes) {
            Add-MonitorResult -Severity Warning -Category Diagnostics -Check 'Data Collector LastHealthy' -Message (
                'Status=Warning; service=Running; LastHealthy={0}; age={1} minutes; warning threshold={2} minutes.' -f
                    $latestHealthy.ToString('o'), $lastHealthyAgeMinutes, $DataCollectorLastHealthyWarningMinutes
            ) -Key 'diagnostics-datacollector-lasthealthy'
        }
        elseif (-not $hasUnresolvedFailure) {
            Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Data Collector LastHealthy' -Message (
                'Status=Healthy; service=Running; LastHealthy={0}; age={1} minutes.' -f $latestHealthy.ToString('o'), $lastHealthyAgeMinutes
            ) -Key 'diagnostics-datacollector-lasthealthy'
        }
    }
}

function Test-IsWatchdogSuccessfulRestartEvidence {
    param([string[]]$Samples)

    $evidence = (@($Samples) -join ' ')
    if ([string]::IsNullOrWhiteSpace($evidence)) { return $false }

    # A failed restart is still actionable even when another entry mentions a restart.
    if ($evidence -match '(?i)restart\s+failed|restart\s+unsuccessful|failed\s+to\s+restart') {
        return $false
    }

    return $evidence -match '(?i)restart\s+succeeded|restarted\s+service'
}

function Test-WatchdogServiceLogs {
    $watchdogRoot = Resolve-WatchdogLogRoot
    if ([string]::IsNullOrWhiteSpace($watchdogRoot)) {
        Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Watchdog service logs' -Message (
            'Watchdog TaskSchedulerOutput folder was not found; optional root-cause log analysis was skipped.'
        ) -Key 'diagnostics-watchdog-logs'
        return
    }

    Test-DataCollectorWatchdogHealth -WatchdogRoot $watchdogRoot

    $since = (Get-Date).AddMinutes(-$LogLookbackMinutes)
    $todayFileName = '{0}.txt' -f (Get-Date -Format 'yyyyMMdd')
    $logFiles = [System.Collections.Generic.List[object]]::new()
    foreach ($serviceFolder in @(Get-ChildItem -LiteralPath $watchdogRoot -Directory -ErrorAction SilentlyContinue)) {
        $logFile = Join-Path $serviceFolder.FullName $todayFileName
        if (Test-Path -LiteralPath $logFile -PathType Leaf) {
            $file = Get-Item -LiteralPath $logFile -ErrorAction Stop
            if ($file.LastWriteTime -ge $since) { $logFiles.Add($file) | Out-Null }
        }
    }

    if ($logFiles.Count -eq 0) {
        Add-MonitorResult -Severity OK -Category Diagnostics -Check 'Watchdog service logs' -Message (
            'No Watchdog service log was updated during the current monitoring window; root={0}' -f $watchdogRoot
        ) -Key 'diagnostics-watchdog-logs'
        return
    }

    $incidentPattern = '(?i)\b(error|fail(?:ed|ure)?|unhealthy|not\s+running|stale|timeout|timed\s+out|exception|crash|restart(?:ed|ing|\s+succeeded|\s+failed|\s+deferred)?)\b'
    foreach ($file in $logFiles) {
        if (Test-IsDataCollectorWatchdogFile -File $file) { continue }
        $lines = @((Get-Content -LiteralPath $file.FullName -Tail $WatchdogLogTailLines -ErrorAction Stop))
        $entryTime = $file.LastWriteTime
        $samples = [System.Collections.Generic.List[string]]::new()
        $lastEvidenceIndex = -3
        for ($index = 0; $index -lt $lines.Count; $index++) {
            $line = [string]$lines[$index]
            $entryTime = Get-WatchdogLogEntryTime -Line $line -FallbackTime $entryTime
            if ($entryTime -lt $since -or $line -notmatch $incidentPattern) { continue }
            if ($index - $lastEvidenceIndex -lt 3) { continue }

            $entryLines = [System.Collections.Generic.List[string]]::new()
            for ($contextIndex = $index; $contextIndex -lt [Math]::Min($index + 3, $lines.Count); $contextIndex++) {
                $contextLine = (([string]$lines[$contextIndex] -replace '[\r\n]+', ' ').Trim())
                if (-not [string]::IsNullOrWhiteSpace($contextLine)) { $entryLines.Add($contextLine) | Out-Null }
            }
            $sample = $entryLines -join ' | '
            if ($sample.Length -gt 900) { $sample = $sample.Substring(0, 900) + '...' }
            if (-not $samples.Contains($sample)) { $samples.Add($sample) | Out-Null }
            $lastEvidenceIndex = $index
            if ($samples.Count -ge 3) { break }
        }

        if ($samples.Count -eq 0) { continue }
        $hasSuccessfulRestart = Test-IsWatchdogSuccessfulRestartEvidence -Samples $samples.ToArray()
        $severity = if ($hasSuccessfulRestart) {
            'Warning'
        }
        elseif (($samples -join ' ') -match '(?i)restart\s+failed|\berror\b|\bfailed\b|unhealthy|not\s+running|stale|timeout|exception|crash') {
            'Alert'
        }
        else {
            'Warning'
        }
        $serviceName = Split-Path -Leaf (Split-Path -Parent $file.FullName)
        $evidenceLabel = if ($hasSuccessfulRestart) { 'successful restart evidence' } else { 'evidence' }
        Add-MonitorResult -Severity $severity -Category Diagnostics -Check 'Watchdog service logs' -Message (
            'Recent Watchdog {0}; service={1}; file={2}; sample={3}' -f $evidenceLabel, $serviceName, $file.FullName, ($samples -join ' || ')
        ) -Key ('diagnostics-watchdog-{0}' -f $serviceName) -NotificationEligible:(-not $hasSuccessfulRestart)
    }
}

function Resolve-DbConfigPath {
    $candidates = [System.Collections.Generic.List[string]]::new()
    function Add-Candidate {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try {
            $expanded = [Environment]::ExpandEnvironmentVariables($Path)
            if (-not $candidates.Contains($expanded)) {
                $candidates.Add($expanded) | Out-Null
            }
        }
        catch {
            Write-ErrorLog -Category Email -Message ('Unable to expand email configuration path {0}: {1}' -f $Path, $_.Exception.Message)
        }
    }

    Add-Candidate -Path $DbConfigPath
    foreach ($root in @($D4AInstallRoot, $env:D4A_HOME)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$root)) {
            $expandedRoot = [Environment]::ExpandEnvironmentVariables([string]$root)
            Add-Candidate -Path (Join-Path $expandedRoot 'Services\API\dbconfig.js')
            Add-Candidate -Path (Join-Path $expandedRoot 'API\dbconfig.js')
        }
    }
    foreach ($path in @(
        'C:\Decide4Action\Services\API\dbconfig.js',
        'D:\Decide4Action\Services\API\dbconfig.js',
        'C:\Decide4Action-v2\Services\API\dbconfig.js',
        'D:\Decide4Action-v2\Services\API\dbconfig.js',
        'C:\Apps\Decide4Action\Services\API\dbconfig.js',
        'D:\Apps\Decide4Action\Services\API\dbconfig.js',
        'C:\Apps\Decide4Action-v2\Services\API\dbconfig.js',
        'D:\Apps\Decide4Action-v2\Services\API\dbconfig.js',
        'C:\Program Files\Decide4Action\Services\API\dbconfig.js',
        'C:\Program Files\Decide4Action-v2\Services\API\dbconfig.js'
    )) {
        Add-Candidate -Path $path
    }

    foreach ($candidate in $candidates) {
        try {
            if (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction Stop) {
                return (Get-Item -LiteralPath $candidate -ErrorAction Stop).FullName
            }
        }
        catch {
            Write-ErrorLog -Category Email -Message ('Unable to inspect email configuration path {0}: {1}' -f $candidate, $_.Exception.Message)
        }
    }
    return $null
}

function Resolve-NodeExecutable {
    param([string]$ResolvedDbConfigPath)

    if (-not [string]::IsNullOrWhiteSpace($NodeExecutable)) {
        $expanded = [Environment]::ExpandEnvironmentVariables($NodeExecutable)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            return (Get-Item -LiteralPath $expanded -ErrorAction Stop).FullName
        }
        throw ('Specified Node executable not found: {0}' -f $expanded)
    }

    foreach ($commandName in @('node.exe', 'node')) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            return [string]$command.Source
        }
    }

    $candidatePaths = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($ResolvedDbConfigPath)) {
        $apiDirectory = Split-Path -Parent $ResolvedDbConfigPath
        $candidatePaths.Add((Join-Path $apiDirectory 'node.exe')) | Out-Null
        $candidatePaths.Add((Join-Path (Split-Path -Parent $apiDirectory) 'node.exe')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidatePaths.Add((Join-Path $env:ProgramFiles 'nodejs\node.exe')) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidatePaths.Add((Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe')) | Out-Null
    }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Get-Item -LiteralPath $candidate -ErrorAction Stop).FullName
        }
    }
    throw 'Node.js was not found. Supply -NodeExecutable or add node.exe to PATH.'
}

function Invoke-NodeProcess {
    param(
        [Parameter(Mandatory = $true)][string]$NodePath,
        [Parameter(Mandatory = $true)][string]$HelperPath,
        [Parameter(Mandatory = $true)][string]$PayloadPath
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $NodePath
    $startInfo.Arguments = '"{0}" "{1}"' -f $HelperPath.Replace('"', '\"'), $PayloadPath.Replace('"', '\"')
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'The Node email helper process could not be started.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $processTimeoutMs = ($EmailTimeoutSeconds + 10) * 1000
        if (-not $process.WaitForExit($processTimeoutMs)) {
            try { $process.Kill() } catch { }
            throw ('The email helper exceeded the {0}-second process timeout.' -f ($EmailTimeoutSeconds + 10))
        }
        $process.WaitForExit()
        $stdout = $stdoutTask.Result.Trim()
        $stderr = $stderrTask.Result.Trim()
        if ($process.ExitCode -ne 0) {
            $detail = (@($stderr, $stdout) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | '
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = 'The Node helper returned no diagnostic output.'
            }
            throw ('Node email helper failed with exit code {0}: {1}' -f $process.ExitCode, $detail)
        }
        return $stdout
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-DbConfiguredEmail {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedDbConfigPath,
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$TextBody,
        [Parameter(Mandatory = $true)][string]$HtmlBody
    )

    $nodePath = Resolve-NodeExecutable -ResolvedDbConfigPath $ResolvedDbConfigPath
    $tempId = '{0}_{1}' -f $PID, [Guid]::NewGuid().ToString('N')
    $helperPath = Join-Path (Split-Path -Parent $script:RunLogPath) ('d4a_monitor_email_{0}.js' -f $tempId)
    $payloadPath = Join-Path (Split-Path -Parent $script:RunLogPath) ('d4a_monitor_email_{0}.json' -f $tempId)
    $payload = [ordered]@{
        dbConfigPath         = $ResolvedDbConfigPath
        nodemailerModulePath = $NodemailerModulePath
        scriptDirectory      = $script:ScriptDirectory
        timeoutMs            = $EmailTimeoutSeconds * 1000
        to                   = $NotificationTo
        from                 = $FromAddress
        subject              = $Subject
        text                 = $TextBody
        html                 = $HtmlBody
    }

    $helper = @'
"use strict";
const fs = require("fs");
const path = require("path");

function loadNodemailer(explicitPath, configDirectory, scriptDirectory) {
    const candidates = [];
    if (explicitPath) candidates.push(explicitPath);
    candidates.push(path.join(configDirectory, "node_modules", "nodemailer"));
    candidates.push(path.join(path.dirname(configDirectory), "node_modules", "nodemailer"));
    if (scriptDirectory) {
        candidates.push(path.join(scriptDirectory, "node_modules", "nodemailer"));
        candidates.push(path.join(scriptDirectory, "scripts", "node_modules", "nodemailer"));
    }
    if (process.env.USERPROFILE) {
        candidates.push(path.join(process.env.USERPROFILE, "Downloads", "scripts", "node_modules", "nodemailer"));
    }

    const failures = [];
    for (const candidate of candidates) {
        try {
            if (path.isAbsolute(candidate) && fs.existsSync(candidate)) return require(candidate);
            return require(require.resolve(candidate, { paths: [configDirectory, path.dirname(configDirectory), process.cwd()] }));
        } catch (error) {
            failures.push(candidate + ": " + error.message);
        }
    }
    try {
        return require(require.resolve("nodemailer", { paths: [configDirectory, path.dirname(configDirectory), process.cwd()] }));
    } catch (error) {
        failures.push("nodemailer: " + error.message);
    }
    throw new Error("nodemailer could not be loaded. " + failures.join(" | "));
}

function asBoolean(value) {
    if (typeof value === "boolean") return value;
    return String(value || "").toLowerCase() === "true";
}

async function main() {
    const payload = JSON.parse(fs.readFileSync(process.argv[2], "utf8").replace(/^\uFEFF/, ""));
    const configPath = path.resolve(payload.dbConfigPath);
    const configDirectory = path.dirname(configPath);
    process.chdir(configDirectory);
    const loadedConfig = require(configPath);
    const config = loadedConfig && loadedConfig.default ? loadedConfig.default : loadedConfig;
    const timeoutMs = Number(payload.timeoutMs || 30000);

    let transporter = config.EmailTransporter;
    if (!transporter || typeof transporter.sendMail !== "function") {
        const nodemailer = loadNodemailer(payload.nodemailerModulePath, configDirectory, payload.scriptDirectory);
        transporter = nodemailer.createTransport({
            host: config.EmailHost,
            port: Number(config.EmailPort || 587),
            secure: asBoolean(config.EmailSecure),
            auth: config.EmailUser || config.EmailPass ? { user: config.EmailUser, pass: config.EmailPass } : undefined,
            connectionTimeout: timeoutMs,
            greetingTimeout: timeoutMs,
            socketTimeout: timeoutMs,
            tls: config.EmailTlsCiphers ? { ciphers: config.EmailTlsCiphers } : undefined
        });
    }

    const configuredFrom = payload.from || config.EmailFrom || config.EmailUser;
    if (!configuredFrom) throw new Error("No sender was found in -FromAddress, EmailFrom, or EmailUser.");
    const addressMatch = String(configuredFrom).match(/<\s*([^<>]+)\s*>/);
    const senderAddress = (addressMatch ? addressMatch[1] : String(configuredFrom)).trim();
    if (!senderAddress) throw new Error("The configured sender address is empty.");
    if (!payload.to) throw new Error("NotificationTo is empty.");

    const info = await transporter.sendMail({
        from: { name: "D4A Monitoring", address: senderAddress },
        to: payload.to,
        subject: payload.subject,
        text: payload.text,
        html: payload.html
    });
    console.log("Email sent successfully.");
    console.log("MessageId: " + (info && info.messageId ? info.messageId : ""));
}

main().catch(error => {
    console.error(error && error.stack ? error.stack : String(error));
    process.exit(1);
});
'@

    try {
        [IO.File]::WriteAllText($helperPath, $helper, $script:Utf8NoBom)
        [IO.File]::WriteAllText($payloadPath, ($payload | ConvertTo-Json -Depth 6), $script:Utf8NoBom)
        $output = Invoke-NodeProcess -NodePath $nodePath -HelperPath $helperPath -PayloadPath $payloadPath
        return [pscustomobject]@{
            Method  = 'D4A dbconfig.js / Node.js / nodemailer'
            Details = $output
        }
    }
    finally {
        Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-MonitorSenderEmailAddress {
    param([Parameter(Mandatory = $true)][string]$Sender)

    try {
        return ([Net.Mail.MailAddress]::new($Sender)).Address
    }
    catch {
        throw "The configured sender address is invalid: $Sender"
    }
}

function Invoke-SmtpEmail {
    param(
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$TextBody,
        [Parameter(Mandatory = $true)][string]$HtmlBody
    )

    if ([string]::IsNullOrWhiteSpace($SmtpServer)) {
        throw 'SmtpServer is empty.'
    }
    $from = if ([string]::IsNullOrWhiteSpace($FromAddress)) {
        'd4a-monitor@decide4action.com'
    }
    else {
        $FromAddress
    }

    $credential = $null
    if (-not [string]::IsNullOrWhiteSpace($SmtpCredentialFile)) {
        if (-not (Test-Path -LiteralPath $SmtpCredentialFile -PathType Leaf)) {
            throw ('SMTP credential file not found: {0}' -f $SmtpCredentialFile)
        }
        $credential = Import-Clixml -LiteralPath $SmtpCredentialFile -ErrorAction Stop
        if ($credential -isnot [Management.Automation.PSCredential]) {
            throw 'SmtpCredentialFile must contain a PSCredential object.'
        }
    }

    $message = [Net.Mail.MailMessage]::new()
    $client = [Net.Mail.SmtpClient]::new($SmtpServer, $SmtpPort)
    try {
        $senderAddress = Get-MonitorSenderEmailAddress -Sender $from
        $message.From = [Net.Mail.MailAddress]::new($senderAddress, 'D4A Monitoring', [Text.Encoding]::UTF8)
        $message.To.Add($NotificationTo)
        $message.Subject = $Subject
        $message.SubjectEncoding = [Text.Encoding]::UTF8
        $message.BodyEncoding = [Text.Encoding]::UTF8
        $message.AlternateViews.Add([Net.Mail.AlternateView]::CreateAlternateViewFromString(
            $TextBody, [Text.Encoding]::UTF8, 'text/plain'
        )) | Out-Null
        $message.AlternateViews.Add([Net.Mail.AlternateView]::CreateAlternateViewFromString(
            $HtmlBody, [Text.Encoding]::UTF8, 'text/html'
        )) | Out-Null

        $client.EnableSsl = [bool]$SmtpUseSsl
        $client.Timeout = $EmailTimeoutSeconds * 1000
        if ($null -ne $credential) {
            $client.Credentials = $credential.GetNetworkCredential()
        }
        $client.Send($message)
        return [pscustomobject]@{ Method = 'PowerShell SMTP'; Details = $null }
    }
    finally {
        $message.Dispose()
        $client.Dispose()
    }
}

function Get-MonitorSubjectComponentLabel {
    param([Parameter(Mandatory = $true)][object]$Result)

    $check = [string]$Result.Check
    $searchText = '{0} {1} {2}' -f $Result.Category, $check, $Result.Key
    if ($check -match '(?i)certificate' -and $searchText -match '(?i)\bAPI\b') { return 'API Certificate' }
    if ($check -match '(?i)certificate' -and $searchText -match '(?i)frontend') { return 'Frontend Certificate' }
    if ($searchText -match '(?i)\bAPI\b') { return 'API' }
    if ($searchText -match '(?i)disk') { return 'Disk Space' }
    if ($searchText -match '(?i)data collector') { return 'Data Collector' }
    if ($searchText -match '(?i)nginx') { return 'Nginx' }
    if ($searchText -match '(?i)mosquitto|mqtt') { return 'Mosquitto/MQTT' }
    if ($searchText -match '(?i)\bCPU\b') { return 'CPU' }
    if ($searchText -match '(?i)memory|\bRAM\b') { return 'Memory' }
    if ($check -match '(?i)windows service' -and [string]$Result.Message -match '^(?<ServiceName>.+?)\s+\[') {
        return $matches.ServiceName.Trim()
    }
    if ($searchText -match '(?i)frontend') { return 'Frontend' }
    if (-not [string]::IsNullOrWhiteSpace($check)) { return ($check -replace '\s*\([^)]*\)\s*$', '').Trim() }
    return 'Monitoring'
}

function Get-MonitorAlertSubjectLabel {
    param([object[]]$IssueResults)

    $distinctIssues = @($IssueResults | Group-Object -Property Key | ForEach-Object { $_.Group | Select-Object -First 1 })
    if ($distinctIssues.Count -gt 1) { return 'Multiple Alerts detected' }
    if ($distinctIssues.Count -eq 0) { return 'Monitoring Alert' }

    $issue = $distinctIssues[0]
    $component = Get-MonitorSubjectComponentLabel -Result $issue
    $level = if ($component -eq 'Disk Space' -and $issue.Severity -in @('Alert', 'Error')) {
        'Critical'
    }
    elseif ($issue.Severity -eq 'Warning') {
        'Warning'
    }
    else {
        'Alert'
    }
    return '{0} {1}' -f $component, $level
}

function Get-MonitorRecoverySubjectLabel {
    param([object[]]$RecoveryResults)

    $distinctRecoveries = @($RecoveryResults | Group-Object -Property Key | ForEach-Object { $_.Group | Select-Object -First 1 })
    if ($distinctRecoveries.Count -gt 1) { return 'Multiple Recoveries detected' }
    if ($distinctRecoveries.Count -eq 0) { return 'Monitoring Recovery' }
    return '{0} Recovery' -f (Get-MonitorSubjectComponentLabel -Result $distinctRecoveries[0])
}

function New-EmailContent {
    param(
        [Parameter(Mandatory = $true)][string]$MonitoredSite,
        [Parameter(Mandatory = $true)][string]$MonitoringName,
        [object[]]$ActiveIgnoreRules,
        [object[]]$RecoveryResults,
        [ValidateSet('Alert', 'Recovery', 'Test', 'Daily')]
        [string]$EmailType = 'Alert'
    )

    $allResults = @($script:Results.ToArray())
    $recoveryResults = @($RecoveryResults)
    $dailyOnlyResults = @($allResults | Where-Object {
        $_.Severity -ne 'OK' -and -not $_.NotificationEligible
    })
    $emailResults = switch ($EmailType) {
        'Alert' {
            @($allResults | Where-Object { $_.Severity -eq 'OK' -or $_.NotificationEligible })
        }
        'Recovery' { $recoveryResults }
        default { $allResults }
    }
    $issues = @($emailResults | Where-Object { $_.Severity -ne 'OK' })
    $unignoredIssues = @($issues | Where-Object { -not $_.IgnoreActive })
    $ignoredIssues = @($issues | Where-Object { $_.IgnoreActive })
    $unignoredNotifiableIssues = @($unignoredIssues | Where-Object { $_.NotificationEligible })
    $ruleEntries = @(Get-IgnoreRuleEntries -Results $emailResults)
    $heading = switch ($EmailType) {
        'Test' { 'MONITORING TEST RESULTS' }
        'Daily' { 'DAILY MONITORING RESULTS' }
        'Recovery' { 'MONITORING RECOVERY' }
        default { 'MONITORING ALERT' }
    }
    $subject = switch ($EmailType) {
        'Test' { 'Monitoring test results for {0}' -f $MonitoringName }
        'Daily' { 'Daily monitoring results for {0}' -f $MonitoringName }
        'Recovery' { '{0} - {1}' -f (Get-MonitorRecoverySubjectLabel -RecoveryResults $recoveryResults), $MonitoringName }
        default { '{0} - {1}' -f (Get-MonitorAlertSubjectLabel -IssueResults $unignoredNotifiableIssues), $MonitoringName }
    }

    $text = [Text.StringBuilder]::new()
    [void]$text.AppendLine($heading)
    [void]$text.AppendLine(('Monitoring name: {0}' -f $MonitoringName))
    [void]$text.AppendLine(('Sites: {0}' -f $MonitoredSite))
    [void]$text.AppendLine(('Server: {0}' -f $env:COMPUTERNAME))
    [void]$text.AppendLine(('Scan started: {0}' -f $script:RunStartedAt.ToString('yyyy-MM-dd HH:mm:ss zzz')))
    [void]$text.AppendLine(('Scan completed: {0}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')))
    [void]$text.AppendLine(('Issues detected: {0}' -f $issues.Count))
    [void]$text.AppendLine(('Issues not ignored: {0}' -f $unignoredIssues.Count))
    [void]$text.AppendLine(('Issues covered by active rules: {0}' -f $ignoredIssues.Count))
    [void]$text.AppendLine(('Recovered previously notified issues: {0}' -f $recoveryResults.Count))
    [void]$text.AppendLine(('Active ignore rules: {0}' -f @($ActiveIgnoreRules).Count))
    if ($EmailType -eq 'Alert' -and $dailyOnlyResults.Count -gt 0) {
        [void]$text.AppendLine(('Daily-only warning evidence held for the daily monitoring email: {0}' -f $dailyOnlyResults.Count))
    }
    [void]$text.AppendLine('')
    [void]$text.AppendLine('ISSUES DETECTED')
    if ($issues.Count -eq 0) {
        [void]$text.AppendLine('No warnings, alerts, or errors were detected.')
    }
    else {
        foreach ($result in $issues) {
            $ignoreStatus = if ($result.IgnoreActive) {
                'IGNORED ({0}{1})' -f $result.IgnoreMode, $(if ($null -ne $result.IgnoreUntil) { '; until ' + $result.IgnoreUntil.ToString('yyyy-MM-dd HH:mm:ss zzz') } else { '' })
            }
            else {
                'NOT IGNORED'
            }
            [void]$text.AppendLine(('[{0}] [{1}] {2}: {3}' -f $result.Severity, $result.Category, $result.Check, $result.Message))
            [void]$text.AppendLine(('Rule key: {0}; Ignore status: {1}' -f $result.Key, $ignoreStatus))
        }
    }
    [void]$text.AppendLine('')
    [void]$text.AppendLine('RECOVERED ISSUES')
    if ($recoveryResults.Count -eq 0) {
        [void]$text.AppendLine('No previously notified issue recovered during this scan.')
    }
    else {
        foreach ($recovery in $recoveryResults) {
            [void]$text.AppendLine(('[RECOVERY] [{0}] {1}: {2} [key={3}]' -f $recovery.Category, $recovery.Check, $recovery.Message, $recovery.Key))
        }
    }
    [void]$text.AppendLine('')
    [void]$text.AppendLine('ACTIVE IGNORE RULES')
    if (@($ActiveIgnoreRules).Count -eq 0) {
        [void]$text.AppendLine('No active ignore rules are defined.')
    }
    else {
        foreach ($rule in @($ActiveIgnoreRules | Sort-Object -Property Key)) {
            $until = if ($null -ne $rule.IgnoreUntil) { $rule.IgnoreUntil.ToString('yyyy-MM-dd HH:mm:ss zzz') } else { 'permanent' }
            [void]$text.AppendLine(('{0}|{1}|{2}|{3}' -f $rule.Key, $rule.Mode, $rule.Duration, $until))
        }
    }
    [void]$text.AppendLine('')
    [void]$text.AppendLine('IGNORE RULE ENTRIES FOR NOT-IGNORED ISSUES')
    if ($ruleEntries.Count -eq 0) {
        [void]$text.AppendLine('No new ignore-rule entries are needed.')
    }
    else {
        [void]$text.AppendLine(('Add one of the following lines to: {0}' -f $script:IgnoreRulesPath))
        foreach ($entry in $ruleEntries) {
            [void]$text.AppendLine(('Temporary (edit duration if needed): {0}' -f $entry.Temporary))
            [void]$text.AppendLine(('Permanent: {0}' -f $entry.Permanent))
        }
    }
    [void]$text.AppendLine('')
    [void]$text.AppendLine('AUTOMATIC NOTIFICATION COOLDOWN')
    [void]$text.AppendLine('After an alert email, the monitor automatically silences the same issue for 24 hours.')
    [void]$text.AppendLine('To change the duration, run the command below. It updates both the duration and expiry time from now:')
    [void]$text.AppendLine(('  .\D4A-ScheduledMonitor-v5.ps1 -SetIssueCooldown ''<rule-key>'' -IssueCooldownDuration ''12h'''))
    [void]$text.AppendLine('To remove the automatic cooldown, run:')
    [void]$text.AppendLine(('  .\D4A-ScheduledMonitor-v5.ps1 -ClearIssueCooldown ''<rule-key>'''))
    [void]$text.AppendLine('')
    [void]$text.AppendLine('COMPLETE SCAN RESULTS')
    foreach ($result in $emailResults) {
        $ignoreStatus = if ($result.IgnoreActive) { 'ignored' } else { 'not ignored' }
        [void]$text.AppendLine(('[{0}] [{1}] {2}: {3} [key={4}; {5}]' -f $result.Severity, $result.Category, $result.Check, $result.Message, $result.Key, $ignoreStatus))
    }
    [void]$text.AppendLine('')
    [void]$text.AppendLine(('Monitoring logs: {0}' -f $script:MonitorLogDirectory))
    [void]$text.AppendLine(('Monitor summary log: {0}' -f $script:RunLogPath))

    $html = [Text.StringBuilder]::new()
    [void]$html.AppendLine('<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#202124;font-size:14px">')
    [void]$html.AppendLine(('<h2>{0}</h2>' -f [Net.WebUtility]::HtmlEncode($heading)))
    [void]$html.AppendLine(('<p><b>Monitoring name:</b> {0}<br><b>Sites:</b> {1}<br><b>Server:</b> {2}<br><b>Time:</b> {3}<br><b>Issues detected:</b> {4}<br><b>Not ignored:</b> {5}<br><b>Covered by active ignore rules:</b> {6}<br><b>Recovered previously notified issues:</b> {7}</p>' -f
        [Net.WebUtility]::HtmlEncode($MonitoringName),
        [Net.WebUtility]::HtmlEncode($MonitoredSite),
        [Net.WebUtility]::HtmlEncode($env:COMPUTERNAME),
        [Net.WebUtility]::HtmlEncode((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')),
        $issues.Count,
        $unignoredIssues.Count,
        $ignoredIssues.Count,
        $recoveryResults.Count))
    if ($EmailType -eq 'Alert' -and $dailyOnlyResults.Count -gt 0) {
        [void]$html.AppendLine(('<p><i>{0} daily-only warning item(s) were retained for the daily monitoring email and are omitted here.</i></p>' -f $dailyOnlyResults.Count))
    }

    if ($issues.Count -eq 0) {
        [void]$html.AppendLine('<p style="padding:10px;background:#e8f5e9;border:1px solid #81c784"><b>Healthy:</b> No warnings, alerts, or errors were detected.</p>')
    }
    else {
        [void]$html.AppendLine('<h3>Issues detected</h3><table style="border-collapse:collapse;width:100%" border="1" cellpadding="6">')
        [void]$html.AppendLine('<tr><th>Severity</th><th>Category</th><th>Check</th><th>Details</th><th>Rule key</th><th>Ignore status</th></tr>')
        foreach ($result in $issues) {
            $background = if ($result.IgnoreActive) { '#e3f2fd' } elseif ($result.Severity -in @('Alert', 'Error')) { '#f8d7da' } else { '#fff3cd' }
            $ignoreStatus = if ($result.IgnoreActive) {
                'Ignored: {0}{1}' -f $result.IgnoreMode, $(if ($null -ne $result.IgnoreUntil) { '; until ' + $result.IgnoreUntil.ToString('yyyy-MM-dd HH:mm:ss zzz') } else { '' })
            }
            else {
                'Not ignored'
            }
            [void]$html.AppendLine(('<tr style="background:{0}"><td><b>{1}</b></td><td>{2}</td><td>{3}</td><td>{4}</td><td><code>{5}</code></td><td>{6}</td></tr>' -f
                $background,
                [Net.WebUtility]::HtmlEncode([string]$result.Severity),
                [Net.WebUtility]::HtmlEncode([string]$result.Category),
                [Net.WebUtility]::HtmlEncode([string]$result.Check),
                [Net.WebUtility]::HtmlEncode([string]$result.Message),
                [Net.WebUtility]::HtmlEncode([string]$result.Key),
                [Net.WebUtility]::HtmlEncode($ignoreStatus)))
        }
        [void]$html.AppendLine('</table>')
    }

    [void]$html.AppendLine('<h3>Recovered issues</h3>')
    if ($recoveryResults.Count -eq 0) {
        [void]$html.AppendLine('<p>No previously notified issue recovered during this scan.</p>')
    }
    else {
        [void]$html.AppendLine('<table style="border-collapse:collapse;width:100%;background:#e8f5e9" border="1" cellpadding="6"><tr><th>Component</th><th>Check</th><th>Details</th><th>Rule key</th></tr>')
        foreach ($recovery in $recoveryResults) {
            [void]$html.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td><code>{3}</code></td></tr>' -f
                [Net.WebUtility]::HtmlEncode([string]$recovery.Category),
                [Net.WebUtility]::HtmlEncode([string]$recovery.Check),
                [Net.WebUtility]::HtmlEncode([string]$recovery.Message),
                [Net.WebUtility]::HtmlEncode([string]$recovery.Key)))
        }
        [void]$html.AppendLine('</table>')
    }

    [void]$html.AppendLine('<h3>Active ignore rules</h3>')
    if (@($ActiveIgnoreRules).Count -eq 0) {
        [void]$html.AppendLine('<p>No active ignore rules are defined.</p>')
    }
    else {
        [void]$html.AppendLine('<table style="border-collapse:collapse;width:100%" border="1" cellpadding="6"><tr><th>Rule key</th><th>Mode</th><th>Duration</th><th>Ignore until</th></tr>')
        foreach ($rule in @($ActiveIgnoreRules | Sort-Object -Property Key)) {
            $until = if ($null -ne $rule.IgnoreUntil) { $rule.IgnoreUntil.ToString('yyyy-MM-dd HH:mm:ss zzz') } else { 'Permanent' }
            [void]$html.AppendLine(('<tr><td><code>{0}</code></td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f
                [Net.WebUtility]::HtmlEncode([string]$rule.Key),
                [Net.WebUtility]::HtmlEncode([string]$rule.Mode),
                [Net.WebUtility]::HtmlEncode([string]$rule.Duration),
                [Net.WebUtility]::HtmlEncode($until)))
        }
        [void]$html.AppendLine('</table>')
    }

    [void]$html.AppendLine('<h3>Ignore a currently not-ignored issue</h3>')
    if ($ruleEntries.Count -eq 0) {
        [void]$html.AppendLine('<p>No new ignore-rule entries are needed.</p>')
    }
    else {
        [void]$html.AppendLine(('<p>Add one line to <code>{0}</code>. A temporary rule receives its end date automatically during the next scan.</p>' -f [Net.WebUtility]::HtmlEncode($script:IgnoreRulesPath)))
        foreach ($entry in $ruleEntries) {
            [void]$html.AppendLine(('<p><b>{0}</b><br>Temporary: <code>{1}</code><br>Permanent: <code>{2}</code></p>' -f
                [Net.WebUtility]::HtmlEncode([string]$entry.Key),
                [Net.WebUtility]::HtmlEncode([string]$entry.Temporary),
                [Net.WebUtility]::HtmlEncode([string]$entry.Permanent)))
        }
    }

    [void]$html.AppendLine('<h3>Automatic notification cooldown</h3>')
    [void]$html.AppendLine('<p>After an alert email, the same issue is automatically silenced for 24 hours. A resolved issue has its automatic rule removed. The override command recalculates both duration and expiry time from now.</p>')
    [void]$html.AppendLine('<p>Override: <code>.\D4A-ScheduledMonitor-v5.ps1 -SetIssueCooldown ''&lt;rule-key&gt;'' -IssueCooldownDuration ''12h''</code><br>Remove: <code>.\D4A-ScheduledMonitor-v5.ps1 -ClearIssueCooldown ''&lt;rule-key&gt;''</code></p>')

    [void]$html.AppendLine('<h3>Complete scan results</h3><table style="border-collapse:collapse;width:100%" border="1" cellpadding="6">')
    [void]$html.AppendLine('<tr><th>Severity</th><th>Category</th><th>Check</th><th>Details</th><th>Rule key</th><th>Ignore status</th></tr>')
    foreach ($result in $emailResults) {
        $ignoreStatus = if ($result.IgnoreActive) { 'Ignored' } else { 'Not ignored' }
        [void]$html.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td><code>{4}</code></td><td>{5}</td></tr>' -f
            [Net.WebUtility]::HtmlEncode([string]$result.Severity),
            [Net.WebUtility]::HtmlEncode([string]$result.Category),
            [Net.WebUtility]::HtmlEncode([string]$result.Check),
            [Net.WebUtility]::HtmlEncode([string]$result.Message),
            [Net.WebUtility]::HtmlEncode([string]$result.Key),
            $ignoreStatus))
    }
    [void]$html.AppendLine('</table>')
    [void]$html.AppendLine(('<p><b>Monitoring logs:</b> <code>{0}</code><br><b>Monitor summary log:</b> <code>{1}</code><br><b>Ignore rules:</b> <code>{2}</code></p>' -f
        [Net.WebUtility]::HtmlEncode($script:MonitorLogDirectory),
        [Net.WebUtility]::HtmlEncode($script:RunLogPath),
        [Net.WebUtility]::HtmlEncode($script:IgnoreRulesPath)))
    [void]$html.AppendLine('</body></html>')

    return [pscustomobject]@{
        Subject  = $subject
        TextBody = $text.ToString()
        HtmlBody = $html.ToString()
    }
}

function Send-MonitorEmail {
    param(
        [Parameter(Mandatory = $true)][string]$Subject,
        [Parameter(Mandatory = $true)][string]$TextBody,
        [Parameter(Mandatory = $true)][string]$HtmlBody
    )

    if ([string]::IsNullOrWhiteSpace($NotificationTo)) {
        throw 'NotificationTo is empty.'
    }

    $failures = [System.Collections.Generic.List[string]]::new()
    $resolvedConfig = Resolve-DbConfigPath
    if (-not [string]::IsNullOrWhiteSpace($resolvedConfig)) {
        try {
            return Invoke-DbConfiguredEmail `
                -ResolvedDbConfigPath $resolvedConfig `
                -Subject $Subject `
                -TextBody $TextBody `
                -HtmlBody $HtmlBody
        }
        catch {
            $failures.Add(('dbconfig.js delivery failed: {0}' -f $_.Exception.Message)) | Out-Null
        }
    }
    else {
        $failures.Add('No D4A API dbconfig.js file was found.') | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($SmtpServer)) {
        try {
            return Invoke-SmtpEmail -Subject $Subject -TextBody $TextBody -HtmlBody $HtmlBody
        }
        catch {
            $failures.Add(('SMTP fallback failed: {0}' -f $_.Exception.Message)) | Out-Null
        }
    }
    else {
        $failures.Add('SMTP fallback is not configured; set -SmtpServer to enable it.') | Out-Null
    }

    throw ($failures -join ' ')
}

function Get-ExitCode {
    $severities = @($script:Results | Select-Object -ExpandProperty Severity)
    if ($severities -contains 'Error' -or $severities -contains 'Alert') { return 2 }
    if ($severities -contains 'Warning') { return 1 }
    return 0
}

function Invoke-D4AMonitor {
    if (-not $script:LoggingReady) { Initialize-MonitorLogging }
    Write-RunLog -Category Monitor -Color Cyan -Message (
        'D4A monitoring run started. Version={0}; release date={1}; script={2}' -f
            $script:MonitorVersion, $script:MonitorReleaseDate, $script:ScriptPath
    )
    Write-RunLog -Category Configuration -Message (
        'Configuration={0}; external configuration loaded={1}' -f $script:ResolvedConfigPath, $script:ConfigurationLoaded
    ) -Color DarkGray
    Write-RunLog -Category Monitor -Message ('Monitoring logs={0}' -f $script:MonitorLogDirectory) -Color DarkGray
    Write-RunLog -Category Monitor -Message ('Monitor summary log={0}' -f $script:RunLogPath) -Color DarkGray

    if ($DisableEmail.IsPresent -and ($SendTestResultsEmail.IsPresent -or $SendDailySummaryEmail.IsPresent)) {
        Add-MonitorResult -Severity Error -Category Configuration -Check Email -Message (
            '-DisableEmail cannot be used with -SendTestResultsEmail or -SendDailySummaryEmail.'
        )
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($SetIssueCooldown) -and -not [string]::IsNullOrWhiteSpace($ClearIssueCooldown)) {
        Add-MonitorResult -Severity Error -Category Configuration -Check 'Issue cooldown' -Message (
            'Use either -SetIssueCooldown or -ClearIssueCooldown, not both.'
        )
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($SetIssueCooldown)) {
        Set-AutomaticIssueCooldown -Key $SetIssueCooldown -Duration $IssueCooldownDuration
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($ClearIssueCooldown)) {
        Set-AutomaticIssueCooldown -Key $ClearIssueCooldown -Remove
        return
    }
    if ([string]::IsNullOrWhiteSpace($SiteAddress) -and [Environment]::UserInteractive) {
        $script:SiteAddressFromPrompt = Read-Host 'Enter the D4A site address(es), separated by commas (default: hostname:1200)'
    }
    else {
        $script:SiteAddressFromPrompt = $SiteAddress
    }

    if ([string]::IsNullOrWhiteSpace($script:SiteAddressFromPrompt)) {
        $script:SiteAddressFromPrompt = 'hostname:1200'
    }
    $resolvedMonitoringName = if ([string]::IsNullOrWhiteSpace($MonitoringName)) { $env:COMPUTERNAME } else { $MonitoringName.Trim() }
    $monitorEndpoints = [System.Collections.Generic.List[object]]::new()
    try {
        $frontendUris = @(ConvertTo-HttpUris -Addresses $script:SiteAddressFromPrompt)
        $resolvedSiteNames = @(Get-MonitorSiteDisplayNames -FrontendUris $frontendUris)
        $resolvedMonitoringName = if ($resolvedSiteNames.Count -gt 0) { $resolvedSiteNames -join ', ' } elseif ([string]::IsNullOrWhiteSpace($MonitoringName)) { $env:COMPUTERNAME } else { $MonitoringName.Trim() }
        for ($index = 0; $index -lt $frontendUris.Count; $index++) {
            $frontendUri = $frontendUris[$index]
            $apiUri = Get-D4AApiUri -FrontendUri $frontendUri
            $monitorEndpoints.Add([pscustomobject]@{
                FrontendUri = $frontendUri
                ApiUri      = $apiUri
                Label       = $resolvedSiteNames[$index]
            }) | Out-Null
        }
        Write-RunLog -Category Configuration -Message ('MonitoringName={0}; Sites={1}; APIs={2}; recipient={3}; test email={4}; daily summary={5}' -f
            $resolvedMonitoringName,
            (($monitorEndpoints | ForEach-Object { $_.FrontendUri.AbsoluteUri }) -join ', '),
            (($monitorEndpoints | ForEach-Object { $_.ApiUri.AbsoluteUri }) -join ', '),
            $NotificationTo,
            $SendTestResultsEmail.IsPresent,
            $SendDailySummaryEmail.IsPresent) -Color White
    }
    catch {
        Add-MonitorResult -Severity Error -Category Configuration -Check 'Site address' -Message $_.Exception.Message
    }

    $lockPath = Join-Path (Split-Path -Parent $script:RunLogPath) 'scheduled-monitor.lock'
    $lockStream = $null
    try {
        try {
            $lockStream = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch {
            Add-MonitorResult -Severity Warning -Category Monitor -Check 'Overlap lock' -Message (
                'Another monitor instance is running. This scan was skipped.'
            )
            return
        }

        foreach ($endpoint in @($monitorEndpoints)) {
            Invoke-SafeMonitorCheck -Category Application -Check Frontend -Action {
                Test-WebEndpoint -Name ('Frontend availability ({0})' -f $endpoint.Label) -Uri $endpoint.FrontendUri
            }
            Invoke-SafeMonitorCheck -Category Application -Check API -Action {
                Test-WebEndpoint `
                    -Name ('API health ({0})' -f $endpoint.Label) `
                    -Uri $endpoint.ApiUri `
                    -FailureAttempts $ApiHealthFailureAttempts `
                    -FailureRetryIntervalSeconds $ApiHealthRetryIntervalSeconds
            }
            Invoke-SafeMonitorCheck -Category TLS -Check Frontend -Action {
                Test-TlsCertificate -Name ('Frontend certificate ({0})' -f $endpoint.Label) -Uri $endpoint.FrontendUri
            }
            Invoke-SafeMonitorCheck -Category TLS -Check API -Action {
                Test-TlsCertificate -Name ('API certificate ({0})' -f $endpoint.Label) -Uri $endpoint.ApiUri
            }
            Invoke-SafeMonitorCheck -Category 'Application performance' -Check Endpoints -Action {
                Test-ApplicationPerformance -PublicApiBaseUri (Get-AuthorityBaseUri -Uri $endpoint.ApiUri) -TargetLabel $endpoint.Label
            }
        }

    Invoke-SafeMonitorCheck -Category Server -Check 'D4A Windows services' -Action { Test-D4AWindowsServices }
    Invoke-SafeMonitorCheck -Category Server -Check 'Mosquitto/MQTT service' -Action { Test-MosquittoWindowsService }
        Invoke-SafeMonitorCheck -Category Server -Check 'API listener' -Action { Test-ApiListener }
        Invoke-SafeMonitorCheck -Category Server -Check Memory -Action { Test-MemoryHealth }
        Invoke-SafeMonitorCheck -Category Server -Check CPU -Action { Test-CpuHealth }
        Invoke-SafeMonitorCheck -Category Server -Check Disks -Action { Test-DiskHealth }
        Invoke-SafeMonitorCheck -Category Diagnostics -Check 'Nginx errors' -Action { Test-NginxErrors }
        Invoke-SafeMonitorCheck -Category Diagnostics -Check 'Windows events' -Action { Test-RelevantWindowsEvents }
        Invoke-SafeMonitorCheck -Category Diagnostics -Check 'Watchdog service logs' -Action { Test-WatchdogServiceLogs }

        $activeIgnoreRules = @()
        try {
            $activeIgnoreRules = @(Get-ActiveIgnoreRules)
            Apply-IgnoreRulesToResults -ActiveRules $activeIgnoreRules
        }
        catch {
            Add-MonitorResult -Severity Error -Category Ignore -Check 'Ignore rules' -Message (
                'Unable to load or apply ignore-rules.txt: {0}' -f $_.Exception.Message
            ) -Key 'ignore-rules'
        }

        $issuesBeforeEmail = @($script:Results | Where-Object { $_.Severity -ne 'OK' })
        $ignoredIssues = @($issuesBeforeEmail | Where-Object { $_.IgnoreActive })
        $unignoredIssues = @($issuesBeforeEmail | Where-Object { -not $_.IgnoreActive })
        $unignoredNotifiableIssues = @($unignoredIssues | Where-Object { $_.NotificationEligible })
        $dailyOnlyResults = @($unignoredIssues | Where-Object { -not $_.NotificationEligible })
        $recoveredNotifiedIssues = @(Get-RecoveredNotifiedIssues)
        Remove-ResolvedAutomaticIssueCooldowns -ActiveIssueKeys @($issuesBeforeEmail | Select-Object -ExpandProperty Key -Unique)
        if ($activeIgnoreRules.Count -gt 0) {
            Write-RunLog -Category Ignore -Color Cyan -Message ('Active ignore rules loaded: {0}; file={1}' -f $activeIgnoreRules.Count, $script:IgnoreRulesPath)
        }
        foreach ($ignoredIssue in $ignoredIssues) {
            $untilText = if ($null -ne $ignoredIssue.IgnoreUntil) {
                '; until ' + $ignoredIssue.IgnoreUntil.ToString('yyyy-MM-dd HH:mm:ss zzz')
            }
            else {
                ''
            }
            Write-RunLog -Category Ignore -Color DarkGray -Message (
                'Issue {0} is ignored by a {1} rule{2}.' -f $ignoredIssue.Key, $ignoredIssue.IgnoreMode, $untilText
            )
        }

        $emailType = if ($SendTestResultsEmail.IsPresent) {
            'Test'
        }
        elseif ($SendDailySummaryEmail.IsPresent) {
            'Daily'
        }
        elseif ($unignoredNotifiableIssues.Count -gt 0) {
            'Alert'
        }
        else {
            'Recovery'
        }
        $shouldSendEmail = -not $DisableEmail.IsPresent -and (
            $SendTestResultsEmail.IsPresent -or
            $SendDailySummaryEmail.IsPresent -or
            $unignoredNotifiableIssues.Count -gt 0 -or
            $recoveredNotifiedIssues.Count -gt 0
        )

        if ($shouldSendEmail) {
            $siteForEmail = if ($monitorEndpoints.Count -gt 0) {
                (($monitorEndpoints | ForEach-Object { $_.FrontendUri.AbsoluteUri.TrimEnd('/') }) -join ', ')
            }
            elseif (-not [string]::IsNullOrWhiteSpace($script:SiteAddressFromPrompt)) {
                $script:SiteAddressFromPrompt
            }
            else {
                'unknown site'
            }
            $content = New-EmailContent `
                -MonitoredSite $siteForEmail `
                -MonitoringName $resolvedMonitoringName `
                -ActiveIgnoreRules $activeIgnoreRules `
                -RecoveryResults $recoveredNotifiedIssues `
                -EmailType $emailType
            Write-RunLog -Category Email -Color Cyan -Message ('Sending to {0}; subject={1}' -f $NotificationTo, $content.Subject)
            $deliverySucceeded = $false
            try {
                $delivery = Send-MonitorEmail `
                    -Subject $content.Subject `
                    -TextBody $content.TextBody `
                    -HtmlBody $content.HtmlBody
                Write-RunLog -Level OK -Category Email -Color Green -Message (
                    'Notification sent to {0} using {1}. {2}' -f $NotificationTo, $delivery.Method, $delivery.Details
                )
                $deliverySucceeded = $true
            }
            catch {
                Add-MonitorResult -Severity Error -Category Email -Check 'Notification delivery' -Message $_.Exception.Message
            }

            if ($deliverySucceeded) {
                $newlyNotifiedIssues = if ($emailType -eq 'Alert') { $unignoredNotifiableIssues } else { @() }
                try {
                    Update-NotifiedIssueStateAfterDelivery `
                        -NewlyNotifiedIssues $newlyNotifiedIssues `
                        -RecoveredIssues $recoveredNotifiedIssues
                }
                catch {
                    Add-MonitorResult -Severity Warning -Category Recovery -Check 'Notification state' -Message (
                        'The email was delivered, but notification/recovery state could not be saved: {0}' -f $_.Exception.Message
                    ) -NotificationEligible:$false
                }
                if ($emailType -eq 'Alert' -and $unignoredNotifiableIssues.Count -gt 0) {
                    foreach ($issueKey in @($unignoredNotifiableIssues | Select-Object -ExpandProperty Key -Unique)) {
                        try {
                            Set-AutomaticIssueCooldown -Key $issueKey -Duration '24h'
                        }
                        catch {
                            Add-MonitorResult -Severity Warning -Category Ignore -Check 'Automatic cooldown' -Message (
                                'The email was delivered, but the automatic cooldown for {0} could not be saved: {1}' -f $issueKey, $_.Exception.Message
                            ) -NotificationEligible:$false
                        }
                    }
                }
            }
        }
        elseif ($DisableEmail.IsPresent) {
            Write-RunLog -Category Email -Color DarkGray -Message 'Email delivery is disabled for this run.'
        }
        elseif ($issuesBeforeEmail.Count -gt 0 -and $unignoredIssues.Count -eq 0) {
            Write-RunLog -Category Email -Color DarkGray -Message (
                'All detected issues are covered by active ignore rules; no notification was required.'
            )
        }
        elseif ($issuesBeforeEmail.Count -gt 0 -and $unignoredNotifiableIssues.Count -eq 0 -and $dailyOnlyResults.Count -gt 0) {
            Write-RunLog -Category Email -Color DarkGray -Message (
                'Only daily-summary warning evidence was detected; it is retained for the daily monitoring results email.'
            )
        }
        elseif ($issuesBeforeEmail.Count -gt 0 -and $unignoredNotifiableIssues.Count -eq 0) {
            Write-RunLog -Category Email -Color DarkGray -Message (
                'Only non-notifying diagnostic or recovered-check warnings were detected; no normal notification was required.'
            )
        }
        else {
            Write-RunLog -Category Email -Color Green -Message 'No issue was detected; no notification was required.'
        }
    }
    finally {
        if ($null -ne $lockStream) {
            $lockStream.Dispose()
        }
    }
}

$finalExitCode = 2
try {
    Import-MonitorConfiguration
    Test-MonitorConfigurationValues
    Initialize-MonitorLogging
    Invoke-MonitorAutomaticUpdate
    $managementModes = @(@(
            $ValidateConfiguration.IsPresent,
            $ShowConfiguration.IsPresent,
            -not [string]::IsNullOrWhiteSpace($AddSiteAddress),
            -not [string]::IsNullOrWhiteSpace($SetIssueCooldown),
            -not [string]::IsNullOrWhiteSpace($ClearIssueCooldown)
        ) | Where-Object { $_ })
    if ($managementModes.Count -gt 1) {
        throw 'Use only one management command at a time: ValidateConfiguration, ShowConfiguration, AddSiteAddress, SetIssueCooldown, or ClearIssueCooldown.'
    }

    if ($ShowConfiguration.IsPresent) {
        Show-MonitorConfiguration
        $finalExitCode = 0
    }
    elseif (-not [string]::IsNullOrWhiteSpace($AddSiteAddress)) {
        Add-MonitorConfiguredSites -Addresses $AddSiteAddress
        $finalExitCode = 0
    }
    elseif ($ValidateConfiguration.IsPresent) {
        Write-Host ('Monitoring configuration is valid. Version={0}; release date={1}; configuration={2}' -f
            $script:MonitorVersion, $script:MonitorReleaseDate, $script:ResolvedConfigPath) -ForegroundColor Green
        Write-Host ('MonitoringName={0}; SiteAddress={1}; NotificationTo={2}; LogRetentionDays={3}' -f
            $MonitoringName, $SiteAddress, $NotificationTo, $LogRetentionDays) -ForegroundColor Gray
        $finalExitCode = 0
    }
    else {
        Invoke-D4AMonitor
        $finalExitCode = Get-ExitCode
    }
}
catch {
    $fatalMessage = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) {
        $fatalMessage = '{0} | Stack: {1}' -f $fatalMessage, (($_.ScriptStackTrace -replace '[\r\n]+', ' ').Trim())
    }
    if ($script:LoggingReady) {
        Write-RunLog -Level Error -Category Monitor -Color Red -Message ('Fatal monitor failure: {0}' -f $fatalMessage)
        Write-ErrorLog -Level Error -Category Monitor -Message ('Fatal monitor failure: {0}' -f $fatalMessage)
    }
    else {
        Write-Host ('[FATAL] Unable to initialize or run the monitor: {0}' -f $fatalMessage) -ForegroundColor Red
    }
    $finalExitCode = 2
}
finally {
    if ($script:LoggingReady) {
        $counts = [ordered]@{
            OK      = @($script:Results | Where-Object { $_.Severity -eq 'OK' }).Count
            Warning = @($script:Results | Where-Object { $_.Severity -eq 'Warning' }).Count
            Alert   = @($script:Results | Where-Object { $_.Severity -eq 'Alert' }).Count
            Error   = @($script:Results | Where-Object { $_.Severity -eq 'Error' }).Count
        }
        Write-RunLog -Category Summary -Color Cyan -Message (
            'Completed in {0:N1} seconds. OK={1}; Warning={2}; Alert={3}; Error={4}; exit code={5}.' -f
                ((Get-Date) - $script:RunStartedAt).TotalSeconds,
                $counts.OK,
                $counts.Warning,
                $counts.Alert,
                $counts.Error,
                $finalExitCode
        )
        Write-RunLog -Category Summary -Color DarkGray -Message ('Monitoring logs: {0}' -f $script:MonitorLogDirectory)
        Write-RunLog -Category Summary -Color DarkGray -Message ('Monitor summary log: {0}' -f $script:RunLogPath)
    }
    [Environment]::ExitCode = $finalExitCode
}

# Task Scheduler normally launches this script with powershell.exe -File. In
# that mode an explicit exit is required for the process to return the monitor
# severity. Interactive invocation keeps the current PowerShell host open.
$commandLineArguments = @([Environment]::GetCommandLineArgs())
if (@($commandLineArguments | Where-Object { $_ -ieq '-File' }).Count -gt 0) {
    exit $finalExitCode
}
