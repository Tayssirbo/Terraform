###############################################################################
# Locals
###############################################################################

locals {
  name = "${var.project}-${var.environment}"

  tags = merge(var.extra_tags, {
    environment = var.environment
    project     = var.project
    cost_center = var.cost_center
    purpose     = "llm-inference"
    managed_by  = "terraform"
  })
}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
  numeric = true
}

###############################################################################
# Resource group
###############################################################################

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name}"
  location = var.location
  tags     = local.tags
}

###############################################################################
# Network
###############################################################################

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name}"
  address_space       = ["10.42.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_subnet" "main" {
  name                 = "snet-${local.name}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.42.1.0/24"]
}

resource "azurerm_network_security_group" "main" {
  name                = "nsg-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.allowed_source_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "allow-stack-services"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = var.service_ports
    source_address_prefixes    = var.allowed_source_cidrs
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "deny-all-other-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_public_ip" "main" {
  name                = "pip-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_network_interface" "main" {
  name                           = "nic-${local.name}"
  location                       = azurerm_resource_group.main.location
  resource_group_name            = azurerm_resource_group.main.name
  accelerated_networking_enabled = true
  tags                           = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.main.id
  }
}

resource "azurerm_network_interface_security_group_association" "main" {
  network_interface_id      = azurerm_network_interface.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

###############################################################################
# Virtual machine
###############################################################################

resource "azurerm_linux_virtual_machine" "main" {
  name                = "vm-${local.name}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = local.tags

  network_interface_ids = [azurerm_network_interface.main.id]

  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  encryption_at_host_enabled = var.encryption_at_host_enabled

  os_disk {
    name                 = "osdisk-${local.name}"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  priority        = var.use_spot ? "Spot" : "Regular"
  eviction_policy = var.use_spot ? "Deallocate" : null
  max_bid_price   = var.use_spot ? var.spot_max_price : null

  custom_data = base64encode(templatefile("${path.module}/cloud-init.tftpl", {
    admin_username        = var.admin_username
    install_nvidia_driver = var.install_nvidia_driver
    nvidia_driver_branch  = var.nvidia_driver_branch
  }))

  boot_diagnostics {}
}

###############################################################################
# Persistent model storage
#
# Deliberately a managed disk rather than the SKU's local disk: local and temp
# storage is wiped on deallocation, and deallocating nightly is the primary cost
# control. Weights must survive it.
###############################################################################

resource "azurerm_managed_disk" "models" {
  name                 = "disk-models-${local.name}-${random_string.suffix.result}"
  location             = azurerm_resource_group.main.location
  resource_group_name  = azurerm_resource_group.main.name
  storage_account_type = var.models_disk_type
  create_option        = "Empty"
  disk_size_gb         = var.models_disk_size_gb
  tags                 = local.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "models" {
  managed_disk_id    = azurerm_managed_disk.models.id
  virtual_machine_id = azurerm_linux_virtual_machine.main.id
  lun                = 0
  caching            = "ReadOnly"
}

###############################################################################
# Auto-shutdown
#
# Requires the Microsoft.DevTestLab resource provider to be registered on the
# subscription. See README prerequisites.
###############################################################################

resource "azurerm_dev_test_global_vm_shutdown_schedule" "main" {
  count = var.auto_shutdown_enabled ? 1 : 0

  virtual_machine_id    = azurerm_linux_virtual_machine.main.id
  location              = azurerm_resource_group.main.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = local.tags

  notification_settings {
    enabled         = true
    time_in_minutes = 30
    email           = var.auto_shutdown_notification_email
  }
}
