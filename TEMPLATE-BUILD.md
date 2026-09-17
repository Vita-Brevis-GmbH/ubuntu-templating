# Ubuntu Template bauen und ausrollen

*Arbeitsanleitung · Ubuntu 26.04.1 LTS · VMware vSphere · Vita Brevis*

Diese Anleitung beschreibt den kompletten Weg vom leeren ISO bis zur
fertig gejointen VM — ausschliesslich über die Scripts aus dem Repository
[`ubuntu-templating`](https://github.com/Vita-Brevis-GmbH/ubuntu-templating).
Sie ersetzt den manuellen Weg. Konfigurationsdetails und Hintergründe stehen
im README des Repos.

Zeitbedarf beim ersten Mal: rund 90 Minuten. Bei einem Template-Update: rund
20 Minuten.

> **Ubuntu 26.04 statt 24.04.** Die Scripts laufen auf beiden Releases. In
> 26.04 ist `sudo-rs` der Standard statt sudo 1.9, und die Basiswerkzeuge
> kommen von uutils statt von GNU. Praktisch betrifft das nur eine Stelle:
> Gruppennamen in `sudoers`-Dateien dürfen **nicht** in Anführungszeichen
> stehen. Die Scripts schreiben das korrekt, wer von Hand nachträgt, muss es
> wissen. Details im README unter Part 10.

---

## Inhalt

| Teil | Thema | Wann |
|------|-------|------|
| [0](#teil-0--voraussetzungen) | Voraussetzungen | Einmalig, vor dem ersten Template |
| [1](#teil-1--basis-vm-installieren) | Basis-VM installieren | Je Template-Bau |
| [2](#teil-2--template-vorbereiten) | `prepare-template.sh` | Je Template-Bau |
| [3](#teil-3--kontrolle-vor-dem-versiegeln) | Kontrolle | Je Template-Bau |
| [4](#teil-4--versiegeln) | `seal-template.sh` | Je Template-Bau |
| [5](#teil-5--zum-template-konvertieren) | Convert to Template | Je Template-Bau |
| [6](#teil-6--customization-spec-anlegen) | Customization Spec | Einmalig |
| [7](#teil-7--vm-ausrollen) | VM ausrollen | Je neue VM |
| [8](#teil-8--template-aktualisieren) | Template aktualisieren | Alle paar Monate |

Anhänge: [Dateien im Template](#anhang-a--dateien-im-template) ·
[Troubleshooting](#anhang-b--troubleshooting) ·
[Secrets](#anhang-c--secrets-und-rotation)

---

## Was am Ende automatisch läuft

Nach dem Klonen einer VM ist **nichts** von Hand nachzukonfigurieren. Zwei
Mechanismen teilen sich die Arbeit:

| Quelle | Liefert |
|--------|---------|
| vCenter Guest OS Customization | Hostname, IP, Gateway, DNS |
| `vb-firstboot.service` im Gast | Domain Join, SSSD, Server-Beschreibung |

Der zweite Teil liegt komplett im Gastbetriebssystem. Er funktioniert deshalb
unabhängig davon, was der Hypervisor an Daten durchreicht — und gilt nach der
Migration auf Proxmox unverändert weiter.

---

## Teil 0 — Voraussetzungen

Einmalig zu erledigen, bevor das erste Template gebaut wird.

### 0.1 Join-Account im Active Directory

Jeder Klon joint sich selbst. Dafür braucht es ein dediziertes Dienstkonto.
Es braucht **keine** Domain-Admin-Rechte.

1. Benutzer anlegen, zum Beispiel `svc-domainjoin`
2. Passwort läuft nicht ab, Benutzer kann Passwort nicht ändern
3. OU für die Linux-Computerobjekte anlegen, zum Beispiel
   `OU=Linux,OU=Server,DC=int,DC=vitabrevis,DC=ch`
4. In *Active Directory Users and Computers*: Rechtsklick auf die OU →
   **Delegate Control** → Konto wählen → *Create a custom task to delegate* →
   *Only the following objects in the folder* → **Computer objects** plus
   *Create selected objects in this folder* und *Delete selected objects in
   this folder*

Zu delegierende Rechte:

| Recht | Objekttyp |
|-------|-----------|
| Create Computer Objects | OU |
| Delete Computer Objects | OU |
| Write All Properties | Computer Objects |
| Reset Password | Computer Objects |

> Das Konto nicht für andere Zwecke verwenden. Sein Passwort liegt im Template.

### 0.2 Admin-Gruppe im Active Directory

Die Gruppe, deren Mitglieder sich auf den Linux-Servern anmelden und `sudo`
benutzen dürfen. Standard: `G_server-admin`. Die Gruppe muss existieren, bevor
der erste Klon gebaut wird, sonst schlägt die Verifikation fehl.

### 0.3 DNS

Die Domain Controller müssen als DNS-Server erreichbar sein und die
SRV-Records der Domain ausliefern. Vom Netz der künftigen Server aus prüfen:

```bash
nslookup -type=SRV _ldap._tcp.int.vitabrevis.ch
```

Kommt hier keine Antwort, schlägt der automatische Join später fehl.

### 0.4 Werte sammeln

Diese Werte fragt `prepare-template.sh` ab. Vorher zusammentragen:

| Wert | Beispiel |
|------|----------|
| AD Domain (FQDN) | `int.vitabrevis.ch` |
| Kerberos Realm | `INT.VITABREVIS.CH` |
| Primärer KDC | `dcs01-000-vb.int.vitabrevis.ch` |
| Sekundärer KDC | `dcs02-000-vb.int.vitabrevis.ch` |
| AD Admin-Gruppe | `G_server-admin` |
| Lokaler Break-Glass-User | `localadmin` |
| AD Join-Account | `svc-domainjoin` |
| Passwort des Join-Accounts | aus dem Passwortmanager |
| Computer-OU als DN | `OU=Linux,OU=Server,DC=int,DC=vitabrevis,DC=ch` |
| SNMPv2c Community | aus dem Passwortmanager |
| Break-Glass-Passwort | neu vergeben, siehe [Teil 4](#teil-4--versiegeln) |

---

## Teil 1 — Basis-VM installieren

### 1.1 VM in vCenter anlegen

| Einstellung | Empfehlung |
|-------------|------------|
| Guest OS | Ubuntu Linux (64-bit) |
| vCPU | 2 |
| RAM | 4 GB |
| Disk | 40 GB, Thin Provision |
| Netzwerk | Portgruppe mit Sicht auf die Domain Controller |
| VM-Name | sprechend und eindeutig, zum Beispiel `ubuntu-2604-tpl` |

> **Der VM-Name wird zum Hostnamen und damit zum Schutzmechanismus.** Der
> Firstboot-Dienst vergleicht den Hostnamen eines Klons mit dem des Templates.
> Sind sie gleich, wird nicht gejoint. Ein Name, den nie eine produktive VM
> tragen wird, ist deshalb Absicht.

### 1.2 Ubuntu installieren

Ubuntu Server 26.04.1 LTS, minimale Installation, kein Desktop.

| Schritt | Auswahl |
|---------|---------|
| Installationstyp | Ubuntu Server (minimized) |
| Partitionierung | Ganze Disk, LVM |
| Profil / Benutzer | Ein temporärer Admin-Benutzer, beliebiger Name |
| OpenSSH Server | installieren |
| Snaps | keine |

> Der temporäre Benutzer wird beim Versiegeln gelöscht. Er dient nur dazu,
> die Scripts auszuführen. `localadmin` wird von den Scripts angelegt.

### 1.3 Hostnamen setzen

Falls der Installer einen anderen Namen gesetzt hat:

```bash
sudo hostnamectl set-hostname ubuntu-2604-tpl
```

---

## Teil 2 — Template vorbereiten

### 2.1 Repository klonen

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/Vita-Brevis-GmbH/ubuntu-templating.git
cd ubuntu-templating
```

> Das komplette Repository wird gebraucht, nicht nur ein einzelnes Script.
> `prepare-template.sh` installiert `firstboot.sh` und `vb-firstboot.service`
> aus demselben Verzeichnis und bricht ab, wenn sie fehlen.

### 2.2 Vorbereitung ausführen

```bash
sudo ./prepare-template.sh
```

Das Script fragt der Reihe nach ab. Enter übernimmt den Wert in Klammern:

| Nr. | Abfrage | Hinweis |
|-----|---------|---------|
| 1 | AD Domain (FQDN) | |
| 2 | Kerberos Realm | Wird aus der Domain abgeleitet |
| 3 | Primärer KDC (FQDN) | |
| 4 | Sekundärer KDC (FQDN) | Leer lassen, wenn es nur einen gibt |
| 5 | AD Admin-Gruppe | Bekommt `sudo` und SSH-Zugang |
| 6 | Default lokaler Admin-User | Break-Glass-Konto, Standard `localadmin` |
| 7 | Server-Beschreibung | Platzhalter, Klone überschreiben ihn |
| 8 | AD Join-Account | Aus Schritt 0.1 |
| 9 | Computer-OU als DN | Leer = Standardcontainer `CN=Computers` |
| 10 | Passwort des Join-Accounts | Zweimal, ohne Echo. **Leer = kein Auto-Join** |
| 11 | SNMPv2c Community | Darf nicht leer sein |
| 12 | SNMP sysLocation | |
| 13 | SNMP sysContact | |

Danach zeigt das Script eine Zusammenfassung und fragt nach der Bestätigung.
Der Lauf dauert einige Minuten, weil er das System aktualisiert.

Unbeaufsichtigt lässt sich das Join-Passwort auch über die Umgebung setzen:

```bash
sudo VB_JOIN_PASSWORD='…' ./prepare-template.sh
```

### 2.3 Was dabei eingerichtet wird

| Schritt | Inhalt |
|---------|--------|
| 1 | Systemupdate, Basispakete, `open-vm-tools`, Break-Glass-User anlegen |
| 2 | cloud-init mit VMware-Datasource |
| 3 | systemd-Service, der fehlende SSH Host Keys vor `sshd` erzeugt |
| 4 | SSH-Hardening als Drop-in unter `/etc/ssh/sshd_config.d/` |
| 5 | MOTD-Banner und `/etc/server-description` |
| 6 | SSSD, Kerberos, `sudoers.d`, `pam_mkhomedir` — vorkonfiguriert, nicht gejoint |
| 7 | Netplan-Fallback auf DHCP, `networkd-wait-online` maskiert |
| 8 | SNMP (SNMPv2c, read-only) |
| 9 | Firstboot-Automatik: Script, systemd-Unit, Konfiguration, Join-Secret |

---

## Teil 3 — Kontrolle vor dem Versiegeln

Diese Prüfungen dauern zwei Minuten und ersparen einen zweiten Anlauf.

```bash
# Firstboot-Automatik installiert und aktiviert?
systemctl is-enabled vb-firstboot.service        # → enabled
sudo ls -l /etc/vb-template/                     # firstboot.conf + join.secret, beide 0600

# Auto-Join aktiv?
sudo grep ENABLE_JOIN /etc/vb-template/firstboot.conf   # → "yes"

# SSSD darf NICHT laufen und NICHT enabled sein
systemctl is-enabled sssd                        # → disabled
ls /etc/krb5.keytab 2>/dev/null                  # → darf nicht existieren

# SSH-Konfiguration gültig?
sudo sshd -t && echo OK

# Sudo-Regel für die AD-Gruppe gültig? (auf 26.04 prüft das sudo-rs)
sudo visudo -c -f /etc/sudoers.d/ad-admins
cat /etc/sudoers.d/ad-admins      # Gruppenname ohne Anführungszeichen

# Netzwerk-Fallback vorhanden?
ls -l /etc/netplan/99-fallback-dhcp.yaml

# SNMP antwortet lokal?
snmpget -v 2c -c <community> 127.0.0.1 .1.3.6.1.2.1.1.1.0
```

Zusätzlich vom Monitoring-Host aus:

```bash
snmpwalk -v 2c -c <community> <template-ip> .1.3.6.1.2.1.1
```

> **Warum numerische OIDs?** Die textuellen MIB-Dateien stecken in
> `snmp-mibs-downloader` aus dem multiverse-Repository und fehlen auf einem
> Standard-Ubuntu. Mit `sysDescr.0` antwortet `snmpget` dann *Unknown Object
> Identifier*, obwohl snmpd einwandfrei läuft. Numerische OIDs brauchen
> keine MIBs.

---

## Teil 4 — Versiegeln

Das Versiegeln entfernt alle instanzspezifischen Daten, vergibt das
Break-Glass-Passwort und schaltet die Firstboot-Automatik scharf.

### 4.1 Break-Glass-Passwort vorbereiten

Ein neues, starkes Passwort erzeugen und **vorher** im Passwortmanager
ablegen. Es gilt auf allen Klonen dieses Templates.

```bash
# Vorschlag erzeugen
openssl rand -base64 18
```

### 4.2 Versiegeln ausführen

```bash
cd ~/ubuntu-templating
sudo ./seal-template.sh
```

Das Script fragt das Passwort zweimal ab, ohne Echo. Unbeaufsichtigt geht auch:

```bash
sudo VB_LOCAL_ADMIN_PASSWORD='…' ./seal-template.sh
```

Es läuft dann durch vierzehn Schritte und meldet am Schluss eine
Abschlussprüfung. Warnungen dort ernst nehmen.

> ⚠️ Der eigene Benutzer aus [Teil 1.2](#12-ubuntu-installieren) wird in
> Schritt 5 gelöscht. Die laufende SSH-Sitzung bleibt bestehen, ein neuer
> Login funktioniert danach nur noch als `localadmin`.

### 4.3 Kontrolle

```bash
# Marker muss weg sein, sonst überspringt jeder Klon den Join
ls /var/lib/vb-template/firstboot.done       # → No such file

# Template-Hostname wurde festgehalten
sudo grep TEMPLATE_HOSTNAME /etc/vb-template/firstboot.conf

# Join-Secret ist noch da
sudo ls -l /etc/vb-template/join.secret      # → -rw------- root root

# Keine SSH Host Keys, keine Machine-ID
ls /etc/ssh/ssh_host_* 2>/dev/null           # → No such file
cat /etc/machine-id                          # → leer
```

### 4.4 Herunterfahren

```bash
sudo shutdown -h now
```

> ⚠️ **Nur herunterfahren, nicht neu starten.** Ein Reboot erzeugt Machine-ID
> und SSH Host Keys sofort wieder und stösst den Firstboot-Lauf an.

---

## Teil 5 — Zum Template konvertieren

In vCenter:

```
Rechtsklick auf die VM → Template → Convert to Template
```

Das Template sinnvoll benennen und ablegen, zum Beispiel
`ubuntu-2604-tpl-2026-09` in einem Ordner `Templates`.

---

## Teil 6 — Customization Spec anlegen

Einmalig. Die Spec setzt Hostname und Netzwerk und ist beim Klonen **Pflicht**.

**Menu → Policies and Profiles → VM Customization Specifications → New**

| Feld | Wert |
|------|------|
| Target guest OS | Linux |
| Computer name | **Use the virtual machine name** |
| Domain name | `int.vitabrevis.ch` |
| Time zone | Europe/Zurich |
| Network | Manuell oder DHCP, je nach Standard |
| DNS-Server | Die Domain Controller |
| DNS-Suchdomain | `int.vitabrevis.ch` |

> ⚠️ **Die DNS-Server müssen auf die Domain Controller zeigen.** Der
> Firstboot-Dienst findet die Domain über deren SRV-Records. Zeigt DNS
> woanders hin, bleibt die VM ungejoint.

Bei statischen IP-Adressen: *Prompt the user for an address* wählen. Dann
fragt der Klon-Assistent die IP je VM ab, und eine Spec reicht für alle
Server.

---

## Teil 7 — VM ausrollen

### 7.1 Klonen

1. Rechtsklick auf das Template → **New VM from This Template**
2. VM-Namen eingeben, zum Beispiel `srv-nextcloud-01` — daraus wird der Hostname
3. Ordner, Cluster und Datastore wählen
4. **Customize the operating system** ankreuzen und die Spec auswählen
5. IP-Adresse eingeben, falls die Spec danach fragt
6. Zusammenfassung prüfen → **Finish**
7. VM einschalten

Mehr ist nicht zu tun. Der erste Boot dauert länger als gewohnt, weil der
Firstboot-Dienst auf cloud-init, Netzwerk und Domain Controller wartet.

> ⚠️ **Ohne Customization Spec behält der Klon den Template-Hostnamen.** Der
> Firstboot-Dienst erkennt das und joint bewusst nicht. Die VM ist dann
> erreichbar, aber ohne AD. Richtig ist: löschen und neu klonen.

### 7.2 Optionale Werte je VM

Nur wenn nötig. Vor dem ersten Einschalten unter *VM bearbeiten → VM Options →
Advanced → Configuration Parameters → Add Configuration Params*:

| Parameter | Wirkung |
|-----------|---------|
| `guestinfo.vb.description` | Text für `/etc/server-description`, erscheint im MOTD |
| `guestinfo.vb.join` | `no` überspringt den Domain Join auf dieser VM |

Ohne diese Parameter trägt die Beschreibung den FQDN, und die VM joint normal.

### 7.3 Verifizieren

Anmelden als `<benutzer>@int.vitabrevis.ch` oder als `localadmin`, dann:

```bash
cd ~/ubuntu-templating 2>/dev/null || git clone https://github.com/Vita-Brevis-GmbH/ubuntu-templating.git ~/ubuntu-templating
sudo ~/ubuntu-templating/post-clone.sh --status
```

Das zeigt Hostname, Firstboot-Marker, Join-Status, SSSD-Status, die Auflösung
der AD-Admin-Gruppe und die letzten Zeilen des Firstboot-Logs.

Ohne das Repo geht es auch direkt:

```bash
sudo cat /var/lib/vb-template/firstboot.done
sudo cat /var/log/vb-firstboot.log
realm list
getent group G_server-admin@int.vitabrevis.ch
hostname -f
```

Erwartet: Marker vorhanden, `realm list` zeigt die Domain, die Gruppe löst auf.

### 7.4 Wenn der Join fehlgeschlagen ist

Der Marker wird nur nach einem erfolgreichen Lauf gesetzt. Fehlt er, versucht
es der Dienst beim nächsten Boot von selbst erneut. Sofort nachholen:

```bash
sudo ./post-clone.sh           # Status zeigen und Join nachholen
sudo ./post-clone.sh --force   # Join in jedem Fall wiederholen
```

Weil das Join-Secret nach dem ersten erfolgreichen Join auf dem Klon
vernichtet wird, fragt `--force` das Passwort des Join-Accounts einmalig ab.

### 7.5 Individuelles Break-Glass-Passwort

Standardmässig gilt auf allen Klonen dasselbe Passwort aus dem Template. Wo
ein eigenes gewünscht ist:

```bash
sudo ./post-clone.sh --password
```

---

## Teil 8 — Template aktualisieren

Alle paar Monate, damit neue VMs nicht mit hundert ausstehenden Updates starten.

1. In vCenter: **Rechtsklick auf das Template → Convert to Virtual Machine**
2. VM einschalten, als `localadmin` anmelden

   Die Wartungs-VM behält den Template-Hostnamen. Der Firstboot-Dienst
   erkennt das und joint nicht. Es ist nichts abzuschalten.

3. Aktualisieren:

   ```bash
   sudo apt update && sudo apt upgrade -y
   cd ~/ubuntu-templating && git pull
   ```

4. Bei Änderungen an den Scripts die Vorbereitung erneut laufen lassen,
   sonst direkt weiter zu Schritt 5:

   ```bash
   sudo ./prepare-template.sh
   ```

5. Versiegeln — hier werden Break-Glass-Passwort und Join-Secret neu gesetzt:

   ```bash
   sudo ./seal-template.sh
   ```

6. Herunterfahren und zurück konvertieren:

   ```bash
   sudo shutdown -h now
   ```

   Dann: **Rechtsklick auf die VM → Template → Convert to Template**

---

## Anhang A — Dateien im Template

| Pfad | Rechte | Inhalt |
|------|--------|--------|
| `/usr/local/sbin/vb-firstboot.sh` | `0755` | Firstboot-Script |
| `/etc/systemd/system/vb-firstboot.service` | `0644` | systemd-Unit |
| `/etc/vb-template/firstboot.conf` | `0600` | Domain, Realm, Join-Account, OU, Timeouts |
| `/etc/vb-template/join.secret` | `0600` | Passwort des Join-Accounts, ohne Zeilenumbruch |
| `/var/lib/vb-template/firstboot.done` | `0644` | Marker, erst nach erfolgreichem Lauf |
| `/var/log/vb-firstboot.log` | `0600` | Protokoll des Firstboot-Laufs |
| `/etc/ssh/sshd_config.d/99-vita-brevis.conf` | `0644` | SSH-Hardening |
| `/etc/netplan/99-fallback-dhcp.yaml` | `0600` | DHCP-Fallback |
| `/etc/server-description` | `0644` | Text im MOTD |

Ablauf des Firstboot-Laufs:

| Schritt | Aktion |
|---------|--------|
| 1 | Auf cloud-init warten |
| 2 | Hostname gegen `TEMPLATE_HOSTNAME` prüfen |
| 3 | `/etc/server-description` setzen |
| 4 | Join-Credentials lesen |
| 5 | Auf Default-Route, Domain Controller und Zeitsynchronisation warten |
| 6 | `realm leave`, Keytab löschen, `realm join`, notfalls `adcli join` |
| 7 | `sssd.conf` setzen, SSSD starten, AD-Gruppe auflösen |
| 8 | Join-Secret vernichten, Marker setzen |

---

## Anhang B — Troubleshooting

**Zuerst immer:**

```bash
sudo ./post-clone.sh --status
sudo cat /var/log/vb-firstboot.log
sudo journalctl -u vb-firstboot -n 50
```

| Symptom | Ursache | Lösung |
|---------|---------|--------|
| Log: „Hostname ist noch der Template-Hostname" | Klon ohne Customization Spec | VM löschen und mit Spec neu klonen |
| Log: „Keine Default-Route" | Netzwerk kam nicht hoch | Portgruppe und Netplan-Fallback prüfen |
| Log: „Domain nicht erreichbar" | DNS zeigt nicht auf die DCs | `nslookup -type=SRV _ldap._tcp.<domain>`, Spec korrigieren |
| Join: „Insufficient permissions" | Delegation zu eng | Rechte auf der Computer-OU prüfen, siehe Teil 0.1 |
| Join: „Already joined" und Keytab fehlt | Alte Mitgliedschaft aus dem Template | `realm leave`, `rm /etc/krb5.keytab`, dann `post-clone.sh --force` |
| Kerberos schlägt fehl | Zeitabweichung über fünf Minuten | `timedatectl`, NTP prüfen |
| Firstboot lief gar nicht | Marker war beim Versiegeln noch da | Im Template löschen, neu versiegeln |
| `join.secret` fehlt auf dem Klon | Normal nach erfolgreichem Join | `post-clone.sh --force` fragt das Passwort ab |
| Kein Auto-Join trotz Absicht | Beim Bau kein Passwort angegeben | `ENABLE_JOIN` in `firstboot.conf` prüfen, Secret nachtragen |
| AD-User fehlt `sudo` | Gruppenname falsch geschrieben | `/etc/sudoers.d/ad-admins` prüfen, unquotiert schreiben |
| `sudo` streikt nach Änderung an `sudoers.d` | Datei parst unter sudo-rs nicht | Aus Root-Shell entfernen, unquotiert neu schreiben, `visudo -c -f` |
| SSH verweigert AD-Login | Gruppe fehlt in `AllowGroups` | `/etc/ssh/sshd_config.d/99-vita-brevis.conf` prüfen |
| SNMP: `Unknown Object Identifier` | MIB-Dateien nicht installiert | Numerische OID verwenden |
| Boot hängt bei networkd | `networkd-wait-online` nicht maskiert | Siehe Teil 2.3, Schritt 7 |

---

## Anhang C — Secrets und Rotation

| Secret | Wo | Rotation |
|--------|-----|----------|
| Break-Glass-Passwort `localadmin` | Abfrage von `seal-template.sh` | Bei jedem Template-Bau |
| Passwort des Join-Accounts | `/etc/vb-template/join.secret` im Template | Bei jedem Template-Bau |
| SNMPv2c Community | Abfrage von `prepare-template.sh` | Nach Bedarf |

Alle drei gehören in den Passwortmanager und in **kein** Repository.

### Join-Secret nachträglich ersetzen

Ohne `prepare-template.sh` erneut laufen zu lassen:

```bash
printf '%s' '<neues-passwort>' | sudo tee /etc/vb-template/join.secret >/dev/null
sudo chmod 600 /etc/vb-template/join.secret
sudo chown root:root /etc/vb-template/join.secret
```

### Warum das Join-Secret im Template liegt

Der Klon muss sich ohne Zutun joinen können, also braucht er die Credentials
lokal. Drei Dinge begrenzen den Schaden:

- Der Account darf ausschliesslich Computerobjekte in einer OU verwalten.
- Nach erfolgreichem Join wird das Secret auf dem Klon mit `shred` vernichtet.
  Es existiert dann nur noch im Template.
- Es wird bei jedem Template-Bau rotiert.

Wer das nicht will, gibt bei der Vorbereitung kein Passwort an. Dann bleibt
der Auto-Join deaktiviert und die Klone werden mit `post-clone.sh --force`
oder `domain-join.sh` von Hand gejoint.

---

## Schnellreferenz

```bash
# Template bauen
git clone https://github.com/Vita-Brevis-GmbH/ubuntu-templating.git
cd ubuntu-templating
sudo ./prepare-template.sh
sudo ./seal-template.sh
sudo shutdown -h now

# Auf einem Klon
sudo ./post-clone.sh --status      # Zustand anzeigen
sudo ./post-clone.sh               # Join nachholen, falls nötig
sudo ./post-clone.sh --force       # Join wiederholen
sudo ./post-clone.sh --password    # Break-Glass-Passwort ändern

# Ohne Template-Automatik, beliebiges Ubuntu-System
sudo ./domain-join.sh
```
