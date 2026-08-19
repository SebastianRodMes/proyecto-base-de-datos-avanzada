@echo off
:: Auto-elevación a Administrador
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo Solicitando permisos de Administrador...
    powershell -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

title Instalador de Instancias SQL Server para Mirroring (Administrador)
cd /d "%~dp0"
cls
echo ===================================================================
echo     INSTALADOR DE INSTANCIAS SQL SERVER (MIRROR Y WITNESS)
echo ===================================================================
echo.
echo Este proceso instalara las dos instancias necesarias:
echo   1. Instancia MIRROR   (Espejo)
echo   2. Instancia WITNESS  (Testigo para Failover Automatico)
echo.
echo Por favor NO cierre esta ventana mientras avanza el proceso.
echo Tarda aproximadamente 3 a 5 minutos.
echo.
echo ===================================================================

powershell -NoProfile -ExecutionPolicy Bypass -File "02-instalar-mirroring-instancias.ps1"

echo.
echo Presione una tecla para salir...
pause >nul
