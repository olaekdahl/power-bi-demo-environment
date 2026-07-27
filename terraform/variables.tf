variable "subscription_id" {
  description = "Azure subscription ID to deploy into."
  type        = string
  default     = "e6c6066c-121b-4225-b65c-42ee806a9be4"
}

variable "resource_group_name" {
  description = "Resource group for the whole demo environment."
  type        = string
  default     = "pbi-rg"
}

variable "location" {
  description = "Azure region. eastus2 matches the other resource groups in this subscription."
  type        = string
  default     = "eastus2"
}

variable "prefix" {
  description = "Short name prefix for resources."
  type        = string
  default     = "pl300"
}

# NOTE ON SIZING: this subscription has 0 quota for the DSv5 family (and 10
# vCPUs per family for most others), so Standard_D4s_v5 cannot be deployed.
# Standard_D4as_v4 is the same shape (4 vCPU / 16 GB, premium storage, all 3
# zones) at the same price. Other 4-vCPU sizes with quota available here:
# Standard_D4s_v3, Standard_D4s_v4, Standard_D4ds_v4, Standard_D4as_v4.
variable "vm_size" {
  description = "VM size. Must be a family with available vCPU quota in var.location."
  type        = string
  default     = "Standard_D4as_v4"
}

variable "vm_name" {
  description = "Computer name of the VM. Windows caps this at 15 characters."
  type        = string
  default     = "pl300-demo-vm"

  validation {
    condition     = length(var.vm_name) <= 15
    error_message = "Windows computer names must be 15 characters or fewer."
  }
}

variable "admin_username" {
  description = "Local administrator account for RDP."
  type        = string
  default     = "pl300admin"

  validation {
    # Windows rejects these outright, and 'admin' is a reserved name.
    condition     = !contains(["admin", "administrator", "guest", "root"], lower(var.admin_username))
    error_message = "admin_username must not be a reserved Windows account name."
  }
}

variable "admin_password" {
  description = <<-EOT
    Password for the RDP admin account and the SQL Server sysadmin login.
    Leave null to have Terraform generate a strong one (retrieve it afterwards
    with: terraform output -raw admin_password).
  EOT
  type        = string
  default     = null
  sensitive   = true
}

variable "allowed_source_ip" {
  description = <<-EOT
    Public IP (or CIDR) allowed to reach RDP 3389 and SQL 1433. Set to your own
    address - never 0.0.0.0/0, which exposes RDP to the whole internet.
    Update it later with scripts/update-my-ip.sh when your address changes.
  EOT
  type        = string

  validation {
    condition     = var.allowed_source_ip != "0.0.0.0/0" && var.allowed_source_ip != "*"
    error_message = "Refusing to open RDP to the entire internet. Supply a specific IP or CIDR."
  }
}

variable "os_disk_size_gb" {
  description = "OS disk size. Needs room for SQL Server, Power BI Desktop, SSMS and the AdventureWorks backups."
  type        = number
  default     = 256
}

variable "sql_admin_login" {
  description = "SQL Server sysadmin login created by the bootstrap script (sa stays disabled)."
  type        = string
  default     = "pl300sql"
}

variable "extra_choco_packages" {
  description = <<-EOT
    Additional Chocolatey packages to install, beyond the standard set (Power BI
    Desktop, SSMS, DAX Studio, Tabular Editor, VS Code, Python, Git, 7-Zip,
    Notepad++). Failures here are logged as warnings and never fail the build.

    Useful ones for PL-300, all deliberately off by default:
      "powerbigateway" - On-premises data gateway. Installs the service but it
                         cannot be registered without a Power BI/Fabric account,
                         so it is only worth it if you want to walk through the
                         gateway configuration UI when covering scheduled refresh.
      "r.project"      - R runtime, if you want to demo R visuals alongside Python.
      "almtoolkit"     - ALM Toolkit, for semantic model diff/deployment demos.
  EOT
  type        = list(string)
  default     = []
}

variable "python_packages" {
  description = <<-EOT
    Python packages installed machine-wide. pandas and matplotlib are REQUIRED
    for Power BI Desktop's Python visuals and "Run Python script" to work at all
    - Power BI shells out to python.exe and hands it a DataFrame, so a bare
    interpreter produces an error rather than a visual.
  EOT
  type        = list(string)
  default     = ["pandas", "matplotlib", "numpy", "seaborn", "openpyxl", "ipykernel"]
}

variable "vscode_extensions" {
  description = "VS Code extensions installed for the RDP user (and baked into the default profile)."
  type        = list(string)
  default = [
    "ms-python.python",             # Python language support + debugger
    "ms-toolsai.jupyter",           # notebooks, pairs with ipykernel
    "ms-mssql.mssql",               # query SQL Server without leaving the editor
    "powerquery.vscode-powerquery", # M language service - useful for Advanced Editor work
  ]
}

variable "auto_shutdown_enabled" {
  description = "Create a nightly auto-shutdown schedule. Strongly recommended - the VM bills ~$0.376/hr while running."
  type        = bool
  default     = true
}

variable "auto_shutdown_time" {
  description = "Daily shutdown time in 24h HHmm format, in auto_shutdown_timezone."
  type        = string
  default     = "2000"
}

variable "auto_shutdown_timezone" {
  description = "Windows timezone ID for the shutdown schedule (e.g. 'Central Standard Time', 'Eastern Standard Time', 'Pacific Standard Time')."
  type        = string
  default     = "Central Standard Time"
}

variable "auto_shutdown_notification_email" {
  description = "Optional email for a 30-minute warning before auto-shutdown. Empty disables the notification."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project     = "PL-300"
    purpose     = "training-demo"
    environment = "demo"
    managed_by  = "terraform"
  }
}
