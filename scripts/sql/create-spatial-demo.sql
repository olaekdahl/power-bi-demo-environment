/* ---------------------------------------------------------------------------
   PL-300 demo: SQL Server spatial data types.

   Creates a PL300Demo database containing geography points and polygons, a
   spatial index, and views shaped for Power BI.

   Why a separate database: AdventureWorks stays pristine so it still matches the
   Microsoft documentation the class will read. The one thing we borrow from it is
   Person.Address.SpatialLocation, which is a real geography column, exposed
   through a view here.

   The coordinates and region bounding boxes match
   scripts/generate-demo-data.py, so the SQL results agree with the CSV, GeoJSON
   and TopoJSON files in C:\PL300\Data\Spatial.

   Invoked as:
     sqlcmd -S localhost -U pl300sql -P ... -b -i create-spatial-demo.sql

   Idempotent: safe to re-run. Objects are dropped and recreated; the database is
   only created if missing.
   --------------------------------------------------------------------------- */

:on error exit
SET NOCOUNT ON;
GO

/* Spatial indexes require a specific set of session options, and sqlcmd does NOT
   default to them the way SSMS does - in particular sqlcmd runs with
   QUOTED_IDENTIFIER OFF, which makes CREATE SPATIAL INDEX fail with:

     Msg 1934 ... CREATE INDEX failed because the following SET options have
     incorrect settings: 'QUOTED_IDENTIFIER'

   Set them explicitly so this script works under sqlcmd, SSMS, or anything else.
   (bootstrap.ps1 also passes sqlcmd -I, but do not rely on the caller.) */
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

IF DB_ID(N'PL300Demo') IS NULL
BEGIN
    PRINT 'Creating database PL300Demo';
    CREATE DATABASE [PL300Demo];
END
ELSE
    PRINT 'Database PL300Demo already exists';
GO

ALTER DATABASE [PL300Demo] SET RECOVERY SIMPLE WITH NO_WAIT;
GO

USE [PL300Demo];
GO

/* Drop in reverse dependency order. CustomerLocation carries a FOREIGN KEY to
   StoreLocation, so dropping the parent first fails with:
     Msg 3726 ... Could not drop object 'dbo.StoreLocation' because it is
     referenced by a FOREIGN KEY constraint
   This block is what makes re-running the script safe, including after a
   partially failed run. */
DROP TABLE IF EXISTS dbo.CustomerLocation;
DROP TABLE IF EXISTS dbo.StoreLocation;
DROP TABLE IF EXISTS dbo.RegionBoundary;
GO

/* --------------------------------------------------------------------------
   Stores as geography points.

   NOTE the argument order: geography::Point(latitude, longitude, SRID).
   Everything else in the GIS world says "long, lat" - including the WKT this
   produces - and getting it backwards is the single most common spatial mistake.
   4326 is WGS 84, the SRID Power BI and web maps expect.
   -------------------------------------------------------------------------- */

CREATE TABLE dbo.StoreLocation (
    StoreID    int          NOT NULL PRIMARY KEY,
    StoreName  nvarchar(50) NOT NULL,
    City       nvarchar(50) NOT NULL,
    [State]    char(2)      NOT NULL,
    RegionID   int          NOT NULL,
    RegionName nvarchar(20) NOT NULL,
    GeoPoint   geography    NOT NULL
);

INSERT INTO dbo.StoreLocation (StoreID, StoreName, City, [State], RegionID, RegionName, GeoPoint)
VALUES
    (1, N'Contoso Bellevue',     N'Bellevue',     'WA', 4, N'West',  geography::Point(47.6104, -122.2007, 4326)),
    (2, N'Contoso Portland',     N'Portland',     'OR', 4, N'West',  geography::Point(45.5152, -122.6784, 4326)),
    (3, N'Contoso Denver',       N'Denver',       'CO', 1, N'North', geography::Point(39.7392, -104.9903, 4326)),
    (4, N'Contoso Minneapolis',  N'Minneapolis',  'MN', 1, N'North', geography::Point(44.9778,  -93.2650, 4326)),
    (5, N'Contoso Austin',       N'Austin',       'TX', 2, N'South', geography::Point(30.2672,  -97.7431, 4326)),
    (6, N'Contoso Atlanta',      N'Atlanta',      'GA', 2, N'South', geography::Point(33.7490,  -84.3880, 4326)),
    (7, N'Contoso Boston',       N'Boston',       'MA', 3, N'East',  geography::Point(42.3601,  -71.0589, 4326)),
    (8, N'Contoso Philadelphia', N'Philadelphia', 'PA', 3, N'East',  geography::Point(39.9526,  -75.1652, 4326));
