# Restore.ps1 - Brings back the Claude sessions that were open at shutdown.
#
# Modes:
#   -Mode Auto   : runs hidden at Windows startup. If there are candidates it reopens itself
#                  visibly in Ask mode.
#   -Mode Ask    : shows the list, you pick, it opens. (The screen Auto mode brings up.)
#   -Mode Manual : the "cc-back" command. No boot filter; lists every session active within
#                  the last -Hours that is not open right now.
#   -Mode List   : read-only diagnostic. Opens nothing, deletes nothing.
#
# THE TIME WINDOW APPLIES TO THE TRANSCRIPT LAYER ONLY.
# "Was it open at shutdown" is a LIVENESS question, not a recency question. A session left
# untouched for a week but still open must come back too. Sources 0, 1 and 2 below are proof
# that it WAS open, so the -Hours window is not applied to them (only a 30-day sanity limit).
# Only source 3 is subject to the window, because it cannot tell open from closed.
#
# Candidates are collected from four independent sources (in priority order):
#   0. state\snapshot-previous.json -> the snapshot Snapshot.ps1 took before shutdown. MOST
#      RELIABLE. Without it a clean restart leaves no trace, because claude deletes its own
#      registry entry on the way out.
#   1. ~\.claude\sessions\<pid>.json -> Claude's own live session registry. Gives cwd +
#      sessionId + pid. Deleted on a clean exit, SURVIVES a crash or power loss - exactly the
#      trace we want. pid + procStart together settle whether it is still running (PIDs get
#      reused after a reboot).
#   2. state\*.json -> heartbeat records for sessions started with "cc". Tells the KIND of
#      shutdown (hard crash vs. window closed).
#   3. ~\.claude\projects\*\*.jsonl -> transcripts. Last resort if source 1 was cleaned up.
#      NOTE: cwd inside a transcript can drift with a shell "cd", so the FIRST cwd line is used.
# Sources are merged on the folder path.

param(
    [ValidateSet('Auto', 'Ask', 'Manual', 'List')][string]$Mode = 'Ask',
    [int]$Hours = 12,
    [switch]$PreviousBoot   # List mode only: apply the boot filter as well (for diagnostics)
)

$ErrorActionPreference = 'Continue'
$root     = $PSScriptRoot
$state    = Join-Path $root 'state'
$starter  = Join-Path $root 'Start.ps1'
$log      = Join-Path $root 'restore.log'
$projects = Join-Path $HOME '.claude\projects'
$registry = Join-Path $HOME '.claude\sessions'
$snapNow  = Join-Path $state 'snapshot.json'
$snapPrev = Join-Path $state 'snapshot-previous.json'

function Log($m) {
    try { Add-Content -LiteralPath $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  [{1}] {2}" -f (Get-Date), $Mode, $m) } catch { }
}
function B64($s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }

# Canonicalise a path. Two traps:
#   1. Resolve-Path can return "Microsoft.PowerShell.Core\FileSystem::\\server\..." for UNC.
#   2. Non-ASCII characters can arrive decomposed (NFD) depending on the source.
# Either one makes the same folder look like two separate candidates.
function CleanPath($path) {
    if (-not $path) { return $path }
    $p = $path -replace '^Microsoft\.PowerShell\.Core\\FileSystem::', ''
    $p = $p.TrimEnd('\')
    try { $p = $p.Normalize([Text.NormalizationForm]::FormC) } catch { }
    return $p
}
function Key($path) { (CleanPath $path).ToLowerInvariant() }

# The SAME computation Start.ps1 uses for the folder id in its record names.
# Needed to locate the "/exit" tombstone.
function FolderId($path) {
    $sha   = [Security.Cryptography.SHA1]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Key $path)))
    return (-join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') }))
}

