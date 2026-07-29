# PL-300 Demo Guide

What is in this environment, what each asset demonstrates, and which part of the
PL-300 syllabus it serves.

Two independent data sets are available, and they are useful for different things:

| Data set | Where | Best for |
|---|---|---|
| **AdventureWorks** | SQL Server on the VM | Modelling, DAX, time intelligence, DirectQuery vs Import, RLS |
| **Contoso Outdoor Co** | `C:\PL300\Data` (files) | Get Data across formats, Power Query transformation, combining sources |
| **PL300-Demos.pbip** | `powerbi/` in this repo | A ready-made report: Python, R and SQL `geography` visuals. See [`../powerbi/README.md`](../powerbi/README.md) |

> The Power BI solution is a finished exhibit rather than something to build live.
> Open it when you want to *show* a working Python/R/spatial visual quickly; use the
> demos below when you want the class to build one. Pages 2-4 need a one-time paste
> of the matching file from `powerbi/scripts/` - `powerbi/README.md` explains why.

---

## Part 1 — The Contoso Outdoor Co file set

All 27 files describe **one fictional business in FY2024**, and they share keys
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
├── PDF\
│   ├── Regional_Sales_Report.pdf       4 tables over 2 pages
│   └── Quarterly_Summary.pdf           1 simple table
└── Spatial\
    ├── Store_Locations.csv             lat/long + WKT for map visuals
    ├── Store_Locations.geojson         point features
    ├── Customer_Locations.csv          480 customers with coordinates
    ├── Contoso_Regions.geojson         4 region polygons
    └── Contoso_Regions.topojson        for the Shape Map visual
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

### Demo 12a — DAX from zero, on the Reseller Sales model
**Module: Add measures to Power BI Desktop models**

This is the ladder to walk up on the **Reseller Sales** star schema — the one the
official labs build:

```
Reseller Sales  *→1  Product  *→1  Product Subcategory  *→1  Product Category
Reseller Sales  *→1  Date
```

| Table | Fields in the model |
|---|---|
| Reseller Sales | `OrderDateKey`, `OrderQuantity`, `ProductKey`, `UnitPrice` |
| Product | `Color`, `Product Name`, `ProductKey`, `ProductSubcategoryKey` |
| Product Subcategory | `Subcategory`, + both keys |
| Product Category | `Category`, `ProductCategoryKey` |
| Date | `DateKey`, `Day` (a real date), `Month`, `Year`, `Calendar` hierarchy |

Everything below uses only those fields. Each measure has its expected answer, so
a wrong number is obvious on the projector.

**1. The simplest measure there is.**

```dax
Total Quantity = SUM ( 'Reseller Sales'[OrderQuantity] )
```

`SUM` takes one column and adds it up. **214,378.** Start here so the class sees a
measure is just a named calculation, nothing more.

**2. Counting rows instead of adding a column.**

```dax
Order Lines = COUNTROWS ( 'Reseller Sales' )
```

**60,855.** Note it takes a *table*, not a column. This model has no order-number
column, so `Order Lines` counts lines, not orders — say so out loud, because
"count of sales" meaning two different things is a real source of wrong reports.

**3. The measure that teaches row context.**

```dax
Revenue = SUMX ( 'Reseller Sales', 'Reseller Sales'[OrderQuantity] * 'Reseller Sales'[UnitPrice] )
```

**$80,978,105.** This model deliberately has no `SalesAmount` column, so revenue
has to be computed. Try `SUM ( [OrderQuantity] * [UnitPrice] )` first and let it
fail — `SUM` wants a column and you handed it an expression. `SUMX` walks the
table row by row, multiplies, then adds the results.

This is the single most important idea in the module: **X-functions iterate.**
Multiplying the two totals ($444.43 avg price × 214,378) would be wildly wrong.

**4. Averages that lie.**

