<#
.SYNOPSIS
    Script automatizado para transferencia de archivos a NAS mediante Robocopy

.DESCRIPTION
    Sistema completo de transferencia con validaciones optimizadas, monitoreo eficiente,
    manejo de errores y protección contra pérdida de conexión.
    Optimizado para carpetas grandes y rutas largas (+240 caracteres).

.FEATURES
    - Arquitectura UNC directa (sin mapeo de unidades)
    - Validaciones eficientes con un solo escaneo de origen
    - Detección simple y rápida de archivos existentes
    - Monitoreo liviano basado en tamaño de log
    - Protección contra pérdida de conexión y bucles de reintentos
    - Timeout dinámico según tamaño de archivos
    - Manejo de rutas largas (>240 caracteres)
    - Logs individuales con rotación automática
    - Exclusión opcional de archivos temporales
    - Optimizado para proyectos de ingeniería civil
#>

#Requires -Version 1.0

#region ===== CONFIGURACIÓN GLOBAL =====

# Constantes del sistema
$SCRIPT_VERSION = "1.0"
$LOG_DIRECTORY = "C:\Logs"
$LOG_RETENTION_DAYS = 30
$CONNECTION_CHECK_INTERVAL = 10  # segundos
$MIN_TIMEOUT_SECONDS = 300       # 5 minutos mínimo

# Configuración NAS predefinida
$NAS_PRESETS = @{
    "1" = @{ Name = "Historico"; Path = "\\192.168.1.254\Historico" }
    "2" = @{ Name = "EDI";       Path = "\\192.168.1.254\edi" }
    "3" = @{ Name = "ATO";       Path = "\\192.168.1.254\ato" }
    "4" = @{ Name = "Pruebas";   Path = "\\192.168.1.254\Pruebas" }
    "5" = @{ Name = "Otra";      Path = "" }
}

# Variables de sesión
$Script:DateTag = Get-Date -Format "yyyyMMdd_HHmmss"
$Script:TransferenciaContador = 1
$Script:LastLogSize = 0
$Script:LastActivity = Get-Date
$Script:NASPath = ""  # Ruta UNC del NAS seleccionado

#endregion

#region ===== FUNCIONES DE UTILIDAD =====

function Write-SectionHeader {
    <#
    .SYNOPSIS
        Muestra un encabezado de sección formateado
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Title,
        
        [Parameter()]
        [ConsoleColor]$Color = 'Cyan'
    )
    
    Write-Host ""
    Write-Host "================================" -ForegroundColor $Color
    Write-Host " $Title" -ForegroundColor $Color
    Write-Host "================================" -ForegroundColor $Color
    Write-Host ""
}

function Confirm-UserAction {
    <#
    .SYNOPSIS
        Solicita confirmación del usuario
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [Parameter()]
        [string]$PromptText = "Ingrese S para continuar o N para colocar otro destino"
    )
    
    Write-SectionHeader -Title "CONFIRMACION DE OPERACION" -Color Cyan
    Write-Host $Message
    Write-Host ""
    $response = Read-Host $PromptText
    
    return ($response -match '^(S|SI|Y|YES)$')
}

function Test-NASConnection {
    <#
    .SYNOPSIS
        Verifica la conectividad con el NAS usando ruta UNC
    #>
    param(
        [Parameter(Mandatory)]
        [string]$UNCPath
    )
    
    try {
        # Intentar acceder a la ruta UNC
        $null = Get-ChildItem -Path $UNCPath -ErrorAction Stop | Select-Object -First 1
        return $true
    } catch {
        return $false
    }
}



function Get-FolderSize {
    <#
    .SYNOPSIS
        Calcula el tamaño total de una carpeta
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $files = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue
    $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
    
    # Asegurar que totalSize nunca sea null
    if ($null -eq $totalSize) {
        $totalSize = 0
    }
    
    return @{
        TotalBytes = $totalSize
        TotalMB = [math]::Round(($totalSize / 1MB), 2)
        TotalGB = [math]::Round(($totalSize / 1GB), 2)
        FileCount = if ($files) { $files.Count } else { 0 }
    }
}

#endregion

#region ===== FUNCIONES DE VALIDACIÓN =====

function Test-ValidPath {
    <#
    .SYNOPSIS
        Valida que una ruta exista y sea una carpeta
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    if (-not (Test-Path $Path)) {
        Write-Host "`nERROR: La ruta no existe: $Path" -ForegroundColor Red
        return $false
    }
    
    if (-not (Test-Path $Path -PathType Container)) {
        Write-Host "`nERROR: La ruta debe ser una carpeta, no un archivo" -ForegroundColor Red
        return $false
    }
    
    return $true
}

