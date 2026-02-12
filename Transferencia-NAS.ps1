Clear-Host
$Host.UI.RawUI.WindowTitle = "Transferencia Automatizada NAS"

Write-Host "================================"
Write-Host " TRANSFERENCIA AUTOMATIZADA NAS"
Write-Host "================================"
Write-Host ""

# ===== SELECCIÓN DE CARPETA NAS =====
Write-Host "Seleccione la carpeta de destino en el NAS:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Pruebas"
Write-Host "  2. Historico"
Write-Host "  3. EDI"
Write-Host "  4. Otra (ingresar manualmente)"
Write-Host ""

do {
    $Opcion = Read-Host "Ingrese opcion (1-4)"
    
    switch ($Opcion) {
        "1" { $NAS = "\\192.168.1.254\Pruebas"; break }
        "2" { $NAS = "\\192.168.1.254\Historico"; break }
        "3" { $NAS = "\\192.168.1.254\edi"; break }
        "4" { 
            do {
                $NAS = Read-Host "Ingrese la ruta completa del NAS (ej: \\192.168.1.254\MiCarpeta)"
                
                # Validar formato UNC
                if ($NAS -notmatch '^\\\\[^\\]+\\[^\\]+') {
                    Write-Host "ERROR: La ruta debe tener formato UNC (\\servidor\recurso)" -ForegroundColor Red
                    $Reintentar = Read-Host "¿Desea intentar nuevamente? (S/N)"
                    if ($Reintentar -notmatch '^(S|SI|Y|YES)$') {
                        $Opcion = $null
                        break
                    }
                    $NAS = $null
                    continue
                }
                
                # Validar que la ruta sea accesible
                Write-Host "Verificando accesibilidad de la ruta..." -ForegroundColor Cyan
                if (-not (Test-Path $NAS -ErrorAction SilentlyContinue)) {
                    Write-Host "ADVERTENCIA: No se puede acceder a la ruta o no existe." -ForegroundColor Yellow
                    Write-Host "Puede ser necesario proporcionar credenciales mas adelante." -ForegroundColor Yellow
                    $Continuar = Read-Host "¿Desea continuar con esta ruta de todos modos? (S/N)"
                    if ($Continuar -notmatch '^(S|SI|Y|YES)$') {
                        $Reintentar = Read-Host "¿Desea ingresar otra ruta? (S/N)"
                        if ($Reintentar -notmatch '^(S|SI|Y|YES)$') {
                            $Opcion = $null
                            break
                        }
                        $NAS = $null
                        continue
                    }
                }
                
                break
            } while ($true)
            
            if ($null -eq $Opcion) { continue }
            break 
        }
        default { 
            Write-Host "Opcion invalida. Intente nuevamente." -ForegroundColor Yellow
            $Opcion = $null
        }
    }
} while ($null -eq $Opcion)

Write-Host "`nCarpeta seleccionada: $NAS" -ForegroundColor Green
Write-Host ""

# ===== CONFIGURACIÓN =====
$Drive  = "Z:"
$LogDir = "C:\Logs"
$DateTag = Get-Date -Format "yyyyMMdd_HHmmss"

$LastLogSize = 0
$LastActivity = Get-Date
$TransferenciaContador = 1  # Contador para logs múltiples

# ===== FUNCIÓN CONFIRMACIÓN =====
function Confirm-Continue {
    param([string]$Message)

    Write-Host ""
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host " CONFIRMACION DE OPERACION" -ForegroundColor Cyan
    Write-Host "================================"
    Write-Host ""
    Write-Host $Message
    Write-Host ""
    $r = Read-Host "Ingrese S para continuar o N en caso desee ingresar la ruta de destino nuevamente"

    return ($r -match '^(S|SI|Y|YES)$')
}

# ===== FUNCIÓN VERIFICAR CONECTIVIDAD NAS =====
function Test-NASConnection {
    param([string]$Drive)
    
    try {
        # Verificar que la unidad existe y es accesible
        $test = Get-PSDrive -Name ($Drive.TrimEnd(':')) -ErrorAction Stop
        
        # Intentar listar contenido (prueba real de acceso)
        $null = Get-ChildItem -Path $Drive -ErrorAction Stop | Select-Object -First 1
        
        return $true
    } catch {
        return $false
    }
}

# ===== LOG DIR =====
if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

# ===== MAPEAR UNIDAD (SEGURO) =====
if (Get-PSDrive -Name Z -ErrorAction SilentlyContinue) {
    net use Z: /delete /y | Out-Null
}

Write-Host "Intentando conectar al NAS..." -ForegroundColor Cyan

