# Claude Oturum Kurtarma (v2)

Bilgisayar aniden kapandığında (elektrik, mavi ekran, Windows Update, uykudan kapanma)
açık olan Claude oturumlarını, tekrar açıldığında tek ekrandan geri getirir.

## Kullanım

| Komut | Ne yapar |
|---|---|
| `cc` | Bulunduğun klasörde Claude'u başlatır ve oturumu kaydeder |
| `cc-tab "C:\yol\klasör"` | O klasörü **aynı Windows Terminal penceresinde yeni sekme** olarak açar |
| `cc-geri` | İstediğin an, son 12 saatte çalışılmış ama şu an açık olmayan oturumları listeler |
| — | Windows açılışında ekran **otomatik** gelir; aday yoksa hiç görünmez |

Geri yükleme ekranında: `Enter` = işaretlilerin hepsini aç, `1 3 5` = işareti değiştir,
`h` = hepsi, `y` = hiçbiri, `q` = vazgeç (kayıtlar korunur, sonra `cc-geri` ile tekrar bakabilirsin).

Kurulum/güncelleme: `powershell -ExecutionPolicy Bypass -File .\Kurulum.ps1` (tekrar çalıştırmak zararsız).

### `cc-tab` nasıl çalışıyor

`wt -w 0` "en son kullanılan pencere"yi hedefler — Windows Terminal içinden çağrıldığında bu,
içinde bulunduğun penceredir. Yeni pencere açmaz, sekme ekler. Klasör yolu base64 ile geçirilir,
böylece Türkçe karakter ve boşluk hiçbir katmanda bozulmaz. `wt` yoksa ayrı pencereye düşer.

## Oturumlar nasıl bulunuyor

Dört bağımsız kaynak birleştirilir; biri kaçırırsa diğeri yakalar:

0. **`durum\anlik-onceki.json`** — `Anlik.ps1`'in kapanmadan önce aldığı son görüntü. **En güvenilir.**
   Zamanlanmış görev bunu 10 dakikada bir tazeler. Bu olmadan düzgün restart'ta iz kalmaz, çünkü
   claude kapanırken kendi defter kaydını siler.
1. **`~\.claude\sessions\<pid>.json`** — Claude'un kendi canlı oturum defteri. `cwd` + `sessionId` + `pid`
   verir. Oturum düzgün kapanınca dosya silinir, **ani kesintide kalır**.
2. **`~\.claude\oturum-kurtarma\durum\*.json`** — `cc` ile açılanların 15 saniyelik heartbeat kaydı.
   Kapanışın türünü söyler: *pencere kapandı* mı, *ani kesinti* mi.
3. **`~\.claude\projects\*\*.jsonl`** — transcript dosyaları. Diğerleri temizlenmişse son çare.

### Zaman penceresi sadece 3. kaynağa uygulanır

"Kapanışta açık mıydı" bir **canlılık** sorusudur, "ne zaman yazıldı" sorusu değil. Bir haftadır
hiç dokunulmamış ama açık duran bir oturum da geri gelmelidir. 0, 1 ve 2 numaralı kaynaklar
"açıktı" kanıtıdır — onlara `-Saat` penceresi uygulanmaz (yalnızca 30 günlük akıl sağlığı sınırı).
Sadece 3. kaynak açık/kapalı ayrımı yapamadığı için pencereye tabidir.

Bir oturumun hâlâ açık olup olmadığı `pid` + **süreç başlangıç zamanı** ile belirlenir —
yeniden açılışta PID'ler tekrar kullanıldığı için tek başına PID yeterli değil.
Açık oturumlar listeye hiç girmez, yani aynı oturum iki kez açılmaz.

## `cc` hangi oturumu açar

Hangi oturumun açılacağı **önceden** seçilir, `claude` **tek sefer** çağrılır:

1. `-Resume <id>` verilmişse (geri yükleme ekranı verir) o oturum açılır.
2. Yoksa, bu klasörün proje dizinindeki en yeni transcript `--resume` edilir.
3. Bu klasörde **zaten açık** bir oturum varsa eski konuşma sürdürülmez — temiz oturum açılır.
   ("devam eden"i zaten açık tutuyorsun demektir.)

İki kural bilinçli:

- **`--continue` kullanılmıyor.** O klasördeki en son konuşmayı alır, ki bu şu an açık olan
  oturum olabilir; üstüne binmek hata verir.
- **`claude` doğrudan çağrılır**, çıktısı bir değişkene veya pipeline'a verilmez. Verilirse
  PowerShell stdout'u yönlendirir, claude terminal olmadığını sanıp `--print` moduna düşer ve
  *"Input must be provided either through stdin or as a prompt argument"* der.

## Bilinen sınırlar

