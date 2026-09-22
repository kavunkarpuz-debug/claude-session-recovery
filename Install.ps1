# Install.ps1 - Run once. Running it again is harmless (it overwrites).
#   powershell -ExecutionPolicy Bypass -File .\Install.ps1
#   .\Install.ps1 -Prefix ccode    use different command names
#   .\Install.ps1 -Force           install even though a name collides with something

[CmdletBinding()]
param(
    # The command names are built from this:
    #   <prefix>  <prefix>-tab  <prefix>-back  <prefix>-health
    [ValidatePattern('^[A-Za-z][A-Za-z0-9]*$')]
    [string]$Prefix = 'cc',

    [switch]$Force
)

$source = $PSScriptRoot

# ---------------------------------------------------------------- prerequisites
# Not fatal: you may be installing before Claude Code, or onto a machine where it
# lands on PATH later. But say it now rather than let 'cc' fail mysteriously.
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "WARNING: claude.exe is not on PATH." -ForegroundColor Yellow
    Write-Host "         Install Claude Code first, or the commands below will not start anything." -ForegroundColor Yellow
    Write-Host "         https://claude.com/claude-code" -ForegroundColor Yellow
    Write-Host ""
}

# The working copy lives under .claude: the "do not touch" rule lands in one place, and
# state\ - written every 10 minutes - does not generate cloud-sync traffic.
# The source copy (this folder) stays wherever you cloned it; that is the part worth backing up.
$target = Join-Path $HOME '.claude\session-recovery'
New-Item -ItemType Directory -Force -Path $target, (Join-Path $target 'state') | Out-Null

$marker    = 'ClaudeSessionRecovery'
$blockHead = "# >>> $marker >>>"
$blockTail = "# <<< $marker <<<"

# GetFolderPath can return an empty string when the shell folders are redirected; Join-Path
# would then throw, so every use of it is guarded.
$documents = [Environment]::GetFolderPath('MyDocuments')
$startup   = [Environment]::GetFolderPath('Startup')
$profiles  = @(
    $PROFILE
    if ($documents) {
        Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1'
    }
) | Where-Object { $_ } | Select-Object -Unique

# ---------------------------------------------------------------------------------
# [0/4] Upgrade from the pre-rename layout.
# Earlier versions installed into ~\.claude\oturum-kurtarma with Turkish file, task and
# command names. Left in place they would mean two scheduled tasks, two startup shortcuts
# and two profile blocks all doing the same job. The old folder itself is NOT deleted:
# sessions started from it may still be running and writing heartbeats there.
# ---------------------------------------------------------------------------------
$legacyDir  = Join-Path $HOME '.claude\oturum-kurtarma'
$legacyTask = 'Claude Oturum Anlik Goruntu'
$legacyLnk  = $(if ($startup) { Join-Path $startup 'Claude Oturum Geri Yukle.lnk' } else { $null })
$legacyHead = '# >>> ClaudeOturum >>>'
$legacyTail = '# <<< ClaudeOturum <<<'

$legacyFound = (Test-Path -LiteralPath $legacyDir) -or
               ($legacyLnk -and (Test-Path -LiteralPath $legacyLnk)) -or
               ($null -ne (Get-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue))

# The teardown itself runs at the END, once the new scheduled task is confirmed. Removing the
# old safety net before the new one is verified would leave nothing running if registration
# were refused.

# 1. Put the scripts in place, clear the "downloaded from the internet" mark
foreach ($f in 'Start.ps1', 'Restore.ps1', 'Snapshot.ps1', 'NewTab.ps1', 'Health.ps1') {
    Copy-Item -LiteralPath (Join-Path $source $f) -Destination $target -Force
    Unblock-File -LiteralPath (Join-Path $target $f)
}
Write-Host "[1/4] Scripts copied: $target" -ForegroundColor Green

