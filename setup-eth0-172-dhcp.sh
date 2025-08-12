
#!/bin/bash
set -euo pipefail

# =============================================
# DietPi: IP fixe (172.16.42.100/24) + DHCP sur eth0
# - Pose l'IP fixe via un service systemd (idempotent)
# - Lance le client DHCP via un service indépendant
# - Fonctionne au boot avec ou sans câble, et en PC↔PC
# - Supprime l'ancien service add-static-ip.service s'il existe
# =============================================

# --- Réglages ---
IFACE="eth0"
STATIC_CIDR="172.16.42.100/24"
UDEV_RULE="/etc/udev/rules.d/99-add-static-ip.rules"
SVC_TEMPLATE="/etc/systemd/system/add-static-ip@.service"
OLD_SVC="/etc/systemd/system/add-static-ip.service"
DHCP_SVC_TEMPLATE="/etc/systemd/system/dhcp-client@.service"
IFDROPIN_DIR="/etc/network/interfaces.d"
IFDROPIN_FILE="${IFDROPIN_DIR}/eth0.conf"
IF_MAIN="/etc/network/interfaces"
BACKUP_SUFFIX=".$(date +%F-%H%M%S).bak"

# --- Détection des binaires ---
IP_BIN="$(command -v ip || true)"
DHCLIENT_BIN="$(command -v dhclient || true)"

if [[ -z "${IP_BIN}" ]]; then
  echo "ERREUR: 'ip' introuvable dans le PATH." >&2
  exit 1
fi
if [[ -z "${DHCLIENT_BIN}" ]]; then
  # Fallback courants
  if [[ -x /usr/sbin/dhclient ]]; then
    DHCLIENT_BIN="/usr/sbin/dhclient"
  elif [[ -x /sbin/dhclient ]]; then
    DHCLIENT_BIN="/sbin/dhclient"
  else
    echo "ERREUR: 'dhclient' introuvable. Installe-le (isc-dhcp-client) puis relance." >&2
    exit 1
  fi
fi

echo "Utilisation de: ip=${IP_BIN} ; dhclient=${DHCLIENT_BIN}"
echo

# --- 0) Préparation répertoires ---
mkdir -p "${IFDROPIN_DIR}"

# --- 1) Nettoyage ancien service systemd (s'il existe) ---
if systemctl list-unit-files | grep -q "^add-static-ip.service"; then
  echo "[*] Désactivation de l'ancien service add-static-ip.service"
  systemctl disable --now add-static-ip.service || true
fi
if [[ -f "${OLD_SVC}" ]]; then
  echo "[*] Suppression de ${OLD_SVC}"
  rm -f "${OLD_SVC}"
fi

# --- 2) Service systemd template pour IP fixe (idempotent) ---
echo "[*] Installation du service ${SVC_TEMPLATE}"
cat > "${SVC_TEMPLATE}" <<EOF
[Unit]
Description=Ajoute IP ${STATIC_CIDR} sur %i
# Assure que le périphérique existe
Requires=sys-subsystem-net-devices-%i.device
After=sys-subsystem-net-devices-%i.device
# Démarre tôt, avant le réseau complet
After=systemd-udevd.service network-pre.target
Wants=systemd-udevd.service
DefaultDependencies=no

[Service]
Type=oneshot
# 1) Monter l'interface même sans câble
ExecStart=${IP_BIN} link set dev %i up
# 2) Poser/remplacer l'IP (idempotent)
ExecStart=${IP_BIN} addr replace ${STATIC_CIDR} dev %i
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# --- 3) Règle udev pour (re)appliquer l'IP sur évènements ---
echo "[*] Installation de la règle udev ${UDEV_RULE}"
cat > "${UDEV_RULE}" <<EOF
# Pose l'IP quand l'interface est créée
ACTION=="add", SUBSYSTEM=="net", KERNEL=="${IFACE}", ENV{SYSTEMD_WANTS}="add-static-ip@${IFACE}.service"

# Repose l'IP quand le lien devient porteur (câble branché)
ACTION=="change", SUBSYSTEM=="net", KERNEL=="${IFACE}", ATTR{carrier}=="1", ENV{SYSTEMD_WANTS}="add-static-ip@${IFACE}.service"
EOF

# --- 4) Drop-in ifupdown minimal (on laisse systemd gérer IP + DHCP) ---
echo "[*] Configuration ifupdown drop-in: ${IFDROPIN_FILE}"
if [[ -f "${IFDROPIN_FILE}" ]]; then
  cp -a "${IFDROPIN_FILE}" "${IFDROPIN_FILE}${BACKUP_SUFFIX}"
  echo "    sauvegarde: ${IFDROPIN_FILE}${BACKUP_SUFFIX}"
fi
cat > "${IFDROPIN_FILE}" <<EOF
# ${IFDROPIN_FILE} - généré par setup-eth0-172-dhcp.sh
auto ${IFACE}
allow-hotplug ${IFACE}

iface ${IFACE} inet manual
EOF

# S'assurer que le fichier principal inclut bien les drop-ins
if ! grep -qE "^\s*source\s+interfaces\.d/\*" "${IF_MAIN}"; then
  echo "[*] Ajout de 'source interfaces.d/*' dans ${IF_MAIN}"
  cp -a "${IF_MAIN}" "${IF_MAIN}${BACKUP_SUFFIX}"
  {
    echo ""
    echo "# Drop-in configs"
    echo "source interfaces.d/*"
  } >> "${IF_MAIN}"
fi

# --- 5) Service systemd template pour DHCP (indépendant d'ifup) ---
echo "[*] Installation du service ${DHCP_SVC_TEMPLATE}"
cat > "${DHCP_SVC_TEMPLATE}" <<EOF
[Unit]
Description=DHCP client sur %i
After=add-static-ip@%i.service
Wants=add-static-ip@%i.service

[Service]
ExecStart=${DHCLIENT_BIN} -4 -nw -pf /run/dhclient-%i.pid -lf /var/lib/dhcp/dhclient.%i.leases %i
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# --- 6) Reload & activation ---
echo "[*] Reload systemd & udev"
systemctl daemon-reload
udevadm control --reload

# Activer et démarrer les services (IP fixe puis DHCP)
echo "[*] Activation des services add-static-ip@${IFACE} et dhcp-client@${IFACE}"
systemctl enable add-static-ip@"${IFACE}".service
systemctl enable dhcp-client@"${IFACE}".service
systemctl restart add-static-ip@"${IFACE}".service || true
systemctl restart dhcp-client@"${IFACE}".service || true

# Déclencher udev pour rejouer la pose d'IP si besoin
echo "[*] Déclenchement udev (add/change) pour ${IFACE}"
udevadm trigger --subsystem-match=net --attr-match=name="${IFACE}" || true

# --- 7) État & diagnostics ---
echo
echo "=== ÉTAT ADRESSAGE IPv4 sur ${IFACE} ==="
${IP_BIN} -4 addr show dev "${IFACE}" || true

echo
echo "=== Statuts services ==="
systemctl --no-pager --full status add-static-ip@"${IFACE}".service || true
systemctl --no-pager --full status dhcp-client@"${IFACE}".service || true

echo
echo "=== Journaux DHCP récents ==="
if [[ -f /var/log/syslog ]]; then
  tail -n 100 /var/log/syslog | grep -Ei "dhclient|dhcp" || true
else
  journalctl -b | grep -Ei "dhclient|dhcp" || true
fi

echo
echo "Terminé ✅"
