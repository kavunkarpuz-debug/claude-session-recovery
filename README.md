# Claude Session Recovery

Brings back the [Claude Code](https://claude.com/claude-code) sessions that were open when
your computer died, from a single screen the next time it boots. Windows + PowerShell.

## The problem it solves

If you keep 8-10 Claude sessions open across different folders — some untouched for weeks —
a power cut, a blue screen or a Windows Update restart takes all of them at once. To get them
back you have to remember which folders you were working in. If you can't, those sessions are
gone.

This system records what was open at the moment of shutdown and brings it all back
**where you left off**, with one keypress.

## Install

```powershell
git clone https://github.com/<user>/claude-session-recovery.git
cd claude-session-recovery
powershell -ExecutionPolicy Bypass -File .\Install.ps1
```

It does four things: copies the scripts to `~\.claude\session-recovery\`, adds the commands to
your PowerShell profile, creates a startup shortcut, and registers a scheduled task that runs
every 10 minutes. No administrator rights needed. Running it again is harmless. When it is
done it runs the health check and shows you the result, so you see it working rather than
being told it worked.

If `cc` is already taken on your machine — it is a C compiler wherever a Unix toolchain is
installed — the installer stops and names the conflict instead of shadowing it. Pick your own:

```powershell
.\Install.ps1 -Prefix ccode      # ccode, ccode-tab, ccode-back, ccode-health
```

## Commands

| Command | What it does |
|---|---|
| `cc` | Starts Claude in the current folder, resuming the last conversation if there is one |
| `cc-tab "<path>"` | Opens another folder as a new tab in the same Windows Terminal window |
| `cc-back` | Lists closed sessions and reopens the ones you pick |
| `cc-health` | Checks, line by line, that the system still works |

(These are the default names; `-Prefix` at install time changes all four.)

At Windows startup the restore screen appears **automatically**; if there are no candidates it
never shows up at all.

```
  CLAUDE SESSION RECOVERY
  Booted 22.09.2026 12:14. Sessions open at shutdown:

   [x]  1. Oilman Vigor Comparison
          3 min ago  |  left open  |  resume
   [x]  2. Drill Pipe
          3 min ago  |  HARD CRASH  |  resume

  [Enter] open selected   [1 3 5] toggle   [a] all  [n] none  [q] quit
```

`Enter` → they all open as tabs in one window, each with `claude --resume <id>`, exactly where
you left it.

## How it works

Four independent sources of evidence are merged; if one misses, another catches it:

| # | Source | When it earns its keep |
|---|---|---|
| 0 | Snapshot (every 10 min) | Clean restart — claude deletes its own record, so this is the only trace |
| 1 | Claude's session registry | Power loss, blue screen — no cleanup ran, so the record survives |
| 2 | Heartbeat records (15 s) | Sessions started with `cc`; tells apart the kind of shutdown |
| 3 | Transcript files | Last resort, if the first three were cleaned up |

**The time window applies to source 3 only.** "Was it open at shutdown" is a liveness question,
not a recency question — a session untouched for a week but still open must come back too.
Sessions that are currently open never enter the list, so nothing is ever opened twice;
liveness is confirmed with `pid` + process start time.

## Health check

The system reads Claude Code's **undocumented** internal files. If a release changes their
shape, nothing raises an error — the source layers quietly come back empty and you only notice
once you have lost a session. `cc-health` makes that silent decay visible:

```
[ OK ] layer 1 (session registry) - 7 record(s)
       Fields present: cwd, sessionId, pid, procStart
[FAIL] layer 3 - no 'cwd' in the transcript
       The format changed. The last-resort layer cannot recover folder paths.
```

It checks each of the four layers, the scheduled task, the startup shortcut and the profile
commands separately, and prints the fix for anything it finds. Worth running once after every
Claude Code upgrade.

## Uninstall

```powershell
.\Uninstall.ps1              # scripts, task, shortcut and profile commands
.\Uninstall.ps1 -RemoveState # also delete the state records and the log
```

It lists what it is about to remove and asks first. **It never touches `~\.claude\projects\` —
your conversation history.**

## Requirements

- Windows 10/11, PowerShell 5.1 or 7
- [Claude Code](https://claude.com/claude-code) CLI (`claude.exe` on PATH)
- Windows Terminal (`wt`) — without it, each session opens in its own window

Claude Code's internal file formats were verified on release **2.1.278**. Whether they still
hold on a newer release is exactly what `cc-health` tells you.

## Tests

```powershell
.\Test.ps1
```

Builds a throwaway `HOME` under `%TEMP%`, fabricates evidence in all four layers and checks
what the restore engine makes of it — including the `/exit` tombstone and the path-canonical
regression that once opened the same network folder twice. Your real installation is never
touched. Run it after changing anything here.

## Details

Architecture, known limits, diagnostic commands and the traps hit while building this are in
[`TECHNICAL.md`](TECHNICAL.md).

`_v1_backup/` holds the first version of this system.

## License

[MIT](LICENSE)
