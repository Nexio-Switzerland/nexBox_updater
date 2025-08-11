#!/usr/bin/env bash

set -euo pipefail
# Set DEBUG=1 dans l'environnement pour activer les traces [DBG]

#######################################
# CONFIG
#######################################
DOWNLOAD_URL="${DOWNLOAD_URL:-https://dl-s3cy4u5n.swisstransfer.com/api/download/9b8b27ec-00cb-4990-8ba9-8bde8d24d250/8d49e288-bb4f-44ef-9174-d2e5dc1dc2fe}"   # <- à adapter
# HTTP download tuning (UA/Referer). Set DOWNLOAD_REFERER for hosts like SwissTransfer
DOWNLOAD_UA="${DOWNLOAD_UA:-Mozilla/5.0}"
DOWNLOAD_REFERER="${DOWNLOAD_REFERER:-}"
SERVICE_NAME="${SERVICE_NAME:-nexSoft}"
TARGET_DIR="${TARGET_DIR:-/opt/nexSoft}"
TIMESHIFT_SCRIPT="${TIMESHIFT_SCRIPT:-/opt/scripts/TimeShift_FactorySettings.sh}"
STATE_DIR="${STATE_DIR:-/var/lib/nex}"
MAC_FILE="$STATE_DIR/previous_mac"
SERVICE_START_TIMEOUT="${SERVICE_START_TIMEOUT:-20}"

WEBMIN_HTTP_TIMEOUT="${WEBMIN_HTTP_TIMEOUT:-5}"

# Certs (NexSoft)
NEXSOFT_CERT_DIR="${NEXSOFT_CERT_DIR:-/opt/nexSoft/cert}"
CERT_GROUP="${CERT_GROUP:-nexroot}"

# RS232 Loopback test (flags & env)
SERIAL_DEV="${SERIAL_DEV:-/dev/ttyUSB0}"
SERIAL_BAUD="${SERIAL_BAUD:-115200}"
SERIAL_TIMEOUT_SEC="${SERIAL_TIMEOUT_SEC:-5}"
LOOPBACK_BYTES="${LOOPBACK_BYTES:-64}"
ENABLE_RS232_TEST="${ENABLE_RS232_TEST:-1}"   # 1=on (default), 0=off
# RS232 modem-lines (RTS/CTS, DTR/DSR/DCD/RI) test toggle
ENABLE_RS232_MODEM="${ENABLE_RS232_MODEM:-0}"   # 0=off (default), 1=on

# Product IDs
PRODUCT_FILE="/etc/dietpi/.product_id"
UDEV_RULE="/etc/udev/rules.d/99-nexSoft-id.rules"
SERIAL_NUMBER_ENV="${SERIAL_NUMBER:-}"   # optionnel: injecter via env
OVERWRITE_IDS="${OVERWRITE_IDS:-0}"      # 1 pour écraser sans poser de question

# Mode sans mise à jour (skip download/unzip/copy)

# Désactiver Timeshift final
NO_TIMESHIFT="${NO_TIMESHIFT:-0}"   # 1 = ne pas lancer le snapshot Timeshift final
NO_UPDATE="${NO_UPDATE:-0}"   # 1 = ne pas faire l'étape update

#######################################
# CLI FLAGS
#######################################
usage() {
  cat <<EOF
Usage: sudo $(basename "$0") [options]

Options:
  --enable-rs232-test           Activer le test RS232 (par défaut si non spécifié)
  --disable-rs232-test          Désactiver le test RS232
  --baud=<N>                    Vitesse série (par défaut: ${SERIAL_BAUD})
  --serial-baud=<N>             Alias de --baud
  --serial-dev=<PATH>           Périphérique série (défaut: ${SERIAL_DEV})
  --serial-number=<VAL>         Numéro de série produit (sinon demandé à l'opérateur)
  --sn=<VAL>                   Alias de --serial-number
  --overwrite-ids               Écraser DEVICE_ID / SERIAL_NUMBER existants dans ${PRODUCT_FILE} sans confirmation
  --no-update                   Ne fait PAS le téléchargement/décompression/copie (QC seulement)
  --no-timeshift                Désactive le snapshot Timeshift final
  --non-interactive            Ne pose aucune question (utilise valeur existante ou SN-UNSET)
  -h, --help                    Afficher cette aide

Variables d'environnement utiles :
  DOWNLOAD_URL, DOWNLOAD_UA, DOWNLOAD_REFERER, SERVICE_NAME, TARGET_DIR, TIMESHIFT_SCRIPT
  SERIAL_DEV, SERIAL_BAUD, ENABLE_RS232_TEST
  SERIAL_NUMBER, OVERWRITE_IDS, NO_UPDATE, NO_TIMESHIFT

EOF
}

for arg in "$@"; do
  case "$arg" in
    --enable-rs232-test) ENABLE_RS232_TEST=1 ;;
    --disable-rs232-test) ENABLE_RS232_TEST=0 ;;
    --baud=*|--serial-baud=*) SERIAL_BAUD="${arg#*=}" ;;
    --serial-dev=*) SERIAL_DEV="${arg#*=}" ;;
    --serial-number=*) SERIAL_NUMBER_ENV="${arg#*=}" ;;
    --sn=*) SERIAL_NUMBER_ENV="${arg#*=}" ;;
    --non-interactive) INTERACTIVE_FORCE=0 ;;
    --overwrite-ids) OVERWRITE_IDS=1 ;;
    --no-update) NO_UPDATE=1 ;;
    --no-timeshift) NO_TIMESHIFT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Arg inconnu: $arg"; usage; exit 1 ;;
  esac
done

