# ---------------------------------------------------------------------------
# PL-300 demo environment
#
#   Windows Server 2022 + SQL Server 2022 Developer (marketplace image)
#   + Power BI Desktop, SSMS, DAX Studio, Tabular Editor  (bootstrap.ps1)
#   + AdventureWorks2022 and AdventureWorksDW2022         (bootstrap.ps1)
#   + CSV / Excel / JSON / XML / PDF demo files           (demo-data.zip)
#
# The VM pulls its own bootstrap payload from blob storage using its system
# assigned managed identity, so no SAS tokens or storage keys are embedded in
# the extension settings.
# ---------------------------------------------------------------------------

locals {
  admin_password = coalesce(var.admin_password, random_password.admin.result)

  # Anything not listed keeps the storage default of application/octet-stream.
  content_types = {
    csv  = "text/csv"
    json = "application/json"
    xml  = "application/xml"
    pdf  = "application/pdf"
    xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    ps1  = "text/plain"
    sql  = "text/plain"
    md   = "text/markdown"
    zip  = "application/zip"
  }

  demo_files = fileset("${path.module}/../demo-data", "**/*")

  # Uploading a changed blob does not, on its own, make the VM fetch it again -
  # the extension's own configuration has to change too, or a demo-file edit
  # would silently leave stale data on the VM. Threading this hash through the
  # extension's command line ties the two together.
  payload_version = md5(join("", [
    filemd5("${path.module}/../scripts/bootstrap.ps1"),
    filemd5("${path.module}/../scripts/sql/configure-sql.sql"),
    filemd5("${path.module}/../scripts/sql/restore-adventureworks.sql"),
    data.archive_file.demo_data.output_md5,
  ]))
}

resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
  numeric = true
}

resource "random_password" "admin" {
  length      = 24
  min_lower   = 2
  min_upper   = 2
  min_numeric = 2
  min_special = 2
  # Windows and SQL Server both choke on quotes, backslashes and semicolons in
  # passwords that get passed through command lines and connection strings.
  override_special = "!#%*+-=?_"
}

resource "azurerm_resource_group" "pl300" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "pl300" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.42.0.0/16"]
  location            = azurerm_resource_group.pl300.location
  resource_group_name = azurerm_resource_group.pl300.name
  tags                = var.tags
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.pl300.name
  virtual_network_name = azurerm_virtual_network.pl300.name
  address_prefixes     = ["10.42.1.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.pl300.location
  resource_group_name = azurerm_resource_group.pl300.name
  tags                = var.tags

  security_rule {
    name                       = "AllowRDPFromInstructor"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = var.allowed_source_ip
    destination_address_prefix = "*"
  }

  # Lets you point a laptop-local Power BI Desktop or SSMS at the VM's SQL
  # instance, not just the copy running on the VM itself.
  security_rule {
    name                       = "AllowSQLFromInstructor"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "1433"
    source_address_prefix      = var.allowed_source_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllInbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_public_ip" "vm" {
  name                = "${var.prefix}-pip"
  location            = azurerm_resource_group.pl300.location
  resource_group_name = azurerm_resource_group.pl300.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "${var.prefix}-demo-${random_string.suffix.result}"
  tags                = var.tags
}

resource "azurerm_network_interface" "vm" {
  name                           = "${var.prefix}-nic"
  location                       = azurerm_resource_group.pl300.location
  resource_group_name            = azurerm_resource_group.pl300.name
  accelerated_networking_enabled = true
  tags                           = var.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm.id
  }
}

# ---------------------------------------------------------------------------
# Bootstrap payload in blob storage
# ---------------------------------------------------------------------------

