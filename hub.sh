#!/bin/bash
# Script to deploy Hub-and-Spoke network architecture in Azure (Tokyo Region)

# Exit on any error,
set -euo pipefail

# Check if az CLI is installed
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Please install it first."; exit 1; }

# Verify az login
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in to Azure. Run 'az login' first."; exit 1; }

# Make az install required extensions non-interactively (avoid prompts during automation)
echo "Configuring az to auto-install extensions if needed..."
az config set extension.dynamic_install_allow_preview=true >/dev/null 2>&1 || true
az config set extension.use_dynamic_install=yes_without_prompt >/dev/null 2>&1 || true

# --- VARIABLES ---
RG_NAME="Hub-Spoke-Tokyo"
LOCATION="japaneast" # Tokyo
ADMIN_USER="${ADMIN_USER:-azureuser}"
ADMIN_PASS="${ADMIN_PASS:-}"
if [ -z "$ADMIN_PASS" ]; then
  echo "ERROR: ADMIN_PASS environment variable not set."
  echo "Set it before running: export ADMIN_PASS='Fill_in_your_password_here'"
  exit 1
fi

# VNet Configurations
HUB_VNET="vnet-hub-secure"
HUB_PREFIX="10.0.0.0/16"
PROD_VNET="vnet-spoke-prod"
PROD_PREFIX="10.1.0.0/16"
NONPROD_VNET="vnet-spoke-nonprod"
NONPROD_PREFIX="10.2.0.0/16"

echo "--- Starting Hub-and-Spoke Deployment (Tokyo) ---"

# 1. Create Resource Group
echo "Creating Resource Group..."
az group create --name "$RG_NAME" --location "$LOCATION" 2>/dev/null || echo "Resource group already exists, continuing..."

# 2. Create VNets and Subnets
echo "Creating VNets..."
az network vnet create -g "$RG_NAME" -n "$HUB_VNET" --address-prefix "$HUB_PREFIX" \
  --subnet-name AzureFirewallSubnet --subnet-prefix 10.0.1.0/24 --location "$LOCATION"

az network vnet subnet create -g "$RG_NAME" --vnet-name "$HUB_VNET" -n GatewaySubnet --address-prefix 10.0.2.0/24
az network vnet subnet create -g "$RG_NAME" --vnet-name "$HUB_VNET" -n AzureBastionSubnet --address-prefix 10.0.3.0/24

az network vnet create -g "$RG_NAME" -n "$PROD_VNET" --address-prefix "$PROD_PREFIX" --subnet-name default --subnet-prefix 10.1.1.0/24 --location "$LOCATION"
az network vnet create -g "$RG_NAME" -n "$NONPROD_VNET" --address-prefix "$NONPROD_PREFIX" --subnet-name default --subnet-prefix 10.2.1.0/24 --location "$LOCATION"

# 3. Public IPs
echo "Creating Public IPs..."
az network public-ip create -g "$RG_NAME" -n pip-firewall --sku Standard --allocation-method Static --location "$LOCATION"
az network public-ip create -g "$RG_NAME" -n pip-vpn-gw --sku Standard --allocation-method Static --location "$LOCATION"
az network public-ip create -g "$RG_NAME" -n pip-bastion --sku Standard --allocation-method Static --location "$LOCATION"

# 4. Deploy Azure Firewall
echo "Validating Firewall prerequisites (public IP, subnet)..."

# Ensure the public IP exists and is Standard SKU
if ! az network public-ip show -g "$RG_NAME" -n pip-firewall >/dev/null 2>&1; then
  echo "Public IP 'pip-firewall' not found. Creating..."
  az network public-ip create -g "$RG_NAME" -n pip-firewall --sku Standard --allocation-method Static --location "$LOCATION"
else
  echo "Public IP 'pip-firewall' exists."
fi

# Ensure AzureFirewallSubnet exists in the hub VNet (Azure Firewall requires this exact subnet name)
if ! az network vnet subnet show -g "$RG_NAME" --vnet-name "$HUB_VNET" -n AzureFirewallSubnet >/dev/null 2>&1; then
  echo "Subnet 'AzureFirewallSubnet' missing in VNet '$HUB_VNET'. Creating subnet..."
  az network vnet subnet create -g "$RG_NAME" --vnet-name "$HUB_VNET" -n AzureFirewallSubnet --address-prefix 10.0.1.0/24
