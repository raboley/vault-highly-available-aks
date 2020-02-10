# ---------------------------
# Azure Key Vault
# ---------------------------
variable "resource_group" {
  description = "the MC_ resource group created by the aks cluster"
  default = "MC_dev_dev-aks_westus"
}


variable "tenant_id" {
  default = ""
}

variable "key_name" {
  description = "Azure Key Vault key name"
  default     = "generated-key"
}

variable "location" {
  description = "Azure location where the Key Vault resource to be created"
  default     = "eastus"
}

variable "environment" {
  default = "learn"
}
