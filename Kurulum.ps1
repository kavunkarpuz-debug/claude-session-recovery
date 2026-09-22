# Kurulum.ps1 (v2) - Bir kere calistir. Tekrar calistirmak zararsizdir (uzerine yazar).
#   powershell -ExecutionPolicy Bypass -File .\Kurulum.ps1

$kaynak = $PSScriptRoot

# Calisan kisim .claude altinda durur: "dokunma" kurali tek bir yere iner ve
# durum\ her 10 dk yazdigi icin OneDrive senkron trafigi yaratmaz.
# Kaynak kopya (bu klasor) OneDrive'da kalir - yedeklenmesi gereken tek parca odur.
$hedef  = Join-Path $HOME '.claude\oturum-kurtarma'
New-Item -ItemType Directory -Force -Path $hedef, (Join-Path $hedef 'durum') | Out-Null

# 1. Scriptleri yerine koy, internetten indirilme isaretini kaldir
foreach ($f in 'baslat.ps1', 'GeriYukle.ps1', 'Anlik.ps1', 'YeniTab.ps1') {
    Copy-Item -LiteralPath (Join-Path $kaynak $f) -Destination $hedef -Force
    Unblock-File -LiteralPath (Join-Path $hedef $f)
}
Write-Host "[1/4] Scriptler kopyalandi: $hedef" -ForegroundColor Green

# 2. PowerShell profiline "cc" ve "cc-geri" komutlarini ekle
$bas = '# >>> ClaudeOturum >>>'
$son = '# <<< ClaudeOturum <<<'
$blok = @"
$bas
function cc      { & "$hedef\baslat.ps1" @args }
function cc-geri { & "$hedef\GeriYukle.ps1" -Mod Manuel @args }
function cc-tab  { & "$hedef\YeniTab.ps1" @args }
$son
"@

$belgeler = [Environment]::GetFolderPath('MyDocuments')
$profiller = @(
    $PROFILE,
    (Join-Path $belgeler 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $belgeler 'PowerShell\Microsoft.PowerShell_profile.ps1')
) | Where-Object { $_ } | Select-Object -Unique

foreach ($p in $profiller) {
    $dizin = Split-Path -Parent $p
    # pwsh 7 kurulu degilse onun profil klasorunu olusturma
    if (-not (Test-Path -LiteralPath $dizin)) {
        if ($p -ne $PROFILE) { continue }
        New-Item -ItemType Directory -Force -Path $dizin | Out-Null
    }

    $icerik = ''
    if (Test-Path -LiteralPath $p) {
        # Once yedek al
        Copy-Item -LiteralPath $p -Destination "$p.claudeoturum-yedek" -Force
        # ONEMLI: acik UTF-8 olarak oku. Windows PowerShell 5.1'in varsayilani ANSI'dir;
        # BOM'suz UTF-8 bir profili ANSI okuyup geri yazmak Turkce karakterleri kalici bozar.
        $icerik = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    }

    # eski blogu ve v1'den kalan tek satirlik cc tanimini temizle
    $icerik = [regex]::Replace($icerik, "(?s)\r?\n?$([regex]::Escape($bas)).*?$([regex]::Escape($son))", '')
    $icerik = [regex]::Replace($icerik, "(?m)^\s*#\s*Claude Code oturum kaydi\s*\r?\n", '')
    $icerik = [regex]::Replace($icerik, "(?m)^\s*function cc \{.*\}\s*\r?\n?", '')

    # BOM'lu UTF-8 yaz: hem icerik korunur hem de PowerShell 5.1 dosyayi dogru okur
    [IO.File]::WriteAllText($p, ($icerik.TrimEnd() + "`r`n`r`n" + $blok + "`r`n"), (New-Object Text.UTF8Encoding($true)))
    Write-Host "      profil guncellendi: $p" -ForegroundColor DarkGray
}
Write-Host "[2/4] 'cc' ve 'cc-geri' komutlari eklendi." -ForegroundColor Green

