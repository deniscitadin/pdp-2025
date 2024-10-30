provider "azurerm" {
  features {}
}
variable "enabled" {
  type    = bool
  default = false  
}
resource "azurerm_managed_disk" "app_volume" {
  count = var.enabled ? 1 : 0
  name                = "app-volume"
  location            = "West US"  
  resource_group_name = "myResourceGroup"  
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = 1
}

output "volume" {
  value = [for volume in azurerm_managed_disk.app_volume : volume.id]
}