function Test-InvalidCharactersInFiles {
    <#
    .SYNOPSIS
        Detecta archivos con caracteres especiales inválidos
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $invalidChars = '[<>"|?*]'
    $problematicFiles = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match $invalidChars }
    
    if ($problematicFiles) {
        Write-Host "ADVERTENCIA: Archivos con caracteres especiales inválidos:" -ForegroundColor Yellow
        Write-Host "Caracteres problemáticos: < > : `" | ? *`n" -ForegroundColor Yellow
        
        $showCount = [math]::Min(5, $problematicFiles.Count)
        for ($i = 0; $i -lt $showCount; $i++) {
            Write-Host "  - $($problematicFiles[$i].Name)" -ForegroundColor Red
        }
        
        if ($problematicFiles.Count -gt 5) {
            Write-Host "  ... y $($problematicFiles.Count - 5) archivo(s) más" -ForegroundColor Gray
        }
        
        return $false
    }
    
    return $true
}

function Test-LongPaths {
    <#
    .SYNOPSIS
        Detecta rutas muy largas que pueden causar problemas
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $longPaths = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.Length -gt 240 }
    
    if ($longPaths) {
        Write-Host "ADVERTENCIA: Rutas muy largas detectadas (>240 caracteres):" -ForegroundColor Yellow
        
        $showCount = [math]::Min(3, $longPaths.Count)
        for ($i = 0; $i -lt $showCount; $i++) {
            $path = $longPaths[$i].FullName
            if ($path.Length -gt 80) {
                $path = $path.Substring(0, 77) + "..."
            }
            $pathLength = $longPaths[$i].FullName.Length
            Write-Host "  - $path - $pathLength caracteres" -ForegroundColor Red
        }
        
        if ($longPaths.Count -gt 3) {
            $remaining = $longPaths.Count - 3
            Write-Host "  ... y $remaining archivos más" -ForegroundColor Gray
        }
        
        Write-Host "NOTA: El script usará rutas largas de Windows si es necesario`n" -ForegroundColor Cyan
    }
}

function Test-FilesInUse {
    <#
    .SYNOPSIS
        Detecta archivos que están en uso
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $commonLockedExtensions = '\.(docx?|xlsx?|pptx?|mdb|accdb|pst|ost|ldf|mdf)$'
    $filesToCheck = Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match $commonLockedExtensions }
    
    $filesInUse = @()
    foreach ($file in $filesToCheck) {
        try {
            $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'None')
            $stream.Close()
            $stream.Dispose()
        } catch {
            $filesInUse += $file.Name
        }
    }
    
    if ($filesInUse.Count -gt 0) {
        Write-Host "ADVERTENCIA: $($filesInUse.Count) archivo(s) podrían estar en uso:" -ForegroundColor Yellow
        
        $showCount = [math]::Min(5, $filesInUse.Count)
        for ($i = 0; $i -lt $showCount; $i++) {
            Write-Host "  - $($filesInUse[$i])" -ForegroundColor Red
        }
        
        if ($filesInUse.Count -gt 5) {
            Write-Host "  ... y $($filesInUse.Count - 5) archivo(s) más" -ForegroundColor Gray
        }
        
        Write-Host "`nRECOMENDACIÓN: Cierre los archivos antes de copiar" -ForegroundColor Yellow
        Write-Host "Robocopy intentará copiarlos con reintentos automáticos`n" -ForegroundColor Cyan
        
        return $false
    }
    
    return $true
}

function Show-SpecialAttributesInfo {
    <#
    .SYNOPSIS
        Muestra información sobre archivos con atributos especiales
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )
    
    $specialFiles = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -match 'ReadOnly|Hidden|System' }
    
    if ($specialFiles) {
        Write-Host "INFO: Archivos con atributos especiales detectados:" -ForegroundColor Cyan
        
        $readOnlyCount = ($specialFiles | Where-Object { $_.Attributes -match 'ReadOnly' }).Count
        $hiddenCount = ($specialFiles | Where-Object { $_.Attributes -match 'Hidden' }).Count
        $systemCount = ($specialFiles | Where-Object { $_.Attributes -match 'System' }).Count
        
        if ($readOnlyCount -gt 0) {
            Write-Host "  - $readOnlyCount archivo(s) de solo lectura (Read-Only)" -ForegroundColor Gray
        }
        if ($hiddenCount -gt 0) {
            Write-Host "  - $hiddenCount archivo(s) ocultos (Hidden)" -ForegroundColor Gray
        }
        if ($systemCount -gt 0) {
            Write-Host "  - $systemCount archivo(s) de sistema (System)" -ForegroundColor Gray
        }
        
        Write-Host "Estos archivos serán copiados preservando sus atributos`n" -ForegroundColor Green
    }
}

#endregion

#region ===== FUNCIÓN PRINCIPAL DE TRANSFERENCIA =====

