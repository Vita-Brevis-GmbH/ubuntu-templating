#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  prepare-template.sh
#  Automatisiert die Vorbereitung einer Ubuntu 24.04 LTS VM
#  als VMware Template (Parts 1-6 aus vmware-template-guide.md)
#
#  Verwendung: sudo ./prepare-template.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Hilfsfunktionen ────────────────────────────────────────────
STEP=0
TOTAL=7

log() {
    STEP=$((STEP + 1))
    echo ""
    echo "========================================================"
    echo "==> [$STEP/$TOTAL] $1"
    echo "========================================================"
}

backup_file() {
    local f="$1"
    if [[ -f "$f" && ! -f "${f}.bak" ]]; then
        cp "$f" "${f}.bak"
        echo "    Backup: ${f}.bak"
    fi
}

# Eingabe mit Default-Wert: prompt_input "Beschreibung" "default"
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

# ── Interaktive Konfiguration ──────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  VMware Template Preparation - Ubuntu 24.04 LTS        ║"
echo "║  Konfiguration                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Bitte Domain- und AD-Einstellungen angeben."
echo "  Enter druecken fuer den Default-Wert in [Klammern]."
echo ""

AD_DOMAIN=$(prompt_input "AD Domain (FQDN)" "int.vitabrevis.ch")
AD_REALM=$(prompt_input "Kerberos Realm" "$(echo "${AD_DOMAIN}" | tr '[:lower:]' '[:upper:]')")
KDC_PRIMARY=$(prompt_input "Primaerer KDC (FQDN)" "dcs01-000-vb.${AD_DOMAIN}")
KDC_SECONDARY=$(prompt_input "Sekundaerer KDC (FQDN, leer = keiner)" "dcs02-000-vb.${AD_DOMAIN}")
AD_ADMIN_GROUP=$(prompt_input "AD Admin-Gruppe (fuer sudo)" "G_server-admin")
DEFAULT_USER=$(prompt_input "Default lokaler Admin-User" "localadmin")
SERVER_DESCRIPTION=$(prompt_input "Server-Beschreibung" "Template - please set description")

# SNMP Community (nur SNMPv2c, read-only) — verpflichtend
SNMP_COMMUNITY=$(prompt_input "SNMPv2c Community (read-only)" "vb-rubigen")
if [[ -z "${SNMP_COMMUNITY}" ]]; then
    echo "  Fehler: SNMP Community darf nicht leer sein."
    exit 1
fi
SNMP_LOCATION=$(prompt_input "SNMP sysLocation" "Vita Brevis Datacenter")
SNMP_CONTACT=$(prompt_input "SNMP sysContact" "it@vitabrevis.ch")

# Zusammenfassung anzeigen
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  Konfiguration:                                     │"
printf "  │  %-18s %-35s│\n" "AD Domain:" "${AD_DOMAIN}"
printf "  │  %-18s %-35s│\n" "Kerberos Realm:" "${AD_REALM}"
printf "  │  %-18s %-35s│\n" "KDC Primary:" "${KDC_PRIMARY}"
printf "  │  %-18s %-35s│\n" "KDC Secondary:" "${KDC_SECONDARY:-—}"
printf "  │  %-18s %-35s│\n" "Admin-Gruppe:" "${AD_ADMIN_GROUP}"
printf "  │  %-18s %-35s│\n" "Default User:" "${DEFAULT_USER}"
printf "  │  %-18s %-35s│\n" "Beschreibung:" "${SERVER_DESCRIPTION}"
printf "  │  %-18s %-35s│\n" "SNMP Community:" "${SNMP_COMMUNITY//?/*}"
printf "  │  %-18s %-35s│\n" "SNMP Location:" "${SNMP_LOCATION}"
printf "  │  %-18s %-35s│\n" "SNMP Contact:" "${SNMP_CONTACT}"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
read -rp "  Weiter mit diesen Einstellungen? [J/n]: " CONFIRM
if [[ "${CONFIRM,,}" == "n" ]]; then
    echo "  Abgebrochen."
    exit 0
