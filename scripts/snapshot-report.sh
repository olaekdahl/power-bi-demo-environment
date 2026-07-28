#!/usr/bin/env bash
#
# Open the Power BI solution on the demo VM, screenshot it, and bring the PNG
# back here. This is how the report is validated: a .pbip is just text until
# Power BI Desktop actually loads the model and paints the visuals.
#
#   ./scripts/snapshot-report.sh                    # page 1, 120s settle
#   ./scripts/snapshot-report.sh 2                  # page index 2 (0-based)
#   ./scripts/snapshot-report.sh 2 180 mypage.png   # page, wait, output name
#
# How it works: az vm run-command runs as SYSTEM in session 0, which has no
# desktop, so a capture from there is black. The heavy lifting therefore happens
# in a scheduled task registered with -LogonType Interactive, which executes
# inside the signed-in user's session. That means SOMEBODY MUST BE LOGGED IN over
# RDP for this to work - the script checks and tells you if not.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PAGE_INDEX="${1:-0}"
WAIT_SECONDS="${2:-120}"
OUT_NAME="${3:-report-page${PAGE_INDEX}.png}"

PBIP_DIR="$REPO_ROOT/powerbi"
SHOT_DIR="$REPO_ROOT/.snapshots"
SNAP_SCRIPT="$REPO_ROOT/scripts/snapshot.ps1"

need az; need python3
require_azure_login
RG="$(rg_name)"; VM="$(vm_name)"
[[ -d "$PBIP_DIR" ]] || die "No powerbi/ directory. Run scripts/generate-pbip.py first."
[[ "$(vm_power_state)" == "running" ]] || die "VM is not running. ./scripts/start-vm.sh"

# --- an interactive session is mandatory ------------------------------------
sessions="$(az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript \
  --scripts '(query user 2>&1 | Out-String)' --query 'value[0].message' -o tsv 2>/dev/null || true)"
if ! grep -qiE 'rdp-tcp|console' <<<"$sessions"; then
  warn "No interactive session found on the VM. Screen capture would be black."
  warn "Connect over RDP first (./scripts/start-vm.sh prints the details), then re-run."
  printf '%s\n' "$sessions" | head -10
  exit 1
fi
ok "interactive session present"

mkdir -p "$SHOT_DIR"

# --- point the report at the page we want to capture ------------------------
info "setting activeSectionIndex=$PAGE_INDEX"
# PBIR keeps page order and the active page in definition/pages/pages.json,
# rather than the legacy report.json "activeSectionIndex".
python3 - "$PBIP_DIR" "$PAGE_INDEX" <<'PY'
import json, sys, pathlib
d, idx = pathlib.Path(sys.argv[1]), int(sys.argv[2])
pages_dir = d / "PL300-Demos.Report" / "definition" / "pages"
meta_path = pages_dir / "pages.json"
meta = json.loads(meta_path.read_text())
order = meta["pageOrder"]
if idx >= len(order):
    raise SystemExit(f"page index {idx} out of range (report has {len(order)} page(s))")
meta["activePageName"] = order[idx]
meta_path.write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
display = json.loads((pages_dir / order[idx] / "page.json").read_text())["displayName"]

# The solution ships both formats; set the active page in the legacy one too,
# since Power BI reads report.json unless the PBIR preview feature is enabled.
legacy = d / "PL300-Demos.Report" / "report.json"
if legacy.exists():
    r = json.loads(legacy.read_text())
    cfg = json.loads(r["config"])
    cfg["activeSectionIndex"] = idx
    r["config"] = json.dumps(cfg, separators=(",", ":"))
    legacy.write_text(json.dumps(r, indent=2, ensure_ascii=False) + "\n")

print(f"  page {idx}: {display}  ({order[idx]})")
PY

# --- ship it -----------------------------------------------------------------
SA="$(tf_out storage_account)"
[[ -n "$SA" ]] || die "Could not read the storage account name from Terraform."
KEY="$(az storage account keys list -g "$RG" -n "$SA" --query '[0].value' -o tsv)"
az storage container create --account-name "$SA" --account-key "$KEY" -n screenshots -o none 2>/dev/null || true
EXPIRY="$(date -u -d '+4 hours' '+%Y-%m-%dT%H:%MZ')"
SAS="$(az storage container generate-sas --account-name "$SA" --account-key "$KEY" \
        -n screenshots --permissions racwdl --expiry "$EXPIRY" -o tsv)"
SASURL="https://${SA}.blob.core.windows.net/screenshots?${SAS}"

