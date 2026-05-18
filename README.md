# Ubuntu 24.04 LTS — VMware Template Guide

*cloud-init · SSSD · Active Directory · Ubuntu 24.04 LTS*

Anleitung zum Bauen eines Ubuntu-24.04-Templates in VMware vSphere mit
cloud-init, SSH-Hardening, dynamischem MOTD, SSSD/Active-Directory-Anbindung
und sauberem Versiegeln vor dem Konvertieren zum Template.

## Helper-Scripts

Im Repo liegen drei Scripts, die die manuellen Schritte aus den Parts unten
automatisieren:

| Script                | Phase                          | Zweck                                                                  |
|-----------------------|--------------------------------|------------------------------------------------------------------------|
| `prepare-template.sh` | Template-Vorbereitung          | Parts 1–6 (Pakete, cloud-init, SSH, MOTD, SSSD-Vorbereitung, Netplan)  |
| `seal-template.sh`    | Vor dem Konvertieren           | Part 7 (Sysprep: cloud-init clean, Machine-ID, SSH-Keys, Logs …)       |
| `post-clone.sh`       | Nach dem Klonen einer VM       | Part 8 (Domain Join, AD-Test, lokalen Sudo-User `vb-admin` anlegen)    |

> **Hinweis:** Die Parts unten dokumentieren den manuellen Weg. Das Repo
> bildet die Schritte 1:1 in den Scripts ab — wer die Scripts nutzt, kann
> die Parts als Referenz für Konfigurationsdetails und Troubleshooting
> verwenden.

---

## Part 1 — VM Preparation

Start mit einer frisch installierten Ubuntu 24.04 LTS VM in vSphere. Minimale Installation, kein Desktop.

### Schritt 1 — System aktualisieren & Pakete installieren
```bash
sudo apt update && sudo apt upgrade -y

sudo apt install -y \
    cloud-init \
    open-vm-tools \
    curl wget git \
    net-tools \
    ca-certificates
```

> **Hinweis:** `open-vm-tools` aktiviert die VMware Guest Customization — notwendig für automatisches Hostname-, IP- und Domain-Joining via vCenter.

### Schritt 1b — Default-User `localadmin` anlegen

Dieser User dient als Standard-Administratorkonto auf allen geklonten VMs. Das Default-Passwort `Change.Me.Now!` wird in der cloud-init Config hinterlegt und muss beim ersten Login geändert werden.
```bash
# User anlegen mit Home-Verzeichnis und Bash als Shell
sudo adduser --disabled-password --gecos "Local Admin" localadmin

# Sudo-Berechtigung setzen
sudo usermod -aG sudo localadmin

# SSH-Verzeichnis vorbereiten (optional, falls Key-Login gewünscht)
sudo mkdir -p /home/localadmin/.ssh
sudo chmod 700 /home/localadmin/.ssh
sudo chown localadmin:localadmin /home/localadmin/.ssh
```

> **Hinweis:** Kein Passwort manuell setzen — das Default-Passwort wird über die cloud-init Config in `/etc/cloud/cloud.cfg` vergeben. `seal-template.sh` setzt es vor dem Versiegeln zurück.

---

## Part 2 — cloud-init Konfiguration

### Schritt 2 — VMware als bevorzugten Datasource setzen
```bash
sudo vim /etc/cloud/cloud.cfg.d/99-vmware.cfg
```

Inhalt:
```yaml
datasource_list: [VMware, OVF, None]
datasource:
  VMware:
    allow_raw_data: true
  OVF:
    transport: [com.vmware.guestInfo, iso]
```

### Schritt 3 — /etc/cloud/cloud.cfg prüfen

Wichtige Einstellungen sicherstellen:
```yaml
# Hostname bei jedem Clone neu setzen
preserve_hostname: false

# localadmin als Default-User für cloud-init registrieren
system_info:
  default_user:
    name: localadmin
    lock_passwd: false
    gecos: Local Admin
    groups: [adm, sudo]
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash

chpasswd:
  list: |
    localadmin:Change.Me.Now!
  expire: true

ssh_pwauth: true

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

cloud_final_modules:
  - scripts_vendor
  - scripts_per_once
  - scripts_per_boot
  - scripts_per_instance
  - scripts_user
  - final_message
```

