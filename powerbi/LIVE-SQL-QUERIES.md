# Repointing the spatial tables at live SQL Server

The spatial tables in this solution are materialised as inline M `#table`
literals so the file opens with no data-source prompt and no credential
setup. The rows are the real output of the `geography` views in the
`PL300Demo` database on the demo VM.

To read them live from SQL Server instead, open **Transform data**, select
the query, and replace its `Source` step with the code below.

## dbo.vw_StoreLocations + dbo.vw_StoreCatchment

```m
Source = Sql.Database("localhost", "PL300Demo",
    [Query = "SELECT s.StoreID, s.StoreName, s.City, s.[State], s.RegionName,
                     s.Latitude, s.Longitude, s.WellKnownText,
                     c.CustomersWithin25km, c.CustomersWithin50km, c.CustomersWithin100km
              FROM dbo.vw_StoreLocations s
              JOIN dbo.vw_StoreCatchment c ON c.StoreID = s.StoreID"])
```

## dbo.vw_CustomerLocations

```m
Source = Sql.Database("localhost", "PL300Demo",
    [Query = "SELECT c.CustomerID, c.HomeStoreID, s.StoreName, s.RegionName,
                     c.LoyaltyTier, c.Latitude, c.Longitude,
                     c.DistanceToHomeStoreKm AS DistanceKm
              FROM dbo.vw_CustomerLocations c
              JOIN dbo.vw_StoreLocations s ON s.StoreID = c.HomeStoreID"])
```

Every one of these queries projects `.Lat` / `.Long` / `.STAsText()` through
a view rather than selecting the raw column, because **Power BI has no spatial
data type**. The documented Power BI type list stops at Text, the number types,
the date/time types, True/false, Binary and Blank; the tabular engine's list is
the same. A `geography` value has nowhere to land.

Microsoft does not document what the SQL Server connector *does* with such a
column - the connector's limitations section covers only certificates, Always
Encrypted and Entra ID - so treat the exact behaviour as unspecified rather
than repeating a blog. What is certain is the type system, and that projecting
to scalars in T-SQL sidesteps the question entirely.

Project `.Lat` and `.Long` as named columns rather than parsing `.STAsText()`
in Power Query: WKT is X-then-Y, so a geography point is `POINT(longitude
latitude)` - the reverse of how people say it - and that mix-up plots data in
the wrong hemisphere without erroring.

## A better pattern than any of the above

`[Query = "SELECT ..."]` is a *native query*: Power BI raises an approval
dialog for every distinct query text, folding stops there, and incremental
refresh cannot use it. Prefer navigating to the view and letting the engine
generate the SQL:

```m
let
    Source = Sql.Database("localhost", "PL300Demo"),
    dbo_vw_StoreLocations = Source{[Schema="dbo",Item="vw_StoreLocations"]}[Data]
in
    dbo_vw_StoreLocations
```

`PL300-Spatial-SQL.pbip` is built entirely this way - see
[README.md](README.md).
