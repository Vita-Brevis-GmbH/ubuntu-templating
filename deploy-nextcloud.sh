#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  deploy-nextcloud.sh
#  Bereitet eine geklonte VM fuer die Rolle "Nextcloud Server" vor.
#  - LVM Disk Setup nach /data (wird uebersprungen wenn /data bereits gemountet)
#  - Nextcloud Installation (Apache + PHP-FPM, MariaDB, Redis, PHP 8.5)
#
#  Tuning-Werte gemaess Aenderungsdokumentation M. Hadorn (01.09.2026),
#  Referenzinstallation fil01-nsh-sef (8 GB RAM). Bei abweichender
#  RAM-Ausstattung die Werte im Konfigurationsblock unten anpassen.
#
#  Verwendung: sudo ./deploy-nextcloud.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Konfiguration ──────────────────────────────────────────────
# PHP 8.5 ist in Ubuntu 24.04 nicht enthalten und kommt aus ppa:ondrej/php
PHP_VER="8.5"

# Tuning-Werte der Referenzinstallation (8 GB RAM)
INNODB_BUFFER_POOL="2G"          # ~25% RAM
REDIS_MAXMEMORY="512mb"
FPM_MAX_CHILDREN="14"            # bei RAM-Reserve auf 20 erhoehen
NC_TMPDIR="/var/nc-tmp"

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
printf "║  LVM + Apache/FPM + MariaDB + Redis + PHP %-4s           ║\n" "${PHP_VER}"
echo "╚══════════════════════════════════════════════════════════╝"

# ── Pruefen ob /data bereits gemountet ist ─────────────────────
SKIP_LVM=false
MOUNT_POINT="/data"

if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
    echo ""
    echo "  ${MOUNT_POINT} ist bereits gemountet — LVM-Setup wird uebersprungen."
    df -h "${MOUNT_POINT}"
    SKIP_LVM=true
    TOTAL=7
else
    TOTAL=11
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
log "Pakete installieren (Apache, MariaDB, Redis, PHP ${PHP_VER})"

export DEBIAN_FRONTEND=noninteractive

apt-get update

# PHP 8.5 ist nicht in Ubuntu 24.04 enthalten — ondrej/php PPA einbinden
if ! apt-cache show "php${PHP_VER}-fpm" &>/dev/null; then
    echo "    PHP ${PHP_VER} nicht in den Ubuntu-Quellen — ppa:ondrej/php einbinden..."
    apt-get install -y software-properties-common
    add-apt-repository -y ppa:ondrej/php
    apt-get update
    echo "    PPA eingebunden."
fi
apt-get install -y \
    apache2 \
    mariadb-server \
    redis-server \
    "php${PHP_VER}-fpm" \
    "php${PHP_VER}-cli" \
    "php${PHP_VER}-gd" \
    "php${PHP_VER}-mysql" \
    "php${PHP_VER}-curl" \
    "php${PHP_VER}-mbstring" \
    "php${PHP_VER}-intl" \
    "php${PHP_VER}-gmp" \
    "php${PHP_VER}-bcmath" \
    "php${PHP_VER}-xml" \
    "php${PHP_VER}-zip" \
    "php${PHP_VER}-bz2" \
    "php${PHP_VER}-imagick" \
    "php${PHP_VER}-opcache" \
    "php${PHP_VER}-apcu" \
    "php${PHP_VER}-redis" \
    "php${PHP_VER}-ldap" \
    ffmpeg \
    librsvg2-common \
    bzip2 \
    unzip \
    wget \
    curl \
    cron

# Imagick-Delegates fuer SVG/HEIC — Paketname variiert je nach ImageMagick-Version
IMAGICK_EXTRA_OK=false
for pkg in libmagickcore-7.q16-10-extra libmagickcore-6.q16-6-extra; do
    if apt-cache show "$pkg" &>/dev/null && apt-get install -y "$pkg"; then
        IMAGICK_EXTRA_OK=true
        break
    fi
done
if [[ "${IMAGICK_EXTRA_OK}" != true ]]; then
    echo "    HINWEIS: Kein passendes libmagickcore-*-extra Paket gefunden."
    echo "    SVG-Vorschauen bleiben deaktiviert. Passendes Delegate-Paket"
    echo "    ermitteln mit: ldd /usr/lib/php/*/imagick.so | grep -i magick"
fi

echo "    Alle Pakete installiert."

# Mit dem PPA koennen mehrere PHP-Versionen parallel liegen — sicherstellen,
# dass 'php' (und damit jeder occ-Aufruf) auf die gewuenschte Version zeigt.
if [[ -x "/usr/bin/php${PHP_VER}" ]]; then
    update-alternatives --set php "/usr/bin/php${PHP_VER}" &>/dev/null || true