fi

# ================================================================
# Part 1 — VM Preparation
# ================================================================
log "System aktualisieren & Pakete installieren"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y -o Dpkg::Options::="--force-confold"

apt-get install -y \
    cloud-init \
    open-vm-tools \
    curl wget git \
    net-tools \
    ca-certificates

# localadmin User anlegen (falls nicht vorhanden)
if id "${DEFAULT_USER}" &>/dev/null; then
    echo "    User '${DEFAULT_USER}' existiert bereits — uebersprungen."
else
    adduser --disabled-password --gecos "Local Admin" "${DEFAULT_USER}"
    echo "    User '${DEFAULT_USER}' angelegt."
fi

usermod -aG sudo "${DEFAULT_USER}"

mkdir -p "/home/${DEFAULT_USER}/.ssh"
chmod 700 "/home/${DEFAULT_USER}/.ssh"
chown "${DEFAULT_USER}:${DEFAULT_USER}" "/home/${DEFAULT_USER}/.ssh"

echo "    Part 1 abgeschlossen."

# ================================================================
# Part 2 — cloud-init Konfiguration
# ================================================================
log "cloud-init konfigurieren"

# VMware Datasource
cat > /etc/cloud/cloud.cfg.d/99-vmware.cfg <<'EOF'
datasource_list: [VMware, OVF, None]
datasource:
  VMware:
    allow_raw_data: true
  OVF:
    transport: [com.vmware.guestInfo, iso]
EOF
echo "    /etc/cloud/cloud.cfg.d/99-vmware.cfg geschrieben."

# cloud.cfg komplett ersetzen
backup_file /etc/cloud/cloud.cfg

cat > /etc/cloud/cloud.cfg <<EOF
# Managed by prepare-template.sh — nicht manuell bearbeiten
preserve_hostname: false

