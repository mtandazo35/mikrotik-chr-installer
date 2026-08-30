# mikrotik-chr-installer

Instalador de **MikroTik CHR** (Cloud Hosted Router) para **Proxmox VE**, en una sola línea.

Crea la VM, descarga la imagen oficial, importa el disco en `virtio-blk` y la
arranca. Interactivo: pregunta versión, VMID, recursos, storage, bridge y VLAN,
detectando en cada nodo lo que hay disponible.

Reemplaza al viejo `mikrotikinstall.sh` que vivía en `/root` de los nodos y que
creaba VMs que RouterOS 6.x no podía arrancar.

---

## ⚡ Instalación rápida (one-liner)

En el nodo Proxmox, **como root**:

```bash
curl -fsSL https://raw.githubusercontent.com/mtandazo35/mikrotik-chr-installer/v1.3/install.sh | bash
```

Deja el instalador en `/root/mikrotik-chr-install.sh` y lanza el asistente.
Para reejecutarlo después no hace falta volver a descargar: `bash /root/mikrotik-chr-install.sh`.

Otra rama o versión:

```bash
CHR_REF=main curl -fsSL https://raw.githubusercontent.com/mtandazo35/mikrotik-chr-installer/main/install.sh | bash
```

### Qué comprueba antes de tocar nada

| Comprobación | Si falla |
|---|---|
| Usuario `root` | aborta |
| Existe `qm` (es un nodo Proxmox) | aborta |
| Existe `curl` | aborta |
| **Versión de Proxmox VE ≥ 6.4** | aborta indicando la versión detectada |
| Versión fuera de soporte upstream (< 8) | avisa y continúa |
| Hay terminal interactivo | aborta **explicando cómo hacerlo a mano** |
| Lo descargado empieza por el shebang | aborta (una ref inexistente devuelve HTML, no script) |
| El script pasa `bash -n` | aborta |

### Por qué hay un bootstrap y no se ejecuta el instalador directo

`mikrotik-chr-install.sh` es **interactivo**. En un `curl … | bash` el `stdin`
del proceso es la tubería de curl, así que cada `read` se tragaría el propio
script en vez de esperar al usuario: el asistente se contestaría solo con
basura.

`install.sh` lo evita ejecutando el instalador con **`< /dev/tty`**, que
reconecta el terminal real. Comprobado: con el método ingenuo la pregunta nunca
llega; con `/dev/tty` el proceso tiene `stdin` en una tubería y aun así lee del
teclado.

---

## Compatibilidad con Proxmox VE

El instalador **detecta la versión de PVE y se adapta**, en vez de asumir uno.

| PVE | Estado | Notas |
|---|---|---|
| **9.x** | probado | referencia de desarrollo |
| **8.x** | soportado | |
| **7.1 – 7.4** | soportado con aviso | fuera de soporte upstream |
| **6.4 – 7.0** | soportado con aviso | CPU portable cae a `kvm64` (no hay `x86-64-v2-AES` antes de PVE 7.1) |
| **< 6.4** | **rechazado** | `qm create --tags` todavía no existe |

Dos detalles que cambian entre versiones y se resuelven **por capacidad, no por
número de versión** — más fiable que mantener una tabla de equivalencias:

- **Importar disco** — `qm disk import` (actual) o `qm importdisk` (nombre
  antiguo, aún presente como alias). Se elige el que exista.
- **Redimensionar** — `qm disk resize` o `qm resize`, igual.

Si el nodo no expone ninguno de los dos, el script lo dice y se detiene en vez
de fallar a medio camino.

---

## Requisitos

- Nodo Proxmox VE 6.4 o superior, acceso `root`.
- `curl`. `unzip` y `wget` se instalan solos si faltan.
- Salida a internet para bajar la imagen de MikroTik.

---

## El bug que motivó este repo

El instalador anterior colgaba el disco del CHR de **virtio-scsi**:

```bash
--scsihw virtio-scsi-single \
--scsi0 local:$vmID/vm-$vmID-disk-1.qcow2
```

**RouterOS 6.x no tiene driver de virtio-scsi.** El resultado es una VM que
arranca el bootloader (que usa BIOS y sí lee el disco) pero cuyo kernel no
encuentra ningún dispositivo de bloque y muere en:

```
Loading system with initrd
ERROR: could not find disk!
Please attach it somewhere else.
```

Síntomas típicos: la VM figura `running` pero nunca escribe al disco
(`wr_bytes: 0`), y `qm shutdown` / `qm reboot` / `qm stop` dan timeout porque
no hay sistema operativo que responda a ACPI.

**El fix**: el disco va en `virtio0` (virtio-blk), soportado por RouterOS 6.x
y 7.x por igual.

Caso real reproducido en un nodo Proxmox VE 9 con un CHR 6.40.1 creado por el
script viejo: la VM arranca el bootloader pero el kernel no encuentra disco.

