# GeriYukle.ps1 (v2) - Kapanis aninda acik olan Claude oturumlarini geri getirir.
#
# Modlar:
#   -Mod Otomatik : Windows acilisinda gizli calisir. Aday varsa kendini Sor modunda gorunur acar.
#   -Mod Sor      : Listeyi gosterir, sec ve ac. (Otomatik modun actigi ekran)
#   -Mod Manuel   : "cc-geri" komutu. Boot filtresi yok, son -Saat icinde aktif her oturumu listeler.
#
# ZAMAN PENCERESI SADECE TRANSCRIPT KATMANINA UYGULANIR.
# "Kapanis aninda acik miydi" bir CANLILIK sorusudur, "ne zaman yazildi" sorusu degil.
# Bir hafta hic dokunulmamis ama acik duran oturum da geri gelmelidir. Asagidaki 0, 1 ve 2
# numarali kaynaklar "acikti" kanitidir; onlara -Saat penceresi uygulanmaz (sadece 30 gunluk
# akil saglig siniri vardir). Yalnizca 3. kaynak acik/kapali ayrimi yapamadigi icin pencereye tabidir.
#
# Dort bagimsiz kaynaktan aday toplar (oncelik sirasiyla):
#   0. durum\anlik-onceki.json -> Anlik.ps1'in kapanmadan once aldigi goruntu. EN GUVENILIR.
#      claude duzgun kapanista kendi kaydini sildigi icin bu goruntu olmadan restart'ta iz kalmaz.
#   1. ~\.claude\sessions\<pid>.json -> Claude'un kendi canli oturum defteri. cwd + sessionId + pid verir.
#      Oturum duzgun kapaninca dosya silinir; cokme/elektrik kesintisinde KALIR. Tam da aradigimiz iz.
#      pid + procStart ile hala calisip calismadigi kesin anlasilir (yeniden acilista pid tekrar kullanilabilir).
#   2. durum\*.json -> "cc" ile acilmis oturumlarin heartbeat kayitlari. Kapanisin turunu (ani kesinti mi,
#      pencere kapatma mi) soyler.
#   3. ~\.claude\projects\*\*.jsonl -> transcriptler. 1. kaynak temizlenmisse son care.
#      DIKKAT: transcript icindeki cwd shell "cd" ile degisebiliyor, o yuzden ILK cwd satiri kullanilir.
# Kaynaklar klasor yoluna gore birlestirilir.

param(
    [ValidateSet('Otomatik', 'Sor', 'Manuel', 'Listele')][string]$Mod = 'Sor',
    [int]$Saat = 12,
    [switch]$OncekiAcilis   # sadece Listele modu icin: acilis filtresini de uygula (teshis amacli)
)

$ErrorActionPreference = 'Continue'
$kok      = $PSScriptRoot
$durum    = Join-Path $kok 'durum'
$baslat   = Join-Path $kok 'baslat.ps1'
$log      = Join-Path $kok 'geri-yukleme.log'
$projeler = Join-Path $HOME '.claude\projects'
$defter   = Join-Path $HOME '.claude\sessions'
$anlikSimdi   = Join-Path $durum 'anlik.json'
$anlikOnceki  = Join-Path $durum 'anlik-onceki.json'

