#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  seal-template.sh — Ubuntu VM für VMware Template vorbereiten
#  Verwendung: sudo ./seal-template.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

echo "==> [1/10] cloud-init State löschen..."
cloud-init clean --logs --seed

echo "==> [2/10] Machine-ID zurücksetzen..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "==> [3/10] SSH Host Keys löschen..."
rm -f /etc/ssh/ssh_host_*

echo "==> [4/10] Netplan cloud-init Config entfernen (Fallback bleibt erhalten)..."
rm -f /etc/netplan/50-cloud-init.yaml

echo "==> [5/10] localadmin Passwort auf Default zuruecksetzen..."
echo "localadmin:Change.Me.Now!" | chpasswd
chage -d 0 localadmin

echo "==> [6/10] Domain-Mitgliedschaft entfernen (Klon muss neu joinen)..."
realm leave 2>/dev/null || true
rm -f /etc/krb5.keytab

echo "==> [7/10] SSSD stoppen & deaktivieren (wird nach realm join aktiviert)..."
systemctl disable sssd 2>/dev/null || true
systemctl stop sssd 2>/dev/null || true

echo "==> [8/10] Shell History & Temp-Dateien löschen..."
truncate -s 0 /root/.bash_history
truncate -s 0 /home/*/.bash_history 2>/dev/null || true
rm -rf /tmp/* /var/tmp/*

echo "==> [9/10] Package Cache & Logs bereinigen..."
apt autoremove -y && apt clean
journalctl --rotate
journalctl --vacuum-time=1s
find /var/log -type f -exec truncate -s 0 {} \;

echo "==> [10/10] SSSD Cache wird bewusst behalten..."
# sssctl cache-remove -o     # auskommentieren um SSSD Cache ebenfalls zu löschen

echo ""
echo "✔  Template erfolgreich versiegelt."
echo "   VM jetzt herunterfahren: sudo shutdown -h now"
echo "   Danach in vCenter zu Template konvertieren."
