# baslat.ps1 (v2) - Claude Code'u "oturum kaydi" ile baslatir.
# Kullanim: talep klasorunde PowerShell ac, "cc" yaz.
#
# Nasil calisir:
#   - Oturum acilinca durum\ klasorune kayit (.json) yazar, 15 sn'de bir heartbeat (.hb) damgasi basar.
#   - Pencere X ile / oturum kapanirken / sistem kapanirken .closed damgasi birakir, kaydi SILMEZ.
#   - Elektrik kesilir, mavi ekran olur, uykudan kapanirsa .closed yazilamaz ama son .hb kalir (en fazla 15 sn kayip).
#   - /exit ile duzgun cikarsan kaydi siler: o klasor bir daha otomatik onerilmez.

param(
    [string]$Klasor = (Get-Location).Path,
    [string]$B64    = '',          # Klasor yolunun base64'u (Turkce karakter guvenligi icin)
    [string]$Resume = ''           # Devam edilecek Claude session id
)

if ($B64) {
    $Klasor = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($B64))
}

$durum = Join-Path $PSScriptRoot 'durum'
New-Item -ItemType Directory -Force -Path $durum | Out-Null

if (-not ('OturumBekcisi' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public static class OturumBekcisi {
    delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);

    static HandlerRoutine _handler;
    static Timer _timer;
    static string _hb, _closed;

    public static void Baslat(string hbPath, string closedPath) {
        _hb = hbPath; _closed = closedPath;
        if (_timer != null) _timer.Dispose();
        Yaz(_hb);
        _timer = new Timer(_ => Yaz(_hb), null, 15000, 15000);
        if (_handler == null) {
            _handler = new HandlerRoutine(Kapanis);
            SetConsoleCtrlHandler(_handler, true);
        }
    }

    // 0 = Ctrl+C, 1 = Ctrl+Break (Claude'un kendi kisayollari, karisma)
    // 2 = pencere kapatma (X), 5 = oturum kapatma, 6 = sistem kapanisi
    static bool Kapanis(uint t) {
        if (t >= 2 && _closed != null) Yaz(_closed);
        return false;
    }

    public static void Durdur() {
        if (_timer != null) { _timer.Dispose(); _timer = null; }
        _closed = null;
    }

    static void Yaz(string p) {
        try { File.WriteAllText(p, DateTime.UtcNow.ToString("o")); } catch { }
    }
}
'@
}

if (-not (Test-Path -LiteralPath $Klasor)) {
    Write-Host "Klasor bulunamadi: $Klasor" -ForegroundColor Red
    Start-Sleep -Seconds 5
    return
}

# .Path DEGIL .ProviderPath: UNC yollarinda .Path
# "Microsoft.PowerShell.Core\FileSystem::\\sunucu\pay\..." seklinde saglayici onekli doner.
# Bu onek kayda girerse ayni klasor iki farkli kimlik uretir ve oturum iki kez acilir.
$Klasor = (Resolve-Path -LiteralPath $Klasor).ProviderPath.TrimEnd('\')
Set-Location -LiteralPath $Klasor
$ad = Split-Path -Leaf $Klasor

# Klasor yolundan sabit kimlik uret (ayni klasor = ayni kayit)
$sha   = [Security.Cryptography.SHA1]::Create()
$bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Klasor.ToLowerInvariant()))
$id    = -join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') })

# Kayit adina PID de girer. Ayni klasorde iki pencere acikken kayit adi sadece yoldan
# uretilseydi ikisi ayni dosyayi paylasirdi; biri /exit ile cikinca kayit digeri icin de
# silinir ve hayatta kalan pencere heartbeat kaydini kaybederdi.
$b     = Join-Path $durum "$id-$PID"

$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')

Remove-Item -LiteralPath "$b.closed" -ErrorAction SilentlyContinue
# Bu klasorde yeniden oturum aciliyor: varsa eski "/exit" mezar tasini kaldir
Remove-Item -LiteralPath (Join-Path $durum "$id.exit") -ErrorAction SilentlyContinue
$procStart = ''
try { $procStart = (Get-Process -Id $PID).StartTime.ToFileTime().ToString() } catch { }

