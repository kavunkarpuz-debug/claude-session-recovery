\xEF\xBB\xBF# baslat.ps1 - Claude Code'u "oturum kaydi" ile baslatir.
# Kullanim: talep klasorunde PowerShell ac, "cc" yaz (Kurulum.ps1 bu kisayolu ekler).
#
# Nasil calisir:
#   - Oturum acilinca durum\ klasorune bir kayit (.json) yazar, 30 sn'de bir "hala yasiyorum" (.hb) damgasi basar.
#   - Pencere X ile ya da sistem kapanirken kapanirsa .closed damgasi birakir, kaydi silmez.
#   - Claude'dan /exit ile duzgun cikarsan kaydi siler: o klasor bir daha otomatik acilmaz.

param([string]$Klasor = (Get-Location).Path)

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
        _timer = new Timer(_ => Yaz(_hb), null, 30000, 30000);
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

$Klasor = (Resolve-Path -LiteralPath $Klasor).Path.TrimEnd('\')
Set-Location -LiteralPath $Klasor
$ad = Split-Path -Leaf $Klasor

# Klasor yolundan sabit bir kimlik uret (ayni klasor = ayni kayit)
$sha   = [Security.Cryptography.SHA1]::Create()
$bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Klasor.ToLowerInvariant()))
$id    = -join ($bytes[0..5] | ForEach-Object { $_.ToString('x2') })
$b     = Join-Path $durum $id

Remove-Item -LiteralPath "$b.closed" -ErrorAction SilentlyContinue
[ordered]@{ yol = $Klasor; ad = $ad } | ConvertTo-Json | Set-Content -LiteralPath "$b.json" -Encoding UTF8
[OturumBekcisi]::Baslat("$b.hb", "$b.closed")
$Host.UI.RawUI.WindowTitle = $ad

$t0 = Get-Date
claude --continue
$kod = $LASTEXITCODE
Start-Sleep -Milliseconds 500

# --continue hemen hata verdiyse bu klasorde eski konusma yok demektir: yeni oturum ac
if ($kod -ne 0 -and -not (Test-Path -LiteralPath "$b.closed") -and ((Get-Date) - $t0).TotalSeconds -lt 15) {
    Write-Host "Bu klasorde devam edilecek konusma yok, yeni oturum aciliyor..." -ForegroundColor Yellow
    claude --rc $ad
    Start-Sleep -Milliseconds 500
}

# Pencere kapaniyorsa (X ya da sistem kapanisi) kaydi birak, karari GeriYukle.ps1 versin
if (Test-Path -LiteralPath "$b.closed") { return }

# Buraya geldiysek /exit ile bilincli cikis yapildi: kaydi sil
[OturumBekcisi]::Durdur()
Remove-Item -LiteralPath "$b.json", "$b.hb" -ErrorAction SilentlyContinue
Write-Host "Oturum kapatildi. '$ad' bir daha otomatik acilmayacak." -ForegroundColor DarkGray
