# ==============================================================================
# IT TOOLS: DATABASE TRANSLATIONS AND LOCAL SERVER CHECKS
# Developer: ⇓⇓⇓⇓
#
#  _  __ _           _          _     ____             _
# | |/ /| |__   __ _| | ___  __| | | | __ )  __ _ _ __| |__   __ _ _ __
# | ' / | '_ \ / _` | |/ _ \/ _` | | |  _ \ / _` | '__| '_ \ / _` | '__|
# | . \ | | | | (_| | |  __/ (_| | | | |_) | (_| | |  | |_) | (_| | |
# |_|\_\__| |_|\__,_|_|\___|\__,_| | |____/ \__,_|_|  |_.__/ \__,_|_|
# ==============================================================================
# This script contains two groups of tools:
#   1. Database tools:
#      - Export language files
#      - Import new languages with translated CSV files
#      - Import CSV or Excel files into staging tables
#      - Migrate data between database tables
#      - Copy P4A activities between machines
#      - Enable Line Detailed View
#      - Roll back script changes from timestamped backups
#      - Review database performance and SQL diagnostics
#      - Find text that needs translation
#      - Find missing translations
#      - Review or remove disconnected translation rows
#   2. Local server and file tools:
#      - Search for text in files
#      - Check basic system health
#      - Show recently created or changed files
#      - Launch the visual disk usage analyzer
#      - Manage SQL backup folder permissions
#      - Check whether a TCP port is open
#   3. Site monitoring:
#      - Deploy and schedule the D4A health and performance monitor
# ==============================================================================

[CmdletBinding()]
param(
    [switch]$SkipAutomaticUpdate
)

$ErrorActionPreference = "Continue"
Clear-Host

# ------------------------------------------------------------------------------
# Shared state
# ------------------------------------------------------------------------------
$Global:SelectedInstance = ""
$Global:SelectedDb       = ""
$Global:User             = ""
$Global:PlainPass        = ""

$Script:ServerCheckCimTimeoutSeconds = 45
$Script:DeepDirectoryScanTimeoutSeconds = 180
$Script:FolderSizeTimeoutSeconds = 60
$Script:ToolVersion = [version]'7.0.3'
$Script:ToolReleaseDate = '2026-08-12'
$Script:ToolRepositoryRawRoot = 'https://raw.githubusercontent.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools/main'
$Script:ToolVersionFileName = 'version.txt'
$Script:ToolUpdateManifestFileName = 'update-manifest.json'
$Script:ToolMainScriptFileName = 'IT_Tools_Database_Translations_and_Server_Checks.ps1'

$Script:IsAdmin = $false
try {
    $Script:IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}
catch {
    $Script:IsAdmin = $false
}

# ------------------------------------------------------------------------------
# Shared helpers
# ------------------------------------------------------------------------------
function Pause-Screen {
    param(
        [string]$Message = "Press any key to return to the previous menu..."
    )
    Write-Host ""
    Write-Host $Message -ForegroundColor DarkGray
    try {
        [void][Console]::ReadKey($true)
    }
    catch {
        [void](Read-Host "Press Enter to return to the previous menu")
    }
}

function Show-SectionTitle {
    param(
        [Parameter(Mandatory = $true)][string]$Title
    )
    Write-Host ""
    Write-Host "------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
}

function Test-IsBack {
    param([AllowNull()][string]$InputVal)
    if ([string]::IsNullOrWhiteSpace($InputVal)) { return $false }
    $value = $InputVal.Trim().ToLowerInvariant()
    return ($value -eq 'b' -or $value -eq 'back' -or $value -eq 'q' -or $value -eq 'quit')
}

function Normalize-UserPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    $cleanPath = $Path.Trim()
    $cleanPath = $cleanPath.Trim([char]34) # double quote
    $cleanPath = $cleanPath.Trim([char]39) # single quote
    return $cleanPath
}

function ConvertTo-RequiredText {
    param(
        [AllowNull()][object]$Value,
        [string]$Purpose = "value",
        [bool]$JoinMultipleStrings = $false
    )

    if ($null -eq $Value) {
        throw "Expected $Purpose as text, but received null."
    }

    $items = @($Value)
    if ($items.Count -eq 1 -and $items[0] -is [string]) {
        return [string]$items[0]
    }

    $stringItems = @($items | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
    if ($stringItems.Count -gt 0) {
        if ($JoinMultipleStrings) { return ($stringItems -join "`r`n") }
        return [string]$stringItems[-1]
    }

    if ($items.Count -eq 1 -and $items[0] -is [System.Management.Automation.PSObject] -and $items[0].BaseObject -is [string]) {
        return [string]$items[0].BaseObject
    }

    $receivedTypes = (@($items | ForEach-Object {
        if ($null -eq $_) { "null" } else { $_.GetType().FullName }
    }) | Sort-Object -Unique) -join ", "

    throw "Expected $Purpose as text, but received: $receivedTypes."
}

function Get-CurrentScriptFolder {
    $scriptFolder = $PSScriptRoot

    if ([string]::IsNullOrWhiteSpace($scriptFolder)) {
        $scriptPath = $PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.PSCommandPath }
        if (-not [string]::IsNullOrWhiteSpace($scriptPath)) {
            $scriptFolder = Split-Path -Parent $scriptPath
        }
    }

    if ([string]::IsNullOrWhiteSpace($scriptFolder)) {
        $scriptFolder = (Get-Location).Path
    }

    return $scriptFolder
}

function Show-ITToolsDeveloperBanner {
    $banner = @'
 _  __ _           _          _   ____             _
| |/ /| |__   __ _| | ___  __| | | __ )  __ _ _ __| |__   __ _ _ __
| ' /| '_ \ / _` | |/ _ \/ _` | | |  _ \ / _` | '__| '_ \ / _` | '__|
| . \| | | | (_| | |  __/ (_| | | | |_) | (_| | |  | |_) | (_| | |
|_|\_\_| |_|\__,_|_|\___|\__,_| | |____/ \__,_|_|  |_.__/ \__,_|_|
'@
    Write-Host $banner -ForegroundColor Green
    Write-Host "Developer: Khaled Barbar | IT Tools version $($Script:ToolVersion) | Release date: $($Script:ToolReleaseDate)" -ForegroundColor Cyan
    Write-Host ''
}

function Get-ITToolsUpdateUri {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    if ($RelativePath -match '(?i)(\.\.|^[\\/]|^[A-Za-z]:)') {
        throw "Unsafe update path: $RelativePath"
    }

    $encodedPath = (@($RelativePath -split '[\\/]' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    return "$($Script:ToolRepositoryRawRoot)/$encodedPath"
}

function Get-ITToolsRemoteText {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $response = Invoke-WebRequest -Uri (Get-ITToolsUpdateUri -RelativePath $RelativePath) -UseBasicParsing -TimeoutSec 12 -ErrorAction Stop
    return ([string]$response.Content).Trim()
}

function Test-ITToolsScriptFolderWritable {
    param([Parameter(Mandatory = $true)][string]$Folder)

    $testPath = Join-Path $Folder ('.it_tools_update_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($testPath, 'IT Tools update permission check')
        Remove-Item -LiteralPath $testPath -Force -ErrorAction Stop
        return $true
    }
    catch {
        Remove-Item -LiteralPath $testPath -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Get-ITToolsDesktopBackupFolder {
    $desktopPath = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
    if ([string]::IsNullOrWhiteSpace($desktopPath)) {
        $desktopPath = Join-Path $env:USERPROFILE 'Desktop'
    }
    return (Join-Path $desktopPath 'IT Tools Backups')
}

function New-ITToolsScriptBackup {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $backupFolder = Get-ITToolsDesktopBackupFolder
    [void](New-Item -Path $backupFolder -ItemType Directory -Force -ErrorAction Stop)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backupPath = Join-Path $backupFolder ('{0}_{1}.ps1' -f $baseName, $timestamp)
    while (Test-Path -LiteralPath $backupPath) {
        Start-Sleep -Seconds 1
        $timestamp = Get-Date -Format 'yyyyMMddHHmmss'
        $backupPath = Join-Path $backupFolder ('{0}_{1}.ps1' -f $baseName, $timestamp)
    }

    Copy-Item -LiteralPath $ScriptPath -Destination $backupPath -Force -ErrorAction Stop
    $oldBackups = @(Get-ChildItem -LiteralPath $backupFolder -File -Filter "$($baseName)_*.ps1" -ErrorAction Stop |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 2)
    foreach ($oldBackup in $oldBackups) {
        Remove-Item -LiteralPath $oldBackup.FullName -Force -ErrorAction Stop
    }
    return $backupPath
}

function Invoke-ITToolsAutomaticUpdate {
    if ($SkipAutomaticUpdate.IsPresent) { return }

    $updateAvailable = $false
    try {
        $remoteVersionText = Get-ITToolsRemoteText -RelativePath $Script:ToolVersionFileName
        $remoteVersion = [version]$remoteVersionText
        if ($remoteVersion -le $Script:ToolVersion) { return }
        $updateAvailable = $true

        Write-Host "A new IT Tools version is available: $remoteVersion." -ForegroundColor Green
        $scriptPath = $PSCommandPath
        if ([string]::IsNullOrWhiteSpace($scriptPath)) { $scriptPath = $MyInvocation.MyCommand.Path }
        if ([string]::IsNullOrWhiteSpace($scriptPath)) {
            throw 'Cannot determine the current IT Tools script path.'
        }
        $scriptPath = [IO.Path]::GetFullPath($scriptPath)
        $scriptFolder = Split-Path -Parent $scriptPath
        if (-not (Test-ITToolsScriptFolderWritable -Folder $scriptFolder)) {
            Write-Host "This copy cannot be updated in: $scriptFolder" -ForegroundColor Yellow
            Write-Host 'Run IT Tools as Administrator, or move the complete IT Tools folder to a user-owned folder such as Desktop or Documents and run it again.' -ForegroundColor Yellow
            return
        }

        Write-StreamingLog -Percent 10 -Step 'Update' -Description 'Downloading the release manifest for verification.'
        $manifestText = Get-ITToolsRemoteText -RelativePath $Script:ToolUpdateManifestFileName
        $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop
        if ([string]$manifest.version -ne $remoteVersion.ToString()) {
            throw "The update manifest version '$($manifest.version)' does not match version.txt '$remoteVersion'."
        }
        $manifestFiles = @($manifest.files)
        if ($manifestFiles.Count -eq 0) { throw 'The update manifest does not contain files.' }
        if (@($manifestFiles | Where-Object { $_.path -eq $Script:ToolMainScriptFileName }).Count -ne 1) {
            throw "The update manifest must contain $($Script:ToolMainScriptFileName)."
        }

        $filesToInstall = @()
        $missingCompanionFiles = @()
        foreach ($file in $manifestFiles) {
            $relativePath = [string]$file.path
            $expectedHash = ([string]$file.sha256).ToUpperInvariant()
            if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath -match '(?i)(\.\.|^[\\/]|^[A-Za-z]:)') {
                throw "Unsafe update file path: $relativePath"
            }
            if ($expectedHash -notmatch '^[A-F0-9]{64}$') {
                throw "Invalid SHA-256 value for $relativePath."
            }

            if ($relativePath -eq $Script:ToolMainScriptFileName -or (Test-Path -LiteralPath (Join-Path $scriptFolder $relativePath) -PathType Leaf)) {
                $filesToInstall += $file
            }
            else {
                $missingCompanionFiles += $relativePath
            }
        }

        if ($missingCompanionFiles.Count -gt 0) {
            Write-Host "Missing companion files will not be downloaded during the version update: $($missingCompanionFiles -join ', ')." -ForegroundColor DarkGray
            Write-Host 'They will be downloaded only when you select the feature that requires them.' -ForegroundColor DarkGray
        }

        $stagingFolder = Join-Path ([IO.Path]::GetTempPath()) ('ITToolsUpdate_{0}' -f [guid]::NewGuid().ToString('N'))
        [void](New-Item -Path $stagingFolder -ItemType Directory -Force -ErrorAction Stop)
        try {
            $fileIndex = 0
            foreach ($file in $filesToInstall) {
                $fileIndex++
                $relativePath = [string]$file.path
                $expectedHash = ([string]$file.sha256).ToUpperInvariant()

                $downloadPath = Join-Path $stagingFolder $relativePath
                $downloadFolder = Split-Path -Parent $downloadPath
                [void](New-Item -Path $downloadFolder -ItemType Directory -Force -ErrorAction Stop)
                $percent = [Math]::Min(75, 10 + [int](($fileIndex / $filesToInstall.Count) * 65))
                Write-StreamingLog -Percent $percent -Step 'Update' -Description "Downloading and verifying $relativePath."
                Invoke-WebRequest -Uri (Get-ITToolsUpdateUri -RelativePath $relativePath) -OutFile $downloadPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
                $actualHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
                if ($actualHash -ne $expectedHash) {
                    throw "Integrity check failed for $relativePath."
                }
            }

            $downloadedMainScript = Join-Path $stagingFolder $Script:ToolMainScriptFileName
            $tokens = $null
            $parserErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($downloadedMainScript, [ref]$tokens, [ref]$parserErrors)
            if ($parserErrors.Count -gt 0) {
                throw ('The downloaded IT Tools script has syntax errors: {0}' -f (($parserErrors | Select-Object -First 1).Message))
            }

            Write-StreamingLog -Percent 80 -Step 'Backup' -Description 'Saving the current IT Tools script on the Desktop.'
            $backupPath = New-ITToolsScriptBackup -ScriptPath $scriptPath
            $orderedFiles = @($filesToInstall | Sort-Object @{ Expression = { if ($_.path -eq $Script:ToolMainScriptFileName) { 1 } else { 0 } } })
            foreach ($file in $orderedFiles) {
                $relativePath = [string]$file.path
                $sourcePath = Join-Path $stagingFolder $relativePath
                $destinationPath = if ($relativePath -eq $Script:ToolMainScriptFileName) { $scriptPath } else { Join-Path $scriptFolder $relativePath }
                $destinationFolder = Split-Path -Parent $destinationPath
                [void](New-Item -Path $destinationFolder -ItemType Directory -Force -ErrorAction Stop)
                Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force -ErrorAction Stop
            }

            Write-StreamingLog -Percent 100 -Step 'Update' -Description "IT Tools version $remoteVersion was installed."
            Write-Host "Update installed successfully. Previous script backup: $backupPath" -ForegroundColor Green
            Start-Sleep -Seconds 1
            $quotedScriptPath = '"{0}"' -f $scriptPath.Replace('"', '""')
            Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File $quotedScriptPath"
            exit
        }
        finally {
            if (Test-Path -LiteralPath $stagingFolder -PathType Container) {
                Remove-Item -LiteralPath $stagingFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        if ($updateAvailable) {
            $logPath = Write-ToolErrorLog -Context 'Automatic GitHub update' -ErrorRecord $_
            Write-Host "The update was not applied. The current version will continue. Error log: $logPath" -ForegroundColor Yellow
        }
    }
}

function Get-FirstWords {
    param(
        [AllowNull()][string]$Text,
        [int]$WordCount = 5
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $words = @($Text -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($words.Count -le $WordCount) { return ($words -join ' ') }
    return (($words | Select-Object -First $WordCount) -join ' ')
}

function Write-ToolErrorLog {
    param(
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $scriptFolder = Get-CurrentScriptFolder
    $logFolder = Join-Path -Path $scriptFolder -ChildPath "Logs"
    if (-not (Test-Path -LiteralPath $logFolder -PathType Container)) {
        [void](New-Item -Path $logFolder -ItemType Directory -Force)
    }

    $logPath = Join-Path -Path $logFolder -ChildPath ("tools_script_error_log_{0}.txt" -f (Get-Date -Format "yyyyMMdd"))
    $entry = @"
===============================================================================
Timestamp: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Context: $Context
SQL Server: $Global:SelectedInstance
Database: $Global:SelectedDb
Message: $($ErrorRecord.Exception.Message)
Exception Type: $($ErrorRecord.Exception.GetType().FullName)
Fully Qualified Error ID: $($ErrorRecord.FullyQualifiedErrorId)
Category: $($ErrorRecord.CategoryInfo)
Script Stack Trace:
$($ErrorRecord.ScriptStackTrace)
Invocation:
$($ErrorRecord.InvocationInfo.PositionMessage)
Exception Details:
$($ErrorRecord.Exception.ToString())

"@

    Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
    return $logPath
}

function Show-LoggedError {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $logPath = Write-ToolErrorLog -Context $Context -ErrorRecord $ErrorRecord
    $message = [string]$ErrorRecord.Exception.Message
    $wordCount = @($message -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count

    if ($wordCount -le 50) {
        Write-Host "${Prefix}: $message" -ForegroundColor Red
    }
    else {
        $shortMessage = Get-FirstWords -Text $message -WordCount 5
        Write-Host "${Prefix}: $shortMessage... Full error exported to log." -ForegroundColor Red
    }

    Write-Host "Error log: $logPath" -ForegroundColor Yellow
}

function Invoke-LoggedToolAction {
    param(
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    try {
        & $Action
    }
    catch {
        Show-LoggedError -Prefix "The selected tool did not complete" -Context $Context -ErrorRecord $_
        Pause-Screen
    }
}

function Write-StreamingLog {
    param(
        [int]$Percent,
        [string]$Step,
        [string]$Description
    )
    $Timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$Timestamp] [$Percent%] " -NoNewline -ForegroundColor DarkGray
    Write-Host "$Step - " -NoNewline -ForegroundColor Cyan
    Write-Host $Description -ForegroundColor Yellow
}

function Invoke-OperationWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$OperationName,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [AllowNull()][object]$Argument = $null,
        [int]$TimeoutSeconds = 120
    )

    if ($TimeoutSeconds -le 0) {
        return & $ScriptBlock $Argument
    }

    if (-not (Get-Command Start-Job -ErrorAction SilentlyContinue)) {
        throw "Cannot enforce timeout for '$OperationName' because Start-Job is not available in this PowerShell session."
    }

    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $Argument
    try {
        $completedJob = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if ($null -eq $completedJob) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            throw "Timed out after $TimeoutSeconds seconds while $OperationName. Narrow the folder scope or try again later."
        }

        if ($job.State -ne 'Completed') {
            $reason = $job.ChildJobs[0].JobStateInfo.Reason
            if ($null -ne $reason) {
                throw "Operation '$OperationName' ended with state '$($job.State)': $($reason.Message)"
            }

            throw "Operation '$OperationName' ended with state '$($job.State)'."
        }

        return Receive-Job -Job $job -ErrorAction Stop
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-InstallStepWithProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [AllowNull()][object]$Argument = $null,
        [int]$StartPercent = 10,
        [int]$EndPercent = 90,
        [int]$IntervalSeconds = 5
    )

    Write-StreamingLog -Percent $StartPercent -Step $Step -Description $Description

    if (-not (Get-Command Start-Job -ErrorAction SilentlyContinue)) {
        & $ScriptBlock $Argument
        Write-StreamingLog -Percent $EndPercent -Step $Step -Description "$Description completed."
        return
    }

    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $Argument
    $elapsedSeconds = 0
    $currentPercent = $StartPercent

    try {
        while ($job.State -in @('NotStarted', 'Running')) {
            $elapsedSeconds += $IntervalSeconds
            $currentPercent = [Math]::Min($EndPercent, $currentPercent + 3)
            Write-StreamingLog -Percent $currentPercent -Step $Step -Description "$Description elapsed ${elapsedSeconds}s..."
            [void](Wait-Job -Job $job -Timeout $IntervalSeconds)
        }

        if ($job.State -ne 'Completed') {
            $reason = $job.ChildJobs[0].JobStateInfo.Reason
            if ($null -ne $reason) {
                throw "Background step '$Step' ended with state '$($job.State)': $($reason.Message)"
            }

            throw "Background step '$Step' ended with state '$($job.State)'."
        }

        [void](Receive-Job -Job $job -ErrorAction Stop)
        Write-StreamingLog -Percent $EndPercent -Step $Step -Description "$Description completed."
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}

function Convert-SecureStringToPlainText {
    param([AllowNull()][Security.SecureString]$SecureString)

    if ($null -eq $SecureString) { return "" }

    $ptr = [IntPtr]::Zero
    try {
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }
}

function Clear-DatabaseConnection {
    $Global:SelectedInstance = ""
    $Global:SelectedDb       = ""
    $Global:User             = ""
    $Global:PlainPass        = ""
}

function Get-ConnectionTextValue {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Purpose,
        [string[]]$PreferredProperties = @()
    )

    if ($null -eq $Value) { return "" }

    if ($Value -is [string]) { return [string]$Value }

    foreach ($propertyName in $PreferredProperties) {
        $property = $Value.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $null -ne $property.Value) {
            return (Get-ConnectionTextValue -Value $property.Value -Purpose $Purpose -PreferredProperties $PreferredProperties)
        }
    }

    if ($Value -is [System.Management.Automation.PSObject] -and $Value.BaseObject -is [string]) {
        return [string]$Value.BaseObject
    }

    try {
        return [string]$Value
    }
    catch {
        $receivedType = $Value.GetType().FullName
        throw "Could not read $Purpose as text. Received: $receivedType."
    }
}

function Read-PasswordWithClipboardSupport {
    param([string]$Prompt = "Database password")

    $password = [Text.StringBuilder]::new()
    Write-Host "$Prompt (Ctrl+V supported): " -NoNewline

    try {
        while ($true) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Enter) {
                Write-Host ""
                break
            }

            if ($key.Key -eq [ConsoleKey]::Backspace) {
                if ($password.Length -gt 0) {
                    [void]$password.Remove($password.Length - 1, 1)
                    Write-Host "`b `b" -NoNewline
                }
                continue
            }

            if ($key.Key -eq [ConsoleKey]::V -and ($key.Modifiers -band [ConsoleModifiers]::Control)) {
                try {
                    $clipboardText = [string](Get-Clipboard -Raw -ErrorAction Stop)
                    $clipboardText = $clipboardText.TrimEnd("`r", "`n")
                    if (-not [string]::IsNullOrEmpty($clipboardText)) {
                        [void]$password.Append($clipboardText)
                        Write-Host ('*' * $clipboardText.Length) -NoNewline
                    }
                }
                catch {
                    Write-Host ""
                    Write-Host "Clipboard content could not be read. Type the password instead." -ForegroundColor Yellow
                    Write-Host "${Prompt}: " -NoNewline
                }
                continue
            }

            if ($key.KeyChar -ne [char]0 -and -not [char]::IsControl($key.KeyChar)) {
                [void]$password.Append($key.KeyChar)
                Write-Host "*" -NoNewline
            }
        }

        return $password.ToString()
    }
    catch {
        # Keep a compatible fallback for hosts without Console.ReadKey support.
        Write-Host ""
        $securePassword = Read-Host -AsSecureString "$Prompt (clipboard support is unavailable in this host)"
        return Convert-SecureStringToPlainText -SecureString $securePassword
    }
}

function Get-DatabaseConnectionSettings {
    $instance = Get-ConnectionTextValue -Value $Global:SelectedInstance -Purpose "SQL Server instance" -PreferredProperties @('ServerInstance', 'DataSource', 'Name')
    $database = Get-ConnectionTextValue -Value $Global:SelectedDb -Purpose "database name" -PreferredProperties @('Database', 'InitialCatalog', 'Name')
    $user = Get-ConnectionTextValue -Value $Global:User -Purpose "database user name" -PreferredProperties @('UserName', 'User', 'Name')
    $password = Get-ConnectionTextValue -Value $Global:PlainPass -Purpose "database password" -PreferredProperties @('Password')

    return [pscustomobject]@{
        Instance = $instance
        Database = $database
        User     = $user
        Password = $password
    }
}

function Test-SqlCommandAvailable {
    if (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue) {
        return $true
    }

    if (Get-Module -ListAvailable -Name SqlServer) {
        try {
            Import-Module SqlServer -ErrorAction Stop
            if (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue) {
                return $true
            }
        }
        catch {
            Show-LoggedError -Prefix "Could not import the SqlServer PowerShell module" -Context "Load SqlServer PowerShell module" -ErrorRecord $_
        }
    }

    Write-Host "The SQL Server PowerShell command 'Invoke-Sqlcmd' is not available." -ForegroundColor Red
    Write-Host "This tool can install the SqlServer module for the current Windows user." -ForegroundColor Yellow
    Write-Host "Command: Install-Module -Name SqlServer -Scope CurrentUser -Force -AllowClobber" -ForegroundColor Gray
    $installChoice = Read-Host "Type INSTALL to install it now, or type q / press Enter to cancel"
    if ($installChoice -cne 'INSTALL') {
        Write-Host "Module installation cancelled. Database tools cannot continue without Invoke-Sqlcmd." -ForegroundColor Yellow
        Pause-Screen
        return $false
    }

    try {
        Show-SectionTitle "Installing SqlServer PowerShell Module"
        Write-StreamingLog -Percent 5 -Step "Prepare" -Description "Preparing module installation for the current Windows user."

        $installModuleCommand = Get-Command Install-Module -ErrorAction SilentlyContinue
        if (-not $installModuleCommand) {
            throw "Install-Module is not available. Install or repair PowerShellGet, then run this tool again."
        }

        Write-StreamingLog -Percent 15 -Step "PowerShellGet" -Description "Install-Module command is available."
        Write-StreamingLog -Percent 20 -Step "TLS" -Description "Enabling TLS 1.2 for PowerShell Gallery access."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $installProviderCommand = Get-Command Install-PackageProvider -ErrorAction SilentlyContinue
        if ($installProviderCommand) {
            $providerParams = @{
                Name           = 'NuGet'
                MinimumVersion = '2.8.5.201'
                Force          = $true
                ErrorAction    = 'Stop'
            }
            if ($installProviderCommand.Parameters.ContainsKey('Scope')) {
                $providerParams['Scope'] = 'CurrentUser'
            }

            Invoke-InstallStepWithProgress -Step "NuGet provider" -Description "Installing or updating the NuGet package provider." -StartPercent 25 -EndPercent 35 -ScriptBlock {
                param([hashtable]$ProviderParams)
                $ErrorActionPreference = 'Stop'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                [void](Install-PackageProvider @ProviderParams)
            } -Argument $providerParams
        }
        else {
            Write-StreamingLog -Percent 35 -Step "NuGet provider" -Description "Install-PackageProvider command is not available; continuing with Install-Module."
        }

        $installModuleParams = @{
            Name        = 'SqlServer'
            Scope       = 'CurrentUser'
            Force       = $true
            ErrorAction = 'Stop'
        }
        if ($installModuleCommand.Parameters.ContainsKey('AllowClobber')) {
            $installModuleParams['AllowClobber'] = $true
        }

        Invoke-InstallStepWithProgress -Step "SqlServer module" -Description "Installing the SqlServer module for the current Windows user." -StartPercent 40 -EndPercent 85 -ScriptBlock {
            param([hashtable]$ModuleParams)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Install-Module @ModuleParams
        } -Argument $installModuleParams

        Write-StreamingLog -Percent 90 -Step "Import module" -Description "Loading the SqlServer module in this PowerShell session."
        Import-Module SqlServer -ErrorAction Stop

        if (Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue) {
            Write-StreamingLog -Percent 100 -Step "Done" -Description "SqlServer module installed and Invoke-Sqlcmd is available."
            Write-Host "SqlServer PowerShell module installed and loaded successfully." -ForegroundColor Green
            Start-Sleep -Seconds 1
            return $true
        }

        throw "The SqlServer module was installed, but Invoke-Sqlcmd is still not available in this PowerShell session."
    }
    catch {
        Show-LoggedError -Prefix "Could not install the SqlServer PowerShell module" -Context "Install SqlServer PowerShell module" -ErrorRecord $_
        Pause-Screen
        return $false
    }
}

function Get-InvokeSqlcmdSslParameters {
    $parameters = @{}
    $command = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
    if ($null -eq $command) { return $parameters }

    if ($command.Parameters.ContainsKey('Encrypt')) {
        $parameters['Encrypt'] = 'Optional'
    }

    if ($command.Parameters.ContainsKey('TrustServerCertificate')) {
        $parameters['TrustServerCertificate'] = $true
    }

    return $parameters
}

function Test-IsSqlCertificateTrustError {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $messages = New-Object System.Collections.Generic.List[string]
    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        if (-not [string]::IsNullOrWhiteSpace($exception.Message)) {
            $messages.Add($exception.Message)
        }
        $exception = $exception.InnerException
    }

    $fullMessage = ($messages -join " ")
    return ($fullMessage -match 'certificate chain.*not trusted' -or
            $fullMessage -match 'authority that is not trusted' -or
            $fullMessage -match 'SSL Provider')
}

function New-InvokeSqlcmdConnectionString {
    param(
        [Parameter(Mandatory = $true)][string]$ServerInstance,
        [string]$Database,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder["Data Source"] = $ServerInstance
    if (-not [string]::IsNullOrWhiteSpace($Database)) {
        $builder["Initial Catalog"] = $Database
    }
    $builder["User ID"] = $Username
    $builder["Password"] = $Password
    $builder["Encrypt"] = $false
    $builder["TrustServerCertificate"] = $true

    return $builder.ConnectionString
}

function Invoke-D4ASqlcmd {
    param(
        [Parameter(Mandatory = $true)][string]$ServerInstance,
        [string]$Database,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [string]$Query,
        [string]$InputFile,
        [int]$QueryTimeout = 0
    )

    $sqlParams = @{
        ServerInstance = $ServerInstance
        Username       = $Username
        Password       = $Password
        QueryTimeout   = $QueryTimeout
        ErrorAction    = 'Stop'
    }

    if (-not [string]::IsNullOrWhiteSpace($Database)) {
        $sqlParams['Database'] = $Database
    }
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $sqlParams['Query'] = $Query
    }
    if (-not [string]::IsNullOrWhiteSpace($InputFile)) {
        $sqlParams['InputFile'] = $InputFile
    }

    foreach ($sslParameter in (Get-InvokeSqlcmdSslParameters).GetEnumerator()) {
        $sqlParams[$sslParameter.Key] = $sslParameter.Value
    }

    try {
        return Invoke-Sqlcmd @sqlParams
    }
    catch {
        $command = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
        if ((Test-IsSqlCertificateTrustError -ErrorRecord $_) -and
            $null -ne $command -and
            $command.Parameters.ContainsKey('ConnectionString')) {
            $connectionString = New-InvokeSqlcmdConnectionString -ServerInstance $ServerInstance -Database $Database -Username $Username -Password $Password
            $fallbackParams = @{
                ConnectionString = $connectionString
                QueryTimeout     = $QueryTimeout
                ErrorAction      = 'Stop'
            }
            if (-not [string]::IsNullOrWhiteSpace($Query)) {
                $fallbackParams['Query'] = $Query
            }
            if (-not [string]::IsNullOrWhiteSpace($InputFile)) {
                $fallbackParams['InputFile'] = $InputFile
            }

            return Invoke-Sqlcmd @fallbackParams
        }

        throw
    }
}

# ------------------------------------------------------------------------------
# Site monitoring deployment
# ------------------------------------------------------------------------------
function Get-DefaultD4AConfigurationFolder {
    $serviceDetails = @()
    try {
        $serviceDetails = @(Invoke-OperationWithTimeout -OperationName "reading Decide4Action service configuration" -TimeoutSeconds $Script:ServerCheckCimTimeoutSeconds -ScriptBlock {
            Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
                Where-Object { $_.Name -match '(?i)decide4action|d4a' -or $_.DisplayName -match '(?i)decide4action|d4a' } |
                Select-Object Name, DisplayName, PathName
        })
    }
    catch {
        # The deployment menu remains usable when WMI/CIM cannot identify the service.
    }

    foreach ($service in $serviceDetails) {
        $pathName = [string]$service.PathName
        if ([string]::IsNullOrWhiteSpace($pathName)) { continue }

        $expandedPath = [Environment]::ExpandEnvironmentVariables($pathName)
        $executablePath = if ($expandedPath -match '^\s*"(?<Path>[^"]+)"') { $matches.Path } else { ($expandedPath -split '\s+')[0] }
        if ([string]::IsNullOrWhiteSpace($executablePath)) { continue }

        $executableFolder = Split-Path -Parent $executablePath
        if ([string]::IsNullOrWhiteSpace($executableFolder)) { continue }

        $installRoot = if ((Split-Path -Leaf $executableFolder) -ieq 'Utilities') {
            Split-Path -Parent $executableFolder
        }
        else {
            $executableFolder
        }
        $configurationFolder = Join-Path $installRoot 'Configuration'
        if (Test-Path -LiteralPath $configurationFolder -PathType Container) {
            return (Get-Item -LiteralPath $configurationFolder -ErrorAction Stop).FullName
        }
    }

    foreach ($installRoot in @($env:D4A_HOME, 'D:\Apps\Decide4Action', 'C:\Apps\Decide4Action', 'D:\Apps\Decide4Action-v2', 'C:\Apps\Decide4Action-v2')) {
        if ([string]::IsNullOrWhiteSpace([string]$installRoot)) { continue }
        $configurationFolder = Join-Path ([Environment]::ExpandEnvironmentVariables([string]$installRoot)) 'Configuration'
        if (Test-Path -LiteralPath $configurationFolder -PathType Container) {
            return (Get-Item -LiteralPath $configurationFolder -ErrorAction Stop).FullName
        }
    }

    return ''
}

function Test-SiteMonitoringHostList {
    param([Parameter(Mandatory = $true)][string]$Hosts)

    $hostEntries = @($Hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($hostEntries.Count -eq 0) { return $false }

    foreach ($entry in $hostEntries) {
        $candidate = if ($entry -match '^[A-Za-z][A-Za-z0-9+.-]*://') { $entry } else { "https://$entry" }
        $uri = $null
        if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or [string]::IsNullOrWhiteSpace($uri.Host)) {
            return $false
        }
    }
    return $true
}

function Read-SiteMonitoringHosts {
    while ($true) {
        Write-Host "Site examples: hostname:1200 or akbou.decide4action.com" -ForegroundColor Gray
        Write-Host "For multiple frontend sites, separate entries with a comma. The matching API health endpoint is added automatically." -ForegroundColor Gray
        $hosts = Read-Host "Enter the site address(es), or press Enter for hostname:1200 (q to go back)"
        if (Test-IsBack $hosts) { return $null }
        if ([string]::IsNullOrWhiteSpace($hosts)) { return 'hostname:1200' }

        $hosts = Normalize-UserPath $hosts
        if (Test-SiteMonitoringHostList -Hosts $hosts) {
            return (($hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) -join ',')
        }

        Write-Host "Enter valid host names separated by commas, for example hostname:1200,akbou.decide4action.com." -ForegroundColor Yellow
    }
}

function Read-SiteMonitoringName {
    while ($true) {
        $name = Read-Host "Enter a friendly monitoring name for email subjects, for example Akbou (q to go back)"
        if (Test-IsBack $name) { return $null }
        $name = $name.Trim()
        if (-not [string]::IsNullOrWhiteSpace($name) -and $name -notmatch '[\r\n]') { return $name }
        Write-Host "A friendly monitoring name is required." -ForegroundColor Yellow
    }
}

function Read-SiteMonitoringFolder {
    param([AllowEmptyString()][string]$DefaultFolder)

    while ($true) {
        if (-not [string]::IsNullOrWhiteSpace($DefaultFolder)) {
            Write-Host "Detected default Decide4Action Configuration folder: $DefaultFolder" -ForegroundColor Cyan
            $folder = Read-Host "Press Enter to use this folder, or paste another existing folder path (q to go back)"
            if ([string]::IsNullOrWhiteSpace($folder)) { return $DefaultFolder }
        }
        else {
            Write-Host "No Decide4Action Configuration folder was detected automatically." -ForegroundColor Yellow
            $folder = Read-Host "Paste the existing folder where the monitor and nodemailer will be installed (q to go back)"
        }

        if (Test-IsBack $folder) { return $null }
        $folder = Normalize-UserPath $folder
        if (Test-Path -LiteralPath $folder -PathType Container) {
            return (Get-Item -LiteralPath $folder -ErrorAction Stop).FullName
        }
        Write-Host "Folder not found. Enter an existing folder path or type q to go back." -ForegroundColor Yellow
    }
}

function Test-SiteMonitoringEmailAddresses {
    param([Parameter(Mandatory = $true)][string]$Addresses)

    $items = @($Addresses -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($items.Count -eq 0) { return $false }
    foreach ($item in $items) {
        try {
            $parsed = [Net.Mail.MailAddress]::new($item)
            if ($parsed.Address -ine $item) { return $false }
        }
        catch { return $false }
    }
    return $true
}

function Read-SiteMonitoringEmailAddresses {
    $defaultAddress = 'techsupport@decide4action.com'
    while ($true) {
        Write-Host "You can enter multiple email addresses separated by commas." -ForegroundColor Gray
        $addresses = Read-Host "Notification email address(es) (default: $defaultAddress; q to go back)"
        if (Test-IsBack $addresses) { return $null }
        if ([string]::IsNullOrWhiteSpace($addresses)) { return $defaultAddress }
        $addresses = $addresses.Trim()
        if (Test-SiteMonitoringEmailAddresses -Addresses $addresses) {
            return (($addresses -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ',')
        }
        Write-Host "Enter valid email addresses separated by commas." -ForegroundColor Yellow
    }
}

function ConvertTo-PowerShellSingleQuotedText {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '' }
    return $Value.Replace("'", "''")
}

function Get-SiteMonitoringScriptMetadata {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $content = Get-Content -LiteralPath $ScriptPath -Raw -ErrorAction Stop
    $versionText = ''
    $releaseDateText = ''
    if ($content -match '(?m)^#\s*D4A-Monitor-Version:\s*(?<Value>[^\r\n]+)') {
        $versionText = $matches.Value.Trim()
    }
    if ($content -match '(?m)^#\s*D4A-Monitor-Release-Date:\s*(?<Value>[^\r\n]+)') {
        $releaseDateText = $matches.Value.Trim()
    }

    $parsedVersion = $null
    if (-not [string]::IsNullOrWhiteSpace($versionText)) {
        try { $parsedVersion = [version]$versionText } catch { $parsedVersion = $null }
    }
    if ($null -eq $parsedVersion -and ([IO.Path]::GetFileNameWithoutExtension($ScriptPath) -match '(?i)-v(?<Value>\d+(?:\.\d+){0,3})$')) {
        $versionText = $matches.Value
        try { $parsedVersion = [version]$versionText } catch { $parsedVersion = $null }
    }

    [pscustomobject]@{
        ScriptPath       = (Get-Item -LiteralPath $ScriptPath -ErrorAction Stop).FullName
        FileName         = [IO.Path]::GetFileName($ScriptPath)
        VersionText      = if ([string]::IsNullOrWhiteSpace($versionText)) { 'Unknown' } else { $versionText }
        Version          = $parsedVersion
        ReleaseDate      = if ([string]::IsNullOrWhiteSpace($releaseDateText)) { 'Unknown' } else { $releaseDateText }
        HasVersionHeader = $null -ne $parsedVersion -and -not [string]::IsNullOrWhiteSpace($releaseDateText)
    }
}

function Get-SiteMonitoringTemplatePath {
    $scriptFolder = Get-CurrentScriptFolder
    $templates = @(
        Get-ChildItem -LiteralPath $scriptFolder -File -Filter 'D4A-ScheduledMonitor*.ps1' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '(?i)\.bak\.ps1$|_\d{14}\.ps1$' } |
            ForEach-Object {
                try { Get-SiteMonitoringScriptMetadata -ScriptPath $_.FullName } catch { $null }
            } |
            Where-Object { $null -ne $_.Version }
    )
    if ($templates.Count -eq 0) {
        [void](Get-RequiredScriptFolderFilePath `
            -FileName 'D4A-ScheduledMonitor-v5.ps1' `
            -DownloadUrl 'https://raw.githubusercontent.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools/main/D4A-ScheduledMonitor-v5.ps1' `
            -FeatureName 'Add Site Monitoring')

        $templates = @(
            Get-ChildItem -LiteralPath $scriptFolder -File -Filter 'D4A-ScheduledMonitor*.ps1' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '(?i)\.bak\.ps1$|_\d{14}\.ps1$' } |
                ForEach-Object {
                    try { Get-SiteMonitoringScriptMetadata -ScriptPath $_.FullName } catch { $null }
                } |
                Where-Object { $null -ne $_.Version }
        )
    }
    if ($templates.Count -eq 0) {
        throw "No versioned D4A-ScheduledMonitor PowerShell template was found beside IT Tools: $scriptFolder"
    }

    return ($templates | Sort-Object -Property Version, ScriptPath -Descending | Select-Object -First 1).ScriptPath
}

function Get-SiteMonitoringConfigurationPath {
    param([Parameter(Mandatory = $true)][string]$DeploymentFolder)

    return Join-Path (Join-Path $DeploymentFolder 'monitor-logs') 'D4A-ScheduledMonitor.config.json'
}

function Get-SiteMonitoringInstallRoot {
    param([Parameter(Mandatory = $true)][string]$ConfigurationFolder)

    if ((Split-Path -Leaf $ConfigurationFolder) -ieq 'Configuration') {
        return Split-Path -Parent $ConfigurationFolder
    }

    $detectedConfigurationFolder = Get-DefaultD4AConfigurationFolder
    if (-not [string]::IsNullOrWhiteSpace($detectedConfigurationFolder)) {
        return Split-Path -Parent $detectedConfigurationFolder
    }
    return Split-Path -Parent $ConfigurationFolder
}

function New-SiteMonitoringConfigurationObject {
    param(
        [Parameter(Mandatory = $true)][string]$Hosts,
        [Parameter(Mandatory = $true)][string]$MonitoringName,
        [Parameter(Mandatory = $true)][string]$NotificationAddresses,
        [Parameter(Mandatory = $true)][string]$DeploymentFolder,
        [Parameter(Mandatory = $true)][string]$MonitorVersion
    )

    $installRoot = Get-SiteMonitoringInstallRoot -ConfigurationFolder $DeploymentFolder
    $logDirectory = Join-Path $DeploymentFolder 'monitor-logs'
    [ordered]@{
        ConfigurationVersion = 1
        MonitoringName       = $MonitoringName
        SiteAddress          = @($Hosts -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        NotificationTo       = @($NotificationAddresses -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        D4AInstallRoot       = $installRoot
        LogDirectory        = $logDirectory
        WatchdogLogRoot     = Join-Path $installRoot 'Log\TaskSchedulerOutput'
        NodemailerModulePath = Join-Path $DeploymentFolder 'node_modules\nodemailer'
        LogRetentionDays    = 5
        NginxErrorsPerMinuteThreshold = 20
        NginxConsecutiveMinutes = 2
        DataCollectorConsecutiveFailureThreshold = 3
        DataCollectorLastHealthyWarningMinutes = 5
        DataCollectorLastHealthyCriticalMinutes = 10
        InstalledMonitorVersion = $MonitorVersion
        TaskScheduler       = [ordered]@{
            RecurringTaskName  = 'D4A-ScheduledMonitor'
            FrequencyMinutes   = $null
            DailySummaryTaskName = 'D4A-ScheduledMonitor-DailySummary'
            DailySummaryEnabled = $false
            DailySummaryTime   = $null
        }
    }
}

function Write-SiteMonitoringConfiguration {
    param(
        [Parameter(Mandatory = $true)][object]$Configuration,
        [Parameter(Mandatory = $true)][string]$ConfigurationPath,
        [switch]$AllowOverwrite
    )

    $configurationFolder = Split-Path -Parent $ConfigurationPath
    if (-not (Test-Path -LiteralPath $configurationFolder -PathType Container)) {
        New-Item -ItemType Directory -Path $configurationFolder -Force -ErrorAction Stop | Out-Null
    }
    if ((Test-Path -LiteralPath $ConfigurationPath -PathType Leaf) -and -not $AllowOverwrite.IsPresent) {
        throw "Monitoring configuration already exists and will not be overwritten: $ConfigurationPath"
    }

    $json = $Configuration | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($ConfigurationPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    return $ConfigurationPath
}

function Set-SiteMonitoringDeploymentConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$Hosts,
        [Parameter(Mandatory = $true)][string]$MonitoringName,
        [Parameter(Mandatory = $true)][string]$NotificationAddresses,
        [Parameter(Mandatory = $true)][string]$DeploymentFolder
    )

    $metadata = Get-SiteMonitoringScriptMetadata -ScriptPath $ScriptPath
    if (-not $metadata.HasVersionHeader) {
        throw "The monitor template does not contain valid version and release-date metadata: $ScriptPath"
    }
    $configurationPath = Get-SiteMonitoringConfigurationPath -DeploymentFolder $DeploymentFolder
    $configuration = New-SiteMonitoringConfigurationObject `
        -Hosts $Hosts `
        -MonitoringName $MonitoringName `
        -NotificationAddresses $NotificationAddresses `
        -DeploymentFolder $DeploymentFolder `
        -MonitorVersion $metadata.VersionText
    return Write-SiteMonitoringConfiguration -Configuration $configuration -ConfigurationPath $configurationPath
}

function Install-SiteMonitoringNodemailer {
    param([Parameter(Mandatory = $true)][string]$DeploymentFolder)

    $npmCommand = Get-Command npm.cmd, npm -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $npmCommand) {
        throw "npm was not found. Install Node.js (including npm), then run Add Site Monitoring again."
    }

    $npmPath = $npmCommand.Source
    Write-StreamingLog -Percent 35 -Step "Node.js" -Description "Preparing nodemailer in $DeploymentFolder."
    Invoke-InstallStepWithProgress -Step "nodemailer" -Description "Installing nodemailer in the selected Configuration folder" -StartPercent 40 -EndPercent 75 -ScriptBlock {
        param([pscustomobject]$InstallSettings)
        $ErrorActionPreference = 'Stop'
        Set-Location -LiteralPath $InstallSettings.WorkingFolder
        if (-not (Test-Path -LiteralPath (Join-Path $InstallSettings.WorkingFolder 'package.json') -PathType Leaf)) {
            & $InstallSettings.NpmExecutable 'init' '-y'
            if ($LASTEXITCODE -ne 0) { throw "npm init failed with exit code $LASTEXITCODE." }
        }
        & $InstallSettings.NpmExecutable 'install' 'nodemailer' '--save'
        if ($LASTEXITCODE -ne 0) { throw "npm install nodemailer failed with exit code $LASTEXITCODE." }
    } -Argument ([pscustomobject]@{ WorkingFolder = $DeploymentFolder; NpmExecutable = $npmPath })

    $modulePath = Join-Path $DeploymentFolder 'node_modules\nodemailer'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Container)) {
        throw "npm completed but nodemailer was not found at $modulePath."
    }
}

function Read-SiteMonitoringFrequencyMinutes {
    while ($true) {
        $inputValue = Read-Host "Monitoring frequency in minutes (default: 5; q to skip task creation)"
        if (Test-IsBack $inputValue) { return $null }
        if ([string]::IsNullOrWhiteSpace($inputValue)) { return 5 }
        $minutes = 0
        if ([int]::TryParse($inputValue, [ref]$minutes) -and $minutes -ge 1 -and $minutes -le 1440) { return $minutes }
        Write-Host "Enter a whole number from 1 to 1440." -ForegroundColor Yellow
    }
}

function New-SiteMonitoringScheduledTaskAction {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$ConfigPath,
        [switch]$DailySummary
    )

    # Session 0 and WindowStyle Hidden keep scheduled scans invisible and independent of user sign-in.
    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $arguments += ' -ConfigPath "{0}"' -f $ConfigPath }
    if ($DailySummary.IsPresent) { $arguments += ' -SendDailySummaryEmail' }
    return New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments -WorkingDirectory $WorkingDirectory
}

function New-SiteMonitoringScheduledTaskPrincipal {
    return New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
}

function New-SiteMonitoringScheduledTaskSettings {
    return New-ScheduledTaskSettingsSet -Hidden -StartWhenAvailable
}

function Register-SiteMonitoringTask {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [string]$ConfigPath,
        [int]$FrequencyMinutes = 5,
        [switch]$DailySummary,
        [datetime]$DailyTime
    )

    $action = New-SiteMonitoringScheduledTaskAction -ScriptPath $ScriptPath -WorkingDirectory $WorkingDirectory -ConfigPath $ConfigPath -DailySummary:$DailySummary.IsPresent
    $principal = New-SiteMonitoringScheduledTaskPrincipal
    $settings = New-SiteMonitoringScheduledTaskSettings

    if ($DailySummary.IsPresent) {
        $taskName = 'D4A-ScheduledMonitor-DailySummary'
        $trigger = New-ScheduledTaskTrigger -Daily -At $DailyTime
        $description = 'Sends the daily D4A monitoring and performance summary.'
    }
    else {
        $taskName = 'D4A-ScheduledMonitor'
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $FrequencyMinutes)
        $description = "Runs the D4A monitor every $FrequencyMinutes minute(s)."
    }

    Register-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -TaskName $taskName -Description $description -Force -ErrorAction Stop | Out-Null
    return $taskName
}

function Get-SiteMonitoringTaskScriptPath {
    param([Parameter(Mandatory = $true)][object]$Task)

    $arguments = [string]$Task.Actions[0].Arguments
    if ($arguments -match '(?i)-file\s+"(?<Path>[^"]+)"') {
        return $matches.Path
    }
    if ($arguments -match "(?i)-file\s+'(?<Path>[^']+)'") {
        return $matches.Path
    }
    if ($arguments -match '(?i)-file\s+(?<Path>\S+)') {
        return $matches.Path
    }
    return ''
}

function Get-SiteMonitoringTaskConfigPath {
    param([Parameter(Mandatory = $true)][object]$Task)

    $arguments = [string]$Task.Actions[0].Arguments
    if ($arguments -match '(?i)-configpath\s+"(?<Path>[^"]+)"') { return $matches.Path }
    if ($arguments -match "(?i)-configpath\s+'(?<Path>[^']+)'") { return $matches.Path }
    if ($arguments -match '(?i)-configpath\s+(?<Path>\S+)') { return $matches.Path }
    return ''
}

function Update-SiteMonitoringTaskConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Nullable[int]]$FrequencyMinutes,
        [Nullable[bool]]$DailySummaryEnabled,
        [AllowNull()][string]$DailySummaryTime
    )

    $configuration = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $configuration.TaskScheduler) {
        $configuration | Add-Member -MemberType NoteProperty -Name TaskScheduler -Value ([pscustomobject]@{})
    }
    if ($PSBoundParameters.ContainsKey('FrequencyMinutes')) {
        $configuration.TaskScheduler.FrequencyMinutes = $FrequencyMinutes
    }
    if ($PSBoundParameters.ContainsKey('DailySummaryEnabled')) {
        $configuration.TaskScheduler.DailySummaryEnabled = $DailySummaryEnabled
    }
    if ($PSBoundParameters.ContainsKey('DailySummaryTime')) {
        $configuration.TaskScheduler.DailySummaryTime = $DailySummaryTime
    }
    Write-SiteMonitoringConfiguration -Configuration $configuration -ConfigurationPath $ConfigPath -AllowOverwrite | Out-Null
}

function Show-UpdateSiteMonitoringTasks {
    Clear-Host
    Show-SectionTitle "Update Existing Site Monitoring Tasks"
    Write-Host "This updates existing monitor tasks to run silently as the local SYSTEM account, including when no user is logged in." -ForegroundColor Cyan
    Write-Host "Type q to return to Add Site Monitoring." -ForegroundColor DarkGray

    if (-not $Script:IsAdmin) {
        Write-Host "Administrator rights are required to update tasks to run as SYSTEM. Restart IT Tools with Run as Administrator." -ForegroundColor Yellow
        Pause-Screen
        return
    }

    try {
        $tasks = @(
            foreach ($taskName in @('D4A-ScheduledMonitor', 'D4A-ScheduledMonitor-DailySummary')) {
                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($null -ne $task) { $task }
            }
        )

        if ($tasks.Count -eq 0) {
            Write-Host "No D4A site monitoring tasks were found on this server." -ForegroundColor Yellow
            Pause-Screen
            return
        }

        $preview = @(
            foreach ($task in $tasks) {
                [pscustomobject]@{
                    TaskName        = $task.TaskName
                    CurrentRunAs    = [string]$task.Principal.UserId
                    CurrentArguments = [string]$task.Actions[0].Arguments
                    ScriptPath      = Get-SiteMonitoringTaskScriptPath -Task $task
                }
            }
        )
        Show-ConsoleResults -Data $preview
        Write-Host "The task triggers are preserved. Execution will change to hidden PowerShell under SYSTEM." -ForegroundColor Yellow
        $confirmation = Read-Host "Type UPDATE to apply this change"
        if (Test-IsBack $confirmation -or $confirmation -cne 'UPDATE') {
            Write-Host "Task update cancelled. No scheduled task was changed." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        $principal = New-SiteMonitoringScheduledTaskPrincipal
        $settings = New-SiteMonitoringScheduledTaskSettings
        $updatedCount = 0
        foreach ($task in $tasks) {
            $scriptPath = Get-SiteMonitoringTaskScriptPath -Task $task
            if ([string]::IsNullOrWhiteSpace($scriptPath) -or -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
                throw "Could not find the monitor script for scheduled task $($task.TaskName): $scriptPath"
            }

            $workingDirectory = [string]$task.Actions[0].WorkingDirectory
            if ([string]::IsNullOrWhiteSpace($workingDirectory) -or -not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
                $workingDirectory = Split-Path -Parent $scriptPath
            }
            $isDailySummary = $task.TaskName -ieq 'D4A-ScheduledMonitor-DailySummary'
            $configPath = Get-SiteMonitoringTaskConfigPath -Task $task
            if ([string]::IsNullOrWhiteSpace($configPath)) {
                $candidateConfigPath = Get-SiteMonitoringConfigurationPath -DeploymentFolder $workingDirectory
                if (Test-Path -LiteralPath $candidateConfigPath -PathType Leaf) { $configPath = $candidateConfigPath }
            }
            $action = New-SiteMonitoringScheduledTaskAction -ScriptPath $scriptPath -WorkingDirectory $workingDirectory -ConfigPath $configPath -DailySummary:$isDailySummary
            Write-StreamingLog -Percent (65 + ($updatedCount * 20)) -Step "Schedule" -Description "Updating $($task.TaskName) to run silently under SYSTEM."
            Set-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
            Write-Host "Success: $($task.TaskName) now runs silently under SYSTEM." -ForegroundColor Green
            $updatedCount++
        }
    }
    catch {
        Show-LoggedError -Prefix "Scheduled task update did not complete" -Context "Add Site Monitoring - update existing scheduled tasks" -ErrorRecord $_
    }

    Pause-Screen
}

function Get-SiteMonitoringLegacySettings {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$DeploymentFolder,
        [Parameter(Mandatory = $true)][string]$MonitorVersion
    )

    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "The installed monitor cannot be parsed to migrate its settings: $($parseErrors[0].Message)"
    }

    $defaults = @{}
    foreach ($parameter in @($ast.ParamBlock.Parameters)) {
        $name = $parameter.Name.VariablePath.UserPath
        if ($null -eq $parameter.DefaultValue) { continue }
        try { $defaults[$name] = $parameter.DefaultValue.SafeGetValue() } catch { }
    }

    $hosts = if ([string]::IsNullOrWhiteSpace([string]$defaults.SiteAddress)) { 'hostname:1200' } else { [string]$defaults.SiteAddress }
    $monitoringName = if ([string]::IsNullOrWhiteSpace([string]$defaults.MonitoringName)) { $env:COMPUTERNAME } else { [string]$defaults.MonitoringName }
    $notificationTo = if ([string]::IsNullOrWhiteSpace([string]$defaults.NotificationTo)) { 'techsupport@decide4action.com' } else { [string]$defaults.NotificationTo }
    $configuration = New-SiteMonitoringConfigurationObject `
        -Hosts $hosts `
        -MonitoringName $monitoringName `
        -NotificationAddresses $notificationTo `
        -DeploymentFolder $DeploymentFolder `
        -MonitorVersion $MonitorVersion

    foreach ($settingName in @(
        'LogDirectory', 'WatchdogLogRoot', 'D4AInstallRoot', 'NginxErrorLog', 'DbConfigPath',
        'NodeExecutable', 'NodemailerModulePath', 'FromAddress', 'LogRetentionDays',
        'WatchdogLogTailLines', 'EmailTimeoutSeconds', 'SmtpServer', 'SmtpPort',
        'SmtpUseSsl', 'SmtpCredentialFile', 'HttpTimeoutSeconds', 'ApplicationAttempts',
        'ApplicationWarningMs', 'ApplicationAlertMs', 'CpuSampleDurationSeconds',
        'CpuSampleIntervalSeconds', 'LogLookbackMinutes', 'DiagnosticTailLines',
        'NginxErrorsPerMinuteThreshold', 'NginxConsecutiveMinutes',
        'DataCollectorConsecutiveFailureThreshold', 'DataCollectorLastHealthyWarningMinutes',
        'DataCollectorLastHealthyCriticalMinutes', 'MaxRedirects'
    )) {
        if ($defaults.ContainsKey($settingName) -and $null -ne $defaults[$settingName] -and -not [string]::IsNullOrWhiteSpace([string]$defaults[$settingName])) {
            $configuration[$settingName] = $defaults[$settingName]
        }
    }
    return $configuration
}

function Get-SiteMonitoringScheduleMetadata {
    param([object[]]$Tasks)

    $frequencyMinutes = $null
    $dailyEnabled = $false
    $dailyTime = $null
    foreach ($task in @($Tasks)) {
        if ($task.TaskName -ieq 'D4A-ScheduledMonitor') {
            $interval = [string]$task.Triggers[0].Repetition.Interval
            if (-not [string]::IsNullOrWhiteSpace($interval)) {
                try { $frequencyMinutes = [int][Math]::Round([Xml.XmlConvert]::ToTimeSpan($interval).TotalMinutes) } catch { }
            }
        }
        elseif ($task.TaskName -ieq 'D4A-ScheduledMonitor-DailySummary') {
            $dailyEnabled = $true
            $startBoundary = [string]$task.Triggers[0].StartBoundary
            if (-not [string]::IsNullOrWhiteSpace($startBoundary)) {
                $parsedTime = [datetime]::MinValue
                if ([datetime]::TryParse($startBoundary, [ref]$parsedTime)) { $dailyTime = $parsedTime.ToString('HH:mm') }
            }
        }
    }

    [pscustomobject]@{
        FrequencyMinutes   = $frequencyMinutes
        DailySummaryEnabled = $dailyEnabled
        DailySummaryTime   = $dailyTime
    }
}

function Test-PowerShellScriptParser {
    param([Parameter(Mandatory = $true)][string]$ScriptPath)

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "PowerShell parser validation failed for '$ScriptPath': $($parseErrors[0].Message)"
    }
}

function Invoke-SiteMonitoringVersionUpdate {
    param(
        [Parameter(Mandatory = $true)][string]$InstalledScriptPath,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [object[]]$RelatedTasks = @()
    )

    $deploymentFolder = Split-Path -Parent $InstalledScriptPath
    $templateMetadata = Get-SiteMonitoringScriptMetadata -ScriptPath $TemplatePath
    $installedMetadata = Get-SiteMonitoringScriptMetadata -ScriptPath $InstalledScriptPath
    if ($null -ne $installedMetadata.Version -and $installedMetadata.Version -gt $templateMetadata.Version) {
        throw "Installed monitor version $($installedMetadata.VersionText) is newer than template version $($templateMetadata.VersionText). Downgrade blocked."
    }
    $configurationPath = Get-SiteMonitoringConfigurationPath -DeploymentFolder $deploymentFolder
    foreach ($task in @($RelatedTasks)) {
        $taskConfigPath = Get-SiteMonitoringTaskConfigPath -Task $task
        if (-not [string]::IsNullOrWhiteSpace($taskConfigPath)) {
            $configurationPath = $taskConfigPath
            break
        }
    }

    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $backupFolder = Join-Path (Join-Path $deploymentFolder 'monitor-backups') $stamp
    New-Item -ItemType Directory -Path $backupFolder -Force -ErrorAction Stop | Out-Null
    $scriptBackupPath = Join-Path $backupFolder ([IO.Path]::GetFileName($InstalledScriptPath))
    Copy-Item -LiteralPath $InstalledScriptPath -Destination $scriptBackupPath -ErrorAction Stop
    $configurationExisted = Test-Path -LiteralPath $configurationPath -PathType Leaf
    $configurationBackupPath = $null
    if ($configurationExisted) {
        $configurationBackupPath = Join-Path $backupFolder ([IO.Path]::GetFileName($configurationPath))
        Copy-Item -LiteralPath $configurationPath -Destination $configurationBackupPath -ErrorAction Stop
    }
    foreach ($task in @($RelatedTasks)) {
        try {
            $taskXml = Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction Stop
            $taskBackupPath = Join-Path $backupFolder ('ScheduledTask_{0}.xml' -f ($task.TaskName -replace '[^A-Za-z0-9_.-]', '_'))
            [IO.File]::WriteAllText($taskBackupPath, [string]$taskXml, [Text.UTF8Encoding]::new($false))
        }
        catch {
            throw "Unable to back up scheduled task '$($task.TaskName)': $($_.Exception.Message)"
        }
    }

    $temporaryScriptPath = Join-Path $deploymentFolder ('.{0}.{1}.update.tmp.ps1' -f [IO.Path]::GetFileNameWithoutExtension($InstalledScriptPath), $stamp)
    $scriptReplaced = $false
    try {
        Write-StreamingLog -Percent 25 -Step 'Backup' -Description "Backed up the monitor, configuration, and task definitions to $backupFolder."
        if (-not $configurationExisted) {
            Write-StreamingLog -Percent 40 -Step 'Migrate' -Description 'Migrating legacy settings embedded in the installed monitor to JSON.'
            $configuration = Get-SiteMonitoringLegacySettings `
                -ScriptPath $InstalledScriptPath `
                -DeploymentFolder $deploymentFolder `
                -MonitorVersion $templateMetadata.VersionText
            $scheduleMetadata = Get-SiteMonitoringScheduleMetadata -Tasks $RelatedTasks
            $configuration.TaskScheduler.FrequencyMinutes = $scheduleMetadata.FrequencyMinutes
            $configuration.TaskScheduler.DailySummaryEnabled = $scheduleMetadata.DailySummaryEnabled
            $configuration.TaskScheduler.DailySummaryTime = $scheduleMetadata.DailySummaryTime
            Write-SiteMonitoringConfiguration -Configuration $configuration -ConfigurationPath $configurationPath | Out-Null
        }

        Write-StreamingLog -Percent 55 -Step 'Stage' -Description 'Staging and parsing the new monitoring script.'
        Copy-Item -LiteralPath $TemplatePath -Destination $temporaryScriptPath -Force -ErrorAction Stop
        Unblock-File -LiteralPath $temporaryScriptPath -ErrorAction Stop
        Test-PowerShellScriptParser -ScriptPath $temporaryScriptPath

        Write-StreamingLog -Percent 70 -Step 'Validate' -Description 'Validating the existing site configuration with the new monitor version.'
        $validationOutput = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $temporaryScriptPath -ConfigPath $configurationPath -ValidateConfiguration 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "The new monitor rejected the existing configuration: $($validationOutput -join ' ')"
        }

        Write-StreamingLog -Percent 85 -Step 'Update' -Description "Replacing monitor code while preserving the installed filename $([IO.Path]::GetFileName($InstalledScriptPath))."
        Copy-Item -LiteralPath $temporaryScriptPath -Destination $InstalledScriptPath -Force -ErrorAction Stop
        Unblock-File -LiteralPath $InstalledScriptPath -ErrorAction Stop
        $scriptReplaced = $true
        Test-PowerShellScriptParser -ScriptPath $InstalledScriptPath

        $configuration = Get-Content -LiteralPath $configurationPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $configuration.PSObject.Properties['InstalledMonitorVersion']) {
            $configuration | Add-Member -MemberType NoteProperty -Name InstalledMonitorVersion -Value $templateMetadata.VersionText
        }
        else { $configuration.InstalledMonitorVersion = $templateMetadata.VersionText }
        if ($null -eq $configuration.PSObject.Properties['LastMonitorUpdate']) {
            $configuration | Add-Member -MemberType NoteProperty -Name LastMonitorUpdate -Value (Get-Date).ToString('o')
        }
        else { $configuration.LastMonitorUpdate = (Get-Date).ToString('o') }
        Write-SiteMonitoringConfiguration -Configuration $configuration -ConfigurationPath $configurationPath -AllowOverwrite | Out-Null

        Write-StreamingLog -Percent 100 -Step 'Done' -Description "Monitoring version $($templateMetadata.VersionText) installed successfully."
        return [pscustomobject]@{
            ScriptPath        = $InstalledScriptPath
            ConfigurationPath = $configurationPath
            Version           = $templateMetadata.VersionText
            ReleaseDate       = $templateMetadata.ReleaseDate
            BackupFolder      = $backupFolder
            TaskCount         = @($RelatedTasks).Count
        }
    }
    catch {
        if ($scriptReplaced -and (Test-Path -LiteralPath $scriptBackupPath -PathType Leaf)) {
            Copy-Item -LiteralPath $scriptBackupPath -Destination $InstalledScriptPath -Force -ErrorAction SilentlyContinue
        }
        if ($configurationExisted -and -not [string]::IsNullOrWhiteSpace($configurationBackupPath)) {
            Copy-Item -LiteralPath $configurationBackupPath -Destination $configurationPath -Force -ErrorAction SilentlyContinue
        }
        elseif (-not $configurationExisted -and (Test-Path -LiteralPath $configurationPath -PathType Leaf)) {
            $failedConfigurationPath = Join-Path $backupFolder 'failed_D4A-ScheduledMonitor.config.json'
            Move-Item -LiteralPath $configurationPath -Destination $failedConfigurationPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $temporaryScriptPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Show-UpdateSiteMonitoringVersion {
    Clear-Host
    Show-SectionTitle 'Monitoring Version Update'
    Write-Host 'Updates monitor code while preserving site addresses, recipients, logs, ignore rules, filenames, and Scheduled Task triggers.' -ForegroundColor Cyan
    Write-Host 'Legacy settings embedded in the installed script are migrated once to monitor-logs\D4A-ScheduledMonitor.config.json.' -ForegroundColor Gray
    Write-Host 'Type q to return to Add Site Monitoring.' -ForegroundColor DarkGray

    if (-not $Script:IsAdmin) {
        Write-Host 'Administrator rights are required to update production monitor files and back up Scheduled Tasks.' -ForegroundColor Yellow
        Pause-Screen
        return
    }

    try {
        $templatePath = Get-SiteMonitoringTemplatePath
        $templateMetadata = Get-SiteMonitoringScriptMetadata -ScriptPath $templatePath
        $tasks = @(
            foreach ($taskName in @('D4A-ScheduledMonitor', 'D4A-ScheduledMonitor-DailySummary')) {
                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                if ($null -ne $task) { $task }
            }
        )
        $candidatePaths = @(
            $tasks | ForEach-Object { Get-SiteMonitoringTaskScriptPath -Task $_ } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
                Select-Object -Unique
        )
        if ($candidatePaths.Count -eq 0) {
            $defaultFolder = Get-DefaultD4AConfigurationFolder
            $deploymentFolder = Read-SiteMonitoringFolder -DefaultFolder $defaultFolder
            if ($null -eq $deploymentFolder) { return }
            $candidatePaths = @(
                Get-ChildItem -LiteralPath $deploymentFolder -File -Filter 'D4A-ScheduledMonitor*.ps1' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notmatch '(?i)\.bak\.ps1$|_\d{14}\.ps1$' } |
                    Select-Object -ExpandProperty FullName
            )
        }
        if ($candidatePaths.Count -eq 0) {
            Write-Host 'No installed D4A monitoring script was found.' -ForegroundColor Yellow
            Pause-Screen
            return
        }

        $candidates = @($candidatePaths | ForEach-Object { Get-SiteMonitoringScriptMetadata -ScriptPath $_ })
        $selected = $candidates[0]
        if ($candidates.Count -gt 1) {
            for ($index = 0; $index -lt $candidates.Count; $index++) {
                Write-Host ('{0}) {1} | version {2} | released {3}' -f ($index + 1), $candidates[$index].ScriptPath, $candidates[$index].VersionText, $candidates[$index].ReleaseDate)
            }
            while ($true) {
                $selection = Read-Host 'Select the installed monitor to update (q to go back)'
                if (Test-IsBack $selection) { return }
                $selectedNumber = 0
                if ([int]::TryParse($selection, [ref]$selectedNumber) -and $selectedNumber -ge 1 -and $selectedNumber -le $candidates.Count) {
                    $selected = $candidates[$selectedNumber - 1]
                    break
                }
                Write-Host 'Select one of the displayed monitor numbers.' -ForegroundColor Yellow
            }
        }

        $relatedTasks = @($tasks | Where-Object { (Get-SiteMonitoringTaskScriptPath -Task $_) -ieq $selected.ScriptPath })
        if (@($relatedTasks | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
            throw 'A related monitoring task is currently running. Wait for it to finish, then start the version update again.'
        }
        if ($null -ne $selected.Version -and $selected.Version -gt $templateMetadata.Version) {
            Write-Host "The installed monitor version $($selected.VersionText) is newer than the available template $($templateMetadata.VersionText)." -ForegroundColor Yellow
            Write-Host 'The update was blocked to prevent a monitoring downgrade.' -ForegroundColor Yellow
            Pause-Screen
            return
        }
        if ($selected.HasVersionHeader -and $null -ne $selected.Version -and $templateMetadata.Version -le $selected.Version) {
            Write-Host "The installed monitor is already version $($selected.VersionText), released $($selected.ReleaseDate)." -ForegroundColor Green
            Write-Host "Available template: version $($templateMetadata.VersionText), released $($templateMetadata.ReleaseDate)." -ForegroundColor Gray
            Pause-Screen
            return
        }

        $configurationPath = Get-SiteMonitoringConfigurationPath -DeploymentFolder (Split-Path -Parent $selected.ScriptPath)
        Show-SectionTitle 'Monitoring Update Summary'
        Write-Host "Installed file: $($selected.ScriptPath)" -ForegroundColor White
        Write-Host "Installed version: $($selected.VersionText)" -ForegroundColor White
        Write-Host "Installed release date: $($selected.ReleaseDate)" -ForegroundColor White
        Write-Host "Available version: $($templateMetadata.VersionText)" -ForegroundColor Green
        Write-Host "Available release date: $($templateMetadata.ReleaseDate)" -ForegroundColor Green
        Write-Host "Configuration: $configurationPath" -ForegroundColor White
        Write-Host "Related Scheduled Tasks: $($relatedTasks.Count); their triggers and frequency will not be replaced." -ForegroundColor Gray
        $confirmation = Read-Host 'Type UPDATE to back up and update this monitor (q to go back)'
        if (Test-IsBack $confirmation -or $confirmation -cne 'UPDATE') {
            Write-Host 'Monitoring version update cancelled. No files or tasks were changed.' -ForegroundColor Cyan
            Pause-Screen
            return
        }

        $result = Invoke-SiteMonitoringVersionUpdate -InstalledScriptPath $selected.ScriptPath -TemplatePath $templatePath -RelatedTasks $relatedTasks
        Write-Host "Success: monitoring version $($result.Version), released $($result.ReleaseDate), is installed." -ForegroundColor Green
        Write-Host "Monitor file preserved: $($result.ScriptPath)" -ForegroundColor Green
        Write-Host "Site configuration preserved: $($result.ConfigurationPath)" -ForegroundColor Green
        Write-Host "Backup folder: $($result.BackupFolder)" -ForegroundColor Green
        Write-Host 'Scheduled Task triggers, frequency, principal, and task names were preserved.' -ForegroundColor Green
    }
    catch {
        Show-LoggedError -Prefix 'Monitoring version update did not complete' -Context 'Add Site Monitoring - version update' -ErrorRecord $_
    }
    Pause-Screen
}

function Invoke-SiteMonitoringFirstTest {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$ConfigPath
    )

    Write-StreamingLog -Percent 95 -Step "Test" -Description "Running the first monitoring test and sending an email even when healthy."
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath)
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $arguments += @('-ConfigPath', $ConfigPath) }
    $arguments += @('-CpuSampleDurationSeconds', '60', '-SendTestResultsEmail')
    & powershell.exe @arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        Write-Host "Test run completed successfully. Check the selected notification mailbox." -ForegroundColor Green
    }
    else {
        Write-Host "Test run completed with monitor status $exitCode. The monitor log contains the health results and email delivery details." -ForegroundColor Yellow
    }
}

function Show-AddSiteMonitoring {
    Clear-Host
    Show-SectionTitle "Add Site Monitoring"
    Write-Host "Create a scheduled D4A site and server health monitor that sends email notifications when issues are detected." -ForegroundColor Cyan
    Write-Host "The monitor checks selected frontend site(s), their API endpoint(s), local D4A services, performance, disk space, logs, and relevant Windows events." -ForegroundColor Gray
    Write-Host "Type q at any prompt to return to the previous menu." -ForegroundColor DarkGray
    if (-not $Script:IsAdmin) {
        Write-Host "Note: Administrator rights are required when creating scheduled tasks that run silently as SYSTEM." -ForegroundColor Yellow
    }
    try {
        $availableMonitorTemplate = Get-SiteMonitoringTemplatePath
        $availableMonitorMetadata = Get-SiteMonitoringScriptMetadata -ScriptPath $availableMonitorTemplate
        Write-Host "Available monitoring version: $($availableMonitorMetadata.VersionText) | Release date: $($availableMonitorMetadata.ReleaseDate)" -ForegroundColor Green
    }
    catch {
        Write-Host 'Available monitoring version could not be determined. Deployment and updates will report the detailed error.' -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "1) Deploy a new site monitor"
    Write-Host "2) Update monitoring script version"
    Write-Host "3) Update existing monitor tasks to run silently in the background"
    Write-Host "q) Back to the main menu"
    $monitoringChoice = Read-Host "Choose an option"
    if (Test-IsBack $monitoringChoice) { return }
    if ($monitoringChoice -eq '2') {
        Show-UpdateSiteMonitoringVersion
        return
    }
    if ($monitoringChoice -eq '3') {
        Show-UpdateSiteMonitoringTasks
        return
    }
    if ($monitoringChoice -ne '1') {
        Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
        Pause-Screen
        return
    }

    try {
        $templatePath = Get-SiteMonitoringTemplatePath
        $templateMetadata = Get-SiteMonitoringScriptMetadata -ScriptPath $templatePath

        $hosts = Read-SiteMonitoringHosts
        if ($null -eq $hosts) { return }
        $monitoringName = Read-SiteMonitoringName
        if ($null -eq $monitoringName) { return }

        Write-StreamingLog -Percent 10 -Step "Detect" -Description "Looking for the Decide4Action Configuration folder from the Windows service."
        $defaultFolder = Get-DefaultD4AConfigurationFolder
        $deploymentFolder = Read-SiteMonitoringFolder -DefaultFolder $defaultFolder
        if ($null -eq $deploymentFolder) { return }

        $emailAddresses = Read-SiteMonitoringEmailAddresses
        if ($null -eq $emailAddresses) { return }

        $targetScriptPath = Join-Path $deploymentFolder ([IO.Path]::GetFileName($templatePath))
        $configurationPath = Get-SiteMonitoringConfigurationPath -DeploymentFolder $deploymentFolder
        Show-SectionTitle "Monitoring Deployment Summary"
        Write-Host "Monitor version: $($templateMetadata.VersionText)" -ForegroundColor White
        Write-Host "Monitor release date: $($templateMetadata.ReleaseDate)" -ForegroundColor White
        Write-Host "Site address(es): $hosts" -ForegroundColor White
        Write-Host "Friendly monitoring name: $monitoringName" -ForegroundColor White
        Write-Host "Notification email(s): $emailAddresses" -ForegroundColor White
        Write-Host "Deployment folder: $deploymentFolder" -ForegroundColor White
        Write-Host "Monitor file: $targetScriptPath" -ForegroundColor White
        Write-Host "Configuration file: $configurationPath" -ForegroundColor White
        Write-Host "Automatic alert cooldown: 24 hours per issue; resolved issues are automatically removed." -ForegroundColor Gray

        if (Test-Path -LiteralPath $targetScriptPath -PathType Leaf) {
            throw "A monitor file already exists at $targetScriptPath. Choose another folder or move the existing monitor first; existing monitoring configuration is not overwritten."
        }

        $confirmation = Read-Host "Type DEPLOY to copy, configure, unblock the monitor, and install nodemailer"
        if (Test-IsBack $confirmation -or $confirmation -cne 'DEPLOY') {
            Write-Host "Deployment cancelled. No files, packages, or tasks were changed." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        Write-StreamingLog -Percent 20 -Step "Copy" -Description "Copying the monitoring template to $deploymentFolder."
        Copy-Item -LiteralPath $templatePath -Destination $targetScriptPath -ErrorAction Stop
        Unblock-File -LiteralPath $targetScriptPath -ErrorAction Stop
        Write-StreamingLog -Percent 30 -Step "Configure" -Description "Creating the site-specific JSON configuration under monitor-logs."
        $configurationPath = Set-SiteMonitoringDeploymentConfiguration -ScriptPath $targetScriptPath -Hosts $hosts -MonitoringName $monitoringName -NotificationAddresses $emailAddresses -DeploymentFolder $deploymentFolder
        Install-SiteMonitoringNodemailer -DeploymentFolder $deploymentFolder

        Write-Host "Site monitoring script created successfully: $targetScriptPath" -ForegroundColor Green
        Write-Host "Site configuration created successfully: $configurationPath" -ForegroundColor Green
        Write-Host "nodemailer is installed in: $deploymentFolder" -ForegroundColor Green

        $frequencyMinutes = Read-SiteMonitoringFrequencyMinutes
        if ($null -eq $frequencyMinutes) {
            Pause-Screen
            return
        }
        Write-Host "The task will run every $frequencyMinutes minute(s): $targetScriptPath" -ForegroundColor Yellow
        $taskConfirmation = Read-Host "Type CREATE to create or replace the recurring monitoring task"
        if ($taskConfirmation -ceq 'CREATE') {
            Write-StreamingLog -Percent 82 -Step "Schedule" -Description "Creating the recurring D4A monitoring task."
            $taskName = Register-SiteMonitoringTask -ScriptPath $targetScriptPath -WorkingDirectory $deploymentFolder -ConfigPath $configurationPath -FrequencyMinutes $frequencyMinutes
            Update-SiteMonitoringTaskConfiguration -ConfigPath $configurationPath -FrequencyMinutes $frequencyMinutes
            Write-Host "Scheduled task created: $taskName" -ForegroundColor Green
        }
        elseif (Test-IsBack $taskConfirmation) {
            Pause-Screen
            return
        }
        else {
            Write-Host "Recurring task creation skipped. The monitoring script remains configured and can be scheduled later." -ForegroundColor Yellow
        }

        $dailyChoice = Read-Host "Create a daily performance email even when healthy? Type Y to create it, or press Enter to skip"
        if (Test-IsBack $dailyChoice) {
            Pause-Screen
            return
        }
        if ($dailyChoice -match '^(?i)y(?:es)?$') {
            while ($true) {
                $timeInput = Read-Host "Daily email server time (default: 02:00; q to skip)"
                if (Test-IsBack $timeInput) {
                    Pause-Screen
                    return
                }
                if ([string]::IsNullOrWhiteSpace($timeInput)) { $timeInput = '02:00' }
                $dailyTime = [datetime]::MinValue
                if ([datetime]::TryParse($timeInput, [ref]$dailyTime)) {
                    Write-StreamingLog -Percent 88 -Step "Schedule" -Description "Creating the daily monitoring summary task at $($dailyTime.ToString('HH:mm'))."
                    $dailyTaskName = Register-SiteMonitoringTask -ScriptPath $targetScriptPath -WorkingDirectory $deploymentFolder -ConfigPath $configurationPath -DailySummary -DailyTime $dailyTime
                    Update-SiteMonitoringTaskConfiguration -ConfigPath $configurationPath -DailySummaryEnabled $true -DailySummaryTime $dailyTime.ToString('HH:mm')
                    Write-Host "Daily summary task created: $dailyTaskName" -ForegroundColor Green
                    break
                }
                Write-Host "Enter a valid time, for example 02:00 or 2:00 AM." -ForegroundColor Yellow
            }
        }

        $testConfirmation = Read-Host "Type TEST to run the first 60-second monitoring test and send an email even when healthy"
        if ($testConfirmation -ceq 'TEST') {
            Invoke-SiteMonitoringFirstTest -ScriptPath $targetScriptPath -ConfigPath $configurationPath
        }
        elseif (Test-IsBack $testConfirmation) {
            Pause-Screen
            return
        }
        else {
            Write-Host "First email test skipped. Run it later with -SendTestResultsEmail." -ForegroundColor Yellow
        }

        Write-StreamingLog -Percent 100 -Step "Done" -Description "Site monitoring deployment completed."
    }
    catch {
        Show-LoggedError -Prefix "Site monitoring setup did not complete" -Context "Main menu - Add Site Monitoring" -ErrorRecord $_
    }

    Pause-Screen
}

function Get-SiteMonitoringCommandTargets {
    $tasks = @(
        foreach ($taskName in @('D4A-ScheduledMonitor', 'D4A-ScheduledMonitor-DailySummary')) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($null -ne $task) { $task }
        }
    )
    $candidatePaths = @(
        $tasks | ForEach-Object { Get-SiteMonitoringTaskScriptPath -Task $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } |
            Sort-Object -Unique
    )

    if ($candidatePaths.Count -eq 0) {
        Write-Host 'No installed monitor was found from Scheduled Tasks.' -ForegroundColor Yellow
        $defaultFolder = Get-DefaultD4AConfigurationFolder
        $deploymentFolder = Read-SiteMonitoringFolder -DefaultFolder $defaultFolder
        if ($null -eq $deploymentFolder) { return @() }
        $candidatePaths = @(
            Get-ChildItem -LiteralPath $deploymentFolder -File -Filter 'D4A-ScheduledMonitor*.ps1' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch '(?i)\.bak\.ps1$|_\d{14}\.ps1$' } |
                Select-Object -ExpandProperty FullName
        )
    }

    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($candidatePath in $candidatePaths) {
        $metadata = Get-SiteMonitoringScriptMetadata -ScriptPath $candidatePath
        $relatedTasks = @($tasks | Where-Object { (Get-SiteMonitoringTaskScriptPath -Task $_) -ieq $metadata.ScriptPath })
        $taskConfigPath = @($relatedTasks | ForEach-Object { Get-SiteMonitoringTaskConfigPath -Task $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1)
        $configPath = if ($taskConfigPath.Count -gt 0) { [string]$taskConfigPath[0] } else { Get-SiteMonitoringConfigurationPath -DeploymentFolder (Split-Path -Parent $metadata.ScriptPath) }
        $targets.Add([pscustomobject]@{
                ScriptPath = $metadata.ScriptPath
                ConfigPath = $configPath
                Version    = $metadata.VersionText
                ReleaseDate = $metadata.ReleaseDate
                ConfigExists = Test-Path -LiteralPath $configPath -PathType Leaf
            }) | Out-Null
    }

    # Convert the generic list explicitly; wrapping it with @() fails in Windows PowerShell 5.1.
    return $targets.ToArray()
}

function Select-SiteMonitoringCommandTarget {
    $targets = @(Get-SiteMonitoringCommandTargets)
    if ($targets.Count -eq 0) {
        Write-Host 'No installed D4A monitoring script was found.' -ForegroundColor Yellow
        Pause-Screen
        return $null
    }

    if ($targets.Count -eq 1) { return $targets[0] }

    Write-Host ''
    Write-Host 'Installed monitoring scripts:' -ForegroundColor Cyan
    for ($index = 0; $index -lt $targets.Count; $index++) {
        $target = $targets[$index]
        $configStatus = if ($target.ConfigExists) { 'configuration found' } else { 'configuration missing' }
        Write-Host "[$($index + 1)] $($target.ScriptPath) | v$($target.Version) | $configStatus"
    }

    while ($true) {
        $selection = Read-Host 'Select a monitor (q to go back)'
        if (Test-IsBack $selection) { return $null }
        $number = 0
        if ([int]::TryParse($selection, [ref]$number) -and $number -ge 1 -and $number -le $targets.Count) {
            return $targets[$number - 1]
        }
        Write-Host 'Select one of the displayed monitor numbers.' -ForegroundColor Yellow
    }
}

function Get-SiteMonitoringCommandText {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [string[]]$ArgumentList = @()
    )

    $parts = @('powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $Target.ScriptPath), '-ConfigPath', ('"{0}"' -f $Target.ConfigPath))
    foreach ($argument in $ArgumentList) {
        if ($argument -match '\s') { $parts += ('"{0}"' -f $argument) } else { $parts += $argument }
    }
    return ($parts -join ' ')
}

function Invoke-SiteMonitoringCommand {
    param(
        [Parameter(Mandatory = $true)][object]$Target,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Description,
        [string[]]$ArgumentList = @()
    )

    Clear-Host
    Show-SectionTitle $Title
    Write-Host $Description -ForegroundColor Cyan
    Write-Host "Monitor file: $($Target.ScriptPath)" -ForegroundColor Gray
    Write-Host "Configuration: $($Target.ConfigPath)" -ForegroundColor Gray
    Write-Host 'Command:' -ForegroundColor Cyan
    Write-Host (Get-SiteMonitoringCommandText -Target $Target -ArgumentList $ArgumentList) -ForegroundColor Yellow
    $confirmation = Read-Host 'Press Enter to run this command, or type q to go back'
    if (Test-IsBack $confirmation) { return }

    Write-StreamingLog -Percent 20 -Step 'Monitor command' -Description 'Running the selected monitoring command.'
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Target.ScriptPath, '-ConfigPath', $Target.ConfigPath) + $ArgumentList
    $output = @(& powershell.exe @arguments 2>&1)
    foreach ($line in $output) { Write-Host $line }
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 1) {
        # The monitor reserves exit code 1 for completed runs containing warnings.
        Write-Host 'Monitoring completed with warnings. Review the monitor run log for details.' -ForegroundColor Yellow
        Write-StreamingLog -Percent 100 -Step 'Complete' -Description 'Monitoring command completed with warnings.'
        Pause-Screen
        return
    }
    $recentOutput = @($output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 10)
    $fatalMonitorFailure = @($recentOutput | Where-Object { $_ -match '(?i)fatal monitor failure|\[fatal\]' }).Count -gt 0
    if ($exitCode -eq 2 -and -not $fatalMonitorFailure) {
        # Code 2 can be a valid completed run containing alerts or errors found by the health checks.
        Write-Host 'Monitoring completed with alerts or errors. Review the displayed results and monitor logs.' -ForegroundColor Red
        Write-StreamingLog -Percent 100 -Step 'Complete' -Description 'Monitoring command completed with alerts or errors.'
        Pause-Screen
        return
    }
    if ($exitCode -ne 0) {
        $detail = if ($recentOutput.Count -gt 0) { $recentOutput -join ' | ' } else { 'No monitor output was returned.' }
        throw "The monitoring command returned exit code $exitCode. Recent monitor output: $detail"
    }

    Write-StreamingLog -Percent 100 -Step 'Complete' -Description 'Monitoring command completed successfully.'
    Pause-Screen
}

function Read-AdditionalMonitoringSites {
    while ($true) {
        Write-Host 'Enter one or more additional frontend sites separated by commas. Their API health checks are added automatically.' -ForegroundColor Gray
        $sites = Read-Host 'Additional site address(es) (q to go back)'
        if (Test-IsBack $sites) { return $null }
        $sites = Normalize-UserPath $sites
        if (Test-SiteMonitoringHostList -Hosts $sites) {
            return (($sites -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique) -join ',')
        }
        Write-Host 'Enter valid site names, for example hostname:1200 or akbou.decide4action.com.' -ForegroundColor Yellow
    }
}

function Read-MonitoringIssueKey {
    while ($true) {
        $key = Read-Host 'Issue rule key from the monitoring email or log (q to go back)'
        if (Test-IsBack $key) { return $null }
        $key = $key.Trim()
        if ($key -match '^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$') { return $key }
        Write-Host 'Enter a valid rule key using letters, numbers, dots, underscores, colons, or hyphens.' -ForegroundColor Yellow
    }
}

function Read-MonitoringCooldownDuration {
    while ($true) {
        $duration = Read-Host 'Cooldown duration (examples: 30m, 12h, 3d, 1w; Enter = 24h; q to go back)'
        if (Test-IsBack $duration) { return $null }
        if ([string]::IsNullOrWhiteSpace($duration)) { return '24h' }
        $duration = $duration.Trim().ToLowerInvariant()
        if ($duration -match '^[1-9]\d*(m|h|d|w)$') { return $duration }
        Write-Host 'Enter a duration such as 30m, 12h, 3d, or 1w.' -ForegroundColor Yellow
    }
}

function Show-ExecuteMonitoringCommandsMenu {
    while ($true) {
        Clear-Host
        Write-Host '========================================================================' -ForegroundColor DarkGray
        Write-Host '                    EXECUTE MONITORING COMMANDS' -ForegroundColor Cyan
        Write-Host '========================================================================' -ForegroundColor DarkGray
        Write-Host 'Each command uses the selected installed monitor and its JSON configuration.' -ForegroundColor Gray
        Write-Host ''
        Write-Host '1) Add site to existing monitoring'
        Write-Host '2) Show current monitoring configuration'
        Write-Host '3) Run monitoring test and send email'
        Write-Host '4) Run normal monitoring check'
        Write-Host '5) Send daily monitoring summary now'
        Write-Host '6) Validate monitoring configuration'
        Write-Host '7) Temporarily test specific site(s) and send email'
        Write-Host '8) Run extended CPU performance test and send email'
        Write-Host '9) Run monitoring without email delivery'
        Write-Host '10) Set automatic alert cooldown'
        Write-Host '11) Clear automatic alert cooldown'
        Write-Host 'q) Back to Site Monitoring'
        Write-Host '------------------------------------------------------------------------'
        $choice = Read-Host 'Choose an option'
        if (Test-IsBack $choice) { return }

        switch ($choice) {
            '1' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                $sites = Read-AdditionalMonitoringSites
                if ($null -eq $sites) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Add site' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Add Site to Existing Monitoring' -Description 'Adds the entered frontend site(s) to the persistent JSON configuration. Matching API health checks are derived automatically.' -ArgumentList @('-AddSiteAddress', $sites)
                }
            }
            '2' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Show configuration' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Show Current Monitoring Configuration' -Description 'Displays configured frontend sites, automatic API sites, scheduled frequency, recipients, log paths, and thresholds.' -ArgumentList @('-ShowConfiguration')
                }
            }
            '3' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Test email' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Run Monitoring Test and Send Email' -Description 'Runs all health checks and sends a complete test email even when no issue is detected.' -ArgumentList @('-SendTestResultsEmail')
                }
            }
            '4' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Normal monitoring run' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Run Normal Monitoring Check' -Description 'Runs all health checks. Email is sent only for a new active issue not covered by an ignore rule.'
                }
            }
            '5' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Daily summary' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Send Daily Monitoring Summary' -Description 'Runs all health checks and sends a complete daily-style summary even when the site is healthy.' -ArgumentList @('-SendDailySummaryEmail')
                }
            }
            '6' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Validate configuration' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Validate Monitoring Configuration' -Description 'Validates the JSON configuration and thresholds without running a health scan.' -ArgumentList @('-ValidateConfiguration')
                }
            }
            '7' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                $sites = Read-AdditionalMonitoringSites
                if ($null -eq $sites) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Temporary site test' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Temporarily Test Specific Site(s)' -Description 'Tests the entered site(s) and derived APIs for this run only; the JSON configuration is not changed.' -ArgumentList @('-SiteAddress', $sites, '-SendTestResultsEmail')
                }
            }
            '8' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Extended CPU test' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Extended CPU Performance Test' -Description 'Runs all health checks with a 120-second CPU sample and sends a complete test email.' -ArgumentList @('-CpuSampleDurationSeconds', '120', '-SendTestResultsEmail')
                }
            }
            '9' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - No-email run' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Run Monitoring Without Email' -Description 'Runs all health checks and writes logs, but does not send an email.' -ArgumentList @('-DisableEmail')
                }
            }
            '10' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                $key = Read-MonitoringIssueKey
                if ($null -eq $key) { continue }
                $duration = Read-MonitoringCooldownDuration
                if ($null -eq $duration) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Set cooldown' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Set Automatic Alert Cooldown' -Description 'Recalculates the automatic issue cooldown duration and expiry timestamp from now.' -ArgumentList @('-SetIssueCooldown', $key, '-IssueCooldownDuration', $duration)
                }
            }
            '11' {
                $target = Select-SiteMonitoringCommandTarget
                if ($null -eq $target) { continue }
                $key = Read-MonitoringIssueKey
                if ($null -eq $key) { continue }
                Invoke-LoggedToolAction -Context 'Execute Monitoring Commands - Clear cooldown' -Action {
                    Invoke-SiteMonitoringCommand -Target $target -Title 'Clear Automatic Alert Cooldown' -Description 'Removes the automatic cooldown so a continuing or recurring issue can notify again.' -ArgumentList @('-ClearIssueCooldown', $key)
                }
            }
            default {
                Write-Host 'That is not a valid choice. Try again.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-SiteMonitoringMenu {
    while ($true) {
        Clear-Host
        Write-Host '========================================================================' -ForegroundColor DarkGray
        Write-Host '                           SITE MONITORING' -ForegroundColor Cyan
        Write-Host '========================================================================' -ForegroundColor DarkGray
        Write-Host '1) Add or update Site Monitoring'
        Write-Host '2) Execute Monitoring Commands'
        Write-Host 'q) Back to main menu'
        Write-Host '------------------------------------------------------------------------'
        $choice = Read-Host 'Choose an option'
        if (Test-IsBack $choice) { return }

        switch ($choice) {
            '1' { Invoke-LoggedToolAction -Context 'Site Monitoring - Add or update monitor' -Action { Show-AddSiteMonitoring } }
            '2' { Invoke-LoggedToolAction -Context 'Site Monitoring - Execute Monitoring Commands' -Action { Show-ExecuteMonitoringCommandsMenu } }
            default {
                Write-Host 'That is not a valid choice. Try again.' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ------------------------------------------------------------------------------
# Database tools
# ------------------------------------------------------------------------------
function Get-InstanceNames {
    try {
        $instanceKeys = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
        if ($null -eq $instanceKeys) { return @() }

        $instanceNames = foreach ($property in $instanceKeys.PSObject.Properties) {
            if ($property.Name -match '^PS' -or $property.Name -eq 'Name') { continue }

            if ($property.Name -eq 'MSSQLSERVER') {
                "localhost"
            }
            else {
                "localhost\$($property.Name)"
            }
        }

        return @($instanceNames | Sort-Object -Unique)
    }
    catch {
        return @()
    }
}

function Connect-Database {
    if (-not [string]::IsNullOrWhiteSpace($Global:SelectedDb)) {
        return
    }

    if (-not (Test-SqlCommandAvailable)) { return }

    Clear-Host
    Show-SectionTitle "Connect to SQL Server"
    Write-Host "Type 'q' at any prompt to go back." -ForegroundColor DarkGray
    Write-Host ""

    $instanceNames = Get-InstanceNames

    if ($instanceNames.Count -eq 0) {
        while ($true) {
            $enteredInstance = Read-Host "Enter the SQL Server name or instance (example: localhost or SERVER\INSTANCE)"
            if (Test-IsBack $enteredInstance) { Clear-DatabaseConnection; return }

            $enteredInstance = Normalize-UserPath $enteredInstance
            if (-not [string]::IsNullOrWhiteSpace($enteredInstance)) {
                $Global:SelectedInstance = $enteredInstance
                break
            }

            Write-Host "Please enter a SQL Server name or type 'q' to go back." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "Detected SQL Server instances:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $instanceNames.Count; $i++) {
            Write-Host "[$($i + 1)] $($instanceNames[$i])"
        }
        Write-Host "[M] Enter a server name manually"

        while ($true) {
            $instIndex = Read-Host "Choose a SQL Server connection"
            if (Test-IsBack $instIndex) { Clear-DatabaseConnection; return }

            if ($instIndex -ieq 'm') {
                $manualInstance = Read-Host "Enter the SQL Server name or instance"
                if (Test-IsBack $manualInstance) { Clear-DatabaseConnection; return }

                $manualInstance = Normalize-UserPath $manualInstance
                if (-not [string]::IsNullOrWhiteSpace($manualInstance)) {
                    $Global:SelectedInstance = $manualInstance
                    break
                }

                Write-Host "Please enter a SQL Server name." -ForegroundColor Yellow
                continue
            }

            $selectedInstanceIndex = 0
            if ([int]::TryParse($instIndex, [ref]$selectedInstanceIndex) -and
                $selectedInstanceIndex -ge 1 -and
                $selectedInstanceIndex -le $instanceNames.Count) {
                $Global:SelectedInstance = $instanceNames[$selectedInstanceIndex - 1]
                break
            }

            Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
        }
    }

    $Global:User = Read-Host "Database user name (default: sa)"
    if (Test-IsBack $Global:User) { Clear-DatabaseConnection; return }
    if ([string]::IsNullOrWhiteSpace($Global:User)) { $Global:User = 'sa' }

    $rawPass = Read-PasswordWithClipboardSupport -Prompt "Database password"
    if (Test-IsBack $rawPass) { Clear-DatabaseConnection; return }
    $Global:PlainPass = $rawPass

    Write-Host ""
    Write-Host "Loading available databases..." -ForegroundColor Gray
    $dbQuery = "select name from sys.databases where database_id > 4 order by name"

    try {
        $dbList = @(Invoke-D4ASqlcmd -ServerInstance $Global:SelectedInstance -Username $Global:User -Password $Global:PlainPass -Query $dbQuery | Select-Object -ExpandProperty name)

        if ($dbList.Count -eq 0) {
            throw "No application databases were found."
        }

        Write-Host ""
        Write-Host "Available databases:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $dbList.Count; $i++) {
            Write-Host "[$($i + 1)] $($dbList[$i])"
        }

        while ($true) {
            $dbIndex = Read-Host "Choose a database"
            if (Test-IsBack $dbIndex) { Clear-DatabaseConnection; return }

            $selectedDbIndex = 0
            if ([int]::TryParse($dbIndex, [ref]$selectedDbIndex) -and
                $selectedDbIndex -ge 1 -and
                $selectedDbIndex -le $dbList.Count) {
                $Global:SelectedDb = $dbList[$selectedDbIndex - 1]
                break
            }

            Write-Host "That is not a valid database choice. Try again." -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "Connected to $($Global:SelectedInstance), database $($Global:SelectedDb)." -ForegroundColor Green
        Start-Sleep -Seconds 1
    }
    catch {
        Show-LoggedError -Prefix "Could not connect to the database" -Context "Connect to SQL Server" -ErrorRecord $_
        Clear-DatabaseConnection
        Pause-Screen
    }
}

function Invoke-TranslationQuery {
    param([Parameter(Mandatory = $true)][string]$Query)

    $settings = Get-DatabaseConnectionSettings
    if ([string]::IsNullOrWhiteSpace($settings.Instance) -or [string]::IsNullOrWhiteSpace($settings.Database)) {
        throw "No database is selected. Please connect to a database first."
    }

    Invoke-D4ASqlcmd -ServerInstance $settings.Instance -Database $settings.Database -Username $settings.User -Password $settings.Password -Query $Query -QueryTimeout 0
}

function Invoke-DatabaseSearchQuery {
    param(
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$CommandTimeout = 900
    )

    # Database-wide searches can be expensive, so this helper deliberately uses
    # a finite timeout instead of the unlimited timeout used by routine reports.
    $connection = New-TranslationSqlConnection
    $command = $null
    $reader = $null

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = $CommandTimeout

        $reader = $command.ExecuteReader()
        $table = New-Object System.Data.DataTable
        $table.Load($reader)
        return @($table.Rows)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $command) { $command.Dispose() }
        if ($null -ne $connection) {
            $connection.Close()
            $connection.Dispose()
        }
    }
}

function Invoke-TranslationSqlFile {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $resolvedPath = Normalize-UserPath $FilePath
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "SQL file not found: $resolvedPath"
    }

    $settings = Get-DatabaseConnectionSettings
    if ([string]::IsNullOrWhiteSpace($settings.Instance) -or [string]::IsNullOrWhiteSpace($settings.Database)) {
        throw "No database is selected. Please connect to a database first."
    }

    Invoke-D4ASqlcmd -ServerInstance $settings.Instance -Database $settings.Database -Username $settings.User -Password $settings.Password -InputFile $resolvedPath -QueryTimeout 0
}

function Get-RequiredScriptFolderFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$DownloadUrl,
        [Parameter(Mandatory = $true)][string]$FeatureName
    )

    $scriptFolder = Get-CurrentScriptFolder
    $filePath = Join-Path -Path $scriptFolder -ChildPath $FileName
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        Write-Host "The required companion file '$FileName' is missing." -ForegroundColor Yellow
        Write-Host "IT Tools will download the official release file for $FeatureName now." -ForegroundColor Cyan

        if (-not (Test-ITToolsScriptFolderWritable -Folder $scriptFolder)) {
            Write-Host "IT Tools cannot save the file in: $scriptFolder" -ForegroundColor Red
            Write-Host 'Run IT Tools as Administrator, or move the complete IT Tools folder to a user-owned Desktop or Documents folder and try again.' -ForegroundColor Yellow
            throw "Required companion file could not be saved: $filePath"
        }

        $downloadFolder = Join-Path ([IO.Path]::GetTempPath()) ('ITToolsCompanion_{0}' -f [guid]::NewGuid().ToString('N'))
        try {
            [void](New-Item -Path $downloadFolder -ItemType Directory -Force -ErrorAction Stop)
            $manifestText = Get-ITToolsRemoteText -RelativePath $Script:ToolUpdateManifestFileName
            $manifest = $manifestText | ConvertFrom-Json -ErrorAction Stop
            $fileEntries = @($manifest.files | Where-Object { [string]$_.path -ieq $FileName })
            if ($fileEntries.Count -ne 1) {
                throw "The official release manifest does not contain a unique entry for '$FileName'."
            }

            $expectedHash = ([string]$fileEntries[0].sha256).ToUpperInvariant()
            if ($expectedHash -notmatch '^[A-F0-9]{64}$') {
                throw "The release manifest contains an invalid SHA-256 value for '$FileName'."
            }

            $temporaryFilePath = Join-Path $downloadFolder $FileName
            $temporaryFileFolder = Split-Path -Parent $temporaryFilePath
            [void](New-Item -Path $temporaryFileFolder -ItemType Directory -Force -ErrorAction Stop)
            Write-StreamingLog -Percent 25 -Step 'Download' -Description "Downloading missing companion file $FileName."
            Invoke-WebRequest -Uri (Get-ITToolsUpdateUri -RelativePath $FileName) -OutFile $temporaryFilePath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop

            Write-StreamingLog -Percent 70 -Step 'Verify' -Description "Verifying the official file $FileName."
            $actualHash = (Get-FileHash -LiteralPath $temporaryFilePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
            if ($actualHash -ne $expectedHash) {
                throw "Integrity check failed for '$FileName'."
            }

            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                Copy-Item -LiteralPath $temporaryFilePath -Destination $filePath -Force -ErrorAction Stop
            }
            Write-StreamingLog -Percent 100 -Step 'Download' -Description "Required file $FileName is ready to use."
            Write-Host "Downloaded and verified: $filePath" -ForegroundColor Green
        }
        catch {
            Write-Host "Automatic download failed for '$FileName'." -ForegroundColor Red
            Write-Host "Official source: $DownloadUrl" -ForegroundColor Cyan
            throw "Required companion file could not be downloaded: $filePath. $($_.Exception.Message)"
        }
        finally {
            if (Test-Path -LiteralPath $downloadFolder -PathType Container) {
                Remove-Item -LiteralPath $downloadFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $filePath
}

function Assert-AssemblyRulesImportFileIsStagingOnly {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $sqlText = Get-Content -LiteralPath $FilePath -Raw
    $stagingPattern = '(?i)(?:\[dbo\]\.|\bdbo\.)?\[?AssemblyRules_Luleburgas\]?'
    $sqlWithoutStagingName = [System.Text.RegularExpressions.Regex]::Replace(
        $sqlText,
        $stagingPattern,
        'STAGING_TABLE'
    )

    $unsafePatterns = @(
        '(?is)\bupdate\s+(?:\[dbo\]\.|\bdbo\.)?\[?AssemblyRules\]?\b',
        '(?is)\bdelete\s+from\s+(?:\[dbo\]\.|\bdbo\.)?\[?AssemblyRules\]?\b',
        '(?is)\btruncate\s+table\s+(?:\[dbo\]\.|\bdbo\.)?\[?AssemblyRules\]?\b',
        '(?is)\bdrop\s+table\s+(?:if\s+exists\s+)?(?:\[dbo\]\.|\bdbo\.)?\[?AssemblyRules\]?\b',
        '(?is)\balter\s+table\s+(?:\[dbo\]\.|\bdbo\.)?\[?AssemblyRules\]?\b',
        '(?is)\bupdate\s+\w+\s+set\b.*?\bfrom\s+(?:\[dbo\]\.|\bdbo\.)?\[?AssemblyRules\]?\b'
    )

    foreach ($pattern in $unsafePatterns) {
        if ($sqlWithoutStagingName -match $pattern) {
            throw "AssemblyRules_Luleburgas.sql must only create and populate AssemblyRules_Luleburgas. Remove any direct UPDATE, DELETE, ALTER, DROP, or TRUNCATE commands for dbo.AssemblyRules; the PowerShell tool applies the update after preview."
        }
    }
}

function New-DatabaseTableBackup {
    param([Parameter(Mandatory = $true)][string]$TableName)

    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    while ($true) {
        $backupTableName = "$TableName$timestamp"
        if (-not (Test-TranslationTableExists -TableName $backupTableName)) { break }

        Start-Sleep -Seconds 1
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    }

    $sourceSqlName = Get-QuotedSqlTableName -TableName $TableName
    $backupSqlName = Get-QuotedSqlTableName -TableName $backupTableName
    Write-StreamingLog -Percent 10 -Step "Backup" -Description "Copying dbo.$TableName to dbo.$backupTableName."
    $query = "select * into $backupSqlName from $sourceSqlName;"
    [void](Invoke-TranslationQuery -Query $query)

    return $backupTableName
}

function New-TranslationSqlConnection {
    $settings = Get-DatabaseConnectionSettings
    if ([string]::IsNullOrWhiteSpace($settings.Instance) -or [string]::IsNullOrWhiteSpace($settings.Database)) {
        throw "No database is selected. Please connect to a database first."
    }

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder["Data Source"] = $settings.Instance
    $builder["Initial Catalog"] = $settings.Database
    $builder["User ID"] = $settings.User
    $builder["Password"] = $settings.Password
    $builder["Encrypt"] = $false
    $builder["TrustServerCertificate"] = $true

    return New-Object System.Data.SqlClient.SqlConnection($builder.ConnectionString)
}

function Invoke-TransactionalNonQuery {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlTransaction]$Transaction,
        [Parameter(Mandatory = $true)][object]$Query,
        [int]$CommandTimeout = 0
    )

    $queryText = ConvertTo-RequiredText -Value $Query -Purpose "SQL command text" -JoinMultipleStrings $true
    $command = $Connection.CreateCommand()
    $command.Transaction = $Transaction
    $command.CommandText = $queryText
    $command.CommandTimeout = $CommandTimeout
    return $command.ExecuteNonQuery()
}

function Invoke-TransactionalQuery {
    param(
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory = $true)][System.Data.SqlClient.SqlTransaction]$Transaction,
        [Parameter(Mandatory = $true)][object]$Query,
        [int]$CommandTimeout = 0
    )

    $queryText = ConvertTo-RequiredText -Value $Query -Purpose "SQL query text" -JoinMultipleStrings $true
    $command = $Connection.CreateCommand()
    $command.Transaction = $Transaction
    $command.CommandText = $queryText
    $command.CommandTimeout = $CommandTimeout

    $table = New-Object System.Data.DataTable
    $reader = $command.ExecuteReader()
    try {
        $table.Load($reader)
    }
    finally {
        $reader.Close()
    }

    return @($table.Rows)
}

function Get-SqlUnicodeLiteral {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return "NULL" }

    $text = ConvertTo-RequiredText -Value $Value -Purpose "SQL unicode literal"
    $escaped = $text.Replace("'", "''")
    return "N'$escaped'"
}

function ConvertTo-SqlSafeNamePart {
    param([Parameter(Mandatory = $true)][object]$Value)

    $text = ConvertTo-RequiredText -Value $Value -Purpose "SQL object name part"
    $safe = ($text.Trim() -replace '[^A-Za-z0-9_]+', '_').Trim('_')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = "Language" }
    if ($safe.Length -gt 80) { $safe = $safe.Substring(0, 80).Trim('_') }
    return $safe
}

function Get-QuotedSqlTableName {
    param([Parameter(Mandatory = $true)][object]$TableName)

    $tableNameText = ConvertTo-RequiredText -Value $TableName -Purpose "SQL table name"
    return "dbo.[$($tableNameText.Replace(']', ']]'))]"
}

function Test-TranslationTableExists {
    param([Parameter(Mandatory = $true)][object]$TableName)

    $tableNameText = ConvertTo-RequiredText -Value $TableName -Purpose "SQL table name"
    $safeTable = $tableNameText.Replace("'", "''")
    $query = @"
select case when exists (
    select 1
    from sys.tables t
    inner join sys.schemas s on t.schema_id = s.schema_id
    where s.name = N'dbo'
      and t.name = N'$safeTable'
) then 1 else 0 end as ExistsFlag;
"@

    try {
        $result = @(Invoke-TranslationQuery -Query $query | Select-Object -First 1)
        return ($result.Count -gt 0 -and [int]$result[0].ExistsFlag -eq 1)
    }
    catch {
        return $false
    }
}

function Test-TranslationColumnExists {
    param(
        [Parameter(Mandatory = $true)][object]$TableName,
        [Parameter(Mandatory = $true)][object]$ColumnName
    )

    $tableNameText = ConvertTo-RequiredText -Value $TableName -Purpose "SQL table name"
    $columnNameText = ConvertTo-RequiredText -Value $ColumnName -Purpose "SQL column name"
    $safeTable = $tableNameText.Replace("'", "''")
    $safeColumn = $columnNameText.Replace("'", "''")
    $query = @"
select case when exists (
    select 1
    from sys.columns c
    inner join sys.tables t on c.object_id = t.object_id
    inner join sys.schemas s on t.schema_id = s.schema_id
    where s.name = N'dbo'
      and t.name = N'$safeTable'
      and c.name = N'$safeColumn'
) then 1 else 0 end as ColumnExists;
"@

    try {
        $result = @(Invoke-TranslationQuery -Query $query | Select-Object -First 1)
        return ($result.Count -gt 0 -and [int]$result[0].ColumnExists -eq 1)
    }
    catch {
        return $false
    }
}

function Assert-TranslationSchema {
    $requiredTables = @('Languages', 'RootTranslation', 'LanguageTranslations')
    $missingItems = New-Object System.Collections.Generic.List[string]

    foreach ($table in $requiredTables) {
        if (-not (Test-TranslationTableExists -TableName $table)) {
            [void]$missingItems.Add("dbo.$table table")
        }
    }

    if ($missingItems.Count -eq 0) {
        $requiredColumns = @(
            @{ Table = 'Languages'; Column = 'LanguageId' },
            @{ Table = 'Languages'; Column = 'LanguageType' },
            @{ Table = 'RootTranslation'; Column = 'RootId' },
            @{ Table = 'RootTranslation'; Column = 'RootItem' },
            @{ Table = 'LanguageTranslations'; Column = 'LanguageId' },
            @{ Table = 'LanguageTranslations'; Column = 'RootId' },
            @{ Table = 'LanguageTranslations'; Column = 'TranslationItem' }
        )

        foreach ($item in $requiredColumns) {
            if (-not (Test-TranslationColumnExists -TableName $item.Table -ColumnName $item.Column)) {
                [void]$missingItems.Add("dbo.$($item.Table).$($item.Column) column")
            }
        }
    }

    if ($missingItems.Count -gt 0) {
        throw "This database does not expose the expected D4A translation schema. Missing: $($missingItems -join ', ')."
    }
}

function Assert-LineDetailedViewSchema {
    $requiredTables = @(
        'SystemGroupLinks',
        'SystemGroups',
        'AssemblyRules',
        'D4A_KPIs',
        'D4A_Kpis_DtlSettings',
        'D4A_Kpis_ComponentType'
    )
    $missingItems = New-Object System.Collections.Generic.List[string]

    foreach ($table in $requiredTables) {
        if (-not (Test-TranslationTableExists -TableName $table)) {
            [void]$missingItems.Add("dbo.$table table")
        }
    }

    if ($missingItems.Count -gt 0) {
        throw "This database does not expose the expected Line Detailed View schema. Missing: $($missingItems -join ', ')."
    }
}

function Get-TranslationSchemaFeatures {
    return [pscustomobject]@{
        LanguagesHasActive = Test-TranslationColumnExists -TableName 'Languages' -ColumnName 'Active'
        LanguageTranslationsHasTranslationId = Test-TranslationColumnExists -TableName 'LanguageTranslations' -ColumnName 'TranslationId'
        LanguageTranslationsHasCustomTranslation = Test-TranslationColumnExists -TableName 'LanguageTranslations' -ColumnName 'CustomTranslation'
    }
}

function Remove-DataTableMetaColumns {
    param([Parameter(ValueFromPipeline = $true)][AllowNull()]$Data)

    process {
        foreach ($row in @($Data)) {
            if ($null -eq $row) { continue }

            $clean = [ordered]@{}
            foreach ($prop in $row.PSObject.Properties) {
                if ($prop.Name -in @('RowError', 'RowState', 'Table', 'ItemArray', 'HasErrors')) { continue }
                $clean[$prop.Name] = $prop.Value
            }
            [pscustomobject]$clean
        }
    }
}

function Normalize-DataRows {
    param([AllowNull()][object[]]$Data)

    if ($null -eq $Data) { return @() }

    $rows = @($Data) | Where-Object { $null -ne $_ } | Remove-DataTableMetaColumns
    return @($rows)
}

function Get-LanguageCatalog {
    $activeSelect = if (Test-TranslationColumnExists -TableName 'Languages' -ColumnName 'Active') {
        'ISNULL(Active, 1) as Active'
    }
    else {
        'CAST(1 as bit) as Active'
    }

    $query = "select LanguageId, LanguageType, $activeSelect from dbo.Languages order by LanguageId"
    $rows = Invoke-TranslationQuery -Query $query
    return @($rows)
}

function Show-LanguageCatalog {
    param([Parameter(Mandatory = $true)][object[]]$Languages)

    Write-Host ""
    Write-Host "Available languages:" -ForegroundColor Cyan

    if ($Languages.Count -eq 0) {
        Write-Host "No target languages were found." -ForegroundColor Yellow
        return
    }

    foreach ($lang in $Languages) {
        $status = if ($null -ne $lang.Active -and $lang.Active -eq 1) { "active" } else { "inactive" }
        Write-Host "[$($lang.LanguageId)] $($lang.LanguageType) ($status)"
    }
}

function New-DatabaseLanguage {
    param([Parameter(Mandatory = $true)][object[]]$Languages)

    while ($true) {
        Show-LanguageCatalog -Languages $Languages
        Write-Host ""
        Write-Host "Type 'q' to go back." -ForegroundColor Green
        $languageName = Read-Host "New language name"

        if (Test-IsBack $languageName) { return $null }

        $languageName = $languageName.Trim()
        if ([string]::IsNullOrWhiteSpace($languageName)) {
            Write-Host "Please enter a language name." -ForegroundColor Yellow
            continue
        }

        $existing = @($Languages | Where-Object { $_.LanguageType -ieq $languageName } | Select-Object -First 1)
        if ($existing.Count -gt 0) {
            Write-Host "That language already exists as ID $($existing[0].LanguageId)." -ForegroundColor Cyan
            return $existing[0]
        }

        $nextId = 1
        if ($Languages.Count -gt 0) {
            $maxId = @($Languages | Select-Object -ExpandProperty LanguageId | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum
            $nextId = [int]$maxId + 1
        }

        Write-Host ""
        Write-Host "This will add language ID $nextId as '$languageName' in dbo.Languages." -ForegroundColor Yellow
        $confirm = Read-Host "Type CREATE to continue, or anything else to cancel"
        if ($confirm -cne 'CREATE') {
            Write-Host "Language creation cancelled." -ForegroundColor Cyan
            Pause-Screen
            return $null
        }

        $safeLanguageName = Get-SqlUnicodeLiteral -Value $languageName
        if (Test-TranslationColumnExists -TableName 'Languages' -ColumnName 'Active') {
            $query = "insert into dbo.Languages (LanguageId, LanguageType, Active) values ($nextId, $safeLanguageName, 1);"
        }
        else {
            $query = "insert into dbo.Languages (LanguageId, LanguageType) values ($nextId, $safeLanguageName);"
        }
        $backupTable = New-DatabaseTableBackup -TableName "Languages"
        Write-Host "Backup table created: $backupTable" -ForegroundColor Green
        [void](Invoke-TranslationQuery -Query $query)

        Write-Host "Language created: [$nextId] $languageName" -ForegroundColor Green
        return [pscustomobject]@{
            LanguageId   = $nextId
            LanguageType = $languageName
            Active       = 1
        }
    }
}

function Prompt-LanguageSelection {
    param(
        [Parameter(Mandatory = $true)][object[]]$Languages,
        [bool]$AllowMultiple = $true,
        [bool]$AllowCreateNew = $false
    )

    $englishLang = @($Languages | Where-Object { $_.LanguageType -eq 'English' } | Select-Object -First 1)
    $englishId = if ($englishLang.Count -gt 0) { [int]$englishLang[0].LanguageId } else { 1 }

    $selectableLangs = @($Languages | Where-Object { $_.LanguageType -ne 'English' })
    $allIds = @($Languages | Select-Object -ExpandProperty LanguageId | ForEach-Object { [int]$_ } | Sort-Object -Unique)
    $selectableIds = @($selectableLangs | Select-Object -ExpandProperty LanguageId | ForEach-Object { [int]$_ })

    while ($true) {
        Show-LanguageCatalog -Languages $selectableLangs
        Write-Host ""
        Write-Host "Notes:" -ForegroundColor Green
        Write-Host "  - English is included automatically so you can compare translations." -ForegroundColor Green
        Write-Host "  - To export English only, type '$englishId'." -ForegroundColor Green
        if ($AllowCreateNew) {
            Write-Host "  - Type 'n' to add a new language before exporting." -ForegroundColor Green
        }
        Write-Host "  - Type 'q' to go back." -ForegroundColor Green
        Write-Host ""

        if ($AllowMultiple) {
            $raw = Read-Host "Enter language IDs separated by commas, or type 'all'"
        }
        else {
            $raw = Read-Host "Enter one language ID"
        }

        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Host "Enter a language ID, type 'all', or type 'q' to go back." -ForegroundColor Yellow
            continue
        }

        $raw = $raw.Trim()
        if (Test-IsBack $raw) { return $null }

        if ($AllowCreateNew -and $raw -ieq 'n') {
            try {
                $newLanguage = New-DatabaseLanguage -Languages $Languages
                if ($null -eq $newLanguage) { continue }

                $Languages = @(Get-LanguageCatalog)
                $englishLang = @($Languages | Where-Object { $_.LanguageType -eq 'English' } | Select-Object -First 1)
                $englishId = if ($englishLang.Count -gt 0) { [int]$englishLang[0].LanguageId } else { 1 }

                if ($AllowMultiple -and [int]$newLanguage.LanguageId -ne $englishId) {
                    return @([int]$newLanguage.LanguageId, $englishId)
                }

                return @([int]$newLanguage.LanguageId)
            }
            catch {
                Show-LoggedError -Prefix "The language could not be created" -Context "Language selection - create new database language" -ErrorRecord $_
                Pause-Screen
                continue
            }
        }

        if ($raw -ieq 'all') {
            if ($AllowMultiple) { return @($allIds) }
            Write-Host "Please choose only one language." -ForegroundColor Yellow
            continue
        }

        $parts = @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if ($parts.Count -eq 0) { continue }

        $parsedIds = New-Object System.Collections.Generic.List[int]
        $valid = $true
        $containsEnglishInput = $false

        foreach ($part in $parts) {
            $num = 0
            if (-not [int]::TryParse($part, [ref]$num)) {
                Write-Host "'$part' is not a number. Please enter language IDs such as 2 or 2,3,4." -ForegroundColor Red
                $valid = $false
                break
            }

            if ($num -eq $englishId) {
                $containsEnglishInput = $true
                continue
            }

            if ($selectableIds -notcontains $num) {
                Write-Host "Language ID '$num' is not in the list." -ForegroundColor Red
                $valid = $false
                break
            }

            if (-not $parsedIds.Contains($num)) { [void]$parsedIds.Add($num) }
        }

        if (-not $valid) {
            Pause-Screen "Press Enter to choose again..."
            continue
        }

        $selectionCount = $parsedIds.Count
        if ($containsEnglishInput) { $selectionCount++ }
        if (-not $AllowMultiple -and $selectionCount -gt 1) {
            Write-Host "Please select only one language." -ForegroundColor Yellow
            continue
        }

        if ($containsEnglishInput -and $parsedIds.Count -eq 0) { return @($englishId) }

        if ($containsEnglishInput -and $parsedIds.Count -gt 0) {
            Write-Host "English is already included automatically, so it will only be included once." -ForegroundColor Cyan
        }

        if (-not $parsedIds.Contains($englishId)) { [void]$parsedIds.Add($englishId) }
        return @($parsedIds)
    }
}

function Get-LanguageSelectionMetadata {
    param([Parameter(Mandatory = $true)][int[]]$LanguageIds)

    $idList = ($LanguageIds | Sort-Object -Unique) -join ','
    if ([string]::IsNullOrWhiteSpace($idList)) {
        throw "No languages were selected."
    }

    $query = "select LanguageId, LanguageType from dbo.Languages where LanguageId in ($idList) order by LanguageId"
    $rows = Invoke-TranslationQuery -Query $query
    return @($rows)
}

function Prompt-ImportTargetLanguage {
    while ($true) {
        $languages = @(Get-LanguageCatalog)
        Show-LanguageCatalog -Languages $languages
        Write-Host ""
        Write-Host "Type an existing language ID, or type 'n' to add a new language." -ForegroundColor Green
        Write-Host "Type 'q' to go back." -ForegroundColor Green
        Write-Host ""

        $raw = Read-Host "Target language for this import"
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Host "Enter a language ID, type 'n', or type 'q' to go back." -ForegroundColor Yellow
            continue
        }

        $raw = $raw.Trim()
        if (Test-IsBack $raw) { return $null }

        if ($raw -ieq 'n') {
            try {
                $newLanguage = New-DatabaseLanguage -Languages $languages
                if ($null -ne $newLanguage) { return $newLanguage }
            }
            catch {
                Show-LoggedError -Prefix "The language could not be created" -Context "Import new Language with a translated CSV file - create target language" -ErrorRecord $_
                Pause-Screen
            }
            continue
        }

        $languageId = 0
        if (-not [int]::TryParse($raw, [ref]$languageId)) {
            Write-Host "'$raw' is not a valid numeric language ID." -ForegroundColor Yellow
            continue
        }

        $match = @($languages | Where-Object { [int]$_.LanguageId -eq $languageId } | Select-Object -First 1)
        if ($match.Count -eq 0) {
            Write-Host "Language ID '$languageId' is not in the list." -ForegroundColor Yellow
            continue
        }

        return $match[0]
    }
}

function Get-CsvColumnName {
    param(
        [Parameter(Mandatory = $true)][string[]]$Headers,
        [Parameter(Mandatory = $true)][string[]]$PreferredNames,
        [Parameter(Mandatory = $true)][string]$Purpose,
        [bool]$Required = $true
    )

    foreach ($preferred in $PreferredNames) {
        $exact = @($Headers | Where-Object { $_.TrimStart([char]0xFEFF) -ceq $preferred })
        if ($exact.Count -eq 1) { return $exact[0] }
    }

    foreach ($preferred in $PreferredNames) {
        $caseInsensitive = @($Headers | Where-Object { $_.TrimStart([char]0xFEFF) -ieq $preferred })
        if ($caseInsensitive.Count -eq 1) {
            Write-Host "Using CSV column '$($caseInsensitive[0])' for $Purpose. Column names differ only by case." -ForegroundColor Yellow
            return $caseInsensitive[0]
        }
    }

    if (-not $Required) { return $null }

    while ($true) {
        Write-Host ""
        Write-Host "CSV columns found:" -ForegroundColor Cyan
        foreach ($header in $Headers) { Write-Host "  - $header" }
        Write-Host ""
        $selected = Read-Host "Enter the exact column name to use for $Purpose, or type 'q' to go back"
        if (Test-IsBack $selected) { return $null }
        if ($Headers -ccontains $selected) { return $selected }

        Write-Host "Column '$selected' was not found. Please enter one of the names exactly as shown." -ForegroundColor Yellow
    }
}

function Prompt-TranslationImportFolder {
    while ($true) {
        $scriptFolder = Get-CurrentScriptFolder
        $downloadsFolder = Join-Path $env:USERPROFILE "Downloads"

        Write-Host ""
        Write-Host "Choose the folder that contains the translated CSV file:" -ForegroundColor Cyan
        Write-Host "1) Same folder as this PowerShell script: $scriptFolder"
        Write-Host "2) Current user's Downloads folder: $downloadsFolder"
        Write-Host "Or enter the full folder path."
        Write-Host "Type 'q' to go back." -ForegroundColor Green
        Write-Host ""

        $choice = Read-Host "CSV folder"
        if (Test-IsBack $choice) { return $null }

        $folderPath = switch ($choice.Trim()) {
            '1' { $scriptFolder }
            '2' { $downloadsFolder }
            default { Normalize-UserPath $choice }
        }

        if ([string]::IsNullOrWhiteSpace($folderPath)) {
            Write-Host "Please choose a folder option or enter a full folder path." -ForegroundColor Yellow
            continue
        }

        if (-not (Test-Path -LiteralPath $folderPath -PathType Container)) {
            Write-Host "Folder not found: $folderPath" -ForegroundColor Yellow
            continue
        }

        return (Resolve-Path -LiteralPath $folderPath).Path
    }
}

function Prompt-TranslationImportCsvFile {
    param([Parameter(Mandatory = $true)][string]$FolderPath)

    $csvFiles = @(Get-ChildItem -LiteralPath $FolderPath -Filter "*.csv" -File -ErrorAction Stop |
        Sort-Object -Property @{ Expression = { $_.CreationTime }; Descending = $true }, @{ Expression = { $_.LastWriteTime }; Descending = $true }, Name)

    if ($csvFiles.Count -eq 0) {
        Write-Host "No CSV files were found in: $FolderPath" -ForegroundColor Yellow
        Pause-Screen
        return $null
    }

    Write-Host ""
    Write-Host "CSV files found in: $FolderPath" -ForegroundColor Cyan
    for ($i = 0; $i -lt $csvFiles.Count; $i++) {
        $file = $csvFiles[$i]
        Write-Host "[$($i + 1)] $($file.Name) - created: $($file.CreationTime) - modified: $($file.LastWriteTime)"
    }
    Write-Host ""
    Write-Host "Choose a number, or type the file name with or without .csv." -ForegroundColor Green
    Write-Host "Type 'q' to go back." -ForegroundColor Green

    while ($true) {
        $rawChoice = Read-Host "CSV file"
        if (Test-IsBack $rawChoice) { return $null }

        $choice = Normalize-UserPath $rawChoice
        if ([string]::IsNullOrWhiteSpace($choice)) {
            Write-Host "Please choose a file number or type a CSV file name." -ForegroundColor Yellow
            continue
        }

        $fileIndex = 0
        if ([int]::TryParse($choice, [ref]$fileIndex)) {
            if ($fileIndex -ge 1 -and $fileIndex -le $csvFiles.Count) {
                return $csvFiles[$fileIndex - 1].FullName
            }

            Write-Host "File number '$fileIndex' is not in the list." -ForegroundColor Yellow
            continue
        }

        $candidateName = [System.IO.Path]::GetFileName($choice)
        if ([string]::IsNullOrWhiteSpace([System.IO.Path]::GetExtension($candidateName))) {
            $candidateName = "$candidateName.csv"
        }

        $matches = @($csvFiles | Where-Object { $_.Name -ieq $candidateName })
        if ($matches.Count -eq 1) {
            return $matches[0].FullName
        }

        if ($matches.Count -gt 1) {
            Write-Host "More than one file matched '$candidateName'. Please choose by number." -ForegroundColor Yellow
            continue
        }

        Write-Host "CSV file '$candidateName' was not found in the selected folder." -ForegroundColor Yellow
    }
}

function Get-TranslationImportRows {
    param(
        [Parameter(Mandatory = $true)][string]$CsvPath,
        [Parameter(Mandatory = $true)][object]$TargetLanguage
    )

    $normalizedPath = Normalize-UserPath $CsvPath
    if (-not (Test-Path -LiteralPath $normalizedPath)) {
        throw "CSV file not found: $normalizedPath"
    }

    $csvRows = @(Import-Csv -LiteralPath $normalizedPath)
    if ($csvRows.Count -eq 0) {
        throw "The CSV file does not contain data rows."
    }

    $headers = @($csvRows[0].PSObject.Properties.Name)
    $rootColumn = Get-CsvColumnName -Headers $headers -PreferredNames @('RootId', 'rootid', 'Root ID') -Purpose "RootId" -Required $true
    if ($null -eq $rootColumn) { return $null }

    $englishColumn = Get-CsvColumnName -Headers $headers -PreferredNames @('English') -Purpose "English text" -Required $false
    $translationColumn = Get-CsvColumnName -Headers $headers -PreferredNames @([string]$TargetLanguage.LanguageType) -Purpose "$($TargetLanguage.LanguageType) translation" -Required $true
    if ($null -eq $translationColumn) { return $null }

    $rowsByRootId = [ordered]@{}
    $invalidRootIds = 0
    $blankTranslations = 0
    $duplicateRootIds = 0

    foreach ($row in $csvRows) {
        $rootRaw = [string]$row.$rootColumn
        $rootId = 0
        if (-not [int]::TryParse($rootRaw.Trim(), [ref]$rootId)) {
            $invalidRootIds++
            continue
        }

        $translationText = [string]$row.$translationColumn
        if ([string]::IsNullOrWhiteSpace($translationText)) {
            $blankTranslations++
            continue
        }

        $englishText = ""
        if ($null -ne $englishColumn) { $englishText = [string]$row.$englishColumn }

        $key = [string]$rootId
        if ($rowsByRootId.Contains($key)) { $duplicateRootIds++ }
        $rowsByRootId[$key] = [pscustomobject]@{
            RootId          = $rootId
            English         = $englishText
            TranslationItem = $translationText
        }
    }

    return [pscustomobject]@{
        Rows              = @($rowsByRootId.Values)
        SourceRowCount    = $csvRows.Count
        InvalidRootIds    = $invalidRootIds
        BlankTranslations = $blankTranslations
        DuplicateRootIds  = $duplicateRootIds
        RootColumn        = $rootColumn
        EnglishColumn     = $englishColumn
        TranslationColumn = $translationColumn
    }
}

function New-LanguageTranslationsBackupTable {
    param([Parameter(Mandatory = $true)][string]$Timestamp)

    while ($true) {
        $translationBackupTable = "LanguageTranslations$Timestamp"
        $safeObjectName = "dbo.$($translationBackupTable.Replace("'", "''"))"
        $existsQuery = "select case when object_id(N'$safeObjectName', N'U') is null then 0 else 1 end as TableExists;"
        $exists = @(Invoke-TranslationQuery -Query $existsQuery | Select-Object -First 1)
        if ($exists.Count -eq 0 -or [int]$exists[0].TableExists -eq 0) { break }

        Start-Sleep -Seconds 1
        $Timestamp = Get-Date -Format "yyyyMMddHHmmss"
    }

    $translationBackupSqlName = Get-QuotedSqlTableName -TableName $translationBackupTable
    $query = @"
select * into $translationBackupSqlName from dbo.LanguageTranslations;
"@
    [void](Invoke-TranslationQuery -Query $query)

    return $translationBackupTable
}

function New-TranslationImportStagingTable {
    param(
        [Parameter(Mandatory = $true)][object]$TargetLanguage,
        [Parameter(Mandatory = $true)][string]$Timestamp
    )

    $languagePart = ConvertTo-SqlSafeNamePart -Value ([string]$TargetLanguage.LanguageType)
    $tableName = "LanguageTranslations_${languagePart}_$Timestamp"
    $sqlName = Get-QuotedSqlTableName -TableName $tableName

    $query = @"
create table $sqlName (
    RootId int not null,
    English nvarchar(max) null,
    TranslationItem nvarchar(max) not null
);
"@
    [void](Invoke-TranslationQuery -Query $query)
    return $tableName
}

function Add-TranslationImportStagingRows {
    param(
        [Parameter(Mandatory = $true)][object]$StagingTableName,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    $stagingTableNameText = ConvertTo-RequiredText -Value $StagingTableName -Purpose "staging table name"
    $sqlName = Get-QuotedSqlTableName -TableName $stagingTableNameText
    $batchSize = 200

    for ($i = 0; $i -lt $Rows.Count; $i += $batchSize) {
        $batch = @($Rows | Select-Object -Skip $i -First $batchSize)
        $values = ($batch | ForEach-Object {
            "($([int]$_.RootId), $(Get-SqlUnicodeLiteral -Value $_.English), $(Get-SqlUnicodeLiteral -Value $_.TranslationItem))"
        }) -join ",`n"

        $query = @"
insert into $sqlName (RootId, English, TranslationItem)
values
$values;
"@
        [void](Invoke-TranslationQuery -Query $query)
    }
}

function Test-LanguageTranslationsIdentityColumn {
    if (-not (Test-TranslationColumnExists -TableName 'LanguageTranslations' -ColumnName 'TranslationId')) {
        return $false
    }

    $query = @"
select COLUMNPROPERTY(OBJECT_ID(N'dbo.LanguageTranslations'), N'TranslationId', N'IsIdentity') as IsIdentity;
"@
    $result = @(Invoke-TranslationQuery -Query $query | Select-Object -First 1)
    if ($result.Count -eq 0 -or $null -eq $result[0].IsIdentity) { return $false }
    return ([int]$result[0].IsIdentity -eq 1)
}

function Invoke-TranslationImportMigration {
    param(
        [Parameter(Mandatory = $true)][object]$StagingTableName,
        [Parameter(Mandatory = $true)][object]$TargetLanguage,
        [Parameter(Mandatory = $true)][bool]$TranslationIdIsIdentity
    )

    $languageId = [int]$TargetLanguage.LanguageId
    $languageName = [string]$TargetLanguage.LanguageType
    $stagingTableNameText = ConvertTo-RequiredText -Value $StagingTableName -Purpose "staging table name"
    $stagingSqlName = Get-QuotedSqlTableName -TableName $stagingTableNameText

    $features = Get-TranslationSchemaFeatures
    $hasTranslationId = [bool]$features.LanguageTranslationsHasTranslationId
    $hasCustomTranslation = [bool]$features.LanguageTranslationsHasCustomTranslation

    $customInsertColumn = if ($hasCustomTranslation) { ', CustomTranslation' } else { '' }
    $customInsertValue = if ($hasCustomTranslation) { ', NULL as CustomTranslation' } else { '' }
    $customPreviewColumn = if ($hasCustomTranslation) { 'LT.CustomTranslation' } else { 'CAST(NULL as nvarchar(max)) as CustomTranslation' }
    $translationIdPreviewColumn = if ($hasTranslationId) { 'LT.TranslationId' } else { 'CAST(NULL as int) as TranslationId' }
    $previewOrderBy = if ($hasTranslationId) { 'LT.TranslationId desc' } else { 'LT.RootId desc' }

    $insertSql = if ($TranslationIdIsIdentity -or -not $hasTranslationId) {
@"
insert into dbo.LanguageTranslations (TranslationItem, LanguageId, RootId$customInsertColumn)
select
    S.TranslationItem,
    $languageId as LanguageId,
    S.RootId$customInsertValue
from (
    select
        RootId,
        max(TranslationItem) as TranslationItem
    from $stagingSqlName
    where nullif(ltrim(rtrim(TranslationItem)), '') is not null
    group by RootId
) S
where exists (
      select 1
      from dbo.RootTranslation RT
      where RT.RootId = S.RootId
  )
  and not exists (
      select 1
      from dbo.LanguageTranslations LT
      where LT.RootId = S.RootId
        and LT.LanguageId = $languageId
  );
"@
    }
    else {
@"
declare @MaxId int = (select isnull(max(TranslationId), 0) from dbo.LanguageTranslations);

insert into dbo.LanguageTranslations (TranslationId, TranslationItem, LanguageId, RootId$customInsertColumn)
select
    @MaxId + row_number() over (order by S.RootId) as TranslationId,
    S.TranslationItem,
    $languageId as LanguageId,
    S.RootId$customInsertValue
from (
    select
        RootId,
        max(TranslationItem) as TranslationItem
    from $stagingSqlName
    where nullif(ltrim(rtrim(TranslationItem)), '') is not null
    group by RootId
) S
where exists (
      select 1
      from dbo.RootTranslation RT
      where RT.RootId = S.RootId
  )
  and not exists (
      select 1
      from dbo.LanguageTranslations LT
      where LT.RootId = S.RootId
        and LT.LanguageId = $languageId
  );
"@
    }

    $connection = New-TranslationSqlConnection
    $connection.Open()
    $transaction = $connection.BeginTransaction()
    $committed = $false

    try {
        $updateSql = @"
update LT
set LT.TranslationItem = S.TranslationItem
from dbo.LanguageTranslations LT
inner join (
    select
        RootId,
        max(TranslationItem) as TranslationItem
    from $stagingSqlName
    where nullif(ltrim(rtrim(TranslationItem)), '') is not null
    group by RootId
) S on LT.RootId = S.RootId
where LT.LanguageId = $languageId
  and nullif(ltrim(rtrim(S.TranslationItem)), '') is not null;
"@
        $updatedRows = Invoke-TransactionalNonQuery -Connection $connection -Transaction $transaction -Query $updateSql
        $insertedRows = Invoke-TransactionalNonQuery -Connection $connection -Transaction $transaction -Query $insertSql

        $countSql = @"
select
    $languageId as [LanguageId],
    $(Get-SqlUnicodeLiteral -Value $languageName) as [Language],
    (select count(*) from $stagingSqlName where nullif(ltrim(rtrim(TranslationItem)), '') is not null) as [Rows in import table],
    (select count(*) from dbo.LanguageTranslations where LanguageId = $languageId) as [Total rows for language after import],
    $updatedRows as [Rows updated],
    $insertedRows as [Rows inserted],
    (select count(*) from $stagingSqlName S where not exists (select 1 from dbo.RootTranslation RT where RT.RootId = S.RootId)) as [Rows skipped because RootId is missing],
    (
        select count(*)
        from (
            select S.RootId
            from $stagingSqlName S
            inner join dbo.RootTranslation RT on S.RootId = RT.RootId
            where nullif(ltrim(rtrim(S.TranslationItem)), '') is not null
            group by S.RootId
            having count(*) > 1
        ) D
    ) as [Import RootIds duplicated in RootTranslation],
    (
        select count(*)
        from (
            select LT.RootId
            from dbo.LanguageTranslations LT
            inner join (
                select RootId
                from $stagingSqlName
                where nullif(ltrim(rtrim(TranslationItem)), '') is not null
                group by RootId
            ) S on LT.RootId = S.RootId
            where LT.LanguageId = $languageId
            group by LT.RootId
            having count(*) > 1
        ) D
    ) as [Import RootIds duplicated in LanguageTranslations];
"@
        $counts = Invoke-TransactionalQuery -Connection $connection -Transaction $transaction -Query $countSql

        $previewSql = @"
with ImportRows as (
    select
        RootId,
        max(English) as English
    from $stagingSqlName
    group by RootId
),
RootRows as (
    select
        RootId,
        max(RootItem) as RootItem
    from dbo.RootTranslation
    group by RootId
)
select top 20
    $translationIdPreviewColumn,
    LT.LanguageId,
    L.LanguageType,
    LT.RootId,
    coalesce(S.English, RT.RootItem) as English,
    LT.TranslationItem,
    $customPreviewColumn
from dbo.LanguageTranslations LT
inner join ImportRows S on LT.RootId = S.RootId
left join RootRows RT on LT.RootId = RT.RootId
left join dbo.Languages L on LT.LanguageId = L.LanguageId
where LT.LanguageId = $languageId
order by $previewOrderBy;
"@
        $preview = Invoke-TransactionalQuery -Connection $connection -Transaction $transaction -Query $previewSql

        Show-SectionTitle "Import Verification Counts"
        Show-ConsoleResults -Data $counts

        Show-SectionTitle "Preview: Top 20 Imported Rows"
        Show-ConsoleResults -Data $preview

        Write-Host ""
        Write-Host "The database changes above are still inside an open transaction." -ForegroundColor Yellow
        $decision = Read-Host "Type COMMIT to save these changes, or anything else to roll them back"
        if ($decision -ceq 'COMMIT') {
            $transaction.Commit()
            $committed = $true
            Write-Host "Import committed." -ForegroundColor Green
        }
        else {
            $transaction.Rollback()
            Write-Host "Import rolled back. No LanguageTranslations rows were changed." -ForegroundColor Cyan
        }

        return [pscustomobject]@{
            Committed    = $committed
            UpdatedRows  = $updatedRows
            InsertedRows = $insertedRows
        }
    }
    catch {
        try { $transaction.Rollback() } catch {}
        throw
    }
    finally {
        $transaction.Dispose()
        $connection.Close()
        $connection.Dispose()
    }
}

function Remove-TranslationImportStagingTable {
    param([Parameter(Mandatory = $true)][object]$StagingTableName)

    $stagingTableNameText = ConvertTo-RequiredText -Value $StagingTableName -Purpose "staging table name"
    $stagingSqlName = Get-QuotedSqlTableName -TableName $stagingTableNameText
    $stagingObjectName = "dbo.$($stagingTableNameText.Replace("'", "''"))"
    [void](Invoke-TranslationQuery -Query "if object_id(N'$stagingObjectName', N'U') is not null drop table $stagingSqlName;")
}

function Get-ExcelSafeCsvRows {
    param([Parameter(Mandatory = $true)][object[]]$Data)

    $safeRows = foreach ($row in $Data) {
        $safe = [ordered]@{}
        foreach ($prop in $row.PSObject.Properties) {
            if ($prop.Name -in @('RowError', 'RowState', 'Table', 'ItemArray', 'HasErrors')) { continue }

            $value = $prop.Value
            if ($null -eq $value) {
                $safe[$prop.Name] = $null
                continue
            }

            if ($value -is [string]) {
                $text = $value -replace "`r`n|`r|`n", ' '

                # Prevent CSV values from being interpreted as formulas in Excel.
                if ($text -match '^[=\+\-@\s]') { $text = "'" + $text }
                $safe[$prop.Name] = $text
            }
            else {
                $safe[$prop.Name] = $value
            }
        }
        [pscustomobject]$safe
    }

    return @($safeRows)
}

function Export-SafeCsv {
    param(
        [Parameter(Mandatory = $true)][object[]]$Data,
        [Parameter(Mandatory = $true)][string]$FileNamePrefix
    )

    $rows = Normalize-DataRows -Data $Data
    if ($rows.Count -eq 0) {
        Write-Host "There is no data to save." -ForegroundColor Yellow
        return $null
    }

    $downloads = Join-Path $env:USERPROFILE "Downloads"
    if (-not (Test-Path $downloads)) {
        try {
            New-Item -Path $downloads -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            $downloads = [Environment]::GetFolderPath('MyDocuments')
        }
    }

    if ([string]::IsNullOrWhiteSpace($downloads) -or -not (Test-Path $downloads)) {
        $downloads = (Get-Location).Path
    }

    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $filePath = Join-Path -Path $downloads -ChildPath "$($FileNamePrefix)_$timestamp.csv"
    $safeRows = Get-ExcelSafeCsvRows -Data $rows
    $safeRows | Export-Csv -Path $filePath -NoTypeInformation -Encoding UTF8

    Write-Host "CSV saved to: $filePath" -ForegroundColor Green
    return $filePath
}

function Show-ConsoleResults {
    param([Parameter(Mandatory = $true)][object[]]$Data)

    $rows = Normalize-DataRows -Data $Data
    if ($rows.Count -eq 0) {
        Write-Host "No results found." -ForegroundColor Yellow
        return
    }

    $displayText = ($rows | Format-Table -AutoSize -Wrap | Out-String -Width 4096)
    Write-Host $displayText
}

function Show-OutputMenu {
    param(
        [Parameter(Mandatory = $true)][object[]]$Data,
        [Parameter(Mandatory = $true)][string]$FileNamePrefix,
        [string]$Title = "Results"
    )

    $rows = Normalize-DataRows -Data $Data
    if ($rows.Count -eq 0) {
        Write-Host "No matching records were found." -ForegroundColor Yellow
        Pause-Screen
        return
    }

    while ($true) {
        Clear-Host
        Write-Host "=== Results ($($rows.Count) rows) ===" -ForegroundColor Cyan
        Write-Host "1) Show results on screen"
        Write-Host "2) Save results to a CSV file"
        Write-Host "3) Show results and save a CSV file"
        Write-Host "4) Go back"
        $choice = Read-Host "Choose an option"

        if (Test-IsBack $choice) { return }
        switch ($choice) {
            '1' {
                Show-SectionTitle $Title
                Show-ConsoleResults -Data $rows
                Pause-Screen
                return
            }
            '2' {
                [void](Export-SafeCsv -Data $rows -FileNamePrefix $FileNamePrefix)
                Pause-Screen
                return
            }
            '3' {
                Show-SectionTitle $Title
                Show-ConsoleResults -Data $rows
                [void](Export-SafeCsv -Data $rows -FileNamePrefix $FileNamePrefix)
                Pause-Screen
                return
            }
            '4' { return }
            default { Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow }
        }
    }
}

function Get-DynamicPivotSql {
    param(
        [Parameter(Mandatory = $true)][int[]]$LanguageIds,
        [ValidateSet('Full', 'Translatable', 'Fixed')][string]$FilterType = 'Full'
    )

    $idList = ($LanguageIds | Sort-Object -Unique) -join ','
    $languageRows = @(Get-LanguageSelectionMetadata -LanguageIds $LanguageIds)
    $languageRows = @($languageRows | Sort-Object -Property @{ Expression = { if ($_.LanguageType -eq 'English') { 0 } else { 1 } } }, LanguageId)

    $caseSelects = ($languageRows | ForEach-Object {
        $langName = $_.LanguageType.Replace("'", "''")
        $escapedColumnName = $_.LanguageType.Replace(']', ']]')

        if ($_.LanguageType -eq 'English') {
            "coalesce(max(case when lang.LanguageType = 'English' then l.TranslationItem end), r.RootItem) as [English]"
        }
        else {
            "max(case when lang.LanguageType = '$langName' then l.TranslationItem end) as [$escapedColumnName]"
        }
    }) -join ",`n        "

    $whereClause = switch ($FilterType) {
        'Translatable' { "where len(e.English_CheckValue) > 1 and e.English_CheckValue like '%[a-zA-Z]%'" }
        'Fixed'        { "where len(e.English_CheckValue) <= 1 or e.English_CheckValue not like '%[a-zA-Z]%'" }
        default        { "" }
    }

    return @"
with EvaluatedRows as (
    select r.RootId,
           coalesce(max(case when lang.LanguageType = 'English' then l.TranslationItem end), r.RootItem) as [English_CheckValue]
    from dbo.RootTranslation r
    left join dbo.LanguageTranslations l on r.RootId = l.RootId
    left join dbo.Languages lang on l.LanguageId = lang.LanguageId
    group by r.RootId, r.RootItem
)
select r.RootId,
        $caseSelects
from dbo.RootTranslation r
join EvaluatedRows e on r.RootId = e.RootId
left join dbo.LanguageTranslations l on r.RootId = l.RootId and l.LanguageId in ($idList)
left join dbo.Languages lang on l.LanguageId = lang.LanguageId
$whereClause
group by r.RootId, r.RootItem
order by r.RootId;
"@
}

function Get-MissingTranslationSql {
    param([Parameter(Mandatory = $true)][int[]]$LanguageIds)

    $idList = ($LanguageIds | Sort-Object -Unique) -join ','
    $languageRows = @(Get-LanguageSelectionMetadata -LanguageIds $LanguageIds)
    $languageRows = @($languageRows | Sort-Object -Property @{ Expression = { if ($_.LanguageType -eq 'English') { 0 } else { 1 } } }, LanguageId)
    $targetRows = @($languageRows | Where-Object { $_.LanguageType -ne 'English' })

    $caseSelects = ($languageRows | ForEach-Object {
        $langName = $_.LanguageType.Replace("'", "''")
        $escapedColumnName = $_.LanguageType.Replace(']', ']]')

        if ($_.LanguageType -eq 'English') {
            "coalesce(max(case when lang.LanguageType = 'English' then l.TranslationItem end), r.RootItem) as [English]"
        }
        else {
            "max(case when lang.LanguageType = '$langName' then l.TranslationItem end) as [$escapedColumnName]"
        }
    }) -join ",`n        "

    if ($targetRows.Count -eq 0) {
        $missingConditions = "1 = 0"
    }
    else {
        $missingConditions = ($targetRows | ForEach-Object {
            $languageId = [int]$_.LanguageId
            "max(case when l.LanguageId = $languageId and nullif(ltrim(rtrim(l.TranslationItem)), '') is not null then 1 else 0 end) = 0"
        }) -join "`n    or "
    }

    return @"
with EvaluatedRows as (
    select r.RootId,
           coalesce(max(case when lang.LanguageType = 'English' then l.TranslationItem end), r.RootItem) as [English_CheckValue]
    from dbo.RootTranslation r
    left join dbo.LanguageTranslations l on r.RootId = l.RootId
    left join dbo.Languages lang on l.LanguageId = lang.LanguageId
    group by r.RootId, r.RootItem
)
select r.RootId,
        $caseSelects
from dbo.RootTranslation r
join EvaluatedRows e on r.RootId = e.RootId
left join dbo.LanguageTranslations l on r.RootId = l.RootId and l.LanguageId in ($idList)
left join dbo.Languages lang on l.LanguageId = lang.LanguageId
where len(e.English_CheckValue) > 1 and e.English_CheckValue like '%[a-zA-Z]%'
group by r.RootId, r.RootItem
having $missingConditions
order by r.RootId;
"@
}

function Read-TranslationExportContentScope {
    while ($true) {
        Write-Host ''
        Write-Host 'Content to export:' -ForegroundColor Cyan
        Write-Host '1) All content selected by the export type (default)'
        Write-Host '2) Only missing translations (translatable English text where a selected target language is NULL or empty)'
        Write-Host 'q) Back to Export Language File'
        $choice = Read-Host 'Choose what to export (Enter = all content)'
        if (Test-IsBack $choice) { return $null }
        if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq '1') { return 'All' }
        if ($choice -eq '2') { return 'Missing' }
        Write-Host 'Choose 1, 2, or q.' -ForegroundColor Yellow
    }
}

function Show-ExtractionMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== Export Language File ===" -ForegroundColor Cyan
        Write-Host "1) Export all translation entries"
        Write-Host "2) Export only text that should be translated"
        Write-Host "3) Export fixed items that usually should not be translated"
        Write-Host "q) Back"
        $sub = Read-Host "Choose a report"

        if (Test-IsBack $sub) { return }
        if ($sub -in @('1', '2', '3')) {
            try {
                $langs = Get-LanguageCatalog
                $selectedIds = Prompt-LanguageSelection -Languages $langs -AllowCreateNew $true
                if ($null -eq $selectedIds) { continue }

                $contentScope = Read-TranslationExportContentScope
                if ($null -eq $contentScope) { continue }

                $filterType = switch ($sub) {
                    '1' { 'Full' }
                    '2' { 'Translatable' }
                    '3' { 'Fixed' }
                }
                $filePrefix = switch ($sub) {
                    '1' { 'All_Translations' }
                    '2' { 'Text_To_Translate' }
                    '3' { 'Fixed_Items' }
                }
                $title = switch ($sub) {
                    '1' { 'All Translation Entries' }
                    '2' { 'Text That Should Be Translated' }
                    '3' { 'Fixed Items That Usually Should Not Be Translated' }
                }

                if ($contentScope -eq 'Missing') {
                    $selectedMetadata = @(Get-LanguageSelectionMetadata -LanguageIds $selectedIds)
                    if (@($selectedMetadata | Where-Object { $_.LanguageType -ne 'English' }).Count -eq 0) {
                        Write-Host 'Choose at least one target language besides English to export missing translations.' -ForegroundColor Yellow
                        Pause-Screen
                        continue
                    }

                    $filePrefix = 'Missing_Translations'
                    $title = 'Missing Translations (Translatable English Text)'
                    Write-Host 'Missing-only export uses translatable English text and excludes fixed codes or technical values.' -ForegroundColor Gray
                    $sql = Get-MissingTranslationSql -LanguageIds $selectedIds
                }
                else {
                    $sql = Get-DynamicPivotSql -LanguageIds $selectedIds -FilterType $filterType
                }

                Write-StreamingLog -Percent 30 -Step 'Export language file' -Description "Loading $title."
                $data = Invoke-TranslationQuery -Query $sql
                Write-StreamingLog -Percent 100 -Step 'Export language file' -Description "Loaded $(@($data).Count) row(s)."
                Show-OutputMenu -Data @($data) -FileNamePrefix $filePrefix -Title $title
            }
            catch {
                Show-LoggedError -Prefix "The language file could not be exported" -Context "Export Language File" -ErrorRecord $_
                Pause-Screen
            }
        }
        else {
            Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

function Show-TranslationImportMenu {
    Clear-Host
    Show-SectionTitle "Import new Language with a translated CSV file"
    Write-Host "This tool imports a translated CSV file into LanguageTranslations for a selected language." -ForegroundColor Cyan
    Write-Host "It creates a LanguageTranslations backup before applying changes." -ForegroundColor Cyan
    Write-Host "Blank translated cells are ignored." -ForegroundColor Cyan
    Write-Host ""

    try {
        $targetLanguage = Prompt-ImportTargetLanguage
        if ($null -eq $targetLanguage) { return }

        $importFolder = Prompt-TranslationImportFolder
        if ($null -eq $importFolder) { return }

        $csvPath = Prompt-TranslationImportCsvFile -FolderPath $importFolder
        if ($null -eq $csvPath) { return }

        $importData = Get-TranslationImportRows -CsvPath $csvPath -TargetLanguage $targetLanguage
        if ($null -eq $importData) { return }

        if ($importData.Rows.Count -eq 0) {
            Write-Host "No rows are eligible for import. All translated cells were blank or RootId values were invalid." -ForegroundColor Yellow
            Pause-Screen
            return
        }

        Write-Host ""
        Write-Host "Import summary:" -ForegroundColor Cyan
        Write-Host "  Target language: [$($targetLanguage.LanguageId)] $($targetLanguage.LanguageType)"
        Write-Host "  CSV file: $csvPath"
        Write-Host "  CSV rows read: $($importData.SourceRowCount)"
        Write-Host "  Rows eligible for import: $($importData.Rows.Count)"
        Write-Host "  Blank translated cells skipped: $($importData.BlankTranslations)"
        Write-Host "  Invalid RootId rows skipped: $($importData.InvalidRootIds)"
        Write-Host "  Duplicate RootId rows collapsed using the last non-empty value: $($importData.DuplicateRootIds)"
        Write-Host "  RootId column: $($importData.RootColumn)"
        if ($null -ne $importData.EnglishColumn) {
            Write-Host "  English column: $($importData.EnglishColumn)"
        }
        else {
            Write-Host "  English column: not found; database RootTranslation text will be used in the preview." -ForegroundColor Yellow
        }
        Write-Host "  Translation column: $($importData.TranslationColumn)"
        Write-Host ""

        $confirm = Read-Host "Type IMPORT to create a backup, stage the CSV, and preview the database changes"
        if ($confirm -cne 'IMPORT') {
            Write-Host "Import cancelled before any database changes were made." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $stagingTable = $null
        $migrationStarted = $false

        try {
            Write-StreamingLog -Percent 10 -Step "Backup" -Description "Copying LanguageTranslations."
            $backupTable = New-LanguageTranslationsBackupTable -Timestamp $timestamp
            Write-Host "Backup table created: $backupTable" -ForegroundColor Green

            Write-StreamingLog -Percent 35 -Step "Stage" -Description "Creating import staging table."
            $stagingTable = New-TranslationImportStagingTable -TargetLanguage $targetLanguage -Timestamp $timestamp
            Add-TranslationImportStagingRows -StagingTableName $stagingTable -Rows $importData.Rows
            Write-Host "Staging table populated: $stagingTable" -ForegroundColor Green

            Write-StreamingLog -Percent 65 -Step "Migrate" -Description "Applying updates and inserts inside a preview transaction."
            $migrationStarted = $true
            $isIdentity = Test-LanguageTranslationsIdentityColumn
            $result = Invoke-TranslationImportMigration -StagingTableName $stagingTable -TargetLanguage $targetLanguage -TranslationIdIsIdentity $isIdentity

            Write-StreamingLog -Percent 95 -Step "Cleanup" -Description "Dropping import staging table."
            Remove-TranslationImportStagingTable -StagingTableName $stagingTable
            Write-Host "Staging table removed: $stagingTable" -ForegroundColor Green

            Write-Host ""
            if ($result.Committed) {
                Write-Host "Import complete. Rows updated: $($result.UpdatedRows). Rows inserted: $($result.InsertedRows)." -ForegroundColor Green
            }
            else {
                Write-Host "Import preview was rolled back. Backup table was kept; staging table was removed." -ForegroundColor Cyan
            }
        }
        catch {
            if (-not $migrationStarted -and -not [string]::IsNullOrWhiteSpace($stagingTable)) {
                try { Remove-TranslationImportStagingTable -StagingTableName $stagingTable } catch {}
            }

                Show-LoggedError -Prefix "The import did not complete" -Context "Import new Language with a translated CSV file" -ErrorRecord $_
            if ($migrationStarted -and -not [string]::IsNullOrWhiteSpace($stagingTable)) {
                Write-Host "The staging table was kept for troubleshooting: $stagingTable" -ForegroundColor Yellow
            }
        }

        Pause-Screen
    }
    catch {
        Show-LoggedError -Prefix "The import could not start" -Context "Start translated CSV import" -ErrorRecord $_
        Pause-Screen
    }
}

function Invoke-LuleburgasAssemblyRulesSettings {
    Clear-Host
    Show-SectionTitle "Copy P4A Settings (AssemblyRules)"
    Write-Host "This option should be executed on newly installed Danone sites." -ForegroundColor Cyan
    Write-Host "It imports the same P4A System Settings used in Danone Turkey (Luleburgas)." -ForegroundColor Cyan
    Write-Host ""

    try {
        $sqlFile = Get-RequiredScriptFolderFilePath `
            -FileName 'AssemblyRules_Luleburgas.sql' `
            -DownloadUrl 'https://raw.githubusercontent.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools/main/AssemblyRules_Luleburgas.sql' `
            -FeatureName 'Import Luleburgas System Settings'
        Assert-AssemblyRulesImportFileIsStagingOnly -FilePath $sqlFile

        Write-Host "SQL file: $sqlFile" -ForegroundColor Gray
        Write-Host "The script will create a temporary table named AssemblyRules_Luleburgas, then compare current and new values." -ForegroundColor Yellow
        $confirm = Read-Host "Type LOAD to create the staging table and show the comparison"
        if ($confirm -cne 'LOAD') {
            Write-Host "Operation cancelled. No database changes were made." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        Write-StreamingLog -Percent 20 -Step "Stage" -Description "Preparing AssemblyRules_Luleburgas staging table."
        [void](Invoke-TranslationQuery -Query "if object_id(N'dbo.AssemblyRules_Luleburgas', N'U') is not null drop table dbo.[AssemblyRules_Luleburgas];")
        [void](Invoke-TranslationSqlFile -FilePath $sqlFile)
        Write-Host "Temporary table created: AssemblyRules_Luleburgas" -ForegroundColor Green

        Write-StreamingLog -Percent 45 -Step "Compare" -Description "Comparing current AssemblyRules values with Luleburgas settings."
        $compareQuery = @"
select
    p.AssemblyName,
    p.RuleName,
    p.ContentCode,
    p.RuleNumericValue as CurrentValue,
    t.RuleNumericValue as NewValue
from dbo.AssemblyRules as p
inner join dbo.AssemblyRules_Luleburgas as t
    on  p.AssemblyName = t.AssemblyName
    and p.RuleName     = t.RuleName
    and p.ContentCode  = t.ContentCode
where isnull(p.RuleNumericValue, -2147483648) <> isnull(t.RuleNumericValue, -2147483648)
order by p.AssemblyName, p.RuleName, p.ContentCode;
"@
        $differences = @(Invoke-TranslationQuery -Query $compareQuery)
        Show-SectionTitle "Current vs New P4A Settings"
        Show-ConsoleResults -Data $differences

        if ($differences.Count -eq 0) {
            Write-Host "No different AssemblyRules settings were found." -ForegroundColor Cyan
            [void](Invoke-TranslationQuery -Query "drop table dbo.[AssemblyRules_Luleburgas];")
            Write-Host "Temporary table removed: AssemblyRules_Luleburgas" -ForegroundColor Green
            Pause-Screen
            return
        }

        Write-Host ""
        Write-Host "A backup of dbo.AssemblyRules will be created before applying the update." -ForegroundColor Yellow
        $apply = Read-Host "Type UPDATE to copy the Luleburgas settings into AssemblyRules"
        if ($apply -cne 'UPDATE') {
            [void](Invoke-TranslationQuery -Query "drop table dbo.[AssemblyRules_Luleburgas];")
            Write-Host "Operation cancelled. Temporary table removed. No AssemblyRules values were changed." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        $backupTable = New-DatabaseTableBackup -TableName "AssemblyRules"
        Write-Host "Backup table created: $backupTable" -ForegroundColor Green

        Write-StreamingLog -Percent 75 -Step "Update" -Description "Copying Luleburgas RuleNumericValue settings into AssemblyRules."
        $updateQuery = @"
update p
set p.RuleNumericValue = t.RuleNumericValue
from dbo.AssemblyRules as p
inner join dbo.AssemblyRules_Luleburgas as t
    on  p.AssemblyName = t.AssemblyName
    and p.RuleName     = t.RuleName
    and p.ContentCode  = t.ContentCode;
"@
        [void](Invoke-TranslationQuery -Query $updateQuery)
        [void](Invoke-TranslationQuery -Query "drop table dbo.[AssemblyRules_Luleburgas];")

        Write-Host "Operation complete. Temporary table removed: AssemblyRules_Luleburgas" -ForegroundColor Green
        Write-Host "Please log out and log back in from the D4A front end to see the changes applied." -ForegroundColor Yellow
        Pause-Screen
    }
    catch {
        try {
            if (Test-TranslationTableExists -TableName "AssemblyRules_Luleburgas") {
                [void](Invoke-TranslationQuery -Query "drop table dbo.[AssemblyRules_Luleburgas];")
            }
        }
        catch {}

        Show-LoggedError -Prefix "The Luleburgas AssemblyRules import failed" -Context "Import Luleburgas System Settings - AssemblyRules" -ErrorRecord $_
        Pause-Screen
    }
}

function Enable-ProcessReliabilityReport {
    Clear-Host
    Show-SectionTitle "Enable the Process Reliability Report"
    Write-Host "This option enables the Process Reliability report in the D4A front end." -ForegroundColor Cyan
    Write-Host ""

    try {
        Write-StreamingLog -Percent 25 -Step "Check" -Description "Checking whether the Process Reliability link already exists."
        $existingQuery = @"
select top 20 *
from dbo.SystemGroupLinks
where LinkTitle = 'Process Reliability Report'
   or WebRoute = 'ProcessReliabilityReport'
   or ExternalURL = 'ProcessReliability/ProcessReliabilityReport.aspx';
"@
        $existing = @(Invoke-TranslationQuery -Query $existingQuery)
        if ($existing.Count -gt 0) {
            Write-Host "The Process Reliability report link already appears to exist." -ForegroundColor Yellow
            Show-ConsoleResults -Data $existing
            Pause-Screen
            return
        }

        $confirm = Read-Host "Type ENABLE to insert the Process Reliability report link"
        if ($confirm -cne 'ENABLE') {
            Write-Host "Operation cancelled. No database changes were made." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        $backupTable = New-DatabaseTableBackup -TableName "SystemGroupLinks"
        Write-Host "Backup table created: $backupTable" -ForegroundColor Green

        Write-StreamingLog -Percent 75 -Step "Insert" -Description "Inserting the Process Reliability report link."
        $insertQuery = @"
insert into dbo.SystemGroupLinks (LinkTitle, SystemGroupId, LinkType, LinkedName, LinkedAssemblyType, IsReport, ReportId, WebRoute, ContentCode, UsesCOMPort, ExternalURL)
values ('Process Reliability Report', 18, 'Link', '', '', 1, -1, 'ProcessReliabilityReport', 'P4A0100', 0, 'ProcessReliability/ProcessReliabilityReport.aspx');
"@
        try {
            [void](Invoke-TranslationQuery -Query $insertQuery)
        }
        catch {
            if ($_.Exception.Message -match 'IDENTITY_INSERT') {
                $fallbackQuery = @"
set identity_insert dbo.SystemGroupLinks on;

insert into dbo.SystemGroupLinks (LinkTitle, SystemGroupId, LinkType, LinkedName, LinkedAssemblyType, IsReport, ReportId, WebRoute, ContentCode, UsesCOMPort, ExternalURL)
values ('Process Reliability Report', 18, 'Link', '', '', 1, -1, 'ProcessReliabilityReport', 'P4A0100', 0, 'ProcessReliability/ProcessReliabilityReport.aspx');

set identity_insert dbo.SystemGroupLinks off;
"@
                [void](Invoke-TranslationQuery -Query $fallbackQuery)
            }
            else {
                throw
            }
        }

        Write-Host "Process Reliability report link inserted successfully." -ForegroundColor Green
        Write-Host "Important: you should now be able to enable the Process Reliability report in the Role Administration menu." -ForegroundColor Yellow
        Pause-Screen
    }
    catch {
        Show-LoggedError -Prefix "The Process Reliability report setup failed" -Context "Import Luleburgas System Settings - Process Reliability" -ErrorRecord $_
        Pause-Screen
    }
}

function Get-SqlFilePotentialModifiedTables {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $sqlText = Get-Content -LiteralPath $FilePath -Raw
    $patterns = @(
        '(?im)\binsert\s+into\s+(?:\[dbo\]\.|\bdbo\.)?\[?([A-Za-z_][A-Za-z0-9_]*)\]?',
        '(?im)\bupdate\s+(?:\[dbo\]\.|\bdbo\.)?\[?([A-Za-z_][A-Za-z0-9_]*)\]?',
        '(?im)\bdelete\s+from\s+(?:\[dbo\]\.|\bdbo\.)?\[?([A-Za-z_][A-Za-z0-9_]*)\]?',
        '(?im)\bmerge\s+(?:into\s+)?(?:\[dbo\]\.|\bdbo\.)?\[?([A-Za-z_][A-Za-z0-9_]*)\]?'
    )

    $tables = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $patterns) {
        foreach ($match in [System.Text.RegularExpressions.Regex]::Matches($sqlText, $pattern)) {
            if ($match.Groups.Count -lt 2) { continue }

            $tableName = [string]$match.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($tableName)) { continue }
            if ($tableName -match '(?i)(backup|_bak|temp|staging)') { continue }
            if (-not (Test-SafeSqlIdentifier -Identifier $tableName)) { continue }
            if (-not (Test-TranslationTableExists -TableName $tableName)) { continue }

            [void]$tables.Add($tableName)
        }
    }

    return @($tables | Sort-Object -Unique)
}

function Invoke-LuleburgasRolePermissionsImport {
    Clear-Host
    Show-SectionTitle "Import Luleburgas User Roles and Privileges"
    Write-Host "This option imports the user roles and privileges used in Danone Turkey (Luleburgas)." -ForegroundColor Cyan
    Write-Host "The SQL file is expected to create its own backups where needed." -ForegroundColor Cyan
    Write-Host ""

    try {
        $sqlFile = Get-RequiredScriptFolderFilePath `
            -FileName 'RoleAdminLuleburgaz-DanoneStandard-090426.sql' `
            -DownloadUrl 'https://raw.githubusercontent.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools/main/RoleAdminLuleburgaz-DanoneStandard-090426.sql' `
            -FeatureName 'Import Luleburgas User Roles and Privileges'

        Write-Host "SQL file: $sqlFile" -ForegroundColor Gray
        $modifiedTables = @(Get-SqlFilePotentialModifiedTables -FilePath $sqlFile)
        if ($modifiedTables.Count -gt 0) {
            Write-Host "Detected table(s) that may be modified by this SQL file: $($modifiedTables -join ', ')" -ForegroundColor Yellow
        }
        else {
            Write-Host "No existing target tables could be detected automatically in the SQL file. The script will still rely on the SQL file's own safeguards." -ForegroundColor Yellow
        }

        $confirm = Read-Host "Type IMPORT to execute the Luleburgas user roles and privileges SQL file"
        if ($confirm -cne 'IMPORT') {
            Write-Host "Operation cancelled. No database changes were made." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        foreach ($tableName in $modifiedTables) {
            $backupTable = New-DatabaseTableBackup -TableName $tableName
            Write-Host "Backup table created: $backupTable" -ForegroundColor Green
        }

        Write-StreamingLog -Percent 50 -Step "SQL file" -Description "Executing Luleburgas user roles and privileges script."
        [void](Invoke-TranslationSqlFile -FilePath $sqlFile)
        Write-StreamingLog -Percent 100 -Step "Done" -Description "User roles and privileges script completed."
        Write-Host "Luleburgas user roles and privileges import complete." -ForegroundColor Green
        Pause-Screen
    }
    catch {
        Show-LoggedError -Prefix "The Luleburgas user roles and privileges import failed" -Context "Import Luleburgas User Roles and Privileges" -ErrorRecord $_
        Pause-Screen
    }
}

function Show-LuleburgasSystemSettingsMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== Import Luleburgas System Settings ===" -ForegroundColor Cyan
        Write-Host "1) Copy P4A settings (AssemblyRules)"
        Write-Host "2) Enable the Process Reliability report"
        Write-Host "q) Back"
        $choice = Read-Host "Choose an option"

        if (Test-IsBack $choice) { return }

        switch ($choice) {
            '1' { Invoke-LuleburgasAssemblyRulesSettings }
            '2' { Enable-ProcessReliabilityReport }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Get-LineDetailedViewSetupSql {
    return @'
SET NOCOUNT ON;
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @ContentCode nvarchar(50) = N'P4A0096';
    DECLARE @RealTimeGroupNum int;
    DECLARE @ValueComponentKey nvarchar(50) =
        N'902F8469-3A1F-4EDD-B488-6A4D650DE813';

    ------------------------------------------------------------
    -- 1. Find the Real Time group
    ------------------------------------------------------------

    -- Preferred source: use the same group as Event Log.
    SELECT TOP (1)
        @RealTimeGroupNum = SystemGroupId
    FROM SystemGroupLinks
    WHERE WebRoute = 'eventlog';

    -- Fallback: retain the existing Line Detailed View group.
    IF @RealTimeGroupNum IS NULL
    BEGIN
        SELECT TOP (1)
            @RealTimeGroupNum = SystemGroupId
        FROM SystemGroupLinks
        WHERE WebRoute = 'LineDetailedView'
           OR ContentCode = @ContentCode;
    END;

    -- Final fallback: locate the Real Time group by name/title.
    IF @RealTimeGroupNum IS NULL
    BEGIN
        SELECT TOP (1)
            @RealTimeGroupNum = SystemGroupId
        FROM SystemGroups
        WHERE
        (
            GroupName IN ('Real Time', 'RealTime')
            OR GroupTitle IN ('Real Time', 'RealTime')
        )
        AND ISNULL(Active, 1) = 1
        ORDER BY SystemGroupId;
    END;

    IF @RealTimeGroupNum IS NULL
    BEGIN
        THROW 50001,
            'The Real Time SystemGroupId could not be found. Verify the Event Log link and SystemGroups configuration.',
            1;
    END;

    ------------------------------------------------------------
    -- 2. Add or repair the menu link
    ------------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1
        FROM SystemGroupLinks
        WHERE WebRoute = 'LineDetailedView'
           OR ContentCode = @ContentCode
    )
    BEGIN
        INSERT INTO SystemGroupLinks
        (
            LinkTitle,
            SystemGroupId,
            LinkType,
            LinkedName,
            LinkedAssemblyType,
            IsReport,
            ReportId,
            WebRoute,
            ContentCode,
            HasKpis
        )
        VALUES
        (
            'Line Detailed View',
            @RealTimeGroupNum,
            'Link',
            '',
            '',
            0,
            -1,
            'LineDetailedView',
            'P4A0096',
            1
        );
    END;
    ELSE
    BEGIN
        UPDATE SystemGroupLinks
        SET LinkTitle         = 'Line Detailed View',
            SystemGroupId     = @RealTimeGroupNum,
            LinkType          = 'Link',
            LinkedName        = '',
            LinkedAssemblyType = '',
            IsReport          = 0,
            ReportId          = -1,
            WebRoute          = 'LineDetailedView',
            ContentCode       = @ContentCode,
            HasKpis           = 1
        WHERE WebRoute = 'LineDetailedView'
           OR ContentCode = @ContentCode;
    END;

    ------------------------------------------------------------
    -- 3. Define KPI rules 1 through 8
    ------------------------------------------------------------

    DECLARE @KpiRules table
    (
        RuleName varchar(255) NOT NULL,
        RuleNumericValue numeric(18, 0) NOT NULL,
        RuleDescription varchar(255) NULL
    );

    INSERT INTO @KpiRules
    (
        RuleName,
        RuleNumericValue,
        RuleDescription
    )
    VALUES
        ('Line Detailed View KPI 1',  8, 'Determines the 1st KPI to show'),
        ('Line Detailed View KPI 2',  9, 'Determines the 2nd KPI to show'),
        ('Line Detailed View KPI 3', 10, 'Determines the 3rd KPI to show'),
        ('Line Detailed View KPI 4', 28, 'Determines the 4th KPI to show'),
        ('Line Detailed View KPI 5',  6, 'Determines the 5th KPI to show'),
        ('Line Detailed View KPI 6',  4, 'Determines the 6th KPI to show'),
        ('Line Detailed View KPI 7',  7, 'Determines the 7th KPI to show'),
        ('Line Detailed View KPI 8', 30, 'Determines the 8th KPI to show');

    ------------------------------------------------------------
    -- 4. Update existing Assembly Rules
    ------------------------------------------------------------

    UPDATE AR
    SET AR.AssemblyName          = 'Line Detailed View',
        AR.RuleNumericValue      = R.RuleNumericValue,
        AR.RuleDescription       = R.RuleDescription,
        AR.WorkStationId         = -1,
        AR.UserId                = -1,
        AR.RoleId                = -1,
        AR.RuleType              = 0,
        AR.RuleEnabled           = 1,
        AR.ContentCode           = @ContentCode,
        AR.ControlType           = 'Dropdown',
        AR.RuleGroup             = 'KPIs',
        AR.LookUpStoredProcedure = 'D4A_GetKPIs',
        AR.LookUpKeyField        = 'KPIID',
        AR.LookUpDescField       = 'KPIDesc'
    FROM AssemblyRules AS AR
    INNER JOIN @KpiRules AS R
        ON R.RuleName = AR.RuleName
    WHERE AR.ContentCode = @ContentCode;

    ------------------------------------------------------------
    -- 5. Insert missing Assembly Rules
    ------------------------------------------------------------

    INSERT INTO AssemblyRules
    (
        AssemblyName,
        RuleName,
        RuleName_Visible,
        RuleNumericValue,
        RuleDescription,
        WorkStationId,
        UserId,
        RoleId,
        RuleType,
        RuleEnabled,
        ContentCode,
        ControlType,
        RuleGroup,
        LookUpStoredProcedure,
        LookUpKeyField,
        LookUpDescField
    )
    SELECT
        'Line Detailed View',
        R.RuleName,
        NULL,
        R.RuleNumericValue,
        R.RuleDescription,
        -1,
        -1,
        -1,
        0,
        1,
        @ContentCode,
        'Dropdown',
        'KPIs',
        'D4A_GetKPIs',
        'KPIID',
        'KPIDesc'
    FROM @KpiRules AS R
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM AssemblyRules AS AR
        WHERE AR.ContentCode = @ContentCode
          AND AR.RuleName = R.RuleName
    );

    ------------------------------------------------------------
    -- 6. Ensure the default "Value" KPI component exists
    ------------------------------------------------------------

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.D4A_Kpis_ComponentType
        WHERE KPIKey = @ValueComponentKey
    )
    BEGIN
        INSERT INTO dbo.D4A_Kpis_ComponentType
        (
            KPIKey,
            KPIName
        )
        VALUES
        (
            @ValueComponentKey,
            'Value'
        );
    END;

    ------------------------------------------------------------
    -- 7. Create KPI detail records for selected active KPIs
    ------------------------------------------------------------

    INSERT INTO dbo.D4A_Kpis_DtlSettings
    (
        KPIID,
        ContentCode,
        KPIComponentType,
        BoundaryMin,
        BoundaryMax,
        OnTargetFormattingKey,
        OffTargetFormattingKey
    )
    SELECT DISTINCT
        K.KPIID,
        @ContentCode,
        @ValueComponentKey,
        0,
        100,
        NULL,
        NULL
    FROM AssemblyRules AS AR
    INNER JOIN dbo.D4A_KPIs AS K
        ON K.KPIID = TRY_CONVERT(int, AR.RuleNumericValue)
    WHERE AR.ContentCode = @ContentCode
      AND AR.RuleName LIKE 'Line Detailed View KPI %'
      AND K.Active = 1
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.D4A_Kpis_DtlSettings AS DS
          WHERE DS.ContentCode = @ContentCode
            AND DS.KPIID = K.KPIID
      );

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
'@
}

function Show-LineDetailedViewValidationResults {
    Show-SectionTitle "Line Detailed View Menu Link"
    $menuLinkQuery = @"
select
    SGL.*
from dbo.SystemGroupLinks as SGL
where SGL.WebRoute = 'LineDetailedView'
   or SGL.ContentCode = 'P4A0096';
"@
    Show-ConsoleResults -Data @(Invoke-TranslationQuery -Query $menuLinkQuery)

    Show-SectionTitle "Line Detailed View Assembly Rules"
    $rulesQuery = @"
select
    AR.AssemblyRuleId,
    AR.AssemblyName,
    AR.RuleName,
    AR.RuleNumericValue,
    AR.RuleEnabled,
    AR.ContentCode
from dbo.AssemblyRules as AR
where AR.ContentCode = 'P4A0096'
  and AR.RuleName like 'Line Detailed View KPI %'
order by
    try_convert(int, replace(AR.RuleName, 'Line Detailed View KPI ', ''));
"@
    Show-ConsoleResults -Data @(Invoke-TranslationQuery -Query $rulesQuery)

    Show-SectionTitle "Line Detailed View KPI Details"
    $kpiDetailQuery = @"
select
    DS.KPIID,
    K.KPIDesc,
    K.KPIField,
    K.Active,
    DS.ContentCode,
    DS.KPIComponentType,
    CT.KPIName as ComponentType,
    DS.BoundaryMin,
    DS.BoundaryMax
from dbo.D4A_Kpis_DtlSettings as DS
inner join dbo.D4A_KPIs as K
    on K.KPIID = DS.KPIID
left join dbo.D4A_Kpis_ComponentType as CT
    on CT.KPIKey = DS.KPIComponentType
where DS.ContentCode = 'P4A0096'
order by DS.KPIID;
"@
    Show-ConsoleResults -Data @(Invoke-TranslationQuery -Query $kpiDetailQuery)
}

function Enable-LineDetailedView {
    Clear-Host
    Show-SectionTitle "Enable Line Detailed View"
    Write-Host "This option adds or repairs the Line Detailed View menu link and KPI configuration." -ForegroundColor Cyan
    Write-Host "Backups are created before changing SystemGroupLinks, AssemblyRules, D4A_Kpis_ComponentType, and D4A_Kpis_DtlSettings." -ForegroundColor Cyan
    Write-Host "Connected to: $($Global:SelectedInstance) / $($Global:SelectedDb)" -ForegroundColor Gray
    Write-Host ""

    try {
        Assert-LineDetailedViewSchema

        $previewQuery = @"
select
    (select count(*) from dbo.SystemGroupLinks where WebRoute = 'LineDetailedView' or ContentCode = 'P4A0096') as ExistingMenuLinks,
    (select count(*) from dbo.AssemblyRules where ContentCode = 'P4A0096' and RuleName like 'Line Detailed View KPI %') as ExistingKpiRules,
    (select count(*) from dbo.D4A_Kpis_ComponentType where KPIKey = '902F8469-3A1F-4EDD-B488-6A4D650DE813') as ExistingValueComponents,
    (select count(*) from dbo.D4A_Kpis_DtlSettings where ContentCode = 'P4A0096') as ExistingKpiDetails;
"@
        Show-SectionTitle "Current Line Detailed View Records"
        Show-ConsoleResults -Data @(Invoke-TranslationQuery -Query $previewQuery)

        Write-Host ""
        Write-Host "Type ENABLE to create backups and enable Line Detailed View, or type q to go back." -ForegroundColor Yellow
        $confirm = Read-Host "Confirmation"
        if (Test-IsBack $confirm) { return }
        if ($confirm -cne 'ENABLE') {
            Write-Host "Operation cancelled. No database changes were made." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        $targetTables = @(
            'SystemGroupLinks',
            'AssemblyRules',
            'D4A_Kpis_ComponentType',
            'D4A_Kpis_DtlSettings'
        )
        $backupRows = New-Object System.Collections.Generic.List[PSObject]

        $index = 0
        foreach ($tableName in $targetTables) {
            $index++
            $percent = 10 + [int](($index / $targetTables.Count) * 35)
            Write-StreamingLog -Percent $percent -Step "Backup" -Description "Creating backup for dbo.$tableName."
            $backupTable = New-DatabaseTableBackup -TableName $tableName
            $backupRows.Add([pscustomobject]@{
                SourceTable = "dbo.$tableName"
                BackupTable = "dbo.$backupTable"
            })
        }

        Show-SectionTitle "Backups Created"
        Show-ConsoleResults -Data @($backupRows)

        Write-StreamingLog -Percent 70 -Step "Configure" -Description "Adding or repairing Line Detailed View configuration."
        [void](Invoke-TranslationQuery -Query (Get-LineDetailedViewSetupSql))

        Write-StreamingLog -Percent 95 -Step "Validate" -Description "Reading Line Detailed View validation results."
        Show-LineDetailedViewValidationResults

        Write-StreamingLog -Percent 100 -Step "Done" -Description "Line Detailed View configuration completed."
        Write-Host ""
        Write-Host "Line Detailed View has been enabled or repaired successfully." -ForegroundColor Green
        Write-Host "Important: enable Line Detailed View for the appropriate role in Role Administration, then sign out and back in so the authorized menu links are reloaded." -ForegroundColor Yellow
        Pause-Screen
    }
    catch {
        Show-LoggedError -Prefix "Line Detailed View setup failed" -Context "Database Tools - Enable Line Detailed View" -ErrorRecord $_
        Pause-Screen
    }
}

function Test-IsDatabaseToolBack {
    param([AllowNull()][string]$InputVal)

    if (Test-IsBack $InputVal) { return $true }
    if ([string]::IsNullOrWhiteSpace($InputVal)) { return $false }

    $value = $InputVal.Trim().ToLowerInvariant()
    return ($value -eq 'q' -or $value -eq 'quit')
}

function ConvertTo-DatabaseObjectNameInput {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }

    $cleanName = Normalize-UserPath $Name
    $cleanName = $cleanName.Replace('[', '').Replace(']', '')
    if ($cleanName -match '^(?i:dbo)\.(.+)$') {
        $cleanName = $Matches[1]
    }

    return $cleanName.Trim()
}

function Test-SafeSqlIdentifier {
    param([AllowNull()][string]$Identifier)

    if ([string]::IsNullOrWhiteSpace($Identifier)) { return $false }
    return ($Identifier -match '^[A-Za-z_][A-Za-z0-9_]{0,127}$')
}

function Get-QuotedSqlColumnName {
    param([Parameter(Mandatory = $true)][object]$ColumnName)

    $columnNameText = ConvertTo-RequiredText -Value $ColumnName -Purpose "SQL column name"
    return "[$($columnNameText.Replace(']', ']]'))]"
}

function Read-DatabaseTableName {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$DefaultValue = "",
        [switch]$MustExist,
        [switch]$DisallowExisting
    )

    while ($true) {
        $promptText = if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
            $Prompt
        }
        else {
            "$Prompt [$DefaultValue]"
        }

        $enteredName = Read-Host $promptText
        if (Test-IsDatabaseToolBack $enteredName) { return $null }
        if ([string]::IsNullOrWhiteSpace($enteredName) -and -not [string]::IsNullOrWhiteSpace($DefaultValue)) {
            $enteredName = $DefaultValue
        }

        $tableName = ConvertTo-DatabaseObjectNameInput $enteredName
        if (-not (Test-SafeSqlIdentifier -Identifier $tableName)) {
            Write-Host "Please enter a safe dbo table name using only letters, numbers, and underscores. It must not start with a number." -ForegroundColor Yellow
            continue
        }

        $exists = Test-TranslationTableExists -TableName $tableName
        if ($MustExist -and -not $exists) {
            Write-Host "The table dbo.$tableName does not exist. Please enter an existing table name." -ForegroundColor Red
            continue
        }

        if ($DisallowExisting -and $exists) {
            Write-Host "The table dbo.$tableName already exists. Overriding an existing table is dangerous, so this tool will not continue with that name." -ForegroundColor Red
            continue
        }

        return $tableName
    }
}

function Read-DatabaseColumnName {
    param(
        [Parameter(Mandatory = $true)][string]$TableName,
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    while ($true) {
        $enteredName = Read-Host $Prompt
        if (Test-IsDatabaseToolBack $enteredName) { return $null }

        $columnName = ConvertTo-DatabaseObjectNameInput $enteredName
        if (-not (Test-SafeSqlIdentifier -Identifier $columnName)) {
            Write-Host "Please enter a safe column name using only letters, numbers, and underscores. It must not start with a number." -ForegroundColor Yellow
            continue
        }

        if (-not (Test-TranslationColumnExists -TableName $TableName -ColumnName $columnName)) {
            Write-Host "The column dbo.$TableName.$columnName does not exist. Please enter an existing column name." -ForegroundColor Red
            continue
        }

        return $columnName
    }
}

function Test-ImportExcelCommandAvailable {
    if (Get-Command Import-Excel -ErrorAction SilentlyContinue) {
        return $true
    }

    if (Get-Module -ListAvailable -Name ImportExcel) {
        try {
            Import-Module ImportExcel -ErrorAction Stop
            if (Get-Command Import-Excel -ErrorAction SilentlyContinue) {
                return $true
            }
        }
        catch {
            Show-LoggedError -Prefix "Could not import the ImportExcel PowerShell module" -Context "Load ImportExcel PowerShell module" -ErrorRecord $_
        }
    }

    Write-Host "The ImportExcel PowerShell module is required to import .xlsx files." -ForegroundColor Yellow
    Write-Host "This tool can install it for the current Windows user." -ForegroundColor Yellow
    Write-Host "Command: Install-Module -Name ImportExcel -Scope CurrentUser -Force -AllowClobber" -ForegroundColor Gray
    $installChoice = Read-Host "Type INSTALL to install it now, or press Enter to cancel"
    if ($installChoice -cne 'INSTALL') {
        return $false
    }

    try {
        $installModuleCommand = Get-Command Install-Module -ErrorAction SilentlyContinue
        if (-not $installModuleCommand) {
            throw "Install-Module is not available. Install or repair PowerShellGet, then run this tool again."
        }

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $installModuleParams = @{
            Name        = 'ImportExcel'
            Scope       = 'CurrentUser'
            Force       = $true
            ErrorAction = 'Stop'
        }
        if ($installModuleCommand.Parameters.ContainsKey('AllowClobber')) {
            $installModuleParams['AllowClobber'] = $true
        }

        Install-Module @installModuleParams
        Import-Module ImportExcel -ErrorAction Stop

        if (Get-Command Import-Excel -ErrorAction SilentlyContinue) {
            Write-Host "ImportExcel PowerShell module installed and loaded successfully." -ForegroundColor Green
            Start-Sleep -Seconds 1
            return $true
        }

        throw "The ImportExcel module was installed, but Import-Excel is still not available in this PowerShell session."
    }
    catch {
        Show-LoggedError -Prefix "Could not install the ImportExcel PowerShell module" -Context "Install ImportExcel PowerShell module" -ErrorRecord $_
        Pause-Screen
        return $false
    }
}

function Read-CsvExcelImportFilePath {
    while ($true) {
        Write-Host ""
        Write-Host "Type q to go back, or enter a .csv/.xlsx file path or a folder path." -ForegroundColor DarkGray
        $enteredPath = Read-Host "File or folder path"
        if (Test-IsDatabaseToolBack $enteredPath) { return $null }

        $cleanPath = Normalize-UserPath $enteredPath
        if ([string]::IsNullOrWhiteSpace($cleanPath)) {
            Write-Host "Please enter a file or folder path." -ForegroundColor Yellow
            continue
        }

        if (Test-Path -LiteralPath $cleanPath -PathType Leaf) {
            $resolvedFile = Get-Item -LiteralPath $cleanPath
            if ($resolvedFile.Extension -in @('.csv', '.xlsx')) {
                return $resolvedFile.FullName
            }

            Write-Host "Only .csv and .xlsx files are supported." -ForegroundColor Red
            continue
        }

        if (Test-Path -LiteralPath $cleanPath -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $cleanPath -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in @('.csv', '.xlsx') } |
                Sort-Object LastWriteTime -Descending)

            if ($files.Count -eq 0) {
                Write-Host "No .csv or .xlsx files were found in that folder." -ForegroundColor Yellow
                continue
            }

            Write-Host ""
            Write-Host "Available import files, newest first:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $files.Count; $i++) {
                Write-Host "[$($i + 1)] $($files[$i].LastWriteTime.ToString('yyyy-MM-dd HH:mm'))  $($files[$i].Name)"
            }

            while ($true) {
                $fileChoice = Read-Host "Choose a file number, or type q to go back"
                if (Test-IsDatabaseToolBack $fileChoice) { return $null }

                $selectedFileIndex = 0
                if ([int]::TryParse($fileChoice, [ref]$selectedFileIndex) -and
                    $selectedFileIndex -ge 1 -and
                    $selectedFileIndex -le $files.Count) {
                    return $files[$selectedFileIndex - 1].FullName
                }

                Write-Host "That is not a valid file choice." -ForegroundColor Yellow
            }
        }

        Write-Host "That path could not be found. Please enter a valid file or folder path." -ForegroundColor Red
    }
}

function ConvertTo-StagingColumnMappings {
    param([Parameter(Mandatory = $true)][string[]]$OriginalColumnNames)

    $usedNames = @{}
    $mappings = New-Object System.Collections.Generic.List[PSObject]
    $columnNumber = 0

    foreach ($originalName in $OriginalColumnNames) {
        $columnNumber++
        $baseName = [string]$originalName
        if ([string]::IsNullOrWhiteSpace($baseName)) {
            $baseName = "Column$columnNumber"
        }

        $safeName = [System.Text.RegularExpressions.Regex]::Replace($baseName.Trim(), '[^A-Za-z0-9_]', '_')
        $safeName = [System.Text.RegularExpressions.Regex]::Replace($safeName, '_+', '_').Trim('_')
        if ([string]::IsNullOrWhiteSpace($safeName)) {
            $safeName = "Column$columnNumber"
        }
        if ($safeName -match '^[0-9]') {
            $safeName = "C_$safeName"
        }
        if ($safeName.Length -gt 120) {
            $safeName = $safeName.Substring(0, 120)
        }

        $candidate = $safeName
        $dedupeNumber = 2
        while ($usedNames.ContainsKey($candidate.ToLowerInvariant())) {
            $suffix = "_$dedupeNumber"
            $maxBaseLength = 128 - $suffix.Length
            $candidateBase = if ($safeName.Length -gt $maxBaseLength) { $safeName.Substring(0, $maxBaseLength) } else { $safeName }
            $candidate = "$candidateBase$suffix"
            $dedupeNumber++
        }

        $usedNames[$candidate.ToLowerInvariant()] = $true
        $mappings.Add([pscustomobject]@{
            OriginalName = $originalName
            ColumnName   = $candidate
        })
    }

    return @($mappings)
}

function ConvertTo-DataTableForSqlImport {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][object[]]$ColumnMappings
    )

    $dataTable = New-Object System.Data.DataTable
    foreach ($mapping in $ColumnMappings) {
        [void]$dataTable.Columns.Add([string]$mapping.ColumnName, [string])
    }

    foreach ($row in $Rows) {
        $dataRow = $dataTable.NewRow()
        foreach ($mapping in $ColumnMappings) {
            $property = $row.PSObject.Properties[[string]$mapping.OriginalName]
            $value = if ($null -eq $property) { $null } else { $property.Value }
            if ($null -eq $value) {
                $dataRow[[string]$mapping.ColumnName] = [DBNull]::Value
            }
            else {
                $dataRow[[string]$mapping.ColumnName] = [string]$value
            }
        }

        [void]$dataTable.Rows.Add($dataRow)
    }

    return $dataTable
}

function Read-TabularImportFile {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    $rows = switch ($extension) {
        '.csv' {
            @(Import-Csv -LiteralPath $FilePath)
        }
        '.xlsx' {
            if (-not (Test-ImportExcelCommandAvailable)) {
                throw "The ImportExcel PowerShell module is required before .xlsx files can be imported."
            }

            @(Import-Excel -Path $FilePath)
        }
        default {
            throw "Unsupported file type: $extension. Only .csv and .xlsx files are supported."
        }
    }

    if ($rows.Count -eq 0) {
        throw "The selected file does not contain any data rows to import."
    }

    $firstRow = $rows | Select-Object -First 1
    $originalColumns = @($firstRow.PSObject.Properties.Name)
    if ($originalColumns.Count -eq 0) {
        throw "The selected file does not expose any importable columns."
    }

    $columnMappings = ConvertTo-StagingColumnMappings -OriginalColumnNames $originalColumns
    $dataTable = ConvertTo-DataTableForSqlImport -Rows $rows -ColumnMappings $columnMappings

    return [pscustomobject]@{
        Rows           = $rows
        ColumnMappings = $columnMappings
        DataTable      = $dataTable
    }
}

function New-DatabaseImportTable {
    param(
        [Parameter(Mandatory = $true)][string]$TableName,
        [Parameter(Mandatory = $true)][object[]]$ColumnMappings
    )

    $columnDefinitions = @($ColumnMappings | ForEach-Object {
        "$(Get-QuotedSqlColumnName -ColumnName $_.ColumnName) nvarchar(max) null"
    })

    $createSql = @"
create table $(Get-QuotedSqlTableName -TableName $TableName) (
    $($columnDefinitions -join ",
    ")
);
"@
    [void](Invoke-TranslationQuery -Query $createSql)
}

function Write-DataTableToDatabaseTable {
    param(
        [Parameter(Mandatory = $true)][System.Data.DataTable]$DataTable,
        [Parameter(Mandatory = $true)][string]$TableName,
        [Parameter(Mandatory = $true)][object[]]$ColumnMappings
    )

    $connection = New-TranslationSqlConnection
    try {
        $connection.Open()
        $bulkCopy = New-Object System.Data.SqlClient.SqlBulkCopy($connection)
        $bulkCopy.DestinationTableName = Get-QuotedSqlTableName -TableName $TableName
        $bulkCopy.BulkCopyTimeout = 0
        $bulkCopy.BatchSize = 1000

        foreach ($mapping in $ColumnMappings) {
            [void]$bulkCopy.ColumnMappings.Add([string]$mapping.ColumnName, [string]$mapping.ColumnName)
        }

        $bulkCopy.WriteToServer($DataTable)
    }
    finally {
        if ($null -ne $bulkCopy) { $bulkCopy.Close() }
        if ($connection.State -ne [System.Data.ConnectionState]::Closed) { $connection.Close() }
    }
}

function Import-TabularFileToDatabaseTable {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$TableName
    )

    $tableCreated = $false
    try {
        Write-StreamingLog -Percent 15 -Step "Read file" -Description "Reading rows and columns from $FilePath."
        $importData = Read-TabularImportFile -FilePath $FilePath
        Write-StreamingLog -Percent 45 -Step "Create table" -Description "Creating dbo.$TableName with nvarchar(max) columns."
        New-DatabaseImportTable -TableName $TableName -ColumnMappings $importData.ColumnMappings
        $tableCreated = $true
        Write-StreamingLog -Percent 75 -Step "Import data" -Description "Bulk loading $($importData.DataTable.Rows.Count) row(s) into dbo.$TableName."
        Write-DataTableToDatabaseTable -DataTable $importData.DataTable -TableName $TableName -ColumnMappings $importData.ColumnMappings
        Write-StreamingLog -Percent 100 -Step "Done" -Description "Import completed."

        return [pscustomobject]@{
            TableName   = $TableName
            FilePath    = $FilePath
            Rows        = $importData.DataTable.Rows.Count
            Columns     = $importData.ColumnMappings.Count
            ColumnNames = (($importData.ColumnMappings | ForEach-Object { $_.ColumnName }) -join ', ')
        }
    }
    catch {
        if ($tableCreated) {
            try {
                [void](Invoke-TranslationQuery -Query "drop table $(Get-QuotedSqlTableName -TableName $TableName);")
            }
            catch {}
        }

        throw
    }
}

function Convert-TableReferenceInCondition {
    param(
        [Parameter(Mandatory = $true)][string]$Condition,
        [Parameter(Mandatory = $true)][string]$TableName,
        [Parameter(Mandatory = $true)][string]$Alias
    )

    $escapedTableName = [System.Text.RegularExpressions.Regex]::Escape($TableName)
    $patterns = @(
        "(?i)(?<![\w\]])\[dbo\]\s*\.\s*\[$escapedTableName\]\s*\.",
        "(?i)(?<![\w\]])dbo\s*\.\s*\[$escapedTableName\]\s*\.",
        "(?i)(?<![\w\]])\[dbo\]\s*\.\s*$escapedTableName\s*\.",
        "(?i)(?<![\w\]])dbo\s*\.\s*$escapedTableName\s*\.",
        "(?i)(?<![\w\]])\[$escapedTableName\]\s*\.",
        "(?i)(?<![\w\]])$escapedTableName\s*\."
    )

    $updatedCondition = $Condition
    foreach ($pattern in $patterns) {
        $updatedCondition = [System.Text.RegularExpressions.Regex]::Replace($updatedCondition, $pattern, "$Alias.")
    }

    return $updatedCondition
}

function Convert-TableMigrationConditionToAliases {
    param(
        [Parameter(Mandatory = $true)][string]$Condition,
        [Parameter(Mandatory = $true)][string]$SourceTable,
        [Parameter(Mandatory = $true)][string]$DestinationTable
    )

    $normalizedCondition = $Condition.Trim()
    if ($normalizedCondition -match '^(?is)\s*where\s+(.+)$') {
        $normalizedCondition = $Matches[1].Trim()
    }
    $normalizedCondition = $normalizedCondition.Trim()
    while ($normalizedCondition.EndsWith(';')) {
        $normalizedCondition = $normalizedCondition.Substring(0, $normalizedCondition.Length - 1).Trim()
    }
    if ($normalizedCondition -match ';') {
        throw "The SQL condition must be a single WHERE expression. Remove semicolons or extra SQL statements."
    }

    $normalizedCondition = [System.Text.RegularExpressions.Regex]::Replace($normalizedCondition, '(?i)(?<![\w\]])source\s*\.', 'S.')
    $normalizedCondition = [System.Text.RegularExpressions.Regex]::Replace($normalizedCondition, '(?i)(?<![\w\]])destination\s*\.', 'D.')

    if ($SourceTable -ine $DestinationTable) {
        $normalizedCondition = Convert-TableReferenceInCondition -Condition $normalizedCondition -TableName $SourceTable -Alias 'S'
        $normalizedCondition = Convert-TableReferenceInCondition -Condition $normalizedCondition -TableName $DestinationTable -Alias 'D'
    }

    if ([string]::IsNullOrWhiteSpace($normalizedCondition)) {
        throw "A SQL condition is required. Use a real condition, or type 1=1 if you intentionally want to update all matching cross-joined rows."
    }

    return $normalizedCondition
}

function Invoke-DatabaseTableMigration {
    param([string]$DefaultSourceTable = "")

    Clear-Host
    Show-SectionTitle "Migrate Data Between Tables"
    Write-Host "This tool updates one destination column from one source column." -ForegroundColor Cyan
    Write-Host "Type q at any prompt to return to the Database Tools menu." -ForegroundColor DarkGray
    Write-Host ""

    try {
        $sourceTable = Read-DatabaseTableName -Prompt "Source dbo table name" -DefaultValue $DefaultSourceTable -MustExist
        if ([string]::IsNullOrWhiteSpace($sourceTable)) { return }

        $sourceColumn = Read-DatabaseColumnName -TableName $sourceTable -Prompt "Source column name from dbo.$sourceTable"
        if ([string]::IsNullOrWhiteSpace($sourceColumn)) { return }

        $destinationTable = Read-DatabaseTableName -Prompt "Destination dbo table name" -MustExist
        if ([string]::IsNullOrWhiteSpace($destinationTable)) { return }

        $destinationColumn = Read-DatabaseColumnName -TableName $destinationTable -Prompt "Destination column name from dbo.$destinationTable"
        if ([string]::IsNullOrWhiteSpace($destinationColumn)) { return }

        Write-Host ""
        Write-Host "Enter the SQL WHERE condition used to match/filter rows." -ForegroundColor Cyan
        Write-Host "Examples:" -ForegroundColor Gray
        Write-Host "  where $sourceTable.Id = $destinationTable.Id" -ForegroundColor Gray
        Write-Host "  where $sourceTable.Status = 'READY' and $destinationTable.Active = 1" -ForegroundColor Gray
        Write-Host "You may also use aliases Source. and Destination.; this tool converts them to S. and D." -ForegroundColor Gray
        $condition = Read-Host "SQL condition"
        if (Test-IsDatabaseToolBack $condition) { return }

        $conditionSql = Convert-TableMigrationConditionToAliases -Condition $condition -SourceTable $sourceTable -DestinationTable $destinationTable
        $sourceSql = Get-QuotedSqlTableName -TableName $sourceTable
        $destinationSql = Get-QuotedSqlTableName -TableName $destinationTable
        $sourceColumnSql = Get-QuotedSqlColumnName -ColumnName $sourceColumn
        $destinationColumnSql = Get-QuotedSqlColumnName -ColumnName $destinationColumn

        Write-StreamingLog -Percent 20 -Step "Analyze" -Description "Counting rows that match the migration condition."
        $countQuery = @"
select count_big(1) as MatchingRows
from $destinationSql as D
inner join $sourceSql as S on 1 = 1
where $conditionSql;
"@
        $countResult = @(Invoke-TranslationQuery -Query $countQuery | Select-Object -First 1)
        $matchingRows = if ($countResult.Count -gt 0) { [int64]$countResult[0].MatchingRows } else { 0 }

        Write-StreamingLog -Percent 35 -Step "Preview" -Description "Loading the top 20 rows that would be updated."
        $previewQuery = @"
select top 20
    D.$destinationColumnSql as CurrentDestinationValue,
    S.$sourceColumnSql as NewSourceValue
from $destinationSql as D
inner join $sourceSql as S on 1 = 1
where $conditionSql;
"@
        $previewRows = @(Invoke-TranslationQuery -Query $previewQuery)

        Show-SectionTitle "Migration Preview"
        Write-Host "Source: dbo.$sourceTable.$sourceColumn" -ForegroundColor Gray
        Write-Host "Destination: dbo.$destinationTable.$destinationColumn" -ForegroundColor Gray
        Write-Host "Matching rows: $matchingRows" -ForegroundColor Yellow
        Write-Host "Condition used by the script: where $conditionSql" -ForegroundColor Gray
        Write-Host ""
        Show-ConsoleResults -Data $previewRows

        if ($matchingRows -eq 0) {
            Write-Host "No rows match the condition. No backup or migration was performed." -ForegroundColor Yellow
            Pause-Screen
            return
        }

        Write-Host ""
        Write-Host "A backup of dbo.$destinationTable will be created before the update." -ForegroundColor Yellow
        $confirm = Read-Host "Type MIGRATE to create the backup and update the destination table"
        if ($confirm -cne 'MIGRATE') {
            Write-Host "Operation cancelled. No data was changed." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        Write-StreamingLog -Percent 55 -Step "Backup" -Description "Creating a safety backup of dbo.$destinationTable."
        $backupTable = New-DatabaseTableBackup -TableName $destinationTable
        Write-Host "Backup table created: $backupTable" -ForegroundColor Green

        Write-StreamingLog -Percent 75 -Step "Update" -Description "Updating dbo.$destinationTable.$destinationColumn from dbo.$sourceTable.$sourceColumn."
        $updateQuery = @"
update D
set D.$destinationColumnSql = S.$sourceColumnSql
from $destinationSql as D
inner join $sourceSql as S on 1 = 1
where $conditionSql;

select @@ROWCOUNT as UpdatedRows;
"@
        $updateResult = @(Invoke-TranslationQuery -Query $updateQuery | Select-Object -First 1)
        $updatedRows = if ($updateResult.Count -gt 0) { [int64]$updateResult[0].UpdatedRows } else { 0 }

        Write-StreamingLog -Percent 100 -Step "Done" -Description "Migration completed."
        Write-Host "Migration complete. Rows updated: $updatedRows." -ForegroundColor Green
        Write-Host "Backup kept as: $backupTable" -ForegroundColor Yellow
    }
    catch {
        Show-LoggedError -Prefix "The table migration failed" -Context "Database Tools - migrate data between tables" -ErrorRecord $_
    }

    Pause-Screen
}

function Show-ImportCsvExcelToDatabaseMenu {
    Clear-Host
    Show-SectionTitle "Import CSV/Excel To Database"
    Write-Host "This tool creates a new dbo staging table and imports a .csv or .xlsx file into it." -ForegroundColor Cyan
    Write-Host "All imported columns are created as nvarchar(max) to avoid data-type conversion failures." -ForegroundColor Gray
    Write-Host ""

    try {
        $filePath = Read-CsvExcelImportFilePath
        if ([string]::IsNullOrWhiteSpace($filePath)) { return }

        Write-Host ""
        Write-Host "Selected file: $filePath" -ForegroundColor Yellow
        $tableName = Read-DatabaseTableName -Prompt "New staging dbo table name to create" -DisallowExisting
        if ([string]::IsNullOrWhiteSpace($tableName)) { return }

        Write-Host ""
        Write-Host "Import summary:" -ForegroundColor Cyan
        Write-Host "  File: $filePath"
        Write-Host "  New table: dbo.$tableName"
        $confirm = Read-Host "Type IMPORT to create the table and load the file"
        if ($confirm -cne 'IMPORT') {
            Write-Host "Operation cancelled. No table was created." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        $result = Import-TabularFileToDatabaseTable -FilePath $filePath -TableName $tableName
        Write-Host ""
        Write-Host "Import complete." -ForegroundColor Green
        Write-Host "Created table: dbo.$($result.TableName)" -ForegroundColor Green
        Write-Host "Rows imported: $($result.Rows)" -ForegroundColor Green
        Write-Host "Columns imported: $($result.Columns)" -ForegroundColor Green
        Write-Host "Database columns: $($result.ColumnNames)" -ForegroundColor Gray

        Write-Host ""
        $migrateNow = Read-Host "Type MIGRATE to copy data from this new table into another table now, or press Enter to return"
        if ($migrateNow -cne 'MIGRATE') {
            Pause-Screen
            return
        }

        Invoke-DatabaseTableMigration -DefaultSourceTable $tableName
    }
    catch {
        Show-LoggedError -Prefix "The CSV/Excel import failed" -Context "Database Tools - import CSV/Excel to database" -ErrorRecord $_
        Pause-Screen
    }
}

function Invoke-DatabaseToolWithTranslationSchema {
    param(
        [Parameter(Mandatory = $true)][string]$Context,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )

    try {
        Assert-TranslationSchema
    }
    catch {
        Show-LoggedError -Prefix "This database cannot be used by the selected translation tool" -Context $Context -ErrorRecord $_
        Pause-Screen
        return
    }

    try {
        & $Action
    }
    catch {
        Show-LoggedError -Prefix "The selected translation tool did not complete" -Context $Context -ErrorRecord $_
        Pause-Screen
    }
}

function Read-RequiredIntegerValue {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$ValueName = "value"
    )

    while ($true) {
        $enteredValue = Read-Host $Prompt
        if (Test-IsDatabaseToolBack $enteredValue) { return $null }

        $cleanValue = Normalize-UserPath $enteredValue
        $parsedValue = 0
        if ([int]::TryParse($cleanValue, [ref]$parsedValue)) {
            return $parsedValue
        }

        Write-Host "Please enter a valid numeric $ValueName, or type Q to return to the previous menu." -ForegroundColor Yellow
    }
}

function Read-IntegerListValue {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$ValueName = "value"
    )

    while ($true) {
        $enteredValue = Read-Host $Prompt
        if (Test-IsDatabaseToolBack $enteredValue) { return $null }

        $parts = @(($enteredValue -split ',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($parts.Count -eq 0) {
            Write-Host "Please enter one or more numeric $ValueName values separated by commas." -ForegroundColor Yellow
            continue
        }

        $values = New-Object System.Collections.Generic.List[int]
        $allValid = $true
        foreach ($part in $parts) {
            $parsedValue = 0
            if ([int]::TryParse($part, [ref]$parsedValue)) {
                [void]$values.Add($parsedValue)
            }
            else {
                Write-Host "'$part' is not a valid numeric $ValueName." -ForegroundColor Red
                $allValid = $false
                break
            }
        }

        if ($allValid) {
            return @($values | Sort-Object -Unique)
        }
    }
}

function Read-SourceMaintenanceCodeFilter {
    while ($true) {
        $enteredValue = Read-Host "Source maintenance code to copy, or ALL to copy all activities"
        if (Test-IsDatabaseToolBack $enteredValue) { return $null }

        $cleanValue = Normalize-UserPath $enteredValue
        if ($cleanValue -ieq 'all') {
            return [pscustomobject]@{
                IsAll = $true
                Value = $null
                Sql   = 'NULL'
                Label = 'ALL'
            }
        }

        $parsedValue = 0
        if ([int]::TryParse($cleanValue, [ref]$parsedValue)) {
            return [pscustomobject]@{
                IsAll = $false
                Value = $parsedValue
                Sql   = [string]$parsedValue
                Label = [string]$parsedValue
            }
        }

        Write-Host "Please enter a numeric maintenance code, ALL, or Q to return to the previous menu." -ForegroundColor Yellow
    }
}

function ConvertTo-SqlIntValuesList {
    param([Parameter(Mandatory = $true)][int[]]$Values)

    return (($Values | ForEach-Object { "($_)" }) -join ",`r`n    ")
}

function Assert-CopyActivitiesSchema {
    $requiredTables = @('P4A_LineEquipmentMasterDowntimeCodes', 'P4A_LineEquipmentMaster')
    foreach ($table in $requiredTables) {
        if (-not (Test-TranslationTableExists -TableName $table)) {
            throw "Required table dbo.$table was not found."
        }
    }

    $requiredColumns = @(
        @{ Table = 'P4A_LineEquipmentMaster'; Column = 'EquipID' },
        @{ Table = 'P4A_LineEquipmentMaster'; Column = 'Line' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'Line' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'EquipID' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'MaintenanceCode' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'Description' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'ShortDescription' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'Category' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'StopSubCategoryKey' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'StatusCode' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'SortOrder' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'Active' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'StandardTime' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'ForceComments' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'OperatorStop' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'GenericFault' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'D4ARecordKey' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'ActivityReportCategoryKey' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'CuteCategoryID' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'Enable_Startup' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'Enable_Changeover' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'RemainUndeclared' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'Enable_Pause' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'ActivityKey' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'OEE123CategoryID' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'IsBreak' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'ForceRedeclare' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'IsDefaultChangeover' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'HideFromOperatorSelection' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'IsDefaultUndeclaredActivities' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'PushToLinkedMachines' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'ProcessReliabilityCategoryID' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'IncludeInShortList' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'ExcludeFromChangeoverReport' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'CategoryImage' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'ImageAttachmentKey' },
        @{ Table = 'P4A_LineEquipmentMasterDowntimeCodes'; Column = 'GoToUnscheduledAfterStandardTime' }
    )

    foreach ($item in $requiredColumns) {
        if (-not (Test-TranslationColumnExists -TableName $item.Table -ColumnName $item.Column)) {
            throw "Required column dbo.$($item.Table).$($item.Column) was not found."
        }
    }
}

function New-CopyActivitiesPreviewQuery {
    param(
        [Parameter(Mandatory = $true)][int]$SourceEquipId,
        [AllowNull()][object]$MaintenanceFilter,
        [Parameter(Mandatory = $true)][int[]]$TargetEquipIds
    )

    $targetValuesSql = ConvertTo-SqlIntValuesList -Values $TargetEquipIds
    $maintenanceCodeSql = if ($null -eq $MaintenanceFilter -or $MaintenanceFilter.IsAll) { 'NULL' } else { [string][int]$MaintenanceFilter.Value }

@"
set nocount on;

declare @SourceEquipID int = $SourceEquipId;
declare @SourceMaintenanceCodeToCopy int = $maintenanceCodeSql;
declare @TargetEquipIDs table (EquipID int primary key);

insert into @TargetEquipIDs (EquipID)
values
    $targetValuesSql;

;with ActivitiesToCopy as (
    select
        Src.EquipID as SourceEquipID,
        TgtList.EquipID as TargetEquipID,
        TgtMaster.Line as TargetLine,
        Src.MaintenanceCode as SourceMaintenanceCode,
        NewMaintenanceCode =
            isnull(TgtMax.MaxMaintenanceCode, 0)
            + row_number() over (partition by TgtList.EquipID order by isnull(Src.SortOrder, 999999), Src.MaintenanceCode),
        Src.Description,
        Src.ShortDescription,
        Src.Category,
        Src.StopSubCategoryKey,
        Src.StatusCode,
        Src.Active,
        Src.StandardTime
    from dbo.P4A_LineEquipmentMasterDowntimeCodes Src
    cross join @TargetEquipIDs TgtList
    inner join dbo.P4A_LineEquipmentMaster TgtMaster
        on TgtMaster.EquipID = TgtList.EquipID
    cross apply (
        select isnull(max(MaintenanceCode), 0) as MaxMaintenanceCode
        from dbo.P4A_LineEquipmentMasterDowntimeCodes
        where EquipID = TgtList.EquipID
    ) TgtMax
    where Src.EquipID = @SourceEquipID
      and (@SourceMaintenanceCodeToCopy is null or Src.MaintenanceCode = @SourceMaintenanceCodeToCopy)
      and not exists (
          select 1
          from dbo.P4A_LineEquipmentMasterDowntimeCodes Tgt
          where Tgt.EquipID = TgtList.EquipID
            and isnull(ltrim(rtrim(Tgt.Description)), '') = isnull(ltrim(rtrim(Src.Description)), '')
            and isnull(Tgt.StatusCode, 0) = isnull(Src.StatusCode, 0)
      )
)
select
    'Preview of Activities to Copy' as Step,
    *
from ActivitiesToCopy
order by TargetEquipID, NewMaintenanceCode;
"@
}

function New-CopyActivitiesDiagnosticsQuery {
    param(
        [Parameter(Mandatory = $true)][int]$SourceEquipId,
        [AllowNull()][object]$MaintenanceFilter,
        [Parameter(Mandatory = $true)][int[]]$TargetEquipIds
    )

    $targetValuesSql = ConvertTo-SqlIntValuesList -Values $TargetEquipIds
    $maintenanceCodeSql = if ($null -eq $MaintenanceFilter -or $MaintenanceFilter.IsAll) { 'NULL' } else { [string][int]$MaintenanceFilter.Value }

@"
set nocount on;

declare @SourceEquipID int = $SourceEquipId;
declare @SourceMaintenanceCodeToCopy int = $maintenanceCodeSql;
declare @TargetEquipIDs table (EquipID int primary key);

insert into @TargetEquipIDs (EquipID)
values
    $targetValuesSql;

select
    @SourceEquipID as SourceEquipID,
    SourceActivitiesFound = (
        select count(1)
        from dbo.P4A_LineEquipmentMasterDowntimeCodes Src
        where Src.EquipID = @SourceEquipID
          and (@SourceMaintenanceCodeToCopy is null or Src.MaintenanceCode = @SourceMaintenanceCodeToCopy)
    ),
    MissingTargetMachines = isnull(stuff((
        select ', ' + cast(T.EquipID as varchar(20))
        from @TargetEquipIDs T
        where not exists (
            select 1
            from dbo.P4A_LineEquipmentMaster M
            where M.EquipID = T.EquipID
        )
        order by T.EquipID
        for xml path(''), type
    ).value('.', 'varchar(max)'), 1, 2, ''), ''),
    DuplicateRowsSkipped = (
        select count(1)
        from dbo.P4A_LineEquipmentMasterDowntimeCodes Src
        cross join @TargetEquipIDs TgtList
        inner join dbo.P4A_LineEquipmentMaster TgtMaster
            on TgtMaster.EquipID = TgtList.EquipID
        where Src.EquipID = @SourceEquipID
          and (@SourceMaintenanceCodeToCopy is null or Src.MaintenanceCode = @SourceMaintenanceCodeToCopy)
          and exists (
              select 1
              from dbo.P4A_LineEquipmentMasterDowntimeCodes Tgt
              where Tgt.EquipID = TgtList.EquipID
                and isnull(ltrim(rtrim(Tgt.Description)), '') = isnull(ltrim(rtrim(Src.Description)), '')
                and isnull(Tgt.StatusCode, 0) = isnull(Src.StatusCode, 0)
          )
    );
"@
}

function New-CopyActivitiesApplyQuery {
    param(
        [Parameter(Mandatory = $true)][int]$SourceEquipId,
        [AllowNull()][object]$MaintenanceFilter,
        [Parameter(Mandatory = $true)][int[]]$TargetEquipIds
    )

    $targetValuesSql = ConvertTo-SqlIntValuesList -Values $TargetEquipIds
    $maintenanceCodeSql = if ($null -eq $MaintenanceFilter -or $MaintenanceFilter.IsAll) { 'NULL' } else { [string][int]$MaintenanceFilter.Value }

@"
set nocount on;

if object_id('tempdb..#ActivitiesToCopy') is not null
    drop table #ActivitiesToCopy;

declare @SourceEquipID int = $SourceEquipId;
declare @SourceMaintenanceCodeToCopy int = $maintenanceCodeSql;
declare @TargetEquipIDs table (EquipID int primary key);

insert into @TargetEquipIDs (EquipID)
values
    $targetValuesSql;

select
    Src.EquipID as SourceEquipID,
    TgtList.EquipID as TargetEquipID,
    TgtMaster.Line as TargetLine,
    Src.MaintenanceCode as SourceMaintenanceCode,
    NewMaintenanceCode =
        isnull(TgtMax.MaxMaintenanceCode, 0)
        + row_number() over (partition by TgtList.EquipID order by isnull(Src.SortOrder, 999999), Src.MaintenanceCode),
    Src.Description,
    Src.ShortDescription,
    Src.Category,
    Src.StopSubCategoryKey,
    Src.StatusCode,
    Src.Active,
    Src.StandardTime
into #ActivitiesToCopy
from dbo.P4A_LineEquipmentMasterDowntimeCodes Src
cross join @TargetEquipIDs TgtList
inner join dbo.P4A_LineEquipmentMaster TgtMaster
    on TgtMaster.EquipID = TgtList.EquipID
cross apply (
    select isnull(max(MaintenanceCode), 0) as MaxMaintenanceCode
    from dbo.P4A_LineEquipmentMasterDowntimeCodes
    where EquipID = TgtList.EquipID
) TgtMax
where Src.EquipID = @SourceEquipID
  and (@SourceMaintenanceCodeToCopy is null or Src.MaintenanceCode = @SourceMaintenanceCodeToCopy)
  and not exists (
      select 1
      from dbo.P4A_LineEquipmentMasterDowntimeCodes Tgt
      where Tgt.EquipID = TgtList.EquipID
        and isnull(ltrim(rtrim(Tgt.Description)), '') = isnull(ltrim(rtrim(Src.Description)), '')
        and isnull(Tgt.StatusCode, 0) = isnull(Src.StatusCode, 0)
  );

insert into dbo.P4A_LineEquipmentMasterDowntimeCodes (
    Line,
    EquipID,
    MaintenanceCode,
    Description,
    Active,
    Category,
    ShortDescription,
    SortOrder,
    ForceComments,
    OperatorStop,
    GenericFault,
    D4ARecordKey,
    StopSubCategoryKey,
    StatusCode,
    ActivityReportCategoryKey,
    CuteCategoryID,
    StandardTime,
    Enable_Startup,
    Enable_Changeover,
    RemainUndeclared,
    Enable_Pause,
    ActivityKey,
    OEE123CategoryID,
    IsBreak,
    ForceRedeclare,
    IsDefaultChangeover,
    HideFromOperatorSelection,
    IsDefaultUndeclaredActivities,
    PushToLinkedMachines,
    ProcessReliabilityCategoryID,
    IncludeInShortList,
    ExcludeFromChangeoverReport,
    CategoryImage,
    ImageAttachmentKey,
    GoToUnscheduledAfterStandardTime
)
select
    M.TargetLine,
    M.TargetEquipID,
    M.NewMaintenanceCode,
    Src.Description,
    Src.Active,
    Src.Category,
    Src.ShortDescription,
    Src.SortOrder,
    Src.ForceComments,
    Src.OperatorStop,
    Src.GenericFault,
    newid(),
    Src.StopSubCategoryKey,
    Src.StatusCode,
    Src.ActivityReportCategoryKey,
    Src.CuteCategoryID,
    Src.StandardTime,
    Src.Enable_Startup,
    Src.Enable_Changeover,
    Src.RemainUndeclared,
    Src.Enable_Pause,
    newid(),
    Src.OEE123CategoryID,
    Src.IsBreak,
    Src.ForceRedeclare,
    Src.IsDefaultChangeover,
    Src.HideFromOperatorSelection,
    Src.IsDefaultUndeclaredActivities,
    Src.PushToLinkedMachines,
    Src.ProcessReliabilityCategoryID,
    Src.IncludeInShortList,
    Src.ExcludeFromChangeoverReport,
    Src.CategoryImage,
    Src.ImageAttachmentKey,
    Src.GoToUnscheduledAfterStandardTime
from dbo.P4A_LineEquipmentMasterDowntimeCodes Src
inner join #ActivitiesToCopy M
    on M.SourceMaintenanceCode = Src.MaintenanceCode
   and Src.EquipID = @SourceEquipID;

declare @InsertedRows int = @@rowcount;

select @InsertedRows as InsertedRows;
"@
}

function New-CopyActivitiesValidationQuery {
    param([Parameter(Mandatory = $true)][int[]]$TargetEquipIds)

    $targetValuesSql = ConvertTo-SqlIntValuesList -Values $TargetEquipIds

@"
set nocount on;

declare @TargetEquipIDs table (EquipID int primary key);

insert into @TargetEquipIDs (EquipID)
values
    $targetValuesSql;

select
    'Post-Copy Validation' as Step,
    EquipID,
    Line,
    MaintenanceCode,
    Description,
    ShortDescription,
    Category,
    StopSubCategoryKey,
    StatusCode
from dbo.P4A_LineEquipmentMasterDowntimeCodes
where EquipID in (select EquipID from @TargetEquipIDs)
order by EquipID, isnull(SortOrder, 999999), MaintenanceCode;
"@
}

function Invoke-CopyActivitiesCommit {
    param(
        [Parameter(Mandatory = $true)][int]$SourceEquipId,
        [Parameter(Mandatory = $true)][int[]]$TargetEquipIds,
        [Parameter(Mandatory = $true)][object]$MaintenanceFilter
    )

    $backupTable = New-DatabaseTableBackup -TableName "P4A_LineEquipmentMasterDowntimeCodes"
    Write-Host "Backup table created: $backupTable" -ForegroundColor Green

    $connection = New-TranslationSqlConnection
    $transaction = $null
    try {
        $connection.Open()
        $transaction = $connection.BeginTransaction()

        Write-StreamingLog -Percent 45 -Step "Copy" -Description "Inserting copied activities into P4A_LineEquipmentMasterDowntimeCodes."
        $applyQuery = New-CopyActivitiesApplyQuery -SourceEquipId $SourceEquipId -MaintenanceFilter $MaintenanceFilter -TargetEquipIds $TargetEquipIds
        $applyRows = @(Invoke-TransactionalQuery -Connection $connection -Transaction $transaction -Query $applyQuery)
        $insertedRows = if ($applyRows.Count -gt 0 -and $null -ne $applyRows[0].InsertedRows) { [int]$applyRows[0].InsertedRows } else { 0 }

        Write-StreamingLog -Percent 70 -Step "Sync" -Description "Refreshing P4A work tables when the sync procedure exists."
        $syncQuery = @"
if object_id(N'dbo.P4A_SyncWorkTables', N'P') is not null
    exec dbo.P4A_SyncWorkTables;
else if object_id(N'P4A_SyncWorkTables', N'P') is not null
    exec P4A_SyncWorkTables;
"@
        [void](Invoke-TransactionalNonQuery -Connection $connection -Transaction $transaction -Query $syncQuery)

        Write-StreamingLog -Percent 90 -Step "Validate" -Description "Loading post-copy validation rows."
        $validationQuery = New-CopyActivitiesValidationQuery -TargetEquipIds $TargetEquipIds
        $validationRows = @(Invoke-TransactionalQuery -Connection $connection -Transaction $transaction -Query $validationQuery)

        $transaction.Commit()
        $transaction = $null

        return [pscustomobject]@{
            BackupTable    = $backupTable
            InsertedRows   = $insertedRows
            ValidationRows = $validationRows
        }
    }
    catch {
        if ($null -ne $transaction) {
            try { $transaction.Rollback() } catch {}
        }
        throw
    }
    finally {
        if ($connection.State -ne [System.Data.ConnectionState]::Closed) { $connection.Close() }
    }
}

function Invoke-CopyActivitiesBetweenMachines {
    while ($true) {
        Clear-Host
        Show-SectionTitle "Copy Activities Between Machines"
        Write-Host "This tool copies P4A activities from one machine to one or more destination machines." -ForegroundColor Cyan
        Write-Host "Duplicates are avoided by matching existing target rows with the same Description and StatusCode." -ForegroundColor Gray
        Write-Host "Type Q at any prompt to return to the Database Tools menu." -ForegroundColor DarkGray
        Write-Host ""

        try {
            Assert-CopyActivitiesSchema

            $sourceEquipId = Read-RequiredIntegerValue -Prompt "Source machine EquipID" -ValueName "machine ID"
            if ($null -eq $sourceEquipId) { return }

            $targetInput = Read-IntegerListValue -Prompt "Destination machine EquipID(s), separated by commas" -ValueName "machine ID"
            if ($null -eq $targetInput) { return }
            $targetEquipIds = @($targetInput)

            $maintenanceFilter = Read-SourceMaintenanceCodeFilter
            if ($null -eq $maintenanceFilter) { return }

            Write-Host ""
            Write-StreamingLog -Percent 20 -Step "Analyze" -Description "Checking source activities, target machines, and duplicates."
            $diagnosticsQuery = New-CopyActivitiesDiagnosticsQuery -SourceEquipId $sourceEquipId -MaintenanceFilter $maintenanceFilter -TargetEquipIds $targetEquipIds
            $diagnostics = @(Invoke-TranslationQuery -Query $diagnosticsQuery | Select-Object -First 1)

            if ($diagnostics.Count -gt 0) {
                if (-not [string]::IsNullOrWhiteSpace([string]$diagnostics[0].MissingTargetMachines)) {
                    Write-Host "Missing target machine(s): $($diagnostics[0].MissingTargetMachines)" -ForegroundColor Red
                }
                Write-Host "Source activities found: $($diagnostics[0].SourceActivitiesFound)" -ForegroundColor Gray
                Write-Host "Duplicate rows skipped: $($diagnostics[0].DuplicateRowsSkipped)" -ForegroundColor Gray
            }

            Write-StreamingLog -Percent 35 -Step "Preview" -Description "Preparing the activity copy preview."
            $previewQuery = New-CopyActivitiesPreviewQuery -SourceEquipId $sourceEquipId -MaintenanceFilter $maintenanceFilter -TargetEquipIds $targetEquipIds
            $previewRows = @(Invoke-TranslationQuery -Query $previewQuery)

            Show-SectionTitle "Copy Preview"
            Write-Host "Source machine: $sourceEquipId" -ForegroundColor Gray
            Write-Host "Destination machine(s): $($targetEquipIds -join ', ')" -ForegroundColor Gray
            Write-Host "Maintenance code: $($maintenanceFilter.Label)" -ForegroundColor Gray
            Write-Host "Rows ready to copy: $($previewRows.Count)" -ForegroundColor Yellow
            Write-Host ""
            Show-ConsoleResults -Data $previewRows

            if ($previewRows.Count -eq 0) {
                Write-Host "No activities are ready to copy. This can happen when the source has no matching activity, targets are missing, or every row already exists on the target." -ForegroundColor Yellow
            }

            Write-Host ""
            Write-Host "Type COMMIT to create a backup and copy these activities." -ForegroundColor Yellow
            Write-Host "Type Q to return to the Database Tools menu." -ForegroundColor DarkGray
            Write-Host "Press any other key, then Enter, to restart this copy process." -ForegroundColor DarkGray
            $decision = Read-Host "Your choice"

            if (Test-IsDatabaseToolBack $decision) { return }
            if ($decision -cne 'COMMIT') { continue }

            if ($previewRows.Count -eq 0) {
                Write-Host "Nothing to commit because the preview has no rows." -ForegroundColor Yellow
                Pause-Screen
                continue
            }

            $commitResult = Invoke-CopyActivitiesCommit -SourceEquipId $sourceEquipId -TargetEquipIds $targetEquipIds -MaintenanceFilter $maintenanceFilter

            Show-SectionTitle "Copy Activities Complete"
            Write-Host "Activities copied successfully." -ForegroundColor Green
            Write-Host "Rows inserted: $($commitResult.InsertedRows)" -ForegroundColor Green
            Write-Host "Backup created before the copy: $($commitResult.BackupTable)" -ForegroundColor Yellow
            Write-Host ""
            Show-ConsoleResults -Data $commitResult.ValidationRows
            Pause-Screen
            return
        }
        catch {
            Show-LoggedError -Prefix "The activity copy failed" -Context "Database Tools - copy activities between machines" -ErrorRecord $_
            Pause-Screen
            return
        }
    }
}

function Get-ScriptBackupOptionName {
    param([Parameter(Mandatory = $true)][string]$SourceTable)

    switch -Regex ($SourceTable) {
        '^LanguageTranslations$' {
            return 'Translation import, restore, or cleanup'
        }
        '^Languages$' {
            return 'Add or validate database language'
        }
        '^AssemblyRules$' {
            return 'P4A settings or Enable Line Detailed View'
        }
        '^SystemGroupLinks$' {
            return 'Process Reliability report or Enable Line Detailed View'
        }
        '^D4A_Kpis_ComponentType$' {
            return 'Enable Line Detailed View'
        }
        '^D4A_Kpis_DtlSettings$' {
            return 'Enable Line Detailed View'
        }
        '^P4A_LineEquipmentMasterDowntimeCodes$' {
            return 'Copy activities between machines'
        }
        default {
            return 'Migrate data between database tables or custom table backup'
        }
    }
}

function Convert-BackupTimestampToText {
    param([AllowNull()][string]$Timestamp)

    if ([string]::IsNullOrWhiteSpace($Timestamp) -or $Timestamp -notmatch '^\d{14}$') {
        return [string]$Timestamp
    }

    return "{0}-{1}-{2} {3}:{4}:{5}" -f
        $Timestamp.Substring(0, 4),
        $Timestamp.Substring(4, 2),
        $Timestamp.Substring(6, 2),
        $Timestamp.Substring(8, 2),
        $Timestamp.Substring(10, 2),
        $Timestamp.Substring(12, 2)
}

function Get-ScriptBackupTables {
    $query = @"
select
    t.name as BackupTable,
    left(t.name, len(t.name) - 14) as SourceTable,
    right(t.name, 14) as BackupTimestamp,
    t.create_date as Created,
    sum(case when p.index_id in (0, 1) then p.rows else 0 end) as [Rows],
    case
        when object_id(quotename(s.name) + N'.' + quotename(left(t.name, len(t.name) - 14)), N'U') is null then 0
        else 1
    end as SourceTableExists
from sys.tables t
inner join sys.schemas s on t.schema_id = s.schema_id
left join sys.partitions p on p.object_id = t.object_id
where s.name = N'dbo'
  and len(t.name) > 14
  and right(t.name, 14) not like '%[^0-9]%'
group by t.name, t.create_date, s.name
order by SourceTable, BackupTimestamp desc;
"@

    $rows = @(Invoke-TranslationQuery -Query $query)
    return @($rows | ForEach-Object {
        $sourceTable = [string]$_.SourceTable
        [pscustomobject]@{
            OptionName        = Get-ScriptBackupOptionName -SourceTable $sourceTable
            SourceTable       = $sourceTable
            BackupTable       = [string]$_.BackupTable
            BackupTimestamp   = [string]$_.BackupTimestamp
            BackupDateTime    = Convert-BackupTimestampToText -Timestamp ([string]$_.BackupTimestamp)
            Created           = $_.Created
            Rows              = $_.Rows
            SourceTableExists = ([int]$_.SourceTableExists -eq 1)
        }
    })
}

function Get-DatabaseTableCount {
    param([Parameter(Mandatory = $true)][string]$TableName)

    $sqlName = Get-QuotedSqlTableName -TableName $TableName
    $result = @(Invoke-TranslationQuery -Query "select count_big(1) as [Rows] from $sqlName;" | Select-Object -First 1)
    if ($result.Count -eq 0) { return 0 }
    return [int64]$result[0].Rows
}

function Get-DatabaseBackupPreview {
    param([Parameter(Mandatory = $true)][string]$BackupTableName)

    $backupSqlName = Get-QuotedSqlTableName -TableName $BackupTableName
    return @(Invoke-TranslationQuery -Query "select top 20 * from $backupSqlName;")
}

function Restore-DatabaseTableFromBackup {
    param(
        [Parameter(Mandatory = $true)][string]$TargetTableName,
        [Parameter(Mandatory = $true)][string]$BackupTableName
    )

    $targetSqlName = Get-QuotedSqlTableName -TableName $TargetTableName
    $backupSqlName = Get-QuotedSqlTableName -TableName $BackupTableName
    $targetObjectName = $targetSqlName.Replace("'", "''")
    $backupObjectName = $backupSqlName.Replace("'", "''")
    $identityOffSql = "set identity_insert $targetSqlName off;".Replace("'", "''")

    $query = @"
set xact_abort on;

declare @RestoredRows int = 0;
declare @DeletedRows int = 0;
declare @UseIdentityInsert bit = 0;

begin try
    begin transaction;

    declare @TargetObjectId int = object_id(N'$targetObjectName', N'U');
    declare @BackupObjectId int = object_id(N'$backupObjectName', N'U');

    if @TargetObjectId is null
        raiserror('Target table was not found.', 16, 1);

    if @BackupObjectId is null
        raiserror('Backup table was not found.', 16, 1);

    declare @ColumnList nvarchar(max);

    select @ColumnList = stuff((
        select ', ' + quotename(TargetColumns.name)
        from sys.columns TargetColumns
        inner join sys.columns BackupColumns
            on BackupColumns.object_id = @BackupObjectId
           and BackupColumns.name = TargetColumns.name
        where TargetColumns.object_id = @TargetObjectId
          and TargetColumns.is_computed = 0
        order by TargetColumns.column_id
        for xml path(''), type
    ).value('.', 'nvarchar(max)'), 1, 2, '');

    if @ColumnList is null or len(@ColumnList) = 0
        raiserror('No matching columns were found between the target table and the selected backup table.', 16, 1);

    delete from $targetSqlName;
    set @DeletedRows = @@rowcount;

    declare @IdentityColumn sysname = (
        select top 1 name
        from sys.columns
        where object_id = @TargetObjectId
          and is_identity = 1
    );

    if @IdentityColumn is not null and charindex(quotename(@IdentityColumn), @ColumnList) > 0
    begin
        set @UseIdentityInsert = 1;
        exec sp_executesql N'set identity_insert $targetSqlName on;';
    end;

    declare @InsertSql nvarchar(max) =
        N'insert into $targetSqlName (' + @ColumnList + N') select ' + @ColumnList + N' from $backupSqlName; set @Rows = @@rowcount;';

    exec sp_executesql @InsertSql, N'@Rows int output', @Rows = @RestoredRows output;

    if @UseIdentityInsert = 1
    begin
        exec sp_executesql N'set identity_insert $targetSqlName off;';
        set @UseIdentityInsert = 0;
    end;

    commit transaction;

    select @DeletedRows as DeletedRows, @RestoredRows as RestoredRows;
end try
begin catch
    if @UseIdentityInsert = 1
    begin
        begin try
            exec sp_executesql N'$identityOffSql';
        end try
        begin catch
        end catch
    end;

    if @@trancount > 0
        rollback transaction;

    throw;
end catch;
"@

    $result = @(Invoke-TranslationQuery -Query $query | Select-Object -First 1)
    if ($result.Count -eq 0) {
        return [pscustomobject]@{
            DeletedRows  = 0
            RestoredRows = 0
        }
    }

    return [pscustomobject]@{
        DeletedRows  = [int64]$result[0].DeletedRows
        RestoredRows = [int64]$result[0].RestoredRows
    }
}

function Show-RollbackScriptChangesMenu {
    Clear-Host
    Show-SectionTitle "Rollback Script Changes"
    Write-Host "This tool searches dbo tables for backups named TableNameyyyyMMddHHmmss." -ForegroundColor Cyan
    Write-Host "Type q at any prompt to return to Database Tools." -ForegroundColor DarkGray
    Write-Host ""

    try {
        Write-StreamingLog -Percent 10 -Step "Search" -Description "Scanning database for script-created backup tables."
        $allBackupTables = @(Get-ScriptBackupTables)
        $backups = @($allBackupTables | Where-Object { $_.SourceTableExists })
        $missingSourceBackups = @($allBackupTables | Where-Object { -not $_.SourceTableExists })

        if ($backups.Count -eq 0) {
            Write-Host "No restorable backup tables were found." -ForegroundColor Yellow
            if ($missingSourceBackups.Count -gt 0) {
                Write-Host "Some timestamped backup-like tables were found, but their source table no longer exists." -ForegroundColor Yellow
            }
            Pause-Screen
            return
        }

        $groups = @($backups |
            Group-Object -Property SourceTable |
            ForEach-Object {
                $firstBackup = $_.Group | Select-Object -First 1
                [pscustomobject]@{
                    SourceTable = [string]$_.Name
                    OptionName  = [string]$firstBackup.OptionName
                    Count       = $_.Count
                    Backups     = @($_.Group | Sort-Object BackupTimestamp -Descending)
                }
            } |
            Sort-Object OptionName, SourceTable)

        Write-Host ""
        Write-Host "Available rollback options:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $groups.Count; $i++) {
            $group = $groups[$i]
            Write-Host "[$($i + 1)] $($group.OptionName) - dbo.$($group.SourceTable) ($($group.Count) backup(s))"
        }
        Write-Host "[q] Back"
        Write-Host ""

        while ($true) {
            $optionChoice = Read-Host "Choose the option to rollback"
            if (Test-IsBack $optionChoice) { return }

            $selectedOptionIndex = 0
            if ([int]::TryParse($optionChoice, [ref]$selectedOptionIndex) -and
                $selectedOptionIndex -ge 1 -and
                $selectedOptionIndex -le $groups.Count) {
                $selectedGroup = $groups[$selectedOptionIndex - 1]
                break
            }

            Write-Host "That is not a valid rollback option." -ForegroundColor Yellow
        }

        Clear-Host
        Show-SectionTitle "Select Backup Date"
        Write-Host "Option: $($selectedGroup.OptionName)" -ForegroundColor Cyan
        Write-Host "Target table to restore: dbo.$($selectedGroup.SourceTable)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Available backup dates, newest first:" -ForegroundColor Cyan

        $selectedBackups = @($selectedGroup.Backups | Sort-Object BackupTimestamp -Descending)
        for ($i = 0; $i -lt $selectedBackups.Count; $i++) {
            $backup = $selectedBackups[$i]
            Write-Host "[$($i + 1)] $($backup.BackupDateTime) - $($backup.BackupTable) - rows: $($backup.Rows)"
        }
        Write-Host "[q] Back"
        Write-Host ""

        while ($true) {
            $backupChoice = Read-Host "Choose the backup date to restore"
            if (Test-IsBack $backupChoice) { return }

            $selectedBackupIndex = 0
            if ([int]::TryParse($backupChoice, [ref]$selectedBackupIndex) -and
                $selectedBackupIndex -ge 1 -and
                $selectedBackupIndex -le $selectedBackups.Count) {
                $selectedBackup = $selectedBackups[$selectedBackupIndex - 1]
                break
            }

            Write-Host "That is not a valid backup date choice." -ForegroundColor Yellow
        }

        Write-StreamingLog -Percent 25 -Step "Preview" -Description "Loading row counts and a top 20 preview."
        $currentRows = Get-DatabaseTableCount -TableName $selectedGroup.SourceTable
        $backupRows = Get-DatabaseTableCount -TableName $selectedBackup.BackupTable
        $previewRows = @(Get-DatabaseBackupPreview -BackupTableName $selectedBackup.BackupTable)

        Show-SectionTitle "Rollback Preview"
        Show-ConsoleResults -Data @([pscustomobject]@{
            TargetTable = "dbo.$($selectedGroup.SourceTable)"
            BackupTable = "dbo.$($selectedBackup.BackupTable)"
            CurrentRows = $currentRows
            BackupRows  = $backupRows
            BackupDate  = $selectedBackup.BackupDateTime
        })

        Show-SectionTitle "Backup Preview: Top 20 Rows"
        Show-ConsoleResults -Data $previewRows

        Write-Host ""
        Write-Host "Warning: this will replace all rows in dbo.$($selectedGroup.SourceTable) with the selected backup table." -ForegroundColor Red
        Write-Host "A fresh safety backup of dbo.$($selectedGroup.SourceTable) will be created first." -ForegroundColor Yellow
        $confirm = Read-Host "Type ROLLBACK to restore this backup, or q to return"
        if (Test-IsBack $confirm) { return }
        if ($confirm -cne 'ROLLBACK') {
            Write-Host "Rollback cancelled. No database changes were made." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        Write-StreamingLog -Percent 45 -Step "Safety backup" -Description "Creating a backup of the current dbo.$($selectedGroup.SourceTable) table."
        $safetyBackupTable = New-DatabaseTableBackup -TableName $selectedGroup.SourceTable
        Write-Host "Safety backup created: $safetyBackupTable" -ForegroundColor Green

        Write-StreamingLog -Percent 70 -Step "Rollback" -Description "Restoring dbo.$($selectedGroup.SourceTable) from dbo.$($selectedBackup.BackupTable)."
        $restoreResult = Restore-DatabaseTableFromBackup -TargetTableName $selectedGroup.SourceTable -BackupTableName $selectedBackup.BackupTable

        Write-StreamingLog -Percent 100 -Step "Done" -Description "Rollback completed."
        Show-SectionTitle "Rollback Complete"
        Write-Host "Restored table: dbo.$($selectedGroup.SourceTable)" -ForegroundColor Green
        Write-Host "Restored from: dbo.$($selectedBackup.BackupTable)" -ForegroundColor Green
        Write-Host "Safety backup kept as: $safetyBackupTable" -ForegroundColor Yellow
        Show-ConsoleResults -Data @($restoreResult)
    }
    catch {
        Show-LoggedError -Prefix "The rollback did not complete" -Context "Database Tools - rollback script changes" -ErrorRecord $_
    }

    Pause-Screen
}

function Show-IntegrityMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== Translation data checks ===" -ForegroundColor Cyan
        Write-Host "1) Show record counts"
        Write-Host "2) Find missing translations"
        Write-Host "3) Review or remove disconnected translation rows"
        Write-Host "q) Back"
        $sub = Read-Host "Choose a check"

        if (Test-IsBack $sub) { return }
        switch ($sub) {
            '1' {
                try {
                    $statsQuery = @"
select
    (select count(*) from dbo.RootTranslation) as [Root items],
    (select count(*) from dbo.LanguageTranslations) as [Translation rows],
    (select count(*)
     from dbo.LanguageTranslations lt
     where not exists (select 1 from dbo.RootTranslation rt where rt.RootId = lt.RootId)) as [Disconnected translation rows];
"@
                    $stats = Invoke-TranslationQuery -Query $statsQuery
                    Show-SectionTitle "Translation Record Counts"
                    Show-ConsoleResults -Data @($stats)
                }
                catch {
                    Show-LoggedError -Prefix "The counts could not be loaded" -Context "Translation data checks - record counts" -ErrorRecord $_
                }
                Pause-Screen
            }
            '2' {
                try {
                    $langs = Get-LanguageCatalog
                    $selectedIds = Prompt-LanguageSelection -Languages $langs -AllowCreateNew $true
                    if ($null -eq $selectedIds) { continue }

                    $selectedMetadata = Get-LanguageSelectionMetadata -LanguageIds $selectedIds
                    if (@($selectedMetadata | Where-Object { $_.LanguageType -ne 'English' }).Count -eq 0) {
                        Write-Host "Choose at least one target language besides English to find missing translations." -ForegroundColor Yellow
                        Pause-Screen
                        continue
                    }

                    $sql = Get-MissingTranslationSql -LanguageIds $selectedIds
                    $data = Invoke-TranslationQuery -Query $sql
                    Show-OutputMenu -Data @($data) -FileNamePrefix "Missing_Translations" -Title "Missing Translations"
                }
                catch {
                    Show-LoggedError -Prefix "The missing translation report could not be created" -Context "Translation data checks - find missing translations" -ErrorRecord $_
                    Pause-Screen
                }
            }
            '3' {
                Show-OrphanTranslationMenu
            }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Get-OrphanTranslations {
    $query = @"
select
    lt.RootId as [Root ID],
    lt.TranslationItem as [Translation text],
    lt.LanguageId as [Language ID],
    l.LanguageType as [Language]
from dbo.LanguageTranslations lt
left join dbo.RootTranslation rt on lt.RootId = rt.RootId
left join dbo.Languages l on lt.LanguageId = l.LanguageId
where rt.RootId is null
order by lt.RootId;
"@
    $orphans = Invoke-TranslationQuery -Query $query
    return @($orphans)
}

function Show-OrphanTranslationMenu {
    while ($true) {
        Clear-Host
        try {
            $orphans = @(Get-OrphanTranslations)
        }
        catch {
            Show-LoggedError -Prefix "Disconnected rows could not be loaded" -Context "Translation data checks - disconnected rows" -ErrorRecord $_
            Pause-Screen
            return
        }

        Write-Host "=== Disconnected translation rows ===" -ForegroundColor Cyan
        Write-Host "Disconnected rows found: $($orphans.Count)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "1) Show disconnected rows on screen"
        Write-Host "2) Save disconnected rows to CSV"
        Write-Host "3) Show rows and save them to CSV"
        Write-Host "4) Back up and delete disconnected rows"
        Write-Host "q) Back"
        $orphanChoice = Read-Host "Choose an option"

        if (Test-IsBack $orphanChoice) { return }
        switch ($orphanChoice) {
            '1' {
                Show-SectionTitle "Disconnected Translation Rows"
                Show-ConsoleResults -Data $orphans
                Pause-Screen
            }
            '2' {
                [void](Export-SafeCsv -Data $orphans -FileNamePrefix "Disconnected_Translations")
                Pause-Screen
            }
            '3' {
                Show-SectionTitle "Disconnected Translation Rows"
                Show-ConsoleResults -Data $orphans
                [void](Export-SafeCsv -Data $orphans -FileNamePrefix "Disconnected_Translations")
                Pause-Screen
            }
            '4' {
                if ($orphans.Count -eq 0) {
                    Write-Host "No disconnected translation rows were found." -ForegroundColor Green
                    Pause-Screen
                    continue
                }

                Write-Host ""
                Write-Host "Warning: this will change the database." -ForegroundColor Red
                Write-Host "The script will first create a full LanguageTranslations backup, then delete disconnected rows." -ForegroundColor Yellow
                $confirm = Read-Host "Type DELETE to continue, or anything else to cancel"

                if ($confirm -ceq 'DELETE') {
                    try {
                        $backupTable = New-DatabaseTableBackup -TableName "LanguageTranslations"
                        Write-Host "Backup table created: $backupTable" -ForegroundColor Green
                        Write-StreamingLog -Percent 50 -Step "Cleanup" -Description "Deleting disconnected LanguageTranslations rows."
                        $backupQuery = @"
set xact_abort on;
begin transaction;
delete lt
from dbo.LanguageTranslations lt
where not exists (select 1 from dbo.RootTranslation rt where rt.RootId = lt.RootId);
commit transaction;
"@
                        Invoke-TranslationQuery -Query $backupQuery
                        Write-Host "Done. Backup table kept as: $backupTable" -ForegroundColor Green
                    }
                    catch {
                        Show-LoggedError -Prefix "The cleanup did not complete" -Context "Translation data checks - delete disconnected rows" -ErrorRecord $_
                    }
                }
                else {
                    Write-Host "Cleanup cancelled. No rows were deleted." -ForegroundColor Cyan
                }
                Pause-Screen
            }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-DatabaseImportExportOperationsMenu {
    while ($true) {
        Clear-Host
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                      IMPORT/EXPORT OPERATIONS" -ForegroundColor Cyan
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "Connected to: $($Global:SelectedInstance) / $($Global:SelectedDb)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "1) Export Language File"
        Write-Host "2) Import new Language with a translated CSV file"
        Write-Host "3) Import CSV/Excel to database"
        Write-Host "4) Migrate data between database tables"
        Write-Host "q) Back to Database Tools"
        Write-Host "------------------------------------------------------------------------"
        $choice = Read-Host "Choose an option"

        if (Test-IsBack $choice) { return }

        switch ($choice) {
            '1' {
                Invoke-DatabaseToolWithTranslationSchema -Context "Import/Export operations - Export Language File" -Action { Show-ExtractionMenu }
            }
            '2' {
                Invoke-DatabaseToolWithTranslationSchema -Context "Import/Export operations - Import new Language with a translated CSV file" -Action { Show-TranslationImportMenu }
            }
            '3' {
                Invoke-LoggedToolAction -Context "Import/Export operations - Import CSV/Excel to database" -Action { Show-ImportCsvExcelToDatabaseMenu }
            }
            '4' {
                Invoke-LoggedToolAction -Context "Import/Export operations - migrate data between database tables" -Action { Invoke-DatabaseTableMigration }
            }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-DanoneFeaturesMenu {
    while ($true) {
        Clear-Host
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                            DANONE FEATURES" -ForegroundColor Cyan
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "Connected to: $($Global:SelectedInstance) / $($Global:SelectedDb)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "1) Import Luleburgas System Settings"
        Write-Host "2) Import Luleburgas User Roles and Privileges"
        Write-Host "q) Back to Database Tools"
        Write-Host "------------------------------------------------------------------------"
        $choice = Read-Host "Choose an option"

        if (Test-IsBack $choice) { return }

        switch ($choice) {
            '1' {
                Invoke-LoggedToolAction -Context "Danone Features - Import Luleburgas System Settings" -Action { Show-LuleburgasSystemSettingsMenu }
            }
            '2' {
                Invoke-LoggedToolAction -Context "Danone Features - Import Luleburgas User Roles and Privileges" -Action { Invoke-LuleburgasRolePermissionsImport }
            }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function ConvertTo-DatabaseSearchSizeMegabytes {
    param([Parameter(Mandatory = $true)][object]$DatabaseSize)

    $sizeText = ConvertTo-RequiredText -Value $DatabaseSize -Purpose "database size"
    if ($sizeText -notmatch '^\s*(?<Amount>[\d\.,]+)\s*(?<Unit>KB|MB|GB|TB)\s*$') {
        throw "Could not interpret the database size returned by SQL Server: $sizeText"
    }

    $amountText = $matches.Amount.Replace(',', '')
    $amount = [decimal]0
    if (-not [decimal]::TryParse($amountText, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$amount)) {
        throw "Could not interpret the database size returned by SQL Server: $sizeText"
    }

    switch ($matches.Unit.ToUpperInvariant()) {
        'KB' { return ($amount / 1024) }
        'MB' { return $amount }
        'GB' { return ($amount * 1024) }
        'TB' { return ($amount * 1024 * 1024) }
    }
}

function Format-DatabaseSearchSize {
    param([Parameter(Mandatory = $true)][decimal]$SizeMegabytes)

    if ($SizeMegabytes -lt 1024) {
        return ("{0:0}MB" -f $SizeMegabytes)
    }

    return ("{0:0.0}GB" -f ($SizeMegabytes / 1024))
}

function Get-DatabaseSearchSizeMegabytes {
    $result = @(Invoke-DatabaseSearchQuery -Query 'EXEC sp_spaceused;' -CommandTimeout 60 | Select-Object -First 1)
    if ($result.Count -eq 0 -or $null -eq $result[0].database_size) {
        throw "SQL Server did not return a database size."
    }

    return (ConvertTo-DatabaseSearchSizeMegabytes -DatabaseSize $result[0].database_size)
}

function Read-DatabaseSearchText {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    while ($true) {
        $value = Read-Host $Prompt
        if (Test-IsBack $value) { return $null }

        $value = [string]$value
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host "Please enter text to search, or type q to go back." -ForegroundColor Yellow
            continue
        }

        if ($value.Length -gt 100) {
            Write-Host "Please limit the search text to 100 characters." -ForegroundColor Yellow
            continue
        }

        return $value
    }
}

function Read-DatabaseSearchTableSizeLimit {
    while ($true) {
        $value = Read-Host "Exclude tables larger than this many MB (Enter = 50, 0 = no limit, q = back)"
        if (Test-IsBack $value) {
            return [pscustomobject]@{ Cancelled = $true; LimitMegabytes = $null }
        }

        if ([string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{ Cancelled = $false; LimitMegabytes = [decimal]50 }
        }

        $limit = [decimal]0
        if ([decimal]::TryParse($value, [Globalization.NumberStyles]::Number, [Globalization.CultureInfo]::InvariantCulture, [ref]$limit) -and $limit -ge 0) {
            if ($limit -eq 0) {
                return [pscustomobject]@{ Cancelled = $false; LimitMegabytes = $null }
            }

            return [pscustomobject]@{ Cancelled = $false; LimitMegabytes = $limit }
        }

        Write-Host "Enter a positive size in MB, 0 for no limit, or q to go back." -ForegroundColor Yellow
    }
}

function Get-DatabaseTextSearchSql {
    param(
        [Parameter(Mandatory = $true)][string]$SearchText,
        [AllowNull()][object]$TableSizeLimitMegabytes
    )

    $searchTextLiteral = Get-SqlUnicodeLiteral -Value $SearchText
    $sizeLimitSql = if ($null -eq $TableSizeLimitMegabytes) {
        'NULL'
    }
    else {
        ([decimal]$TableSizeLimitMegabytes).ToString([Globalization.CultureInfo]::InvariantCulture)
    }

    return @"
set nocount on;

declare @SearchStr nvarchar(100) = $searchTextLiteral;
declare @TableSizeLimitMB decimal(19, 2) = $sizeLimitSql;
declare @Results table (
    TableName nvarchar(370),
    ColumnName nvarchar(370),
    FoundValue nvarchar(max)
);

declare @TableName nvarchar(370), @ColumnName nvarchar(370), @Query nvarchar(max);

declare ColumnCursor cursor local fast_forward for
select
    quotename(s.name) + N'.' + quotename(t.name) as TableName,
    quotename(c.name) as ColumnName
from sys.columns c
inner join sys.tables t on c.object_id = t.object_id
inner join sys.schemas s on t.schema_id = s.schema_id
inner join sys.types ty on c.user_type_id = ty.user_type_id
inner join (
    select p.object_id, (sum(a.total_pages) * 8) / 1024.0 as TotalSpaceMB
    from sys.partitions p
    inner join sys.allocation_units a on p.partition_id = a.container_id
    group by p.object_id
) as SizeStats on t.object_id = SizeStats.object_id
where ty.name in (N'varchar', N'nvarchar', N'char', N'nchar', N'text', N'ntext')
  and (@TableSizeLimitMB is null or SizeStats.TotalSpaceMB <= @TableSizeLimitMB);

open ColumnCursor;
fetch next from ColumnCursor into @TableName, @ColumnName;

while @@fetch_status = 0
begin
    set @Query = N'select @ResultTableName, @ResultColumnName, cast(' + @ColumnName + N' as nvarchar(max))
                   from ' + @TableName + N' with (nolock)
                   where cast(' + @ColumnName + N' as nvarchar(max)) like N''%'' + @SearchStr + N''%'';';

    begin try
        insert into @Results (TableName, ColumnName, FoundValue)
        exec sys.sp_executesql @Query,
            N'@SearchStr nvarchar(100), @ResultTableName nvarchar(370), @ResultColumnName nvarchar(370)',
            @SearchStr = @SearchStr,
            @ResultTableName = @TableName,
            @ResultColumnName = @ColumnName;
    end try
    begin catch
        -- A single inaccessible or incompatible text column must not stop the full search.
    end catch;

    fetch next from ColumnCursor into @TableName, @ColumnName;
end;

close ColumnCursor;
deallocate ColumnCursor;

select TableName, ColumnName, FoundValue
from @Results
group by TableName, ColumnName, FoundValue
order by TableName, ColumnName, FoundValue;
"@
}

function Show-DatabaseSearchOutput {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Data,
        [Parameter(Mandatory = $true)][string]$Title
    )

    $rows = @(Normalize-DataRows -Data $Data)
    Show-SectionTitle $Title
    if ($rows.Count -eq 0) {
        Write-Host "No results found." -ForegroundColor Yellow
    }
    else {
        Show-ConsoleResults -Data $rows
    }

    Pause-Screen
}

function Search-DatabaseText {
    Clear-Host
    Show-SectionTitle "Search Text in Database"
    Write-Host "This read-only search checks text columns in the selected database." -ForegroundColor Cyan
    Write-Host "Type q at any prompt to return to Database Search Tools." -ForegroundColor DarkGray
    Write-Host ""

    $searchText = Read-DatabaseSearchText -Prompt "Text to find"
    if ($null -eq $searchText) { return }

    try {
        Write-StreamingLog -Percent 10 -Step "Database size" -Description "Reading the selected database size."
        $databaseSizeMegabytes = Get-DatabaseSearchSizeMegabytes
        $formattedSize = Format-DatabaseSearchSize -SizeMegabytes $databaseSizeMegabytes
        Write-Host "Database size: $formattedSize" -ForegroundColor Green

        $tableSizeLimitMegabytes = $null
        if ($databaseSizeMegabytes -gt 2048) {
            Write-Host "This database is larger than 2 GB. Excluding large tables can make the search faster." -ForegroundColor Yellow
            $limitSelection = Read-DatabaseSearchTableSizeLimit
            if ($limitSelection.Cancelled) { return }
            $tableSizeLimitMegabytes = $limitSelection.LimitMegabytes
        }
        else {
            Write-Host "A full text-column search will be performed because the database is 2 GB or smaller." -ForegroundColor Gray
        }

        $limitDescription = if ($null -eq $tableSizeLimitMegabytes) { 'No table-size limit' } else { "Tables up to $tableSizeLimitMegabytes MB" }
        Write-Host "Table scope: $limitDescription" -ForegroundColor Cyan
        Write-StreamingLog -Percent 30 -Step "Prepare" -Description "Building the read-only text search."
        $query = Get-DatabaseTextSearchSql -SearchText $searchText -TableSizeLimitMegabytes $tableSizeLimitMegabytes
        Write-StreamingLog -Percent 45 -Step "Search" -Description "Scanning text columns. This can take up to 15 minutes."
        $results = @(Invoke-DatabaseSearchQuery -Query $query -CommandTimeout 900)
        Write-StreamingLog -Percent 100 -Step "Complete" -Description "Text search completed."

        Write-Host "Matches found: $($results.Count)" -ForegroundColor Green
        Show-DatabaseSearchOutput -Data $results -Title "Database Text Search Results"
    }
    catch {
        Show-LoggedError -Prefix "The database text search did not complete" -Context "Database Search Tools - Search text in Database" -ErrorRecord $_
        Pause-Screen
    }
}

function Find-DatabaseTablesByColumnName {
    Clear-Host
    Show-SectionTitle "Find Which Table Has a Specific Column"
    Write-Host "Use % before or after the text for a partial column-name search." -ForegroundColor Cyan
    Write-Host "Example: %SMTP% finds columns containing SMTP; SMTP finds an exact match." -ForegroundColor Gray
    Write-Host "Type q at any prompt to return to Database Search Tools." -ForegroundColor DarkGray
    Write-Host ""

    $columnPattern = Read-DatabaseSearchText -Prompt "Column name or pattern"
    if ($null -eq $columnPattern) { return }

    try {
        $columnPatternLiteral = Get-SqlUnicodeLiteral -Value $columnPattern
        $query = @"
select
    s.name as SchemaName,
    t.name as TableName,
    c.name as ColumnName
from sys.tables t
inner join sys.schemas s on t.schema_id = s.schema_id
inner join sys.columns c on t.object_id = c.object_id
where c.name like $columnPatternLiteral
order by s.name, t.name, c.name;
"@

        Write-StreamingLog -Percent 25 -Step "Search" -Description "Looking up matching table columns."
        $results = @(Invoke-DatabaseSearchQuery -Query $query -CommandTimeout 120)
        Write-StreamingLog -Percent 100 -Step "Complete" -Description "Column search completed."
        Show-DatabaseSearchOutput -Data $results -Title "Tables with Matching Columns"
    }
    catch {
        Show-LoggedError -Prefix "The column search did not complete" -Context "Database Search Tools - Find table by column" -ErrorRecord $_
        Pause-Screen
    }
}

function Search-DatabaseStoredProcedures {
    Clear-Host
    Show-SectionTitle "Text Search in Stored Procedures"
    Write-Host "This read-only search checks the definitions of SQL stored procedures." -ForegroundColor Cyan
    Write-Host "Type q at any prompt to return to Database Search Tools." -ForegroundColor DarkGray
    Write-Host ""

    $searchText = Read-DatabaseSearchText -Prompt "Text to find"
    if ($null -eq $searchText) { return }

    try {
        $searchTextLiteral = Get-SqlUnicodeLiteral -Value $searchText
        $query = @"
declare @SearchText nvarchar(100) = $searchTextLiteral;

select
    schema_name(o.schema_id) as SchemaName,
    o.name as ProcedureName,
    m.definition as Definition
from sys.sql_modules m
inner join sys.objects o on m.object_id = o.object_id
where o.type = N'P'
  and m.definition like N'%' + @SearchText + N'%'
order by schema_name(o.schema_id), o.name;
"@

        Write-StreamingLog -Percent 25 -Step "Search" -Description "Scanning stored procedure definitions."
        $results = @(Invoke-DatabaseSearchQuery -Query $query -CommandTimeout 300)
        Write-StreamingLog -Percent 100 -Step "Complete" -Description "Stored procedure search completed."
        Show-DatabaseSearchOutput -Data $results -Title "Stored Procedures with Matching Text"
    }
    catch {
        Show-LoggedError -Prefix "The stored procedure search did not complete" -Context "Database Search Tools - Text Search in Sprocs" -ErrorRecord $_
        Pause-Screen
    }
}

function Show-DatabaseSearchToolsMenu {
    while ($true) {
        Clear-Host
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                         DATABASE SEARCH TOOLS" -ForegroundColor Cyan
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "Connected to: $($Global:SelectedInstance) / $($Global:SelectedDb)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "1) Search text in Database"
        Write-Host "2) Find which table has a specific column"
        Write-Host "3) Text Search in Sprocs"
        Write-Host "q) Back to Database Tools"
        Write-Host "------------------------------------------------------------------------"
        $choice = Read-Host "Choose an option"

        if (Test-IsBack $choice) { return }

        switch ($choice) {
            '1' { Search-DatabaseText }
            '2' { Find-DatabaseTablesByColumnName }
            '3' { Search-DatabaseStoredProcedures }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Read-DatabasePerformanceTopCount {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [int]$DefaultValue = 20
    )

    while ($true) {
        $value = Read-Host "$Prompt (Enter = $DefaultValue, q = back)"
        if (Test-IsBack $value) { return $null }
        if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultValue }

        $count = 0
        if ([int]::TryParse($value, [ref]$count) -and $count -ge 1 -and $count -le 1000) {
            return $count
        }

        Write-Host "Enter a whole number from 1 to 1000, or type q to go back." -ForegroundColor Yellow
    }
}

function Read-DatabasePerformanceTimeWindow {
    while ($true) {
        $value = Read-Host "Time window (Enter = 10min, examples: 5min or 2h, q = back)"
        if (Test-IsBack $value) { return $null }
        if ([string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{ Amount = 10; DatePart = 'minute'; Display = '10 minutes' }
        }

        if ($value.Trim() -match '^(?<Amount>[1-9]\d{0,3})\s*(?<Unit>m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days)$') {
            $amount = [int]$matches.Amount
            $datePart = switch ($matches.Unit.ToLowerInvariant()) {
                { $_ -in @('m', 'min', 'mins', 'minute', 'minutes') } { 'minute'; break }
                { $_ -in @('h', 'hr', 'hrs', 'hour', 'hours') } { 'hour'; break }
                default { 'day' }
            }
            $displayUnit = if ($amount -eq 1) { $datePart } else { "$datePart" + 's' }
            return [pscustomobject]@{ Amount = $amount; DatePart = $datePart; Display = "$amount $displayUnit" }
        }

        Write-Host "Enter a time window such as 5min, 2h, or 1d; or type q to go back." -ForegroundColor Yellow
    }
}

function Show-DatabasePerformanceOutput {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Data,
        [Parameter(Mandatory = $true)][string]$FileNamePrefix,
        [Parameter(Mandatory = $true)][string]$Title,
        [string[]]$PostDisplayNotes = @()
    )

    $rows = @(Normalize-DataRows -Data $Data)
    if ($rows.Count -eq 0) {
        Write-Host "No results were found." -ForegroundColor Yellow
        Pause-Screen
        return
    }

    Show-SectionTitle "$Title ($($rows.Count) rows)"
    Show-ConsoleResults -Data $rows
    foreach ($note in $PostDisplayNotes) { Write-Host $note -ForegroundColor Yellow }
    Pause-Screen
}

function Show-DatabasePerformanceSqlOutput {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Data,
        [Parameter(Mandatory = $true)][string]$Title
    )

    $rows = @(Normalize-DataRows -Data $Data)
    if ($rows.Count -eq 0) {
        Write-Host "No results were found." -ForegroundColor Yellow
        Pause-Screen
        return
    }

    $displayRows = @()
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $displayRow = [ordered]@{ Line = $index + 1 }
        foreach ($property in $rows[$index].PSObject.Properties) {
            if ($property.Name -eq 'FullStatementText') { continue }
            $displayRow[$property.Name] = $property.Value
        }
        $displayRows += [pscustomobject]$displayRow
    }

    Show-SectionTitle "$Title ($($rows.Count) rows)"
    Show-ConsoleResults -Data $displayRows
    Write-Host "StatementText is shortened to 50 characters in this view." -ForegroundColor Gray

    while ($true) {
        $choice = Read-Host "Enter a line number to view the full SQL, or press Enter / type q to return"
        if ([string]::IsNullOrWhiteSpace($choice) -or (Test-IsBack $choice)) { return }

        $lineNumber = 0
        if (-not [int]::TryParse($choice, [ref]$lineNumber) -or $lineNumber -lt 1 -or $lineNumber -gt $rows.Count) {
            Write-Host "Enter a line number from 1 to $($rows.Count), or type q to go back." -ForegroundColor Yellow
            continue
        }

        $fullText = [string]$rows[$lineNumber - 1].FullStatementText
        Clear-Host
        Show-SectionTitle "Full SQL Text - Line $lineNumber"
        Write-Host $fullText
        Pause-Screen
        return
    }
}

function Invoke-DatabasePerformanceSqlReport {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string]$Context,
        [int]$CommandTimeout = 300
    )

    Clear-Host
    Show-SectionTitle $Title
    Write-Host $Description -ForegroundColor Cyan
    Write-Host "This diagnostic is read-only." -ForegroundColor Gray

    try {
        Write-StreamingLog -Percent 20 -Step "Collect" -Description "Running the SQL Server diagnostic."
        $results = @(Invoke-DatabaseSearchQuery -Query $Query -CommandTimeout $CommandTimeout)
        Write-StreamingLog -Percent 100 -Step "Complete" -Description "Diagnostic completed."
        Show-DatabasePerformanceSqlOutput -Data $results -Title $Title
    }
    catch {
        Show-LoggedError -Prefix "The database performance diagnostic did not complete" -Context $Context -ErrorRecord $_
        Pause-Screen
    }
}

function Invoke-DatabasePerformanceReport {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Query,
        [Parameter(Mandatory = $true)][string]$FileNamePrefix,
        [Parameter(Mandatory = $true)][string]$Context,
        [int]$CommandTimeout = 300,
        [string[]]$PostDisplayNotes = @()
    )

    Clear-Host
    Show-SectionTitle $Title
    Write-Host $Description -ForegroundColor Cyan
    Write-Host "This diagnostic is read-only." -ForegroundColor Gray

    try {
        Write-StreamingLog -Percent 20 -Step "Collect" -Description "Running the SQL Server diagnostic."
        $results = @(Invoke-DatabaseSearchQuery -Query $Query -CommandTimeout $CommandTimeout)
        Write-StreamingLog -Percent 100 -Step "Complete" -Description "Diagnostic completed."
        Show-DatabasePerformanceOutput -Data $results -FileNamePrefix $FileNamePrefix -Title $Title -PostDisplayNotes $PostDisplayNotes
    }
    catch {
        Show-LoggedError -Prefix "The database performance diagnostic did not complete" -Context $Context -ErrorRecord $_
        Pause-Screen
    }
}

function Show-DatabaseTableDiskUsage {
    Clear-Host
    Show-SectionTitle "Disk Usage Per Table"
    Write-Host "Lists the largest tables by allocated, used, and unused space." -ForegroundColor Cyan
    Write-Host "Type q to return to Database Performance." -ForegroundColor DarkGray
    $topCount = Read-DatabasePerformanceTopCount -Prompt "Number of tables to show" -DefaultValue 30
    if ($null -eq $topCount) { return }

    $query = @"
select top ($topCount)
    t.name as TableName,
    s.name as SchemaName,
    sum(p.rows) as RowCounts,
    cast(round(sum(a.total_pages) * 8.0 / 1024, 2) as numeric(36, 2)) as TotalSpaceMB,
    cast(round(sum(a.used_pages) * 8.0 / 1024, 2) as numeric(36, 2)) as UsedSpaceMB,
    cast(round((sum(a.total_pages) - sum(a.used_pages)) * 8.0 / 1024, 2) as numeric(36, 2)) as UnusedSpaceMB
from sys.tables as t
inner join sys.schemas as s on t.schema_id = s.schema_id
inner join sys.partitions as p on t.object_id = p.object_id
inner join sys.allocation_units as a on p.partition_id = a.container_id
group by t.name, s.name
order by TotalSpaceMB desc;
"@
    Invoke-DatabasePerformanceReport -Title "Disk Usage Per Table" -Description "Showing the top $topCount table(s) by allocated disk space." -Query $query -FileNamePrefix "Database_Table_Disk_Usage" -Context "Database Performance - disk usage per table" -CommandTimeout 300
}

function Show-DatabaseErrorLogs {
    Clear-Host
    Show-SectionTitle "Database Error Logs"
    Write-Host "Reads the current SQL Server error log. This diagnostic is read-only." -ForegroundColor Cyan
    Write-Host "Type q to return to Database Performance." -ForegroundColor DarkGray

    try {
        Write-StreamingLog -Percent 20 -Step "Read log" -Description "Reading the current SQL Server error log."
        $results = @(Invoke-DatabaseSearchQuery -Query 'EXEC xp_readerrorlog 0, 1;' -CommandTimeout 120)
        Write-StreamingLog -Percent 100 -Step "Complete" -Description "SQL Server error log loaded."
        Show-DatabasePerformanceOutput -Data $results -FileNamePrefix "Sql_Server_Error_Log" -Title "Database Error Logs"
    }
    catch {
        $initialError = $_
        [void](Write-ToolErrorLog -Context "Database Performance - database error log initial read" -ErrorRecord $initialError)
        $settings = Get-DatabaseConnectionSettings
        $sqlUser = [string]$settings.User
        $quotedSqlUser = Get-QuotedSqlColumnName -ColumnName $sqlUser

        Write-Host "The current SQL user '$sqlUser' could not read the SQL Server error log." -ForegroundColor Yellow
        Write-Host "The script can try to grant EXECUTE on sys.xp_readerrorlog in master to this user." -ForegroundColor Yellow
        $confirm = Read-Host "Type GRANT to apply this permission, or q to go back"
        if (Test-IsBack $confirm) { return }
        if ($confirm -cne 'GRANT') {
            Write-Host "Permission change cancelled. No SQL permissions were changed." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        try {
            Write-StreamingLog -Percent 50 -Step "Permission" -Description "Granting error-log execution permission to $sqlUser."
            $grantQuery = @"
use [master];
grant execute on object::sys.xp_readerrorlog to $quotedSqlUser;
"@
            [void](Invoke-DatabaseSearchQuery -Query $grantQuery -CommandTimeout 60)
            Write-StreamingLog -Percent 75 -Step "Retry" -Description "Retrying the SQL Server error-log read."
            $results = @(Invoke-DatabaseSearchQuery -Query 'EXEC xp_readerrorlog 0, 1;' -CommandTimeout 120)
            Write-StreamingLog -Percent 100 -Step "Complete" -Description "SQL Server error log loaded."
            Show-DatabasePerformanceOutput -Data $results -FileNamePrefix "Sql_Server_Error_Log" -Title "Database Error Logs"
        }
        catch {
            Show-LoggedError -Prefix "The database administrator has restricted '$sqlUser' from running the SQL Server error-log command" -Context "Database Performance - database error log permission" -ErrorRecord $_
            Pause-Screen
        }
    }
}

function Show-PendingSqlQueries {
    while ($true) {
        Clear-Host
        Show-SectionTitle "Pending SQL Queries"
        Write-Host "Shows active SQL requests and their start time. SQL command text is shortened to 50 characters." -ForegroundColor Cyan
        Write-Host "Type q to return to Database Performance." -ForegroundColor DarkGray

        try {
            Write-StreamingLog -Percent 20 -Step "Collect" -Description "Checking active SQL Server requests."
            $query = @"
select
    r.session_id as Session_ID,
    r.status as Status,
    r.command as Command,
    r.start_time as Start_Time,
    datediff(second, r.start_time, getdate()) as Running_Seconds,
    s.host_name as Host_Name,
    s.program_name as Program_Name,
    left(t.text, 50) as SQL_Command_Preview
from sys.dm_exec_requests r
inner join sys.dm_exec_sessions s on r.session_id = s.session_id
cross apply sys.dm_exec_sql_text(r.sql_handle) t
where r.session_id <> @@spid
order by r.start_time;
"@
            $results = @(Invoke-DatabaseSearchQuery -Query $query -CommandTimeout 120)
            Write-StreamingLog -Percent 100 -Step "Complete" -Description "Active request check completed."
            if ($results.Count -eq 0) {
                Write-Host "No pending SQL queries are currently running." -ForegroundColor Green
                Pause-Screen
                return
            }
            Show-ConsoleResults -Data $results
        }
        catch {
            Show-LoggedError -Prefix "The pending-query check did not complete" -Context "Database Performance - pending SQL queries" -ErrorRecord $_
            Pause-Screen
            return
        }

        while ($true) {
            $choice = Read-Host "Enter a Session_ID for full SQL text, R to rerun, or q to go back"
            if (Test-IsBack $choice) { return }
            if ($choice -ieq 'r') { break }

            $sessionId = 0
            if (-not [int]::TryParse($choice, [ref]$sessionId) -or $sessionId -le 0) {
                Write-Host "Enter a valid Session_ID, R, or q." -ForegroundColor Yellow
                continue
            }

            try {
                Write-StreamingLog -Percent 60 -Step "Details" -Description "Loading the full SQL command for session $sessionId."
                $detailsQuery = @"
select
    r.session_id as Session_ID,
    r.status as Status,
    r.command as Command,
    r.start_time as Start_Time,
    datediff(second, r.start_time, getdate()) as Running_Seconds,
    s.host_name as Host_Name,
    s.program_name as Program_Name,
    t.text as SQL_Command
from sys.dm_exec_requests r
inner join sys.dm_exec_sessions s on r.session_id = s.session_id
cross apply sys.dm_exec_sql_text(r.sql_handle) t
where r.session_id = $sessionId;
"@
                $details = @(Invoke-DatabaseSearchQuery -Query $detailsQuery -CommandTimeout 120)
                if ($details.Count -eq 0) {
                    Write-Host "Session $sessionId is no longer running." -ForegroundColor Yellow
                    continue
                }

                Show-DatabasePerformanceOutput -Data $details -FileNamePrefix "Pending_Sql_Query_$sessionId" -Title "Full SQL Command for Session $sessionId"
            }
            catch {
                Show-LoggedError -Prefix "The full SQL command could not be loaded" -Context "Database Performance - pending SQL query details" -ErrorRecord $_
                Pause-Screen
            }
        }
    }
}

function Show-HeavyQueriesInTimeWindow {
    Clear-Host
    Show-SectionTitle "Identify Heavy Queries"
    Write-Host "Shows the heaviest cached queries executed within a selected recent time window." -ForegroundColor Cyan
    Write-Host "Type q at any prompt to return to Database Performance." -ForegroundColor DarkGray
    $topCount = Read-DatabasePerformanceTopCount -Prompt "Number of queries to show" -DefaultValue 20
    if ($null -eq $topCount) { return }
    $timeWindow = Read-DatabasePerformanceTimeWindow
    if ($null -eq $timeWindow) { return }

    $query = @"
select top ($topCount)
    qs.execution_count as [Execution Count],
    cast(qs.total_elapsed_time / 1000000.0 as decimal(18, 2)) as TotalDuration_s,
    cast(qs.max_elapsed_time / 1000000.0 as decimal(18, 4)) as MaxDuration_s,
    cast((qs.total_elapsed_time / qs.execution_count) / 1000000.0 as decimal(18, 4)) as AvgDuration_s,
    qs.last_execution_time as LastRunTime,
    left(st.text, 50) as StatementText,
    st.text as FullStatementText
from sys.dm_exec_query_stats as qs
cross apply sys.dm_exec_sql_text(qs.sql_handle) as st
where qs.last_execution_time >= dateadd($($timeWindow.DatePart), -$($timeWindow.Amount), getdate())
order by TotalDuration_s desc;
"@
    Invoke-DatabasePerformanceSqlReport -Title "Heavy Queries in the Last $($timeWindow.Display)" -Description "Showing the $topCount heaviest cached query plan(s) run in the last $($timeWindow.Display)." -Query $query -Context "Database Performance - heavy queries in recent time window" -CommandTimeout 300
}

function Show-CacheLifetimeHeavyQueries {
    Clear-Host
    Show-SectionTitle "Cache Lifetime Heaviest Queries"
    Write-Host "Shows cumulative execution duration for query plans still in SQL Server cache that ran within the last minute." -ForegroundColor Cyan
    Write-Host "The duration and execution counts are retained for the lifetime of each cached plan." -ForegroundColor Gray
    Write-Host "Type q to return to Database Performance." -ForegroundColor DarkGray
    $topCount = Read-DatabasePerformanceTopCount -Prompt "Number of queries to show" -DefaultValue 20
    if ($null -eq $topCount) { return }

    $query = @"
select top ($topCount)
    qs.execution_count as [Total Lifetime Executions],
    cast(qs.total_elapsed_time / 1000000.0 as decimal(18, 2)) as TotalLifetimeDuration_s,
    cast(qs.max_elapsed_time / 1000000.0 as decimal(18, 4)) as MaxDuration_s,
    cast((qs.total_elapsed_time / qs.execution_count) / 1000000.0 as decimal(18, 4)) as AvgDuration_s,
    qs.last_execution_time as LastRunTime,
    left(st.text, 50) as StatementText,
    st.text as FullStatementText
from sys.dm_exec_query_stats as qs
cross apply sys.dm_exec_sql_text(qs.sql_handle) as st
where qs.last_execution_time >= dateadd(minute, -1, getdate())
order by TotalLifetimeDuration_s desc;
"@
    Invoke-DatabasePerformanceSqlReport -Title "Cache Lifetime Heaviest Queries" -Description "Showing the $topCount heaviest cached query plan(s) that ran in the last minute." -Query $query -Context "Database Performance - cache lifetime heaviest queries" -CommandTimeout 300
}

function Show-TopResourceConsumingQueries {
    $query = @"
select top 10
    cast(((qs.total_elapsed_time / 1000000.0) / nullif(qs.execution_count, 0)) as decimal(18, 4)) as AvgDuration_s,
    qs.total_logical_reads / nullif(qs.execution_count, 0) as AvgLogicalReads,
    qs.execution_count,
    qs.max_elapsed_time / 1000000.0 as MaxDuration_s,
    qs.last_execution_time,
    left(StatementDetails.FullStatementText, 50) as StatementText,
    StatementDetails.FullStatementText
from sys.dm_exec_query_stats qs
cross apply sys.dm_exec_sql_text(qs.sql_handle) st
cross apply (
    select substring(
        st.text,
        (qs.statement_start_offset / 2) + 1,
        ((case qs.statement_end_offset when -1 then datalength(st.text) else qs.statement_end_offset end - qs.statement_start_offset) / 2) + 1
    ) as FullStatementText
) as StatementDetails
order by AvgDuration_s desc;
"@
    Invoke-DatabasePerformanceSqlReport -Title "Top Resource-Consuming Cached Queries" -Description "Shows the top 10 cached statements by average duration, with average logical reads." -Query $query -Context "Database Performance - top resource-consuming cached queries" -CommandTimeout 300
}

function Show-LastFourHoursSqlCpuUsage {
    $query = @"
declare @ts_now bigint = (select cpu_ticks / (cpu_ticks / ms_ticks) from sys.dm_os_sys_info);

with CpuHistory as (
    select
        dateadd(ms, -1 * (@ts_now - [timestamp]), getdate()) as Event_Time,
        SQLProcessUtilization as SQL_Server_CPU_Percent,
        SystemIdle as System_Idle_Percent,
        100 - SystemIdle - SQLProcessUtilization as Other_Process_CPU_Percent
    from (
        select
            record.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int') as SystemIdle,
            record.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') as SQLProcessUtilization,
            [timestamp]
        from (
            select [timestamp], convert(xml, record) as record
            from sys.dm_os_ring_buffers
            where ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
              and record like N'%<SystemHealth>%'
        ) as x
    ) as y
)
select top (256)
    Event_Time,
    SQL_Server_CPU_Percent,
    System_Idle_Percent,
    Other_Process_CPU_Percent
from CpuHistory
where Event_Time >= dateadd(hour, -4, getdate())
order by Event_Time desc;
"@
    $notes = @(
        'If Other_Process_CPU is high: look for antivirus scans, backups, or Windows updates.',
        'If SQL_Server_CPU is high: check Query Store for high-duration queries.'
    )
    Invoke-DatabasePerformanceReport -Title "Last 4 Hours SQL Server CPU Usage" -Description "Shows SQL Server, system idle, and other process CPU samples from the SQL Server ring buffer." -Query $query -FileNamePrefix "Sql_Server_Cpu_Usage" -Context "Database Performance - last four hours SQL Server CPU usage" -CommandTimeout 300 -PostDisplayNotes $notes
}

function Show-DatabasePerformanceMenu {
    while ($true) {
        Clear-Host
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                         DATABASE PERFORMANCE" -ForegroundColor Cyan
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "Connected to: $($Global:SelectedInstance) / $($Global:SelectedDb)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "1) Disk usage per table"
        Write-Host "2) Database error logs"
        Write-Host "3) Pending SQL queries"
        Write-Host "4) Identify heavy queries"
        Write-Host "5) Cache lifetime heaviest queries"
        Write-Host "6) Top resource-consuming queries (historical/cached)"
        Write-Host "7) Last 4 hours SQL Server CPU usage"
        Write-Host "q) Back to Database Tools"
        Write-Host "------------------------------------------------------------------------"
        $choice = Read-Host "Choose an option"

        if (Test-IsBack $choice) { return }
        switch ($choice) {
            '1' { Show-DatabaseTableDiskUsage }
            '2' { Show-DatabaseErrorLogs }
            '3' { Show-PendingSqlQueries }
            '4' { Show-HeavyQueriesInTimeWindow }
            '5' { Show-CacheLifetimeHeavyQueries }
            '6' { Show-TopResourceConsumingQueries }
            '7' { Show-LastFourHoursSqlCpuUsage }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-DatabaseMasterSuite {
    Connect-Database
    if ([string]::IsNullOrWhiteSpace($Global:SelectedDb)) { return }

    while ($true) {
        Clear-Host
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                           DATABASE TOOLS" -ForegroundColor Cyan
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "Connected to: $($Global:SelectedInstance) / $($Global:SelectedDb)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "1) Import/Export operations"
        Write-Host "2) Danone Features"
        Write-Host "3) Check or clean translation data"
        Write-Host "4) Copy activities between machines"
        Write-Host "5) Enable Line Detailed View"
        Write-Host "6) Rollback script changes"
        Write-Host "8) Database Performance"
        Write-Host "9) Database Search Tools"
        Write-Host "10) Change SQL Server connection"
        Write-Host "q) Back to main menu"
        Write-Host "------------------------------------------------------------------------"
        $mainChoice = Read-Host "Choose an option"

        if (Test-IsBack $mainChoice) { return }
        switch ($mainChoice) {
            '1' { Invoke-LoggedToolAction -Context "Database Tools - Import/Export operations" -Action { Show-DatabaseImportExportOperationsMenu } }
            '2' { Invoke-LoggedToolAction -Context "Database Tools - Danone Features" -Action { Show-DanoneFeaturesMenu } }
            '3' {
                Invoke-DatabaseToolWithTranslationSchema -Context "Database Tools - check or clean translation data" -Action { Show-IntegrityMenu }
            }
            '4' { Invoke-LoggedToolAction -Context "Database Tools - copy activities between machines" -Action { Invoke-CopyActivitiesBetweenMachines } }
            '5' { Invoke-LoggedToolAction -Context "Database Tools - Enable Line Detailed View" -Action { Enable-LineDetailedView } }
            '6' { Invoke-LoggedToolAction -Context "Database Tools - rollback script changes" -Action { Show-RollbackScriptChangesMenu } }
            '8' { Invoke-LoggedToolAction -Context "Database Tools - Database Performance" -Action { Show-DatabasePerformanceMenu } }
            '9' { Invoke-LoggedToolAction -Context "Database Tools - Database Search Tools" -Action { Show-DatabaseSearchToolsMenu } }
            '10' {
                Invoke-LoggedToolAction -Context "Database Tools - change SQL Server connection" -Action {
                    Clear-DatabaseConnection
                    Connect-Database
                }
                if ([string]::IsNullOrWhiteSpace($Global:SelectedDb)) { return }
            }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ------------------------------------------------------------------------------
# Local server and file tools
# ------------------------------------------------------------------------------
function Get-DataCollectorLogFolderCandidates {
    $folders = New-Object System.Collections.Generic.List[string]
    $addFolder = {
        param([AllowNull()][string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
        $resolved = (Get-Item -LiteralPath $Path -ErrorAction Stop).FullName
        if (@($folders | Where-Object { $_ -ieq $resolved }).Count -eq 0) {
            [void]$folders.Add($resolved)
        }
    }

    # The Configuration folder is detected from the existing D4A installation logic.
    $configurationFolder = Get-DefaultD4AConfigurationFolder
    if (-not [string]::IsNullOrWhiteSpace($configurationFolder)) {
        & $addFolder (Join-Path (Split-Path -Parent $configurationFolder) 'Data Collector\Logs')
    }

    try {
        $dataCollectorServices = @(Invoke-OperationWithTimeout -OperationName 'reading Decide4Action Data Collector service paths' -TimeoutSeconds $Script:ServerCheckCimTimeoutSeconds -ScriptBlock {
                Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
                    Where-Object { $_.Name -match '(?i)data\s*collector|datacollector' -or $_.DisplayName -match '(?i)data\s*collector|datacollector' } |
                    Select-Object Name, DisplayName, PathName
            })
        foreach ($service in $dataCollectorServices) {
            $pathName = [Environment]::ExpandEnvironmentVariables([string]$service.PathName)
            if ([string]::IsNullOrWhiteSpace($pathName)) { continue }
            $executablePath = if ($pathName -match '^\s*"(?<Path>[^"]+)"') { $matches.Path } else { ($pathName -split '\s+')[0] }
            if ([string]::IsNullOrWhiteSpace($executablePath)) { continue }
            & $addFolder (Join-Path (Split-Path -Parent $executablePath) 'Logs')
        }
    }
    catch {
        # The user can still enter the folder manually when service discovery is unavailable.
    }

    return $folders.ToArray()
}

function Select-DataCollectorLogFolder {
    $folders = @(Get-DataCollectorLogFolderCandidates)
    while ($true) {
        if ($folders.Count -eq 1) {
            Write-Host "Detected Data Collector log folder: $($folders[0])" -ForegroundColor Cyan
            $choice = Read-Host 'Press Enter to use it, enter another existing log folder, or type q to go back'
            if (Test-IsBack $choice) { return $null }
            if ([string]::IsNullOrWhiteSpace($choice)) { return $folders[0] }
        }
        elseif ($folders.Count -gt 1) {
            Write-Host 'Multiple Data Collector log folders were found:' -ForegroundColor Cyan
            for ($index = 0; $index -lt $folders.Count; $index++) {
                Write-Host "[$($index + 1)] $($folders[$index])"
            }
            $choice = Read-Host 'Select a number, enter another existing log folder, or type q to go back'
            if (Test-IsBack $choice) { return $null }
            $number = 0
            if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $folders.Count) {
                return $folders[$number - 1]
            }
        }
        else {
            Write-Host 'No Data Collector log folder was detected automatically.' -ForegroundColor Yellow
            $choice = Read-Host 'Enter the existing Data Collector Logs folder path (q to go back)'
            if (Test-IsBack $choice) { return $null }
        }

        $choice = Normalize-UserPath $choice
        if (Test-Path -LiteralPath $choice -PathType Container) {
            return (Get-Item -LiteralPath $choice -ErrorAction Stop).FullName
        }
        Write-Host 'That log folder does not exist. Enter a valid folder path or type q to go back.' -ForegroundColor Yellow
    }
}

function Select-DataCollectorLogFile {
    param([Parameter(Mandatory = $true)][string]$LogFolder)

    $logFiles = @(Get-ChildItem -LiteralPath $LogFolder -File -ErrorAction Stop |
            Where-Object { $_.Name -match '^Log-\d{8}(\.txt)?$' } |
            Sort-Object LastWriteTime -Descending)
    if ($logFiles.Count -eq 0) {
        throw "No Data Collector files named Log-YYYYMMDD.txt were found in $LogFolder."
    }

    $todayName = 'Log-{0}.txt' -f (Get-Date -Format 'yyyyMMdd')
    $todayFile = @($logFiles | Where-Object { $_.Name -ieq $todayName } | Select-Object -First 1)
    $defaultFile = if ($todayFile.Count -gt 0) { $todayFile[0] } else { $logFiles[0] }

    while ($true) {
        Write-Host ''
        Write-Host 'Five most recent Data Collector log files:' -ForegroundColor Cyan
        $visibleFiles = @($logFiles | Select-Object -First 5)
        for ($index = 0; $index -lt $visibleFiles.Count; $index++) {
            Write-Host "[$($index + 1)] $($visibleFiles[$index].Name)  ($($visibleFiles[$index].LastWriteTime))"
        }
        Write-Host "Default log file: $($defaultFile.Name)" -ForegroundColor Gray
        $choice = Read-Host 'Press Enter for the default, select a number, enter YYYYMMDD, or type q to go back'
        if (Test-IsBack $choice) { return $null }
        if ([string]::IsNullOrWhiteSpace($choice)) { return $defaultFile.FullName }

        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $visibleFiles.Count) {
            return $visibleFiles[$number - 1].FullName
        }
        if ($choice -match '^\d{8}$') {
            $datedFile = @($logFiles | Where-Object { $_.Name -match ("^Log-{0}(\.txt)?$" -f [regex]::Escape($choice)) } | Select-Object -First 1)
            if ($datedFile.Count -gt 0) { return $datedFile[0].FullName }
            Write-Host "No Data Collector log file exists for $choice." -ForegroundColor Yellow
            continue
        }
        Write-Host 'Enter a displayed number, a date as YYYYMMDD, or q.' -ForegroundColor Yellow
    }
}

function Read-DataCollectorLogTime {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][TimeSpan]$DefaultValue
    )

    while ($true) {
        $inputValue = Read-Host "$Label (HH:mm or HH:mm:ss; Enter = $($DefaultValue.ToString('hh\:mm\:ss')); q to go back)"
        if (Test-IsBack $inputValue) { return $null }
        if ([string]::IsNullOrWhiteSpace($inputValue)) { return $DefaultValue }
        $parsed = [TimeSpan]::Zero
        [string[]]$formats = @('hh\:mm', 'hh\:mm\:ss')
        if ([TimeSpan]::TryParseExact($inputValue.Trim(), $formats, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) {
            return $parsed
        }
        Write-Host 'Enter a 24-hour time such as 01:45 or 01:45:30.' -ForegroundColor Yellow
    }
}

function Read-DataCollectorLogExclusions {
    $exclusions = New-Object System.Collections.Generic.List[string]
    for ($index = 1; $index -le 3; $index++) {
        $value = Read-Host "Text to exclude $index of 3 (Enter for no more exclusions; q to go back)"
        if (Test-IsBack $value) { return $null }
        if ([string]::IsNullOrWhiteSpace($value)) { break }
        [void]$exclusions.Add($value.Trim())
    }
    return $exclusions.ToArray()
}

function Invoke-DataCollectorEventTrace {
    Clear-Host
    Show-SectionTitle 'Trace Events in Data Collector'
    Write-Host 'Searches one Data Collector log by text and optional time window. Type q at any prompt to go back.' -ForegroundColor Gray

    $logFolder = Select-DataCollectorLogFolder
    if ($null -eq $logFolder) { return }
    $logFile = Select-DataCollectorLogFile -LogFolder $logFolder
    if ($null -eq $logFile) { return }

    while ($true) {
        $searchText = Read-Host 'Text to find'
        if (Test-IsBack $searchText) { return }
        if (-not [string]::IsNullOrWhiteSpace($searchText)) { break }
        Write-Host 'Enter the text to search for.' -ForegroundColor Yellow
    }
    $startTime = Read-DataCollectorLogTime -Label 'Start time' -DefaultValue ([TimeSpan]::Zero)
    if ($null -eq $startTime) { return }
    $endTime = Read-DataCollectorLogTime -Label 'End time' -DefaultValue ([TimeSpan]::Parse('23:59:59'))
    if ($null -eq $endTime) { return }
    if ($startTime -gt $endTime) {
        Write-Host 'The start time cannot be later than the end time.' -ForegroundColor Yellow
        Pause-Screen
        return
    }
    $exclusions = Read-DataCollectorLogExclusions
    if ($null -eq $exclusions) { return }

    Write-Host ''
    Write-Host "Log file: $logFile" -ForegroundColor Cyan
    Write-Host "Search text: $searchText | Time window: $($startTime.ToString('hh\:mm\:ss')) to $($endTime.ToString('hh\:mm\:ss'))" -ForegroundColor Cyan
    if ($exclusions.Count -gt 0) { Write-Host "Excluded text: $($exclusions -join '; ')" -ForegroundColor Gray }
    Write-StreamingLog -Percent 10 -Step 'Read log' -Description 'Searching the selected Data Collector log file.'

    $reader = $null
    $lineNumber = 0
    $matchCount = 0
    $displayLimit = 1000
    $nextProgressPercent = 25
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $fileInfo = Get-Item -LiteralPath $logFile -ErrorAction Stop
        # Data Collector keeps the current log open for writing. Allow concurrent reads.
        $stream = New-Object IO.FileStream($fileInfo.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = New-Object IO.StreamReader($stream)
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            if ($stopwatch.Elapsed.TotalSeconds -ge $Script:DeepDirectoryScanTimeoutSeconds) {
                throw "Timed out after $Script:DeepDirectoryScanTimeoutSeconds seconds while searching $($fileInfo.Name). Narrow the time window or search for more specific text."
            }
            $progress = if ($fileInfo.Length -gt 0) { [int](($reader.BaseStream.Position / [double]$fileInfo.Length) * 85) + 10 } else { 95 }
            if ($progress -ge $nextProgressPercent) {
                Write-StreamingLog -Percent ([Math]::Min($progress, 95)) -Step 'Read log' -Description "Searching line $lineNumber..."
                $nextProgressPercent += 25
            }
            if ($line.IndexOf($searchText, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            if (@($exclusions | Where-Object { $line.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0) { continue }
            if ($line -notmatch '^\s*\d{1,2}/\d{1,2}/\d{4}\s+(?<EventTime>\d{2}:\d{2}:\d{2})\b') { continue }
            $eventTime = [TimeSpan]::Zero
            if (-not [TimeSpan]::TryParseExact($matches.EventTime, 'hh\:mm\:ss', [Globalization.CultureInfo]::InvariantCulture, [ref]$eventTime)) { continue }
            if ($eventTime -lt $startTime -or $eventTime -gt $endTime) { continue }

            $matchCount++
            if ($matchCount -le $displayLimit) {
                Write-Host "${lineNumber}: $($line.Trim())" -ForegroundColor Yellow
            }
        }
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $stopwatch.Stop()
    }

    Write-StreamingLog -Percent 100 -Step 'Complete' -Description "Search completed. Matching events: $matchCount."
    if ($matchCount -eq 0) {
        Write-Host 'No matching events were found.' -ForegroundColor Magenta
    }
    elseif ($matchCount -gt $displayLimit) {
        Write-Host "Displayed the first $displayLimit of $matchCount matching events. Use a narrower time window or more specific text to reduce the results." -ForegroundColor Yellow
    }
    else {
        Write-Host "Found $matchCount matching event(s)." -ForegroundColor Green
    }
    Pause-Screen
}

function Invoke-TextSearch {
    do {
        Clear-Host
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                         SEARCH FOR TEXT IN FILES" -ForegroundColor Cyan
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "Type 'q' at any prompt to return to the menu." -ForegroundColor DarkGray
        Write-Host ""

        $searchPath = Read-Host "Folder to search"
        if (Test-IsBack $searchPath) { break }
        $searchPath = Normalize-UserPath $searchPath
        if ([string]::IsNullOrWhiteSpace($searchPath)) {
            Write-Host "Please enter a folder to search." -ForegroundColor Yellow
            $action = Read-Host "Type S to try again, or Q to go back"
            if (Test-IsBack $action -or $action -ieq 'b') { break }
            continue
        }

        if (-not (Test-Path $searchPath)) {
            Write-Host "That folder could not be found." -ForegroundColor Red
            $action = Read-Host "Type S to try again, or Q to go back"
            if (Test-IsBack $action -or $action -ieq 'b') { break }
            continue
        }

        $searchText = Read-Host "Exact text to find"
        if (Test-IsBack $searchText) { break }
        if ([string]::IsNullOrWhiteSpace($searchText)) {
            Write-Host "Please enter the text you want to find." -ForegroundColor Yellow
            $action = Read-Host "Type S to try again, or Q to go back"
            if (Test-IsBack $action -or $action -ieq 'b') { break }
            continue
        }

        Write-Host ""
        Write-Host "How should matches be shown?"
        Write-Host "1) Show matching lines"
        Write-Host "2) Show file paths and line numbers"
        Write-Host "3) Show file path, line number, and matching line"
        $option = Read-Host "Choose an option"
        if (Test-IsBack $option) { break }

        Write-Host ""
        Write-Host "Searching files..." -ForegroundColor Gray
        $results = @(Invoke-OperationWithTimeout -OperationName "search files under $searchPath" -TimeoutSeconds $Script:DeepDirectoryScanTimeoutSeconds -ScriptBlock {
            param($SearchArgs)
            Get-ChildItem -Path $SearchArgs.Path -Recurse -File -ErrorAction SilentlyContinue |
                Select-String -Pattern $SearchArgs.Pattern -SimpleMatch -ErrorAction SilentlyContinue
        } -Argument @{
            Path    = $searchPath
            Pattern = $searchText
        })

        if ($results.Count -eq 0) {
            Write-Host "No matches were found." -ForegroundColor Magenta
        }
        else {
            foreach ($match in $results) {
                switch ($option) {
                    '1' {
                        Write-Host "$($match.LineNumber): " -NoNewline -ForegroundColor Gray
                        Write-Host "$($match.Line.Trim())" -ForegroundColor Yellow
                    }
                    '2' {
                        Write-Host "$($match.Path) " -NoNewline -ForegroundColor Cyan
                        Write-Host "(line $($match.LineNumber))" -ForegroundColor Gray
                    }
                    '3' {
                        Write-Host "$($match.Path):$($match.LineNumber):" -NoNewline -ForegroundColor Cyan
                        Write-Host " $($match.Line.Trim())" -ForegroundColor Yellow
                    }
                    default {
                        Write-Host "$($match.Path):$($match.LineNumber): $($match.Line.Trim())" -ForegroundColor Yellow
                    }
                }
            }
        }

        Write-Host ""
        Write-Host "----------------------------------------"
        $action = Read-Host "Type S to search again, or Q to return to the menu"
        if (Test-IsBack $action) { break }
    } while ($action -ieq 's')
}

function Invoke-ServerAudit {
    Clear-Host
    Write-Host "========================================================================" -ForegroundColor DarkGray
    Write-Host "                          SYSTEM HEALTH CHECK" -ForegroundColor Cyan
    Write-Host "========================================================================" -ForegroundColor DarkGray
    Write-Host ""

    if (-not $Script:IsAdmin) {
        Write-Host "Note: this script is not running as Administrator. Some system counters may not be available." -ForegroundColor Yellow
        Write-Host ""
    }

    Show-SectionTitle "Progress"

    try {
        Write-StreamingLog -Percent 10 -Step "System info" -Description "Reading operating system and processor details..."
        $OS = @(Invoke-OperationWithTimeout -OperationName "read operating system details" -TimeoutSeconds $Script:ServerCheckCimTimeoutSeconds -ScriptBlock {
            Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        } | Select-Object -First 1)[0]
        $CPUHardware = @(Invoke-OperationWithTimeout -OperationName "read processor details" -TimeoutSeconds $Script:ServerCheckCimTimeoutSeconds -ScriptBlock {
            Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        } | Select-Object -First 1)[0]
        $TotalRAM_GB = [Math]::Round($OS.TotalVisibleMemorySize / 1MB, 2)
        $CPUName = $CPUHardware.Name.Trim()
        Start-Sleep -Milliseconds 300

        Write-StreamingLog -Percent 35 -Step "Disk hardware" -Description "Checking physical disks..."
        if (Get-Command Get-PhysicalDisk -ErrorAction SilentlyContinue) {
            $DiskTech = @(Invoke-OperationWithTimeout -OperationName "read physical disk information" -TimeoutSeconds $Script:ServerCheckCimTimeoutSeconds -ScriptBlock {
                Get-PhysicalDisk -ErrorAction SilentlyContinue
            })
        }
        else {
            $DiskTech = @()
        }
        Start-Sleep -Milliseconds 300

        Write-StreamingLog -Percent 55 -Step "Drive space" -Description "Checking local drive space..."
        $Disks = @(Invoke-OperationWithTimeout -OperationName "read local logical disk space" -TimeoutSeconds $Script:ServerCheckCimTimeoutSeconds -ScriptBlock {
            Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue
        })
        Start-Sleep -Milliseconds 300

        Write-StreamingLog -Percent 75 -Step "Performance" -Description "Sampling CPU, memory, and disk activity..."
        $Counters = @(
            "\Processor(_Total)\% Processor Time",
            "\Memory\Available MBytes",
            "\PhysicalDisk(_Total)\Disk Read Bytes/sec",
            "\PhysicalDisk(_Total)\Disk Write Bytes/sec"
        )

        $SampleInterval = 3
        $SamplesCount = 4
        $Samples = @()

        if (-not (Get-Command Get-Counter -ErrorAction SilentlyContinue)) {
            Write-Host "Performance counters are not available in this PowerShell session." -ForegroundColor Yellow
            $Samples = @()
        }
        else {
            for ($i = 1; $i -le $SamplesCount; $i++) {
                $SubPercent = 75 + [int](($i / $SamplesCount) * 20)
                Write-StreamingLog -Percent $SubPercent -Step "Performance sample" -Description "Taking sample $i of $SamplesCount..."
                try {
                    $Samples += @(Invoke-OperationWithTimeout -OperationName "collect performance counter sample $i" -TimeoutSeconds 20 -ScriptBlock {
                        param($CounterArgs)
                        Get-Counter -Counter $CounterArgs.Counters -SampleInterval $CounterArgs.SampleInterval -MaxSamples 1 -ErrorAction Stop
                    } -Argument @{
                        Counters       = $Counters
                        SampleInterval = $SampleInterval
                    })
                }
                catch {
                    $logPath = Write-ToolErrorLog -Context "Local server and file tools - system health performance counters" -ErrorRecord $_
                    Write-Host "Performance counters were not available: $($_.Exception.Message)" -ForegroundColor Yellow
                    Write-Host "Error log: $logPath" -ForegroundColor Yellow
                    $Samples = @()
                    break
                }
            }
        }

        Write-StreamingLog -Percent 100 -Step "Done" -Description "Preparing the report..."
        Start-Sleep -Milliseconds 300
    }
    catch {
        Show-LoggedError -Prefix "System information could not be loaded" -Context "Local server and file tools - system health report" -ErrorRecord $_
        Pause-Screen
        return
    }

    $AvgCPU = $null
    $AvgAvailRAM_MB = $null
    $AvgUsedRAM_GB = $null
    $PeakRead = $null
    $PeakWrite = $null

    if ($Samples.Count -gt 0 -and $Samples.CounterSamples.Count -gt 0) {
        $AvgCPU = [Math]::Round(($Samples.CounterSamples | Where-Object Path -like "*processor*" | Measure-Object -Property CookedValue -Average).Average, 2)
        $AvgAvailRAM_MB = ($Samples.CounterSamples | Where-Object Path -like "*available mbytes*" | Measure-Object -Property CookedValue -Average).Average
        $AvgUsedRAM_GB = [Math]::Round(($TotalRAM_GB - ($AvgAvailRAM_MB / 1024)), 2)
        $PeakRead = [Math]::Round(($Samples.CounterSamples | Where-Object Path -like "*disk read bytes*" | Measure-Object -Property CookedValue -Maximum).Maximum / 1MB, 2)
        $PeakWrite = [Math]::Round(($Samples.CounterSamples | Where-Object Path -like "*disk write bytes*" | Measure-Object -Property CookedValue -Maximum).Maximum / 1MB, 2)
    }

    $CpuText = if ($null -ne $AvgCPU) { "$AvgCPU%" } else { "Not available" }
    $MemoryText = if ($null -ne $AvgUsedRAM_GB -and $TotalRAM_GB -gt 0) { "$AvgUsedRAM_GB GB used ($([Math]::Round(($AvgUsedRAM_GB / $TotalRAM_GB) * 100, 2))%)" } else { "Not available" }
    $ReadText = if ($null -ne $PeakRead) { "$PeakRead MB/s" } else { "Not available" }
    $WriteText = if ($null -ne $PeakWrite) { "$PeakWrite MB/s" } else { "Not available" }

    Write-Host ""
    Write-Host "========================================================" -ForegroundColor DarkGray
    Write-Host "                      SYSTEM HEALTH REPORT" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor DarkGray
    Write-Host "Checked at: $(Get-Date)"
    Write-Host "--------------------------------------------------------"

    Write-Host "[Computer]" -ForegroundColor Cyan
    Write-Host "Operating system: $($OS.Caption)"
    Write-Host "Processor:        $CPUName"
    Write-Host "Average CPU use:  $CpuText"

    Write-Host ""
    Write-Host "[Memory]" -ForegroundColor Cyan
    Write-Host "Installed RAM:    $TotalRAM_GB GB"
    Write-Host "Memory in use:    $MemoryText"

    Write-Host ""
    Write-Host "[Disk hardware]" -ForegroundColor Cyan
    if ($DiskTech.Count -gt 0) {
        foreach ($Disk in $DiskTech) {
            $Type = if ($Disk.MediaType -eq "Unspecified" -or -not $Disk.MediaType) { "Unknown or virtual disk" } else { $Disk.MediaType }
            Write-Host "- $($Disk.FriendlyName) ($Type, bus: $($Disk.BusType))"
        }
    }
    else {
        Write-Host "Physical disk details are not available." -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "[Drive space]" -ForegroundColor Cyan
    if ($Disks.Count -gt 0) {
        foreach ($Drive in $Disks) {
            $FreeGB = [Math]::Round($Drive.FreeSpace / 1GB, 2)
            $SizeGB = [Math]::Round($Drive.Size / 1GB, 2)
            $UsedGB = [Math]::Round($SizeGB - $FreeGB, 2)
            $PercentUsed = if ($SizeGB -gt 0) { [Math]::Round(($UsedGB / $SizeGB) * 100, 1) } else { 0 }
            $volumeName = if ([string]::IsNullOrWhiteSpace($Drive.VolumeName)) { "No label" } else { $Drive.VolumeName }
            Write-Host "$($Drive.DeviceID) [$volumeName]: $PercentUsed% used ($UsedGB GB used / $SizeGB GB total)"
        }
    }
    else {
        Write-Host "No local drives were found." -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "[Disk activity during the sample]" -ForegroundColor Cyan
    Write-Host "Peak read speed:  $ReadText"
    Write-Host "Peak write speed: $WriteText"
    Write-Host "--------------------------------------------------------"

    Pause-Screen
}

function Parse-TimeScope {
    param([AllowNull()][string]$InputString)

    if ([string]::IsNullOrWhiteSpace($InputString)) { return $null }

    $text = $InputString.Trim().ToLowerInvariant()
    $match = [regex]::Match($text, '^\s*(\d+)\s*([a-z]*)')
    if (-not $match.Success) { return $null }

    $value = [int]$match.Groups[1].Value
    $unit = $match.Groups[2].Value

    switch -Regex ($unit) {
        '^m(in|ins|inute|inutes)?$' { return (Get-Date).AddMinutes(-$value) }
        '^h(r|rs|our|ours)?$'       { return (Get-Date).AddHours(-$value) }
        '^d(ay|ays)?$'              { return (Get-Date).AddDays(-$value) }
        default                     { return (Get-Date).AddHours(-$value) }
    }
}

function Invoke-RecentFilesTracker {
    $CachedPath = ""
    $CachedScope = ""

    while ($true) {
        Clear-Host
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                         RECENT FILE CHANGES" -ForegroundColor Cyan
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "Type 'q' at any prompt to return to the menu." -ForegroundColor DarkGray
        Write-Host ""

        if (-not [string]::IsNullOrWhiteSpace($CachedPath)) {
            $PathPrompt = Read-Host "Press Enter to reuse [$CachedPath], or enter a different folder"
            if (Test-IsBack $PathPrompt) { break }

            if ([string]::IsNullOrWhiteSpace($PathPrompt)) {
                $CurrentPath = $CachedPath
            }
            else {
                $CurrentPath = Normalize-UserPath $PathPrompt
            }
        }
        else {
            $CurrentPath = Read-Host "Folder to check"
            $CurrentPath = Normalize-UserPath $CurrentPath
        }

        if (Test-IsBack $CurrentPath) { break }
        if ([string]::IsNullOrWhiteSpace($CurrentPath)) {
            Write-Host "Please enter a folder to check." -ForegroundColor Yellow
            Pause-Screen "Press Enter to try again..."
            continue
        }
        if (-not (Test-Path $CurrentPath)) {
            Write-Host "That folder could not be found." -ForegroundColor Red
            Pause-Screen "Press Enter to try again..."
            continue
        }
        $CachedPath = $CurrentPath

        if (-not [string]::IsNullOrWhiteSpace($CachedScope)) {
            $ScopePrompt = Read-Host "Press Enter to reuse [$CachedScope], or enter a different time range"
            if (Test-IsBack $ScopePrompt) { break }

            if ([string]::IsNullOrWhiteSpace($ScopePrompt)) {
                $CurrentScope = $CachedScope
            }
            else {
                $CurrentScope = $ScopePrompt
            }
        }
        else {
            $CurrentScope = Read-Host "Time range to check (examples: 20 minutes, 1 hour, 3 hours, 2 days)"
        }

        if (Test-IsBack $CurrentScope) { break }
        $CutoffDate = Parse-TimeScope -InputString $CurrentScope

        if ($null -eq $CutoffDate) {
            Write-Host "I could not understand that time range, so I used the last 1 hour." -ForegroundColor Yellow
            $CutoffDate = (Get-Date).AddHours(-1)
            $CurrentScope = "1 hour"
        }
        $CachedScope = $CurrentScope

        Write-Host ""
        Write-Host "Scanning files changed since $CutoffDate..." -ForegroundColor Gray
        $AllTargetFiles = @(Invoke-OperationWithTimeout -OperationName "scan recent files under $CurrentPath" -TimeoutSeconds $Script:DeepDirectoryScanTimeoutSeconds -ScriptBlock {
            param($Path)
            Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue
        } -Argument $CurrentPath)

        $CreatedFiles = @($AllTargetFiles | Where-Object { $_.CreationTime -ge $CutoffDate } | Sort-Object CreationTime -Descending)
        $ModifiedFiles = @($AllTargetFiles | Where-Object { $_.LastWriteTime -ge $CutoffDate } | Sort-Object LastWriteTime -Descending)

        Write-Host ""
        Write-Host "=======================================================================" -ForegroundColor DarkGray
        Write-Host "                         RECENT FILE REPORT ($CurrentScope)" -ForegroundColor Green
        Write-Host "=======================================================================" -ForegroundColor DarkGray

        Write-Host ""
        Write-Host "[New files] ($($CreatedFiles.Count))" -ForegroundColor Cyan
        if ($CreatedFiles.Count -gt 0) {
            foreach ($file in $CreatedFiles) {
                Write-Host "[+] $($file.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')) " -NoNewline -ForegroundColor Green
                Write-Host "$($file.FullName)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "No files were created in this time range." -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host "[Changed files] ($($ModifiedFiles.Count))" -ForegroundColor Cyan
        if ($ModifiedFiles.Count -gt 0) {
            foreach ($file in $ModifiedFiles) {
                Write-Host "[*] $($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) " -NoNewline -ForegroundColor Magenta
                Write-Host "$($file.FullName)" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "No files were changed in this time range." -ForegroundColor Gray
        }

        Write-Host ""
        Write-Host "Scan complete." -ForegroundColor Gray
        $next = Read-Host "Type R to scan again, or Q to return to the menu"
        if ($next -ine 'r') { break }
    }
}

function Invoke-DiskSpaceAnalyzer {
    Clear-Host
    Show-SectionTitle 'Analyze Disk Usage (Visual Report)'
    Write-Host 'Select a local disk partition in the analyzer, then press Enter to search the whole drive or paste a folder path to focus the large-file search.' -ForegroundColor Cyan
    Write-Host 'The analyzer opens a visual report with folder sizes, large files, and export options when the scan is complete.' -ForegroundColor Cyan
    Write-Host 'For the fastest NTFS scan, run IT Tools as Administrator. Auto mode safely falls back when MFT access is unavailable.' -ForegroundColor Gray
    Write-Host ''

    $analyzerPath = Get-RequiredScriptFolderFilePath `
        -FileName 'D4A-DiskSpaceAnalyzer.ps1' `
        -DownloadUrl 'https://raw.githubusercontent.com/Khaled-barbar/IT_Tools_DB_Management_Server_Tools/main/D4A-DiskSpaceAnalyzer.ps1' `
        -FeatureName 'Analyze Disk Usage (Visual Report)'

    Write-Host "Disk usage analyzer: $analyzerPath" -ForegroundColor Gray
    Write-StreamingLog -Percent 10 -Step 'Launch analyzer' -Description 'Starting the interactive visual disk usage analyzer.'
    # SingleRun returns control to IT Tools so its standard error logging and menu flow remain in effect.
    & $analyzerPath -ScanMode Auto -Verbose -SingleRun
    Write-StreamingLog -Percent 100 -Step 'Complete' -Description 'Disk usage analyzer closed.'
    Pause-Screen
}

function Convert-ServiceStartNameToAclPrincipal {
    param([Parameter(Mandatory = $true)][string]$StartName)

    switch -Regex ($StartName) {
        '^(LocalSystem|NT AUTHORITY\\SYSTEM)$' {
            return 'NT AUTHORITY\SYSTEM'
        }
        '^(NetworkService|NT AUTHORITY\\NetworkService|NT AUTHORITY\\NETWORK SERVICE)$' {
            return 'NT AUTHORITY\NETWORK SERVICE'
        }
        '^(LocalService|NT AUTHORITY\\LocalService|NT AUTHORITY\\LOCAL SERVICE)$' {
            return 'NT AUTHORITY\LOCAL SERVICE'
        }
        default {
            return $StartName
        }
    }
}

function Get-SqlInstanceNameFromServiceName {
    param([Parameter(Mandatory = $true)][string]$ServiceName)

    if ($ServiceName -eq 'MSSQLSERVER' -or $ServiceName -eq 'SQLSERVERAGENT') {
        return 'MSSQLSERVER'
    }

    if ($ServiceName -match '^(?:MSSQL|SQLAgent)\$(.+)$') {
        return $Matches[1]
    }

    return $null
}

function Get-SqlComponentFromServiceName {
    param([Parameter(Mandatory = $true)][string]$ServiceName)

    if ($ServiceName -eq 'MSSQLSERVER' -or $ServiceName -like 'MSSQL$*') {
        return 'DatabaseEngine'
    }

    if ($ServiceName -eq 'SQLSERVERAGENT' -or $ServiceName -like 'SQLAgent$*') {
        return 'SqlAgent'
    }

    return 'Unknown'
}

function Get-SqlServiceAccountInfo {
    $sqlServices = @(Invoke-OperationWithTimeout -OperationName "detect SQL Server services" -TimeoutSeconds $Script:ServerCheckCimTimeoutSeconds -ScriptBlock {
        Get-CimInstance -ClassName Win32_Service |
            Where-Object {
                $_.Name -eq 'MSSQLSERVER' -or
                $_.Name -eq 'SQLSERVERAGENT' -or
                $_.Name -like 'MSSQL$*' -or
                $_.Name -like 'SQLAgent$*'
            }
    })

    if ($sqlServices.Count -eq 0) {
        throw "No SQL Server Database Engine or SQL Server Agent services were found on $env:COMPUTERNAME."
    }

    $detected = foreach ($service in $sqlServices) {
        $component = Get-SqlComponentFromServiceName -ServiceName $service.Name
        $instance = Get-SqlInstanceNameFromServiceName -ServiceName $service.Name
        $principal = Convert-ServiceStartNameToAclPrincipal -StartName $service.StartName

        [pscustomobject]@{
            ComputerName             = $env:COMPUTERNAME
            Instance                 = $instance
            Component                = $component
            ServiceName              = $service.Name
            DisplayName              = $service.DisplayName
            State                    = $service.State
            StartMode                = $service.StartMode
            ServiceAccount           = $service.StartName
            PermissionPrincipal      = $principal
            UseForBackupFolder       = ($component -eq 'DatabaseEngine')
        }
    }

    return @($detected | Sort-Object Instance, Component, ServiceName)
}

function Read-ExistingFolderPath {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    while ($true) {
        $folderPath = Read-Host $Prompt
        if (Test-IsBack $folderPath) { return $null }

        $folderPath = Normalize-UserPath $folderPath
        if ([string]::IsNullOrWhiteSpace($folderPath)) {
            Write-Host "Please enter a folder path, or type 'q' to go back." -ForegroundColor Yellow
            continue
        }

        if (Test-Path -LiteralPath $folderPath -PathType Container) {
            return (Resolve-Path -LiteralPath $folderPath).ProviderPath
        }

        Write-Host "That folder could not be found. Please enter a valid existing folder path." -ForegroundColor Red
    }
}

function Show-SqlAgentAccountNames {
    param([Parameter(Mandatory = $true)][string]$BackupPath)

    Clear-Host
    Show-SectionTitle "SQL Agent Service Account"
    Write-Host "Selected backup folder: $BackupPath" -ForegroundColor Gray
    Write-Host ""

    try {
        $agents = @(Get-SqlServiceAccountInfo |
            Where-Object { $_.Component -eq 'SqlAgent' } |
            Select-Object Instance, ServiceName, State, ServiceAccount, PermissionPrincipal)

        if ($agents.Count -eq 0) {
            Write-Host "No SQL Server Agent service was detected on this computer." -ForegroundColor Yellow
        }
        else {
            Show-ConsoleResults -Data $agents
        }
    }
    catch {
        Show-LoggedError -Prefix "Could not detect the SQL Agent account" -Context "SQL backup folder permissions - detect Agent account" -ErrorRecord $_
    }

    Pause-Screen
}

function Show-SqlServiceAccountDetails {
    param([Parameter(Mandatory = $true)][string]$BackupPath)

    Clear-Host
    Show-SectionTitle "SQL Server Service Account Details"
    Write-Host "Detection only. No permissions will be changed." -ForegroundColor Cyan
    Write-Host "Selected backup folder: $BackupPath" -ForegroundColor Gray
    Write-Host ""

    try {
        $detected = @(Get-SqlServiceAccountInfo)
        Show-ConsoleResults -Data $detected
    }
    catch {
        Show-LoggedError -Prefix "Could not detect SQL Server service accounts" -Context "SQL backup folder permissions - full detection" -ErrorRecord $_
    }

    Pause-Screen
}

function Grant-SqlBackupFolderModifyPermissions {
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [switch]$GrantAgentToo
    )

    Clear-Host
    $title = if ($GrantAgentToo) {
        "Grant Modify to Database Engine and SQL Agent"
    }
    else {
        "Grant Modify to SQL Backup Account"
    }
    Show-SectionTitle $title

    try {
        $detected = @(Get-SqlServiceAccountInfo)
        $permissionTargets = @($detected | Where-Object {
            $_.Component -eq 'DatabaseEngine' -or
            ($GrantAgentToo -and $_.Component -eq 'SqlAgent')
        })

        if ($permissionTargets.Count -eq 0) {
            throw "No SQL Server service account was found for the selected permission action."
        }

        Write-Host "Target folder: $BackupPath" -ForegroundColor Yellow
        Write-Host "The following account(s) will receive Modify permissions:" -ForegroundColor Cyan
        Show-ConsoleResults -Data ($permissionTargets | Select-Object Instance, Component, ServiceName, PermissionPrincipal)

        if (-not $Script:IsAdmin) {
            Write-Host "Warning: this script is not running as Administrator. Granting folder permissions may fail." -ForegroundColor Yellow
        }

        Write-Host ""
        $confirm = Read-Host "Type GRANT to apply Modify permissions to this folder"
        if ($confirm -cne 'GRANT') {
            Write-Host "Operation cancelled. No permissions were changed." -ForegroundColor Cyan
            Pause-Screen
            return
        }

        Write-Host ""
        Write-Host "Permission update results for: $BackupPath" -ForegroundColor Cyan
        Write-Host "------------------------------------------------------------------------"

        $failedCount = 0
        foreach ($target in $permissionTargets) {
            $grantArgument = "$($target.PermissionPrincipal):(OI)(CI)M"
            $icaclsOutput = @(& icacls.exe $BackupPath /grant $grantArgument 2>&1)
            $exitCode = $LASTEXITCODE
            $message = (($icaclsOutput | ForEach-Object { [string]$_ }) -join " ").Trim()

            if ($exitCode -eq 0) {
                Write-Host "Success: Modify permission granted to '$($target.PermissionPrincipal)' for '$BackupPath'." -ForegroundColor Green
                Write-Host "Account: $($target.Instance) / $($target.Component) / $($target.ServiceName)" -ForegroundColor Gray
            }
            else {
                $failedCount++
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $message = "icacls.exe exited with code $exitCode and did not return an error message."
                }

                Write-Host "Failed: Modify permission was not granted to '$($target.PermissionPrincipal)' for '$BackupPath'." -ForegroundColor Red
                Write-Host "Account: $($target.Instance) / $($target.Component) / $($target.ServiceName)" -ForegroundColor Gray
                Write-Host "Error: $message" -ForegroundColor Red
            }

            Write-Host ""
        }

        if ($failedCount -eq 0) {
            Write-Host "All requested Modify permissions were applied successfully." -ForegroundColor Green
        }
        else {
            Write-Host "$failedCount permission update(s) failed. Review the error line under each failed account above." -ForegroundColor Red
        }
    }
    catch {
        Show-LoggedError -Prefix "Could not update SQL backup folder permissions" -Context "SQL backup folder permissions - grant Modify" -ErrorRecord $_
    }

    Pause-Screen
}

function Show-SqlBackupFolderPermissionsMenu {
    Clear-Host
    Show-SectionTitle "SQL Backup Folder Permissions"
    Write-Host "This tool detects SQL Server service accounts and can grant Modify permissions on a backup folder." -ForegroundColor Cyan
    Write-Host "Type 'q' to return to the previous menu." -ForegroundColor DarkGray
    Write-Host ""

    $backupPath = Read-ExistingFolderPath -Prompt "Enter the SQL backup folder path"
    if ([string]::IsNullOrWhiteSpace($backupPath)) { return }

    while ($true) {
        Clear-Host
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                      SQL BACKUP FOLDER PERMISSIONS" -ForegroundColor Cyan
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "Selected folder: $backupPath" -ForegroundColor Gray
        Write-Host ""
        Write-Host "1) Show SQL Agent account name"
        Write-Host "2) Show all SQL Server service account details (detection only)"
        Write-Host "3) Grant Modify to SQL Database Engine account(s)"
        Write-Host "4) Grant Modify to Database Engine and SQL Agent account(s)"
        Write-Host "5) Select a different backup folder"
        Write-Host "q) Back to local server and file tools"
        Write-Host "------------------------------------------------------------------------"
        $choice = Read-Host "Choose an option"

        if (Test-IsBack $choice) { return }

        switch ($choice) {
            '1' { Invoke-LoggedToolAction -Context "SQL backup folder permissions - show SQL Agent account name" -Action { Show-SqlAgentAccountNames -BackupPath $backupPath } }
            '2' { Invoke-LoggedToolAction -Context "SQL backup folder permissions - show service account details" -Action { Show-SqlServiceAccountDetails -BackupPath $backupPath } }
            '3' { Invoke-LoggedToolAction -Context "SQL backup folder permissions - grant Modify to Database Engine" -Action { Grant-SqlBackupFolderModifyPermissions -BackupPath $backupPath } }
            '4' { Invoke-LoggedToolAction -Context "SQL backup folder permissions - grant Modify to Database Engine and SQL Agent" -Action { Grant-SqlBackupFolderModifyPermissions -BackupPath $backupPath -GrantAgentToo } }
            '5' {
                $newBackupPath = Read-ExistingFolderPath -Prompt "Enter the new SQL backup folder path"
                if (-not [string]::IsNullOrWhiteSpace($newBackupPath)) {
                    $backupPath = $newBackupPath
                }
            }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Test-RemoteTcpPort {
    Clear-Host
    Show-SectionTitle "Check If a Port Is Open"
    Write-Host "Tests whether a TCP port can be reached on a local or remote host." -ForegroundColor Cyan
    Write-Host "Type q at any prompt to return to Local server and file tools." -ForegroundColor DarkGray
    Write-Host ""

    while ($true) {
        $computerName = Read-Host "Remote IP address or hostname (Enter = 127.0.0.1)"
        if (Test-IsBack $computerName) { return }
        if ([string]::IsNullOrWhiteSpace($computerName)) { $computerName = '127.0.0.1' }
        $computerName = $computerName.Trim()

        $portText = Read-Host "TCP port number"
        if (Test-IsBack $portText) { return }
        $port = 0
        if (-not [int]::TryParse($portText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
            Write-Host "Enter a TCP port from 1 to 65535, or type q to go back." -ForegroundColor Yellow
            continue
        }

        try {
            Write-StreamingLog -Percent 20 -Step "Connect" -Description "Testing TCP $computerName`:$port (30-second timeout)."
            $arguments = [pscustomobject]@{ ComputerName = $computerName; Port = $port }
            $testResult = @(Invoke-OperationWithTimeout -OperationName "testing TCP $computerName`:$port" -TimeoutSeconds 30 -Argument $arguments -ScriptBlock {
                param($InputArguments)
                Test-NetConnection -ComputerName $InputArguments.ComputerName -Port $InputArguments.Port -InformationLevel Detailed -WarningAction SilentlyContinue
            } | Select-Object -First 1)

            if ($testResult.Count -eq 0) { throw "Test-NetConnection did not return a result." }
            Write-StreamingLog -Percent 100 -Step "Complete" -Description "TCP port test completed."
            Show-ConsoleResults -Data $testResult
            if ($testResult[0].TcpTestSucceeded) {
                Write-Host "Success: TCP port $port is open on $computerName." -ForegroundColor Green
            }
            else {
                Write-Host "Failed: TCP port $port is not reachable on $computerName." -ForegroundColor Red
            }
        }
        catch {
            Show-LoggedError -Prefix "The TCP port check did not complete" -Context "Local server and file tools - Check if a port is open" -ErrorRecord $_
        }

        Pause-Screen
        return
    }
}

function Show-ServerInfrastructureSuite {
    while ($true) {
        Clear-Host
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                        LOCAL SERVER AND FILE TOOLS" -ForegroundColor Cyan
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "1) Search for text in files"
        Write-Host "2) Check system health"
        Write-Host "3) Show recently created or changed files"
        Write-Host "4) Analyze disk usage (visual report)"
        Write-Host "5) Manage SQL backup folder permissions"
        Write-Host "6) Check if a port is open"
        Write-Host "7) Trace events in Data Collector"
        Write-Host "q) Back to main menu"
        Write-Host "------------------------------------------------------------------------"
        $Choice = Read-Host "Choose an option"

        if (Test-IsBack $Choice) { return }
        switch ($Choice) {
            '1' { Invoke-LoggedToolAction -Context "Local server and file tools - search for text in files" -Action { Invoke-TextSearch } }
            '2' { Invoke-LoggedToolAction -Context "Local server and file tools - check system health" -Action { Invoke-ServerAudit } }
            '3' { Invoke-LoggedToolAction -Context "Local server and file tools - show recently created or changed files" -Action { Invoke-RecentFilesTracker } }
            '4' { Invoke-LoggedToolAction -Context "Local server and file tools - analyze disk usage" -Action { Invoke-DiskSpaceAnalyzer } }
            '5' { Invoke-LoggedToolAction -Context "Local server and file tools - manage SQL backup folder permissions" -Action { Show-SqlBackupFolderPermissionsMenu } }
            '6' { Invoke-LoggedToolAction -Context "Local server and file tools - Check if a port is open" -Action { Test-RemoteTcpPort } }
            '7' { Invoke-LoggedToolAction -Context "Local server and file tools - Trace events in Data Collector" -Action { Invoke-DataCollectorEventTrace } }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ------------------------------------------------------------------------------
# Main menu
# ------------------------------------------------------------------------------
function Show-MasterMainMenu {
    while ($true) {
        Clear-Host
        Show-ITToolsDeveloperBanner
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "                              IT TOOLS" -ForegroundColor Green
        Write-Host "========================================================================" -ForegroundColor DarkGray
        Write-Host "1) Database Tools"
        Write-Host "2) Local server and file tools"
        Write-Host "3) Add Site Monitoring"
        Write-Host "q) Quit"
        Write-Host "------------------------------------------------------------------------"
        $MainChoice = Read-Host "Choose an option"

        if ($MainChoice -ieq 'q' -or $MainChoice -ieq 'quit' -or $MainChoice -ieq 'exit') {
            Clear-DatabaseConnection
            Write-Host ""
            Write-Host "Done. The tool has closed." -ForegroundColor Cyan
            Start-Sleep -Seconds 1
            break
        }

        switch ($MainChoice) {
            '1' { Invoke-LoggedToolAction -Context "Main menu - Database Tools" -Action { Show-DatabaseMasterSuite } }
            '2' { Invoke-LoggedToolAction -Context "Main menu - Local server and file tools" -Action { Show-ServerInfrastructureSuite } }
            '3' { Invoke-LoggedToolAction -Context "Main menu - Site Monitoring" -Action { Show-SiteMonitoringMenu } }
            default {
                Write-Host "That is not a valid choice. Try again." -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
}

# Start the script.
try {
    Invoke-ITToolsAutomaticUpdate
    Show-MasterMainMenu
}
catch {
    Show-LoggedError -Prefix "The script stopped unexpectedly" -Context "IT Tools startup/runtime" -ErrorRecord $_
    Pause-Screen
}
