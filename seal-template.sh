#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  seal-template.sh — Ubuntu VM für VMware Template vorbereiten
#
#  Letzter Schritt vor "Convert to Template". Entfernt alle
#  instanzspezifischen Daten, setzt das Break-Glass-Passwort und
#  schaltet die Firstboot-Automatik scharf.
#
#  Das Break-Glass-Passwort wird hier — und nur hier — vergeben:
#    interaktiv, oder unbeaufsichtigt ueber die Umgebungsvariable
#    VB_LOCAL_ADMIN_PASSWORD.
#
#  Verwendung: sudo ./seal-template.sh
#              sudo VB_LOCAL_ADMIN_PASSWORD='…' ./seal-template.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

LOCAL_ADMIN_USER="${VB_LOCAL_ADMIN_USER:-localadmin}"
CONF_FILE="/etc/vb-template/firstboot.conf"
SECRET_FILE="/etc/vb-template/join.secret"
MARKER="/var/lib/vb-template/firstboot.done"

# ── Root-Check ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Dieses Script muss als root ausgefuehrt werden." >&2
    echo "Verwendung: sudo $0" >&2
    exit 1
fi

# ── Break-Glass-Passwort beschaffen ─────────────────────────────
# Bewusst nicht im Repository hinterlegt: ein Passwort im Git-Verlauf
# ist auf jedem Klon gueltig und laesst sich nicht zurueckziehen.
prompt_secret() {
    local prompt="$1"
    local first second
    while true; do
        IFS= read -r -s -p "  ${prompt}: " first
        echo "" >&2
        IFS= read -r -s -p "  ${prompt} (Wiederholung): " second
        echo "" >&2
        if [[ -z "$first" ]]; then
            echo "    Passwort darf nicht leer sein." >&2
            continue
        fi
        if [[ "$first" == "$second" ]]; then
            printf '%s' "$first"
            return 0
        fi
        echo "    Eingaben stimmen nicht ueberein. Bitte erneut." >&2
    done
}

LOCAL_ADMIN_PASSWORD="${VB_LOCAL_ADMIN_PASSWORD:-}"
if [[ -z "${LOCAL_ADMIN_PASSWORD}" ]]; then
    echo ""
    echo "  Break-Glass-Passwort fuer '${LOCAL_ADMIN_USER}' festlegen."
    echo "  Es gilt auf allen Klonen dieses Templates — sicher hinterlegen"
    echo "  (Passwortmanager) und beim naechsten Template-Bau rotieren."
    echo ""
    LOCAL_ADMIN_PASSWORD=$(prompt_secret "Passwort fuer '${LOCAL_ADMIN_USER}'")
fi

echo ""
echo "==> [1/14] cloud-init State löschen..."
cloud-init clean --logs --seed

echo "==> [2/14] Machine-ID zurücksetzen..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "==> [3/14] SSH Host Keys löschen..."
rm -f /etc/ssh/ssh_host_*

echo "==> [4/14] Netplan cloud-init Config entfernen (Fallback bleibt erhalten)..."
rm -f /etc/netplan/50-cloud-init.yaml

echo "==> [5/14] '${LOCAL_ADMIN_USER}' sicherstellen..."
if ! id "$LOCAL_ADMIN_USER" &>/dev/null; then
    adduser --disabled-password --gecos "Local Admin" "$LOCAL_ADMIN_USER"
    echo "    User '$LOCAL_ADMIN_USER' angelegt."
fi
usermod -aG sudo "$LOCAL_ADMIN_USER"
# authorized_keys leeren — Test-Keys aus dem Template duerfen nicht in Klone leaken
rm -f "/home/${LOCAL_ADMIN_USER}/.ssh/authorized_keys"

echo "==> [6/14] '${LOCAL_ADMIN_USER}' Break-Glass-Passwort setzen..."
# Bewusst VOR dem Entfernen der uebrigen User: bricht spaeter etwas ab,
# ist der Notzugang trotzdem gesetzt. Andersherum stuende am Ende ein
# Template ohne jeden brauchbaren lokalen Login.
#
# printf statt echo: keine Backslash-Interpretation, kein "-e"-Problem.
# chpasswd setzt zugleich das Datum der letzten Aenderung — der
# Break-Glass-Account startet also ohne erzwungenen Passwortwechsel.
printf '%s:%s\n' "$LOCAL_ADMIN_USER" "$LOCAL_ADMIN_PASSWORD" | chpasswd
unset LOCAL_ADMIN_PASSWORD VB_LOCAL_ADMIN_PASSWORD