# 2. Add the commands to the PowerShell profile
#    Names come from -Prefix so they can be changed if 'cc' is taken (it is a C compiler on
#    machines with a Unix toolchain, and PowerShell resolves Function before Application -
#    our function would silently shadow it).
$commands = [ordered]@{
    "$Prefix"        = @('Start.ps1',   '')
    "$Prefix-tab"    = @('NewTab.ps1',  '')
    "$Prefix-back"   = @('Restore.ps1', ' -Mode Manual')
    "$Prefix-health" = @('Health.ps1',  '')
}

$clash = @()
foreach ($name in $commands.Keys) {
    $existing = Get-Command $name -ErrorAction SilentlyContinue
    # A Function by that name is almost certainly our own block from a previous install.
    if ($existing -and $existing.CommandType -ne 'Function') {
        $clash += "$name -> $($existing.CommandType) $($existing.Source)"
    }
}
if ($clash.Count -gt 0 -and -not $Force) {
    Write-Host ""
    Write-Host "STOPPED: these command names are already taken:" -ForegroundColor Red
    foreach ($c in $clash) { Write-Host "  $c" -ForegroundColor Red }
    Write-Host ""
    Write-Host "  Defining them would shadow the existing commands. Pick another prefix:" -ForegroundColor Yellow
    Write-Host "    .\Install.ps1 -Prefix ccode" -ForegroundColor Yellow
    Write-Host "  Or override deliberately:  .\Install.ps1 -Force" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Nothing was written to any profile. The scripts are in place at:" -ForegroundColor DarkGray
    Write-Host "  $target" -ForegroundColor DarkGray
    return
}

$pad   = ($commands.Keys | Measure-Object -Property Length -Maximum).Maximum
$lines = foreach ($name in $commands.Keys) {
    'function {0} {{ & "{1}\{2}"{3} @args }}' -f $name.PadRight($pad), $target, $commands[$name][0], $commands[$name][1]
}
$block = (@($blockHead) + $lines + @($blockTail)) -join "`r`n"

foreach ($p in $profiles) {
    $dir = Split-Path -Parent $p
    # do not create the pwsh 7 profile folder if pwsh is not installed
    if (-not (Test-Path -LiteralPath $dir)) {
        if ($p -ne $PROFILE) { continue }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $content = ''
    if (Test-Path -LiteralPath $p) {
        # Back it up first
        Copy-Item -LiteralPath $p -Destination "$p.sessionrecovery-backup" -Force
        # IMPORTANT: read as explicit UTF-8. Windows PowerShell 5.1 defaults to ANSI; reading a
        # BOM-less UTF-8 profile as ANSI and writing it back corrupts non-ASCII characters
        # permanently.
        $content = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    }

    # drop our own block and anything left by earlier versions
    foreach ($pair in @(@($blockHead, $blockTail), @($legacyHead, $legacyTail))) {
        $content = [regex]::Replace($content,
            "(?s)\r?\n?$([regex]::Escape($pair[0])).*?$([regex]::Escape($pair[1]))", '')
    }
    $content = [regex]::Replace($content, "(?m)^\s*#\s*Claude Code oturum kaydi\s*\r?\n", '')
    $content = [regex]::Replace($content, "(?m)^\s*function cc \{.*\}\s*\r?\n?", '')

    # Write UTF-8 WITH a BOM: the content is preserved and PowerShell 5.1 reads it correctly
    [IO.File]::WriteAllText($p, ($content.TrimEnd() + "`r`n`r`n" + $block + "`r`n"), (New-Object Text.UTF8Encoding($true)))
    Write-Host "      profile updated: $p" -ForegroundColor DarkGray
}
Write-Host "[2/4] Commands added: $(($commands.Keys) -join ', ')" -ForegroundColor Green

# 3. Run Restore.ps1 (Auto mode) at Windows startup
if ($startup) {
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $startup 'Claude Session Restore.lnk'))
    $lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
    $lnk.Arguments  = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$target\Restore.ps1`" -Mode Auto"
    $lnk.Save()
    Write-Host "[3/4] Startup shortcut created." -ForegroundColor Green
} else {
    Write-Host "[3/4] Startup folder could not be resolved - no shortcut created." -ForegroundColor Yellow
    Write-Host "      The restore screen will not appear automatically; use 'cc-back'." -ForegroundColor Yellow
}

# 4. Snapshot task: save the list of open sessions every few minutes.
#    Without it, a clean restart makes claude delete its own records and the "what was open"
#    information disappears.
$task = 'Claude Session Snapshot'
$ps   = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$argv = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$target\Snapshot.ps1`""

