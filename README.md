# Ubuntu 24.04 LTS — VMware Template Guide

*cloud-init · SSSD · Active Directory · Zero-Touch Deployment · Ubuntu 24.04 LTS*

Anleitung zum Bauen eines Ubuntu-24.04-Templates in VMware vSphere mit
cloud-init, SSH-Hardening, dynamischem MOTD, SSSD/Active-Directory-Anbindung
und sauberem Versiegeln vor dem Konvertieren zum Template.

## Der Deployment-Ablauf in Kürze

Seit die cloud-init User-Data beim Klonen in vCenter nicht mehr mitgegeben
werden können, wird **nichts mehr von Hand nachkonfiguriert**. Alles, was
pro VM unterschiedlich ist, kommt aus zwei Quellen:

| Quelle                          | Liefert                                            |
|---------------------------------|-----------------------------------------------------|
| vCenter Guest OS Customization  | Hostname, IP-Adresse, Gateway, DNS                 |
| `vb-firstboot.service` im Gast  | Domain Join, SSSD, Server-Beschreibung             |

Der Ablauf besteht damit aus genau drei Handgriffen im vCenter:

1. **Rechtsklick auf das Template → New VM from This Template**
2. VM-Namen vergeben und die Customization Spec auswählen
3. Einschalten — fertig

