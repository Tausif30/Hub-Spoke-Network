<h1 align="center">Azure Secure Hub-and-Spoke Network Project</h1>

<hr>

<h2>1. Project Overview</h2>

<p>
    This project implements a secure, scalable <strong>Hub-and-Spoke</strong> network topology in Azure. The design uses a central "Hub" Virtual Network (VNet) to consolidate shared services, while "Spoke" VNets host isolated workloads (Production and Non-Production), enhancing security and operational efficiency. The entire infrastructure is deployed using idempotent Bash scripts.
</p>

<h3>Project Highlights</h3>
<ul>
    <li><strong>Centralized Security:</strong> Azure Firewall (AZFW_VNet SKU) is deployed in the Hub, combined with User-Defined Routes (UDRs), to ensure all traffic between Spokes and the internet is inspected.</li>
    <li><strong>Zero Trust Data:</strong> Azure SQL Database is secured using <strong>Private Link</strong> and a <strong>Private DNS Zone</strong>, completely eliminating public internet exposure for the database.</li>
    <li><strong>Hybrid Readiness:</strong> Secure remote access is enabled via a <strong>VPN Gateway</strong> and <strong>Azure Bastion</strong>, providing a foundation for hybrid cloud integration.</li>
    <li><strong>Validated Segmentation:</strong> The routing configuration strictly enforces isolation, confirming zero unauthorized packet movement between the Prod and Non-Prod environments.</li>
</ul>

<hr>

<h2>2. Network Topology & Components</h2>

<p>
    The architecture is logically divided into a Hub VNet and two Spoke VNets, with communication managed by VNet Peering and controlled by the Azure Firewall.
</p>

<p align="center">

![Hub-Spoke-Tokyo](https://github.com/user-attachments/assets/fd36fe34-dd9a-4bc8-90eb-aa6e3983d24d)
    
</p>
<p align="center"><em>Figure 1: Azure Hub-and-Spoke Logical Diagram</em></p>


<h3>The Hub VNet (<code>vnet-hub-secure</code> - 10.0.0.0/16)</h3>
<p>Hosts all shared network and services which are:</p>
<ul>
    <li><strong>Azure Firewall (<code>fw-hub</code>):</strong> The security choke point. All egress and inter-VNet traffic is routed through its Private IP (<code>10.0.1.4</code>).</li>
    <li><strong>VPN Gateway (<code>vpn-gw-hub</code>):</strong> Provides encrypted site-to-site or point-to-site connectivity. VNet Peering utilizes <strong>Gateway Transit</strong> to allow Spokes to use this connection.</li>
    <li><strong>Azure Bastion (<code>bastion-hub</code>):</strong> A managed service for secure RDP/SSH access to VMs using HTTPS (port 443), eliminating the need for public IPs on the workload VMs.</li>
    <li><strong>SQL Private Endpoint (<code>pe-sql-hub</code>):</strong> A network interface placed in the dedicated Database Subnet (<code>10.0.4.0/24</code>) that links to the Azure SQL PaaS service.</li>
</ul>

<h3>The Spoke VNets</h3>
<p>Isolated networks hosting the application environment:</p>
<ul>
    <li><strong>Production Spoke (<code>vnet-spoke-prod</code> - 10.1.0.0/16)</strong></li>
    <li><strong>Non-Production Spoke (<code>vnet-spoke-nonprod</code> - 10.2.0.0/16)</strong></li>
    <li><strong>Connectivity:</strong> Spoke-to-Spoke communication is disabled by default. Traffic must be peered to the Hub and then explicitly permitted by the Firewall's rules.</li>
</ul>

<h3>Network Controls</h3>
<ul>
    <li><strong>VNet Peering:</strong> Establishes the virtual connection that allows packets to travel between the Hub and Spokes using Azure's backbone network.</li>
    <li><strong>User Defined Routes (UDRs):</strong> Applied to Spoke subnets, these rules override Azure's default routing and force the <code>0.0.0.0/0</code> route (all internet-bound and inter-VNet traffic) to the Firewall's Private IP (<code>10.0.1.4</code>).</li>
    <li><strong>Private DNS Zones:</strong> A critical security component that ensures the SQL Database name resolves to its Private Endpoint IP (<code>10.0.4.x</code>) across all three peered VNets, bypassing all public DNS resolution.</li>
</ul>
