#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  domain-join.sh
#  Standalone-Script fuer Active Directory Domain Join auf einem
#  Ubuntu-24.04-System — installiert und konfiguriert SSSD/Kerberos,
#  joint die Domain und verifiziert das Ergebnis mit einem Test-User.
#
#  Ablauf:
#    1. Pakete installieren (SSSD-Stack, realmd, krb5-user)
#    2. /etc/krb5.conf schreiben
#    3. /etc/sssd/sssd.conf + sudoers.d/ad-admins + mkhomedir
#    4. Domain Join & SSSD aktivieren
#    5. AD-Authentifizierung mit Test-User verifizieren
#
#  Verwendung: sudo ./domain-join.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Hilfsfunktionen ────────────────────────────────────────────
STEP=0
TOTAL=5

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
echo "║  Active Directory Domain Join (SSSD)                    ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── Interaktive Konfiguration ──────────────────────────────────
echo ""
echo "  Bitte AD-Einstellungen angeben."
echo "  Enter druecken fuer den Default-Wert in [Klammern]."
echo ""

# Default-Domain: falls krb5.conf bereits existiert, dortigen Realm nehmen
DEFAULT_DOMAIN="int.vitabrevis.ch"
if [[ -f /etc/krb5.conf ]]; then
    DETECTED=$(grep -m1 "default_realm" /etc/krb5.conf 2>/dev/null | awk '{print $3}' | tr '[:upper:]' '[:lower:]')
    [[ -n "${DETECTED}" ]] && DEFAULT_DOMAIN="${DETECTED}"
fi

AD_DOMAIN=$(prompt_input "AD Domain (FQDN)" "${DEFAULT_DOMAIN}")
AD_REALM=$(prompt_input "Kerberos Realm" "$(echo "${AD_DOMAIN}" | tr '[:lower:]' '[:upper:]')")
KDC_PRIMARY=$(prompt_input "Primaerer KDC (FQDN)" "dcs01-000-vb.${AD_DOMAIN}")
KDC_SECONDARY=$(prompt_input "Sekundaerer KDC (FQDN, leer = keiner)" "dcs02-000-vb.${AD_DOMAIN}")
AD_ADMIN_GROUP=$(prompt_input "AD Admin-Gruppe (fuer sudo)" "G_server-admin")
JOIN_USER=$(prompt_input "Join-User (AD-Konto fuer Domain Join)" "Administrator")
TEST_USER=$(prompt_input "Test-User (AD-Konto zum Verifizieren)" "")

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
printf "  │  %-18s %-35s│\n" "KDC Primary:" "${KDC_PRIMARY}"
printf "  │  %-18s %-35s│\n" "KDC Secondary:" "${KDC_SECONDARY:-—}"
printf "  │  %-18s %-35s│\n" "Admin-Gruppe:" "${AD_ADMIN_GROUP}"
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
# Schritt 1 — Pakete installieren
# ================================================================
log "SSSD- und Kerberos-Pakete installieren"

export DEBIAN_FRONTEND=noninteractive

# debconf preseed fuer krb5-user (verhindert interaktive Prompts)
echo "krb5-config krb5-config/default_realm string ${AD_REALM}"        | debconf-set-selections
echo "krb5-config krb5-config/add_servers_realm string ${AD_REALM}"    | debconf-set-selections
echo "krb5-config krb5-config/admin_server string ${KDC_PRIMARY}"      | debconf-set-selections
echo "krb5-config krb5-config/kerberos_servers string ${KDC_PRIMARY}"  | debconf-set-selections

apt-get update
apt-get install -y \
    sssd \
    sssd-ad \
    sssd-tools \
    realmd \
    adcli \
    samba-common-bin \
    oddjob \
    oddjob-mkhomedir \
    packagekit \
    krb5-user

echo "    Pakete installiert."

# ================================================================
# Schritt 2 — /etc/krb5.conf schreiben
# ================================================================
log "/etc/krb5.conf schreiben"