function ReadStamp($p) {
    if (Test-Path -LiteralPath $p) {
        try {
            [datetime]::Parse((Get-Content -LiteralPath $p -Raw).Trim(),
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        } catch { $null }
    }
}

# Pull the working folder from the START of a transcript (a later cwd may have drifted via cd)
function ReadCwd($p) {
    try { $lines = @(Get-Content -LiteralPath $p -TotalCount 60 -Encoding UTF8 -ErrorAction Stop) } catch { return $null }
    foreach ($line in $lines) {
        $m = [regex]::Match($line, '"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { return ($m.Groups[1].Value -replace '\\\\', '\') }
    }
    return $null
}

# Is a process still running? The start time is verified too, because a PID may have been reused.
function ProcessAlive($processId, $procStart) {
    if (-not $processId) { return $false }
    $p = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if (-not $procStart) { return $true }
    try { return ($p.StartTime.ToFileTime().ToString() -eq $procStart.ToString()) } catch { return $true }
}

# Is the window that OWNS this state record still alive?
function RecordAlive($record, $thisBootUtc) {
    if (-not $record.pid) { return $false }
    if ($record.procStart) { return (ProcessAlive $record.pid $record.procStart) }
    if ($record.boot -ne $thisBootUtc.ToString('o')) { return $false }
    return ($null -ne (Get-Process -Id $record.pid -ErrorAction SilentlyContinue))
}

# ------------------------------------------------------------ candidate collection
function CollectCandidates($thisBootUtc, $limitUtc, $previousBootOnly) {
    $result = [ordered]@{}
    $stale  = @()
    $live   = New-Object 'System.Collections.Generic.HashSet[string]'
    $oldest = (Get-Date).ToUniversalTime().AddDays(-30)   # sanity limit

    # PRE-PASS: collect the folders that are LIVE right now, before anything else.
    # Without this, source 0 (the snapshot) would keep offering a session that has already
    # been reopened - its new pid does not match the one in the old snapshot, so it looks dead.
    if (Test-Path -LiteralPath $registry) {
        foreach ($d in Get-ChildItem -LiteralPath $registry -Filter *.json -File -ErrorAction SilentlyContinue) {
            try { $r = Get-Content -LiteralPath $d.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if ($r.cwd -and (ProcessAlive $r.pid $r.procStart)) { [void]$live.Add((Key $r.cwd)) }
        }
    }

    # 0) Snapshot: the last known state before shutdown. NOT subject to the time window.
    foreach ($file in @($snapPrev, $snapNow)) {
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try { $snap = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $snap.sessions) { continue }
        # A snapshot from THIS boot cannot supply candidates in "previous boot" mode
        if ($previousBootOnly -and $snap.boot -eq $thisBootUtc.ToString('o')) { continue }

        $when = $thisBootUtc
        try { $when = [datetime]::Parse($snap.time, [Globalization.CultureInfo]::InvariantCulture,
                                        [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { }

        foreach ($s in $snap.sessions) {
            if (-not $s.path) { continue }
            $path = CleanPath $s.path
            $k = Key $path
            if ($live.Contains($k) -or $result.Contains($k)) { continue }
            if (ProcessAlive $s.pid $s.procStart) { [void]$live.Add($k); continue }
            if (-not (Test-Path -LiteralPath $path)) { continue }

            $result[$k] = [pscustomobject]@{
                Path      = $path
                Name      = (Split-Path -Leaf $path)
                When      = $when
                SessionId = $s.sessionId
                Kind      = 'left open'
            }
        }
    }

    # 1) Claude's live session registry  (most reliable source)
    if (Test-Path -LiteralPath $registry) {
        foreach ($d in Get-ChildItem -LiteralPath $registry -Filter *.json -File -ErrorAction SilentlyContinue) {
            try { $r = Get-Content -LiteralPath $d.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if (-not $r.cwd) { continue }
            $path = CleanPath $r.cwd
            $k = Key $path

            if (ProcessAlive $r.pid $r.procStart) { [void]$live.Add($k); continue }   # open now, leave alone
            # Another live session exists in this folder. What we hold is a stale entry that
            # could not be cleaned up at shutdown (claude cannot always tidy up on restart).
            # Do not count it as a candidate.
            if ($live.Contains($k)) { continue }

            # Last activity of the session: trust the registry's own stamp. The file mtime may
            # have been touched by something else (cleanup, sync), so do not rely on it.
            $when = $null
            if ($r.updatedAt) {
                try { $when = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$r.updatedAt).UtcDateTime } catch { }
            }
            if (-not $when) { $when = $d.LastWriteTimeUtc }
            if ($previousBootOnly -and $when -ge $thisBootUtc) { continue }
            if ($when -lt $oldest) { continue }   # not the window, just the 30-day limit
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if ($result.Contains($k)) { continue }

            $result[$k] = [pscustomobject]@{
                Path      = $path
                Name      = (Split-Path -Leaf $path)
                When      = $when
                SessionId = $r.sessionId
                Kind      = 'left open'
            }
        }
    }

    # 2) state records
    if (Test-Path -LiteralPath $state) {
        foreach ($j in Get-ChildItem -LiteralPath $state -Filter *.json -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -notlike 'snapshot*' }) {
            $base = Join-Path $state $j.BaseName
            try { $r = Get-Content -LiteralPath $j.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if (-not $r.path) { continue }

            $closed = ReadStamp "$base.closed"
            $when   = @($closed, (ReadStamp "$base.hb")) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
            if (-not $when) { continue }

            $path = CleanPath $r.path
            $k = Key $path

            # First check the record's OWN window: if it lives, the record stands and the
            # folder counts as live.
            if (RecordAlive $r $thisBootUtc) { [void]$live.Add($k); continue }

            # Its own window is gone: the record can be consumed. This holds even if another
            # session is open in the folder - otherwise dead records become permanent litter.
            $stale += $base

            if ($live.Contains($k)) { continue }                     # another live session in this folder
            if ($previousBootOnly -and $when -ge $thisBootUtc) { continue }
            if ($when -lt $oldest) { continue }   # not the window, just the 30-day limit
            if (-not (Test-Path -LiteralPath $path)) { continue }

            $kind = $(if ($closed) { 'window closed' } else { 'HARD CRASH' })
            if ($result.Contains($k)) {
                # enrich the registry entry: the heartbeat knows the kind of shutdown better
                $result[$k].Kind = $kind
                if ($when -gt $result[$k].When) { $result[$k].When = $when }
                continue
            }
            $result[$k] = [pscustomobject]@{
                Path      = $path
                Name      = (Split-Path -Leaf $path)
                When      = $when
                SessionId = $null
                Kind      = $kind
            }
        }
    }

    # 3) transcript scan (last resort)
    if (Test-Path -LiteralPath $projects) {
        $files = Get-ChildItem -LiteralPath $projects -Directory -ErrorAction SilentlyContinue |
                 ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue } |
                 Where-Object {
                     $_.LastWriteTimeUtc -ge $limitUtc -and
                     ((-not $previousBootOnly) -or ($_.LastWriteTimeUtc -lt $thisBootUtc))
                 } |
                 Sort-Object LastWriteTimeUtc -Descending

        foreach ($d in $files) {
            $path = CleanPath (ReadCwd $d.FullName)
            if (-not $path -or -not (Test-Path -LiteralPath $path)) { continue }
            $k = Key $path
            if ($live.Contains($k)) { continue }

            # Was it deliberately closed with "/exit"? A transcript cannot tell open from
            # closed; if the stamp is NEWER than the transcript the folder was closed on
            # purpose, so do not offer it.
            $tombstone = Join-Path $state ((FolderId $path) + '.exit')
            if (Test-Path -LiteralPath $tombstone) {
                $ts = ReadStamp $tombstone
                if ($ts -and $ts -ge $d.LastWriteTimeUtc) { continue }
            }
            if ($result.Contains($k)) {
                if (-not $result[$k].SessionId) { $result[$k].SessionId = $d.BaseName }   # newest transcript
                continue
            }
            $result[$k] = [pscustomobject]@{
                Path      = $path
                Name      = (Split-Path -Leaf $path)
                When      = $d.LastWriteTimeUtc
                SessionId = $d.BaseName
                Kind      = 'transcript'
            }
        }
    }

    return [pscustomobject]@{
        Candidates = @($result.Values | Sort-Object When -Descending)
        Stale      = $stale
    }
}

function CleanupStale($staleRecords) {
    foreach ($b in $staleRecords) {
        Remove-Item -LiteralPath "$b.json", "$b.hb", "$b.closed" -ErrorAction SilentlyContinue
    }
    # The previous boot's snapshot has been consumed. If it is not deleted the same sessions
    # get offered again every time; once the user has decided, its job as evidence is done.
    Remove-Item -LiteralPath $snapPrev -Force -ErrorAction SilentlyContinue

    # Sweep orphaned .hb / .closed files that have no .json. Those are only ever reached by
    # walking *.json, so nothing else would clean them up. The one-hour staleness guard keeps
    # a live window that is still writing safe.
    $cutoff = (Get-Date).AddHours(-1)
    foreach ($orphan in Get-ChildItem -LiteralPath $state -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -eq '.hb' -or $_.Extension -eq '.closed' }) {
        $owner = Join-Path $state ($orphan.BaseName + '.json')
        if ((-not (Test-Path -LiteralPath $owner)) -and $orphan.LastWriteTime -lt $cutoff) {
            Remove-Item -LiteralPath $orphan.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# ------------------------------------------------------------------ open the sessions
# NOTE: naming matters here. PowerShell resolves commands Alias > Function > Cmdlet, so a
# function whose name collides with a built-in alias is never called - the call silently goes
# to a cmdlet instead. That is a real bug this project already hit once; see the guard below.
function OpenSessions($selected) {
    $parts = foreach ($c in $selected) {
        $argv = "-B64 $(B64 $c.Path)"
        if ($c.SessionId) { $argv += " -Resume $($c.SessionId)" }
        # ';' is a COMMAND SEPARATOR on the wt command line, and tabs are already joined with
        # ' ; '. A ';' in a folder name would split the command in the wrong place; the title
        # is cosmetic, so strip it.
        $title = $c.Name -replace '[;"]', '-'
        "new-tab --title `"$title`" --suppressApplicationTitle powershell -NoExit -ExecutionPolicy Bypass -File `"$starter`" $argv"
    }
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        # "-w 0" = the most recently used window. Without it wt decides on its own default and,
        # depending on the calling context, may open a NEW WINDOW. At boot, when no window
        # exists, -w 0 creates one anyway - so it is correct in both cases.
        Start-Process wt.exe -ArgumentList ('-w 0 ' + ($parts -join ' ; '))
    } else {
        foreach ($c in $selected) {
            # NOTE: the path is NOT wrapped in quotes. When Start-Process -ArgumentList gets an
            # array it quotes elements containing spaces itself; adding quotes by hand produces
            # double quoting and powershell cannot find the file.
            $argv = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $starter, '-B64', (B64 $c.Path))
            if ($c.SessionId) { $argv += @('-Resume', $c.SessionId) }
            Start-Process powershell -ArgumentList $argv
        }
    }
    Log ("Opened: " + (($selected | ForEach-Object { $_.Name }) -join ', '))

    # It takes about a minute for newly opened sessions to appear in Claude's registry. Waiting
    # for the scheduled task (10 min) would leave the snapshot in that interval EMPTY; a crash
    # right then would make layer 0 claim "nothing was open". A delayed refresh closes the gap.
    $snapshotScript = Join-Path $root 'Snapshot.ps1'
    if (Test-Path -LiteralPath $snapshotScript) {
        Start-Process powershell -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
            "Start-Sleep -Seconds 75; & `"$snapshotScript`""
        )
        Log "Snapshot will refresh in 75 s."
    }
}

# ------------------------------------------------------------------- selection screen
function SelectionScreen($candidates, $subtitle) {
    $checked = New-Object 'System.Collections.Generic.HashSet[int]'
    0..($candidates.Count - 1) | ForEach-Object { [void]$checked.Add($_) }

    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  CLAUDE SESSION RECOVERY" -ForegroundColor Cyan
        Write-Host "  $subtitle" -ForegroundColor DarkGray
        Write-Host ""
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $c      = $candidates[$i]
            $tick   = $(if ($checked.Contains($i)) { 'x' } else { ' ' })
            $colour = $(if ($checked.Contains($i)) { 'White' } else { 'DarkGray' })
            $mins   = [int]((Get-Date).ToUniversalTime() - $c.When).TotalMinutes
            $ago    = $(if ($mins -lt 90) { "$mins min ago" } else { "{0:0.#} hours ago" -f ($mins / 60) })
            $how    = $(if ($c.SessionId) { 'resume' } else { 'new session' })
            Write-Host ("   [{0}] {1,2}. {2}" -f $tick, ($i + 1), $c.Name) -ForegroundColor $colour
            Write-Host ("          {0}  |  {1}  |  {2}" -f $ago, $c.Kind, $how) -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  [Enter] open selected   [1 3 5] toggle   [a] all  [n] none  [q] quit" -ForegroundColor DarkGray
        Write-Host ""
        # Read-Host throws when stdin is redirected; in that case quit (records are kept, and
        # cc-back can be used to look again)
        try { $answer = (Read-Host "  >").Trim() } catch { Log "No input available: $($_.Exception.Message)"; return $null }

        if ($answer -eq '')  {
            $picked = @()
            for ($i = 0; $i -lt $candidates.Count; $i++) { if ($checked.Contains($i)) { $picked += $candidates[$i] } }
            return , $picked
        }
        if ($answer -eq 'q') { return $null }
        if ($answer -eq 'a') { 0..($candidates.Count - 1) | ForEach-Object { [void]$checked.Add($_) }; continue }
        if ($answer -eq 'n') { $checked.Clear(); continue }
        foreach ($part in ($answer -split '[,\s]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($part, [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count) {
                if ($checked.Contains($n - 1)) { [void]$checked.Remove($n - 1) } else { [void]$checked.Add($n - 1) }
            }
        }
    }
}

# ------------------------------------------------------------- alias collision guard
# PowerShell command resolution order: Alias > Function > Cmdlet.
# If a function name collides with a built-in alias the function is NEVER called and the call
# silently goes to another cmdlet instead. This loop catches the collision at runtime and
# removes the alias FOR THIS PROCESS ONLY.
foreach ($fn in $MyInvocation.MyCommand.ScriptBlock.Ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (Get-Alias -Name $fn.Name -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath "Alias:\$($fn.Name)" -Force -ErrorAction SilentlyContinue
        Log "Warning: function name '$($fn.Name)' collided with an alias; alias removed for this process."
    }
}

# ------------------------------------------------------------------------- main flow
try {
    if ($Mode -eq 'Auto') { Start-Sleep -Seconds 12 }   # let logon and the network settle

    $boot        = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $bootUtc     = $boot.ToUniversalTime()
    $previousMode = ($Mode -eq 'Auto' -or $Mode -eq 'Ask' -or ($Mode -eq 'List' -and $PreviousBoot))
    $limit       = $(if ($previousMode) { $bootUtc.AddHours(-$Hours) } else { (Get-Date).ToUniversalTime().AddHours(-$Hours) })

    $found      = CollectCandidates $bootUtc $limit $previousMode
    $candidates = @($found.Candidates)

    # Read-only test mode: opens nothing, deletes no records
    if ($Mode -eq 'List') {
        Write-Host "boot(UTC)=$($bootUtc.ToString('o'))  limit(UTC)=$($limit.ToString('o'))  previousBootFilter=$previousMode"
        Write-Host "candidates=$($candidates.Count)  stale-records-to-clean=$($found.Stale.Count)"
        $candidates | Select-Object @{n = 'When'; e = { $_.When.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } }, Kind,
                                    @{n = 'Session'; e = { if ($_.SessionId) { $_.SessionId.Substring(0, 8) } else { '-' } } },
                                    Name, Path | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        return
    }

    if ($candidates.Count -eq 0) {
        Log "No candidates."
        CleanupStale $found.Stale
        if ($Mode -ne 'Auto') {
            Write-Host ""
            Write-Host "  No sessions to bring back." -ForegroundColor Yellow
            Write-Host "  (scanned the last $Hours hours)" -ForegroundColor DarkGray
            Write-Host ""
            Start-Sleep -Seconds 4
        }
        return
    }

    # Auto mode runs hidden; it opens a visible window to ask for the decision
    if ($Mode -eq 'Auto') {
        Log "$($candidates.Count) candidates found, opening the selection screen."
        Start-Process powershell -ArgumentList @(
            '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Mode', 'Ask', '-Hours', $Hours
        )
        return
    }

    $subtitle = $(if ($previousMode) {
        "Booted {0:dd.MM.yyyy HH:mm}. Sessions open at shutdown:" -f $boot
    } else {
        "Sessions worked on in the last $Hours hours that are not open now:"
    })

    $selection = SelectionScreen $candidates $subtitle

    if ($null -eq $selection) { Log "User quit, records kept."; return }

    CleanupStale $found.Stale

    if ($selection.Count -eq 0) { Log "Nothing selected."; return }

    OpenSessions $selection
    Write-Host ""
    Write-Host "  Opening $($selection.Count) session(s)..." -ForegroundColor Green
    Start-Sleep -Seconds 3
}
catch {
    Log "ERROR: $($_.Exception.Message)"
    if ($Mode -ne 'Auto') {
        Write-Host ""
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        Read-Host "  Press Enter to continue"
    }
}
