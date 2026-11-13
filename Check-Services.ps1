[CmdletBinding()]
param (
    [switch]$AddTaskScheduler,
    [switch]$RemoveTaskScheduler
)

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

# Any service whose name matches this pattern is monitored
$servicePattern = "Veeam*"

# Services started first (in this order) when they are stopped. Everything else follows alphabetically.
$priorityServices = @("VeeamBackupSvc")

# Service names to leave alone even though they match the pattern, e.g. @("VeeamCloudSvc")
$excludeServices = @()

# Only services set to Automatic are started. Set to $true to also start services set to Manual.
# Disabled services are never started.
$startManualServices = $false

# Configuration database services to check before the Veeam services.
# PostgreSQL is the default for Veeam B&R 12 and later; older installs use a SQL Express instance.
$databasePatterns = @("postgresql*", "MSSQL`$VEEAM*")

# Seconds to wait after starting a database service before starting the Veeam services
$databaseWaitSeconds = 30

# Seconds to wait before the final re-check of services that had to be started
$verifyWaitSeconds = 30

# Directory and dynamic log file path (the folder this script lives in)
$ScriptFolder = $PSScriptRoot
$logDirectory = $ScriptFolder # Adjust this if you want logs in a different directory
$today = Get-Date -Format "yyyy-MM-dd"
$logFilePath = Join-Path -Path $logDirectory -ChildPath "Veeam_Service_Monitor_$today.log"

$taskName = "Veeam Check Services"

# 1. Ensure the directory exists
if (-not (Test-Path -Path $logDirectory)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}

# 2. Purge log files older than 5 days
$retentionDays = 5
Get-ChildItem -Path $logDirectory -Filter "Veeam_Service_Monitor_*.log" -File |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays) } |
    Remove-Item -Force

# Helper function to write to both screen and file
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $formattedLog = "[$timestamp] [$Level] $Message"

    # Print to screen
    switch ($Level) {
        "ERROR"   { Write-Host $formattedLog -ForegroundColor Red }
        "WARNING" { Write-Host $formattedLog -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $formattedLog -ForegroundColor Green }
        default   { Write-Host $formattedLog -ForegroundColor Cyan }
    }

    # Append to local log file
    Add-Content -Path $logFilePath -Value $formattedLog
}