KDC_LINES="        kdc = ${KDC_PRIMARY}"
if [[ -n "${KDC_SECONDARY}" ]]; then
    KDC_LINES="${KDC_LINES}
        kdc = ${KDC_SECONDARY}"
fi

cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${AD_REALM}
    kdc_timesync = 1
    ccache_type = 4
    forwardable = true
    proxiable = true
    rdns = false
    dns_canonicalize_hostname = false
    udp_preference_limit = 0

[realms]
    ${AD_REALM} = {
${KDC_LINES}
        admin_server = ${KDC_PRIMARY}
    }

[domain_realm]
    .${AD_DOMAIN} = ${AD_REALM}
    ${AD_DOMAIN} = ${AD_REALM}
EOF
echo "    /etc/krb5.conf geschrieben."

# ================================================================
# Schritt 3 — SSSD-, Sudo- und PAM-Konfiguration
# ================================================================
log "SSSD- / Sudo- / PAM-Konfiguration schreiben"

# /etc/sssd/sssd.conf
cat > /etc/sssd/sssd.conf <<EOF
[sssd]
domains = ${AD_DOMAIN}
config_file_version = 2
services = nss, pam, sudo
default_domain_suffix = ${AD_DOMAIN}

[domain/${AD_DOMAIN}]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = ${AD_REALM}
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u@%d
ad_domain = ${AD_DOMAIN}
use_fully_qualified_names = True
ldap_id_mapping = True
access_provider = ad
ldap_referrals = False
dyndns_update = True
EOF
chmod 600 /etc/sssd/sssd.conf
echo "    /etc/sssd/sssd.conf geschrieben (chmod 600)."

# Sudo fuer AD-Admin-Gruppe
cat > /etc/sudoers.d/ad-admins <<EOF
# Sudo fuer AD-Gruppe '${AD_ADMIN_GROUP}' erlauben
%${AD_ADMIN_GROUP}\@${AD_DOMAIN} ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/ad-admins
visudo -c -f /etc/sudoers.d/ad-admins
echo "    /etc/sudoers.d/ad-admins geschrieben und validiert."

# Automatische Home-Verzeichnisse via PAM
pam-auth-update --enable mkhomedir
echo "    pam_mkhomedir aktiviert."

# ================================================================
# Schritt 4 — Domain Join & SSSD aktivieren
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

# SSSD nach dem Schreiben unserer sssd.conf neu einlesen — realm join
# hat die Datei ggf. ergaenzt/ueberschrieben; wir setzen sie hier bewusst
# noch einmal, damit z.B. default_domain_suffix und use_fully_qualified_names
# unseren Werten entsprechen.
cat > /etc/sssd/sssd.conf <<EOF
[sssd]
domains = ${AD_DOMAIN}
config_file_version = 2
services = nss, pam, sudo
default_domain_suffix = ${AD_DOMAIN}

[domain/${AD_DOMAIN}]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = ${AD_REALM}
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u@%d
ad_domain = ${AD_DOMAIN}
use_fully_qualified_names = True
ldap_id_mapping = True
access_provider = ad
ldap_referrals = False
dyndns_update = True
EOF
chmod 600 /etc/sssd/sssd.conf
systemctl restart sssd

echo "    Domain Join abgeschlossen."

# ================================================================
# Schritt 5 — AD-Authentifizierung testen
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
    echo "    Troubleshooting: siehe README.md Part 8"
    exit 1
fi

# ================================================================
# Abschluss
# ================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Domain Join abgeschlossen!                             ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  ✔ Domain:       %-40s║\n" "${AD_DOMAIN}"
echo "║  ✔ SSSD:         aktiv                                  ║"
echo "║  ✔ Sudo:         '${AD_ADMIN_GROUP}' hat sudo-Rechte"
echo "╚══════════════════════════════════════════════════════════╝"
