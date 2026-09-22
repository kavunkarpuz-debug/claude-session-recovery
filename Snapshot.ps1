# Snapshot.ps1 - Takes a snapshot of Claude's live session registry.
# The scheduled task runs this every few minutes.
#
# Why it is needed:
#   On a clean shutdown (window X, logoff, restart) claude.exe DELETES its own registry entry
#   at ~\.claude\sessions\<pid>.json. So after a restart there is no trace of what was open.
#   A session left untouched for a week also has an old transcript, so it falls outside the
#   time window. The answer: keep our own copy of the last state before shutdown.
#
# Critical detail - boot ordering:
#   This task also runs at boot and may run BEFORE Restore.ps1. So it never overwrites the
#   snapshot left by the previous boot; it first preserves it as 'snapshot-previous.json'.
#   Whatever order they run in, the evidence survives.

$state    = Join-Path $PSScriptRoot 'state'
$registry = Join-Path $HOME '.claude\sessions'
$current  = Join-Path $state 'snapshot.json'
$previous = Join-Path $state 'snapshot-previous.json'

New-Item -ItemType Directory -Force -Path $state | Out-Null

$bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')

# Preserve the snapshot left by the previous boot (once)
if (Test-Path -LiteralPath $current) {
    try {
        $old = Get-Content -LiteralPath $current -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($old.boot -ne $bootUtc) {

            # If an UNCONSUMED snapshot is still on hand (the user skipped the last restore or
            # pressed 'q'), do not clobber it - MERGE. A plain Move-Item -Force would mean that
            # two restarts in a row silently drop the first boot's sessions from layer 0.
            if (Test-Path -LiteralPath $previous) {
                try {
                    $unconsumed = Get-Content -LiteralPath $previous -Raw -Encoding UTF8 | ConvertFrom-Json
                    $seen = @{}
                    foreach ($s in @($old.sessions)) {
                        if ($s.path) { $seen[$s.path.TrimEnd('\').ToLowerInvariant()] = $true }
                    }
                    $extra = @()
                    foreach ($s in @($unconsumed.sessions)) {
                        if (-not $s.path) { continue }
                        if (-not $seen.ContainsKey($s.path.TrimEnd('\').ToLowerInvariant())) { $extra += $s }
                    }
                    if ($extra.Count -gt 0) { $old.sessions = @(@($old.sessions) + $extra) }
                } catch { }
            }

            $old | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $previous -Encoding UTF8
            Remove-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

$list = @()
if (Test-Path -LiteralPath $registry) {
    foreach ($d in Get-ChildItem -LiteralPath $registry -Filter *.json -File -ErrorAction SilentlyContinue) {
        try { $r = Get-Content -LiteralPath $d.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $r.cwd -or -not $r.sessionId) { continue }

        # Only record processes that are REALLY running
        $p = Get-Process -Id $r.pid -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if ($r.procStart) {
            try { if ($p.StartTime.ToFileTime().ToString() -ne $r.procStart.ToString()) { continue } } catch { }
        }

        $list += [ordered]@{
            path      = $r.cwd
            sessionId = $r.sessionId
            pid       = $r.pid
            procStart = "$($r.procStart)"
        }
    }
}

$out = [ordered]@{
    time     = (Get-Date).ToUniversalTime().ToString('o')
    boot     = $bootUtc
    sessions = @($list)
}

# Write atomically: a half-written file would mean losing the evidence
$tmp = Join-Path $state 'snapshot.tmp'
$out | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmp -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $current -Force