> **Hinweis:** Durch `system_info.default_user` weiss cloud-init, dass `localadmin` der Hauptbenutzer ist. Das Default-Passwort `Change.Me.Now!` wird beim ersten Login zwingend geändert (`expire: true`). `ssh_pwauth: true` erlaubt SSH-Login mit Passwort.

---

## Part 3 — SSH Hardening

### Schritt 4 — sshd_config absichern
```bash
sudo vim /etc/ssh/sshd_config
```
```
PermitRootLogin no
PasswordAuthentication yes          # für AD-Passwort-Login
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
KerberosAuthentication yes
GSSAPIAuthentication yes
GSSAPICleanupCredentials yes
X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2

# Zugang auf AD-Gruppe einschränken
AllowGroups G_server-admin@int.vitabrevis.ch localadmin
```
```bash
sudo systemctl restart sshd
```

> **Hinweis:** `AllowGroups` enthält jetzt `localadmin` als lokalen User — damit ist SSH-Zugang vor dem AD-Join möglich.

### Schritt 4b — SSH Host Keys vor sshd regenerieren

Nach dem Versiegeln (Part 7) werden die Host Keys gelöscht. cloud-init generiert sie zwar neu, aber `sshd` startet oft schneller als cloud-init die Config-Phase erreicht — Ergebnis: `no host keys available`.

Lösung: Ein systemd-Service, der fehlende Keys **vor** sshd erzeugt.
```bash
sudo vim /etc/systemd/system/ssh-host-keys.service
```
```ini
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
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable ssh-host-keys.service
```

> **Hinweis:** `ConditionPathExistsGlob` sorgt dafür, dass der Service nur läuft wenn tatsächlich keine Keys vorhanden sind — auf einer laufenden VM hat er also keinen Effekt. `Before=ssh.service` garantiert, dass die Keys bereitstehen bevor sshd startet.

---

## Part 4 — Login Banner (MOTD)

### Schritt 5 — Dynamisches MOTD-Script erstellen
```bash
sudo vim /etc/update-motd.d/99-vita-brevis
```

Inhalt:
```bash
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
```
```bash
# Ausführbar machen
sudo chmod +x /etc/update-motd.d/99-vita-brevis

# Andere Standard-Banner deaktivieren (optional, aber empfohlen)
sudo chmod -x /etc/update-motd.d/10-help-text 2>/dev/null || true
sudo chmod -x /etc/update-motd.d/50-motd-news 2>/dev/null || true
sudo chmod -x /etc/update-motd.d/80-livepatch  2>/dev/null || true
```

### Schritt 6 — Server-Beschreibung Placeholder anlegen
```bash
echo "Template - please set description" | sudo tee /etc/server-description
```

> **Hinweis:** Hostname und IP werden beim Login live aus dem System gelesen — nach einem Clone stimmen die Werte automatisch, ohne manuelle Anpassung.

### Banner testen
```bash
sudo run-parts /etc/update-motd.d/
```

---

## Part 5 — SSSD & Active Directory (Template-Konfiguration)

> **Hinweis:** In diesem Part werden Pakete und Konfiguration vorbereitet. Der eigentliche Domain Join (`realm join`) erfolgt erst nach dem Klonen mit dem finalen Hostname — siehe Part 8.

### Schritt 7 — Benötigte Pakete installieren
```bash
sudo apt install -y \
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
```

> **Hinweis:** Bei der `krb5-user`-Installation wird nach dem Standard-Realm gefragt — Domain in GROSSBUCHSTABEN eingeben: `INT.VITABREVIS.CH`

### Schritt 7b — /etc/krb5.conf konfigurieren

