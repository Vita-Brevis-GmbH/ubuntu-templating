#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  firstboot.sh  →  installiert als /usr/local/sbin/vb-firstboot.sh
#
#  Zero-Touch-Konfiguration beim ERSTEN Boot eines geklonten
#  Templates. Laeuft nicht-interaktiv als systemd-Oneshot
#  (vb-firstboot.service) und erledigt alles, was frueher per Hand
#  ueber post-clone.sh gemacht wurde:
#
#    1. Warten bis cloud-init / Guest Customization fertig ist
#    2. Plausibilitaetscheck: Hostname darf nicht mehr der
#       Template-Hostname sein (sonst kein Join, Retry beim
#       naechsten Boot)
#    3. /etc/server-description setzen
#    4. Join-Credentials beschaffen (Datei oder Umgebung)
#    5. Warten bis Netzwerk, DNS und ein Domain Controller
#       erreichbar sind
#    6. Domain Join mit hinterlegtem Service-Account
#    7. SSSD konfigurieren, aktivieren und verifizieren
#    8. Join-Secret auf dem Klon vernichten, Marker setzen —
#       danach laeuft der Service nie wieder
#
#  Konfiguration:  /etc/vb-template/firstboot.conf   (0600)
#  Join-Passwort:  /etc/vb-template/join.secret      (0600)
#                  oder Umgebungsvariable VB_JOIN_PASSWORD
#  Marker:         /var/lib/vb-template/firstboot.done
#  Log:            /var/log/vb-firstboot.log
#
#  Verwendung (normalerweise automatisch via systemd):
#      sudo /usr/local/sbin/vb-firstboot.sh [--force]
# ─────────────────────────────────────────────────────────────────

# Kein 'set -e': Fehler werden bewusst einzeln behandelt und
# geloggt, damit ein Fehlschlag im Log nachvollziehbar bleibt.
set -uo pipefail

CONF_DIR="/etc/vb-template"
CONF_FILE="${CONF_DIR}/firstboot.conf"
SECRET_FILE="${CONF_DIR}/join.secret"
STATE_DIR="/var/lib/vb-template"
MARKER="${STATE_DIR}/firstboot.done"
LOG_FILE="/var/log/vb-firstboot.log"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-vita-brevis.conf"
SUDOERS_FILE="/etc/sudoers.d/ad-admins"

# ── Defaults (werden von firstboot.conf ueberschrieben) ─────────
AD_DOMAIN=""
AD_REALM=""
AD_ADMIN_GROUP="G_server-admin"
JOIN_USER=""
COMPUTER_OU=""
LOCAL_ADMIN_USER="localadmin"
TEMPLATE_HOSTNAME=""
ENABLE_JOIN="yes"
WIPE_JOIN_SECRET="yes"
WAIT_TIMEOUT="300"
CLOUDINIT_TIMEOUT="300"

FORCE="no"