function Start-FileTransfer {
    <#
    .SYNOPSIS
        Ejecuta la transferencia con Robocopy y monitorea el progreso
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Source,
        
        [Parameter(Mandatory)]
        [string]$Destination,
        
        [Parameter(Mandatory)]
        [string]$LogFile,
        
        [Parameter()]
        [string]$Strategy = "",
        
        [Parameter()]
        [string]$ExcludeParams = "",
        
        [Parameter()]
        [int]$TimeoutSeconds = 300,
        
        [Parameter()]
        [double]$SourceSizeBytes = 0,
        
        [Parameter(Mandatory)]
        [string]$NASPath
    )
    
    # Configurar argumentos de Robocopy
    $robocopyArgs = @(
        "`"$Source`"",
        "`"$Destination`"",
        "/E /Z /MT:16 /R:10 /W:30 $Strategy $ExcludeParams",
        "/COPY:DATS /DCOPY:DAT /A-:SH",
        "/LOG:`"$LogFile`"",
        "/NFL /NDL /NP",
        "/V /TS /FP /BYTES /X /XX"
    )
    
    Write-Host "Iniciando transferencia...`n" -ForegroundColor Green
    Write-Host "Ejecutando: robocopy $($robocopyArgs -join ' ')`n" -ForegroundColor Gray
    Write-Host "Copiando archivos... (puede tardar varios minutos)" -ForegroundColor Cyan
    Write-Host "Monitor de actividad:" -ForegroundColor Cyan
    
    # Iniciar proceso de Robocopy
    $process = Start-Process robocopy -ArgumentList $robocopyArgs -NoNewWindow -PassThru
    
    # Variables de monitoreo
    $lastLogSize = 0
    $lastActivity = Get-Date
    $lastConnectionCheck = Get-Date
    $checkCount = 0
    $errorCount = 0
    $lastErrorCheck = Get-Date
    
    # Mostrar progreso inicial inmediatamente
    Write-Progress -Activity "Copiando archivos..." `
        -Status "Iniciando copia... Espere mientras Robocopy analiza los archivos" `
        -PercentComplete 0
    
    # Monitoreo del proceso
    do {
        Start-Sleep 2
        $checkCount++
        
        # Verificar si el proceso sigue activo
        if (-not (Get-Process -Id $process.Id -ErrorAction SilentlyContinue)) {
            break
        }
        
        # Verificar conectividad periódicamente
        if (((Get-Date) - $lastConnectionCheck).TotalSeconds -ge $CONNECTION_CHECK_INTERVAL) {
            if (-not (Test-NASConnection -UNCPath $NASPath)) {
                Write-Progress -Activity "Copiando archivos..." -Completed
                
                Write-SectionHeader -Title "ERROR: CONEXION AL NAS PERDIDA" -Color Red
                Write-Host "Se detectó pérdida de conexión durante la transferencia." -ForegroundColor Yellow
                Write-Host "`nPosibles causas:" -ForegroundColor Yellow
                Write-Host "  - Cable de red desconectado" -ForegroundColor Yellow
                Write-Host "  - NAS apagado o reiniciado" -ForegroundColor Yellow
                Write-Host "  - Timeout de red" -ForegroundColor Yellow
                Write-Host "  - Credenciales expiradas`n" -ForegroundColor Yellow
                
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                
                Write-Host "Proceso detenido para prevenir corrupción de archivos." -ForegroundColor Red
                Write-Host "`nACCIONES RECOMENDADAS:" -ForegroundColor Cyan
                Write-Host "1. Verifique la conexión de red" -ForegroundColor Cyan
                Write-Host "2. Verifique que el NAS esté accesible" -ForegroundColor Cyan
                Write-Host "3. Ejecute el script nuevamente" -ForegroundColor Cyan
                Write-Host "4. Robocopy continuará desde donde se interrumpió (modo /Z)`n" -ForegroundColor Green
                
                Pause
                exit 1
            }
            $lastConnectionCheck = Get-Date
        }
        
        # Verificar actividad del log o archivos en destino
        $activityDetected = $false
        
        if (Test-Path $LogFile) {
            $logSize = (Get-Item $LogFile).Length
            if ($logSize -gt $lastLogSize) {
                $lastLogSize = $logSize
                $activityDetected = $true
            }
        }
        
        # Verificar actividad también mirando archivos modificados recientemente en destino
        if (-not $activityDetected) {
            try {
                $recentFiles = Get-ChildItem -Path $Destination -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -gt (Get-Date).AddSeconds(-30) } |
                    Select-Object -First 1
                
                if ($recentFiles) {
                    $activityDetected = $true
                }
            } catch {
                # Ignorar errores de acceso
            }
        }
        
        if ($activityDetected) {
            $lastActivity = Get-Date
            
            # Detectar errores repetidos cada 30 segundos
            if (((Get-Date) - $lastErrorCheck).TotalSeconds -ge 30) {
                $logContent = Get-Content $LogFile -Tail 20 -ErrorAction SilentlyContinue
                $recentErrors = ($logContent | Select-String -Pattern "ERROR|Esperando.*segundos.*Reintentando").Count
                
                if ($recentErrors -gt 5) {
                    $errorCount++
                    if ($errorCount -ge 3) {
                        Write-Progress -Activity "Copiando archivos..." -Completed
                        Write-Host "`n`nERROR: Robocopy atascado en bucle de reintentos" -ForegroundColor Red
                        Write-Host "Errores detectados en log. Revise: $LogFile" -ForegroundColor Yellow
                        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                        Pause
                        exit 1
                    }
                } else {
                    $errorCount = 0
                }
                $lastErrorCheck = Get-Date
            }
            
            # Mostrar progreso simple basado en log
            if (Test-Path $LogFile) {
                $logSizeKB = [math]::Round((Get-Item $LogFile).Length/1KB, 1)
                Write-Progress -Activity "Copiando archivos..." `
                    -Status "Robocopy activo - Log: $logSizeKB KB" `
                    -PercentComplete 50
                
                if ($checkCount % 15 -eq 0) {
                    Write-Host " [Log: $logSizeKB KB - Activo]" -ForegroundColor Cyan
                }
            }
        }
        
        # Verificar timeout
        if (((Get-Date) - $lastActivity).TotalSeconds -ge $TimeoutSeconds) {
            Write-Progress -Activity "Copiando archivos..." -Completed
            Write-Host "`nERROR: Robocopy sin actividad por $([math]::Round($TimeoutSeconds/60,1)) minutos" -ForegroundColor Red
            
            if (-not (Test-NASConnection -UNCPath $NASPath)) {
                Write-Host "CAUSA: Pérdida de conexión al NAS detectada" -ForegroundColor Red
            }
            
            Stop-Process -Id $process.Id -Force
            Pause
            exit 1
        }
            
    } while ($true)
    
    Write-Host "`n`nRobocopy completado. Procesando resultado..." -ForegroundColor Green
    Write-Progress -Activity "Copiando archivos..." -Completed
    
    # Esperar a que termine el proceso y obtener exit code
    $process.WaitForExit()
    return $process.ExitCode
}

