#!/usr/bin/env bash
#
# Send a sequence of clicks/keystrokes to Power BI Desktop on the demo VM and
# bring back a screenshot. Used to navigate GUI dialogs that UI Automation cannot
# see (Power BI renders several of them in an embedded WebView2, where a UIA
# search for a Button by name returns nothing).
#
#   ./scripts/ui-probe.sh out.png "click:32,50" "sleep:2" "click:120,300"
#   ./scripts/ui-probe.sh out.png "keys:%{F4}"
#
# Steps: click:X,Y | dclick:X,Y | keys:SENDKEYS | sleep:SECONDS | pixel:X,Y

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT_NAME="${1:?usage: ui-probe.sh <out.png> <step> [step...]}"
shift
STEPS=("$@")

require_azure_login
RG="$(rg_name)"; VM="$(vm_name)"
SHOT_DIR="$REPO_ROOT/.snapshots"
mkdir -p "$SHOT_DIR"

SA="$(tf_out storage_account)"
KEY="$(az storage account keys list -g "$RG" -n "$SA" --query '[0].value' -o tsv)"
EXPIRY="$(date -u -d '+2 hours' '+%Y-%m-%dT%H:%MZ')"
SAS="$(az storage container generate-sas --account-name "$SA" --account-key "$KEY" \
        -n screenshots --permissions racwdl --expiry "$EXPIRY" -o tsv)"
SASURL="https://${SA}.blob.core.windows.net/screenshots?${SAS}"

STEP_ARG="$(IFS='|'; echo "${STEPS[*]}")"

PROBE="$SHOT_DIR/probe.ps1"
cat > "$PROBE" <<'PSEOF'
param([string]$SasUrl, [string]$BlobName, [string]$Steps)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace P -Name N -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, int e);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@
$log = 'C:\PL300\Snapshots\probe.txt'
function L($m) { Add-Content $log ("{0} {1}" -f (Get-Date -Format HH:mm:ss), $m) }
Set-Content $log "=== ui-probe ==="

$p = Get-Process PBIDesktop -EA SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if ($p) { [P.N]::SetForegroundWindow($p.MainWindowHandle) | Out-Null; Start-Sleep -Milliseconds 800; L "focused '$($p.MainWindowTitle)'" }
else { L 'no PBIDesktop window' }

function Click([int]$x, [int]$y) {
    [P.N]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 300
    [P.N]::mouse_event(0x0002, 0, 0, 0, 0); [P.N]::mouse_event(0x0004, 0, 0, 0, 0)
}

foreach ($step in ($Steps -split '\|')) {
    $kind, $arg = $step -split ':', 2
    switch ($kind) {
        'click'  { $c = $arg -split ','; L "click $arg";  Click ([int]$c[0]) ([int]$c[1]); Start-Sleep -Milliseconds 900 }
        'dclick' { $c = $arg -split ','; L "dclick $arg"; Click ([int]$c[0]) ([int]$c[1]); Start-Sleep -Milliseconds 120; Click ([int]$c[0]) ([int]$c[1]); Start-Sleep -Milliseconds 900 }
        'keys'   { L "keys $arg"; [System.Windows.Forms.SendKeys]::SendWait($arg); Start-Sleep -Milliseconds 900 }
        'sleep'  { L "sleep $arg"; Start-Sleep -Seconds ([int]$arg) }
        'pixel'  {
            $c = $arg -split ','
            $b = New-Object System.Drawing.Bitmap(1, 1); $g = [System.Drawing.Graphics]::FromImage($b)
            $g.CopyFromScreen([int]$c[0], [int]$c[1], 0, 0, (New-Object System.Drawing.Size(1, 1)))
            $px = $b.GetPixel(0, 0); $g.Dispose(); $b.Dispose()
            L "pixel $arg = $($px.R),$($px.G),$($px.B)"
        }
        default  { L "unknown step '$step'" }
    }
}

$bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
$png = "C:\PL300\Snapshots\$BlobName"
$bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
$base = ($SasUrl -split '\?')[0]; $q = ($SasUrl -split '\?')[1]
Invoke-RestMethod -Uri "$base/$BlobName`?$q" -Method Put -InFile $png -Headers @{'x-ms-blob-type' = 'BlockBlob'} -ContentType 'image/png' | Out-Null
Invoke-RestMethod -Uri "$base/probe.txt`?$q" -Method Put -InFile $log -Headers @{'x-ms-blob-type' = 'BlockBlob'} | Out-Null
L 'done'
PSEOF
PROBE_B64="$(base64 -w0 "$PROBE")"

info "running ${#STEPS[@]} step(s): $STEP_ARG"
az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts "
[IO.File]::WriteAllBytes('C:\\PL300\\Tools\\probe.ps1',[Convert]::FromBase64String('$PROBE_B64'))
\$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File \"C:\\PL300\\Tools\\probe.ps1\" -SasUrl \"$SASURL\" -BlobName \"$OUT_NAME\" -Steps \"$STEP_ARG\"'
\$pr = New-ScheduledTaskPrincipal -UserId 'pl300admin' -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName 'PL300-Probe' -Action \$a -Principal \$pr -Force | Out-Null
Start-ScheduledTask -TaskName 'PL300-Probe'
Start-Sleep -Seconds 12
\$lim=(Get-Date).AddSeconds(150)
while((Get-Date) -lt \$lim){ if((Get-Content 'C:\\PL300\\Snapshots\\probe.txt' -EA SilentlyContinue) -match 'done'){break}; Start-Sleep -Seconds 5 }
Get-Content 'C:\\PL300\\Snapshots\\probe.txt' -EA SilentlyContinue" \
  --query 'value[0].message' -o tsv 2>&1 | sed 's/^/  /'

az storage blob download --account-name "$SA" --account-key "$KEY" -c screenshots \
  -n "$OUT_NAME" -f "$SHOT_DIR/$OUT_NAME" --overwrite -o none >/dev/null 2>&1 \
  && ok "screenshot: $SHOT_DIR/$OUT_NAME" || die "no screenshot produced"