Die Default-Config von `krb5-user` enthält MIT-Beispieleinträge in `[domain_realm]` die unbedingt ersetzt werden müssen. Ohne korrekte Konfiguration schlägt `kinit` mit "KDC reply did not match expectations" fehl.
```bash
sudo vim /etc/krb5.conf
```
```ini
[libdefaults]
    default_realm = INT.VITABREVIS.CH
    kdc_timesync = 1
    ccache_type = 4
    forwardable = true
    proxiable = true
    rdns = false
    dns_canonicalize_hostname = false
    udp_preference_limit = 0

[realms]
    INT.VITABREVIS.CH = {
        kdc = dcs01-000-vb.int.vitabrevis.ch
        kdc = dcs02-000-vb.int.vitabrevis.ch
        admin_server = dcs01-000-vb.int.vitabrevis.ch
    }

[domain_realm]
    .int.vitabrevis.ch = INT.VITABREVIS.CH
    int.vitabrevis.ch = INT.VITABREVIS.CH
```

> ⚠️ **Wichtig:**
> - `dns_canonicalize_hostname = false` — verhindert, dass Kerberos den KDC-Hostnamen per Reverse-DNS auflöst und dabei einen unerwarteten Namen zurückbekommt.
> - `[domain_realm]` — die Default-Einträge (MIT, Stanford, Toronto) müssen komplett entfernt und durch die eigene Domain ersetzt werden.
> - Alle DCs unter `[realms]` auflisten für Redundanz.

### Schritt 8 — /etc/sssd/sssd.conf vorkonfigurieren
```bash
sudo vim /etc/sssd/sssd.conf
```
```ini
[sssd]
domains = int.vitabrevis.ch
config_file_version = 2
services = nss, pam, sudo

[domain/int.vitabrevis.ch]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = INT.VITABREVIS.CH
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u@%d
ad_domain = int.vitabrevis.ch
use_fully_qualified_names = True        # Login als 'john@int.vitabrevis.ch'
ldap_id_mapping = True
access_provider = ad

# Optional: Zugang auf bestimmte AD-Gruppe einschränken
# ad_access_filter = (memberOf=CN=G_server-admin,OU=Groups,DC=int,DC=vitabrevis,DC=ch)

# Performance
ldap_referrals = False
dyndns_update = True
```
```bash
# sssd.conf muss nur für root lesbar sein
sudo chmod 600 /etc/sssd/sssd.conf
```

### Schritt 9 — Automatische Home-Verzeichnisse aktivieren
```bash
sudo pam-auth-update --enable mkhomedir
```

Oder manuell in `/etc/pam.d/common-session`:
```
session required pam_mkhomedir.so skel=/etc/skel/ umask=0077
```

### Schritt 10 — Sudo für AD-Gruppen konfigurieren
```bash
sudo visudo -f /etc/sudoers.d/ad-admins
```
```
# Sudo für AD-Gruppe 'G_server-admin' erlauben
%G_server-admin\@int.vitabrevis.ch ALL=(ALL) ALL

# Ohne Passwort (mit Bedacht verwenden)
# %G_server-admin\@int.vitabrevis.ch ALL=(ALL) NOPASSWD: ALL
```

### Schritt 10b — SSSD & Domain-Mitgliedschaft auf dem Template bereinigen

SSSD darf auf dem Template **nicht** enabled sein — ohne abgeschlossenen Domain Join fehlt `/etc/krb5.keytab`, und SSSD crashed beim Boot mit `Could not restart critical service`. Falls das Template bereits domain-joined war, muss die Mitgliedschaft ebenfalls entfernt werden.
```bash
# Domain-Mitgliedschaft entfernen (falls vorhanden)
sudo realm leave 2>/dev/null || true
sudo rm -f /etc/krb5.keytab

# SSSD deaktivieren
sudo systemctl disable sssd
sudo systemctl stop sssd
```

> **Hinweis:** SSSD wird erst nach dem Domain Join (`realm leave` → `realm join`) im Post-Clone-Prozess aktiviert — siehe Part 8, Schritt 21.

---

## Part 6 — Netzwerk-Fallback konfigurieren

