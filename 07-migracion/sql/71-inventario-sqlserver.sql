/* =====================================================================
   ITI-821 · Escenario 8: Turismo Inteligente · Semana 3
   Integrante 1: Alex Herrera

   71-inventario-sqlserver.sql
   ---------------------------------------------------------------------
   Inventario de objetos de TurismoDW leido de los catalogos del sistema.

   Entregable de Semana 3: "Crear inventario de objetos a migrar: tablas,
   colecciones, vistas, procedimientos, indices".

   Se consulta el catalogo vivo y no los scripts DDL a proposito: un
   inventario transcrito a mano desde el codigo fuente describe lo que se
   penso crear, no lo que realmente existe. Para decidir que migra y que
   no, solo sirve lo segundo.

   Uso:
     sqlcmd -S localhost,1433 -U sa -P <pwd> -C -d TurismoDW -i este.sql
   ===================================================================== */
SET NOCOUNT ON;
GO
USE TurismoDW;
GO

PRINT '';
PRINT '=====================================================================';
PRINT ' INVENTARIO DE OBJETOS - SQL SERVER (TurismoDW)';
PRINT '=====================================================================';
GO

PRINT '';
PRINT '=== 0. Instancia y base ===';
SELECT
    [Servidor]   = CONVERT(varchar(60), @@SERVERNAME),
    [Version]    = CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')),
    [Edicion]    = CONVERT(varchar(50), SERVERPROPERTY('Edition')),
    [Compat]     = CONVERT(varchar(5),  d.compatibility_level),
    [Recovery]   = CONVERT(varchar(15), d.recovery_model_desc),
    [Collation]  = CONVERT(varchar(50), d.collation_name),
    [RCSI]       = CONVERT(varchar(3),  CASE WHEN d.is_read_committed_snapshot_on = 1 THEN 'ON' ELSE 'OFF' END)
FROM sys.databases d
WHERE d.name = DB_NAME();
GO

PRINT '';
PRINT '=== 1. Filegroups y archivos (clave para la portabilidad a RDS) ===';
SELECT
    [Filegroup]  = CONVERT(varchar(20), fg.name),
    [Archivo]    = CONVERT(varchar(28), df.name),
    [TamanoMB]   = CONVERT(int, df.size / 128),
    [UsadoMB]    = CONVERT(int, FILEPROPERTY(df.name, 'SpaceUsed') / 128),
    [PorDefecto] = CONVERT(varchar(3), CASE WHEN fg.is_default = 1 THEN 'SI' ELSE 'no' END),
    [RutaFisica] = CONVERT(varchar(60), df.physical_name)
FROM sys.database_files df
LEFT JOIN sys.filegroups fg ON fg.data_space_id = df.data_space_id
ORDER BY df.type, fg.name, df.name;
GO

PRINT '';
PRINT '=== 2. Tablas por esquema, con filas y espacio ===';
/* Las filas y el espacio se calculan en subconsultas SEPARADAS a proposito.

   Unir sys.partitions con sys.allocation_units en una sola consulta y luego
   agrupar cuenta las filas VARIAS VECES: una tabla con columnas nvarchar(max)
   tiene hasta tres unidades de asignacion (IN_ROW_DATA, LOB_DATA y
   ROW_OVERFLOW_DATA), y el SUM las multiplica. Con esa forma, stg.Resena
   reportaba 1 500 000 filas en vez de 500 000.

   Ademas LOB_DATA se enlaza por hobt_id y no por partition_id, asi que el
   join de espacio contempla ambos casos. */
SELECT
    [Esquema]     = CONVERT(varchar(6),  s.name),
    [Tabla]       = CONVERT(varchar(32), t.name),
    [Columnas]    = (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id),
    [Filas]       = (SELECT SUM(p.rows) FROM sys.partitions p
                      WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)),
    [Particiones] = (SELECT COUNT(*) FROM sys.partitions p
                      WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)),
    [EspacioMB]   = (SELECT CONVERT(int, SUM(a.total_pages) * 8 / 1024)
                       FROM sys.partitions p
                       JOIN sys.allocation_units a
                         ON (a.type IN (1, 3) AND a.container_id = p.partition_id)
                         OR (a.type = 2        AND a.container_id = p.hobt_id)
                      WHERE p.object_id = t.object_id)
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
ORDER BY s.name, t.name;
GO

