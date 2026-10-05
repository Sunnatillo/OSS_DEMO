#!/usr/bin/env bash
#
# One-shot installer for the k0rdent BYO Metal3 management cluster.
#
# Steps: create kind (optional) -> install KCM -> (optional) trim providers ->
# publish BYO charts -> register provider + templates -> add Metal3 to Management
# -> deploy BMO + Ironic -> apply stub credential.  BareMetalHost enrollment and
# the ClusterDeployment are left to the operator (see k0rdent/deploy/).
#
# Usage:
#   ./install.sh [--skip-kind]      # reuse the current kubectl context instead of kind
#
# Reads k0rdent/config.env.

set -eux

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPTDIR}/config.env"

SKIP_KIND="false"
[[ "${1:-}" == "--skip-kind" ]] && SKIP_KIND="true"

# Cloud and unused IPAM providers removed from Management when TRIM_PROVIDERS=true.
# cluster-api-provider-ipam is CAPI in-cluster IPAM; we use ipam.metal3.io instead.
# Deliberately keeps cluster-api-provider-k0sproject-k0smotron and projectsveltos (KCM machinery).
TRIM_DENYLIST='["cluster-api-provider-aws","cluster-api-provider-azure","cluster-api-provider-gcp","cluster-api-provider-docker","cluster-api-provider-kubevirt","cluster-api-provider-openstack","cluster-api-provider-vsphere","cluster-api-provider-infoblox","cluster-api-provider-ipam"]'

ensure_kind() {
  [[ "${SKIP_KIND}" == "true" ]] && return 0
  if [[ "${SETUP_HOST_NETWORK:-false}" == "true" ]]; then
    # Creates the kind cluster AND the provisioning/external L2 networking
    # (bridges, ironicendpoint veth, docker nets, node attach), httpd + registry.
    KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" K8S_VERSION="${K8S_VERSION}" IMAGE_OS="${IMAGE_OS}" NODE_IMAGE_URL="${NODE_IMAGE_URL:-}" \
      "${SCRIPTDIR}/host-setup/02_configure_host.sh"
  elif ! kind get clusters | grep -qx "${KIND_CLUSTER_NAME}"; then
    kind create cluster --name "${KIND_CLUSTER_NAME}"
  fi
  kubectl config use-context "kind-${KIND_CLUSTER_NAME}"
}

install_kcm() {
  helm install kcm "oci://ghcr.io/k0rdent/kcm/charts/kcm" \
    --version "${KCM_VERSION}" -n kcm-system --create-namespace
  kubectl -n kcm-system rollout status deploy/kcm-controller-manager --timeout=600s
}

trim_providers() {
  [[ "${TRIM_PROVIDERS}" == "true" ]] || return 0
  local desired
  desired="$(kubectl get management kcm -o json \
    | jq -c --argjson deny "${TRIM_DENYLIST}" \
      '[.spec.providers[] | select(.name as $n | ($deny | index($n)) | not)]')"
  kubectl patch management kcm --type=merge -p "{\"spec\":{\"providers\":${desired}}}"
}

publish_charts() {
  local out="/tmp/byo-charts"
  mkdir -p "${out}"
  helm package "${SCRIPTDIR}/charts/capm3-provider" \
    "${SCRIPTDIR}/charts/metal3-cluster" -d "${out}"
  helm push "${out}/capm3-provider-0.1.0.tgz" "oci://192.168.111.1:5000/k0rdent-byo" --plain-http
  helm push "${out}/metal3-cluster-0.1.1.tgz" "oci://192.168.111.1:5000/k0rdent-byo" --plain-http
}

register_templates() {
  kubectl apply -f "${SCRIPTDIR}/providers/00-helmrepository.yaml"
  kubectl apply -f "${SCRIPTDIR}/providers/10-providertemplate-metal3.yaml"
  kubectl apply -f "${SCRIPTDIR}/providers/20-clustertemplate-metal3-cluster.yaml"
}

add_metal3_provider() {
  if ! kubectl get management kcm -o json \
      | jq -e '.spec.providers[] | select(.name=="cluster-api-provider-metal3")' >/dev/null; then
    kubectl patch management kcm --type=json -p \
      '[{"op":"add","path":"/spec/providers/-","value":{"name":"cluster-api-provider-metal3","template":"cluster-api-provider-metal3-0-1-0"}}]'
  fi
  kubectl wait --for=condition=Ready --timeout=10m management/kcm
}

apply_credential() {
  kubectl apply -f "${SCRIPTDIR}/deploy/credential.yaml"
  kubectl apply -f "${SCRIPTDIR}/deploy/resource-template-configmap.yaml"
}

# Mirror kubeadm's control-plane images into the local registry so provisioned
# nodes pull them over the LAN (not registry.k8s.io), cutting kubeadm init time.
seed_registry_images() {
  [[ -n "${K8S_IMAGES:-}" ]] || return 0
  if ! command -v skopeo >/dev/null 2>&1; then
    echo "WARN: skopeo not found; skipping k8s image seeding (nodes pull from registry.k8s.io)." >&2
    return 0
  fi
  local img
  for img in ${K8S_IMAGES}; do
    skopeo copy --retry-times 3 --dest-tls-verify=false \
      "docker://registry.k8s.io/${img}" \
      "docker://192.168.111.1:5000/registry.k8s.io/${img}"
  done
}

ensure_kind
seed_registry_images
install_kcm
trim_providers
publish_charts
register_templates
add_metal3_provider
"${SCRIPTDIR}/scripts/deploy-ironic-bmo.sh"
apply_credential

set +x
cat <<'EOF'

Management cluster ready. Next (lab, with real servers):
  1. Enroll BareMetalHosts in namespace kcm-system (create BMH manifests manually).
  2. kubectl apply -f k0rdent/deploy/clusterdeployment.yaml
  3. Watch: kubectl -n kcm-system get bmh,clusterdeployment -w
EOF
