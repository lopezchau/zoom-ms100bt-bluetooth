# zoom-ms100bt-bluetooth

Una herramienta para macOS (incluido Apple Silicon) que se comunica con el pedal **ZOOM MS-100BT MultiStomp** por Bluetooth.
El objetivo final es instalar efectos nuevos, incluidos efectos personalizados, sin depender de la app StompShare para iOS,
que está abandonada.

> Proyecto independiente, sin relación con ZOOM Corporation. Úsalo bajo tu propia responsabilidad.

## Estado

| Paso | Estado |
|---|---|
| Descifrar el protocolo del actualizador oficial (v1.30, i386/PPC) | ✅ |
| Identificación del pedal por Bluetooth desde un M1 | ✅ |
| Listado de archivos, espacio libre e info del sistema de archivos | ✅ |
| Respaldo completo de los archivos del pedal (lectura verificada con CRC) | ✅ |
| Escritura de un efecto (`.ZDL`) con verificación por relectura | ✅ |
| Registrar efectos en `FLST_SEQ.ZDT` | ⏳ siguiente |
| Efectos personalizados (DSP TI C6000) | ⏳ |
| Interfaz gráfica | ⏳ |

Los detalles técnicos están en [PROTOCOL.md](PROTOCOL.md).

## Requisitos

- macOS 12 o posterior, con las Command Line Tools de Xcode (`swiftc`)
- Un ZOOM MS-100BT (probado con SYSTEM 1.30)

## Compilar

```bash
./build.sh
```

Genera `build/MS100BTProbe.app`, una app sin ventana que declara el permiso de Bluetooth que exige macOS.

## Uso

Primero pon el pedal en **MENU → Bluetooth → PAIRING**.

```bash
# Identificación (solo lectura)
open -W build/MS100BTProbe.app --args --log "$PWD/logs/probe.txt"

# Info del sistema de archivos y listado de archivos (solo lectura)
open -W build/MS100BTProbe.app --args --log "$PWD/logs/fs.txt" --fs

# Respaldo completo de los archivos del pedal (solo lectura)
open -W build/MS100BTProbe.app --args --log "$PWD/logs/backup.txt" --backup "$PWD/backup/$(date +%F)" --chunk 4096
```

Opciones:
- `--address XX-XX-XX-XX-XX-XX`: no buscar el pedal y usar esa dirección
- `--channel N`: canal RFCOMM; en el MS-100BT el canal MIDI es el 2
- `--only NOMBRE`: respaldar un solo archivo

Escribir un archivo (primero simula; después escribe de verdad y verifica volviendo a leerlo):

```bash
open -W build/MS100BTProbe.app --args --log "$PWD/logs/w.txt" --write RUTA/ARCHIVO.ZDL --dry-run
open -W build/MS100BTProbe.app --args --log "$PWD/logs/w.txt" --write RUTA/ARCHIVO.ZDL --confirm-write
```

La herramienta nunca envía los comandos de borrado o escritura de firmware y se niega a tocar `PAIR.DAT` y `FLST_SEQ.ZDT`.

## Aviso

Este repositorio no incluye archivos de ZOOM: ni firmware, ni efectos `.ZDL`, ni los respaldos. `.gitignore` los excluye.
La licencia del actualizador oficial prohíbe la ingeniería inversa. Este trabajo se hizo solo con fines de
interoperabilidad, con un pedal propio.
