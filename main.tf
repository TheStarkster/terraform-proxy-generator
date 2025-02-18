################################################################################
# Provider and Azure CLI Data
################################################################################
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  # Using OIDC as specified
  use_oidc           = true
  features {}
  # Read subscription_id from data source
  subscription_id = data.external.azure_cli.result.subscription_id
}

data "external" "azure_cli" {
  program = [
    "az",
    "account",
    "show",
    "--query",
    "{ subscription_id: id }",
    "--output",
    "json"
  ]
}

################################################################################
# Resource Group
################################################################################
resource "azurerm_resource_group" "proxy_rg" {
  name     = "proxy-server-rg"
  location = "Central India"
}

################################################################################
# Virtual Network
################################################################################
resource "azurerm_virtual_network" "proxy_vnet" {
  name                = "proxy-vnet"
  location            = azurerm_resource_group.proxy_rg.location
  resource_group_name = azurerm_resource_group.proxy_rg.name
  address_space       = ["10.0.0.0/16"]
}

################################################################################
# Subnet
################################################################################
resource "azurerm_subnet" "proxy_subnet" {
  name                 = "proxy-subnet"
  resource_group_name  = azurerm_resource_group.proxy_rg.name
  virtual_network_name = azurerm_virtual_network.proxy_vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

################################################################################
# Public IPs (10 total)
################################################################################
resource "azurerm_public_ip" "proxy_public_ip" {
  count               = 10
  name                = "proxy-public-ip-${count.index + 1}"
  location            = azurerm_resource_group.proxy_rg.location
  resource_group_name = azurerm_resource_group.proxy_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

################################################################################
# Network Security Group (NSG)
################################################################################
resource "azurerm_network_security_group" "proxy_nsg" {
  name                = "proxy-nsg"
  location            = azurerm_resource_group.proxy_rg.location
  resource_group_name = azurerm_resource_group.proxy_rg.name

  # Rule for SSH (port 22)
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # Rule for Squid proxy (port 3128)
  security_rule {
    name                       = "Proxy"
    priority                   = 1002
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3128"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

################################################################################
# Network Interfaces (10 total)
################################################################################
resource "azurerm_network_interface" "proxy_nic" {
  count               = 10
  name                = "proxy-nic-${count.index + 1}"
  location            = azurerm_resource_group.proxy_rg.location
  resource_group_name = azurerm_resource_group.proxy_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.proxy_subnet.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.proxy_public_ip[count.index].id
  }
}

################################################################################
# Associate Network Security Group with Each NIC
################################################################################
resource "azurerm_network_interface_security_group_association" "proxy_nsg_association" {
  count                     = 10
  network_interface_id      = azurerm_network_interface.proxy_nic[count.index].id
  network_security_group_id = azurerm_network_security_group.proxy_nsg.id
}

################################################################################
# Linux VMs (10 total)
################################################################################
resource "azurerm_linux_virtual_machine" "proxy_vm" {
  count               = 10
  name                = "proxy-vm-${count.index + 1}"
  resource_group_name = azurerm_resource_group.proxy_rg.name
  location            = azurerm_resource_group.proxy_rg.location
  size                = "Standard_B1s"
  admin_username      = "azureuser"

  # Attach each VM to its corresponding NIC
  network_interface_ids = [
    azurerm_network_interface.proxy_nic[count.index].id
  ]

  # Use your local public key for SSH
  admin_ssh_key {
    username   = "azureuser"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    name                 = "proxy-disk-${count.index + 1}"
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  # Ubuntu 18.04
  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  # Startup script for installing and configuring Squid
  custom_data = base64encode(<<-EOF
              #!/bin/bash
              
              # Update and install Squid
              apt-get update
              DEBIAN_FRONTEND=noninteractive apt-get install -y squid
              
              # Backup original config
              cp /etc/squid/squid.conf /etc/squid/squid.conf.backup
              
              # Create new Squid configuration
              cat > /etc/squid/squid.conf <<'END'
              # Basic configuration
              http_port 3128
              
              # Access Control Lists (ACL)
              acl SSL_ports port 443
              acl Safe_ports port 80          # http
              acl Safe_ports port 21          # ftp
              acl Safe_ports port 443         # https
              acl Safe_ports port 70          # gopher
              acl Safe_ports port 210         # wais
              acl Safe_ports port 1025-65535  # unregistered ports
              acl Safe_ports port 280         # http-mgmt
              acl Safe_ports port 488         # gss-http
              acl Safe_ports port 591         # filemaker
              acl Safe_ports port 777         # multiling http
              acl CONNECT method CONNECT
              
              # Deny requests to unsafe ports
              http_access deny !Safe_ports
              
              # Deny CONNECT to other than secure SSL ports
              http_access deny CONNECT !SSL_ports
              
              # Allow localhost
              acl localhost src 127.0.0.1/32
              http_access allow localhost
              
              # Allow all other requests
              http_access allow all
              
              # Enhanced anonymity settings
              request_header_access From deny all
              request_header_access Server deny all
              request_header_access WWW-Authenticate deny all
              request_header_access Link deny all
              request_header_access Cache-Control deny all
              request_header_access Proxy-Connection deny all
              request_header_access X-Cache deny all
              request_header_access X-Cache-Lookup deny all
              request_header_access Via deny all
              request_header_access X-Forwarded-For deny all
              request_header_access Pragma deny all
              request_header_access Keep-Alive deny all
              
              # Disable cache headers
              via off
              forwarded_for delete
              follow_x_forwarded_for deny all
              request_header_access Authorization allow all
              request_header_access Proxy-Authorization allow all
              request_header_access Connection allow all
              request_header_access User-Agent allow all
              
              # Performance settings
              cache_mem 256 MB
              maximum_object_size 1024 MB
              cache_replacement_policy heap LFUDA
              
              # DNS settings
              dns_v4_first on
              
              # Logging
              access_log /var/log/squid/access.log
              cache_log /var/log/squid/cache.log
              
              # Replace or hide identifying headers
              header_replace User-Agent Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36
              header_replace From "Anonymous"
              
              # Additional anonymity settings
              request_header_access Referer deny all
              request_header_access X-Forwarded-Host deny all
              request_header_access X-Forwarded-Server deny all
              request_header_access X-Real-IP deny all
              
              # Hide client IP
              forwarded_for off
              request_header_access All deny all
              request_header_access Accept allow all
              request_header_access Accept-Charset allow all
              request_header_access Accept-Encoding allow all
              request_header_access Accept-Language allow all
              request_header_access Host allow all
              END
              
              # Set correct permissions
              chown -R proxy:proxy /etc/squid
              
              # Restart Squid to apply changes
              systemctl restart squid
              
              # Enable Squid on boot
              systemctl enable squid
              
              # Verify Squid is running (optional)
              systemctl status squid
              EOF
  )

  tags = {
    proxy_number = "proxy-${count.index + 1}"
  }
}

################################################################################
# Outputs
################################################################################
# Output a map of "proxy-1" => <ip_address>, ..., "proxy-10" => <ip_address>
output "proxy_public_ips" {
  description = "Public IP addresses of all proxy servers"
  value = {
    for idx, ip in azurerm_public_ip.proxy_public_ip :
    "proxy-${idx + 1}" => ip.ip_address
  }
}

# Output IP addresses in a comma-separated list
output "proxy_ips_array" {
  description = "Comma-separated list of proxy IPs"
  value       = join(",", [for ip in azurerm_public_ip.proxy_public_ip : ip.ip_address])
}