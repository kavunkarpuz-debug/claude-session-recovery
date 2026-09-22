# Technical Notes

How the system works inside, its known limits, and the traps hit while building it.
For what it is, how to install it and the commands, see [`README.md`](README.md).

On the restore screen: `Enter` = open everything ticked, `1 3 5` = toggle, `a` = all,
`n` = none, `q` = quit (records are kept, so `cc-back` can show them again later).

### How `cc-tab` works

`wt -w 0` targets "the most recently used window" — called from inside Windows Terminal, that
is the window you are in. It adds a tab instead of opening a new window. The folder path is
passed as base64, so spaces and non-ASCII characters survive every layer intact. Without `wt`
it falls back to a separate window.

## How sessions are found

Four independent sources are merged; if one misses, another catches it:

0. **`state\snapshot-previous.json`** — the last snapshot `Snapshot.ps1` took before shutdown.
   **Most reliable.** The scheduled task refreshes it every 10 minutes. Without it a clean
   restart leaves no trace at all, because claude deletes its own registry entry on the way out.
1. **`~\.claude\sessions\<pid>.json`** — Claude's own live session registry. Gives `cwd` +
   `sessionId` + `pid`. Deleted on a clean exit, **survives a hard crash**.
2. **`~\.claude\session-recovery\state\*.json`** — 15-second heartbeat records for sessions
   started with `cc`. Tells the kind of shutdown: *window closed* or *hard crash*.
3. **`~\.claude\projects\*\*.jsonl`** — transcript files. Last resort if the others were cleaned up.

### The time window applies to source 3 only

"Was it open at shutdown" is a **liveness** question, not a "when was it written" question. A
session untouched for a week but still open must come back too. Sources 0, 1 and 2 are proof
that it *was* open — the `-Hours` window is not applied to them (only a 30-day sanity limit).
Source 3 alone is subject to the window, because it cannot tell open from closed.

Whether a session is still open is settled by `pid` + **process start time** — PIDs get reused
after a reboot, so the PID alone is not enough. Open sessions never enter the list, so the same
session is never opened twice.

## Which session `cc` resumes

The session to open is decided **up front**, and `claude` is invoked **exactly once**:

1. If `-Resume <id>` was given (the restore screen supplies it), that session opens.
2. Otherwise the newest transcript in this folder's project directory is `--resume`d.
3. If a session is **already open** in this folder, no old conversation is resumed — a fresh
   session starts. (The "ongoing" one is the window you already have open.)

Two rules are deliberate:

- **`--continue` is never used.** It picks the most recent conversation in the folder, which may
  be the session that is open right now; resuming on top of it fails.
- **`claude` is invoked directly**, never assigned to a variable or piped. If it is, PowerShell
  redirects stdout, claude concludes it is not attached to a terminal, drops into `--print` mode
  and says *"Input must be provided either through stdin or as a prompt argument"*.

## Known limits

- `cwd` inside a transcript can drift with a shell `cd`, so source 3 uses the **first** `cwd`
  line in the file. Source 1 gives the correct folder anyway.
- A session is not written to the registry until the folder-trust prompt has been accepted.
- Without `wt` (Windows Terminal) every session opens in its own PowerShell window.
- A folder you closed with `/exit` can still appear via source 3 (the transcript) if its window
  is still around. Untick it and move on.
- **If the snapshot task is not running**, long-idle sessions can be missed on a clean restart.
  Check with `cc-health` (or `Get-ScheduledTask 'Claude Session Snapshot'`).
- **When Claude Code is upgraded** the internal file formats may change; the code degrades
  gracefully (every layer is `Test-Path` guarded) but the decay is silent. See below.

## Version dependency and the health check

Two things this system relies on are **undocumented** by Claude Code: the fields of a session
registry record (`cwd`, `sessionId`, `pid`, `procStart` in `~\.claude\sessions\<pid>.json`) and
the `cwd` carried on transcript lines. Their shape was verified on release **2.1.278**.

