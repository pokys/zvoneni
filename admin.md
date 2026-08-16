```md
# School Bell System – Admin Guide

Tento dokument je určen pro správce systému (admina).
Popisuje běžný provoz, údržbu a řešení problémů.

---

## 🟢 Ověření stavu systému

Po bootu musí platit:

```bash
systemctl status zvoneni.target
```

Výsledek:
```
Active: active
```

Timery:

```bash
systemctl list-timers | grep zvoneni
```

Musíš vidět plánované časy zvonění.

---

## 🎛️ Textové UI (doporučený způsob správy)

Spusť:

```bash
zvoneni-tui
```

V TUI můžeš:
- vidět stav systému
- vidět další zvonění
- upravit rozvrh
- aplikovat rozvrh
- otestovat zvuk
- zapnout / vypnout zvonění

❗ **Používej TUI, ne ruční systemctl**

---

## 📝 Změna rozvrhu

### Doporučený postup
1. `zvoneni-tui`
2. Edit schedule
3. Apply schedule

### Ručně (pokročilé)

```bash
nano /opt/zvoneni/schedule.txt
generate-timers.sh
```

---

## 🔔 Test zvuku

```bash
systemctl start zvoneni@normal.service
```

Pokud hraje → zvuk je OK.

---

## 🔊 Zesilovač (GPIO)

Systém umí sepnout zesilovač před zvoněním a zase ho vypnout po dozvonění.
Ve výchozím stavu je funkce **vypnutá** a na GPIO se vůbec nesahá.

Jak to funguje na příkladu (zvonění 8:00, pre-roll 10 s, zvuk 10 s, post-roll 0 s):

| čas | co se stane |
|---|---|
| 07:59:50 | timer sepne pin, zesilovač náběhne |
| 08:00:00 | začne hrát zvuk |
| 08:00:10 | zvuk dohrál, pin jde dolů |

Zvuk tedy **začíná přesně v naplánovaný čas** – posunutý je timer, ne přehrávání.
Proto se po každé změně pre-rollu musí přegenerovat timery, což TUI dělá samo.

### Ovládání

```bash
zvoneni-tui
```
→ `11 Amplifier (GPIO switching)`

Nastavit lze zapnutí funkce, GPIO pin, sekundy před a po, a polaritu.
**Ručně soubor upravovat netřeba**, TUI je jediné doporučené rozhraní.

### Konfigurace

```bash
cat /opt/zvoneni/amp.conf
```

| Klíč | Význam |
|---|---|
| `AMP_ENABLED` | 0/1 – hlavní vypínač celé funkce |
| `AMP_GPIO` | BCM číslo pinu (0–27) |
| `AMP_ACTIVE_HIGH` | 1 = HIGH zapíná, 0 = LOW zapíná |
| `AMP_PRE_SECONDS` | sekundy před zvoněním (0–300) |
| `AMP_POST_SECONDS` | sekundy po dozvonění (0–300) |

Rozbitá nebo chybějící konfigurace = funkce vypnutá, **zvonění běží dál**.

⚠️ Pre-roll nenastavuj delší, než je mezera mezi dvěma nejbližšími zvoněními
v rozvrhu – jinak se druhé zvonění spustí ještě během prvního.

### Diagnostika

```bash
zvoneni-amp status     # konfigurace, reálný stav pinu, kdo ho drží
zvoneni-amp reset      # nouzové vypnutí, když zesilovač zůstal viset
zvoneni-amp test 5     # sepnout na 5 sekund
```

Zesilovač si drží víc věcí najednou (zvonění, později tlačítko) a vypne se
až ve chvíli, kdy ho pustí poslední z nich. Stav držitelů je v `/run`,
tedy v RAM – po rebootu je čistý a na SD kartu se nic nezapisuje.

Při bootu jede `zvoneni-amp-reset.service`, který pin srazí dolů. Je to
pojistka pro případ, že Pi spadlo mezi zapnutím a vypnutím zesilovače.

### ⚡ Zapojení

GPIO dává **3,3 V a jednotky mA**. Zesilovač se spíná přes MOSFET, relé
nebo SSR – **nikdy ne přímo z pinu**. Na gate/vstup spínače patří pull-down
rezistor, aby zesilovač nenaskočil během bootu, než se pin nastaví.

---

## ⏱️ Čas a synchronizace

Stav času:

```bash
timedatectl status
```

Gate soubor:

```bash
ls /run/clock-ok
```

Pokud **neexistuje**, systém **nezvoní** (ochrana proti špatnému času).
Gate platí pro ruční i plánované zvonění.

---

## 🔍 Logování a debug

### Zvonění
```bash
journalctl -u zvoneni@*
```

### Clock watchdog
```bash
journalctl -u clock-watch
```

### Generátor
```bash
journalctl -u zvoneni-generator.service
```

---

## 🔁 Obnova po problému

### Restart zvonění
```bash
systemctl restart zvoneni.target
```

### Znovu vygenerovat timery
```bash
generate-timers.sh
```

Poznámky:
- prázdný rozvrh se neaplikuje (ochrana proti vypnutí systému)
- pokud nejsou žádné `.wav` v `/opt/zvoneni/sounds/`, generátor skončí chybou

---

## 🧹 Factory reset timerů (nouzový postup)

Použij jen pokud je systém rozbitý:

```bash
systemctl stop zvoneni.target

rm -f /etc/systemd/system/zvoneni-[MTWF][a-z][a-z]-*.timer
rm -f /etc/systemd/system/zvoneni-[MTWF][a-z][a-z]-*.service
rm -f /etc/systemd/system/zvoneni.target.wants/zvoneni-[MTWF][a-z][a-z]-*.timer

systemctl daemon-reload
generate-timers.sh
```

---

## 🧊 Overlay filesystem (doporučeno pro produkci)

Zapnutí:

```bash
sudo raspi-config
```

→ Performance Options  
→ Overlay File System  

Po zapnutí:
- root FS je RO
- změny jsou v RAM
- SD karta se neopotřebovává

⚠️ **Se zapnutým overlay se změny v TUI po rebootu ztratí** – týká se
`schedule.txt` i `amp.conf`. Postup při změně:

1. `sudo raspi-config` → vypnout overlay
2. reboot
3. změnit rozvrh / nastavení zesilovače
4. `sudo raspi-config` → zapnout overlay
5. reboot

### Další šetření karty

Generátor přepisuje unit soubory jen tehdy, když se rozvrh opravdu změnil –
při nezměněném rozvrhu boot na kartu nezapíše nic.

Zbývá journal:

```bash
ls /var/log/journal        # když adresář existuje, logy jdou na SD kartu
journalctl --disk-usage
```

Když neexistuje (výchozí stav Raspberry Pi OS), logy jsou v RAM a zvonění
na kartu nezapisuje. Jinak se to řeší přes `Storage=volatile`
v `/etc/systemd/journald.conf`.

---

## ⚠️ Co NEDĚLAT

- nepoužívat cron
- neupravovat systemd jednotky ručně
- nespouštět generátor opakovaně bez důvodu
- neměnit čas ručně
- neupravovat systém mimo TUI

---

## 🏁 Stav systému

Tento systém je navržen jako **appliance**:
- zapojíš → funguje
- reboot → funguje
- výpadek proudu → funguje
- admin nic neřeší

Pokud tohle čteš, systém už běží.
```
