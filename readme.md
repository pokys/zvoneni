# School Bell System (Raspberry Pi)

## Start
sudo ./install.sh

## Admin UI
zvoneni-tui

## Schedule
/opt/zvoneni/schedule.txt

Format:
DAY HH:MM TYPE

## Sounds
/opt/zvoneni/sounds/*.wav

## Stop bells
systemctl stop zvoneni.target

## Start bells
systemctl start zvoneni.target