Ohne diesen Schritt bleibt der erste Boot nach dem Klonen hängen: Das Versiegeln löscht die Netplan-Konfiguration, und `systemd-networkd-wait-online` blockiert den Boot solange kein Interface online kommt.

### Schritt 11 — DHCP-Fallback Netplan anlegen

Diese Datei wird beim Versiegeln **nicht** gelöscht und stellt sicher, dass nach dem Klonen immer ein Netzwerk-Interface per DHCP hochkommt — auch wenn cloud-init die Guest Customization noch nicht verarbeitet hat.
```bash
sudo vim /etc/netplan/99-fallback-dhcp.yaml
```
```yaml
network:
  version: 2
  ethernets:
    match-all:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: false
```
```bash
sudo chmod 600 /etc/netplan/99-fallback-dhcp.yaml
sudo netplan apply
```

### Schritt 12 — systemd-networkd-wait-online deaktivieren

Verhindert, dass ein fehlendes oder langsames Netzwerk den gesamten Boot blockiert.
```bash
sudo systemctl disable systemd-networkd-wait-online.service
sudo systemctl mask systemd-networkd-wait-online.service
```

> **Hinweis:** Wenn cloud-init vom VMware-Datasource eine spezifischere Netzwerkkonfiguration erhält, überschreibt diese die Fallback-Config automatisch.

---

## Part 7 — Template versiegeln (Sysprep-Äquivalent)

Das ist der eigentliche Sysprep-Schritt — alle instanzspezifischen Daten werden entfernt, damit jeder Clone mit einer sauberen Identität startet.

### Schritt 13 — cloud-init State löschen
```bash
sudo cloud-init clean --logs --seed
```

### Schritt 14 — Machine-ID zurücksetzen

Die Machine-ID wird von DHCP, systemd und diversen Diensten zur eindeutigen Identifikation genutzt. Jeder Clone muss seine eigene generieren.
```bash
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
```

### Schritt 15 — SSH Host Keys löschen
```bash
sudo rm -f /etc/ssh/ssh_host_*
```

> Neue Host Keys werden beim ersten Boot automatisch generiert.

### Schritt 16 — Netzwerk, History & Logs aufräumen
```bash
# Nur die cloud-init generierte Netplan-Config löschen
# 99-fallback-dhcp.yaml bleibt erhalten!
sudo rm -f /etc/netplan/50-cloud-init.yaml

# Shell History
sudo truncate -s 0 /root/.bash_history
sudo truncate -s 0 ~/.bash_history
history -c

# Package Cache & Temp-Dateien
sudo apt autoremove -y && sudo apt clean
sudo rm -rf /tmp/* /var/tmp/*

# System Logs
sudo journalctl --rotate
sudo journalctl --vacuum-time=1s
sudo find /var/log -type f -exec truncate -s 0 {} \;
```

### Schritt 17 — Herunterfahren & Template erstellen
```bash
sudo shutdown -h now
```

> ⚠️ **Nur herunterfahren — NICHT neu starten!** Ein Reboot generiert Machine-ID und SSH-Keys sofort neu.

Danach in vCenter:
```
Rechtsklick auf VM → Template → Convert to Template
```

---

## Part 8 — Deploy & Verify (Post-Clone)

Beim Klonen werden drei Dinge individuell pro VM konfiguriert: **Hostname**, **IP-Konfiguration** und **Passwort für `localadmin`**. Dafür stehen zwei Mechanismen zur Verfügung, die zusammenarbeiten:

| Mechanismus                      | Setzt                                                  |
|----------------------------------|--------------------------------------------------------|
| vCenter Guest OS Customization   | Hostname, Domain, IP-Adresse, Gateway, DNS             |
| cloud-init User-Data             | Passwort für `localadmin`, Server-Beschreibung, Scripte  |

### Schritt 18a — Customization Specification in vCenter erstellen

Unter **Menu → Policies and Profiles → VM Customization Specifications** eine neue Spec für Linux anlegen. Diese wird beim Klonen ausgewählt und setzt Hostname sowie Netzwerk.

