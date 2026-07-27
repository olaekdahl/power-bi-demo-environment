#!/usr/bin/env bash
#
# Re-run the VM bootstrap in place to repair a partial install, without
# rebuilding the VM. Every step in bootstrap.ps1 is idempotent: installed
# packages are skipped, already-downloaded backups are reused, and databases
# that already exist are left alone.
#
# Takes 5-40 minutes depending on what needs redoing. Run scripts/verify.sh
# afterwards.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_azure_login
RG="$(rg_name)"; VM="$(vm_name)"

[[ "$(vm_power_state)" == "running" ]] || die "VM is not running. Start it first: ./scripts/start-vm.sh"

SQL_LOGIN="$(tf_out sql_admin_login)"; SQL_LOGIN="${SQL_LOGIN:-pl300sql}"
SQL_PASS="$(tf_out admin_password)"
ADMIN_USER="$(tf_out admin_username)"; ADMIN_USER="${ADMIN_USER:-pl300admin}"
TZ_ID="$(terraform -chdir="$TF_DIR" output -raw auto_shutdown 2>/dev/null | sed 's/^[0-9]* //')"
TZ_ID="${TZ_ID:-Central Standard Time}"

[[ -n "$SQL_PASS" ]] || die "Could not read the password from Terraform state. Run this from the repo root."

# Same reason as the Terraform extension: send the password base64-encoded so no
# shell between here and PowerShell can reinterpret its special characters.
SQL_PASS_B64="$(printf '%s' "$SQL_PASS" | base64 -w0)"

info "Re-running bootstrap on $VM ..."
warn "This call blocks until the script finishes (up to 40 minutes) and Azure"
warn "run-command truncates long output - the full log stays on the VM at"
warn "C:\\PL300\\Logs\\bootstrap.log"

# -SkipReboot: no reason to bounce the box during a repair, and a reboot would
# kill the run-command channel before it reports back.
az vm run-command invoke \
  -g "$RG" -n "$VM" \
  --command-id RunPowerShellScript \
  --scripts "
    \$ErrorActionPreference = 'Continue'
    if (-not (Test-Path 'C:\\PL300\\bootstrap.ps1')) {
      Write-Output 'bootstrap.ps1 not found on the VM; re-run terraform apply instead.'
      exit 1
    }
    & powershell.exe -ExecutionPolicy Unrestricted -NoProfile -File 'C:\\PL300\\bootstrap.ps1' \`
        -SqlAdminLogin '$SQL_LOGIN' -SqlAdminPasswordB64 '$SQL_PASS_B64' \`
        -WindowsAdminUser '$ADMIN_USER' -TimeZoneId '$TZ_ID' -SkipReboot
    Get-Content 'C:\\PL300\\Logs\\status.json' -Raw
  " \
  --query 'value[0].message' -o tsv | tail -60

head1 "Bootstrap re-run finished"
info "Now check the result: ./scripts/verify.sh"
