<#
.SYNOPSIS
    Automated script for file transfer to NAS using Robocopy

.DESCRIPTION
    Complete transfer system with optimized validations, efficient monitoring,
    error handling, and protection against connection loss.
    Optimized for large folders and long paths (+240 characters).

.NOTES
    Version: 1.0
    Author: Automated System
    Date: 2026-02-13
    Status: Pre-production
    
.FEATURES
    - Direct UNC architecture (no drive mapping)
    - Efficient validations with single source scan
    - Simple and fast detection of existing files
    - Lightweight log-based monitoring
    - Protection against connection loss and retry loops
    - Dynamic timeout based on file size
    - Long path handling (>240 characters)
    - Individual logs with automatic rotation
    - Optional exclusion of temporary files
    - Optimized for civil engineering projects
#>

#Requires -Version 5.1

#region ===== GLOBAL CONFIGURATION =====

# System constants
$SCRIPT_VERSION = "1.0"
$LOG_DIRECTORY = "C:\Logs"
$LOG_RETENTION_DAYS = 30
$CONNECTION_CHECK_INTERVAL = 10  # seconds
$MIN_TIMEOUT_SECONDS = 300       # 5 minutes minimum

# Predefined NAS configuration
$NAS_PRESETS = @{
    "1" = @{ Name = "Historical"; Path = "\\192.168.1.254\Historico" }
    "2" = @{ Name = "EDI";       Path = "\\192.168.1.254\edi" }
    "3" = @{ Name = "ATO";     Path = "\\192.168.1.254\ato" }
    "4" = @{ Name = "Testing";   Path = "\\192.168.1.254\Pruebas" }
    "5" = @{ Name = "Other";     Path = "" }
}

# Session variables
$Script:DateTag = Get-Date -Format "yyyyMMdd_HHmmss"
$Script:TransferCounter = 1
$Script:LastLogSize = 0
$Script:LastActivity = Get-Date
$Script:NASPath = ""  # UNC path of selected NAS

#endregion

#region ===== UTILITY FUNCTIONS =====

function Write-SectionHeader {
    <#
    .SYNOPSIS
        Displays a formatted section header
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        
        [Parameter()]
        [ConsoleColor]$Color = 'Cyan'
    )
    
    Write-Host ""
    Write-Host "================================" -ForegroundColor $Color
    Write-Host " $Title" -ForegroundColor $Color
    Write-Host "================================" -ForegroundColor $Color
    Write-Host ""
}

function Confirm-UserAction {
    <#
    .SYNOPSIS
        Requests user confirmation
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [string]$PromptText = "Enter Y to continue or N to specify another destination"
    )
    
    Write-SectionHeader -Title "OPERATION CONFIRMATION" -Color Cyan
    Write-Host $Message
    Write-Host ""
    $response = Read-Host $PromptText
    
    return ($response -match '^(Y|YES|S|SI)$')
}

function Test-NASConnection {
    <#
    .SYNOPSIS
        Verifies connectivity with NAS using UNC path
    #>
    param(
        [Parameter(Mandatory)]
        [string]$UNCPath
    )
    
    try {
        # Try to access the UNC path
        $null = Get-ChildItem -Path $UNCPath -ErrorAction Stop | Select-Object -First 1
        return $true
    } catch {
        return $false
    }
}



function Get-FolderSize {
    <#
    .SYNOPSIS
        Calculates the total size of a folder
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $files = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue
    $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
    
    # Ensure totalSize is never null
    if ($null -eq $totalSize) {
        $totalSize = 0
    }
    
    return @{
        TotalBytes = $totalSize
        TotalMB = [math]::Round(($totalSize / 1MB), 2)
        TotalGB = [math]::Round(($totalSize / 1GB), 2)
        FileCount = if ($files) { $files.Count } else { 0 }
    }
}

#endregion

#region ===== VALIDATION FUNCTIONS =====

function Test-ValidPath {
    <#
    .SYNOPSIS
        Validates that a path exists and is a folder
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    if (-not (Test-Path $Path)) {
        Write-Host "`nERROR: Path does not exist: $Path" -ForegroundColor Red
        return $false
    }
    
    if (-not (Test-Path $Path -PathType Container)) {
        Write-Host "`nERROR: Path must be a folder, not a file" -ForegroundColor Red
        return $false
    }
    
    return $true
}

