#!/usr/bin/env bash
#
# mikrotik-chr-install.sh — Despliegue de MikroTik CHR en Proxmox VE
#
# Reemplaza a mikrotikinstall.sh, que colgaba el disco de virtio-scsi:
# RouterOS 6.x no trae ese driver y el kernel moria con
#   "ERROR: could not find disk! Please attach it somewhere else."
# Aqui el disco va SIEMPRE en virtio-blk (virtio0), reconocido por
# RouterOS 6.x y 7.x por igual.
#
# Generico: no asume tipo de storage, ni hardware, ni bridge.
#
# Version: 1.2
#

set -uo pipefail

VERSION_SCRIPT="1.2"

# ---------------------------------------------------------------- salida ----
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'

info()  { echo -e "  ${CYAN}i${NC}  $*"; }
ok()    { echo -e "  ${GREEN}OK${NC} $*"; }
warn()  { echo -e "  ${YELLOW}!${NC}  $*"; }
die()   { echo -e "\n  ${RED}ERROR:${NC} $*\n" >&2; exit 1; }
title() { echo -e "\n${BOLD}$*${NC}"; }

# --------------------------------------------------------------- globals ----
TMPDIR_IMG="/root/temp/chr"
CPU_TYPE="host"
STORAGE_MEDIO=""
CHR_VERSION=""
VMID=""
VM_NAME=""
VM_CORES=1
VM_MEMORY=1024
VM_DISK="1G"
STORAGE=""
BRIDGE=""
VLAN_TAG=""
IMG_FILE=""
PVE_VERSION=""
PVE_MAJOR=0
PVE_MINOR=0
QM_IMPORT=""
QM_RESIZE=""

