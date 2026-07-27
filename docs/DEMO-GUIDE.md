# PL-300 Demo Guide

What is in this environment, what each asset demonstrates, and which part of the
PL-300 syllabus it serves.

Two independent data sets are available, and they are useful for different things:

| Data set | Where | Best for |
|---|---|---|
| **AdventureWorks** | SQL Server on the VM | Modelling, DAX, time intelligence, DirectQuery vs Import, RLS |
| **Contoso Outdoor Co** | `C:\PL300\Data` (files) | Get Data across formats, Power Query transformation, combining sources |

---

## Part 1 — The Contoso Outdoor Co file set

All 22 files describe **one fictional business in FY2024**, and they share keys
(`ProductID`, `StoreID`, `RegionID`, dates in 2024). That is deliberate: the
class can build a single model whose dimensions come from XML and Excel while its
facts come from CSV and JSON, which is a far more honest picture of real BI work
than loading one tidy CSV.

```
C:\PL300\Data\
├── CSV\
│   ├── Sales_Transactions.csv          27,653 rows - clean fact table
│   ├── Sales_Transactions_MESSY.csv    the cleanup demo
│   └── MonthlySales\  Sales_2024-01.csv ... Sales_2024-12.csv
├── Excel\
│   ├── Product_Sales_Analysis.xlsx     4 sheets, 1 named Table
│   └── Store_Master.xlsx               store + region dimensions
├── JSON\
│   ├── Orders_Nested.json              900 online orders, nested line items
│   └── Products_Api_Response.json      API envelope shape
├── XML\
│   ├── Product_Catalog.xml             hierarchical, attributes + elements
│   └── Employees.xml                   flat repeating elements
└── PDF\
    ├── Regional_Sales_Report.pdf       4 tables over 2 pages
    └── Quarterly_Summary.pdf           1 simple table
```

### The star schema hiding in the files

| Role | File | Grain |
|---|---|---|
| Fact — in-store | `CSV\MonthlySales\*.csv` | one row per order line |
| Fact — online | `JSON\Orders_Nested.json` | one row per order, line items nested |
| Dim — Product | `XML\Product_Catalog.xml` | 12 products |
| Dim — Store | `Excel\Store_Master.xlsx` → `Stores` | 8 stores |
| Dim — Region | `Excel\Store_Master.xlsx` → `Regions` | 4 regions |
| Dim — Employee | `XML\Employees.xml` | 40 employees |
| Targets | `Excel\Product_Sales_Analysis.xlsx` → `Targets` | region × quarter |

---

### Demo 1 — CSV, and why "Get Data" is the easy part
**Module: Get data in Power BI**

Load `CSV\Sales_Transactions.csv`. It is clean, 27k rows, and takes one click.
Use it to establish the baseline before showing what real extracts look like.

Point out in the preview dialog: delimiter detection, data type detection from
the first 200 rows, and the **File origin / encoding** dropdown that everyone
ignores until it breaks.

### Demo 2 — The messy CSV
**Module: Clean, transform, and load data in Power BI**

`CSV\Sales_Transactions_MESSY.csv` is built to require, in this order:

| Problem in the file | Transformation |
|---|---|
| 3 junk lines before the header | **Remove Rows → Remove Top Rows → 3** |
| Real header now in row 1 | **Use First Row as Headers** |
| Dates as `2024-01-01`, `01/01/2024`, `01-Jan-2024` | **Change Type → Using Locale → English (United States)** |
| `$1,234.56` currency text | **Replace Values** `$` → nothing, then Change Type |
| ` Store 1  ` padded text | **Transform → Format → Trim** |
| `West` / `WEST` / `west` / `  West ` | **Trim** then **Format → Capitalize Each Word** |
| `N/A`, `NULL`, empty strings | **Replace Values → null** |
| Header row repeated mid-file | **Filter** `Txn ID` ≠ `"Txn ID"` |
| 4 exact duplicate rows | **Remove Rows → Remove Duplicates** |
| Blank rows | **Remove Rows → Remove Blank Rows** |
| `GRAND TOTAL` and a footer line | **Remove Rows → Remove Bottom Rows → 2** |

This is the single most valuable demo in the file set — it is essentially the
whole "Clean, transform and load" module in one file. Work top-down through the
Applied Steps pane and the shape of Power Query becomes obvious.

Good teaching moment at the end: click **Advanced Editor** and show that the
clicking produced readable M.

### Demo 3 — Combine files from a folder
**Module: Get data in Power BI**

**Get Data → Folder** → `C:\PL300\Data\CSV\MonthlySales` → **Combine & Load**.

Twelve identical-schema files become one table, and Power Query generates the
sample-file helper queries. Show the `Source.Name` column it adds, then:

