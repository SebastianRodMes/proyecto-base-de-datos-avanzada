/* =====================================================================
   ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
   Integrante 3: Erick - Alta Disponibilidad (Database Mirroring)
   ---------------------------------------------------------------------
   48a-principal-setup.sql

   Paso 1 del Mirroring en la instancia PRINCIPAL (localhost / Erick):
   1. Asegurar recovery FULL.
   2. Crear Endpoint en puerto 5022.
   3. Conceder permisos de conexión a las cuentas de servicio.
   4. Realizar BACKUP FULL y BACKUP LOG para inicializar el espejo.
   ===================================================================== */
SET NOCOUNT ON;
USE master;
GO

PRINT '=== [1/4] Verificando Modelo de Recuperacion ===';
ALTER DATABASE TurismoDW SET RECOVERY FULL;
GO

PRINT '=== [2/4] Creando Endpoint de Mirroring (Puerto 5022) ===';
IF EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints WHERE name = 'Mirroring')
BEGIN
    DROP ENDPOINT Mirroring;
END
GO

CREATE ENDPOINT Mirroring
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5022, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
        ROLE = ALL,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );
GO

PRINT '=== [3/4] Configurando Permisos de Conexion ===';
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT AUTHORITY\SYSTEM')
BEGIN
    CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
END
GRANT CONNECT ON ENDPOINT::Mirroring TO [NT AUTHORITY\SYSTEM];

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT Service\MSSQL$MIRROR')
BEGIN
    CREATE LOGIN [NT Service\MSSQL$MIRROR] FROM WINDOWS;
END
GRANT CONNECT ON ENDPOINT::Mirroring TO [NT Service\MSSQL$MIRROR];

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT Service\MSSQL$WITNESS')
BEGIN
    CREATE LOGIN [NT Service\MSSQL$WITNESS] FROM WINDOWS;
END
GRANT CONNECT ON ENDPOINT::Mirroring TO [NT Service\MSSQL$WITNESS];
GO

PRINT '=== [4/4] Generando Backups Iniciales ===';
BACKUP DATABASE TurismoDW
TO DISK = 'D:\DB\mssql\TurismoDW\backup\TurismoDW_full.bak'
WITH FORMAT, INIT, COMPRESSION, STATS = 20;
GO

BACKUP LOG TurismoDW
TO DISK = 'D:\DB\mssql\TurismoDW\backup\TurismoDW_log.trn'
WITH FORMAT, INIT, STATS = 20;
GO

PRINT '>> Setup del Principal completado exitosamente.';
GO
