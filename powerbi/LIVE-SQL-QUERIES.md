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

Power BI cannot consume a `geography` column directly - it arrives as an
unusable binary value - which is why every one of these queries selects
`.Lat` / `.Long` / `.STAsText()` through a view rather than the raw column.
