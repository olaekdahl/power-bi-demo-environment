#!/usr/bin/env bash
# Start the demo VM and print how to connect. Billing resumes while it runs.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_azure_login
RG="$(rg_name)"; VM="$(vm_name)"

state="$(vm_power_state)"
if [[ "$state" == "running" ]]; then
  ok "VM is already running."
else
  info "Starting $VM ..."
  az vm start -g "$RG" -n "$VM" -o none
  ok "Started."
fi

fqdn="$(tf_out fqdn)"
head1 "Connect"
printf '  RDP      : %s\n' "${fqdn:-$(az vm show -d -g "$RG" -n "$VM" --query fqdn -o tsv)}"
printf '  Username : %s\n' "$(tf_out admin_username)"
printf '  Password : terraform -chdir=terraform output -raw admin_password\n'
echo
info "Windows needs another 1-2 minutes before it accepts RDP."
warn "Remember to stop it when you are done: ./scripts/stop-vm.sh"
