#!/usr/bin/env bash
#
# Re-point the NSG at your current public IP. Hotel wifi, tethering and ISP
# lease changes will all lock you out of RDP; this fixes it in a few seconds.
#
#   ./scripts/update-my-ip.sh            # detect current IP
#   ./scripts/update-my-ip.sh 1.2.3.4    # or set it explicitly

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_azure_login
RG="$(rg_name)"
NEW_IP="${1:-}"

if [[ -z "$NEW_IP" ]]; then
  info "Detecting your public IP ..."
  NEW_IP="$(my_public_ip)" || die "Could not detect your IP. Pass it explicitly."
fi
[[ "$NEW_IP" == "0.0.0.0/0" ]] && die "Refusing to open RDP to the whole internet."

NSG="$(az network nsg list -g "$RG" --query '[0].name' -o tsv)"
[[ -n "$NSG" ]] || die "No network security group found in $RG."
info "network security group: $NSG"

for rule in AllowRDPFromInstructor AllowSQLFromInstructor; do
  current="$(az network nsg rule show -g "$RG" --nsg-name "$NSG" -n "$rule" \
              --query 'sourceAddressPrefix' -o tsv 2>/dev/null || true)"
  if [[ -z "$current" ]]; then
    warn "rule '$rule' not found, skipping"
    continue
  fi
  if [[ "$current" == "$NEW_IP" ]]; then
    ok "$rule already allows $NEW_IP"
    continue
  fi
  info "$rule: $current -> $NEW_IP"
  az network nsg rule update -g "$RG" --nsg-name "$NSG" -n "$rule" \
    --source-address-prefixes "$NEW_IP" -o none
  ok "$rule updated"
done

# Keep Terraform in step so the next apply doesn't revert the change.
if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
  if grep -q '^allowed_source_ip' "$TF_DIR/terraform.tfvars"; then
    sed -i "s|^allowed_source_ip.*|allowed_source_ip = \"$NEW_IP\"|" "$TF_DIR/terraform.tfvars"
  else
    printf 'allowed_source_ip = "%s"\n' "$NEW_IP" >> "$TF_DIR/terraform.tfvars"
  fi
  ok "terraform/terraform.tfvars updated to $NEW_IP"
fi

head1 "Access restored for $NEW_IP"