GO

/* --------------------------------------------------------------------------
   Sales regions as geography polygons.

   Ring order matters. geography follows the left-hand rule, so the interior is
   whatever lies to the left as you walk the ring. Reverse the vertices and you
   describe the entire planet minus this box - queries still "work", they just
   return nonsense. These rings are counter-clockwise, and the sanity check below
   reorients anything that slipped through.
   -------------------------------------------------------------------------- */

CREATE TABLE dbo.RegionBoundary (
    RegionID   int          NOT NULL PRIMARY KEY,
    RegionName nvarchar(20) NOT NULL,
    Boundary   geography    NOT NULL
);

INSERT INTO dbo.RegionBoundary (RegionID, RegionName, Boundary)
VALUES
    (1, N'North', geography::STGeomFromText(
        'POLYGON((-115.0 38.5, -87.0 38.5, -87.0 49.5, -115.0 49.5, -115.0 38.5))', 4326)),
    (2, N'South', geography::STGeomFromText(
        'POLYGON((-107.0 24.0, -75.0 24.0, -75.0 38.5, -107.0 38.5, -107.0 24.0))', 4326)),
    (3, N'East',  geography::STGeomFromText(
        'POLYGON((-80.5 38.5, -66.0 38.5, -66.0 48.0, -80.5 48.0, -80.5 38.5))', 4326)),
    (4, N'West',  geography::STGeomFromText(
        'POLYGON((-125.0 32.0, -115.0 32.0, -115.0 49.5, -125.0 49.5, -125.0 32.0))', 4326));
GO

/* Earth's surface is roughly 5.1e14 m2. Any "region" bigger than 1e14 m2 is the
   inverted complement, which means the ring was wound the wrong way. */
UPDATE dbo.RegionBoundary
SET Boundary = Boundary.ReorientObject()
WHERE Boundary.STArea() > 1.0E14;

IF @@ROWCOUNT > 0
    PRINT 'Reoriented one or more region polygons that were wound clockwise.';
GO

/* --------------------------------------------------------------------------
   Customers around each store, for distance and catchment demos.

   Offsets are a deterministic function of the row number rather than RAND(), so
   re-running this script produces identical data and the demo numbers in the
   guide stay true. Every point stays inside its store's region polygon.
   -------------------------------------------------------------------------- */

CREATE TABLE dbo.CustomerLocation (
    CustomerKey  int          NOT NULL PRIMARY KEY,
    CustomerID   varchar(10)  NOT NULL,
    HomeStoreID  int          NOT NULL REFERENCES dbo.StoreLocation(StoreID),
    LoyaltyTier  nvarchar(10) NOT NULL,
    GeoPoint     geography    NOT NULL
);

WITH n AS (
    SELECT TOP (60) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS i
    FROM sys.all_objects
)
INSERT INTO dbo.CustomerLocation (CustomerKey, CustomerID, HomeStoreID, LoyaltyTier, GeoPoint)
SELECT
    (s.StoreID - 1) * 60 + n.i                              AS CustomerKey,
    'C' + CAST(1000 + (s.StoreID - 1) * 60 + n.i AS varchar(10)) AS CustomerID,
    s.StoreID,
    CHOOSE(((n.i * 7) % 4) + 1, N'None', N'Silver', N'Gold', N'Platinum'),
    geography::Point(
        s.GeoPoint.Lat  + (((n.i * 37) % 91)  - 45) / 100.0,
        s.GeoPoint.Long + (((n.i * 53) % 111) - 55) / 100.0,
        4326)
FROM dbo.StoreLocation s
CROSS JOIN n;
GO

/* A spatial index is what makes STDistance / STIntersects filters usable at
   scale. GEOGRAPHY_AUTO_GRID lets SQL Server pick the grid densities. */
CREATE SPATIAL INDEX SIX_CustomerLocation_GeoPoint
    ON dbo.CustomerLocation(GeoPoint) USING GEOGRAPHY_AUTO_GRID;