# Take a snapshot right away - whether or not the task registers, what is open now is preserved
& "$target\Snapshot.ps1"

Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

# ---- The task must not flash a console window on screen ----
# Task Scheduler launching powershell.exe directly creates a console host inside your
# interactive session, and Windows shows it for a fraction of a second every time the task
# fires - every 10 minutes, all day. -WindowStyle Hidden does not prevent it: the host exists
# before the script can hide anything.
#
# Two ways out. Running the task as S4U ("whether the user is logged on or not") puts it in a
# non-interactive session, but registering that needs administrator rights. The fix that works
# for a normal account is wscript.exe: it is a GUI-subsystem program, so it has no console of
# its own, and it can start powershell already hidden.
$hiddenVbs = Join-Path $target 'RunHidden.vbs'
$command   = "$ps $argv"
Set-Content -LiteralPath $hiddenVbs -Encoding ASCII -Value @"
' Generated by Install.ps1 - runs the snapshot without a console window.
' wscript.exe has no console of its own, and window style 0 starts the process hidden,
' so nothing flashes on screen. The third argument, False, means "do not wait".
Set sh = CreateObject("WScript.Shell")
sh.Run "$($command -replace '"', '""')", 0, False
"@

$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$hidden  = Test-Path -LiteralPath $wscript      # Windows Script Host can be disabled by policy
if ($hidden) {
    $exec    = $wscript
    $execArg = "//nologo `"$hiddenVbs`""
} else {
    $exec    = $ps
    $execArg = $argv
}

# Method A: the PowerShell cmdlets.
# NOTE: -RepetitionDuration [TimeSpan]::MaxValue is not used; Task Scheduler rejects the
# value P99999999DT23H59M59S. Omitting the duration entirely means "repeat indefinitely".
try {
    $action  = New-ScheduledTaskAction -Execute $exec -Argument $execArg
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
               -RepetitionInterval (New-TimeSpan -Minutes 10)
    $set     = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
               -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Settings $set `
        -Description 'Records the list of open Claude sessions, for recovery after an unexpected shutdown.' `
        -ErrorAction Stop | Out-Null
} catch {
    Write-Host "      cmdlet method failed ($($_.Exception.Message.Split([char]10)[0])), trying schtasks..." -ForegroundColor DarkGray
}

# Method B: schtasks.exe if the cmdlets did not take
if (-not (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue)) {
    $null = schtasks.exe /Create /TN $task /TR "$exec $execArg" /SC MINUTE /MO 10 /F 2>&1
}

# ---- Did it really register? VERIFY before claiming success ----
$registered = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if ($registered) {
    Start-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    $interval = $registered.Triggers[0].Repetition.Interval
    $count    = 0
    $snapshot = Join-Path $target 'state\snapshot.json'
    if (Test-Path -LiteralPath $snapshot) {
        $count = @((Get-Content -LiteralPath $snapshot -Raw -Encoding UTF8 | ConvertFrom-Json).sessions).Count
    }
    Write-Host "[4/4] Snapshot task REGISTERED. Repeat interval: $interval" -ForegroundColor Green
    Write-Host "      Open sessions recorded right now: $count" -ForegroundColor Green
    # Say which way it ended up, because the difference is visible on screen.
    if ($hidden) {
        Write-Host "      Runs hidden - no console window will flash." -ForegroundColor Green
    } else {
        Write-Host "      NOTE: Windows Script Host is unavailable, so the task runs powershell" -ForegroundColor Yellow
        Write-Host "      directly and a console window will flash briefly every $interval." -ForegroundColor Yellow
        Write-Host "      Harmless, but expect to see it." -ForegroundColor Yellow
    }
} else {
    Write-Host "[4/4] Snapshot task COULD NOT BE REGISTERED." -ForegroundColor Red
    Write-Host "      The system still works, but on a clean restart long-idle sessions may be" -ForegroundColor Yellow
    Write-Host "      missed. A snapshot was taken just now; it will not refresh." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------------
# Upgrade from the pre-rename layout. Earlier versions installed into
# ~\.claude\oturum-kurtarma with Turkish file, task and command names. Left in place they
# would mean two scheduled tasks and two startup shortcuts doing the same job. (The old
# profile block is already gone - step 2 strips it along with ours.)
#
# This runs LAST and only if the new task registered: the old setup stays untouched while
# the new one is unproven, so a refused registration never leaves you with nothing.
# The old folder itself is NOT deleted - sessions started from it may still be running and
# writing heartbeats there.
# ---------------------------------------------------------------------------------
if ($legacyFound) {
    if (-not $registered) {
        Write-Host ""
        Write-Host "      An older installation is still in place and was LEFT ALONE, because the" -ForegroundColor Yellow
        Write-Host "      new task could not be registered. Fix that first, then run this again." -ForegroundColor Yellow
    } else {
        Write-Host ""
        if (Get-ScheduledTask -TaskName $legacyTask -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $legacyTask -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host "      old scheduled task removed: $legacyTask" -ForegroundColor DarkGray
        }
        if ($legacyLnk -and (Test-Path -LiteralPath $legacyLnk)) {
            Remove-Item -LiteralPath $legacyLnk -Force -ErrorAction SilentlyContinue
            Write-Host "      old startup shortcut removed" -ForegroundColor DarkGray
        }
        Write-Host "      Upgraded from the previous layout." -ForegroundColor Green
        if (Test-Path -LiteralPath $legacyDir) {
            Write-Host "      The old folder was left in place - sessions already running still write to it:" -ForegroundColor DarkGray
            Write-Host "      $legacyDir" -ForegroundColor DarkGray
            Write-Host "      You can delete it once those windows have been closed." -ForegroundColor DarkGray
        }
    }
}

# The profile can only load if script execution is allowed
$policy = try { Get-ExecutionPolicy } catch { $null }
if ($policy -in 'Restricted', 'AllSigned') {
    Write-Host ""
    Write-Host "NOTE: your execution policy is '$policy'. For 'cc' to work:" -ForegroundColor Yellow
    Write-Host "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" -ForegroundColor Yellow
    Write-Host "If company policy blocks it you will get an error; then you need your IT team." -ForegroundColor Yellow
}

# ---- Prove it works rather than assume it: run the health check and show the result ----
Write-Host ""
Write-Host "Verifying the installation..." -ForegroundColor Cyan
& (Join-Path $target 'Health.ps1')

Write-Host "Done. Open a new PowerShell window." -ForegroundColor Cyan
$pad2 = ($commands.Keys | Measure-Object -Property Length -Maximum).Maximum
Write-Host ("  {0} -> start Claude in the current folder, with recording" -f "$Prefix".PadRight($pad2))        -ForegroundColor Cyan
Write-Host ("  {0} -> open another folder as a tab in the SAME window"    -f "$Prefix-tab".PadRight($pad2))    -ForegroundColor Cyan
Write-Host ("  {0} -> list lost sessions and bring them back"             -f "$Prefix-back".PadRight($pad2))   -ForegroundColor Cyan
Write-Host ("  {0} -> check that the system is still working"             -f "$Prefix-health".PadRight($pad2)) -ForegroundColor Cyan
Write-Host ""
Write-Host "To remove: .\Uninstall.ps1" -ForegroundColor DarkGray
