#!/usr/bin/env bash
#
# install.sh — bootstrap de una linea para mikrotik-chr-installer
#
#   curl -fsSL https://raw.githubusercontent.com/mtandazo35/mikrotik-chr-installer/v1.2/install.sh | bash
#
# Por que existe este bootstrap y no se ejecuta el instalador directo:
# mikrotik-chr-install.sh es INTERACTIVO (pregunta version, VMID, storage,
# bridge...). En un "curl | bash" el stdin del proceso es la tuberia de curl,
# asi que cada 'read' se tragaria el propio script en vez de esperar al
# usuario. Por eso aqui se descarga a disco y se ejecuta reconectando el
# terminal con < /dev/tty.
#
# El instalador queda en /root (no /tmp): sobrevive reinicios y se puede
# reejecutar sin volver a descargarlo.

set -Eeuo pipefail

REPO="mtandazo35/mikrotik-chr-installer"
REF="${CHR_REF:-v1.2}"          # se puede fijar otra version: CHR_REF=main
DEST="/root/mikrotik-chr-install.sh"
URL="https://raw.githubusercontent.com/${REPO}/${REF}/mikrotik-chr-install.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'
YELLOW=$'\033[1;33m'; NC=$'\033[0m'
die() { echo -e "\n  ${RED}ERROR:${NC} $*\n" >&2; exit 1; }
info(){ echo -e "  ${CYAN}i${NC}  $*"; }
warn(){ echo -e "  ${YELLOW}!${NC}  $*"; }
ok()  { echo -e "  ${GREEN}OK${NC} $*"; }

[ "$(id -u)" -eq 0 ] || die "Ejecutar como root."
command -v qm   >/dev/null 2>&1 || die "No se encontro 'qm'. Esto corre en un nodo Proxmox VE."
command -v curl >/dev/null 2>&1 || die "Hace falta curl."

# --- Version de Proxmox -----------------------------------------------------
# Se comprueba ANTES de descargar nada, para fallar rapido y con un mensaje
# claro en vez de reventar a mitad del asistente.
# Minimo 6.4: es cuando 'qm create --tags' empieza a existir.
PVE_VER="$(pveversion 2>/dev/null | sed -n 's|^pve-manager/\([0-9][0-9.]*\).*|\1|p')"
[ -n "$PVE_VER" ] || die "No se pudo determinar la version de Proxmox VE ('pveversion' no dio salida reconocible)."

PVE_MAJ="${PVE_VER%%.*}"
PVE_MIN="$(printf '%s' "$PVE_VER" | cut -d. -f2)"
[ -n "$PVE_MIN" ] || PVE_MIN=0

if [ "$PVE_MAJ" -lt 6 ] || { [ "$PVE_MAJ" -eq 6 ] && [ "$PVE_MIN" -lt 4 ]; }; then
    die "Proxmox VE ${PVE_VER} es demasiado antiguo. Hace falta 6.4 o superior (por 'qm create --tags')."
fi

info "Proxmox VE ${PVE_VER} (kernel $(uname -r))"
# 'if' y no '[ ] && ...': con 'set -e' un test falso en la ultima posicion
# aborta el script, que es justo lo que pasaria en PVE 8 y 9.
if [ "$PVE_MAJ" -lt 8 ]; then
    warn "PVE ${PVE_VER} esta fuera de soporte upstream; el instalador se adapta pero no esta probado ahi."
fi

# Sin terminal no tiene sentido seguir: el instalador es interactivo y se
# quedaria colgado o leyendo basura.
if ! { [ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null; }; then
    die "Sin terminal interactivo. Descargalo y ejecutalo a mano:
    curl -fsSL ${URL} -o ${DEST} && bash ${DEST}"
fi

info "Descargando instalador (${REF})..."
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL --max-time 60 "$URL" -o "$TMP" || die "No se pudo descargar ${URL}"

# Verificacion minima: que sea el script y no una pagina de error de GitHub.
head -1 "$TMP" | grep -q '^#!/usr/bin/env bash' || die "Lo descargado no es el instalador (¿ref '${REF}' inexistente?)."
bash -n "$TMP" || die "El script descargado no pasa el analisis sintactico."

install -m 0755 "$TMP" "$DEST"
ok "Instalador en ${DEST}"

# El terminal se reconecta explicitamente: sin esto, el 'read' del instalador
# leeria de la tuberia de curl y el asistente se saltaria solo.
exec bash "$DEST" < /dev/tty