else
  echo "Subnet 'AzureFirewallSubnet' present in VNet '$HUB_VNET'."
fi

echo "Starting Azure Firewall deployment (synchronous; errors will surface)..."
az network firewall policy create -g "$RG_NAME" -n fw-policy-hub --sku Standard --location "$LOCATION" 2>/dev/null || echo "Firewall policy already exists, continuing..."
az network firewall create -g "$RG_NAME" -n fw-hub --policy fw-policy-hub \
  --vnet-name "$HUB_VNET" --conf-name fw-config --public-ip pip-firewall \
  --sku AZFW_VNet --location "$LOCATION"

# 5. Deploy VPN Gateway
echo "Starting VPN Gateway deployment (Background)..."
# Ensure the VPN public IP exists (named 'pip-vpn-gw')
if ! az network public-ip show -g "$RG_NAME" -n pip-vpn-gw >/dev/null 2>&1; then
  echo "Public IP 'pip-vpn-gw' not found. Creating..."
  az network public-ip create -g "$RG_NAME" -n pip-vpn-gw --sku Standard --allocation-method Static --location "$LOCATION"
else
  echo "Public IP 'pip-vpn-gw' exists."
fi

az network vnet-gateway create -g "$RG_NAME" -n vpn-gw-hub --public-ip-address pip-vpn-gw \
  --vnet "$HUB_VNET" --gateway-type Vpn --sku VpnGw1 --vpn-type RouteBased --location "$LOCATION" --no-wait

# 6. Azure Bastion
echo "Starting Bastion deployment (Background)..."
if ! az network public-ip show -g "$RG_NAME" -n pip-bastion >/dev/null 2>&1; then
  echo "Public IP 'pip-bastion' not found. Creating..."
  az network public-ip create -g "$RG_NAME" -n pip-bastion --sku Standard --allocation-method Static --location "$LOCATION"
else
  echo "Public IP 'pip-bastion' exists."
fi

az network bastion create -g "$RG_NAME" -n bastion-hub --public-ip-address pip-bastion \
  --vnet-name "$HUB_VNET" --sku Standard --location "$LOCATION" --no-wait

# 7. VNet Peering
echo "Configuring Peering..."
# NOTE: Hub-to-Spoke peerings allow gateway transit, but spoke-to-hub peerings
# After VPN Gateway is ready, update spoke peerings to enable --use-remote-gateways.

az network vnet peering create -g "$RG_NAME" -n Hub-to-Prod --vnet-name "$HUB_VNET" \
  --remote-vnet "$PROD_VNET" --allow-vnet-access --allow-forwarded-traffic --allow-gateway-transit
az network vnet peering create -g "$RG_NAME" -n Prod-to-Hub --vnet-name "$PROD_VNET" \
  --remote-vnet "$HUB_VNET" --allow-vnet-access --allow-forwarded-traffic

az network vnet peering create -g "$RG_NAME" -n Hub-to-NonProd --vnet-name "$HUB_VNET" \
  --remote-vnet "$NONPROD_VNET" --allow-vnet-access --allow-forwarded-traffic --allow-gateway-transit
az network vnet peering create -g "$RG_NAME" -n NonProd-to-Hub --vnet-name "$NONPROD_VNET" \
  --remote-vnet "$HUB_VNET" --allow-vnet-access --allow-forwarded-traffic

# 8. Create Test VMs
echo "Creating Test VMs..."
az vm create -g "$RG_NAME" -n vm-prod --image Ubuntu2204 --vnet-name "$PROD_VNET" --subnet default \
  --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PASS" --size Standard_B1s --public-ip-address "" --location "$LOCATION" --no-wait

az vm create -g "$RG_NAME" -n vm-nonprod --image Ubuntu2204 --vnet-name "$NONPROD_VNET" --subnet default \
  --admin-username "$ADMIN_USER" --admin-password "$ADMIN_PASS" --size Standard_B1s --public-ip-address "" --location "$LOCATION" --no-wait

echo "------------------------------------------------"
echo "DEPLOYMENT INITIATED SUCCESSFULLY"
echo "Resources deploying in Tokyo (japaneast)."
echo "Estimated time: 45 minutes for full deployment."
echo "------------------------------------------------"
