# Veeam-Check-Services

## Overview & Purpose

A scheduled task that checks the Veeam services on a Veeam Backup & Replication server and starts any that are stopped.

### Why It's Needed
After a reboot, Veeam services can fail to start in a timely manner, usually because the configuration database (PostgreSQL or SQL Express on the same host) was not ready when they tried to initialise. This script checks the database first, then starts whatever Veeam services are down.

### What the Script Does
* **Checks the database first**: Looks for a local `postgresql*` or `MSSQL$VEEAM*` service. If one is stopped, starts it and waits **30 seconds**. If none is found, the database is assumed to be remote and the check moves on.
* **Finds Veeam services by name**: Monitors every service whose name starts with `Veeam`, so new services added by an upgrade are picked up without editing the script.
* **Starts stopped services**: `VeeamBackupSvc` first, then the rest alphabetically. Only services with an **Automatic** startup type are started; Manual and Disabled services are logged and skipped.
* **Verifies**: If anything had to be started, waits **30 seconds**, re-checks, and logs an `ERROR` for any service still not running.
* **Manages logs automatically**: Writes `Veeam_Service_Monitor_<date>.log` to the script folder and purges log files older than 5 days.

### Settings
These are variables at the top of `Check-Services.ps1`:

| Variable | Default | Purpose |
| --- | --- | --- |
| `$servicePattern` | `Veeam*` | Which services are monitored |
| `$priorityServices` | `VeeamBackupSvc` | Started first, in order |
| `$excludeServices` | *(empty)* | Service names to leave alone |
| `$startManualServices` | `$false` | Also start services set to Manual |
| `$databasePatterns` | `postgresql*`, `MSSQL$VEEAM*` | Database services checked first |
| `$databaseWaitSeconds` | `30` | Wait after starting a database service |
| `$verifyWaitSeconds` | `30` | Wait before the final re-check |

## Install / Remove Instructions

### Prerequisites
- Run PowerShell as an Administrator.
- Place the script in a folder such as `C:\Scripts\Veeam-Check-Services`. The task points at wherever the script is when you install it, and logs are written to the same folder.

### Install the Scheduled Task
From an elevated PowerShell session:

```powershell
Set-Location "C:\Scripts"
git clone https://github.com/bradmcdowell/Veeam-Check-Services.git
cd .\Veeam-Check-Services
Get-ChildItem -Path .\ -Recurse | Unblock-File
.\Check-Services.ps1 -AddTaskScheduler
```

This creates a scheduled task named `Veeam Check Services` that runs:
- At Windows startup after a 15-minute delay
- Daily at 05:49:25 AM
- As `NT AUTHORITY\SYSTEM` with highest privileges

### Remove the Scheduled Task
From an elevated PowerShell session:

```powershell
Set-Location "C:\Scripts\Veeam-Check-Services"
.\Check-Services.ps1 -RemoveTaskScheduler
```

### Run the Script Manually

```powershell
Set-Location "C:\Scripts\Veeam-Check-Services"
.\Check-Services.ps1
```

### Note on upgrades
A Veeam upgrade or patch stops the services while it runs. If one is likely to be in progress at 05:49 AM, disable the task first so the script does not start services mid-upgrade.