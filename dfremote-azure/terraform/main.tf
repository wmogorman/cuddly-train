terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100.0"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "prefix" {
  description = "A short name to prefix resources (e.g., dfremote)"
  type        = string
  default     = "dfremote"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "dfremote-rg"
}

variable "container_image" {
  description = "Docker image to run"
  type        = string
  default     = "mifki/dfremote"
}

variable "udp_port" {
  description = "UDP port to expose"
  type        = number
  default     = 1235
}

variable "mount_path" {
  description = "Mount path inside the container"
  type        = string
  default     = "/df/data/save"
}

variable "file_share_name" {
  description = "Azure File Share name"
  type        = string
  default     = "dfremote-saves"
}

variable "cpu_cores" {
  description = "Container CPU cores"
  type        = number
  default     = 1
}

variable "memory_gb" {
  description = "Container memory in GB"
  type        = number
  default     = 1
}

resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

resource "random_string" "sa_suffix" {
  length  = 8
  lower   = true
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_storage_account" "sa" {
  name                     = "${var.prefix}sa${random_string.sa_suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  allow_blob_public_access = false
  min_tls_version          = "TLS1_2"
  enable_https_traffic_only = true
}

resource "azurerm_storage_share" "share" {
  name                 = var.file_share_name
  storage_account_name = azurerm_storage_account.sa.name
  quota                = 100 # GB
}

resource "azurerm_container_group" "aci" {
  name                = "${var.prefix}-aci"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  ip_address_type     = "Public"
  dns_name_label      = null

  exposed_port {
    port     = var.udp_port
    protocol = "UDP"
  }

  container {
    name   = var.prefix
    image  = var.container_image
    cpu    = var.cpu_cores
    memory = var.memory_gb

    ports {
      port     = var.udp_port
      protocol = "UDP"
    }

    volume {
      name       = "saves"
      mount_path = var.mount_path
      read_only  = false
      share_name = azurerm_storage_share.share.name

      storage_account_name = azurerm_storage_account.sa.name
      storage_account_key  = azurerm_storage_account.sa.primary_access_key
    }
  }
}
output "public_ip" {
  value = azurerm_container_group.aci.ip_address
}

output "file_share_unc" {
  value = "//${azurerm_storage_account.sa.name}.file.core.windows.net/${azurerm_storage_share.share.name}"
}
