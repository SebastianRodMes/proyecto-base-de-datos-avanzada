/* =====================================================================
   ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
   Integrante 3: Erick - Alta Disponibilidad (Database Mirroring)
   ---------------------------------------------------------------------
   48c-testigo-setup.sql

   Paso 3 del Mirroring en la instancia TESTIGO (localhost\WITNESS):
   1. Crear Endpoint en puerto 5024 con ROLE = WITNESS.
   2. Conceder permisos de conexión a Principal y Espejo.
   ===================================================================== */
SET NOCOUNT ON;
USE master;
GO

PRINT '=== [1/2] Creando Endpoint de Testigo en Witness (Puerto 5024) ===';
IF EXISTS (SELECT 1 FROM sys.database_mirroring_endpoints WHERE name = 'Mirroring')
BEGIN
    DROP ENDPOINT Mirroring;
END
GO

CREATE ENDPOINT Mirroring
    STATE = STARTED
    AS TCP (LISTENER_PORT = 5024, LISTENER_IP = ALL)
    FOR DATABASE_MIRRORING (
        ROLE = WITNESS,
        ENCRYPTION = REQUIRED ALGORITHM AES
    );
GO

PRINT '=== [2/2] Configurando Permisos de Conexion en Witness ===';
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

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'NT Service\MSSQL$MIRROR')
BEGIN
    CREATE LOGIN [NT Service\MSSQL$MIRROR] FROM WINDOWS;
END
GRANT CONNECT ON ENDPOINT::Mirroring TO [NT Service\MSSQL$MIRROR];
GO

PRINT '>> Setup del Testigo completado exitosamente.';
GO
