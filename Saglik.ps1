# Saglik.ps1 - "Sistem hala calisiyor mu?" kontrolu.
#
# Neden var:
#   Bu sistem Claude Code'un BELGELENMEMIS ic yapilarina dayaniyor
#   (~\.claude\sessions\<pid>.json kaydinin alanlari, transcript'lerdeki cwd).
#   Bir claude surumu bunlarin bicimini degistirirse hicbir sey hata vermez -
#   kaynak katmanlari sessizce bos doner ve sen bunu ancak oturum kaybedince
#   anlarsin. Bu script o sessiz korelmeyi gorunur yapar.
#
# Kullanim:  cc-saglik      (veya)  .\Saglik.ps1
# Cikis kodu: 0 = sorun yok, 1 = en az bir HATA var.

[CmdletBinding()]
param()

# Ic yapilari en son bu claude surumunde dogruladik. Farkli olmasi tek basina
# sorun degil; asagidaki YAPI kontrolleri geciyorsa sistem calisiyor demektir.
$BilinenSurum = '2.1.278'

$kurulu = Join-Path $HOME '.claude\oturum-kurtarma'
$durum  = Join-Path $kurulu 'durum'
$defter = Join-Path $HOME '.claude\sessions'
$projel = Join-Path $HOME '.claude\projects'
$gorev  = 'Claude Oturum Anlik Goruntu'

$hata = 0
$uyari = 0

