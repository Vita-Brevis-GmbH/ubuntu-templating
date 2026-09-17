#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  deploy-nextcloud.sh
#  Bereitet eine geklonte VM fuer die Rolle "Nextcloud Server" vor.
#  - LVM Disk Setup nach /data (wird uebersprungen wenn /data bereits gemountet)
#  - Nextcloud Installation (Apache, MariaDB, PHP 8.3)
#  - Optional: Self-signed SSL (-ssl)
#
#  Verwendung: sudo ./deploy-nextcloud.sh [-ssl]
#    -ssl    Nextcloud mit self-signed SSL-Zertifikat einrichten.
#            - Frische VM: nach der Installation wird zusaetzlich SSL aktiviert.
#            - Bestehende HTTP-Installation: nur SSL-Migration
#              (Cert erzeugen, Apache umbauen, overwriteprotocol=https).
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Argumente parsen ───────────────────────────────────────────
ENABLE_SSL=false
for arg in "$@"; do
    case "$arg" in
        -ssl|--ssl)
            ENABLE_SSL=true
            ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unbekanntes Argument: $arg"
            echo "Verwendung: sudo $0 [-ssl]"
            exit 1
            ;;
    esac
done

# ── Hilfsfunktionen ────────────────────────────────────────────
STEP=0

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

prompt_password() {
    local prompt="$1"
    local pass1 pass2
    read -rsp "  ${prompt}: " pass1
    echo ""
    read -rsp "  ${prompt} (bestaetigen): " pass2
    echo ""
    if [[ "${pass1}" != "${pass2}" ]]; then
        echo "  Fehler: Passwoerter stimmen nicht ueberein!"
        exit 1
    fi
    if [[ -z "${pass1}" ]]; then
        echo "  Fehler: Passwort darf nicht leer sein!"
        exit 1
    fi
    echo "${pass1}"
}

# ── SSL Setup (idempotent) ─────────────────────────────────────
#  Erzeugt self-signed Cert (falls fehlend), schreibt Apache-Vhosts
#  fuer :80 (Redirect) und :443 (SSL), setzt occ overwriteprotocol=https.
setup_ssl() {
    local ssl_dir="/etc/ssl/nextcloud"
    local ssl_key="${ssl_dir}/nextcloud.key"
    local ssl_crt="${ssl_dir}/nextcloud.crt"
    local nc_root="/var/www/nextcloud"
    local hostname_short hostname_fqdn ip_addr san

    hostname_short=$(hostname)
    hostname_fqdn=$(hostname -f 2>/dev/null || echo "$hostname_short")
    ip_addr=$(hostname -I | awk '{print $1}')

    if ! command -v openssl &>/dev/null; then
        echo "    openssl fehlt — nachinstallieren..."
        apt-get install -y openssl
    fi

    echo "    Self-signed Zertifikat vorbereiten (${ssl_dir})..."
    install -d -m 750 "${ssl_dir}"

    if [[ -f "${ssl_key}" && -f "${ssl_crt}" ]]; then
        echo "    Zertifikat existiert bereits — Wiederverwendung."
    else
        san="DNS:${hostname_fqdn},DNS:${hostname_short},DNS:localhost,IP:${ip_addr},IP:127.0.0.1"
        openssl req -x509 -nodes -newkey rsa:4096 \
            -keyout "${ssl_key}" \
            -out "${ssl_crt}" \
            -days 3650 \
            -subj "/CN=${hostname_fqdn}" \
            -addext "subjectAltName=${san}" >/dev/null 2>&1
        chmod 600 "${ssl_key}"
        chmod 644 "${ssl_crt}"
        echo "    Zertifikat erstellt (10 Jahre, SAN=${san})."
    fi

    echo "    Apache-Module ssl/headers/rewrite aktivieren..."
    a2enmod ssl headers rewrite >/dev/null

    echo "    Vhost /etc/apache2/sites-available/nextcloud-ssl.conf schreiben (Port 443)..."
    cat > /etc/apache2/sites-available/nextcloud-ssl.conf <<EOF
<VirtualHost *:443>
    DocumentRoot ${nc_root}
    ServerName ${hostname_fqdn}

    SSLEngine on
    SSLCertificateFile      ${ssl_crt}
    SSLCertificateKeyFile   ${ssl_key}

    <Directory ${nc_root}/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
    </IfModule>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud-ssl-access.log combined
</VirtualHost>
EOF

    echo "    Vhost /etc/apache2/sites-available/nextcloud.conf auf Redirect umbauen (Port 80)..."
    cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    ServerName ${hostname_fqdn}
    RewriteEngine On
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [L,R=301]

    ErrorLog \${APACHE_LOG_DIR}/nextcloud-error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud-access.log combined
</VirtualHost>
EOF

    a2ensite nextcloud.conf nextcloud-ssl.conf >/dev/null
    a2dissite 000-default.conf 2>/dev/null || true
    a2dissite default-ssl.conf 2>/dev/null || true

    if [[ -f "${nc_root}/config/config.php" ]]; then
        echo "    Nextcloud occ config anpassen (overwriteprotocol, trusted_domains)..."
        sudo -u www-data php "${nc_root}/occ" config:system:set overwriteprotocol --value=https >/dev/null
        sudo -u www-data php "${nc_root}/occ" config:system:set overwrite.cli.url --value="https://${hostname_fqdn}" >/dev/null
        sudo -u www-data php "${nc_root}/occ" config:system:set trusted_domains 0 --value="localhost" >/dev/null
        sudo -u www-data php "${nc_root}/occ" config:system:set trusted_domains 1 --value="${ip_addr}" >/dev/null
        sudo -u www-data php "${nc_root}/occ" config:system:set trusted_domains 2 --value="${hostname_fqdn}" >/dev/null
    fi

    echo "    Apache Config testen..."
    if apache2ctl configtest >/dev/null 2>&1; then
        systemctl reload apache2 || systemctl restart apache2
        echo "    Apache reloaded — SSL aktiv."
    else
        echo "    FEHLER: Apache configtest fehlgeschlagen. Pruefen mit: apache2ctl configtest"
        apache2ctl configtest || true
        return 1
    fi
}

