# 📁 Guía de Usuario - Transferencia Automatizada NAS

**Versión 1.0** | Herramienta para copiar archivos al NAS de forma segura y eficiente

---

## 🚀 Inicio Rápido

### ¿Qué hace este programa?
Copia carpetas completas desde tu computadora hacia el NAS (almacenamiento de red) de manera automática.

### Requisitos
- ✅ Windows 11
- ✅ Conexión de red al NAS
- ✅ Credenciales del NAS (usuario y contraseña)

---

## 📖 Cómo Usar el Programa

### **Paso 1: Preparación**

1. **Verificar acceso al NAS** (IMPORTANTE - OBLIGATORIO):
   - Abre el **Explorador de Archivos**
   - En la barra de direcciones escribe: `\\192.168.1.254`
   - Presiona Enter
   - **Si pide credenciales, ingrésalas y marca "Recordar mis credenciales"**
   - Verifica que puedas ver las carpetas del NAS
   - ✅ **Este paso evita que el script pida credenciales nuevamente**

2. **Configurar permisos** (solo la primera vez):
   - Abre PowerShell
   - Ejecuta: `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`
   - Confirma con `S`

3. **Ubicar el script**:
   - Guarda `Transferencia-NAS-v3.0.ps1` en una carpeta fácil de encontrar
   - Ejemplo: `C:\Scripts\`

---

### **Paso 2: Ejecutar el Programa**

1. **Clic derecho** en el archivo `Transferencia-NAS-v3.0.ps1`
2. Selecciona **"Ejecutar con PowerShell"**

![Pantalla inicial]
```
================================
 TRANSFERENCIA AUTOMATIZADA NAS
 Versión 1.0
================================

Seleccione la carpeta de destino en el NAS:

  1. Historico
  2. EDI
  3. ATO
  4. Pruebas
  5. Otra

Ingrese opción (1-5):
```

---

### **Paso 3: Seleccionar Destino en el NAS**

**Opción recomendada**: Elige `1`, `2` o `3` para carpetas predefinidas

**Opción avanzada**: Elige `5` para ingresar una ruta personalizada
- Formato: `\\192.168.1.254\NombreCarpeta`
- Ejemplo: `\\192.168.1.254\Proyectos`

---

### **Paso 4: Seleccionar Carpeta Origen**

```
Ingrese ruta ORIGEN (carpeta completa): 
```

**Ejemplos válidos:**
- `C:\Documentos\Proyecto2024`
- `D:\Backups\Importante`
- `\\OtraPC\Compartida\Datos`

**💡 Tip**: Puedes copiar la ruta desde el Explorador de Windows

---

### **Paso 5: Validaciones Automáticas**

El programa verificará:

✅ **Archivos encontrados**: Cuántos archivos detectó
```
Analizando archivos de origen...
Archivos encontrados: 1234
```

⚠️ **Advertencias posibles**:
- Caracteres especiales en nombres (como `<>"|?*`)
- Rutas muy largas (>240 caracteres)
- Archivos que podrían estar abiertos

**¿Qué hacer?**
- Si aparece advertencia → Puedes continuar (`S`) o cancelar (`N`)
- El programa intentará copiar de todas formas

---

### **Paso 6: Confirmar Destino**

```
Resumen:
Origen : C:\Documentos\Proyecto2024
Destino: \\192.168.1.254\Pruebas\Proyecto2024
Log    : C:\Logs\robocopy_20260212_143055_transferencia1.txt

¿Desea iniciar la transferencia?
Ingrese S para continuar o N para poner otra destino:
```

- **S** = Continuar
- **N** = Cambiar la carpeta de destino

---

### **Paso 7: Archivos Existentes** (si aplica)

Si el destino ya tiene archivos:

```
El destino contiene archivos existentes

Información de la transferencia:
  Total de archivos en ORIGEN: 16 archivos
  Tamaño total: 67.3 MB
  Archivos encontrados en DESTINO: 50+ archivos

¿Desea analizar archivos antes de copiar? (S/N):
```

**💡 Nuevo comportamiento:**
- **ANALIZA TUS ARCHIVOS DE ORIGEN** (no los del destino)
- Muestra exactamente qué archivos DE TU ORIGEN se copiarán o se omitirán
- Predicción más precisa para estrategia #1 (Reemplazar si es más nuevo)

**Si eliges S**, el programa analizará hasta 20 archivos de TU ORIGEN:

