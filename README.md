# Enterprise Proxmox & Ceph Cluster Manager

A robust, interactive bash script designed to safely manage Proxmox VE and Ceph clusters. It provides automated, enterprise-grade safety nets for full cluster blackouts (shutdown/reboot) and rolling node maintenance, seamlessly integrating with the Proxmox HA-Manager and ProxLB.

## Features

* **Pre-Flight Safety Checks:** Automatically verifies SSH connectivity across all nodes and ensures Ceph is `HEALTH_OK` before executing any disruptive commands.
* **Full Cluster Suspend:** Safely prepares the entire cluster for a power outage. Sets Ceph flags (`noout`, `norecover`, etc.) to prevent rebalancing storms, forcefully stops HA services to prevent fencing, gracefully shuts down all VMs/LXCs, and finally powers off or reboots all nodes.
* **Full Cluster Resume:** Easily removes all global Ceph flags after a cluster-wide reboot to restore normal operations.
* **Rolling Node Maintenance (Zero Downtime):** Automates single-node updates. Sets Ceph `noout`, places the node into Maintenance Mode, monitors the live migration of HA and non-HA guests (via ProxLB), reboots the empty node, and automatically restores it to the cluster once it is back online.

## Prerequisites

Before using this script, ensure your environment meets the following requirements:

1. **Proxmox VE + Ceph Cluster:** Tested on a standard 3-node setup (scales to larger environments).
2. **Root SSH Access:** Nodes must be able to communicate via SSH without a password. (This is the default configuration in a Proxmox cluster).
3. **ProxLB (Optional but recommended):** For Option 3 (Rolling Maintenance) to work completely hands-off, [ProxLB](https://github.com/gyptazy/ProxLB) should be installed and configured. While Proxmox HA-Manager evacuates HA-guests, ProxLB handles the automated evacuation of non-HA guests.
* *Note: Ensure `with_local_disks: False` is set in your ProxLB config when using Ceph.*



## Quick Start

**1. Create the script on your primary node (e.g., PVE-01):**

```bash
nano /root/cluster-manager.sh

```

**2. Paste the script code into the editor, then save and exit.** *(Press `Ctrl+O`, `Enter`, and `Ctrl+X` in nano).*

**3. Make the script executable:**

```bash
chmod +x /root/cluster-manager.sh

```

**4. Run the script:**

```bash
./cluster-manager.sh

```

## Usage Guide

Upon running the script, you will be greeted with an interactive menu:

```text
=====================================================
      Enterprise Proxmox & Ceph Cluster Manager      
=====================================================

1) FULL CLUSTER SUSPEND (Stops HA -> Shuts down all VMs -> Poweroff/Reboot)
2) FULL CLUSTER RESUME  (Unset Ceph Flags after full blackout)
3) ROLLING NODE MAINTENANCE (Evacuate via ProxLB/HA -> Reboot -> Restore)
4) Exit

```

* **Option 1:** Use this when you need to shut down the *entire* datacenter (e.g., replacing a main UPS, physical move, or major power outage).
* **Option 2:** Use this once the cluster is powered back on after utilizing Option 1. It releases the Ceph handbrake.
* **Option 3:** Use this for everyday maintenance (e.g., installing kernel updates on a single node). Type the name of the node (e.g., `PVE-03`) and the script will handle the evacuation, reboot, and restoration autonomously.

## ⚠️ Disclaimer

This script interacts with critical infrastructure components (Power management, Ceph, High Availability). Always test scripts in a non-production or staging environment first. Ensure you have out-of-band management (IPMI/iDRAC/iLO) available before performing remote reboots.