function Test-InvalidCharactersInFiles {
    <#
    .SYNOPSIS
        Detects files with invalid special characters
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $invalidChars = '[<>"|?*]'
    $problematicFiles = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $invalidChars }
    
    if ($problematicFiles) {
        Write-Host "WARNING: Files with invalid special characters:" -ForegroundColor Yellow
        Write-Host "Problematic characters: < > : `" | ? *`n" -ForegroundColor Yellow
        
        $showCount = [math]::Min(5, $problematicFiles.Count)
        for ($i = 0; $i -lt $showCount; $i++) {
            Write-Host "  - $($problematicFiles[$i].Name)" -ForegroundColor Red
        }
        
        if ($problematicFiles.Count -gt 5) {
            Write-Host "  ... and $($problematicFiles.Count - 5) more file(s)" -ForegroundColor Gray
        }
        
        return $false
    }
    
    return $true
}

function Test-LongPaths {
    <#
    .SYNOPSIS
        Detects very long paths that may cause problems
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $longPaths = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.Length -gt 240 }
    
    if ($longPaths) {
        Write-Host "WARNING: Very long paths detected (>240 characters):" -ForegroundColor Yellow
        
        $showCount = [math]::Min(3, $longPaths.Count)
        for ($i = 0; $i -lt $showCount; $i++) {
            $path = $longPaths[$i].FullName
            if ($path.Length -gt 80) {
                $path = $path.Substring(0, 77) + "..."
            }
            $pathLength = $longPaths[$i].FullName.Length
            Write-Host "  - $path - $pathLength characters" -ForegroundColor Red
        }
        
        if ($longPaths.Count -gt 3) {
            $remaining = $longPaths.Count - 3
            Write-Host "  ... and $remaining more files" -ForegroundColor Gray
        }
        
        Write-Host "NOTE: Script will use Windows long paths if necessary`n" -ForegroundColor Cyan
    }
}

function Test-FilesInUse {
    <#
    .SYNOPSIS
        Detects files that are in use
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $commonLockedExtensions = '\.(docx?|xlsx?|pptx?|mdb|accdb|pst|ost|ldf|mdf)$'
    $filesToCheck = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match $commonLockedExtensions }
    
    $filesInUse = @()
    foreach ($file in $filesToCheck) {
        try {
            $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'None')
            $stream.Close()
            $stream.Dispose()
        } catch {
            $filesInUse += $file.Name
        }
    }
    
    if ($filesInUse.Count -gt 0) {
        Write-Host "WARNING: $($filesInUse.Count) file(s) may be in use:" -ForegroundColor Yellow
        
        $showCount = [math]::Min(5, $filesInUse.Count)
        for ($i = 0; $i -lt $showCount; $i++) {
            Write-Host "  - $($filesInUse[$i])" -ForegroundColor Red
        }
        
        if ($filesInUse.Count -gt 5) {
            Write-Host "  ... and $($filesInUse.Count - 5) more file(s)" -ForegroundColor Gray
        }
        
        Write-Host "`nRECOMMENDATION: Close files before copying" -ForegroundColor Yellow
        Write-Host "Robocopy will attempt to copy them with automatic retries`n" -ForegroundColor Cyan
        
        return $false
    }
    
    return $true
}

function Show-SpecialAttributesInfo {
    <#
    .SYNOPSIS
        Displays information about files with special attributes
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $specialFiles = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -match 'ReadOnly|Hidden|System' }
    
    if ($specialFiles) {
        Write-Host "INFO: Files with special attributes detected:" -ForegroundColor Cyan
        
        $readOnlyCount = ($specialFiles | Where-Object { $_.Attributes -match 'ReadOnly' }).Count
        $hiddenCount = ($specialFiles | Where-Object { $_.Attributes -match 'Hidden' }).Count
        $systemCount = ($specialFiles | Where-Object { $_.Attributes -match 'System' }).Count
        
        if ($readOnlyCount -gt 0) {
            Write-Host "  - $readOnlyCount read-only file(s)" -ForegroundColor Gray
        }
        if ($hiddenCount -gt 0) {
            Write-Host "  - $hiddenCount hidden file(s)" -ForegroundColor Gray
        }
        if ($systemCount -gt 0) {
            Write-Host "  - $systemCount system file(s)" -ForegroundColor Gray
        }
        
        Write-Host "These files will be copied preserving their attributes`n" -ForegroundColor Green
    }
}

#endregion

#region ===== MAIN TRANSFER FUNCTION =====

