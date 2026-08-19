/* =====================================================================
   Restore de TurismoDW en la maquina de Sebastian (Integrante 3)
   ---------------------------------------------------------------------
   Adaptado: rutas a C:\ (esta maquina no tiene disco D:) y restore
   CON RECOVERY para dejar la base LISTA PARA USAR y probar.

   NOTA: este restore es para PROBAR la base en la instancia principal.
   Para el ESPEJO del Mirroring se usa otro restore (WITH NORECOVERY,
   a C:\DB\mssql\Mirror\). Eso va despues, en la fase de Mirroring.

   Requisitos previos:
     1. SQL Server 2022 Developer instalado, instancia .\DW
     2. Archivo TurismoDW_full.bak recibido de Alex, copiado a:
        C:\DB\mssql\TurismoDW\backup\TurismoDW_full.bak

   Uso (una vez instalado sqlcmd):
     sqlcmd -S .\DW -E -C -i 99-setup\restore-sebas-testing.sql

   O desde SSMS: abrir este archivo y ejecutar (F5) conectado a .\DW
   ===================================================================== */

/* Paso 0 - confirmar los nombres logicos que trae el .bak.
   Descomentar y correr SOLO esto primero si el restore de abajo falla:
   los nombres logicos (TurismoDW_sys, etc.) deben coincidir. */
-- RESTORE FILELISTONLY
--   FROM DISK = 'C:\DB\mssql\TurismoDW\backup\TurismoDW_full.bak';
-- GO

/* Paso 1 - restaurar la base completa a las rutas de C: */
RESTORE DATABASE TurismoDW
  FROM DISK = 'C:\DB\mssql\TurismoDW\backup\TurismoDW_full.bak'
  WITH RECOVERY, REPLACE,
       MOVE 'TurismoDW_sys'    TO 'C:\DB\mssql\TurismoDW\data\TurismoDW_sys.mdf',
       MOVE 'TurismoDW_dim01'  TO 'C:\DB\mssql\TurismoDW\data\TurismoDW_dim01.ndf',
       MOVE 'TurismoDW_fact01' TO 'C:\DB\mssql\TurismoDW\data\TurismoDW_fact01.ndf',
       MOVE 'TurismoDW_fact02' TO 'C:\DB\mssql\TurismoDW\data\TurismoDW_fact02.ndf',
       MOVE 'TurismoDW_stg01'  TO 'C:\DB\mssql\TurismoDW\data\TurismoDW_stg01.ndf',
       MOVE 'TurismoDW_idx01'  TO 'C:\DB\mssql\TurismoDW\data\TurismoDW_idx01.ndf',
       MOVE 'TurismoDW_log'    TO 'C:\DB\mssql\TurismoDW\log\TurismoDW_log.ldf';
GO

/* Paso 2 - verificar que quedo bien */
USE TurismoDW;
GO
PRINT '=== Estado de la base ===';
SELECT name, state_desc, recovery_model_desc
FROM   sys.databases
WHERE  name = 'TurismoDW';

PRINT '=== Conteo de reservas (debe dar 2,000,005) ===';
SELECT COUNT(*) AS Reservas FROM dw.FactReserva;

PRINT '=== Archivos fisicos ===';
SELECT name AS ArchivoLogico, physical_name AS RutaFisica
FROM   sys.database_files;
GO