function Get-RobocopyExitCodeMessage {
    <#
    .SYNOPSIS
        Interpreta el código de salida de Robocopy
    #>
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode
    )
    
    $result = @{
        IsError = $false
        Message = ""
        Color = "Green"
    }
    
    switch ($ExitCode) {
        0 {
            $result.Message = "Sin cambios - Archivos ya sincronizados"
            $result.Color = "Cyan"
        }
        1 {
            $result.Message = "Éxito - Archivos copiados correctamente"
            $result.Color = "Green"
        }
        2 {
            $result.Message = "Éxito - Archivos extra detectados en destino"
            $result.Color = "Green"
        }
        3 {
            $result.Message = "Éxito - Archivos copiados y extras detectados"
            $result.Color = "Green"
        }
        { $_ -ge 8 } {
            $result.IsError = $true
            $result.Message = "ERROR GRAVE - Algunos archivos NO se copiaron"
            $result.Color = "Red"
        }
        { $_ -ge 4 } {
            $result.Message = "ADVERTENCIA - Algunos archivos no coinciden o hubo errores menores"
            $result.Color = "Yellow"
        }
    }
    
    return $result
}

#endregion

#region ===== SCRIPT PRINCIPAL =====

# Inicialización
Clear-Host
$Host.UI.RawUI.WindowTitle = "Transferencia Automatizada NAS v$SCRIPT_VERSION"

Write-Host "================================"
Write-Host " TRANSFERENCIA AUTOMATIZADA NAS"
Write-Host " Versión $SCRIPT_VERSION"
Write-Host "================================"
Write-Host ""

# Crear directorio de logs si no existe
if (-not (Test-Path $LOG_DIRECTORY)) {
    New-Item -ItemType Directory -Path $LOG_DIRECTORY | Out-Null
}

# Selección de carpeta NAS
Write-Host "Seleccione la carpeta de destino en el NAS:" -ForegroundColor Cyan
Write-Host ""
foreach ($key in ($NAS_PRESETS.Keys | Sort-Object)) {
    Write-Host "  $key. $($NAS_PRESETS[$key].Name)"
}
Write-Host ""

do {
    $option = Read-Host "Ingrese opción (1-5)"
    
    if ($NAS_PRESETS.ContainsKey($option)) {
        $selectedNAS = $NAS_PRESETS[$option].Path
        
        # Si el path está vacío, solicitar entrada manual
        if ([string]::IsNullOrEmpty($selectedNAS)) {
            do {
                $selectedNAS = Read-Host "Ingrese la ruta completa del NAS (ej: \\192.168.1.254\MiCarpeta)"
                
                if ($selectedNAS -notmatch '^\\\\[^\\]+\\[^\\]+') {
                    Write-Host "ERROR: La ruta debe tener formato UNC (\\servidor\recurso)" -ForegroundColor Red
                    $retry = Read-Host "¿Desea intentar nuevamente? (S/N)"
                    if ($retry -notmatch '^(S|SI|Y|YES)$') {
                        $option = $null
                        break
                    }
                    $selectedNAS = $null
                    continue
                }
                
                Write-Host "Verificando accesibilidad..." -ForegroundColor Cyan
                if (-not (Test-Path $selectedNAS -ErrorAction SilentlyContinue)) {
                    Write-Host "ADVERTENCIA: No se puede acceder a la ruta" -ForegroundColor Yellow
                    $continue = Read-Host "¿Continuar de todos modos? (S/N)"
                    if ($continue -notmatch '^(S|SI|Y|YES)$') {
                        $selectedNAS = $null
                        continue
                    }
                }
                
                break
            } while ($true)
            
            if ($null -eq $option) { continue }
        }
        
        break
    } else {
        Write-Host "Opción inválida. Intente nuevamente." -ForegroundColor Yellow
        $option = $null
    }
} while ($null -eq $option)

Write-Host "`nCarpeta seleccionada: $selectedNAS" -ForegroundColor Green
Write-Host ""

# Guardar ruta NAS en variable de script
$Script:NASPath = $selectedNAS

# Autenticar con el NAS
Write-Host "Conectando al NAS..." -ForegroundColor Cyan
Write-Host "Ruta: $Script:NASPath" -ForegroundColor Gray

# Verificar si necesita credenciales intentando acceso directo
$needsCredentials = $false

