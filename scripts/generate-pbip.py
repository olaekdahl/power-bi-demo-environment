#!/usr/bin/env python3
"""
Generate the PL-300 demo Power BI solution as a .pbip project.

Why .pbip and not .pbix: a .pbix is an opaque ZIP with a binary analysis-services
model inside, which cannot be authored by hand. A Power BI Project (.pbip) is the
documented text format - TMSL for the semantic model, JSON for the report - so it
can live in git, be reviewed, and be regenerated. Power BI Desktop opens it
directly and can then Save As .pbix if a single-file artifact is wanted.

Data: every table is an inline M `#table` literal, so the file opens with NO data
source prompt and NO credential setup - which is what makes it reliable to
validate automatically and to hand to a class. The spatial rows are the real
output of the SQL Server `geography` views in the PL300Demo database (see
--from-sql), and the live-SQL M query is emitted alongside each table as a
comment so the class can repoint it at SQL Server in one edit.

Usage:
    python generate-pbip.py --out powerbi --sql-dir <dir with stores/catchment/customers csv>
    python generate-pbip.py --out powerbi --sql-dir ... --pages overview   # bisect
"""

import argparse
import csv
import json
import shutil
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

SQL_SERVER = "localhost"
SQL_DATABASE = "PL300Demo"


# --------------------------------------------------------------------------- #
# M helpers
# --------------------------------------------------------------------------- #

def m_str(v):
    """Quote a value as an M text literal."""
    return '"' + str(v).replace('"', '""') + '"'


def m_num(v, dp=None):
    """
    Format a number for M.

    SQL Server hands back float noise like 47.610399999999998 for what is really
    47.6104; rounding here keeps the model readable and the map accurate to well
    under a metre.
    """
    f = float(v)
    if dp is not None:
        f = round(f, dp)
    if f == int(f) and dp in (None, 0):
        return str(int(f))
    return repr(f)


def inline_table(cols, rows, live_sql=None, view=None, indent="        ", docs=None):
    """
    Build an M expression for an inline table.

    cols: list of (name, m_type, formatter)
    docs: optional list collecting (view, live_sql) pairs for LIVE-SQL-QUERIES.md

    NOTE: the live-SQL alternative is deliberately NOT emitted as a comment
    inside the M. A `//` comment ahead of `let` is valid M in isolation, but in
    the PBIP -> mashup pipeline it can leave the query body commented out, and
    the refresh then fails with "A cyclic reference was encountered during
    evaluation" - the query ends up resolving to itself. The guidance goes to
    LIVE-SQL-QUERIES.md instead.
    """
    lines = []
    if view and live_sql and docs is not None:
        docs.append((view, live_sql.strip()))
    lines.append("let")
    type_parts = ", ".join(f"{n} = {t}" for n, t, _ in cols)
    lines.append(f"    Source = #table(")
    lines.append(f"        type table [{type_parts}],")
    lines.append("        {")
    for i, row in enumerate(rows):
        vals = ", ".join(fmt(row[n]) for n, _, fmt in cols)
        comma = "," if i < len(rows) - 1 else ""
        lines.append(f"{indent}    {{{vals}}}{comma}")
    lines.append("        }")
    lines.append("    )")
    lines.append("in")
    lines.append("    Source")
    return lines


def sql_view(view, server=SQL_SERVER, database=SQL_DATABASE, indent="    "):
    """
    M that navigates to a SQL Server view - the source step for a live table.

    Deliberately navigation, NOT Sql.Database(server, db, [Query = "SELECT ..."]):

      * a native query raises the "native database query" approval dialog for
        every distinct query text, which is a guaranteed stall in front of a
        class, and Microsoft documents it as unusable for incremental refresh;
      * navigation folds, so `View Native Query` stays enabled in the Power
        Query editor - which is itself one of the demos on the catchment page.

    All the SELECT logic already lives in the views, so there is nothing a
    native query would buy.
    """
    step = "dbo_" + view
    return [
        "let",
        f"{indent}Source = Sql.Database({m_str(server)}, {m_str(database)}),",
        f'{indent}{step} = Source{{[Schema="dbo",Item={m_str(view)}]}}[Data]',
        "in",
        f"{indent}{step}",
    ]


def col(name, dtype, summarize="none", fmt=None, data_category=None, sort_by=None):
    c = {
        "name": name,
        "dataType": dtype,
        "sourceColumn": name,
        "summarizeBy": summarize,
        "annotations": [{"name": "SummarizationSetBy", "value": "Automatic"}],
    }
    if fmt:
        c["formatString"] = fmt
    if data_category:
        c["dataCategory"] = data_category
    if sort_by:
        # Otherwise a text month sorts alphabetically on the axis.
        c["sortByColumn"] = sort_by
    return c


def table(name, columns, expression, measures=None, mode="import"):
    """
    mode: "import" or "directQuery" - the TMSL ModeType enum is camelCase and is
    matched case-sensitively. A DirectQuery table is never refreshed, so Power BI
    gets no chance to infer a schema: every column has to be declared here by
    hand with a sourceColumn and dataType that match the view exactly, or the
    table errors on open.
    """
    if mode not in ("import", "directQuery", "dual"):
        raise ValueError(f"{name}: unsupported partition mode {mode!r}")
    t = {
        "name": name,
        "columns": columns,
        "partitions": [{
            "name": f"{name}-partition",
            "mode": mode,
            "source": {"type": "m", "expression": expression},
        }],
        "annotations": [{"name": "PBI_ResultType", "value": "Table"}],
    }
    if measures:
        t["measures"] = measures
    return t


def measure(name, expr, fmt=None):
    m = {"name": name, "expression": expr}
    if fmt:
        m["formatString"] = fmt
    return m


# --------------------------------------------------------------------------- #
# Source data
# --------------------------------------------------------------------------- #

def read_pipe_csv(path, fields):
    """Read the pipe-delimited sqlcmd -W -s'|' output (may carry a UTF-8 BOM)."""
    out = []
    with path.open(encoding="utf-8-sig") as f:
        for line in f:
            line = line.rstrip("\n").rstrip("\r")
            if not line.strip():
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) != len(fields):
                continue
            out.append(dict(zip(fields, parts)))
    return out


def load_contoso_aggregates(demo_data):
    """Category and monthly revenue from the generated Contoso CSVs."""
    MONTHS = ["January", "February", "March", "April", "May", "June",
              "July", "August", "September", "October", "November", "December"]
    prod_cat = {}
    import xml.etree.ElementTree as ET
    root = ET.parse(demo_data / "XML" / "Product_Catalog.xml").getroot()
    for cnode in root.findall("Category"):
        for p in cnode.findall("Product"):
            prod_cat[int(p.get("id"))] = cnode.get("name")

    cat = defaultdict(float)
    cat_units = defaultdict(int)
    mon = defaultdict(lambda: {"rev": 0.0, "cost": 0.0, "units": 0})
    cat_mon = defaultdict(float)
    with (demo_data / "CSV" / "Sales_Transactions.csv").open() as f:
        for r in csv.DictReader(f):
            c = prod_cat[int(r["ProductID"])]
            amt = float(r["SalesAmount"])
            m = int(r["OrderDate"][5:7])
            cat[c] += amt
            cat_units[c] += int(r["Quantity"])
            mon[m]["rev"] += amt
            mon[m]["cost"] += float(r["TotalCost"])
            mon[m]["units"] += int(r["Quantity"])
            cat_mon[(c, m)] += amt

    categories = [{"Category": k, "SalesAmount": round(v, 2), "Units": cat_units[k]}
                  for k, v in sorted(cat.items(), key=lambda kv: -kv[1])]
    monthly = [{"MonthNumber": m, "MonthName": MONTHS[m - 1],
                "Revenue": round(mon[m]["rev"], 2),
                "Cost": round(mon[m]["cost"], 2),
                "Margin": round(mon[m]["rev"] - mon[m]["cost"], 2),
                "Units": mon[m]["units"]} for m in range(1, 13)]
    cat_monthly = [{"Category": c, "MonthNumber": m, "MonthName": MONTHS[m - 1],
                    "SalesAmount": round(v, 2)}
                   for (c, m), v in sorted(cat_mon.items(), key=lambda kv: (kv[0][0], kv[0][1]))]
    return categories, monthly, cat_monthly


# --------------------------------------------------------------------------- #
# Semantic model
# --------------------------------------------------------------------------- #

def model_envelope(tables, relationships):
    """
    The TMSL wrapper shared by every solution.

    Property order is load-bearing for byte-identical regeneration - json.dump
    writes insertion order - so this literal is not to be tidied or re-sorted.
    """
    return {
        "name": "SemanticModel",
        "compatibilityLevel": 1550,
        "model": {
            "culture": "en-US",
            "dataAccessOptions": {
                "legacyRedirects": True,
                "returnErrorValuesAsNull": True,
            },
            "defaultPowerBIDataSourceVersion": "powerBI_V3",
            "sourceQueryCulture": "en-US",
            "tables": tables,
            "relationships": relationships,
            "annotations": [
                {"name": "PBI_QueryOrder",
                 "value": json.dumps([t["name"] for t in tables])},
                {"name": "__PBI_TimeIntelligenceEnabled", "value": "0"},
            ],
        },
    }