fi

ACTIVE_PHP=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "?")
if [[ "${ACTIVE_PHP}" != "${PHP_VER}" ]]; then
    echo "  Fehler: 'php' zeigt auf Version ${ACTIVE_PHP}, erwartet ${PHP_VER}."
    echo "  Korrigieren mit: update-alternatives --config php"
    exit 1
fi
echo "    Aktive PHP-CLI-Version: ${ACTIVE_PHP}"

# ================================================================
# Schritt 6 — MariaDB konfigurieren
# ================================================================
log "MariaDB konfigurieren"

# Sicherstellen dass MariaDB laeuft
systemctl is-active --quiet mariadb || systemctl start mariadb

# MariaDB-Tuning fuer Nextcloud (READ-COMMITTED, binlog ROW, InnoDB)
MARIADB_TUNING="/etc/mysql/mariadb.conf.d/60-nextcloud.cnf"
if [[ -f "${MARIADB_TUNING}" ]]; then
    echo "    MariaDB-Tuning ${MARIADB_TUNING} existiert bereits — uebersprungen."
else
    echo "    Schreibe MariaDB-Tuning nach ${MARIADB_TUNING}..."
    cat > "${MARIADB_TUNING}" <<EOF
# Nextcloud MariaDB Tuning
# Siehe: https://docs.nextcloud.com/server/latest/admin_manual/configuration_database/linux_database_configuration.html
[mysqld]
innodb_buffer_pool_size   = ${INNODB_BUFFER_POOL}
innodb_flush_log_at_trx_commit = 2
innodb_file_per_table     = 1
transaction_isolation     = READ-COMMITTED
binlog_format             = ROW
tmp_table_size            = 64M
max_heap_table_size       = 64M
read_rnd_buffer_size      = 4M
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
# Schritt 7 — Redis konfigurieren (Locking + verteilter Cache)
# ================================================================
log "Redis konfigurieren (Unix-Socket, Locking-Cache)"

# Redis auf Unix-Socket umstellen — kein TCP-Overhead
REDIS_SOCKET="/run/redis/redis-server.sock"

if grep -q "^unixsocket ${REDIS_SOCKET}" /etc/redis/redis.conf 2>/dev/null; then
    echo "    Redis ist bereits auf Unix-Socket konfiguriert — uebersprungen."
else
    echo "    Redis-Konfiguration anpassen..."
    cp -n /etc/redis/redis.conf /etc/redis/redis.conf.orig 2>/dev/null || true

    # Vorhandene Direktiven entfernen, dann sauber neu setzen
    sed -i -E '/^[[:space:]]*#?[[:space:]]*(unixsocket|unixsocketperm|maxmemory|maxmemory-policy)[[:space:]]/d' \
        /etc/redis/redis.conf

    cat >> /etc/redis/redis.conf <<EOF

# ── Nextcloud Tuning ────────────────────────────────────────────
unixsocket ${REDIS_SOCKET}
unixsocketperm 770
maxmemory ${REDIS_MAXMEMORY}
maxmemory-policy volatile-lru
EOF
    echo "    Redis-Konfiguration geschrieben (Socket, ${REDIS_MAXMEMORY}, volatile-lru)."
fi

# www-data braucht Gruppenmitgliedschaft fuer den Socket (unixsocketperm 770)
if id -nG www-data | tr ' ' '\n' | grep -qx redis; then
    echo "    www-data ist bereits in der Gruppe 'redis'."
else
    usermod -aG redis www-data
    echo "    www-data zur Gruppe 'redis' hinzugefuegt."
fi

systemctl enable --now redis-server
systemctl restart redis-server

# Socket-Verfuegbarkeit pruefen (systemd braucht einen Moment)
for _ in {1..10}; do
    [[ -S "${REDIS_SOCKET}" ]] && break
    sleep 1
done

if [[ -S "${REDIS_SOCKET}" ]]; then
    echo "    Redis laeuft, Socket ${REDIS_SOCKET} verfuegbar."
else
    echo "    WARNUNG: Redis-Socket ${REDIS_SOCKET} nicht gefunden!"
    echo "    Pruefen mit: systemctl status redis-server"
    exit 1
fi

# ================================================================
# Schritt 8 — Nextcloud herunterladen & entpacken
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

# Eigenes Temp-Verzeichnis: /tmp ist auf der Root-Disk zu klein fuer grosse
# Uploads — abgebrochene Uploads waren Mitursache haengender Sperren.
echo "    Temp-Verzeichnis ${NC_TMPDIR} erstellen..."
mkdir -p "${NC_TMPDIR}"
chown www-data:www-data "${NC_TMPDIR}"
chmod 750 "${NC_TMPDIR}"