usage() {
    cat <<'EOF'
vb-firstboot.sh — Zero-Touch-Konfiguration beim ersten Boot

  --force     Auch ausfuehren, wenn der Firstboot-Marker bereits
              gesetzt ist (Repair/Re-Join). Ueberspringt zusaetzlich
              den Template-Hostname-Check.
  --help      Diese Hilfe

Konfiguration: /etc/vb-template/firstboot.conf
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE="yes" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ── Root-Check ──────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Fehler: Dieses Script muss als root ausgefuehrt werden." >&2
    exit 1
fi

# ── Logging ─────────────────────────────────────────────────────
touch "$LOG_FILE" 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { log "WARN  — $*"; }
die()  { log "FEHLER — $*"; log "Firstboot abgebrochen. Retry beim naechsten Boot oder: post-clone.sh --force"; exit 1; }

log "═══════════════════════════════════════════════════════════"
log "vb-firstboot gestartet (force=${FORCE})"

# ── Konfiguration laden ─────────────────────────────────────────
if [[ -r "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
    log "Konfiguration geladen: ${CONF_FILE}"
else
    die "Konfigurationsdatei ${CONF_FILE} fehlt oder ist nicht lesbar."
fi

[[ -n "$AD_DOMAIN" ]] || die "AD_DOMAIN ist in ${CONF_FILE} nicht gesetzt."
[[ -n "$AD_REALM"  ]] || AD_REALM="${AD_DOMAIN^^}"

# ── Marker pruefen ──────────────────────────────────────────────
if [[ -e "$MARKER" && "$FORCE" != "yes" ]]; then
    log "Marker ${MARKER} vorhanden — nichts zu tun."
    exit 0
fi

# ── guestinfo-Helper (VMware, optional) ─────────────────────────
# Erlaubt es, einzelne Werte pro VM ueber die vCenter-WebUI zu
# setzen: VM bearbeiten → VM Options → Advanced →
# Configuration Parameters → Add. Alles optional — fehlt der
# Schluessel, greifen die Defaults.
guestinfo() {
    local key="$1" val
    command -v vmware-rpctool >/dev/null 2>&1 || return 1
    val=$(vmware-rpctool "info-get ${key}" 2>/dev/null) || return 1
    [[ -n "$val" ]] || return 1
    printf '%s' "$val"
}

# ════════════════════════════════════════════════════════════════
# Schritt 1 — cloud-init / Guest Customization abwarten
# ════════════════════════════════════════════════════════════════
log "── [1/8] Warte auf cloud-init (max. ${CLOUDINIT_TIMEOUT}s)..."

if command -v cloud-init >/dev/null 2>&1; then
    if timeout "${CLOUDINIT_TIMEOUT}" cloud-init status --wait >/dev/null 2>&1; then
        log "        cloud-init abgeschlossen."
    else
        warn "cloud-init nicht sauber abgeschlossen (Status: $(cloud-init status 2>/dev/null | head -1)). Weiter."
    fi
else
    warn "cloud-init nicht installiert — Schritt uebersprungen."
fi

# ════════════════════════════════════════════════════════════════
# Schritt 2 — Hostname pruefen
# ════════════════════════════════════════════════════════════════
CURRENT_HOST="$(hostname -s)"
log "── [2/8] Hostname-Check: aktueller Hostname '${CURRENT_HOST}'"

if [[ -n "$TEMPLATE_HOSTNAME" && "$CURRENT_HOST" == "$TEMPLATE_HOSTNAME" && "$FORCE" != "yes" ]]; then
    die "Hostname ist noch der Template-Hostname ('${TEMPLATE_HOSTNAME}').
        Entweder wurde beim Klonen keine Customization Spec gewaehlt, oder
        dies ist die Wartungs-VM des Templates selbst. Es wird NICHT gejoint —
        ein Computer-Objekt mit Template-Namen soll nicht im AD landen.
        Der Join wird beim naechsten Boot automatisch erneut versucht."
fi

# ════════════════════════════════════════════════════════════════
# Schritt 3 — Server-Beschreibung setzen
# ════════════════════════════════════════════════════════════════
log "── [3/8] Server-Beschreibung setzen..."

DESC="$(guestinfo "guestinfo.vb.description" || true)"
if [[ -n "$DESC" ]]; then
    printf '%s\n' "$DESC" > /etc/server-description
    log "        Beschreibung aus guestinfo.vb.description uebernommen."
elif [[ ! -s /etc/server-description ]] || grep -qi '^Template' /etc/server-description 2>/dev/null; then
    printf '%s\n' "$(hostname -f 2>/dev/null || echo "$CURRENT_HOST")" > /etc/server-description
    log "        Platzhalter durch Hostname ersetzt."
else
    log "        Bestehende Beschreibung bleibt unveraendert."
fi

# ════════════════════════════════════════════════════════════════
# Schritt 4 — Domain Join gewuenscht? Credentials beschaffen
# ════════════════════════════════════════════════════════════════
GI_JOIN="$(guestinfo "guestinfo.vb.join" || true)"
if [[ -n "$GI_JOIN" ]]; then
    case "${GI_JOIN,,}" in
        no|false|0|off) ENABLE_JOIN="no" ;;
        yes|true|1|on)  ENABLE_JOIN="yes" ;;
        *) warn "guestinfo.vb.join='${GI_JOIN}' nicht interpretierbar — ignoriert." ;;
    esac
fi

if [[ "${ENABLE_JOIN,,}" != "yes" ]]; then
    log "── [4/8] Domain Join deaktiviert (ENABLE_JOIN=${ENABLE_JOIN}) — uebersprungen."
    mkdir -p "$STATE_DIR"
    {
        echo "firstboot:  $(date '+%Y-%m-%dT%H:%M:%S%z')"
        echo "hostname:   $(hostname -f 2>/dev/null || hostname)"
        echo "domainjoin: uebersprungen"
    } > "$MARKER"
    log "Firstboot abgeschlossen (ohne Domain Join)."
    exit 0
