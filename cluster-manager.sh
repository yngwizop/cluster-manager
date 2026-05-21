#!/bin/bash

# Enterprise Proxmox & Ceph Cluster Manager
# Supports Full Cluster Shutdowns AND Rolling Node Maintenance utilizing HA-Manager & ProxLB.

NODES=$(ls /etc/pve/nodes)
MAX_WAIT_TIME=900 # 15 minutes max wait time for ProxLB/HA to evacuate a node

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}      Enterprise Proxmox & Ceph Cluster Manager      ${NC}"
echo -e "${GREEN}=====================================================${NC}\n"

echo "1) FULL CLUSTER SUSPEND (Stops HA -> Shuts down all VMs -> Poweroff/Reboot)"
echo "2) FULL CLUSTER RESUME  (Unset Ceph Flags after full blackout)"
echo -e "${CYAN}3) ROLLING NODE MAINTENANCE (Evacuate via ProxLB/HA -> Reboot -> Restore)${NC}"
echo "4) Exit"
echo ""
read -p "Please select an option (1-4): " OPTION

# Function to count active VMs/LXCs on all nodes
get_total_running_guests() {
    local total=0
    for NODE in $NODES; do
        local count=$(ssh -q -o BatchMode=yes root@$NODE "qm list 2>/dev/null | grep -c 'running' && pct list 2>/dev/null | grep -c 'running'" | awk '{s+=$1} END {print s}')
        total=$((total + count))
    done
    echo "$total"
}

# Function to count active VMs/LXCs on a SINGLE node
get_node_running_guests() {
    local target_node=$1
    local count=$(ssh -q -o BatchMode=yes root@$target_node "qm list 2>/dev/null | grep -c 'running' && pct list 2>/dev/null | grep -c 'running'" | awk '{s+=$1} END {print s}')
    echo "$count"
}

case $OPTION in
  1)
    echo -e "\n${YELLOW}--- FULL CLUSTER SUSPEND ---${NC}"
    read -p "Do you want to [S]hutdown or [R]eboot the entire cluster? (S/R): " ACTION_TYPE
    if [[ "$ACTION_TYPE" == "S" || "$ACTION_TYPE" == "s" ]]; then
        CMD="poweroff"
    elif [[ "$ACTION_TYPE" == "R" || "$ACTION_TYPE" == "r" ]]; then
        CMD="reboot"
    else
        echo -e "${RED}Invalid input. Aborting.${NC}"; exit 1
    fi

    echo -e "${RED}WARNING: This will shutdown ALL VMs and power off the entire cluster!${NC}"
    read -p "Are you absolutely sure? (yes/no): " CONFIRM
    [[ "$CONFIRM" != "yes" ]] && echo "Aborted." && exit 0

    echo -e "\n[1/4] Setting global Ceph flags..."
    ceph osd set noout && ceph osd set norecover && ceph osd set norebalance && ceph osd set nobackfill || exit 1
    
    echo -e "\n[2/4] Gracefully stopping all running VMs and containers globally..."
    for NODE in $NODES; do
        ssh -q root@$NODE "pvesh create /nodes/$NODE/stopall" >/dev/null 2>&1 &
    done

    WAIT_TIME=0
    while true; do
        RUNNING=$(get_total_running_guests)
        [[ "$RUNNING" -eq 0 ]] && echo -e "\n${GREEN}All guests stopped.${NC}" && break
        [[ $WAIT_TIME -ge $MAX_WAIT_TIME ]] && echo -e "\n${RED}TIMEOUT! Aborting host shutdown.${NC}" && exit 1
        echo -n -e "\rWaiting for global shutdown... $RUNNING guests still active. (${WAIT_TIME}s)"
        sleep 15; WAIT_TIME=$((WAIT_TIME + 15))
    done

    echo -e "\n[3/4] Stopping HA services (preventing ProxLB/HA interference)..."
    for NODE in $NODES; do
        ssh -q root@$NODE "systemctl stop pve-ha-lrm pve-ha-crm"
    done

    echo -e "\n[4/4] Executing $CMD on all nodes..."
    for NODE in $NODES; do
        [[ "$NODE" != "$HOSTNAME" ]] && ssh -q root@$NODE "$CMD"
    done
    $CMD
    ;;

  2)
    echo -e "\n${GREEN}--- FULL CLUSTER RESUME ---${NC}"
    ceph osd unset noout; ceph osd unset norecover; ceph osd unset norebalance; ceph osd unset nobackfill
    echo -e "${GREEN}Ceph flags removed. Cluster is operational.${NC}"
    ;;

  3)
    echo -e "\n${CYAN}--- ROLLING NODE MAINTENANCE ---${NC}"
    echo "Available nodes: $NODES"
    read -p "Which node do you want to update/reboot? (e.g., PVE-03): " TARGET_NODE

    # Check if node exists
    if [[ ! "$NODES" == *"$TARGET_NODE"* ]]; then
        echo -e "${RED}Node '$TARGET_NODE' not found. Aborting.${NC}"; exit 1
    fi

    echo -e "\n[1/5] Setting Ceph 'noout' flag to prevent rebalancing during reboot..."
    ceph osd set noout || exit 1

    echo -e "\n[2/5] Enabling Maintenance Mode. ProxLB and HA-Manager will now evacuate $TARGET_NODE..."
    ha-manager crm-command node-maintenance enable $TARGET_NODE

    WAIT_TIME=0
    while true; do
        RUNNING=$(get_node_running_guests $TARGET_NODE)
        [[ "$RUNNING" -eq 0 ]] && echo -e "\n${GREEN}$TARGET_NODE is completely empty!${NC}" && break
        [[ $WAIT_TIME -ge $MAX_WAIT_TIME ]] && echo -e "\n${RED}TIMEOUT: ProxLB/HA could not migrate all VMs in time! Aborting reboot.${NC}" && exit 1
        
        echo -n -e "\rWaiting for live migration... $RUNNING guests left on $TARGET_NODE. (${WAIT_TIME}s)"
        sleep 10; WAIT_TIME=$((WAIT_TIME + 10))
    done

    echo -e "\n[3/5] Rebooting $TARGET_NODE safely..."
    ssh -q root@$TARGET_NODE "reboot"
    
    echo -e "\n[4/5] Waiting for $TARGET_NODE to come back online..."
    sleep 30 # Give it time to go down
    while ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 root@$TARGET_NODE "echo 1" >/dev/null 2>&1; do
        echo -n -e "\rStill waiting for SSH response from $TARGET_NODE..."
        sleep 10
    done
    echo -e "\n${GREEN}$TARGET_NODE is back online!${NC}"
    sleep 15 # Wait for PVE services to fully start

    echo -e "\n[5/5] Disabling Maintenance Mode and removing Ceph flags..."
    ha-manager crm-command node-maintenance disable $TARGET_NODE
    ceph osd unset noout
    
    echo -e "\n${GREEN}DONE! ProxLB and HA-Manager will now automatically balance the load back to $TARGET_NODE.${NC}"
    ;;

  4)
    echo "Exited."; exit 0 ;;
  *)
    echo -e "${RED}Invalid option.${NC}"; exit 1 ;;
esac
