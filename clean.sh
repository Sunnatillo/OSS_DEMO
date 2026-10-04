#!/usr/bin/env bash
# Scoped teardown for the k0rdent BYO Metal3 management lab.
#
# Removes ONLY the resources this folder's setup creates:
#   - the kind management cluster (KIND_CLUSTER_NAME)
#   - the two docker networks bound to the kind node (provisioning/external)
#   - the host bridges + veth from host-setup/02_configure_host.sh
#   - the NAT/forward rules added for the external subnet egress
#
# Unlike host-setup/clean.sh it does NOT stop/remove unrelated containers,
# minikube, or libvirt networks, so it is safe on a shared/dev machine.

set -u

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Load site config for cluster/network names, if present.
if [[ -f "${SCRIPTDIR}/config.env" ]]; then
    # shellcheck disable=SC1091
    . "${SCRIPTDIR}/config.env"
fi

KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-metal3-mgmt}"
KIND_PROVISIONING_NETWORK="${KIND_PROVISIONING_NETWORK:-bml-provisioning}"
KIND_EXTERNAL_NETWORK="${KIND_EXTERNAL_NETWORK:-bml-external}"
EXTERNAL_SUBNET="${EXTERNAL_SUBNET:-192.168.111.0/24}"

set -x

# 1. Management cluster.
kind delete cluster --name "${KIND_CLUSTER_NAME}" || true

# 2. Docker networks attached to the kind node.
sudo docker network rm "${KIND_PROVISIONING_NETWORK}" || true
sudo docker network rm "${KIND_EXTERNAL_NETWORK}" || true

# 3. Host bridges + veth created by host-setup/02_configure_host.sh.
#    Deleting ironicendpoint removes its ironic-peer veth; the explicit delete
#    is a fallback in case only the peer survived a partial setup.
sudo ip link delete provisioning   || true
sudo ip link delete external       || true
sudo ip link delete ironicendpoint || true
sudo ip link delete ironic-peer    || true

# 4. NAT/forward rules added for external-subnet internet egress (best-effort).
DEFAULT_IF="$(ip route show default | awk '/default/ {print $5; exit}')"
if [[ -n "${DEFAULT_IF}" ]]; then
    sudo iptables -t nat -D POSTROUTING -s "${EXTERNAL_SUBNET}" -o "${DEFAULT_IF}" -j MASQUERADE || true
    sudo iptables -D FORWARD -i external -o "${DEFAULT_IF}" -j ACCEPT || true
    sudo iptables -D FORWARD -i "${DEFAULT_IF}" -o external -m state --state RELATED,ESTABLISHED -j ACCEPT || true
fi

set +x
echo "Scoped teardown complete for cluster '${KIND_CLUSTER_NAME}'."