fi

# ── Join-Credentials beschaffen ─────────────────────────────────
log "── [4/8] Join-Credentials beschaffen..."

JOIN_USER="${VB_JOIN_USER:-$JOIN_USER}"
[[ -n "$JOIN_USER" ]] || die "JOIN_USER ist nicht gesetzt."

if [[ -n "${VB_JOIN_PASSWORD:-}" ]]; then
    JOIN_PASSWORD="${VB_JOIN_PASSWORD}"
    log "        Join-Passwort aus Umgebungsvariable."
elif [[ -r "$SECRET_FILE" ]]; then
    JOIN_PASSWORD="$(<"$SECRET_FILE")"
    log "        Join-Passwort aus ${SECRET_FILE}."
else
    die "Kein Join-Passwort gefunden (weder \$VB_JOIN_PASSWORD noch ${SECRET_FILE})."
fi
[[ -n "$JOIN_PASSWORD" ]] || die "Join-Passwort ist leer."

# ════════════════════════════════════════════════════════════════
# Schritt 5 — Auf Netzwerk und Domain Controller warten
# ════════════════════════════════════════════════════════════════
log "── [5/8] Warte auf Netzwerk und Domain Controller (max. ${WAIT_TIMEOUT}s)..."

DEADLINE=$(( SECONDS + WAIT_TIMEOUT ))
ROUTE_OK="no"
while (( SECONDS < DEADLINE )); do
    if [[ -n "$(ip route show default 2>/dev/null)" ]]; then
        ROUTE_OK="yes"
        break
    fi
    sleep 3
done
[[ "$ROUTE_OK" == "yes" ]] || die "Keine Default-Route nach ${WAIT_TIMEOUT}s — Netzwerkkonfiguration pruefen."
log "        Default-Route vorhanden: $(ip route show default | head -1)"

DC_OK="no"
while (( SECONDS < DEADLINE )); do
    if realm discover "$AD_DOMAIN" >/dev/null 2>&1; then
        DC_OK="yes"
        break
    fi
    sleep 5
done
if [[ "$DC_OK" != "yes" ]]; then
    die "Domain '${AD_DOMAIN}' nach ${WAIT_TIMEOUT}s nicht erreichbar.
        Pruefen: DNS-Server korrekt gesetzt? 'nslookup _ldap._tcp.${AD_DOMAIN}'"
fi
log "        Domain '${AD_DOMAIN}' erreichbar."

# ── Zeitsynchronisation (Kerberos toleriert max. 5 Min Abweichung)
TS_DEADLINE=$(( SECONDS + 60 ))
while (( SECONDS < TS_DEADLINE )); do
    [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]] && break
    sleep 5
done
if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    log "        Systemzeit ist synchronisiert."
else
    warn "Systemzeit (noch) nicht synchronisiert — Kerberos kann bei Clock Skew > 5 Min fehlschlagen."
fi

# ════════════════════════════════════════════════════════════════
# Schritt 6 — Domain Join
# ════════════════════════════════════════════════════════════════
log "── [6/8] Domain Join als '${JOIN_USER}' nach '${AD_DOMAIN}'..."

# Veraltete Mitgliedschaft aus dem Template entfernen. Ohne diesen
# Schritt meldet 'realm join' nur "Already joined" und generiert
# keine neue Keytab.
realm leave >/dev/null 2>&1 || true
rm -f /etc/krb5.keytab

join_domain() {
    local rc=0

    # Weg 1: realmd. Das Passwort kommt ueber stdin — 'realm join'
    # liest es von dort, sobald stdin kein Terminal ist.
    local -a realm_args=( --unattended "--user=${JOIN_USER}" )
    [[ -n "$COMPUTER_OU" ]] && realm_args+=( "--computer-ou=${COMPUTER_OU}" )

    printf '%s' "$JOIN_PASSWORD" \
        | realm join "${realm_args[@]}" "$AD_DOMAIN" >>"$LOG_FILE" 2>&1 || rc=$?
    if (( rc == 0 )); then
        log "        'realm join' erfolgreich."
        return 0
    fi
    warn "'realm join' fehlgeschlagen (Exit ${rc}) — Fallback auf 'adcli join'."

    # Weg 2: adcli direkt. Deckt die Faelle ab, in denen realmd
    # stolpert (z.B. PackageKit nicht verfuegbar). Die sssd.conf
    # schreiben wir ohnehin selbst, realmd wird dafuer nicht
    # gebraucht.
    local -a adcli_args=(
        "--domain=${AD_DOMAIN}"
        "--login-user=${JOIN_USER}"
        "--host-fqdn=${CURRENT_HOST}.${AD_DOMAIN}"
        --stdin-password
    )
    [[ -n "$COMPUTER_OU" ]] && adcli_args+=( "--domain-ou=${COMPUTER_OU}" )

    rc=0
    printf '%s' "$JOIN_PASSWORD" \
        | adcli join "${adcli_args[@]}" >>"$LOG_FILE" 2>&1 || rc=$?
    if (( rc == 0 )); then
        log "        'adcli join' erfolgreich."
        return 0
    fi
    warn "'adcli join' fehlgeschlagen (Exit ${rc})."
    return 1
}

