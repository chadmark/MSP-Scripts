"""
.SYNOPSIS
    Batch-runs a set of 'show' commands across all Dell OS10/DNOS switches
    for a client and writes one output file per switch.

.DESCRIPTION
    Reads a device list from devices.csv (hostname, ip, device_type), prompts
    once for shared SSH credentials, connects via Netmiko (which auto-detects
    the prompt and disables paging - no manual 'terminal length 0' needed),
    runs the command set below in order, and writes the full output to
    switch_output/<hostname>_<timestamp>.txt.

.NOTES
    Author: Chad
    Last Edit: 09-03-2026
    GitHub Path: MSP-Scripts/network/dell-switch-command-audit/dell_switch_command_audit.py
    Environment: Python 3.9+ (Ubuntu or Windows)
    Requires: netmiko (pip install netmiko)
    Version: 1.1

.CHANGELOG
    1.0 - 09-03-2026 - Initial version
    1.1 - 09-03-2026 - Shortened output filenames to hostname prefix (strip FQDN suffix)

.LINK
    https://github.com/ktbyers/netmiko
"""

import csv
import os
import sys
from datetime import datetime
from getpass import getpass

from netmiko import ConnectHandler, NetmikoAuthenticationException, NetmikoTimeoutException

# ---- CONFIG ----
DEVICE_LIST_FILE = "devices.csv"
OUTPUT_DIR = "switch_output"
TIMEOUT = 120  # seconds - core switches with large configs can take a while to finish streaming

# Commands run on every device, in order.
COMMANDS = [
    "show version",
    "show inventory",
    "show running-config",
    "show interface status",
    "show interfaces description",
    "show ip interface brief",
    "show ip route",
    "show vlan brief",
    "show spanning-tree",
    "show lldp neighbors detail",
    "show vlt brief",
    "show inventory media",
]

# Dell OS10 uses 'show running-configuration', not 'show running-config'.
# DNOS/Force10 accepts the shorter form as given above, so no override needed there.
COMMAND_OVERRIDES = {
    "dell_os10": {
        "show running-config": "show running-configuration",
    },
}


def load_devices(path):
    if not os.path.exists(path):
        print(f"Missing {path} - create it with columns: hostname,ip,device_type")
        print("device_type must be 'dell_os10' (OS10-based) or 'dell_force10' (DNOS/legacy Force10)")
        sys.exit(1)
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def run_switch(device, username, password):
    hostname = device["hostname"]
    device_type = device["device_type"]
    overrides = COMMAND_OVERRIDES.get(device_type, {})

    conn_params = {
        "device_type": device_type,
        "host": device["ip"],
        "username": username,
        "password": password,
        "timeout": TIMEOUT,
        "conn_timeout": 20,
    }

    output_lines = []
    try:
        conn = ConnectHandler(**conn_params)
        for cmd in COMMANDS:
            actual_cmd = overrides.get(cmd, cmd)
            output_lines.append(f"{'=' * 20} {actual_cmd} {'=' * 20}\n")
            result = conn.send_command(actual_cmd, read_timeout=TIMEOUT)
            output_lines.append(result + "\n\n")
        conn.disconnect()
        status = "OK"
    except NetmikoAuthenticationException:
        output_lines.append("CONNECTION FAILED: authentication rejected\n")
        status = "AUTH FAILED"
    except NetmikoTimeoutException:
        output_lines.append("CONNECTION FAILED: SSH timeout / unreachable\n")
        status = "UNREACHABLE"
    except Exception as e:
        output_lines.append(f"UNEXPECTED ERROR: {e}\n")
        status = "FAILED"

    return hostname, status, "".join(output_lines)


def main():
    devices = load_devices(DEVICE_LIST_FILE)
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    username = input("SSH username: ")
    password = getpass("SSH password: ")

    timestamp = datetime.now().strftime("%m-%d-%Y_%H%M")
    summary = []

    for device in devices:
        print(f"Connecting to {device['hostname']} ({device['ip']})...")
        hostname, status, output = run_switch(device, username, password)
        short_name = hostname.split(".")[0]  # strip FQDN suffix for the filename
        filename = os.path.join(OUTPUT_DIR, f"{short_name}_{timestamp}.txt")
        with open(filename, "w") as f:
            f.write(output)
        print(f"  -> {status}: {filename}")
        summary.append((hostname, status))

    print("\nSummary:")
    for hostname, status in summary:
        print(f"  {hostname}: {status}")


if __name__ == "__main__":
    main()
