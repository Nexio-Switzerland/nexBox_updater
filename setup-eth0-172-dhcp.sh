#!/usr/bin/env bash
set -euo pipefail

# --- Réglages ---
IFACE="eth0"
STATIC_CIDR="172.16.42.100/24"
UDEV_RULE="/etc/udev/rules.d/99-add-static-ip.rules"
SVC_TEMPLATE="/etc/systemd/system/add-static-ip@.service"
OLD_SVC="/etc/systemd/system/add-static-ip.service"
IFDROPIN_DIR="/etc/network/interfaces.d"
IFDROPIN_FILE="$IFDROPIN_DIR/eth0.conf"
BACKUP_SUFFIX=".$(date +%F-%H%M%S).bak"

# --- Détection des binaires ---
IP_BIN="$(command -v ip || true)"
DHCLIENT_BIN="$(command -v dhclient || true)"

if [[ -z "${IP_BIN}" ]]; then
  echo "ERREUR: 'ip' introuvable dans le PATH." >&2
  exit 1
fi
if [[ -z "${DHCLIENT_BIN}" ]]; then
  # fallback Debian courant
  if [[ -x /usr/sbin/dhclient ]]; then
    DHCLIENT_BIN="/usr/sbin/dhclient"
  elif [[ -x /sbin/dhclient ]]; then
    DHCLIENT_BIN="/sbin/dhclient"
  else
    echo "ERREUR: 'dhclient' introuvable. Installe-le (isc-dhcp-client) puis relance." >&2
    exit 1
  fi
fi

echo "Utilisation de: ip=$IP_BIN ; dhclient=$DHCLIENT_BIN"
echo

# --- 1) Nettoyage ancien service systemd (s'il existe) ---
if systemctl list-unit-files | grep -q "^add-static-ip.service"; then
  echo "[*] Désactivation de l'ancien service add-static-ip.service"
  systemctl disable --now add-static-ip.service || true
fi
if [[ -f "$OLD_SVC" ]]; then
  echo "[*] Suppression de $OLD_SVC"
  rm -f "$OLD_SVC"
fi

# --- 2) Service systemd template déclenché par udev ---
echo "[*] Installation du service $SVC_TEMPLATE"
cat > "$SVC_TEMPLATE" <<EOF
[Unit]
Description=Ajoute IP $STATIC_CIDR sur %i (déclenché par udev)
After=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=$IP_BIN addr replace $STATIC_CIDR dev %i
EOF

# --- 3) Règle udev pour réappliquer l'IP sur add/change ---
echo "[*] Installation de la règle udev $UDEV_RULE"
cat > "$UDEV_RULE" <<EOF
# À chaque ajout/changement de l'interface $IFACE, (re)poser l'IP fixe
ACTION=="add|change", SUBSYSTEM=="net", KERNEL=="$IFACE", ENV{SYSTEMD_WANTS}="add-static-ip@$IFACE.service"
EOF

# --- 4) Drop-in ifupdown: statique + DHCP en plus ---
echo "[*] Configuration ifupdown drop-in: $IFDROPIN_FILE"
mkdir -p "$IFDROPIN_DIR"

if [[ -f "$IFDROPIN_FILE" ]]; then
  cp -a "$IFDROPIN_FILE" "$IFDROPIN_FILE$BACKUP_SUFFIX"
  echo "    sauvegarde: $IFDROPIN_FILE$BACKUP_SUFFIX"
fi

cat > "$IFDROPIN_FILE" <<EOF
# $IFDROPIN_FILE - généré par setup-eth0-172-dhcp.sh
auto $IFACE
allow-hotplug $IFACE

iface $IFACE inet static
    address $STATIC_CIDR

    # Forcer l'interface UP même sans câble
    pre-up $IP_BIN link set dev $IFACE up

    # Lancer le DHCP en arrière-plan pour ajouter une IP dynamique si dispo
    post-up $DHCLIENT_BIN -4 -nw -pf /run/dhclient-$IFACE.pid -lf /var/lib/dhcp/dhclient.$IFACE.leases $IFACE || true

    # Au ifdown: libérer/arrêter proprement le client DHCP
    pre-down $DHCLIENT_BIN -r -pf /run/dhclient-$IFACE.pid $IFACE 2>/dev/null || true
EOF

# S'assurer que le fichier principal inclut bien les drop-ins
IF_MAIN="/etc/network/interfaces"
if ! grep -qE "^\s*source\s+interfaces\.d/\*" "$IF_MAIN"; then
  echo "[*] Ajout de 'source interfaces.d/*' dans $IF_MAIN"
  cp -a "$IF_MAIN" "$IF_MAIN$BACKUP_SUFFIX"
  {
    echo ""
    echo "# Drop-in configs"
    echo "source interfaces.d/*"
  } >> "$IF_MAIN"
fi

# --- 5) Reloads & triggers ---
echo "[*] Reload systemd & udev"
systemctl daemon-reload
udevadm control --reload

echo "[*] Déclenchement udev (add/change) pour $IFACE"
udevadm trigger --subsystem-match=net --attr-match=name="$IFACE" || true

# --- 6) Restart propre de l'interface ---
echo "[*] Redémarrage de l'interface $IFACE"
ifdown "$IFACE" 2>/dev/null || true
ifup -v "$IFACE"

# --- 7) Affichage de l'état ---
echo
echo "=== ÉTAT ADRESSAGE IPv4 sur $IFACE ==="
ip -4 addr show dev "$IFACE" || true

echo
echo "=== Derniers logs du service add-static-ip@$IFACE ==="
journalctl -u "add-static-ip@$IFACE.service" -b --no-pager || true

echo
echo "=== DHCP (si serveur dispo) ==="
tail -n 50 /var/log/syslog | grep -E "dhclient|DHCP" || true

echo
echo "Terminé ✅"
