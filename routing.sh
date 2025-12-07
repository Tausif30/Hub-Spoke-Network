#!/bin/bash
# Controls Routing for Spoke VNets to route traffic through Firewall in Hub VNet

# Exit on any error
set -euo pipefail

# Check if az CLI is installed
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Please install it first."; exit 1; }

# Verify az login
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in to Azure. Run 'az login' first."; exit 1; }

# --- VARIABLES ---
RG_NAME="Hub-Spoke-Tokyo"
PROD_VNET="vnet-spoke-prod"
NONPROD_VNET="vnet-spoke-nonprod"
FW_NAME="fw-hub"

# Precondition checks
echo "Verifying prerequisites..."
az group show -n "$RG_NAME" >/dev/null 2>&1 || { echo "ERROR: Resource group '$RG_NAME' not found."; exit 1; }
az network vnet show -g "$RG_NAME" -n "$PROD_VNET" >/dev/null 2>&1 || { echo "ERROR: VNet '$PROD_VNET' not found."; exit 1; }
az network vnet show -g "$RG_NAME" -n "$NONPROD_VNET" >/dev/null 2>&1 || { echo "ERROR: VNet '$NONPROD_VNET' not found."; exit 1; }
echo "All prerequisites verified."

echo "Getting Firewall Private IP (will retry up to 10 minutes)..."
# Retry loop: total 600s (10 minutes) with 15s intervals
MAX_WAIT=600
INTERVAL=15
ELAPSED=0
FW_IP=""
while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
  FW_IP=$(az network firewall show -g "$RG_NAME" -n "$FW_NAME" --query "ipConfigurations[0].privateIPAddress" -o tsv 2>/dev/null || true)
  if [ -n "$FW_IP" ]; then
    break
  fi
  echo "Firewall not yet ready (elapsed ${ELAPSED}s). Retrying in ${INTERVAL}s..."
  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

if [ -z "$FW_IP" ]; then
  echo "ERROR: Firewall '$FW_NAME' not found or has no private IP after $((MAX_WAIT/60)) minutes."
  echo "Check provisioning with: az network firewall show -g \"$RG_NAME\" -n \"$FW_NAME\" -o json"
  echo "Check activity log: az monitor activity-log list --resource-group \"$RG_NAME\" --offset 24h -o table"
  echo "If the firewall was deployed with a different SKU (AZFW_Hub) it may require a virtual hub."
  exit 1
fi

echo "Firewall IP is: $FW_IP"

echo "Creating UDRs..."
# Prod Route
echo "Creating route table for Prod spoke..."
az network route-table create -g "$RG_NAME" -n rt-prod --location japaneast 2>/dev/null || echo "Route table rt-prod already exists, continuing..."

echo "Adding default route to Prod route table..."
az network route-table route create -g "$RG_NAME" --route-table-name rt-prod -n Default-to-FW \
  --next-hop-type VirtualAppliance --address-prefix 0.0.0.0/0 --next-hop-ip-address "$FW_IP" 2>/dev/null || \
  az network route-table route update -g "$RG_NAME" --route-table-name rt-prod -n Default-to-FW \
  --next-hop-type VirtualAppliance --address-prefix 0.0.0.0/0 --next-hop-ip-address "$FW_IP"

echo "Associating route table with Prod subnet..."
az network vnet subnet update -g "$RG_NAME" --vnet-name "$PROD_VNET" -n default --route-table rt-prod

# Non-Prod Route
echo "Creating route table for Non-Prod spoke..."
az network route-table create -g "$RG_NAME" -n rt-nonprod --location japaneast 2>/dev/null || echo "Route table rt-nonprod already exists, continuing..."

echo "Adding default route to Non-Prod route table..."
az network route-table route create -g "$RG_NAME" --route-table-name rt-nonprod -n Default-to-FW \
  --next-hop-type VirtualAppliance --address-prefix 0.0.0.0/0 --next-hop-ip-address "$FW_IP" 2>/dev/null || \
  az network route-table route update -g "$RG_NAME" --route-table-name rt-nonprod -n Default-to-FW \
  --next-hop-type VirtualAppliance --address-prefix 0.0.0.0/0 --next-hop-ip-address "$FW_IP"

echo "Associating route table with Non-Prod subnet..."
az network vnet subnet update -g "$RG_NAME" --vnet-name "$NONPROD_VNET" -n default --route-table rt-nonprod

echo "Routing Configured Successfully."

