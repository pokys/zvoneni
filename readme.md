```md
# School Bell System (Zvoneni)

Školní zvonění jako appliance na Raspberry Pi.  
Po instalaci a rebootu systém **běží automaticky** a nevyžaduje obsluhu.

Zvonění je řízeno rozvrhem a přehrává zvuk přes 3.5mm jack.

---

## ✨ Vlastnosti

- systemd timers (žádný cron)
- automatický start po bootu
- ochrana proti špatnému času (NTP gate) – platí pro ruční i plánované zvonění
- tolerantní NTP gate (po bootu čeká, pak pustí zvonění i bez internetu)
- textové TUI přes SSH
- samoopravné po rebootu
- připravené pro RO filesystem
- minimální údržba

---

## 🚀 Instalace

```bash
cd /opt
git clone https://github.com/pokys/zvoneni.git
cd zvoneni/install
chmod +x *.sh
sudo ./install.sh
reboot
```

Po rebootu systém **okamžitě běží**.

---

## 🖥️ Ovládání

```bash
zvoneni-tui
```

Vše se spravuje přes TUI.

---

## 📄 Dokumentace

- `ADMIN.md` – provoz a údržba
- `schedule.txt` – rozvrh
- `/opt/zvoneni/sounds/` – zvuky (musí obsahovat alespoň jeden `.wav`)
- prázdný rozvrh se neaplikuje (ochrana proti vypnutí systému)

---

## 🏁 Stav projektu

Tento systém je navržen jako appliance:
- zapojíš → funguje
- reboot → funguje
- výpadek proudu → funguje
```