---

## Diferencias con el script viejo

| # | `mikrotikinstall.sh` (viejo) | Este instalador |
|---|---|---|
| 1 | `--scsi0` + `virtio-scsi-single` — rompe RouterOS 6.x | `--virtio0` (virtio-blk) — funciona en 6.x y 7.x |
| 2 | `wget` sin verificar: un 404 seguía adelante y creaba una VM con disco vacío | Valida la descarga y el ZIP (`unzip -t`); aborta si falla |
| 3 | `mkdir /var/lib/vz/images/$vmID` + `local:` fijo — solo storages tipo `dir` | `qm disk import` sobre cualquier storage activo (dir, LVM, ZFS, Ceph...) |
| 4 | `dpkg -l \| grep -q unzip` — falso positivo con cualquier paquete que mencione "unzip" | `command -v unzip` |
| 5 | VMID: solo miraba si existía el directorio | Consulta `/cluster/resources` + los `.conf`; sugiere `nextid` |
| 6 | `qm resize +0.875G` — asume que la imagen mide 128 MB | Tamaño absoluto configurable |
| 7 | Sin `--balloon 0` (CHR no lleva bien el ballooning) | `--balloon 0` |
| 8 | Sin `discard=on` | `discard=on` (thin provisioning real) |
| 9 | `--cores 1 --memory 1024 --net0 vmbr0` fijos, sin preguntar | Pregunta cores, RAM, disco, storage, bridge y VLAN |
| 10 | `--bootdisk` (obsoleto), sin `--boot order=` | `--boot order=virtio0` |
| 11 | Sugería versiones 6.x en el prompt | Consulta la última estable en `LATEST.7` y avisa si eliges una 6.x |
| 12 | Sin `--agent` | `--agent 1` en RouterOS 7.x |

---

## Genérico para cualquier Proxmox

Nada está hardcodeado según el hardware del nodo donde se probó:

- **`cpu=`** — `host` si el nodo es standalone (máximo rendimiento). Si existe
  `/etc/pve/corosync.conf` usa un modelo portable, para no romper la migración
  en vivo en clusters con CPU heterogénea: `x86-64-v2-AES` en PVE 7.1+, y
  `kvm64` en versiones anteriores, donde ese modelo todavía no existe.
- **Tipo de medio** — resuelve el storage a sus discos físicos
  (`lvm`/`lvmthin` vía `pvs`, `dir` vía `findmnt` — incluido root-on-ZFS —,
  `zfspool` vía `zpool list`) y consulta `lsblk ROTA`, para decirte si estás
  desplegando sobre SSD o sobre disco rotacional. Si el storage es remoto
  (NFS, CIFS, CephFS, RBD) no se puede saber y lo dice, sin preguntar.

  **No se aplica `ssd=1`**: Proxmox solo acepta esa propiedad en `ide`, `sata`
  y `scsi`. En `virtio0` el API la rechaza con
  `virtio0.ssd: property is not defined in schema`, y como este instalador usa
  virtio-blk a propósito, el flag no es aplicable nunca.
- **Storage y bridge** — se listan los realmente disponibles en el nodo. Los
  bridges se leen de la **configuración de red** (`/etc/network/interfaces`,
  `interfaces.d/` y las vnets de SDN), no de `/sys/class/net`: ahí aparecen
  también los internos de Proxmox —`fwbr<vmid>i<n>` (firewall, uno por NIC) y
  `vmbr0v<vlan>` (sub-bridge de un `tag=`)— que nunca son destino válido.
  Reconoce bridges Linux, **Open vSwitch** (`ovs_type OVSBridge`) y **SDN**, así
  que no depende de que se llamen `vmbrN`.

---

## Uso manual

Si prefieres no usar el one-liner:

```bash
scp mikrotik-chr-install.sh root@<nodo-proxmox>:/root/
ssh root@<nodo-proxmox>
chmod +x /root/mikrotik-chr-install.sh
/root/mikrotik-chr-install.sh
```

Si algo falla durante la importación del disco, la VM a medio crear **se
elimina sola** (`qm destroy --purge`) para no dejar basura. El log de la
importación queda en `/tmp/chr-import-<VMID>.log`.

---

## Notas

- Las imágenes descargadas quedan cacheadas en `/root/temp/chr/`.
- Usuario por defecto del CHR: `admin` **sin contraseña**. Cámbiala en el
  primer acceso.
- Evita RouterOS 6.x: fuera de soporte y con CVEs conocidas (p. ej.
  `CVE-2018-14847` en Winbox). El script avisa y pide confirmación.
- El instalador va a `/root`, no a `/tmp`: sobrevive reinicios y se puede
  reejecutar sin volver a descargarlo.
- `.gitattributes` fuerza `eol=lf`. Un CRLF hace que Linux responda
  `No such file or directory` al ejecutar el script, sin que git lo delate.