system_info:
  default_user:
    name: ${DEFAULT_USER}
    lock_passwd: false
    gecos: Local Admin
    groups: [adm, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash

cloud_init_modules:
  - migrator
  - seed_random
  - bootcmd
  - write_files
  - growpart
  - resizefs
  - disk_setup
  - mounts
  - set_hostname
  - update_hostname
  - update_etc_hosts

cloud_config_modules:
  - ssh
  - set_passwords
  - package_update_upgrade_install

chpasswd:
  list: |
    ${DEFAULT_USER}:Change.Me.Now!
  expire: true

ssh_pwauth: true

cloud_final_modules:
  - scripts_vendor
  - scripts_per_once
  - scripts_per_boot
  - scripts_per_instance
  - scripts_user
  - final_message
EOF
echo "    /etc/cloud/cloud.cfg geschrieben."

echo "    Part 2 abgeschlossen."

# ================================================================
# Part 3 — SSH Host-Key Regeneration Service
# ================================================================
log "SSH Host-Key Service einrichten"

cat > /etc/systemd/system/ssh-host-keys.service <<'EOF'
[Unit]
Description=Generate SSH host keys if missing
Before=ssh.service sshd.service
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ssh-host-keys.service

echo "    ssh-host-keys.service aktiviert."
echo "    Part 3 abgeschlossen."

# ================================================================
# Part 4 — Login Banner (MOTD)
# ================================================================
log "MOTD Banner einrichten"

cat > /etc/update-motd.d/99-vita-brevis <<'MOTDEOF'
#!/bin/bash

HOSTNAME=$(hostname -f)
IP=$(hostname -I | awk '{print $1}')
DESCRIPTION=$(cat /etc/server-description 2>/dev/null || echo "No description set")
UPTIME=$(uptime -p)
OS=$(lsb_release -ds 2>/dev/null || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')

echo ""
echo "  ██╗   ██╗██╗████████╗ █████╗     ██████╗ ██████╗ ███████╗██╗   ██╗██╗███████╗"
echo "  ██║   ██║██║╚══██╔══╝██╔══██╗    ██╔══██╗██╔══██╗██╔════╝██║   ██║██║██╔════╝"
echo "  ██║   ██║██║   ██║   ███████║    ██████╔╝██████╔╝█████╗  ██║   ██║██║███████╗"
echo "  ╚██╗ ██╔╝██║   ██║   ██╔══██║    ██╔══██╗██╔══██╗██╔══╝  ╚██╗ ██╔╝██║╚════██║"
echo "   ╚████╔╝ ██║   ██║   ██║  ██║    ██████╔╝██║  ██║███████╗ ╚████╔╝ ██║███████║"
echo "    ╚═══╝  ╚═╝   ╚═╝   ╚═╝  ╚═╝    ╚═════╝ ╚═╝  ╚═╝╚══════╝  ╚═══╝  ╚═╝╚══════╝"
echo ""
echo "                         p o w e r e d   b y   V I T A   B R E V I S"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────┐"
printf "  │  %-20s  %-42s│\n" "Hostname:"    "$HOSTNAME"
printf "  │  %-20s  %-42s│\n" "IP Address:"  "$IP"
printf "  │  %-20s  %-42s│\n" "Description:" "$DESCRIPTION"
printf "  │  %-20s  %-42s│\n" "OS:"          "$OS"
printf "  │  %-20s  %-42s│\n" "Uptime:"      "$UPTIME"
echo "  └─────────────────────────────────────────────────────────────────┘"
echo ""
MOTDEOF

chmod +x /etc/update-motd.d/99-vita-brevis

# Standard-Banner deaktivieren
chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
chmod -x /etc/update-motd.d/80-livepatch 2>/dev/null || true

# Server-Beschreibung setzen
echo "${SERVER_DESCRIPTION}" > /etc/server-description

echo "    MOTD Banner und server-description eingerichtet."
echo "    Part 4 abgeschlossen."

# ================================================================
# Part 5 — SSSD & Active Directory
# ================================================================
log "SSSD & Active Directory vorbereiten"

# debconf preseed fuer krb5-user (verhindert interaktive Prompts)
echo "krb5-config krb5-config/default_realm string ${AD_REALM}" | debconf-set-selections
echo "krb5-config krb5-config/add_servers_realm string ${AD_REALM}" | debconf-set-selections
echo "krb5-config krb5-config/admin_server string ${KDC_PRIMARY}" | debconf-set-selections
echo "krb5-config krb5-config/kerberos_servers string ${KDC_PRIMARY}" | debconf-set-selections

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

# /etc/krb5.conf — sekundaerer KDC nur wenn angegeben
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

# Home-Verzeichnisse automatisch erstellen
pam-auth-update --enable mkhomedir

# Sudo fuer AD-Gruppe
cat > /etc/sudoers.d/ad-admins <<EOF
# Sudo fuer AD-Gruppe '${AD_ADMIN_GROUP}' erlauben
%${AD_ADMIN_GROUP}\@${AD_DOMAIN} ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/ad-admins
visudo -c -f /etc/sudoers.d/ad-admins
echo "    /etc/sudoers.d/ad-admins geschrieben und validiert."

# SSSD & Domain-Mitgliedschaft bereinigen (Template darf nicht joined sein)
realm leave 2>/dev/null || true
rm -f /etc/krb5.keytab

systemctl disable sssd 2>/dev/null || true
systemctl stop sssd 2>/dev/null || true

echo "    SSSD deaktiviert, Domain-Mitgliedschaft entfernt."
echo "    Part 5 abgeschlossen."

# ================================================================
# Part 6 — Netzwerk-Fallback
# ================================================================
log "Netzwerk-Fallback konfigurieren"

cat > /etc/netplan/99-fallback-dhcp.yaml <<'EOF'
network:
  version: 2
  ethernets:
    match-all:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
EOF
chmod 600 /etc/netplan/99-fallback-dhcp.yaml
echo "    /etc/netplan/99-fallback-dhcp.yaml geschrieben."

netplan apply

systemctl disable systemd-networkd-wait-online.service
systemctl mask systemd-networkd-wait-online.service
echo "    systemd-networkd-wait-online deaktiviert und maskiert."

echo "    Part 6 abgeschlossen."

# ================================================================
# Part 7 — SNMP Monitoring (SNMPv2c, read-only)
# ================================================================
log "SNMP Monitoring einrichten (snmpd, SNMPv2c read-only)"

apt-get install -y snmpd snmp

backup_file /etc/snmp/snmpd.conf

# Ubuntu Default-Config nur auf 127.0.0.1 hoerend ersetzen.
# Listen auf allen Interfaces (UDP/161); Zugriffsbeschraenkung via Community
# und Netzwerk-Firewall/Routing — keine Source-IP-ACL in der snmpd.conf.
cat > /etc/snmp/snmpd.conf <<EOF
# ─────────────────────────────────────────────────────────────
#  snmpd.conf — generiert von prepare-template.sh
#  SNMPv2c, read-only. Community wird beim Templating gesetzt.
# ─────────────────────────────────────────────────────────────

# Listen auf allen Interfaces, UDP Port 161
agentAddress udp:161

# Systeminformationen
sysLocation    ${SNMP_LOCATION}
sysContact     ${SNMP_CONTACT}
sysServices    72

# Komplette MIB-2 + UCD freigeben (CPU, RAM, Disk, Interfaces)
view   systemview  included   .1.3.6.1.2.1
view   systemview  included   .1.3.6.1.4.1.2021
view   systemview  included   .1.3.6.1.4.1.2021.11

# Read-only Community (SNMPv2c) — Zugriff von ueberall, Filter via Firewall
rocommunity ${SNMP_COMMUNITY} default -V systemview

# Disk-Monitoring: alle Mountpoints, jeweils Schwellwert 10% frei
includeAllDisks 10%

# Load-Schwellwerte (1/5/15 min) — auslesbar via UCD-MIB
load 12 10 5
EOF
chmod 600 /etc/snmp/snmpd.conf
echo "    /etc/snmp/snmpd.conf geschrieben."

# snmpd nicht via Default-Args /etc/default/snmpd auf 127.0.0.1 binden
# lassen — agentAddress aus snmpd.conf gilt.
if [[ -f /etc/default/snmpd ]]; then
    sed -i 's|^SNMPDOPTS=.*|SNMPDOPTS="-Lsd -Lf /dev/null -u Debian-snmp -g Debian-snmp -I -smux mteTrigger mteTriggerConf -p /run/snmpd.pid"|' /etc/default/snmpd
fi

systemctl enable snmpd
systemctl restart snmpd

# Quick-Sanity-Check (lokal)
sleep 1
if snmpget -v 2c -c "${SNMP_COMMUNITY}" -t 2 -r 1 127.0.0.1 sysDescr.0 >/dev/null 2>&1; then
    echo "    snmpd antwortet lokal — OK."
else
    echo "    Warnung: snmpd antwortet (noch) nicht — Status pruefen mit: systemctl status snmpd"
fi

echo "    Part 7 abgeschlossen."

# ================================================================
# Abschluss
# ================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Template-Vorbereitung abgeschlossen!                   ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Naechste Schritte:                                     ║"
echo "║  1. SSH Hardening manuell durchfuehren (falls gewuenscht)║"
echo "║  2. SNMP-Erreichbarkeit vom Monitoring-Host testen:     ║"
echo "║       snmpwalk -v 2c -c <community> <host> system       ║"
echo "║  3. seal-template.sh ausfuehren                         ║"
echo "║  4. VM herunterfahren: sudo shutdown -h now             ║"
echo "║  5. In vCenter: Convert to Template                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