- Transcript dosyasındaki `cwd` shell `cd`'si ile değişebiliyor, bu yüzden 3. kaynakta
  dosyanın **ilk** `cwd` satırı kullanılır. 1. kaynak zaten doğru klasörü verir.
- Bir oturum, klasör güven onayı verilene kadar deftere yazılmaz.
- `wt` (Windows Terminal) yoksa her oturum ayrı PowerShell penceresinde açılır.
- `/exit` ile kapattığın bir klasör, 3. kaynak (transcript) üzerinden pencere içindeyse yine
  listede belirebilir. İşaretini kaldırıp geçersin.
- **Anlık görüntü görevi çalışmıyorsa** uzun süredir sessiz duran oturumlar düzgün restart'ta
  kaçabilir. Kontrol: `Get-ScheduledTask 'Claude Oturum Anlik Goruntu'`.
  Kaldırmak için: `Unregister-ScheduledTask 'Claude Oturum Anlik Goruntu'`.

## Dosyalar nerede — ve silinirse ne olur

| Yer | Ne | Silinirse |
|---|---|---|
| `~\.claude\projects\` | **Tüm konuşma geçmişi** (272 MB, 72 klasör) | ⛔ Konuşmalar kalıcı gider. Geri dönüşü yok. |
| `~\.claude\sessions\` | Claude'un canlı oturum defteri | Claude kendi yeniden üretir; sadece o anki kurtarma bilgisi kaybolur |
| `~\.claude\oturum-kurtarma\` | Çalışan sistem (3 script + `durum\` + log) | `Kurulum.ps1` ile 5 saniyede geri kurulur |
| `~\.claude\oturum-kurtarma\durum\anlik.json` | Açık oturumların son görüntüsü | 10 dk içinde kendini yeniler |
| Masaüstü`\claude oturum1\` | Kaynak kopya + `Kurulum.ps1` + bu dosya | Sistem çalışmaya devam eder, ama yeniden kuramazsın |
| Startup`\Claude Oturum Geri Yukle.lnk` | Açılışta çalışan kısayol | Otomatik ekran gelmez; `cc-geri` çalışır. Kurulum geri koyar |
| Görev: `Claude Oturum Anlik Goruntu` | 10 dk'da bir görüntü alır | Düzgün restart'ta sessiz oturumlar kaçabilir. Kurulum geri koyar |
| `...\WindowsPowerShell\Microsoft.PowerShell_profile.ps1` | `cc` / `cc-geri` tanımları | Komutlar tanınmaz. Kurulum geri koyar (yedeği: `.claudeoturum-yedek`) |

**Özet:** bu sistemin ürettiği her şey `Kurulum.ps1` ile yeniden kurulabilir. Asla silinmemesi
gereken tek şey `~\.claude\projects\` — o bana ait değil, Claude'un konuşma arşivi.

## Script yazarken dikkat

`Resolve-Path`'in **`.Path`** özelliği UNC yollarında sağlayıcı önekli biçim döndürür:
`Microsoft.PowerShell.Core\FileSystem::\\sunucu\pay\...`. Bu kayda girerse aynı klasör iki
farklı kimlik üretir ve oturum iki kez açılır. Ağ paylaşımındaki bir klasörde tam olarak bu
oldu. Doğrusu **`.ProviderPath`**. `GeriYukle.ps1` ayrıca `TemizYol` ile bu öneki temizler ve
yolu NFC'ye normalize eder, böylece kaynaklar arası karşılaştırma tutarlı olur.


PowerShell komut çözümleme sırası **Alias > Function > Cmdlet**. Bir fonksiyona yerleşik bir
alias'la aynı adı verirsen fonksiyon hiç çağrılmaz, çağrı sessizce başka bir cmdlet'e gider.
Bu tam olarak başımıza geldi: `Ac` adlı fonksiyon `ac` (= `Add-Content`) alias'ına gidiyordu,
ekranda `Value[0]:` beliriyor ve hiçbir oturum açılmıyordu. `GeriYukle.ps1` artık başlangıçta
kendi fonksiyon adlarını alias'lara karşı tarıyor ve çakışan alias'ı o süreç için kaldırıyor.

## Teşhis

```powershell
# Neyin aday olduğunu hiçbir şey açmadan/silmeden gör
& "$HOME\.claude\oturum-kurtarma\GeriYukle.ps1" -Mod Listele -Saat 24
& "$HOME\.claude\oturum-kurtarma\GeriYukle.ps1" -Mod Listele -Saat 12 -OncekiAcilis   # açılış filtresiyle
```

Log: `~\.claude\oturum-kurtarma\geri-yukleme.log`
v1 scriptleri: `_v1_yedek\`
PowerShell profil yedeği: `Microsoft.PowerShell_profile.ps1.claudeoturum-yedek`
