# Start.ps1 - Launches Claude Code with session recording.
# Usage: open PowerShell in the folder you want to work in, type "cc".
#
# How it works:
#   - On start it writes a record (.json) into state\ and stamps a heartbeat (.hb) every 15 s.
#   - On window close / logoff / shutdown it leaves a .closed stamp and KEEPS the record.
#   - On power loss, blue screen or death-in-sleep no .closed can be written, but the last
#     .hb survives (at most 15 s of loss).
#   - On a clean /exit it deletes the record: that folder is never offered again.

param(
    [string]$Folder = (Get-Location).Path,
    [string]$B64    = '',          # Base64 of the folder path (safe for non-ASCII characters)
    [string]$Resume = ''           # Claude session id to resume
)

if ($B64) {
    $Folder = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64))
}

$state = Join-Path $PSScriptRoot 'state'
New-Item -ItemType Directory -Force -Path $state | Out-Null

if (-not ('SessionWatcher' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class SessionWatcher {
    delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);

    static HandlerRoutine _handler;
    static Timer _timer;
    static string _hb, _closed;

    public static void Start(string hbPath, string closedPath) {
        _hb = hbPath; _closed = closedPath;
        if (_timer != null) _timer.Dispose();
        Stamp(_hb);
        _timer = new Timer(_ => Stamp(_hb), null, 15000, 15000);
        if (_handler == null) {
            _handler = new HandlerRoutine(OnClose);
            SetConsoleCtrlHandler(_handler, true);
        }
    }

    // 0 = Ctrl+C, 1 = Ctrl+Break (Claude's own shortcuts - stay out of the way)
    // 2 = window close (X), 5 = logoff, 6 = system shutdown
    static bool OnClose(uint t) {
        if (t >= 2 && _closed != null) Stamp(_closed);
        return false;
    }

    public static void Stop() {
        if (_timer != null) { _timer.Dispose(); _timer = null; }
        _closed = null;
    }

    static void Stamp(string p) {
        try { File.WriteAllText(p, DateTime.UtcNow.ToString("o")); } catch { }
    }
}
'@
}

if (-not (Test-Path -LiteralPath $Folder)) {
    Write-Host "Folder not found: $Folder" -ForegroundColor Red
    Start-Sleep -Seconds 5
    return
}

# .ProviderPath, NOT .Path: for UNC paths .Path comes back provider-qualified as
# "Microsoft.PowerShell.Core\FileSystem::\\server\share\...". If that prefix lands in the
# record, the same folder produces two different identities and gets opened twice.
$Folder = (Resolve-Path -LiteralPath $Folder).ProviderPath.TrimEnd('\')
Set-Location -LiteralPath $Folder
$name = Split-Path -Leaf $Folder

# Stable identity derived from the folder path (same folder = same record)
$sha   = [Security.Cryptography.SHA1]::Create()
$bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Folder.ToLowerInvariant()))
$id    = -join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') })

# The PID goes into the record name too. With two windows open on the same folder, a name
# derived from the path alone would make them share one file; when one exits with /exit the
# record would be deleted for the other as well, and the surviving window would lose its
# heartbeat record.
$b     = Join-Path $state "$id-$PID"

$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')

Remove-Item -LiteralPath "$b.closed" -ErrorAction SilentlyContinue
# A session is being opened in this folder again: drop any leftover "/exit" tombstone
Remove-Item -LiteralPath (Join-Path $state "$id.exit") -ErrorAction SilentlyContinue
$procStart = ''
try { $procStart = (Get-Process -Id $PID).StartTime.ToFileTime().ToString() } catch { }

