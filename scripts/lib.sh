#!/usr/bin/env bash
# Shared helpers for the PL-300 demo environment scripts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
DATA_DIR="$REPO_ROOT/demo-data"
VENV_DIR="$REPO_ROOT/.venv"

# Fall back to the known defaults when Terraform state isn't readable yet.
RG_DEFAULT="pbi-rg"
VM_DEFAULT="pl300-demo-vm"

c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_red=$'\033[31m'
c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_blue=$'\033[36m'

info()  { printf '%s==>%s %s\n' "$c_blue"   "$c_reset" "$*"; }
ok()    { printf '%s  ok%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn()  { printf '%swarn%s %s\n' "$c_yellow" "$c_reset" "$*" >&2; }
die()   { printf '%sfail%s %s\n' "$c_red"    "$c_reset" "$*" >&2; exit 1; }
head1() { printf '\n%s%s%s\n' "$c_bold" "$*" "$c_reset"; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

# Read a Terraform output, or empty string if unavailable.
tf_out() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null || true
}

rg_name() {
  local v; v="$(tf_out resource_group)"
  printf '%s' "${v:-$RG_DEFAULT}"
}

vm_name() {
  local v; v="$(tf_out vm_name)"
  printf '%s' "${v:-$VM_DEFAULT}"
}

my_public_ip() {
  local ip
  for svc in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
    ip="$(curl -fsS4 --max-time 10 "$svc" 2>/dev/null | tr -d '[:space:]')" || continue
    [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

require_azure_login() {
  need az
  az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run: az login"
}

vm_power_state() {
  az vm get-instance-view -g "$(rg_name)" -n "$(vm_name)" \
    --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv 2>/dev/null \
    | sed 's|PowerState/||'
}
