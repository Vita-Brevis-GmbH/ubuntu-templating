#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  prepare-template.sh
#  Automatisiert die Vorbereitung einer Ubuntu LTS VM als VMware
#  Template. Getestet auf Ubuntu 26.04 LTS und 24.04 LTS.
#
#  Verwendung: sudo ./prepare-template.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# Verzeichnis, in dem dieses Script (und firstboot.sh) liegt
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Hilfsfunktionen ────────────────────────────────────────────
STEP=0
TOTAL=9

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

# Passworteingabe ohne Echo, mit Wiederholung. Prompts und Meldungen
# gehen nach stderr, damit nur das Passwort selbst auf stdout landet
# und per $(...) uebernommen werden kann.
prompt_secret() {
    local prompt="$1"
    local first second
    while true; do
        IFS= read -r -s -p "  ${prompt}: " first
        echo "" >&2
        IFS= read -r -s -p "  ${prompt} (Wiederholung): " second
        echo "" >&2
        if [[ "$first" == "$second" ]]; then
            printf '%s' "$first"
            return 0
        fi
        echo "    Eingaben stimmen nicht ueberein. Bitte erneut." >&2
    done
}

# ── Root-Check ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Dieses Script muss als root ausgefuehrt werden."
    echo "Verwendung: sudo $0"
    exit 1
fi

# ── Ubuntu-Release ermitteln ───────────────────────────────────
# Das Script ist auf 24.04 LTS und 26.04 LTS getestet. Auf 26.04 sind
# sudo-rs und uutils-coreutils Standard; die Scripts sind darauf
# ausgelegt, aber ein unbekanntes Release soll bewusst auffallen.
UBUNTU_RELEASE="unbekannt"
if [[ -r /etc/os-release ]]; then
    UBUNTU_RELEASE="$(. /etc/os-release && echo "${VERSION_ID:-unbekannt}")"
fi

case "${UBUNTU_RELEASE}" in
    24.04|26.04)
        : ;;
    *)
        echo ""
        echo "  WARNUNG: Ubuntu ${UBUNTU_RELEASE} ist mit diesen Scripts nicht getestet."
        echo "  Getestet sind 24.04 LTS und 26.04 LTS."
        read -rp "  Trotzdem fortfahren? (ja/nein): " _rel_confirm
        if [[ "${_rel_confirm,,}" != "ja" ]]; then
            echo "  Abgebrochen."
            exit 1
        fi
        ;;
esac

# ── Mitgelieferte Dateien pruefen ──────────────────────────────
for _required in firstboot.sh vb-firstboot.service; do
    if [[ ! -f "${SCRIPT_DIR}/${_required}" ]]; then
        echo "Fehler: '${_required}' nicht gefunden in ${SCRIPT_DIR}."
        echo "Bitte das komplette Repository auf die Template-VM klonen."
        exit 1
    fi
done

# ── Interaktive Konfiguration ──────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
printf "║  VMware Template Preparation - Ubuntu %-19s║\n" "${UBUNTU_RELEASE} LTS"
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

# ── Automatischer Domain Join beim ersten Boot ─────────────────
echo ""
echo "  Automatischer Domain Join (vb-firstboot)"
echo "  Der hinterlegte Service-Account joint jeden Klon beim ersten"
echo "  Boot selbsttaetig. Er braucht auf der Computer-OU nur das"
echo "  Recht, Computerobjekte anzulegen und zurueckzusetzen."
echo ""

JOIN_USER=$(prompt_input "AD Join-Account" "svc-domainjoin")
COMPUTER_OU=$(prompt_input "Computer-OU als DN (leer = Default-Container)" "")

# Passwort: entweder aus der Umgebung (unbeaufsichtigter Build) oder
# interaktiv. Leer = automatischer Join wird deaktiviert.
JOIN_PASSWORD="${VB_JOIN_PASSWORD:-}"
if [[ -z "${JOIN_PASSWORD}" ]]; then
    JOIN_PASSWORD=$(prompt_secret "Passwort fuer '${JOIN_USER}' (leer = kein Auto-Join)")
fi

if [[ -n "${JOIN_PASSWORD}" ]]; then
    ENABLE_JOIN="yes"
