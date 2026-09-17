#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  post-clone.sh
#
#  Im Normalfall wird dieses Script NICHT gebraucht: vb-firstboot.service
#  erledigt Domain Join, SSSD und Server-Beschreibung beim ersten Boot
#  eines Klons automatisch.
#
#  Hier geht es um die Ausnahmen:
#    - nachsehen, ob der Firstboot durchgelaufen ist
#    - einen fehlgeschlagenen oder uebersprungenen Join nachholen
#    - eine VM neu joinen (z.B. nach Umbenennung)
#    - das Break-Glass-Passwort auf diesem Klon aendern
#
#  Verwendung:
#    sudo ./post-clone.sh              Status zeigen, Join bei Bedarf
#    sudo ./post-clone.sh --status     Nur Status, nichts aendern
#    sudo ./post-clone.sh --force      Join in jedem Fall wiederholen
#    sudo ./post-clone.sh --password   Break-Glass-Passwort neu setzen
# ─────────────────────────────────────────────────────────────────
set -uo pipefail

FIRSTBOOT_BIN="/usr/local/sbin/vb-firstboot.sh"
CONF_FILE="/etc/vb-template/firstboot.conf"
SECRET_FILE="/etc/vb-template/join.secret"
MARKER="/var/lib/vb-template/firstboot.done"
LOG_FILE="/var/log/vb-firstboot.log"

MODE="auto"          # auto | status | force
DO_PASSWORD="no"

usage() {
    cat <<'EOF'
post-clone.sh — Status & Reparatur nach dem Klonen

Im Normalfall nicht noetig: vb-firstboot.service erledigt Domain Join,
SSSD und Server-Beschreibung beim ersten Boot automatisch.

  (ohne Optionen)  Status anzeigen und den Join nachholen, falls er
                   fehlt oder fehlgeschlagen ist
  --status         Nur Status anzeigen, nichts aendern
  --force          Domain Join in jedem Fall wiederholen
  --password       Break-Glass-Passwort auf diesem Klon neu setzen
  --help           Diese Hilfe
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)   MODE="status" ;;
        --force)    MODE="force" ;;
        --password) DO_PASSWORD="yes" ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; echo "Hilfe: $0 --help" >&2; exit 2 ;;
    esac
    shift
done

# ── Root-Check ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Dieses Script muss als root ausgefuehrt werden." >&2
    echo "Verwendung: sudo $0" >&2
    exit 1
fi

