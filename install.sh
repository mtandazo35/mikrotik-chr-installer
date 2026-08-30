#!/usr/bin/env bash
#
# install.sh — bootstrap de una linea para mikrotik-chr-installer
#
#   curl -fsSL https://raw.githubusercontent.com/mtandazo35/mikrotik-chr-installer/v1.0/install.sh | bash
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
REF="${CHR_REF:-v1.0}"          # se puede fijar otra version: CHR_REF=main
DEST="/root/mikrotik-chr-install.sh"
URL="https://raw.githubusercontent.com/${REPO}/${REF}/mikrotik-chr-install.sh"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
die() { echo -e "\n  ${RED}ERROR:${NC} $*\n" >&2; exit 1; }
info(){ echo -e "  ${CYAN}i${NC}  $*"; }
ok()  { echo -e "  ${GREEN}OK${NC} $*"; }

[ "$(id -u)" -eq 0 ] || die "Ejecutar como root."
command -v qm   >/dev/null 2>&1 || die "No se encontro 'qm'. Esto corre en un nodo Proxmox VE."
command -v curl >/dev/null 2>&1 || die "Hace falta curl."

# Sin terminal no tiene sentido seguir: el instalador es interactivo y se
# quedaria colgado o leyendo basura.
[ -e /dev/tty ] && (: < /dev/tty) 2>/dev/null \
    || die "Sin terminal interactivo. Descargalo y ejecutalo a mano:
    curl -fsSL ${URL} -o ${DEST} && bash ${DEST}"

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
