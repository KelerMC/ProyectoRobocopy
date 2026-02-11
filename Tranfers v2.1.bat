@echo off
title Transferencia Automatizada NAS

echo ================================
echo  TRANSFERENCIA AUTOMATIZADA NAS
echo ================================
echo.

:: === CONFIGURACION ===
set NAS=\\192.168.1.254\Pruebas
set DRIVE=Z:
set LOGDIR=C:\Logs

if not exist %LOGDIR% mkdir %LOGDIR%

:: === MAPEAR UNIDAD (UNA SOLA VEZ) ===
echo Verificando unidad %DRIVE% ...

:: Desconectar si ya existe
net use %DRIVE% /delete /y >nul 2>&1

echo Mapeando unidad %DRIVE% ...
net use %DRIVE% %NAS% /persistent:no

if errorlevel 1 (
 echo.
 echo ERROR: No se pudo conectar al NAS
 echo Verifique:
 echo  - Conexion de red
 echo  - Ruta del NAS: %NAS%
 echo  - Credenciales de acceso
 echo.
 pause
 exit /b
)
echo Unidad mapeada correctamente.
echo.

:INICIO

:: === SOLICITAR DATOS ===
set /p SOURCE=Ingrese ruta ORIGEN (carpeta completa):
set /p DEST=Ingrese ruta DESTINO dentro del NAS:

:: === EXTRAER NOMBRE DE CARPETA ORIGEN ===
for %%I in ("%SOURCE%") do set FOLDER_NAME=%%~nxI

echo.
echo Carpeta a copiar: %FOLDER_NAME%
echo Destino final: %NAS%\%DEST%\%FOLDER_NAME%
echo.
pause

echo.
echo Creando carpeta destino...
mkdir "%DRIVE%\%DEST%\%FOLDER_NAME%" 2>nul

:: === LOG ===
set LOG=%LOGDIR%\robocopy_%date:~-4%%date:~3,2%%date:~0,2%_%time:~0,2%%time:~3,2%%time:~6,2%.txt

:: === ROBOCOPY ===
echo.
echo ================================
echo  COPIANDO ARCHIVOS...
echo ================================
echo.
echo Origen: %SOURCE%
echo Destino: %DRIVE%\%DEST%\%FOLDER_NAME%
echo.
echo Por favor espere, esto puede tardar varios minutos...
echo.

echo Archivo de registro:
echo %LOG%
echo.
echo --------------------------------
echo Progreso de transferencia:
echo --------------------------------
echo.


robocopy "%SOURCE%" "%DRIVE%\%DEST%\%FOLDER_NAME%" ^
 /E /Z /DCOPY:DAT /COPY:DAT ^
 /MT:16 /R:3 /W:10 ^
 /NFL /NDL /NJH /NP ^
 /TEE /LOG:"%LOG%"


echo.
echo ================================
echo  TRANSFERENCIA COMPLETADA
echo ================================
echo.
echo Detalles guardados en: %LOG%
echo.
echo.

:: === PREGUNTAR SI CONTINUAR ===
set /p CONTINUE=Desea realizar otra transferencia? (S/N):
if /i "%CONTINUE%"=="S" goto INICIO
if /i "%CONTINUE%"=="SI" goto INICIO

:: === DESCONECTAR UNIDAD AL SALIR ===
echo.
echo Desconectando unidad...
net use %DRIVE% /delete /y >nul 2>&1

echo Saliendo...
timeout /t 2 >nul
