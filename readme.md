# School Bell System (Zvoneni)

Školní zvonění jako appliance na Raspberry Pi.  
Po instalaci a rebootu systém **běží automaticky** a nevyžaduje obsluhu.

Zvonění je řízeno rozvrhem a přehrává zvuk přes 3.5mm jack.

---

## ✨ Vlastnosti

- systemd timers (žádný cron)
- rozvrh pokrývá celý týden včetně soboty a neděle
- volitelné spínání zesilovače přes GPIO (zapne před zvoněním, vypne po něm)
- volitelné tlačítko, které po dobu stisku drží zesilovač zapnutý
- aktualizace z GitHubu přímo z TUI, včetně návratu na předchozí verzi
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
sudo apt update && sudo apt install -y git

cd /opt
sudo git clone https://github.com/pokys/zvoneni.git
sudo bash /opt/zvoneni/install/install.sh
sudo reboot
```

`git` se instaluje zvlášť, protože bez něj neproběhne ani to klonování –
na Raspberry Pi OS Lite předinstalovaný není. Instalátor si ho pak hlídá
sám, protože ho potřebuje i aktualizace.

Po rebootu systém **okamžitě běží**.

---

## 🖥️ Ovládání

```bash
sudo zvoneni-tui
```

Vše se spravuje přes TUI – rozvrh, zvuky, zesilovač i aktualizace.

---

## ⬆️ Aktualizace

TUI → `12 Update from GitHub` → `Check for updates`.

Rozvrh, nastavení zesilovače ani vlastní zvuky se nepřepisují.
Podrobnosti a omezení (nutnost vypnutého overlay FS) jsou v `admin.md`.

---

## 📄 Dokumentace

- `admin.md` – provoz a údržba
- `schedule.txt` – rozvrh
- `amp.conf` – nastavení zesilovače (spravuje se z TUI)
- `/opt/zvoneni/sounds/` – zvuky (musí obsahovat alespoň jeden `.wav`);
  dodávané zvuky se sem kopírují z `install/sounds/` jen když chybí,
  vlastní se nepřepisují
- prázdný rozvrh se neaplikuje (ochrana proti vypnutí systému)

---

## 🏁 Stav projektu

Tento systém je navržen jako appliance:
- zapojíš → funguje
- reboot → funguje
- výpadek proudu → funguje
