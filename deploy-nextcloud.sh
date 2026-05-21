#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  deploy-nextcloud.sh
#  Bereitet eine geklonte VM fuer die Rolle "Nextcloud Server" vor.
#  - LVM Disk Setup nach /data (wird uebersprungen wenn /data bereits gemountet)
#  - Nextcloud Installation (Apache, MariaDB, PHP 8.3)
#
#  Verwendung: sudo ./deploy-nextcloud.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

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

# ── Root-Check ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Dieses Script muss als root ausgefuehrt werden."
    echo "Verwendung: sudo $0"
    exit 1
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Deploy: Nextcloud Server                                ║"
echo "║  LVM + Apache + MariaDB + PHP 8.3 + Nextcloud           ║"
echo "╚══════════════════════════════════════════════════════════╝"

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

# MariaDB-Tuning fuer Nextcloud (READ-COMMITTED, binlog ROW, InnoDB)
MARIADB_TUNING="/etc/mysql/mariadb.conf.d/90-nextcloud.cnf"
if [[ -f "${MARIADB_TUNING}" ]]; then
    echo "    MariaDB-Tuning ${MARIADB_TUNING} existiert bereits — uebersprungen."
else
    echo "    Schreibe MariaDB-Tuning nach ${MARIADB_TUNING}..."
    cat > "${MARIADB_TUNING}" <<'EOF'
# Nextcloud MariaDB Tuning
# Siehe: https://docs.nextcloud.com/server/latest/admin_manual/configuration_database/linux_database_configuration.html
[mysqld]
transaction_isolation     = READ-COMMITTED
binlog_format             = ROW
innodb_file_per_table     = 1
innodb_buffer_pool_size   = 512M
innodb_log_file_size      = 64M
innodb_flush_log_at_trx_commit = 2
innodb_flush_method       = O_DIRECT
character-set-server      = utf8mb4
collation-server          = utf8mb4_general_ci
skip-character-set-client-handshake
EOF
    systemctl restart mariadb
    echo "    MariaDB mit neuer Konfiguration neu gestartet."
fi

# Pruefen ob DB bereits existiert
if mysql -u root -e "USE nextcloud" 2>/dev/null; then
    echo "    Datenbank 'nextcloud' existiert bereits."
    echo ""
    echo "  DB-Passwort fuer bestehenden User 'nextcloud' eingeben"
    echo "  (wird gegen die Datenbank verifiziert):"

    # Bis zu 3 Versuche, das Passwort gegen die laufende DB zu verifizieren
    DB_AUTH_OK=false
    for attempt in 1 2 3; do
        NC_DB_PASS=$(prompt_password "DB-Passwort fuer User 'nextcloud'")
        if MYSQL_PWD="${NC_DB_PASS}" mysql -u nextcloud -h localhost \
               -e "SELECT 1 FROM DUAL;" nextcloud &>/dev/null; then
            echo "    Passwort verifiziert."
            DB_AUTH_OK=true
            break
        else
            echo "  Fehler: Passwort fuer 'nextcloud'@'localhost' ist falsch (Versuch ${attempt}/3)."
        fi
    done

    if [[ "${DB_AUTH_OK}" != true ]]; then
        echo ""
        echo "  Passwort konnte nicht verifiziert werden. Abgebrochen."
        echo "  Tipp: Passwort manuell setzen mit:"
        echo "    sudo mysql -e \"ALTER USER 'nextcloud'@'localhost' IDENTIFIED BY '<neues-passwort>';\""
        exit 1
    fi
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
a2enmod rewrite headers env dir mime ssl socache_shmcb

# Selbstsigniertes Zertifikat erzeugen falls noch keines vorhanden
# (Ubuntu liefert ssl-cert mit; das erzeugt /etc/ssl/{certs,private}/ssl-cert-snakeoil.*)
SSL_CERT="/etc/ssl/certs/ssl-cert-snakeoil.pem"
SSL_KEY="/etc/ssl/private/ssl-cert-snakeoil.key"

if [[ ! -f "${SSL_CERT}" || ! -f "${SSL_KEY}" ]]; then
    echo "    Selbstsigniertes Snake-Oil-Zertifikat erzeugen..."
    apt-get install -y ssl-cert
    make-ssl-cert generate-default-snakeoil --force-overwrite