# ------------------------------------------------------------ pre-vuelo ----
preflight() {
    [ "$(id -u)" -eq 0 ] || die "Este script debe ejecutarse como root."
    command -v qm >/dev/null 2>&1 || die "No se encontro 'qm'. Este script corre en un nodo Proxmox VE."

    local faltan=()
    command -v unzip >/dev/null 2>&1 || faltan+=("unzip")
    command -v wget  >/dev/null 2>&1 || faltan+=("wget")

    if [ ${#faltan[@]} -gt 0 ]; then
        info "Instalando dependencias: ${faltan[*]}"
        apt-get update -qq || die "apt-get update fallo."
        apt-get install -y "${faltan[@]}" >/dev/null || die "No se pudieron instalar: ${faltan[*]}"
    fi
    ok "Dependencias listas."
}

# --------------------------------------------- version de Proxmox VE ----
# Distintas versiones de PVE cambian los nombres de subcomando de qm y los
# modelos de CPU disponibles. Aqui se detecta la version y, sobre todo, se
# comprueba por CAPACIDAD que subcomandos existen realmente: es mas fiable
# que deducirlo de un numero de version.
#
#   qm disk import   (PVE 7+)   <- nombre actual
#   qm importdisk    (PVE 6.x)  <- nombre antiguo, sigue como alias en 7/8/9
#
# Minimo real: 6.4, que es cuando 'qm create --tags' empieza a existir.
PVE_MIN_MAJOR=6
PVE_MIN_MINOR=4

detect_pve_version() {
    title "0) Comprobando Proxmox VE"

    PVE_VERSION=$(pveversion 2>/dev/null | sed -n 's|^pve-manager/\([0-9][0-9.]*\)/.*|\1|p')
    [ -n "$PVE_VERSION" ] || PVE_VERSION=$(pveversion 2>/dev/null | sed -n 's|^pve-manager/\([0-9][0-9.]*\).*|\1|p')
    [ -n "$PVE_VERSION" ] || die "No se pudo determinar la version de Proxmox VE ('pveversion' no dio salida reconocible)."

    PVE_MAJOR=${PVE_VERSION%%.*}
    PVE_MINOR=$(printf '%s' "$PVE_VERSION" | cut -d. -f2)
    [ -n "$PVE_MINOR" ] || PVE_MINOR=0

    info "Proxmox VE detectado: ${BOLD}${PVE_VERSION}${NC}  (kernel $(uname -r))"

    # Demasiado viejo: ni siquiera soporta las opciones que usa 'qm create'.
    if [ "$PVE_MAJOR" -lt "$PVE_MIN_MAJOR" ] ||
       { [ "$PVE_MAJOR" -eq "$PVE_MIN_MAJOR" ] && [ "$PVE_MINOR" -lt "$PVE_MIN_MINOR" ]; }; then
        die "Proxmox VE ${PVE_VERSION} es demasiado antiguo. Hace falta ${PVE_MIN_MAJOR}.${PVE_MIN_MINOR} o superior (por 'qm create --tags')."
    fi

    # Soportado pero fuera de soporte upstream: se avisa, no se bloquea.
    if [ "$PVE_MAJOR" -lt 8 ]; then
        warn "PVE ${PVE_VERSION} esta fuera de soporte de Proxmox. El script deberia funcionar, pero no esta probado ahi."
    fi

    # --- subcomandos, por capacidad y no por numero de version ---
    if qm help disk import >/dev/null 2>&1; then
        QM_IMPORT="disk import"
    elif qm help importdisk >/dev/null 2>&1; then
        QM_IMPORT="importdisk"
    else
        die "Este PVE no expone ni 'qm disk import' ni 'qm importdisk'."
    fi

    if qm help disk resize >/dev/null 2>&1; then
        QM_RESIZE="disk resize"
    elif qm help resize >/dev/null 2>&1; then
        QM_RESIZE="resize"
    else
        die "Este PVE no expone ni 'qm disk resize' ni 'qm resize'."
    fi

    ok "Subcomandos: 'qm ${QM_IMPORT}' y 'qm ${QM_RESIZE}'."
}

# ------------------------------------------------- deteccion de hardware ----
# cpu=host da maximo rendimiento pero rompe la migracion en vivo entre nodos
# con CPU distinta. En cluster se usa un modelo portable.
detect_cpu_type() {
    if [ -f /etc/pve/corosync.conf ]; then
        # x86-64-v2-AES aparece con QEMU 6.1, o sea PVE 7.1. En nodos mas
        # viejos ese modelo no existe y 'qm create' fallaria; kvm64 es el
        # portable de toda la vida.
        if [ "$PVE_MAJOR" -gt 7 ] || { [ "$PVE_MAJOR" -eq 7 ] && [ "$PVE_MINOR" -ge 1 ]; }; then
            CPU_TYPE="x86-64-v2-AES"
        else
            CPU_TYPE="kvm64"
            warn "PVE ${PVE_VERSION} no tiene x86-64-v2-AES -> se usa kvm64."
        fi
        info "Nodo en cluster -> cpu=${CPU_TYPE} (portable, permite migracion en vivo)"
    else
        CPU_TYPE="host"
        info "Nodo standalone -> cpu=${CPU_TYPE} (maximo rendimiento)"
    fi
}

# Imprime el bloque de /etc/pve/storage.cfg de un storage dado, con el tipo
# como primera linea ("TYPE dir", "TYPE zfspool", ...).
_storage_section() {
    awk -v s="$1" '
        /^[a-z]+:[[:space:]]*[^[:space:]]+/ {
            t = $1; sub(/:$/, "", t)
            insec = ($2 == s)
            if (insec) print "TYPE " t
            next
        }
        insec && NF { print }
    ' /etc/pve/storage.cfg 2>/dev/null
}

# Resuelve un storage de Proxmox a sus discos fisicos y decide si es SSD.
# Devuelve 0 y escribe "0" (no rotacional) o "1" (rotacional); 1 si no se sabe.
detect_storage_rotational() {
    local sto="$1" sec tipo pool vg path devs="" d rota

    sec=$(_storage_section "$sto")
    tipo=$(echo "$sec" | awk '$1=="TYPE" {print $2; exit}')
    [ -n "$tipo" ] || return 1

    case "$tipo" in
        lvm|lvmthin)
            vg=$(echo "$sec" | awk '$1=="vgname" {print $2; exit}')
            [ -n "$vg" ] || return 1
            devs=$(pvs --noheadings -o pv_name -S "vg_name=${vg}" 2>/dev/null)
            ;;
        dir)
            path=$(echo "$sec" | awk '$1=="path" {print $2; exit}')
            [ -n "$path" ] || path="/var/lib/vz"
            local src fstype
            src=$(findmnt -no SOURCE --target "$path" 2>/dev/null)
            fstype=$(findmnt -no FSTYPE --target "$path" 2>/dev/null)
            if [ "$fstype" = "zfs" ]; then
                # un dir sobre ZFS (root-on-ZFS) no da un /dev: hay que ir al pool
                devs=$(zpool list -vHP "${src%%/*}" 2>/dev/null | awk '$1 ~ /^\/dev\// {print $1}')
            else
                devs="$src"
            fi
            ;;
        zfspool)
            pool=$(echo "$sec" | awk '$1=="pool" {print $2; exit}')
            [ -n "$pool" ] || return 1
            devs=$(zpool list -vHP "${pool%%/*}" 2>/dev/null | awk '$1 ~ /^\/dev\// {print $1}')
            ;;
        *)
            # nfs, cifs, cephfs, rbd, pbs... el disco fisico no es local: no se asume nada
            return 1
            ;;
    esac

    [ -n "$devs" ] || return 1

    local visto=1
    for d in $devs; do
        d=$(lsblk -ndo PKNAME "$d" 2>/dev/null || true)
        [ -n "$d" ] || continue
        rota=$(lsblk -ndo ROTA "/dev/$d" 2>/dev/null | tr -d ' ')
        [ -n "$rota" ] || continue
        visto=0
        [ "$rota" = "1" ] && { echo "1"; return 0; }
    done

    [ "$visto" -eq 0 ] || return 1
    echo "0"
}

