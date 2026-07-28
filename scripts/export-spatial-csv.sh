#!/usr/bin/env bash
#
# Export the SQL Server `geography` view results from the demo VM to local CSVs.
#
# These are the input to scripts/generate-pbip.py, which materialises them as
# inline M literals in the Power BI solution. Without this step a fresh rebuild
# could not regenerate the report, so it closes that loop:
#
#   ./scripts/export-spatial-csv.sh                 # -> .spatial-export/
#   ./scripts/export-spatial-csv.sh /tmp/somewhere
#
# Then:
#   python scripts/generate-pbip.py --out powerbi --sql-dir .spatial-export
#   python scripts/validate-pbip.py powerbi

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT_DIR="${1:-$REPO_ROOT/.spatial-export}"

need az; need python3
require_azure_login
RG="$(rg_name)"; VM="$(vm_name)"
[[ "$(vm_power_state)" == "running" ]] || die "VM is not running. ./scripts/start-vm.sh"

PW="$(tf_out admin_password)"
LOGIN="$(tf_out sql_admin_login)"; LOGIN="${LOGIN:-pl300sql}"
SA="$(tf_out storage_account)"
[[ -n "$PW" && -n "$SA" ]] || die "Could not read Terraform outputs. Run from the repo root."

KEY="$(az storage account keys list -g "$RG" -n "$SA" --query '[0].value' -o tsv)"
az storage container create --account-name "$SA" --account-key "$KEY" -n screenshots -o none 2>/dev/null || true
EXPIRY="$(date -u -d '+2 hours' '+%Y-%m-%dT%H:%MZ')"
SAS="$(az storage container generate-sas --account-name "$SA" --account-key "$KEY" \
        -n screenshots --permissions racwdl --expiry "$EXPIRY" -o tsv)"

mkdir -p "$OUT_DIR"
EXPORT_PS="$OUT_DIR/export.ps1"
cat > "$EXPORT_PS" <<'PSEOF'
param([string]$Login, [string]$Pw, [string]$Sa, [string]$Sas)
$ErrorActionPreference = 'Continue'
$sqlcmd = (Get-ChildItem 'C:\Program Files\Microsoft SQL Server' -Filter sqlcmd.exe -Recurse `
            -EA SilentlyContinue | Sort-Object FullName -Desc | Select-Object -First 1).FullName
$dir = 'C:\PL300\Snapshots'
New-Item -ItemType Directory -Path $dir -Force | Out-Null

# -W -s'|' -h -1 gives a headerless pipe-delimited dump that read_pipe_csv() in
# generate-pbip.py understands. Column order here must match the field lists there.
$queries = [ordered]@{
  'stores.csv'    = 'SET NOCOUNT ON; SELECT StoreID,StoreName,City,[State],RegionName,Latitude,Longitude,WellKnownText FROM dbo.vw_StoreLocations ORDER BY StoreID;'
  'catchment.csv' = 'SET NOCOUNT ON; SELECT StoreID,StoreName,RegionName,CustomersWithin25km,CustomersWithin50km,CustomersWithin100km,CustomersTotal FROM dbo.vw_StoreCatchment ORDER BY StoreID;'
  'customers.csv' = 'SET NOCOUNT ON; SELECT c.CustomerID,c.HomeStoreID,s.StoreName,s.RegionName,c.LoyaltyTier,c.Latitude,c.Longitude,c.DistanceToHomeStoreKm FROM dbo.vw_CustomerLocations c JOIN dbo.vw_StoreLocations s ON s.StoreID=c.HomeStoreID ORDER BY c.CustomerKey;'
}
foreach ($n in $queries.Keys) {
  $f = Join-Path $dir $n
  & $sqlcmd -S localhost -U $Login -P $Pw -d PL300Demo -I -b -h -1 -W -s '|' -Q $queries[$n] |
    Where-Object { $_ -notmatch '^\(' -and $_ -notmatch 'rows affected' -and $_.Trim() } |
    Set-Content $f -Encoding utf8
  Write-Output ("{0} : {1} rows" -f $n, (Get-Content $f).Count)
  $uri = 'https://{0}.blob.core.windows.net/screenshots/{1}?{2}' -f $Sa, $n, $Sas
  Invoke-RestMethod -Uri $uri -Method Put -InFile $f -Headers @{'x-ms-blob-type' = 'BlockBlob'} | Out-Null
}
PSEOF
B64="$(base64 -w0 "$EXPORT_PS")"

info "exporting the spatial views from SQL Server on $VM ..."
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts "
[IO.File]::WriteAllBytes('C:\\PL300\\Tools\\export-spatial.ps1',[Convert]::FromBase64String('$B64'))
& powershell -ExecutionPolicy Bypass -NoProfile -File C:\\PL300\\Tools\\export-spatial.ps1 -Login '$LOGIN' -Pw '$PW' -Sa '$SA' -Sas '$SAS'" \
  --query 'value[0].message' -o tsv 2>&1 | sed 's/^/  /'

for f in stores.csv catchment.csv customers.csv; do
  az storage blob download --account-name "$SA" --account-key "$KEY" -c screenshots \
    -n "$f" -f "$OUT_DIR/$f" --overwrite -o none >/dev/null 2>&1 \
    || die "could not download $f"
  printf '  %-14s %s rows\n' "$f" "$(wc -l < "$OUT_DIR/$f")"
done
rm -f "$EXPORT_PS"

ok "exports in $OUT_DIR"
info "now: python scripts/generate-pbip.py --out powerbi --sql-dir $OUT_DIR"