# 3. Windows acilisinda GeriYukle.ps1 (Otomatik mod) calissin
$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Oturum Geri Yukle.lnk'))
$lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments  = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hedef\GeriYukle.ps1`" -Mod Otomatik"
$lnk.Save()
Write-Host "[3/4] Acilis kisayolu olusturuldu." -ForegroundColor Green

# 4. Anlik goruntu gorevi: acik oturumlarin listesini birkac dakikada bir kaydet.
#    Bu olmadan, duzgun restart'ta claude kendi kaydini siler ve "neler acikti" bilgisi kaybolur.
$gorev = 'Claude Oturum Anlik Goruntu'
$ps    = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$argv  = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hedef\Anlik.ps1`""

# Hemen bir goruntu al - gorev kurulsun kurulmasin, su an acik olanlar korunmus olsun
& "$hedef\Anlik.ps1"

Unregister-ScheduledTask -TaskName $gorev -Confirm:$false -ErrorAction SilentlyContinue | Out-Null

# Yontem A: PowerShell cmdlet'leri.
# NOT: -RepetitionDuration [TimeSpan]::MaxValue kullanilmaz; Gorev Zamanlayici
# P99999999DT23H59M59S degerini reddediyor. Duration'i hic vermemek = suresiz tekrar.
try {
    $eylem = New-ScheduledTaskAction -Execute $ps -Argument $argv
    $tetik = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
             -RepetitionInterval (New-TimeSpan -Minutes 10)
    $ayar  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
             -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
             -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $gorev -Action $eylem -Trigger $tetik -Settings $ayar `
        -Description 'Acik Claude oturumlarinin listesini kaydeder; ani kapanma sonrasi geri yukleme icin.' `
        -ErrorAction Stop | Out-Null
} catch {
    Write-Host "      cmdlet yontemi olmadi ($($_.Exception.Message.Split([char]10)[0])), schtasks deneniyor..." -ForegroundColor DarkGray
}

# Yontem B: cmdlet tutmadiysa schtasks.exe
if (-not (Get-ScheduledTask -TaskName $gorev -ErrorAction SilentlyContinue)) {
    $null = schtasks.exe /Create /TN $gorev /TR "$ps $argv" /SC MINUTE /MO 10 /F 2>&1
}

# ---- Gercekten kuruldu mu? Basarili yazmadan once DOGRULA ----
$t = Get-ScheduledTask -TaskName $gorev -ErrorAction SilentlyContinue
if ($t) {
    Start-ScheduledTask -TaskName $gorev -ErrorAction SilentlyContinue
    $tekrar = $t.Triggers[0].Repetition.Interval
    $sayi   = 0
    $anlik  = Join-Path $hedef 'durum\anlik.json'
    if (Test-Path -LiteralPath $anlik) {
        $sayi = @((Get-Content -LiteralPath $anlik -Raw -Encoding UTF8 | ConvertFrom-Json).oturumlar).Count
    }
    Write-Host "[4/4] Anlik goruntu gorevi KURULDU. Tekrar araligi: $tekrar" -ForegroundColor Green
    Write-Host "      Su an kayitli acik oturum: $sayi" -ForegroundColor Green
} else {
    Write-Host "[4/4] Anlik goruntu gorevi KURULAMADI." -ForegroundColor Red
    Write-Host "      Sistem yine calisir ama duzgun restart'ta uzun suredir sessiz duran" -ForegroundColor Yellow
    Write-Host "      oturumlar kacabilir. Goruntu su an elle alindi, tazelenmeyecek." -ForegroundColor Yellow
}

# Profilin yuklenebilmesi icin script calistirma izni lazim
$pol = try { Get-ExecutionPolicy } catch { $null }
if ($pol -in 'Restricted', 'AllSigned') {
    Write-Host ""
    Write-Host "DIKKAT: Script calistirma politikan '$pol'. 'cc' komutunun calismasi icin:" -ForegroundColor Yellow
    Write-Host "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" -ForegroundColor Yellow
    Write-Host "Sirket politikasi engelliyorsa hata verir; o zaman IT'ye gitmen gerekir." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Bitti. Yeni bir PowerShell penceresi ac." -ForegroundColor Cyan
Write-Host "  cc        -> bulundugun klasorde Claude'u kayitli baslat" -ForegroundColor Cyan
Write-Host "  cc-geri   -> kaybolan oturumlari istedigin an listele ve geri ac" -ForegroundColor Cyan
Write-Host "  cc-tab    -> baska bir klasoru AYNI pencerede yeni sekme olarak ac" -ForegroundColor Cyan
