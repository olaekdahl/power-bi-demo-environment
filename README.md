# PL-300 Demo Environment

Infrastructure-as-code for a self-contained **Microsoft PL-300 (Power BI Data Analyst)**
teaching environment on Azure: one Windows VM with Power BI Desktop, SQL Server 2022
with both AdventureWorks sample databases, and a purpose-built set of CSV / Excel /
JSON / XML / PDF demo files.

Course reference: [PL-300T00 study guide](https://learn.microsoft.com/en-us/training/courses/PL-300T00)

## What gets built

| | |
|---|---|
| Resource group | `pbi-rg` (eastus2) |
| VM | `Standard_D4as_v4` — 4 vCPU / 16 GB, Premium SSD 256 GB |
| Image | `MicrosoftSQLServer:sql2022-ws2022:sqldev-gen2` — Windows Server 2022 + SQL Server 2022 **Developer** |
| Databases | `AdventureWorksDW2022` (star schema), `AdventureWorks2022` (OLTP) |
| Tools | Power BI Desktop, SSMS, DAX Studio, Tabular Editor 2, VS Code, Python 3.12, Git, 7-Zip, Notepad++ |
| Python | `pandas`, `matplotlib`, `numpy`, `seaborn`, `openpyxl`, `ipykernel` — machine-wide |
| Demo files | 22 files on the VM at `C:\PL300\Data`, also in blob storage |
| Access | RDP 3389 and SQL 1433, restricted to **your public IP only** |
| Cost control | Nightly auto-shutdown, plus start/stop scripts |

> **Why `D4as_v4` and not `D4s_v5`?** This subscription has **0 quota** for the DSv5
> family. `D4as_v4` is the same shape (4 vCPU / 16 GB, premium storage, all three
> zones) at the same price. Other sizes with quota here: `D4s_v3`, `D4s_v4`,
> `D4ds_v4`. Change `vm_size` in `terraform/variables.tf` if you raise quota.

## Deploy

```bash
az login
./scripts/deploy.sh
```

That is the whole thing. It detects your public IP, generates the demo data,
runs `terraform apply`, then verifies the result. Expect **25–45 minutes** —
most of it is the VM installing Power BI Desktop and SSMS and restoring the
AdventureWorks backups.

To pin a specific source IP instead of autodetecting:

```bash
./scripts/deploy.sh 203.0.113.45
```

Then get your connection details:

```bash
terraform -chdir=terraform output -raw connection_summary
terraform -chdir=terraform output -raw admin_password
```

See [docs/CONNECT.md](docs/CONNECT.md) for step-by-step connection instructions
and [docs/DEMO-GUIDE.md](docs/DEMO-GUIDE.md) for what each demo file teaches and
which PL-300 module it maps to.

## Day-to-day

```bash
./scripts/start-vm.sh          # start before class
./scripts/stop-vm.sh           # deallocate after class - this is what stops the bill
./scripts/verify.sh            # confirm the environment is healthy
./scripts/update-my-ip.sh      # regain RDP access after your IP changes
./scripts/rerun-bootstrap.sh   # repair a partial software install in place
./scripts/destroy.sh           # delete pbi-rg and everything in it
```

## Optional extras

Three things are genuinely useful for PL-300 but deliberately off by default.
Enable any of them in `terraform/terraform.tfvars`, then re-run
`terraform apply` (the bootstrap re-runs and skips everything already installed):

```hcl
extra_choco_packages = ["powerbigateway", "r.project", "almtoolkit"]
```

| Package | Why you might want it | Why it is off |
|---|---|---|
| `powerbigateway` | On-premises data gateway — the missing piece when you explain why `C:\PL300\Data` breaks a scheduled refresh in the service | Cannot be *registered* without a Power BI/Fabric account, so it installs a service that just sits there |
| `r.project` | R runtime, so R visuals work alongside Python | Another ~200 MB and most classes only demo Python |
| `almtoolkit` | Semantic model diff/deploy demos for the "Manage" objectives | Overlaps Tabular Editor for most teaching purposes |

## Cost

| State | Cost |
|---|---|
| VM running | **~$0.376/hr** (compute + Windows licence; SQL Developer is free) |
| VM deallocated | **$0** compute |
| Always-on | ~$25/month — 256 GB Premium SSD, static public IP, storage account |

An 8-hour class day costs roughly **$3**. Left running 24/7 it would be about
**$275/month**, which is why auto-shutdown defaults to on at 20:00 Central.
Change it in `terraform/variables.tf` (`auto_shutdown_time`,
`auto_shutdown_timezone`), or set `auto_shutdown_enabled = false` to remove it.

**Auto-shutdown does not stop disk and IP charges.** Run `./scripts/destroy.sh`
between courses if the environment will sit idle for weeks.

## Layout

```
terraform/
  main.tf          network, VM, storage, extension, auto-shutdown
  variables.tf     all knobs, with sizing and quota notes
  outputs.tf       connection details (passwords marked sensitive)
scripts/
  deploy.sh              end-to-end build
  verify.sh              read bootstrap results back off the VM
  start-vm.sh stop-vm.sh billing control
  update-my-ip.sh        fix NSG after your IP changes
  rerun-bootstrap.sh     idempotent in-place repair
  destroy.sh             tear down
  generate-demo-data.py  builds the CSV/Excel/JSON/XML/PDF set
  bootstrap.ps1          runs on the VM: tools, SQL config, restores, demo files
  sql/
    configure-sql.sql            login, mixed-mode auth, memory cap
    restore-adventureworks.sql   header-driven restore with MOVE
docs/
  CONNECT.md       how to get in
  DEMO-GUIDE.md    demo file catalogue mapped to PL-300 modules
```

## Design notes

**Secrets.** The admin password is generated by Terraform and never written to a
file in the repo. Read it with `terraform output -raw admin_password`. It does
live in `terraform.tfstate`, which is local and gitignored — treat that file as
a secret.

**The extension uses a container SAS, not the managed identity.** The first
build tried managed identity, which is the tidier design, and it failed: storage
**data-plane** RBAC is eventually consistent, and `Storage Blob Data Reader` was
still not effective more than two minutes after the role assignment returned, so
the Custom Script Extension's download died with `403 … not authorized to perform
this operation using this permission`. A fixed `time_sleep` only makes that race
longer, not winnable. A read-only container SAS is effective immediately, so the
extension uses that and the deploy has no race to lose. The VM keeps its managed
identity and role assignment, which is what you'd use for the "connect to cloud
data without a stored credential" discussion.

The SAS window is pinned to a `time_static` resource so it doesn't drift on every
plan. It is valid for one year; if this environment somehow outlives that and the
extension needs recreating, refresh it with:

```bash
terraform -chdir=terraform apply -replace=time_static.sas_start
```

**Extension arguments are double-quoted, and the password is base64.** The second
build failed too, with `A positional parameter cannot be found that accepts
argument 'Time'`. The extension writes `commandToExecute` to a `.cmd` file run by
`cmd.exe`, which then launches `powershell.exe -File` — and single quotes are not
grouping characters to either parser, so `'Central Standard Time'` arrived as
three separate arguments. Double quotes group correctly in both. The password is
passed base64-encoded on top of that, because `cmd.exe` can expand `%` and `!`
inside an unquoted value and the generated password contains `!`.

**Bootstrap always exits 0.** Each step is independent and records its outcome to
`C:\PL300\Logs\status.json`. A failed optional download (say Tabular Editor)
therefore doesn't taint the Terraform resource or block the rest of the build.
`scripts/verify.sh` is what reports the real state, and
`scripts/rerun-bootstrap.sh` repairs in place — every step is idempotent.

**SQL is configured through the SQL IaaS Agent extension, not the bootstrap
script.** The third build got further and then failed on `Msg 15247, User does
not have permission to perform this action`: the marketplace SQL image does not
grant `NT AUTHORITY\SYSTEM` the sysadmin role, and the Custom Script Extension
runs as SYSTEM — so the bootstrap cannot configure SQL Server over Windows
authentication at all. `azurerm_mssql_virtual_machine` creates a
SQL-authentication sysadmin login through the Azure control plane (and enables
mixed-mode auth, TCP/IP and the guest firewall rule), and the bootstrap then
connects with that login instead of `-E`.

**`sqlcmd -v` is not used for paths.** It cannot parse an unquoted value
containing a colon: `-v BakFile=C:\PL300\Backups\x.bak` is truncated at the drive
letter and the remainder is read as a stray argument. `Invoke-SqlFile` instead
generates a small wrapper script that declares the values with `:setvar` (quoted)
and then `:r`'s the real file.

**All native commands go through `Invoke-Native`.** In Windows PowerShell 5.1 —
which is what `powershell.exe` under the Custom Script Extension gives you —
merging a native command's stderr with `2>&1` produces `ErrorRecord` objects, and
`$ErrorActionPreference = 'Stop'` escalates those to a *terminating* error. Plenty
of well-behaved tools write harmless notes to stderr:

| Tool | Harmless stderr output | Effect before the fix |
|---|---|---|
| `pip` | `WARNING: The scripts pip.exe … is not on PATH` | Python step aborted before installing pandas |
| `code` | `(node:…) [DEP0169] DeprecationWarning: url.parse()…` | VS Code extension step reported failure |

Exit code is the only trustworthy signal, so `Invoke-Native` relaxes the
preference around the call, logs the merged output, and judges success by exit
code (with `SuccessExitCodes` for cases like Chocolatey's `3010` = "installed,
reboot required"). Worth knowing: this does **not** reproduce under PowerShell 7,
which yields plain strings from a merged native stream — so testing with `pwsh`
will not surface it.

**Python is pinned to 3.12, and pandas/matplotlib are not optional.** Power BI
Desktop shells out to `python.exe` and hands it a DataFrame, so its Python visuals
and "Run Python script" step fail with an error rather than degrading gracefully
if those libraries are missing. The bootstrap verifies they are *importable*, not
just that the interpreter exists. 3.12 rather than latest because what matters is
prebuilt wheel availability for pandas/numpy/matplotlib.

**VS Code extensions are installed per-profile, not as SYSTEM.** A plain
`code --install-extension` from the bootstrap would put them in
`C:\Windows\System32\config\systemprofile\.vscode` — invisible to the account
that RDPs in. They are installed with an explicit `--extensions-dir` for every
real profile plus `C:\Users\Default`, so a profile created later inherits them.
Same class of bug as the file-extension registry setting below.

**Tabular Editor comes from its GitHub release, not Chocolatey.** There is no
`tabulareditor` Chocolatey package — `choco install tabulareditor` fails with
"package was not found with the source(s) listed". It ships as a portable zip, so
the bootstrap unpacks it to `C:\PL300\Tools\TabularEditor` and drops a desktop
shortcut.

**Terraform needs the VM running.** `azurerm_mssql_virtual_machine` cannot be
refreshed while the VM is deallocated — the Azure API returns
`VmNotRunning: … is not in running state` and the plan aborts before it produces
anything. Since the VM spends most of its life deallocated to save money, every
`plan`/`apply`/`destroy` has to start it first. `deploy.sh` and `destroy.sh` do
that automatically; if you run Terraform by hand, run `./scripts/start-vm.sh`
first.

**SQL memory is capped at 6 GB.** SQL Server would otherwise take almost all 16 GB
and make Power BI Desktop feel broken in front of a class.

**`sa` stays disabled.** `pl300sql` is the sysadmin login for the class.

## Requirements

Azure CLI (logged in), Terraform ≥ 1.5, Python 3, `jq`, and a subscription with
at least 4 spare vCPUs in the target region.