else
    ENABLE_JOIN="no"
    echo ""
    echo "  Hinweis: Kein Join-Passwort angegeben — der automatische"
    echo "  Domain Join bleibt deaktiviert. Klone muessen dann manuell"
    echo "  per 'post-clone.sh --force' oder 'domain-join.sh' joinen."
fi

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
printf "  │  %-18s %-35s│\n" "Auto-Join:" "${ENABLE_JOIN}"
printf "  │  %-18s %-35s│\n" "Join-Account:" "${JOIN_USER}"
printf "  │  %-18s %-35s│\n" "Computer-OU:" "${COMPUTER_OU:-— (Default)}"
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
#
# 'datasource_list' muss einzeilig bleiben: ds-identify ist ein
# Shell-Script mit zeilenweisem Parser und liest ein mehrzeiliges Array
# nicht. Seit cloud-init 25.1 verlangt ds-identify ausserdem eine
# eindeutige Identifikation — diese explizite Liste ist genau das.
#
# Kein 'OVF: transport:' mehr: DataSourceOVF.py hat die Transportliste
# fest im Code (com.vmware.guestInfo, dann iso) und liest dafuer gar
# keine Konfiguration. Der Schluessel war immer wirkungslos, auch auf
# 24.04 — die gewuenschte Reihenfolge ist ohnehin die eingebaute.
cat > /etc/cloud/cloud.cfg.d/99-vmware.cfg <<'EOF'
datasource_list: [VMware, OVF, None]
datasource:
  VMware:
    allow_raw_data: true
EOF
echo "    /etc/cloud/cloud.cfg.d/99-vmware.cfg geschrieben."

# cloud.cfg komplett ersetzen
backup_file /etc/cloud/cloud.cfg

cat > /etc/cloud/cloud.cfg <<EOF
# Managed by prepare-template.sh — nicht manuell bearbeiten
#
# Bewusst KEIN 'chpasswd'-Block: das Break-Glass-Passwort fuer
# '${DEFAULT_USER}' wird ausschliesslich von seal-template.sh gesetzt.
# Stuende es zusaetzlich hier, wuerde cloud-init es beim ersten Boot
# jedes Klons wieder ueberschreiben — es gaebe zwei konkurrierende
# Quellen fuer dasselbe Passwort.
preserve_hostname: false

