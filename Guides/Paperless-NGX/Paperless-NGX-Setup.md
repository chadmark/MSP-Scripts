# Paperless-NGX Complete Setup Guide
### With Paperless-AI, Tika, Gotenberg, SMB Share, and Active Directory Integration

**Author:** Chad Mark  
**GitHub:** https://github.com/chadmark/MSP-Scripts/blob/main/Guides/Paperless-NGX-Setup.md  
**Environment:** Ubuntu VM, Docker, Windows Network with Active Directory  
**Last Updated:** 2026-03-26  
**Version:** 1.1

---

## Table of Contents

1. [Overview](#overview)
2. [Stack Components](#stack-components)
3. [Prerequisites](#prerequisites)
4. [Directory Structure](#directory-structure)
5. [Generate Secret Values](#generate-secret-values)
6. [Docker Compose File](#docker-compose-file)
7. [Deploy the Stack](#deploy-the-stack)
8. [Create Admin Account](#create-admin-account)
9. [Configure Paperless-AI](#configure-paperless-ai)
10. [Configure Paperless Structure](#configure-paperless-structure)
11. [SMB Share Setup](#smb-share-setup)
12. [Active Directory Integration](#active-directory-integration)
13. [Document Ingestion](#document-ingestion)
14. [AI Token Usage and Cost](#ai-token-usage-and-cost)
15. [Troubleshooting](#troubleshooting)
16. [Appendix — Quick Command Reference](#appendix--quick-command-reference)

---

## Overview

This guide documents the deployment of a self-hosted AI-powered document management system using Paperless-NGX, Paperless-AI, Tika, and Gotenberg on an Ubuntu virtual machine with Docker. The consume folder is exposed as an SMB share authenticated against Active Directory, allowing Windows users on the network to drop documents in for automatic ingestion, OCR, and AI categorization.

**The end result:**
- Drop files into a network share from any Windows machine
- Paperless automatically ingests, OCR's, and archives them
- Paperless-AI automatically applies titles, tags, correspondents, and document types using OpenAI
- Everything is searchable and organized in a web UI

---

## Stack Components

| Container | Purpose |
|---|---|
| `paperless-ngx` | Core document management — ingestion, OCR, storage, web UI |
| `postgres` | Database backend for Paperless |
| `redis` | Message queue/broker for Paperless tasks |
| `gotenberg` | Converts Office documents and HTML to PDF for processing |
| `tika` | Extracts text from complex file formats (Word, Excel, etc.) |
| `paperless-ai` | AI layer — uses OpenAI to tag, classify, and title documents |

---

## Prerequisites

- Ubuntu VM (22.04 or 24.04 LTS recommended)
- Docker and Docker Compose already installed and working
- VM has a static IP on your network
- Active Directory domain (optional — required for AD-authenticated SMB)
- OpenAI API key (for Paperless-AI)
- VM DNS pointing to your Domain Controller (required for AD join)

---

## Directory Structure

Create all required directories before deploying:

```bash
sudo mkdir -p /opt/paperless/{postgres,redis,data,media,consume,export}
sudo mkdir -p /opt/paperless-ai/data
sudo chown -R $(id -u):$(id -g) /opt/paperless /opt/paperless-ai
```

**What each directory is for:**

| Path | Purpose |
|---|---|
| `/opt/paperless/postgres` | PostgreSQL data files |
| `/opt/paperless/redis` | Redis persistence data |
| `/opt/paperless/data` | Paperless internal app data |
| `/opt/paperless/media` | Document archive — your permanent document storage |
| `/opt/paperless/consume` | Inbox — files dropped here are ingested then deleted |
| `/opt/paperless/export` | Export output directory |
| `/opt/paperless-ai/data` | Paperless-AI app data |

> **Important:** The consume directory is an inbox, not storage. Paperless deletes files from it after successful ingestion. Always keep your source copies elsewhere before importing.

After creating directories, set open permissions on the consume folder so AD users and the container can both read/write:

```bash
sudo chmod 1777 /opt/paperless/consume
```

---

## Generate Secret Values

Generate both secrets before editing the compose file:

```bash
openssl rand -hex 32        # → PAPERLESS_SECRET_KEY
openssl rand -base64 24     # → POSTGRES_PASSWORD and PAPERLESS_DBPASS
```

**Which key goes where:**

| Secret | Variable | Format | Reason |
|---|---|---|---|
| `openssl rand -hex 32` | `PAPERLESS_SECRET_KEY` | 64-char hex string | Django's cryptographic secret key |
| `openssl rand -base64 24` | `POSTGRES_PASSWORD` and `PAPERLESS_DBPASS` | Shorter alphanumeric | Database password — must match exactly in both places |

> **Note:** `POSTGRES_PASSWORD` and `PAPERLESS_DBPASS` must be identical. A mismatch causes a password authentication failure on startup.

---

## Docker Compose File

Create the compose file:

```bash
mkdir -p ~/paperless
nano ~/paperless/docker-compose.yml
```

Paste the following, replacing all placeholder values:

```yaml
services:
  postgres:
    image: postgres:16
    container_name: paperless-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: paperless
      POSTGRES_USER: paperless
      POSTGRES_PASSWORD: YOUR_GENERATED_POSTGRES_PASSWORD
      TZ: America/Los_Angeles
    volumes:
      - /opt/paperless/postgres:/var/lib/postgresql/data
    networks:
      - paperless_net

  redis:
    image: redis:7
    container_name: paperless-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - /opt/paperless/redis:/data
    networks:
      - paperless_net

  gotenberg:
    image: gotenberg/gotenberg:8
    container_name: paperless-gotenberg
    restart: unless-stopped
    command:
      - gotenberg
      - --chromium-disable-javascript=true
      - --chromium-allow-list=file:///tmp/.*
    networks:
      - paperless_net

  tika:
    image: apache/tika:latest
    container_name: paperless-tika
    restart: unless-stopped
    networks:
      - paperless_net

  paperless:
    image: ghcr.io/paperless-ngx/paperless-ngx:latest
    container_name: paperless
    restart: unless-stopped
    depends_on:
      - postgres
      - redis
      - gotenberg
      - tika
    ports:
      - "8000:8000"
    environment:
      USERMAP_UID: 1000   # verify with: id -u
      USERMAP_GID: 1000   # verify with: id -g
      TZ: America/Los_Angeles

      PAPERLESS_REDIS: redis://redis:6379
      PAPERLESS_DBHOST: postgres
      PAPERLESS_DBNAME: paperless
      PAPERLESS_DBUSER: paperless
      PAPERLESS_DBPASS: YOUR_GENERATED_POSTGRES_PASSWORD

      PAPERLESS_URL: http://YOUR_VM_IP:8000
      PAPERLESS_SECRET_KEY: YOUR_GENERATED_SECRET_KEY

      PAPERLESS_TIME_ZONE: America/Los_Angeles
      PAPERLESS_OCR_LANGUAGE: eng
      PAPERLESS_CONSUMER_POLLING: 60
      PAPERLESS_CONSUMER_RECURSIVE: 1
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS: 1
      PAPERLESS_UMASK: 0002

      PAPERLESS_TIKA_ENABLED: 1
      PAPERLESS_TIKA_ENDPOINT: http://tika:9998
      PAPERLESS_TIKA_GOTENBERG_ENDPOINT: http://gotenberg:3000

      PAPERLESS_CONSUMPTION_DIR: /usr/src/paperless/consume
    volumes:
      - /opt/paperless/data:/usr/src/paperless/data
      - /opt/paperless/media:/usr/src/paperless/media
      - /opt/paperless/consume:/usr/src/paperless/consume
      - /opt/paperless/export:/usr/src/paperless/export
    networks:
      - paperless_net

  paperless-ai:
    image: clusterzx/paperless-ai:latest
    container_name: paperless-ai
    restart: unless-stopped
    depends_on:
      - paperless
    ports:
      - "8001:3000"
    environment:
      PUID: 1000
      PGID: 1000
      TZ: America/Los_Angeles
    volumes:
      - /opt/paperless-ai/data:/app/data
    networks:
      - paperless_net

networks:
  paperless_net:
    driver: bridge
```

**Key environment variables explained:**

| Variable | Purpose |
|---|---|
| `USERMAP_UID/GID` | Maps container file operations to your Ubuntu user — run `id` to verify |
| `PAPERLESS_CONSUMER_POLLING` | How often (seconds) to check consume folder for new files |
| `PAPERLESS_CONSUMER_RECURSIVE` | Enables watching subdirectories inside consume |
| `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS` | Automatically applies subfolder name as a tag to ingested documents |
| `PAPERLESS_UMASK` | Ensures files created by the container are group-writable — prevents permission errors with AD-created subdirectories |
| `PAPERLESS_TIKA_ENABLED` | Enables Tika for complex file format support |

---

## Deploy the Stack

```bash
cd ~/paperless
docker compose config       # validate syntax
docker compose pull         # pull all images
docker compose up -d        # start the stack
```

Monitor startup:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

Wait until both `paperless` and `paperless-ai` show **healthy** before proceeding. Tika may take a minute or two on first start.

---

## Create Admin Account

Once the stack is healthy:

```bash
docker exec -it paperless python3 manage.py createsuperuser
```

Enter username, email, and password when prompted. This is your Paperless login.

**Open the web interfaces:**
- Paperless-NGX: `http://YOUR_VM_IP:8000`
- Paperless-AI: `http://YOUR_VM_IP:8001`

---

## Configure Paperless-AI

### Step 1 — Get your API token

In Paperless-NGX: click your username (top right) → **My Profile** → create/reveal **API Token** → copy it.

### Step 2 — Connect Paperless-AI to Paperless

In the Paperless-AI setup screen:

| Field | Value |
|---|---|
| Paperless-NGX API URL | `http://paperless:8000` |
| Paperless-NGX Username | your superuser username |
| API Token | token from above |

> **Important:** Use the container name `paperless` — not `localhost` or the VM IP. Inside Docker, `localhost` refers to the container itself, not Paperless.

### Step 3 — AI Model Settings

In Paperless-AI → AI Settings:

| Setting | Value |
|---|---|
| Provider | OpenAI |
| API Key | your OpenAI API key |
| Model | gpt-4o-mini |
| Temperature | low |

### Step 4 — Advanced Settings

| Setting | Value |
|---|---|
| Use existing Correspondents and Tags? | Yes |
| Scan Interval | `/5 *` |
| Process only specific pre-tagged documents? | No |
| Add AI-processed tag to documents? | Yes |
| Use specific tags in prompt? | No |
| Disable automatic processing? | No |

**Enable these functions:**

| Function | State |
|---|---|
| Tags Assignment | On |
| Correspondent Detection | On |
| Document Type Classification | On |
| Title Generation | On |
| Custom Fields | Off |

---

## Configure Paperless Structure

All of the following are created within the Paperless-NGX UI under **Settings** in the left sidebar.

### Document Types
What the document *is*. Examples:
- Invoice
- Receipt
- Contract
- Statement
- Letter
- Report

### Correspondents
Who the document *came from*. Use actual names:
- Vendor names
- Bank names
- Utilities
- Government agencies

**Bulk import via API** (faster than manual entry):

```bash
nano correspondents.txt   # one name per line
```

```bash
while IFS= read -r name; do
  curl -s -X POST http://YOUR_VM_IP:8000/api/correspondents/ \
    -H "Authorization: Token YOUR_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$name\"}"
  echo " → added: $name"
done < correspondents.txt
```

### Tags
Topic or grouping. Examples:
- Finance
- Legal
- Tax
- HR

### Storage Path (optional but recommended)
Organizes the media folder automatically by metadata.

| Field | Value |
|---|---|
| Name | By Year / Type / Correspondent |
| Path | `{created_year}/{document_type}/{correspondent}` |

---

## SMB Share Setup

Exposes the consume folder as a Windows network share.

### Install Samba

```bash
sudo apt install samba -y
```

### Configure the Share

```bash
sudo nano /etc/samba/smb.conf
```

Add to the bottom:

```ini
[paperless-consume]
    path = /opt/paperless/consume
    browseable = yes
    writable = yes
    guest ok = no
    valid users = @"domain users"
    create mask = 0664
    directory mask = 0775
    force group = "domain users"
```

### Set Consume Directory Permissions

```bash
sudo chmod 1777 /opt/paperless/consume
```

This allows any authenticated user to write files while the Paperless container can read them all.

### Restart Samba

```bash
sudo systemctl restart smbd
sudo systemctl enable smbd
```

### Connect from Windows

In File Explorer address bar:

```
\\YOUR_VM_IP\paperless-consume
```

Or map as a persistent network drive via right-click **This PC** → **Map Network Drive**.

---

## Active Directory Integration

Allows domain users to authenticate to the SMB share with their domain credentials.

### Install Required Packages

```bash
sudo apt install samba winbind libpam-winbind libnss-winbind krb5-user -y
```

When prompted for Kerberos realm enter your domain in ALL CAPS (e.g., `LOCAL.HDCCO.NET`).

### Configure Kerberos

```bash
sudo nano /etc/krb5.conf
```

```ini
[libdefaults]
    default_realm = YOUR.DOMAIN.NET
    dns_lookup_realm = false
    dns_lookup_kdc = true
```

### Configure Time Sync

Kerberos requires clocks within 5 minutes of the DC:

```bash
sudo apt install chrony -y
sudo nano /etc/chrony.conf
```

Add your DC as NTP source:

```
server YOUR_DC_IP iburst
```

```bash
sudo systemctl restart chrony
chronyc tracking    # verify sync
```

### Full smb.conf for AD Integration

Replace `/etc/samba/smb.conf` entirely:

```ini
[global]
    workgroup = YOURDOMAIN
    realm = YOUR.DOMAIN.NET
    security = ads
    idmap config * : backend = tdb
    idmap config * : range = 10000-99999
    idmap config YOURDOMAIN : backend = ad
    idmap config YOURDOMAIN : range = 10000-99999
    winbind use default domain = yes
    winbind enum users = yes
    winbind enum groups = yes
    winbind refresh tickets = yes
    template homedir = /home/%U
    template shell = /bin/bash
    netbios name = YOURSERVERNAME
    dns proxy = no

[paperless-consume]
    path = /opt/paperless/consume
    browseable = yes
    writable = yes
    valid users = @"domain users"
    create mask = 0664
    directory mask = 0775
    force group = "domain users"
```

### Set Hostname FQDN

```bash
sudo hostnamectl set-hostname yourserver.your.domain.net
```

Update `/etc/hosts`:

```
YOUR_VM_IP    yourserver.your.domain.net    yourserver
```

### Join the Domain

```bash
sudo net ads join -U Administrator
```

### Start and Enable Services

```bash
sudo systemctl restart smbd nmbd winbind
sudo systemctl enable smbd nmbd winbind
```

### Verify the Join

```bash
sudo net ads testjoin      # should return "Join is OK"
wbinfo -u | head -20       # list domain users
wbinfo -g | head -20       # list domain groups
id "YOURDOMAIN\\username"  # test specific user resolution
```

### Register DNS (if needed)

```bash
sudo net ads dns register -U Administrator
```

Or manually create an A record in Windows DNS Manager pointing your server hostname to the VM IP.

---

## Document Ingestion

### The Full Pipeline

1. File dropped into consume share via SMB from Windows
2. Paperless detects it within 60 seconds (polling interval)
3. OCR runs — text is extracted and made searchable
4. Document appears in Paperless-NGX UI
5. Paperless-AI scans every 5 minutes and applies:
   - Generated title
   - Correspondent
   - Document type
   - Tags
6. Document is deleted from consume folder — it now lives in `/opt/paperless/media`

### Subdirectory Support

With `PAPERLESS_CONSUMER_RECURSIVE=1` and `PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS=1`, you can organize your consume share into subfolders:

```
\\YOUR_VM_IP\paperless-consume\
├── INVOICES\       → files tagged "INVOICES" automatically
├── CHECKS\         → files tagged "CHECKS" automatically
└── EMAILS\         → files tagged "EMAILS" automatically
```

### Supported File Types

- PDF, JPG, PNG, TIFF, GIF — native support
- Word, Excel, PowerPoint — handled by Tika
- HTML — handled by Gotenberg

### Test Document Ingestion

```bash
# Watch logs in real time
docker logs -f paperless

# Check consume directory
ls -la /opt/paperless/consume/

# Verify files are being processed
docker ps --format 'table {{.Names}}\t{{.Status}}'
```

### Bulk Import Notes

- Files are deleted from consume after ingestion — keep source copies elsewhere
- Large batches will queue and process over time — set and let it run
- Test with 50-100 representative documents before committing a full archive
- Subdirectories are preserved as permanent drop zones even after contents are ingested

---

## AI Token Usage and Cost

Using `gpt-4o-mini` — the most cost-effective OpenAI model for this use case.

**Typical usage per document:**

| | Tokens |
|---|---|
| Prompt | ~1,296 |
| Completion | ~120 |
| Total per document | ~1,416 |

**GPT-4o-mini pricing:**

| | Rate |
|---|---|
| Input | $0.15 per 1M tokens |
| Output | $0.60 per 1M tokens |

**Cost at scale:**

| Documents | Estimated Cost |
|---|---|
| 100 | ~$0.03 |
| 1,000 | ~$0.27 |
| 10,000 | ~$1.33 |
| 20,000 | ~$2.66 |

Ongoing monthly costs for normal document flow are typically pennies per month.

---

## Troubleshooting

### Container won't start — password authentication failed

**Symptom:** `FATAL: password authentication failed for user "paperless"`

**Cause:** `POSTGRES_PASSWORD` and `PAPERLESS_DBPASS` don't match, or Postgres initialized with a different password before the compose file was finalized.

**Fix:**
```bash
docker compose down
sudo rm -rf /opt/paperless/postgres
sudo mkdir -p /opt/paperless/postgres
sudo chown -R $(id -u):$(id -g) /opt/paperless/postgres
docker compose up -d
```

> Postgres only reads `POSTGRES_PASSWORD` on first initialization. If the data directory already exists it ignores the env variable.

---

### Files dropped via SMB not being picked up

**Check 1 — Are files landing in the directory?**
```bash
ls -la /opt/paperless/consume/
```

**Check 2 — Is polling active?**
```bash
docker exec paperless env | grep POLLING
```

**Check 3 — Is recursive mode active?**
```bash
docker exec paperless env | grep -i consumer
```

**Check 4 — Permissions on consume directory**
```bash
stat /opt/paperless/consume | grep Access
# Should show 1777
sudo chmod 1777 /opt/paperless/consume   # fix if needed
```

---

### SMB connection denied — NT_STATUS_ACCESS_DENIED

**Check winbind is resolving the user:**
```bash
wbinfo -i YOURDOMAIN\\username
id "YOURDOMAIN\\username"
```

**Check smb.conf valid users syntax** — groups require `@` prefix:
```ini
valid users = @"domain users"    # correct
valid users = "DOMAIN\Domain Users"  # incorrect
```

**Check idmap config uses your actual domain name** — not the placeholder `YOURDOMAIN`.

**Restart services after any smb.conf change:**
```bash
sudo systemctl restart smbd winbind
```

---

### Domain join fails

**Most common causes:**

| Cause | Fix |
|---|---|
| DNS not pointing to DC | Set VM DNS to DC IP in `/etc/resolv.conf` or network config |
| Clock drift > 5 minutes | Install and configure chrony pointing at DC |
| Hostname not FQDN | `sudo hostnamectl set-hostname server.your.domain.net` |

**Test DNS resolution:**
```bash
nslookup your.domain.net
```

---

### Paperless-AI not applying correspondents or document types

**Cause:** AI can only assign correspondents/document types that already exist in Paperless when "Use existing Correspondents and Tags" is set to Yes.

**Fix:** Create the missing correspondent or document type in Paperless-NGX → Settings, then trigger a rescan in Paperless-AI.

**Alternative:** Temporarily set "Use existing Correspondents and Tags" → No to let AI create them automatically during initial population, then switch back to Yes.

---

### Permission denied error on consume subdirectories

**Symptom:** `[Errno 13] Permission denied: '/usr/src/paperless/consume/SUBFOLDER/filename.pdf'`

**Cause:** When Windows/AD users create subdirectories via SMB they are owned by their winbind UID (e.g., `10001`). The Paperless container runs as UID `1000` and can read files but cannot delete them from directories it doesn't own.

**Immediate fix — reset permissions recursively:**
```bash
sudo chmod -R 1777 /opt/paperless/consume
```

**Permanent fix — add PAPERLESS_UMASK to compose file:**

In the paperless environment section:
```yaml
PAPERLESS_UMASK: 0002
```

Then apply:
```bash
cd ~/paperless
docker compose up -d
```

> The `chmod -R 1777` handles existing subdirectories. `PAPERLESS_UMASK: 0002` ensures future directories created by the container are group-writable going forward.

---

### Checking Logs

```bash
# All containers
docker compose logs -f

# Specific container
docker logs -f paperless
docker logs -f paperless-ai
docker logs -f paperless-postgres

# Filter for specific events
docker logs paperless | grep -i consumer
docker logs paperless | grep -i error
```

---

## Appendix — Quick Command Reference

### Stack Management

```bash
cd ~/paperless

docker compose up -d          # start stack
docker compose down           # stop stack
docker compose pull           # update images
docker compose config         # validate compose file
docker compose logs -f        # follow all logs
```

### Container Status

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
```

### Paperless Admin

```bash
# Create superuser
docker exec -it paperless python3 manage.py createsuperuser

# Verify environment variables
docker exec paperless env | grep PAPERLESS
docker exec paperless env | grep -i consumer
```

### Directory Permissions

```bash
# Check permissions
ls -la /opt/paperless/
stat /opt/paperless/consume | grep Access

# Fix consume directory permissions (recursive — covers all subdirectories)
sudo chmod -R 1777 /opt/paperless/consume

# Fix ownership
sudo chown -R 1000:1000 /opt/paperless
```

### Samba / AD

```bash
# Test domain join
sudo net ads testjoin

# List domain users/groups
wbinfo -u | head -20
wbinfo -g | head -20

# Test user resolution
wbinfo -i DOMAIN\\username
id "DOMAIN\\username"

# Test SMB share access
smbclient //localhost/paperless-consume -U DOMAIN\\username

# Register DNS
sudo net ads dns register -U Administrator

# Restart services
sudo systemctl restart smbd nmbd winbind
```

### Secret Generation

```bash
openssl rand -hex 32      # PAPERLESS_SECRET_KEY
openssl rand -base64 24   # POSTGRES_PASSWORD / PAPERLESS_DBPASS
```

### Bulk Correspondent Import

```bash
while IFS= read -r name; do
  curl -s -X POST http://YOUR_VM_IP:8000/api/correspondents/ \
    -H "Authorization: Token YOUR_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$name\"}"
  echo " → added: $name"
done < correspondents.txt
```

---

*This guide is part of the MSP-Scripts repository. For updates and related scripts visit https://github.com/chadmark/MSP-Scripts*
