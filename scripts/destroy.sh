#!/usr/bin/env bash
#
# Tear the whole demo environment down. Deletes the pbi-rg resource group and
# everything in it - VM, disks, storage account, demo data blobs. Not reversible.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_azure_login
RG="$(rg_name)"

head1 "Destroy the PL-300 demo environment"
warn "This permanently deletes resource group '$RG' and everything inside it:"
az resource list -g "$RG" --query '[].{type:type,name:name}' -o table 2>/dev/null || {
  ok "Resource group '$RG' does not exist - nothing to destroy."
  exit 0
}

echo
if [[ "${AUTO_APPROVE:-0}" != "1" ]]; then
  read -r -p "Type the resource group name to confirm: " confirm
  [[ "$confirm" == "$RG" ]] || die "Confirmation did not match. Nothing was deleted."
fi

info "terraform destroy ..."
terraform -chdir="$TF_DIR" destroy -auto-approve -input=false

# The demo data zip is a build artifact of the deploy, not something to keep.
rm -f "$REPO_ROOT/demo-data.zip"

ok "Environment destroyed."
info "Rebuild any time with: ./scripts/deploy.sh"