resource "azurerm_storage_account" "demo" {
  name                            = "${var.prefix}demo${random_string.suffix.result}"
  resource_group_name             = azurerm_resource_group.pl300.name
  location                        = azurerm_resource_group.pl300.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  account_kind                    = "StorageV2"
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

# Bootstrap scripts the Custom Script Extension downloads.
resource "azurerm_storage_container" "bootstrap" {
  name                  = "bootstrap"
  storage_account_id    = azurerm_storage_account.demo.id
  container_access_type = "private"
}

# The demo files, kept as individual blobs so they double as an Azure Blob
# Storage data source for the "connect to cloud data" part of the class.
resource "azurerm_storage_container" "demo_data" {
  name                  = "demo-data"
  storage_account_id    = azurerm_storage_account.demo.id
  container_access_type = "private"
}

data "archive_file" "demo_data" {
  type        = "zip"
  source_dir  = "${path.module}/../demo-data"
  output_path = "${path.module}/../demo-data.zip"
}

resource "azurerm_storage_blob" "demo_data_zip" {
  name                 = "demo-data.zip"
  storage_container_id = azurerm_storage_container.bootstrap.id
  type                 = "Block"
  content_type         = local.content_types["zip"]
  source               = data.archive_file.demo_data.output_path
  content_md5          = data.archive_file.demo_data.output_md5
}

resource "azurerm_storage_blob" "bootstrap_ps1" {
  name                 = "bootstrap.ps1"
  storage_container_id = azurerm_storage_container.bootstrap.id
  type                 = "Block"
  content_type         = local.content_types["ps1"]
  source               = "${path.module}/../scripts/bootstrap.ps1"
  content_md5          = filemd5("${path.module}/../scripts/bootstrap.ps1")
}

resource "azurerm_storage_blob" "configure_sql" {
  name                 = "configure-sql.sql"
  storage_container_id = azurerm_storage_container.bootstrap.id
  type                 = "Block"
  content_type         = local.content_types["sql"]
  source               = "${path.module}/../scripts/sql/configure-sql.sql"
  content_md5          = filemd5("${path.module}/../scripts/sql/configure-sql.sql")
}

resource "azurerm_storage_blob" "restore_adventureworks" {
  name                 = "restore-adventureworks.sql"
  storage_container_id = azurerm_storage_container.bootstrap.id
  type                 = "Block"
  content_type         = local.content_types["sql"]
  source               = "${path.module}/../scripts/sql/restore-adventureworks.sql"
  content_md5          = filemd5("${path.module}/../scripts/sql/restore-adventureworks.sql")
}

resource "azurerm_storage_blob" "demo_file" {
  for_each = local.demo_files

  name                 = each.value
  storage_container_id = azurerm_storage_container.demo_data.id
  type                 = "Block"
  content_type         = lookup(local.content_types, lower(element(split(".", each.value), length(split(".", each.value)) - 1)), "application/octet-stream")
  source               = "${path.module}/../demo-data/${each.value}"
  content_md5          = filemd5("${path.module}/../demo-data/${each.value}")
}

# ---------------------------------------------------------------------------
# Virtual machine
# ---------------------------------------------------------------------------

resource "azurerm_windows_virtual_machine" "pl300" {
  name                  = "${var.prefix}-demo-vm"
  computer_name         = var.vm_name
  resource_group_name   = azurerm_resource_group.pl300.name
  location              = azurerm_resource_group.pl300.location
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = local.admin_password
  network_interface_ids = [azurerm_network_interface.vm.id]
  provision_vm_agent    = true
  tags                  = var.tags

  identity {
    type = "SystemAssigned"
  }

  os_disk {
    name                 = "${var.prefix}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  # SQL Server 2022 Developer edition on Windows Server 2022. Developer edition
  # is fully featured and carries no SQL licence charge - you pay compute and
  # the Windows licence only.
  source_image_reference {
    publisher = "MicrosoftSQLServer"
    offer     = "sql2022-ws2022"
    sku       = "sqldev-gen2"
    version   = "latest"
  }

  # The bootstrap script reboots at the end; don't let Windows Update fight it
  # during a live class.
  patch_mode                = "Manual"
  automatic_updates_enabled = false

  lifecycle {
    # Avoid surprise VM replacement when Microsoft publishes a new image
    # version of the SQL 2022 marketplace image.
    ignore_changes = [source_image_reference[0].version]
  }
}

# The SQL Server marketplace image does NOT grant NT AUTHORITY\SYSTEM the
# sysadmin role, and the Custom Script Extension runs as SYSTEM - so the
# bootstrap script cannot configure SQL Server over Windows authentication at
# all (it fails with Msg 15247, "User does not have permission to perform this
# action"). The SQL IaaS Agent extension creates a SQL-authentication sysadmin
# login through the Azure control plane instead, and the bootstrap then connects
# with that. It also enables mixed-mode auth, turns on TCP/IP and opens the
# Windows firewall for 1433.
#
# "PUBLIC" refers to the guest firewall only - inbound 1433 is still restricted
# to var.allowed_source_ip by the network security group.
resource "azurerm_mssql_virtual_machine" "pl300" {
  virtual_machine_id = azurerm_windows_virtual_machine.pl300.id
  sql_license_type   = "PAYG" # Developer edition carries no SQL licence charge

  sql_connectivity_type            = "PUBLIC"
  sql_connectivity_port            = 1433
  sql_connectivity_update_username = var.sql_admin_login
  sql_connectivity_update_password = local.admin_password

  tags = var.tags

  timeouts {
    create = "60m"
    update = "60m"
  }
}

# Lets anything running on the VM read the demo files from blob storage with no
# embedded credential - handy for the "connect to cloud data with a managed
# identity" discussion, and for extending bootstrap.ps1 later.
#
# NOTE: this is deliberately NOT how the Custom Script Extension below gets its
# payload. Storage data-plane RBAC is eventually consistent and took over two
# minutes to become effective here, which is long enough for a freshly created
# extension to fail its download with 403. A container SAS is effective
# immediately, so the extension uses that instead and the deployment has no race
# to lose.
resource "azurerm_role_assignment" "vm_blob_reader" {
  scope                = azurerm_storage_account.demo.id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_windows_virtual_machine.pl300.identity[0].principal_id
}

# Frozen at first apply so the SAS window - and therefore the extension's
# protected_settings - stays stable across later plans instead of drifting on
# every run.
resource "time_static" "sas_start" {}

data "azurerm_storage_account_blob_container_sas" "bootstrap" {
  connection_string = azurerm_storage_account.demo.primary_connection_string
  container_name    = azurerm_storage_container.bootstrap.name
  https_only        = true

  # Backdated an hour to tolerate clock skew between here and the storage
  # service; valid for a year, which comfortably outlives a course.
  start  = timeadd(time_static.sas_start.rfc3339, "-1h")
  expiry = timeadd(time_static.sas_start.rfc3339, "8760h")

  permissions {
    read   = true
    list   = true
    add    = false
    create = false
    write  = false
    delete = false
  }
}

resource "azurerm_virtual_machine_extension" "bootstrap" {
  name                       = "pl300-bootstrap"
  virtual_machine_id         = azurerm_windows_virtual_machine.pl300.id
  publisher                  = "Microsoft.Compute"
  type                       = "CustomScriptExtension"
  type_handler_version       = "1.10"
  auto_upgrade_minor_version = true
  tags                       = var.tags

  # Everything sensitive lives in protected_settings: `settings` is readable
  # from the ARM API, and both the SAS token and the SQL password would leak
  # through it. protected_settings is encrypted and write-only.
  protected_settings = jsonencode({
    fileUris = [
      "${azurerm_storage_blob.bootstrap_ps1.url}${data.azurerm_storage_account_blob_container_sas.bootstrap.sas}",
      "${azurerm_storage_blob.configure_sql.url}${data.azurerm_storage_account_blob_container_sas.bootstrap.sas}",
      "${azurerm_storage_blob.restore_adventureworks.url}${data.azurerm_storage_account_blob_container_sas.bootstrap.sas}",
      "${azurerm_storage_blob.demo_data_zip.url}${data.azurerm_storage_account_blob_container_sas.bootstrap.sas}",
    ]
    # Quoting here crosses two parsers: the extension writes commandToExecute to
    # a .cmd file run by cmd.exe, which then launches powershell.exe -File.
    # Single quotes are NOT grouping characters to either one, so a value
    # containing a space (any Windows timezone id) splits into stray positional
    # arguments. Double quotes group correctly in both. The password goes across
    # base64-encoded so that cmd cannot expand `%` or `!` inside it.
    commandToExecute = join(" ", [
      "powershell.exe -ExecutionPolicy Unrestricted -NoProfile -NonInteractive -File bootstrap.ps1",
      "-SqlAdminLogin \"${var.sql_admin_login}\"",
      "-SqlAdminPasswordB64 \"${base64encode(local.admin_password)}\"",
      "-WindowsAdminUser \"${var.admin_username}\"",
      "-TimeZoneId \"${var.auto_shutdown_timezone}\"",
      # Comma-joined rather than passed as separate arguments: a PowerShell
      # array parameter across the cmd.exe boundary is more quoting risk than
      # this is worth.
      "-ExtraChocoPackages \"${join(",", var.extra_choco_packages)}\"",
      "-PythonPackages \"${join(",", var.python_packages)}\"",
      "-VsCodeExtensions \"${join(",", var.vscode_extensions)}\"",
      "-PayloadVersion \"${local.payload_version}\"",
    ])
  })

  # Installing Power BI Desktop, SSMS and restoring both AdventureWorks
  # databases takes a while on a 4-vCPU VM.
  timeouts {
    create = "90m"
    update = "90m"
  }

  depends_on = [
    azurerm_storage_blob.demo_file,
    # The bootstrap authenticates to SQL with the login this creates.
    azurerm_mssql_virtual_machine.pl300,
  ]
}

# ---------------------------------------------------------------------------
# Cost control
# ---------------------------------------------------------------------------

resource "azurerm_dev_test_global_vm_shutdown_schedule" "pl300" {
  count = var.auto_shutdown_enabled ? 1 : 0

  virtual_machine_id    = azurerm_windows_virtual_machine.pl300.id
  location              = azurerm_resource_group.pl300.location
  enabled               = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = var.tags

  notification_settings {
    enabled         = var.auto_shutdown_notification_email != ""
    email           = var.auto_shutdown_notification_email != "" ? var.auto_shutdown_notification_email : null
    time_in_minutes = 30
  }
}