```m
// Extract the month from the file name - the pattern behind incremental loads
Table.AddColumn(#"Removed Other Columns", "SourceMonth",
    each Text.BetweenDelimiters([Source.Name], "Sales_", ".csv"), type text)
```

Then drop a 13th file in the folder and refresh, to make the point that the query
is a pipeline, not an import.

### Demo 4 — Excel: Tables vs Sheets, and Unpivot
**Module: Clean, transform, and load data in Power BI**

`Excel\Product_Sales_Analysis.xlsx` has four sheets. The Navigator shows
`SalesData` twice — once as a **Table** (blue grid icon) and once as a **Sheet**.
Explain why you always take the Table: sheets pick up stray cells and formatting
rows, tables have a defined range.

Then open the **`CrossTab`** sheet, which is a report, not data:

```
Row 1-3:  title block
Row 4:    blank
Row 5:    Region | January | February | ... | December
Row 6-9:  North / South / East / West
```

The fix, and the canonical unpivot demo:

1. **Remove Top Rows → 4**
2. **Use First Row as Headers**
3. Select the `Region` column → **Unpivot Other Columns**
4. Rename `Attribute` → `Month`, `Value` → `Revenue`

48 rows of proper tabular data out of a 4×12 matrix. Contrast it with what a
`Region`/`January`…`December` model would force you to write in DAX.

### Demo 5 — JSON and nested structures
**Module: Get data in Power BI**

**`Orders_Nested.json`** — a list of 900 orders, each with a nested `customer`
record, a `shipTo` record, and a `lineItems` **list of records**:

1. **Get Data → JSON** → returns a list → **To Table**
2. Expand the record column — choose columns rather than taking all of them
3. `lineItems` is a `List`. **Expand → Expand to New Rows** (900 orders fan out to 1,907 rows)
4. Now it is a record column → expand again to reach `productId`, `quantity`, `lineTotal`

The two-step "expand to rows, then expand the record" is the bit that trips
people up, so do it slowly.

Also: `customer.email` is null for 118 of the 900 orders (13%) — a natural
lead-in to null handling and to why `COUNT` and `COUNTA` disagree.

**`Products_Api_Response.json`** — the shape a REST API actually returns:

```
{ apiVersion, endpoint, generatedAt, pagination: {...}, data: [ ... ], regions: [ ... ] }
```

Get Data returns a single **record**, not a table. Drill into `data` → **To
Table** → expand. Then show `pagination.hasMore` and discuss why paged APIs need
a function plus `List.Generate` rather than one query.

### Demo 6 — XML
**Module: Get data in Power BI**

**`Product_Catalog.xml`** is `Catalog → Category → Product`, and mixes attributes
(`id`, `sku`, `name`) with child elements (`Name`, `ListPrice`, `Specifications`).

Loading it gives nested tables. Expand `Category` → `Product`, and show that
attributes arrive as ordinary columns alongside elements. `Specifications` is a
third level down — expand it to make the point that XML depth becomes expand
steps.

**`Employees.xml`** is flat repeating elements and loads almost directly — the
useful contrast.

### Demo 7 — PDF
**Module: Get data in Power BI**

**`Regional_Sales_Report.pdf`** — **Get Data → PDF**. The Navigator lists four
detected tables plus per-page entries:

| Table | Contents |
|---|---|
| Table 1 | Net revenue by region × quarter, with targets and variance |
| Table 2 | Store performance detail |
| Table 3 | Product performance |
| Table 4 | Online channel by loyalty tier |

Worth saying out loud: the connector infers tables from text layout, so it works
well on ruled tables like these and badly on scanned or free-form documents. Show
that headers still need promoting and numbers still arrive as text with thousands
separators.

**`Quarterly_Summary.pdf`** is one clean 12-row table if you want the demo
without the noise.

### Demo 8 — Reconciliation exercise
**Modules: Clean/transform/load + Model data**

A genuinely useful classroom exercise, because it mirrors the first thing anyone
asks about a new report:

> Table 1 of `Regional_Sales_Report.pdf` reports FY2024 net revenue by region.
> Load the 12 monthly CSVs, relate them to `Store_Master.xlsx`, aggregate by
> region, and prove your numbers match the PDF.

They do match — the PDF is generated from the same source data. Getting there
requires a folder combine, an Excel dimension, a relationship, and a measure,
which is most of the "Prepare" and "Model" objectives in one task.

### Demo 9 — Cloud data source
**Module: Get data in Power BI**

The same files are in Azure Blob Storage:

```bash
terraform -chdir=terraform output -raw demo_data_container_url
terraform -chdir=terraform output -raw storage_account_key
```

**Get Data → Azure → Azure Blob Storage** → paste the container URL →
authenticate with **Account key**. Use it to discuss cloud vs local file paths,
gateway requirements after publishing, and why `C:\PL300\Data` would break a
scheduled refresh in the service.

---

