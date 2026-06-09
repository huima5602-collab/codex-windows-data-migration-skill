[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$TaskName = 'Codex-One-Time-Windows-Data-Migration',

    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
$skillRoot = Split-Path -Parent $PSScriptRoot
$migrationScript = Join-Path $PSScriptRoot 'Invoke-DirectoryMigration.ps1'
$taskRoot = Join-Path $env:ProgramData "CodexMigration\$TaskName"
$taskConfig = Join-Path $taskRoot 'migration.json'
$taskScript = Join-Path $taskRoot 'Invoke-DirectoryMigration.ps1'

if (-not (Test-IsAdministrator)) {
    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"",
        '-ConfigPath', "`"$resolvedConfig`"",
        '-TaskName', "`"$TaskName`""
    )
    if ($Restart) {
        $arguments += '-Restart'
    }

    if ($PSCmdlet.ShouldProcess('Windows UAC', 'Request administrator elevation')) {
        Start-Process `
            -FilePath 'powershell.exe' `
            -Verb RunAs `
            -ArgumentList ($arguments -join ' ') `
            -Wait
    }
    return
}

if (-not $PSCmdlet.ShouldProcess(
    $TaskName,
    "Register a one-time SYSTEM startup migration task using $resolvedConfig"
)) {
    return
}

New-Item -ItemType Directory -Path $taskRoot -Force | Out-Null
Copy-Item -LiteralPath $resolvedConfig -Destination $taskConfig -Force
Copy-Item -LiteralPath $migrationScript -Destination $taskScript -Force

$action = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument (
        "-NoProfile -ExecutionPolicy Bypass -File `"$taskScript`" " +
        "-ConfigPath `"$taskConfig`" -Resume -CleanupTaskName `"$TaskName`""
    )
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries
$principal = New-ScheduledTaskPrincipal `
    -UserId 'SYSTEM' `
    -LogonType ServiceAccount `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description 'One-time validated Windows data migration before user logon.' `
    -Force | Out-Null

[pscustomobject]@{
    TaskName = $TaskName
    State = (Get-ScheduledTask -TaskName $TaskName).State
    TaskRoot = $taskRoot
    SourceSkill = $skillRoot
    RestartRequested = [bool]$Restart
}

if ($Restart) {
    shutdown.exe /r /t 30 /c 'Windows data migration will run before the next logon.'
}