if ! join_domain; then
    die "Domain Join fehlgeschlagen. Details im Log: ${LOG_FILE}
        Haeufige Ursachen: falsches Passwort des Join-Accounts, zu wenig
        Delegation auf der Computer-OU, Clock Skew, oder Computer-Objekt
        existiert bereits mit anderem Owner."
fi

if [[ ! -s /etc/krb5.keytab ]]; then
    die "Join gemeldet, aber /etc/krb5.keytab fehlt oder ist leer."
fi
log "        Keytab vorhanden ($(klist -k /etc/krb5.keytab 2>/dev/null | grep -c '@' || echo '?') Eintraege)."

# ════════════════════════════════════════════════════════════════
# Schritt 7 — SSSD konfigurieren und aktivieren
# ════════════════════════════════════════════════════════════════
log "── [7/8] SSSD konfigurieren und aktivieren..."

# realmd schreibt beim Join eine eigene sssd.conf. Wir setzen sie
# danach bewusst noch einmal auf unsere Template-Werte — sonst
# stimmen z.B. use_fully_qualified_names oder fallback_homedir
# nicht mit den sudoers-Regeln aus dem Template ueberein.
cat > /etc/sssd/sssd.conf <<EOF
[sssd]
domains = ${AD_DOMAIN}
config_file_version = 2
services = nss, pam, sudo
# Hinweis: KEIN 'default_domain_suffix' setzen — laut SSSD-Doku
# inkompatibel mit sudo.

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

systemctl enable sssd >/dev/null 2>&1 || warn "'systemctl enable sssd' fehlgeschlagen."
if ! systemctl restart sssd; then
    die "SSSD startet nicht. Pruefen: journalctl -u sssd -n 50"
fi
log "        SSSD laeuft und ist aktiviert."

# ── Verifikation (nicht-interaktiv) ─────────────────────────────
VERIFY_OK="no"
CANON_GROUP=""
for _ in {1..12}; do
    # Erste Spalte von getent: der Gruppenname in der Schreibweise, die
    # SSSD tatsaechlich ausliefert.
    CANON_GROUP="$(getent group "${AD_ADMIN_GROUP}@${AD_DOMAIN}" 2>/dev/null | cut -d: -f1)"
    if [[ -n "$CANON_GROUP" ]]; then
        VERIFY_OK="yes"
        break
    fi
    sleep 5
done
if [[ "$VERIFY_OK" == "yes" ]]; then
    log "        Verifikation OK — AD-Gruppe aufloesbar als '${CANON_GROUP}'."
else
    warn "AD-Gruppe '${AD_ADMIN_GROUP}@${AD_DOMAIN}' nicht aufloesbar.
        Der Join selbst war erfolgreich. Pruefen, ob der Gruppenname stimmt:
        'getent group ${AD_ADMIN_GROUP}@${AD_DOMAIN}' bzw. 'sssctl domain-status ${AD_DOMAIN}'"
fi

