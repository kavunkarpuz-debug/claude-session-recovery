# Install.ps1 - Run once. Running it again is harmless (it overwrites).
#   powershell -ExecutionPolicy Bypass -File .\Install.ps1

$source = $PSScriptRoot

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
$block = @"
$blockHead
function cc        { & "$target\Start.ps1" @args }
function cc-tab    { & "$target\NewTab.ps1" @args }
function cc-back   { & "$target\Restore.ps1" -Mode Manual @args }
function cc-health { & "$target\Health.ps1" @args }
$blockTail
"@

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
Write-Host "[2/4] Commands added: cc, cc-tab, cc-back, cc-health" -ForegroundColor Green

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

# Method A: the PowerShell cmdlets.
# NOTE: -RepetitionDuration [TimeSpan]::MaxValue is not used; Task Scheduler rejects the
# value P99999999DT23H59M59S. Omitting the duration entirely means "repeat indefinitely".
try {
    $action  = New-ScheduledTaskAction -Execute $ps -Argument $argv
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
    $null = schtasks.exe /Create /TN $task /TR "$ps $argv" /SC MINUTE /MO 10 /F 2>&1
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

Write-Host ""
Write-Host "Done. Open a new PowerShell window." -ForegroundColor Cyan
Write-Host "  cc        -> start Claude in the current folder, with recording" -ForegroundColor Cyan
Write-Host "  cc-tab    -> open another folder as a tab in the SAME window" -ForegroundColor Cyan
Write-Host "  cc-back   -> list lost sessions and bring them back" -ForegroundColor Cyan
Write-Host "  cc-health -> check that the system is still working" -ForegroundColor Cyan
Write-Host ""
Write-Host "To remove: .\Uninstall.ps1" -ForegroundColor DarkGray
