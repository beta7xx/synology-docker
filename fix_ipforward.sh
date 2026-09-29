#!/bin/bash

# Test if script has root privileges, exit otherwise
id=$(id -u)
if [ "${id}" -ne 0 ]; then
  echo "You need to run this with sudo or as root."
  exit 1
fi

# Optional: --masq-subnet CIDR (source subnet for the fallback NAT MASQUERADE rule, defaults to Docker's address pool)
MASQ_SUBNET="172.16.0.0/12"
if [ "$1" = "--masq-subnet" ]; then
  MASQ_SUBNET="$2"
  if ! echo "${MASQ_SUBNET}" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$'; then
    echo "Unrecognized subnet '${MASQ_SUBNET}' (expected IPv4 CIDR, e.g. 172.16.0.0/12)"
    exit 1
  fi
fi

# Define the lines to insert. The MASQUERADE rule lives in the DSM-managed DEFAULT_POSTROUTING chain because DSM
# firewall reloads flush the rules dockerd adds to nat POSTROUTING, leaving containers without outbound NAT.
MASQ_RULE="-s ${MASQ_SUBNET} ! -d ${MASQ_SUBNET} -j MASQUERADE"
MASQ_LINE="          iptables -t nat -L DEFAULT_POSTROUTING -n >/dev/null 2>\&1 \&\& { iptables -t nat -C DEFAULT_POSTROUTING ${MASQ_RULE} 2>/dev/null || iptables -t nat -A DEFAULT_POSTROUTING ${MASQ_RULE}; }"
INSERT="            # Added by docker update\n          iptables -P FORWARD ACCEPT\n          iptables -C FORWARD -j DOCKER-FORWARD 2>/dev/null || iptables -I FORWARD 1 -j DOCKER-FORWARD\n${MASQ_LINE}"

# File to edit
file="/var/packages/ContainerManager/scripts/start-stop-status"

# Verify the insertion anchor exists before touching the file, so a missing anchor leaves
# the file unmodified.
match="^[[:space:]]*[$]DockerUpdaterBin postdaemonup[[:space:]]*$"
if ! grep -qE "${match}" "${file}"; then
  echo "WARNING: anchor '\$DockerUpdaterBin postdaemonup' not found in ${file}."
  echo "         File left unmodified -- check the file manually."
  exit 1
fi

# Remove any previously-inserted forwarding block, wherever it landed. Earlier versions inserted it
# before 'start_docker_daemon', where the DOCKER-FORWARD chain does not yet exist. The insmod block
# sharing the same comment is left untouched.
sed -i '/^[[:space:]]*iptables -C FORWARD -j DOCKER-FORWARD/d' "${file}"
sed -i '/^[[:space:]]*iptables -[ID] FORWARD -[io] docker0 -j ACCEPT[[:space:]]*$/d' "${file}"
sed -i '/^[[:space:]]*# Added by docker update[[:space:]]*$/{N;/\n[[:space:]]*iptables -P FORWARD ACCEPT/d}' "${file}"
sed -i '/^[[:space:]]*iptables -P FORWARD ACCEPT[[:space:]]*$/d' "${file}"
sed -i '/^[[:space:]]*iptables -t nat -.*DEFAULT_POSTROUTING .*-j MASQUERADE/d' "${file}"

# Insert only after the daemon is confirmed up. dockerd creates the DOCKER-FORWARD chain, so the
# jump rule cannot be added any earlier.
sed -i "/${match}/i\\${INSERT}" "${file}"
echo "Added IP forwarding and NAT masquerading (${MASQ_SUBNET}) configuration to ${file} (post daemon start)"
echo
echo "To avoid a restart of docker, adding the rules now. This should automatically apply"
echo " with the next docker restart"
iptables -P FORWARD ACCEPT
iptables -C FORWARD -j DOCKER-FORWARD 2>/dev/null || iptables -I FORWARD 1 -j DOCKER-FORWARD
if iptables -t nat -L DEFAULT_POSTROUTING -n >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  iptables -t nat -C DEFAULT_POSTROUTING ${MASQ_RULE} 2>/dev/null || iptables -t nat -A DEFAULT_POSTROUTING ${MASQ_RULE}
else
  echo "NOTE: nat chain DEFAULT_POSTROUTING not found (DSM firewall disabled?), MASQUERADE rule not added now."
fi