function Log($m) {
    try { Add-Content -LiteralPath $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  [{1}] {2}" -f (Get-Date), $Mod, $m) } catch { }
}
function B64($s) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
# Yolu kanonik hale getir. Iki tuzak var:
#   1. Resolve-Path UNC'de "Microsoft.PowerShell.Core\FileSystem::\\sunucu\..." dondurebiliyor.
#   2. Turkce karakterler kaynaga gore ayrisik (NFD) gelebiliyor.
# Ikisi de ayni klasorun iki ayri aday gibi gorunmesine yol acar.
function TemizYol($yol) {
    if (-not $yol) { return $yol }
    $y = $yol -replace '^Microsoft\.PowerShell\.Core\\FileSystem::', ''
    $y = $y.TrimEnd('\')
    try { $y = $y.Normalize([Text.NormalizationForm]::FormC) } catch { }
    return $y
}
function Anahtar($yol) { (TemizYol $yol).ToLowerInvariant() }

# baslat.ps1'in kayit adinda kullandigi klasor kimligi ile AYNI hesap.
# "/exit" mezar tasini bulmak icin gerekiyor.
function KlasorKimligi($yol) {
    $sha   = [Security.Cryptography.SHA1]::Create()
    $bayt  = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes((Anahtar $yol)))
    return (-join ($bayt[0..5] | ForEach-Object { $_.ToString('x2') }))
}

function ZamanOku($p) {
    if (Test-Path -LiteralPath $p) {
        try {
            [datetime]::Parse((Get-Content -LiteralPath $p -Raw).Trim(),
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        } catch { $null }
    }
}

# Transcriptin BASINDAN calisma klasorunu cikar (sondaki cwd shell cd ile kaymis olabilir)
function CwdOku($p) {
    try { $satirlar = @(Get-Content -LiteralPath $p -TotalCount 60 -Encoding UTF8 -ErrorAction Stop) } catch { return $null }
    foreach ($s in $satirlar) {
        $m = [regex]::Match($s, '"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"')
        if ($m.Success) { return ($m.Groups[1].Value -replace '\\\\', '\') }
    }
    return $null
}

# Bir surec hala calisiyor mu? PID yeniden kullanilmis olabilecegi icin baslangic zamani da dogrulanir.
function SurecCanli($surecId, $procStart) {
    if (-not $surecId) { return $false }
    $p = Get-Process -Id $surecId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if (-not $procStart) { return $true }
    try { return ($p.StartTime.ToFileTime().ToString() -eq $procStart.ToString()) } catch { return $true }
}

# durum\ kaydinin KENDI penceresi hala yasiyor mu?
# Not: eski surumden kalan kayitlarda procStart yok; onlarda boot damgasina bakilir.
function KayitCanli($kayit, $buBootUtc) {
    if (-not $kayit.pid) { return $false }
    if ($kayit.procStart) { return (SurecCanli $kayit.pid $kayit.procStart) }
    if ($kayit.boot -ne $buBootUtc.ToString('o')) { return $false }
    return ($null -ne (Get-Process -Id $kayit.pid -ErrorAction SilentlyContinue))
}

# ---------------------------------------------------------------- aday toplama
function AdaylariTopla($buBootUtc, $sinirUtc, $sadeceOncekiAcilis) {
    $sonuc   = [ordered]@{}
    $eskiler = @()
    $canli   = New-Object 'System.Collections.Generic.HashSet[string]'
    $enEski  = (Get-Date).ToUniversalTime().AddDays(-30)   # akil sagligi siniri

    # ON GECIS: su an CANLI olan klasorleri once topla.
    # Bu yapilmazsa 0. kaynak (anlik goruntu) daha once calistigi icin, geri acilmis bir
    # oturumu -yeni pid'i eski goruntudekiyle tutmadigindan- "olu" sanip tekrar tekrar onerir.
    if (Test-Path -LiteralPath $defter) {
        foreach ($d in Get-ChildItem -LiteralPath $defter -Filter *.json -File -ErrorAction SilentlyContinue) {
            try { $k = Get-Content -LiteralPath $d.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if ($k.cwd -and (SurecCanli $k.pid $k.procStart)) { [void]$canli.Add((Anahtar $k.cwd)) }  # Anahtar zaten temizliyor
        }
    }

    # 0) Anlik goruntu: kapanmadan onceki son durum. Zaman penceresine TABI DEGIL.
    foreach ($dosya in @($anlikOnceki, $anlikSimdi)) {
        if (-not (Test-Path -LiteralPath $dosya)) { continue }
        try { $g = Get-Content -LiteralPath $dosya -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $g.oturumlar) { continue }
        # Bu acilistan olan goruntu, "onceki acilis" moduna aday veremez
        if ($sadeceOncekiAcilis -and $g.boot -eq $buBootUtc.ToString('o')) { continue }

        $zaman = $buBootUtc
        try { $zaman = [datetime]::Parse($g.zaman, [Globalization.CultureInfo]::InvariantCulture,
                                         [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { }

        foreach ($o in $g.oturumlar) {
            if (-not $o.yol) { continue }
            $oYol = TemizYol $o.yol
            $a = Anahtar $oYol
            if ($canli.Contains($a) -or $sonuc.Contains($a)) { continue }
            if (SurecCanli $o.pid $o.procStart) { [void]$canli.Add($a); continue }
            if (-not (Test-Path -LiteralPath $oYol)) { continue }

            $sonuc[$a] = [pscustomobject]@{
                Yol       = $oYol
                Ad        = (Split-Path -Leaf $oYol)
                Zaman     = $zaman
                SessionId = $o.sessionId
                Tip       = 'acik kalmis'
            }
        }
    }

    # 1) Claude'un canli oturum defteri  (en guvenilir kaynak)
    if (Test-Path -LiteralPath $defter) {
        foreach ($d in Get-ChildItem -LiteralPath $defter -Filter *.json -File -ErrorAction SilentlyContinue) {
            try { $k = Get-Content -LiteralPath $d.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if (-not $k.cwd) { continue }
            $kYol = TemizYol $k.cwd
            $a = Anahtar $kYol

            if (SurecCanli $k.pid $k.procStart) { [void]$canli.Add($a); continue }   # su an acik, dokunma
            # Bu klasorde BASKA bir canli oturum var. Elimizdeki kayit, kapanista temizlenememis
            # eski bir kayittir (restart'ta claude her zaman temizlik yapamiyor). Aday sayma.
            if ($canli.Contains($a)) { continue }

            # Oturumun son aktivitesi: defterin kendi damgasi esas. Dosya mtime'i baska bir sey
            # (temizlik, senkronizasyon) tarafindan guncellenmis olabilir, ona guvenme.
            $zaman = $null
            if ($k.updatedAt) {
                try { $zaman = [datetimeoffset]::FromUnixTimeMilliseconds([int64]$k.updatedAt).UtcDateTime } catch { }
            }
            if (-not $zaman) { $zaman = $d.LastWriteTimeUtc }
            if ($sadeceOncekiAcilis -and $zaman -ge $buBootUtc) { continue }
            if ($zaman -lt $enEski) { continue }   # pencere degil, sadece 30 gun siniri
            if (-not (Test-Path -LiteralPath $kYol)) { continue }
            if ($sonuc.Contains($a)) { continue }

            $sonuc[$a] = [pscustomobject]@{
                Yol       = $kYol
                Ad        = (Split-Path -Leaf $kYol)
                Zaman     = $zaman
                SessionId = $k.sessionId
                Tip       = 'acik kalmis'
            }
        }
    }

    # 2) durum kayitlari
    if (Test-Path -LiteralPath $durum) {
        foreach ($j in Get-ChildItem -LiteralPath $durum -Filter *.json -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -notlike 'anlik*' }) {
            $base = Join-Path $durum $j.BaseName
            try { $k = Get-Content -LiteralPath $j.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if (-not $k.yol) { continue }

            $kapanis = ZamanOku "$base.closed"
            $zaman   = @($kapanis, (ZamanOku "$base.hb")) | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
            if (-not $zaman) { continue }

            $dYol = TemizYol $k.yol
            $a = Anahtar $dYol

            # Once KAYDIN KENDI penceresine bak: yasiyorsa kayit duruyor, klasor canli sayilir.
            if (KayitCanli $k $buBootUtc) { [void]$canli.Add($a); continue }

            # Kendi penceresi olmus: kayit tuketilebilir. Bu, klasorde baska bir oturum
            # acik olsa bile gecerli - yoksa olu kayitlar kalici artik haline gelir.
            $eskiler += $base

            if ($canli.Contains($a)) { continue }                     # klasorde baska canli oturum var
            if ($sadeceOncekiAcilis -and $zaman -ge $buBootUtc) { continue }
            if ($zaman -lt $enEski) { continue }   # pencere degil, sadece 30 gun siniri
            if (-not (Test-Path -LiteralPath $dYol)) { continue }

            $tip = $(if ($kapanis) { 'pencere kapandi' } else { 'ANI KESINTI' })
            if ($sonuc.Contains($a)) {
                # defterden gelen kaydi zenginlestir: kapanisin turunu heartbeat daha iyi bilir
                $sonuc[$a].Tip = $tip
                if ($zaman -gt $sonuc[$a].Zaman) { $sonuc[$a].Zaman = $zaman }
                continue
            }
            $sonuc[$a] = [pscustomobject]@{
                Yol       = $dYol
                Ad        = (Split-Path -Leaf $dYol)
                Zaman     = $zaman
                SessionId = $null
                Tip       = $tip
            }
        }
    }

    # 3) transcript taramasi (son care)
    if (Test-Path -LiteralPath $projeler) {
        $dosyalar = Get-ChildItem -LiteralPath $projeler -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Filter *.jsonl -File -ErrorAction SilentlyContinue } |
                    Where-Object {
                        $_.LastWriteTimeUtc -ge $sinirUtc -and
                        ((-not $sadeceOncekiAcilis) -or ($_.LastWriteTimeUtc -lt $buBootUtc))
                    } |
                    Sort-Object LastWriteTimeUtc -Descending

        foreach ($d in $dosyalar) {
            $yol = TemizYol (CwdOku $d.FullName)
            if (-not $yol -or -not (Test-Path -LiteralPath $yol)) { continue }
            $a = Anahtar $yol
            if ($canli.Contains($a)) { continue }

            # "/exit" ile bilerek kapatilmis mi? Transcript acik/kapali ayrimi yapamaz;
            # damga transcript'ten YENI ise bu klasor kasten kapatilmistir, onerme.
            $mezar = Join-Path $durum ((KlasorKimligi $yol) + '.exit')
            if (Test-Path -LiteralPath $mezar) {
                $mz = ZamanOku $mezar
                if ($mz -and $mz -ge $d.LastWriteTimeUtc) { continue }
            }
            if ($sonuc.Contains($a)) {
                if (-not $sonuc[$a].SessionId) { $sonuc[$a].SessionId = $d.BaseName }   # en yeni transcript
                continue
            }
            $sonuc[$a] = [pscustomobject]@{
                Yol       = $yol
                Ad        = (Split-Path -Leaf $yol)
                Zaman     = $d.LastWriteTimeUtc
                SessionId = $d.BaseName
                Tip       = 'transcript'
            }
        }
    }

    return [pscustomobject]@{
        Adaylar = @($sonuc.Values | Sort-Object Zaman -Descending)
        Eskiler = $eskiler
    }
}

function EskileriTemizle($eskiler) {
    foreach ($b in $eskiler) {
        Remove-Item -LiteralPath "$b.json", "$b.hb", "$b.closed" -ErrorAction SilentlyContinue
    }
    # Onceki acilisin goruntusu tuketildi. Silinmezse ayni oturumlar her seferinde
    # yeniden onerilir; kullanici karar verdikten sonra kanit gorevi bitmis olur.
    Remove-Item -LiteralPath $anlikOnceki -Force -ErrorAction SilentlyContinue

    # .json'i olmayan sahipsiz .hb / .closed dosyalarini supur. Bunlar yalnizca
    # *.json uzerinden gezildigi icin baska hicbir yerde temizlenmez. 1 saatlik
    # dokunulmama sarti, yazmaya devam eden canli bir pencereyi korur.
    $sinir = (Get-Date).AddHours(-1)
    foreach ($art in Get-ChildItem -LiteralPath $durum -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.Extension -eq '.hb' -or $_.Extension -eq '.closed' }) {
        $sahip = Join-Path $durum ($art.BaseName + '.json')
        if ((-not (Test-Path -LiteralPath $sahip)) -and $art.LastWriteTime -lt $sinir) {
            Remove-Item -LiteralPath $art.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- oturumlari ac
# DIKKAT: bu fonksiyonun adi 'Ac' OLAMAZ. PowerShell komut cozumleme sirasi
# Alias > Function > Cmdlet oldugu icin 'Ac' cagrisi yerlesik 'ac' alias'ina,
# yani Add-Content'e gider; fonksiyon hic calismaz ve ekranda 'Value[0]:' sorulur.
function OturumlariAc($secilenler) {
    $parcalar = foreach ($g in $secilenler) {
        $argv = "-B64 $(B64 $g.Yol)"
        if ($g.SessionId) { $argv += " -Resume $($g.SessionId)" }
        # wt komut satirinda ';' komut ayiricidir ve sekmeler zaten ' ; ' ile ayriliyor.
        # Klasor adinda ';' gecerse komut yanlis yerden bolunur; baslik kozmetik, temizle.
        $baslik = $g.Ad -replace '[;"]', '-'
        "new-tab --title `"$baslik`" --suppressApplicationTitle powershell -NoExit -ExecutionPolicy Bypass -File `"$baslat`" $argv"
    }
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        # "-w 0" = en son kullanilan pencere. Bu verilmezse wt, hangi pencereyi kullanacagina
        # kendi varsayilanina gore karar verir ve cagrildigi baglama gore YENI PENCERE acabilir.
        # Acilista hic pencere yoksa -w 0 zaten yeni pencere olusturur, yani her iki durumda dogru.
        Start-Process wt.exe -ArgumentList ('-w 0 ' + ($parcalar -join ' ; '))
    } else {
        foreach ($g in $secilenler) {
            # DIKKAT: yol tirnak ICINE alinmaz. Start-Process -ArgumentList bir dizi aldiginda
            # bosluklu elemanlari kendisi tirnaklar; elle tirnak eklemek cift tirnaga yol acar
            # ve powershell dosyayi bulamaz.
            $argv = @('-NoExit', '-ExecutionPolicy', 'Bypass', '-File', $baslat, '-B64', (B64 $g.Yol))
            if ($g.SessionId) { $argv += @('-Resume', $g.SessionId) }
            Start-Process powershell -ArgumentList $argv
        }
    }
    Log ("Acildi: " + (($secilenler | ForEach-Object { $_.Ad }) -join ', '))

    # Yeni acilan oturumlarin Claude'un defterine yazilmasi ~1 dakika suruyor. Zamanlanmis
    # gorevi (10 dk) beklersek o araliktaki anlik goruntu BOS kalir; tam o sirada bir cokme
    # olursa 0. katman "hicbir sey acik degildi" der. Gecikmeli bir tazeleme ile bu bosluk kapanir.
    $anlikScript = Join-Path $kok 'Anlik.ps1'
    if (Test-Path -LiteralPath $anlikScript) {
        Start-Process powershell -WindowStyle Hidden -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command',
            "Start-Sleep -Seconds 75; & `"$anlikScript`""
        )
        Log "Anlik goruntu 75 sn sonra tazelenecek."
    }
}

# ---------------------------------------------------------------- secim ekrani
function SecimEkrani($adaylar, $ustyazi) {
    $isaretli = New-Object 'System.Collections.Generic.HashSet[int]'
    0..($adaylar.Count - 1) | ForEach-Object { [void]$isaretli.Add($_) }

    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "  CLAUDE OTURUM GERI YUKLEME" -ForegroundColor Cyan
        Write-Host "  $ustyazi" -ForegroundColor DarkGray
        Write-Host ""
        for ($i = 0; $i -lt $adaylar.Count; $i++) {
            $a     = $adaylar[$i]
            $tik   = $(if ($isaretli.Contains($i)) { 'x' } else { ' ' })
            $renk  = $(if ($isaretli.Contains($i)) { 'White' } else { 'DarkGray' })
            $dk    = [int]((Get-Date).ToUniversalTime() - $a.Zaman).TotalMinutes
            $ne    = $(if ($dk -lt 90) { "$dk dk once" } else { "{0:0.#} saat once" -f ($dk / 60) })
            $devam = $(if ($a.SessionId) { 'kaldigi yerden' } else { 'yeni oturum' })
            Write-Host ("   [{0}] {1,2}. {2}" -f $tik, ($i + 1), $a.Ad) -ForegroundColor $renk
            Write-Host ("          {0}  |  {1}  |  {2}" -f $ne, $a.Tip, $devam) -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host "  [Enter] isaretlileri ac   [1 3 5] isareti degistir   [h] hepsi  [y] hicbiri  [q] vazgec" -ForegroundColor DarkGray
        Write-Host ""
        # stdin yonlendirilmisse Read-Host patlar; o durumda vazgec (kayitlar korunur, cc-geri ile tekrar bakilir)
        try { $g = (Read-Host "  >").Trim() } catch { Log "Girdi alinamadi: $($_.Exception.Message)"; return $null }

        if ($g -eq '')  {
            $secilen = @()
            for ($i = 0; $i -lt $adaylar.Count; $i++) { if ($isaretli.Contains($i)) { $secilen += $adaylar[$i] } }
            return , $secilen
        }
        if ($g -eq 'q') { return $null }
        if ($g -eq 'h') { 0..($adaylar.Count - 1) | ForEach-Object { [void]$isaretli.Add($_) }; continue }
        if ($g -eq 'y') { $isaretli.Clear(); continue }
        foreach ($p in ($g -split '[,\s]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le $adaylar.Count) {
                if ($isaretli.Contains($n - 1)) { [void]$isaretli.Remove($n - 1) } else { [void]$isaretli.Add($n - 1) }
            }
        }
    }
}

# ---------------------------------------------------------- alias cakisma korumasi
# PowerShell komut cozumleme sirasi: Alias > Function > Cmdlet.
# Bir fonksiyon adi yerlesik bir alias ile cakisirsa fonksiyon HIC cagrilmaz ve
# cagri sessizce baska bir cmdlet'e gider ('Ac' -> 'ac' -> Add-Content gibi).
# Bu dongu cakismayi calisma aninda yakalar ve alias'i SADECE bu surec icin kaldirir.
foreach ($fn in $MyInvocation.MyCommand.ScriptBlock.Ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if (Get-Alias -Name $fn.Name -ErrorAction SilentlyContinue) {
        Remove-Item -LiteralPath "Alias:\$($fn.Name)" -Force -ErrorAction SilentlyContinue
        Log "Uyari: '$($fn.Name)' fonksiyon adi bir alias ile cakisiyordu; alias bu surec icin kaldirildi."
    }
}

# ---------------------------------------------------------------- ana akis
try {
    if ($Mod -eq 'Otomatik') { Start-Sleep -Seconds 12 }   # oturum acilisi ve ag otursun

    $boot     = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    $bootUtc  = $boot.ToUniversalTime()
    $oncekiMi = ($Mod -eq 'Otomatik' -or $Mod -eq 'Sor' -or ($Mod -eq 'Listele' -and $OncekiAcilis))
    $sinir    = $(if ($oncekiMi) { $bootUtc.AddHours(-$Saat) } else { (Get-Date).ToUniversalTime().AddHours(-$Saat) })

    $t = AdaylariTopla $bootUtc $sinir $oncekiMi
    $adaylar = @($t.Adaylar)

    # Salt-okunur test modu: hicbir sey acmaz, hicbir kayit silmez
    if ($Mod -eq 'Listele') {
        Write-Host "boot(UTC)=$($bootUtc.ToString('o'))  sinir(UTC)=$($sinir.ToString('o'))  oncekiAcilisFiltresi=$oncekiMi"
        Write-Host "aday=$($adaylar.Count)  temizlenecek-eski-kayit=$($t.Eskiler.Count)"
        $adaylar | Select-Object @{n = 'Zaman'; e = { $_.Zaman.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } }, Tip,
                                 @{n = 'Session'; e = { if ($_.SessionId) { $_.SessionId.Substring(0, 8) } else { '-' } } },
                                 Ad, Yol | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
        return
    }

    if ($adaylar.Count -eq 0) {
        Log "Aday yok."
        EskileriTemizle $t.Eskiler
        if ($Mod -ne 'Otomatik') {
            Write-Host ""
            Write-Host "  Geri getirilecek oturum bulunamadi." -ForegroundColor Yellow
            Write-Host "  (son $Saat saat tarandi)" -ForegroundColor DarkGray
            Write-Host ""
            Start-Sleep -Seconds 4
        }
        return
    }

    # Otomatik mod gizli calisir; karari sormak icin gorunur pencere acar
    if ($Mod -eq 'Otomatik') {
        Log "$($adaylar.Count) aday bulundu, secim ekrani aciliyor."
        Start-Process powershell -ArgumentList @(
            '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Mod', 'Sor', '-Saat', $Saat
        )
        return
    }

    $ustyazi = $(if ($oncekiMi) {
        "Bilgisayar {0:dd.MM.yyyy HH:mm} itibariyla acildi. Kapanis aninda acik olan oturumlar:" -f $boot
    } else {
        "Son $Saat saat icinde calisilmis, su an acik olmayan oturumlar:"
    })

    $secim = SecimEkrani $adaylar $ustyazi

    if ($null -eq $secim) { Log "Kullanici vazgecti, kayitlar korundu."; return }

    EskileriTemizle $t.Eskiler

    if ($secim.Count -eq 0) { Log "Hicbiri secilmedi."; return }

    OturumlariAc $secim
    Write-Host ""
    Write-Host "  $($secim.Count) oturum aciliyor..." -ForegroundColor Green
    Start-Sleep -Seconds 3
}
catch {
    Log "HATA: $($_.Exception.Message)"
    if ($Mod -ne 'Otomatik') {
        Write-Host ""
        Write-Host "  HATA: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
        Read-Host "  Devam icin Enter"
    }
}