[ordered]@{
    yol        = $Klasor
    ad         = $ad
    pid        = $PID
    procStart  = $procStart      # PID yeniden kullanimina karsi kimlik dogrulamasi
    boot       = $boot
    baslangic  = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath "$b.json" -Encoding UTF8

[OturumBekcisi]::Baslat("$b.hb", "$b.closed")
$Host.UI.RawUI.WindowTitle = $ad

# ---------------------------------------------------------------------------
# Hangi oturumun acilacagini ONCEDEN sec, sonra claude'u TEK sefer calistir.
#
# Iki kural:
#   - claude.exe her zaman dogrudan (statement olarak) cagrilir. Ciktisi bir degiskene
#     atanir ya da pipeline'a verilirse PowerShell stdout'u yonlendirir, claude da
#     terminal olmadigini sanip --print moduna duser ve "Input must be provided..." der.
#   - "--continue" kullanilmaz: o klasordeki EN SON konusmayi alir, bu da su an ACIK olan
#     oturum olabilir. Bunun yerine canli olmayan en yeni oturum id'si secilip --resume edilir.
# ---------------------------------------------------------------------------

function SurecCanli($surecId, $procStart) {
    if (-not $surecId) { return $false }
    $p = Get-Process -Id $surecId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if (-not $procStart) { return $true }
    try { return ($p.StartTime.ToFileTime().ToString() -eq $procStart.ToString()) } catch { return $true }
}

# Bu klasorde su an acik olan oturumlarin id'leri - ustlerine binme
$canliIdler = @()
$defter = Join-Path $HOME '.claude\sessions'
if (Test-Path -LiteralPath $defter) {
    foreach ($d in Get-ChildItem -LiteralPath $defter -Filter *.json -File -ErrorAction SilentlyContinue) {
        try { $k = Get-Content -LiteralPath $d.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $k.cwd -or $k.cwd.TrimEnd('\').ToLowerInvariant() -ne $Klasor.ToLowerInvariant()) { continue }
        if (SurecCanli $k.pid $k.procStart) { $canliIdler += $k.sessionId }
    }
}

$hedefId = $null
if ($Resume -and ($canliIdler -notcontains $Resume)) { $hedefId = $Resume }

# Bu klasorde zaten acik bir oturum varsa ve acikca bir id istenmediyse: eski bir konusmayi
# surdurme, yeni oturum ac. Kullanici zaten "devam eden"i acik tutuyor demektir.
if (-not $hedefId -and $canliIdler.Count -eq 0) {
    # Claude proje klasoru adi: alfanumerik olmayan her karakter '-' olur
    $slug = [regex]::Replace($Klasor, '[^a-zA-Z0-9]', '-')
    $pd   = Join-Path $HOME ".claude\projects\$slug"
    if (Test-Path -LiteralPath $pd) {
        $hedefId = Get-ChildItem -LiteralPath $pd -Filter *.jsonl -File -ErrorAction SilentlyContinue |
                   Where-Object { $canliIdler -notcontains $_.BaseName -and $_.Length -gt 1kb } |
                   Sort-Object LastWriteTimeUtc -Descending |
                   Select-Object -First 1 -ExpandProperty BaseName
    }
}

if ($canliIdler.Count -gt 0) {
    Write-Host "Not: bu klasorde zaten acik bir Claude oturumu var; ona dokunulmadan yeni oturum aciliyor." -ForegroundColor Yellow
}

if ($hedefId) {
    Write-Host "Kaldigi yerden devam ediliyor..." -ForegroundColor DarkGray
    claude --resume $hedefId
    $kod = $LASTEXITCODE
    # Secilen oturum acilamadiysa (bozuk/eski kayit) tek bir kez yeni oturumla dene
    if ($kod -ne 0 -and -not (Test-Path -LiteralPath "$b.closed")) {
        Write-Host "Oturum acilamadi, yeni oturum aciliyor..." -ForegroundColor Yellow
        claude
    }
} else {
    Write-Host "Bu klasorde devam edilecek konusma yok, yeni oturum aciliyor..." -ForegroundColor DarkGray
    claude
}
Start-Sleep -Milliseconds 400

# Pencere kapaniyorsa (X / oturum / sistem kapanisi) kaydi birak, karari GeriYukle.ps1 versin
if (Test-Path -LiteralPath "$b.closed") { return }

# Buraya geldiysek /exit ile bilincli cikis yapildi: kaydi sil
[OturumBekcisi]::Durdur()
Remove-Item -LiteralPath "$b.json", "$b.hb" -ErrorAction SilentlyContinue

# /exit sozlesmesi: bu klasor bir daha onerilmemeli. Kendi kaydimizi sildik, Claude da kendi
# defter kaydini sildi. Ama ANLIK GORUNTU 10 dakikada bir tazeleniyor; cikis ile restart
# arasina tazeleme girmezse goruntu bu klasoru hala icerir ve oturum geri onerilirdi.
# O yuzden goruntuyu hemen tazele ve tuketilmemis eski goruntuden de bu klasoru cikar.
$anlikScript = Join-Path $PSScriptRoot 'Anlik.ps1'
if (Test-Path -LiteralPath $anlikScript) { & $anlikScript }

# Mezar tasi: transcript katmani acik/kapali ayrimi yapamadigi icin bu klasoru yine
# onerirdi. Bu damga "burasi bilerek kapatildi" der; GeriYukle transcript'i bundan
# eski ise atlar. Klasorde yeniden oturum acilinca damga kalkar.
try { [IO.File]::WriteAllText((Join-Path $durum "$id.exit"), (Get-Date).ToUniversalTime().ToString('o')) } catch { }

$oncekiGoruntu = Join-Path $durum 'anlik-onceki.json'
if (Test-Path -LiteralPath $oncekiGoruntu) {
    try {
        $g = Get-Content -LiteralPath $oncekiGoruntu -Raw -Encoding UTF8 | ConvertFrom-Json
        $hepsi = @($g.oturumlar)
        $kalan = @($hepsi | Where-Object {
            $_.yol -and $_.yol.TrimEnd('\').ToLowerInvariant() -ne $Klasor.ToLowerInvariant()
        })
        if ($kalan.Count -ne $hepsi.Count) {
            $g.oturumlar = $kalan
            $g | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $oncekiGoruntu -Encoding UTF8
        }
    } catch { }
}

Write-Host "Oturum kapatildi. '$ad' bir daha otomatik onerilmeyecek." -ForegroundColor DarkGray
