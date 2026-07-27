/* ---------------------------------------------------------------------------
   PL-300 demo: SQL Server instance configuration.

   Creates a dedicated SQL-authentication sysadmin login for the class and
   leaves the built-in `sa` account disabled. Mixed-mode authentication, TCP/IP
   and the Windows firewall are handled by bootstrap.ps1 - those are host-level
   settings, not T-SQL.

   Invoked as:
     sqlcmd -S localhost -E -b -i configure-sql.sql \
            -v SqlLogin="pl300sql" SqlPassword="..."

   Idempotent: safe to re-run.
   --------------------------------------------------------------------------- */

:on error exit
SET NOCOUNT ON;
GO

DECLARE @login    sysname       = N'$(SqlLogin)';
DECLARE @password nvarchar(256) = N'$(SqlPassword)';
DECLARE @sql      nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    SET @sql = N'CREATE LOGIN ' + QUOTENAME(@login)
             + N' WITH PASSWORD = ' + QUOTENAME(@password, '''')
             + N', DEFAULT_DATABASE = [master], CHECK_EXPIRATION = OFF, CHECK_POLICY = ON;';
    EXEC (@sql);
    PRINT 'Created login: ' + @login;
END
ELSE
BEGIN
    SET @sql = N'ALTER LOGIN ' + QUOTENAME(@login)
             + N' WITH PASSWORD = ' + QUOTENAME(@password, '''')
             + N', CHECK_POLICY = ON;';
    EXEC (@sql);
    SET @sql = N'ALTER LOGIN ' + QUOTENAME(@login) + N' ENABLE;';
    EXEC (@sql);
    PRINT 'Updated existing login: ' + @login;
END

IF NOT EXISTS (
    SELECT 1
    FROM sys.server_role_members rm
    JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id
    JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id
    WHERE r.name = N'sysadmin' AND m.name = @login)
BEGIN
    SET @sql = N'ALTER SERVER ROLE [sysadmin] ADD MEMBER ' + QUOTENAME(@login) + N';';
    EXEC (@sql);
    PRINT 'Granted sysadmin to: ' + @login;
END
GO

/* The class login above is the intended entry point; sa stays off. */
IF EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'sa' AND is_disabled = 0)
BEGIN
    ALTER LOGIN [sa] DISABLE;
    PRINT 'Disabled the sa login.';
END
GO

/* Keep the demo instance modest - it shares 16 GB with Power BI Desktop.
   Without a cap, SQL Server will happily take almost all of it and make the
   Power BI Desktop demos feel broken. */
EXEC sys.sp_configure N'show advanced options', 1;
RECONFIGURE WITH OVERRIDE;
GO
EXEC sys.sp_configure N'max server memory (MB)', 6144;
EXEC sys.sp_configure N'min server memory (MB)', 1024;
RECONFIGURE WITH OVERRIDE;
GO

/* Optimize for ad-hoc workloads: the class will run a lot of one-off queries. */
EXEC sys.sp_configure N'optimize for ad hoc workloads', 1;
RECONFIGURE WITH OVERRIDE;
GO

PRINT '--- Instance configuration complete ---';
SELECT
    @@SERVERNAME                                        AS ServerName,
    SERVERPROPERTY('Edition')                           AS Edition,
    SERVERPROPERTY('ProductVersion')                    AS ProductVersion,
    SERVERPROPERTY('IsIntegratedSecurityOnly')          AS WindowsAuthOnly;
GO
