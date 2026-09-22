# YeniTab.ps1 - Verilen klasoru MEVCUT Windows Terminal penceresinde yeni bir sekme olarak acar.
#
# Kullanim (profildeki kisayol):
#   cc-tab "C:\...\Yeni Talep"     -> o klasoru yeni sekmede acar
#   cc-tab                          -> bulundugun klasoru yeni sekmede acar
#
# Nasil: "wt -w 0" en son kullanilan pencereyi hedefler. Windows Terminal icinden
# cagrildiginda bu, icinde bulundugun penceredir; yeni pencere acmaz, sekme ekler.

param(
    # Tirnaksiz yazilan, bosluk iceren yollar da calissin diye kalan tum argumanlar toplanir
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Parca
)

$Klasor = if ($Parca) { ($Parca -join ' ').Trim().Trim('"') } else { (Get-Location).Path }

if (-not (Test-Path -LiteralPath $Klasor)) {
    Write-Host "Klasor bulunamadi: $Klasor" -ForegroundColor Red
    return
}

# .Path DEGIL .ProviderPath - UNC yollarinda saglayici oneki gelmesin (bkz. OKUBENI.md)
$Klasor = (Resolve-Path -LiteralPath $Klasor).ProviderPath.TrimEnd('\')
$baslat = Join-Path $PSScriptRoot 'baslat.ps1'

# DIKKAT: wt komut satirinda ';' KOMUT AYIRICIDIR. Sekme basliginda gecerse wt komutu
# ikiye boler ve "dosya bulunamadi" hatasi verir. Baslik zaten kozmetik, temizle.
# (Yol base64 ile gectigi icin ondan risk yok.)
$ad = (Split-Path -Leaf $Klasor) -replace '[;"]', '-'

if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    Write-Host "Windows Terminal (wt) bulunamadi, ayri pencerede aciliyor..." -ForegroundColor Yellow
    Start-Process powershell -ArgumentList @(
        '-NoExit', '-ExecutionPolicy', 'Bypass', '-File', "`"$baslat`"",
        '-B64', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Klasor))
    )
    return
}

# Klasor yolu base64 ile gecer: Turkce karakterler ve bosluklar hicbir katmanda bozulmaz
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Klasor))

& wt.exe -w 0 new-tab --title $ad --suppressApplicationTitle `
    powershell -NoExit -ExecutionPolicy Bypass -File $baslat -B64 $b64

Write-Host "Yeni sekme aciliyor: $ad" -ForegroundColor DarkGray
