\xEF\xBB\xBF# GeriYukle.ps1 - Bilgisayar acilinca, kapanis aninda acik olan Claude oturumlarini geri getirir.
# Windows acilisinda otomatik calisir (Kurulum.ps1 Baslangic klasorune kisayol koyar).
#
# Karar mantigi:
#   1. Sadece bir onceki acilistan kalan kayitlara bakar.
#   2. Kapanis aninda ayni anda "olen" oturumlari bulur (90 sn'lik kume).
#   3. Bu kume sistem kapanisina yakinsa (15 dk) geri getirir.
#   4. Daha once X ile kapatilip birakilmis eski kayitlar kumeye girmez, silinir.

$ErrorActionPreference = 'SilentlyContinue'
$kok        = $PSScriptRoot
$durum      = Join-Path $kok 'durum'
$baslat     = Join-Path $kok 'baslat.ps1'
$log        = Join-Path $kok 'geri-yukleme.log'
$KUME_SN    = 90
$KAPANIS_DK = 15

function Log($m) { Add-Content -LiteralPath $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) }
function Oku($p) {
    if (Test-Path -LiteralPath $p) {
        [datetime]::Parse((Get-Content -LiteralPath $p -Raw).Trim(),
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
}

if (-not (Test-Path -LiteralPath $durum)) { return }
Start-Sleep -Seconds 10   # oturum acilisi ve ag otursun

$acilis    = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$acilisUtc = $acilis.ToUniversalTime()

$kayitlar = @()
foreach ($j in Get-ChildItem -LiteralPath $durum -Filter *.json) {
    $b = Join-Path $durum $j.BaseName
    $zaman = @((Oku "$b.closed"), (Oku "$b.hb")) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
    if (-not $zaman) { continue }
    $bilgi = Get-Content -LiteralPath $j.FullName -Raw | ConvertFrom-Json
    $kayitlar += [pscustomobject]@{ Base = $b; Yol = $bilgi.yol; Ad = $bilgi.ad; Bitis = $zaman }
}

# Bu acilista hala calisan / bu acilista kapatilanlara dokunma
$adaylar = @($kayitlar | Where-Object { $_.Bitis -lt $acilisUtc })
if ($adaylar.Count -eq 0) { Log 'Onceki acilistan kalan oturum yok.'; return }

$sonOlum = ($adaylar | Sort-Object Bitis -Descending | Select-Object -First 1).Bitis

# Sistem kapanis ani: acilistan onceki son sistem olayi
$sonOlay = Get-WinEvent -FilterHashtable @{ LogName = 'System'; EndTime = $acilis } -MaxEvents 1 |
           Select-Object -ExpandProperty TimeCreated
$kapanisaYakin = $true
if ($sonOlay) { $kapanisaYakin = $sonOlum -ge $sonOlay.ToUniversalTime().AddMinutes(-$KAPANIS_DK) }

$geri = @()
if ($kapanisaYakin) {
    $geri = @($adaylar | Where-Object { $_.Bitis -ge $sonOlum.AddSeconds(-$KUME_SN) -and (Test-Path -LiteralPath $_.Yol) })
}

# Eski kayitlarin hepsini temizle; geri gelenler acilinca kendi kaydini yeniden yazar
foreach ($a in $adaylar) {
    Remove-Item -LiteralPath "$($a.Base).json", "$($a.Base).hb", "$($a.Base).closed" -ErrorAction SilentlyContinue
}

if ($geri.Count -eq 0) { Log "Geri getirilecek oturum yok ($($adaylar.Count) eski kayit temizlendi)."; return }

$tabs = foreach ($g in $geri) {
    "new-tab --title `"$($g.Ad)`" --suppressApplicationTitle -d `"$($g.Yol)`" powershell -NoExit -ExecutionPolicy Bypass -File `"$baslat`""
}
Start-Process wt -ArgumentList ($tabs -join ' ; ')
Log ("Geri getirildi: " + (($geri | ForEach-Object { $_.Ad }) -join ', '))