function Start-FileTransfer {
    <#
    .SYNOPSIS
        Executes transfer with Robocopy and monitors progress
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        
        [Parameter(Mandatory)]
        [string]$Destination,
        
        [Parameter(Mandatory)]
        [string]$LogFile,
        
        [Parameter()]
        [string]$Strategy = "",
        
        [Parameter()]
        [string]$ExcludeParams = "",
        
        [Parameter()]
        [int]$TimeoutSeconds = 300,
        
        [Parameter()]
        [double]$SourceSizeBytes = 0,
        
        [Parameter(Mandatory)]
        [string]$NASPath
    )
    
    # Configure Robocopy arguments
    $robocopyArgs = @(
        "`"$Source`"",
        "`"$Destination`"",
        "/E /Z /MT:16 /R:10 /W:30 $Strategy $ExcludeParams",
        "/COPY:DATS /DCOPY:DAT /A-:SH",
        "/LOG:`"$LogFile`"",
        "/NFL /NDL /NP",
        "/V /TS /FP /BYTES /X /XX"
    )
    
    Write-Host "Starting transfer...`n" -ForegroundColor Green
    Write-Host "Executing: robocopy $($robocopyArgs -join ' ')`n" -ForegroundColor Gray
    Write-Host "Copying files... (may take several minutes)" -ForegroundColor Cyan
    Write-Host "Activity monitor:" -ForegroundColor Cyan
    
    # Start Robocopy process
    $process = Start-Process robocopy -ArgumentList $robocopyArgs -NoNewWindow -PassThru
    
    # Monitoring variables
    $lastLogSize = 0
    $lastActivity = Get-Date
    $lastConnectionCheck = Get-Date
    $checkCount = 0
    $errorCount = 0
    $lastErrorCheck = Get-Date
    
    # Show initial progress immediately
    Write-Progress -Activity "Copying files..." `
        -Status "Starting copy... Please wait while Robocopy analyzes the files" `
        -PercentComplete 0
    
    # Process monitoring
    do {
        Start-Sleep 2
        $checkCount++
        
        # Verify process is still active
        if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            break
        }
        
        # Check connectivity periodically
        if (((Get-Date) - $lastConnectionCheck).TotalSeconds -ge $CONNECTION_CHECK_INTERVAL) {
            if (-not (Test-NASConnection -UNCPath $NASPath)) {
                Write-Progress -Activity "Copying files..." -Completed
                
                Write-SectionHeader -Title "ERROR: NAS CONNECTION LOST" -Color Red
                Write-Host "Connection loss detected during transfer." -ForegroundColor Yellow
                Write-Host "`nPossible causes:" -ForegroundColor Yellow
                Write-Host "  - Network cable disconnected" -ForegroundColor Yellow
                Write-Host "  - NAS powered off or restarted" -ForegroundColor Yellow
                Write-Host "  - Network timeout" -ForegroundColor Yellow
                Write-Host "  - Credentials expired`n" -ForegroundColor Yellow
                
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                
                Write-Host "Process stopped to prevent file corruption." -ForegroundColor Red
                Write-Host "`nRECOMMENDED ACTIONS:" -ForegroundColor Cyan
                Write-Host "1. Check network connection" -ForegroundColor Cyan
                Write-Host "2. Verify NAS is accessible" -ForegroundColor Cyan
                Write-Host "3. Run the script again" -ForegroundColor Cyan
                Write-Host "4. Robocopy will continue from where it stopped (/Z mode)`n" -ForegroundColor Green
                
                Pause
                exit 1
            }
            $lastConnectionCheck = Get-Date
        }
        
        # Check log activity
        if (Test-Path $LogFile) {
            $logSize = (Get-Item $LogFile).Length
            if ($logSize -gt $lastLogSize) {
                $lastLogSize = $logSize
                $lastActivity = Get-Date
                
                # Detect repeated errors every 30 seconds
                if (((Get-Date) - $lastErrorCheck).TotalSeconds -ge 30) {
                    $logContent = Get-Content $LogFile -Tail 20 -ErrorAction SilentlyContinue
                    $recentErrors = ($logContent | Select-String -Pattern "ERROR|Waiting.*seconds.*Retrying").Count
                    
                    if ($recentErrors -gt 5) {
                        $errorCount++
                        if ($errorCount -ge 3) {
                            Write-Progress -Activity "Copying files..." -Completed
                            Write-Host "`n`nERROR: Robocopy stuck in retry loop" -ForegroundColor Red
                            Write-Host "Errors detected in log. Review: $LogFile" -ForegroundColor Yellow
                            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                            Pause
                            exit 1
                        }
                    } else {
                        $errorCount = 0
                    }
                    $lastErrorCheck = Get-Date
                }
                
                # Show simple log-based progress
                $logSizeKB = [math]::Round($logSize/1KB, 1)
                Write-Progress -Activity "Copying files..." `
                    -Status "Robocopy active - Log: $logSizeKB KB" `
                    -PercentComplete 50
                
                if ($checkCount % 15 -eq 0) {
                    Write-Host " [Log: $logSizeKB KB - Active]" -ForegroundColor Cyan
                }
            }
        }
        
        # Check timeout
        if (((Get-Date) - $lastActivity).TotalSeconds -ge $TimeoutSeconds) {
            Write-Progress -Activity "Copying files..." -Completed
            Write-Host "`nERROR: Robocopy without activity for $([math]::Round($TimeoutSeconds/60,1)) minutes" -ForegroundColor Red
            
            if (-not (Test-NASConnection -UNCPath $NASPath)) {
                Write-Host "CAUSE: NAS connection loss detected" -ForegroundColor Red
            }
            
            Stop-Process -Id $process.Id -Force
            Pause
            exit 1
        }
            
    } while ($true)
    
    Write-Host "`n`nRobocopy completed. Processing result..." -ForegroundColor Green
    Write-Progress -Activity "Copying files..." -Completed
    
    # Wait for process to finish and get exit code
    $process.WaitForExit()
    return $process.ExitCode
}

