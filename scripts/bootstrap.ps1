<#
    PL-300 demo VM bootstrap.

    Runs once via the Azure Custom Script Extension, which drops this file and
    its siblings (configure-sql.sql, restore-adventureworks.sql,
    demo-data.zip) into the same directory before executing it.

    Design notes:
      * Every step is wrapped by Invoke-Step, which logs, times and records the
        outcome without aborting the run. A failed SSMS download shouldn't cost
        you the AdventureWorks restore.
      * The script always exits 0. Real status lives in C:\PL300\Logs\status.json
        and is checked afterwards by scripts/verify.sh - that way a transient
        download failure doesn't leave the whole Terraform apply tainted.
      * Everything is idempotent, so re-running it to repair a partial install
        is safe:
            powershell -File C:\PL300\bootstrap.ps1 -SqlAdminLogin ... -SqlAdminPassword ...
#>

[CmdletBinding()]
param(
    [string] $SqlAdminLogin = 'pl300sql',

    # Prefer -SqlAdminPasswordB64. The Custom Script Extension runs
    # commandToExecute through cmd.exe and then powershell.exe -File, and
    # neither handles quoting the way you would hope: cmd can expand `%` and
    # `!`, and powershell.exe -File does not treat single quotes as grouping, so
    # a password or a timezone containing a space silently splits into extra
    # positional arguments. Base64 uses only A-Za-z0-9+/= which survives both
    # layers untouched.
    [string] $SqlAdminPassword,
    [string] $SqlAdminPasswordB64,

    [string] $WindowsAdminUser = 'pl300admin',
    [string] $TimeZoneId       = 'Central Standard Time',
    [string] $RootPath         = 'C:\PL300',

    # Hash of the whole payload (this script, the two .sql files, the demo data
    # zip), supplied by Terraform. Nothing reads it - its purpose is to change
    # the extension's settings when the payload changes, so that editing a demo
    # file actually re-runs the bootstrap instead of silently leaving stale
    # files on the VM.
    [string] $PayloadVersion   = 'unspecified',

    [switch] $SkipReboot
)

# No Mandatory parameters anywhere in this script: an unsatisfied mandatory
# parameter prompts, and a prompt in a non-interactive extension run hangs until
# the extension times out.
if (-not $SqlAdminPassword -and $SqlAdminPasswordB64) {
    $SqlAdminPassword = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($SqlAdminPasswordB64))
}
if (-not $SqlAdminPassword) {
    throw 'Supply either -SqlAdminPassword or -SqlAdminPasswordB64.'
}

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # huge speedup for Invoke-WebRequest

# --------------------------------------------------------------------------- #
# Paths and logging
# --------------------------------------------------------------------------- #

$Paths = @{
    Root      = $RootPath
    Data      = Join-Path $RootPath 'Data'
    Backups   = Join-Path $RootPath 'Backups'
    Logs      = Join-Path $RootPath 'Logs'
    Downloads = Join-Path $RootPath 'Downloads'
    Scripts   = Join-Path $RootPath 'Scripts'
}
foreach ($p in $Paths.Values) { New-Item -ItemType Directory -Path $p -Force | Out-Null }

$LogFile    = Join-Path $Paths.Logs 'bootstrap.log'
$StatusFile = Join-Path $Paths.Logs 'status.json'
$Steps      = [System.Collections.ArrayList]::new()
$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Write-Log {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string] $Level = 'INFO')
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $LogFile -Value $line -Encoding utf8
    Write-Host $line
}

function Save-Status {
    $ok = @($Steps | Where-Object { $_.status -eq 'ok' }).Count
    $payload = [ordered]@{
        completedAt = (Get-Date).ToString('o')
        computerName = $env:COMPUTERNAME
        stepsTotal  = $Steps.Count
        stepsOk     = $ok
        stepsFailed = $Steps.Count - $ok
        steps       = $Steps
    }
    $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $StatusFile -Encoding utf8
}