GO

/* --------------------------------------------------------------------------
   Views for Power BI.

   Power BI's SQL Server connector cannot consume a `geography` column directly -
   it arrives as an unusable binary value. Always project what the report needs:
   .Lat and .Long for map visuals, .STAsText() when you want human-readable WKT.
   That projection is the whole point of these views.
   -------------------------------------------------------------------------- */

CREATE OR ALTER VIEW dbo.vw_StoreLocations
AS
SELECT
    s.StoreID,
    s.StoreName,
    s.City,
    s.[State],
    s.RegionID,
    s.RegionName,
    s.GeoPoint.Lat            AS Latitude,
    s.GeoPoint.Long           AS Longitude,
    s.GeoPoint.STAsText()     AS WellKnownText,
    /* City + State is what Power BI's built-in geocoding wants when you do not
       supply coordinates. */
    s.City + N', ' + s.[State] AS CityState
FROM dbo.StoreLocation AS s;
GO

CREATE OR ALTER VIEW dbo.vw_CustomerLocations
AS
SELECT
    c.CustomerKey,
    c.CustomerID,
    c.HomeStoreID,
    s.StoreName            AS HomeStoreName,
    s.RegionName,
    c.LoyaltyTier,
    c.GeoPoint.Lat         AS Latitude,
    c.GeoPoint.Long        AS Longitude,
    /* STDistance returns metres for geography. */
    ROUND(c.GeoPoint.STDistance(s.GeoPoint) / 1000.0, 2) AS DistanceToHomeStoreKm
FROM dbo.CustomerLocation AS c
JOIN dbo.StoreLocation    AS s ON s.StoreID = c.HomeStoreID;
GO

/* Nearest-store assignment: the classic spatial question, and a good CROSS APPLY
   example. Note this ignores HomeStoreID and works purely from geometry, so it
   can disagree with it - which is exactly the interesting part. */
CREATE OR ALTER VIEW dbo.vw_CustomerNearestStore
AS
SELECT
    c.CustomerID,
    c.HomeStoreID,
    nearest.StoreID    AS NearestStoreID,
    nearest.StoreName  AS NearestStoreName,
    nearest.DistanceKm,
    CASE WHEN nearest.StoreID = c.HomeStoreID THEN 'Yes' ELSE 'No' END AS NearestIsHomeStore
FROM dbo.CustomerLocation AS c
CROSS APPLY (
    SELECT TOP (1)
        s.StoreID,
        s.StoreName,
        ROUND(c.GeoPoint.STDistance(s.GeoPoint) / 1000.0, 2) AS DistanceKm
    FROM dbo.StoreLocation AS s
    ORDER BY c.GeoPoint.STDistance(s.GeoPoint)
) AS nearest;
GO

/* Point-in-polygon. STIntersects answers "is this store inside that region?"
   and should agree with the RegionID already on the store row. */
CREATE OR ALTER VIEW dbo.vw_StoreRegionCheck
AS
SELECT
    s.StoreID,
    s.StoreName,
    s.RegionName                                    AS AssignedRegion,
    b.RegionName                                    AS ContainingRegion,
    CASE WHEN s.RegionName = b.RegionName THEN 'Match' ELSE 'MISMATCH' END AS Result,
    ROUND(b.Boundary.STArea() / 1000000.0, 0)       AS RegionAreaSqKm
FROM dbo.StoreLocation  AS s
JOIN dbo.RegionBoundary AS b ON b.Boundary.STIntersects(s.GeoPoint) = 1;
GO

/* Catchment sizes, using a real buffer rather than a bounding box. */
CREATE OR ALTER VIEW dbo.vw_StoreCatchment
AS
SELECT
    s.StoreID,
    s.StoreName,
    s.RegionName,
    SUM(CASE WHEN c.GeoPoint.STDistance(s.GeoPoint) <=  25000 THEN 1 ELSE 0 END) AS CustomersWithin25km,
    SUM(CASE WHEN c.GeoPoint.STDistance(s.GeoPoint) <=  50000 THEN 1 ELSE 0 END) AS CustomersWithin50km,
    SUM(CASE WHEN c.GeoPoint.STDistance(s.GeoPoint) <= 100000 THEN 1 ELSE 0 END) AS CustomersWithin100km,
    COUNT(*)                                                                     AS CustomersTotal
