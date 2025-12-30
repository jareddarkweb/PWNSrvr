```hcl
variable "location" {
  description = "Azure Region"
  default     = "East US"
}

variable "resource_group_name" {
  description = "Name of the Resource Group"
  default     = "rg-pwnmachine"
}

variable "environment_name" {
  description = "Name of the Container Apps Environment"
  default     = "aca-env-pwnmachine"
}

variable "lets_encrypt_email" {
  description = "Email for Lets Encrypt"
  type        = string
}

variable "pdns_api_key" {
  description = "PowerDNS API Key"
  type        = string
  sensitive   = true
  default     = "pdns-secret"
}

variable "pdns_mysql_root_password" {
  description = "MySQL Root Password"
  type        = string
  sensitive   = true
  default     = "pdns"
}

variable "acr_name" {
  description = "Name of the Azure Container Registry (must be globally unique)"
  default     = "acrpwnmachine001"
}

# Provider Configuration
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Resource Group
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
}

# Networking (VNet & Subnet)
resource "azurerm_virtual_network" "vnet" {
  name                = "vnet-pwnmachine"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "subnet_aca" {
  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.0.0/23"]

  delegation {
    name = "aca-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/action"]
    }
  }
}

# Storage for Persistence (Azure Files)
resource "azurerm_storage_account" "sa" {
  name                     = "sapwnmachine${random_string.suffix.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_storage_share" "share_pdns_data" {
  name                 = "powerdns-data"
  storage_account_name = azurerm_storage_account.sa.name
  quota                = 5
}

resource "azurerm_storage_share" "share_pdns_logs" {
  name                 = "powerdns-logs"
  storage_account_name = azurerm_storage_account.sa.name
  quota                = 5
}

resource "azurerm_storage_share" "share_redis_data" {
  name                 = "redis-data"
  storage_account_name = azurerm_storage_account.sa.name
  quota                = 5
}

resource "azurerm_storage_share" "share_traefik_data" {
  name                 = "traefik-data"
  storage_account_name = azurerm_storage_account.sa.name
  quota                = 5
}

resource "azurerm_storage_share" "share_traefik_logs" {
  name                 = "traefik-logs"
  storage_account_name = azurerm_storage_account.sa.name
  quota                = 5
}

# Container Registry
resource "azurerm_container_registry" "acr" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  sku                 = "Basic"
  admin_enabled       = true
}

# Container Apps Environment
resource "azurerm_container_app_environment" "env" {
  name                           = var.environment_name
  location                       = azurerm_resource_group.rg.location
  resource_group_name            = azurerm_resource_group.rg.name
  infrastructure_subnet_id       = azurerm_subnet.subnet_aca.id
  internal_load_balancer_enabled = false # Set to true if you don't want public IPs
}

# Link Storage to Environment
resource "azurerm_container_app_environment_storage" "mnt_pdns_data" {
  name                         = "mnt-powerdns-data"
  container_app_environment_id = azurerm_container_app_environment.env.id
  account_name                 = azurerm_storage_account.sa.name
  share_name                   = azurerm_storage_share.share_pdns_data.name
  access_key                   = azurerm_storage_account.sa.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_environment_storage" "mnt_pdns_logs" {
  name                         = "mnt-powerdns-logs"
  container_app_environment_id = azurerm_container_app_environment.env.id
  account_name                 = azurerm_storage_account.sa.name
  share_name                   = azurerm_storage_share.share_pdns_logs.name
  access_key                   = azurerm_storage_account.sa.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_environment_storage" "mnt_redis_data" {
  name                         = "mnt-redis-data"
  container_app_environment_id = azurerm_container_app_environment.env.id
  account_name                 = azurerm_storage_account.sa.name
  share_name                   = azurerm_storage_share.share_redis_data.name
  access_key                   = azurerm_storage_account.sa.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_environment_storage" "mnt_traefik_data" {
  name                         = "mnt-traefik-data"
  container_app_environment_id = azurerm_container_app_environment.env.id
  account_name                 = azurerm_storage_account.sa.name
  share_name                   = azurerm_storage_share.share_traefik_data.name
  access_key                   = azurerm_storage_account.sa.primary_access_key
  access_mode                  = "ReadWrite"
}

resource "azurerm_container_app_environment_storage" "mnt_traefik_logs" {
  name                         = "mnt-traefik-logs"
  container_app_environment_id = azurerm_container_app_environment.env.id
  account_name                 = azurerm_storage_account.sa.name
  share_name                   = azurerm_storage_share.share_traefik_logs.name
  access_key                   = azurerm_storage_account.sa.primary_access_key
  access_mode                  = "ReadWrite"
}

# Service 1: PowerDNS DB (MariaDB)
resource "azurerm_container_app" "pdns_db" {
  name                         = "pm-powerdns-db"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  template {
    container {
      name   = "mariadb"
      image  = "mariadb@sha256:0c3c560359a6da112134a52122aa9b78fec5f9dd292a01ee7954de450f25f0c1"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "MYSQL_ROOT_PASSWORD"
        value = var.pdns_mysql_root_password
      }
      env {
        name  = "MYSQL_DATABASE"
        value = "pdns"
      }

      volume_mounts {
        name = "vol-pdns-data"
        path = "/var/lib/mysql"
      }
    }
    volume {
      name         = "vol-pdns-data"
      storage_name = azurerm_container_app_environment_storage.mnt_pdns_data.name
      storage_type = "AzureFile"
    }
  }
}

# Service 2: PowerDNS
# Note: ACA Ingress supports TCP/HTTP. UDP ingress requires external LB integration or Gateway.
# This config exposes TCP 53.
resource "azurerm_container_app" "pdns" {
  name                         = "pm-powerdns"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 53
    transport        = "tcp"
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  secret {
    name  = "pdns-api-key"
    value = var.pdns_api_key
  }
  
  secret {
    name  = "db-password"
    value = var.pdns_mysql_root_password
  }

  template {
    container {
      name   = "powerdns"
      # Assuming image is pushed to ACR. Replace with actual path if different.
      image  = "${azurerm_container_registry.acr.login_server}/powerdns:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "MYSQL_HOST"
        value = azurerm_container_app.pdns_db.name # Resolves internally via ACA DNS
      }
      env {
        name  = "MYSQL_USER"
        value = "root"
      }
      env {
        name        = "MYSQL_PASSWORD"
        secret_name = "db-password"
      }
      env {
        name  = "MYSQL_DATABASE"
        value = "pdns"
      }
      env {
        name        = "API_KEY"
        secret_name = "pdns-api-key"
      }

      volume_mounts {
        name = "vol-pdns-logs"
        path = "/logs/pdns"
      }
    }

    volume {
      name         = "vol-pdns-logs"
      storage_name = azurerm_container_app_environment_storage.mnt_pdns_logs.name
      storage_type = "AzureFile"
    }
  }
}

# Service 3: Redis
resource "azurerm_container_app" "redis" {
  name                         = "pm-redis"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  # Internal only
  ingress {
    external_enabled = false
    target_port      = 6379
    transport        = "tcp"
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  template {
    container {
      name   = "redis"
      image  = "redis:latest"
      cpu    = 0.5
      memory = "1Gi"
      
      # Command override
      command = ["redis-server", "--appendonly", "yes"]

      volume_mounts {
        name = "vol-redis-data"
        path = "/data"
      }
    }
    volume {
      name         = "vol-redis-data"
      storage_name = azurerm_container_app_environment_storage.mnt_redis_data.name
      storage_type = "AzureFile"
    }
  }
}

# Service 4: Traefik
resource "azurerm_container_app" "traefik" {
  name                         = "pm-traefik"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  ingress {
    external_enabled = true
    target_port      = 80 # Mapping 80. Azure ACA manages 443 termination usually, but Traefik handles it here.
    transport        = "tcp"
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
    # Note: ACA Ingress maps external 80/443 to target_port. 
    # Because Traefik expects both, we map 80 here. 
    # For full 443 passthrough to Traefik, additional specific TCP settings are needed 
    # or Traefik runs behind the ACA Envoy proxy.
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  secret {
    name  = "pdns-api-key"
    value = var.pdns_api_key
  }

  template {
    container {
      name   = "traefik"
      image  = "${azurerm_container_registry.acr.login_server}/traefik:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "TRAEFIK_PROVIDERS_REDIS_ENDPOINTS"
        value = "${azurerm_container_app.redis.name}:6379"
      }
      env {
        name  = "TRAEFIK_PROVIDERS_REDIS_ROOTKEY"
        value = "traefik"
      }
      env {
        name        = "PDNS_API_KEY"
        secret_name = "pdns-api-key"
      }
      env {
        name  = "PDNS_API_URL"
        # PowerDNS API usually runs on 8081 inside the container based on standard configs
        # Using the internal DNS name of the PowerDNS app.
        value = "http://${azurerm_container_app.pdns.name}:8081/" 
      }
      env {
        name  = "LETS_ENCRYPT_EMAIL"
        value = var.lets_encrypt_email
      }

      volume_mounts {
        name = "vol-traefik-data"
        path = "/data"
      }
      volume_mounts {
        name = "vol-traefik-logs"
        path = "/logs/traefik"
      }
    }
    volume {
      name         = "vol-traefik-data"
      storage_name = azurerm_container_app_environment_storage.mnt_traefik_data.name
      storage_type = "AzureFile"
    }
    volume {
      name         = "vol-traefik-logs"
      storage_name = azurerm_container_app_environment_storage.mnt_traefik_logs.name
      storage_type = "AzureFile"
    }
  }
}

# Service 5: Manager
resource "azurerm_container_app" "manager" {
  name                         = "pm-manager"
  container_app_environment_id = azurerm_container_app_environment.env.id
  resource_group_name          = azurerm_resource_group.rg.name
  revision_mode                = "Single"

  # Internal logic, likely no incoming ports needed or Traefik routes to it.
  # Assuming internal traffic only.
  ingress {
    external_enabled = false
    target_port      = 80
    traffic_weight {
      percentage      = 100
      latest_revision = true
    }
  }

  registry {
    server               = azurerm_container_registry.acr.login_server
    username             = azurerm_container_registry.acr.admin_username
    password_secret_name = "acr-password"
  }

  secret {
    name  = "acr-password"
    value = azurerm_container_registry.acr.admin_password
  }

  secret {
    name  = "pdns-api-key"
    value = var.pdns_api_key
  }

  template {
    container {
      name   = "manager"
      image  = "${azurerm_container_registry.acr.login_server}/pm-manager:latest"
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "PM_REDIS_HOST"
        value = "redis://${azurerm_container_app.redis.name}"
      }
      env {
        name  = "PM_POWERDNS_HTTP_API"
        value = "http://${azurerm_container_app.pdns.name}:8081"
      }
      env {
        name        = "PM_POWERDNS_HTTP_API_KEY"
        secret_name = "pdns-api-key"
      }
    }
  }
}
```