# Deklarativ. Wirksam wird dieser Block erst durch das Modul
# 'users_groups', und das steht bewusst NICHT in der Liste unten:
# '${DEFAULT_USER}' wird von diesem Script per adduser angelegt, nicht
# von cloud-init. Wuerde 'users_groups' laufen, schriebe cloud-init
# zusaetzlich /etc/sudoers.d/90-cloud-init-users mit NOPASSWD — das
# soll der Break-Glass-Account nicht bekommen.
system_info:
  default_user:
    name: ${DEFAULT_USER}
    lock_passwd: false
    gecos: Local Admin
    groups: [adm, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash

# 'migrator' ist seit cloud-init 24.1 entfernt und steht deshalb nicht
# mehr in der Liste — es wuerde nur eine Meldung im Log erzeugen.
cloud_init_modules:
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
  - set_passwords

cloud_config_modules:
  - ssh
  - package_update_upgrade_install

# Wird vom Modul 'set_passwords' angewendet. Das steht oben in der
# init-Stage, so wie es Ubuntu ab 26.04 auch selbst ausliefert — dort
# ist es aus cloud_config_modules dorthin gewandert.
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
# Ordnung wie in dem 'sshd-keygen.service', das Ubuntu ab 26.04 selbst
# mitliefert: ssh.socket steht bewusst NICHT in Before=. Der Socket
# bindet nur den Port und braucht keine Host Keys — die braucht der
# Dienst, der die Verbindung annimmt. Ein Before=ssh.socket wuerde das
# Binden des Ports unnoetig verzoegern.
Before=ssh.service sshd.service sshd@.service
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
# ssh.socket gehoert dagegen in WantedBy: bei Socket-Aktivierung startet
# ssh.service beim Booten gar nicht, die Unit soll aber trotzdem mit dem
# Socket zusammen angezogen werden.
WantedBy=multi-user.target ssh.socket
EOF

systemctl daemon-reload
systemctl enable ssh-host-keys.service

echo "    ssh-host-keys.service aktiviert."
echo "    Part 3 abgeschlossen."

# ================================================================
# Part 3b — SSH Hardening
# ================================================================
log "SSH Hardening konfigurieren"

# Als Drop-in statt als Aenderung an sshd_config: Ubuntu zieht
# /etc/ssh/sshd_config.d/*.conf ganz oben ein, damit gewinnen unsere
# Werte und ein Distributions-Update kann die Datei nicht ueberschreiben.
#
# AllowGroups trennt seine Muster an Leerzeichen. Ein Gruppenname mit
# Leerzeichen ("Domain Admins") zerfiele unquotiert still in zwei Muster
# — 'sshd -t' meldet das NICHT, die Regel waere aber falsch. Deshalb das
# ganze Muster quoten, sobald ein Leerzeichen vorkommt.
ssh_pattern() {
    local p="$1"
    if [[ "$p" == *" "* ]]; then printf '"%s"' "$p"; else printf '%s' "$p"; fi
}

# Zur Schreibweise: sshd vergleicht Gruppennamen ZEICHENGENAU, SSSD
# nicht. Beim AD-Provider ist 'case_sensitive = True' laut sssd.conf(5)
# sogar ungueltig, der Default ist False — Namen kommen aus NSS also
# kleingeschrieben zurueck, egal wie sie im Verzeichnis stehen.
# Wer hier 'G_server-admin' eintippt, bekommt von 'getent group' brav
# einen Treffer, waehrend sshd denselben Benutzer abweist, weil in
# dessen Gruppenliste 'g_server-admin@domain' steht.
# Deshalb die Kleinschreibung als Standard, die eingegebene Variante
# zusaetzlich fuer den Fall 'case_sensitive = Preserving'.
# vb-firstboot.sh zieht die Zeile nach dem Join ohnehin auf den
# tatsaechlich gelieferten Namen nach.
AD_GROUP_TYPED="${AD_ADMIN_GROUP}@${AD_DOMAIN}"
AD_GROUP_LOWER="${AD_GROUP_TYPED,,}"
AD_SSH_PATTERN="$(ssh_pattern "${AD_GROUP_LOWER}")"
if [[ "${AD_GROUP_TYPED}" != "${AD_GROUP_LOWER}" ]]; then
    AD_SSH_PATTERN="${AD_SSH_PATTERN} $(ssh_pattern "${AD_GROUP_TYPED}")"
fi

cat > /etc/ssh/sshd_config.d/99-vita-brevis.conf <<EOF
# Managed by prepare-template.sh — nicht manuell bearbeiten

PermitRootLogin no
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

# Kerberos/GSSAPI fuer Single-Sign-on nach dem Domain Join
KerberosAuthentication yes
GSSAPIAuthentication yes
GSSAPICleanupCredentials yes

X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2

# Zugang auf die AD-Admin-Gruppe und lokale Admins beschraenken.
# 'sudo' deckt den Break-Glass-User ab und bleibt erreichbar, solange
# die Domain nicht verfuegbar ist.
AllowGroups sudo ${DEFAULT_USER} ${AD_SSH_PATTERN}
EOF
chmod 644 /etc/ssh/sshd_config.d/99-vita-brevis.conf

# Erst validieren, dann aktivieren — eine kaputte sshd_config wuerde
# die laufende Session beim naechsten Reconnect aussperren.
if sshd -t 2>/dev/null; then
    # try-reload-or-restart wirkt nur auf eine aktive Unit. Bei
    # socket-aktiviertem sshd (Ubuntu 22.10+) ist ssh.service inaktiv und
    # der Befehl ist ein No-op — richtig so, denn dort liest jede neue
    # Verbindung die Konfiguration ohnehin frisch ein.
    systemctl try-reload-or-restart ssh 2>/dev/null || true
    echo "    /etc/ssh/sshd_config.d/99-vita-brevis.conf aktiv."
else
    rm -f /etc/ssh/sshd_config.d/99-vita-brevis.conf
    echo "    WARNUNG: sshd-Konfiguration ungueltig — Drop-in wurde wieder entfernt."
    sshd -t || true
fi

echo "    Part 3b abgeschlossen."

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
#
# Schreibweise: unquoted, Leerzeichen mit Backslash escaped.
# Das ist die einzige Form, die beide Parser akzeptieren:
#   - sudo 1.9.x (Ubuntu 24.04) nimmt sie ebenso wie die frueher hier
#     verwendete Variante in doppelten Anfuehrungszeichen.
#   - sudo-rs (Standard ab Ubuntu 26.04) kennt KEINE Anfuehrungszeichen
#     um Benutzer- und Gruppennamen. Sein Lexer akzeptiert '@' mitten im
#     Namen, ein fuehrendes '"' dagegen nicht — die gequotete Variante
#     waere dort ein Syntaxfehler und die ganze Datei ungueltig.
# '\@' ist ebenfalls raus: sudo-rs kennt nur \\ \" \, \: \= \! \( \) und
# das Leerzeichen als Escape-Sequenz.
AD_ADMIN_GROUP_SUDO="${AD_ADMIN_GROUP// /\\ }"

cat > /etc/sudoers.d/ad-admins <<EOF
# Sudo fuer AD-Gruppe '${AD_ADMIN_GROUP}' erlauben
# Generiert von prepare-template.sh — nicht manuell bearbeiten.
%${AD_ADMIN_GROUP_SUDO}@${AD_DOMAIN} ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/ad-admins

# Validieren. Eine ungueltige Datei in /etc/sudoers.d macht sudo
# systemweit unbrauchbar — deshalb hier abbrechen statt weiterlaufen.
if ! visudo -c -f /etc/sudoers.d/ad-admins; then
    rm -f /etc/sudoers.d/ad-admins
    echo "    FEHLER: sudoers-Regel ungueltig — Datei wurde wieder entfernt."
    echo "    Gruppenname pruefen: '${AD_ADMIN_GROUP}'"
    exit 1
fi
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

# 'optional: true' ist der netplan-eigene Hebel gegen blockierende
# Boots. Ab netplan 1.2 (Ubuntu 26.04) erzeugt der Generator fuer jedes
# nicht-optionale Interface ein ExecStart-Override von
# systemd-networkd-wait-online, das auf eine routbare Adresse UND auf
# DNS wartet. Optional markierte Netdefs werden dabei uebersprungen.
# Zusammen mit dem Maskieren der Unit weiter unten ist der Boot damit
# doppelt abgesichert.
cat > /etc/netplan/99-fallback-dhcp.yaml <<'EOF'
network:
  version: 2
  ethernets:
    match-all:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
      optional: true
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

# Hinweis: /etc/default/snmpd wird bewusst NICHT angefasst. Die
# systemd-Unit von snmpd hat kein EnvironmentFile und baut ihre
# Kommandozeile fest zusammen — SNMPDOPTS aus /etc/default/snmpd wird
# also gar nicht gelesen. Die Lauschadresse kommt aus 'agentAddress' in
# der snmpd.conf oben, und die gilt unabhaengig davon.

systemctl enable snmpd
systemctl restart snmpd

# Quick-Sanity-Check (lokal).
# Numerische OID statt 'sysDescr.0': die textuellen MIB-Dateien stecken
# in 'snmp-mibs-downloader' (multiverse) und fehlen auf einem Standard-
# Ubuntu. Mit einem symbolischen Namen wuerde der Check deshalb immer
# scheitern und eine Warnung ausgeben, obwohl snmpd laeuft.
# .1.3.6.1.2.1.1.1.0 ist sysDescr.0 in numerischer Form.
sleep 1
if snmpget -v 2c -c "${SNMP_COMMUNITY}" -t 2 -r 1 127.0.0.1 .1.3.6.1.2.1.1.1.0 >/dev/null 2>&1; then
    echo "    snmpd antwortet lokal — OK."
else
    echo "    Warnung: snmpd antwortet (noch) nicht — Status pruefen mit: systemctl status snmpd"
fi

echo "    Part 7 abgeschlossen."

# ================================================================
# Part 8 — Firstboot-Automatik (Zero-Touch Domain Join)
# ================================================================
log "Firstboot-Automatik installieren (vb-firstboot)"

install -m 0755 -o root -g root \
    "${SCRIPT_DIR}/firstboot.sh" /usr/local/sbin/vb-firstboot.sh
echo "    /usr/local/sbin/vb-firstboot.sh installiert."

install -d -m 0700 -o root -g root /etc/vb-template
install -d -m 0755 -o root -g root /var/lib/vb-template

cat > /etc/vb-template/firstboot.conf <<EOF
# ─────────────────────────────────────────────────────────────
#  firstboot.conf — gelesen von /usr/local/sbin/vb-firstboot.sh
#  Generiert von prepare-template.sh. Wird beim Klonen mitkopiert.
# ─────────────────────────────────────────────────────────────

# Active Directory
AD_DOMAIN="${AD_DOMAIN}"
AD_REALM="${AD_REALM}"
AD_ADMIN_GROUP="${AD_ADMIN_GROUP}"

# Service-Account fuer den unbeaufsichtigten Join. Das Passwort steht
# in /etc/vb-template/join.secret und wird nach erfolgreichem Join auf
# dem Klon vernichtet (WIPE_JOIN_SECRET).
JOIN_USER="${JOIN_USER}"

# Distinguished Name der Ziel-OU fuer Computerobjekte.
# Leer = Standard-Container 'CN=Computers'.
COMPUTER_OU="${COMPUTER_OU}"

# Lokaler Break-Glass-User (nur fuer die Abschlussmeldung im Log)
LOCAL_ADMIN_USER="${DEFAULT_USER}"

# Wird von seal-template.sh gesetzt: Hostname zum Zeitpunkt des
# Versiegelns. Stimmt der Hostname beim Boot noch damit ueberein,
# wurde keine Customization Spec angewendet — dann wird NICHT gejoint.
TEMPLATE_HOSTNAME=""

# Automatischer Domain Join beim ersten Boot
ENABLE_JOIN="${ENABLE_JOIN}"

# Join-Secret nach erfolgreichem Join vom Klon loeschen
WIPE_JOIN_SECRET="yes"

# Timeouts in Sekunden
WAIT_TIMEOUT="300"
CLOUDINIT_TIMEOUT="300"
EOF
chmod 600 /etc/vb-template/firstboot.conf
echo "    /etc/vb-template/firstboot.conf geschrieben (chmod 600)."

if [[ -n "${JOIN_PASSWORD}" ]]; then
    # Ohne Newline schreiben — der Wert wird 1:1 an realm/adcli gereicht.
    ( umask 077; printf '%s' "${JOIN_PASSWORD}" > /etc/vb-template/join.secret )
    chmod 600 /etc/vb-template/join.secret
    chown root:root /etc/vb-template/join.secret
    echo "    /etc/vb-template/join.secret geschrieben (chmod 600, nur root)."
else
    rm -f /etc/vb-template/join.secret
    echo "    Kein Join-Secret hinterlegt — Auto-Join ist deaktiviert."
fi
unset JOIN_PASSWORD

install -m 0644 -o root -g root \
    "${SCRIPT_DIR}/vb-firstboot.service" /etc/systemd/system/vb-firstboot.service

systemctl daemon-reload
systemctl enable vb-firstboot.service
# Marker entfernen, damit der Service auf jedem Klon wirklich laeuft.
rm -f /var/lib/vb-template/firstboot.done
echo "    vb-firstboot.service aktiviert."

echo "    Part 8 abgeschlossen."

# ================================================================
# Abschluss
# ================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Template-Vorbereitung abgeschlossen!                   ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Eingerichtet:"
echo "    - cloud-init (VMware Datasource), MOTD, SNMP, Netzwerk-Fallback"
echo "    - SSH Hardening (/etc/ssh/sshd_config.d/99-vita-brevis.conf)"
echo "    - SSSD/Kerberos vorkonfiguriert, Domain-Join noch offen"
if [[ "${ENABLE_JOIN}" == "yes" ]]; then
echo "    - vb-firstboot.service: joint jeden Klon beim ersten Boot"
echo "      automatisch als '${JOIN_USER}' in '${AD_DOMAIN}'"
else
echo "    - vb-firstboot.service: installiert, Auto-Join DEAKTIVIERT"
fi
echo ""
echo "  Naechste Schritte:"
echo "    1. SNMP-Erreichbarkeit vom Monitoring-Host testen:"
echo "         snmpwalk -v 2c -c <community> <host> .1.3.6.1.2.1.1"
echo "    2. Break-Glass-Passwort setzen und versiegeln:"
echo "         sudo ./seal-template.sh"
echo "    3. VM herunterfahren: sudo shutdown -h now"
echo "    4. In vCenter: Convert to Template"
echo ""
echo "  Hinweis: '${DEFAULT_USER}' hat aktuell noch KEIN Passwort."
echo "  Es wird von seal-template.sh vergeben — das ist die einzige"
echo "  Stelle, an der das Break-Glass-Passwort gesetzt wird."