# Nachsehen, ob wirklich ein Hash in /etc/shadow steht. '!' oder '*'
# bedeuten gesperrt, leer bedeutet gar kein Passwort — in allen drei
# Faellen waere der Notzugang wertlos, und das faellt sonst erst beim
# ersten Ernstfall auf.
_shadow_hash="$(getent shadow "$LOCAL_ADMIN_USER" | cut -d: -f2)"
case "${_shadow_hash}" in
    ''|'!'*|'*')
        echo "    FEHLER: Fuer '${LOCAL_ADMIN_USER}' steht kein gueltiger" >&2
        echo "            Passwort-Hash in /etc/shadow (Feld: '${_shadow_hash}')." >&2
        echo "            Abbruch — ein Template ohne Break-Glass-Zugang ist wertlos." >&2
        exit 1
        ;;
esac
unset _shadow_hash
echo "    Passwort gesetzt und in /etc/shadow verifiziert."

echo "==> [7/14] Alle lokalen User ausser '${LOCAL_ADMIN_USER}' entfernen..."
# Lokale User: UID >= 1000 und < 65534 (nobody). Direkt aus /etc/passwd
# lesen, damit eventuell gecachte SSSD-Eintraege nicht angefasst werden.
#
# Die eigene Sitzung wird NICHT abgeschossen. Wer das Script per sudo aus
# der Sitzung des Build-Users startet, wuerde sich mit 'pkill -u' sonst
# selbst rauswerfen: die Login-Shell stirbt, die Sitzung bekommt SIGHUP,
# und das Script endet mitten im Versiegeln. Ergebnis waere ein Template
# mit halb geloeschtem Build-User und ohne die restlichen Schritte.
# 'userdel -f' entfernt das Konto auch bei laufender Sitzung.
INVOKING_USER="${SUDO_USER:-}"
[[ -n "$INVOKING_USER" ]] && echo "    Aufrufender User: '${INVOKING_USER}' (Sitzung bleibt am Leben)"

while IFS=: read -r _user _ _uid _ _ _ _; do
    if (( _uid >= 1000 && _uid < 65534 )) && [[ "$_user" != "$LOCAL_ADMIN_USER" ]]; then
        echo "    Entferne User '$_user' (UID $_uid)..."
        if [[ "$_user" != "$INVOKING_USER" ]]; then
            pkill -KILL -u "$_user" 2>/dev/null || true
        fi
        userdel -r -f "$_user" 2>/dev/null || userdel -f "$_user" || true
    fi
done < /etc/passwd

echo "==> [8/14] Domain-Mitgliedschaft entfernen (Klon muss neu joinen)..."
realm leave 2>/dev/null || true
rm -f /etc/krb5.keytab

echo "==> [9/14] SSSD stoppen & deaktivieren (wird nach realm join aktiviert)..."
systemctl disable sssd 2>/dev/null || true
systemctl stop sssd 2>/dev/null || true

echo "==> [10/14] Firstboot-Automatik scharf schalten..."
if [[ -f /usr/local/sbin/vb-firstboot.sh && -f "$CONF_FILE" ]]; then
    # Template-Hostname festhalten. vb-firstboot.sh vergleicht ihn beim
    # Boot mit dem tatsaechlichen Hostname: sind sie gleich, wurde keine
    # Customization Spec angewendet (oder es ist die Wartungs-VM des
    # Templates) — dann wird bewusst nicht gejoint.
    sed -i '/^TEMPLATE_HOSTNAME=/d' "$CONF_FILE"
    printf 'TEMPLATE_HOSTNAME="%s"\n' "$(hostname -s)" >> "$CONF_FILE"
    chmod 600 "$CONF_FILE"
    echo "    TEMPLATE_HOSTNAME=$(hostname -s) in ${CONF_FILE} hinterlegt."

    # Marker und Log entfernen, damit der Service auf jedem Klon laeuft.
    rm -f "$MARKER"
    rm -f /var/log/vb-firstboot.log
    systemctl reset-failed vb-firstboot.service 2>/dev/null || true
    systemctl enable vb-firstboot.service 2>/dev/null || true

    if [[ -s "$SECRET_FILE" ]]; then
        chmod 600 "$SECRET_FILE"
        chown root:root "$SECRET_FILE"
        echo "    Join-Secret vorhanden — Klone joinen beim ersten Boot automatisch."
    else
        echo "    WARNUNG: ${SECRET_FILE} fehlt oder ist leer."
        echo "             Klone joinen NICHT automatisch. Nachtragen mit:"
        echo "             printf '%%s' '<passwort>' | sudo tee ${SECRET_FILE} >/dev/null"
        echo "             sudo chmod 600 ${SECRET_FILE}"
    fi