## Part 2 — AdventureWorks on SQL Server

Connect Power BI Desktop with **Get Data → SQL Server**, server `localhost`.

- **`AdventureWorksDW2022`** — pre-built star schema, and what the official
  PL-300 labs use. Go here for modelling and DAX.
- **`AdventureWorks2022`** — normalized OLTP. Go here to show why you reshape.

Verified contents of this instance:

| | |
|---|---|
| `FactInternetSales` | **60,398 rows**, `OrderDate` spanning **2010-12-29 to 2014-01-28** |
| `AdventureWorks2022` | 71 tables in the OLTP schema |

That date range matters for the DAX below: the data covers **three complete
years (2011, 2012, 2013)** plus a few days either side. Year-over-year measures
are therefore blank for 2011 and misleading for 2014 — which is a useful thing to
show deliberately rather than discover live. Slice to 2012–2013 for clean YoY
demos.

```sql
SELECT MIN(OrderDate) AS FirstOrder, MAX(OrderDate) AS LastOrder, COUNT(*) AS [Rows]
FROM dbo.FactInternetSales;
```

### Demo 10 — Import vs DirectQuery
**Modules: Get data / Optimize a model for performance**

Build the same simple report twice against `FactInternetSales` — once Import,
once DirectQuery. Then show what changes:

- DirectQuery greys out many DAX functions and disables Power Query steps that
  cannot fold
- **View → Performance Analyzer** exposes the generated SQL for DirectQuery
- Run SQL Profiler or an Extended Events session in SSMS to watch queries arrive
  per visual interaction

This is much more convincing on a real SQL Server than described on a slide,
which is the main reason this environment exists.

### Demo 11 — Query folding
**Module: Clean, transform, and load data in Power BI**

Import `FactInternetSales`, add a filter and a removed column, then right-click
the last Applied Step → **View Native Query**. It is available, because the steps
folded.

Now insert a step that cannot fold — a custom column using
`Text.Proper([SomeText])`, or `Table.Buffer` — and show **View Native Query** go
grey. That single greyed-out menu item is the clearest explanation of folding
anyone will get.

### Demo 12 — Star schema and relationships
**Module: Design a semantic model in Power BI**

Load `FactInternetSales`, `DimCustomer`, `DimProduct`, `DimDate`,
`DimSalesTerritory`. Discuss:

- Why `DimDate` must be marked as a date table (**Table tools → Mark as date table**)
- `OrderDateKey` → `DateKey` as an integer relationship, and the surrogate-key idea
- Single vs bidirectional filter direction, and why bidirectional is a last resort
- Hiding key columns from Report view so field lists stay usable

Then contrast with `AdventureWorks2022`: `Sales.SalesOrderHeader` +
`Sales.SalesOrderDetail` + `Production.Product` + `Production.ProductSubcategory`
+ `Production.ProductCategory` — five tables and three joins to answer "sales by
category", which is exactly why the DW exists.

### Demo 13 — Measures and time intelligence
**Modules: Add measures / Use DAX time intelligence functions**

```dax
Total Sales = SUM ( FactInternetSales[SalesAmount] )

Order Count = DISTINCTCOUNT ( FactInternetSales[SalesOrderNumber] )

Sales YTD = TOTALYTD ( [Total Sales], DimDate[FullDateAlternateKey] )

Sales LY =
CALCULATE ( [Total Sales], SAMEPERIODLASTYEAR ( DimDate[FullDateAlternateKey] ) )

YoY Growth % =
VAR Current = [Total Sales]
VAR Prior   = [Sales LY]
RETURN DIVIDE ( Current - Prior, Prior )

Sales Rolling 3M =
CALCULATE (
    [Total Sales],
    DATESINPERIOD ( DimDate[FullDateAlternateKey], MAX ( DimDate[FullDateAlternateKey] ), -3, MONTH )
)
```

`Sales LY` is the one to dwell on: it silently returns blank if the date table is
not marked as a date table or does not cover contiguous full years. Break it on
purpose, then fix it.

Then the calculated-column-vs-measure conversation:

```dax
// Calculated column - materialized per row, costs model memory
FactInternetSales[Line Margin] =
    FactInternetSales[SalesAmount] - FactInternetSales[TotalProductCost]

// Measure - evaluated at query time, costs nothing to store
Total Margin =
    SUMX ( FactInternetSales,
           FactInternetSales[SalesAmount] - FactInternetSales[TotalProductCost] )
```

### Demo 14 — CALCULATE and filter context
**Module: Add measures to Power BI Desktop models**

```dax
Sales All Products =
CALCULATE ( [Total Sales], REMOVEFILTERS ( DimProduct ) )

Product Share % =
DIVIDE ( [Total Sales], [Sales All Products] )

Sales Bikes Only =
CALCULATE ( [Total Sales], KEEPFILTERS ( DimProduct[EnglishProductCategoryName] = "Bikes" ) )
```

