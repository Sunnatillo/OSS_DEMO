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
# Reads k0rdent/config.env. Set REGISTRY_HOST before running.

set -eux

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPTDIR}/config.env"

SKIP_KIND="false"
[[ "${1:-}" == "--skip-kind" ]] && SKIP_KIND="true"

# Cloud providers removed from Management when TRIM_PROVIDERS=true.
TRIM_DENYLIST='["cluster-api-provider-aws","cluster-api-provider-azure","cluster-api-provider-gcp","cluster-api-provider-docker","cluster-api-provider-kubevirt","cluster-api-provider-openstack","cluster-api-provider-vsphere","cluster-api-provider-infoblox"]'

ensure_kind() {
  [[ "${SKIP_KIND}" == "true" ]] && return 0
  if [[ "${SETUP_HOST_NETWORK:-false}" == "true" ]]; then
    # Creates the kind cluster AND the provisioning/external L2 networking
    # (bridges, ironicendpoint veth, docker nets, node attach), httpd + registry.
    KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" K8S_VERSION="${K8S_VERSION}" IMAGE_OS="${IMAGE_OS}" \
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
    "${SCRIPTDIR}/charts/capm3-standalone-cp" -d "${out}"
  helm push "${out}/capm3-provider-0.1.0.tgz" "oci://${REGISTRY_HOST}/k0rdent-byo"
  helm push "${out}/capm3-standalone-cp-0.1.0.tgz" "oci://${REGISTRY_HOST}/k0rdent-byo"
}

register_templates() {
  # Point the HelmRepository at the configured registry, then apply the sources.
  sed "s#oci://REGISTRY_HOST/k0rdent-byo#oci://${REGISTRY_HOST}/k0rdent-byo#" \
    "${SCRIPTDIR}/providers/00-helmrepository.yaml" | kubectl apply -f -
  kubectl apply -f "${SCRIPTDIR}/providers/10-providertemplate-metal3.yaml"
  kubectl apply -f "${SCRIPTDIR}/providers/20-clustertemplate-capm3-standalone-cp.yaml"
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

ensure_kind
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
  1. Enroll BareMetalHosts in namespace kcm-system
     (render k0rdent/deploy/bmhosts_crs.yaml.j2 with k0rdent/default_vars/vars.yaml).
  2. Set sshPublicKey in k0rdent/deploy/clusterdeployment-example.yaml.
  3. kubectl apply -f k0rdent/deploy/clusterdeployment-example.yaml
  4. Watch: kubectl -n kcm-system get bmh,clusterdeployment -w
EOF