def build_demo_model(sources, docs):
    """The inline-literal solution: no data source, no credential prompt."""
    categories = sources["categories"]
    monthly = sources["monthly"]
    cat_monthly = sources["cat_monthly"]
    stores = sources["stores"]
    catchment = sources["catchment"]
    customers = sources["customers"]
    catch_by_id = {c["StoreID"]: c for c in catchment}

    store_rows = []
    for s in stores:
        c = catch_by_id.get(s["StoreID"], {})
        store_rows.append({
            "StoreID": int(s["StoreID"]),
            "StoreName": s["StoreName"],
            "City": s["City"],
            "State": s["State"],
            "RegionName": s["RegionName"],
            "Latitude": s["Latitude"],
            "Longitude": s["Longitude"],
            "WellKnownText": s["WellKnownText"],
            "CustomersWithin25km": int(c.get("CustomersWithin25km", 0)),
            "CustomersWithin50km": int(c.get("CustomersWithin50km", 0)),
            "CustomersWithin100km": int(c.get("CustomersWithin100km", 0)),
        })

    cust_rows = [{
        "CustomerID": c["CustomerID"],
        "HomeStoreID": int(c["HomeStoreID"]),
        "StoreName": c["StoreName"],
        "RegionName": c["RegionName"],
        "LoyaltyTier": c["LoyaltyTier"],
        "Latitude": c["Latitude"],
        "Longitude": c["Longitude"],
        "DistanceKm": c["DistanceToHomeStoreKm"],
    } for c in customers]

    txt = lambda v: m_str(v)
    num2 = lambda v: m_num(v, 2)
    num6 = lambda v: m_num(v, 6)
    integer = lambda v: str(int(v))

    tables = []

    tables.append(table(
        "CategorySales",
        [col("Category", "string"),
         col("SalesAmount", "double", "sum", "\\$#,0.00;(\\$#,0.00);\\$#,0.00"),
         col("Units", "int64", "sum", "#,0")],
        inline_table(
            [("Category", "text", txt), ("SalesAmount", "number", num2), ("Units", "Int64.Type", integer)],
            categories),
        measures=[
            measure("Total Sales", "SUM ( CategorySales[SalesAmount] )",
                    "\\$#,0;(\\$#,0);\\$#,0"),
            measure("Total Units", "SUM ( CategorySales[Units] )", "#,0"),
            measure("Category Count", "DISTINCTCOUNT ( CategorySales[Category] )", "#,0"),
        ]))

    tables.append(table(
        "MonthlyRevenue",
        [col("MonthNumber", "int64", fmt="0"),
         col("MonthName", "string", sort_by="MonthNumber"),
         col("Revenue", "double", "sum", "\\$#,0.00;(\\$#,0.00);\\$#,0.00"),
         col("Cost", "double", "sum", "\\$#,0.00;(\\$#,0.00);\\$#,0.00"),
         col("Margin", "double", "sum", "\\$#,0.00;(\\$#,0.00);\\$#,0.00"),
         col("Units", "int64", "sum", "#,0")],
        inline_table(
            [("MonthNumber", "Int64.Type", integer), ("MonthName", "text", txt),
             ("Revenue", "number", num2), ("Cost", "number", num2),
             ("Margin", "number", num2), ("Units", "Int64.Type", integer)],
            monthly),
        measures=[
            measure("Total Revenue", "SUM ( MonthlyRevenue[Revenue] )", "\\$#,0;(\\$#,0);\\$#,0"),
            measure("Total Margin", "SUM ( MonthlyRevenue[Margin] )", "\\$#,0;(\\$#,0);\\$#,0"),
            measure("Margin %", "DIVIDE ( [Total Margin], [Total Revenue] )", "0.0%;-0.0%;0.0%"),
        ]))

    tables.append(table(
        "CategoryMonthlySales",
        [col("Category", "string"), col("MonthNumber", "int64", fmt="0"),
         col("MonthName", "string", sort_by="MonthNumber"),
         col("SalesAmount", "double", "sum", "\\$#,0.00;(\\$#,0.00);\\$#,0.00")],
        inline_table(
            [("Category", "text", txt), ("MonthNumber", "Int64.Type", integer),
             ("MonthName", "text", txt), ("SalesAmount", "number", num2)],
            cat_monthly)))

    tables.append(table(
        "StoreGeography",
        [col("StoreID", "int64", fmt="0"), col("StoreName", "string"),
         col("City", "string", data_category="City"),
         col("State", "string", data_category="StateOrProvince"),
         col("RegionName", "string"),
         col("Latitude", "double", fmt="0.0000", data_category="Latitude"),
         col("Longitude", "double", fmt="0.0000", data_category="Longitude"),
         col("WellKnownText", "string"),
         col("CustomersWithin25km", "int64", "sum", "#,0"),
         col("CustomersWithin50km", "int64", "sum", "#,0"),
         col("CustomersWithin100km", "int64", "sum", "#,0")],
        inline_table(
            [("StoreID", "Int64.Type", integer), ("StoreName", "text", txt),
             ("City", "text", txt), ("State", "text", txt), ("RegionName", "text", txt),
             ("Latitude", "number", num6), ("Longitude", "number", num6),
             ("WellKnownText", "text", txt),
             ("CustomersWithin25km", "Int64.Type", integer),
             ("CustomersWithin50km", "Int64.Type", integer),
             ("CustomersWithin100km", "Int64.Type", integer)],
            store_rows,
            docs=docs,
            view="dbo.vw_StoreLocations + dbo.vw_StoreCatchment",
            live_sql='Source = Sql.Database("localhost", "PL300Demo",\n'
                     '    [Query = "SELECT s.StoreID, s.StoreName, s.City, s.[State], s.RegionName,\n'
                     '                     s.Latitude, s.Longitude, s.WellKnownText,\n'
                     '                     c.CustomersWithin25km, c.CustomersWithin50km, c.CustomersWithin100km\n'
                     '              FROM dbo.vw_StoreLocations s\n'
                     '              JOIN dbo.vw_StoreCatchment c ON c.StoreID = s.StoreID"])'),
        measures=[
            measure("Store Count", "DISTINCTCOUNT ( StoreGeography[StoreID] )", "#,0"),
        ]))

    tables.append(table(
        "CustomerGeography",
        [col("CustomerID", "string"), col("HomeStoreID", "int64", fmt="0"),
         col("StoreName", "string"), col("RegionName", "string"),
         col("LoyaltyTier", "string"),
         col("Latitude", "double", fmt="0.00000", data_category="Latitude"),
         col("Longitude", "double", fmt="0.00000", data_category="Longitude"),
         col("DistanceKm", "double", "sum", "#,0.00")],
        inline_table(
            [("CustomerID", "text", txt), ("HomeStoreID", "Int64.Type", integer),
             ("StoreName", "text", txt), ("RegionName", "text", txt),
             ("LoyaltyTier", "text", txt), ("Latitude", "number", num6),
             ("Longitude", "number", num6), ("DistanceKm", "number", num2)],
            cust_rows,
            docs=docs,
            view="dbo.vw_CustomerLocations",
            live_sql='Source = Sql.Database("localhost", "PL300Demo",\n'
                     '    [Query = "SELECT c.CustomerID, c.HomeStoreID, s.StoreName, s.RegionName,\n'
                     '                     c.LoyaltyTier, c.Latitude, c.Longitude,\n'
                     '                     c.DistanceToHomeStoreKm AS DistanceKm\n'
                     '              FROM dbo.vw_CustomerLocations c\n'
                     '              JOIN dbo.vw_StoreLocations s ON s.StoreID = c.HomeStoreID"])'),
        measures=[
            measure("Customer Count", "COUNTROWS ( CustomerGeography )", "#,0"),
            measure("Avg Distance Km", "AVERAGE ( CustomerGeography[DistanceKm] )", "#,0.0"),
        ]))

    relationships = [{
        "name": "StoreGeography-CustomerGeography",
        "fromTable": "CustomerGeography",
        "fromColumn": "HomeStoreID",
        "toTable": "StoreGeography",
        "toColumn": "StoreID",
        "crossFilteringBehavior": "oneDirection",
    }]

    return model_envelope(tables, relationships)


# --------------------------------------------------------------------------- #
# Semantic model - live from SQL Server
# --------------------------------------------------------------------------- #
#
# Every column each view actually exposes, transcribed from
# sys.dm_exec_describe_first_result_set run against PL300Demo on the demo VM.
#
# This exists because model.bim is the one generated file nothing validates
# offline: validate-pbip.py skips any document without a `$schema`, and TMSL has
# none. A DirectQuery table is never refreshed either, so Power BI never gets a
# chance to infer a schema and reconcile a wrong name - it just errors when the
# project is opened against SQL Server, a full VM round trip away. Checking
# against this inventory turns that into a generator-time failure.
#
# The trap it is really here to catch: vw_CustomerLocations calls its store
# column HomeStoreName. The inline-literal solution aliases it to StoreName in
# its hand-written SELECT, but navigation gives you the view's real name.

VIEW_COLUMNS = {
    "vw_StoreLocations": {
        "StoreID": "int64", "StoreName": "string", "City": "string",
        "State": "string", "RegionID": "int64", "RegionName": "string",
        "Latitude": "double", "Longitude": "double",
        "WellKnownText": "string", "CityState": "string",
    },
    "vw_StoreCatchment": {
        "StoreID": "int64", "StoreName": "string", "RegionName": "string",
        "CustomersWithin25km": "int64", "CustomersWithin50km": "int64",
        "CustomersWithin100km": "int64", "CustomersTotal": "int64",
    },
    "vw_CustomerLocations": {
        "CustomerKey": "int64", "CustomerID": "string", "HomeStoreID": "int64",
        "HomeStoreName": "string", "RegionName": "string", "LoyaltyTier": "string",
        "Latitude": "double", "Longitude": "double",
        "DistanceToHomeStoreKm": "double",
    },
    "vw_CustomerNearestStore": {
        "CustomerID": "string", "HomeStoreID": "int64", "NearestStoreID": "int64",
        "NearestStoreName": "string", "DistanceKm": "double",
        "NearestIsHomeStore": "string",
    },
    "vw_StoreRegionCheck": {
        "StoreID": "int64", "StoreName": "string", "AssignedRegion": "string",
        "ContainingRegion": "string", "Result": "string", "RegionAreaSqKm": "double",
    },
    "vw_RegionBoundaries": {
        "RegionID": "int64", "RegionName": "string", "WellKnownText": "string",
        "CenterLatitude": "double", "CenterLongitude": "double",
        "AreaSqKm": "double", "PointCount": "int64",
    },
    "vw_AdventureWorksAddresses": {
        "AddressID": "int64", "City": "string", "StateProvince": "string",
        "StateProvinceCode": "string", "CountryRegion": "string",
        "PostalCode": "string", "Latitude": "double", "Longitude": "double",
    },
}


def sql_table(name, view, columns, measures=None, mode="directQuery"):
    """A table bound to a PL300Demo view, checked against VIEW_COLUMNS."""
    known = VIEW_COLUMNS[view]
    for c in columns:
        src = c["sourceColumn"]
        if src not in known:
            raise SystemExit(
                f"{name}: dbo.{view} has no column {src!r}. "
                f"It exposes: {', '.join(sorted(known))}")
        if c["dataType"] != known[src]:
            raise SystemExit(
                f"{name}[{src}]: declared as {c['dataType']}, "
                f"but dbo.{view} returns {known[src]}")
    return table(name, columns, sql_view(view), measures=measures, mode=mode)