Put `Product Share %` in a matrix by category and subcategory and let the class
watch the denominator stay fixed while the numerator changes. `KEEPFILTERS` vs
plain filter arguments is worth the extra five minutes.

### Demo 15 — Row-level security
**Module: Implement row-level security**

**Modeling → Manage roles**, on `DimSalesTerritory`:

```dax
[SalesTerritoryGroup] = "North America"
```

Then **View as → Role** to test. Follow with the dynamic version, which is what
anyone will actually deploy:

```dax
[EmailAddress] = USERPRINCIPALNAME()
```

Explain that `USERPRINCIPALNAME()` returns your desktop identity locally but the
signed-in user's UPN in the service — and that RLS is bypassed for workspace
Admin/Member/Contributor roles, which surprises people in production.

### Demo 16 — Python in Power BI
**Modules: Get data / Clean, transform and load / Perform analytics**

Python 3.12 is installed machine-wide with `pandas`, `matplotlib`, `numpy`,
`seaborn`, `openpyxl` and `ipykernel`. Power BI needs pandas and matplotlib
present or these features error instead of rendering, which is worth stating
plainly — it is the most common reason "Python doesn't work in Power BI".

First: **File → Options and settings → Options → Python scripting** and confirm
the detected home directory. Then the three integration points:

**1. As a data source** — Get Data → Other → **Python script**:

```python
import pandas as pd
df = pd.read_csv(r"C:\PL300\Data\CSV\Sales_Transactions.csv")
summary = df.groupby("ProductID", as_index=False)["SalesAmount"].sum()
```

Every DataFrame in scope shows up in the Navigator as a table. Useful for showing
that "Get Data" is extensible, and for pulling in a source Power Query has no
connector for.

**2. As a transformation step** — Transform Data → Transform → **Run Python
script**. The current table arrives as `dataset`; return a DataFrame:

```python
# dataset holds the current query result
dataset["Margin"] = dataset["SalesAmount"] - dataset["TotalCost"]
dataset["MarginPct"] = dataset["Margin"] / dataset["SalesAmount"]
```

Good moment to note this **breaks query folding** and requires a personal gateway
after publishing — it ties straight back to Demo 11.

**3. As a visual** — the Python visual on the canvas. Drag fields in, and they
arrive as `dataset`. Must end with `plt.show()`:

```python
import matplotlib.pyplot as plt
agg = dataset.groupby("Category")["SalesAmount"].sum().sort_values()
agg.plot(kind="barh", color="#1F4E79")
plt.xlabel("Sales Amount")
plt.tight_layout()
plt.show()
```

Worth being honest with the class about the trade-offs: Python visuals are static
images, do not cross-filter other visuals, cap at 150,000 rows, and need a gateway
in the service. They earn their place for statistical plots the built-in visuals
cannot do — not for bar charts.

VS Code is installed with the Python, Jupyter, SQL Server and Power Query (M)
extensions, which makes it a better place to draft M and Python before pasting
into Power BI than the Advanced Editor.

### Demo 17 — Optimization
**Module: Optimize a model for performance**

- **Performance Analyzer** — record, interact, read DAX query durations
- **DAX Studio** (installed) — Server Timings to split formula engine vs storage
  engine, and VertiPaq Analyzer to find the columns eating your model
- **Tabular Editor** (installed) — Best Practice Analyzer over the model

High-cardinality columns are the concrete lesson here. In
`FactInternetSales`, remove `SalesOrderNumber` or the raw datetime columns and
watch model size drop; a datetime column with a time component is usually the
single worst offender in a real model.

---

## Suggested class sequence

| Day | Focus | Assets |
|---|---|---|
| 1 | Get data across formats | Demos 1, 3, 4, 5, 6, 7 |
| 1 | Clean and transform | Demo 2 (the messy CSV), Demo 11 |
| 2 | Model design | Demos 12, 8 (reconciliation) |
| 2 | DAX | Demos 13, 14 |
| 3 | Visualize and analyze | AdventureWorksDW model built on day 2 |
| 3 | Analytics extensibility | Demo 16 (Python) — optional, if the class has the appetite |
| 3 | Manage and secure | Demos 15, 17, Demo 9 (gateway discussion) |

## What this environment does *not* provide

Power BI **Service** — workspaces, publishing, dashboards, apps, deployment
pipelines and scheduled refresh — needs a Power BI / Microsoft Fabric licence in
your tenant. That is separate from this Azure subscription and cannot be
provisioned by Terraform. Power BI Desktop here does everything up to the point
of **Publish**.

For the "Manage and secure Power BI" objectives (15–20% of the exam) you will
need a Fabric trial or a Pro licence on `ciracon.com`. Everything else in the
syllabus is fully covered by this VM offline.
