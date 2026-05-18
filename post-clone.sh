#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  post-clone.sh
#  Allgemeine Post-Clone Aufgaben nach dem Klonen eines
#  VMware Templates (Ubuntu 24.04 LTS).
#
#  Reihenfolge:
#    1. Domain Join (SSSD aktivieren)
#    2. AD-Authentifizierung testen
#    3. Benutzer vb-admin entfernen
#
#  Verwendung: sudo ./post-clone.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Hilfsfunktionen ────────────────────────────────────────────
STEP=0
TOTAL=3

log() {
    STEP=$((STEP + 1))
    echo ""
    echo "========================================================"
    echo "==> [$STEP/$TOTAL] $1"
    echo "========================================================"
}

prompt_input() {
    local prompt="$1"
    local default="$2"
    local value
    read -rp "  ${prompt} [${default}]: " value
    echo "${value:-$default}"
}

# ── Root-Check ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Dieses Script muss als root ausgefuehrt werden."
    echo "Verwendung: sudo $0"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Post-Clone: Allgemeine Nachbereitung                   ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── Interaktive Abfrage ────────────────────────────────────────
echo ""
echo "  Domain Join & AD-Konfiguration"
echo ""

# Domain aus krb5.conf lesen falls vorhanden
DEFAULT_DOMAIN="int.vitabrevis.ch"
if [[ -f /etc/krb5.conf ]]; then
    DETECTED_DOMAIN=$(grep -m1 "default_realm" /etc/krb5.conf 2>/dev/null | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
    [[ -n "$DETECTED_DOMAIN" ]] && DEFAULT_DOMAIN="$DETECTED_DOMAIN"
fi

AD_DOMAIN=$(prompt_input "AD Domain (FQDN)" "${DEFAULT_DOMAIN}")
AD_REALM=$(echo "${AD_DOMAIN}" | tr '[:lower:]' '[:upper:]')
JOIN_USER=$(prompt_input "Join-User (AD-Konto fuer Domain Join)" "Administrator")
TEST_USER=$(prompt_input "Test-User (AD-Konto zum Verifizieren)" "")

# Test-User Validierung
if [[ -z "${TEST_USER}" ]]; then
    echo "  Fehler: Ein Test-User muss angegeben werden."
    exit 1
fi

# Zusammenfassung
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Konfiguration:                                     │"
printf "  │  %-18s %-35s│\n" "AD Domain:" "${AD_DOMAIN}"
printf "  │  %-18s %-35s│\n" "Kerberos Realm:" "${AD_REALM}"
printf "  │  %-18s %-35s│\n" "Join-User:" "${JOIN_USER}"
printf "  │  %-18s %-35s│\n" "Test-User:" "${TEST_USER}"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
read -rp "  Weiter mit diesen Einstellungen? [J/n]: " CONFIRM
if [[ "${CONFIRM,,}" == "n" ]]; then
    echo "  Abgebrochen."
    exit 0
fi

# ================================================================
# Schritt 1 — Domain Join & SSSD aktivieren
# ================================================================
log "Domain Join & SSSD aktivieren"

echo "    Veraltete Domain-Mitgliedschaft bereinigen..."
realm leave 2>/dev/null || true
rm -f /etc/krb5.keytab

echo "    Domain-Erreichbarkeit pruefen..."
if ! realm discover "${AD_DOMAIN}" &>/dev/null; then
    echo "    FEHLER: Domain '${AD_DOMAIN}' nicht erreichbar!"
    echo "    DNS pruefen: nslookup _ldap._tcp.${AD_DOMAIN}"
    exit 1
fi
echo "    Domain '${AD_DOMAIN}' erreichbar."

echo ""
echo "    Domain Join mit User '${JOIN_USER}'..."
echo "    (Passwort-Eingabe wird von realm join abgefragt)"
echo ""
realm join --user="${JOIN_USER}" "${AD_DOMAIN}"

echo ""
echo "    Mitgliedschaft pruefen..."
realm list

echo "    SSSD aktivieren & starten..."
systemctl enable --now sssd

echo "    Domain Join abgeschlossen."

# ================================================================
# Schritt 2 — AD-Authentifizierung testen
# ================================================================
log "AD-Authentifizierung mit '${TEST_USER}' testen"

TEST_OK=true

# Test 1: User-Lookup via SSSD
echo "    [Test 1/3] User-Lookup: id ${TEST_USER}@${AD_DOMAIN}"
if id "${TEST_USER}@${AD_DOMAIN}" &>/dev/null; then
    id "${TEST_USER}@${AD_DOMAIN}"
    echo "    ✔ User-Lookup erfolgreich."
else
    echo "    ✘ User '${TEST_USER}@${AD_DOMAIN}' nicht gefunden!"
    echo "      Moeglicherweise braucht SSSD einen Moment..."
    sleep 3
    if id "${TEST_USER}@${AD_DOMAIN}" &>/dev/null; then
        id "${TEST_USER}@${AD_DOMAIN}"
        echo "    ✔ User-Lookup erfolgreich (nach Retry)."
    else
        echo "    ✘ User-Lookup fehlgeschlagen."
        TEST_OK=false
    fi
fi

# Test 2: Kerberos Ticket
echo ""
echo "    [Test 2/3] Kerberos: kinit ${TEST_USER}@${AD_REALM}"
echo "    (Passwort des Test-Users eingeben)"
echo ""
if kinit "${TEST_USER}@${AD_REALM}"; then
    echo "    ✔ Kerberos-Ticket erhalten."
    klist
    kdestroy
else
    echo "    ✘ Kerberos-Authentifizierung fehlgeschlagen."
    TEST_OK=false
fi

# Test 3: SSSD Status
echo ""
echo "    [Test 3/3] SSSD Status..."
if systemctl is-active --quiet sssd; then
    echo "    ✔ SSSD laeuft."
else
    echo "    ✘ SSSD laeuft nicht!"
    TEST_OK=false
fi

# Ergebnis auswerten
echo ""
if [[ "${TEST_OK}" == true ]]; then
    echo "    ════════════════════════════════════════════"
    echo "    ✔  Alle AD-Tests bestanden!"
    echo "    ════════════════════════════════════════════"
else
    echo "    ════════════════════════════════════════════"
    echo "    ✘  Einige Tests fehlgeschlagen!"
    echo "    ════════════════════════════════════════════"
    echo ""
    read -rp "  Trotzdem fortfahren und vb-admin entfernen? (ja/nein): " FORCE
    if [[ "${FORCE,,}" != "ja" ]]; then
        echo "  Abgebrochen. vb-admin bleibt erhalten."
        echo "  Troubleshooting: siehe vmware-template-guide.md Part 8"
        exit 1
    fi
fi

# ================================================================
# Schritt 3 — Benutzer vb-admin entfernen
# ================================================================
log "Benutzer 'vb-admin' entfernen"

if id "vb-admin" &>/dev/null; then
    # Aktive Prozesse des Users beenden
    pkill -u vb-admin 2>/dev/null || true

    # User + Home-Verzeichnis entfernen
    deluser --remove-home vb-admin 2>/dev/null || userdel -r vb-admin 2>/dev/null || true

    # Sicherstellen dass Home-Verzeichnis weg ist
    rm -rf /home/vb-admin

    echo "    Benutzer 'vb-admin' und Home-Verzeichnis entfernt."
else
    echo "    Benutzer 'vb-admin' existiert nicht — uebersprungen."
fi

# ================================================================
# Abschluss
# ================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Post-Clone abgeschlossen!                              ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  ✔ Domain Join:  ${AD_DOMAIN}                           "
echo "║  ✔ SSSD:         aktiv                                  ║"
echo "║  ✔ vb-admin:     entfernt                               ║"
echo "╚══════════════════════════════════════════════════════════╝"