echo "    Schritt abgeschlossen."

# ================================================================
# Schritt 9 — Apache + PHP-FPM konfigurieren
# ================================================================
log "Apache + PHP-FPM konfigurieren (mpm_event statt mod_php)"

# mod_php/prefork abloesen — FPM mit mpm_event ist der groesste Einzelgewinn
echo "    mod_php und mpm_prefork deaktivieren..."
a2dismod "php${PHP_VER}" 2>/dev/null || true
a2dismod mpm_prefork 2>/dev/null || true

echo "    Apache-Module aktivieren..."
a2enmod mpm_event proxy_fcgi setenvif http2
a2enconf "php${PHP_VER}-fpm"
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

# Globalen ServerName setzen — beseitigt die AH00558-Warnung beim Start
if [[ ! -f /etc/apache2/conf-available/servername.conf ]]; then
    echo "ServerName $(hostname -f 2>/dev/null || hostname)" \
        > /etc/apache2/conf-available/servername.conf
    a2enconf servername
    echo "    Globaler ServerName gesetzt."
fi

a2dissite 000-default.conf 2>/dev/null || true
a2dissite default-ssl.conf 2>/dev/null || true
a2ensite nextcloud.conf

# ── PHP-FPM Pool ───────────────────────────────────────────────
FPM_POOL="/etc/php/${PHP_VER}/fpm/pool.d/www.conf"

echo "    PHP-FPM Pool konfigurieren (max_children=${FPM_MAX_CHILDREN})..."
for setting in \
    "pm = dynamic" \
    "pm.max_children = ${FPM_MAX_CHILDREN}" \
    "pm.start_servers = 6" \
    "pm.min_spare_servers = 4" \
    "pm.max_spare_servers = 12" \
    "pm.max_requests = 500"
do
    key="${setting%% =*}"
    # Vorhandene (auch auskommentierte) Direktive ersetzen, sonst anhaengen
    if grep -qE "^[;[:space:]]*${key//./\\.}[[:space:]]*=" "${FPM_POOL}"; then
        sed -i -E "s|^[;[:space:]]*${key//./\\.}[[:space:]]*=.*|${setting}|" "${FPM_POOL}"
    else
        echo "${setting}" >> "${FPM_POOL}"
    fi
done

echo "    FPM-Pool ${FPM_POOL} angepasst."

# ================================================================
# Schritt 10 — PHP Tuning
# ================================================================
log "PHP Tuning (zentral via mods-available)"

# Zentrale Konfiguration fuer alle SAPIs (fpm, cli, apache2) statt getrennter
# Pflege pro SAPI. phpenmod verlinkt sie als 20-nextcloud.ini.
PHP_MODS_DIR="/etc/php/${PHP_VER}/mods-available"

cat > "${PHP_MODS_DIR}/nextcloud.ini" <<EOF
; Nextcloud PHP Tuning
; Gemaess Aenderungsdokumentation M. Hadorn (01.09.2026)

memory_limit = 512M
upload_max_filesize = 16G
post_max_size = 16G
max_execution_time = 3600
max_input_time = 3600
output_buffering = 0

; Sessions: NC nimmt intern 24 h an — der Default von 1440 s liess den
; systemd-Timer phpsessionclean Sessions loeschen (Ursache Neuanmeldungen).
session.gc_maxlifetime = 86400

; Eigenes Temp-Verzeichnis, /tmp ist zu klein fuer grosse Uploads
upload_tmp_dir = ${NC_TMPDIR}
sys_temp_dir = ${NC_TMPDIR}

; APCu — 32M fuehrte zur Eviction des Token-Caches
apc.enable_cli = 1
apc.shm_size = 256M

; OPcache
opcache.enable = 1
opcache.enable_cli = 1
opcache.memory_consumption = 256
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files = 20000
opcache.revalidate_freq = 60
opcache.save_comments = 1

; JIT bringt bei Nextcloud keinen Nutzen
opcache.jit = disable
opcache.jit_buffer_size = 0

; Beseitigt "Allocation of JIT memory failed" bei jedem preg_match
pcre.jit = 0
EOF

echo "    ${PHP_MODS_DIR}/nextcloud.ini geschrieben."

phpenmod -v "${PHP_VER}" nextcloud
echo "    Konfiguration fuer alle SAPIs aktiviert (20-nextcloud.ini)."