```dax
Average Unit Price = AVERAGE ( 'Reseller Sales'[UnitPrice] )   -- $444.43
Revenue per Unit   = DIVIDE ( [Revenue], [Total Quantity] )    -- $377.74
```

Both are "the average price" in English, and they differ by 18%. `AVERAGE` treats
a line selling 1 item and a line selling 40 as equal; `DIVIDE` weights by volume.
Ask the class which one the sales director meant. Also worth noting: `DIVIDE`
returns blank on divide-by-zero where `/` throws an error.

**5. Measure vs calculated column.**

```dax
-- Calculated column, on Reseller Sales. Computed at refresh, stored in the model.
Line Revenue = 'Reseller Sales'[OrderQuantity] * 'Reseller Sales'[UnitPrice]

-- Then this gives the identical $80,978,105:
Revenue via Column = SUM ( 'Reseller Sales'[Line Revenue] )
```

Same answer, different cost. The column adds 60,855 stored values to the model
and cannot react to slicers; the measure computes at query time and costs nothing
to store. Rule of thumb: **columns when you need to slice or filter by it,
measures when you need to aggregate it.**

**6. The relationships do the work.**

Drop `Category` on rows with `[Revenue]` — no new DAX at all:

| Category | Revenue |
|---|---|
| Bikes | $66,797,022 |
| Components | $11,804,291 |
| Clothing | $1,798,805 |
| Accessories | $577,986 |

The filter travels `Product Category → Product Subcategory → Product → Reseller
Sales`, three hops up the snowflake. Delete one relationship and watch every row
collapse to the same $80.9M total — the fastest way to make filter propagation
concrete.

**7. Changing the filter, with CALCULATE.**

```dax
Bikes Revenue = CALCULATE ( [Revenue], 'Product Category'[Category] = "Bikes" )
```

**$66,797,022**, and it stays $66.8M even in the Clothing row. `CALCULATE` is the
only function that modifies filter context — its filter argument *replaces* the
one coming from the visual.

**8. Percent of total — and a snowflake trap.**

```dax
All Category Revenue = CALCULATE ( [Revenue], REMOVEFILTERS ( 'Product Category' ) )
Category Share %     = DIVIDE ( [Revenue], [All Category Revenue] )
```

Bikes = 82.5%. Now switch the visual to `Subcategory` and the percentages break —
they all read 100%. `REMOVEFILTERS` cleared `Product Category` but the visual is
now filtering `Product Subcategory`, a different table. Fix it by clearing the
whole branch:

```dax
All Product Revenue =
CALCULATE ( [Revenue], REMOVEFILTERS ( 'Product Category', 'Product Subcategory', Product ) )
```

Road Bikes then reads 36.3% of $80.9M. This trap is specific to snowflakes and
catches people constantly — it is the best argument in the course for flattening
the product tables into one dimension.

**9. Time intelligence.**

First **Table tools → Mark as date table** on `Date`, using `Day`. Time
intelligence silently returns blank without it, which is the failure to
demonstrate on purpose.

```dax
Revenue YTD = TOTALYTD ( [Revenue], 'Date'[Day] )

Revenue LY  = CALCULATE ( [Revenue], SAMEPERIODLASTYEAR ( 'Date'[Day] ) )

YoY %       = DIVIDE ( [Revenue] - [Revenue LY], [Revenue LY] )
```

By year: 2010 $489,329 · 2011 $18,351,294 · 2012 $28,297,496 · 2013 $33,839,986.

**Read those dates before trusting the growth numbers.** The data runs
2010-12-29 to 2013-11-29, so 2010 is three days and 2013 stops in November. YoY
for 2011 comes out at roughly +3,650% against a three-day "year", and 2013 looks
weak only because December is missing. Partial years wrecking a time-intelligence
comparison is worth more class time than the syntax is.

**10. Two field-list gotchas in this model.**

