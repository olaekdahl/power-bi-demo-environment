<#
    Capture the interactive desktop of the PL-300 demo VM and upload the PNG to
    blob storage, so a report can be visually validated from outside the VM.

    Why this exists: az vm run-command executes as SYSTEM in session 0, which has
    no desktop - a screen capture from there is black. This script is therefore
    launched by a scheduled task registered with -LogonType Interactive, which
    makes it run inside the signed-in user's session where the desktop is
    actually composed.

    Usage (from the interactive session, via the scheduled task):
        snapshot.ps1 -SasUrl <container SAS URL> -BlobName shot.png
                     [-LaunchFile <path>] [-WaitSeconds 90]

    -LaunchFile opens a file with its registered application first (used to open
    a .pbip in Power BI Desktop) and waits for it to settle before capturing.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SasUrl,
    [Parameter(Mandatory)][string] $BlobName,
    [string] $LaunchFile,
    [int]    $WaitSeconds = 90,
    [string] $WorkDir = 'C:\PL300\Snapshots',
    # A .pbip carries no data cache, so an import model opens with empty tables
    # until it is refreshed. F5 is Power BI Desktop's Refresh-all shortcut, and
    # with inline #table sources it needs no credentials.
    [int]    $RefreshWaitSeconds = 60,
    # R/Python visuals shell out to an interpreter and render a PNG; they finish
    # noticeably after the model refresh does.
    [int]    $ScriptSettleSeconds = 45,
    [switch] $NoRefresh
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$log = Join-Path $WorkDir 'snapshot.log'

function Log([string] $m) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -Path $log -Value $line
}

Log "=== snapshot start: blob=$BlobName launch=$LaunchFile wait=$WaitSeconds ==="

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

