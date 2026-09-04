# Dell Switch Command Audit

Batch-runs a fixed set of `show` commands across a fleet of Dell DNOS/Force10
switches over SSH and writes one clean output file per switch. Built for
running a full config/state snapshot across a client's entire switch stack
in one pass instead of logging into each device by hand.

---

## What it does

Read `devices.csv` (hostname, IP, device_type)
    ↓
Prompt once for shared SSH username/password (never stored on disk)
    ↓
Connect to each switch in turn via Netmiko
    ↓
Netmiko auto-disables paging on login (`terminal length 0` equivalent) — no manual step needed
    ↓
Run all 12 commands below, in order, against that switch
    ↓
Write full output to `switch_output/<short-hostname>_<timestamp>.txt`
    ↓
Move to the next switch, then print a pass/fail summary at the end

---

## Files

| File | Purpose |
|---|---|
| `dell_switch_command_audit.py` | Main script |
| `devices.csv` | Generic template — replace with a real switch inventory before running |

> **Client-specific device lists (real hostnames/IPs) belong in the private `MSP-Configs` repo, not here** — this repo only ships the generic template above.

---

## Commands run (in order)

```
show version
show inventory
show running-config
show interface status
show interfaces description
show ip interface brief
show ip route
show vlan brief
show spanning-tree
show lldp neighbors detail
show vlt brief
show inventory media
```

---

## Prerequisites

- **Python 3.9+**
  - **Ubuntu/Debian:** usually preinstalled; if not:
    ```bash
    sudo apt update
    sudo apt install python3 python3-pip
    ```
  - **Windows:** download and install from [python.org/downloads](https://www.python.org/downloads/) — check "Add python.exe to PATH" during install.
- **netmiko** (Python SSH library with Dell OS10/Force10 drivers) — install below.
- **Network access** from wherever you run this to every switch IP in `devices.csv` over SSH (port 22).
- **SSH credentials** valid on all target switches (script prompts for these at runtime — nothing is hardcoded or stored).

## Setup

**Ubuntu / Linux:**
```bash
pip install netmiko --break-system-packages
```
Or, to keep it isolated in a venv instead:
```bash
python3 -m venv venv
source venv/bin/activate
pip install netmiko
```

**Windows:**
```
pip install netmiko
```

---

## `devices.csv` format

```csv
hostname,ip,device_type
sw-annex.ci.colton.ca.us,10.59.11.11,dell_force10
sw-ch-1-vl100.ci.colton.ca.us,10.10.4.10,dell_force10
```

- **hostname** — used for the output filename only (FQDN suffix is stripped automatically, e.g. `sw-annex.ci.colton.ca.us` → `sw-annex_...txt`). Connection is made via the `ip` column, not this field.
- **ip** — IP the script actually connects to. Preferred over hostname/DNS for batch jobs — no DNS or VPN split-tunnel dependency.
- **device_type** — Netmiko driver to use:
  - `dell_force10` — DNOS9 and legacy Force10-branded hardware (this covers the current fleet in full)
  - `dell_os10` — only if you ever add Dell EMC OS10-based switches (confirm via `show version` — OS10 reports as "Dell EMC Networking OS10-Enterprise"). If used, `show running-config` is auto-swapped to `show running-configuration` for that device only (see `COMMAND_OVERRIDES` in the script) — no other command differs between the two driver types.

---

## Running it

From the folder containing both files:

**Ubuntu / Linux:**
```bash
python3 dell_switch_command_audit.py
```

**Windows:**
```
python dell_switch_command_audit.py
```
(use `py dell_switch_command_audit.py` if `python` isn't on PATH)

You'll be prompted interactively:
```
SSH username:
SSH password:
```
Password entry is blind (no echo) via `getpass` — never written to disk or logged.

Progress prints per switch as it runs:
```
Connecting to sw-annex.ci.colton.ca.us (10.59.11.11)...
  -> OK: switch_output/sw-annex_09-03-2026_1430.txt
```

Ends with a pass/fail summary across every switch in `devices.csv`.

---

## Notes

- Runs sequentially, one switch at a time. With a large fleet, several unreachable devices in a row will add up (each waits out its timeout before moving on). Ask if you want a threaded/parallel version.
- Timeout is set generously (120s) — large running-configs on core/distribution switches can take longer to fully stream than access switches.
- Output files are plain text, one full session transcript per switch, commands clearly delimited with `====` headers.