`Year` carries a Σ — it is a whole number, so dropping it into a visual *adds the
years together* instead of listing them. Set **Summarization → Don't summarize**
(or use the `Calendar` hierarchy). And `Month` is text with no
month-number column, so it sorts April, August, December. Add one and use **Sort
by column**:

```dax
Month Number = MONTH ( 'Date'[Day] )      -- calculated column on Date
```

Then select `Month` → **Column tools → Sort by column → Month Number**. Chronological
sorting is a guaranteed exam topic and a guaranteed real-world bug.

**Stretch, if the room is quick.** 209 products have no subcategory, so a matrix
by `Category` shows a blank row that does not tie to the $80.9M total —
`ISBLANK` and referential-integrity handling fall straight out of it.

### Demo 13 — Measures and time intelligence
**Modules: Add measures / Use DAX time intelligence functions**

> Demo 12a is the gentle on-ramp on the **Reseller Sales** model. This demo is on
> **Internet Sales** with raw `Fact…`/`Dim…` names, and it moves faster. Pick one
> model for the DAX block and stay in it — switching mid-session means every field
> name changes and the class loses the thread.

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

A finished, runnable version of this is **page 6 of `powerbi/PL300-Demos.pbip`**,
already on the VM at `C:\PL300\Solution\powerbi`. Every number below is exact, so
a wrong render is obvious from the back of the room. The paste source, including
four variants that are not in the model, is
`powerbi/scripts/calculate-filter-context.dax`.

It is all built on one table, `CategoryMonthlySales` (Category, MonthNumber,
MonthName, SalesAmount — 48 rows). That is deliberate: it holds both dimensions
the lesson needs plus the amount, so filter context can be changed without a
single relationship in the picture. Relationships and filter propagation are the
*next* lesson, and running them together is what makes CALCULATE feel like magic.

**1. Start with no CALCULATE at all.**

```dax
Sales = SUM ( CategoryMonthlySales[SalesAmount] )
```

Put `Category` on a table with this beside it. **$6,637,231** at the total,
Camping $3,302,900, Apparel $1,580,293, Hiking $1,220,450, Cooking $533,589. Say
out loud what is happening: the visual puts a filter on each row, and the measure
answers *that* filter. Nothing else is going on yet.

**2. The simplest CALCULATE there is.**

```dax
Sales Camping = CALCULATE ( [Sales], CategoryMonthlySales[Category] = "Camping" )
```

Add it as a second column and stop. **All four rows read $3,302,900.** This is
the moment the demo exists for — let the room react before explaining. A filter
argument on a column that the visual has *already* filtered **replaces** that
filter; it does not narrow it.

**3. The correction, immediately.**

```dax
Sales Camping Kept =
CALCULATE ( [Sales], KEEPFILTERS ( CategoryMonthlySales[Category] = "Camping" ) )
```

Same filter, wrapped. Now only the Camping row shows $3,302,900 and the other
three go **blank**, because `KEEPFILTERS` intersects with the row's filter instead
of replacing it. Side by side, columns 2 and 3 teach the whole idea. "CALCULATE
overrides the filter context" is a half-truth, and this is where to correct it.

**4. Filters can be taken away, not just added.**

```dax
Sales All Categories =
CALCULATE ( [Sales], REMOVEFILTERS ( CategoryMonthlySales[Category] ) )
```

Every row now shows the **$6,637,231** grand total — the row's own Category filter
is gone.

**5. Why step 4 was worth learning.**

```dax
Category Share % = DIVIDE ( [Sales], [Sales All Categories] )
```

A numerator that moves per row over a denominator that does not: Camping 49.8%,
Apparel 23.8%, Hiking 18.4%, Cooking 8.0%, adding to **100.0%**.

**6. The same measure, a different question.**

Build a second table with `MonthName` on rows and put `[Sales Camping]` — the
*unchanged* measure from step 2 — next to `[Sales]`. It no longer shows one
repeated number; it shows Camping's own months (January $149,950 … December
$313,079, total $3,302,900). Category is not on rows here, so there is no Category
filter to replace and the filter simply applies. The behaviour was never a
property of the measure; it was a property of what the visual had already filtered.