function Get-RobocopyExitCodeMessage {
    <#
    .SYNOPSIS
        Interprets Robocopy exit code
    #>
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode
    )
    
    $result = @{
        IsError = $false
        Message = ""
        Color = "Green"
    }
    
    switch ($ExitCode) {
        0 {
            $result.Message = "No changes - No files were copied"
            $result.Color = "Yellow"
            $result.Details = @(
                "Possible causes:",
                "  • Source files are NOT newer than destination files",
                "  • Modification dates are the same or older",
                "  • No new files to copy",
                "Check the summary above to confirm: Copied = 0, Skipped = all"
            )
        }
        1 {
            $result.Message = "Success - Files copied correctly"
            $result.Color = "Green"
        }
        2 {
            $result.Message = "Success - Extra files detected at destination"
            $result.Color = "Green"
        }
        3 {
            $result.Message = "Success - Files copied and extras detected"
            $result.Color = "Green"
        }
        { $_ -ge 8 } {
            $result.IsError = $true
            $result.Message = "CRITICAL ERROR - Some files were NOT copied"
            $result.Color = "Red"
        }
        { $_ -ge 4 } {
            $result.Message = "WARNING - Some files do not match or there were minor errors"
            $result.Color = "Yellow"
        }
    }
    
    return $result
}

#endregion

#region ===== MAIN SCRIPT =====

# Initialization
Clear-Host
$Host.UI.RawUI.WindowTitle = "Automated NAS Transfer v$SCRIPT_VERSION"

Write-Host "================================"
Write-Host " AUTOMATED NAS TRANSFER"
Write-Host " Version $SCRIPT_VERSION"
Write-Host "================================"
Write-Host ""

# Create log directory if it doesn't exist
if (-not (Test-Path $LOG_DIRECTORY)) {
    New-Item -ItemType Directory -Path $LOG_DIRECTORY | Out-Null
}

# NAS folder selection
Write-Host "Select destination folder on NAS:" -ForegroundColor Cyan
Write-Host ""
foreach ($key in ($NAS_PRESETS.Keys | Sort-Object)) {
    Write-Host "  $key. $($NAS_PRESETS[$key].Name)"
}
Write-Host ""

do {
    $option = Read-Host "Enter option (1-5)"
    
    if ($NAS_PRESETS.ContainsKey($option)) {
        $selectedNAS = $NAS_PRESETS[$option].Path
        
        # If path is empty, request manual input
        if ([string]::IsNullOrEmpty($selectedNAS)) {
            do {
                $selectedNAS = Read-Host "Enter complete NAS path (e.g., \\192.168.1.254\MyFolder)"
                
                if ($selectedNAS -notmatch '^\\\\[^\\]+\\[^\\]+') {
                    Write-Host "ERROR: Path must be in UNC format (\\server\share)" -ForegroundColor Red
                    $retry = Read-Host "Do you want to try again? (Y/N)"
                    if ($retry -notmatch '^(Y|YES|S|SI)$') {
                        $option = $null
                        break
                    }
                    $selectedNAS = $null
                    continue
                }
                
                Write-Host "Verifying accessibility..." -ForegroundColor Cyan
                if (-not (Test-Path $selectedNAS -ErrorAction SilentlyContinue)) {
                    Write-Host "WARNING: Cannot access path" -ForegroundColor Yellow
                    $continue = Read-Host "Continue anyway? (Y/N)"
                    if ($continue -notmatch '^(Y|YES|S|SI)$') {
                        $selectedNAS = $null
                        continue
                    }
                }
                
                break
            } while ($true)
            
            if ($null -eq $option) { continue }
        }
        
        break
    } else {
        Write-Host "Invalid option. Please try again." -ForegroundColor Yellow
        $option = $null
    }
} while ($null -eq $option)

Write-Host "`nSelected folder: $selectedNAS" -ForegroundColor Green
Write-Host ""

# Save NAS path in script variable
$Script:NASPath = $selectedNAS

# Authenticate with NAS
Write-Host "Connecting to NAS..." -ForegroundColor Cyan
Write-Host "Path: $Script:NASPath" -ForegroundColor Gray

# Check if credentials are needed by attempting direct access
$needsCredentials = $false

try {
    Write-Host "Verifying access..." -ForegroundColor Gray
    $null = Get-ChildItem -Path $Script:NASPath -ErrorAction Stop | Select-Object -First 1
    Write-Host "Connection established successfully (saved credentials)" -ForegroundColor Green
} catch {
    $needsCredentials = $true
}

if ($needsCredentials) {
    Write-Host "`nCredentials required to access NAS." -ForegroundColor Yellow
    Write-Host "A window will open to enter username and password...`n" -ForegroundColor Cyan
    
    try {
        $credential = Get-Credential -Message "Enter your credentials for $Script:NASPath"
    } catch {
        Write-Host "ERROR: Could not open credentials window" -ForegroundColor Red
        Write-Host "Try connecting manually to NAS from File Explorer first`n" -ForegroundColor Yellow
        Pause
        exit 1
    }
    
    if ($null -eq $credential) {
        Write-Host "`nOperation cancelled by user" -ForegroundColor Yellow
        Write-Host "You can connect manually to NAS from File Explorer and run the script again`n" -ForegroundColor Cyan
        Pause
        exit 1
    }
    
    $username = $credential.UserName
    $password = $credential.GetNetworkCredential().Password
    
    Write-Host "Authenticating with NAS..." -ForegroundColor Cyan
    
    # Authenticate with credentials
    net use $Script:NASPath /user:$username $password /persistent:no 2>$null | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nERROR: Could not connect to NAS" -ForegroundColor Red
        Write-Host "Verify that:" -ForegroundColor Yellow
        Write-Host "  - Username and password are correct" -ForegroundColor Yellow
        Write-Host "  - NAS is powered on and accessible" -ForegroundColor Yellow
        Write-Host "  - You have permissions to access this folder`n" -ForegroundColor Yellow
        Pause
        exit 1
    }
    
    Write-Host "Connection established successfully" -ForegroundColor Green
}

