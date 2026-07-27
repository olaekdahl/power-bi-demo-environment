/* ---------------------------------------------------------------------------
   PL-300 demo: restore one AdventureWorks backup.

   The Azure SQL Server marketplace image puts data and log files on a data
   disk (typically F:\ and G:\), not the paths recorded inside the Microsoft
   sample backups, so every file has to be relocated with MOVE.

   File names are read from the backup header. If the header layout doesn't
   match what we expect - the FILELISTONLY result set has gained columns
   between SQL Server versions before - we fall back to the documented logical
   names for these two sample databases.

   Invoked as:
     sqlcmd -S localhost -E -b -i restore-adventureworks.sql \
            -v DbName="AdventureWorksDW2022" BakFile="C:\PL300\Backups\AdventureWorksDW2022.bak"

   Idempotent: exits early if the database already exists.
   --------------------------------------------------------------------------- */

:on error exit
SET NOCOUNT ON;
GO

DECLARE @db      sysname        = N'$(DbName)';
DECLARE @bak     nvarchar(4000) = N'$(BakFile)';
DECLARE @dataDir nvarchar(4000) = CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(4000));
DECLARE @logDir  nvarchar(4000) = CAST(SERVERPROPERTY('InstanceDefaultLogPath')  AS nvarchar(4000));
DECLARE @move    nvarchar(max)  = N'';
DECLARE @sql     nvarchar(max);

IF DB_ID(@db) IS NOT NULL
BEGIN
    PRINT 'Database already exists, nothing to do: ' + @db;
    RETURN;
END

PRINT 'Restoring ' + @db + ' from ' + @bak;
PRINT '  data -> ' + @dataDir;
PRINT '  log  -> ' + @logDir;

CREATE TABLE #filelist (
    LogicalName          nvarchar(128),
    PhysicalName         nvarchar(260),
    [Type]               char(1),
    FileGroupName        nvarchar(128),
    [Size]               numeric(20, 0),
    [MaxSize]            numeric(20, 0),
    FileID               bigint,
    CreateLSN            numeric(25, 0),
    DropLSN              numeric(25, 0),
    UniqueID             uniqueidentifier,
    ReadOnlyLSN          numeric(25, 0),
    ReadWriteLSN         numeric(25, 0),
    BackupSizeInBytes    bigint,
    SourceBlockSize      int,
    FileGroupID          int,
    LogGroupGUID         uniqueidentifier,
    DifferentialBaseLSN  numeric(25, 0),
    DifferentialBaseGUID uniqueidentifier,
    IsReadOnly           bit,
    IsPresent            bit,
    TDEThumbprint        varbinary(32),
    SnapshotUrl          nvarchar(360)
);

BEGIN TRY
    INSERT INTO #filelist
    EXEC (N'RESTORE FILELISTONLY FROM DISK = ' + QUOTENAME(@bak, ''''));
END TRY
BEGIN CATCH
    PRINT 'Could not read the backup header (' + ERROR_MESSAGE() + ').';
    PRINT 'Falling back to the documented logical file names.';
    DELETE FROM #filelist;
    INSERT INTO #filelist (LogicalName, [Type], FileID)
    VALUES (@db, 'D', 1), (@db + N'_log', 'L', 2);
END CATCH

IF NOT EXISTS (SELECT 1 FROM #filelist)
BEGIN
    RAISERROR('No files found in backup %s', 16, 1, @bak);
    RETURN;
END

SELECT @move = @move
    + N', MOVE ' + QUOTENAME(LogicalName, '''') + N' TO '
    + QUOTENAME(
          CASE WHEN [Type] = 'L' THEN @logDir ELSE @dataDir END
          + @db + N'_' + CAST(FileID AS nvarchar(10))
          + CASE WHEN [Type] = 'L' THEN N'.ldf'
                 WHEN FileID = 1   THEN N'.mdf'
                 ELSE                   N'.ndf' END,
          '''')
FROM #filelist
ORDER BY FileID;

SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@db)
         + N' FROM DISK = ' + QUOTENAME(@bak, '''')
         + N' WITH RECOVERY, REPLACE, STATS = 25' + @move + N';';

PRINT @sql;
EXEC (@sql);
DROP TABLE #filelist;
GO

/* Post-restore housekeeping. SIMPLE recovery keeps the log from growing during
   a class, and the compatibility level is raised so demos can use modern
   T-SQL and the newer cardinality estimator. */
DECLARE @db  sysname       = N'$(DbName)';
DECLARE @sql nvarchar(max);

SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET RECOVERY SIMPLE WITH NO_WAIT;';
EXEC (@sql);

SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET COMPATIBILITY_LEVEL = 160;';
EXEC (@sql);

/* Without this the database owner is whichever account ran the restore, which
   makes ownership-chaining demos behave oddly. */
SET @sql = N'ALTER AUTHORIZATION ON DATABASE::' + QUOTENAME(@db) + N' TO [sa];';
EXEC (@sql);

SET @sql = N'ALTER DATABASE ' + QUOTENAME(@db) + N' SET AUTO_CREATE_STATISTICS ON, AUTO_UPDATE_STATISTICS ON;';
EXEC (@sql);
GO

DECLARE @db sysname = N'$(DbName)';
SELECT
    name                             AS DatabaseName,
    state_desc                       AS State,
    recovery_model_desc              AS RecoveryModel,
    compatibility_level              AS CompatLevel,
    SUSER_SNAME(owner_sid)           AS Owner
FROM sys.databases
WHERE name = @db;
GO