#######################################
# UI / HELPERS
#######################################
RED="\033[1;31m"; GRN="\033[1;32m"; YLW="\033[1;33m"; BLU="\033[1;34m"; RST="\033[0m"
OK="✅"; KO="❌"; WRN="⚠️"
STEP=0; FAILS=0
declare -a RECAP

banner(){ echo -e "${BLU}=== nexSoft Update & QC ===${RST}"; }
say(){ echo -e "$*"; }
mark_ok(){ say "   ${GRN}${OK} ${1}${RST}"; RECAP+=("${OK} ${1}"); }
mark_warn(){ say "   ${YLW}${WRN} ${1}${RST}"; RECAP+=("${WRN} ${1}"); }
mark_ko(){ say "   ${RED}${KO} ${1}${RST}"; RECAP+=("${KO} ${1}"); FAILS=$((FAILS+1)); }
step(){ STEP=$((STEP+1)); say ""; say "${BLU}[${STEP}]${RST} $*"; }

need_bin(){ command -v "$1" >/dev/null 2>&1 || { mark_ko "Dépendance manquante: $1"; exit 1; }; }

mac_to_serial(){ local mac=${1//:/}; printf "%015d" "$((16#${mac^^}))"; }

format_blocks_5(){ local s="$1"; echo "${s:0:5}-${s:5:5}-${s:10:5}"; }


timestamp(){ date +"%Y%m%d-%H%M%S"; }

# Debug helpers
DEBUG="${DEBUG:-0}"
dbg(){ if [[ "$DEBUG" -eq 1 ]]; then echo -e "   [DBG] $*"; fi }

# Detect service user and fix cert permissions
get_service_user(){
  local _u
  _u=$(systemctl show -p User --value "$SERVICE_NAME" 2>/dev/null | tr -d '\n')
  if [[ -z "$_u" || "$_u" == "n/a" ]]; then
    # Try to read from unit file
    local frag
    frag=$(systemctl show -p FragmentPath --value "$SERVICE_NAME" 2>/dev/null | tr -d '\n')
    if [[ -n "$frag" && -r "$frag" ]]; then
      _u=$(grep -E '^User=' "$frag" 2>/dev/null | tail -n1 | cut -d= -f2)
    fi
  fi
  echo "${_u:-root}"
}

fix_nexsoft_cert_perms(){
  local svc_user="$1"
  [[ -d "$NEXSOFT_CERT_DIR" ]] || return 0
  # Create group if missing
  if ! getent group "$CERT_GROUP" >/dev/null 2>&1; then
    groupadd "$CERT_GROUP" >/dev/null 2>&1 || true
  fi
  # Add service user to group (if not root)
  if [[ -n "$svc_user" && "$svc_user" != "root" ]]; then
    id -nG "$svc_user" 2>/dev/null | grep -qw "$CERT_GROUP" || usermod -aG "$CERT_GROUP" "$svc_user" 2>/dev/null || true
  fi
  # Ownership: root:group ; perms: dir 750, files 640
  chown -R root:"$CERT_GROUP" "$NEXSOFT_CERT_DIR" 2>/dev/null || true
  find "$NEXSOFT_CERT_DIR" -type d -exec chmod 750 {} + 2>/dev/null || true
  find "$NEXSOFT_CERT_DIR" -type f -exec chmod 640 {} + 2>/dev/null || true
}

#######################################
# PRECHECKS
#######################################
banner
if [[ $EUID -ne 0 ]]; then
  say -e "${RED}${KO} Ce script doit être exécuté en root.${RST}"; exit 1
fi

for b in unzip rsync systemctl journalctl ip findmnt blockdev df lsblk; do need_bin "$b"; done
if [[ "$NO_UPDATE" -eq 0 ]]; then
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    say -e "${RED}${KO} Il faut curl ou wget pour télécharger.${RST}"; exit 1
  fi
fi
mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"

if [[ ! -d "$TARGET_DIR" ]]; then
  say -e "${RED}${KO} Répertoire cible introuvable: $TARGET_DIR${RST}"; exit 1
fi

# Détection mode interactif (peut être forcé via --non-interactive)
INTERACTIVE=1
if [[ ! -t 0 || ! -t 1 || ! -r /dev/tty ]]; then
  INTERACTIVE=0
fi
# Si flag forcé présent
INTERACTIVE_FORCE=${INTERACTIVE_FORCE:-1}
if [[ "$INTERACTIVE_FORCE" -eq 0 ]]; then
  INTERACTIVE=0
fi
if [[ "$INTERACTIVE" -eq 0 ]]; then
  say "   ${YLW}${WRN} Mode non interactif: aucune saisie ne sera demandée${RST}"
fi
dbg "INTERACTIVE=$INTERACTIVE FORCE=${INTERACTIVE_FORCE:-1} tty0=$([[ -t 0 ]] && echo 1 || echo 0) tty1=$([[ -t 1 ]] && echo 1 || echo 0) /dev/tty=$([[ -r /dev/tty ]] && echo R || echo -)"

WORKDIR="$(mktemp -d /tmp/nexSoft_update.XXXXXX)"
ZIP_PATH="$WORKDIR/package.zip"
EXTRACT_DIR="$WORKDIR/extracted"
mkdir -p "$EXTRACT_DIR"
cleanup(){ rm -rf "$WORKDIR"; }
trap cleanup EXIT

SERVICE_NEEDS_START=0
WAS_ACTIVE_RS232=0

#######################################
# 1→5) Update (optionnel si --no-update)
#######################################
if [[ "$NO_UPDATE" -eq 0 ]]; then

  #######################################
  # 1) Download ZIP
  #######################################
  step "Téléchargement du paquet"
  # Auto-derive referer for SwissTransfer direct links if not provided
  if [[ -z "$DOWNLOAD_REFERER" && "$DOWNLOAD_URL" =~ swisstransfer\.com/.*/download/([^/]+)/ ]]; then
    SWX_ID="${BASH_REMATCH[1]}"
    DOWNLOAD_REFERER="https://www.swisstransfer.com/d/${SWX_ID}"
    dbg "Referer dérivé pour SwissTransfer: $DOWNLOAD_REFERER"
  fi
  if command -v curl >/dev/null 2>&1; then
    if curl -fL --retry 3 \
         -A "$DOWNLOAD_UA" \
         ${DOWNLOAD_REFERER:+-e "$DOWNLOAD_REFERER"} \
         -o "$ZIP_PATH" \
         "$DOWNLOAD_URL"; then
      mark_ok "Téléchargé depuis $DOWNLOAD_URL"
    else
      mark_ko "Échec téléchargement (curl)"; exit 1
    fi
  else
    # wget fallback with UA and referer
    if wget -q --tries=3 --retry-connrefused \
            --user-agent="$DOWNLOAD_UA" \
            ${DOWNLOAD_REFERER:+--referer="$DOWNLOAD_REFERER"} \
            -O "$ZIP_PATH" \
            "$DOWNLOAD_URL"; then
      mark_ok "Téléchargé depuis $DOWNLOAD_URL"
    else
      mark_ko "Échec téléchargement (wget)"; exit 1
    fi
  fi

  #######################################
  # 2) Test + unzip
  #######################################
  step "Validation & décompression"
  if unzip -tq "$ZIP_PATH" >/dev/null; then
    mark_ok "Archive valide"
  else
    mark_ko "Archive corrompue"; exit 1
  fi
  if unzip -q "$ZIP_PATH" -d "$EXTRACT_DIR"; then
    mark_ok "Décompressé vers $EXTRACT_DIR"
    # Nettoyage des artefacts MacOS et sélection du répertoire /update
    rm -rf "$EXTRACT_DIR/__MACOSX" 2>/dev/null || true
    UPDATE_ROOT="$EXTRACT_DIR/update"
    if [[ ! -d "$UPDATE_ROOT" ]]; then
      mark_ko "Dossier 'update' manquant dans l'archive (attendu: update/opt, update/usr, ...)"; exit 1
    fi
    mark_ok "Dossier racine d'update détecté: $UPDATE_ROOT"
  else
    mark_ko "Échec décompression"; exit 1
  fi

  #######################################
  # 3) Backup /opt/nexSoft
  #######################################
  step "Backup de $TARGET_DIR"
  BKP_ROOT="/opt/backups"; mkdir -p "$BKP_ROOT"
  BKP_PATH="$BKP_ROOT/nexSoft-$(timestamp).tar.gz"
  if tar -C / -czf "$BKP_PATH" "${TARGET_DIR#/}" 2>/dev/null; then
    mark_ok "Backup OK → $BKP_PATH"
  else
    mark_ko "Backup échoué"; exit 1
  fi

  #######################################
  # 4) Stop service
  #######################################
  step "Arrêt du service ${SERVICE_NAME}"
  if systemctl stop "$SERVICE_NAME"; then
    mark_ok "Service arrêté"
    SERVICE_NEEDS_START=1
  else
    mark_ko "Impossible d'arrêter le service"; exit 1
  fi

  #######################################
  # 5) Copie auto (toutes racines du ZIP), merge non destructif
  #######################################
  step "Copie automatique des contenus du ZIP (merge, sans suppression)"

  # 5.0 Sécurité: refuser chemins absolus et '..' dans l'archive
  BAD=0
  while IFS= read -r p; do
    # Ignorer les artefacts MacOS
    [[ "$p" == __MACOSX/* ]] && continue
    case "$p" in
      /*|*..*) BAD=1; echo "   ❌ Chemin suspect dans l'archive: $p" ;;
    esac
  done < <(unzip -Z1 "$ZIP_PATH" 2>/dev/null || true)
  if (( BAD==1 )); then
    mark_ko "Archive refusée: chemins suspects (.. ou absolus)."
    exit 1
  fi
  mark_ok "Validation chemins: OK"

  # 5.1 Racines détectées (ex: opt, usr, etc) → copie vers /<racine>
  mapfile -t ROOTS < <(find "$UPDATE_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name "__MACOSX" -printf '%P\n' | sort)
  if (( ${#ROOTS[@]} == 0 )); then
    mark_warn "Aucune racine détectée dans l'archive"
  fi

  copy_merge_dir() {
    local src="$1" dst="$2"
    mkdir -p "$dst"

    # PASS 1: créer uniquement les NOUVEAUX fichiers/dossiers
    # - ignore-existing => ne touche pas aux fichiers déjà présents
    # - chown=nexroot:nexroot => owner/groupe pour les nouveaux
    # - no-owner/no-group/no-perms => ne pousse pas les méta du ZIP
    if rsync -rltD --info=progress2 \
             --ignore-existing \
             --chown=nexroot:nexroot \
             --no-owner --no-group --no-perms \
             "$src"/ "$dst"/; then
      :
    else
      mark_ko "Échec copie (nouveaux) vers $dst"; exit 1
    fi

    # PASS 2: mettre à jour UNIQUEMENT les fichiers existants (sans changer droits/owner/groupe)
    if rsync -rltD --info=progress2 \
             --existing \
             --no-owner --no-group --no-perms \
             "$src"/ "$dst"/; then
      mark_ok "Copie → $dst (merge, sans suppression; droits existants préservés; nouveaux en nexroot:nexroot)"
    else
      mark_ko "Échec copie (existants) vers $dst"; exit 1
    fi
  }

  for r in "${ROOTS[@]}"; do
    copy_merge_dir "$UPDATE_ROOT/$r" "/$r"
  done

  # 5.2 Rendre exécutables les scripts *.sh livrés (usr/local/bin, opt/scripts, etc.)
  while IFS= read -r -d '' f; do
    target="/${f#"$UPDATE_ROOT/"}"
    if [[ -f "$target" ]]; then
      chmod 755 "$target" || true
      echo "   ✅ Exécutable → $target"
    fi
  done < <(find "$UPDATE_ROOT" -type f -name "*.sh" -print0)

  # 5.3 Hooks systemd si des unités sont livrées
  SYSTEMD_DIR="$UPDATE_ROOT/etc/systemd/system"
  if [[ -d "$SYSTEMD_DIR" ]]; then
    systemctl daemon-reload || true
    shopt -s nullglob
    for uf in "$SYSTEMD_DIR"/*.service "$SYSTEMD_DIR"/*.timer; do
      unit="$(basename "$uf")"
      systemctl enable --now "$unit" 2>/dev/null || true
      echo "   ✅ systemd (ré)activé → $unit"
    done
    shopt -u nullglob
    mark_ok "systemd rechargé"
  fi

else
  step "Mode --no-update : on saute téléchargement / décompression / backup / copie"
  mark_ok "Aucune mise à jour de fichiers effectuée"
fi

#######################################
# 5bis) Vérification ${SERIAL_DEV} présent et libre
#######################################
step "Vérification ${SERIAL_DEV} présent et libre"
if [[ -c "$SERIAL_DEV" ]]; then
  mark_ok "${SERIAL_DEV} présent"
  BUSY_PIDS=""
  if command -v fuser >/dev/null 2>&1; then
    if fuser -s "$SERIAL_DEV"; then BUSY_PIDS="$(fuser -v "$SERIAL_DEV" 2>/dev/null | awk 'NR>1{print $2}' | paste -sd, -)"; fi
  elif command -v lsof >/dev/null 2>&1; then
    BUSY_PIDS="$(lsof -t "$SERIAL_DEV" 2>/dev/null | paste -sd, -)"
  fi
  if [[ -n "$BUSY_PIDS" ]]; then
    mark_warn "${SERIAL_DEV} occupé par PID(s): ${BUSY_PIDS}"
  else
    mark_ok "${SERIAL_DEV} libre"
  fi
else
  mark_ko "${SERIAL_DEV} absent — test RS232 sera ignoré"
fi

#######################################
# 6) Test loopback RS232 (si activé)
#######################################
step "Test loopback RS232 (${SERIAL_DEV})"
if [[ "$ENABLE_RS232_TEST" -eq 1 ]]; then
  set +e
  # En --no-update, arrêter temporairement le service s'il tourne (pour libérer le port)
  if [[ "$NO_UPDATE" -eq 1 ]]; then
    if systemctl is-active --quiet "$SERVICE_NAME"; then
      WAS_ACTIVE_RS232=1
      if systemctl stop "$SERVICE_NAME"; then
        mark_ok "Service ${SERVICE_NAME} arrêté temporairement pour test RS232"
        SERVICE_NEEDS_START=1
      else
        mark_warn "Impossible d'arrêter ${SERVICE_NAME} pour le test RS232"
      fi
    fi
  fi

  # Re-vérifier présence et occupation
  if [[ ! -c "$SERIAL_DEV" ]]; then
    mark_warn "${SERIAL_DEV} introuvable — test RS232 ignoré"
    set -e
  else
    BUSY_PIDS=""
    if command -v fuser >/dev/null 2>&1; then
      if fuser -s "$SERIAL_DEV"; then BUSY_PIDS="$(fuser -v "$SERIAL_DEV" 2>/dev/null | awk 'NR>1{print $2}' | paste -sd, -)"; fi
    elif command -v lsof >/dev/null 2>&1; then
      BUSY_PIDS="$(lsof -t "$SERIAL_DEV" 2>/dev/null | paste -sd, -)"
    fi
    if [[ -n "$BUSY_PIDS" ]]; then
      mark_warn "${SERIAL_DEV} occupé (PID: ${BUSY_PIDS}) — test RS232 ignoré"
      set -e
    else
      STTY_ORIG="$(stty -F "$SERIAL_DEV" -g 2>/dev/null || echo "")"
      if stty -F "$SERIAL_DEV" "$SERIAL_BAUD" cs8 -cstopb -parenb -ixon -ixoff -crtscts -echo -icanon -isig -iexten raw; then
        mark_ok "Port configuré: ${SERIAL_BAUD} 8N1, pas de flow control"
      else
        mark_warn "Impossible de configurer ${SERIAL_DEV}"
      fi

      TX_FILE="$WORKDIR/tx.bin"
      RX_FILE="$WORKDIR/rx.bin"
      PAYLOAD="$(head -c 32 /dev/urandom | base64 | tr -d '\n' | head -c ${LOOPBACK_BYTES})"
      printf "%s" "$PAYLOAD" > "$TX_FILE"

      timeout "$SERIAL_TIMEOUT_SEC" cat "$SERIAL_DEV" > "$RX_FILE" &
      READER_PID=$!
      sleep 0.3
      cat "$TX_FILE" > "$SERIAL_DEV" || true
      wait "$READER_PID" 2>/dev/null || true

      if [[ -s "$RX_FILE" ]]; then
        RX_PAYLOAD="$(tr -d '\r\n' < "$RX_FILE" 2>/dev/null || cat "$RX_FILE")"
        if [[ "$RX_PAYLOAD" == "$PAYLOAD" ]]; then
          mark_ok "TX/RX loopback: OK"
        else
          mark_warn "TX/RX reçu différent (len=$(wc -c < "$RX_FILE"))"
        fi
      else
        mark_warn "Aucune donnée reçue (vérifie pontage broches 2↔3)"
      fi

      if [[ "$ENABLE_RS232_MODEM" -eq 1 ]]; then
        SERIAL_DEV="$SERIAL_DEV" python3 - << 'PYEOF'
import os, fcntl, time, sys
dev = os.environ.get("SERIAL_DEV", "/dev/ttyUSB0")
fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
TIOCMGET=0x5415; TIOCMBIS=0x5416; TIOCMBIC=0x5417
TIOCM_DTR=0x002; TIOCM_RTS=0x004; TIOCM_CTS=0x020; TIOCM_DSR=0x100; TIOCM_CD=0x040; TIOCM_RI=0x080
def get_bits():
    b = fcntl.ioctl(fd, TIOCMGET, b'\x00\x00\x00\x00'); v = int.from_bytes(b[:4],'little')
    return {'CTS':bool(v&TIOCM_CTS),'DSR':bool(v&TIOCM_DSR),'DCD':bool(v&TIOCM_CD),'RI':bool(v&TIOCM_RI),'RTS':bool(v&TIOCM_RTS),'DTR':bool(v&TIOCM_DTR)}, v
def set_bit(mask,on):
    fcntl.ioctl(fd, TIOCMBIS if on else TIOCMBIC, mask.to_bytes(4,'little'))
def flip(from_mask,to_key):
    before,_=get_bits(); set_bit(from_mask,True); time.sleep(0.1); after,_=get_bits(); set_bit(from_mask,False); return before[to_key]!=after[to_key]
ok=True
if not flip(TIOCM_RTS,'CTS'): ok=False; print("NOK RTS->CTS")
else: print("OK RTS->CTS")
if not flip(TIOCM_DTR,'DSR'): ok=False; print("NOK DTR->DSR")
else: print("OK DTR->DSR")
if not flip(TIOCM_DTR,'DCD'): ok=False; print("NOK DTR->DCD")
else: print("OK DTR->DCD")
if not flip(TIOCM_DTR,'RI'):  ok=False; print("NOK DTR->RI")
else: print("OK DTR->RI")
os.close(fd)
sys.exit(0 if ok else 2)
PYEOF
        PYRET=$?
        if [[ "$PYRET" -eq 0 ]]; then
          mark_ok "Modem lines (RTS/CTS, DTR/DSR/DCD/RI): OK"
        else
          mark_warn "Modem lines: transitions non détectées (vérifie le pontage 7↔8, 4↔6, 1↔4↔6, 9↔4)"
        fi
      else
        mark_warn "Test modem-lines RS232 désactivé (seul TX/RX est testé)"
      fi

      if [[ -n "${STTY_ORIG}" ]]; then stty -F "$SERIAL_DEV" "$STTY_ORIG" 2>/dev/null || true; fi
      pkill -f "cat $SERIAL_DEV" 2>/dev/null || true
      mark_ok "Port ${SERIAL_DEV} restauré et libéré"
      set -e
    fi  # fin test port libre
  fi
else
  mark_warn "Test RS232 désactivé (--disable-rs232-test)"
fi




#######################################
# 8) /dev/ttyUSB0 présent
#######################################
step "Vérification /dev/ttyUSB0"
if [[ -c /dev/ttyUSB0 ]]; then
  mark_ok "/dev/ttyUSB0 présent"
else
  mark_warn "/dev/ttyUSB0 manquant"
fi

#######################################
# 9) IP 172.16.42.100 sur eth0
#######################################
step "Vérification IP fixe 172.16.42.100 sur eth0"
if ip -4 addr show dev eth0 | grep -qE '172\.16\.42\.100/'; then
  mark_ok "IP 172.16.42.100 présente"
else
  mark_warn "IP 172.16.42.100 absente"
fi

#######################################
# 10) Hostname = nexBox-<serial(mac)>
#######################################
step "Vérification / mise à jour hostname basé sur MAC"
if [[ -r /sys/class/net/eth0/address ]]; then
  CURRENT_MAC="$(cat /sys/class/net/eth0/address)"
  SERIAL="$(mac_to_serial "$CURRENT_MAC")"
  EXPECTED_HOST="nexBox-$SERIAL"
  CURRENT_HOST="$(hostname)"
  if [[ "$CURRENT_HOST" != "$EXPECTED_HOST" ]]; then
    echo "$EXPECTED_HOST" > /etc/hostname
    hostname "$EXPECTED_HOST"
    if grep -qE '^127\.0\.1\.1' /etc/hosts; then
      sed -i "s/^127\.0\.1\.1\s\+.*/127.0.1.1 $EXPECTED_HOST/" /etc/hosts
    else
      echo "127.0.1.1 $EXPECTED_HOST" >> /etc/hosts
    fi
    mark_ok "Hostname mis à jour → $EXPECTED_HOST"
  else
    mark_ok "Hostname déjà correct → $CURRENT_HOST"
  fi
  echo "$CURRENT_MAC" > "$MAC_FILE"
else
  mark_warn "Impossible de lire l'adresse MAC d'eth0"
fi

#######################################
# 11) Webmin
#######################################
step "Vérification Webmin (test explicite HTTPS)"
# Méthodes de détection: systemd, script init, process miniserv, test HTTP
WEBMIN_DETECTED=0
WEBMIN_ACTIVE=0

# 1) systemd unit
if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^webmin\.service'; then
  WEBMIN_DETECTED=1
  if systemctl is-active --quiet webmin; then WEBMIN_ACTIVE=1; fi
fi

# 2) init script (Debian/older)
if [[ $WEBMIN_DETECTED -eq 0 && -x /etc/init.d/webmin ]]; then
  WEBMIN_DETECTED=1
  /etc/init.d/webmin status >/dev/null 2>&1 && WEBMIN_ACTIVE=1
fi

# 3) process miniserv.pl
if [[ $WEBMIN_DETECTED -eq 0 ]]; then
  if pgrep -f miniserv\.pl >/dev/null 2>&1; then
    WEBMIN_DETECTED=1; WEBMIN_ACTIVE=1
  fi
fi

# 4) test HTTP si curl dispo
if command -v curl >/dev/null 2>&1; then
  code=$(curl -k -m "$WEBMIN_HTTP_TIMEOUT" -o /dev/null -s -w "%{http_code}" https://127.0.0.1:10000/ || echo "000")
  case "$code" in
    200|301|302|401|403)
      mark_ok "Webmin HTTPS répond (HTTP $code)";
      WEBMIN_ACTIVE=1; WEBMIN_DETECTED=1 ;;
    000)
      mark_warn "Webmin HTTP injoignable (port 10000 fermé?)" ;;
    *)
      mark_warn "Webmin HTTP inattendu ($code)" ;;
  esac
else
  mark_warn "curl absent — test HTTP non effectué"
fi

if [[ $WEBMIN_DETECTED -eq 0 ]]; then
  mark_warn "Webmin non détecté (ni service, ni process, ni HTTP)"
elif [[ $WEBMIN_ACTIVE -eq 0 ]]; then
  mark_warn "Webmin détecté mais semble inactif"
fi

# Debug separator at end of section 11
dbg "--- FIN WEBMIN ---"

#######################################
# 12) Vérif partition & FS étendus à tout le disque
#######################################
step "Vérification que la partition root et le filesystem occupent tout le disque"
ROOT_DEV="$(findmnt -no SOURCE /)"
if [[ "$ROOT_DEV" == "/dev/root" ]]; then
  ROOT_DEV="$(awk '$2=="/"{print $1}' /proc/mounts)"
fi
if [[ -b "$ROOT_DEV" ]]; then
  PART_SIZE=$(blockdev --getsize64 "$ROOT_DEV" 2>/dev/null || echo 0)
  FS_SIZE=$(df -B1 --output=size / | tail -1 | tr -d ' ')
  PKNAME=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | tr -d ' ')
  DISK_DEV="/dev/${PKNAME:-}"
  if [[ -b "$DISK_DEV" ]]; then
    DISK_SIZE=$(blockdev --getsize64 "$DISK_DEV" 2>/dev/null || echo 0)
  else
    DISK_SIZE=0
  fi
  # Seuil dynamique: max(50MiB, 2% de la taille de partition)
  BASE_MARGIN=$((50*1024*1024))
  PCT_MARGIN=$(( PART_SIZE / 50 ))  # ~2%
  MARGIN=$BASE_MARGIN
  if (( PCT_MARGIN > MARGIN )); then MARGIN=$PCT_MARGIN; fi
  msg="root=$ROOT_DEV part_size=$PART_SIZE fs_size=$FS_SIZE disk=$DISK_DEV disk_size=$DISK_SIZE margin=$MARGIN"
  if (( DISK_SIZE>0 )) && (( DISK_SIZE - PART_SIZE > MARGIN )); then
    mark_warn "Partition root n'occupe pas tout le disque (${msg})"
  else
    mark_ok "Partition root occupe ~tout le disque (${msg})"
  fi
  if (( PART_SIZE - FS_SIZE > MARGIN )); then
    mark_warn "Filesystem n'utilise pas toute la partition (écart <= seuil si message unique)"
  else
    mark_ok "Filesystem utilise ~toute la partition"
  fi
else
  mark_warn "Impossible de déterminer le périphérique root (source=$ROOT_DEV)"
fi

#######################################
# 13) Enregistrement SERIAL_NUMBER et DEVICE_ID
#######################################
step "Enregistrement des identifiants produit (SERIAL_NUMBER / DEVICE_ID)"
mkdir -p "$(dirname "$PRODUCT_FILE")"
touch "$PRODUCT_FILE"
chmod 644 "$PRODUCT_FILE"
set +e

# Saisie interactive du SERIAL_NUMBER (toujours demandé si console dispo, sinon fallback)
dbg "PRODUCT_FILE=$PRODUCT_FILE"
CURRENT_MAC="$(cat /sys/class/net/eth0/address 2>/dev/null || echo "00:00:00:00:00:00")"
MAC_DEC="$(mac_to_serial "$CURRENT_MAC")"
DEVICE_ID_FMT="$(format_blocks_5 "$MAC_DEC")"

EXIST_SN="$(grep -E '^SERIAL_NUMBER=' "$PRODUCT_FILE" 2>/dev/null | sed 's/^SERIAL_NUMBER=//')"
EXIST_DID="$(grep -E '^DEVICE_ID=' "$PRODUCT_FILE" 2>/dev/null | sed 's/^DEVICE_ID=//')"

# 1) Si fourni via CLI/env, on l'utilise directement (et on n'affiche pas d'invite)
if [[ -n "$SERIAL_NUMBER_ENV" ]]; then
  SERIAL_NUMBER_VAL="$SERIAL_NUMBER_ENV"
else
  # 2) Si une console est disponible, on DEMANDE à l'opérateur
  if [[ -t 0 && -t 1 && -r /dev/tty ]]; then
    say "   Saisie du numéro de série produit"
    echo "   >>> PROMPT SERIAL_NUMBER (interactive)" 1>&2
    if [[ -n "$EXIST_SN" && "$OVERWRITE_IDS" -eq 0 ]]; then
      say "   Valeur actuelle détectée: $EXIST_SN"
    fi
    while true; do
      # Entrée vide → conserver existant si présent, sinon SN-UNSET
      if [[ -n "$EXIST_SN" && "$OVERWRITE_IDS" -eq 0 ]]; then
        PROMPT_TEXT="   Saisir SERIAL_NUMBER [Entrée = conserver: $EXIST_SN] : "
      else
        PROMPT_TEXT="   Saisir SERIAL_NUMBER [Entrée = SN-UNSET] : "
      fi

      # Essai 1: /dev/tty avec timeout
      if [[ -r /dev/tty ]]; then
        printf "%s" "$PROMPT_TEXT" > /dev/tty 2>/dev/null || true
        if read -t 30 -r SERIAL_NUMBER_VAL </dev/tty; then
          dbg "Lecture SERIAL_NUMBER via /dev/tty: '${SERIAL_NUMBER_VAL}'"
          echo "   → SERIAL_NUMBER retenu: ${SERIAL_NUMBER_VAL}" 1>&2
        else
          mark_warn "Aucune saisie via /dev/tty (timeout/erreur)"
          SERIAL_NUMBER_VAL=""
          echo "   → SERIAL_NUMBER retenu: ${SERIAL_NUMBER_VAL}" 1>&2
        fi
      fi

      if [[ -z "${SERIAL_NUMBER_VAL}" ]]; then
        if [[ -n "$EXIST_SN" && "$OVERWRITE_IDS" -eq 0 ]]; then
          SERIAL_NUMBER_VAL="$EXIST_SN"
          dbg "SERIAL_NUMBER_VAL retenu='${SERIAL_NUMBER_VAL}' (interactive: défaut existant)"
          echo "   → SERIAL_NUMBER retenu: ${SERIAL_NUMBER_VAL}" 1>&2
          break
        else
          SERIAL_NUMBER_VAL="SN-UNSET"
          dbg "SERIAL_NUMBER_VAL retenu='${SERIAL_NUMBER_VAL}' (interactive: défaut unset)"
          echo "   → SERIAL_NUMBER retenu: ${SERIAL_NUMBER_VAL}" 1>&2
          break
        fi
      else
        dbg "SERIAL_NUMBER_VAL retenu='${SERIAL_NUMBER_VAL}' (interactive: saisi)"
        echo "   → SERIAL_NUMBER retenu: ${SERIAL_NUMBER_VAL}" 1>&2
        break
      fi
    done
  else
    # 3) Non interactif: fallback
    echo "   >>> PROMPT SERIAL_NUMBER (non-interactif)" 1>&2
    if [[ -n "$EXIST_SN" && "$OVERWRITE_IDS" -eq 0 ]]; then
      SERIAL_NUMBER_VAL="$EXIST_SN"
      mark_ok "SERIAL_NUMBER conservé (non interactif) → $EXIST_SN"
      dbg "SERIAL_NUMBER_VAL retenu='${SERIAL_NUMBER_VAL}' (non-interactive)"
      echo "   → SERIAL_NUMBER retenu: ${SERIAL_NUMBER_VAL}" 1>&2
    else
      SERIAL_NUMBER_VAL="SN-UNSET"
      mark_warn "Mode non interactif: SERIAL_NUMBER non fourni → 'SN-UNSET'"
      dbg "SERIAL_NUMBER_VAL retenu='${SERIAL_NUMBER_VAL}' (non-interactive)"
      echo "   → SERIAL_NUMBER retenu: ${SERIAL_NUMBER_VAL}" 1>&2
    fi
  fi
fi

DEVICE_ID_VAL="$DEVICE_ID_FMT"

sed -i '/^SERIAL_NUMBER=/d' "$PRODUCT_FILE"
sed -i '/^DEVICE_ID=/d' "$PRODUCT_FILE"
echo "SERIAL_NUMBER=${SERIAL_NUMBER_VAL}" >> "$PRODUCT_FILE"
echo "DEVICE_ID=${DEVICE_ID_VAL}" >> "$PRODUCT_FILE"
set -e

mark_ok "SERIAL_NUMBER=$(grep -E '^SERIAL_NUMBER=' "$PRODUCT_FILE" | cut -d= -f2-)"
mark_ok "DEVICE_ID=$(grep -E '^DEVICE_ID=' "$PRODUCT_FILE" | cut -d= -f2-)"
say "   Fichier ${PRODUCT_FILE} mis à jour avec SERIAL_NUMBER et DEVICE_ID"
dbg "IDs écrits → SERIAL_NUMBER='$(grep -E '^SERIAL_NUMBER=' "$PRODUCT_FILE" | cut -d= -f2-)' DEVICE_ID='$(grep -E '^DEVICE_ID=' "$PRODUCT_FILE" | cut -d= -f2-)'"

cat > "$UDEV_RULE" <<RULE
ACTION=="add", SUBSYSTEM=="block", KERNEL=="mmcblk0", ENV{NEXSOFT_SERIAL}="${SERIAL_NUMBER_VAL}", ENV{NEXSOFT_DEVICE_ID}="${DEVICE_ID_VAL}"
RULE
udevadm control --reload-rules >/dev/null 2>&1 || true
udevadm trigger -s block >/dev/null 2>&1 || true
mark_ok "Udev rule mise à jour: $UDEV_RULE"


#######################################
# 14) Renouvellement SSL forcé (Webmin & NexSoft)
#######################################
step "Renouvellement SSL forcé (Webmin & NexSoft)"

RENEW_BIN="/usr/local/bin/renew-webmin-cert.sh"
if [[ -x "$RENEW_BIN" ]]; then
  if "$RENEW_BIN" --force; then
    mark_ok "Renouvellement SSL forcé exécuté avec succès"
  else
    mark_warn "renew-webmin-cert.sh a retourné une erreur (voir logs au-dessus)"
  fi
else
  mark_warn "Script de renouvellement SSL introuvable ou non exécutable: $RENEW_BIN"
fi

# Ajuster les permissions des certs pour le service NexSoft
svc_user="$(get_service_user)"
dbg "Service user détecté: '${svc_user}'"
if [[ -d "$NEXSOFT_CERT_DIR" ]]; then
  fix_nexsoft_cert_perms "$svc_user"
  if [[ $? -eq 0 ]]; then
    mark_ok "Permissions des certificats ajustées pour l'utilisateur '${svc_user}'"
  else
    mark_warn "Impossible d'ajuster les permissions des certificats"
  fi
else
  mark_warn "Répertoire de certificats NexSoft introuvable: $NEXSOFT_CERT_DIR"
fi


#######################################
# 14bis) Redémarrage du service + health logs (avant Timeshift)
#######################################
if [[ "$SERVICE_NEEDS_START" -eq 1 ]]; then
  step "Démarrage du service ${SERVICE_NAME}"
  if systemctl start "$SERVICE_NAME"; then
    mark_ok "Start demandé"
  else
    mark_ko "Échec démarrage"; exit 1
  fi
else
  step "Service ${SERVICE_NAME} : pas de redémarrage nécessaire"
  if systemctl is-active --quiet "$SERVICE_NAME"; then
    mark_ok "Service déjà actif"
  else
    mark_warn "Service non actif (non redémarré par ce script)"
  fi
fi

OK_ACTIVE=0
for i in $(seq 1 "$SERVICE_START_TIMEOUT"); do
  if systemctl is-active --quiet "$SERVICE_NAME"; then OK_ACTIVE=1; break; fi
  sleep 1
done
if (( OK_ACTIVE==1 )); then
  mark_ok "Service actif"
else
  mark_warn "Service non actif après ${SERVICE_START_TIMEOUT}s"
fi

step "Scan des logs récents (${SERVICE_NAME})"
if journalctl -u "$SERVICE_NAME" -n 300 --no-pager | grep -Ei "error|exception|traceback|critical|fail" >/dev/null; then
  mark_warn "Avertissements/erreurs potentiels trouvés (voir ci-dessous)"
  journalctl -u "$SERVICE_NAME" -n 60 --no-pager | tail -n 60 | sed 's/^/     /'
else
  mark_ok "Pas d'erreurs évidentes dans les 300 dernières lignes"
fi

#######################################
# 15) Timeshift snapshot (final)
#######################################
step "Snapshot Timeshift final (script: $TIMESHIFT_SCRIPT)"

if [[ "$NO_TIMESHIFT" -eq 1 ]]; then
  mark_warn "Timeshift désactivé par --no-timeshift"
else
  if [[ -x "$TIMESHIFT_SCRIPT" ]]; then
    if bash "$TIMESHIFT_SCRIPT"; then
      # Vérifier qu’un snapshot récent existe (≤10 min)
      sleep 2
      NOW=$(date +%s); FOUND=0
      while IFS= read -r -d '' sd; do
        while IFS= read -r -d '' s; do
          mt=$(stat -c %Y "$s" 2>/dev/null || echo 0)
          if (( NOW - mt < 600 )); then FOUND=1; say "     Snapshot récent: $s"; fi
        done < <(find "$sd" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
      done < <(find /timeshift -maxdepth 2 -type d -name 'snapshots*' -print0 2>/dev/null || true)
      if (( FOUND==1 )); then
        mark_ok "Snapshot Timeshift confirmé"
      else
        mark_warn "Snapshot récent non détecté (≤10min). Vérifie la config Timeshift."
      fi
    else
      mark_warn "Le script Timeshift a retourné une erreur"
    fi
  else
    mark_warn "Script Timeshift introuvable/non exécutable: $TIMESHIFT_SCRIPT"
  fi
fi

#######################################
# 16) Normalisation des propriétaires /opt/nexSoft
#######################################
step "Normalisation des propriétaires sur $TARGET_DIR (nexroot:nexroot)"
if chown -R nexroot:nexroot "$TARGET_DIR" 2>/dev/null; then
  mark_ok "Propriétaire et groupe appliqués récursivement sur $TARGET_DIR"
else
  mark_warn "Échec du chown récursif sur $TARGET_DIR (vérifier droits/disponibilité)"
fi

#######################################
# RÉCAP
#######################################
say ""; say "${BLU}=== RÉCAP ===${RST}"
for line in "${RECAP[@]}"; do
  [[ "$line" == ${OK}* ]]   && echo -e " ${GRN}${line}${RST}" && continue
  [[ "$line" == ${WRN}* ]]  && echo -e " ${YLW}${line}${RST}" && continue
  [[ "$line" == ${KO}* ]]   && echo -e " ${RED}${line}${RST}" && continue
  echo " $line"
done
say -e "${BLU}Backup:${RST} ${BKP_PATH:-"(aucun - --no-update)"}"
if (( FAILS>0 )); then
  say -e "${RED}${KO} Terminé avec ${FAILS} échec(s).${RST}"
  exit 1
else
  say -e "${GRN}${OK} Terminé avec succès.${RST}"
  exit 0
fi
