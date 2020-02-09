provider "azurerm" {
  
}

data "azurerm_resource_group" "vault" {
  name = "MC_awdresourcegroup_awdakscluster_westus"
}

resource "random_id" "keyvault" {
  byte_length = 4
}

data "azurerm_client_config" "current" {
}

resource "azurerm_key_vault" "vault" {
  name                        = "${var.environment}-vault-${random_id.keyvault.hex}"
  location                    = data.azurerm_resource_group.vault.location
  resource_group_name         = data.azurerm_resource_group.vault.name
  enabled_for_deployment      = true
  enabled_for_disk_encryption = true
  tenant_id                   = var.tenant_id

  sku_name = "standard"

  tags = {
    environment = "${var.environment}"
  }

  access_policy {
    tenant_id = var.tenant_id

    #object_id = "${var.object_id}"
    object_id = data.azurerm_client_config.current.service_principal_object_id

    key_permissions = [
      "get",
      "list",
      "create",
      "delete",
      "update",
      "wrapKey",
      "unwrapKey",
    ]
  }

  network_acls {
    default_action = "Allow"
    bypass         = "AzureServices"
  }
}

resource "azurerm_key_vault_key" "generated" {
  name         = var.key_name
  key_vault_id = azurerm_key_vault.vault.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]
}

output "key_vault_name" {
  value = "${azurerm_key_vault.vault.name}"
}