function Satir($durumKodu, $baslik, $detay) {
    switch ($durumKodu) {
        'ok'    { $im = '[ OK ]'; $renk = 'Green' }
        'uyari' { $im = '[ !  ]'; $renk = 'Yellow'; $script:uyari++ }
        'hata'  { $im = '[HATA]'; $renk = 'Red';    $script:hata++ }
        default { $im = '[ .. ]'; $renk = 'DarkGray' }
    }
    Write-Host ("{0} {1}" -f $im, $baslik) -ForegroundColor $renk
    if ($detay) { Write-Host ("       {0}" -f $detay) -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "  CLAUDE OTURUM KURTARMA - SAGLIK KONTROLU" -ForegroundColor Cyan
Write-Host "  $(Get-Date -Format 'dd.MM.yyyy HH:mm')" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------- claude CLI
$claude = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claude) {
    Satir hata "claude.exe PATH'te bulunamadi" "Claude Code kurulu degil ya da PATH disinda. Hicbir sey calismaz."
    $surum = $null
} else {
    $surum = $null
    try { $surum = (& claude --version 2>&1 | Select-Object -First 1) -replace '[^0-9\.].*$', '' } catch { }
    if (-not $surum) {
        Satir uyari "claude surumu okunamadi" "Yapi kontrolleri yine de asagida calisacak."
    } elseif ($surum -eq $BilinenSurum) {
        Satir ok "claude $surum" "Ic yapilar bu surumde dogrulandi."
    } else {
        Satir uyari "claude $surum (dogrulanan surum: $BilinenSurum)" "Sorun olmayabilir - asagidaki YAPI kontrolleri geciyorsa sistem calisiyor."
    }
}

# ------------------------------------------------------- 0. katman: goruntu
$anlik = Join-Path $durum 'anlik.json'
if (-not (Test-Path -LiteralPath $anlik)) {
    Satir hata "0. katman (anlik goruntu) - dosya yok" "Beklenen: $anlik  |  Zamanlanmis gorev hic calismamis olabilir."
} else {
    try {
        $g    = Get-Content -LiteralPath $anlik -Raw -Encoding UTF8 | ConvertFrom-Json
        $yas  = ((Get-Date).ToUniversalTime() - [datetime]::Parse($g.zaman).ToUniversalTime()).TotalMinutes
        $adet = @($g.oturumlar).Count
        if ($yas -gt 25) {
            Satir hata "0. katman - goruntu bayat ($([int]$yas) dk once)" "10 dk'da bir tazelenmeliydi. Zamanlanmis gorev calismiyor; duzgun restart'ta oturum kaybedersin."
        } elseif ($adet -eq 0) {
            Satir uyari "0. katman - taze ama bos" "Su an acik claude oturumu gorunmuyor. Oturum acikken bekleniyorsa 1. katmana bak."
        } else {
            Satir ok "0. katman (anlik goruntu) - $adet oturum" "$([int]$yas) dk once alindi."
        }
    } catch {
        Satir hata "0. katman - goruntu okunamadi" $_.Exception.Message
    }
}

# --------------------------------------- 1. katman: claude'un oturum defteri
if (-not (Test-Path -LiteralPath $defter)) {
    Satir hata "1. katman (oturum defteri) - klasor yok" "Beklenen: $defter  |  Bu klasor claude'a ait; yoksa surum degismis olabilir."
} else {
    $kayitlar = @(Get-ChildItem -LiteralPath $defter -Filter *.json -File -ErrorAction SilentlyContinue)
    if ($kayitlar.Count -eq 0) {
        Satir uyari "1. katman - kayit yok" "Su an acik oturum yoksa normal. Oturum acikken bos ise KAYIT BICIMI DEGISMIS olabilir."
    } else {
        # YAPI KONTROLU: sessiz korelmeyi yakalayan asil test.
        $gerekli = 'cwd', 'sessionId', 'pid', 'procStart'
        $saglam  = 0
        $eksikler = @{}
        foreach ($k in $kayitlar) {
            try { $j = Get-Content -LiteralPath $k.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            $eksik = @($gerekli | Where-Object { -not $j.PSObject.Properties[$_] -or -not $j.$_ })
            if ($eksik.Count -eq 0) { $saglam++ } else { foreach ($e in $eksik) { $eksikler[$e] = $true } }
        }
        if ($saglam -eq 0) {
            Satir hata "1. katman - kayit bicimi taninmiyor" "Eksik alan(lar): $($eksikler.Keys -join ', '). Ani kesinti sonrasi kurtarma bu katmandan calismaz."
        } elseif ($saglam -lt $kayitlar.Count) {
            Satir uyari "1. katman - $saglam/$($kayitlar.Count) kayit okunabildi" "Eksik alan(lar): $($eksikler.Keys -join ', ')"
        } else {
            Satir ok "1. katman (oturum defteri) - $saglam kayit" "Alanlar yerinde: $($gerekli -join ', ')"
        }
    }
}

# --------------------------------------------- 2. katman: heartbeat kayitlari
if (-not (Test-Path -LiteralPath $durum)) {
    Satir hata "2. katman (heartbeat) - durum klasoru yok" "Beklenen: $durum  |  Kurulum calistirilmamis."
} else {
    $hb    = @(Get-ChildItem -LiteralPath $durum -Filter *.hb -File -ErrorAction SilentlyContinue)
    $bayat = @($hb | Where-Object { ((Get-Date) - $_.LastWriteTime).TotalMinutes -gt 60 })
    if ($bayat.Count -gt 0) {
        Satir uyari "2. katman - $($hb.Count) kayit, $($bayat.Count) tanesi bayat" "1 saattir yazilmayan kayitlar var; sonraki geri yuklemede temizlenirler."
    } else {
        Satir ok "2. katman (heartbeat) - $($hb.Count) canli kayit" "Yalnizca 'cc' ile acilan oturumlar burada gorunur."
    }
}

# ------------------------------------------------- 3. katman: transcript'ler
if (-not (Test-Path -LiteralPath $projel)) {
    Satir hata "3. katman (transcript) - klasor yok" "Beklenen: $projel"
} else {
    $son = Get-ChildItem -LiteralPath $projel -Filter *.jsonl -File -Recurse -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if (-not $son) {
        Satir uyari "3. katman - transcript bulunamadi" "Son care katmani bos."
    } else {
        # YAPI KONTROLU: dosyada cwd tasiyan bir satir var mi? Yoksa bicim degismistir.
        # Bas taraftaki satirlar (mode, permission-mode, atis-latch...) cwd tasimaz;
        # ilk cwd genellikle 5-10. satirda gelir. Akis halinde okunur, bulunca durulur -
        # transcript dosyalari yuzlerce MB olabiliyor.
        $cwd = $null
        try {
            $sayac = 0
            foreach ($s in [IO.File]::ReadLines($son.FullName)) {
                if (++$sayac -gt 200) { break }
                if (-not $s -or $s -notmatch '"cwd"') { continue }
                try { $o = $s | ConvertFrom-Json } catch { continue }
                if ($o.cwd) { $cwd = $o.cwd; break }
            }
        } catch { }
        if ($cwd) {
            Satir ok "3. katman (transcript) - okunabiliyor" "Ornek: $(Split-Path -Leaf $cwd)"
        } else {
            Satir hata "3. katman - transcript'te 'cwd' yok" "Bicim degismis. Son care katmani klasor yolunu cikaramaz."
        }
    }
}

# ------------------------------------------------------ zamanlanmis gorev
$t = Get-ScheduledTask -TaskName $gorev -ErrorAction SilentlyContinue
if (-not $t) {
    Satir hata "Zamanlanmis gorev yok: $gorev" "Kurulum.ps1'i tekrar calistir. Bu olmadan 0. katman tazelenmez."
} else {
    $bilgi  = Get-ScheduledTaskInfo -TaskName $gorev -ErrorAction SilentlyContinue
    $tekrar = $t.Triggers[0].Repetition.Interval
    if ($t.State -eq 'Disabled') {
        Satir hata "Zamanlanmis gorev DEVRE DISI" "Etkinlestir: Enable-ScheduledTask '$gorev'"
    } elseif ($bilgi -and $bilgi.LastTaskResult -ne 0) {
        Satir uyari "Zamanlanmis gorev hata kodu donduruyor: $($bilgi.LastTaskResult)" "Son calisma: $($bilgi.LastRunTime)"
    } else {
        Satir ok "Zamanlanmis gorev calisiyor ($tekrar)" "Son: $($bilgi.LastRunTime)  |  Sonraki: $($bilgi.NextRunTime)"
    }
}

# --------------------------------------------------------- acilis kisayolu
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Oturum Geri Yukle.lnk'
if (Test-Path -LiteralPath $lnk) {
    Satir ok "Acilis kisayolu yerinde" "Windows acilisinda geri yukleme ekrani otomatik gelir."
} else {
    Satir uyari "Acilis kisayolu yok" "Otomatik ekran gelmez; 'cc-geri' elle calisir. Kurulum.ps1 geri koyar."
}

# --------------------------------------------------------- profil komutlari
$belgeler  = [Environment]::GetFolderPath('MyDocuments')
$profiller = @(
    $PROFILE,
    (Join-Path $belgeler 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $belgeler 'PowerShell\Microsoft.PowerShell_profile.ps1')
) | Where-Object { $_ } | Select-Object -Unique

$bulundu = @($profiller | Where-Object {
    (Test-Path -LiteralPath $_) -and ([IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) -match '>>> ClaudeOturum >>>')
})
if ($bulundu.Count -gt 0) {
    Satir ok "Komutlar profilde tanimli ($($bulundu.Count) profil)" "cc  |  cc-tab  |  cc-geri  |  cc-saglik"
} else {
    Satir hata "Profilde komut tanimi yok" "Kurulum.ps1'i tekrar calistir."
}

# ------------------------------------------------------------ yardimcilar
if (Get-Command wt -ErrorAction SilentlyContinue) {
    Satir ok "Windows Terminal (wt) var" "Oturumlar tek pencerede sekme sekme acilir."
} else {
    Satir uyari "Windows Terminal (wt) yok" "Her oturum ayri PowerShell penceresinde acilir."
}

$pol = try { Get-ExecutionPolicy } catch { $null }
if ($pol -in 'Restricted', 'AllSigned') {
    Satir hata "Script politikasi: $pol" "Duzeltme: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
}

# ------------------------------------------------------------------- ozet
Write-Host ""
if ($hata -eq 0 -and $uyari -eq 0) {
    Write-Host "  Sistem saglikli." -ForegroundColor Green
} elseif ($hata -eq 0) {
    Write-Host "  Sistem calisiyor. $uyari uyari var (yukarida sari)." -ForegroundColor Yellow
} else {
    Write-Host "  $hata HATA, $uyari uyari. Kirmizi satirlardaki duzeltmeyi uygula." -ForegroundColor Red
}
Write-Host ""

exit ([int]($hata -gt 0))