**7. Variants, if the room is quick.** Each is in the `.dax` file with its answer.

```dax
Sales Q4 = CALCULATE ( [Sales], CategoryMonthlySales[MonthNumber] >= 10 )

Sales Camping H2 =
CALCULATE ( [Sales], CategoryMonthlySales[Category] = "Camping",
                     CategoryMonthlySales[MonthNumber] >= 7 )

Sales Everything = CALCULATE ( [Sales], REMOVEFILTERS ( CategoryMonthlySales ) )

Sales Visible Categories =
CALCULATE ( [Sales], ALLSELECTED ( CategoryMonthlySales[Category] ) )
```

$1,566,730 · $1,737,262 · always $6,637,231 · and `ALLSELECTED` is the one that
needs a slicer to show its point — it clears the filter the *visual* applied but
respects the one the *user* applied, so pick two categories and watch a share
denominator follow the selection instead of staying at the grand total.

**On the AdventureWorks model instead.** If the class built the Internet Sales
model in Demo 12, the same ladder reads:

```dax
Sales All Products =
CALCULATE ( [Total Sales], REMOVEFILTERS ( DimProduct ) )

Product Share % =
DIVIDE ( [Total Sales], [Sales All Products] )

Sales Bikes Only =
CALCULATE ( [Total Sales], KEEPFILTERS ( DimProduct[EnglishProductCategoryName] = "Bikes" ) )
```

Those figures have not been verified against the database, unlike the ones above.
Note also that `REMOVEFILTERS ( DimProduct )` crosses a relationship — it clears a
filter on the dimension and lets that flow through to the fact — which is a second
idea on top of the first. That is exactly why the single-table version is the one
to open with.

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

A finished example of this is page 2 of `powerbi/PL300-Demos.pbip`.

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

### Demo 17 — Spatial data and map visuals
**Modules: Get data / Design a semantic model / Create reports**

Two sources are available, and the contrast between them *is* the lesson. Page 5 of
`powerbi/PL300-Demos.pbip` is a worked example - Azure Maps, a longitude/latitude
scatter, and a table showing the raw `POINT (...)` well-known text.

#### Files — `C:\PL300\Data\Spatial`

| File | Use |
|---|---|
| `Store_Locations.csv` | 8 stores with `Latitude`, `Longitude`, `WKT`, `CityState` |
| `Customer_Locations.csv` | 480 customers with coordinates |
| `Store_Locations.geojson` | Point features — Azure Maps, or Power Query JSON parsing |
| `Contoso_Regions.geojson` | 4 region polygons |
| `Contoso_Regions.topojson` | Same polygons for the **Shape Map** visual |

Start with the CSV and the built-in **Map** visual. Two ways to feed it, worth
doing both:

1. **Latitude / Longitude fields** — exact, no ambiguity, no internet geocoding.
2. **`CityState` in the Location bucket** — Power BI geocodes the text via Bing.
   Then set **Column tools → Data category** to `City`/`State or Province` and
   show how it changes the result. This is where you explain why "Springfield"
   plots in the wrong state and why data categories matter.

Then **Filled Map** using `State`, and **Shape Map** with
`Contoso_Regions.topojson` (**Format → Shape → Add map**).

> Shape Map is still a preview feature. If you don't see it, enable it under
> **File → Options → Preview features → Shape map visual** and restart. Check
> this before class — a missing visual is an awkward thing to discover live.

#### SQL Server — the `PL300Demo` database

This is where the actual `geography` **data type** lives. Connect to `localhost`,
database `PL300Demo`.

