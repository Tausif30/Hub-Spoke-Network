#!/bin/bash
# Script to deploy Secure Azure SQL Database in Hub-and-Spoke network architecture

# Exit on error, undefined variables, and pipe failures
set -euo pipefail

# Check if az CLI is installed
command -v az >/dev/null 2>&1 || { echo "ERROR: Azure CLI (az) not found. Please install it first."; exit 1; }

# Verify az login
az account show >/dev/null 2>&1 || { echo "ERROR: Not logged in to Azure. Run 'az login' first."; exit 1; }

# --- VARIABLES ---
RG_NAME="Hub-Spoke-Tokyo"
LOCATION="japaneast" # Tokyo
HUB_VNET="vnet-hub-secure"
ADMIN_USER="sqladmin"

# Fetch password from Azure Key Vault
if [ -n "${KEY_VAULT_NAME:-}" ] && [ -n "${SQL_ADMIN_PASSWORD_SECRET_NAME:-}" ]; then
  echo "Fetching SQL admin password from Key Vault..."
  ADMIN_PASS=$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" -n "$SQL_ADMIN_PASSWORD_SECRET_NAME" --query value -o tsv)
else
  ADMIN_PASS="${ADMIN_PASS:-}"
  if [ -z "$ADMIN_PASS" ]; then
    echo "ERROR: ADMIN_PASS not set. Either:"
    echo "  1. Set ADMIN_PASS environment variable, or"
    echo "  2. Set KEY_VAULT_NAME and SQL_ADMIN_PASSWORD_SECRET_NAME to fetch from Key Vault"
    exit 1
  fi
fi

# SQL Server Name must be globally unique
# Use a timestamp for better uniqueness
SERVER_NAME="sql-hub-server-$(date +%s)"
DB_NAME="HubDataDB"

echo "--- Deploying Secure Azure SQL Database ---"

# Precondition checks
echo "Verifying prerequisites..."
az group show -n "$RG_NAME" >/dev/null 2>&1 || { echo "ERROR: Resource group '$RG_NAME' not found."; exit 1; }
az network vnet show -g "$RG_NAME" -n "$HUB_VNET" >/dev/null 2>&1 || { echo "ERROR: Hub VNet '$HUB_VNET' not found."; exit 1; }
az network vnet show -g "$RG_NAME" -n "vnet-spoke-prod" >/dev/null 2>&1 || { echo "ERROR: Spoke VNet 'vnet-spoke-prod' not found."; exit 1; }
az network vnet show -g "$RG_NAME" -n "vnet-spoke-nonprod" >/dev/null 2>&1 || { echo "ERROR: Spoke VNet 'vnet-spoke-nonprod' not found."; exit 1; }
echo "All prerequisites verified."

# Resolve VNet resource IDs
HUB_VNET_ID=$(az network vnet show -g "$RG_NAME" -n "$HUB_VNET" --query id -o tsv)
PROD_VNET_ID=$(az network vnet show -g "$RG_NAME" -n "vnet-spoke-prod" --query id -o tsv)
NONPROD_VNET_ID=$(az network vnet show -g "$RG_NAME" -n "vnet-spoke-nonprod" --query id -o tsv)

# 1. Create a dedicated Subnet for the Database in the Hub
echo "Creating Database Subnet in Hub..."
az network vnet subnet create -g "$RG_NAME" --vnet-name "$HUB_VNET" \
  -n DatabaseSubnet --address-prefix 10.0.4.0/24 \
  --disable-private-endpoint-network-policies true

# 2. Create the SQL Logical Server
echo "Creating SQL Server ($SERVER_NAME)..."
az sql server create -g "$RG_NAME" -n "$SERVER_NAME" -l "$LOCATION" \
  --admin-user "$ADMIN_USER" --admin-password "$ADMIN_PASS" \
  --enable-public-network false # CRITICAL: Disable public internet access

# 3. Create the Database (Basic SKU = ~$5/mo)
echo "Creating SQL Database..."
az sql db create -g "$RG_NAME" -s "$SERVER_NAME" -n "$DB_NAME" \
  --service-objective Basic --edition Basic

# 4. Create the Private Endpoint
# This puts the database 'physically' into your Hub Network at 10.0.4.x
echo "Creating Private Endpoint connection..."
# Compute and store server resource id to avoid subshell quoting issues and for clearer errors
SERVER_ID=$(az sql server show -g "$RG_NAME" -n "$SERVER_NAME" --query id -o tsv)
if [ -z "$SERVER_ID" ]; then
  echo "ERROR: could not resolve SQL server resource id for '$SERVER_NAME'. Check the server exists and is provisioned."
  exit 1
fi

# Check if private endpoint already exists (idempotent)
if az network private-endpoint show -g "$RG_NAME" -n pe-sql-hub >/dev/null 2>&1; then
  echo "Private endpoint 'pe-sql-hub' already exists. Checking if it's properly connected..."
  # Check if it has custom DNS configs (indicates proper connection)
  DNS_CHECK=$(az network private-endpoint show -g "$RG_NAME" -n pe-sql-hub --query "customDnsConfigs[0].fqdn" -o tsv 2>/dev/null || true)
  if [ -z "$DNS_CHECK" ]; then
    echo "Existing endpoint has no DNS config. Deleting and recreating..."
    az network private-endpoint delete -g "$RG_NAME" -n pe-sql-hub
  else
    echo "Private endpoint properly configured with DNS."
  fi
fi