try {
    Write-Host "Verificando acceso..." -ForegroundColor Gray
    $null = Get-ChildItem -Path $Script:NASPath -ErrorAction Stop | Select-Object -First 1
    Write-Host "Conexión establecida correctamente (credenciales guardadas)" -ForegroundColor Green
} catch {
    $needsCredentials = $true
}

if ($needsCredentials) {
    Write-Host "`nSe requieren credenciales para acceder al NAS." -ForegroundColor Yellow
    Write-Host "Se abrirá una ventana para ingresar usuario y contraseña...`n" -ForegroundColor Cyan
    
    try {
        $credential = Get-Credential -Message "Ingrese sus credenciales para $Script:NASPath"
    } catch {
        Write-Host "ERROR: No se pudo abrir ventana de credenciales" -ForegroundColor Red
        Write-Host "Intente conectarse primero manualmente al NAS desde Explorador de Archivos`n" -ForegroundColor Yellow
        Pause
        exit 1
    }
    
    if ($null -eq $credential) {
        Write-Host "`nOperación cancelada por el usuario" -ForegroundColor Yellow
        Write-Host "Puede conectarse manualmente al NAS desde Explorador de Archivos y ejecutar el script nuevamente`n" -ForegroundColor Cyan
        Pause
        exit 1
    }
    
    $username = $credential.UserName
    $password = $credential.GetNetworkCredential().Password
    
    Write-Host "Autenticando con el NAS..." -ForegroundColor Cyan
    
    # Autenticar con credenciales
    net use $Script:NASPath /user:$username $password /persistent:no 2>$null | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nERROR: No se pudo conectar al NAS" -ForegroundColor Red
        Write-Host "Verifique que:" -ForegroundColor Yellow
        Write-Host "  - El usuario y contraseña sean correctos" -ForegroundColor Yellow
        Write-Host "  - El NAS esté encendido y accesible" -ForegroundColor Yellow
        Write-Host "  - Tiene permisos para acceder a esta carpeta`n" -ForegroundColor Yellow
        Pause
        exit 1
    }
    
    Write-Host "Conexión establecida correctamente" -ForegroundColor Green
}

Write-Host "Las credenciales se mantendrán activas durante la sesión`n" -ForegroundColor Cyan