| Object | Demonstrates |
|---|---|
| `dbo.StoreLocation` | `geography` points, built with `geography::Point()` |
| `dbo.RegionBoundary` | `geography` polygons from WKT |
| `dbo.CustomerLocation` | 480 points + a **spatial index** |
| `dbo.vw_StoreLocations` | `.Lat` / `.Long` / `.STAsText()` projected for Power BI |
| `dbo.vw_CustomerNearestStore` | `STDistance` + `CROSS APPLY` nearest-neighbour |
| `dbo.vw_StoreRegionCheck` | `STIntersects` point-in-polygon |
| `dbo.vw_StoreCatchment` | customers within 25 / 50 / 100 km |
| `dbo.vw_AdventureWorksAddresses` | the real `Person.Address.SpatialLocation` column |

**The key teaching point:** Power BI's SQL Server connector **cannot consume a
`geography` column**. Prove it — import `dbo.StoreLocation` directly and watch
`GeoPoint` arrive as an unusable binary value. Then import `dbo.vw_StoreLocations`
instead, which projects `.Lat` and `.Long`, and the map works. That is why every
spatial source you'll ever meet needs a projection step.

Queries worth running in SSMS first:

```sql
USE PL300Demo;

-- Argument order is (latitude, longitude) - the opposite of WKT, and the single
-- most common spatial mistake.
SELECT StoreName, GeoPoint.Lat, GeoPoint.Long, GeoPoint.STAsText()
FROM dbo.StoreLocation;

-- Distance in metres between two stores
SELECT ROUND(a.GeoPoint.STDistance(b.GeoPoint) / 1000, 1) AS Km
FROM dbo.StoreLocation a, dbo.StoreLocation b
WHERE a.City = 'Denver' AND b.City = 'Boston';

-- Point in polygon
SELECT * FROM dbo.vw_StoreRegionCheck;

-- Everything within 300 km of Denver, using a real buffer
DECLARE @denver geography = (SELECT GeoPoint FROM dbo.StoreLocation WHERE City = 'Denver');
SELECT CustomerID, ROUND(GeoPoint.STDistance(@denver) / 1000, 1) AS Km
FROM dbo.CustomerLocation
WHERE GeoPoint.STWithin(@denver.STBuffer(300000)) = 1
ORDER BY Km;
```

Verified results on this instance: 8 stores, 4 regions, 480 customers, and all
8 stores resolve to exactly their assigned region.

Two gotchas baked into the script as comments, both worth showing:

- **Ring orientation.** `geography` uses the left-hand rule, so a clockwise
  polygon ring describes the entire planet *minus* your region. Queries still
  return rows — just nonsense ones. The script checks `STArea()` and reorients
  anything larger than 1e14 m².
- **`geometry` and `geography` are not interchangeable.** `STCentroid()` exists
  only on `geometry`; on `geography` you need `EnvelopeCenter()`.

**The finished Power BI version is `powerbi/PL300-Spatial-SQL.pbip`** — five pages
reading these views live over DirectQuery, so every distance and every
point-in-polygon test is computed by SQL Server as the visual asks for it. Storage
mode reads **Mixed**: six DirectQuery tables plus one Import table over
`Person.Address.SpatialLocation`, a genuine `geography` column in
AdventureWorks2022.

Two things to set up before you show it, both in
[`../powerbi/README.md`](../powerbi/README.md): it prompts for SQL credentials on
first open, and pages 3 and 4 are validation checks that currently **pass**, so
their headline cards read `0`. Say that expected answer out loud before you click —
otherwise a zero reads as a broken demo. There is a one-line `UPDATE` in that README
that makes them non-zero live, and because the tables are DirectQuery the cards move
with no refresh, which is the most convincing thirty seconds of "this is live" you
can put on a projector.

Page 5 of `PL300-Demos.pbip` covers the same ground with the rows baked in as inline
literals — use that one if you are off the VM or want a file with no credential
prompt.

### Demo 18 — R in Power BI
**Modules: Perform analytics / Enhance report designs**

Finished examples of both of these are pages 3 and 4 of
`powerbi/PL300-Demos.pbip`.

