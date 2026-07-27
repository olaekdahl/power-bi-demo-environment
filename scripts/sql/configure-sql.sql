/* ---------------------------------------------------------------------------
   PL-300 demo: SQL Server instance configuration.

   The class login itself is created by Terraform's
   azurerm_mssql_virtual_machine resource (the SQL IaaS Agent extension), which
   also enables mixed-mode authentication, TCP/IP and the guest firewall rule.
   This script confirms that login has sysadmin, disables `sa`, and tunes the
   instance for a machine shared with Power BI Desktop.

   Deliberately does NOT set the login's password: this script runs *as* that
   login, the password is already correct, and re-setting it would be a
   needless way to lock the class out of its own SQL Server.

   Invoked as:
     sqlcmd -S localhost -U pl300sql -P ... -b -i configure-sql.sql
            (with :setvar SqlLogin supplied by a wrapper - see bootstrap.ps1)

   Idempotent: safe to re-run.
   --------------------------------------------------------------------------- */

:on error exit
SET NOCOUNT ON;
GO

DECLARE @login sysname      = N'$(SqlLogin)';
DECLARE @sql   nvarchar(max);

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    /* Should not happen - Terraform creates it - but keep the script usable
       standalone. No password available here, so this is a hard stop. */
    RAISERROR('Login %s does not exist. It is created by azurerm_mssql_virtual_machine.', 16, 1, @login);
    RETURN;
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
