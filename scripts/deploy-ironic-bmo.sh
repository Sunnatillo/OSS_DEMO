#!/usr/bin/env bash
#
# Deploys the Bare Metal Operator (BMO), the Ironic Standalone Operator (IRSO)
# and an Ironic instance into the k0rdent management cluster. These are NOT
# Cluster API providers, so k0rdent does not manage them; we deploy them the
# same way the existing BML flow does.
#
# Prerequisite: host provisioning networking (provisioning bridge, ironicendpoint,
# the mgmt node attached to the provisioning network) must already be configured.
# Reuse host-setup/02_configure_host.sh for that.
#
# Usage: ./deploy-ironic-bmo.sh   (reads ../config.env)

set -eux

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPTDIR}/../config.env"

WORKDIR="${WORKDIR:-/opt/metal3-k0rdent}"
BMOPATH="${WORKDIR}/baremetal-operator"
IRSOPATH="${WORKDIR}/ironic-standalone-operator"
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-registry.nordix.org/quay-io-proxy}"
KIND_NODE_NAME="${KIND_NODE_NAME:-${KIND_CLUSTER_NAME:-metal3-mgmt}-control-plane}"

mkdir -p "${WORKDIR}"

# Discover the provisioning interface inside the kind node (the NIC on
# PROVISION_CIDR). Ironic must bind this, not a host NIC such as eno49.
discover_prov_iface() {
  local net="${PROVISION_CIDR%/*}" pfx
  pfx="${net%.*}"          # 172.22.0.0/24 -> 172.22.0
  pfx="${pfx//./\\.}"     # -> 172\.22\.0
  sudo docker exec "${KIND_NODE_NAME}" sh -c \
    "ip -o -4 addr show | awk '/${pfx}\\./ {print \$2; exit}'"
}

clone_with_retry() {
  local url="$1" dest="$2" branch="$3" attempt=1 max=5 wait=1
  [[ -d "${dest}/.git" ]] && { echo "exists: ${dest}"; return 0; }
  while [[ ${attempt} -le ${max} ]]; do
    if git clone --depth 1 --single-branch --branch "${branch}" "${url}" "${dest}"; then return 0; fi
    sleep "${wait}"; wait=$((wait * 2)); attempt=$((attempt + 1))
  done
  echo "failed to clone ${url} (${branch})" >&2; return 1
}

clone_with_retry "https://github.com/metal3-io/baremetal-operator.git" "${BMOPATH}" "${BMO_BRANCH}"
clone_with_retry "https://github.com/metal3-io/ironic-standalone-operator.git" "${IRSOPATH}" "${IRSO_BRANCH}"

# --- Bare Metal Operator ---
deploy_bmo() {
  pushd "${BMOPATH}"
  cat > config/default/ironic.env <<EOF
DEPLOY_KERNEL_URL=http://${KEEPALIVED_VIP}:6180/images/ironic-python-agent.kernel
DEPLOY_RAMDISK_URL=http://${KEEPALIVED_VIP}:6180/images/ironic-python-agent.initramfs
IRONIC_ENDPOINT=https://${KEEPALIVED_VIP}:6385/v1/
IRONIC_INSPECTOR_ENDPOINT=https://${KEEPALIVED_VIP}:5050/v1/
EOF
  export MANIFEST_IMG="${CONTAINER_REGISTRY}/metal3-io/baremetal-operator"
  export MANIFEST_TAG="${BMO_BRANCH}"
  make set-manifest-image-bmo
  ./tools/deploy.sh -b -k -t
  popd
}

# --- Ironic Standalone Operator ---
deploy_irso() {
  echo "IPA_BASEURI=${IMAGE_BASE_URL}" > "${IRSOPATH}/config/manager/manager.env"
  make -C "${IRSOPATH}" install deploy \
    IMG="${CONTAINER_REGISTRY}/metal3-io/ironic-standalone-operator:${IRSO_BRANCH}"
  kubectl wait --for=condition=Available --timeout=120s \
    -n ironic-standalone-operator-system \
    deployment/ironic-standalone-operator-controller-manager
}

# --- Ironic instance via IRSO ---
deploy_ironic() {
  local iface="${PROVISION_INTERFACE:-}"
  [[ -z "${iface}" ]] && iface="$(discover_prov_iface)"
  if [[ -z "${iface}" ]]; then
    echo "Failed to discover provisioning interface in ${KIND_NODE_NAME}" >&2
    exit 1
  fi
  kubectl create namespace "${IRONIC_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  cat <<EOF | kubectl apply -f -
apiVersion: ironic.metal3.io/v1alpha1
kind: Ironic
metadata:
  name: ironic
  namespace: "${IRONIC_NAMESPACE}"
spec:
  images:
    deployRamdiskBranch: "master"
    deployRamdiskDownloader: "${CONTAINER_REGISTRY}/metal3-io/ironic-ipa-downloader"
    ironic: "${CONTAINER_REGISTRY}/metal3-io/ironic:release-${IRSO_IRONIC_VERSION}"
    keepalived: "${CONTAINER_REGISTRY}/metal3-io/keepalived:release-0.9"
  version: "${IRSO_IRONIC_VERSION}"
  networking:
    dhcp:
      rangeBegin: "${DHCP_RANGE_START}"
      rangeEnd: "${DHCP_RANGE_END}"
      networkCIDR: "${PROVISION_CIDR}"
      ignore:
        - "tag:!known"
    interface: "${iface}"
    ipAddress: "${KEEPALIVED_VIP}"
    ipAddressManager: keepalived
EOF
  kubectl wait --for=condition=Ready --timeout=10m \
    -n "${IRONIC_NAMESPACE}" ironic/ironic
}

deploy_bmo
deploy_irso
deploy_ironic
echo "BMO + Ironic deployed."