# Bucle principal de transferencias
do {
    Clear-Host
    Write-SectionHeader -Title "TRANSFERENCIA AUTOMATIZADA NAS" -Color Cyan
    
    # Solicitar ruta origen
    $sourcePath = Read-Host "Ingrese ruta ORIGEN (carpeta completa)"
    
    # Validar ruta origen
    if (-not (Test-ValidPath -Path $sourcePath)) {
        Write-Host "Verifique la ruta e intente nuevamente.`n" -ForegroundColor Yellow
        continue
    }
    
    # Validaciones de origen (OPTIMIZADO - un solo escaneo)
    Write-Host "`nAnalizando archivos de origen..." -ForegroundColor Cyan
    Write-Host "Esto puede tardar unos segundos en carpetas grandes..." -ForegroundColor Gray
    
    # Hacer UN SOLO escaneo del directorio
    $allFiles = Get-ChildItem -Path $sourcePath -Recurse -File -Force -ErrorAction SilentlyContinue
    
    if ($null -eq $allFiles -or $allFiles.Count -eq 0) {
        Write-Host "`nADVERTENCIA: No se encontraron archivos en la ruta de origen" -ForegroundColor Yellow
        $continueEmpty = Read-Host "¿Desea continuar de todos modos? (S/N)"
        if ($continueEmpty -notmatch '^(S|SI|Y|YES)$') {
            continue
        }
    }
    
    Write-Host "Archivos encontrados: $($allFiles.Count)" -ForegroundColor Green
    Write-Host "`nRealizando validaciones..." -ForegroundColor Cyan
    
    # Validar caracteres inválidos
    $invalidChars = '[<>"|?*]'
    $problematicFiles = $allFiles | Where-Object { $_.Name -match $invalidChars }
    
    if ($problematicFiles) {
        Write-Host "`nADVERTENCIA: $($problematicFiles.Count) archivo(s) con caracteres especiales" -ForegroundColor Yellow
        $continueWithInvalidChars = Read-Host "¿Desea continuar? (S/N)"
        if ($continueWithInvalidChars -notmatch '^(S|SI|Y|YES)$') {
            continue
        }
    }
    
    # Validar rutas largas
    $longPaths = $allFiles | Where-Object { $_.FullName.Length -gt 240 }
    if ($longPaths) {
        Write-Host "INFO: $($longPaths.Count) archivo(s) con rutas largas (>240 caracteres)" -ForegroundColor Cyan
    }
    
    # Validar archivos especiales
    $specialFiles = $allFiles | Where-Object { $_.Attributes -match 'ReadOnly|Hidden|System' }
    if ($specialFiles) {
        Write-Host "INFO: $($specialFiles.Count) archivo(s) con atributos especiales" -ForegroundColor Cyan
    }
    
    # Bucle de validación de destino
    do {
        $destPath = Read-Host "`nIngrese ruta DESTINO dentro del NAS"
        
        $folderName = Split-Path $sourcePath -Leaf
        $finalDestination = Join-Path $Script:NASPath "$destPath\$folderName"
        
        $currentLogFile = "$LOG_DIRECTORY\robocopy_$($Script:DateTag)_transferencia$($Script:TransferenciaContador).txt"
        
        Write-Host "`nResumen:"
        Write-Host "Origen : $sourcePath"
        Write-Host "Destino: $finalDestination"
        Write-Host "Log    : $currentLogFile"
        
        if (Confirm-UserAction -Message "¿Desea iniciar la transferencia?") {
            break
        } else {
            Write-Host "`nVolviendo a solicitar ruta de destino...`n" -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    } while ($true)
    
    # Calcular tamaño de origen usando archivos ya escaneados
    Write-Host "`nCalculando tamaño total..." -ForegroundColor Cyan
    $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $totalSize) { $totalSize = 0 }
    
    $totalMB = [math]::Round($totalSize / 1MB, 2)
    $fileCount = $allFiles.Count
    Write-Host "Tamaño total: $totalMB MB - $fileCount archivos`n" -ForegroundColor Green
    
    # Crear directorio destino
    New-Item -ItemType Directory -Path $finalDestination -Force | Out-Null
    
    # Detectar si destino tiene archivos (RÁPIDO - sin escaneo profundo)
    Write-Host "`nVerificando destino..." -ForegroundColor Cyan
    
    $hasExistingFiles = $false
    $existingFiles = @()
    
    if (Test-Path $finalDestination) {
        # Obtener primeros archivos para muestra rápida
        $existingFiles = @(Get-ChildItem -Path $finalDestination -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 50)
        $hasExistingFiles = ($existingFiles.Count -gt 0)
    }
    
    $strategyParams = ""
    
    if ($hasExistingFiles) {
        Write-Host "El destino contiene archivos existentes" -ForegroundColor Yellow
        Write-Host "`nInformación de la transferencia:" -ForegroundColor Cyan
        Write-Host "  Total de archivos en ORIGEN: $fileCount archivos" -ForegroundColor White
        Write-Host "  Tamaño total: $totalMB MB" -ForegroundColor White
        Write-Host "  Archivos encontrados en DESTINO: $($existingFiles.Count)+ archivos" -ForegroundColor Gray
        
        # Preguntar si quiere ver análisis previo
        $showFiles = Read-Host "`n¿Desea analizar archivos antes de copiar? (S/N)"
        
        if ($showFiles -match '^(S|SI|Y|YES)$') {
            Write-Host "`nAnalizando archivos de ORIGEN (muestra de hasta 20)..." -ForegroundColor Cyan
            Write-Host "Comparando con archivos en destino para estrategia 'Reemplazar si es más nuevo'`n" -ForegroundColor Yellow
            
            $willCopy = 0      # Nuevos o más recientes
            $willSkip = 0      # Misma fecha o más viejos
            $showCount = [math]::Min(20, $allFiles.Count)
            
            for ($i = 0; $i -lt $showCount; $i++) {
                $srcFile = $allFiles[$i]
                $relPath = $srcFile.FullName.Replace($sourcePath, "")
                $destFilePath = Join-Path $finalDestination $relPath
                
                if (Test-Path $destFilePath) {
                    # Archivo existe en destino - comparar fechas
                    $destFile = Get-Item $destFilePath -ErrorAction SilentlyContinue
                    if ($destFile) {
                        if ($srcFile.LastWriteTime -gt $destFile.LastWriteTime) {
                            # Origen más nuevo → SE COPIARÁ
                            Write-Host "  ✓ $relPath" -ForegroundColor Green -NoNewline
                            Write-Host " [MÁS NUEVO - se copiará]" -ForegroundColor Yellow
                            $willCopy++
                        } elseif ($srcFile.LastWriteTime -lt $destFile.LastWriteTime) {
                            # Origen más viejo → SE OMITIRÁ
                            Write-Host "  ✗ $relPath" -ForegroundColor Gray -NoNewline
                            Write-Host " [más viejo - se omitirá]" -ForegroundColor DarkGray
                            $willSkip++
                        } else {
                            # Misma fecha → SE OMITIRÁ
                            Write-Host "  ✗ $relPath" -ForegroundColor Gray -NoNewline
                            Write-Host " [misma fecha - se omitirá]" -ForegroundColor DarkGray
                            $willSkip++
                        }
                    }
                } else {
                    # Archivo NO existe en destino → SE COPIARÁ
                    Write-Host "  ✓ $relPath" -ForegroundColor Green -NoNewline
                    Write-Host " [NUEVO - se copiará]" -ForegroundColor Cyan
                    $willCopy++
                }
            }
            
            if ($allFiles.Count -gt 20) {
                $remaining = $allFiles.Count - 20
                Write-Host "`n  ... y $remaining archivo(s) más no mostrados" -ForegroundColor Gray
            }
            
            Write-Host "`n" -NoNewline
            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host "PREDICCIÓN PARA ESTRATEGIA #1 (Reemplazar si es más nuevo):" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
            Write-Host "  ✓ Se copiarán (nuevos o más recientes): $willCopy" -ForegroundColor Green
            Write-Host "  ✗ Se omitirán (misma fecha o más viejos): $willSkip" -ForegroundColor Gray
            Write-Host "`n" -NoNewline
            Write-Host "  💡 Este análisis es SOLO para estrategia #1" -ForegroundColor Yellow
            Write-Host "     Si elige opción 2 o 3, el comportamiento será diferente" -ForegroundColor Gray
            Write-Host "     Robocopy procesará los $fileCount archivos totales" -ForegroundColor Cyan
            Write-Host "========================================" -ForegroundColor Cyan
        }
        
        Write-Host ""
        Write-Host "Seleccione estrategia de copia:" -ForegroundColor Cyan
        Write-Host "(Esta estrategia se aplicará a TODOS los archivos de la transferencia)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  1. Reemplazar si es más nuevo (recomendado)"
        Write-Host "  2. Omitir archivos existentes"
        Write-Host "  3. Sobrescribir todo"
        Write-Host ""
        
        $strategy = Read-Host "Seleccione (1-3, Enter=1)"
        if ([string]::IsNullOrWhiteSpace($strategy)) { $strategy = "1" }
        
        switch ($strategy) {
            "1" { 
                $strategyParams = "/XO"
                Write-Host "Estrategia: Reemplazar más nuevos" -ForegroundColor Green
                Write-Host "Robocopy copiará solo archivos cuya fecha de origen sea más reciente" -ForegroundColor Cyan
                Write-Host "Omitirá automáticamente archivos con misma fecha o más viejos" -ForegroundColor Gray
            }
            "2" { 
                $strategyParams = "/XC /XN /XO"
                Write-Host "Estrategia: Omitir existentes" -ForegroundColor Green
                Write-Host "Robocopy NO tocará ningún archivo que ya exista en destino" -ForegroundColor Cyan
            }
            "3" { 
                $strategyParams = "/IS /IT"
                Write-Host "Estrategia: Sobrescribir todo" -ForegroundColor Green
                Write-Host "Robocopy reemplazará TODOS los archivos sin importar la fecha" -ForegroundColor Yellow
                Write-Host "Incluye archivos idénticos (fuerza copia completa)" -ForegroundColor Gray
            }
            default { $strategyParams = "/XO" }
        }
        Write-Host ""
    } else {
        Write-Host "Destino vacío. Procediendo con copia normal`n" -ForegroundColor Green
    }
    
    # Opciones avanzadas
    Write-SectionHeader -Title "OPCIONES AVANZADAS" -Color Cyan
    Write-Host "¿Desea excluir archivos temporales y de sistema?" -ForegroundColor Cyan
    Write-Host "  - Archivos temporales: ~$*, *.tmp, *.temp, *.bak" -ForegroundColor Gray
    Write-Host "  - Carpetas del sistema: Thumbs.db, .DS_Store, desktop.ini`n" -ForegroundColor Gray
    
    $excludeTemps = Read-Host "¿Excluir archivos temporales? (S/N)"
    $excludeParams = ""
    
    if ($excludeTemps -match '^(S|SI|Y|YES)$') {
        $excludeParams = "/XF ~$* *.tmp *.temp *.bak Thumbs.db .DS_Store desktop.ini /XD `$RECYCLE.BIN `"System Volume Information`""
        Write-Host "Archivos temporales serán excluidos`n" -ForegroundColor Green
    } else {
        Write-Host "Se copiarán todos los archivos`n" -ForegroundColor Yellow
    }
    
    # Verificar espacio en destino
    Write-Host "Verificando espacio disponible..." -ForegroundColor Cyan
    
    try {
        # Obtener información del volumen usando WMI
        $nasServer = ($Script:NASPath -split '\\')[2]
        $nasShare = ($Script:NASPath -split '\\')[3]
        
        # Intentar obtener espacio libre
        $wmiQuery = "SELECT * FROM Win32_MappedLogicalDisk WHERE ProviderName LIKE '%$nasServer%'"
        $mappedDrive = Get-WmiObject -Query $wmiQuery -ErrorAction SilentlyContinue | Select-Object -First 1
        
        if ($mappedDrive) {
            $freeSpaceGB = [math]::Round($mappedDrive.FreeSpace / 1GB, 2)
            
            Write-Host "Espacio requerido: $totalGB GB" -ForegroundColor Cyan
            Write-Host "Espacio disponible: $freeSpaceGB GB" -ForegroundColor Cyan
            
            if ($mappedDrive.FreeSpace -lt ($totalSize * 1.1)) {
                Write-Host "`nADVERTENCIA: Espacio insuficiente" -ForegroundColor Red
                $continueAnyway = Read-Host "¿Continuar de todos modos? (S/N)"
                if ($continueAnyway -notmatch '^(S|SI|Y|YES)$') {
                    continue
                }
            } else {
                Write-Host "Espacio suficiente disponible`n" -ForegroundColor Green
            }
        } else {
            Write-Host "No se pudo verificar espacio (continuando de todos modos)`n" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "No se pudo verificar espacio en destino`n" -ForegroundColor Yellow
    }
    
    # Calcular timeout dinámico (más realista: 10 minutos por GB + 20 min base)
    $totalGB = [math]::Round($totalSize / 1GB, 2)
    $baseTimeout = 1200  # 20 minutos base
    $timeoutSeconds = [math]::Max($MIN_TIMEOUT_SECONDS, $baseTimeout + (600 * [math]::Ceiling($totalGB)))
    Write-Host "Timeout configurado: $([math]::Round($timeoutSeconds / 60, 1)) minutos (ajustado según tamaño)`n" -ForegroundColor Cyan
    
    # Configurar parámetros de Robocopy
    Write-Host "Configurando parámetros de copia resiliente..." -ForegroundColor Cyan
    Write-Host "  - Modo reiniciable (/Z) - Permite continuar copias interrumpidas" -ForegroundColor Gray
    Write-Host "  - 10 reintentos con 30 segundos de espera" -ForegroundColor Gray
    Write-Host "  - Copia de atributos especiales" -ForegroundColor Gray
    Write-Host "  - Verificación de conectividad cada $CONNECTION_CHECK_INTERVAL segundos`n" -ForegroundColor Gray
    
    # Ejecutar transferencia
    $exitCode = Start-FileTransfer -Source $sourcePath `
        -Destination $finalDestination `
        -LogFile $currentLogFile `
        -Strategy $strategyParams `
        -ExcludeParams $excludeParams `
        -TimeoutSeconds $timeoutSeconds `
        -SourceSizeBytes $totalSize `
        -NASPath $Script:NASPath
    
    # Validar resultado (corrección silenciosa de exit code si es necesario)
    if (Test-Path $currentLogFile) {
        $logContent = Get-Content $currentLogFile -ErrorAction SilentlyContinue
        
        # Detectar archivos copiados del log
        $actualFilesCopied = 0
        foreach ($line in $logContent) {
            if ($line -match "^\s*Archivos:\s+(\d+)\s+(\d+)\s+(\d+)") {
                $actualFilesCopied = [int]$matches[2]
                break
            }
        }
        
        # Corregir exit code si es necesario (silenciosamente)
        if ($exitCode -eq 0 -and $actualFilesCopied -gt 0) {
            $exitCode = 1
        }
    }
    
    $exitResult = Get-RobocopyExitCodeMessage -ExitCode $exitCode
    
    # Resumen
    Clear-Host
    Write-Host "--------------------------------"
    Write-Host " RESUMEN DE TRANSFERENCIA"
    Write-Host "--------------------------------"
    Write-Host ""
    
    if (Test-Path $currentLogFile) {
        # Buscar sección de resumen de Robocopy
        $logContent = Get-Content $currentLogFile
        $summaryStart = -1
        
        for ($i = 0; $i -lt $logContent.Count; $i++) {
            if ($logContent[$i] -match "^\s+(Dirs\s*:|Archivos\s*:|Bytes\s*:)" -or 
                $logContent[$i] -match "^\s+Total\s+Copiado\s+Omitido" -or
                $logContent[$i] -match "------------------------------------------------------------------------------" -and 
                $i -gt 10 -and $logContent.Count - $i -lt 50) {
                $summaryStart = $i
                break
            }
        }
        
        if ($summaryStart -ge 0) {
            # Mostrar desde el inicio del resumen hasta el final o las próximas 30 líneas
            $endLine = [math]::Min($summaryStart + 30, $logContent.Count - 1)
            for ($i = $summaryStart; $i -le $endLine; $i++) {
                # Saltar líneas que solo contienen guiones o están vacías
                if ($logContent[$i] -match "^[\s-]*$") {
                    continue
                }
                if ($logContent[$i] -match "Finalizado|Ended" -and $i -gt $summaryStart + 5) {
                    break
                }
                Write-Host $logContent[$i]
            }
        } else {
            Write-Host "No se encontró resumen en el log" -ForegroundColor Yellow
            Write-Host "Verifique el archivo de log para más detalles: $currentLogFile" -ForegroundColor Gray
        }
    }
    
    Write-Host "`n================================"
    Write-Host " TRANSFERENCIA COMPLETADA"
    Write-Host "================================"
    Write-Host "Log: $currentLogFile"
    Write-Host ""
    
    # Incrementar contador
    $Script:TransferenciaContador++
    
    # Preguntar si continuar
    $continue = Read-Host "¿Desea realizar otra transferencia? (S/N)"
    
} while ($continue -match '^(S|SI|Y|YES)$')

# Limpieza final
Write-Host "`nCerrando sesión con el NAS..." -ForegroundColor Cyan
net use $Script:NASPath /delete /y 2>$null | Out-Null
Write-Host "Sesión cerrada correctamente" -ForegroundColor Green

# Gestión de logs antiguos
Write-Host "Verificando logs antiguos..." -ForegroundColor Cyan

$oldLogs = Get-ChildItem -Path $LOG_DIRECTORY -Filter "robocopy_*.txt" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LOG_RETENTION_DAYS) }

if ($oldLogs) {
    Write-Host "Se encontraron $($oldLogs.Count) log(s) con más de $LOG_RETENTION_DAYS días" -ForegroundColor Yellow
    
    $totalSize = ($oldLogs | Measure-Object -Property Length -Sum).Sum
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)
    
    Write-Host "Espacio ocupado: $totalSizeMB MB" -ForegroundColor Yellow
    
    $deleteLogs = Read-Host "¿Desea eliminar logs antiguos? (S/N)"
    
    if ($deleteLogs -match '^(S|SI|Y|YES)$') {
        $oldLogs | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "Logs antiguos eliminados" -ForegroundColor Green
    }
}

Write-Host "`nProceso finalizado." -ForegroundColor Green
Write-Host "Logs de sesión guardados en: $LOG_DIRECTORY" -ForegroundColor Cyan

#endregion