FROM dbo.StoreLocation   AS s
CROSS JOIN dbo.CustomerLocation AS c
GROUP BY s.StoreID, s.StoreName, s.RegionName;
GO

/* Region polygons as WKT, so Power BI can at least show the boundary text and
   the Azure Maps visual can consume it. */
CREATE OR ALTER VIEW dbo.vw_RegionBoundaries
AS
SELECT
    b.RegionID,
    b.RegionName,
    b.Boundary.STAsText()                        AS WellKnownText,
    /* geometry has STCentroid(); geography does not - it fails with
         Msg 6506 ... Could not find method 'STCentroid' for type
         'Microsoft.SqlServer.Types.SqlGeography'
       EnvelopeCenter() is the geography equivalent. The two spatial types look
       interchangeable until you hit a method only one of them implements. */
    b.Boundary.EnvelopeCenter().Lat              AS CenterLatitude,
    b.Boundary.EnvelopeCenter().Long             AS CenterLongitude,
    ROUND(b.Boundary.STArea() / 1000000.0, 0)    AS AreaSqKm,
    b.Boundary.STNumPoints()                     AS PointCount
FROM dbo.RegionBoundary AS b;
GO

/* --------------------------------------------------------------------------
   AdventureWorks2022.Person.Address.SpatialLocation is a genuine geography
   column in a Microsoft sample database - worth showing because it is real data
   the class can go and read the docs about. Created dynamically so this script
   still succeeds if that database is missing.
   -------------------------------------------------------------------------- */

IF DB_ID(N'AdventureWorks2022') IS NOT NULL
BEGIN
    DECLARE @view nvarchar(max) = N'
CREATE OR ALTER VIEW dbo.vw_AdventureWorksAddresses
AS
SELECT
    a.AddressID,
    a.City,
    sp.Name                  AS StateProvince,
    sp.StateProvinceCode,
    cr.Name                  AS CountryRegion,
    a.PostalCode,
    a.SpatialLocation.Lat    AS Latitude,
    a.SpatialLocation.Long   AS Longitude
FROM AdventureWorks2022.Person.Address        AS a
JOIN AdventureWorks2022.Person.StateProvince  AS sp ON sp.StateProvinceID = a.StateProvinceID
JOIN AdventureWorks2022.Person.CountryRegion  AS cr ON cr.CountryRegionCode = sp.CountryRegionCode
WHERE a.SpatialLocation IS NOT NULL;';
    EXEC (@view);
    PRINT 'Created dbo.vw_AdventureWorksAddresses over Person.Address.SpatialLocation';
END
ELSE
    PRINT 'AdventureWorks2022 not present - skipping the SpatialLocation view';
GO

/* --------------------------------------------------------------------------
   Report what was built, and prove the spatial results are self-consistent.
   -------------------------------------------------------------------------- */

PRINT '--- Spatial demo objects ---';
SELECT
    (SELECT COUNT(*) FROM dbo.StoreLocation)     AS Stores,
    (SELECT COUNT(*) FROM dbo.RegionBoundary)    AS Regions,
    (SELECT COUNT(*) FROM dbo.CustomerLocation)  AS Customers;

PRINT '--- Point-in-polygon: every store should say Match ---';
SELECT Result, COUNT(*) AS Stores
FROM dbo.vw_StoreRegionCheck
GROUP BY Result;

/* Fail loudly rather than leave a broken demo in place: if a polygon were wound
   the wrong way, or a coordinate typo'd, this is what catches it. */
IF EXISTS (SELECT 1 FROM dbo.vw_StoreRegionCheck WHERE Result = 'MISMATCH')
    OR (SELECT COUNT(*) FROM dbo.vw_StoreRegionCheck) <> (SELECT COUNT(*) FROM dbo.StoreLocation)
BEGIN
    RAISERROR('Spatial validation failed: stores do not map 1:1 onto their assigned region polygon.', 16, 1);
END
GO

PRINT '--- Sample: nearest store vs assigned home store ---';
SELECT TOP (5) CustomerID, HomeStoreID, NearestStoreID, DistanceKm, NearestIsHomeStore
FROM dbo.vw_CustomerNearestStore
ORDER BY CustomerID;
GO