# ── Konfiguration einlesen (nur zur Anzeige) ────────────────────
AD_DOMAIN=""
AD_ADMIN_GROUP=""
LOCAL_ADMIN_USER="localadmin"
if [[ -r "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Post-Clone: Status & Reparatur                         ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ================================================================
# Status
# ================================================================
echo ""
echo "  System"
printf "    %-22s %s\n" "Hostname:" "$(hostname -f 2>/dev/null || hostname)"
printf "    %-22s %s\n" "Beschreibung:" "$(cat /etc/server-description 2>/dev/null || echo '—')"
printf "    %-22s %s\n" "AD Domain (Config):" "${AD_DOMAIN:-— (keine Config gefunden)}"

echo ""
echo "  Firstboot"
if [[ -e "$MARKER" ]]; then
    printf "    %-22s %s\n" "Marker:" "vorhanden"
    sed 's/^/      /' "$MARKER"
else
    printf "    %-22s %s\n" "Marker:" "NICHT vorhanden — Firstboot lief nicht oder schlug fehl"
fi
if systemctl list-unit-files vb-firstboot.service &>/dev/null; then
    printf "    %-22s %s\n" "Service:" "$(systemctl is-enabled vb-firstboot.service 2>/dev/null || echo unbekannt) / $(systemctl is-active vb-firstboot.service 2>/dev/null || echo inaktiv)"
fi

echo ""
echo "  Active Directory"
# Als gejoint gilt die VM, wenn eine Keytab existiert und SSSD laeuft.
# Auf 'realm list' allein ist kein Verlass: beim adcli-Fallback kennt
# realmd die Mitgliedschaft nicht.
JOINED="nein"
if [[ -s /etc/krb5.keytab ]] && systemctl is-active --quiet sssd; then
    JOINED="ja"
fi
printf "    %-22s %s\n" "Domain Join:" "${JOINED}"
printf "    %-22s %s\n" "Keytab:" "$( [[ -s /etc/krb5.keytab ]] && echo 'vorhanden' || echo 'fehlt' )"
printf "    %-22s %s\n" "SSSD:" "$(systemctl is-active sssd 2>/dev/null || echo inaktiv)"
printf "    %-22s %s\n" "realm list:" "$(realm list 2>/dev/null | head -1 || true)"
if [[ -n "$AD_ADMIN_GROUP" && -n "$AD_DOMAIN" ]]; then
    if getent group "${AD_ADMIN_GROUP}@${AD_DOMAIN}" >/dev/null 2>&1; then
        printf "    %-22s %s\n" "Gruppen-Lookup:" "OK (${AD_ADMIN_GROUP}@${AD_DOMAIN})"
    else
        printf "    %-22s %s\n" "Gruppen-Lookup:" "fehlgeschlagen (${AD_ADMIN_GROUP}@${AD_DOMAIN})"
        JOINED="nein"
    fi
fi

if [[ -f "$LOG_FILE" ]]; then
    echo ""
    echo "  Letzte Zeilen aus ${LOG_FILE}:"
    tail -n 8 "$LOG_FILE" | sed 's/^/    /'
fi

# ================================================================
# Break-Glass-Passwort
# ================================================================
if [[ "$DO_PASSWORD" == "yes" ]]; then
    echo ""
    echo "── Break-Glass-Passwort fuer '${LOCAL_ADMIN_USER}' neu setzen"
    echo "   Sonderzeichen sind erlaubt; die Eingabe wird nicht angezeigt."
    echo ""
    while true; do
        IFS= read -r -s -p "  Neues Passwort: " NEW_PW; echo ""
        if [[ -z "$NEW_PW" ]]; then
            echo "    Passwort darf nicht leer sein."
            continue
        fi
        IFS= read -r -s -p "  Wiederholung:   " NEW_PW2; echo ""
        if [[ "$NEW_PW" != "$NEW_PW2" ]]; then
            echo "    Eingaben stimmen nicht ueberein."
            continue
        fi
        break
    done
    # chpasswd trennt user:password am ERSTEN ':' — Doppelpunkte im
    # Passwort bleiben damit erhalten.
    printf '%s:%s\n' "$LOCAL_ADMIN_USER" "$NEW_PW" | chpasswd
    unset NEW_PW NEW_PW2
    echo "    Passwort fuer '${LOCAL_ADMIN_USER}' gesetzt."
fi

# ================================================================
# Join nachholen / wiederholen
# ================================================================
if [[ "$MODE" == "status" ]]; then
    echo ""
    echo "  (--status: es wurde nichts veraendert)"
    exit 0
fi

if [[ "$MODE" == "auto" && "$JOINED" == "ja" && -e "$MARKER" ]]; then
    echo ""
    echo "  Nichts zu tun — die VM ist gejoint und der Firstboot ist durchgelaufen."
    echo "  Erneuten Join erzwingen: sudo $0 --force"
    exit 0
fi

if [[ ! -x "$FIRSTBOOT_BIN" ]]; then
    echo ""
    echo "  FEHLER: ${FIRSTBOOT_BIN} nicht gefunden."
    echo "  Dieses Template wurde ohne Firstboot-Automatik gebaut."
    echo "  Fuer einen manuellen Join stattdessen './domain-join.sh' verwenden."
    exit 1
fi

echo ""
echo "── Domain Join wird nachgeholt (${FIRSTBOOT_BIN} --force)"

# Auf einem erfolgreich gejointen Klon ist das Join-Secret bewusst
# geloescht. Fuer einen erneuten Join muss es einmalig eingegeben werden.
if [[ ! -s "$SECRET_FILE" && -z "${VB_JOIN_PASSWORD:-}" ]]; then
    echo ""
    echo "   Das Join-Secret wurde auf diesem Klon nach dem ersten Join"
    echo "   geloescht. Passwort des Join-Accounts '${JOIN_USER:-?}' eingeben:"
    echo ""
    IFS= read -r -s -p "  Passwort: " VB_JOIN_PASSWORD; echo ""
    if [[ -z "$VB_JOIN_PASSWORD" ]]; then
        echo "  Abgebrochen — kein Passwort eingegeben."
        exit 1
    fi
    export VB_JOIN_PASSWORD
fi

echo ""
if "$FIRSTBOOT_BIN" --force; then
    unset VB_JOIN_PASSWORD
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  Post-Clone abgeschlossen.                              ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo "   AD-Login:    <user>@${AD_DOMAIN}"
    echo "   Break-Glass: ${LOCAL_ADMIN_USER}"
else
    unset VB_JOIN_PASSWORD
    echo ""
    echo "  FEHLER: Firstboot-Lauf fehlgeschlagen."
    echo "  Details: ${LOG_FILE}  bzw.  journalctl -u vb-firstboot -n 50"
    echo "  Troubleshooting: siehe README.md"
    exit 1
fi
