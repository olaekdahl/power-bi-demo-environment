#!/usr/bin/env bash
# Deallocate the demo VM. Compute billing stops; disks and the public IP keep
# costing roughly $25/month, and everything installed is preserved.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_azure_login
RG="$(rg_name)"; VM="$(vm_name)"

state="$(vm_power_state)"
if [[ "$state" == "deallocated" ]]; then
  ok "VM is already deallocated - you are not paying for compute."
  exit 0
fi

info "Deallocating $VM (this is the one that actually stops the bill) ..."
az vm deallocate -g "$RG" -n "$VM" -o none
ok "Deallocated. Compute charges have stopped."
info "Start it again with: ./scripts/start-vm.sh"
