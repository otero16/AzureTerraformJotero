# Configure the Azure Provider
provider "azurerm" {
  features {}
}

variable "location" {
  type = string
  default = "East US 2"
}

variable "IPAddress" {
  type = string
  description = "Enter your home IP address. For example: 1.2.3.4 . If you are on MSIT CorpNet, you can just enter 127.0.0.1 as your IP , which is a non-routable IP address (As you don't need an NSG when accessing via CorpNet)."
  
  validation {
    condition = can(regex("\\b(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\b", var.IPAddress))
	error_message = "Could not parse IP address. Please ensure the IP is a valid IPv4 IP address."
  }
}

locals {
  cidr = "${cidrhost("${var.IPAddress}/24", 0)}/24"
}

variable "subnetCount" {
    type = number
    description = "Enter the number of Vnets to create (betweeen 2 and 99)."
    default =4
    validation {
      condition     = var.subnetCount > 1 && var.subnetCount < 100
      error_message = "Please enter a value betweeon 2 and 99." 
    }
}

locals {
    rangestring=toset(formatlist("%02.0f", toset(range(1,var.subnetCount+1))))
}

################################
# AD to get user's alias
################################

provider "azuread" {
    tenant_id = "72f988bf-86f1-41af-91ab-2d7cd011db47"
}

data "azurerm_client_config" "current" {}

data "azuread_user" "example" {
    object_id   = data.azurerm_client_config.current.object_id
}

################################
# Resource Group
################################

resource "azurerm_resource_group" "resourcegroup" {
  name     = "bgpLabResourceGroup"
  location = var.location
}

################################
# Virtual Networks & Subnets
################################

# Hub Vnet
resource "azurerm_virtual_network" "vnet" {
  name                = "virtualNetwork"
  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = var.location
  address_space       = ["10.100.0.0/16"]
}

resource "azurerm_subnet" "subnets" {
  for_each = local.rangestring
    name                 = "subnet${each.key}"
    resource_group_name  = azurerm_resource_group.resourcegroup.name
    virtual_network_name = azurerm_virtual_network.vnet.name
    address_prefixes     = ["10.100.${trimprefix(each.key, "0")}.0/24"]
}

################################
# NSG for all subnets
################################

resource "azurerm_network_security_group" "primaryNSG" {
  name                = "primaryNSG"
  location            = azurerm_resource_group.resourcegroup.location
  resource_group_name = azurerm_resource_group.resourcegroup.name

  security_rule {
    access                                     = "Allow"
    description                                = "Allow from External IP"
    destination_address_prefix                 = "*"
    destination_port_range                     = "*"
    direction                                  = "Inbound"
    name                                       = "externalCidr"
    priority                                   = 100
    protocol                                   = "*"
    source_address_prefix                      = local.cidr
    source_port_range                          = "*"
  }
  security_rule {
    access                                     = "Allow"
    description                                = "CSS Governance Security Rule.  Allow Corpnet inbound.  https://aka.ms/casg"
    destination_address_prefix                 = "*"
    destination_port_range                     = "*"
    direction                                  = "Inbound"
    name                                       = "CASG-AllowCorpNetPublic"
    priority                                   = 2700
    protocol                                   = "*"
    source_address_prefix                      = "CorpNetPublic"
    source_port_range                          = "*"
  }
  security_rule {
    access                                     = "Allow"
    description                                = "CSS Governance Security Rule.  Allow SAW inbound.  https://aka.ms/casg"
    destination_address_prefix                 = "*"
    destination_port_range                     = "*"
    direction                                  = "Inbound"
    name                                       = "CASG-AllowCorpNetSaw"
    priority                                   = 2701
    protocol                                   = "*"
    source_address_prefix                      = "CorpNetSaw"
    source_port_range                          = "*"
  }

  tags = {
    "Creator" = "Automatically added by CASG Azure Policy"
    "CASG Info" = "https://aka.ms/cssbaselinesecurity"
  }
}

# Apply NSG to Subnets
resource "azurerm_subnet_network_security_group_association" "nsgapply" {
  for_each = local.rangestring
    subnet_id                 = azurerm_subnet.subnets[each.key].id
    network_security_group_id = azurerm_network_security_group.primaryNSG.id
}

################################
# Virtual Machine(s)
################################

# Network Interface
resource "azurerm_network_interface" "nics" {
  for_each = local.rangestring
    name                = "VM${each.key}-nic"
    location            = azurerm_resource_group.resourcegroup.location
    resource_group_name = azurerm_resource_group.resourcegroup.name

    ip_configuration {
        name                          = "ipconfig1"
        subnet_id                     = azurerm_subnet.subnets[each.key].id
        private_ip_address_allocation = "Static"
        private_ip_address            = "10.100.${trimprefix(each.key, "0")}.${trimprefix(each.key, "0")}0"
        public_ip_address_id          = azurerm_public_ip.pips[each.key].id
    }
}

# Public IP Address
resource "azurerm_public_ip" "pips" {
  for_each = local.rangestring
    name                = "VM${each.key}-IP"
    resource_group_name = azurerm_resource_group.resourcegroup.name
    location            = azurerm_resource_group.resourcegroup.location
    allocation_method   = "Static"
    domain_name_label   = "anpbgplab-vm${each.key}-${data.azuread_user.example.mail_nickname}"
}

# cloud-init for VMs
data "template_cloudinit_config" "cloudinit" {
  for_each = local.rangestring
    gzip          = true
    base64_encode = true

    part {
      content_type = "text/cloud-config"
      content      = "fqdn: VM${each.key}"
    }
}

# Virtual Machine
resource "azurerm_virtual_machine" "vms" {
  for_each = local.rangestring

  name                = "VM${each.key}"
  resource_group_name = azurerm_resource_group.resourcegroup.name
  location            = azurerm_resource_group.resourcegroup.location
  vm_size             = "Standard_B1ls"
  network_interface_ids = [azurerm_network_interface.nics[each.key].id]
  
  os_profile_linux_config {
    disable_password_authentication = false
  }

  storage_image_reference {
    publisher = "vyos"
    offer     = "vyos"
    sku       = "1.3"
    version   = "latest"
  }

  os_profile {
    computer_name  = "VM${each.key}"
    admin_username = "secretuser"
    admin_password = "Corp123!"
    custom_data = data.template_cloudinit_config.cloudinit[each.key].rendered
  }

  storage_os_disk {
    name              = "VM${each.key}-osDisk"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Premium_LRS"
  }
}

################################
# Outputs
################################

data "azurerm_public_ip" "pips" {
  for_each = local.rangestring
    name                = azurerm_public_ip.pips[each.key].name
    resource_group_name = azurerm_resource_group.resourcegroup.name
    depends_on = [ azurerm_public_ip.pips, azurerm_virtual_machine.vms ]
}

output "VM_PIPs" {
  value = [for i in data.azurerm_public_ip.pips : "${i.name}: ${i.ip_address} / ${i.fqdn}"]  
}
