# Health.ps1 - "Is the system still working?"
#
# Why it exists:
#   This system reads Claude Code's UNDOCUMENTED internals (the fields of
#   ~\.claude\sessions\<pid>.json, the cwd inside transcripts). If a Claude Code release
#   changes their shape, nothing raises an error - the source layers quietly come back empty
#   and you only find out when you lose a session. This script makes that silent decay visible.
#
# Usage:  cc-health      (or)  .\Health.ps1
# Exit code: 0 = no problems, 1 = at least one FAIL.

[CmdletBinding()]
param()

# The Claude Code release the internals were last verified against. A different version is not
# a problem in itself; if the STRUCTURE checks below pass, the system works.
$VerifiedVersion = '2.1.278'

$installed = Join-Path $HOME '.claude\session-recovery'
$state     = Join-Path $installed 'state'
$registry  = Join-Path $HOME '.claude\sessions'
$projects  = Join-Path $HOME '.claude\projects'
$task      = 'Claude Session Snapshot'

$fail = 0
$warn = 0

function Line($status, $title, $detail) {
    switch ($status) {
        'ok'   { $mark = '[ OK ]'; $colour = 'Green' }
        'warn' { $mark = '[ !  ]'; $colour = 'Yellow'; $script:warn++ }
        'fail' { $mark = '[FAIL]'; $colour = 'Red';    $script:fail++ }
        default { $mark = '[ .. ]'; $colour = 'DarkGray' }
    }
    Write-Host ("{0} {1}" -f $mark, $title) -ForegroundColor $colour
    if ($detail) { Write-Host ("       {0}" -f $detail) -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "  CLAUDE SESSION RECOVERY - HEALTH CHECK" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm')" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------- claude CLI
$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) {
    Line fail "claude.exe not found on PATH" "Claude Code is not installed, or is outside PATH. Nothing will work."
} else {
    $version = $null
    try { $version = (& claude --version 2>&1 | Select-Object -First 1) -replace '[^0-9\.].*$', '' } catch { }
    if (-not $version) {
        Line warn "could not read the claude version" "The structure checks below still run."
    } elseif ($version -eq $VerifiedVersion) {
        Line ok "claude $version" "Internals were verified against this release."
    } else {
        Line warn "claude $version (verified against $VerifiedVersion)" "Probably fine - if the STRUCTURE checks below pass, the system works."
    }
}

# -------------------------------------------------------------- layer 0: snapshot
$snapshot = Join-Path $state 'snapshot.json'
if (-not (Test-Path -LiteralPath $snapshot)) {
    Line fail "layer 0 (snapshot) - file missing" "Expected: $snapshot  |  The scheduled task may never have run."
} else {
    try {
        $s     = Get-Content -LiteralPath $snapshot -Raw -Encoding UTF8 | ConvertFrom-Json
        $age   = ((Get-Date).ToUniversalTime() - [datetime]::Parse($s.time).ToUniversalTime()).TotalMinutes
        $count = @($s.sessions).Count
        if ($age -gt 25) {
            Line fail "layer 0 - snapshot is stale ($([int]$age) min old)" "It should refresh every 10 min. The scheduled task is not running; you will lose sessions on a clean restart."
        } elseif ($count -eq 0) {
            Line warn "layer 0 - fresh but empty" "No Claude session appears to be open. If one should be, check layer 1."
        } else {
            Line ok "layer 0 (snapshot) - $count session(s)" "Taken $([int]$age) min ago."
        }
    } catch {
        Line fail "layer 0 - snapshot unreadable" $_.Exception.Message
    }
}

# --------------------------------------------------- layer 1: claude's session registry
if (-not (Test-Path -LiteralPath $registry)) {
    Line fail "layer 1 (session registry) - folder missing" "Expected: $registry  |  This folder belongs to claude; its absence may mean the format changed."
} else {
    $records = @(Get-ChildItem -LiteralPath $registry -Filter *.json -File -ErrorAction SilentlyContinue)
    if ($records.Count -eq 0) {
        Line warn "layer 1 - no records" "Normal if no session is open. If one IS open, THE RECORD FORMAT MAY HAVE CHANGED."
    } else {
        # STRUCTURE CHECK: the test that actually catches silent decay.
        $required = 'cwd', 'sessionId', 'pid', 'procStart'
        $sound    = 0
        $missing  = @{}
        foreach ($r in $records) {
            try { $j = Get-Content -LiteralPath $r.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $gaps = @($required | Where-Object { -not $j.PSObject.Properties[$_] -or -not $j.$_ })
            if ($gaps.Count -eq 0) { $sound++ } else { foreach ($g in $gaps) { $missing[$g] = $true } }
        }
        if ($sound -eq 0) {
            Line fail "layer 1 - record format not recognised" "Missing field(s): $($missing.Keys -join ', '). Recovery after a crash will not work from this layer."
        } elseif ($sound -lt $records.Count) {
            Line warn "layer 1 - $sound/$($records.Count) records readable" "Missing field(s): $($missing.Keys -join ', ')"
        } else {
            Line ok "layer 1 (session registry) - $sound record(s)" "Fields present: $($required -join ', ')"
        }
    }
}

# ------------------------------------------------------------- layer 2: heartbeats
if (-not (Test-Path -LiteralPath $state)) {
    Line fail "layer 2 (heartbeat) - state folder missing" "Expected: $state  |  Install.ps1 has not been run."
} else {
    $hb    = @(Get-ChildItem -LiteralPath $state -Filter *.hb -File -ErrorAction SilentlyContinue)
    $stale = @($hb | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 60 })
    if ($stale.Count -gt 0) {
        Line warn "layer 2 - $($hb.Count) record(s), $($stale.Count) stale" "Some have not been written for an hour; the next restore will clean them up."
    } else {
        Line ok "layer 2 (heartbeat) - $($hb.Count) live record(s)" "Only sessions started with 'cc' appear here."
    }
}

# ------------------------------------------------------------ layer 3: transcripts
if (-not (Test-Path -LiteralPath $projects)) {
    Line fail "layer 3 (transcripts) - folder missing" "Expected: $projects"
} else {
    $newest = Get-ChildItem -LiteralPath $projects -Filter *.jsonl -File -Recurse -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $newest) {
        Line warn "layer 3 - no transcript found" "The last-resort layer is empty."
    } else {
        # STRUCTURE CHECK: is there a line carrying cwd? If not, the format changed.
        # The first lines (mode, permission-mode, atis-latch...) carry no cwd; the first one
        # usually arrives around line 5-10. Read as a stream and stop on the first hit -
        # transcripts can be hundreds of MB.
        $cwd = $null
        try {
            $n = 0
            foreach ($line in [IO.File]::ReadLines($newest.FullName)) {
                if (++$n -gt 200) { break }
                if (-not $line -or $line -notmatch '"cwd"') { continue }
                try { $o = $line | ConvertFrom-Json } catch { continue }
                if ($o.cwd) { $cwd = $o.cwd; break }
            }
        } catch { }
        if ($cwd) {
            Line ok "layer 3 (transcripts) - readable" "Example: $(Split-Path -Leaf $cwd)"
        } else {
            Line fail "layer 3 - no 'cwd' in the transcript" "The format changed. The last-resort layer cannot recover folder paths."
        }
    }
}

