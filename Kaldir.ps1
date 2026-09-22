# Kaldir.ps1 - Kurulum.ps1'in kurdugu her seyi geri alir.
#
#   powershell -ExecutionPolicy Bypass -File .\Kaldir.ps1
#   .\Kaldir.ps1 -DurumuSil      durum\ kayitlarini ve logu da siler
#   .\Kaldir.ps1 -Onayla         soru sormadan calisir
#
# ASLA DOKUNMAZ:
#   ~\.claude\projects\   -> tum konusma gecmisin. Bu klasor claude'a ait.
#   ~\.claude\sessions\   -> claude'un kendi canli oturum defteri.
# Bu script yalnizca kendi kurdugu dosyalari kaldirir; silecegi her dosyayi
# tek tek sayar, toplu/rekursif silme komutu kullanmaz.

[CmdletBinding()]
param(
    [switch]$DurumuSil,
    [switch]$Onayla
)

$hedef = Join-Path $HOME '.claude\oturum-kurtarma'
$durum = Join-Path $hedef 'durum'
$gorev = 'Claude Oturum Anlik Goruntu'
$lnk   = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Oturum Geri Yukle.lnk'
$bas   = '# >>> ClaudeOturum >>>'
$son   = '# <<< ClaudeOturum <<<'

$scriptler = 'baslat.ps1', 'GeriYukle.ps1', 'Anlik.ps1', 'YeniTab.ps1', 'Saglik.ps1'

$belgeler  = [Environment]::GetFolderPath('MyDocuments')
$profiller = @(
    $PROFILE,
    (Join-Path $belgeler 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $belgeler 'PowerShell\Microsoft.PowerShell_profile.ps1')
) | Where-Object { $_ } | Select-Object -Unique |
    Where-Object { (Test-Path -LiteralPath $_) -and
                   ([IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) -match [regex]::Escape($bas)) }

# ------------------------------------------------- once NE SILINECEGINI goster
Write-Host ""
Write-Host "  KALDIRILACAKLAR" -ForegroundColor Cyan
Write-Host ""

$var = @(Get-ChildItem -LiteralPath $hedef -File -ErrorAction SilentlyContinue |
         Where-Object { $scriptler -contains $_.Name })
foreach ($f in $var) { Write-Host "   script      $($f.FullName)" }

if (Get-ScheduledTask -TaskName $gorev -ErrorAction SilentlyContinue) {
    Write-Host "   gorev       $gorev"
}
if (Test-Path -LiteralPath $lnk) { Write-Host "   kisayol     $lnk" }
foreach ($p in $profiller)       { Write-Host "   profil      $p  (ClaudeOturum blogu)" }

$durumDosya = @()
if (Test-Path -LiteralPath $durum) {
    $durumDosya = @(Get-ChildItem -LiteralPath $durum -File -ErrorAction SilentlyContinue)
}
$log = Join-Path $hedef 'geri-yukleme.log'
if ($DurumuSil) {
    if ($durumDosya.Count -gt 0) { Write-Host "   durum       $durum  ($($durumDosya.Count) dosya)" }
    if (Test-Path -LiteralPath $log) { Write-Host "   log         $log" }
} else {
    Write-Host ""
    Write-Host "   KALACAK: $durum  ($($durumDosya.Count) dosya) ve log." -ForegroundColor DarkGray
    Write-Host "   Bunlari da silmek icin: .\Kaldir.ps1 -DurumuSil" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "   DOKUNULMAYACAK: ~\.claude\projects\ (konusma gecmisi), ~\.claude\sessions\" -ForegroundColor DarkGray
Write-Host ""

if ($var.Count -eq 0 -and $profiller.Count -eq 0 -and -not (Test-Path -LiteralPath $lnk) -and
    -not (Get-ScheduledTask -TaskName $gorev -ErrorAction SilentlyContinue)) {
    Write-Host "  Kaldirilacak bir sey bulunamadi - sistem zaten kurulu degil." -ForegroundColor Yellow
    Write-Host ""
    return
}

if (-not $Onayla) {
    $cevap = Read-Host "  Devam edilsin mi? (e/H)"
    if ($cevap -notin 'e', 'E', 'evet', 'y', 'Y') {
        Write-Host "  Vazgecildi. Hicbir sey degismedi." -ForegroundColor Yellow
        Write-Host ""
        return
    }
}
Write-Host ""

# ------------------------------------------------------------ 1. gorev
if (Get-ScheduledTask -TaskName $gorev -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $gorev -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-ScheduledTask -TaskName $gorev -ErrorAction SilentlyContinue) {
        $null = schtasks.exe /Delete /TN $gorev /F 2>&1
    }
    if (Get-ScheduledTask -TaskName $gorev -ErrorAction SilentlyContinue) {
        Write-Host "[1/4] Gorev SILINEMEDI: $gorev" -ForegroundColor Red
    } else {
        Write-Host "[1/4] Zamanlanmis gorev silindi." -ForegroundColor Green
    }
} else {
    Write-Host "[1/4] Zamanlanmis gorev zaten yoktu." -ForegroundColor DarkGray
}

