#!/usr/bin/env bash
# Azure SNMP autodiscovery test bed — provisioning
# Run where `az` is installed and `az login` is done. NOTHING runs unless APPLY=1.
#
#   az login            # if needed
#   az account set --subscription "<sub>"
#   APPLY=1 ./azure-snmp-testbed.sh            # create
#   APPLY=1 ./azure-snmp-testbed.sh teardown   # delete the whole RG
#
# Cost: all VMs are deallocate-when-idle. Simulator + AG are cheap; the NVAs
# (Catalyst 8000V, FortiGate-VM) carry software licensing — keep them stopped
# between test windows.  See docs/cloud-snmp-testbed-plan.md.
set -euo pipefail

# ---------------- config (edit me) ----------------
LOC="${LOC:-eastus}"
RG="${RG:-rg-snmp-testbed}"
VNET="${VNET:-vnet-snmp}"
VNET_CIDR="${VNET_CIDR:-10.20.0.0/16}"
SUBNET="${SUBNET:-snet-infra}"
SUBNET_CIDR="${SUBNET_CIDR:-10.20.0.0/24}"
SIM_TARGET_CIDR="${SIM_TARGET_CIDR:-10.20.64.0/18}"   # routed to the sim VM -> 16,384 virtual devices (covers 10k)
COMMUNITY="${COMMUNITY:-public-wood}"
ADMIN="${ADMIN:-azureuser}"
MY_IP="${MY_IP:-$(curl -s https://api.ipify.org 2>/dev/null || echo '0.0.0.0')}"   # SSH source lock
AG_SIZE="${AG_SIZE:-Standard_D2s_v5}"
SIM_SIZE="${SIM_SIZE:-Standard_D8s_v5}"      # headroom for scan bursts across 7 concurrent configs
NVA_SIZE="${NVA_SIZE:-Standard_D4s_v5}"
IMG_UBUNTU="${IMG_UBUNTU:-Ubuntu2204}"
# NVA marketplace URNs change often. Catalyst 8000V is BYOL (unlicensed/eval still serves SNMP -> VM-cost only). Discover then set:
#   az vm image list --publisher cisco    --all -o table | grep -i c8000v
#   az vm image list --publisher fortinet --all -o table | grep -i fortigate
CISCO_URN="${CISCO_URN:-}"      # e.g. cisco:cisco-c8000v:17_15_01a-byol:latest
FORTI_URN="${FORTI_URN:-}"      # e.g. fortinet:fortinet_fortigate-vm_v5:fortinet_fg-vm:latest
# --------------------------------------------------

# Print the command; run it only when APPLY=1. Uses `if` (not `&&`) so that in
# dry-run mode run() returns 0 — otherwise the trailing false test trips `set -e`
# and the script exits after the first command. In APPLY mode the real command's
# exit status propagates, so `set -e` still catches genuine failures.
run(){ echo "+ $*"; if [ "${APPLY:-0}" = "1" ]; then "$@"; fi; }

teardown(){ echo ">>> deleting resource group $RG"; run az group delete -n "$RG" --yes --no-wait; exit 0; }
[ "${1:-}" = "teardown" ] && teardown

command -v az >/dev/null || { echo "az CLI not found. Install Azure CLI and 'az login' first."; exit 1; }
az account show >/dev/null 2>&1 || { echo "Not logged in. Run 'az login' (and 'az account set --subscription ...')."; exit 1; }
[ "${APPLY:-0}" = "1" ] || echo "### DRY RUN (set APPLY=1 to execute). Commands are printed below. ###"

echo "=== resource group / network ==="
run az group create -n "$RG" -l "$LOC"
run az network vnet create -g "$RG" -n "$VNET" --address-prefixes "$VNET_CIDR" \
     --subnet-name "$SUBNET" --subnet-prefixes "$SUBNET_CIDR"
run az network nsg create -g "$RG" -n nsg-snmp
run az network nsg rule create -g "$RG" --nsg-name nsg-snmp -n allow-ssh --priority 1000 \
     --access Allow --direction Inbound --protocol Tcp --destination-port-ranges 22 \
     --source-address-prefixes "$MY_IP"
# intra-VNet UDP 161 is already permitted by the default AllowVnetInBound rule.
run az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$SUBNET" --network-security-group nsg-snmp

echo "=== ActiveGate VM (install Dynatrace AG after boot; x86-64, current, EEC) ==="
run az vm create -g "$RG" -n vm-ag --image "$IMG_UBUNTU" --size "$AG_SIZE" \
     --vnet-name "$VNET" --subnet "$SUBNET" --admin-username "$ADMIN" \
     --generate-ssh-keys --public-ip-sku Standard --nsg ""

