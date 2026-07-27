output "resource_group" {
  description = "Resource group holding the demo environment."
  value       = azurerm_resource_group.pl300.name
}

output "vm_name" {
  description = "Azure resource name of the VM (used by the start/stop scripts)."
  value       = azurerm_windows_virtual_machine.pl300.name
}

output "public_ip" {
  description = "Public IP address for RDP and SQL."
  value       = azurerm_public_ip.vm.ip_address
}

output "fqdn" {
  description = "Stable DNS name - prefer this over the IP, it survives a stop/start."
  value       = azurerm_public_ip.vm.fqdn
}

output "rdp_target" {
  description = "Paste into Remote Desktop / Microsoft Remote Desktop."
  value       = "${azurerm_public_ip.vm.fqdn}:3389"
}

output "admin_username" {
  description = "RDP username."
  value       = var.admin_username
}

output "admin_password" {
  description = "RDP password. Retrieve with: terraform output -raw admin_password"
  value       = local.admin_password
  sensitive   = true
}

output "sql_server_local" {
  description = "SQL Server instance name to use from inside the VM."
  value       = "localhost"
}

output "sql_server_remote" {
  description = "SQL Server endpoint to use from your laptop (allowed_source_ip only)."
  value       = "${azurerm_public_ip.vm.fqdn},1433"
}

output "sql_admin_login" {
  description = "SQL Server sysadmin login (SQL authentication)."
  value       = var.sql_admin_login
}

output "sql_admin_password" {
  description = "SQL login password - same as the RDP password. Retrieve with: terraform output -raw sql_admin_password"
  value       = local.admin_password
  sensitive   = true
}

output "databases" {
  description = "Databases restored on the instance."
  value       = ["AdventureWorks2022", "AdventureWorksDW2022"]
}

output "demo_data_path_on_vm" {
  description = "Where the CSV/Excel/JSON/XML/PDF demo files live on the VM."
  value       = "C:\\PL300\\Data"
}

output "storage_account" {
  description = "Storage account also serving the demo files as an Azure Blob data source."
  value       = azurerm_storage_account.demo.name
}

output "demo_data_container_url" {
  description = "Blob container URL - use with the Power BI 'Azure Blob Storage' connector."
  value       = "${azurerm_storage_account.demo.primary_blob_endpoint}${azurerm_storage_container.demo_data.name}"
}

output "storage_account_key" {
  description = "Storage key for the Azure Blob Storage connector demo. Retrieve with: terraform output -raw storage_account_key"
  value       = azurerm_storage_account.demo.primary_access_key
  sensitive   = true
}

output "auto_shutdown" {
  description = "Nightly auto-shutdown schedule, if enabled."
  value       = var.auto_shutdown_enabled ? "${var.auto_shutdown_time} ${var.auto_shutdown_timezone}" : "disabled"
}

output "estimated_hourly_cost_usd" {
  description = "Compute + Windows licence while the VM is running. Storage and IP bill separately (~$25/month)."
  value       = "~0.38 (VM running) / ~0.00 (deallocated)"
}

output "connection_summary" {
  description = "Everything you need to get in, minus the passwords."
  value       = <<-EOT

    PL-300 demo environment
    =======================
    RDP           : ${azurerm_public_ip.vm.fqdn}   (port 3389)
    Username      : ${var.admin_username}
    Password      : terraform output -raw admin_password

    SQL (on VM)   : localhost
    SQL (remote)  : ${azurerm_public_ip.vm.fqdn},1433
    SQL login     : ${var.sql_admin_login}  (SQL auth; same password as RDP)
    Databases     : AdventureWorks2022, AdventureWorksDW2022

    Demo files    : C:\PL300\Data  (CSV, Excel, JSON, XML, PDF)
    Blob source   : ${azurerm_storage_account.demo.primary_blob_endpoint}${azurerm_storage_container.demo_data.name}
    Demo guide    : C:\PL300\DEMO-GUIDE.md  (also on the desktop)

    Auto-shutdown : ${var.auto_shutdown_enabled ? "${var.auto_shutdown_time} ${var.auto_shutdown_timezone}" : "disabled"}
    Stop the VM   : ./scripts/stop-vm.sh     (billing stops when deallocated)
    Start the VM  : ./scripts/start-vm.sh
  EOT
}