# Python's zipfile rather than the zip(1) binary, which is not installed
# everywhere and cannot be added without root.
ZIP="$SHOT_DIR/pbip.zip"
rm -f "$ZIP"
python3 - "$REPO_ROOT" "$ZIP" <<'PY'
import pathlib, sys, zipfile
root, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted((root / "powerbi").rglob("*")):
        if f.is_file():
            z.write(f, f.relative_to(root).as_posix())
PY
info "uploading solution ($(du -h "$ZIP" | cut -f1))"
az storage blob upload --account-name "$SA" --account-key "$KEY" -c screenshots \
  -n pbip.zip -f "$ZIP" --overwrite -o none

# --- render + capture on the VM ---------------------------------------------
SNAP_B64="$(base64 -w0 "$SNAP_SCRIPT")"
RUNNER="$SHOT_DIR/runner.ps1"
cat > "$RUNNER" <<'PSEOF'
param([string]$SasUrl, [string]$BlobName, [int]$WaitSeconds, [string]$SnapB64, [int]$RefreshWait = 70, [string]$NoRefresh = '0')
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path 'C:\PL300\Tools','C:\PL300\Solution' -Force | Out-Null
[IO.File]::WriteAllBytes('C:\PL300\Tools\snapshot.ps1', [Convert]::FromBase64String($SnapB64))

# Fetch and unpack the solution.
$zip = 'C:\PL300\Solution\pbip.zip'
$base = ($SasUrl -split '\?')[0]; $q = ($SasUrl -split '\?')[1]
Invoke-WebRequest -Uri "$base/pbip.zip`?$q" -OutFile $zip -UseBasicParsing
Remove-Item 'C:\PL300\Solution\powerbi' -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $zip -DestinationPath 'C:\PL300\Solution' -Force
$pbip = Get-ChildItem 'C:\PL300\Solution\powerbi' -Filter *.pbip | Select-Object -First 1
if (-not $pbip) { Write-Output 'ERROR: no .pbip found after extract'; exit 1 }
Write-Output "solution: $($pbip.FullName)"

$args = '-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File "C:\PL300\Tools\snapshot.ps1"' +
        " -SasUrl `"$SasUrl`" -BlobName $BlobName -WaitSeconds $WaitSeconds -RefreshWaitSeconds $RefreshWait" +
        $(if ($NoRefresh -eq '1') { ' -NoRefresh' } else { '' }) +
        " -LaunchFile `"$($pbip.FullName)`""
$a  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $args
$pr = New-ScheduledTaskPrincipal -UserId 'pl300admin' -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'PL300-Snapshot' -Action $a -Principal $pr -Force | Out-Null
Remove-Item 'C:\PL300\Snapshots\snapshot.log' -Force -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName 'PL300-Snapshot'

# Wait for the task to finish, then hand back its log.
$limit = (Get-Date).AddSeconds($WaitSeconds + $RefreshWait + 240)
while ((Get-Date) -lt $limit) {
    Start-Sleep -Seconds 10
    $log = Get-Content 'C:\PL300\Snapshots\snapshot.log' -ErrorAction SilentlyContinue
    if ($log -match 'RESULT') { break }
}
Get-Content 'C:\PL300\Snapshots\snapshot.log' -ErrorAction SilentlyContinue
PSEOF
RUNNER_B64="$(base64 -w0 "$RUNNER")"

info "opening the solution, refreshing the model, and capturing (allow ~$((WAIT_SECONDS + 200))s)"
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript \
  --scripts "[IO.File]::WriteAllBytes('C:\\PL300\\Tools\\runner.ps1',[Convert]::FromBase64String('$RUNNER_B64')); & powershell -ExecutionPolicy Bypass -NoProfile -File C:\\PL300\\Tools\\runner.ps1 -SasUrl '$SASURL' -BlobName '$OUT_NAME' -WaitSeconds $WAIT_SECONDS -SnapB64 '$SNAP_B64' -NoRefresh '${NO_REFRESH:-0}'" \
  --query 'value[0].message' -o tsv 2>&1 | sed 's/^/  /'

# --- retrieve ----------------------------------------------------------------
if az storage blob download --account-name "$SA" --account-key "$KEY" -c screenshots \
     -n "$OUT_NAME" -f "$SHOT_DIR/$OUT_NAME" --overwrite -o none >/dev/null 2>&1; then
  ok "screenshot: $SHOT_DIR/$OUT_NAME ($(du -h "$SHOT_DIR/$OUT_NAME" | cut -f1))"
else
  die "No screenshot was produced - see the log above."
fi
