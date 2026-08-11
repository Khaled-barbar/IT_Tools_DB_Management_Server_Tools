# Loop control variables
$filePath = $null
$mainLoop = $true

while ($mainLoop) {
    # Prompt for file path if not already retained from a Restart 'R'
    if (-not $filePath) {
        $filePath = Read-Host "Enter the log file path"
        # Clean up quotes in case the user dragged and dropped the file into the console
        $filePath = $filePath.Trim('"').Trim("'")
    }

    # Verify file existence
    if (-not (Test-Path -Path $filePath -PathType Leaf)) {
        Write-Host "Error: File not found at '$filePath'. Please try again." -ForegroundColor Red
        $filePath = $null
        continue
    }

    Write-Host "`nAnalyzing log file..." -ForegroundColor Cyan

    $gaps = @()
    $lastLine = $null
    $lastTime = $null
    
    # Streams initialization
    $fileStream = $null
    $reader = $null

    try {
        # Open the file with Read access and explicit ReadWrite sharing rules
        $fileStream = [System.IO.FileStream]::new(
            $filePath, 
            [System.IO.FileMode]::Open, 
            [System.IO.FileAccess]::Read, 
            [System.IO.FileShare]::ReadWrite
        )
        $reader = [System.IO.StreamReader]::new($fileStream)

        while (($line = $reader.ReadLine()) -ne $null) {
            
            # Match the timestamp regex pattern at the start of the line (MM/dd/yyyy HH:mm:ss)
            if ($line -match '^(\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})') {
                $timeString = $Matches[1]
                $currentTime = [datetime]::ParseExact($timeString, 'MM/dd/yyyy HH:mm:ss', $null)

                if ($lastTime -ne $null) {
                    # Calculate difference in seconds
                    $secondsDiff = ($currentTime - $lastTime).TotalSeconds
                    
                    # If gap is greater than 60 seconds (1 minute)
                    if ($secondsDiff -gt 60) {
                        $gaps += [PSCustomObject]@{
                            Before = $lastLine
                            After  = $line
                        }
                    }
                }
                $lastTime = $currentTime
                $lastLine = $line
            }
        }
    }
    catch {
        Write-Host "An error occurred while processing the file: $_" -ForegroundColor Red
    }
    finally {
        # Properly close streams in reverse order
        if ($reader) { $reader.Close() }
        if ($fileStream) { $fileStream.Close() }
    }

    # --- Display Results ---
    Write-Host "`nNumber of event gaps (more than 60 seconds): $($gaps.Count)"
    foreach ($gap in $gaps) {
        Write-Host "---"
        Write-Host $gap.Before
        Write-Host $gap.After
    }
    if ($gaps.Count -gt 0) {
        Write-Host "---"
    }

    # --- Post-Search Menu ---
    $menuLoop = $true
    while ($menuLoop) {
        Write-Host "`n[Q] Quit  |  [S] Search a different file path  |  [R] Restart the same search" -ForegroundColor Yellow
        $choice = (Read-Host "Select an option").ToUpper().Trim()

        switch ($choice) {
            'Q' {
                $mainLoop = $false
                $menuLoop = $false
                Write-Host "Exiting script. Goodbye!" -ForegroundColor Green
            }
            'S' {
                $filePath = $null  # Reset path so it prompts again
                $menuLoop = $false
            }
            'R' {
                # Keeps the current $filePath and loops back to run again
                $menuLoop = $false
            }
            default {
                Write-Host "Invalid choice. Please enter Q, S, or R." -ForegroundColor Red
            }
        }
    }
}