try {
    if ($LaunchFile) {
        if (-not (Test-Path $LaunchFile)) { throw "LaunchFile not found: $LaunchFile" }

        # Close any Power BI Desktop left over from a previous attempt, so the
        # capture cannot show a stale window.
        Get-Process PBIDesktop -ErrorAction SilentlyContinue | ForEach-Object {
            Log "closing existing PBIDesktop pid=$($_.Id)"
            $_.CloseMainWindow() | Out-Null
            Start-Sleep -Seconds 3
            if (-not $_.HasExited) { $_.Kill() }
        }
        Start-Sleep -Seconds 3

        # Clear the auto-recovery backlog. Killing Power BI (above) leaves
        # recovery files behind, and the next launch raises both a notification
        # bar and a modal "Auto recovery" dialog that sits over the report.
        $recovery = Join-Path $env:LOCALAPPDATA 'Microsoft\Power BI Desktop\AutoRecovery'
        if (Test-Path $recovery) {
            Remove-Item "$recovery\*" -Recurse -Force -ErrorAction SilentlyContinue
            Log 'cleared the auto-recovery backlog'
        }

        $pbi = 'C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe'
        if ((Test-Path $pbi) -and $LaunchFile -match '\.pbip$|\.pbix$') {
            Log "launching Power BI Desktop with $LaunchFile"
            Start-Process -FilePath $pbi -ArgumentList "`"$LaunchFile`""
        }
        else {
            Log "launching via shell association: $LaunchFile"
            Start-Process -FilePath $LaunchFile
        }

        # Poll until the main window has a title, then keep waiting - Power BI
        # reports a window long before the model loads and the visuals paint.
        $deadline = (Get-Date).AddSeconds($WaitSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $p = Get-Process PBIDesktop -ErrorAction SilentlyContinue |
                 Where-Object { $_.MainWindowTitle } | Select-Object -First 1
            if ($p) { Log "window: '$($p.MainWindowTitle)'" }
        }
    }

    # Maximise Power BI Desktop so the visuals fill the capture.
    $p = Get-Process PBIDesktop -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) {
        Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@
        [Win32.Native]::ShowWindow($p.MainWindowHandle, 3) | Out-Null   # SW_MAXIMIZE
        [Win32.Native]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
        Start-Sleep -Seconds 6
        Log "maximised '$($p.MainWindowTitle)'"

        if ($LaunchFile -and -not $NoRefresh) {
            Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

            # NOTE: do NOT blind-press {ESC} here. Power BI shows an "Enable
            # script visuals" consent dialog when a report contains R/Python
            # visuals, and Escape *cancels* it - which leaves every script visual
            # silently blank with no error message at all. Click Enable instead.
            function Invoke-UiaButton {
                param([int] $ProcessId, [string] $ButtonName)
                try {
                    $AE = [System.Windows.Automation.AutomationElement]
                    $root = $AE::RootElement.FindFirst(
                        [System.Windows.Automation.TreeScope]::Children,
                        (New-Object System.Windows.Automation.PropertyCondition(
                            $AE::ProcessIdProperty, $ProcessId)))
                    if (-not $root) { return $false }
                    $cond = New-Object System.Windows.Automation.AndCondition(
                        (New-Object System.Windows.Automation.PropertyCondition(
                            $AE::NameProperty, $ButtonName)),
                        (New-Object System.Windows.Automation.PropertyCondition(
                            $AE::ControlTypeProperty,
                            [System.Windows.Automation.ControlType]::Button)))
                    $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)
                    Log "UIA: $($found.Count) button(s) named '$ButtonName'"
                    foreach ($b in $found) {
                        try {
                            $b.GetCurrentPattern(
                                [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                            Log "UIA: invoked '$ButtonName'"
                            return $true
                        } catch { }
                    }
                }
                catch { Log "UIA failed for '$ButtonName': $($_.Exception.Message)" }
                return $false
            }

            Add-Type -Namespace Win32 -Name Mouse -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, int e);
'@
            function Invoke-Click {
                param([int] $X, [int] $Y)
                [Win32.Mouse]::SetCursorPos($X, $Y)
                Start-Sleep -Milliseconds 350
                [Win32.Mouse]::mouse_event(0x0002, 0, 0, 0, 0)   # LEFTDOWN
                [Win32.Mouse]::mouse_event(0x0004, 0, 0, 0, 0)   # LEFTUP
            }

            function Get-ScreenPixel {
                param([int] $X, [int] $Y)
                $b = New-Object System.Drawing.Bitmap(1, 1)
                $g = [System.Drawing.Graphics]::FromImage($b)
                $g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size(1, 1)))
                $c = $b.GetPixel(0, 0)
                $g.Dispose(); $b.Dispose()
                return $c
            }

            # 1. Consent to script visuals.
            #
            # This dialog is rendered by Power BI's embedded WebView2, not as
            # native WPF controls, so UI Automation cannot find a Button named
            # "Enable" - a UIA search returns 0 matches even while the dialog is
            # plainly on screen. Locate it by the accent colour of its Enable
            # button instead, which is a stable RGB(17,120,101).
            #
            # The search is over the middle of the screen rather than at fixed
            # coordinates, because the desktop resolution is not guaranteed
            # (moving the session to the console drops it to 1024x768, which
            # silently invalidated every hard-coded position).
            function Find-AccentButtons {
                <#
                    Return the centres of accent-coloured buttons, clustered.

                    Clustering matters: when the consent prompt is up there are
                    TWO accent buttons on screen - the dialog's "Enable" and the
                    "Select to enable" button drawn inside the visual itself. An
                    earlier version took the bounding box of all matching pixels,
                    which spanned both and was rejected by its own size guard, so
                    it reported "no dialog" while the dialog was plainly visible.
                #>
                param([int] $R = 17, [int] $G = 120, [int] $B = 101)
                $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
                $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
                $gfx = [System.Drawing.Graphics]::FromImage($bmp)
                $gfx.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
                try {
                    $x0 = [int]($vs.Width * 0.15);  $x1 = [int]($vs.Width * 0.85)
                    $y0 = [int]($vs.Height * 0.25); $y1 = [int]($vs.Height * 0.85)
                    $clusters = New-Object System.Collections.ArrayList
                    for ($y = $y0; $y -lt $y1; $y += 3) {
                        for ($x = $x0; $x -lt $x1; $x += 3) {
                            $c = $bmp.GetPixel($x, $y)
                            if ($c.R -ne $R -or $c.G -ne $G -or $c.B -ne $B) { continue }
                            $placed = $false
                            foreach ($cl in $clusters) {
                                if ([math]::Abs($x - $cl.CX) -le 90 -and [math]::Abs($y - $cl.CY) -le 40) {
                                    $cl.N++
                                    $cl.CX = [int]((($cl.CX * ($cl.N - 1)) + $x) / $cl.N)
                                    $cl.CY = [int]((($cl.CY * ($cl.N - 1)) + $y) / $cl.N)
                                    $placed = $true
                                    break
                                }
                            }
                            if (-not $placed) {
                                [void]$clusters.Add([pscustomobject]@{ CX = $x; CY = $y; N = 1 })
                            }
                        }
                    }
                    # Text links are also accent-coloured; require a solid block.
                    return @($clusters | Where-Object { $_.N -ge 12 } | Sort-Object CY)
                }
                finally { $gfx.Dispose(); $bmp.Dispose() }
            }

            function Enable-ScriptVisuals {
                param([string] $Stage)
                $btns = Find-AccentButtons
                if (-not $btns -or $btns.Count -eq 0) {
                    Log "[$Stage] no accent buttons on screen"
                    return $false
                }
                Log ("[$Stage] accent buttons: " + (($btns | ForEach-Object { "($($_.CX),$($_.CY)) n=$($_.N)" }) -join ' '))
                # Topmost first: that is the dialog's Enable when the modal is up.
                foreach ($b in $btns) {
                    Invoke-Click -X $b.CX -Y $b.CY
                    Start-Sleep -Seconds 6
                    if (-not (Find-AccentButtons)) { Log "[$Stage] consent cleared"; return $true }
                }
                Start-Sleep -Seconds 4
                return $true
            }

            Enable-ScriptVisuals -Stage 'pre-refresh' | Out-Null

            # 2. A .pbip stores no data, so the model opens empty and must be
            #    refreshed. F5 is unreliable (focus inside a visual swallows it),
            #    so drive the ribbon Refresh button, falling back to a click at
            #    its fixed 1920x1080 position.
            [Win32.Native]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 800
            if (-not (Invoke-UiaButton -ProcessId $p.Id -ButtonName 'Refresh')) {
                Add-Type -Namespace Win32 -Name Mouse -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, int e);
'@
                Log 'falling back to clicking the ribbon Refresh button'
                [Win32.Mouse]::SetCursorPos(609, 105); Start-Sleep -Milliseconds 400
                [Win32.Mouse]::mouse_event(0x0002, 0, 0, 0, 0)
                [Win32.Mouse]::mouse_event(0x0004, 0, 0, 0, 0)
            }

            Start-Sleep -Seconds $RefreshWaitSeconds

            # 2b. Now that script visuals are consented to, Escape is safe and is
            #     the simplest way to close purely informational pop-ups Power BI
            #     raises after a refresh (for example the "Bing map visuals are
            #     going away" deprecation notice). Do NOT move this before the
            #     Enable click - Escape cancels that one.
            [Win32.Native]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 500
            for ($i = 1; $i -le 3; $i++) {
                [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
                Start-Sleep -Seconds 2
            }
            Log 'dismissed informational dialogs'

            # 3. Dismiss the notification bars ("Auto recovery...", "relationships
            #    have been modified...", "tables have incomplete or no data").
            #    Each one steals ~33px from the canvas and clips the page header.
            #    Their close button sits at a fixed spot, and dismissing one
            #    slides the next into the same place, so click repeatedly.
            [Win32.Native]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 600
            $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
            $barX = $vs.Width - 379   # close button, measured from the right edge
            $barY = 177
            for ($i = 1; $i -le 4; $i++) {
                $c = Get-ScreenPixel -X $barX -Y $barY
                # The bars are pale grey/yellow; the canvas behind them is white.
                if ($c.R -ge 250 -and $c.G -ge 250 -and $c.B -ge 250) { break }
                Invoke-Click -X $barX -Y $barY
                Start-Sleep -Seconds 2
            }
            Log 'dismissed notification bars'

            # 4. Check for the consent prompt AGAIN. Power BI raises it when the
            #    page containing a script visual actually paints, which is after
            #    the refresh completes - so a single pre-refresh check misses it.
            [Win32.Native]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
            Start-Sleep -Seconds 2
            Enable-ScriptVisuals -Stage 'post-refresh' | Out-Null

            # 5. Script visuals shell out to an interpreter and render a PNG, so
            #    they finish well after the model refresh does.
            [Win32.Native]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
            Start-Sleep -Seconds $ScriptSettleSeconds

            $p2 = Get-Process PBIDesktop -ErrorAction SilentlyContinue |
                  Where-Object { $_.MainWindowTitle } | Select-Object -First 1
            if ($p2) { Log "after refresh: '$($p2.MainWindowTitle)'" }
        }
    }
    else {
        Log 'no PBIDesktop window found; capturing the desktop as-is'
    }

    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    Log "virtual screen: $($bounds.Width)x$($bounds.Height)"
    if ($bounds.Width -le 0 -or $bounds.Height -le 0) {
        throw "No usable desktop bounds ($($bounds.Width)x$($bounds.Height)) - is this running in an interactive session?"
    }

    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $local = Join-Path $WorkDir $BlobName
    $bmp.Save($local, [System.Drawing.Imaging.ImageFormat]::Png)
    $gfx.Dispose(); $bmp.Dispose()

    $sizeKb = [math]::Round((Get-Item $local).Length / 1kb, 1)
    Log "saved $local ($sizeKb KB)"

    # An all-black capture means we grabbed a session with no composed desktop -
    # worth detecting explicitly rather than shipping a black PNG as "success".
    $check = New-Object System.Drawing.Bitmap($local)
    $distinct = @{}
    for ($x = 0; $x -lt $check.Width; $x += 40) {
        for ($y = 0; $y -lt $check.Height; $y += 40) {
            $distinct[$check.GetPixel($x, $y).ToArgb()] = $true
        }
    }
    $colours = $distinct.Count
    $check.Dispose()
    Log "distinct sampled colours: $colours"
    if ($colours -le 2) { Log 'WARNING: capture looks blank' }

    # Upload with a container SAS. -InFile keeps the whole PNG out of memory.
    $uri = $SasUrl -replace '\?', "/$BlobName`?"
    Invoke-RestMethod -Uri $uri -Method Put -InFile $local `
        -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -ContentType 'image/png' | Out-Null
    Log "uploaded to $BlobName"

    # Power BI Desktop's own traces are far more informative than the "Something
    # went wrong" dialog, and reading them beats trying to click through a modal.
    $traceRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power BI Desktop\Traces'
    if (Test-Path $traceRoot) {
        $recent = Get-ChildItem $traceRoot -Recurse -Include '*.log', '*.pbixtrace.log' `
                    -ErrorAction SilentlyContinue |
                  Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-12) } |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 4
        foreach ($f in $recent) {
            $hits = Select-String -Path $f.FullName -ErrorAction SilentlyContinue `
                        -Pattern 'error|exception|invalid|failed|cannot|unable' |
                    Select-Object -Last 12
            if ($hits) {
                Log "--- traces from $($f.Name) ---"
                foreach ($h in $hits) {
                    # Keep lines short; these can be enormous single-line JSON blobs.
                    $t = $h.Line.Trim()
                    if ($t.Length -gt 600) { $t = $t.Substring(0, 600) + ' ...[truncated]' }
                    Log "    $t"
                }
            }
        }
    }
    else {
        Log "no trace directory at $traceRoot"
    }

    Log "RESULT ok colours=$colours size=${sizeKb}KB"
}
catch {
    Log "RESULT failed: $($_.Exception.Message)"
    throw
}
