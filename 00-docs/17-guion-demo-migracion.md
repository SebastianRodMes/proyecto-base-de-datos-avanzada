# Comandos para la demo de migración

Ejecutar desde la raíz del repo en PowerShell 7. No correr `71`, `73`, `74`, `74b`, `75`, `77` en vivo (lentos o sobrescriben evidencia); no limpiar marcas de `MONGODB`.

### 0. Preparar la sesión (cargar credenciales y endpoints)
```powershell
Set-Location "D:\GitHub\Universidad\proyecto-base-de-datos-avanzada"
$env:PATH = "C:\Program Files\Amazon\AWSCLIV2;$env:PATH"
$ctx = @{}; Get-Content ".secrets\turismodw-cloud.env" | Where-Object { $_ -match '^\s*[^#].*=' } | ForEach-Object { $k,$val = $_ -split '=',2; $ctx[$k.Trim()] = $val.Trim() }
$SQL_EP = "turismodw-sql.cyjcymmugyxk.us-east-1.rds.amazonaws.com"
aws sts get-caller-identity --profile turismodw
```

### 1. Encender las 2 RDS y reabrir el firewall para tu IP
```powershell
.\07-migracion\78-detener-recursos.ps1 -Iniciar -Esperar
$ip = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
foreach ($port in 1433,5432) { aws ec2 authorize-security-group-ingress --group-id $ctx['SG_ID'] --protocol tcp --port $port --cidr "$ip/32" --profile turismodw 2>$null | Out-Null }
.\07-migracion\78-detener-recursos.ps1 -Estado
```

### 2. Mostrar el origen local vivo (las 4 fuentes)
```powershell
docker compose -f docker\docker-compose.yml -f docker\docker-compose.override.yml ps
docker exec turismodw-postgres-1 psql -U postgres -d turismo -c "SELECT COUNT(*) AS reservas, SUM(monto_total) AS monto FROM reserva;"
docker exec turismodw-mongo-1 mongosh turismo_nosql --quiet --eval "print('resenas:', db.resenas.countDocuments({}), 'interacciones:', db.interacciones_web.countDocuments({}))"
Get-ChildItem .\03-archivos\entrada\ | Select-Object Name, Length
```

### 3. Mostrar el inventario de objetos a migrar (ya generado)
```powershell
Get-Content .\00-docs\09-inventario-migracion.md | Select-Object -First 80
```

### 4. Migración piloto 10 % (opcional; escribe una base desechable en RDS)
```powershell
.\07-migracion\72-piloto-migracion.ps1 -SinRutaAlterna
```

### 5. Mostrar evidencia de la migración real (narrar, no ejecutar)
```powershell
Get-ChildItem .\07-migracion\73-migrar-postgres.ps1, .\07-migracion\74-migrar-mongo.ps1, .\07-migracion\74b-archivos-a-s3.ps1, .\07-migracion\75-migrar-dw.ps1
Get-Content .\00-docs\05-evidencias\migracion\migracion-postgres-completa.txt
Get-Content .\00-docs\05-evidencias\migracion\migracion-dw-completa.txt
```

### 6. Validar el DW migrado en la nube (debe dar "MIGRACION VERIFICADA")
```powershell
sqlcmd -S "$SQL_EP,1433" -U $ctx['RDS_SQL_USER'] -P $ctx['RDS_SQL_PASSWORD'] -C -N -d TurismoDW -i .\07-migracion\76-validacion-post-migracion.sql -v ReservasOrigen=2000011 MontoOrigen=16709505560.28 ResenasOrigen=500002 InteraccionesOrigen=1500002
Get-Content .\00-docs\05-evidencias\migracion\comparacion-local-cloud.txt
```

### 7. Abrir Power BI contra la nube (auth Base de datos: turismoadmin / ver .secrets)
```powershell
Start-Process .\06-powerbi\TurismoDW.pbip
```

### 8. Apagar la nube al terminar (imprescindible)
```powershell
.\07-migracion\78-detener-recursos.ps1
```

### Bonus. Carga incremental en vivo contra el laboratorio local (~22 s)
```powershell
Set-Location .\05-etl; python run_etl.py --modo INCREMENTAL; Set-Location ..
```
