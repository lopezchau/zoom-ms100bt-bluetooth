# Protocolo del ZOOM MS-100BT (Bluetooth)

Obtenido del desensamblado de la parte i386 de `ZOOM MS-100BT System v1.30 Updater.app`
(binario de 2013). La sección "Confirmado" se actualiza a medida que se prueba con el pedal real.

## Transporte

- Bluetooth clásico. Perfil **Serial Port** (SDP UUID `0x1101`) → canal RFCOMM.
- El pedal debe estar en **MENU → Bluetooth → PAIRING** (guía oficial de actualización).
- Se mandan **bytes SysEx MIDI crudos**, sin encapsulado extra. El envío se trocea según el MTU del canal.
- Recepción: se acumulan bytes hasta que el último sea `F7`. Luego se separan por cabecera:
  - `F0 52 xx 5D|5E …` → mensaje ZOOM (se ignoran otros IDs de modelo)
  - `F0 7E xx 06 …` → respuesta universal (identidad)
- Tiempo de espera de 5 s por mensaje, con hasta 5 reintentos.

## Mensajes enviados (`dev` = ID de modelo, 0x5D o 0x5E)

| Estado | Mensaje | Bytes |
|---|---|---|
| 1 | Consulta de identidad | `F0 7E 00 06 01 F7` |
| 2 | FS función 6 | `F0 52 00 dev 60 06 F7` |
| 3 | Bluetooth op 5 | `F0 52 00 dev 61 05 F7` |
| 4 | Flash op 1 | `F0 52 00 dev 01 F7` |
| 5–8 | Borrado de ROM | `makeRomEraseMessage` (regiones 0x0/0xA0000, 0x1FD000, 0x400000, 0xA0000/0x100000) |
| 9–12 | Escritura de ROM | `makeRomWritePacket` |
| 13 | Flash op 4 | `F0 52 00 dev 04 F7` |
| 14 | FS ACK (resultado 0) | `F0 52 00 dev 60 05 00 F7` |
| 15 | FS borrar archivo | `F0 52 00 dev 60 24 <nombre, 12 bytes con relleno de ceros> 00 F7` |
| 16 | FS escribir bloque | ver abajo |
| 17 | FS función 2 | `F0 52 00 dev 60 02 F7` |
| 18 | FS abrir archivo | `F0 52 00 dev 60 20 <flag 32→7 bits, 5 bytes> 00×5 <nombre, 12 bytes> 00 F7` (flag = 1) |
| 19 | FS cerrar archivo | `F0 52 00 dev 60 21 <handle> F7` |

**ADVERTENCIA:** los estados 5–13 reescriben el firmware. Nuestra herramienta **nunca** debe usarlos.

### FS escribir bloque (función 0x23)
```
F0 52 00 dev 60 23
<handle>                      (tal como lo devolvió "abrir")
<tamaño: 32 bits en 5 bytes de 7 bits, LSB primero>
<datos codificados 8→7>       (cada 7 bytes → 1 byte con los bits altos + 7 bytes de 7 bits)
<CRC32 de los datos originales: 5 bytes de 7 bits, LSB primero>
F7
```

### Codificación 8→7 (`convert8to7`)
Por cada grupo de hasta 7 bytes: primero un byte "MSB" cuyo bit 6 corresponde al 1.er byte,
el bit 5 al 2.º, etc. Después, los 7 bytes con el bit alto eliminado.

### Entero 32→7 (`convert32to7`)
5 bytes: `v & 7F, (v>>7) & 7F, (v>>14) & 7F, (v>>21) & 7F, v>>28`.

## Respuestas

- **Identidad:** `F0 7E ch 06 02 52 <ID> 00 <modo> … F7`. ID 0x5D/0x5E es aceptado; otro ID →
  "Illegal device connected". El byte 8 indica el modo (0, 1 u otro).
- **ZOOM** `F0 52 00 dev <func> <sub> …`:
  - func `00` → código de respuesta en el byte 5 (0 = OK; avanza la escritura de ROM)
  - func `60` (FS):
    - sub `03` → respuesta a abrir; los bytes 6–10 son un valor de 32 bits en 7 bits (handle, o error si es 0 o 0xFA)
    - sub `04` → "data send code" (control de flujo durante la escritura)
    - sub `05` → ACK; el byte 6 es el resultado (0 = OK)
  - func `61` (Bluetooth): sub `08` → 7 bytes en formato 8→7

## Motor de comunicación (`executeCommunication`)