R is installed with `ggplot2`, `dplyr`, `scales` and `forecast`, into the R
installation's own library so every user sees them. Confirm detection under
**File → Options and settings → Options → R scripting**.

The same three integration points as Python — R script data source, R transform
step, and R visual — but the R visual is where it earns its keep.

**ggplot2 visual** against the sales data. Drag `Category` and `SalesAmount` in:

```r
library(ggplot2)
ggplot(dataset, aes(x = reorder(Category, SalesAmount), y = SalesAmount)) +
  geom_col(fill = "#1F4E79") +
  coord_flip() +
  labs(title = "Revenue by Category", x = NULL, y = "Revenue") +
  theme_minimal(base_size = 14)
```

**Forecasting** — the demo that justifies R visuals existing. Power BI's built-in
analytics forecast is a black box; this is auto-fitted ARIMA with a visible model.
Drag in `MonthNumber` and `Revenue` from `MonthlyRevenue`:

```r
library(forecast)
# `dataset` columns are named after the fields you dragged in, so this must
# say Revenue, not SalesAmount. A wrong name is silently NULL, and the error
# surfaces one line later as "'ts' object must have one or more observations".
# Sort first: ts() assumes the rows are already in chronological order.
d       <- dataset[order(dataset$MonthNumber), ]
ts_data <- ts(d$Revenue, frequency = 12)
fit     <- auto.arima(ts_data)
plot(forecast(fit, h = 6),
     main = paste0("6-month forecast - ARIMA(",
                   paste(arimaorder(fit), collapse = ","), ")"),
     xlab = "Period", ylab = "Revenue")
```

The full version, with confidence-band styling and a legend, is
`powerbi/scripts/r-forecast-arima.R` — that file is generated from
`scripts/generate-pbip.py` and is the copy to trust if the two ever drift.

Verified on this VM against the monthly revenue figures from
`Quarterly_Summary.pdf`: `auto.arima` selects ARIMA(2,0,0) and forecasts
678,184 / 679,910 / 632,080 for the next three months. Handy to know in advance
so you can tell whether a live run has gone wrong.

**A transform step** — Transform Data → **Run R script**. The table arrives as
`dataset`; return a data frame:

```r
library(dplyr)
output <- dataset %>%
  group_by(Category) %>%
  mutate(CategoryShare = SalesAmount / sum(SalesAmount)) %>%
  ungroup()
```

Same honest caveats as Python: R visuals render as static images, do not
cross-filter, cap at 150,000 rows, and need a gateway once published. Use them for
statistical output the built-in visuals can't produce — `forecast`, correlation
matrices, box plots with custom stats — not for bar charts.

Good comparison to draw at the end: Python and R do the *same* job here. Python
suits teams already using pandas; R suits statisticians and has the stronger
plotting grammar in `ggplot2`. Power BI genuinely does not care which.

### Demo 19 — Optimization
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
| 2 | DAX — first principles | Demo 12a (Reseller Sales; start here) |
| 2 | DAX — filter context | Demos 13, 14 |
| 3 | Visualize and analyze | AdventureWorksDW model built on day 2 |
| 2 | Spatial and maps | Demo 17 — pairs naturally with the Store dimension |
| 3 | Analytics extensibility | Demos 16 (Python) and 18 (R) — pick one, or contrast both |
| 3 | Manage and secure | Demos 15, 19, Demo 9 (gateway discussion) |

## What this environment does *not* provide

Power BI **Service** — workspaces, publishing, dashboards, apps, deployment
pipelines and scheduled refresh — needs a Power BI / Microsoft Fabric licence in
your tenant. That is separate from this Azure subscription and cannot be
provisioned by Terraform. Power BI Desktop here does everything up to the point
of **Publish**.

For the "Manage and secure Power BI" objectives (15–20% of the exam) you will
need a Fabric trial or a Pro licence on `ciracon.com`. Everything else in the
syllabus is fully covered by this VM offline.
