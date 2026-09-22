# Test.ps1 - Smoke test. Run it after changing anything in this repo.
#
#   powershell -ExecutionPolicy Bypass -File .\Test.ps1
#   .\Test.ps1 -Keep    leave the temporary files behind for inspection
#
# It builds a throwaway HOME under %TEMP%, fabricates evidence in all four source layers and
# checks what Restore.ps1 makes of it. Your real installation is never touched: every path is
# derived from the fake HOME, and the scripts under test are copied out of this repo.
#
# Exit code: 0 = all passed, 1 = at least one failure.

[CmdletBinding()]
param([switch]$Keep)

$ErrorActionPreference = 'Stop'

$repo    = $PSScriptRoot
$scripts = 'Start.ps1', 'Restore.ps1', 'Snapshot.ps1', 'NewTab.ps1', 'Health.ps1'
foreach ($s in $scripts) {
    if (-not (Test-Path -LiteralPath (Join-Path $repo $s))) { throw "Not found in repo: $s" }
}

$sandbox = Join-Path $env:TEMP ('csr-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$passed  = 0
$failed  = 0

function Check($name, $expected, $actual) {
    if ("$expected" -eq "$actual") {
        Write-Host ("  PASS  {0}" -f $name) -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host ("  FAIL  {0}" -f $name) -ForegroundColor Red
        Write-Host ("        expected [{0}], got [{1}]" -f $expected, $actual) -ForegroundColor Red
        $script:failed++
    }
}

# Each scenario gets its own fake HOME, so nothing leaks from one test into the next.
function NewEnv($label) {
    $home2 = Join-Path $sandbox $label
    $e = @{
        Home     = $home2
        Inst     = Join-Path $home2 '.claude\session-recovery'
        State    = Join-Path $home2 '.claude\session-recovery\state'
        Registry = Join-Path $home2 '.claude\sessions'
        Projects = Join-Path $home2 '.claude\projects'
        Work     = Join-Path $sandbox ($label + '-folders')
    }
    foreach ($d in $e.State, $e.Registry, $e.Projects, $e.Work) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    foreach ($s in $scripts) { Copy-Item -LiteralPath (Join-Path $repo $s) -Destination $e.Inst -Force }
    return $e
}

function WorkFolder($e, $name) {
    $p = Join-Path $e.Work $name
    New-Item -ItemType Directory -Force -Path $p | Out-Null
    return $p
}

$deadPid = 999999   # a process id that does not exist

function WriteSnapshot($e, $entries, $file) {
    @{
        time     = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
        boot     = (Get-Date).ToUniversalTime().AddDays(-1).ToString('o')
        sessions = @($entries)
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $e.State $file) -Encoding UTF8
}

function WriteRegistry($e, $path, $sessionId, $processId, $procStart) {
    @{
        pid = $processId; procStart = $procStart; cwd = $path; sessionId = $sessionId
        updatedAt = [DateTimeOffset]::UtcNow.AddHours(-3).ToUnixTimeMilliseconds()
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $e.Registry ("$processId.json")) -Encoding UTF8
}

function WriteHeartbeat($e, $path, $minutesAgo) {
    $base = Join-Path $e.State ('aaaaaaaaaaaa-' + $deadPid)
    @{ path = $path; name = (Split-Path -Leaf $path); pid = $deadPid; procStart = '1'
       boot = 'older-boot'; started = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath "$base.json" -Encoding UTF8
    [IO.File]::WriteAllText("$base.hb", (Get-Date).ToUniversalTime().AddMinutes(-$minutesAgo).ToString('o'))
}

# A transcript whose cwd only appears on line 6, behind the metadata lines Claude writes first.
function WriteTranscript($e, $path, $sessionId) {
    $slug = [regex]::Replace($path, '[^a-zA-Z0-9]', '-')
    $dir  = Join-Path $e.Projects $slug
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $file = Join-Path $dir "$sessionId.jsonl"
    Set-Content -LiteralPath $file -Encoding UTF8 -Value @(
        '{"type":"mode","mode":"normal"}'
        '{"type":"permission-mode","permissionMode":"auto"}'
        '{"type":"atis-latch","atis":"x"}'
        '{"type":"meta","a":1}'
        '{"type":"meta","b":2}'
        ('{"type":"user","cwd":"' + ($path -replace '\\', '\\') + '","sessionId":"' + $sessionId + '"}')
    )
    return $file
}

function WriteTombstone($e, $path, $hoursOffset) {
    $sha  = [Security.Cryptography.SHA1]::Create()
    $id   = -join (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($path.TrimEnd('\').ToLowerInvariant())))[0..5] |
                   ForEach-Object { $_.ToString('x2') })
    [IO.File]::WriteAllText((Join-Path $e.State ($id + '.exit')),
                            (Get-Date).ToUniversalTime().AddHours($hoursOffset).ToString('o'))
}

# Runs Restore.ps1 in read-only List mode against the fake HOME and returns its output.
# $HOME is resolved when a process STARTS, so the environment has to be set before launching.
function RunRestore($e) {
    $env:USERPROFILE = $e.Home
    $env:HOMEDRIVE   = ''
    $env:HOMEPATH    = ''
    $env:HOME        = $e.Home
    return (& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $e.Inst 'Restore.ps1') `
                -Mode List -Hours 24 2>&1 | ForEach-Object { $_.ToString() })
}

function CandidateCount($out) {
    $m = [regex]::Match(($out -join "`n"), 'candidates=(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return -1
}

Write-Host ""
Write-Host "  CLAUDE SESSION RECOVERY - SMOKE TEST" -ForegroundColor Cyan
Write-Host "  sandbox: $sandbox" -ForegroundColor DarkGray
Write-Host ""

$me = Get-Process -Id $PID   # a genuinely running process, for the liveness tests

try {
    # ---------------------------------------------------------------- all four layers
    $e  = NewEnv 'layers'
    $f0 = WorkFolder $e 'FromSnapshot'
    $f1 = WorkFolder $e 'FromRegistry'
    $f2 = WorkFolder $e 'FromHeartbeat'
    $f3 = WorkFolder $e 'FromTranscript'
    WriteSnapshot  $e @(@{ path = $f0; sessionId = 'aaaa1111'; pid = $deadPid; procStart = '1' }) 'snapshot-previous.json'
    WriteRegistry  $e $f1 'bbbb2222' 12345 '1'
    WriteHeartbeat $e $f2 20
    WriteTranscript $e $f3 'cccc3333' | Out-Null

    $out = RunRestore $e
    Check 'four layers each contribute one candidate' 4 (CandidateCount $out)
    Check 'heartbeat without .closed reads as a hard crash' $true (($out -join "`n") -match 'HARD CRASH')

    # ------------------------------------------------- /exit tombstone hides a transcript
    WriteTombstone $e $f3 0          # stamped now, i.e. newer than the transcript
    Check 'tombstone newer than transcript suppresses it' 3 (CandidateCount (RunRestore $e))

    WriteTombstone $e $f3 -5         # stamped before the transcript: worked on again since
    Check 'tombstone older than transcript does not suppress' 4 (CandidateCount (RunRestore $e))

    # --------------------------------------------------------- a live session is not offered
    $e2 = NewEnv 'live'
    $fl = WorkFolder $e2 'StillOpen'
    WriteRegistry $e2 $fl 'dddd4444' $me.Id $me.StartTime.ToFileTime().ToString()
    WriteSnapshot $e2 @(@{ path = $fl; sessionId = 'dddd4444'; pid = $me.Id
                           procStart = $me.StartTime.ToFileTime().ToString() }) 'snapshot-previous.json'
    Check 'a session that is still running is excluded' 0 (CandidateCount (RunRestore $e2))

    # ------------------------------------------- same folder from two sources = one candidate
    # Regression test: Resolve-Path used to store UNC paths provider-qualified, which made the
    # same folder look like two candidates and opened it twice.
    $e3 = NewEnv 'dedupe'
    $fd = WorkFolder $e3 'SameFolder'
    WriteSnapshot $e3 @(@{ path = ('Microsoft.PowerShell.Core\FileSystem::' + $fd)
                           sessionId = 'eeee5555'; pid = $deadPid; procStart = '1' }) 'snapshot-previous.json'
    WriteRegistry $e3 $fd 'eeee5555' 23456 '1'
    Check 'provider-qualified and plain paths merge into one' 1 (CandidateCount (RunRestore $e3))

    # ------------------------------------------------------------------ Snapshot.ps1 itself
    $e4 = NewEnv 'snapshot'
    $fs = WorkFolder $e4 'Recorded'
    WriteRegistry $e4 $fs 'ffff6666' $me.Id $me.StartTime.ToFileTime().ToString()
    WriteRegistry $e4 (WorkFolder $e4 'Dead') 'aaaa7777' $deadPid '1'

    $env:USERPROFILE = $e4.Home; $env:HOMEDRIVE = ''; $env:HOMEPATH = ''; $env:HOME = $e4.Home
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $e4.Inst 'Snapshot.ps1')

    $snapFile = Join-Path $e4.State 'snapshot.json'
    $snap     = Get-Content -LiteralPath $snapFile -Raw -Encoding UTF8 | ConvertFrom-Json
    Check 'snapshot records only the live session' 1 @($snap.sessions).Count

    # Rotation: a snapshot from a different boot must be preserved, not overwritten
    $snap.boot = 'a-different-boot'
    $snap | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $snapFile -Encoding UTF8
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $e4.Inst 'Snapshot.ps1')
    Check 'snapshot from an older boot is preserved' $true (Test-Path -LiteralPath (Join-Path $e4.State 'snapshot-previous.json'))
}
finally {
    if ($Keep) {
        Write-Host ""
        Write-Host "  kept: $sandbox" -ForegroundColor DarkGray
    } elseif (Test-Path -LiteralPath $sandbox) {
        # Delete file by file, then the directories deepest first. Everything here was created
        # by this run, inside our own %TEMP% folder.
        Get-ChildItem -LiteralPath $sandbox -Recurse -File -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $sandbox -Recurse -Directory -ErrorAction SilentlyContinue |
            Sort-Object { $_.FullName.Length } -Descending |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $sandbox -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($failed -eq 0) {
    Write-Host "  $passed passed, 0 failed." -ForegroundColor Green
} else {
    Write-Host "  $passed passed, $failed FAILED." -ForegroundColor Red
}
Write-Host ""

exit ([int]($failed -gt 0))