# ── Root-Check ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Dieses Script muss als root ausgefuehrt werden."
    echo "Verwendung: sudo $0"
    exit 1
fi

# ── Release-Check ───────────────────────────────────────────────
# Dieses Script installiert PHP 8.3 und ist damit an Ubuntu 24.04
# gebunden. Ab 26.04 gibt es keine php8.3-Pakete mehr — dort gehoert
# deploy-nextcloud-26.04.sh hin. Frueh abbrechen ist besser, als auf
# halber Strecke an fehlenden Paketen zu scheitern.
_RELEASE="$( [[ -r /etc/os-release ]] && . /etc/os-release && echo "${VERSION_ID:-unbekannt}" )"
if [[ "${_RELEASE}" != "24.04" ]]; then
    echo "Fehler: Dieses Script ist fuer Ubuntu 24.04 LTS (PHP 8.3)."
    echo "        Gefunden: Ubuntu ${_RELEASE}"
    if [[ "${_RELEASE}" == "26.04" ]]; then
        echo "        Fuer 26.04 stattdessen './deploy-nextcloud-26.04.sh' verwenden."
    fi
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Deploy: Nextcloud Server                                ║"
echo "║  LVM + Apache + MariaDB + PHP 8.3 + Nextcloud           ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ── Frueher Ausstieg: bestehende Installation + -ssl → nur Migration ──
if [[ "${ENABLE_SSL}" == true && -f /var/www/nextcloud/config/config.php ]]; then
    echo ""
    echo "  Bestehende Nextcloud-Installation erkannt (${NC_DEST:-/var/www/nextcloud}/config/config.php)."
    echo "  Modus: SSL-Migration (self-signed) — keine Neu-Installation."
    echo ""
    read -rp "  Fortfahren? [J/n]: " CONFIRM
    if [[ "${CONFIRM,,}" == "n" ]]; then
        echo "  Abgebrochen."
        exit 0
    fi

    echo ""
    echo "========================================================"
    echo "==> SSL-Migration"
    echo "========================================================"
    setup_ssl

    IP_ADDR=$(hostname -I | awk '{print $1}')
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  SSL-Migration abgeschlossen!                            ║"
    printf "║  %-56s║\n" "URL: https://${IP_ADDR}"
    echo "║  Hinweis: self-signed Cert — Browser-Warnung erwartet.   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    exit 0
