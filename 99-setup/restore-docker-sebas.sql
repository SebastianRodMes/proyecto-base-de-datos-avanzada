/* =====================================================================
   Restore de TurismoDW en contenedor Docker (Integrante 2 - Sebastian)
   ---------------------------------------------------------------------
   El contenedor corre SQL Server sobre LINUX, asi que las rutas son
   /var/opt/mssql/... (no C:\ ni D:\).

   Requisitos previos:
     1. Contenedor 'turismo-sql' corriendo (mcr...mssql/server:2022).
     2. Archivo TurismoDW_full.bak recibido de Alex y copiado ADENTRO
        del contenedor con:
          docker exec turismo-sql mkdir -p /var/opt/mssql/backup
          docker cp "C:\ruta\TurismoDW_full.bak" turismo-sql:/var/opt/mssql/backup/

   Uso: conectarse desde SSMS a  localhost,1433  (sa / Armagedon45*)
        abrir este archivo y ejecutar (F5).
   ===================================================================== */

/* Paso 0 - confirmar los nombres logicos que trae el .bak.
   Correr esto primero si el restore falla por nombres que no coinciden: */
-- RESTORE FILELISTONLY
--   FROM DISK = '/var/opt/mssql/backup/TurismoDW_full.bak';
-- GO

/* Paso 1 - restaurar la base a las rutas de Linux del contenedor */
RESTORE DATABASE TurismoDW
  FROM DISK = '/var/opt/mssql/backup/TurismoDW_full.bak'
  WITH RECOVERY, REPLACE,
       MOVE 'TurismoDW_sys'    TO '/var/opt/mssql/data/TurismoDW_sys.mdf',
       MOVE 'TurismoDW_dim01'  TO '/var/opt/mssql/data/TurismoDW_dim01.ndf',
       MOVE 'TurismoDW_fact01' TO '/var/opt/mssql/data/TurismoDW_fact01.ndf',
       MOVE 'TurismoDW_fact02' TO '/var/opt/mssql/data/TurismoDW_fact02.ndf',
       MOVE 'TurismoDW_stg01'  TO '/var/opt/mssql/data/TurismoDW_stg01.ndf',
       MOVE 'TurismoDW_idx01'  TO '/var/opt/mssql/data/TurismoDW_idx01.ndf',
       MOVE 'TurismoDW_log'    TO '/var/opt/mssql/data/TurismoDW_log.ldf';
GO

/* Paso 2 - verificar */
USE TurismoDW;
GO
PRINT '=== Estado de la base ===';
SELECT name, state_desc, recovery_model_desc
FROM   sys.databases WHERE name = 'TurismoDW';

PRINT '=== Reservas (debe dar 2,000,005) ===';
SELECT COUNT(*) AS Reservas FROM dw.FactReserva;

PRINT '=== Archivos fisicos ===';
SELECT name AS ArchivoLogico, physical_name AS RutaFisica
FROM   sys.database_files;
GO
