# Connecting to the PL-300 Demo Environment

## 1. Get your connection details

From the repo root:

```bash
# Everything except the passwords
terraform -chdir=terraform output -raw connection_summary

# The passwords (same value for RDP and SQL)
terraform -chdir=terraform output -raw admin_password
```

| Item | Value |
|---|---|
| RDP host | `terraform -chdir=terraform output -raw fqdn` |
| Port | 3389 |
| Username | `pl300admin` |
| Password | `terraform -chdir=terraform output -raw admin_password` |

Use the **FQDN**, not the IP. The IP is static today, but the DNS name is what
survives any future rebuild.

## 2. Start the VM

The VM auto-shuts-down nightly, so it is probably deallocated:

```bash
./scripts/start-vm.sh
```

Windows needs another 1–2 minutes after Azure reports "running" before it
accepts RDP.

## 3. Remote Desktop

**Windows** — press `Win+R`, run `mstsc`, paste the FQDN.

**macOS** — install [Windows App](https://apps.apple.com/app/id1295203466)
(formerly Microsoft Remote Desktop), add a PC, paste the FQDN.

**Linux** — `xfreerdp` gives the best experience for a class demo:

```bash
FQDN=$(terraform -chdir=terraform output -raw fqdn)
PASS=$(terraform -chdir=terraform output -raw admin_password)
xfreerdp /v:"$FQDN" /u:pl300admin /p:"$PASS" /dynamic-resolution /clipboard +fonts
```

For projecting to a class, force a resolution the projector can handle rather
than using `/dynamic-resolution`:

```bash
xfreerdp /v:"$FQDN" /u:pl300admin /p:"$PASS" /size:1920x1080 /smart-sizing /clipboard
```

## 4. What is on the desktop

- **PL-300 Demo Data** — shortcut to `C:\PL300\Data`
- **PL-300 Demo Guide** — what each demo file teaches
- Power BI Desktop, SSMS, DAX Studio and Tabular Editor are in the Start menu

## 5. SQL Server

### From inside the VM

Use the **SQL Server Management Studio** shortcut on the desktop and connect to:

| | |
|---|---|
| Server name | `localhost` |
| Authentication | Windows Authentication |

> Two SSMS versions are on the box: **22.x** (installed by the bootstrap, under
> `C:\Program Files\...Management Studio 22`) and **20.2** which ships
> pre-installed on the Azure SQL marketplace image. Both appear in the Start
> menu. The desktop shortcut points at 22 — use that one for consistency,
> especially if you are screen-sharing.

Windows auth works for the RDP account, which the Azure image makes a sysadmin.
In Power BI Desktop, **Get Data → SQL Server**, server `localhost`, database
`AdventureWorksDW2022`.

If you ever need SQL authentication on the VM itself, the `pl300sql` login below
works there too.

### From your own laptop

SQL 1433 is open to your IP as well, so you can point local tools at the VM:

| | |
|---|---|
| Server name | `<fqdn>,1433` |
| Authentication | SQL Server Authentication |
| Login | `pl300sql` |
| Password | same as the RDP password |

```bash
terraform -chdir=terraform output -raw sql_server_remote   # host,port
terraform -chdir=terraform output -raw sql_admin_login
```

The built-in `sa` account is deliberately disabled; `pl300sql` is the sysadmin
login for the class.

### Databases

- **`AdventureWorksDW2022`** — the star schema. This is the one the official
  PL-300 labs use. Start with `FactInternetSales`, `DimCustomer`, `DimProduct`,
  `DimDate`.
- **`AdventureWorks2022`** — the normalized OLTP schema, useful for showing why
  you reshape data before modelling it (`Sales.SalesOrderHeader`,
  `Sales.SalesOrderDetail`, `Production.Product`).

## 6. Demo files as an Azure Blob data source

The same demo files also live in blob storage, which makes a good "connect to
cloud data" demo without leaving the environment:

```bash
terraform -chdir=terraform output -raw demo_data_container_url
terraform -chdir=terraform output -raw storage_account_key
```

In Power BI Desktop: **Get Data → Azure → Azure Blob Storage**, paste the
container URL, and authenticate with the **Account key**.

## 7. The ready-made Power BI solutions

There are two, both in `powerbi/`. Copy that folder to the VM (or open it from a
synced location) and open the `.pbip` you want in Power BI Desktop.

**`PL300-Demos.pbip`** — six pages covering Python, R, SQL Server `geography`
visuals and a CALCULATE filter-context walkthrough, with every table baked in as an
inline literal so it opens with no prompts at all. This is the one to hand out.

- Accept the **Enable script visuals** prompt on first open. Escape *cancels* it,
  which leaves the R and Python visuals blank with no error shown.
- Pages 2-4 need a one-time paste of the matching file from `powerbi/scripts/`.
- Page 6 needs nothing — the measures are in the model. `powerbi/scripts/`
  `calculate-filter-context.dax` holds the same ladder plus four variants to add
  live, each with its expected answer.

**`PL300-Spatial-SQL.pbip`** — five pages reading the `geography` views live from
`localhost/PL300Demo` over DirectQuery, so the spatial results are computed by SQL
Server on every interaction. Status bar reads **Mixed** (six DirectQuery tables plus
one Import). It only works on the VM, and it prompts for SQL credentials the first
time — Windows authentication as the RDP account is enough.

[`../powerbi/README.md`](../powerbi/README.md) covers both, including the expected
figures for every page so a wrong render is obvious.

## 8. Screen capture from outside the VM

`./scripts/snapshot-report.sh <page> <wait> <name>.png` opens the solution on the VM
and brings back a screenshot. It needs an interactive session, because a capture from
`az vm run-command` (which runs as SYSTEM in session 0) has no desktop and comes back
black.

The session was moved to the VM's console with `tscon` so capture keeps working with
no RDP client attached:

```powershell
tscon 2 /dest:console
```

Reconnecting over RDP is fine and takes the session back; if you do, re-run `tscon`
before relying on unattended screenshots again. A capture that fails with
"The handle is invalid" or returns an all-white image means the session is locked or
disconnected.

## 9. When you are done

```bash
./scripts/stop-vm.sh
```

Deallocating is what stops compute billing. Simply signing out of RDP does not.

---

## Troubleshooting

**RDP times out.** Your public IP almost certainly changed — that is the single
most common cause, and it happens on any hotel wifi, tethered connection, or ISP
lease renewal:

```bash
./scripts/update-my-ip.sh
```

**RDP still times out.** Confirm the VM is actually running:

```bash
az vm get-instance-view -g pbi-rg -n pl300-demo-vm \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].code" -o tsv
```

**Power BI Desktop or a database is missing.** Check what the bootstrap actually
did, then repair in place:

```bash
./scripts/verify.sh
./scripts/rerun-bootstrap.sh   # idempotent
```

**Read the bootstrap log directly.** On the VM: `C:\PL300\Logs\bootstrap.log`
and `C:\PL300\Logs\status.json`. Or remotely:

```bash
az vm run-command invoke -g pbi-rg -n pl300-demo-vm \
  --command-id RunPowerShellScript \
  --scripts 'Get-Content C:\PL300\Logs\bootstrap.log -Tail 80' \
  --query 'value[0].message' -o tsv
```

**`terraform plan` fails with `VmNotRunning`.** Expected when the VM is
deallocated — the SQL VM resource cannot be read while it is stopped. Start it
first:

```bash
./scripts/start-vm.sh
```

**Power BI Desktop wants a sign-in.** Reports and models work fully offline. You
only need an account to publish to the Power BI service — that is a Fabric/Power
BI licence, separate from this Azure subscription, and not something this
environment provisions.

**SQL connection from the laptop fails but works on the VM.** Check the NSG rule
covers your current IP (`./scripts/update-my-ip.sh`), and that you are using SQL
authentication with `pl300sql` — Windows auth will not work across the internet.
