# NewTab.ps1 - Opens the given folder as a new tab in the CURRENT Windows Terminal window.
#
# Usage (the profile shortcut):
#   cc-tab "C:\...\New Request"     -> opens that folder in a new tab
#   cc-tab                          -> opens the current folder in a new tab
#
# How: "wt -w 0" targets the most recently used window. Called from inside Windows Terminal
# that is the window you are in, so it adds a tab instead of opening a new window.

param(
    # All remaining arguments are collected so unquoted paths containing spaces work too
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Part
)

$Folder = if ($Part) { ($Part -join ' ').Trim().Trim('"') } else { (Get-Location).Path }

if (-not (Test-Path -LiteralPath $Folder)) {
    Write-Host "Folder not found: $Folder" -ForegroundColor Red
    return
}

# .ProviderPath, NOT .Path - keeps the provider prefix out of UNC paths (see TECHNICAL.md)
$Folder  = (Resolve-Path -LiteralPath $Folder).ProviderPath.TrimEnd('\')
$starter = Join-Path $PSScriptRoot 'Start.ps1'

# NOTE: ';' is a COMMAND SEPARATOR on the wt command line. If one appears in a tab title wt
# splits the command in two and reports "file not found". The title is cosmetic, so strip it.
# (The path travels as base64, so there is no risk from that side.)
$name = (Split-Path -Leaf $Folder) -replace '[;"]', '-'

if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    Write-Host "Windows Terminal (wt) not found, opening a separate window..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList @(
        '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$starter`"",
        '-B64', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Folder))
    )
    return
}

# The folder path travels as base64: non-ASCII characters and spaces survive every layer
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Folder))

& wt.exe -w 0 new-tab --title $name --suppressApplicationTitle `
    powershell -NoExit -ExecutionPolicy Bypass -File $starter -B64 $b64

Write-Host "Opening new tab: $name" -ForegroundColor DarkGray