# Helper function to check for Administrator privileges
function Test-IsAdministrator {
    $currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Helper function to register Scheduled Task
function Install-CheckServicesTask {
    # Point the task at this script, wherever it has been placed
    $targetScriptPath = $PSCommandPath

    if (-not (Test-IsAdministrator)) {
        Write-Log "Administrator privileges are required to register this Scheduled Task." "ERROR"
        return
    }

    # Task Action
    $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$targetScriptPath`""

    # Task Triggers: 15-minute delay after boot AND Daily at 05:49 AM
    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    $bootTrigger.Delay = 'PT15M'
    $dailyTrigger = New-ScheduledTaskTrigger -Daily -At "05:49:25 AM"

    # Task Principal: SYSTEM Account with Highest Privileges
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    # Task Settings
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -Priority 7

    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($bootTrigger, $dailyTrigger) -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Log "Scheduled Task '$taskName' successfully created pointing to: $targetScriptPath" "SUCCESS"
    } catch {
        Write-Log "Failed to register Scheduled Task. Error: $_" "ERROR"
    }
}

# Helper function to remove Scheduled Task
function Unregister-CheckServicesTask {
    if (-not (Test-IsAdministrator)) {
        Write-Log "Administrator privileges are required to remove this Scheduled Task." "ERROR"
        return
    }

    # Check if task exists before attempting removal
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($task) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
            Write-Log "Scheduled Task '$taskName' successfully removed." "SUCCESS"
        } catch {
            Write-Log "Failed to remove Scheduled Task '$taskName'. Error: $_" "ERROR"
        }
    } else {
        Write-Log "Scheduled Task '$taskName' does not exist." "WARNING"
    }
}

# Helper function to list services matching one or more wildcard patterns.
# Win32_Service is used (rather than Get-Service) so the start mode is available on every PowerShell version.
function Get-MatchingServices {
    param ([string[]]$Patterns)

    Get-CimInstance -ClassName Win32_Service |
        Where-Object {
            $name = $_.Name
            @($Patterns | Where-Object { $name -like $_ }).Count -gt 0
        } |
        Sort-Object -Property Name
}

# Helper function to decide whether a stopped service should be started, based on its start mode
function Test-ShouldStart {
    param ($Service)

    switch ($Service.StartMode) {
        "Auto"   { return $true }
        "Manual" { return $startManualServices }
        default  { return $false }
    }
}

# Helper function to start a stopped service. Returns $true if it was started.
function Start-MonitoredService {
    param ($Service)

    $label = "$($Service.DisplayName) ($($Service.Name))"

    if ($Service.State -eq 'Running') {
        Write-Log "Service '$label' is already running." "INFO"
        return $false
    }

    if ($Service.State -ne 'Stopped') {
        # Start Pending, Stop Pending, Paused etc. - leave it alone and let the final re-check report on it
        Write-Log "Service '$label' is in state '$($Service.State)'. Not attempting to start it." "WARNING"
        return $false
    }

    if (-not (Test-ShouldStart -Service $Service)) {
        Write-Log "Service '$label' is stopped but its startup type is '$($Service.StartMode)'. Skipping." "INFO"
        return $false
    }

    try {
        Write-Log "Service '$label' is not running. Attempting to start..." "WARNING"
        Start-Service -Name $Service.Name -ErrorAction Stop
        Write-Log "Service '$label' started successfully." "SUCCESS"
        return $true
    } catch {
        Write-Log "Failed to start service '$label'. Error: $_" "ERROR"
        return $false
    }
}

# --- Handle -AddTaskScheduler Switch ---
if ($AddTaskScheduler) {
    Write-Log "Registering Scheduled Task..." "INFO"
    Install-CheckServicesTask
    exit
}

# --- Handle -RemoveTaskScheduler Switch ---
if ($RemoveTaskScheduler) {
    Write-Log "Removing Scheduled Task..." "INFO"
    Unregister-CheckServicesTask
    exit
}

Write-Log "Starting service status check..." "INFO"

# --- Pre-check: Configuration database ---
$databaseServices = @(Get-MatchingServices -Patterns $databasePatterns)
$databaseStarted = $false

if ($databaseServices.Count -eq 0) {
    Write-Log "No local database service found (patterns: $($databasePatterns -join ', ')). Assuming the configuration database is remote." "INFO"
} else {
    foreach ($databaseService in $databaseServices) {
        if (Start-MonitoredService -Service $databaseService) {
            $databaseStarted = $true
        }
    }

    if ($databaseStarted) {
        Write-Log "A database service was started. Waiting $databaseWaitSeconds seconds for database initialization..." "INFO"
        Start-Sleep -Seconds $databaseWaitSeconds
    }
}

# --- Service Loop ---
$services = @(Get-MatchingServices -Patterns @($servicePattern) | Where-Object { $excludeServices -notcontains $_.Name })

if ($services.Count -eq 0) {
    Write-Log "No services matching '$servicePattern' were found on this system." "WARNING"
    Write-Log "Service status check completed." "INFO"
    exit
}

Write-Log "Found $($services.Count) service(s) matching '$servicePattern'." "INFO"

# Priority services first, then everything else alphabetically
$orderedServices = @()
foreach ($priorityName in $priorityServices) {
    $orderedServices += @($services | Where-Object { $_.Name -eq $priorityName })
}
$orderedServices += @($services | Where-Object { $priorityServices -notcontains $_.Name })

$startedServices = @()
foreach ($service in $orderedServices) {
    # Re-read the state, as starting an earlier service may have started this one as a dependency
    $current = Get-CimInstance -ClassName Win32_Service -Filter "Name='$($service.Name)'"
    if (-not $current) { continue }

    if (Start-MonitoredService -Service $current) {
        $startedServices += $current.Name
    }
}

# --- Final re-check ---
if ($startedServices.Count -gt 0) {
    Write-Log "$($startedServices.Count) service(s) were started. Waiting $verifyWaitSeconds seconds before verifying..." "INFO"
    Start-Sleep -Seconds $verifyWaitSeconds
} else {
    Write-Log "No Veeam services needed to be started." "INFO"
}

$notRunning = @(Get-MatchingServices -Patterns @($servicePattern) |
    Where-Object { $excludeServices -notcontains $_.Name } |
    Where-Object { $_.State -ne 'Running' -and (Test-ShouldStart -Service $_) })

if ($notRunning.Count -gt 0) {
    foreach ($service in $notRunning) {
        Write-Log "Service '$($service.DisplayName) ($($service.Name))' is still not running (state: $($service.State))." "ERROR"
    }
} elseif ($startedServices.Count -gt 0) {
    Write-Log "All monitored Veeam services are now running." "SUCCESS"
}

Write-Log "Service status check completed." "INFO"