Write-Host "Credentials will remain active during session`n" -ForegroundColor Cyan

# Main transfer loop
do {
    Clear-Host
    Write-SectionHeader -Title "AUTOMATED NAS TRANSFER" -Color Cyan
    
    # Request source path
    $sourcePath = Read-Host "Enter SOURCE path (complete folder)"
    
    # Validate source path
    if (-not (Test-ValidPath -Path $sourcePath)) {
        Write-Host "Verify path and try again.`n" -ForegroundColor Yellow
        continue
    }
    
    # Source validations (OPTIMIZED - single scan)
    Write-Host "`nAnalyzing source files..." -ForegroundColor Cyan
    Write-Host "This may take a few seconds on large folders..." -ForegroundColor Gray
    
    # Do ONE SINGLE directory scan
    $allFiles = Get-ChildItem -Path $sourcePath -Recurse -File -Force -ErrorAction SilentlyContinue
    
    if ($null -eq $allFiles -or $allFiles.Count -eq 0) {
        Write-Host "`nWARNING: No files found in source path" -ForegroundColor Yellow
        $continueEmpty = Read-Host "Continue anyway? (Y/N)"
        if ($continueEmpty -notmatch '^(Y|YES|S|SI)$') {
            continue
        }
    }
    
    Write-Host "Files found: $($allFiles.Count)" -ForegroundColor Green
    Write-Host "`nPerforming validations..." -ForegroundColor Cyan
    
    # Validate invalid characters
    $invalidChars = '[<>"|?*]'
    $problematicFiles = $allFiles | Where-Object { $_.Name -match $invalidChars }
    
    if ($problematicFiles) {
        Write-Host "`nWARNING: $($problematicFiles.Count) file(s) with special characters" -ForegroundColor Yellow
        $continueWithInvalidChars = Read-Host "Continue? (Y/N)"
        if ($continueWithInvalidChars -notmatch '^(Y|YES|S|SI)$') {
            continue
        }
    }
    
    # Validate long paths
    $longPaths = $allFiles | Where-Object { $_.FullName.Length -gt 240 }
    if ($longPaths) {
        Write-Host "INFO: $($longPaths.Count) file(s) with long paths (>240 characters)" -ForegroundColor Cyan
    }
    
    # Validate special files
    $specialFiles = $allFiles | Where-Object { $_.Attributes -match 'ReadOnly|Hidden|System' }
    if ($specialFiles) {
        Write-Host "INFO: $($specialFiles.Count) file(s) with special attributes" -ForegroundColor Cyan
    }
    
    # Destination validation loop
    do {
        $destPath = Read-Host "`nEnter DESTINATION path inside NAS"
        
        $folderName = Split-Path $sourcePath -Leaf
        $finalDestination = Join-Path $Script:NASPath "$destPath\$folderName"
        
        $currentLogFile = "$LOG_DIRECTORY\robocopy_$($Script:DateTag)_transfer$($Script:TransferCounter).txt"
        
        Write-Host "`nSummary:"
        Write-Host "Source     : $sourcePath"
        Write-Host "Destination: $finalDestination"
        Write-Host "Log        : $currentLogFile"
        
        if (Confirm-UserAction -Message "Start transfer?") {
            break
        } else {
            Write-Host "`nReturning to destination path input...`n" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    } while ($true)
    
    # Calculate source size using already scanned files
    Write-Host "`nCalculating total size..." -ForegroundColor Cyan
    $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalSize) { $totalSize = 0 }
    
    $totalMB = [math]::Round($totalSize / 1MB, 2)
    $fileCount = $allFiles.Count
    Write-Host "Total size: $totalMB MB - $fileCount files`n" -ForegroundColor Green
    
    # Create destination directory
    New-Item -ItemType Directory -Path $finalDestination -Force | Out-Null
    
    # Detect if destination has files (FAST - no deep scan)
    Write-Host "`nVerifying destination..." -ForegroundColor Cyan
    
    $hasExistingFiles = $false
    $existingFiles = @()
    
    if (Test-Path $finalDestination) {
        # Get first files for quick sample
        $existingFiles = @(Get-ChildItem -Path $finalDestination -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 50)
        $hasExistingFiles = ($existingFiles.Count -gt 0)
    }
    
    $strategyParams = ""
    
    if ($hasExistingFiles) {
        Write-Host "Destination contains existing files" -ForegroundColor Yellow
        Write-Host "`nTransfer information:" -ForegroundColor Cyan
        Write-Host "  Total files in SOURCE: $fileCount files" -ForegroundColor White
        Write-Host "  Total size: $totalMB MB" -ForegroundColor White
        Write-Host "  Files found in DESTINATION: $($existingFiles.Count)+ files" -ForegroundColor Gray
        
        # Ask if they want to see analysis before copying
        $showFiles = Read-Host "`nAnalyze files before copying? (Y/N)"
        
        if ($showFiles -match '^(Y|YES|S|SI)$') {
            Write-Host "`nAnalyzing SOURCE files (sample of up to 20)..." -ForegroundColor Cyan
            Write-Host "Comparing with destination files for 'Replace if newer' strategy`n" -ForegroundColor Yellow
            
            $willCopy = 0      # New or more recent
            $willSkip = 0      # Same date or older
            $showCount = [math]::Min(20, $allFiles.Count)
            
            for ($i = 0; $i -lt $showCount; $i++) {
                $srcFile = $allFiles[$i]
                $relPath = $srcFile.FullName.Replace($sourcePath, "")
                $destFilePath = Join-Path $finalDestination $relPath
                
                if (Test-Path $destFilePath) {
                    # File exists in destination - compare dates
                    $destFile = Get-Item $destFilePath -ErrorAction SilentlyContinue
                    if ($destFile) {
                        if ($srcFile.LastWriteTime -gt $destFile.LastWriteTime) {
                            # Source newer → WILL BE COPIED
                            Write-Host "  ✓ $relPath" -ForegroundColor Green -NoNewline
                            Write-Host " [NEWER - will be copied]" -ForegroundColor Yellow
                            $willCopy++
                        } elseif ($srcFile.LastWriteTime -lt $destFile.LastWriteTime) {
                            # Source older → WILL BE SKIPPED
                            Write-Host "  ✗ $relPath" -ForegroundColor Gray -NoNewline
                            Write-Host " [older - will be skipped]" -ForegroundColor DarkGray
                            $willSkip++
                        } else {
                            # Same date → WILL BE SKIPPED
                            Write-Host "  ✗ $relPath" -ForegroundColor Gray -NoNewline
                            Write-Host " [same date - will be skipped]" -ForegroundColor DarkGray
                            $willSkip++
                        }
                    }
                } else {
                    # File DOES NOT exist in destination → WILL BE COPIED
                    Write-Host "  ✓ $relPath" -ForegroundColor Green -NoNewline
                    Write-Host " [NEW - will be copied]" -ForegroundColor Cyan
                    $willCopy++
                }
            }
            
            if ($allFiles.Count -gt 20) {
                $remaining = $allFiles.Count - 20
                Write-Host "`n  ... and $remaining more file(s) not shown" -ForegroundColor Gray
            }
            
            Write-Host "`n" -NoNewline
            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host "PREDICTION (based on sample of $showCount files):" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host "  ✓ Will be copied (new or more recent): $willCopy" -ForegroundColor Green
            Write-Host "  ✗ Will be skipped (same date or older): $willSkip" -ForegroundColor Gray
            Write-Host "`n" -NoNewline
            Write-Host "  💡 This analysis shows files from YOUR SOURCE" -ForegroundColor Yellow
            Write-Host "     Robocopy will process all $fileCount files" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
        }
        
        Write-Host ""
        Write-Host "Select copy strategy:" -ForegroundColor Cyan
        Write-Host "(This strategy will apply to ALL files in the transfer)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  1. Replace if newer (recommended)"
        Write-Host "  2. Skip existing files"
        Write-Host "  3. Overwrite all"
        Write-Host ""
        
        $strategy = Read-Host "Select (1-3, Enter=1)"
        if ([string]::IsNullOrWhiteSpace($strategy)) { $strategy = "1" }
        
        switch ($strategy) {
            "1" { 
                $strategyParams = ""
                Write-Host "Strategy: Replace newer" -ForegroundColor Green
                Write-Host "Robocopy will copy files where source date is more recent" -ForegroundColor Cyan
            }
            "2" { 
                $strategyParams = "/XC /XN /XO"
                Write-Host "Strategy: Skip existing" -ForegroundColor Green
                Write-Host "Robocopy will NOT touch any file that already exists at destination" -ForegroundColor Cyan
            }
            "3" { 
                $strategyParams = "/IS"
                Write-Host "Strategy: Overwrite all" -ForegroundColor Green
                Write-Host "Robocopy will replace ALL files regardless of date" -ForegroundColor Yellow
            }
            default { $strategyParams = "" }
        }
        Write-Host ""
    } else {
        Write-Host "Destination is empty. Proceeding with normal copy`n" -ForegroundColor Green
    }
    
    # Advanced options
    Write-SectionHeader -Title "ADVANCED OPTIONS" -Color Cyan
    Write-Host "Exclude temporary and system files?" -ForegroundColor Cyan
    Write-Host "  - Temporary files: ~$*, *.tmp, *.temp, *.bak" -ForegroundColor Gray
    Write-Host "  - System folders: Thumbs.db, .DS_Store, desktop.ini`n" -ForegroundColor Gray
    
    $excludeTemps = Read-Host "Exclude temporary files? (Y/N)"
    $excludeParams = ""
    
    if ($excludeTemps -match '^(Y|YES|S|SI)$') {
        $excludeParams = "/XF ~$* *.tmp *.temp *.bak Thumbs.db .DS_Store desktop.ini /XD `$RECYCLE.BIN `"System Volume Information`""
        Write-Host "Temporary files will be excluded`n" -ForegroundColor Green
    } else {
        Write-Host "All files will be copied`n" -ForegroundColor Yellow
    }
    
    # Verify destination space
    Write-Host "Verifying available space..." -ForegroundColor Cyan
    
    try {
        # Get volume information using WMI
        $nasServer = ($Script:NASPath -split '\\')[2]
        $nasShare = ($Script:NASPath -split '\\')[3]
        
        # Try to get free space
        $wmiQuery = "SELECT * FROM Win32_MappedLogicalDisk WHERE ProviderName LIKE '%$nasServer%'"
        $mappedDrive = Get-WmiObject -Query $wmiQuery -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($mappedDrive) {
            $freeSpaceGB = [math]::Round($mappedDrive.FreeSpace / 1GB, 2)
            $totalGB = [math]::Round($totalSize / 1GB, 2)
            
            Write-Host "Required space: $totalGB GB" -ForegroundColor Cyan
            Write-Host "Available space: $freeSpaceGB GB" -ForegroundColor Cyan
            
            if ($mappedDrive.FreeSpace -lt ($totalSize * 1.1)) {
                Write-Host "`nWARNING: Insufficient space" -ForegroundColor Red
                $continueAnyway = Read-Host "Continue anyway? (Y/N)"
                if ($continueAnyway -notmatch '^(Y|YES|S|SI)$') {
                    continue
                }
            } else {
                Write-Host "Sufficient space available`n" -ForegroundColor Green
            }
        } else {
            Write-Host "Could not verify space (continuing anyway)`n" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Could not verify space at destination`n" -ForegroundColor Yellow
    }
    
    # Calculate dynamic timeout
    $totalGB = [math]::Round($totalSize / 1GB, 2)
    $timeoutSeconds = [math]::Max($MIN_TIMEOUT_SECONDS, 60 * [math]::Ceiling($totalGB))
    Write-Host "Timeout configured: $([math]::Round($timeoutSeconds / 60, 1)) minutes (adjusted by size)`n" -ForegroundColor Cyan
    
    # Configure Robocopy parameters
    Write-Host "Configuring resilient copy parameters..." -ForegroundColor Cyan
    Write-Host "  - Restartable mode (/Z) - Allows resuming interrupted copies" -ForegroundColor Gray
    Write-Host "  - 10 retries with 30 seconds wait" -ForegroundColor Gray
    Write-Host "  - Copying special attributes" -ForegroundColor Gray
    Write-Host "  - Connectivity check every $CONNECTION_CHECK_INTERVAL seconds`n" -ForegroundColor Gray
    
    # Execute transfer
    $exitCode = Start-FileTransfer -Source $sourcePath `
        -Destination $finalDestination `
        -LogFile $currentLogFile `
        -Strategy $strategyParams `
        -ExcludeParams $excludeParams `
        -TimeoutSeconds $timeoutSeconds `
        -SourceSizeBytes $totalSize `
        -NASPath $Script:NASPath
    
    # Validate result
    Write-SectionHeader -Title "RESULT VALIDATION" -Color Cyan
    Write-Host "Robocopy RAW exit code: $exitCode" -ForegroundColor Cyan
    
    # Detect files copied from log (additional validation)
    $actualFilesCopied = 0
    $actualFilesSkipped = 0
    if (Test-Path $currentLogFile) {
        $logContent = Get-Content $currentLogFile -ErrorAction SilentlyContinue
        
        # Find file summary line
        $fileSummaryLine = $logContent | Select-String -Pattern "^\s+(Files|Archivos):\s+" | Select-Object -Last 1
        if ($fileSummaryLine) {
            # Parse: "Files:  16  13  3  0  0  0"
            # Format: Total, Copied, Skipped, Mismatch, ERROR, Extras
            if ($fileSummaryLine -match "(Files|Archivos):\s+(\d+)\s+(\d+)\s+(\d+)") {
                $actualFilesCopied = [int]$matches[3]
                $actualFilesSkipped = [int]$matches[4]
                Write-Host "Files copied (from log): $actualFilesCopied" -ForegroundColor $(if ($actualFilesCopied -gt 0) { 'Green' } else { 'Gray' })
                Write-Host "Files skipped (from log): $actualFilesSkipped" -ForegroundColor Gray
            }
        }
        
        # Correct exit code if necessary
        if ($exitCode -eq 0 -and $actualFilesCopied -gt 0) {
            Write-Host ""
            Write-Host "⚠️ CORRECTION: Exit code was 0 but $actualFilesCopied files were copied" -ForegroundColor Yellow
            Write-Host "   Adjusting exit code to 1 (Success with files copied)" -ForegroundColor Yellow
            $exitCode = 1
        }
    }
    
    # Detect files modified during copy
    $filesChangedDuringCopy = $false
    if (Test-Path $currentLogFile) {
        $logContent = Get-Content $currentLogFile -ErrorAction SilentlyContinue
        $changedFiles = $logContent | Select-String -Pattern "ERROR.*file has changed|changed during copy" -SimpleMatch
        
        if ($changedFiles) {
            $filesChangedDuringCopy = $true
            Write-Host ""
            Write-Host "WARNING: Files modified during copy:" -ForegroundColor Yellow
            Write-Host "$($changedFiles.Count) file(s) changed while being copied" -ForegroundColor Yellow
            Write-Host "These files may be incomplete at destination`n" -ForegroundColor Red
        }
    }
    
    $exitResult = Get-RobocopyExitCodeMessage -ExitCode $exitCode
    Write-Host $exitResult.Message -ForegroundColor $exitResult.Color
    Write-Host ""
    
    # Summary
    Clear-Host
    Write-Host "--------------------------------"
    Write-Host " TRANSFER SUMMARY"
    Write-Host "--------------------------------"
    Write-Host ""
    
    if (Test-Path $currentLogFile) {
        # Search for Robocopy summary section
        $logContent = Get-Content $currentLogFile
        $summaryStart = -1
        
        for ($i = 0; $i -lt $logContent.Count; $i++) {
            if ($logContent[$i] -match "^\s+(Dirs\s*:|Files\s*:|Bytes\s*:)" -or 
                $logContent[$i] -match "^\s+Total\s+Copied\s+Skipped" -or
                $logContent[$i] -match "------------------------------------------------------------------------------" -and 
                $i -gt 10 -and $logContent.Count - $i -lt 50) {
                $summaryStart = $i
                break
            }
        }
        
        if ($summaryStart -ge 0) {
            # Show from summary start to end or next 30 lines
            $endLine = [math]::Min($summaryStart + 30, $logContent.Count - 1)
            for ($i = $summaryStart; $i -le $endLine; $i++) {
                # Skip lines that only contain dashes or are empty
                if ($logContent[$i] -match "^[\s-]*$") {
                    continue
                }
                if ($logContent[$i] -match "Finished|Ended" -and $i -gt $summaryStart + 5) {
                    break
                }
                Write-Host $logContent[$i]
            }
        } else {
            Write-Host "Summary not found in log" -ForegroundColor Yellow
            Write-Host "Check log file for more details: $currentLogFile" -ForegroundColor Gray
        }
    }
    
    Write-Host "`n================================"
    Write-Host " TRANSFER COMPLETED"
    Write-Host "================================"
    Write-Host "Status: $($exitResult.Message)" -ForegroundColor $exitResult.Color
    Write-Host "Log: $currentLogFile"
    Write-Host ""
    
    if ($exitResult.IsError) {
        Write-Host "ATTENTION: Review log to identify files not copied" -ForegroundColor Red
        Write-Host ""
    }
    
    # Show additional details if available (e.g., exit code 0)
    if ($exitResult.Details) {
        Write-Host "────────────────────────────────" -ForegroundColor Yellow
        foreach ($detail in $exitResult.Details) {
            if ($detail -match "^Possible causes:") {
                Write-Host $detail -ForegroundColor Yellow
            } elseif ($detail -match "^  •") {
                Write-Host $detail -ForegroundColor Gray
            } else {
                Write-Host $detail -ForegroundColor Cyan
            }
        }
        Write-Host "────────────────────────────────" -ForegroundColor Yellow
        Write-Host ""
    }
    
    # Increment counter
    $Script:TransferCounter++
    
    # Ask if continue
    $continue = Read-Host "Perform another transfer? (Y/N)"
    
} while ($continue -match '^(Y|YES|S|SI)$')

# Final cleanup
Write-Host "`nClosing session with NAS..." -ForegroundColor Cyan
net use $Script:NASPath /delete /y 2>$null | Out-Null
Write-Host "Session closed successfully" -ForegroundColor Green

# Old log management
Write-Host "Checking old logs..." -ForegroundColor Cyan

$oldLogs = Get-ChildItem -Path $LOG_DIRECTORY -Filter "robocopy_*.txt" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LOG_RETENTION_DAYS) }

if ($oldLogs) {
    Write-Host "Found $($oldLogs.Count) log(s) older than $LOG_RETENTION_DAYS days" -ForegroundColor Yellow
    
    $totalSize = ($oldLogs | Measure-Object -Property Length -Sum).Sum
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)
    
    Write-Host "Space used: $totalSizeMB MB" -ForegroundColor Yellow
    
    $deleteLogs = Read-Host "Delete old logs? (Y/N)"
    
    if ($deleteLogs -match '^(Y|YES|S|SI)$') {
        $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "Old logs deleted" -ForegroundColor Green
    }
}

Write-Host "`nProcess completed." -ForegroundColor Green
Write-Host "Session logs saved in: $LOG_DIRECTORY" -ForegroundColor Cyan

#endregion