**Hostname-Einstellungen:**
- *Computer Name* → **Use the Virtual Machine Name** (empfohlen) oder manuell eingeben
- Damit übernimmt die VM automatisch den Namen, den sie beim Klonen im Inventar bekommt

**Netzwerk-Einstellungen (statische IP):**
- NIC 1 konfigurieren:
  - IPv4: Manuell
  - IP-Adresse: `10.0.1.50` (Beispiel — je VM anpassen)
  - Subnetzmaske: `255.255.255.0`
  - Gateway: `10.0.1.1`
- DNS-Server: `10.0.1.10, 10.0.1.11` (Domain Controller)
- DNS-Suchdomain: `int.vitabrevis.ch`

> **Hinweis:** Die Customization Spec kann als Vorlage gespeichert und beim Klonen pro VM angepasst werden. Unter *Customize this virtual machine's hardware → Network* lässt sich die IP pro Klon individuell überschreiben.

**Alternativ: DHCP beibehalten** — Wenn der Server seine IP per DHCP erhalten soll, einfach bei NIC 1 *DHCP* auswählen. Die Fallback-Config aus Part 6 greift dann automatisch.

### Schritt 18b — Login-Daten nach dem Klonen

Das Template enthält ein Default-Passwort, das direkt in der cloud-init Config hinterlegt ist. **User-Data ist nicht erforderlich.**

| | |
|---|---|
| **User** | `localadmin` |
| **Passwort** | `Change.Me.Now!` |
| **Passwortwechsel** | Wird beim ersten Login erzwungen |

> ⚠️ **Wichtig:** Das Default-Passwort sofort nach dem ersten Login ändern. `expire: true` in der cloud-init Config erzwingt dies automatisch.

### Schritt 18c — Klon-Vorgang in vCenter durchführen

Zusammenfassung des Ablaufs:

1. **Rechtsklick auf Template → New VM from This Template**
2. VM-Name eingeben (wird als Hostname übernommen, z.B. `srv-nextcloud-01`)
3. Datastore und Cluster auswählen
4. **Customize operating system** → Gespeicherte Customization Spec auswählen
5. IP-Adresse für diesen spezifischen Klon anpassen (falls statisch)
6. Zusammenfassung prüfen → **Finish**

### cloud-init Phasen beim ersten Boot

| Phase   | Was passiert                                              |
|---------|-----------------------------------------------------------|
| detect  | VMware Datasource wird via guestInfo erkannt              |
| local   | Hostname & Machine-ID werden gesetzt (aus Customization)  |
| network | IP-Konfiguration angewendet, SSH Host Keys erstellt       |
| config  | Default-Passwort für `localadmin` aktiv, Passwortwechsel erzwungen |
| final   | write_files Scripts ausgeführt, final_message              |

### Schritt 19 — cloud-init nach dem ersten Boot prüfen
```bash
# Warten bis alle Phasen abgeschlossen sind
sudo cloud-init status --wait

# Logs ansehen
sudo cat /var/log/cloud-init.log

# Detaillierte Timing-Analyse
sudo cloud-init analyze show

# Prüfen ob Hostname korrekt gesetzt wurde
hostname -f
hostnamectl

# Prüfen ob IP korrekt konfiguriert ist
ip addr show
cat /etc/netplan/*.yaml
```

### Schritt 20 — Domain erreichbar prüfen
```bash
# Domain Controller entdecken
realm discover int.vitabrevis.ch

# DNS-Auflösung testen
nslookup int.vitabrevis.ch
nslookup _ldap._tcp.int.vitabrevis.ch
```

### Schritt 21 — Domain beitreten ⬅ Post-Clone, mit finalem Hostname
```bash
# Sicherstellen, dass keine veraltete Mitgliedschaft existiert
sudo realm leave 2>/dev/null || true
sudo rm -f /etc/krb5.keytab

# Mit Domain Admin (oder delegiertem Join-Account)
sudo realm join --user=Administrator int.vitabrevis.ch

# Mitgliedschaft prüfen
realm list
```