Cada paso funciona así:
- Se envía el mensaje del estado y se espera la respuesta hasta 5 s. Si no llega, se reintenta hasta 5 veces.
- Si la respuesta es "ocupado", se reenvía hasta `txErrCount` veces, esperando `txErrWaitTime` entre intentos.
- Errores: ACK FS 3/0xFF y respuesta 0x0C/0xFF muestran el aviso "batería baja". ACK FS 1 con reintentos agotados da "error de transferencia".

Un **handshake FS** (`executeFsHandShake`) consiste en el mensaje de la operación seguido de `F0 52 00 dev 60 05 00 F7` (estado 14). Ambos esperan respuesta. zoom-zt2 hace exactamente lo mismo: manda `60 05 00` después de cada operación.

## Respuestas FS "data send" (sub 04): `F0 52 00 dev 60 04 <func> …`

Los índices cuentan desde el `F0`.
- func `02` (respuesta a "info FS") → bytes 20–24: `maxFFSWriteSize` (32 bits en 7 bits). Es el tamaño de bloque de escritura.
- func `20` (respuesta a "abrir") → bytes 11–15: **handle** de 5 bytes, que se copia tal cual en escribir y cerrar.
- func `23` (respuesta a "escribir") → avanza el progreso un bloque.

## CRC32
Valor inicial 0xFFFFFFFF, tabla estándar y **sin XOR final**, es decir, `zlib.crc32(datos) ^ 0xFFFFFFFF`.
Es idéntico a zoom-zt2.

## Flujo completo del actualizador en modo normal (byte de modo = 1)

1. Estado 1: identidad.
2. Estado 2: `60 06`, reenviado hasta 100 veces cada 50 ms hasta que el pedal acepte. Probablemente "preparar sistema de archivos".
3. Estado 3: `61 05` (función Bluetooth 5, significado desconocido).
4. Estado 4: `F0 52 00 dev 01 F7` (significado desconocido; podría preparar el modo actualización). **No usar sin investigarlo.**
5. Carga MAIN.bin y espera 0,5 s.
6. Handshake 0x11: `60 02` + `60 05 00` → obtiene `maxFFSWriteSize`.
7. **Para cada ZDL** (`executeZdlUpdate`):
   1. Estado 15: borrar → `60 24 <nombre>`
   2. Handshake 0x12: abrir → `60 20 01 …<nombre>` + `60 05 00` → handle
   3. Handshake 0x10 repetido: escribir bloques de `maxFFSWriteSize` → `60 23 <handle> <tam> <datos 8→7> <crc>` + `60 05 00`
   4. Estado 19: cerrar → `60 21 <handle>`
8. Estados 5–12: borrado y escritura de ROM (firmware). **Aquí paramos nosotros.**

La instalación de ZDL ocurre en **modo normal**, antes de tocar el firmware, y usa solo operaciones de archivos.
No está claro si los pasos 2–4 son necesarios para que el sistema de archivos responda. Lo comprobaremos con operaciones de solo lectura.

## Comandos FS adicionales conocidos por zoom-zt2 (G1 Four / MS Plus)

Son de solo lectura y no los usa el actualizador. Están por probar en el MS-100BT.

| Bytes | Uso |
|---|---|
| `60 25 00 00 <patrón> 00` | buscar primer archivo (`*` = todos); respuesta sub 04 con el nombre en bytes 15–27 |
| `60 26 00 00 <patrón> 00` | buscar siguiente |
| `60 27` | terminar la búsqueda |
| `60 29 00 00 00 00 00` | espacio en disco: bytes 11–15 total, 16–20 libre (7 bits, LSB primero) |
| `60 20 02 …<nombre> 00` | abrir para **lectura** |
| `60 22 …` | leer bloque |
| `60 09` | se envía después de cerrar |

En zoom-zt2, "abrir para escribir" es `60 20 01 00×9 <nombre> 00` (mismo formato que el actualizador: flag de 5 bytes + 5 de relleno) y el handle de escritura es `40 00 00 00 00`.

## Formato .ZDL

Cabecera `SIZE` / `INFO` con `"ZOOM EFFECT DLL SYSTEM VER 1.00"`, seguida de un ELF
(código del DSP). Es el mismo formato de la familia MS-50G / MS-60B / MS-70CDR.

Análisis de `LINESEL.ZDL` (9217 bytes):
- `00000000` y luego `SIZE`(8): `38 00 00 00` `b5 23 00 00`. 0x38 = 56 es el tamaño del bloque INFO+cabecera; 0x23B5 = 9141 es el tamaño del ELF.
- `INFO`(48): texto de versión del sistema, después `02 01 02 00 08 00 00 02` (probablemente tipo/categoría/ID del efecto) y la versión `"1.01"`.
- ELF de 32 bits little-endian en el offset 76, con `e_machine = 140` (**TI TMS320C6000**).
  Compilado con TI C6x Compiler v7.3.7 (2012). Parámetros visibles: `OnOff`, `LineSel`.