# Create private endpoint if it doesn't exist
if ! az network private-endpoint show -g "$RG_NAME" -n pe-sql-hub >/dev/null 2>&1; then
  echo "Creating private endpoint..."
  export MSYS_NO_PATHCONV=1
  az network private-endpoint create -g "$RG_NAME" -n pe-sql-hub \
    --vnet-name "$HUB_VNET" --subnet DatabaseSubnet \
    --private-connection-resource-id "$SERVER_ID" \
    --group-id sqlServer \
    --connection-name sql-connection
  unset MSYS_NO_PATHCONV
fi

# 5. Configure Private DNS Zone for SQL Private Endpoint
echo "Configuring Private DNS Zone..."
# Create zone if missing (idempotent)
if ! az network private-dns zone show -g "$RG_NAME" -n "privatelink.database.windows.net" >/dev/null 2>&1; then
  az network private-dns zone create -g "$RG_NAME" -n "privatelink.database.windows.net"
else
  echo "Private DNS zone 'privatelink.database.windows.net' already exists."
fi

# Link the DNS Zone to Hub, Prod, and NonProd VNets
echo "Linking DNS to VNets..."
# Prevent Git Bash from converting /subscriptions paths
export MSYS_NO_PATHCONV=1

if ! az network private-dns link vnet show -g "$RG_NAME" -n link-hub --zone-name "privatelink.database.windows.net" --query id -o tsv >/dev/null 2>&1; then
  az network private-dns link vnet create -g "$RG_NAME" -n link-hub \
    --zone-name "privatelink.database.windows.net" --virtual-network "$HUB_VNET_ID" --registration-enabled false
else
  echo "DNS link 'link-hub' already exists."
fi

if ! az network private-dns link vnet show -g "$RG_NAME" -n link-prod --zone-name "privatelink.database.windows.net" --query id -o tsv >/dev/null 2>&1; then
  az network private-dns link vnet create -g "$RG_NAME" -n link-prod \
    --zone-name "privatelink.database.windows.net" --virtual-network "$PROD_VNET_ID" --registration-enabled false
else
  echo "DNS link 'link-prod' already exists."
fi

if ! az network private-dns link vnet show -g "$RG_NAME" -n link-nonprod --zone-name "privatelink.database.windows.net" --query id -o tsv >/dev/null 2>&1; then
  az network private-dns link vnet create -g "$RG_NAME" -n link-nonprod \
    --zone-name "privatelink.database.windows.net" --virtual-network "$NONPROD_VNET_ID" --registration-enabled false
else
  echo "DNS link 'link-nonprod' already exists."
fi

unset MSYS_NO_PATHCONV

# 6. Create a DNS Group for the Endpoint
echo "Mapping Private Endpoint to DNS..."
# Delete existing DNS zone group if present (ensures clean state)
az network private-endpoint dns-zone-group delete -g "$RG_NAME" --endpoint-name pe-sql-hub -n dns-group-sql 2>/dev/null || true

# Create DNS zone group
export MSYS_NO_PATHCONV=1
DNS_ZONE_ID=$(az network private-dns zone show -g "$RG_NAME" -n "privatelink.database.windows.net" --query id -o tsv)
az network private-endpoint dns-zone-group create -g "$RG_NAME" -n dns-group-sql \
  --endpoint-name pe-sql-hub \
  --private-dns-zone "$DNS_ZONE_ID" --zone-name sql
unset MSYS_NO_PATHCONV

# Wait for DNS records to propagate
echo "Waiting for DNS records to propagate..."
sleep 10

# Verify DNS records were created
DNS_RECORD_COUNT=$(az network private-dns record-set a list -g "$RG_NAME" -z privatelink.database.windows.net --query "length(@)" -o tsv)
if [ "$DNS_RECORD_COUNT" -gt 0 ]; then
  echo "DNS records successfully created."
else
  echo "WARNING: No DNS records found. Private endpoint may not resolve correctly."
fi

# 7. (Optional) Add local PC IP to SQL Server firewall for testing allowing direct connection from your development machine
echo "Adding local PC IP to SQL Server firewall for testing..."
LOCAL_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "")
if [ -n "$LOCAL_IP" ]; then
  echo "Detected local IP: $LOCAL_IP"
  # Temporarily enable public network access for the local PC
  az sql server update -g "$RG_NAME" -n "$SERVER_NAME" --set publicNetworkAccess=Enabled 2>/dev/null || true
  
  # Add firewall rule
  az sql server firewall-rule create \
    -g "$RG_NAME" \
    -s "$SERVER_NAME" \
    -n AllowLocalPC \
    --start-ip-address "$LOCAL_IP" \
    --end-ip-address "$LOCAL_IP" 2>/dev/null || \
  az sql server firewall-rule update \
    -g "$RG_NAME" \
    -s "$SERVER_NAME" \
    -n AllowLocalPC \
    --start-ip-address "$LOCAL_IP" \
    --end-ip-address "$LOCAL_IP"
  
  echo "Firewall rule 'AllowLocalPC' created for IP: $LOCAL_IP"
  echo "NOTE: Public access is ENABLED for testing. Disable with:"
  echo "  az sql server update -g $RG_NAME -n $SERVER_NAME --set publicNetworkAccess=Disabled"
else
  echo "Could not detect local IP. Skipping firewall rule creation."
  echo "SQL Server is only accessible via private endpoint from Azure VNets."
fi

echo "------------------------------------------------"
echo "DATABASE DEPLOYMENT COMPLETE"
echo "Server: $SERVER_NAME.database.windows.net"
echo "User: $ADMIN_USER"
echo "Private IP: $(az network private-endpoint show -g "$RG_NAME" -n pe-sql-hub --query 'customDnsConfigs[0].ipAddresses[0]' -o tsv 2>/dev/null || echo 'pending')"
if [ -n "$LOCAL_IP" ]; then
  echo "Local PC IP allowed: $LOCAL_IP"
fi
echo "------------------------------------------------"