# Primer intento: usar credenciales guardadas
net use Z: $NAS /persistent:no 2>$null | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "Se requieren credenciales." -ForegroundColor Yellow
    
    # Solicitar credenciales
    $Credencial = Get-Credential -Message "Ingrese credenciales para $NAS"
    
    if ($null -eq $Credencial) {
        Write-Host "`nERROR: Operacion cancelada por el usuario" -ForegroundColor Red
        Pause
        exit 1
    }
    
    $Usuario = $Credencial.UserName
    $Password = $Credencial.GetNetworkCredential().Password
    
    # Segundo intento: con credenciales proporcionadas
    net use Z: $NAS /user:$Usuario $Password /persistent:no 2>$null | Out-Null
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host "`nERROR: No se pudo conectar al NAS. Verifique credenciales." -ForegroundColor Red
        Pause
        exit 1
    }
}

Write-Host "Unidad mapeada correctamente.`n" -ForegroundColor Green

# ===== BUCLE PRINCIPAL =====
do {
    Clear-Host
    Write-Host "================================"
    Write-Host " TRANSFERENCIA AUTOMATIZADA NAS"
    Write-Host "================================"
    Write-Host ""

# ===== DATOS =====
$Source = Read-Host "Ingrese ruta ORIGEN (carpeta completa)"

# Validar que la ruta de origen exista
if (-not (Test-Path $Source)) {
    Write-Host "`nERROR: La ruta de origen no existe: $Source" -ForegroundColor Red
    Write-Host "Verifique la ruta e intente nuevamente.`n" -ForegroundColor Yellow
    continue
}

if (-not (Test-Path $Source -PathType Container)) {
    Write-Host "`nERROR: La ruta debe ser una carpeta, no un archivo." -ForegroundColor Red
    Write-Host "Use la ruta completa de la carpeta.`n" -ForegroundColor Yellow
    continue
}

# ===== VALIDAR CARACTERES ESPECIALES EN NOMBRES DE ARCHIVOS =====
Write-Host "`nValidando nombres de archivos..." -ForegroundColor Cyan

$CaracteresInvalidos = '[<>"|?*]'
$ArchivosProblematicos = Get-ChildItem -Path $Source -Recurse -File -ErrorAction SilentlyContinue | 
    Where-Object { $_.Name -match $CaracteresInvalidos }

if ($ArchivosProblematicos) {
    Write-Host "ADVERTENCIA: Se encontraron archivos con caracteres especiales invalidos:" -ForegroundColor Yellow
    Write-Host "Los siguientes caracteres pueden causar problemas: < > : \" | ? *`n" -ForegroundColor Yellow
    
    $CantidadMostrar = [math]::Min(5, $ArchivosProblematicos.Count)
    for ($i = 0; $i -lt $CantidadMostrar; $i++) {
        Write-Host "  - $($ArchivosProblematicos[$i].Name)" -ForegroundColor Red
    }
    
    if ($ArchivosProblematicos.Count -gt 5) {
        Write-Host "  ... y $($ArchivosProblematicos.Count - 5) archivo(s) mas" -ForegroundColor Gray
    }
    
    Write-Host ""
    $ContinuarCaracteres = Read-Host "¿Desea intentar copiar de todos modos? (S/N)"
    if ($ContinuarCaracteres -notmatch '^(S|SI|Y|YES)$') {
        Write-Host "Operacion cancelada. Renombre los archivos y vuelva a intentar.`n" -ForegroundColor Yellow
        continue
    }
}

# ===== VALIDAR RUTAS MUY LARGAS =====
$RutasLargas = Get-ChildItem -Path $Source -Recurse -File -ErrorAction SilentlyContinue | 
    Where-Object { $_.FullName.Length -gt 240 }

if ($RutasLargas) {
    Write-Host "ADVERTENCIA: Se encontraron archivos con rutas muy largas (>240 caracteres):" -ForegroundColor Yellow
    Write-Host "Esto puede causar errores en sistemas con limite de 260 caracteres`n" -ForegroundColor Yellow
    
    $CantidadMostrar = [math]::Min(3, $RutasLargas.Count)
    for ($i = 0; $i -lt $CantidadMostrar; $i++) {
        $ruta = $RutasLargas[$i].FullName
        if ($ruta.Length -gt 80) {
            $ruta = $ruta.Substring(0, 77) + "..."
        }
        Write-Host "  - $ruta ($($RutasLargas[$i].FullName.Length) caracteres)" -ForegroundColor Red
    }
    
    if ($RutasLargas.Count -gt 3) {
        Write-Host "  ... y $($RutasLargas.Count - 3) archivo(s) mas" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "NOTA: El script usara rutas largas de Windows si es necesario" -ForegroundColor Cyan
}

# ===== DETECTAR ARCHIVOS CON ATRIBUTOS ESPECIALES =====
$ArchivosEspeciales = Get-ChildItem -Path $Source -Recurse -File -Force -ErrorAction SilentlyContinue | 
    Where-Object { $_.Attributes -match 'ReadOnly|Hidden|System' }

if ($ArchivosEspeciales) {
    Write-Host "`nINFO: Se encontraron archivos con atributos especiales:" -ForegroundColor Cyan
    
    $ReadOnlyCount = ($ArchivosEspeciales | Where-Object { $_.Attributes -match 'ReadOnly' }).Count
    $HiddenCount = ($ArchivosEspeciales | Where-Object { $_.Attributes -match 'Hidden' }).Count
    $SystemCount = ($ArchivosEspeciales | Where-Object { $_.Attributes -match 'System' }).Count
    
    if ($ReadOnlyCount -gt 0) {
        Write-Host "  - $ReadOnlyCount archivo(s) de solo lectura (Read-Only)" -ForegroundColor Gray
    }
    if ($HiddenCount -gt 0) {
        Write-Host "  - $HiddenCount archivo(s) ocultos (Hidden)" -ForegroundColor Gray
    }
    if ($SystemCount -gt 0) {
        Write-Host "  - $SystemCount archivo(s) de sistema (System)" -ForegroundColor Gray
    }
    
    Write-Host "Estos archivos seran copiados con sus atributos preservados.`n" -ForegroundColor Green
}

# ===== DETECTAR ARCHIVOS EN USO / BLOQUEADOS =====
Write-Host "Verificando archivos en uso..." -ForegroundColor Cyan

$ArchivosEnUso = @()
$ArchivosAVerificar = Get-ChildItem -Path $Source -Recurse -File -ErrorAction SilentlyContinue | 
    Where-Object { $_.Extension -match '\.(docx?|xlsx?|pptx?|mdb|accdb|pst|ost|ldf|mdf)$' }

foreach ($archivo in $ArchivosAVerificar) {
    try {
        $stream = [System.IO.File]::Open($archivo.FullName, 'Open', 'Read', 'None')
        $stream.Close()
        $stream.Dispose()
    } catch {
        $ArchivosEnUso += $archivo.Name
    }
}

if ($ArchivosEnUso.Count -gt 0) {
    Write-Host "ADVERTENCIA: Se encontraron $($ArchivosEnUso.Count) archivo(s) que podrian estar en uso:" -ForegroundColor Yellow
    
    $CantidadMostrar = [math]::Min(5, $ArchivosEnUso.Count)
    for ($i = 0; $i -lt $CantidadMostrar; $i++) {
        Write-Host "  - $($ArchivosEnUso[$i])" -ForegroundColor Red
    }
    
    if ($ArchivosEnUso.Count -gt 5) {
        Write-Host "  ... y $($ArchivosEnUso.Count - 5) archivo(s) mas" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "RECOMENDACION: Cierre los archivos antes de copiar para evitar errores." -ForegroundColor Yellow
    Write-Host "Robocopy intentara copiarlos con reintentos automaticos.`n" -ForegroundColor Cyan
    
    $ContinuarConBloqueados = Read-Host "¿Desea continuar de todos modos? (S/N)"
    if ($ContinuarConBloqueados -notmatch '^(S|SI|Y|YES)$') {
        Write-Host "Operacion cancelada. Cierre los archivos y vuelva a intentar.`n" -ForegroundColor Yellow
        continue
    }
}

# Bucle para validar destino
do {
    $Dest   = Read-Host "Ingrese ruta DESTINO dentro del NAS"

    $FolderName = Split-Path $Source -Leaf
    $FinalDest = Join-Path "$Drive\$Dest" $FolderName
    
    # ===== LOG INDIVIDUAL =====
    $LogFile = "$LogDir\robocopy_${DateTag}_transferencia${TransferenciaContador}.txt"

    Write-Host "`nResumen:"
    Write-Host "Origen : $Source"
    Write-Host "Destino: $FinalDest"
    Write-Host "Log    : $LogFile"

    if (Confirm-Continue "¿Desea iniciar la transferencia?") {
        break
    } else {
        Write-Host "`nVolviendo a solicitar ruta de destino...`n" -ForegroundColor Yellow
        Start-Sleep -Seconds 1
    }
} while ($true)

# ===== MODO DE COMPARACION =====
Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host " MODO DE COMPARACION" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Rapido (fecha y tamaño) - Recomendado"
Write-Host "  2. Avanzado (hash MD5) - Mas preciso pero mas lento"
Write-Host ""

do {
    $ModoComparacion = Read-Host "Seleccione modo (1-2)"
    
    switch ($ModoComparacion) {
        "1" { 
            Write-Host "`nModo seleccionado: Rapido" -ForegroundColor Green
            $UsarHash = $false
            break 
        }
        "2" { 
            Write-Host "`nModo seleccionado: Avanzado (con hash)" -ForegroundColor Green
            Write-Host "NOTA: Este modo puede tomar varios minutos para muchos archivos" -ForegroundColor Yellow
            $UsarHash = $true
            break 
        }
        default { 
            Write-Host "Opcion invalida. Intente nuevamente." -ForegroundColor Yellow
            $ModoComparacion = $null
        }
    }
} while ($null -eq $ModoComparacion)

# ===== FUNCION CALCULAR HASH =====
function Get-FileHashMD5 {
    param([string]$FilePath)
    try {
        $hash = Get-FileHash -Path $FilePath -Algorithm MD5 -ErrorAction Stop
        return $hash.Hash
    } catch {
        return $null
    }
}

# ===== CALCULAR TAMAÑO ORIGEN =====
Write-Host "`nCalculando tamaño de origen..." -ForegroundColor Cyan
$OrigenSize = (Get-ChildItem -Path $Source -Recurse -File -ErrorAction SilentlyContinue | 
               Measure-Object -Property Length -Sum).Sum

if ($OrigenSize -eq 0 -or $null -eq $OrigenSize) {
    $OrigenSize = 1  # Evitar división por cero
}

$OrigenSizeMB = [math]::Round($OrigenSize / 1MB, 2)
Write-Host "Tamaño total: $OrigenSizeMB MB`n" -ForegroundColor Green

# ===== CREAR DESTINO =====
New-Item -ItemType Directory -Path $FinalDest -Force | Out-Null

# ===== DETECTAR CONFLICTOS =====
Write-Host "Analizando archivos para detectar conflictos..." -ForegroundColor Cyan
if ($UsarHash) {
    Write-Host "Modo: Avanzado (con verificacion hash)" -ForegroundColor Cyan
} else {
    Write-Host "Modo: Rapido (fecha y tamaño)" -ForegroundColor Cyan
}

# Verificar si el destino ya tiene archivos
$ArchivosDestino = @()
if (Test-Path $FinalDest) {
    $ArchivosDestino = Get-ChildItem -Path $FinalDest -Recurse -File -ErrorAction SilentlyContinue
}

$HayConflictos = $false
$Conflictos = @()

if ($ArchivosDestino.Count -gt 0) {
    # Hay archivos en destino, buscar coincidencias
    $ArchivosOrigen = Get-ChildItem -Path $Source -Recurse -File -ErrorAction SilentlyContinue
    
    Write-Host "Fase 1: Comparando metadata..." -ForegroundColor Cyan
    $ArchivosParaHash = @()
    $ContadorArchivos = 0
    
    foreach ($archivoOrigen in $ArchivosOrigen) {
        $ContadorArchivos++
        $rutaRelativa = $archivoOrigen.FullName.Substring($Source.Length)
        $archivoDestinoPath = Join-Path $FinalDest $rutaRelativa
        
        if (Test-Path $archivoDestinoPath) {
            $archivoDestino = Get-Item $archivoDestinoPath
            
            # Comparar fechas de modificación y tamaño
            $origenFecha = $archivoOrigen.LastWriteTime
            $destinoFecha = $archivoDestino.LastWriteTime
            $origenSize = $archivoOrigen.Length
            $destinoSize = $archivoDestino.Length
            
            $estado = ""
            if ($origenFecha -gt $destinoFecha) {
                $estado = "[MAS NUEVO]"
                $Conflictos += "$estado $rutaRelativa"
                $HayConflictos = $true
            } elseif ($origenFecha -lt $destinoFecha) {
                $estado = "[MAS VIEJO]"
                $Conflictos += "$estado $rutaRelativa"
                $HayConflictos = $true
            } elseif ($origenSize -ne $destinoSize) {
                $estado = "[DIFERENTE TAMAÑO]"
                $Conflictos += "$estado $rutaRelativa"
                $HayConflictos = $true
            } else {
                # Parecen idénticos (misma fecha y tamaño)
                if ($UsarHash) {
                    # Guardar para verificar hash después
                    $ArchivosParaHash += @{
                        Origen = $archivoOrigen.FullName
                        Destino = $archivoDestinoPath
                        RutaRelativa = $rutaRelativa
                    }
                } else {
                    # Modo rápido: aceptar como idéntico
                    $estado = "[IDENTICO]"
                    $Conflictos += "$estado $rutaRelativa"
                    $HayConflictos = $true
                }
            }
        }
    }
    
    Write-Host "Fase 1 completada: $ContadorArchivos archivo(s) analizados" -ForegroundColor Green
    
    # Fase 2: Verificar hash para archivos que parecen idénticos
    if ($UsarHash -and $ArchivosParaHash.Count -gt 0) {
        Write-Host "`nFase 2: Calculando hash de $($ArchivosParaHash.Count) archivo(s)..." -ForegroundColor Cyan
        $ContadorHash = 0
        
        foreach ($item in $ArchivosParaHash) {
            $ContadorHash++
            Write-Progress -Activity "Calculando hash MD5" `
                -Status "Archivo $ContadorHash de $($ArchivosParaHash.Count)" `
                -PercentComplete (($ContadorHash / $ArchivosParaHash.Count) * 100)
            
            $hashOrigen = Get-FileHashMD5 -FilePath $item.Origen
            $hashDestino = Get-FileHashMD5 -FilePath $item.Destino
            
            if ($null -eq $hashOrigen -or $null -eq $hashDestino) {
                $estado = "[ERROR HASH]"
            } elseif ($hashOrigen -eq $hashDestino) {
                $estado = "[IDENTICO - HASH OK]"
            } else {
                $estado = "[IDENTICO - HASH DIFERENTE]"
            }
            
            $Conflictos += "$estado $($item.RutaRelativa)"
            $HayConflictos = $true
        }
        
        Write-Progress -Activity "Calculando hash MD5" -Completed
        Write-Host "Fase 2 completada: Hash verificado" -ForegroundColor Green
    }
}

# Variable para parámetros adicionales según estrategia
$EstrategiaParams = ""

if ($HayConflictos) {
    Write-Host "`n================================" -ForegroundColor Yellow
    Write-Host " CONFLICTOS DETECTADOS" -ForegroundColor Yellow
    Write-Host "================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Se encontraron $($Conflictos.Count) archivo(s) que ya existen en el destino." -ForegroundColor Yellow
    Write-Host ""
    
    # Mostrar primeros 10 conflictos
    $MostrarCantidad = [math]::Min(10, $Conflictos.Count)
    Write-Host "Primeros $MostrarCantidad archivo(s) con conflicto:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $MostrarCantidad; $i++) {
        Write-Host "  - $($Conflictos[$i])"
    }
    
    if ($Conflictos.Count -gt 10) {
        Write-Host "  ... y $($Conflictos.Count - 10) mas" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host " ESTRATEGIA DE COPIA" -ForegroundColor Cyan
    Write-Host "================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Reemplazar si es mas nuevo (recomendado)"
    Write-Host "  2. Omitir archivos existentes (no sobrescribir)"
    Write-Host "  3. Sobrescribir todo (reemplazar todos)"
    Write-Host "  4. Cancelar operacion"
    Write-Host ""
    
    do {
        $EstrategiaOpcion = Read-Host "Seleccione estrategia (1-4)"
        
        switch ($EstrategiaOpcion) {
            "1" { 
                $EstrategiaParams = ""  # Comportamiento predeterminado
                Write-Host "`nEstrategia: Reemplazar archivos mas nuevos" -ForegroundColor Green
                break 
            }
            "2" { 
                $EstrategiaParams = "/XC /XN /XO"  # Excluir cambiados, nuevos, antiguos
                Write-Host "`nEstrategia: Omitir archivos existentes" -ForegroundColor Green
                break 
            }
            "3" { 
                $EstrategiaParams = "/IS"  # Incluir idénticos (sobrescribir todo)
                Write-Host "`nEstrategia: Sobrescribir todos los archivos" -ForegroundColor Green
                break 
            }
            "4" { 
                Write-Host "`nOperacion cancelada por el usuario." -ForegroundColor Yellow
                continue  # Volver al inicio del bucle principal
            }
            default { 
                Write-Host "Opcion invalida. Intente nuevamente." -ForegroundColor Yellow
                $EstrategiaOpcion = $null
            }
        }
    } while ($null -eq $EstrategiaOpcion)
    
    Write-Host ""
} else {
    Write-Host "No se detectaron conflictos. Procediendo con copia normal.`n" -ForegroundColor Green
}

# ===== OPCIONES AVANZADAS DE COPIA =====
Write-Host "================================" -ForegroundColor Cyan
Write-Host " OPCIONES AVANZADAS" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "¿Desea excluir archivos temporales y de sistema?" -ForegroundColor Cyan
Write-Host "  - Archivos temporales: ~$*, *.tmp, *.temp, *.bak" -ForegroundColor Gray
Write-Host "  - Carpetas del sistema: Thumbs.db, .DS_Store, desktop.ini" -ForegroundColor Gray
Write-Host ""

$ExcluirTemporales = Read-Host "¿Excluir archivos temporales? (S/N)"
$ParamsExcluir = ""

if ($ExcluirTemporales -match '^(S|SI|Y|YES)$') {
    $ParamsExcluir = "/XF ~$* *.tmp *.temp *.bak Thumbs.db .DS_Store desktop.ini /XD `$RECYCLE.BIN `"System Volume Information`""
    Write-Host "Archivos temporales y de sistema seran excluidos`n" -ForegroundColor Green
} else {
    Write-Host "Se copiaran todos los archivos (incluyendo temporales)`n" -ForegroundColor Yellow
}

# ===== VERIFICAR ESPACIO EN DESTINO =====
Write-Host "Verificando espacio disponible en destino..." -ForegroundColor Cyan

$DestinoVolumen = (Get-Item $Drive -ErrorAction SilentlyContinue)
if ($null -ne $DestinoVolumen) {
    try {
        $VolumenInfo = Get-PSDrive -Name ($Drive.TrimEnd(':')) -ErrorAction Stop
        $EspacioLibreGB = [math]::Round($VolumenInfo.Free / 1GB, 2)
        $OrigenSizeGB = [math]::Round($OrigenSize / 1GB, 2)
        
        Write-Host "Espacio requerido: $OrigenSizeGB GB" -ForegroundColor Cyan
        Write-Host "Espacio disponible: $EspacioLibreGB GB" -ForegroundColor Cyan
        
        if ($VolumenInfo.Free -lt ($OrigenSize * 1.1)) {  # 10% extra de margen
            Write-Host "`nADVERTENCIA: Espacio insuficiente en destino" -ForegroundColor Red
            Write-Host "Se requiere aproximadamente $OrigenSizeGB GB pero solo hay $EspacioLibreGB GB disponibles" -ForegroundColor Red
            $ContinuarSinEspacio = Read-Host "¿Desea continuar de todos modos? (S/N)"
            if ($ContinuarSinEspacio -notmatch '^(S|SI|Y|YES)$') {
                Write-Host "`nOperacion cancelada por espacio insuficiente." -ForegroundColor Yellow
                continue
            }
        } else {
            Write-Host "Espacio suficiente disponible`n" -ForegroundColor Green
        }
    } catch {
        Write-Host "No se pudo verificar espacio (continuando de todos modos)`n" -ForegroundColor Yellow
    }
}

# ===== CALCULAR TIMEOUT DINAMICO =====
$OrigenSizeGB = [math]::Round($OrigenSize / 1GB, 2)
# Timeout basado en tamaño: mínimo 5 min, +1 min por cada 1 GB
$MaxIdleSeconds = [math]::Max(300, 60 * [math]::Ceiling($OrigenSizeGB))
Write-Host "Timeout configurado: $([math]::Round($MaxIdleSeconds / 60, 1)) minutos (ajustado segun tamaño)`n" -ForegroundColor Cyan

# ===== ROBOCOPY =====
Write-Host "Configurando parametros de copia resiliente..." -ForegroundColor Cyan
Write-Host "  - Modo reiniciable (/Z) - Permite continuar copias interrumpidas" -ForegroundColor Gray
Write-Host "  - 10 reintentos con 30 segundos de espera - Tolera desconexiones breves" -ForegroundColor Gray
Write-Host "  - Copia atributos especiales (Read-Only, Hidden, System)" -ForegroundColor Gray
Write-Host "  - Verificacion de conectividad cada 10 segundos durante la copia" -ForegroundColor Gray
Write-Host "  - Manejo de archivos en uso con reintentos automaticos`n" -ForegroundColor Gray

$RoboArgs = @(
    "`"$Source`"",
    "`"$FinalDest`"",
    "/E /Z /MT:16 /R:10 /W:30 $EstrategiaParams $ParamsExcluir",
    "/COPY:DATSOU /DCOPY:DAT /A-:SH",
    "/LOG:`"$LogFile`"",
    "/NFL /NDL /NP",
    "/V /TS /FP /BYTES /X /XX"
)

Write-Host "Iniciando transferencia...`n" -ForegroundColor Green

$Process = Start-Process robocopy -ArgumentList $RoboArgs -NoNewWindow -PassThru

# ===== MONITOREO =====
$UltimaVerificacionConexion = Get-Date
$IntervaloVerificacionConexion = 10  # Verificar conectividad cada 10 segundos

do {
    Start-Sleep 2

    if (-not (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue)) {
        break
    }

    # Verificar conectividad al NAS periódicamente
    if (((Get-Date) - $UltimaVerificacionConexion).TotalSeconds -ge $IntervaloVerificacionConexion) {
        if (-not (Test-NASConnection -Drive $Drive)) {
            Write-Progress -Activity "Copiando archivos..." -Completed
            Write-Host "`n================================" -ForegroundColor Red
            Write-Host " ERROR: CONEXION AL NAS PERDIDA" -ForegroundColor Red
            Write-Host "================================" -ForegroundColor Red
            Write-Host ""
            Write-Host "Se detecto perdida de conexion al NAS durante la transferencia." -ForegroundColor Yellow
            Write-Host "Esto puede deberse a:" -ForegroundColor Yellow
            Write-Host "  - Cable de red desconectado" -ForegroundColor Yellow
            Write-Host "  - NAS apagado o reiniciado" -ForegroundColor Yellow
            Write-Host "  - Timeout de red" -ForegroundColor Yellow
            Write-Host "  - Credenciales expiradas" -ForegroundColor Yellow
            Write-Host ""
            
            # Detener Robocopy de forma controlada
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            
            Write-Host "Proceso de copia detenido para prevenir corrupcion de archivos." -ForegroundColor Red
            Write-Host ""
            Write-Host "ACCIONES RECOMENDADAS:" -ForegroundColor Cyan
            Write-Host "1. Verifique la conexion de red" -ForegroundColor Cyan
            Write-Host "2. Verifique que el NAS este encendido y accesible" -ForegroundColor Cyan
            Write-Host "3. Ejecute el script nuevamente" -ForegroundColor Cyan
            Write-Host "4. Robocopy continuara desde donde se interrumpio (modo /Z)" -ForegroundColor Green
            Write-Host ""
            
            Pause
            
            # Intentar desmapear y salir
            net use Z: /delete /y 2>$null | Out-Null
            exit 1
        }
        $UltimaVerificacionConexion = Get-Date
    }

    if (Test-Path $LogFile) {
        $size = (Get-Item $LogFile).Length
        if ($size -gt $LastLogSize) {
            $LastLogSize = $size
            $LastActivity = Get-Date
        }
    }

    if (((Get-Date) - $LastActivity).TotalSeconds -ge $MaxIdleSeconds) {
        Write-Progress -Activity "Copiando archivos..." -Completed
        Write-Host "`nERROR: Robocopy parece colgado (sin actividad por $([math]::Round($MaxIdleSeconds/60,1)) minutos)." -ForegroundColor Red
        
        # Verificar si es problema de conectividad antes de reportar colgado
        if (-not (Test-NASConnection -Drive $Drive)) {
            Write-Host "CAUSA: Perdida de conexion al NAS detectada." -ForegroundColor Red
        }
        
        Stop-Process -Id $Process.Id -Force
        Pause
        exit 1
    }

    # Calcular progreso real
    $DestinoSize = 0
    if (Test-Path $FinalDest) {
        $DestinoSize = (Get-ChildItem -Path $FinalDest -Recurse -File -ErrorAction SilentlyContinue | 
                        Measure-Object -Property Length -Sum).Sum
    }
    
    $PorcentajeReal = [math]::Min(99, [math]::Round(($DestinoSize / $OrigenSize) * 100, 0))
    $DestinoSizeMB = [math]::Round($DestinoSize / 1MB, 2)
    
    Write-Progress -Activity "Copiando archivos..." `
        -Status "Transferido: $DestinoSizeMB MB de $OrigenSizeMB MB" `
        -PercentComplete $PorcentajeReal

} while ($true)

Write-Progress -Activity "Copiando archivos..." -Completed

# ===== VALIDAR EXIT CODE DE ROBOCOPY =====
$Process.WaitForExit()
$ExitCode = $Process.ExitCode

Write-Host ""
Write-Host "================================" -ForegroundColor Cyan
Write-Host " VALIDACION DE RESULTADO" -ForegroundColor Cyan
Write-Host "================================" -ForegroundColor Cyan
Write-Host "Codigo de salida Robocopy: $ExitCode" -ForegroundColor Cyan

# Interpretar código de salida
# Bits: 0=Sin errores, 1=Archivos copiados, 2=Extras, 3=Mismatch, 4+=Errores
$ErrorGrave = $false
$MensajeEstado = ""
$ArchivosModificadosDuranteCopia = $false

# Detectar archivos que cambiaron durante la copia
if (Test-Path $LogFile) {
    $LogContent = Get-Content $LogFile -ErrorAction SilentlyContinue
    $ArchivosCambiados = $LogContent | Select-String -Pattern "ERROR.*file has changed|changed during copy" -SimpleMatch
    
    if ($ArchivosCambiados) {
        $ArchivosModificadosDuranteCopia = $true
        Write-Host ""
        Write-Host "ADVERTENCIA: Algunos archivos fueron modificados durante la copia:" -ForegroundColor Yellow
        
        $CantidadCambiados = $ArchivosCambiados.Count
        Write-Host "$CantidadCambiados archivo(s) cambiaron mientras se copiaban" -ForegroundColor Yellow
        Write-Host "Esto puede ocurrir con archivos de log activos o bases de datos abiertas" -ForegroundColor Gray
        Write-Host "Estos archivos pueden estar incompletos o corruptos en el destino`n" -ForegroundColor Red
    }
}

if ($ExitCode -eq 0) {
    $MensajeEstado = "Sin cambios - Todos los archivos ya estaban sincronizados"
    Write-Host $MensajeEstado -ForegroundColor Green
} elseif ($ExitCode -eq 1) {
    $MensajeEstado = "Exito - Archivos copiados correctamente"
    Write-Host $MensajeEstado -ForegroundColor Green
} elseif ($ExitCode -eq 2) {
    $MensajeEstado = "Exito - Archivos extra detectados en destino"
    Write-Host $MensajeEstado -ForegroundColor Green
} elseif ($ExitCode -eq 3) {
    $MensajeEstado = "Exito - Archivos copiados y extras detectados"
    Write-Host $MensajeEstado -ForegroundColor Green
} elseif ($ExitCode -ge 8) {
    $ErrorGrave = $true
    $MensajeEstado = "ERROR GRAVE - Algunos archivos NO se copiaron"
    Write-Host $MensajeEstado -ForegroundColor Red
    Write-Host "Verifique el log para detalles de los errores" -ForegroundColor Red
} elseif ($ExitCode -ge 4) {
    $MensajeEstado = "ADVERTENCIA - Algunos archivos no coinciden o hubo errores menores"
    Write-Host $MensajeEstado -ForegroundColor Yellow
}

Write-Host ""

# ===== RESUMEN =====
Clear-Host
Write-Host "--------------------------------"
Write-Host " RESUMEN DE TRANSFERENCIA"
Write-Host "--------------------------------"
Write-Host ""

$Summary = Select-String $LogFile -Pattern "^ *Total" -Context 1,20
if ($Summary) {
    $Summary.Context.PreContext
    $Summary.Line
    $Summary.Context.PostContext
} else {
    Write-Host "No se encontro resumen."
}

Write-Host "`n================================"
Write-Host " TRANSFERENCIA COMPLETADA"
Write-Host "================================"
Write-Host "Estado: $MensajeEstado"
Write-Host "Log: $LogFile"
Write-Host ""

if ($ErrorGrave) {
    Write-Host "ATENCION: Revise el log para identificar archivos no copiados" -ForegroundColor Red
    Write-Host ""
}

# Incrementar contador para próxima transferencia
$TransferenciaContador++

# ===== PREGUNTAR SI CONTINUAR =====
$Continuar = Read-Host "¿Desea realizar otra transferencia? (S/N)"

} while ($Continuar -match '^(S|SI|Y|YES)$')

# ===== DESMAPEAR =====
Write-Host "`nDesmapeando unidad..." -ForegroundColor Cyan
net use Z: /delete /y | Out-Null

# ===== GESTION DE LOGS ANTIGUOS =====
Write-Host "Verificando logs antiguos..." -ForegroundColor Cyan

$LogsAntiguos = Get-ChildItem -Path $LogDir -Filter "robocopy_*.txt" -ErrorAction SilentlyContinue | 
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) }

if ($LogsAntiguos) {
    Write-Host "Se encontraron $($LogsAntiguos.Count) log(s) con mas de 30 dias de antiguedad" -ForegroundColor Yellow
    
    $TamañoTotal = ($LogsAntiguos | Measure-Object -Property Length -Sum).Sum
    $TamañoTotalMB = [math]::Round($TamañoTotal / 1MB, 2)
    
    Write-Host "Espacio ocupado: $TamañoTotalMB MB" -ForegroundColor Yellow
    
    $EliminarLogs = Read-Host "¿Desea eliminar logs antiguos para liberar espacio? (S/N)"
    
    if ($EliminarLogs -match '^(S|SI|Y|YES)$') {
        $LogsAntiguos | Remove-Item -Force -ErrorAction SilentlyContinue
        Write-Host "Logs antiguos eliminados correctamente" -ForegroundColor Green
    }
}

Write-Host "`nProceso finalizado." -ForegroundColor Green
Write-Host "Logs de sesion guardados en: $LogDir" -ForegroundColor Cyan