- Conclusión: el DSP es un TI C6000, el mismo que usa la familia MultiStomp. Los efectos
  personalizados se pueden compilar con el toolchain TI C6000, como hace el proyecto ZoomMultistompZDL para el MS-70CDR.

## Confirmado con el pedal real

Prueba del 2026-10-08: MacBook M1 con macOS 26.6.2 y pedal con SYSTEM 1.30 en MENU → Bluetooth → PAIRING.

- Nombre Bluetooth `ZOOM MS-100BT`, clase de dispositivo `0x240408`. El pedal **no** necesita emparejarse en Ajustes del Sistema.
- SDP anuncia dos servicios RFCOMM:
  - canal 1 "Serial Port": se abre, pero **no responde** a SysEx
  - canal 2 (sin nombre, con UUID 0x1101): **este es el canal MIDI**
- Si se abre el canal justo después de la consulta SDP, falla con `kIOReturnError` (0xE00002BC). Funciona cuando se abre directamente.
- MTU del canal: 503.
- Identidad: TX `F0 7E 00 06 01 F7` → RX `F0 7E 00 06 02 52 5E 00 01 00 31 2E 33 30 F7`
  - ID de modelo **0x5E**
  - byte de modo **0x01** en funcionamiento normal (por lo tanto 0x00 sería el modo de arranque/actualización)
  - versión de firmware en ASCII: `"1.30"`
- Respuesta en menos de 1 s.

### Sistema de archivos (2026-10-08, modo normal, SIN enviar `60 06` / `61 05` / `01`)

El sistema de archivos responde directamente después de la identidad. Los tres mensajes previos del actualizador **no son necesarios para leer**.

- `60 02` → `60 04 02 …`: `maxFFSWriteSize` en los bytes 20–24 = **4096**.
- `60 05 00` → `F0 52 00 5E 60 03 00 00 00 00 00 F7`, es decir, sub 03 con valor 0 = OK.
- `60 29 00×5` → total **4 143 170 bytes**, libre **752 560 bytes**.
- `60 25 00 00 '*' 00` / `60 26 …` → sub 04, con el nombre en los bytes 15–27 y el **tamaño del archivo en los bytes 30–34** (7 bits).
  Al terminar la lista llega sub 03 con valor `7A 7F 7F 7F 0F` = 0xFFFFFFFA. Ese es el "0xFA" que el actualizador trata como fin o "no encontrado".
- `60 27` → sub 03 con valor 0.
- **175 archivos** (lista en `pedal-files.txt`):
  - 101 de fábrica (orden alfabético), incluidos `CMN_DRV.ZDL` (controlador común de amplificadores) y `LINESEL.ZDL`.
  - `FLST_SEQ.ZDT` (4108 bytes): probablemente el orden de la lista de efectos.
  - `PAIR.DAT` (1024 bytes): datos de emparejamiento Bluetooth. **No tocarlo.**
  - 72 efectos añadidos después (la biblioteca de guitarra de StompShare): CLONECHO, SHIMMER, PARTICLE, HolyFLRB…
- `LINESEL.ZDL` en el pedal mide **9217 bytes**, idéntico al del actualizador.

### Lectura de archivos (confirmado 2026-10-08)

```
TX 60 20 02 00×9 <nombre> 00                  abrir para LECTURA
RX 60 04 20 00 00 04 00 <handle: 00 00 00 00 00> …   (handle en bytes 11–15; en el MS-100BT es 00×5)
TX 60 05 00            → RX 60 03 00…          ACK
repetir:
  TX 60 22 <handle 5> <tamaño pedido 5 (7 bits)>
  RX 60 04 22 00 …                             confirmación corta (byte 7 = 00)
  TX 60 05 00
  RX 60 04 22 01 00 <lenLo> <lenHi> <datos 8→7 desde el byte 11> <CRC 5> F7   (byte 7 = 01 indica datos)
  TX 60 05 00            → RX 60 03 00…
  (termina cuando len < tamaño pedido)
TX 60 21 <handle>      → RX 60 03 00…          cerrar
TX 60 09               → RX 60 05 00            fin de sesión de archivo
```
- El CRC del bloque de datos es `zlib.crc32(bloque) ^ 0xFFFFFFFF`.
- Funciona con bloques de 512 y de **4096** bytes (este último es unas 2 veces más rápido: 9 KB en 1,8 s).
- Verificación: `LINESEL.ZDL` leído del pedal es **idéntico byte a byte** al archivo del actualizador (CRC32 0x80b78c37).
- El primer intento de lectura emparejó el pedal automáticamente con macOS (aparece en la lista de emparejados).
- **Respaldo completo** (2026-10-08): los 175 archivos en `backup/2026-10-08-completo/` (3,2 MB, 398 s), con
  `MANIFEST.txt` (nombre, tamaño y CRC32). Todos los tamaños coinciden con el listado y todos los .ZDL tienen cabecera válida.

