#!/bin/bash

# Enterprise Proxmox & Ceph Cluster Manager
# Verifies status, cleanly shuts down VMs, and prevents split-brains.

NODES=$(ls /etc/pve/nodes)
MAX_WAIT_TIME=600 # Maximum wait time for VM shutdown in seconds (here: 10 mins)

# Colors for better readability
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}      Enterprise Proxmox & Ceph Cluster Manager      ${NC}"
echo -e "${GREEN}=====================================================${NC}\n"

echo "1) SUSPEND CLUSTER (Pre-Check -> VM Shutdown -> Ceph/HA -> Poweroff/Reboot)"
echo "2) RESUME CLUSTER  (Unset Ceph Flags)"
echo "3) Exit"
echo ""
read -p "Please select an option (1-3): " OPTION

# Function to count active VMs/LXCs
get_running_guests_count() {
    local total_running=0
    for NODE in $NODES; do
        # Count running VMs and containers, ignoring error outputs
        local vm_count=$(ssh -q -o BatchMode=yes root@$NODE "qm list 2>/dev/null | grep -c 'running'" || echo 0)
        local ct_count=$(ssh -q -o BatchMode=yes root@$NODE "pct list 2>/dev/null | grep -c 'running'" || echo 0)
        total_running=$((total_running + vm_count + ct_count))
    done
    echo "$total_running"
}

case $OPTION in
  1)
    echo ""
    read -p "Do you want to [S]hutdown or [R]eboot the cluster? (S/R): " ACTION_TYPE
    if [[ "$ACTION_TYPE" == "S" || "$ACTION_TYPE" == "s" ]]; then
        CMD="poweroff"
        echo -e "Action selected: ${RED}SHUTDOWN (poweroff)${NC}"
    elif [[ "$ACTION_TYPE" == "R" || "$ACTION_TYPE" == "r" ]]; then
        CMD="reboot"
        echo -e "Action selected: ${YELLOW}REBOOT (reboot)${NC}"
    else
        echo -e "${RED}Invalid input. Aborting.${NC}"
        exit 1
    fi

    echo -e "${YELLOW}WARNING: This will affect the entire cluster!${NC}"
    read -p "Are you absolutely sure? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Aborted."
        exit 0
    fi

    echo -e "\n${YELLOW}[1/6] Pre-Flight Check: Checking SSH connectivity to all nodes...${NC}"
    for NODE in $NODES; do
        if ! ssh -q -o BatchMode=yes root@$NODE "echo 1" >/dev/null; then
            echo -e "${RED}ERROR: Node $NODE is not reachable via SSH. Aborting!${NC}"
            exit 1
        fi
    done
    echo -e "${GREEN}SSH connections OK.${NC}"

    echo -e "\n${YELLOW}[2/6] Pre-Flight Check: Checking Ceph status...${NC}"
    CEPH_STATUS=$(ceph health)
    if [[ "$CEPH_STATUS" != *"HEALTH_OK"* ]]; then
        echo -e "${RED}ERROR: Ceph is not HEALTH_OK (Status: $CEPH_STATUS).${NC}"
        echo -e "${RED}Fix the Ceph issue or remove old flags before suspending the cluster! Aborting.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Ceph status is HEALTH_OK.${NC}"

    echo -e "\n${YELLOW}[3/6] Setting global Ceph flags (prevents rebalancing)...${NC}"
    if ceph osd set noout && ceph osd set norecover && ceph osd set norebalance && ceph osd set nobackfill; then
        echo -e "${GREEN}Ceph flags successfully set.${NC}"
    else
        echo -e "${RED}ERROR setting Ceph flags! Aborting.${NC}"
        exit 1
    fi
    sleep 2

    echo -e "\n${YELLOW}[4/6] Gracefully stopping all running VMs and containers...${NC}"
    for NODE in $NODES; do
        # pvesh stopall respects Startup/Shutdown order and HA status
        echo "  -> Sending stop signal to all guests on $NODE..."
        ssh -q root@$NODE "pvesh create /nodes/$NODE/stopall" >/dev/null 2>&1 &
    done

    # Wait loop
    WAIT_TIME=0
    while true; do
        RUNNING_GUESTS=$(get_running_guests_count)
        if [ "$RUNNING_GUESTS" -eq 0 ]; then
            echo -e "\n${GREEN}All VMs and containers have been successfully stopped.${NC}"
            break
        fi
        
        if [ $WAIT_TIME -ge $MAX_WAIT_TIME ]; then
            echo -e "\n${RED}TIMEOUT: $RUNNING_GUESTS guests are still running after $MAX_WAIT_TIME seconds!${NC}"
            echo -e "${RED}The operation is being aborted. Please log in and check which VMs are hanging.${NC}"
            exit 1
        fi

        echo -n -e "\rWaiting for shutdown... $RUNNING_GUESTS guests still active. (Elapsed: ${WAIT_TIME}s)"
        sleep 15
        WAIT_TIME=$((WAIT_TIME + 15))
    done

    echo -e "\n${YELLOW}[5/6] Stopping HA services on all nodes (prevents fencing)...${NC}"
    for NODE in $NODES; do
        if ssh -q root@$NODE "systemctl stop pve-ha-lrm pve-ha-crm"; then
            echo "  -> HA stopped on $NODE."
        else
            echo -e "${RED}ERROR: Could not stop HA services on $NODE! Aborting.${NC}"
            exit 1
        fi
    done
    echo -e "${GREEN}HA services successfully stopped.${NC}"

    echo -e "\n${YELLOW}[6/6] Sending $CMD command to the cluster...${NC}"
    for NODE in $NODES; do
        if [ "$NODE" != "$HOSTNAME" ]; then
            echo "  -> Sending $CMD to node $NODE..."
            ssh -q root@$NODE "$CMD"
        fi
    done
    echo "  -> Sending $CMD to local node $HOSTNAME..."
    $CMD
    ;;

  2)
    echo -e "\n${YELLOW}Unsetting Ceph flags to release the cluster...${NC}"
    ceph osd unset noout
    ceph osd unset norecover
    ceph osd unset norebalance
    ceph osd unset nobackfill
    
    echo -e "\n${GREEN}Flags removed! Checking Ceph status...${NC}"
    sleep 3
    ceph -s
    echo -e "\n${GREEN}Hint: VMs with 'Start at boot' enabled and active HA guests should now start automatically.${NC}"
    ;;

  3)
    echo "Exited."
    exit 0
    ;;

  *)
    echo -e "${RED}Invalid input.${NC}"
    exit 1
    ;;
esac
