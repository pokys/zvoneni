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

rm -f /etc/systemd/system/zvoneni-*.timer
rm -f /etc/systemd/system/zvoneni-*.service
rm -f /etc/systemd/system/zvoneni.target.wants/zvoneni-*.timer

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