fi

# ── Pruefen ob /data bereits gemountet ist ─────────────────────
SKIP_LVM=false
MOUNT_POINT="/data"

if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    echo ""
    echo "  ${MOUNT_POINT} ist bereits gemountet — LVM-Setup wird uebersprungen."
    df -h "${MOUNT_POINT}"
    SKIP_LVM=true
    TOTAL=6
else
    TOTAL=10
fi

# SSL zaehlt als zusaetzlicher Step am Ende.
if [[ "${ENABLE_SSL}" == true ]]; then
    TOTAL=$((TOTAL + 1))
fi

# ================================================================
#  LVM DISK SETUP (wird uebersprungen wenn /data bereits gemountet)
# ================================================================
if [[ "${SKIP_LVM}" == false ]]; then

# ── Unformatierte Disks erkennen ───────────────────────────────
echo ""
echo "  Suche unformatierte Disks..."
echo ""

# Boot-Disk ermitteln (die Disk, auf der / liegt)
BOOT_DISK=$(lsblk -npdo PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1)

# Alle Disks ohne Filesystem/Partitionen finden, Boot-Disk ausschliessen
declare -a AVAIL_DISKS=()
declare -a AVAIL_SIZES=()

while IFS= read -r line; do
    disk_name=$(echo "$line" | awk '{print $1}')
    disk_size=$(echo "$line" | awk '{print $2}')
    disk_fstype=$(echo "$line" | awk '{print $4}')

    # Boot-Disk ueberspringen
    [[ "$disk_name" == "$BOOT_DISK" ]] && continue

    # Nur Disks ohne Filesystem
    [[ -n "$disk_fstype" ]] && continue

    # Pruefen ob die Disk Partitionen hat
    part_count=$(lsblk -nplo NAME "$disk_name" 2>/dev/null | wc -l)
    if [[ "$part_count" -le 1 ]]; then
        AVAIL_DISKS+=("$disk_name")
        AVAIL_SIZES+=("$disk_size")
    fi
done < <(lsblk -dpno NAME,SIZE,TYPE,FSTYPE | grep "disk")