Beim ersten Boot joint die VM selbsttätig die Domain und aktiviert SSSD.
Danach meldet man sich mit dem AD-Konto an. Details in
[Part 6c](#part-6c--zero-touch-firstboot-vb-firstboot).

## Helper-Scripts

Im Repo liegen mehrere Scripts, die die manuellen Schritte aus den Parts unten
automatisieren:

| Script                | Phase                          | Zweck                                                                  |
|-----------------------|--------------------------------|------------------------------------------------------------------------|
| `prepare-template.sh` | Template-Vorbereitung          | Parts 1–6c (Pakete, cloud-init, SSH-Hardening, MOTD, SSSD-Vorbereitung, Netplan, SNMP, Firstboot-Automatik) |
| `firstboot.sh`        | Läuft **automatisch** im Klon  | Wird als `/usr/local/sbin/vb-firstboot.sh` installiert und beim ersten Boot von `vb-firstboot.service` ausgeführt: Domain Join, SSSD, Server-Beschreibung |
| `vb-firstboot.service`| systemd-Unit dazu              | Oneshot beim ersten Boot, deaktiviert sich danach über einen Marker    |
| `seal-template.sh`    | Vor dem Konvertieren           | Part 7 (Sysprep: cloud-init clean, Machine-ID, SSH-Keys, Logs, Break-Glass-Passwort, Firstboot scharf schalten) |
| `post-clone.sh`       | Nur im Störungsfall            | Status anzeigen, fehlgeschlagenen Join nachholen, Break-Glass-Passwort ändern |
| `domain-join.sh`      | Standalone AD-Join             | Nur Domain Join: SSSD/Kerberos installieren + konfigurieren + joinen + testen — unabhängig von den Template-Scripts einsetzbar |
| `deploy-nextcloud.sh` | Rollen-Deploy (Ubuntu 24.04)   | LVM `/data` + Apache + MariaDB + **PHP 8.3** + Nextcloud                |
| `deploy-nextcloud-26.04.sh` | Rollen-Deploy (Ubuntu 26.04) | Wie oben, aber mit distro-nativem **PHP 8.5** (26.04 liefert kein php8.3) |

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

### Schritt 1b — Break-Glass-User `localadmin` anlegen

Dieser User ist das **Break-Glass-Konto**: der lokale Notzugang für den Fall,
dass AD oder SSSD nicht erreichbar sind. Der reguläre Admin-Zugang läuft über
Active Directory. Sein Passwort wird ausschliesslich von `seal-template.sh`
vergeben — siehe Part 7.
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

> **Hinweis:** Kein Passwort manuell setzen. `seal-template.sh` fragt es beim
> Versiegeln ab und ist die einzige Stelle, an der es vergeben wird. Zwischen
> `prepare-template.sh` und `seal-template.sh` hat `localadmin` deshalb noch
> kein Passwort — das ist beabsichtigt.

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

> **Hinweis:** Durch `system_info.default_user` weiss cloud-init, dass `localadmin` der Hauptbenutzer ist. `ssh_pwauth: true` erlaubt SSH-Login mit Passwort.

> ⚠️ **Bewusst kein `chpasswd`-Block:** Früher stand das Default-Passwort
> zusätzlich hier. Das Ergebnis waren zwei konkurrierende Quellen für dasselbe
> Passwort — cloud-init hat beim ersten Boot jedes Klons überschrieben, was
> `seal-template.sh` vorher gesetzt hatte. Das Break-Glass-Passwort wird
> ausschliesslich beim Versiegeln vergeben.

---

## Part 3 — SSH Hardening

### Schritt 4 — sshd absichern

`prepare-template.sh` erledigt das automatisch. Statt `/etc/ssh/sshd_config`
zu verändern, schreibt es ein Drop-in — Ubuntu 24.04 zieht
`/etc/ssh/sshd_config.d/*.conf` ganz oben ein, damit gewinnen diese Werte
und ein Distributions-Update kann sie nicht überschreiben.
```bash
sudo vim /etc/ssh/sshd_config.d/99-vita-brevis.conf
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

# Zugang auf AD-Gruppe und lokale Admins einschränken
AllowGroups sudo localadmin G_server-admin@int.vitabrevis.ch
```
```bash
# Erst validieren, dann aktivieren — eine kaputte Config sperrt beim
# nächsten Reconnect aus.
sudo sshd -t && sudo systemctl reload ssh
```

> **Hinweis:** `AllowGroups` enthält neben der AD-Gruppe auch `sudo` und
> `localadmin`. Damit bleibt der Break-Glass-Zugang offen, solange die Domain
> nicht erreichbar ist. Schlägt `sshd -t` fehl, entfernt
> `prepare-template.sh` das Drop-in wieder, statt die laufende SSH-Sitzung zu
> riskieren.

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
# Hinweis: KEIN 'default_domain_suffix' setzen — es ist laut SSSD-Doku
# inkompatibel mit sudo und bricht das Matching gruppenbasierter
# sudoers-Regeln (%G_server-admin@domain) sowie die Namensauflösung der
# Primärgruppe ('groups: cannot find name for group ID ...').

[domain/int.vitabrevis.ch]
default_shell = /bin/bash
krb5_store_password_if_offline = True
cache_credentials = True
krb5_realm = INT.VITABREVIS.CH
realmd_tags = manages-system joined-with-adcli
id_provider = ad
fallback_homedir = /home/%u@%d
ad_domain = int.vitabrevis.ch
use_fully_qualified_names = True        # NSS liefert FQN: 'john@int.vitabrevis.ch'
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
# Gruppenname mit '@' in doppelte Anführungszeichen setzen — modernes
# sudo (1.9.x, Ubuntu 24.04) lehnt den Backslash-Escape '\@' als
# "illegal escape sequence" ab.
"%G_server-admin@int.vitabrevis.ch" ALL=(ALL) ALL

# Ohne Passwort (mit Bedacht verwenden)
# "%G_server-admin@int.vitabrevis.ch" ALL=(ALL) NOPASSWD: ALL
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

## Part 6b — SNMP Monitoring (SNMPv2c)

Alle geklonten VMs sollen per SNMP überwacht werden. Die Community wird
**einmalig beim Template-Bau** vergeben und ist damit auf allen Klonen
identisch — Zugriffsbeschränkung erfolgt zusätzlich über Firewall/Routing
auf den Monitoring-Host.

### Schritt 12a — snmpd installieren
```bash
sudo apt install -y snmpd snmp
```

### Schritt 12b — /etc/snmp/snmpd.conf konfigurieren
```bash
sudo vim /etc/snmp/snmpd.conf
```
```ini
# Listen auf allen Interfaces, UDP/161
agentAddress udp:161

sysLocation    Vita Brevis Datacenter
sysContact     it@vitabrevis.ch
sysServices    72

# MIB-2 + UCD freigeben (CPU, RAM, Disk, Interfaces)
view systemview included .1.3.6.1.2.1
view systemview included .1.3.6.1.4.1.2021
view systemview included .1.3.6.1.4.1.2021.11

# Read-only Community (SNMPv2c)
rocommunity <COMMUNITY> default -V systemview

# Disk- und Load-Monitoring
includeAllDisks 10%
load 12 10 5
```
```bash
sudo chmod 600 /etc/snmp/snmpd.conf
sudo systemctl enable --now snmpd
```

> ⚠️ **Wichtig:** Die Community ist auf SNMPv2c ein **Shared Secret** —
> nicht öffentlich machen, nicht `public` verwenden. Da SNMPv2c
> unverschlüsselt überträgt, MUSS der Zugriff zusätzlich per Firewall auf
> die Monitoring-Server beschränkt werden.

### Schritt 12c — Erreichbarkeit testen
Vom Monitoring-Host:
```bash
snmpwalk -v 2c -c <community> <host> system
snmpget  -v 2c -c <community> <host> hrSystemUptime.0
```

> **Hinweis:** snmpd wird im Template aktiv gelassen — beim Klonen
> startet der Service automatisch mit; `sysName` wird dynamisch aus
> dem (durch cloud-init gesetzten) Hostname gelesen.

---

## Part 6c — Zero-Touch Firstboot (`vb-firstboot`)

Das ist das Herzstück des Ablaufs. Ein systemd-Oneshot läuft beim **ersten
Boot eines Klons**, joint die Domain und aktiviert SSSD. Danach setzt er einen
Marker und läuft nie wieder.

Der Dienst ersetzt den früheren manuellen Lauf von `post-clone.sh`. Weil er
komplett im Gast liegt, funktioniert er unabhängig davon, was der Hypervisor
an User-Data durchreicht — und bleibt damit auch nach der Migration auf
Proxmox gültig.

### Schritt 12d — AD vorbereiten: delegierter Join-Account

Der Klon joint sich mit einem eigenen Service-Account. Der braucht **keine
Domain-Admin-Rechte**. Auf der Ziel-OU für Computerobjekte genügt:

| Recht                                   | Objekttyp        |
|-----------------------------------------|------------------|
| Create Computer Objects                 | OU               |
| Delete Computer Objects                 | OU               |
| Write All Properties                    | Computer Objects |
| Reset Password                          | Computer Objects |

In *Active Directory Users and Computers* → Rechtsklick auf die OU →
**Delegate Control** → Service-Account wählen → *Create a custom task to
delegate* → *Computer objects* mit *Create* und *Delete* → obige Rechte.

> ⚠️ Den Account nicht für andere Zwecke wiederverwenden und bei jedem
> Template-Rebuild rotieren. Sein Passwort liegt im Template.

### Schritt 12e — Dateien im Template

`prepare-template.sh` legt alles an. Zur Orientierung:

| Pfad                                  | Rechte | Inhalt                                          |
|---------------------------------------|--------|-------------------------------------------------|
| `/usr/local/sbin/vb-firstboot.sh`     | `0755` | Das Script (aus `firstboot.sh` im Repo)         |
| `/etc/systemd/system/vb-firstboot.service` | `0644` | Die systemd-Unit                           |
| `/etc/vb-template/firstboot.conf`     | `0600` | Domain, Realm, Join-Account, OU, Timeouts       |
| `/etc/vb-template/join.secret`        | `0600` | Passwort des Join-Accounts, ohne Zeilenumbruch  |
| `/var/lib/vb-template/firstboot.done` | `0644` | Marker — erst nach erfolgreichem Lauf vorhanden |
| `/var/log/vb-firstboot.log`           | `0600` | Protokoll des Laufs                             |

### Schritt 12f — Was beim ersten Boot passiert

| Schritt | Aktion                                                                 |
|---------|------------------------------------------------------------------------|
| 1       | `cloud-init status --wait` — Hostname und IP stehen erst danach fest     |
| 2       | Hostname-Check gegen `TEMPLATE_HOSTNAME` (siehe unten)                  |
| 3       | `/etc/server-description` setzen                                        |
| 4       | Join-Passwort aus `join.secret` oder `$VB_JOIN_PASSWORD` lesen           |
| 5       | Warten auf Default-Route, `realm discover` und Zeitsynchronisation       |
| 6       | `realm leave`, Keytab löschen, dann `realm join` (Fallback: `adcli join`)|
| 7       | `sssd.conf` auf die Template-Werte setzen, SSSD starten, Gruppe auflösen |
| 8       | `join.secret` vernichten, Marker setzen                                 |

### Der Hostname-Schutz

`seal-template.sh` schreibt den Hostname des Templates in die Config. Stimmt
der Hostname beim Boot noch damit überein, wurde **keine Customization Spec
angewendet** — oder es handelt sich um die Wartungs-VM des Templates selbst.
In beiden Fällen bricht der Dienst ab, statt ein Computerobjekt mit dem
Template-Namen im AD anzulegen. Beim nächsten Boot versucht er es erneut.

Das heisst auch: Wer das Template zum Aktualisieren wieder als VM startet,
muss nichts weiter beachten. Die Wartungs-VM joint nicht.

### Fehlerverhalten

Der Marker wird **nur nach einem erfolgreichen Lauf** gesetzt. Schlägt der
Join fehl, bleibt er aus und der Dienst versucht es beim nächsten Boot wieder.
Das Join-Secret wird dabei nicht angetastet.

```bash
# Nachsehen, was passiert ist
sudo cat /var/log/vb-firstboot.log
sudo journalctl -u vb-firstboot -n 50

# Sofort nachholen, ohne Reboot
sudo ./post-clone.sh --force
```

### Optional: Werte pro VM über die vCenter-WebUI

Auch ohne cloud-init User-Data lassen sich einzelne Werte pro VM mitgeben —
über *VM bearbeiten → VM Options → Advanced → Configuration Parameters →
Add*. Das Script liest sie mit `vmware-rpctool` aus. Beides ist optional.

| Parameter                   | Wirkung                                                  |
|-----------------------------|----------------------------------------------------------|
| `guestinfo.vb.description`  | Setzt `/etc/server-description` (erscheint im MOTD)      |
| `guestinfo.vb.join`         | `no` überspringt den Domain Join auf dieser VM           |

> **Hinweis:** Der Klon-Assistent kennt diese Felder nicht. Wer sie nutzen
> will, klont ohne Einschalten, trägt die Parameter nach und schaltet dann
> ein. Für den Normalfall braucht es das nicht.

### Sicherheitsabwägung

Das Passwort des Join-Accounts liegt als root-lesbare Datei im Template.
Wer root auf einem frisch geklonten, noch nicht gejointen System hat, kann es
lesen. Abgefedert wird das so:

- Der Account darf **nur** Computerobjekte in einer OU verwalten.
- Nach erfolgreichem Join wird `join.secret` auf dem Klon mit `shred`
  vernichtet. Es existiert dann nur noch im Template.
- Das Passwort wird bei jedem Template-Rebuild rotiert.

Wer das nicht will, setzt beim Bau kein Passwort. Dann bleibt der Auto-Join
deaktiviert und die Klone werden mit `post-clone.sh --force` oder
`domain-join.sh` von Hand gejoint.

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

### Schritt 16b — Break-Glass-Passwort vergeben

Das Passwort für `localadmin` wird hier vergeben und nirgends sonst. Es steht
bewusst **nicht** im Repository: ein Passwort im Git-Verlauf gilt auf jedem
Klon und lässt sich nicht zurückziehen.
```bash
# Interaktiv (fragt zweimal ab, ohne Echo)
sudo ./seal-template.sh

# Oder unbeaufsichtigt
sudo VB_LOCAL_ADMIN_PASSWORD='…' ./seal-template.sh
```

> ⚠️ Das Passwort gilt auf allen Klonen dieses Templates. Sicher hinterlegen
> und bei jedem Template-Rebuild rotieren.

### Schritt 16c — Firstboot scharf schalten

`seal-template.sh` erledigt das mit. Zur Kontrolle:
```bash
# Template-Hostname festhalten — Grundlage für den Hostname-Schutz
grep TEMPLATE_HOSTNAME /etc/vb-template/firstboot.conf

# Marker muss WEG sein, sonst überspringt der Klon den Join
ls /var/lib/vb-template/firstboot.done      # darf nicht existieren

# Service muss aktiviert sein
systemctl is-enabled vb-firstboot.service   # → enabled

# Join-Secret muss vorhanden sein
sudo ls -l /etc/vb-template/join.secret     # → -rw------- root root
```

### Schritt 17 — Herunterfahren & Template erstellen
```bash
sudo shutdown -h now
```

> ⚠️ **Nur herunterfahren — NICHT neu starten!** Ein Reboot generiert Machine-ID und SSH-Keys sofort neu — und stösst den Firstboot-Lauf an.

Danach in vCenter:
```
Rechtsklick auf VM → Template → Convert to Template
```

---

## Part 8 — Deploy & Verify (Zero-Touch)

Pro VM sind nur noch zwei Dinge individuell: **Hostname** und
**IP-Konfiguration**. Beides liefert die vCenter Guest OS Customization.
Alles Weitere — Domain Join, SSSD, Server-Beschreibung — erledigt
`vb-firstboot.service` im Gast.

| Mechanismus                     | Setzt                                          |
|---------------------------------|------------------------------------------------|
| vCenter Guest OS Customization  | Hostname, Domain, IP-Adresse, Gateway, DNS     |
| `vb-firstboot.service` im Gast  | Domain Join, SSSD, `/etc/server-description`   |

> **Warum kein cloud-init User-Data mehr?** Es lässt sich beim Klonen in
> vCenter nicht mehr hinterlegen. Deshalb liegt die gesamte Logik im Gast —
> siehe [Part 6c](#part-6c--zero-touch-firstboot-vb-firstboot). Das ist
> zugleich der Teil, der die spätere Migration auf Proxmox unverändert
> übersteht.

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

> ⚠️ **Die DNS-Server müssen auf die Domain Controller zeigen.** Der
> Firstboot-Dienst findet die Domain über die SRV-Records
> `_ldap._tcp.int.vitabrevis.ch`. Zeigt DNS woanders hin, schlägt der Join
> fehl und die VM bleibt ungejoint.

> **Hinweis:** Die Customization Spec kann als Vorlage gespeichert und beim Klonen pro VM angepasst werden. Unter *Customize this virtual machine's hardware → Network* lässt sich die IP pro Klon individuell überschreiben.

**Alternativ: DHCP beibehalten** — Wenn der Server seine IP per DHCP erhalten soll, einfach bei NIC 1 *DHCP* auswählen. Die Fallback-Config aus Part 6 greift dann automatisch.

### Schritt 18b — Klon-Vorgang in vCenter durchführen

1. **Rechtsklick auf Template → New VM from This Template**
2. VM-Name eingeben (wird als Hostname übernommen, z.B. `srv-nextcloud-01`)
3. Datastore und Cluster auswählen
4. **Customize operating system** → Gespeicherte Customization Spec auswählen
5. IP-Adresse für diesen spezifischen Klon anpassen (falls statisch)
6. Zusammenfassung prüfen → **Finish**
7. VM einschalten

Danach ist nichts mehr zu tun. Der erste Boot dauert etwas länger als üblich,
weil der Firstboot-Dienst auf cloud-init, Netzwerk und Domain Controller
wartet.

> ⚠️ **Die Customization Spec ist Pflicht.** Ohne sie behält der Klon den
> Hostname des Templates. Der Firstboot-Dienst erkennt das und joint bewusst
> nicht — sonst entstünde ein Computerobjekt mit Template-Namen im AD.

### Schritt 18c — Login-Daten

| Zugang          | Konto                          | Passwort                                  |
|-----------------|--------------------------------|-------------------------------------------|
| **Regulär**     | `<user>@int.vitabrevis.ch`     | AD-Passwort                               |
| **Break-Glass** | `localadmin`                   | Beim Versiegeln vergeben (Passwortmanager) |

Sudo-Rechte hat die AD-Gruppe `G_server-admin` sowie `localadmin`.

### Was beim ersten Boot abläuft

| Phase                   | Was passiert                                               |
|-------------------------|------------------------------------------------------------|
| cloud-init `local`      | Hostname & Machine-ID werden gesetzt (aus Customization)   |
| cloud-init `network`    | IP-Konfiguration angewendet, SSH Host Keys erstellt        |
| cloud-init `final`      | Abschluss, danach startet `vb-firstboot.service`           |
| `vb-firstboot` 1–2      | Wartet auf cloud-init, prüft den Hostname                  |
| `vb-firstboot` 3–5      | Beschreibung setzen, Credentials lesen, auf DC warten      |
| `vb-firstboot` 6–8      | `realm join`, SSSD starten, Secret vernichten, Marker      |

### Schritt 19 — Ergebnis prüfen

Ein einziger Aufruf zeigt den kompletten Zustand:
```bash
sudo ./post-clone.sh --status
```

Ausgegeben werden Hostname, Firstboot-Marker, Join-Status, SSSD-Status, die
Auflösung der AD-Admin-Gruppe und die letzten Zeilen des Firstboot-Logs.

Einzeln nachsehen:
```bash
# Firstboot
sudo cat /var/log/vb-firstboot.log
sudo journalctl -u vb-firstboot -n 50
cat /var/lib/vb-template/firstboot.done

# cloud-init
sudo cloud-init status --wait
sudo cloud-init analyze show

# Hostname & Netzwerk
hostname -f
ip addr show
cat /etc/netplan/*.yaml

# Domain
realm list
sudo klist -k /etc/krb5.keytab
getent group G_server-admin@int.vitabrevis.ch
```

### Schritt 20 — AD-Authentifizierung testen

Optional, wenn ein Testkonto zur Hand ist:
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

### Schritt 21 — Wenn der Firstboot fehlgeschlagen ist

Der Marker `/var/lib/vb-template/firstboot.done` wird nur nach einem
erfolgreichen Lauf gesetzt. Fehlt er, versucht es der Dienst beim nächsten
Boot erneut — oder man holt es sofort nach:
```bash
# Status ansehen und den Join nachholen
sudo ./post-clone.sh

# Join in jedem Fall wiederholen (z.B. nach Umbenennung der VM)
sudo ./post-clone.sh --force
```

`post-clone.sh --force` ruft intern `vb-firstboot.sh --force` auf. Weil das
Join-Secret nach dem ersten erfolgreichen Join auf dem Klon vernichtet wird,
fragt es das Passwort des Join-Accounts dann einmalig ab.

Ist das Template ohne Firstboot-Automatik gebaut worden, bleibt der manuelle
Weg:
```bash
sudo ./domain-join.sh
```

### Schritt 22 — Break-Glass-Passwort pro VM ändern

Standardmässig gilt auf allen Klonen dasselbe Break-Glass-Passwort aus dem
Template. Wo ein individuelles gewünscht ist:
```bash
sudo ./post-clone.sh --password
```

---

### Troubleshooting

**Firstboot / Zero-Touch**

| Symptom                                   | Ursache                                      | Lösung                                                        |
|-------------------------------------------|----------------------------------------------|---------------------------------------------------------------|
| VM ist nicht gejoint, Marker fehlt         | Firstboot-Lauf fehlgeschlagen                | `sudo cat /var/log/vb-firstboot.log`, dann `sudo ./post-clone.sh --force` |
| Log: „Hostname ist noch der Template-Hostname" | Klon ohne Customization Spec deployt      | Klon mit Spec neu deployen, oder Hostname setzen und `--force`  |
| Log: „Keine Default-Route"                 | Netzwerk kam nicht hoch                      | Netplan-Fallback und Portgruppe prüfen                          |
| Log: „Domain nicht erreichbar"             | DNS zeigt nicht auf die DCs                  | `nslookup _ldap._tcp.int.vitabrevis.ch`, DNS in der Spec korrigieren |
| Join-Fehler „Insufficient permissions"     | Join-Account hat zu wenig Delegation         | Rechte auf der Computer-OU prüfen (Part 6c, Schritt 12d)       |
| Firstboot lief gar nicht                   | Marker war beim Versiegeln noch da           | Im Template `rm /var/lib/vb-template/firstboot.done`, neu versiegeln |
| `join.secret` fehlt auf dem Klon           | Normal nach erfolgreichem Join               | Für einen erneuten Join fragt `post-clone.sh --force` das Passwort ab |
| Kein Auto-Join, obwohl gewünscht           | Beim Bau kein Join-Passwort angegeben        | `ENABLE_JOIN` in `/etc/vb-template/firstboot.conf` prüfen, Secret nachtragen |

**System & Active Directory**

| Symptom                          | Ursache                             | Lösung                                          |
|----------------------------------|-------------------------------------|-------------------------------------------------|
| Boot hängt bei networkd          | Kein Netzwerk-Interface online      | Part 6 Schritte 11+12 nachholen                 |
| Keine Netzwerkverbindung         | Netplan-Config fehlt                | `99-fallback-dhcp.yaml` vorhanden?              |
| Hostname ist noch der alte       | Customization Spec nicht ausgewählt | Klon erneut mit Spec deployen                   |
| IP-Adresse stimmt nicht          | DHCP überschreibt statische Config  | Fallback-Config Priorität prüfen (99 vs 50)     |
| `localadmin` Login verweigert    | Passwort nicht gesetzt / User locked | Wurde `seal-template.sh` ausgeführt? Es vergibt das Passwort |
| `id: user not found`            | SSSD läuft nicht / falsche Domain   | `systemctl restart sssd; realm list`            |
| SSSD crashed: `krb5.keytab not found` | SSSD enabled vor Domain Join   | `systemctl disable sssd`, erst nach `realm join` aktivieren |
| `Already joined` + keytab fehlt  | Veraltete Realm-Mitgliedschaft vom Template | `realm leave`, `rm /etc/krb5.keytab`, dann neu joinen |
| `realm join`: Insufficient permissions | Join-Account hat zu wenig Rechte | Delegation auf OU: Write All Properties auf Computer Objects |
| `kinit`: KDC reply did not match | `[domain_realm]` fehlt oder falsch  | MIT-Defaults ersetzen, `dns_canonicalize_hostname = false` setzen |
| Kerberos Auth schlägt fehl       | Clock Skew > 5 Minuten             | `sudo ntpdate -u <DC-IP>; timedatectl`          |
| AD-User: not in sudoers file     | Gruppenname mit `@` nicht gequotet | `"%G_server-admin@int.vitabrevis.ch"` (in Anführungszeichen) verwenden |
| `visudo`: illegal escape sequence | `\@`-Escape von altem sudo entfernt | Backslash weg, Gruppenname stattdessen quoten: `"%grp@domain"` |
| Sudoers-Änderung greift nicht    | SSSD cached Gruppenmitgliedschaft  | `rm -rf /var/lib/sss/db/*`, SSSD restart, neu einloggen |
| Login verweigert                 | User nicht in erlaubter Gruppe      | `ad_access_filter` oder `AllowGroups` prüfen    |
| Home-Verzeichnis fehlt           | pam_mkhomedir nicht aktiv           | `pam-auth-update --enable mkhomedir`            |
| Offline-Login schlägt fehl       | `cache_credentials = False`         | `cache_credentials = True` in sssd.conf setzen  |

---

## Part 9 — Template aktualisieren

Ein Template will regelmässig gepatcht werden. Der Ablauf:

1. In vCenter: **Rechtsklick auf das Template → Convert to Virtual Machine**
2. VM einschalten und als `localadmin` anmelden

   Die Wartungs-VM behält den Hostname des Templates. `vb-firstboot.service`
   erkennt das und joint bewusst **nicht** — siehe
   [Part 6c](#der-hostname-schutz). Es ist also nichts abzuschalten.

3. Updates einspielen und Änderungen vornehmen:
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```
4. Versiegeln — hier wird auch das Break-Glass-Passwort neu vergeben und die
   Firstboot-Automatik wieder scharf geschaltet:
   ```bash
   cd ~/ubuntu-templating && git pull
   sudo ./seal-template.sh
   ```
5. Herunterfahren (**nicht** neu starten) und zurück konvertieren:
   ```bash
   sudo shutdown -h now
   ```
   Dann: **Rechtsklick auf VM → Template → Convert to Template**

### Was dabei rotiert werden sollte

| Secret                        | Wo                                         | Wann                       |
|-------------------------------|---------------------------------------------|----------------------------|
| Break-Glass-Passwort          | Abfrage von `seal-template.sh`              | Bei jedem Template-Rebuild |
| Passwort des Join-Accounts    | `/etc/vb-template/join.secret`              | Bei jedem Template-Rebuild |
| SNMP Community                | Abfrage von `prepare-template.sh`           | Nach Bedarf                |

Das Join-Secret nachträglich ersetzen, ohne `prepare-template.sh` erneut
laufen zu lassen:
```bash
printf '%s' '<neues-passwort>' | sudo tee /etc/vb-template/join.secret >/dev/null
sudo chmod 600 /etc/vb-template/join.secret
sudo chown root:root /etc/vb-template/join.secret
```

> **Hinweis:** Die Scripts liegen im Repository, nicht im Template. Vor dem
> Versiegeln das Repo auf der Wartungs-VM aktualisieren, damit die aktuelle
> Version von `firstboot.sh` installiert wird.