fi

# Nextcloud vhost: Port 80 -> 301 Redirect auf 443
cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    ServerName ${SERVER_NAME:-localhost}

    # Alles auf HTTPS umlenken
    RewriteEngine On
    RewriteRule ^/?(.*)$ https://%{HTTP_HOST}/\$1 [R=301,L]

    ErrorLog \${APACHE_LOG_DIR}/nextcloud-error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud-access.log combined
</VirtualHost>

<VirtualHost *:443>
    DocumentRoot /var/www/nextcloud
    ServerName ${SERVER_NAME:-localhost}

    SSLEngine on
    SSLCertificateFile      ${SSL_CERT}
    SSLCertificateKeyFile   ${SSL_KEY}

    # Moderne TLS-Konfiguration
    SSLProtocol             all -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite          ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    SSLHonorCipherOrder     off
    SSLSessionTickets       off

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud-ssl-error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud-ssl-access.log combined
</VirtualHost>
EOF

echo "    Vhost /etc/apache2/sites-available/nextcloud.conf erstellt (HTTP+HTTPS)."

a2dissite 000-default.conf 2>/dev/null || true
a2dissite default-ssl.conf 2>/dev/null || true
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

cd /var/www/nextcloud

NC_CONFIG="/var/www/nextcloud/config/config.php"

if [[ -f "${NC_CONFIG}" ]] && sudo -u www-data php occ status 2>/dev/null | grep -q "installed: true"; then
    echo "    Nextcloud ist bereits installiert (config.php vorhanden, occ status: installed)."
    echo "    maintenance:install wird uebersprungen."
    NC_ADMIN_USER=$(sudo -u www-data php occ user:list --output=json 2>/dev/null \
        | grep -oE '"[^"]+"' | head -1 | tr -d '"' || echo "admin")
else
    if [[ -f "${NC_CONFIG}" ]]; then
        echo "  WARNUNG: ${NC_CONFIG} existiert, aber 'occ status' meldet die Instanz"
        echo "  nicht als installiert. Vermutlich abgebrochene Installation."
        read -rp "  config.php verschieben (.bak) und neu installieren? (ja/nein): " RESET_NC
        if [[ "${RESET_NC,,}" == "ja" ]]; then
            mv "${NC_CONFIG}" "${NC_CONFIG}.bak.$(date +%s)"
            echo "    Alte config.php weggesichert."
        else
            echo "  Abgebrochen. config.php manuell bereinigen und Script erneut starten."
            exit 1
        fi
    fi

    echo ""
    echo "  Nextcloud Admin-Konto festlegen:"
    echo ""
    NC_ADMIN_USER=$(prompt_input "Admin-Benutzername" "admin")
    NC_ADMIN_PASS=$(prompt_password "Admin-Passwort")

    echo ""
    echo "    Nextcloud Installation starten..."

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
fi

# Trusted Domains: localhost + Server-IP
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "    Trusted Domains konfigurieren..."
sudo -u www-data php occ config:system:set trusted_domains 0 --value="localhost"
sudo -u www-data php occ config:system:set trusted_domains 1 --value="${SERVER_IP}"

# APCu Memory Cache
sudo -u www-data php occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu"

# Default-Telefon-Region
sudo -u www-data php occ config:system:set default_phone_region --value="CH"

echo "    Nextcloud konfiguriert."

# ================================================================
# Abschluss
# ================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Nextcloud Deployment abgeschlossen!                     ║"
echo "╠══════════════════════════════════════════════════════════╣"
printf "║  %-18s %-39s║\n" "URL:" "https://${SERVER_IP}"
printf "║  %-18s %-39s║\n" "Admin-User:" "${NC_ADMIN_USER}"
printf "║  %-18s %-39s║\n" "Datenverzeichnis:" "${NC_DATA}"
printf "║  %-18s %-39s║\n" "Datenbank:" "nextcloud@localhost (MariaDB)"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Naechste Schritte:                                      ║"
echo "║  - Snake-Oil-Zertifikat durch Let's Encrypt ersetzen    ║"
echo "║    (certbot --apache) oder eigene CA einbinden          ║"
echo "║  - Trusted Domains anpassen falls noetig                ║"
echo "║  - Backup-Strategie einrichten                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