> **Hinweis:** `realm leave` vor dem Join ist wichtig — ein geklontes Template kann eine veraltete Realm-Mitgliedschaft enthalten. Ohne `realm leave` meldet `realm join` nur "Already joined to this domain" und überspringt die Keytab-Generierung. Falls DNS nicht auf den DC zeigt: `--server=<DC-IP>` anhängen.
```bash
# SSSD starten & aktivieren
sudo systemctl enable --now sssd
```

### Schritt 22 — AD-Authentifizierung testen
```bash
# AD-User nachschlagen
id john@int.vitabrevis.ch

# Kerberos Ticket testen
kinit john@INT.VITABREVIS.CH
klist

# Login testen
su - john

# SSSD Cache & Logs prüfen
sudo sssctl user-show john
sudo tail -50 /var/log/sssd/sssd_int.vitabrevis.ch.log
```

### Schritt 23 — Lokalen Sudo-User `vb-admin` anlegen (Break-Glass-Account)

Nach erfolgreichem Domain Join wird auf jedem Klon ein zusätzlicher lokaler
Sudo-User `vb-admin` angelegt. Er dient als **Break-Glass-Account** für den
Fall, dass AD/SSSD nicht erreichbar ist (z.B. DC-Ausfall, Netzwerkproblem,
Kerberos-Issue) — dann ist trotzdem ein lokaler Login mit Sudo-Rechten
möglich.
```bash
# Interaktive Passwortabfrage durch adduser
sudo adduser --gecos "VitaBrevis Admin" vb-admin

# Sudo-Gruppe zuweisen
sudo usermod -aG sudo vb-admin
```

> **Hinweis:** `adduser` fragt das Passwort interaktiv ab. Pro Klon ein
> individuelles, starkes Passwort vergeben und sicher hinterlegen
> (Passwortmanager / Vault). Der User bleibt persistent auf der VM —
> im Gegensatz zu `localadmin`, dessen Default-Passwort vom Template stammt
> und beim ersten Login geändert werden muss.