### Escritura de archivos (confirmado 2026-10-08)

Se reescribió `LINESEL.ZDL` (9217 bytes) con su mismo contenido, en modo normal y sin `60 06` / `61 05` / `01`:
```
TX 60 24 "LINESEL.ZDL" 00                        → RX 60 03 00×5         borrar (OK)
TX 60 20 01 00×9 "LINESEL.ZDL" 00                → RX 60 04 20 … handle 00×5
TX 60 05 00                                      → RX 60 03 00×5
por bloque (4096, 4096, 1025):
  TX 60 23 <handle 00×5> <tam 5> <datos 8→7> <CRC 5>   → RX 60 04 23 00 00 04 00 <tam 5> …  (eco del tamaño)
  TX 60 05 00                                    → RX 60 03 00×5
TX 60 21 <handle>                                → RX 60 03 00×5         cerrar
TX 60 09                                         → RX 60 05 00
```
- CRC del bloque = `zlib.crc32(bloque) ^ 0xFFFFFFFF`, igual que en la lectura.
- Bloques de 4096 bytes (`maxFFSWriteSize`), es decir, 4704 bytes de SysEx enviados en trozos del MTU (503).
- Una nueva lectura dio un archivo **idéntico** (CRC32 0x80b78c37). La escritura completa más la verificación tardaron unos 5 s.

## `FLST_SEQ.ZDT`: orden y categorías de la lista de efectos

Archivo de 4108 bytes formado por **registros de 13 bytes** (nombre 8.3 de hasta 12 caracteres + NUL, con relleno de ceros):
- `>>>\0` + `u32 categoría` + ceros → inicio de categoría
- `NOMBRE.ZDL\0…` → un efecto, en el orden en que aparece en el pedal
- `<<<\0` + `u32 categoría` + ceros → fin de categoría

Hay categorías de 0x00 a 0x1A o más; muchas están vacías. Datos útiles hasta el byte 3072, después ceros.

| Cat. | Contenido (ejemplos) |
|---|---|
| 01 | dinámica: COMP, RACKCOMP, ZNR, NOISEGTE… |
| 02 | filtro: LINESEL, GEQ, AUTOWAH, SLOWFLTR… |
| 03 | drive: BOOSTER, T_SCREAM, Z_* … |
| 04 | amplificador: FDCOMBO, MS_1959, HW_STACK… |
| 05 | vacía (¿amplificadores de bajo en otros modelos?) |
| 06 | modulación: TREMOLO, CHORUS, PHASER… |
| 07 | SFX: BITCRUSH, BOMBER, Z_ORGAN… |
| 08 | delay: DELAY, TAPEECHO, ICEDLY… |
| 09 | reverb: HALL, SHIMMER, PARTICLE, PLATE… |

Los efectos de StompShare aparecen al final de su categoría. Esto confirma que, para que un efecto nuevo
aparezca en el menú, **hay que subir el .ZDL y además insertar su nombre en `FLST_SEQ.ZDT`** dentro de la categoría correcta.
Es una hipótesis razonable; queda por confirmar.

## Instalación de un efecto nuevo (2026-10-08): Z_SYN del MS-60B

1. Se escribió `Z_SYN.ZDL` (14 097 B, 4 bloques) y se verificó con CRC32 5f19a8d2.
   El borrado previo respondió `60 03 7A 7F 7F 7F 0F` (0xFFFFFFFA = no existe), lo cual es inofensivo.
2. Se escribió `FLST_SEQ.ZDT` con `Z_SYN.ZDL` añadido al final de la categoría 07 y se verificó con CRC32 b832cbf8.
   - **El handle no siempre es 00×5:** al abrir FLST_SEQ.ZDT el pedal devolvió `54 26 46 28 0E`. Siempre hay que usar el handle que devuelve "abrir".
3. Resultado en el pedal: pendiente de confirmar (tras reiniciar, Z_SYN debe aparecer en SFX).
