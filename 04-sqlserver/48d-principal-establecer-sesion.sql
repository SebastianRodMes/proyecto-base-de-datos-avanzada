/* =====================================================================
   ITI-821 Bases de Datos Avanzadas - Escenario 8: Turismo Inteligente
   Integrante 3: Erick - Alta Disponibilidad (Database Mirroring)
   ---------------------------------------------------------------------
   48d-principal-establecer-sesion.sql

   Paso 4 del Mirroring en la instancia PRINCIPAL (localhost):
   1. Unir la sesión apuntando al Espejo (puerto 5023).
   2. Asignar el Testigo (puerto 5024).
   3. Establecer SAFETY FULL (alta seguridad sincrónica con failover automático).
   4. Validar el estado del Mirroring.
   ===================================================================== */
SET NOCOUNT ON;
USE master;
GO

PRINT '=== [1/3] Conectando Principal con el Espejo (puerto 5023) ===';
ALTER DATABASE TurismoDW SET PARTNER = 'TCP://localhost:5023';
GO

PRINT '=== [2/3] Asignando Testigo (puerto 5024) y Modo Alta Seguridad ===';
ALTER DATABASE TurismoDW SET WITNESS = 'TCP://localhost:5024';
GO

ALTER DATABASE TurismoDW SET SAFETY FULL;
GO

PRINT '=== [3/3] Validando Estado de Alta Disponibilidad ===';
SELECT 
    DB_NAME(database_id)            AS [Base de Datos],
    mirroring_role_desc             AS [Rol],
    mirroring_state_desc            AS [Estado],
    mirroring_safety_level_desc     AS [Seguridad],
    mirroring_partner_name          AS [Socio],
    mirroring_witness_name          AS [Testigo],
    mirroring_witness_state_desc    AS [Estado Testigo]
FROM sys.database_mirroring
WHERE mirroring_guid IS NOT NULL;
GO

USE TurismoDW;
GO
SELECT * FROM dw.vw_EstadoSistema;
GO

PRINT '>> ¡Sesion de Database Mirroring establecida y sincronizada!';
GO