PRINT '';
PRINT '=== 3. Vistas ===';
SELECT
    [Esquema] = CONVERT(varchar(6),  s.name),
    [Vista]   = CONVERT(varchar(34), v.name),
    [Lineas]  = LEN(m.definition) - LEN(REPLACE(m.definition, CHAR(10), '')) + 1
FROM sys.views v
JOIN sys.schemas s     ON s.schema_id = v.schema_id
JOIN sys.sql_modules m ON m.object_id = v.object_id
ORDER BY s.name, v.name;
GO

PRINT '';
PRINT '=== 4. Procedimientos y funciones ===';
SELECT
    [Esquema]    = CONVERT(varchar(6),  s.name),
    [Objeto]     = CONVERT(varchar(34), o.name),
    [Tipo]       = CONVERT(varchar(22), o.type_desc),
    [Parametros] = (SELECT COUNT(*) FROM sys.parameters p WHERE p.object_id = o.object_id),
    [Lineas]     = LEN(m.definition) - LEN(REPLACE(m.definition, CHAR(10), '')) + 1
FROM sys.objects o
JOIN sys.schemas s     ON s.schema_id = o.schema_id
JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.type IN ('P', 'FN', 'IF', 'TF')
ORDER BY s.name, o.name;
GO

PRINT '';
PRINT '=== 5. Indices (tipo, alineacion y filegroup) ===';
SELECT
    [Tabla]      = CONVERT(varchar(30), s.name + '.' + t.name),
    [Indice]     = CONVERT(varchar(32), i.name),
    [Tipo]       = CONVERT(varchar(22), i.type_desc),
    [Unico]      = CONVERT(varchar(3), CASE WHEN i.is_unique = 1 THEN 'SI' ELSE 'no' END),
    [Alineado]   = CONVERT(varchar(3), CASE WHEN ps.name IS NOT NULL THEN 'SI' ELSE 'no' END),
    [Ubicacion]  = CONVERT(varchar(20), COALESCE(ps.name, fg.name))
FROM sys.indexes i
JOIN sys.tables t          ON t.object_id = i.object_id
JOIN sys.schemas s         ON s.schema_id = t.schema_id
LEFT JOIN sys.partition_schemes ps ON ps.data_space_id = i.data_space_id
LEFT JOIN sys.filegroups fg        ON fg.data_space_id = i.data_space_id
WHERE i.type > 0
ORDER BY s.name, t.name, i.type, i.name;
GO

PRINT '';
PRINT '=== 6. Claves foraneas (y si son confiables) ===';
SELECT
    [Restriccion] = CONVERT(varchar(34), fk.name),
    [Origen]      = CONVERT(varchar(30), so.name + '.' + o.name),
    [Destino]     = CONVERT(varchar(26), sr.name + '.' + r.name),
    [NoConfiable] = CONVERT(varchar(3), CASE WHEN fk.is_not_trusted = 1 THEN 'SI' ELSE 'no' END),
    [Deshabilit]  = CONVERT(varchar(3), CASE WHEN fk.is_disabled   = 1 THEN 'SI' ELSE 'no' END)
FROM sys.foreign_keys fk
JOIN sys.objects o  ON o.object_id = fk.parent_object_id
JOIN sys.schemas so ON so.schema_id = o.schema_id
JOIN sys.objects r  ON r.object_id = fk.referenced_object_id
JOIN sys.schemas sr ON sr.schema_id = r.schema_id
ORDER BY so.name, o.name, fk.name;
GO

PRINT '';
PRINT '=== 7. Particionamiento ===';
SELECT
    [Funcion]   = CONVERT(varchar(20), pf.name),
    [Tipo]      = CONVERT(varchar(12), CASE WHEN pf.boundary_value_on_right = 1 THEN 'RANGE RIGHT' ELSE 'RANGE LEFT' END),
    [Limites]   = pf.fanout - 1,
    [Particion] = pf.fanout
FROM sys.partition_functions pf;

SELECT
    [Esquema]   = CONVERT(varchar(20), ps.name),
    [Particion] = dds.destination_id,
    [Filegroup] = CONVERT(varchar(20), fg.name)
FROM sys.partition_schemes ps
JOIN sys.destination_data_spaces dds ON dds.partition_scheme_id = ps.data_space_id
JOIN sys.filegroups fg               ON fg.data_space_id = dds.data_space_id
ORDER BY ps.name, dds.destination_id;
GO