if [[ ${#AVAIL_DISKS[@]} -eq 0 ]]; then
    echo "  Keine unformatierten Disks gefunden!"
    echo "  Alle angeschlossenen Disks:"
    lsblk -dpo NAME,SIZE,TYPE,FSTYPE
    echo ""
    echo "  Bitte eine unformatierte Disk in vCenter hinzufuegen und erneut starten."
    exit 1
fi

# Disks zur Auswahl anzeigen
echo "  Verfuegbare unformatierte Disks:"
echo "  ┌──────┬──────────────────┬──────────┐"
printf "  │ %-4s │ %-16s │ %-8s │\n" "Nr." "Device" "Groesse"
echo "  ├──────┼──────────────────┼──────────┤"
for i in "${!AVAIL_DISKS[@]}"; do
    printf "  │ %-4s │ %-16s │ %-8s │\n" "$((i + 1))" "${AVAIL_DISKS[$i]}" "${AVAIL_SIZES[$i]}"
done
echo "  └──────┴──────────────────┴──────────┘"
echo ""

# Auswahl
if [[ ${#AVAIL_DISKS[@]} -eq 1 ]]; then
    DISK_CHOICE=1
    echo "  Nur eine Disk verfuegbar — automatisch ausgewaehlt."
else
    read -rp "  Disk auswaehlen [1-${#AVAIL_DISKS[@]}]: " DISK_CHOICE
    if [[ ! "$DISK_CHOICE" =~ ^[0-9]+$ ]] || [[ "$DISK_CHOICE" -lt 1 ]] || [[ "$DISK_CHOICE" -gt ${#AVAIL_DISKS[@]} ]]; then
        echo "  Ungueltige Auswahl. Abgebrochen."
        exit 1
    fi
fi

SELECTED_DISK="${AVAIL_DISKS[$((DISK_CHOICE - 1))]}"
SELECTED_SIZE="${AVAIL_SIZES[$((DISK_CHOICE - 1))]}"

VG_NAME=$(prompt_input "Volume Group Name" "vg_data")
LV_NAME=$(prompt_input "Logical Volume Name" "lv_data")

# Zusammenfassung + Warnung
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  LVM Konfiguration:                                 │"
printf "  │  %-18s %-35s│\n" "Device:" "${SELECTED_DISK} (${SELECTED_SIZE})"
printf "  │  %-18s %-35s│\n" "Volume Group:" "${VG_NAME}"
printf "  │  %-18s %-35s│\n" "Logical Volume:" "${LV_NAME}"
printf "  │  %-18s %-35s│\n" "Filesystem:" "ext4"
printf "  │  %-18s %-35s│\n" "Mount-Punkt:" "${MOUNT_POINT}"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
echo "  ⚠  WARNUNG: ${SELECTED_DISK} wird unwiderruflich formatiert!"
echo "     Alle vorhandenen Daten gehen verloren."
echo ""
read -rp "  Fortfahren? (ja/nein): " CONFIRM
if [[ "${CONFIRM,,}" != "ja" ]]; then
    echo "  Abgebrochen."
    exit 0
fi

# ================================================================
# Schritt 1 — lvm2 sicherstellen
# ================================================================
log "lvm2 Paket sicherstellen"

if dpkg -s lvm2 &>/dev/null; then
    echo "    lvm2 ist bereits installiert."
else
    apt-get update
    apt-get install -y lvm2
    echo "    lvm2 installiert."
fi

# ================================================================
# Schritt 2 — LVM erstellen
# ================================================================
log "LVM auf ${SELECTED_DISK} erstellen"

echo "    Physical Volume erstellen..."
pvcreate -f "${SELECTED_DISK}"

echo "    Volume Group '${VG_NAME}' erstellen..."
vgcreate "${VG_NAME}" "${SELECTED_DISK}"

echo "    Logical Volume '${LV_NAME}' erstellen (100% der Disk)..."
lvcreate -l 100%FREE -n "${LV_NAME}" "${VG_NAME}"

echo "    LVM erfolgreich erstellt."

# ================================================================
# Schritt 3 — Filesystem erstellen & mounten
# ================================================================
log "ext4 Filesystem erstellen & nach ${MOUNT_POINT} mounten"

LV_PATH="/dev/${VG_NAME}/${LV_NAME}"

echo "    Formatiere ${LV_PATH} mit ext4..."
mkfs.ext4 -q "${LV_PATH}"

echo "    Mount-Punkt ${MOUNT_POINT} erstellen..."
mkdir -p "${MOUNT_POINT}"

# fstab Eintrag (nur hinzufuegen wenn nicht bereits vorhanden)
FSTAB_LINE="${LV_PATH}  ${MOUNT_POINT}  ext4  defaults  0  2"
if grep -qF "${LV_PATH}" /etc/fstab; then
    echo "    fstab-Eintrag existiert bereits — uebersprungen."
else
    echo "${FSTAB_LINE}" >> /etc/fstab
    echo "    fstab-Eintrag hinzugefuegt."
fi

echo "    Mounte alle Eintraege..."
mount -a

echo "    Filesystem gemountet."

# ================================================================
# Schritt 4 — LVM Verifikation
# ================================================================
log "LVM Verifikation"

echo ""
echo "  LVM Uebersicht:"
echo "  ────────────────"
pvs
echo ""
vgs
echo ""
lvs
echo ""
echo "  Disk-Uebersicht:"
echo "  ────────────────"
lsblk "${SELECTED_DISK}"
echo ""
echo "  Mount-Status:"
echo "  ────────────────"
df -h "${MOUNT_POINT}"

# Ende LVM-Block
fi

# ================================================================
#  NEXTCLOUD INSTALLATION
# ================================================================

# ================================================================
# Schritt 5 — Pakete installieren
# ================================================================
log "Pakete installieren (Apache, MariaDB, PHP 8.3)"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    apache2 \
    mariadb-server \
    libapache2-mod-php \
    php8.3 \
    php8.3-gd \
    php8.3-mysql \
    php8.3-curl \
    php8.3-mbstring \
    php8.3-intl \
    php8.3-gmp \
    php8.3-bcmath \
    php8.3-xml \
    php8.3-zip \
    php8.3-bz2 \
    php8.3-imagick \
    php8.3-opcache \
    php8.3-apcu \
    php8.3-redis \
    php8.3-ldap \
    bzip2 \
    unzip \
    wget

echo "    Alle Pakete installiert."

# ================================================================
# Schritt 6 — MariaDB konfigurieren
# ================================================================
log "MariaDB konfigurieren"

# Sicherstellen dass MariaDB laeuft
systemctl is-active --quiet mariadb || systemctl start mariadb

# Pruefen ob DB bereits existiert
if mysql -u root -e "USE nextcloud" 2>/dev/null; then
    echo "    Datenbank 'nextcloud' existiert bereits — uebersprungen."
    echo ""
    echo "  DB-Passwort fuer bestehende Datenbank eingeben:"
    NC_DB_PASS=$(prompt_password "DB-Passwort fuer User 'nextcloud'")
else
    echo ""
    echo "  Nextcloud Datenbank-Passwort festlegen:"
    NC_DB_PASS=$(prompt_password "DB-Passwort fuer User 'nextcloud'")

    # Passwort sicher escapen fuer SQL (einfache Anfuehrungszeichen verdoppeln)
    NC_DB_PASS_SQL=$(printf '%s' "${NC_DB_PASS}" | sed "s/'/''/g")

    mysql -u root -e "CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -u root -e "CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '${NC_DB_PASS_SQL}';"
    mysql -u root -e "GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost'; FLUSH PRIVILEGES;"

    echo "    Datenbank 'nextcloud' und User erstellt."
fi

# ================================================================
# Schritt 7 — Nextcloud herunterladen & entpacken
# ================================================================
log "Nextcloud herunterladen & entpacken"

NC_URL="https://download.nextcloud.com/server/releases/latest.tar.bz2"
NC_DEST="/var/www/nextcloud"
NC_DATA="/data/nextcloud-data"

if [[ -d "${NC_DEST}" ]]; then
    echo "    ${NC_DEST} existiert bereits — uebersprungen."
else
    echo "    Nextcloud herunterladen (latest stable)..."
    wget -q --show-progress "${NC_URL}" -O /tmp/nextcloud.tar.bz2

    echo "    Entpacken nach /var/www/..."
    tar -xjf /tmp/nextcloud.tar.bz2 -C /var/www/
    rm -f /tmp/nextcloud.tar.bz2

    echo "    Nextcloud entpackt."
fi

echo "    Berechtigungen setzen..."
chown -R www-data:www-data "${NC_DEST}"

echo "    Datenverzeichnis ${NC_DATA} erstellen..."
mkdir -p "${NC_DATA}"
chown www-data:www-data "${NC_DATA}"

echo "    Schritt 7 abgeschlossen."

# ================================================================
# Schritt 8 — Apache konfigurieren
# ================================================================
log "Apache konfigurieren"

echo "    Apache-Module aktivieren..."
a2enmod rewrite headers env dir mime ssl

# Nextcloud vhost
cat > /etc/apache2/sites-available/nextcloud.conf <<'EOF'
<VirtualHost *:80>
    DocumentRoot /var/www/nextcloud
    ServerName localhost

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog ${APACHE_LOG_DIR}/nextcloud-error.log
    CustomLog ${APACHE_LOG_DIR}/nextcloud-access.log combined
</VirtualHost>
EOF

echo "    Vhost /etc/apache2/sites-available/nextcloud.conf erstellt."

a2dissite 000-default.conf 2>/dev/null || true
a2ensite nextcloud.conf

systemctl restart apache2
echo "    Apache konfiguriert und neu gestartet."

# ================================================================
# Schritt 9 — PHP Tuning
# ================================================================
log "PHP Tuning"

PHP_INI_DIR="/etc/php/8.3/apache2/conf.d"

cat > "${PHP_INI_DIR}/99-nextcloud.ini" <<'EOF'
; Nextcloud PHP Tuning
memory_limit = 512M
upload_max_filesize = 16G
post_max_size = 16G
max_execution_time = 3600
max_input_time = 3600

; OPcache
opcache.enable = 1
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 1
EOF

echo "    ${PHP_INI_DIR}/99-nextcloud.ini geschrieben."

systemctl restart apache2
echo "    Apache mit neuer PHP-Konfiguration neu gestartet."

# ================================================================
# Schritt 10 — Nextcloud Einrichtung (occ)
# ================================================================
log "Nextcloud Einrichtung via occ"

echo ""
echo "  Nextcloud Admin-Konto festlegen:"
echo ""
NC_ADMIN_USER=$(prompt_input "Admin-Benutzername" "admin")
NC_ADMIN_PASS=$(prompt_password "Admin-Passwort")

echo ""
echo "    Nextcloud Installation starten..."
cd /var/www/nextcloud

# Passwoerter in temporaere Dateien schreiben (umgeht Shell-Sonderzeichen-Probleme)
TMPDIR_PW=$(mktemp -d)
printf '%s' "${NC_DB_PASS}" > "${TMPDIR_PW}/dbpass"
printf '%s' "${NC_ADMIN_PASS}" > "${TMPDIR_PW}/adminpass"
chmod 600 "${TMPDIR_PW}/dbpass" "${TMPDIR_PW}/adminpass"

sudo -u www-data php occ maintenance:install \
    --database      "mysql" \
    --database-name  "nextcloud" \
    --database-user  "nextcloud" \
    --database-pass  "$(cat "${TMPDIR_PW}/dbpass")" \
    --admin-user     "${NC_ADMIN_USER}" \
    --admin-pass     "$(cat "${TMPDIR_PW}/adminpass")" \
    --data-dir       "${NC_DATA}"

rm -rf "${TMPDIR_PW}"

echo "    Nextcloud Basisinstallation abgeschlossen."

# Trusted Domains: localhost + Server-IP
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "    Trusted Domains konfigurieren..."
sudo -u www-data php occ config:system:set trusted_domains 0 --value="localhost"
sudo -u www-data php occ config:system:set trusted_domains 1 --value="${SERVER_IP}"

# APCu Memory Cache
sudo -u www-data php occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu"

# Default-Telefon-Region
sudo -u www-data php occ config:system:set default_phone_region --value="CH"

# Skeleton-Verzeichnis leeren: neue Nutzer erhalten keine Beispieldateien
sudo -u www-data php occ config:system:set skeletondirectory --value=""

echo "    Nextcloud konfiguriert."

# ================================================================
# Schritt 11 — SSL (self-signed) — nur wenn -ssl gesetzt
# ================================================================
if [[ "${ENABLE_SSL}" == true ]]; then
    log "SSL einrichten (self-signed)"
    setup_ssl
fi

# ================================================================
# Abschluss
# ================================================================
if [[ "${ENABLE_SSL}" == true ]]; then
    NC_URL="https://${SERVER_IP}"
    NC_SSL_NOTE="- self-signed Cert (10 J.) — Browser-Warnung erwartet"
else
    NC_URL="http://${SERVER_IP}"
    NC_SSL_NOTE="- HTTPS/SSL einrichten (mit -ssl oder Reverse Proxy)"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Nextcloud Deployment abgeschlossen!                     ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  %-18s %-39s║\n" "URL:" "${NC_URL}"
printf "║  %-18s %-39s║\n" "Admin-User:" "${NC_ADMIN_USER}"
printf "║  %-18s %-39s║\n" "Datenverzeichnis:" "${NC_DATA}"
printf "║  %-18s %-39s║\n" "Datenbank:" "nextcloud@localhost (MariaDB)"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Naechste Schritte:                                      ║"
printf "║  %-56s║\n" "${NC_SSL_NOTE}"
echo "║  - Trusted Domains anpassen falls noetig                ║"
echo "║  - Backup-Strategie einrichten                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