# Altlasten aus frueheren Laeufen entfernen — die 20er-Verlinkung ist massgebend
for old in "/etc/php/${PHP_VER}"/*/conf.d/99-nextcloud.ini; do
    [[ -e "$old" ]] && rm -f "$old" && echo "    Alte $old entfernt."
done

systemctl restart "php${PHP_VER}-fpm"
systemctl restart apache2
echo "    PHP-FPM und Apache neu gestartet."

# ================================================================
# Schritt 11 — Nextcloud Einrichtung (occ)
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

# ── Caching und Locking ────────────────────────────────────────
# Ohne Redis faellt NC auf DB-Locking zurueck. DB-Locks haben keine TTL:
# jeder abgebrochene PHP-Prozess hinterlaesst eine dauerhafte Sperre.
echo "    Redis-Anbindung konfigurieren..."
sudo -u www-data php occ config:system:set redis host --value="${REDIS_SOCKET}"
sudo -u www-data php occ config:system:set redis port --value=0 --type=integer
sudo -u www-data php occ config:system:set redis timeout --value=1.5 --type=double

sudo -u www-data php occ config:system:set memcache.local --value="\\OC\\Memcache\\APCu"
sudo -u www-data php occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis"
sudo -u www-data php occ config:system:set memcache.distributed --value="\\OC\\Memcache\\Redis"
sudo -u www-data php occ config:system:set filelocking.enabled --value=true --type=boolean

# ── Weitere Systemeinstellungen ────────────────────────────────
echo "    Systemeinstellungen setzen..."
sudo -u www-data php occ config:system:set default_phone_region --value="CH"
sudo -u www-data php occ config:system:set tempdirectory --value="${NC_TMPDIR}"
sudo -u www-data php occ config:system:set log_rotate_size --value=104857600 --type=integer
# Schwere Hintergrundjobs 01:00–05:00 UTC (03:00–07:00 lokal)
sudo -u www-data php occ config:system:set maintenance_window_start --value=1 --type=integer
sudo -u www-data php occ config:system:set overwrite.cli.url --value="https://${SERVER_IP}"

# ── Hintergrundjobs via System-Cron ────────────────────────────
# AJAX-Jobs sind nicht empfohlen; Cron laeuft alle 5 Minuten.
echo "    Cron fuer Hintergrundjobs einrichten..."
CRON_LINE="*/5 * * * * /usr/bin/php${PHP_VER} -f ${NC_DEST}/cron.php"
if crontab -u www-data -l 2>/dev/null | grep -qF "${NC_DEST}/cron.php"; then
    echo "    Cron-Eintrag existiert bereits — uebersprungen."
else
    { crontab -u www-data -l 2>/dev/null || true; echo "${CRON_LINE}"; } \
        | crontab -u www-data -
    echo "    Cron-Eintrag fuer www-data angelegt (alle 5 Minuten)."
fi
sudo -u www-data php occ background:cron

# ── Datenbankschema vervollstaendigen ──────────────────────────
echo "    Datenbankschema pruefen und vervollstaendigen..."
sudo -u www-data php occ db:add-missing-indices
sudo -u www-data php occ db:add-missing-columns
sudo -u www-data php occ db:add-missing-primary-keys

echo "    Nextcloud konfiguriert."

# ── Smoke-Test ─────────────────────────────────────────────────
echo "    Erreichbarkeit pruefen..."
if curl -fsSk -o /dev/null "https://localhost/status.php"; then
    echo "    status.php antwortet."
else
    echo "    WARNUNG: https://localhost/status.php nicht erreichbar."
    echo "    Pruefen mit: systemctl status apache2 php${PHP_VER}-fpm"
fi

echo ""
echo "  Setup-Checks (nur Abweichungen):"
sudo -u www-data php occ setupchecks 2>/dev/null | grep -v '✓' || true

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
printf "║  %-18s %-39s║\n" "Cache/Locking:" "Redis (Unix-Socket)"
printf "║  %-18s %-39s║\n" "PHP:" "${PHP_VER} via FPM (mpm_event)"
printf "║  %-18s %-39s║\n" "Temp-Verzeichnis:" "${NC_TMPDIR}"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Naechste Schritte:                                      ║"
echo "║  - Snake-Oil-Zertifikat durch Let's Encrypt ersetzen    ║"
echo "║    (certbot --apache) oder eigene CA einbinden          ║"
echo "║  - Trusted Domains anpassen falls noetig                ║"
echo "║  - Backup-Strategie einrichten                          ║"
echo "║  - Bei LDAP-Anbindung: ldapCacheTTL auf 1800 setzen,    ║"
echo "║    ldapConnectionTimeout auf 8                          ║"
echo "║  - Unter Last pruefen: meldet FPM 'max_children',       ║"
printf "║    %-18s %-35s║\n" "pm.max_children" "von ${FPM_MAX_CHILDREN} auf 20 erhoehen"
echo "╚══════════════════════════════════════════════════════════╝"
