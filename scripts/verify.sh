#!/usr/bin/env bash
#
# Read the bootstrap results back off the VM and report what is actually there.
#
# The bootstrap script deliberately exits 0 even on failure so a flaky download
# doesn't taint the Terraform resource. This is the script that tells you the
# truth about the environment.
#
# Exit code: 0 = ready, 1 = something is wrong.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_azure_login
RG="$(rg_name)"
VM="$(vm_name)"

head1 "PL-300 demo environment - verification"
info "resource group : $RG"
info "vm             : $VM"

state="$(vm_power_state)"
[[ -n "$state" ]] || die "VM '$VM' not found in resource group '$RG'."
info "power state    : $state"
if [[ "$state" != "running" ]]; then
  warn "VM is '$state'. Start it first: ./scripts/start-vm.sh"
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# The bootstrap reboots the VM when it finishes, so a verify run started right
# after `terraform apply` can arrive while the guest agent is still coming back.
# Retry rather than reporting a false failure.
run_on_vm() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if az vm run-command invoke \
        -g "$RG" -n "$VM" \
        --command-id RunPowerShellScript \
        --scripts "$1" -o json > "$tmp" 2>/dev/null; then
      return 0
    fi
    warn "VM did not answer (attempt $attempt/5) - it may be rebooting after bootstrap; waiting 45s"
    sleep 45
  done
  return 1
}

info "Querying the VM (this takes 20-60 seconds) ..."
run_on_vm '
    $out = [ordered]@{}
    $statusFile = "C:\PL300\Logs\status.json"
    $verifyFile = "C:\PL300\Logs\verify.json"
    $out.bootstrapRan = Test-Path $statusFile
    if ($out.bootstrapRan) { $out.status = Get-Content $statusFile -Raw | ConvertFrom-Json }
    if (Test-Path $verifyFile) { $out.verify = Get-Content $verifyFile -Raw | ConvertFrom-Json }
    $out.sqlService = (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status.ToString()
    $out.tcp1433 = [bool](Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue)
    $out.dataFiles = (Get-ChildItem "C:\PL300\Data" -Recurse -File -ErrorAction SilentlyContinue).Count
    $out | ConvertTo-Json -Depth 8 -Compress
  ' -o json > "$tmp" 2>/dev/null || die "run-command failed. Is the VM agent healthy?"

payload="$(jq -r '.value[0].message // ""' "$tmp")"
# run-command wraps stdout in banner lines; keep only the JSON object.
json="$(printf '%s' "$payload" | grep -o '{.*}' | head -1)"

if [[ -z "$json" ]]; then
  warn "Could not parse a result from the VM. Raw output:"
  printf '%s\n' "$payload" | head -40
  exit 1
fi

ran="$(jq -r '.bootstrapRan // false' <<<"$json")"
if [[ "$ran" != "true" ]]; then
  warn "Bootstrap has not completed yet (C:\\PL300\\Logs\\status.json is missing)."
  warn "It runs for 25-45 minutes after the VM is created. Re-run this script later."
  exit 1
fi

total="$(jq -r '.status.stepsTotal // 0'  <<<"$json")"
okc="$(jq -r   '.status.stepsOk // 0'     <<<"$json")"
failc="$(jq -r '.status.stepsFailed // 0' <<<"$json")"

head1 "Bootstrap steps: $okc/$total succeeded"
jq -r '.status.steps[]? | "  \(if .status=="ok" then "[ok]  " else "[FAIL]" end) \(.name) (\(.seconds)s)\(if .error then "\n         " + .error else "" end)"' <<<"$json"

head1 "Environment checks"
printf '  %-24s %s\n' "SQL Server service"  "$(jq -r '.sqlService // "unknown"' <<<"$json")"
printf '  %-24s %s\n' "Listening on 1433"   "$(jq -r '.tcp1433 // false' <<<"$json")"
printf '  %-24s %s\n' "Power BI Desktop"    "$(jq -r '.verify.PowerBIDesktop // "unknown"' <<<"$json")"
printf '  %-24s %s\n' "SSMS"               "$(jq -r '.verify.SSMS // "unknown"' <<<"$json")"
printf '  %-24s %s\n' "DAX Studio"         "$(jq -r '.verify.DaxStudio // "unknown"' <<<"$json")"
printf '  %-24s %s\n' "Tabular Editor"     "$(jq -r '.verify.TabularEditor // "unknown"' <<<"$json")"
printf '  %-24s %s\n' "Databases"          "$(jq -r '.verify.Databases // "unknown"' <<<"$json")"
printf '  %-24s %s\n' "FactInternetSales"  "$(jq -r '.verify.FactInternetSalesRows // "unknown"' <<<"$json") rows"
printf '  %-24s %s\n' "Demo files"         "$(jq -r '.dataFiles // 0' <<<"$json") files"
printf '  %-24s %s\n' "Demo formats"       "$(jq -r '.verify.DemoFormats // "unknown"' <<<"$json")"

problems=0
[[ "$(jq -r '.sqlService // ""' <<<"$json")" == "Running" ]] || { warn "SQL Server is not running."; problems=1; }
[[ "$(jq -r '.verify.PowerBIDesktop // ""' <<<"$json")" == "NOT FOUND" ]] && { warn "Power BI Desktop is missing."; problems=1; }
jq -e '.verify.Databases | test("AdventureWorksDW2022")' <<<"$json" >/dev/null 2>&1 || { warn "AdventureWorksDW2022 is missing."; problems=1; }
jq -e '.verify.Databases | test("AdventureWorks2022")'   <<<"$json" >/dev/null 2>&1 || { warn "AdventureWorks2022 is missing."; problems=1; }
(( $(jq -r '.dataFiles // 0' <<<"$json") >= 20 )) || { warn "Expected 20+ demo files."; problems=1; }

if (( problems == 0 && failc == 0 )); then
  head1 "${c_green}Environment is ready.${c_reset}"
  exit 0
fi

if (( problems == 0 )); then
  head1 "${c_yellow}Ready, with non-critical warnings above.${c_reset}"
  exit 0
fi

head1 "${c_red}Environment has problems.${c_reset}"
echo "Repair by re-running the bootstrap (idempotent):  ./scripts/rerun-bootstrap.sh"
echo "Full log on the VM:                              C:\\PL300\\Logs\\bootstrap.log"
exit 1