function Invoke-Step {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][scriptblock] $Action,
        [switch] $Critical
    )
    Write-Log "==> $Name"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $record = [ordered]@{ name = $Name; status = 'ok'; seconds = 0; critical = [bool]$Critical; error = $null }
    try {
        & $Action
        $sw.Stop()
        $record.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Write-Log "    done in $($record.seconds)s" -Level OK
    }
    catch {
        $sw.Stop()
        $record.status  = 'failed'
        $record.seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $record.error   = $_.Exception.Message
        Write-Log "    FAILED after $($record.seconds)s: $($_.Exception.Message)" -Level ERROR
    }
    [void]$Steps.Add($record)
    Save-Status
}

function Get-RemoteFile {
    <# Download with retry. Azure egress is reliable but the upstream CDNs
       occasionally throttle, and a class build is not worth losing to one
       dropped connection. #>
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $OutFile,
        [int] $Retries = 4
    )
    if ((Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 1mb) {
        Write-Log "    already downloaded: $(Split-Path $OutFile -Leaf)"
        return
    }
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Write-Log "    downloading (attempt $i): $Uri"
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 1800
            $mb = [math]::Round((Get-Item $OutFile).Length / 1mb, 1)
            Write-Log "    got $(Split-Path $OutFile -Leaf) ($mb MB)"
            return
        }
        catch {
            Write-Log "    attempt $i failed: $($_.Exception.Message)" -Level WARN
            if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
            if ($i -eq $Retries) { throw }
            Start-Sleep -Seconds (10 * $i)
        }
    }
}

Write-Log '================ PL-300 bootstrap starting ================'
Write-Log "script dir : $ScriptDir"
Write-Log "root path  : $($Paths.Root)"
Write-Log "sql login  : $SqlAdminLogin"
Write-Log "payload    : $PayloadVersion"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --------------------------------------------------------------------------- #
# 1. Host preparation
# --------------------------------------------------------------------------- #

Invoke-Step 'Configure Windows for demo use' {
    # Server Manager popping up over a shared screen every login is noise.
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager' `
        -Name 'DoNotOpenServerManagerAtLogon' -Value 1 -PropertyType DWord -Force | Out-Null

    # IE Enhanced Security Configuration blocks app.powerbi.com and the docs
    # site behind endless prompts.
    foreach ($key in @(
        'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}',
        'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}')) {
        if (Test-Path $key) {
            Set-ItemProperty -Path $key -Name 'IsInstalled' -Value 0 -Type DWord -Force
        }
    }

    # Show file extensions - you cannot teach "get data from JSON" while the
    # shell hides which file is which.
    #
    # This script runs as SYSTEM, so HKCU here is SYSTEM's hive, not the hive of
    # the account that will actually RDP in. That profile does not exist yet
    # (it is created at first logon), so write the setting into the Default User
    # hive and let the new profile inherit it.
    $defaultHive = 'C:\Users\Default\NTUSER.DAT'
    if (Test-Path $defaultHive) {
        & reg.exe load 'HKU\PL300Default' $defaultHive 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            try {
                $adv = 'Registry::HKEY_USERS\PL300Default\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                if (-not (Test-Path $adv)) { New-Item -Path $adv -Force | Out-Null }
                Set-ItemProperty -Path $adv -Name 'HideFileExt' -Value 0 -Type DWord -Force
                Set-ItemProperty -Path $adv -Name 'Hidden'      -Value 1 -Type DWord -Force
            }
            finally {
                # The hive must be unloaded or the profile is left locked, and
                # first logon then fails with a temporary profile.
                [gc]::Collect()
                & reg.exe unload 'HKU\PL300Default' 2>&1 | Out-Null
            }
        }
        else {
            Write-Log '    could not load the default user hive; file extensions stay hidden' -Level WARN
        }
    }

    # Suppress the "why did you shut down" dialog on every restart.
    $reliability = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Reliability'
    if (-not (Test-Path $reliability)) { New-Item -Path $reliability -Force | Out-Null }
    Set-ItemProperty -Path $reliability -Name 'ShutdownReasonOn' -Value 0 -Type DWord -Force

    try { Set-TimeZone -Id $TimeZoneId } catch { Write-Log "    timezone '$TimeZoneId' rejected, leaving UTC" -Level WARN }

    # Windows Server ships with audio disabled; screen-share demos need it.
    foreach ($svc in 'Audiosrv', 'AudioEndpointBuilder') {
        try {
            Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        } catch { Write-Log "    could not enable $svc" -Level WARN }
    }

    powercfg /setactive SCHEME_MIN 2>&1 | Out-Null   # High performance
}

