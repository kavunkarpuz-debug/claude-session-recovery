# Claude Oturum Kurtarma

Bilgisayar aniden kapandığında açık olan [Claude Code](https://claude.com/claude-code)
oturumlarını, tekrar açıldığında tek ekrandan geri getirir. Windows + PowerShell.

## Çözdüğü problem

Aynı anda 8-10 Claude oturumunu farklı klasörlerde açık tutuyorsan — bazıları haftalarca
dokunulmadan — elektrik kesintisi, mavi ekran veya Windows Update restart'ı hepsini birden
götürür. Geri açmak için hangi klasörlerde çalıştığını hatırlaman gerekir; hatırlamazsan
o oturumlar kaybolur.

Bu sistem kapanış anında neyin açık olduğunu kaydeder ve açılışta tek tuşla hepsini
**kaldıkları yerden** geri getirir.

## Kurulum

```powershell
git clone https://github.com/<kullanici>/claude-oturum-kurtarma.git
cd claude-oturum-kurtarma
powershell -ExecutionPolicy Bypass -File .\Kurulum.ps1
```

Kurulum dört şey yapar: script'leri `~\.claude\oturum-kurtarma\` altına kopyalar, PowerShell
profiline komutları ekler, açılış kısayolu oluşturur ve 10 dakikada bir çalışan bir
zamanlanmış görev kurar. Yönetici yetkisi gerekmez. Tekrar çalıştırmak zararsızdır.

## Komutlar

| Komut | Ne yapar |
|---|---|
| `cc` | Bulunduğun klasörde Claude'u başlatır, varsa son konuşmayı sürdürür |
| `cc-tab "<yol>"` | Başka bir klasörü aynı Windows Terminal penceresinde yeni sekmede açar |
| `cc-geri` | Kapanmış oturumları listeler, seçtiklerini geri açar |
| `cc-saglik` | Sistemin hâlâ çalışıp çalışmadığını satır satır kontrol eder |

Windows açılışında geri yükleme ekranı **otomatik** gelir; aday yoksa hiç görünmez.

```
  CLAUDE OTURUM GERI YUKLEME
  Bilgisayar 22.09.2026 12:14 itibariyla acildi. Kapanis aninda acik olan oturumlar:

   [x]  1. Oilman Vigor Mukayese
          3 dk once  |  acik kalmis  |  kaldigi yerden
   [x]  2. Drill Pipe
          3 dk once  |  ANI KESINTI  |  kaldigi yerden

  [Enter] isaretlileri ac   [1 3 5] isareti degistir   [h] hepsi  [y] hicbiri  [q] vazgec
```

`Enter` → hepsi tek pencerede sekme sekme açılır, her biri `claude --resume <id>` ile
tam kaldığı yerden.

## Nasıl çalışıyor

Dört bağımsız kanıt kaynağı birleştirilir; biri kaçırırsa diğeri yakalar:

| # | Kaynak | Ne zaman işe yarar |
|---|---|---|
| 0 | Anlık görüntü (10 dk'da bir) | Düzgün restart — Claude kendi kaydını sildiğinde tek iz budur |
| 1 | Claude'un oturum defteri | Ani kesinti, mavi ekran — temizlik çalışmadığı için kayıt kalır |
| 2 | Heartbeat kayıtları (15 sn) | `cc` ile açılanlar; kapanışın türünü ayırt eder |
| 3 | Transcript dosyaları | İlk üçü temizlenmişse son çare |

**Zaman penceresi sadece 3. kaynağa uygulanır.** "Kapanışta açık mıydı" bir canlılık
sorusudur, "ne zaman yazıldı" sorusu değil — bir haftadır dokunulmamış ama açık duran bir
oturum da geri gelmelidir. Açık olan oturumlar listeye hiç girmez, yani aynı oturum iki kez
açılmaz; canlılık `pid` + süreç başlangıç zamanı ile doğrulanır.

## Sağlık kontrolü

Sistem Claude Code'un **belgelenmemiş** iç dosyalarını okuyor. Bir Claude Code sürümü bu
dosyaların biçimini değiştirirse hiçbir şey hata vermez — kaynak katmanları sessizce boş
döner ve bunu ancak bir oturum kaybedince fark edersin. `cc-saglik` o sessiz körelmeyi
görünür yapar:

```
[ OK ] 1. katman (oturum defteri) - 7 kayit
       Alanlar yerinde: cwd, sessionId, pid, procStart
[HATA] 3. katman - transcript'te 'cwd' yok
       Bicim degismis. Son care katmani klasor yolunu cikaramaz.
```

Dört katmanın her birini, zamanlanmış görevi, açılış kısayolunu ve profil komutlarını
ayrı ayrı denetler; sorun bulursa düzeltme komutunu yazar. Claude Code yükselttikten
sonra bir kere çalıştırmak iyi bir alışkanlık.

## Kaldırma

```powershell
.\Kaldir.ps1              # script'ler, görev, kısayol ve profil tanımları
.\Kaldir.ps1 -DurumuSil   # kayıtları ve logu da sil
```

Ne sileceğini önce listeler, onay ister. **`~\.claude\projects\` klasörüne — yani
konuşma geçmişine — asla dokunmaz.**

## Gereksinimler

- Windows 10/11, PowerShell 5.1 veya 7
- [Claude Code](https://claude.com/claude-code) CLI (`claude.exe` PATH'te)
- Windows Terminal (`wt`) — yoksa oturumlar ayrı pencerelerde açılır

Claude Code'un iç dosya biçimleri **2.1.278** sürümünde doğrulandı. Daha yeni bir sürümde
çalışıp çalışmadığını `cc-saglik` söyler.

## Ayrıntılar

Mimari, bilinen sınırlar, teşhis komutları ve geliştirirken düşülen tuzaklar
[`OKUBENI.md`](OKUBENI.md) dosyasında.

`_v1_yedek/` klasöründe bu sistemin ilk sürümü duruyor.

## Lisans

[MIT](LICENSE)
