# mikrotik-chr-installer

Instalador de MikroTik CHR (Cloud Hosted Router) para Proxmox VE.

Reemplaza al viejo `mikrotikinstall.sh` que vivía en `/root` de los nodos.

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
| 8 | Sin `discard=on`, sin detección de SSD | `discard=on` + `ssd=1` auto-detectado |
| 9 | `--cores 1 --memory 1024 --net0 vmbr0` fijos, sin preguntar | Pregunta cores, RAM, disco, storage, bridge y VLAN |
| 10 | `--bootdisk` (obsoleto), sin `--boot order=` | `--boot order=virtio0` |
| 11 | Sugería versiones 6.x en el prompt | Consulta la última estable en `LATEST.7` y avisa si eliges una 6.x |
| 12 | Sin `--agent` | `--agent 1` en RouterOS 7.x |

## Genérico para cualquier Proxmox

Nada está hardcodeado según el hardware del nodo donde se probó:

- **`cpu=`** — `host` si el nodo es standalone (máximo rendimiento);
  `x86-64-v2-AES` si existe `/etc/pve/corosync.conf`, para no romper la
  migración en vivo en clusters con CPU heterogénea.
- **`ssd=1`** — solo si se confirma. Resuelve el storage a sus discos físicos
  (`lvm`/`lvmthin` vía `pvs`, `dir` vía `findmnt` — incluido root-on-ZFS —,
  `zfspool` vía `zpool list`) y consulta `lsblk ROTA`. Si el storage es remoto
  (NFS, CIFS, CephFS, RBD) no se puede saber y el flag se omite, sin preguntar.
- **Storage y bridge** — se listan los realmente disponibles en el nodo.

## ⚡ Instalación rápida (one-liner)

En el nodo Proxmox, como root:

```bash
curl -fsSL https://raw.githubusercontent.com/mtandazo35/mikrotik-chr-installer/v1.0/install.sh | bash
```

Descarga el instalador a `/root/mikrotik-chr-install.sh` y lanza el asistente.
Para probar otra rama o versión: `CHR_REF=main curl -fsSL .../main/install.sh | bash`.

### Por qué hace falta un bootstrap y no se ejecuta el instalador directo

`mikrotik-chr-install.sh` es **interactivo**. En un `curl … | bash` el `stdin`
del proceso es la tubería de curl, así que cada `read` se tragaría el propio
script en vez de esperar al usuario: el asistente se saltaría solo y con
respuestas basura.

`install.sh` lo evita ejecutando el instalador con `< /dev/tty`, que reconecta
el terminal real. Comprobado: con el método ingenuo la pregunta nunca llega;
con `/dev/tty` el proceso tiene `stdin` en una tubería y aun así lee del
teclado correctamente.

Antes de ejecutar nada verifica que hay `root`, `qm` (o sea, que es un nodo
Proxmox), `curl` y un terminal interactivo; que lo descargado empieza por el
shebang esperado (y no es una página de error de GitHub por una ref
inexistente); y que pasa `bash -n`. Si no hay terminal, no se cuelga: dice cómo
hacerlo a mano.

## Uso manual

```bash
scp mikrotik-chr-install.sh root@<nodo-proxmox>:/root/
ssh root@<nodo-proxmox>
chmod +x /root/mikrotik-chr-install.sh
/root/mikrotik-chr-install.sh
```

Es interactivo. Si algo falla durante la importación del disco, la VM a medio
crear se elimina sola (`qm destroy --purge`) para no dejar basura.

## Notas

- Las imágenes descargadas quedan cacheadas en `/root/temp/chr/`.
- Usuario por defecto del CHR: `admin` sin contraseña. **Cámbiala en el primer
  acceso.**
- Evita RouterOS 6.x: fuera de soporte y con CVEs conocidas
  (p. ej. `CVE-2018-14847` en Winbox). El script avisa y pide confirmación.
- Los scripts se desarrollan en local y se suben al nodo bajo pedido; ver
  `.gitattributes` (`eol=lf`) — un CRLF hace que Linux responda
  `No such file or directory` al ejecutar el script.