Invoke-Step 'Install Chocolatey' {
    if (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        Write-Log '    already installed'
        return
    }
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not (Get-Command choco.exe -ErrorAction SilentlyContinue)) {
        throw 'Chocolatey install reported success but choco.exe is not on PATH.'
    }
    choco feature enable -n=allowGlobalConfirmation --limit-output | Out-Null
    choco config set --name=commandExecutionTimeoutSeconds --value=3600 --limit-output | Out-Null
}

# --------------------------------------------------------------------------- #
# 2. Client tools
# --------------------------------------------------------------------------- #

function Install-ChocoPackage {
    param([Parameter(Mandatory)][string] $Id, [string] $ExtraArgs = '')
    $argv = @('install', $Id, '-y', '--no-progress', '--limit-output', '--ignore-checksums')
    if ($ExtraArgs) { $argv += $ExtraArgs.Split(' ') }
    Write-Log "    choco $($argv -join ' ')"
    & choco.exe @argv 2>&1 | ForEach-Object { Add-Content -Path $LogFile -Value "        $_" -Encoding utf8 }
    # 3010 = success, reboot required. Chocolatey surfaces it as a failure code.
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
        throw "choco install $Id exited with $LASTEXITCODE"
    }
}

Invoke-Step 'Install Power BI Desktop' -Critical {
    # Chocolatey first: it tracks the current installer URL, which Microsoft
    # rotates. aka.ms/pbiSingleInstaller is the documented fallback.
    try {
        Install-ChocoPackage -Id 'powerbi'
    }
    catch {
        Write-Log "    chocolatey route failed ($($_.Exception.Message)); trying direct installer" -Level WARN
        $exe = Join-Path $Paths.Downloads 'PBIDesktopSetup_x64.exe'
        Get-RemoteFile -Uri 'https://aka.ms/pbiSingleInstaller' -OutFile $exe
        $p = Start-Process -FilePath $exe -ArgumentList '-s', '-norestart', 'ACCEPT_EULA=1' -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) {
            throw "Power BI Desktop installer exited with $($p.ExitCode)"
        }
    }
}

Invoke-Step 'Install SQL Server Management Studio' {
    Install-ChocoPackage -Id 'sql-server-management-studio'
}

Invoke-Step 'Install supporting tools' {
    # Not strictly required for PL-300, but DAX Studio comes up constantly once
    # the class reaches modelling and DAX optimisation.
    # (Tabular Editor is handled separately - there is no Chocolatey package for
    # it; `choco install tabulareditor` fails with "package was not found".)
    foreach ($pkg in 'daxstudio', '7zip', 'notepadplusplus') {
        try { Install-ChocoPackage -Id $pkg }
        catch { Write-Log "    optional package '$pkg' failed: $($_.Exception.Message)" -Level WARN }
    }
}