If a release changes them nothing errors out — the layer simply returns empty and the system
quietly weakens. `Health.ps1` exists to make that visible: it does not stop at comparing version
numbers, it opens the real files and confirms **the fields are still there**. A differing
version is only a warning; the verdict comes from the structure checks.

The transcript scan skips the metadata lines at the top of the file (`mode`, `permission-mode`
and friends) when looking for the first `cwd`, and reads at most 200 lines — these files can run
to hundreds of megabytes.

## Where the files live — and what happens if you delete them

| Location | What | If deleted |
|---|---|---|
| `~\.claude\projects\` | **All conversation history** | ⛔ Conversations are gone for good. No way back. |
| `~\.claude\sessions\` | Claude's live session registry | Claude recreates it; only the current recovery information is lost |
| `~\.claude\session-recovery\` | The working system (5 scripts + `state\` + log) | `Install.ps1` puts it back in five seconds |
| `~\.claude\session-recovery\state\snapshot.json` | Last snapshot of open sessions | Refreshes itself within 10 minutes |
| your clone of this repo | Source copy + `Install.ps1` + these docs | The system keeps running, but you cannot reinstall it |
| Startup`\Claude Session Restore.lnk` | The shortcut that runs at boot | No automatic screen; `cc-back` still works. Install puts it back |
| Task: `Claude Session Snapshot` | Takes a snapshot every 10 min | Idle sessions can be missed on a clean restart. Install puts it back |
| `...\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` | The `cc` / `cc-back` definitions | Commands stop resolving. Install puts them back (backup: `.sessionrecovery-backup`) |

**In short:** everything this system produces can be rebuilt by `Install.ps1`. The one thing that
must never be deleted is `~\.claude\projects\` — that is not ours, it is Claude's conversation
archive.

## Traps to know when editing these scripts

`Resolve-Path`'s **`.Path`** property returns a provider-qualified form for UNC paths:
`Microsoft.PowerShell.Core\FileSystem::\\server\share\...`. If that lands in a record, the same
folder produces two different identities and the session is opened twice. This happened with a
folder on a network share. The correct property is **`.ProviderPath`**. `Restore.ps1` also strips
the prefix in `CleanPath` and normalises to NFC, so comparisons across sources stay consistent.

PowerShell resolves commands in the order **Alias > Function > Cmdlet**. Give a function the same
name as a built-in alias and the function is never called — the call silently goes elsewhere.
That is exactly what happened here: a function named `Ac` was resolving to the `ac` alias
(= `Add-Content`), which prompted `Value[0]:` on screen while no session opened. `Restore.ps1`
now scans its own function names against the alias table at startup and removes any colliding
alias for that process only.

Windows PowerShell 5.1 reads files as ANSI by default. Reading a BOM-less UTF-8 profile that way
and writing it back corrupts non-ASCII characters permanently, so `Install.ps1` and
`Uninstall.ps1` always read with an explicit UTF-8 encoding and write UTF-8 **with** a BOM.

`;` is a **command separator** on the `wt` command line, and tabs are already joined with ` ; `.
A `;` in a folder name would split the command in the wrong place, so tab titles are sanitised.

Task Scheduler rejects `-RepetitionDuration [TimeSpan]::MaxValue` (`P99999999DT23H59M59S`).
Omitting the duration means "repeat indefinitely". `Register-ScheduledTask` can also emit a
non-terminating error that never reaches `catch`, so registration is **verified** with
`Get-ScheduledTask` before success is reported.

## Diagnostics

```powershell
# Are the four layers, the task, the shortcut and the profile commands all working?
cc-health

# See what would be offered, without opening or deleting anything
& "$HOME\.claude\session-recovery\Restore.ps1" -Mode List -Hours 24
& "$HOME\.claude\session-recovery\Restore.ps1" -Mode List -Hours 12 -PreviousBoot   # with the boot filter
```

Log: `~\.claude\session-recovery\restore.log`
v1 scripts: `_v1_backup\`
PowerShell profile backup: `Microsoft.PowerShell_profile.ps1.sessionrecovery-backup`
