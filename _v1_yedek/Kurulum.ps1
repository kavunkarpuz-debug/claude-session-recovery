\xEF\xBB\xBF# Kurulum.ps1 - Bir kere calistir. Sag tik > "PowerShell ile Calistir" ya da:
#   powershell -ExecutionPolicy Bypass -File .\Kurulum.ps1

$kaynak = $PSScriptRoot
$hedef  = Join-Path $HOME 'ClaudeOturum'
New-Item -ItemType Directory -Force -Path $hedef, (Join-Path $hedef 'durum') | Out-Null

# 1. Scriptleri yerine koy, internetten indirilme isaretini kaldir
foreach ($f in 'baslat.ps1', 'GeriYukle.ps1') {
    Copy-Item -LiteralPath (Join-Path $kaynak $f) -Destination $hedef -Force
    Unblock-File -LiteralPath (Join-Path $hedef $f)
}
Write-Host "[1/3] Scriptler kopyalandi: $hedef" -ForegroundColor Green

# 2. PowerShell profiline "cc" komutunu ekle
if (-not (Test-Path -LiteralPath $PROFILE)) { New-Item -ItemType File -Force -Path $PROFILE | Out-Null }
if (-not (Select-String -LiteralPath $PROFILE -SimpleMatch 'function cc ' -Quiet)) {
    Add-Content -LiteralPath $PROFILE -Value "`r`n# Claude Code oturum kaydi`r`nfunction cc { & `"$hedef\baslat.ps1`" @args }"
}
Write-Host "[2/3] 'cc' komutu profile eklendi: $PROFILE" -ForegroundColor Green

# 3. Windows acilisinda GeriYukle.ps1 calissin
$ws  = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Oturum Geri Yukle.lnk'))
$lnk.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments  = "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hedef\GeriYukle.ps1`""
$lnk.Save()
Write-Host "[3/3] Acilis kisayolu olusturuldu." -ForegroundColor Green

# Profilin yuklenebilmesi icin script calistirma izni lazim
$pol = Get-ExecutionPolicy
if ($pol -in 'Restricted', 'AllSigned') {
    Write-Host ""
    Write-Host "DIKKAT: Script calistirma politikan '$pol'. 'cc' komutunun calismasi icin su komutu calistir:" -ForegroundColor Yellow
    Write-Host "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned" -ForegroundColor Yellow
    Write-Host "Sirket politikasi engelliyorsa hata verir; o zaman IT'ye gitmen gerekir." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Bitti. Yeni bir PowerShell penceresi ac ve bir talep klasorunde 'cc' yaz." -ForegroundColor Cyan