[ordered]@{
    path      = $Folder
    name      = $name
    pid       = $PID
    procStart = $procStart      # identity check against PID reuse
    boot      = $boot
    started   = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath "$b.json" -Encoding UTF8

[SessionWatcher]::Start("$b.hb", "$b.closed")
$Host.UI.RawUI.WindowTitle = $name

# ---------------------------------------------------------------------------
# Decide WHICH session to open UP FRONT, then invoke claude EXACTLY ONCE.
#
# Two rules:
#   - claude.exe is always called directly, as a statement. If its output is assigned to a
#     variable or piped, PowerShell redirects stdout, claude concludes it is not attached to
#     a terminal, falls into --print mode and says "Input must be provided...".
#   - "--continue" is never used: it picks the MOST RECENT conversation in the folder, which
#     may be the session that is open right now. Instead the newest non-live session id is
#     selected and passed to --resume.
# ---------------------------------------------------------------------------

function ProcessAlive($processId, $procStart) {
    if (-not $processId) { return $false }
    $p = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if (-not $procStart) { return $true }
    try { return ($p.StartTime.ToFileTime().ToString() -eq $procStart.ToString()) } catch { return $true }
}

# Ids of sessions currently open in this folder - never resume on top of them
$liveIds  = @()
$registry = Join-Path $HOME '.claude\sessions'
if (Test-Path -LiteralPath $registry) {
    foreach ($d in Get-ChildItem -LiteralPath $registry -Filter *.json -File -ErrorAction SilentlyContinue) {
        try { $r = Get-Content -LiteralPath $d.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $r.cwd -or $r.cwd.TrimEnd('\').ToLowerInvariant() -ne $Folder.ToLowerInvariant()) { continue }
        if (ProcessAlive $r.pid $r.procStart) { $liveIds += $r.sessionId }
    }
}

$targetId = $null
if ($Resume -and ($liveIds -notcontains $Resume)) { $targetId = $Resume }

# If a session is already open in this folder and no id was explicitly requested: do not
# resume an old conversation, start a fresh one. The "ongoing" one is already open.
if (-not $targetId -and $liveIds.Count -eq 0) {
    # Claude project folder name: every non-alphanumeric character becomes '-'
    $slug = [regex]::Replace($Folder, '[^a-zA-Z0-9]', '-')
    $pd   = Join-Path $HOME ".claude\projects\$slug"
    if (Test-Path -LiteralPath $pd) {
        $targetId = Get-ChildItem -LiteralPath $pd -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                    Where-Object { $liveIds -notcontains $_.BaseName -and $_.Length -gt 1kb } |
                    Sort-Object LastWriteTimeUtc -Descending |
                    Select-Object -First 1 -ExpandProperty BaseName
    }
}

if ($liveIds.Count -gt 0) {
    Write-Host "Note: a Claude session is already open in this folder; starting a new one without touching it." -ForegroundColor Yellow
}

if ($targetId) {
    Write-Host "Resuming where you left off..." -ForegroundColor DarkGray
    claude --resume $targetId
    $code = $LASTEXITCODE
    # If the chosen session could not be opened (corrupt/stale record) try a fresh one, once
    if ($code -ne 0 -and -not (Test-Path -LiteralPath "$b.closed")) {
        Write-Host "Could not resume that session, starting a new one..." -ForegroundColor Yellow
        claude
    }
} else {
    Write-Host "No conversation to resume in this folder, starting a new session..." -ForegroundColor DarkGray
    claude
}
Start-Sleep -Milliseconds 400

# If the window is closing (X / logoff / shutdown) leave the record behind and let Restore.ps1 decide
if (Test-Path -LiteralPath "$b.closed") { return }

# Reaching here means a deliberate /exit: remove the record
[SessionWatcher]::Stop()
Remove-Item -LiteralPath "$b.json", "$b.hb" -ErrorAction SilentlyContinue

# The /exit contract: this folder must not be offered again. We deleted our own record and
# claude deleted its registry entry. But the SNAPSHOT only refreshes every 10 minutes; if no
# refresh happens between the exit and a restart, the snapshot still contains this folder and
# the session would be offered back. So refresh it now and also strip this folder from any
# unconsumed earlier snapshot.
$snapshotScript = Join-Path $PSScriptRoot 'Snapshot.ps1'
if (Test-Path -LiteralPath $snapshotScript) { & $snapshotScript }

# Tombstone: the transcript layer cannot tell open from closed, so it would offer this folder
# anyway. This stamp says "closed on purpose"; Restore skips a transcript older than the stamp.
# Opening a session in the folder again removes it.
try { [IO.File]::WriteAllText((Join-Path $state "$id.exit"), (Get-Date).ToUniversalTime().ToString('o')) } catch { }

$previousSnapshot = Join-Path $state 'snapshot-previous.json'
if (Test-Path -LiteralPath $previousSnapshot) {
    try {
        $s    = Get-Content -LiteralPath $previousSnapshot -Raw -Encoding UTF8 | ConvertFrom-Json
        $all  = @($s.sessions)
        $kept = @($all | Where-Object {
            $_.path -and $_.path.TrimEnd('\').ToLowerInvariant() -ne $Folder.ToLowerInvariant()
        })
        if ($kept.Count -ne $all.Count) {
            $s.sessions = $kept
            $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previousSnapshot -Encoding UTF8
        }
    } catch { }
}

Write-Host "Session closed. '$name' will not be offered again." -ForegroundColor DarkGray