echo "=== Simulator VM (snmpsim; owns $SIM_TARGET_CIDR via local-route + IP forwarding) ==="
# rendered cloud-init with the target CIDR + community baked in
CI="$(mktemp)"; cat > "$CI" <<CICFG
#cloud-config
package_update: true
packages: [python3-pip, python3-venv]
write_files:
  - path: /opt/snmpsim/data/${COMMUNITY}.snmprec
    content: |
      1.3.6.1.2.1.1.1.0|4|Simulated SNMP device (snmpsim)
      1.3.6.1.2.1.1.2.0|6|1.3.6.1.4.1.8072.3.2.10
      1.3.6.1.2.1.1.3.0|67|123456
      1.3.6.1.2.1.1.4.0|4|noc@testbed
      1.3.6.1.2.1.1.5.0|4|sim-device
      1.3.6.1.2.1.1.6.0|4|azure-testbed
  - path: /etc/systemd/system/snmpsim-localroute.service
    content: |
      [Unit]
      Description=local route for simulated SNMP range
      After=network-online.target
      [Service]
      Type=oneshot
      ExecStart=/sbin/ip route replace local ${SIM_TARGET_CIDR} dev lo
      RemainAfterExit=yes
      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/snmpsim.service
    content: |
      [Unit]
      Description=snmpsim responder
      After=network-online.target snmpsim-localroute.service
      Wants=snmpsim-localroute.service
      [Service]
      # snmpsim-lextudio confdir.py reads os.environ["HOME"] at import; systemd
      # does not set HOME for services, so without this the responder crashes
      # with KeyError: 'HOME' before it binds UDP 161.
      Environment=HOME=/root
      ExecStart=/opt/snmpsim/venv/bin/snmpsim-command-responder --data-dir=/opt/snmpsim/data --agent-udpv4-endpoint=0.0.0.0:161
      Restart=always
      [Install]
      WantedBy=multi-user.target
runcmd:
  - sysctl -w net.ipv4.ip_forward=1
  - sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf; echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
  - python3 -m venv /opt/snmpsim/venv
  - /opt/snmpsim/venv/bin/pip install --upgrade pip snmpsim-lextudio
  - systemctl daemon-reload
  - systemctl enable --now snmpsim-localroute.service
  - systemctl enable --now snmpsim.service
CICFG
run az vm create -g "$RG" -n vm-snmpsim --image "$IMG_UBUNTU" --size "$SIM_SIZE" \
     --vnet-name "$VNET" --subnet "$SUBNET" --admin-username "$ADMIN" \
     --generate-ssh-keys --public-ip-sku Standard --nsg "" --custom-data "$CI"
# accept routed traffic for other dest IPs
run az network nic update -g "$RG" -n vm-snmpsimVMNic --ip-forwarding true
SIM_IP="10.20.0.5"
if [ "${APPLY:-0}" = "1" ]; then SIM_IP="$(az vm list-ip-addresses -g "$RG" -n vm-snmpsim --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv)"; fi
echo "  sim private IP = $SIM_IP"
run az network route-table create -g "$RG" -n rt-sim
run az network route-table route create -g "$RG" --route-table-name rt-sim -n to-sim \
     --address-prefix "$SIM_TARGET_CIDR" --next-hop-type VirtualAppliance --next-hop-ip-address "$SIM_IP"
run az network vnet subnet update -g "$RG" --vnet-name "$VNET" -n "$SUBNET" --route-table rt-sim

echo "=== NVAs (fidelity: real SNMP agents) ==="
if [ -n "$CISCO_URN" ]; then
  run az vm image terms accept --urn "$CISCO_URN"
  run az vm create -g "$RG" -n vm-c8000v --image "$CISCO_URN" --size "$NVA_SIZE" \
       --vnet-name "$VNET" --subnet "$SUBNET" --admin-username "$ADMIN" --generate-ssh-keys \
       --public-ip-sku Standard --nsg ""
else echo "  (skipped Catalyst 8000V — set CISCO_URN; discover via: az vm image list --publisher cisco --all -o table | grep -i c8000v)"; fi
if [ -n "$FORTI_URN" ]; then
  run az vm image terms accept --urn "$FORTI_URN"
  run az vm create -g "$RG" -n vm-fgt --image "$FORTI_URN" --size "$NVA_SIZE" \
       --vnet-name "$VNET" --subnet "$SUBNET" --admin-username "$ADMIN" --generate-ssh-keys \
       --public-ip-sku Standard --nsg ""
else echo "  (skipped FortiGate-VM — set FORTI_URN; discover via: az vm image list --publisher fortinet --all -o table | grep -i fortigate)"; fi
rm -f "$CI"

cat <<DONE

=== next steps (post-provision) ===
1. ActiveGate: SSH to vm-ag, install the Dynatrace ActiveGate (x86-64, current), enable the
   Extension Execution Controller, set its group to 'cloud-snmp'. Verify it shows Connected.
2. Verify the simulator from vm-ag:
     snmpget -v2c -c $COMMUNITY 10.20.64.1 1.3.6.1.2.1.1.1.0      # any IP in $SIM_TARGET_CIDR
3. NVA SNMP (once booted), via each vendor CLI:
     Cisco IOS-XE : conf t ; snmp-server community $COMMUNITY RO ; end ; wr mem
     FortiOS      : config system snmp community ; edit 1 ; set name "$COMMUNITY" ; set events ... ; next ; end
   Confirm: snmpget -v2c -c $COMMUNITY <nva-ip> 1.3.6.1.2.1.1.1.0
4. Point Dynatrace autodiscovery (extension 2.4.7) at ag_group-cloud-snmp with the enumerated
   /32 batches — reuse the generator in this repo.

Deallocate when idle:  az vm deallocate -g $RG -n vm-c8000v  (etc.)  |  teardown: APPLY=1 $0 teardown
DONE