# --------------------------------------------------------- 2. kisayol
if (Test-Path -LiteralPath $lnk) {
    Remove-Item -LiteralPath $lnk -Force -ErrorAction SilentlyContinue
    Write-Host "[2/4] Acilis kisayolu silindi." -ForegroundColor Green
} else {
    Write-Host "[2/4] Acilis kisayolu zaten yoktu." -ForegroundColor DarkGray
}

# ----------------------------------------------------------- 3. profil
foreach ($p in $profiller) {
    Copy-Item -LiteralPath $p -Destination "$p.claudeoturum-yedek" -Force
    # Kurulum.ps1 ile ayni okuma/yazma kurali: acik UTF-8. 5.1'in ANSI varsayilaniyla
    # okunup geri yazilan BOM'suz bir profilde Turkce karakterler kalici bozulur.
    $icerik = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    $icerik = [regex]::Replace($icerik, "(?s)\r?\n?$([regex]::Escape($bas)).*?$([regex]::Escape($son))", '')
    [IO.File]::WriteAllText($p, ($icerik.TrimEnd() + "`r`n"), (New-Object Text.UTF8Encoding($true)))
    Write-Host "      profil temizlendi: $p" -ForegroundColor DarkGray
    Write-Host "      yedek: $p.claudeoturum-yedek" -ForegroundColor DarkGray
}
if ($profiller.Count -gt 0) {
    Write-Host "[3/4] Komutlar profilden kaldirildi." -ForegroundColor Green
} else {
    Write-Host "[3/4] Profilde tanim yoktu." -ForegroundColor DarkGray
}

# --------------------------------------------------------- 4. dosyalar
$silinen = 0
foreach ($f in $var) {
    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $f.FullName)) { $silinen++ }
}

if ($DurumuSil) {
    foreach ($f in $durumDosya) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $f.FullName)) { $silinen++ }
    }
    if (Test-Path -LiteralPath $log) {
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $log)) { $silinen++ }
    }
    # Bosalan klasorleri kaldir - icinde baska bir sey kaldiysa dokunma
    foreach ($k in $durum, $hedef) {
        if ((Test-Path -LiteralPath $k) -and
            -not @(Get-ChildItem -LiteralPath $k -Force -ErrorAction SilentlyContinue).Count) {
            Remove-Item -LiteralPath $k -Force -ErrorAction SilentlyContinue
        }
    }
}
Write-Host "[4/4] $silinen dosya silindi." -ForegroundColor Green

Write-Host ""
Write-Host "  Kaldirildi. Acik PowerShell pencerelerinde 'cc' tanimi hafizada kalir;" -ForegroundColor Cyan
Write-Host "  tamamen gitmesi icin yeni bir pencere ac." -ForegroundColor Cyan
if (-not $DurumuSil -and (Test-Path -LiteralPath $durum)) {
    Write-Host "  Kayitlar duruyor: $durum" -ForegroundColor DarkGray
}
Write-Host ""