else
    echo "    WARNUNG: vb-firstboot ist nicht installiert."
    echo "             prepare-template.sh ausfuehren, sonst bleibt der"
    echo "             Domain Join auf jedem Klon Handarbeit."
fi

echo "==> [11/14] Shell History & Temp-Dateien löschen..."
truncate -s 0 /root/.bash_history
truncate -s 0 /home/*/.bash_history 2>/dev/null || true
rm -rf /tmp/* /var/tmp/*

echo "==> [12/14] Package Cache & Logs bereinigen..."
apt autoremove -y && apt clean
journalctl --rotate
journalctl --vacuum-time=1s
find /var/log -type f -exec truncate -s 0 {} \;

echo "==> [13/14] SSSD Cache wird bewusst behalten..."
# sssctl cache-remove -o     # auskommentieren um SSSD Cache ebenfalls zu löschen

echo "==> [14/14] Abschlusspruefung..."
SEAL_WARN=0

# Break-Glass-Zugang: Hash vorhanden, Konto nicht gesperrt, kein
# erzwungener Wechsel. Das ist der Zugang, auf den im Ernstfall alles
# hinauslaeuft — er wird hier ein zweites Mal geprueft.
_final_hash="$(getent shadow "$LOCAL_ADMIN_USER" 2>/dev/null | cut -d: -f2)"
case "${_final_hash}" in
    ''|'!'*|'*')
        echo "    FEHLER: '${LOCAL_ADMIN_USER}' hat keinen gueltigen Passwort-Hash."
        SEAL_WARN=1
        ;;
    *)
        echo "    Break-Glass-Zugang '${LOCAL_ADMIN_USER}': Passwort gesetzt."
        ;;
esac
unset _final_hash

if ! id -nG "$LOCAL_ADMIN_USER" 2>/dev/null | tr ' ' '\n' | grep -qx sudo; then
    echo "    WARNUNG: '${LOCAL_ADMIN_USER}' ist nicht in der Gruppe 'sudo'."
    SEAL_WARN=1
fi

# Uebrig gebliebene lokale User. Der Build-User von der Installation
# darf im Template nicht zurueckbleiben.
_leftover=""
while IFS=: read -r _u _ _id _ _ _ _; do
    if (( _id >= 1000 && _id < 65534 )) && [[ "$_u" != "$LOCAL_ADMIN_USER" ]]; then
        _leftover="${_leftover} ${_u}"
    fi
done < /etc/passwd
if [[ -n "$_leftover" ]]; then
    echo "    WARNUNG: Diese lokalen User sind noch vorhanden:${_leftover}"
    echo "             Sie landen unveraendert auf jedem Klon."
    SEAL_WARN=1
fi
unset _leftover

if [[ ! -f /etc/netplan/99-fallback-dhcp.yaml ]]; then
    echo "    WARNUNG: Netplan-Fallback /etc/netplan/99-fallback-dhcp.yaml fehlt."
    SEAL_WARN=1
fi
if [[ ! -f /etc/systemd/system/vb-firstboot.service ]]; then
    echo "    WARNUNG: vb-firstboot.service fehlt."
    SEAL_WARN=1
fi
if [[ -e /etc/krb5.keytab ]]; then
    echo "    WARNUNG: /etc/krb5.keytab existiert noch — Klone joinen sonst als Template."
    SEAL_WARN=1
fi
if [[ -e "$MARKER" ]]; then
    echo "    WARNUNG: Firstboot-Marker ${MARKER} existiert noch."
    SEAL_WARN=1
fi
if (( SEAL_WARN == 0 )); then
    echo "    Keine Auffaelligkeiten."
fi

echo ""
echo "✔  Template erfolgreich versiegelt."
echo "   VM jetzt herunterfahren: sudo shutdown -h now"
echo "   Danach in vCenter zu Template konvertieren."
echo ""
echo "   NICHT neu starten — ein Reboot erzeugt Machine-ID und SSH Host"
echo "   Keys sofort wieder und setzt den Firstboot-Lauf in Gang."