Invoke-Step 'Install Tabular Editor (portable)' {
    # Tabular Editor 2 ships as a portable zip on GitHub and needs no installer,
    # which is also why nobody maintains a Chocolatey package for it.
    $dest = Join-Path $Paths.Root 'Tools\TabularEditor'
    $exe  = Join-Path $dest 'TabularEditor.exe'
    if (Test-Path $exe) {
        Write-Log '    already present'
    }
    else {
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        $zip = Join-Path $Paths.Downloads 'TabularEditor.Portable.zip'
        # Force a fresh download: Get-RemoteFile's cache check assumes installers
        # larger than 1 MB and this zip is smaller.
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
        Invoke-WebRequest -UseBasicParsing -TimeoutSec 600 -OutFile $zip `
            -Uri 'https://github.com/TabularEditor/TabularEditor/releases/latest/download/TabularEditor.Portable.zip'
        Expand-Archive -Path $zip -DestinationPath $dest -Force
        if (-not (Test-Path $exe)) { throw 'TabularEditor.exe missing after extracting the portable zip.' }
    }

    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut('C:\Users\Public\Desktop\Tabular Editor.lnk')
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $dest
    $lnk.Description = 'Tabular Editor 2 (portable)'
    $lnk.Save()
}

# --------------------------------------------------------------------------- #
# 3. SQL Server
# --------------------------------------------------------------------------- #

function Get-SqlCmdPath {
    $cmd = Get-Command sqlcmd.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = Get-ChildItem -Path 'C:\Program Files\Microsoft SQL Server' -Filter 'sqlcmd.exe' `
                    -Recurse -ErrorAction SilentlyContinue |
                  Sort-Object FullName -Descending
    if ($candidates) { return $candidates[0].FullName }
    throw 'sqlcmd.exe not found on this machine.'
}

function Invoke-SqlFile {
    <#
        Runs a .sql file against the local instance.

        Authentication is SQL, not Windows: the marketplace image does not make
        NT AUTHORITY\SYSTEM (which is what the Custom Script Extension runs as)
        a sysadmin, so -E fails with Msg 15247. Terraform's
        azurerm_mssql_virtual_machine resource creates this login with sysadmin
        before the extension runs.

        Variables are passed by generating a wrapper script that declares them
        with :setvar and then :r's the real file, rather than by using
        `sqlcmd -v`. sqlcmd's -v parser cannot handle an unquoted value
        containing a colon, so a Windows path like C:\PL300\Backups\x.bak is
        truncated at the drive letter and the rest is read as a stray argument.
    #>
    param(
        [Parameter(Mandatory)][string] $Path,
        [hashtable] $Variables = @{},
        [int] $TimeoutSeconds = 3600
    )
    $sqlcmd  = Get-SqlCmdPath
    $wrapper = Join-Path $env:TEMP ('pl300_' + [IO.Path]::GetRandomFileName() + '.sql')
    try {
        # @() matters: with a single variable the foreach yields a bare string,
        # and `+=` on a string concatenates instead of appending - which put
        # :setvar and :r on the same line and produced
        # "Syntax error ... near command ':setvar'".
        $lines = @(foreach ($k in $Variables.Keys) { ':setvar {0} "{1}"' -f $k, $Variables[$k] })
        $lines += ':r "{0}"' -f $Path
        Set-Content -Path $wrapper -Value $lines -Encoding ascii

        Write-Log "    sqlcmd -i $(Split-Path $Path -Leaf) [$(($Variables.Keys | Sort-Object) -join ', ')]"
        # 2>&1 on a native command turns its stderr into ErrorRecords, which
        # $ErrorActionPreference='Stop' escalates to a terminating error before
        # we can log the output. Relax it just around the call so sqlcmd's own
        # diagnostics reach the log and $LASTEXITCODE stays authoritative.
        $out = & {
            $ErrorActionPreference = 'Continue'
            & $sqlcmd -S 'localhost' -U $SqlAdminLogin -P $SqlAdminPassword `
                      -b -l 60 -t "$TimeoutSeconds" -i $wrapper 2>&1
        }
        $out | ForEach-Object { Add-Content -Path $LogFile -Value "        $_" -Encoding utf8 }
        if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed ($LASTEXITCODE) on $(Split-Path $Path -Leaf)" }
    }
    finally {
        # The wrapper holds the SQL password when configure-sql.sql runs.
        Remove-Item $wrapper -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SqlQuery {
    <#
        Single-statement query returning raw output lines.

        Retries, because this script restarts the SQL Server service and an
        instance that has only just come back can reject a perfectly valid login
        for a few seconds while it finishes recovery.
    #>
    param(
        [Parameter(Mandatory)][string] $Query,
        [string] $Database = 'master',
        [int] $Retries = 6,
        [switch] $PassThruFailure
    )
    $sqlcmd = Get-SqlCmdPath
    $out = $null
    for ($i = 1; $i -le $Retries; $i++) {
        $out = & {
            $ErrorActionPreference = 'Continue'
            & $sqlcmd -S 'localhost' -U $SqlAdminLogin -P $SqlAdminPassword `
                      -d $Database -b -h -1 -W -Q $Query 2>&1
        }
        if ($LASTEXITCODE -eq 0) { return $out }
        if ($i -lt $Retries) {
            Write-Log "    sqlcmd query failed (attempt $i/$Retries), retrying in 10s" -Level WARN
            Start-Sleep -Seconds 10
        }
    }
    if ($PassThruFailure) { return $out }
    throw "sqlcmd query failed after $Retries attempts: $(($out | Select-Object -Last 3) -join ' | ')"
}

function Wait-ForSqlLogin {
    <# The SQL IaaS extension creates the login shortly before this script runs. #>
    Invoke-SqlQuery -Query 'SET NOCOUNT ON; SELECT 1;' | Out-Null
    Write-Log "    connected to SQL Server as '$SqlAdminLogin'"
}

# Terraform's azurerm_mssql_virtual_machine already enabled mixed-mode auth,
# TCP/IP and the firewall rule before this script runs. This step re-asserts it,
# pins the port to 1433 on every IP entry, and starts SQL Browser - so it is
# belt-and-braces rather than load-bearing, hence not Critical.
Invoke-Step 'Re-assert SQL Server TCP/IP configuration' {
    $instanceKey = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -ErrorAction Stop |
                   Where-Object { $_.PSChildName -match '^MSSQL\d+\.MSSQLSERVER$' } |
                   Select-Object -First 1
    if (-not $instanceKey) { throw 'Could not locate the default SQL Server instance registry key.' }
    $base = $instanceKey.PSPath
    Write-Log "    instance key: $($instanceKey.PSChildName)"

    # Only restart SQL Server if a value actually changed. Restarting an
    # instance that is already configured correctly is pure downside: it briefly
    # rejects valid logins while it recovers, which is what made the following
    # steps fail intermittently.
    $changed = $false
    function Set-IfDifferent {
        param($Path, $Name, $Value, $Type)
        $current = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ("$current" -ne "$Value") {
            Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
            Write-Log "    changed $Name : '$current' -> '$Value'"
            $script:sqlRegistryChanged = $true
        }
    }
    $script:sqlRegistryChanged = $false

    # LoginMode 2 = SQL Server and Windows Authentication.
    Set-IfDifferent -Path (Join-Path $base 'MSSQLServer') -Name 'LoginMode' -Value 2 -Type DWord

    # Enable the TCP/IP protocol and pin it to 1433.
    $tcp = Join-Path $base 'MSSQLServer\SuperSocketNetLib\Tcp'
    Set-IfDifferent -Path $tcp -Name 'Enabled' -Value 1 -Type DWord
    $ipAll = Join-Path $tcp 'IPAll'
    Set-IfDifferent -Path $ipAll -Name 'TcpPort'         -Value '1433' -Type String
    Set-IfDifferent -Path $ipAll -Name 'TcpDynamicPorts' -Value ''     -Type String
    foreach ($ipKey in Get-ChildItem $tcp | Where-Object { $_.PSChildName -match '^IP\d+$' }) {
        Set-IfDifferent -Path $ipKey.PSPath -Name 'Enabled' -Value 1 -Type DWord
    }

    New-NetFirewallRule -DisplayName 'SQL Server (TCP 1433)' -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 1433 -ErrorAction SilentlyContinue | Out-Null
    New-NetFirewallRule -DisplayName 'SQL Server Browser (UDP 1434)' -Direction Inbound -Action Allow `
        -Protocol UDP -LocalPort 1434 -ErrorAction SilentlyContinue | Out-Null

    Set-Service -Name 'SQLBrowser' -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name 'SQLBrowser' -ErrorAction SilentlyContinue
    Set-Service -Name 'MSSQLSERVER' -StartupType Automatic

    if (-not $script:sqlRegistryChanged) {
        Write-Log '    already configured by the SQL IaaS extension - no restart needed'
    }
    else {
        Write-Log '    restarting MSSQLSERVER to apply protocol changes'
        Restart-Service -Name 'MSSQLSERVER' -Force
        for ($i = 0; $i -lt 30; $i++) {
            if ((Get-Service MSSQLSERVER).Status -eq 'Running') { break }
            Start-Sleep -Seconds 2
        }
        Start-Sleep -Seconds 15

        # Restart-Service -Force stopped SQL Agent as a dependent service and
        # does not bring it back.
        try {
            Set-Service -Name 'SQLSERVERAGENT' -StartupType Automatic -ErrorAction Stop
            Start-Service -Name 'SQLSERVERAGENT' -ErrorAction Stop
        }
        catch { Write-Log '    SQL Server Agent did not restart (not needed for the demos)' -Level WARN }
    }
}

Invoke-Step 'Confirm SQL login and tune instance' -Critical {
    Wait-ForSqlLogin
    $sql = Join-Path $ScriptDir 'configure-sql.sql'
    if (-not (Test-Path $sql)) { throw "configure-sql.sql not found in $ScriptDir" }
    Copy-Item $sql -Destination $Paths.Scripts -Force
    Invoke-SqlFile -Path $sql -Variables @{ SqlLogin = $SqlAdminLogin }
}

Invoke-Step 'Download AdventureWorks backups' -Critical {
    $backups = @{
        'AdventureWorks2022.bak'   = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak'
        'AdventureWorksDW2022.bak' = 'https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorksDW2022.bak'
    }
    foreach ($name in $backups.Keys) {
        Get-RemoteFile -Uri $backups[$name] -OutFile (Join-Path $Paths.Backups $name)
    }
    # SQL Server runs under a virtual service account and must be able to read
    # the .bak files. Inherited permissions from C:\ usually already allow this,
    # so treat an ACL failure as a warning rather than losing the restore step.
    try {
        $acl = Get-Acl $Paths.Backups
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            'NT SERVICE\MSSQLSERVER', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -Path $Paths.Backups -AclObject $acl
    }
    catch {
        Write-Log "    could not grant MSSQLSERVER explicit read on $($Paths.Backups): $($_.Exception.Message)" -Level WARN
    }
}

Invoke-Step 'Restore AdventureWorks databases' -Critical {
    $sql = Join-Path $ScriptDir 'restore-adventureworks.sql'
    if (-not (Test-Path $sql)) { throw "restore-adventureworks.sql not found in $ScriptDir" }
    Copy-Item $sql -Destination $Paths.Scripts -Force

    foreach ($db in 'AdventureWorksDW2022', 'AdventureWorks2022') {
        $bak = Join-Path $Paths.Backups "$db.bak"
        if (-not (Test-Path $bak)) {
            Write-Log "    backup missing, skipping $db" -Level WARN
            continue
        }
        Invoke-SqlFile -Path $sql -Variables @{ DbName = $db; BakFile = $bak }
    }
}

# --------------------------------------------------------------------------- #
# 4. Demo files
# --------------------------------------------------------------------------- #

Invoke-Step 'Unpack demo data files' -Critical {
    $zip = Join-Path $ScriptDir 'demo-data.zip'
    if (-not (Test-Path $zip)) { throw "demo-data.zip not found in $ScriptDir" }
    if (Test-Path $Paths.Data) { Remove-Item "$($Paths.Data)\*" -Recurse -Force -ErrorAction SilentlyContinue }
    Expand-Archive -Path $zip -DestinationPath $Paths.Data -Force
    $count = (Get-ChildItem $Paths.Data -Recurse -File).Count
    Write-Log "    extracted $count files to $($Paths.Data)"
    if ($count -lt 20) { throw "Expected at least 20 demo files, found $count." }
}

Invoke-Step 'Write demo guide and desktop shortcuts' {
    $guide = Join-Path $Paths.Root 'DEMO-GUIDE.md'
    @"
# PL-300 Demo Environment

Everything below is already installed and ready on this VM.

## SQL Server
- Instance: ``localhost`` (default instance, SQL Server 2022 Developer)
- Databases: ``AdventureWorksDW2022`` (star schema), ``AdventureWorks2022`` (OLTP)
- Windows auth works as-is in SSMS. SQL auth login: ``$SqlAdminLogin``
- Capped at 6 GB RAM so Power BI Desktop stays responsive.

## Demo files - C:\PL300\Data
| Folder | File | What it demonstrates |
|---|---|---|
| CSV | Sales_Transactions.csv | Clean flat file, 27k rows |
| CSV | Sales_Transactions_MESSY.csv | Power Query cleanup: preamble rows, mixed date formats, currency text, duplicates, repeated header, grand-total row |
| CSV | MonthlySales\ (12 files) | Combine Files from Folder |
| Excel | Product_Sales_Analysis.xlsx | Tables vs Sheets; ``CrossTab`` sheet needs Unpivot |
| Excel | Store_Master.xlsx | Clean dimension as a named Excel Table |
| JSON | Orders_Nested.json | Expand nested records and list columns |
| JSON | Products_Api_Response.json | API envelope: drill from record to list to table |
| XML | Product_Catalog.xml | Hierarchical XML, attributes plus elements |
| XML | Employees.xml | Flat repeating XML |
| PDF | Regional_Sales_Report.pdf | PDF connector, 4 tables across 2 pages |
| PDF | Quarterly_Summary.pdf | PDF connector, single simple table |

All of these describe the same fictional business (Contoso Outdoor Co, FY2024)
and share keys - ProductID, StoreID, RegionID, dates in 2024 - so they can be
related to each other in one model. The PDF figures reconcile with the CSV data,
which makes a good "validate your model" exercise.

## Tools installed
Power BI Desktop, SQL Server Management Studio, DAX Studio, Tabular Editor,
7-Zip, Notepad++.

## Logs
Bootstrap log: C:\PL300\Logs\bootstrap.log
Step results : C:\PL300\Logs\status.json
"@ | Set-Content -Path $guide -Encoding utf8

    $desktops = @("C:\Users\Public\Desktop")
    if ($WindowsAdminUser) {
        $userDesktop = "C:\Users\$WindowsAdminUser\Desktop"
        if (Test-Path $userDesktop) { $desktops += $userDesktop }
    }

    $shell = New-Object -ComObject WScript.Shell
    foreach ($desktop in $desktops) {
        if (-not (Test-Path $desktop)) { continue }

        $lnk = $shell.CreateShortcut((Join-Path $desktop 'PL-300 Demo Data.lnk'))
        $lnk.TargetPath = $Paths.Data
        $lnk.Description = 'CSV, Excel, JSON, XML and PDF demo files'
        $lnk.Save()

        $lnk2 = $shell.CreateShortcut((Join-Path $desktop 'PL-300 Demo Guide.lnk'))
        $lnk2.TargetPath = 'notepad.exe'
        $lnk2.Arguments = "`"$guide`""
        $lnk2.Description = 'What is installed and what each demo file teaches'
        $lnk2.Save()
    }
    Copy-Item $guide -Destination 'C:\Users\Public\Desktop\DEMO-GUIDE.md' -Force -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------- #
# 5. Verify
# --------------------------------------------------------------------------- #

Invoke-Step 'Verify installation' {
    $checks = [ordered]@{}

    $pbi = @(
        'C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe',
        'C:\Program Files (x86)\Microsoft Power BI Desktop\bin\PBIDesktop.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    $checks['PowerBIDesktop'] = if ($pbi) { $pbi } else { 'NOT FOUND' }

    $ssms = Get-ChildItem 'C:\Program Files (x86)\Microsoft SQL Server Management Studio*', `
                          'C:\Program Files\Microsoft SQL Server Management Studio*' `
                          -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    $checks['SSMS'] = if ($ssms) { $ssms.FullName } else { 'NOT FOUND' }

    $checks['SqlService'] = (Get-Service MSSQLSERVER -ErrorAction SilentlyContinue).Status.ToString()

    # Chocolatey puts DAX Studio under Program Files on 64-bit, not (x86).
    foreach ($tool in @(
        @{ Name = 'DaxStudio';     Paths = @('C:\Program Files\DAX Studio\DaxStudio.exe',
                                             'C:\Program Files (x86)\DAX Studio\DaxStudio.exe') },
        @{ Name = 'TabularEditor'; Paths = @((Join-Path $Paths.Root 'Tools\TabularEditor\TabularEditor.exe')) }
    )) {
        $found = $tool.Paths | Where-Object { Test-Path $_ } | Select-Object -First 1
        $checks[$tool.Name] = if ($found) { $found } else { 'NOT FOUND' }
    }

    try {
        $dbs = Invoke-SqlQuery -Query 'SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name LIKE ''AdventureWorks%'' ORDER BY name;' |
               Where-Object { $_ -match '^AdventureWorks' }
        $checks['Databases'] = ($dbs -join ', ')

        $checks['FactInternetSalesRows'] = "$(
            Invoke-SqlQuery -Database 'AdventureWorksDW2022' `
                -Query 'SET NOCOUNT ON; SELECT COUNT(*) FROM dbo.FactInternetSales;' |
            Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)"

        # The fact table's date span drives every time-intelligence demo, so
        # record it here rather than making the instructor go looking.
        $checks['FactDateRange'] = (Invoke-SqlQuery -Database 'AdventureWorksDW2022' `
            -Query 'SET NOCOUNT ON; SELECT CONVERT(varchar(10), MIN(OrderDate), 23) + '' to '' + CONVERT(varchar(10), MAX(OrderDate), 23) FROM dbo.FactInternetSales;' |
            Where-Object { $_ -match '^\d{4}-' } | Select-Object -First 1)

        $checks['WindowsAuthOnly'] = "$(
            Invoke-SqlQuery -Query "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS varchar(3));" |
            Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)"

        $checks['OltpTableCount'] = "$(
            Invoke-SqlQuery -Database 'AdventureWorks2022' `
                -Query 'SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables;' |
            Where-Object { $_ -match '^\d+$' } | Select-Object -First 1)"
    }
    catch {
        $checks['Databases'] = "query failed: $($_.Exception.Message)"
    }

    $checks['DemoFileCount'] = (Get-ChildItem $Paths.Data -Recurse -File -ErrorAction SilentlyContinue).Count
    $checks['DemoFormats']   = ((Get-ChildItem $Paths.Data -Recurse -File -ErrorAction SilentlyContinue |
                                 ForEach-Object { $_.Extension.ToLower() } | Sort-Object -Unique) -join ' ')

    foreach ($k in $checks.Keys) { Write-Log "    $k = $($checks[$k])" }
    $checks | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $Paths.Logs 'verify.json') -Encoding utf8

    if ($checks['PowerBIDesktop'] -eq 'NOT FOUND') { throw 'Power BI Desktop is not installed.' }
    if ($checks['Databases'] -notmatch 'AdventureWorksDW2022') { throw 'AdventureWorksDW2022 was not restored.' }
}

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #

Copy-Item (Join-Path $ScriptDir 'bootstrap.ps1') -Destination $Paths.Root -Force -ErrorAction SilentlyContinue
Save-Status

$failed = @($Steps | Where-Object { $_.status -eq 'failed' })
$criticalFailed = @($failed | Where-Object { $_.critical })

Write-Log '================ PL-300 bootstrap finished ================'
Write-Log "steps ok       : $(@($Steps | Where-Object { $_.status -eq 'ok' }).Count)/$($Steps.Count)"
if ($failed.Count) {
    Write-Log "failed steps   : $(($failed.name) -join '; ')" -Level WARN
}
if ($criticalFailed.Count) {
    Write-Log "CRITICAL failures: $(($criticalFailed.name) -join '; ')" -Level ERROR
    Write-Log 'Re-run this script after fixing the cause; every step is idempotent.' -Level ERROR
}
else {
    Write-Log 'Environment is ready.' -Level OK
}

if (-not $SkipReboot -and -not $criticalFailed.Count) {
    Write-Log 'Rebooting in 30s so the installed tools appear for the interactive session.'
    shutdown.exe /r /t 30 /c 'PL-300 bootstrap complete' /d p:4:1
}

# Always exit 0: status.json is the source of truth, and a non-zero exit here
# only serves to taint the Terraform resource. scripts/verify.sh reads the real
# result and tells you what to do about it.
exit 0
