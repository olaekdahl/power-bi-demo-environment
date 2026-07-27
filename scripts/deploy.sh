#!/usr/bin/env bash
#
# Build the whole PL-300 demo environment from nothing.
#
#   ./scripts/deploy.sh              # detect your public IP, deploy
#   ./scripts/deploy.sh 1.2.3.4      # pin a specific source IP
#   AUTO_APPROVE=1 ./scripts/deploy.sh
#
# Safe to re-run: Terraform reconciles, and the VM bootstrap is idempotent.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALLOWED_IP="${1:-}"

head1 "PL-300 demo environment - deploy"

need terraform
need python3
require_azure_login
info "subscription: $(az account show --query '[name,id]' -o tsv | paste -sd' / ')"

# --- 1. source IP -----------------------------------------------------------
if [[ -z "$ALLOWED_IP" ]]; then
  info "Detecting your public IP ..."
  ALLOWED_IP="$(my_public_ip)" || die "Could not detect your public IP. Pass it explicitly: ./scripts/deploy.sh 1.2.3.4"
fi
[[ "$ALLOWED_IP" == "0.0.0.0/0" ]] && die "Refusing to open RDP to the whole internet."
ok "RDP and SQL will be restricted to $ALLOWED_IP"

# --- 2. demo data -----------------------------------------------------------
info "Preparing the Python environment for data generation ..."
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install --quiet --upgrade pip >/dev/null
"$VENV_DIR/bin/pip" install --quiet openpyxl reportlab
ok "openpyxl + reportlab ready"

info "Generating demo data files (CSV, Excel, JSON, XML, PDF) ..."
"$VENV_DIR/bin/python" "$REPO_ROOT/scripts/generate-demo-data.py" --out "$DATA_DIR"
[[ -d "$DATA_DIR" ]] || die "Demo data generation produced no output."

# --- 3. terraform -----------------------------------------------------------
cat > "$TF_DIR/terraform.tfvars" <<EOF
# Written by scripts/deploy.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ').
# Change allowed_source_ip with scripts/update-my-ip.sh when your address moves.
allowed_source_ip = "$ALLOWED_IP"
EOF
ok "wrote terraform/terraform.tfvars"

info "terraform init ..."
terraform -chdir="$TF_DIR" init -upgrade -input=false

info "terraform validate ..."
terraform -chdir="$TF_DIR" validate

info "terraform apply ... (VM build plus software install takes 25-45 minutes)"
if [[ "${AUTO_APPROVE:-0}" == "1" ]]; then
  terraform -chdir="$TF_DIR" apply -auto-approve -input=false
else
  terraform -chdir="$TF_DIR" apply -input=false
fi

# --- 4. report --------------------------------------------------------------
head1 "Deployment complete"
terraform -chdir="$TF_DIR" output -raw connection_summary
echo
info "Verifying what actually landed on the VM ..."
"$REPO_ROOT/scripts/verify.sh" || warn "Verification reported problems - see the output above."