# --------------------------------------------------------------- scheduled task
$registered = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if (-not $registered) {
    Line fail "scheduled task missing: $task" "Run Install.ps1 again. Without it layer 0 never refreshes."
} else {
    $info     = Get-ScheduledTaskInfo -TaskName $task -ErrorAction SilentlyContinue
    $interval = $registered.Triggers[0].Repetition.Interval
    if ($registered.State -eq 'Disabled') {
        Line fail "scheduled task is DISABLED" "Enable it: Enable-ScheduledTask '$task'"
    } elseif ($info -and $info.LastTaskResult -ne 0) {
        Line warn "scheduled task returns error code $($info.LastTaskResult)" "Last run: $($info.LastRunTime)"
    } else {
        Line ok "scheduled task running ($interval)" "Last: $($info.LastRunTime)  |  Next: $($info.NextRunTime)"
    }
}

# -------------------------------------------------------------- startup shortcut
# GetFolderPath can return an empty string when the shell folders are redirected or the
# profile is unusual; Join-Path would then throw, so every use of it is guarded.
$startup = [Environment]::GetFolderPath('Startup')
if (-not $startup) {
    Line warn "startup folder could not be resolved" "Cannot tell whether the boot shortcut is in place."
} else {
    $lnk = Join-Path $startup 'Claude Session Restore.lnk'
    if (Test-Path -LiteralPath $lnk) {
        Line ok "startup shortcut in place" "The restore screen appears automatically at Windows startup."
    } else {
        Line warn "startup shortcut missing" "No automatic screen; 'cc-back' still works. Install.ps1 puts it back."
    }
}

# -------------------------------------------------------------- profile commands
$documents = [Environment]::GetFolderPath('MyDocuments')
$profiles  = @(
    $PROFILE
    if ($documents) {
        Join-Path $documents 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
        Join-Path $documents 'PowerShell\Microsoft.PowerShell_profile.ps1'
    }
) | Where-Object { $_ } | Select-Object -Unique

$withBlock = @($profiles | Where-Object {
    (Test-Path -LiteralPath $_) -and ([IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) -match '>>> ClaudeSessionRecovery >>>')
})
if ($withBlock.Count -gt 0) {
    Line ok "commands defined in $($withBlock.Count) profile(s)" "cc  |  cc-tab  |  cc-back  |  cc-health"
} else {
    Line fail "no command block in any profile" "Run Install.ps1 again."
}

# ------------------------------------------------------------------- helpers
if (Get-Command wt -ErrorAction SilentlyContinue) {
    Line ok "Windows Terminal (wt) present" "Sessions open as tabs in a single window."
} else {
    Line warn "Windows Terminal (wt) not found" "Each session opens in its own PowerShell window."
}

$policy = try { Get-ExecutionPolicy } catch { $null }
if ($policy -in 'Restricted', 'AllSigned') {
    Line fail "execution policy: $policy" "Fix: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}

# -------------------------------------------------------------------- summary
Write-Host ""
if ($fail -eq 0 -and $warn -eq 0) {
    Write-Host "  System healthy." -ForegroundColor Green
} elseif ($fail -eq 0) {
    Write-Host "  System works. $warn warning(s) above, in yellow." -ForegroundColor Yellow
} else {
    Write-Host "  $fail failure(s), $warn warning(s). Apply the fix shown on the red lines." -ForegroundColor Red
}
Write-Host ""

exit ([int]($fail -gt 0))
