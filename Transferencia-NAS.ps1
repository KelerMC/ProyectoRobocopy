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
            $NAS = Read-Host "Ingrese la ruta completa del NAS (ej: \\192.168.1.254\MiCarpeta)"
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
$LogFile = "$LogDir\robocopy_$DateTag.txt"

$MaxIdleSeconds = 300
$LastLogSize = 0
$LastActivity = Get-Date

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
    $r = Read-Host "Ingrese S para continuar"

    return ($r -match '^(S|SI|Y|YES)$')
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

$Dest   = Read-Host "Ingrese ruta DESTINO dentro del NAS"

$FolderName = Split-Path $Source -Leaf
$FinalDest = Join-Path "$Drive\$Dest" $FolderName

Write-Host "`nResumen:"
Write-Host "Origen : $Source"
Write-Host "Destino: $FinalDest"
Write-Host "Log    : $LogFile"

if (-not (Confirm-Continue "¿Desea iniciar la transferencia?")) {
    Write-Host "Operacion cancelada por el usuario." -ForegroundColor Yellow
    net use Z: /delete /y | Out-Null
    exit 0
}

# ===== CREAR DESTINO =====
New-Item -ItemType Directory -Path $FinalDest -Force | Out-Null

# ===== ROBOCOPY =====
$RoboArgs = @(
    "`"$Source`"",
    "`"$FinalDest`"",
    "/E /Z /MT:16 /R:3 /W:10",
    "/COPY:DAT /DCOPY:DAT",
    "/LOG:`"$LogFile`"",
    "/NFL /NDL /NP"
)

$Process = Start-Process robocopy -ArgumentList $RoboArgs -NoNewWindow -PassThru

# ===== MONITOREO =====
do {
    Start-Sleep 2

    if (-not (Get-Process -Id $Process.Id -ErrorAction SilentlyContinue)) {
        break
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
        Write-Host "`nERROR: Robocopy parece colgado." -ForegroundColor Red
        Stop-Process -Id $Process.Id -Force
        Pause
        exit 1
    }

    Write-Progress -Activity "Copiando archivos..." `
        -Status "Transferencia en curso..." `
        -PercentComplete ((Get-Random -Minimum 10 -Maximum 95))

} while ($true)

Write-Progress -Activity "Copiando archivos..." -Completed

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
Write-Host "Log: $LogFile"
Write-Host ""

# ===== PREGUNTAR SI CONTINUAR =====
$Continuar = Read-Host "¿Desea realizar otra transferencia? (S/N)"

} while ($Continuar -match '^(S|SI|Y|YES)$')

# ===== DESMAPEAR =====
Write-Host "`nDesmapeando unidad..." -ForegroundColor Cyan
net use Z: /delete /y | Out-Null
Write-Host "Proceso finalizado." -ForegroundColor Green
