# School Bell System (Zvoneni)

Appliance-style školní zvonění postavené na Raspberry Pi a systemd timerech.

Po instalaci a rebootu systém **automaticky běží** a nevyžaduje žádnou obsluhu.
Zvonění je řízeno rozvrhem a přehrává zvuk přes 3.5mm jack.

---

## ✨ Vlastnosti

- žádný cron (pouze systemd timers)
- automatický start po bootu
- bezpečné chování při výpadku proudu
- NTP gate (nezvoní, dokud není čas OK)
- textové TUI přes SSH
- samoopravný po rebootu (self-healing)
- připravené pro RO filesystem / overlay
- minimální údržba, maximální spolehlivost

---

## 🧠 Jak to funguje (stručně)

```
schedule.txt
   ↓
generate-timers.sh
   ↓
systemd timers
   ↓
zvoneni.target (master switch)
   ↓
zvoneni@.service
   ↓
aplay → reproduktor
```

---

## 🖥️ Ovládání

Přihlásíš se přes SSH a spustíš:

```bash
zvoneni-tui
```

TUI slouží pro:
- zobrazení stavu
- úpravu rozvrhu
- aplikaci změn
- test zvuku
- základní údržbu

---

## 🔧 Důležité soubory

| Soubor | Popis |
|------|------|
| `/opt/zvoneni/schedule.txt` | rozvrh zvonění |
| `/opt/zvoneni/sounds/` | zvuky (.wav) |
| `/usr/local/bin/zvoneni-tui` | textové UI |
| `/usr/local/bin/generate-timers.sh` | generátor timerů |

---

## 🔔 Formát rozvrhu

```txt
DAY TIME TYPE
Mon 08:00 normal
Mon 09:10 normal
```

- DAY = Mon Tue Wed Thu Fri
- TIME = HH:MM
- TYPE = název zvuku (normal.wav)

---

## 🚀 Instalace

Na čistém Raspberry Pi OS Lite:

```bash
cd /opt
git clone https://github.com/pokys/zvoneni.git
cd zvoneni/install
chmod +x *.sh
sudo ./install.sh
reboot
```

Po rebootu systém **automaticky běží**.

---

## 🔒 Doporučení pro provoz

- zapnout overlay filesystem (raspi-config)
- zálohovat SD kartu po instalaci
- používat kvalitní SD (industrial)
- neměnit systém ručně

---