PRINT '';
PRINT '=== 8. Distribucion de filas por particion (tablas particionadas) ===';
SELECT
    [Tabla]     = CONVERT(varchar(30), s.name + '.' + t.name),
    [Particion] = p.partition_number,
    [Filegroup] = CONVERT(varchar(16), fg.name),
    [Filas]     = p.rows
FROM sys.partitions p
JOIN sys.tables t            ON t.object_id = p.object_id
JOIN sys.schemas s           ON s.schema_id = t.schema_id
JOIN sys.indexes i           ON i.object_id = p.object_id AND i.index_id = p.index_id
JOIN sys.allocation_units au ON au.container_id = p.hobt_id
JOIN sys.filegroups fg       ON fg.data_space_id = au.data_space_id
WHERE i.index_id = 1
  AND EXISTS (SELECT 1 FROM sys.partitions p2
               WHERE p2.object_id = p.object_id AND p2.index_id = 1
               GROUP BY p2.object_id HAVING COUNT(*) > 1)
ORDER BY s.name, t.name, p.partition_number;
GO

PRINT '';
PRINT '=== 9. Resumen contable de objetos ===';
/* Se cuenta SOLO lo que vive en los esquemas del proyecto. Query Store esta
   activo y crea sus propias tablas internas con indices y restricciones; sin
   este filtro el inventario reportaria 122 indices agrupados y 31 claves
   foraneas que nadie escribio y que ademas no se migran. */
;WITH objetos AS (
    SELECT t.object_id
    FROM sys.tables t
    JOIN sys.schemas s ON s.schema_id = t.schema_id
    WHERE s.name IN ('stg', 'dw', 'etl', 'dbo')
)
SELECT [Categoria] = 'Tablas stg',        [Cantidad] = COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='stg'
UNION ALL SELECT 'Tablas dw (dimension)', COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='dw' AND t.name LIKE 'Dim%'
UNION ALL SELECT 'Tablas dw (hechos)',    COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='dw' AND t.name LIKE 'Fact%'
UNION ALL SELECT 'Tablas etl (control)',  COUNT(*) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id WHERE s.name='etl'
UNION ALL SELECT 'Vistas',                COUNT(*) FROM sys.views v JOIN sys.schemas s ON s.schema_id=v.schema_id WHERE s.name IN ('stg','dw','etl','dbo')
UNION ALL SELECT 'Procedimientos',        COUNT(*) FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE o.type='P' AND s.name IN ('stg','dw','etl','dbo')
UNION ALL SELECT 'Funciones',             COUNT(*) FROM sys.objects o JOIN sys.schemas s ON s.schema_id=o.schema_id WHERE o.type IN ('FN','IF','TF') AND s.name IN ('stg','dw','etl','dbo')
UNION ALL SELECT 'Indices agrupados',     COUNT(*) FROM sys.indexes i JOIN objetos ob ON ob.object_id=i.object_id WHERE i.type=1
UNION ALL SELECT 'Indices no agrupados',  COUNT(*) FROM sys.indexes i JOIN objetos ob ON ob.object_id=i.object_id WHERE i.type=2
UNION ALL SELECT 'Columnstore',           COUNT(*) FROM sys.indexes i JOIN objetos ob ON ob.object_id=i.object_id WHERE i.type IN (5,6)
UNION ALL SELECT 'Claves foraneas',       COUNT(*) FROM sys.foreign_keys fk JOIN objetos ob ON ob.object_id=fk.parent_object_id
UNION ALL SELECT 'Filegroups de usuario', COUNT(*) FROM sys.filegroups WHERE name <> 'PRIMARY' AND type='FG'
UNION ALL SELECT 'Archivos de datos',     COUNT(*) FROM sys.database_files WHERE type=0
UNION ALL SELECT 'Funciones de particion',COUNT(*) FROM sys.partition_functions;
GO

PRINT '';
PRINT '=== 10. Tamano total de la base (define si cabe en Express, tope 10 GB) ===';
SELECT
    [ArchivosDatosMB] = CONVERT(int, SUM(CASE WHEN type = 0 THEN size ELSE 0 END) / 128),
    [UsadoDatosMB]    = CONVERT(int, SUM(CASE WHEN type = 0 THEN CONVERT(bigint, FILEPROPERTY(name,'SpaceUsed')) ELSE 0 END) / 128),
    [LogMB]           = CONVERT(int, SUM(CASE WHEN type = 1 THEN size ELSE 0 END) / 128)
FROM sys.database_files;
GO

PRINT '';
PRINT '>> Fin del inventario de SQL Server.';
GO
