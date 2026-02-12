<#
.SYNOPSIS
    Script automatizado para transferencia de archivos a NAS mediante Robocopy

.DESCRIPTION
    Sistema completo de transferencia con validaciones, detección de conflictos,
    monitoreo de progreso real, manejo de errores y protección contra pérdida de conexión

.NOTES
    Versión: 3.0
    Autor: Sistema Automatizado
    Fecha: 2026-02-12
    
.FEATURES
    - Detección inteligente de conflictos
    - Modo de comparación rápido y avanzado (hash MD5)
    - Progreso real en tiempo real
    - Validación de espacio en destino
    - Timeout dinámico según tamaño
    - Protección contra pérdida de conexión
    - Manejo de archivos especiales y en uso
    - Logs individuales con rotación automática
#>

#Requires -Version 5.1

#region ===== CONFIGURACIÓN GLOBAL =====

# Constantes del sistema
$SCRIPT_VERSION = "3.1"
$LOG_DIRECTORY = "C:\Logs"
$LOG_RETENTION_DAYS = 30
$CONNECTION_CHECK_INTERVAL = 10  # segundos
$MIN_TIMEOUT_SECONDS = 300       # 5 minutos mínimo

# Configuración NAS predefinida
$NAS_PRESETS = @{
    "1" = @{ Name = "Pruebas";   Path = "\\192.168.1.254\Pruebas" }
    "2" = @{ Name = "Historico"; Path = "\\192.168.1.254\Historico" }
    "3" = @{ Name = "EDI";       Path = "\\192.168.1.254\edi" }
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
        [string]$PromptText = "Ingrese S para continuar"
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

function Get-FileHashMD5 {
    <#
    .SYNOPSIS
        Calcula el hash MD5 de un archivo
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )
    
    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm MD5 -ErrorAction Stop
        return $hash.Hash
    } catch {
        return $null
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
    
    return @{
        TotalBytes = if ($totalSize) { $totalSize } else { 0 }
        TotalMB = [math]::Round(($totalSize / 1MB), 2)
        TotalGB = [math]::Round(($totalSize / 1GB), 2)
        FileCount = $files.Count
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

#region ===== FUNCIONES DE DETECCIÓN DE CONFLICTOS =====

function Find-FileConflicts {
    <#
    .SYNOPSIS
        Detecta conflictos entre archivos de origen y destino
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        
        [Parameter(Mandatory)]
        [string]$DestinationPath,
        
        [Parameter()]
        [bool]$UseHashComparison = $false
    )
    
    $conflicts = @()
    $filesForHash = @()
    
    if (-not (Test-Path $DestinationPath)) {
        return @{ Conflicts = $conflicts; HasConflicts = $false }
    }
    
    $destFiles = Get-ChildItem -Path $DestinationPath -Recurse -File -ErrorAction SilentlyContinue
    if ($destFiles.Count -eq 0) {
        return @{ Conflicts = $conflicts; HasConflicts = $false }
    }
    
    Write-Host "Fase 1: Comparando metadata..." -ForegroundColor Cyan
    $sourceFiles = Get-ChildItem -Path $SourcePath -Recurse -File -ErrorAction SilentlyContinue
    $fileCount = 0
    
    foreach ($sourceFile in $sourceFiles) {
        $fileCount++
        $relativePath = $sourceFile.FullName.Substring($SourcePath.Length)
        $destFilePath = Join-Path $DestinationPath $relativePath
        
        if (Test-Path $destFilePath) {
            $destFile = Get-Item $destFilePath
            
            $sourceDate = $sourceFile.LastWriteTime
            $destDate = $destFile.LastWriteTime
            $sourceSize = $sourceFile.Length
            $destSize = $destFile.Length
            
            $status = ""
            $needsHash = $false
            
            if ($sourceDate -gt $destDate) {
                $status = "[MAS NUEVO]"
            } elseif ($sourceDate -lt $destDate) {
                $status = "[MAS VIEJO]"
            } elseif ($sourceSize -ne $destSize) {
                $status = "[DIFERENTE TAMAÑO]"
            } else {
                # Mismo tamaño y fecha
                if ($UseHashComparison) {
                    $needsHash = $true
                    $filesForHash += @{
                        Source = $sourceFile.FullName
                        Destination = $destFilePath
                        RelativePath = $relativePath
                    }
                } else {
                    $status = "[IDENTICO]"
                }
            }
            
            if ($status) {
                $conflicts += "$status $relativePath"
            }
        }
    }
    
    Write-Host "Fase 1 completada: $fileCount archivo(s) analizados" -ForegroundColor Green
    
    # Fase 2: Verificar hash si es necesario
    if ($UseHashComparison -and $filesForHash.Count -gt 0) {
        Write-Host "`nFase 2: Calculando hash de $($filesForHash.Count) archivo(s)..." -ForegroundColor Cyan
        $hashCount = 0
        
        foreach ($item in $filesForHash) {
            $hashCount++
            Write-Progress -Activity "Calculando hash MD5" `
                -Status "Archivo $hashCount de $($filesForHash.Count)" `
                -PercentComplete (($hashCount / $filesForHash.Count) * 100)
            
            $hashSource = Get-FileHashMD5 -FilePath $item.Source
            $hashDest = Get-FileHashMD5 -FilePath $item.Destination
            
            if ($null -eq $hashSource -or $null -eq $hashDest) {
                $status = "ERROR_HASH"
            } elseif ($hashSource -eq $hashDest) {
                $status = "IDENTICO_HASH_OK"
            } else {
                $status = "[IDENTICO - HASH DIFERENTE]"
            }
            
            $conflicts += "$status $($item.RelativePath)"
        }
        
        Write-Progress -Activity "Calculando hash MD5" -Completed
        Write-Host "Fase 2 completada: Hash verificado" -ForegroundColor Green
    }
    
    return @{
        Conflicts = $conflicts
        HasConflicts = ($conflicts.Count -gt 0)
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
        "/COPY:DATSOU /DCOPY:DAT /A-:SH",
        "/LOG:`"$LogFile`"",
        "/NFL /NDL /NP",
        "/V /TS /FP /BYTES /X /XX"
    )
    
    Write-Host "Iniciando transferencia...`n" -ForegroundColor Green
    
    # Iniciar proceso de Robocopy
    $process = Start-Process robocopy -ArgumentList $robocopyArgs -NoNewWindow -PassThru
    
    # Variables de monitoreo
    $lastLogSize = 0
    $lastActivity = Get-Date
    $lastConnectionCheck = Get-Date
    
    # Monitoreo del proceso
    do {
        Start-Sleep 2
        
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
        
        # Verificar actividad del log
        if (Test-Path $LogFile) {
            $logSize = (Get-Item $LogFile).Length
            if ($logSize -gt $lastLogSize) {
                $lastLogSize = $logSize
                $lastActivity = Get-Date
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
        
        # Calcular y mostrar progreso real
        $destSize = 0
        if (Test-Path $Destination) {
            $destFiles = Get-ChildItem -Path $Destination -Recurse -File -ErrorAction SilentlyContinue
            $destSize = ($destFiles | Measure-Object -Property Length -Sum).Sum
        }
        
        $percentComplete = 0
        if ($SourceSizeBytes -gt 0) {
            $percentComplete = [math]::Min(99, [math]::Round(($destSize / $SourceSizeBytes) * 100, 0))
        }
        
        $destSizeMB = [math]::Round($destSize / 1MB, 2)
        $sourceSizeMB = [math]::Round($SourceSizeBytes / 1MB, 2)
        
        Write-Progress -Activity "Copiando archivos..." `
            -Status "Transferido: $destSizeMB MB de $sourceSizeMB MB" `
            -PercentComplete $percentComplete
            
    } while ($true)
    
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
            $result.Message = "Sin cambios - Todos los archivos ya estaban sincronizados"
            $result.Color = "Green"
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
Write-Host "  4. Otra (ingresar manualmente)"
Write-Host ""

do {
    $option = Read-Host "Ingrese opción (1-4)"
    
    if ($NAS_PRESETS.ContainsKey($option)) {
        $selectedNAS = $NAS_PRESETS[$option].Path
        break
    } elseif ($option -eq "4") {
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

# Verificar si necesita credenciales
net use $Script:NASPath 2>$null | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "Se requieren credenciales." -ForegroundColor Yellow
    $credential = Get-Credential -Message "Ingrese credenciales para $Script:NASPath"
    
    if ($null -eq $credential) {
        Write-Host "`nERROR: Operación cancelada" -ForegroundColor Red
        exit 1
    }
    
    $username = $credential.UserName
    $password = $credential.GetNetworkCredential().Password
    
    # Autenticar con credenciales
    net use $Script:NASPath /user:$username $password /persistent:no 2>$null | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nERROR: No se pudo conectar. Verifique credenciales." -ForegroundColor Red
        Pause
        exit 1
    }
}

Write-Host "Conexión establecida correctamente" -ForegroundColor Green
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
    
    # Validaciones de origen
    Write-Host "`nValidando archivos de origen..." -ForegroundColor Cyan
    
    $hasInvalidChars = -not (Test-InvalidCharactersInFiles -Path $sourcePath)
    if ($hasInvalidChars) {
        $continueWithInvalidChars = Read-Host "`n¿Desea intentar copiar de todos modos? (S/N)"
        if ($continueWithInvalidChars -notmatch '^(S|SI|Y|YES)$') {
            continue
        }
    }
    
    Test-LongPaths -Path $sourcePath
    Show-SpecialAttributesInfo -Path $sourcePath
    
    $hasFilesInUse = -not (Test-FilesInUse -Path $sourcePath)
    if ($hasFilesInUse) {
        $continueWithLocked = Read-Host "¿Desea continuar de todos modos? (S/N)"
        if ($continueWithLocked -notmatch '^(S|SI|Y|YES)$') {
            continue
        }
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
    
    # Selección de modo de comparación
    Write-SectionHeader -Title "MODO DE COMPARACION" -Color Cyan
    Write-Host "  1. Rápido (fecha y tamaño) - Recomendado"
    Write-Host "  2. Avanzado (hash MD5) - Más preciso pero más lento"
    Write-Host ""
    
    do {
        $comparisonMode = Read-Host "Seleccione modo (1-2)"
        
        switch ($comparisonMode) {
            "1" {
                Write-Host "`nModo seleccionado: Rápido" -ForegroundColor Green
                $useHash = $false
                break
            }
            "2" {
                Write-Host "`nModo seleccionado: Avanzado (con hash)" -ForegroundColor Green
                Write-Host "NOTA: Este modo puede tomar varios minutos`n" -ForegroundColor Yellow
                $useHash = $true
                break
            }
            default {
                Write-Host "Opción inválida" -ForegroundColor Yellow
                $comparisonMode = $null
            }
        }
    } while ($null -eq $comparisonMode)
    
    # Calcular tamaño de origen
    Write-Host "Calculando tamaño de origen..." -ForegroundColor Cyan
    $sourceInfo = Get-FolderSize -Path $sourcePath
    $totalMB = $sourceInfo.TotalMB
    $fileCount = $sourceInfo.FileCount
    Write-Host "Tamaño total: $totalMB MB - $fileCount archivos`n" -ForegroundColor Green
    
    # Crear directorio destino
    New-Item -ItemType Directory -Path $finalDestination -Force | Out-Null
    
    # Detectar conflictos
    Write-Host "Analizando archivos para detectar conflictos..." -ForegroundColor Cyan
    if ($useHash) {
        Write-Host "Modo: Avanzado (con verificación hash)" -ForegroundColor Cyan
    } else {
        Write-Host "Modo: Rápido (fecha y tamaño)" -ForegroundColor Cyan
    }
    
    $conflictResult = Find-FileConflicts -SourcePath $sourcePath `
        -DestinationPath $finalDestination `
        -UseHashComparison $useHash
    
    $strategyParams = ""
    
    if ($conflictResult.HasConflicts) {
        Write-SectionHeader -Title "CONFLICTOS DETECTADOS" -Color Yellow
        Write-Host "Se encontraron $($conflictResult.Conflicts.Count) archivo(s) que ya existen`n" -ForegroundColor Yellow
        
        $showCount = [math]::Min(10, $conflictResult.Conflicts.Count)
        Write-Host "Primeros $showCount archivo(s) con conflicto:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $showCount; $i++) {
            Write-Host "  - $($conflictResult.Conflicts[$i])"
        }
        
        if ($conflictResult.Conflicts.Count -gt 10) {
            Write-Host "  ... y $($conflictResult.Conflicts.Count - 10) más" -ForegroundColor Gray
        }
        
        Write-SectionHeader -Title "ESTRATEGIA DE COPIA" -Color Cyan
        Write-Host "  1. Reemplazar si es más nuevo (recomendado)"
        Write-Host "  2. Omitir archivos existentes (no sobrescribir)"
        Write-Host "  3. Sobrescribir todo (reemplazar todos)"
        Write-Host "  4. Cancelar operación"
        Write-Host ""
        
        do {
            $strategyOption = Read-Host "Seleccione estrategia (1-4)"
            
            switch ($strategyOption) {
                "1" {
                    $strategyParams = ""
                    Write-Host "`nEstrategia: Reemplazar archivos más nuevos" -ForegroundColor Green
                    break
                }
                "2" {
                    $strategyParams = "/XC /XN /XO"
                    Write-Host "`nEstrategia: Omitir archivos existentes" -ForegroundColor Green
                    break
                }
                "3" {
                    $strategyParams = "/IS"
                    Write-Host "`nEstrategia: Sobrescribir todos los archivos" -ForegroundColor Green
                    break
                }
                "4" {
                    Write-Host "`nOperación cancelada" -ForegroundColor Yellow
                    continue
                }
                default {
                    Write-Host "Opción inválida" -ForegroundColor Yellow
                    $strategyOption = $null
                }
            }
        } while ($null -eq $strategyOption)
        
        Write-Host ""
    } else {
        Write-Host "No se detectaron conflictos. Procediendo con copia normal`n" -ForegroundColor Green
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
            
            Write-Host "Espacio requerido: $($sourceInfo.TotalGB) GB" -ForegroundColor Cyan
            Write-Host "Espacio disponible: $freeSpaceGB GB" -ForegroundColor Cyan
            
            if ($mappedDrive.FreeSpace -lt ($sourceInfo.TotalBytes * 1.1)) {
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
    
    # Calcular timeout dinámico
    $timeoutSeconds = [math]::Max($MIN_TIMEOUT_SECONDS, 60 * [math]::Ceiling($sourceInfo.TotalGB))
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
        -SourceSizeBytes $sourceInfo.TotalBytes `
        -NASPath $Script:NASPath
    
    # Validar resultado
    Write-SectionHeader -Title "VALIDACION DE RESULTADO" -Color Cyan
    Write-Host "Código de salida Robocopy: $exitCode" -ForegroundColor Cyan
    
    # Detectar archivos modificados durante copia
    $filesChangedDuringCopy = $false
    if (Test-Path $currentLogFile) {
        $logContent = Get-Content $currentLogFile -ErrorAction SilentlyContinue
        $changedFiles = $logContent | Select-String -Pattern "ERROR.*file has changed|changed during copy" -SimpleMatch
        
        if ($changedFiles) {
            $filesChangedDuringCopy = $true
            Write-Host ""
            Write-Host "ADVERTENCIA: Archivos modificados durante la copia:" -ForegroundColor Yellow
            Write-Host "$($changedFiles.Count) archivo(s) cambiaron mientras se copiaban" -ForegroundColor Yellow
            Write-Host "Estos archivos pueden estar incompletos en el destino`n" -ForegroundColor Red
        }
    }
    
    $exitResult = Get-RobocopyExitCodeMessage -ExitCode $exitCode
    Write-Host $exitResult.Message -ForegroundColor $exitResult.Color
    Write-Host ""
    
    # Resumen
    Clear-Host
    Write-Host "--------------------------------"
    Write-Host " RESUMEN DE TRANSFERENCIA"
    Write-Host "--------------------------------"
    Write-Host ""
    
    if (Test-Path $currentLogFile) {
        $summary = Select-String $currentLogFile -Pattern "^ *Total" -Context 1,20
        if ($summary) {
            $summary.Context.PreContext
            $summary.Line
            $summary.Context.PostContext
        } else {
            Write-Host "No se encontró resumen en el log"
        }
    }
    
    Write-Host "`n================================"
    Write-Host " TRANSFERENCIA COMPLETADA"
    Write-Host "================================"
    Write-Host "Estado: $($exitResult.Message)"
    Write-Host "Log: $currentLogFile"
    Write-Host ""
    
    if ($exitResult.IsError) {
        Write-Host "ATENCIÓN: Revise el log para identificar archivos no copiados" -ForegroundColor Red
        Write-Host ""
    }
    
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