def build_sql_model(sources, docs):
    """
    Six DirectQuery tables plus one Import table - a composite ("Mixed") model.

    DirectQuery is the right default here purely on measurement: every view
    answers in under 50 ms on the demo VM (RegionBoundaries 1 ms,
    CustomerLocations 2 ms, StoreCatchment 9-10 ms, CustomerNearestStore
    21-23 ms, AdventureWorksAddresses 46 ms), and the largest table is 19,614
    rows against DirectQuery's 1,000,000-row intermediate limit. The views that
    sound expensive - an 8x480 cross join with STDistance, a CROSS APPLY TOP 1
    nearest-neighbour - are the two that were timed most carefully, and neither
    is a risk at this volume.

    AdventureWorksAddresses is Import on purpose, and it is the only Import
    table: it makes the storage mode read "Mixed", puts a populated Data view
    beside six that say "DirectQuery tables can't be shown", and means stopping
    the SQL Server service breaks four pages while page 5 keeps rendering.
    """
    del sources, docs  # this solution reads no CSVs and emits no live-SQL doc

    tables = [
        sql_table(
            "StoreLocations", "vw_StoreLocations",
            [col("StoreID", "int64", fmt="0"), col("StoreName", "string"),
             col("City", "string", data_category="City"),
             col("State", "string", data_category="StateOrProvince"),
             col("RegionID", "int64", fmt="0"), col("RegionName", "string"),
             col("Latitude", "double", fmt="0.0000", data_category="Latitude"),
             col("Longitude", "double", fmt="0.0000", data_category="Longitude"),
             col("WellKnownText", "string"),
             # What Power BI geocodes when you give it no coordinates.
             col("CityState", "string", data_category="Place")],
            measures=[
                measure("Store Count", "DISTINCTCOUNT ( StoreLocations[StoreID] )", "#,0"),
            ]),

        sql_table(
            "StoreCatchment", "vw_StoreCatchment",
            [col("StoreID", "int64", fmt="0"), col("StoreName", "string"),
             col("RegionName", "string"),
             col("CustomersWithin25km", "int64", "sum", "#,0"),
             col("CustomersWithin50km", "int64", "sum", "#,0"),
             col("CustomersWithin100km", "int64", "sum", "#,0"),
             # COUNT(*) over the cross join, so this is 480 on all 8 rows.
             # Summing it gives a plausible-looking 3,840.
             col("CustomersTotal", "int64", "none", "#,0")],
            measures=[
                measure("Within 25 km", "SUM ( StoreCatchment[CustomersWithin25km] )", "#,0"),
                measure("Within 50 km", "SUM ( StoreCatchment[CustomersWithin50km] )", "#,0"),
                measure("Within 100 km", "SUM ( StoreCatchment[CustomersWithin100km] )", "#,0"),
                measure("Catchment Coverage %",
                        "DIVIDE ( [Within 50 km], [Within 100 km] )", "0.0%;-0.0%;0.0%"),
            ]),

        sql_table(
            "CustomerLocations", "vw_CustomerLocations",
            [col("CustomerKey", "int64", fmt="0"), col("CustomerID", "string"),
             col("HomeStoreID", "int64", fmt="0"),
             col("HomeStoreName", "string"), col("RegionName", "string"),
             col("LoyaltyTier", "string"),
             col("Latitude", "double", fmt="0.00000", data_category="Latitude"),
             col("Longitude", "double", fmt="0.00000", data_category="Longitude"),
             col("DistanceToHomeStoreKm", "double", "average", "#,0.00")],
            measures=[
                measure("Customer Count", "COUNTROWS ( CustomerLocations )", "#,0"),
                measure("Avg Distance To Home Km",
                        "AVERAGE ( CustomerLocations[DistanceToHomeStoreKm] )", "#,0.00"),
            ]),

        sql_table(
            "CustomerNearestStore", "vw_CustomerNearestStore",
            [col("CustomerID", "string"), col("HomeStoreID", "int64", fmt="0"),
             col("NearestStoreID", "int64", fmt="0"),
             col("NearestStoreName", "string"),
             col("DistanceKm", "double", "average", "#,0.00"),
             col("NearestIsHomeStore", "string")],
            measures=[
                measure("Customers Assessed", "COUNTROWS ( CustomerNearestStore )", "#,0"),
                measure("Nearest Is Home Store",
                        'CALCULATE ( COUNTROWS ( CustomerNearestStore ), '
                        'CustomerNearestStore[NearestIsHomeStore] = "Yes" )', "#,0"),
                # The COALESCE is load-bearing, not style. This filter matches
                # zero rows on the shipped data, and COUNTROWS over an empty
                # table returns BLANK - which renders as an empty card that
                # reads as a broken visual rather than the correct answer, 0.
                measure("Reassignment Candidates",
                        'COALESCE ( CALCULATE ( COUNTROWS ( CustomerNearestStore ), '
                        'CustomerNearestStore[NearestIsHomeStore] = "No" ), 0 )', "#,0"),
                measure("Assignment Match Rate",
                        "DIVIDE ( [Nearest Is Home Store], [Customers Assessed] )",
                        "0.0%;-0.0%;0.0%"),
                measure("Avg Nearest Distance Km",
                        "AVERAGE ( CustomerNearestStore[DistanceKm] )", "#,0.00"),
            ]),

        sql_table(
            "StoreRegionCheck", "vw_StoreRegionCheck",
            [col("StoreID", "int64", fmt="0"), col("StoreName", "string"),
             col("AssignedRegion", "string"), col("ContainingRegion", "string"),
             col("Result", "string"),
             # Each region's area repeats on 2 store rows, so SUM double-counts
             # to 20,997,820 against a true 10,498,910.
             col("RegionAreaSqKm", "double", "none", "#,0")],
            measures=[
                measure("Stores Checked", "COUNTROWS ( StoreRegionCheck )", "#,0"),
                # COALESCE for the same reason as Reassignment Candidates.
                measure("Region Mismatches",
                        'COALESCE ( CALCULATE ( COUNTROWS ( StoreRegionCheck ), '
                        'StoreRegionCheck[Result] = "MISMATCH" ), 0 )', "#,0"),
            ]),

        sql_table(
            "RegionBoundaries", "vw_RegionBoundaries",
            [col("RegionID", "int64", fmt="0"), col("RegionName", "string"),
             col("WellKnownText", "string"),
             # EnvelopeCenter(), because geography has no STCentroid().
             col("CenterLatitude", "double", fmt="0.0000", data_category="Latitude"),
             col("CenterLongitude", "double", fmt="0.0000", data_category="Longitude"),
             col("AreaSqKm", "double", "sum", "#,0"),
             col("PointCount", "int64", fmt="0")],
            measures=[
                measure("Region Count", "DISTINCTCOUNT ( RegionBoundaries[RegionID] )", "#,0"),
                measure("Total Region Area SqKm", "SUM ( RegionBoundaries[AreaSqKm] )", "#,0"),
            ]),

        sql_table(
            "AdventureWorksAddresses", "vw_AdventureWorksAddresses",
            [col("AddressID", "int64", fmt="0"),
             col("City", "string", data_category="City"),
             col("StateProvince", "string", data_category="StateOrProvince"),
             # nchar(3), so two-letter codes arrive padded with a trailing
             # space. Fine to display, broken as a join key or slicer label.
             col("StateProvinceCode", "string"),
             col("CountryRegion", "string", data_category="Country"),
             col("PostalCode", "string", data_category="PostalCode"),
             col("Latitude", "double", fmt="0.0000", data_category="Latitude"),
             col("Longitude", "double", fmt="0.0000", data_category="Longitude")],
            measures=[
                measure("Address Count", "COUNTROWS ( AdventureWorksAddresses )", "#,0"),
                measure("Country Count",
                        "DISTINCTCOUNT ( AdventureWorksAddresses[CountryRegion] )", "#,0"),
                measure("City Count",
                        "DISTINCTCOUNT ( AdventureWorksAddresses[City] )", "#,0"),
            ],
            mode="import"),
    ]

    # A plain star into StoreLocations, plus one snowflake hop to
    # RegionBoundaries. CustomerNearestStore[NearestStoreID] is deliberately
    # left unrelated: a second path to StoreLocations would be ambiguous, and
    # the view already denormalises NearestStoreName.
    #
    # AdventureWorksAddresses is an island on purpose. It is the only Import
    # table, so leaving it unrelated means the model contains no Import-to-
    # DirectQuery relationship, and therefore no limited relationships.
    rels = [("StoreCatchment", "StoreID", "StoreLocations", "StoreID"),
            ("StoreRegionCheck", "StoreID", "StoreLocations", "StoreID"),
            ("CustomerLocations", "HomeStoreID", "StoreLocations", "StoreID"),
            ("CustomerNearestStore", "HomeStoreID", "StoreLocations", "StoreID"),
            ("StoreLocations", "RegionID", "RegionBoundaries", "RegionID")]
    relationships = [{
        "name": f"{ft}-{tt}",
        "fromTable": ft, "fromColumn": fc,
        "toTable": tt, "toColumn": tc,
        "crossFilteringBehavior": "oneDirection",
    } for ft, fc, tt, tc in rels]

    return model_envelope(tables, relationships)


# --------------------------------------------------------------------------- #
# Report (PBIR)
# --------------------------------------------------------------------------- #
#
# The report is emitted as PBIR - the `definition/` folder - and NOT as
# report.json. Microsoft documents report.json (PBIR-Legacy) as a format that
# "doesn't support external editing", and hand-authoring it genuinely does not
# work: Power BI keeps the visual types and the field bindings but silently
# discards every `objects` entry. The symptoms were R/Python visuals whose script
# body never loaded (blank canvas, empty script editor, no error anywhere) and
# visual titles falling back to auto-generated ones like "Revenue by MonthName".
#
# PBIR is the documented, externally-editable equivalent, and every file carries
# a public JSON schema - see scripts/validate-pbip.py, which checks the output
# offline instead of us discovering shape errors one 5-minute render at a time.

SCHEMA_BASE = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition"
VISUAL_SCHEMA = f"{SCHEMA_BASE}/visualContainer/1.4.0/schema.json"
PAGE_SCHEMA = f"{SCHEMA_BASE}/page/1.4.0/schema.json"
PAGES_SCHEMA = f"{SCHEMA_BASE}/pagesMetadata/1.0.0/schema.json"
REPORT_DEF_SCHEMA = f"{SCHEMA_BASE}/report/1.0.0/schema.json"
VERSION_SCHEMA = f"{SCHEMA_BASE}/versionMetadata/1.0.0/schema.json"

PAGE_W, PAGE_H = 1280, 720
ACCENT = "#1F4E79"