# ------------------------------------------------------------- preguntas ----
ask_version() {
    title "1) Version de CHR"

    local latest=""
    latest=$(wget -qO- --timeout=10 https://download.mikrotik.com/routeros/LATEST.7 2>/dev/null | awk '{print $1}')

    if [ -n "$latest" ]; then
        info "Ultima estable publicada por MikroTik: ${BOLD}${latest}${NC}"
    else
        warn "No se pudo consultar la ultima version (sin internet?). Indicala a mano."
    fi
    echo -e "  ${YELLOW}Nota:${NC} se recomienda 7.x. Las 6.x estan fuera de soporte y arrastran CVEs conocidas."

    while true; do
        read -rp "  Version de CHR a desplegar [${latest:-7.x.y}]: " CHR_VERSION
        CHR_VERSION="${CHR_VERSION:-$latest}"
        [ -n "$CHR_VERSION" ] || { warn "Debes indicar una version."; continue; }
        if [[ "$CHR_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
            break
        fi
        warn "Formato invalido. Ejemplos: 7.16.2, 6.49.13"
    done

    if [ "${CHR_VERSION%%.*}" -lt 7 ] 2>/dev/null; then
        warn "RouterOS ${CHR_VERSION} es una version antigua y sin soporte."
        read -rp "  Continuar de todas formas? [s/N]: " r
        [[ "${r,,}" == "s" ]] || die "Cancelado por el usuario."
    fi
}

download_image() {
    title "2) Imagen"
    mkdir -p "$TMPDIR_IMG" || die "No se pudo crear $TMPDIR_IMG"

    IMG_FILE="${TMPDIR_IMG}/chr-${CHR_VERSION}.img"
    local zip="${TMPDIR_IMG}/chr-${CHR_VERSION}.img.zip"
    local url="https://download.mikrotik.com/routeros/${CHR_VERSION}/chr-${CHR_VERSION}.img.zip"

    if [ -s "$IMG_FILE" ]; then
        ok "Imagen ya descargada: $IMG_FILE"
        return
    fi

    info "Descargando ${url}"
    # --content-on-error evita guardar paginas de error como si fueran la imagen
    if ! wget -q --show-progress --timeout=30 --tries=3 -O "$zip" "$url"; then
        rm -f "$zip"
        die "No se pudo descargar CHR ${CHR_VERSION}. Verifica que la version exista en download.mikrotik.com."
    fi

    # Un HTML de error tambien se descarga con exito: hay que validar el contenido
    if ! unzip -tq "$zip" >/dev/null 2>&1; then
        rm -f "$zip"
        die "El archivo descargado no es un ZIP valido (la version ${CHR_VERSION} probablemente no existe)."
    fi

    unzip -oq "$zip" -d "$TMPDIR_IMG" || die "Fallo al descomprimir $zip"
    rm -f "$zip"

    [ -s "$IMG_FILE" ] || die "El ZIP no contenia chr-${CHR_VERSION}.img"
    ok "Imagen lista: $IMG_FILE ($(du -h "$IMG_FILE" | cut -f1))"
}

ask_vmid() {
    title "3) VM ID"
    local sugerido
    sugerido=$(pvesh get /cluster/nextid 2>/dev/null || echo "")

    echo
    qm list | head -30
    echo

    while true; do
        read -rp "  VM ID libre a usar${sugerido:+ [$sugerido]}: " VMID
        VMID="${VMID:-$sugerido}"

        if ! [[ "$VMID" =~ ^[0-9]+$ ]] || [ "$VMID" -lt 100 ]; then
            warn "El VM ID debe ser un numero >= 100."
            continue
        fi
        # Comprobacion real a nivel cluster, no solo si existe un directorio
        if pvesh get /cluster/resources --type vm --output-format json 2>/dev/null | grep -q "\"vmid\":${VMID},"; then
            warn "El VM ID ${VMID} ya esta en uso en el cluster."
            continue
        fi
        if [ -e "/etc/pve/qemu-server/${VMID}.conf" ] || [ -e "/etc/pve/lxc/${VMID}.conf" ]; then
            warn "Ya existe una configuracion para el ID ${VMID}."
            continue
        fi
        break
    done
    ok "Se usara el VM ID ${VMID}"
}

ask_basics() {
    title "4) Datos de la VM"

    read -rp "  Nombre de la VM [chr-${CHR_VERSION}]: " VM_NAME
    VM_NAME="${VM_NAME:-chr-${CHR_VERSION}}"
    VM_NAME="${VM_NAME// /-}"

    while true; do
        read -rp "  Cores [1]: " VM_CORES
        VM_CORES="${VM_CORES:-1}"
        [[ "$VM_CORES" =~ ^[0-9]+$ ]] && [ "$VM_CORES" -ge 1 ] && break
        warn "Valor invalido."
    done

    while true; do
        read -rp "  Memoria RAM en MB [1024]: " VM_MEMORY
        VM_MEMORY="${VM_MEMORY:-1024}"
        [[ "$VM_MEMORY" =~ ^[0-9]+$ ]] && [ "$VM_MEMORY" -ge 256 ] && break
        warn "Valor invalido (minimo 256)."
    done

    while true; do
        read -rp "  Tamano de disco [1G]: " VM_DISK
        VM_DISK="${VM_DISK:-1G}"
        [[ "$VM_DISK" =~ ^[0-9]+[MG]$ ]] && break
        warn "Formato invalido. Ejemplos: 1G, 2G, 512M"
    done
}

ask_storage() {
    title "5) Storage"
    local candidatos
    candidatos=$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}')
    [ -n "$candidatos" ] || die "No hay storages activos que soporten imagenes de disco."

    echo
    pvesm status --content images | awk 'NR==1 || $3=="active"'
    echo

    local defecto
    defecto=$(echo "$candidatos" | head -1)

    while true; do
        read -rp "  Storage para el disco [${defecto}]: " STORAGE
        STORAGE="${STORAGE:-$defecto}"
        if echo "$candidatos" | grep -qx "$STORAGE"; then
            break
        fi
        warn "Storage no valido. Opciones: $(echo "$candidatos" | tr '\n' ' ')"
    done

    # NO se pone ssd=1: Proxmox solo acepta esa propiedad en ide/sata/scsi.
    # En virtio-blk el API la rechaza con
    #   "virtio0.ssd: property is not defined in schema"
    # y como este instalador usa virtio0 a proposito (RouterOS 6.x no tiene
    # driver de virtio-scsi), el flag no es aplicable NUNCA. Se deja solo el
    # dato informativo. No reintroducir el flag.
    local rota
    if rota=$(detect_storage_rotational "$STORAGE"); then
        if [ "$rota" = "0" ]; then
            STORAGE_MEDIO="SSD/NVMe"
        else
            STORAGE_MEDIO="disco rotacional"
        fi
    else
        STORAGE_MEDIO="medio desconocido (storage remoto?)"
    fi
    info "Storage '${STORAGE}' -> ${STORAGE_MEDIO}. (virtio-blk no admite ssd=1; no se aplica)"
}

ask_network() {
    title "6) Red"
    local bridges defecto
    bridges=$(ls /sys/class/net 2>/dev/null | grep -E '^vmbr[0-9]+$' | sort -V)
    [ -n "$bridges" ] || die "No se encontro ningun bridge vmbrX en este nodo."

    info "Bridges disponibles: $(echo "$bridges" | tr '\n' ' ')"
    defecto=$(echo "$bridges" | head -1)

    while true; do
        read -rp "  Bridge [${defecto}]: " BRIDGE
        BRIDGE="${BRIDGE:-$defecto}"
        echo "$bridges" | grep -qx "$BRIDGE" && break
        warn "Bridge no valido."
    done

    while true; do
        read -rp "  VLAN tag (vacio = sin VLAN): " tag
        if [ -z "$tag" ]; then
            VLAN_TAG=""
            break
        fi
        if [[ "$tag" =~ ^[0-9]+$ ]] && [ "$tag" -ge 1 ] && [ "$tag" -le 4094 ]; then
            VLAN_TAG=",tag=${tag}"
            break
        fi
        warn "VLAN invalida (1-4094)."
    done
}

# ------------------------------------------------------------- despliegue ----
confirm() {
    title "Resumen"
    cat <<EOF
    VM ID .......... ${VMID}
    Nombre ......... ${VM_NAME}
    CHR ............ ${CHR_VERSION}
    Cores / RAM .... ${VM_CORES} / ${VM_MEMORY} MB
    Disco .......... ${VM_DISK} en ${STORAGE} (virtio0, ${STORAGE_MEDIO})
    Red ............ ${BRIDGE}${VLAN_TAG}
    CPU ............ ${CPU_TYPE}
EOF
    echo
    read -rp "  Crear la VM con estos datos? [S/n]: " r
    [[ -z "$r" || "${r,,}" == "s" ]] || die "Cancelado por el usuario."
}

create_vm() {
    title "7) Creando la VM"

    local agent_opt=()
    if [ "${CHR_VERSION%%.*}" -ge 7 ] 2>/dev/null; then
        agent_opt=(--agent 1)
        info "RouterOS 7.x -> se habilita qemu-guest-agent"
    fi

    qm create "$VMID" \
        --name "$VM_NAME" \
        --ostype l26 \
        --machine q35 \
        --cpu "$CPU_TYPE" \
        --sockets 1 \
        --cores "$VM_CORES" \
        --memory "$VM_MEMORY" \
        --balloon 0 \
        --onboot 1 \
        --tags "routeros;chr" \
        --description "MikroTik CHR ${CHR_VERSION}" \
        --net0 "virtio,bridge=${BRIDGE}${VLAN_TAG}" \
        "${agent_opt[@]}" \
        || die "Fallo 'qm create'."

    ok "VM ${VMID} creada."
}

import_disk() {
    title "8) Importando el disco"

    # 'qm disk import' elige el formato correcto para cada tipo de storage
    # (qcow2 en dir, raw en lvm/zfs). Nada de mkdir en /var/lib/vz.
    if ! qm $QM_IMPORT "$VMID" "$IMG_FILE" "$STORAGE" >/tmp/chr-import-$VMID.log 2>&1; then
        cat /tmp/chr-import-$VMID.log >&2
        qm destroy "$VMID" --purge >/dev/null 2>&1
        die "Fallo la importacion del disco. Se elimino la VM ${VMID}."
    fi

    local vol
    vol=$(qm config "$VMID" | awk -F': ' '/^unused[0-9]+:/ {print $2; exit}')
    [ -n "$vol" ] || { qm destroy "$VMID" --purge >/dev/null 2>&1; die "No se encontro el disco importado."; }
    ok "Disco importado: ${vol}"

    # ---- EL FIX ----
    # virtio0 = virtio-blk. RouterOS 6.x NO tiene driver de virtio-scsi:
    # el bootloader arranca por BIOS pero el kernel no ve el disco y muere con
    # "ERROR: could not find disk!". virtio-blk funciona en 6.x y en 7.x.
    if ! qm set "$VMID" --virtio0 "${vol},discard=on" >/dev/null 2>/tmp/chr-attach-$VMID.log; then
        cat /tmp/chr-attach-$VMID.log >&2
        qm destroy "$VMID" --purge >/dev/null 2>&1
        die "No se pudo conectar el disco a virtio0. Se elimino la VM ${VMID}."
    fi
    ok "Disco conectado a virtio0 (virtio-blk)."

    qm set "$VMID" --boot order=virtio0 >/dev/null \
        || die "No se pudo fijar el orden de arranque."
    ok "Orden de arranque: virtio0."

    if ! qm $QM_RESIZE "$VMID" virtio0 "$VM_DISK" >/dev/null 2>&1; then
        warn "No se pudo redimensionar el disco a ${VM_DISK} (queda en el tamano original de la imagen)."
    else
        ok "Disco redimensionado a ${VM_DISK}."
    fi
}

start_vm() {
    title "9) Arranque"
    read -rp "  Arrancar la VM ${VMID} ahora? [S/n]: " r
    if [[ -n "$r" && "${r,,}" != "s" ]]; then
        info "VM creada pero no arrancada. Usa: qm start ${VMID}"
        return
    fi

    qm start "$VMID" || die "Fallo 'qm start'."
    ok "VM ${VMID} arrancada."

    echo
    info "Consola:            qm terminal ${VMID}  (o la consola noVNC del webUI)"
    info "Usuario por defecto: admin  (sin contrasena)"
    info "El CHR toma IP por DHCP en ether1 si hay servidor en ${BRIDGE}${VLAN_TAG}."
    echo
    warn "Cambia la contrasena de admin en el primer acceso."
}

# ------------------------------------------------------------------ main ----
main() {
    echo -e "${BOLD}"
    echo "==========================================================="
    echo "  Instalador MikroTik CHR para Proxmox VE   v${VERSION_SCRIPT}"
    echo "==========================================================="
    echo -e "${NC}"

    preflight
    detect_pve_version
    detect_cpu_type
    ask_version
    download_image
    ask_vmid
    ask_basics
    ask_storage
    ask_network
    confirm
    create_vm
    import_disk
    start_vm

    title "Listo"
    qm config "$VMID"
    echo
}

main "$@"
