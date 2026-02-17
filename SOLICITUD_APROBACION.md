# Solicitud de Aprobación - Solución de Transferencia NAS

**Para:** Equipo de Aprobaciones y Desarrollo Corporativo  
**De:** Keler Modesto - TI, EVT Sucursal del Perú  
**Fecha:** 17 de febrero de 2026  
**Ref. Incidente:** INC0192003 (creado 23-12-2025)

---

## 🎯 Contexto del Incidente

El incidente **INC0192003** escaló por múltiples grupos sin resolución efectiva:
- **GS_EGG_APP_SNW_HELPDESK-MEXICO** (sin resolución)
- **GS_EGG_APP_SNW_APPLICATION_PLATFORM_WIN** (Manish Kumar sugirió solución local con Robocopy)
- **GS_EGG_APP_SNW_HELPDESK-TUNISIA** → **SUPPORT-BRAZIL** → **SUPPORT-LATIN-AMERICA**

**Prioridad:** Alta | **Impacto:** Medio  
**Recomendación recibida:** Implementar Robocopy localmente para resolver transferencias a NAS.

---

## 🛠️ Solución Implementada

### Evolución Técnica

**Versión Batch (descartada):**
- Manejo limitado de credenciales
- Sin validación dinámica de rutas
- Ausencia de logs estructurados

**Versión PowerShell v1.0 (implementada):**
- Arquitectura UNC directa (sin mapeo de unidades)
- Un solo escaneo de origen
- Monitoreo basado en crecimiento de logs
- Validación silenciosa de exit codes

---

## 📋 Especificaciones Técnicas

### Requisitos del Sistema
- **OS:** Windows 11 (PowerShell 5.1+ y Robocopy incluidos)
- **Permisos:** No requiere administrador
- **Logs:** Creación automática en `C:\Logs\`

### Parámetros Robocopy
```
/E /Z /MT:16 /R:10 /W:30 /COPY:DATS /DCOPY:DAT /A-:SH
```

**Significado:**
- `/E` - Copia subdirectorios completos (incluye vacíos)
- `/Z` - Modo reiniciable (resistente a interrupciones)
- `/MT:16` - 16 hilos paralelos
- `/R:10 /W:30` - 10 reintentos con 30s de espera
- `/COPY:DATS` - Datos, atributos, timestamps, seguridad
- `/DCOPY:DAT` - Datos, atributos, timestamps de directorios
- `/A-:SH` - Quita atributos System y Hidden

### Estrategias de Copia
1. **Incremental** (`/XO`) - Solo archivos más nuevos
2. **Solo nuevos** (`/XC /XN /XO`) - Omite existentes
3. **Forzar todo** (`/IS /IT`) - Copia incluso idénticos

### Funcionalidades Clave
✅ Autenticación con credenciales del sistema  
✅ Menú preconfigurado (Histórico/EDI/ATO/Pruebas/Otra)  
✅ Validación de caracteres inválidos y rutas largas (+240 caracteres)  
✅ Detección de pérdida de conexión cada 10 segundos  
✅ Logs individuales con timestamp: `robocopy_AAAAMMDD_HHMMSS_transferenciaN.txt`  
✅ Rotación automática de logs >30 días  
✅ Bucle de transferencias múltiples sin reiniciar  
✅ Análisis predictivo de archivos a copiar (muestra de 20 archivos)

---

## 🚀 Opciones de Despliegue

### **Opción A: Script .ps1** (Implementación Inmediata)
- **Requisito único:** `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`
- **Ventaja:** Despliegue inmediato
- **Consideración:** Código visible/editable

### **Opción B: Ejecutable .exe** (Recomendado)
- **Ventajas:**
  - Ejecución estándar sin configuración
  - Código protegido
  - Experiencia profesional
  - Mayor adopción por usuarios no técnicos
- **Requerimiento:** Herramienta corporativa con firma digital certificada

---

## 📝 Solicitud Específica

### 1. Aprobación Inmediata
Autorizar despliegue de **Transferencia-NAS-v3.0.ps1** (versión 1.0) en:
- **Usuario:** GUTIERREZ Valerie
- **Usuario:** PACHERRES Rolando

### 2. Evaluación de Conversión .EXE
Solicito que el equipo de desarrollo corporativo evalúe:
- Conversión PS1 → EXE con firma certificada
- Integración al catálogo de herramientas aprobadas
- Despliegue masivo posterior

---

## 📦 Recursos Disponibles

**Código fuente y documentación:**  
🔗 https://egis-group.fromsmash.com/LbvZywuEGD-ct

**Contenido del paquete:**
- `Transferencia-NAS-v3.0.ps1` (versión español)
- `NAS-Transfer-v1.0.ps1` (versión inglés)
- `GUIA_USUARIO.md` (11 pasos ilustrados)
- `USER_GUIDE.md` (English version)

**Disponibilidad para:**
- ✅ Demostración en vivo
- ✅ Auditoría de código
- ✅ Pruebas en entorno controlado
- ✅ Capacitación de usuarios

---

## ⏱️ Urgencia

La solución está **operativa y probada**. Se solicita aprobación para cerrar **INC0192003** que lleva **56 días abierto** (desde 23-12-2025).

---

**Contacto:**  
Keler Modesto  
Área de TI - EVT Sucursal del Perú  
Ext: [tu extensión]  
Email: [tu email]