```
Analizando archivos de ORIGEN (muestra de hasta 20)...
Comparando con archivos en destino para estrategia 'Reemplazar si es más nuevo'

  ✓ \nochancar1.txt [MÁS NUEVO - se copiará]
  ✗ \nochancar2.txt [misma fecha - se omitirá]
  ✗ \nochancar3.txt [misma fecha - se omitirá]
  ✓ \BBBB_BBBB\archivoNUEVO.pdf [NUEVO - se copiará]
  ✓ \BBBB_BBBB\archivoMOD.xlsx [MÁS NUEVO - se copiará]
  ✗ \BBBB_BBBB\archivoSIN_CAMBIO.doc [misma fecha - se omitirá]
  ... y 10 archivo(s) más no mostrados

========================================
PREDICCIÓN (basada en muestra de 20 archivos):
========================================
  ✓ Se copiarán (nuevos o más recientes): 13
  ✗ Se omitirán (misma fecha o más viejos): 3

  💡 Este análisis muestra archivos de TU ORIGEN
     Robocopy procesará los 16 archivos totales
========================================
```

**🔍 Leyenda:**
- **✓** (marca verde) = Se COPIARÁ este archivo
  - `[MÁS NUEVO]`: Tu versión es más reciente
  - `[NUEVO]`: No existe en destino
- **✗** (marca gris) = Se OMITIRÁ este archivo
  - `[misma fecha]`: Fechas idénticas
  - `[más viejo]`: Destino tiene versión más nueva

**🎯 Ventajas del nuevo análisis:**
1. Muestra TUS archivos que vas a copiar
2. Identifica archivos NUEVOS (que no existen en destino)
3. Predicción más precisa de lo que Robocopy hará
4. Fácil de entender: ✓ = copiar, ✗ = omitir

**Luego elige estrategia:**
```
Seleccione estrategia de copia:
(Esta estrategia se aplicará a TODOS los archivos de la transferencia)

  1. Reemplazar si es más nuevo (recomendado)
  2. Omitir archivos existentes
  3. Sobrescribir todo

Seleccione (1-3, Enter=1):
```

| Opción | ¿Qué hace? | ¿Cuándo usar? |
|--------|------------|---------------|
| **1** | Compara fechas de cada archivo. Solo copia si origen es más nuevo | Actualizar backups, sincronización incremental |
| **2** | No toca archivos que ya existen en destino (sin importar fecha) | Preservar versiones en destino, no sobrescribir nada |
| **3** | Reemplaza TODO sin comparar fechas | Forzar copia completa desde cero |

**💡 Resumen clave**: 
- El análisis de 20 archivos es SOLO para que entiendas cómo funciona
- Los números reales los verás al final en el resumen de Robocopy
- Robocopy compara CADA archivo de tu origen contra lo que existe en destino

---

### **Paso 8: Opciones de Archivos**

```
¿Desea excluir archivos temporales y de sistema?
  - Archivos temporales: ~$*, *.tmp, *.temp, *.bak
  - Carpetas del sistema: Thumbs.db, .DS_Store, desktop.ini

¿Excluir archivos temporales? (S/N):
```

**Recomendación**: `S` para excluir archivos innecesarios

---

### **Paso 9: Verificación de Espacio**

```
Verificando espacio disponible...
Espacio requerido: 2.5 GB
Espacio disponible: 150 GB
Espacio suficiente disponible

Timeout configurado: 7.5 minutos (ajustado según tamaño)
```

✅ El programa calcula automáticamente el tiempo máximo de espera

---

### **Paso 10: Transferencia en Progreso**

```
Iniciando transferencia...

Copiando archivos... (puede tardar varios minutos)
Monitor de actividad:

 [Log: 5.2 KB - Activo]
```

**Durante la copia:**
- Verás actualizaciones cada 30 segundos
- El programa verifica la conexión automáticamente
- Si se detecta un problema, se detiene para prevenir errores

**⏱️ Tiempo estimado**: Depende del tamaño y cantidad de archivos
- 100 MB → ~30 segundos
- 1 GB → ~3-5 minutos
- 10 GB → ~30-40 minutos

---

### **Paso 11: Resumen Final**

```
--------------------------------
 RESUMEN DE TRANSFERENCIA
--------------------------------

Dirs :        10         0        10         0         0         0
Files:       123       123         0         0         0         0
Bytes:  256.5 MB  256.5 MB         0         0         0         0

================================
 TRANSFERENCIA COMPLETADA
================================
Estado: Éxito - Archivos copiados correctamente
Log: C:\Logs\robocopy_20260212_143055_transferencia1.txt

¿Desea realizar otra transferencia? (S/N):
```