def lit(value):
    """Wrap a raw value as a PBIR literal expression."""
    return {"expr": {"Literal": {"Value": value}}}


def lit_text(text):
    """A single-quoted text literal, doubling any embedded single quote."""
    return lit("'" + text.replace("'", "''") + "'")


# --- field references -------------------------------------------------------
# PBIR names the source table directly via SourceRef.Entity, so there is no
# separate From/alias list to keep in step (the legacy prototypeQuery needed
# both, and drift between them was easy to introduce).

def fld_column(entity, prop):
    return {"Column": {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def fld_measure(entity, prop):
    return {"Measure": {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def fld_aggregation(entity, prop, function=0):
    """function: 0=Sum, 1=Avg, 2=Min, 3=Max, 4=Count, 5=CountNonNull."""
    return {"Aggregation": {
        "Expression": {"Column": {
            "Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}},
        "Function": function}}


def proj_column(entity, prop, native=None):
    return {"field": fld_column(entity, prop),
            "queryRef": f"{entity}.{prop}",
            "nativeQueryRef": native or prop}


def proj_measure(entity, prop, native=None):
    return {"field": fld_measure(entity, prop),
            "queryRef": f"{entity}.{prop}",
            "nativeQueryRef": native or prop}


def proj_sum(entity, prop, native=None):
    return {"field": fld_aggregation(entity, prop, 0),
            "queryRef": f"Sum({entity}.{prop})",
            "nativeQueryRef": native or f"Sum of {prop}"}


def proj_avg(entity, prop, native=None):
    return {"field": fld_aggregation(entity, prop, 1),
            "queryRef": f"Avg({entity}.{prop})",
            "nativeQueryRef": native or f"Average of {prop}"}


# --- visual containers ------------------------------------------------------

def visual(name, visual_type, x, y, w, h, roles=None, title_text=None,
           objects=None, z=0, tab_order=0):
    """
    Build one visual.json.

    Note the split the legacy format obscured:

      * a visual's TITLE is container chrome -> `visualContainerObjects.title`
      * data-view objects, such as a script visual's `script` -> `objects`

    The legacy code put the title in `objects`, which is precisely why every
    title was dropped.
    """
    v = {"visualType": visual_type}
    if roles:
        v["query"] = {"queryState": {
            role: {"projections": projections} for role, projections in roles.items()}}
        v["drillFilterOtherVisuals"] = True
    if objects:
        v["objects"] = objects
    if title_text:
        v["visualContainerObjects"] = {"title": [{"properties": {
            "show": lit("true"),
            "text": lit_text(title_text),
        }}]}
    return {
        "$schema": VISUAL_SCHEMA,
        "name": name,
        "position": {"x": x, "y": y, "z": z, "width": w, "height": h,
                     "tabOrder": tab_order},
        "visual": v,
    }


def script_objects(script_text):
    """The script body of an R (`scriptVisual`) or Python (`pythonVisual`) visual."""
    return {"script": [{"properties": {"source": lit_text(script_text)}}]}


def textbox(name, x, y, w, h, runs, z=0):
    """A static text box. Content lives in objects.general.paragraphs."""
    paragraphs = [{"textRuns": [{
        "value": r["text"],
        "textStyle": {
            "fontSize": f"{r.get('size', 11)}pt",
            "fontWeight": "bold" if r.get("bold") else "normal",
            "color": r.get("colour", "#333333"),
        },
    }]} for r in runs]
    return {
        "$schema": VISUAL_SCHEMA,
        "name": name,
        "position": {"x": x, "y": y, "z": z, "width": w, "height": h, "tabOrder": 0},
        "visual": {
            "visualType": "textbox",
            "objects": {"general": [{"properties": {"paragraphs": paragraphs}}]},
        },
    }


PYTHON_SCRIPT = """# Power BI hands the fields you dropped in to this script as the
# pandas DataFrame `dataset`. It must finish by calling plt.show().
#
# Do NOT call matplotlib.use("Agg") here. Power BI sets up its own backend and
# hooks plt.show() to capture the figure; overriding the backend makes show() a
# no-op and the visual renders completely blank with no error.
import matplotlib.pyplot as plt

df = dataset.groupby("Category", as_index=False)["SalesAmount"].sum()
df = df.sort_values("SalesAmount")

fig, ax = plt.subplots(figsize=(8, 4.5))
bars = ax.barh(df["Category"], df["SalesAmount"], color="#1F4E79")
ax.set_xlabel("Revenue (USD)")
ax.set_title("Revenue by Category - built by Python in Power BI", fontsize=13)
ax.spines[["top", "right"]].set_visible(False)
for b, v in zip(bars, df["SalesAmount"]):
    ax.text(v, b.get_y() + b.get_height() / 2, f" ${v/1e6:.2f}M",
            va="center", fontsize=10, color="#1F4E79")
ax.set_xlim(0, df["SalesAmount"].max() * 1.18)
plt.tight_layout()
plt.show()
"""

R_GGPLOT_SCRIPT = """# `dataset` is the data frame Power BI builds from the fields
# dropped into this visual.
library(ggplot2)

agg <- aggregate(SalesAmount ~ Category, data = dataset, FUN = sum)
agg$Label <- paste0("$", format(round(agg$SalesAmount / 1e6, 2), nsmall = 2), "M")

ggplot(agg, aes(x = reorder(Category, SalesAmount), y = SalesAmount)) +
  geom_col(fill = "#1F4E79", width = 0.65) +
  geom_text(aes(label = Label), hjust = -0.12, size = 4.2, colour = "#1F4E79") +
  coord_flip() +
  scale_y_continuous(expand = expansion(mult = c(0, 0.20))) +
  labs(title = "Revenue by Category - built by R (ggplot2)",
       x = NULL, y = "Revenue (USD)") +
  theme_minimal(base_size = 14) +
  theme(panel.grid.major.y = element_blank(),
        plot.title = element_text(colour = "#1F4E79", size = 14))
"""

R_FORECAST_SCRIPT = """# auto.arima picks the model, then we forecast 6 periods.
# This is the demo that justifies R visuals: the built-in Power BI
# forecast cannot show you which ARIMA order it chose.
library(forecast)

d  <- dataset[order(dataset$MonthNumber), ]
ts_data <- ts(d$Revenue, frequency = 12)
fit <- auto.arima(ts_data)
fc  <- forecast(fit, h = 6)

par(mar = c(4, 4, 3, 1))
plot(fc,
     main = paste0("6-month revenue forecast - ARIMA(",
                   paste(arimaorder(fit), collapse = ","), ")"),
     xlab = "Period (year fraction, 12 = monthly)",
     ylab = "Revenue (USD)",
     col = "#1F4E79", fcol = "#C00000", flwd = 2)
grid(col = "#DDDDDD")
legend("topleft", bty = "n", cex = 0.9,
       legend = c("Actual", "Forecast + 80/95% CI"),
       col = c("#1F4E79", "#C00000"), lwd = 2)
"""


# --- pages ------------------------------------------------------------------
# Each builder returns (pageName, displayName, [visual dicts]). Page names must
# be word characters or hyphens - Power BI silently ignores folders that break
# that rule and treats them as private user files.

def page_overview():
    return "PageOverview", "1. Overview", [
        textbox("tbOverview", 16, 12, 1248, 80, [
            {"text": "PL-300 Demo Solution", "size": 20, "bold": True, "colour": ACCENT},
            {"text": "  Python, R and SQL Server spatial visuals. Every table is an "
                     "inline M literal, so this file opens with no credential prompt.",
             "size": 11},
        ]),
        visual("cardRevenue", "card", 16, 100, 300, 110,
               roles={"Values": [proj_measure("MonthlyRevenue", "Total Revenue")]},
               title_text="FY2024 revenue"),
        visual("cardStores", "card", 328, 100, 300, 110,
               roles={"Values": [proj_measure("StoreGeography", "Store Count")]},
               title_text="Stores"),
        visual("cardCustomers", "card", 640, 100, 300, 110,
               roles={"Values": [proj_measure("CustomerGeography", "Customer Count")]},
               title_text="Customers (from SQL geography)"),
        visual("tblCategory", "tableEx", 16, 222, 612, 290,
               roles={"Values": [
                   proj_column("CategorySales", "Category"),
                   proj_sum("CategorySales", "SalesAmount", "Revenue"),
                   proj_sum("CategorySales", "Units", "Units"),
               ]},
               title_text="Revenue by category"),
        visual("chartMonth", "columnChart", 640, 222, 624, 290,
               roles={
                   "Category": [proj_column("MonthlyRevenue", "MonthName", "Month")],
                   "Y": [proj_sum("MonthlyRevenue", "Revenue", "Revenue")],
               },
               title_text="Revenue by month"),
    ]


def page_python():
    return "PagePython", "2. Python visual", [
        textbox("tbPy", 16, 12, 1248, 88, [
            {"text": "Python visual  ", "size": 18, "bold": True, "colour": ACCENT},
            {"text": "matplotlib + pandas. Power BI passes the selected fields to the "
                     "script as the DataFrame `dataset`; the script must end with "
                     "plt.show(). Needs pandas and matplotlib installed.", "size": 11},
        ]),
        visual("pyVisual", "pythonVisual", 16, 108, 1248, 596,
               roles={"Values": [
                   proj_column("CategorySales", "Category"),
                   proj_sum("CategorySales", "SalesAmount", "SalesAmount"),
               ]},
               objects=script_objects(PYTHON_SCRIPT)),
    ]


def page_r():
    return "PageR", "3. R visual (ggplot2)", [
        textbox("tbR", 16, 12, 1248, 88, [
            {"text": "R visual - ggplot2  ", "size": 18, "bold": True, "colour": ACCENT},
            {"text": "The same question answered in R. `dataset` arrives as a data "
                     "frame and the last plot produced becomes the visual. Needs the "
                     "ggplot2 package.", "size": 11},
        ]),
        visual("rVisual", "scriptVisual", 16, 108, 1248, 596,
               roles={"Values": [
                   proj_column("CategorySales", "Category"),
                   proj_sum("CategorySales", "SalesAmount", "SalesAmount"),
               ]},
               objects=script_objects(R_GGPLOT_SCRIPT)),
    ]


def page_r_forecast():
    return "PageRForecast", "4. R forecast (ARIMA)", [
        textbox("tbRf", 16, 12, 1248, 88, [
            {"text": "R visual - auto.arima forecast  ", "size": 18, "bold": True,
             "colour": ACCENT},
            {"text": "The case for R visuals: auto.arima picks the model and the title "
                     "reports which ARIMA order it chose, with 80% and 95% confidence "
                     "bands. Needs the forecast package.", "size": 11},
        ]),
        visual("rForecast", "scriptVisual", 16, 108, 1248, 596,
               roles={"Values": [
                   proj_column("MonthlyRevenue", "MonthNumber"),
                   proj_sum("MonthlyRevenue", "Revenue", "Revenue"),
               ]},
               objects=script_objects(R_FORECAST_SCRIPT)),
    ]


def page_spatial():
    return "PageSpatial", "5. SQL spatial (geography)", [
        textbox("tbSp", 16, 12, 1248, 88, [
            {"text": "SQL Server spatial data  ", "size": 18, "bold": True,
             "colour": ACCENT},
            {"text": "Sourced from the geography columns in PL300Demo via "
                     "dbo.vw_StoreLocations and dbo.vw_CustomerLocations. Power BI "
                     "cannot read a geography column directly, so those views project "
                     ".Lat / .Long / .STAsText() for it.", "size": 11},
        ]),
        # scatterChart role names matter: `Category` is the granularity (one mark
        # per distinct value) and `Series` is the legend. Putting RegionName in
        # Category collapsed 480 customers down to one point per region, and
        # `Details` - which is what the field well is labelled in the UI - is not
        # a role the query layer accepts at all.
        visual("scatterGeo", "scatterChart", 16, 108, 780, 400,
               roles={
                   "Category": [proj_column("CustomerGeography", "CustomerID")],
                   "X": [proj_avg("CustomerGeography", "Longitude", "Longitude")],
                   "Y": [proj_avg("CustomerGeography", "Latitude", "Latitude")],
                   "Series": [proj_column("CustomerGeography", "RegionName", "Region")],
               },
               title_text="480 customer geography points, longitude x latitude"),
        # Azure Maps, not the classic "map" visual: the Bing-backed one is
        # deprecated and Power BI raises a modal "Bing map visuals are going away"
        # notice the first time a report containing one is opened.
        visual("mapStores", "azureMap", 812, 108, 452, 400,
               roles={
                   "Category": [proj_column("StoreGeography", "City")],
                   "Latitude": [proj_avg("StoreGeography", "Latitude", "Latitude")],
                   "Longitude": [proj_avg("StoreGeography", "Longitude", "Longitude")],
                   "Size": [proj_sum("StoreGeography", "CustomersWithin50km", "Within 50km")],
               },
               title_text="Store locations (Azure Maps)"),
        visual("tblGeo", "tableEx", 16, 520, 1248, 184,
               roles={"Values": [
                   proj_column("StoreGeography", "StoreName"),
                   proj_column("StoreGeography", "RegionName", "Region"),
                   proj_column("StoreGeography", "WellKnownText", "WKT"),
                   proj_sum("StoreGeography", "CustomersWithin25km", "Within 25km"),
                   proj_sum("StoreGeography", "CustomersWithin50km", "Within 50km"),
               ]},
               title_text="Well-known text straight from the geography column"),
    ]


# --------------------------------------------------------------------------- #
# Pages - the live-SQL solution
# --------------------------------------------------------------------------- #
#
# These bind to the view-derived table names (StoreLocations, CustomerLocations,
# ...), not the inline solution's StoreGeography / CustomerGeography, so no page
# builder is shared between the two registries.
#
# All narration goes in textbox visuals, because that is the only text on the
# legacy report.json path that survives. Two things do NOT, both confirmed by
# screenshotting this solution on the VM:
#
#   * `visualContainerObjects` - so `title_text` is honoured only under --pbir.
#     The rendered title is otherwise auto-generated ("CustomersWithin50km by
#     City").
#   * `nativeQueryRef` -> the legacy `NativeReferenceName`. Table headers and
#     axis captions come out as the raw model names regardless ("StoreName",
#     "Average of Latitude"), so the aliases below document intent and take
#     effect under --pbir, but do not rename anything today.
#
# Practical consequence: keep model column names presentable, and leave room in
# table visuals for the full unaliased header.

def page_sql_stores():
    return "PageSqlStores", "1. Stores (geography to columns)", [
        textbox("tbSqlStores", 16, 12, 1248, 92, [
            {"text": "A geography column, projected into columns  ", "size": 18,
             "bold": True, "colour": ACCENT},
            {"text": "Live from SQL Server: dbo.vw_StoreLocations over "
                     "PL300Demo, in DirectQuery. Power BI has no spatial data "
                     "type at all - the documented type list stops at "
                     "Text/Number/Date/Boolean/Binary - so StoreLocation.GeoPoint "
                     "has nowhere to land. The view is what makes it usable: "
                     ".Lat and .Long become numbers, .STAsText() becomes the WKT "
                     "text in the last column.", "size": 11},
        ]),
        visual("cardStores", "card", 16, 112, 300, 104,
               roles={"Values": [proj_measure("StoreLocations", "Store Count")]},
               title_text="Stores"),
        visual("cardRegions", "card", 328, 112, 300, 104,
               roles={"Values": [proj_measure("RegionBoundaries", "Region Count")]},
               title_text="Region polygons"),
        visual("cardCustomers", "card", 640, 112, 300, 104,
               roles={"Values": [proj_measure("CustomerLocations", "Customer Count")]},
               title_text="Customer points"),
        # The one Import number sitting beside three DirectQuery ones.
        visual("cardAddresses", "card", 952, 112, 312, 104,
               roles={"Values": [proj_measure("AdventureWorksAddresses", "Address Count")]},
               title_text="AdventureWorks addresses (Import)"),
        # No Size role, deliberately. Binding CustomersWithin50km here looked
        # right and rendered a lie: Azure Maps stretches whatever range it is
        # given across the full bubble-size scale, so values of 44..52 - a 15%
        # spread - came out as Austin at a tenth the diameter of Bellevue.
        # Magnitudes belong on page 2, where a column chart gives them an axis.
        visual("mapStores", "azureMap", 16, 232, 620, 472,
               roles={
                   "Category": [proj_column("StoreLocations", "City")],
                   "Latitude": [proj_avg("StoreLocations", "Latitude", "Latitude")],
                   "Longitude": [proj_avg("StoreLocations", "Longitude", "Longitude")],
               },
               title_text="Store locations from the geography column"),
        visual("tblStoreWkt", "tableEx", 648, 232, 616, 472,
               roles={"Values": [
                   proj_column("StoreLocations", "StoreName", "Store"),
                   proj_column("StoreLocations", "State"),
                   proj_column("StoreLocations", "RegionName", "Region"),
                   proj_avg("StoreLocations", "Latitude", "Latitude"),
                   proj_avg("StoreLocations", "Longitude", "Longitude"),
                   proj_column("StoreLocations", "WellKnownText", "WKT from .STAsText()"),
               ]},
               title_text="Well-known text, straight from the geography column"),
    ]


def page_sql_catchment():
    return "PageSqlCatchment", "2. Catchment (STDistance)", [
        textbox("tbSqlCatchment", 16, 12, 1248, 92, [
            {"text": "STDistance, recomputed on every click  ", "size": 18,
             "bold": True, "colour": ACCENT},
            {"text": "dbo.vw_StoreCatchment CROSS JOINs 8 stores against 480 "
                     "customers and evaluates GeoPoint.STDistance for all 3,840 "
                     "pairs - a real distance buffer, not a bounding box. "
                     "STDistance returns metres for geography, hence the /1000 "
                     "in the view. It answers in about 10 ms, which is why "
                     "DirectQuery is safe here. Performance Analyzer > Copy "
                     "query shows the SQL Power BI sent.", "size": 11},
        ]),
        visual("cardWithin25", "card", 16, 112, 300, 104,
               roles={"Values": [proj_measure("StoreCatchment", "Within 25 km")]},
               title_text="Within 25 km"),
        visual("cardWithin50", "card", 328, 112, 300, 104,
               roles={"Values": [proj_measure("StoreCatchment", "Within 50 km")]},
               title_text="Within 50 km"),
        visual("cardWithin100", "card", 640, 112, 300, 104,
               roles={"Values": [proj_measure("StoreCatchment", "Within 100 km")]},
               title_text="Within 100 km"),
        visual("cardCoverage", "card", 952, 112, 312, 104,
               roles={"Values": [proj_measure("StoreCatchment", "Catchment Coverage %")]},
               title_text="50 km as a share of 100 km"),
        # clusteredColumnChart, NOT columnChart. Power BI's "columnChart" is the
        # STACKED column chart, and these three buffers are cumulative - every
        # customer within 25 km is also within 50 and 100 - so stacking them
        # adds a number to itself. Bellevue rendered as 15+52+60 = 127, a total
        # that means nothing and that nobody questions from the back of a room.
        visual("chartCatchment", "clusteredColumnChart", 16, 232, 700, 472,
               roles={
                   "Category": [proj_column("StoreCatchment", "StoreName", "Store")],
                   "Y": [proj_measure("StoreCatchment", "Within 25 km"),
                         proj_measure("StoreCatchment", "Within 50 km"),
                         proj_measure("StoreCatchment", "Within 100 km")],
               },
               title_text="Customers inside each distance buffer"),
        visual("tblCatchment", "tableEx", 732, 232, 532, 472,
               roles={"Values": [
                   proj_column("StoreCatchment", "StoreName", "Store"),
                   proj_column("StoreCatchment", "CustomersWithin25km", "25 km"),
                   proj_column("StoreCatchment", "CustomersWithin50km", "50 km"),
                   proj_column("StoreCatchment", "CustomersWithin100km", "100 km"),
               ]},
               title_text="Catchment counts per store"),
    ]


def page_sql_nearest():
    return "PageSqlNearest", "3. Nearest store (CROSS APPLY)", [
        textbox("tbSqlNearest", 16, 12, 1248, 104, [
            {"text": "Nearest-neighbour: CROSS APPLY TOP 1 ORDER BY STDistance  ",
             "size": 18, "bold": True, "colour": ACCENT},
            {"text": "dbo.vw_CustomerNearestStore ignores HomeStoreID entirely "
                     "and picks the closest store geometrically, then compares "
                     "the two. Expect 480 of 480 to agree and 0 reassignment "
                     "candidates - this is a data-quality check that currently "
                     "PASSES, so say the expected answer out loud before you "
                     "click. powerbi/README.md has a one-line UPDATE that makes "
                     "it fail, and because these tables are DirectQuery the "
                     "cards move with no refresh.", "size": 11},
        ]),
        visual("cardAssessed", "card", 16, 124, 300, 104,
               roles={"Values": [proj_measure("CustomerNearestStore", "Customers Assessed")]},
               title_text="Customers assessed"),
        visual("cardMatch", "card", 328, 124, 300, 104,
               roles={"Values": [proj_measure("CustomerNearestStore", "Nearest Is Home Store")]},
               title_text="Nearest is the home store"),
        visual("cardCandidates", "card", 640, 124, 300, 104,
               roles={"Values": [proj_measure("CustomerNearestStore", "Reassignment Candidates")]},
               title_text="Reassignment candidates"),
        visual("cardRate", "card", 952, 124, 312, 104,
               roles={"Values": [proj_measure("CustomerNearestStore", "Assignment Match Rate")]},
               title_text="Assignment match rate"),
        visual("scatterCustomers", "scatterChart", 16, 244, 760, 460,
               roles={
                   "Category": [proj_column("CustomerLocations", "CustomerID")],
                   "X": [proj_avg("CustomerLocations", "Longitude", "Longitude")],
                   "Y": [proj_avg("CustomerLocations", "Latitude", "Latitude")],
                   "Series": [proj_column("CustomerLocations", "RegionName", "Region")],
               },
               title_text="480 customers, longitude x latitude"),
        visual("chartNearestDist", "columnChart", 788, 244, 476, 226,
               roles={
                   "Category": [proj_column("CustomerNearestStore", "NearestStoreName",
                                            "Nearest store")],
                   "Y": [proj_measure("CustomerNearestStore", "Avg Nearest Distance Km")],
               },
               title_text="Average distance to the nearest store"),
        visual("tblNearest", "tableEx", 788, 478, 476, 226,
               roles={"Values": [
                   proj_column("CustomerNearestStore", "CustomerID", "Customer"),
                   proj_column("CustomerNearestStore", "NearestStoreName", "Nearest store"),
                   proj_avg("CustomerNearestStore", "DistanceKm", "Distance km"),
                   proj_column("CustomerNearestStore", "NearestIsHomeStore", "Nearest = home?"),
               ]},
               title_text="Per-customer nearest-store assignment"),
    ]


def page_sql_regions():
    return "PageSqlRegions", "4. Point-in-polygon (STIntersects)", [
        textbox("tbSqlRegions", 16, 12, 1248, 104, [
            {"text": "STIntersects, STArea, and the STCentroid trap  ",
             "size": 18, "bold": True, "colour": ACCENT},
            {"text": "dbo.vw_StoreRegionCheck joins each store to a region by "
                     "GEOMETRY - ON b.Boundary.STIntersects(s.GeoPoint) = 1 - a "
                     "join on shape rather than on a key. STArea() returns square "
                     "metres. The gotcha worth the page: geography has no "
                     "STCentroid() (that is geometry-only, and calling it fails "
                     "with Msg 6506), so the centre points below come from "
                     "EnvelopeCenter() instead. The centres are plotted on a "
                     "scatter rather than a map on purpose: Azure Maps geocodes "
                     "whatever is in its Location field, and \"South\" is not a "
                     "place - it lands in the Atlantic.", "size": 11},
        ]),
        visual("cardStoresChecked", "card", 16, 124, 300, 104,
               roles={"Values": [proj_measure("StoreRegionCheck", "Stores Checked")]},
               title_text="Stores checked"),
        visual("cardMismatches", "card", 328, 124, 300, 104,
               roles={"Values": [proj_measure("StoreRegionCheck", "Region Mismatches")]},
               title_text="Region mismatches"),
        visual("cardRegionCount", "card", 640, 124, 300, 104,
               roles={"Values": [proj_measure("RegionBoundaries", "Region Count")]},
               title_text="Region polygons"),
        # Sourced from RegionBoundaries (4 rows), NOT StoreRegionCheck (8 rows,
        # each area repeated twice).
        visual("cardArea", "card", 952, 124, 312, 104,
               roles={"Values": [proj_measure("RegionBoundaries", "Total Region Area SqKm")]},
               title_text="Total area (sq km)"),
        # A scatter, not an azureMap, and the reason is worth knowing.
        #
        # Azure Maps resolves position from its Location bucket - the role this
        # generator calls Category - and in this hand-authored binding the
        # Latitude and Longitude roles did not override it. With RegionName in
        # Location, Power BI geocoded the words "East", "North", "South" and
        # "West": the South bubble landed in the middle of the Atlantic while
        # the four real EnvelopeCenter coordinates sat unused. Silently - no
        # error, no warning, just a wrong map. Dropping Location instead makes
        # the visual render zero marks, so there is no coordinates-only mode to
        # fall back to.
        #
        # A scatter plots longitude and latitude as plain numbers, so nothing
        # gets geocoded and the points are exactly where the geography column
        # says they are. Page 1 keeps a real Azure map because its Location
        # field is City, which geocodes to the right place.
        visual("scatterRegionCentres", "scatterChart", 16, 244, 620, 270,
               roles={
                   "Category": [proj_column("RegionBoundaries", "RegionName", "Region")],
                   "X": [proj_avg("RegionBoundaries", "CenterLongitude", "Longitude")],
                   "Y": [proj_avg("RegionBoundaries", "CenterLatitude", "Latitude")],
                   "Series": [proj_column("RegionBoundaries", "RegionName", "Region")],
               },
               title_text="Region centres from EnvelopeCenter(), longitude x latitude"),
        visual("chartArea", "clusteredColumnChart", 16, 522, 620, 182,
               roles={
                   "Category": [proj_column("RegionBoundaries", "RegionName", "Region")],
                   "Y": [proj_sum("RegionBoundaries", "AreaSqKm", "Area sq km")],
               },
               title_text="Polygon area by region"),
        visual("tblRegionCheck", "tableEx", 648, 244, 616, 226,
               roles={"Values": [
                   proj_column("StoreRegionCheck", "StoreName", "Store"),
                   proj_column("StoreRegionCheck", "AssignedRegion", "Assigned"),
                   proj_column("StoreRegionCheck", "ContainingRegion", "Contains the point"),
                   proj_column("StoreRegionCheck", "Result"),
               ]},
               title_text="Assigned region vs the polygon that contains the point"),
        visual("tblRegionWkt", "tableEx", 648, 478, 616, 226,
               roles={"Values": [
                   proj_column("RegionBoundaries", "RegionName", "Region"),
                   proj_sum("RegionBoundaries", "PointCount", "Points"),
                   proj_sum("RegionBoundaries", "AreaSqKm", "Area sq km"),
                   proj_column("RegionBoundaries", "WellKnownText", "Polygon WKT"),
               ]},
               title_text="Polygon WKT, area and vertex count"),
    ]


def page_sql_adventureworks():
    return "PageSqlAdventureWorks", "5. Real geography column (Import)", [
        textbox("tbSqlAw", 16, 12, 1248, 104, [
            {"text": "A genuine Microsoft geography column  ", "size": 18,
             "bold": True, "colour": ACCENT},
            {"text": "Person.Address.SpatialLocation in AdventureWorks2022 is a "
                     "real geography column in a Microsoft sample database, not "
                     "demo data - and dbo.vw_AdventureWorksAddresses projects it "
                     "with exactly the same .Lat / .Long pattern as page 1, so "
                     "the technique generalises. This is also the only Import "
                     "table in the model, which is what makes the storage mode "
                     "read Mixed.", "size": 11},
        ]),
        visual("cardAwCount", "card", 16, 124, 300, 104,
               roles={"Values": [proj_measure("AdventureWorksAddresses", "Address Count")]},
               title_text="Addresses"),
        visual("cardAwCountries", "card", 328, 124, 300, 104,
               roles={"Values": [proj_measure("AdventureWorksAddresses", "Country Count")]},
               title_text="Countries / regions"),
        visual("cardAwCities", "card", 640, 124, 300, 104,
               roles={"Values": [proj_measure("AdventureWorksAddresses", "City Count")]},
               title_text="Cities"),
        textbox("tbAwMode", 952, 124, 312, 104, [
            {"text": "Import. ", "size": 11, "bold": True, "colour": ACCENT},
            {"text": "Data view shows its 19,614 rows; the six DirectQuery "
                     "tables say \"DirectQuery tables can't be shown\". Stop the "
                     "SQL Server service and pages 1-4 go red while this one "
                     "keeps rendering.", "size": 10},
        ]),
        # No Size role: binding a measure into azureMap's Size is one step off
        # the shape proven elsewhere in this file, and it buys nothing here.
        visual("mapAw", "azureMap", 16, 244, 760, 460,
               roles={
                   "Category": [proj_column("AdventureWorksAddresses", "City")],
                   "Latitude": [proj_avg("AdventureWorksAddresses", "Latitude", "Latitude")],
                   "Longitude": [proj_avg("AdventureWorksAddresses", "Longitude", "Longitude")],
               },
               title_text="19,614 addresses across three continents"),
        visual("chartAwCountry", "columnChart", 788, 244, 476, 226,
               roles={
                   "Category": [proj_column("AdventureWorksAddresses", "CountryRegion",
                                            "Country / region")],
                   "Y": [proj_measure("AdventureWorksAddresses", "Address Count")],
               },
               title_text="Addresses by country"),
        # Deliberate redundancy: the same footprint with no Azure Maps
        # dependency, so a blocked tenant or firewall degrades the page instead
        # of emptying it.
        visual("scatterAwFallback", "scatterChart", 788, 478, 476, 226,
               roles={
                   "Category": [proj_column("AdventureWorksAddresses", "City")],
                   "X": [proj_avg("AdventureWorksAddresses", "Longitude", "Longitude")],
                   "Y": [proj_avg("AdventureWorksAddresses", "Latitude", "Latitude")],
                   "Series": [proj_column("AdventureWorksAddresses", "CountryRegion", "Country")],
               },
               title_text="The same points without Azure Maps"),
    ]


# Two registries, never one dict. main() derives both the page set and its order
# from list(...), so appending these keys to the demos registry would silently
# ship five extra pages inside PL300-Demos.
DEMO_PAGES = {
    "overview": page_overview,
    "python": page_python,
    "r": page_r,
    "rforecast": page_r_forecast,
    "spatial": page_spatial,
}

SQL_PAGES = {
    "stores": page_sql_stores,
    "catchment": page_sql_catchment,
    "nearest": page_sql_nearest,
    "regions": page_sql_regions,
    "adventureworks": page_sql_adventureworks,
}


def write_report_pbir(report_dir, page_keys, write_json_fn, builders):
    """
    Emit the PBIR `definition/` tree and return the page names in order.

    write_json_fn is the module's write_json, passed in to keep this function
    free of import-order concerns. `builders` is the solution's page registry,
    passed rather than read from a global so the two solutions cannot leak into
    each other.
    """
    definition = report_dir / "definition"
    page_names = []

    for key in page_keys:
        page_name, display_name, visuals = builders[key]()
        page_names.append(page_name)
        page_dir = definition / "pages" / page_name

        write_json_fn(page_dir / "page.json", {
            "$schema": PAGE_SCHEMA,
            "name": page_name,
            "displayName": display_name,
            "displayOption": "FitToPage",
            "width": PAGE_W,
            "height": PAGE_H,
        })
        for v in visuals:
            write_json_fn(page_dir / "visuals" / v["name"] / "visual.json", v)

    write_json_fn(definition / "pages" / "pages.json", {
        "$schema": PAGES_SCHEMA,
        "pageOrder": page_names,
        "activePageName": page_names[0],
    })
    write_json_fn(definition / "version.json", {
        "$schema": VERSION_SCHEMA,
        "version": "1.0.0",
    })
    write_json_fn(definition / "report.json", {
        "$schema": REPORT_DEF_SCHEMA,
        # An empty themeCollection is deliberate and schema-valid (baseTheme and
        # customTheme are both optional). Omitting the member entirely made the
        # legacy renderer die with "TypeError: Cannot read properties of
        # undefined (reading 'customTheme')"; an empty object lets Power BI apply
        # its built-in default theme without us naming a base theme version.
        "themeCollection": {},
        # Required by the schema. "None" = no mobile-specific layout.
        "layoutOptimization": "None",
    })
    return page_names


# --------------------------------------------------------------------------- #
# Driver
# --------------------------------------------------------------------------- #

def platform_file(kind, display, logical_id):
    return {
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/"
                   "platformProperties/2.0.0/schema.json",
        "metadata": {"type": kind, "displayName": display},
        "config": {"version": "2.0", "logicalId": logical_id},
    }


def write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")


@dataclass
class Solution:
    """One generated .pbip project. Everything that differs between them."""
    name: str
    logical_ids: dict
    pages: dict
    model_builder: object
    needs_sql_dir: bool = False
    emit_scripts: bool = False
    extra_dirs: tuple = ()
    extra_files: tuple = ()

    def owned(self):
        """(directories, files) under --out that this solution may delete."""
        return ([f"{self.name}.Report", f"{self.name}.SemanticModel", *self.extra_dirs],
                [f"{self.name}.pbip", *self.extra_files])


SOLUTIONS = {
    # Inline #table literals. Opens with no data source and no credential
    # prompt, which is what makes it safe to hand out and to validate
    # automatically.
    "demos": Solution(
        name="PL300-Demos",
        logical_ids={"report": "6f1d2b7a-3c4e-4a51-9b0d-7e2f8a1c4d55",
                     "model": "b28c7f14-9a3d-4e62-8f07-1c5d93ab6e20"},
        pages=DEMO_PAGES,
        model_builder=build_demo_model,
        needs_sql_dir=True,
        emit_scripts=True,
        extra_dirs=("scripts",),
        extra_files=("LIVE-SQL-QUERIES.md",),
    ),
    # Live Sql.Database against PL300Demo. Prompts for credentials on first
    # open, and needs the demo VM (or a reachable copy of that database).
    "spatial-sql": Solution(
        name="PL300-Spatial-SQL",
        logical_ids={"report": "e9cea732-bd54-47ed-9655-1a1c3d9f100d",
                     "model": "ef1fab1a-5e48-4dae-82fa-29f384b7c637"},
        pages=SQL_PAGES,
        model_builder=build_sql_model,
    ),
}


def _check_solutions():
    """
    No two solutions may claim the same path or the same logicalId.

    Paths matter because generating one solution deletes what it owns, and
    `scripts` and `LIVE-SQL-QUERIES.md` are not name-prefixed - a second
    solution claiming either would silently eat the first's files.

    logicalId matters because it is the item key for Fabric git integration, not
    the folder name. Duplicating one produces a tree that validates, opens fine
    in Desktop, and only breaks on sync, where the second item overwrites the
    first. Nothing else in the toolchain checks this.
    """
    paths, ids = {}, {}
    for key, sol in SOLUTIONS.items():
        dirs, files = sol.owned()
        for p in dirs + files:
            if p in paths:
                raise SystemExit(f"solutions {paths[p]!r} and {key!r} both own {p!r}")
            paths[p] = key
        for gid in sol.logical_ids.values():
            if gid in ids:
                raise SystemExit(f"solutions {ids[gid]!r} and {key!r} share logicalId {gid}")
            ids[gid] = key


_check_solutions()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--solution", default="demos", choices=sorted(SOLUTIONS),
                    help="demos = inline literals, no credential prompt; "
                         "spatial-sql = live DirectQuery against PL300Demo")
    ap.add_argument("--out", default="powerbi")
    ap.add_argument("--demo-data", default="demo-data")
    ap.add_argument("--sql-dir",
                    help="directory holding stores.csv, catchment.csv, customers.csv "
                         "exported from the PL300Demo spatial views. Required for "
                         "--solution demos; unused by spatial-sql, which reads the "
                         "views live")
    ap.add_argument("--pages", default="all",
                    help="comma-separated subset of the chosen solution's pages")
    ap.add_argument("--pbir", action="store_true",
                    help="declare definition.pbir version 4.0 so Power BI reads the "
                         "PBIR definition/ folder. REQUIRES the 'Store reports using "
                         "enhanced metadata format (PBIR)' preview feature to be enabled "
                         "in Power BI Desktop; without it a 4.0 project does not open at "
                         "all. Default (1.0) makes Desktop read report.json, which works "
                         "on a stock install.")
    args = ap.parse_args()

    sol = SOLUTIONS[args.solution]
    out = Path(args.out).resolve()
    demo_data = Path(args.demo_data).resolve()

    sources = {}
    if sol.needs_sql_dir:
        if not args.sql_dir:
            ap.error(f"--sql-dir is required for --solution {args.solution}")
        sql_dir = Path(args.sql_dir).resolve()
        sources["stores"] = read_pipe_csv(
            sql_dir / "stores.csv",
            ["StoreID", "StoreName", "City", "State", "RegionName",
             "Latitude", "Longitude", "WellKnownText"])
        sources["catchment"] = read_pipe_csv(
            sql_dir / "catchment.csv",
            ["StoreID", "StoreName", "RegionName", "CustomersWithin25km",
             "CustomersWithin50km", "CustomersWithin100km", "CustomersTotal"])
        sources["customers"] = read_pipe_csv(
            sql_dir / "customers.csv",
            ["CustomerID", "HomeStoreID", "StoreName", "RegionName",
             "LoyaltyTier", "Latitude", "Longitude", "DistanceToHomeStoreKm"])
        for name in ("stores", "catchment", "customers"):
            if not sources[name]:
                raise SystemExit(f"No rows read from {name}.csv - check --sql-dir")
        (sources["categories"], sources["monthly"],
         sources["cat_monthly"]) = load_contoso_aggregates(demo_data)

    page_keys = list(sol.pages) if args.pages == "all" else \
        [p.strip() for p in args.pages.split(",") if p.strip()]
    for p in page_keys:
        if p not in sol.pages:
            raise SystemExit(f"Unknown page '{p}' for --solution {args.solution}. "
                             f"Choose from: {', '.join(sol.pages)}")

    # Remove only what THIS solution owns. A blanket rmtree(out) would delete
    # hand-written files that live alongside the generated ones - it silently ate
    # powerbi/README.md once - and would now also delete the sibling solution.
    owned_dirs, owned_files = sol.owned()
    for owned in owned_dirs:
        target = out / owned
        if target.exists():
            shutil.rmtree(target)
    for owned in owned_files:
        target = out / owned
        if target.exists():
            target.unlink()

    report_dir = out / f"{sol.name}.Report"
    model_dir = out / f"{sol.name}.SemanticModel"

    # Power BI Desktop validates these $schema values against a regex and refuses
    # the project outright if they do not match. The exact patterns it expects
    # (surfaced in its own "Issues were found" dialog) are:
    #   .pbip            ^.../fabric/pbip/pbipProperties/1.[0-9]+.[0-9]+/schema.json$
    #   definition.pbir  ^.../fabric/item/report/definitionProperties/1.[0-9]+.[0-9]+/schema.json$
    #   definition.pbism ^.../fabric/item/semanticModel/definitionProperties/1.[0-9]+.[0-9]+/...
    write_json(out / f"{sol.name}.pbip", {
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/pbip/"
                   "pbipProperties/1.0.0/schema.json",
        "version": "1.0",
        "artifacts": [{"report": {"path": f"{sol.name}.Report"}}],
        "settings": {"enableAutoRecovery": True},
    })

    write_json(model_dir / "definition.pbism", {
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/semanticModel/"
                   "definitionProperties/1.0.0/schema.json",
        "version": "4.0",
        "settings": {},
    })
    write_json(model_dir / ".platform",
               platform_file("SemanticModel", sol.name, sol.logical_ids["model"]))
    live_sql_docs = []
    model = sol.model_builder(sources, live_sql_docs)
    write_json(model_dir / "model.bim", model)

    # Version 4.0 (+ the 2.0.0 schema) is what lets Power BI read the PBIR
    # definition/ folder - but ONLY when the PBIR preview feature is enabled. On a
    # stock install a 4.0 project silently fails to open: Power BI starts a blank
    # "Untitled" report instead. Version 1.0 is therefore the default, which makes
    # Desktop read report.json. Pass --pbir once you have enabled the preview
    # feature; the definition/ folder is emitted and schema-validated either way.
    if args.pbir:
        pbir_props = {
            "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/"
                       "definitionProperties/2.0.0/schema.json",
            "version": "4.0",
        }
    else:
        pbir_props = {
            "$schema": "https://developer.microsoft.com/json-schemas/fabric/item/report/"
                       "definitionProperties/1.0.0/schema.json",
            "version": "1.0",
        }
    pbir_props["datasetReference"] = {"byPath": {"path": f"../{sol.name}.SemanticModel"}}
    write_json(report_dir / "definition.pbir", pbir_props)
    write_json(report_dir / ".platform",
               platform_file("Report", sol.name, sol.logical_ids["report"]))
    page_names = write_report_pbir(report_dir, page_keys, write_json, sol.pages)
    # Also emit the legacy report.json. definition.pbir version 4.0 permits
    # either, and Power BI Desktop reads the definition/ folder only when the
    # PBIR preview feature is enabled - falling back to report.json otherwise.
    # Shipping both means the solution renders on a stock install today.
    write_json(report_dir / "report.json", build_report_legacy(page_keys, sol.pages))

    # Emit the script bodies as standalone files from the same constants the
    # report uses, so the two can never drift. They serve two purposes: a
    # teaching artifact the class can read, and a paste source for the R/Python
    # visuals while the report is in PBIR-Legacy form (where Power BI does not
    # load an externally-authored script body).
    if sol.emit_scripts:
        scripts_dir = out / "scripts"
        for filename, body, note in (
            ("python-category-revenue.py", PYTHON_SCRIPT,
             "Paste into the Python visual on page 2."),
            ("r-ggplot-category.R", R_GGPLOT_SCRIPT,
             "Paste into the R visual on page 3."),
            ("r-forecast-arima.R", R_FORECAST_SCRIPT,
             "Paste into the R visual on page 4."),
        ):
            comment = "#" if filename.endswith(".py") else "#"
            header = f"{comment} {note}\n{comment} Generated by scripts/generate-pbip.py - edit there, not here.\n\n"
            (scripts_dir / filename).parent.mkdir(parents=True, exist_ok=True)
            (scripts_dir / filename).write_text(header + body, encoding="utf-8")

    if live_sql_docs:
        doc = ["# Repointing the spatial tables at live SQL Server", "",
               "The spatial tables in this solution are materialised as inline M `#table`",
               "literals so the file opens with no data-source prompt and no credential",
               "setup. The rows are the real output of the `geography` views in the",
               "`PL300Demo` database on the demo VM.", "",
               "To read them live from SQL Server instead, open **Transform data**, select",
               "the query, and replace its `Source` step with the code below.", ""]
        for view, sql in live_sql_docs:
            doc += [f"## {view}", "", "```m", sql, "```", ""]
        doc += ["Every one of these queries projects `.Lat` / `.Long` / `.STAsText()` through",
                "a view rather than selecting the raw column, because **Power BI has no spatial",
                "data type**. The documented Power BI type list stops at Text, the number types,",
                "the date/time types, True/false, Binary and Blank; the tabular engine's list is",
                "the same. A `geography` value has nowhere to land.",
                "",
                "Microsoft does not document what the SQL Server connector *does* with such a",
                "column - the connector's limitations section covers only certificates, Always",
                "Encrypted and Entra ID - so treat the exact behaviour as unspecified rather",
                "than repeating a blog. What is certain is the type system, and that projecting",
                "to scalars in T-SQL sidesteps the question entirely.",
                "",
                "Project `.Lat` and `.Long` as named columns rather than parsing `.STAsText()`",
                "in Power Query: WKT is X-then-Y, so a geography point is `POINT(longitude",
                "latitude)` - the reverse of how people say it - and that mix-up plots data in",
                "the wrong hemisphere without erroring.",
                "",
                "## A better pattern than any of the above",
                "",
                "`[Query = \"SELECT ...\"]` is a *native query*: Power BI raises an approval",
                "dialog for every distinct query text, folding stops there, and incremental",
                "refresh cannot use it. Prefer navigating to the view and letting the engine",
                "generate the SQL:",
                "",
                "```m",
                'let',
                '    Source = Sql.Database("localhost", "PL300Demo"),',
                '    dbo_vw_StoreLocations = Source{[Schema="dbo",Item="vw_StoreLocations"]}[Data]',
                'in',
                '    dbo_vw_StoreLocations',
                "```",
                "",
                "`PL300-Spatial-SQL.pbip` is built entirely this way - see",
                "[README.md](README.md).",
                ""]
        (out / "LIVE-SQL-QUERIES.md").write_text("\n".join(doc), encoding="utf-8")

    # Scoped to this solution's own paths: an unscoped rglob over --out would
    # count the sibling solution's files as if this run had written them.
    files = sorted(
        p for owned in owned_dirs + owned_files
        for p in ([out / owned] if (out / owned).is_file()
                  else (out / owned).rglob("*"))
        if p.is_file())
    total = sum(p.stat().st_size for p in files)
    modes = {t["partitions"][0]["mode"] for t in model["model"]["tables"]}
    print(f"solution: {sol.name} ({args.solution}), storage "
          f"{'/'.join(sorted(modes))}")
    print(f"pages   : {', '.join(page_names)}")
    print(f"tables  : " + ", ".join(t["name"] for t in model["model"]["tables"]))
    print(f"written : {len(files)} files, {total/1024:.1f} KB -> {out}")
    for f in files:
        print(f"          {f.relative_to(out)}")




# --------------------------------------------------------------------------- #
# Report (PBIR-Legacy)
# --------------------------------------------------------------------------- #
#
# Emitted ALONGSIDE the PBIR definition/ folder, derived from the same page
# builders so there is only one description of the layout.
#
# Why both: PBIR is the correct, documented, schema-validated format - but Power
# BI Desktop only reads the definition/ folder once the "Store reports using
# enhanced metadata format (PBIR)" preview feature is switched on. With it off,
# a PBIR-only project opens with the model loaded and ZERO pages. report.json is
# the format Desktop falls back to, so shipping both means the solution renders
# on a stock install and upgrades cleanly the moment the toggle is flipped.
#
# Known limitation of the legacy path, and the reason PBIR exists: Power BI
# silently discards `objects` on non-textbox visuals here, so visual titles fall
# back to auto-generated ones and R/Python script bodies do not load. The Python
# and R pages therefore need either the PBIR toggle or a one-time paste of the
# matching file from powerbi/scripts/.

def _legacy_select(field, alias, native=None):
    """Translate one PBIR field reference into a legacy prototypeQuery Select."""
    if "Column" in field:
        prop = field["Column"]["Property"]
        entity = field["Column"]["Expression"]["SourceRef"]["Entity"]
        out = {"Column": {"Expression": {"SourceRef": {"Source": alias}}, "Property": prop},
               "Name": f"{entity}.{prop}"}
    elif "Measure" in field:
        prop = field["Measure"]["Property"]
        entity = field["Measure"]["Expression"]["SourceRef"]["Entity"]
        out = {"Measure": {"Expression": {"SourceRef": {"Source": alias}}, "Property": prop},
               "Name": f"{entity}.{prop}"}
    elif "Aggregation" in field:
        inner = field["Aggregation"]["Expression"]["Column"]
        prop = inner["Property"]
        entity = inner["Expression"]["SourceRef"]["Entity"]
        func = field["Aggregation"]["Function"]
        fname = {0: "Sum", 1: "Avg", 2: "Min", 3: "Max", 4: "Count"}.get(func, "Sum")
        out = {"Aggregation": {"Expression": {"Column": {
                   "Expression": {"SourceRef": {"Source": alias}}, "Property": prop}},
               "Function": func},
               "Name": f"{fname}({entity}.{prop})"}
    else:
        raise ValueError(f"unsupported field shape: {list(field)}")
    if native:
        out["NativeReferenceName"] = native
    return out


def _field_entity(field):
    for kind in ("Column", "Measure"):
        if kind in field:
            return field[kind]["Expression"]["SourceRef"]["Entity"]
    return field["Aggregation"]["Expression"]["Column"]["Expression"]["SourceRef"]["Entity"]


def pbir_visual_to_legacy(v):
    """Convert one PBIR visual.json dict into a legacy visualContainer."""
    pos = v["position"]
    vis = v["visual"]
    single = {"visualType": vis["visualType"], "drillFilterOtherVisuals": True}

    qs = vis.get("query", {}).get("queryState", {})
    if qs:
        # One From alias per distinct entity, stable across roles.
        aliases, selects, projections = {}, [], {}
        for role, state in qs.items():
            projections[role] = []
            for p in state["projections"]:
                entity = _field_entity(p["field"])
                if entity not in aliases:
                    aliases[entity] = f"e{len(aliases)}"
                sel = _legacy_select(p["field"], aliases[entity], p.get("nativeQueryRef"))
                if not any(s["Name"] == sel["Name"] for s in selects):
                    selects.append(sel)
                projections[role].append({"queryRef": sel["Name"]})
        single["projections"] = projections
        single["prototypeQuery"] = {
            "Version": 2,
            "From": [{"Name": a, "Entity": e, "Type": 0} for e, a in aliases.items()],
            "Select": selects,
        }

    # Only `objects` survives here; visualContainerObjects (titles) does not.
    if vis.get("objects"):
        single["objects"] = vis["objects"]

    config = {
        "name": v["name"],
        "layouts": [{"id": 0, "position": dict(pos)}],
        "singleVisual": single,
    }
    return {
        "x": pos["x"], "y": pos["y"], "z": pos.get("z", 0),
        "width": pos["width"], "height": pos["height"],
        "config": json.dumps(config, separators=(",", ":")),
        "filters": "[]",
    }


def build_report_legacy(page_keys, builders):
    sections = []
    for i, key in enumerate(page_keys):
        page_name, display_name, visuals = builders[key]()
        sections.append({
            "name": page_name,
            "displayName": display_name,
            "ordinal": i,
            "width": PAGE_W,
            "height": PAGE_H,
            "displayOption": 1,
            "filters": "[]",
            # Collapse the Filters pane; it steals canvas and is noise on a projector.
            "config": json.dumps({"objects": {"outspacePane": [
                {"properties": {"expanded": {"expr": {"Literal": {"Value": "false"}}},
                                "visible": {"expr": {"Literal": {"Value": "false"}}}}}]}},
                separators=(",", ":")),
            "visualContainers": [pbir_visual_to_legacy(v) for v in visuals],
        })

    report_config = {
        "version": "5.43",
        # Required: omitting themeCollection makes the legacy renderer throw
        # "TypeError: Cannot read properties of undefined (reading 'customTheme')".
        "themeCollection": {},
        "activeSectionIndex": 0,
        "defaultDrillFilterOtherVisuals": True,
        "settings": {
            "useStylableVisualContainerHeader": True,
            "allowChangeFilterTypes": True,
            "useNewFilterPaneExperience": True,
            "useEnhancedTooltips": True,
        },
    }
    return {
        "config": json.dumps(report_config, separators=(",", ":")),
        "layoutOptimization": 0,
        "publicCustomVisuals": [],
        "sections": sections,
    }


if __name__ == "__main__":
    main()
