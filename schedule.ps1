# claude-code-backup — schedule.ps1
# Registers a Windows Scheduled Task that runs backup.sh daily.
#
# Usage (in PowerShell, as your user — no admin needed for per-user tasks):
#     .\schedule.ps1                    # default: daily at 09:00
#     .\schedule.ps1 -Hour 14 -Minute 30
#     .\schedule.ps1 -Uninstall         # remove the task
#     .\schedule.ps1 -IntervalHours 6   # run every 6 hours instead of daily

[CmdletBinding()]
param(
    [string]$TaskName = "ClaudeCodeBackup",
    [int]$Hour = 9,
    [int]$Minute = 0,
    [int]$IntervalHours = 0,       # 0 = daily at HH:MM, >0 = repeat every N hours
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

# --- find bash -------------------------------------------------------------
$GitBash = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $GitBash) {
    throw "Git Bash not found. Install Git for Windows or pass bash via PATH."
}
Write-Host "[schedule] bash: $GitBash"

# --- locate script dir -----------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BackupSh  = Join-Path $ScriptDir "backup.sh"
if (-not (Test-Path $BackupSh)) {
    throw "backup.sh not found next to schedule.ps1 (looked: $BackupSh)"
}

# --- uninstall -------------------------------------------------------------
if ($Uninstall) {
    Write-Host "[schedule] removing task '$TaskName'"
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
        Write-Host "[schedule] removed."
    } catch [Microsoft.PowerShell.Commands.ScheduleTaskNotFoundException] {
        Write-Host "[schedule] task not present — nothing to remove."
    }
    return
}

# --- build action ----------------------------------------------------------
# Convert Windows path -> bash path (C:\foo -> /c/foo)
$BashScriptDir = $ScriptDir -replace '\\','/' -replace '^([A-Z]):', '/$1'.ToLower()
$BashCmd = "cd '$BashScriptDir' && bash ./backup.sh >> '$BashScriptDir/backup.log' 2>&1"

$Action    = New-ScheduledTaskAction -Execute $GitBash -Argument "-lc '$BashCmd'"
$Settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
             -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

# --- trigger ---------------------------------------------------------------
if ($IntervalHours -gt 0) {
    $StartAt   = (Get-Date).Date.AddHours($Hour).AddMinutes($Minute)
    if ($StartAt -lt (Get-Date)) { $StartAt = $StartAt.AddDays(1) }
    $Trigger   = New-ScheduledTaskTrigger -Once -At $StartAt `
                 -RepetitionInterval (New-TimeSpan -Hours $IntervalHours)
    Write-Host "[schedule] trigger: every $IntervalHours h (first $StartAt)"
} else {
    $Trigger   = New-ScheduledTaskTrigger -Daily -At "$($Hour.ToString('00')):$($Minute.ToString('00'))"
    Write-Host "[schedule] trigger: daily at $($Hour):$($Minute.ToString('00'))"
}

# --- principal (current user, interactive — no password storage) -----------
$Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

# --- register --------------------------------------------------------------
$Existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($Existing) {
    Write-Host "[schedule] task exists, replacing."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger `
    -Principal $Principal -Settings $Settings -Description "Backs up ~/.claude and ~/.openclaude to private GitHub repos" | Out-Null

Write-Host "[schedule] registered. View via:"
Write-Host "    Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
Write-Host "    Start-ScheduledTask -TaskName '$TaskName'  # manual run"
