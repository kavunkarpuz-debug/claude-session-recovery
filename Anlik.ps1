# Anlik.ps1 - Claude'un canli oturum defterinin anlik goruntusunu alir.
# Zamanlanmis gorev bunu birkac dakikada bir calistirir.
#
# Neden gerekli:
#   claude.exe duzgun kapanista (pencere X, oturum kapatma, restart) kendi defter kaydini
#   ~\.claude\sessions\<pid>.json SILER. Yani restart'tan sonra "neler acikti" bilgisi yok olur.
#   Bir hafta hic dokunulmamis ama acik duran bir oturumun transcript'i de eski oldugu icin
#   zaman penceresine takilir. Cozum: kapanmadan onceki son goruntuyu kendimiz saklamak.
#
# Kritik ayrinti - acilis sirasi:
#   Bu gorev acilista da calisir ve GeriYukle.ps1'den ONCE calisabilir. O yuzden onceki
#   acilistan kalan goruntunun uzerine YAZMAZ; once 'anlik-onceki.json' olarak saklar.
#   Boylece GeriYukle hangi sirada calisirsa calissin kanit elde kalir.

$durum  = Join-Path $PSScriptRoot 'durum'
$defter = Join-Path $HOME '.claude\sessions'
$anlik  = Join-Path $durum 'anlik.json'
$onceki = Join-Path $durum 'anlik-onceki.json'

New-Item -ItemType Directory -Force -Path $durum | Out-Null

$bootUtc = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')

# Onceki acilistan kalan goruntuyu koru (bir kez)
if (Test-Path -LiteralPath $anlik) {
    try {
        $eski = Get-Content -LiteralPath $anlik -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($eski.boot -ne $bootUtc) {

            # Elde TUKETILMEMIS bir goruntu daha varsa (kullanici onceki geri yuklemeyi
            # atlamis ya da 'q' demis) onu ezme, BIRLESTIR. Duz Move-Item -Force olsaydi
            # ust uste iki restart, ilk acilistaki oturumlari 0. katmandan sessizce silerdi.
            if (Test-Path -LiteralPath $onceki) {
                try {
                    $tuketilmemis = Get-Content -LiteralPath $onceki -Raw -Encoding UTF8 | ConvertFrom-Json
                    $varolan = @{}
                    foreach ($o in @($eski.oturumlar)) {
                        if ($o.yol) { $varolan[$o.yol.TrimEnd('\').ToLowerInvariant()] = $true }
                    }
                    $ek = @()
                    foreach ($o in @($tuketilmemis.oturumlar)) {
                        if (-not $o.yol) { continue }
                        if (-not $varolan.ContainsKey($o.yol.TrimEnd('\').ToLowerInvariant())) { $ek += $o }
                    }
                    if ($ek.Count -gt 0) { $eski.oturumlar = @(@($eski.oturumlar) + $ek) }
                } catch { }
            }

            $eski | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $onceki -Encoding UTF8
            Remove-Item -LiteralPath $anlik -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

$liste = @()
if (Test-Path -LiteralPath $defter) {
    foreach ($d in Get-ChildItem -LiteralPath $defter -Filter *.json -File -ErrorAction SilentlyContinue) {
        try { $k = Get-Content -LiteralPath $d.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $k.cwd -or -not $k.sessionId) { continue }

        # Sadece GERCEKTEN calisan surecleri goruntuye al
        $p = Get-Process -Id $k.pid -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        if ($k.procStart) {
            try { if ($p.StartTime.ToFileTime().ToString() -ne $k.procStart.ToString()) { continue } } catch { }
        }

        $liste += [ordered]@{
            yol       = $k.cwd
            sessionId = $k.sessionId
            pid       = $k.pid
            procStart = "$($k.procStart)"
        }
    }
}

$cikti = [ordered]@{
    zaman     = (Get-Date).ToUniversalTime().ToString('o')
    boot      = $bootUtc
    oturumlar = @($liste)
}

# Atomik yaz: yarim yazilmis bir dosya kanitin kaybi demek olurdu
$gecici = Join-Path $durum 'anlik.tmp'
$cikti | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $gecici -Encoding UTF8
Move-Item -LiteralPath $gecici -Destination $anlik -Force
