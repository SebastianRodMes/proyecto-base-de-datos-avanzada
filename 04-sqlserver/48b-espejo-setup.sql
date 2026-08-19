/* =====================================================================
   ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
   Integrante 3: Erick - Alta Disponibilidad (Database Mirroring)
   ---------------------------------------------------------------------
   48b-espejo-setup.sql

   Paso 2 del Mirroring en la instancia ESPEJO (localhost\MIRROR):
   1. Crear Endpoint en puerto 5023.
   2. Conceder permisos de conexión.
   3. Restaurar TurismoDW con NORECOVERY y 7 clausulas MOVE.
   4. Establecer PARTNER apuntando al Principal (puerto 5022).
   ===================================================================== */
SET NOCOUNT ON;
USE master;
GO

PRINT '=== [1/4] Creando Endpoint de Mirroring en Espejo (Puerto 5023) ===';
IF EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints WHERE name = 'Mirroring')
BEGIN
    DROP ENDPOINT Mirroring;
END
GO

CREATE ENDPOINT Mirroring
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5023, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
        ROLE = ALL,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );
GO

PRINT '=== [2/4] Configurando Permisos de Conexion en Espejo ===';
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT AUTHORITY\SYSTEM')
BEGIN
    CREATE LOGIN [NT AUTHORITY\SYSTEM] FROM WINDOWS;
END
GRANT CONNECT ON ENDPOINT::Mirroring TO [NT AUTHORITY\SYSTEM];

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT Service\MSSQLSERVER')
BEGIN
    CREATE LOGIN [NT Service\MSSQLSERVER] FROM WINDOWS;
END
GRANT CONNECT ON ENDPOINT::Mirroring TO [NT Service\MSSQLSERVER];

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT Service\MSSQL$WITNESS')
BEGIN
    CREATE LOGIN [NT Service\MSSQL$WITNESS] FROM WINDOWS;
END
GRANT CONNECT ON ENDPOINT::Mirroring TO [NT Service\MSSQL$WITNESS];
GO

PRINT '=== [3/4] Restaurando TurismoDW con NORECOVERY en Espejo ===';
IF DB_ID('TurismoDW') IS NOT NULL
BEGIN
    ALTER DATABASE TurismoDW SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE TurismoDW;
END
GO

RESTORE DATABASE TurismoDW
FROM DISK = 'D:\DB\mssql\TurismoDW\backup\TurismoDW_full.bak'
WITH NORECOVERY, REPLACE,
     MOVE 'TurismoDW_sys'    TO 'D:\DB\mssql\Mirror\data\TurismoDW_sys.mdf',
     MOVE 'TurismoDW_dim01'  TO 'D:\DB\mssql\Mirror\data\TurismoDW_dim01.ndf',
     MOVE 'TurismoDW_fact01' TO 'D:\DB\mssql\Mirror\data\TurismoDW_fact01.ndf',
     MOVE 'TurismoDW_fact02' TO 'D:\DB\mssql\Mirror\data\TurismoDW_fact02.ndf',
     MOVE 'TurismoDW_stg01'  TO 'D:\DB\mssql\Mirror\data\TurismoDW_stg01.ndf',
     MOVE 'TurismoDW_idx01'  TO 'D:\DB\mssql\Mirror\data\TurismoDW_idx01.ndf',
     MOVE 'TurismoDW_log'    TO 'D:\DB\mssql\Mirror\log\TurismoDW_log.ldf';
GO

RESTORE LOG TurismoDW
FROM DISK = 'D:\DB\mssql\TurismoDW\backup\TurismoDW_log.trn'
WITH NORECOVERY;
GO

PRINT '=== [4/4] Apuntando Espejo al Principal (puerto 5022) ===';
ALTER DATABASE TurismoDW SET PARTNER = 'TCP://localhost:5022';
GO

PRINT '>> Setup del Espejo completado exitosamente.';
GO