**Opciones:**
- **S** = Hacer otra transferencia (sin cerrar el programa)
- **N** = Salir del programa

---

## 🔍 Entender el Resumen

| Columna | Significado |
|---------|-------------|
| **Dirs** | Cantidad de carpetas |
| **Files** | Cantidad de archivos |
| **Bytes** | Tamaño total copiado |

**Estados posibles:**
- ✅ **Éxito**: Todo copiado correctamente
- ✅ **Sin cambios**: Archivos ya estaban actualizados
- ⚠️ **Advertencia**: Algunos archivos no coinciden
- ❌ **Error**: Algunos archivos NO se copiaron

---

## 📋 Logs y Registros

### Ubicación de Logs
```
C:\Logs\robocopy_AAAAMMDD_HHMMSS_transferenciaN.txt
```

**Ejemplo**: `robocopy_20260212_143055_transferencia1.txt`
- `20260212` = Fecha (12 de febrero 2026)
- `143055` = Hora (14:30:55)
- `transferencia1` = Número de transferencia en la sesión

### ¿Para qué sirven los logs?
- 📝 Ver qué archivos se copiaron
- ❌ Identificar errores específicos
- 📊 Estadísticas detalladas de la transferencia
- 🔍 Auditoría y seguimiento

---

## ⚠️ Problemas Comunes

### ❌ "ERROR: La ruta no existe"
**Causa**: La carpeta que escribiste no se encuentra  
**Solución**: Verifica que la ruta esté bien escrita y exista

### ❌ "No se pudo conectar al NAS"
**Causa**: Credenciales incorrectas o NAS no disponible  
**Solución**: 
1. Verifica el usuario y contraseña
2. Confirma que el NAS esté encendido
3. Verifica la conexión de red

### ⚠️ "Archivos con caracteres especiales"
**Causa**: Nombres con `< > : " | ? *`  
**Solución**: Puedes continuar, pero considera renombrar esos archivos

### ⚠️ "Archivos que podrían estar en uso"
**Causa**: Excel, Word u otros programas tienen archivos abiertos  
**Solución**: Cierra los archivos antes de copiar (recomendado)

### ⏱️ "Robocopy atascado en bucle de reintentos"
**Causa**: Pérdida de conexión o problema de permisos  
**Solución**: El programa se detendrá automáticamente tras 90 segundos

---

## 💡 Consejos y Mejores Prácticas

### ✅ Antes de copiar:
1. **Cierra archivos abiertos** en Office
2. **Verifica espacio disponible** en el NAS
3. **Usa nombres simples** sin caracteres raros

### ✅ Durante la copia:
1. **No desconectes** el cable de red
2. **No apagues** la computadora
3. **No suspendas** el equipo

### ✅ Después de copiar:
1. **Revisa el resumen** para confirmar éxito
2. **Verifica archivos** en el NAS si es crítico
3. **Consulta el log** si hubo advertencias

---

## 🔐 Seguridad

### ¿Es seguro este programa?
✅ **Sí**, el programa:
- No modifica archivos originales
- Solo **copia** (no mueve ni elimina)
- Usa herramientas nativas de Windows (Robocopy)
- Credenciales manejadas por sistema de Windows
- No envía datos a internet

### ¿Qué permisos necesita?
- ❌ **No necesita** permisos de administrador
- ✅ Solo necesita acceso al NAS (con tus credenciales)

---

## 📞 Soporte

### ¿Necesitas ayuda?

**Revisa el log:**
```
C:\Logs\robocopy_[fecha]_[hora]_transferencia[N].txt
```

**Información útil para reportar problemas:**
- Mensaje de error exacto
- Ruta de origen y destino
- Contenido del archivo log
- Tamaño y cantidad de archivos

**Contacto:**
- Área de TI - EVT Sucursal Perú
- Keler Modesto

---

## 📚 Glosario

| Término | Significado |
|---------|-------------|
| **NAS** | Almacenamiento de red compartido |
| **Robocopy** | Herramienta de Windows para copiar archivos |
| **UNC** | Formato de ruta de red (`\\servidor\carpeta`) |
| **Timeout** | Tiempo máximo de espera sin actividad |
| **Log** | Archivo de registro con detalles de la operación |

---

## 📄 Versión del Documento

**Versión**: 1.0  
**Fecha**: 13 de febrero de 2026  
**Compatible con**: Transferencia-NAS-v3.0.ps1 (v1.0)  
**Estado**: Pre-producción

---

✨ **¡Gracias por usar Transferencia Automatizada NAS!** ✨