Damit `vb-admin` auch via SSH einloggen kann, sollte die SSH-`AllowGroups`-Zeile
(Part 3, Schritt 4) bereits den lokalen User enthalten — alternativ kann ein
zusätzlicher User explizit erlaubt werden:
```bash
# Optional: vb-admin explizit für SSH erlauben
sudo sed -i 's/^AllowGroups .*/& vb-admin/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

> **Automatisierung:** Diese drei Schritte (Domain Join, AD-Test, vb-admin
> anlegen) sind in `post-clone.sh` zusammengefasst. Aufruf nach dem Klonen:
> `sudo ./post-clone.sh`.

### Troubleshooting

| Symptom                          | Ursache                             | Lösung                                          |
|----------------------------------|-------------------------------------|-------------------------------------------------|
| Boot hängt bei networkd          | Kein Netzwerk-Interface online      | Part 6 Schritte 11+12 nachholen                 |
| Keine Netzwerkverbindung         | Netplan-Config fehlt                | `99-fallback-dhcp.yaml` vorhanden?              |
| Hostname ist noch der alte       | Customization Spec nicht ausgewählt | Klon erneut mit Spec deployen                   |
| IP-Adresse stimmt nicht          | DHCP überschreibt statische Config  | Fallback-Config Priorität prüfen (99 vs 50)     |
| `localadmin` Login verweigert    | Passwort nicht gesetzt / User locked | User-Data in cloud-init Logs prüfen            |
| `vb-admin` Login verweigert      | User nicht in `AllowGroups` / kein Sudo | `usermod -aG sudo vb-admin`, `AllowGroups` in sshd_config prüfen |
| `id: user not found`            | SSSD läuft nicht / falsche Domain   | `systemctl restart sssd; realm list`            |
| SSSD crashed: `krb5.keytab not found` | SSSD enabled vor Domain Join   | `systemctl disable sssd`, erst nach `realm join` aktivieren |
| `Already joined` + keytab fehlt  | Veraltete Realm-Mitgliedschaft vom Template | `realm leave`, `rm /etc/krb5.keytab`, dann neu joinen |
| `realm join`: Insufficient permissions | Join-Account hat zu wenig Rechte | Delegation auf OU: Write All Properties auf Computer Objects |
| `kinit`: KDC reply did not match | `[domain_realm]` fehlt oder falsch  | MIT-Defaults ersetzen, `dns_canonicalize_hostname = false` setzen |
| Kerberos Auth schlägt fehl       | Clock Skew > 5 Minuten             | `sudo ntpdate -u <DC-IP>; timedatectl`          |
| AD-User: not in sudoers file     | `@` in sudoers nicht escaped       | `%G_server-admin\@int.vitabrevis.ch` verwenden  |
| Sudoers-Änderung greift nicht    | SSSD cached Gruppenmitgliedschaft  | `rm -rf /var/lib/sss/db/*`, SSSD restart, neu einloggen |
| Login verweigert                 | User nicht in erlaubter Gruppe      | `ad_access_filter` oder `AllowGroups` prüfen    |
| Home-Verzeichnis fehlt           | pam_mkhomedir nicht aktiv           | `pam-auth-update --enable mkhomedir`            |
| Offline-Login schlägt fehl       | `cache_credentials = False`         | `cache_credentials = True` in sssd.conf setzen  |

---

## Part 9 — seal-template.sh

Dieses Script in `/usr/local/sbin/seal-template.sh` speichern und vor jedem Template-Update ausführen. Es automatisiert den gesamten Part 7.
```bash
#!/bin/bash
# ─────────────────────────────────────────────────────────────────
#  seal-template.sh — Ubuntu VM für VMware Template vorbereiten
#  Verwendung: sudo ./seal-template.sh
# ─────────────────────────────────────────────────────────────────
set -euo pipefail

echo "==> [1/10] cloud-init State löschen..."
cloud-init clean --logs --seed

echo "==> [2/10] Machine-ID zurücksetzen..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

echo "==> [3/10] SSH Host Keys löschen..."
rm -f /etc/ssh/ssh_host_*

echo "==> [4/10] Netplan cloud-init Config entfernen (Fallback bleibt erhalten)..."
rm -f /etc/netplan/50-cloud-init.yaml

echo "==> [5/10] localadmin Passwort auf Default zuruecksetzen..."
echo "localadmin:Change.Me.Now!" | chpasswd
chage -d 0 localadmin

echo "==> [6/10] Domain-Mitgliedschaft entfernen (Klon muss neu joinen)..."
realm leave 2>/dev/null || true
rm -f /etc/krb5.keytab

echo "==> [7/10] SSSD stoppen & deaktivieren (wird nach realm join aktiviert)..."
systemctl disable sssd 2>/dev/null || true
systemctl stop sssd 2>/dev/null || true

echo "==> [8/10] Shell History & Temp-Dateien löschen..."
truncate -s 0 /root/.bash_history
truncate -s 0 /home/*/.bash_history 2>/dev/null || true
rm -rf /tmp/* /var/tmp/*

echo "==> [9/10] Package Cache & Logs bereinigen..."
apt autoremove -y && apt clean
journalctl --rotate
journalctl --vacuum-time=1s
find /var/log -type f -exec truncate -s 0 {} \;

echo "==> [10/10] SSSD Cache wird bewusst behalten..."
# sssctl cache-remove -o     # auskommentieren um SSSD Cache ebenfalls zu löschen

echo ""
echo "✔  Template erfolgreich versiegelt."
echo "   VM jetzt herunterfahren: sudo shutdown -h now"
echo "   Danach in vCenter zu Template konvertieren."
```
```bash
# Ausführbar machen
sudo chmod +x /usr/local/sbin/seal-template.sh

# Vor jedem Template-Update ausführen
sudo seal-template.sh
```

> **Hinweis:** Das Script entfernt die Domain-Mitgliedschaft (Schritt 6/10), setzt das `localadmin`-Passwort auf den Default `Change.Me.Now!` zurück (Schritt 5/10) und deaktiviert SSSD (Schritt 7/10). Der Passwortwechsel wird beim ersten Login erzwungen (`chage -d 0`).