# ── Gruppennamen auf die kanonische Schreibweise ziehen ─────────
#
# Warum das noetig ist: sshd vergleicht Gruppennamen in AllowGroups
# ZEICHENGENAU. SSSD dagegen ist beim AD-Provider zwingend
# case-insensitiv — 'case_sensitive = True' ist dort laut sssd.conf(5)
# ungueltig, der Default ist False, und damit kommen Namen aus NSS
# kleingeschrieben zurueck.
#
# Folge ohne diese Korrektur: 'getent group G_Server-Admin@domain'
# liefert brav einen Treffer, die Verifikation oben meldet OK, und sshd
# weist denselben Benutzer trotzdem ab, weil in seiner Gruppenliste
# 'g_server-admin@domain' steht. sshd ersetzt das Passwort dann durch
# eine Dummy-Zeichenkette (Schutz vor Timing-Angriffen), weshalb im Log
# ein Kerberos-Preauth-Fehler landet statt einer Zugriffsverweigerung.
# Das ist ausgesprochen schwer zu deuten.
#
# Deshalb: nach dem Join den echten Namen holen und die Konfiguration
# darauf setzen. Das deckt auch 'case_sensitive = Preserving' ab, wo die
# Schreibweise aus dem Verzeichnis erhalten bleibt.
TYPED_GROUP="${AD_ADMIN_GROUP}@${AD_DOMAIN}"
if [[ "$VERIFY_OK" == "yes" && "$CANON_GROUP" != "$TYPED_GROUP" ]]; then
    log "        Schreibweise weicht ab: konfiguriert '${TYPED_GROUP}', geliefert '${CANON_GROUP}'."

    # --- sshd ---
    if [[ -f "$SSHD_DROPIN" ]] && grep -q '^AllowGroups ' "$SSHD_DROPIN"; then
        _tmp="$(mktemp)"
        cp "$SSHD_DROPIN" "$_tmp.bak"
        # Beide Schreibweisen eintragen. Kostet nichts und haelt die
        # Konfiguration gueltig, falls sich das Verhalten spaeter aendert.
        sed "s|^AllowGroups .*|AllowGroups sudo ${LOCAL_ADMIN_USER} ${CANON_GROUP} ${TYPED_GROUP}|" \
            "$SSHD_DROPIN" > "$_tmp"
        cat "$_tmp" > "$SSHD_DROPIN"
        if sshd -t 2>/dev/null; then
            log "        AllowGroups auf '${CANON_GROUP}' korrigiert."
        else
            cat "$_tmp.bak" > "$SSHD_DROPIN"
            warn "Korrigierte sshd-Konfiguration war ungueltig — Original wiederhergestellt."
        fi
        rm -f "$_tmp" "$_tmp.bak"
    fi

    # --- sudo ---
    # sudo loest den Gruppennamen ueber NSS auf und ist damit von der
    # Schreibweise unabhaengig. Der Vollstaendigkeit halber trotzdem
    # angleichen, aber nur wenn visudo die neue Datei akzeptiert.
    if [[ -f "$SUDOERS_FILE" ]]; then
        _sudo_group="${CANON_GROUP// /\\ }"
        _tmp="$(mktemp)"
        {
            echo "# Sudo fuer AD-Gruppe '${AD_ADMIN_GROUP}' erlauben"
            echo "# Schreibweise von vb-firstboot.sh nach dem Join angeglichen."
            echo "%${_sudo_group} ALL=(ALL) ALL"
        } > "$_tmp"
        chmod 440 "$_tmp"
        if visudo -c -f "$_tmp" >/dev/null 2>&1; then
            cat "$_tmp" > "$SUDOERS_FILE"
            chmod 440 "$SUDOERS_FILE"
            log "        sudoers-Regel auf '${CANON_GROUP}' korrigiert."
        else
            warn "Korrigierte sudoers-Regel war ungueltig — Original bleibt unveraendert."
        fi
        rm -f "$_tmp"
    fi
fi

# ════════════════════════════════════════════════════════════════
# Schritt 8 — Aufraeumen und Marker setzen
# ════════════════════════════════════════════════════════════════
log "── [8/8] Aufraeumen..."

unset JOIN_PASSWORD VB_JOIN_PASSWORD

if [[ "${WIPE_JOIN_SECRET,,}" == "yes" && -f "$SECRET_FILE" ]]; then
    shred -u "$SECRET_FILE" 2>/dev/null || rm -f "$SECRET_FILE"
    log "        Join-Secret auf diesem Klon geloescht (es existiert nur noch im Template)."
fi

mkdir -p "$STATE_DIR"
{
    echo "firstboot:  $(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "hostname:   $(hostname -f 2>/dev/null || hostname)"
    echo "domain:     ${AD_DOMAIN}"
    echo "join-user:  ${JOIN_USER}"
    echo "verify:     ${VERIFY_OK}"
} > "$MARKER"

log "✔ Firstboot erfolgreich abgeschlossen."
log "  AD-Login:    <user>@${AD_DOMAIN}"
log "  Break-Glass: ${LOCAL_ADMIN_USER} (lokales Passwort aus dem Template)"
log "═══════════════════════════════════════════════════════════"
