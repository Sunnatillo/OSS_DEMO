#!/usr/bin/env bash
#
# Video-recording wrapper around the install flow. Same steps as install.sh,
# but with curated output: key commands are shown as typed, noise goes to
# /tmp/demo.log, and every long wait is bracketed by pauses so the camera can
# be stopped/started without dead air.
#
# Usage:
#   ./demo.sh prep    # BEFORE recording: kind + networking + registry seeding
#   ./demo.sh         # on camera: k0rdent -> metal3 -> ironic -> BMH -> cluster
#
# Recording plan (3 videos, concat with ffmpeg):
#   video 1: k0rdent + Metal3 provider + Ironic kickoff
#   video 2: BMH enrollment -> available
#   video 3: ClusterDeployment -> child-cluster nodes Ready
# Stop recording whenever a dim "[camera ...]" hint appears; the script waits
# for Enter and never advances on its own.

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${SCRIPTDIR}/config.env"

LOG="/tmp/demo.log"
BMH_MANIFEST="${BMH_MANIFEST:-${SCRIPTDIR}/deploy/bmhosts.yaml}"
CLUSTER_NS="kcm-system"

C_CMD=$'\e[1;36m'   # cyan   - commands "typed" on screen
C_HDR=$'\e[1;33m'   # yellow - section banners
C_OK=$'\e[1;32m'    # green  - success marks
C_DIM=$'\e[2m'      # dim    - operator-only hints (barely visible on video)
C_RST=$'\e[0m'

banner() {
  echo
  echo "${C_HDR}============================================================${C_RST}"
  echo "${C_HDR}  $*${C_RST}"
  echo "${C_HDR}============================================================${C_RST}"
  echo
  key
}

ok() { echo "${C_OK}  OK: $*${C_RST}"; }

# Silent Enter: invisible on video; lets you narrate, then "run" the command.
# DEMO_AUTO=true disables all pacing (unattended rehearsal).
key() {
  [[ "${DEMO_AUTO:-false}" == "true" ]] && return 0
  read -rs _ </dev/tty
}

# Show the command as typed, wait for a silent Enter, then run it visibly.
show() {
  echo "${C_CMD}\$ $*${C_RST}"
  key
  "$@"
  echo
}

# Show the command as typed, wait for a silent Enter, hide its output.
quiet() {
  echo "${C_CMD}\$ $*${C_RST}"
  key
  "$@" >>"${LOG}" 2>&1
}

# Fully silent; output only in the log.
hidden() { "$@" >>"${LOG}" 2>&1; }

# Freeze until Enter. The dim hint tells the operator what to do with the camera.
pause() {
  echo
  read -rp "${C_DIM}[camera: $*] press Enter...${C_RST} " _ </dev/tty
  echo
}

# Run a long command in the background, show only an elapsed-time ticker.
wait_for() {
  local desc="$1"; shift
  echo "${C_CMD}\$ $*${C_RST}"
  "$@" >>"${LOG}" 2>&1 &
  local pid=$! start=${SECONDS}
  while kill -0 "${pid}" 2>/dev/null; do
    printf '\r  waiting for %s... %ds ' "${desc}" "$((SECONDS - start))"
    sleep 5
  done
  wait "${pid}"
  printf '\r%*s\r' 60 ''
  ok "${desc} ($((SECONDS - start))s)"
  echo
}

# --- prep: everything boring, run BEFORE recording -------------------------
prep() {
  echo "Prep (off camera): kind + networking + registry seeding. Log: ${LOG}"
  KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME}" K8S_VERSION="${K8S_VERSION}" \
    IMAGE_OS="${IMAGE_OS}" NODE_IMAGE_URL="${NODE_IMAGE_URL:-}" \
    "${SCRIPTDIR}/host-setup/02_configure_host.sh"
  kubectl config use-context "kind-${KIND_CLUSTER_NAME}"
  if command -v skopeo >/dev/null 2>&1 && [[ -n "${K8S_IMAGES:-}" ]]; then
    local img
    for img in ${K8S_IMAGES}; do
      skopeo copy --retry-times 3 --dest-tls-verify=false \
        "docker://registry.k8s.io/${img}" \
        "docker://192.168.111.1:5000/registry.k8s.io/${img}"
    done
  fi
  echo "Prep done. Start recording and run: ./demo.sh"
}

# --- video 1: k0rdent + Metal3 provider + Ironic ----------------------------
part1_kcm() {
  banner "1/5  Install k0rdent"
  if helm status kcm -n kcm-system >/dev/null 2>&1; then
    echo "${C_DIM}(kcm already installed; skipping helm install)${C_RST}"
  else
    quiet helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm \
      --version "${KCM_VERSION}" -n kcm-system --create-namespace
  fi
  show kubectl -n kcm-system rollout status deploy/kcm-controller-manager --timeout=600s
  show kubectl -n kcm-system get pods
  kubectl get namespace "${CLUSTER_NS}" >/dev/null 2>&1 \
    || hidden kubectl create namespace "${CLUSTER_NS}"
  trim_providers_hidden
}

trim_providers_hidden() {
  [[ "${TRIM_PROVIDERS}" == "true" ]] || return 0
  local deny='["cluster-api-provider-aws","cluster-api-provider-azure","cluster-api-provider-gcp","cluster-api-provider-docker","cluster-api-provider-kubevirt","cluster-api-provider-openstack","cluster-api-provider-vsphere","cluster-api-provider-infoblox","cluster-api-provider-ipam"]'
  local desired
  desired="$(kubectl get management kcm -o json \
    | jq -c --argjson deny "${deny}" \
      '[.spec.providers[] | select(.name as $n | ($deny | index($n)) | not)]')"
  hidden kubectl patch management kcm --type=merge -p "{\"spec\":{\"providers\":${desired}}}"
}

part2_metal3() {
  banner "2/5  Enable the Metal3 provider (BYO)"
  hidden mkdir -p /tmp/byo-charts
  hidden helm package "${SCRIPTDIR}/charts/capm3-provider" \
    "${SCRIPTDIR}/charts/metal3-cluster" -d /tmp/byo-charts
  quiet helm push /tmp/byo-charts/capm3-provider-0.1.0.tgz \
    oci://192.168.111.1:5000/k0rdent-byo --plain-http
  quiet helm push /tmp/byo-charts/metal3-cluster-0.1.1.tgz \
    oci://192.168.111.1:5000/k0rdent-byo --plain-http
  echo
  show kubectl apply -f "${SCRIPTDIR}/providers/00-helmrepository.yaml"
  show kubectl apply -f "${SCRIPTDIR}/providers/10-providertemplate-metal3.yaml"
  show kubectl apply -f "${SCRIPTDIR}/providers/20-clustertemplate-metal3-cluster.yaml"
  if ! kubectl get management kcm -o json \
      | jq -e '.spec.providers[] | select(.name=="cluster-api-provider-metal3")' >/dev/null; then
    show kubectl patch management kcm --type=json -p \
      '[{"op":"add","path":"/spec/providers/-","value":{"name":"cluster-api-provider-metal3","template":"cluster-api-provider-metal3-0-1-0"}}]'
  fi
  wait_for "Management Ready (Metal3 provider installed)" \
    kubectl wait --for=condition=Ready --timeout=10m management/kcm
  show kubectl get management kcm
  show kubectl -n "${CLUSTER_NS}" get clustertemplate
}

part3_ironic() {
  banner "3/5  Deploy Ironic + Bare Metal Operator"
  pause "STOP recording video 1 here; Ironic deploy takes a few minutes"
  hidden "${SCRIPTDIR}/scripts/deploy-ironic-bmo.sh"
  hidden kubectl apply -f "${SCRIPTDIR}/deploy/credential.yaml"
  hidden kubectl apply -f "${SCRIPTDIR}/deploy/resource-template-configmap.yaml"
  pause "START recording video 2, then press Enter"
  show kubectl -n "${IRONIC_NAMESPACE}" get ironic,pods
  banner "Management ready. Continue manually (parts 4-5):"
  cat <<EOF
  # Enroll BareMetalHosts, then watch them reach 'available':
  kubectl apply -f ${SCRIPTDIR}/deploy/bmhosts.yaml
  kubectl -n ${CLUSTER_NS} get bmh -w

  # Provision the child cluster:
  kubectl apply -f ${SCRIPTDIR}/deploy/clusterdeployment.yaml
  kubectl -n ${CLUSTER_NS} get clusterdeployment,bmh -w
EOF
}

# --- video 2: BMH -> available ----------------------------------------------
part4_bmh() {
  banner "4/5  Enroll BareMetalHosts"
  if [[ -f "${BMH_MANIFEST}" ]]; then
    show kubectl apply -f "${BMH_MANIFEST}"
  else
    pause "no ${BMH_MANIFEST}; apply your BMH manifests in another terminal, then Enter"
  fi
  show kubectl -n "${CLUSTER_NS}" get bmh
  pause "STOP recording video 2; inspection takes 5-10 min"
  wait_for "all BareMetalHosts available" \
    kubectl wait --for=jsonpath='{.status.provisioning.state}'=available \
    bmh --all -n "${CLUSTER_NS}" --timeout=30m
  pause "START recording video 3, then press Enter"
  show kubectl -n "${CLUSTER_NS}" get bmh
}

# --- video 3: provision the child cluster -----------------------------------
part5_provision() {
  banner "5/5  Provision the child cluster"
  show kubectl apply -f "${SCRIPTDIR}/deploy/clusterdeployment.yaml"
  show kubectl -n "${CLUSTER_NS}" get clusterdeployment,bmh
  pause "STOP recording video 3; provisioning takes 15-25 min"
  wait_for "ClusterDeployment ${CLUSTER_NAME} Ready" \
    kubectl wait --for=condition=Ready --timeout=40m \
    -n "${CLUSTER_NS}" "clusterdeployment/${CLUSTER_NAME}"
  pause "START recording the finale, then press Enter"
  show kubectl -n "${CLUSTER_NS}" get clusterdeployment,bmh
  hidden sh -c "kubectl -n ${CLUSTER_NS} get secret ${CLUSTER_NAME}-kubeconfig \
    -o jsonpath='{.data.value}' | base64 -d > /tmp/${CLUSTER_NAME}.kubeconfig"
  show kubectl --kubeconfig "/tmp/${CLUSTER_NAME}.kubeconfig" get nodes -o wide
  banner "Done: bare-metal cluster provisioned by k0rdent + Metal3"
}

if [[ "${1:-}" == "prep" ]]; then
  prep
  exit 0
fi

: > "${LOG}"
part1_kcm
part2_metal3
part3_ironic
# Parts 4-5 (BMH enrollment, provisioning) are run manually on camera.
# The part4_bmh / part5_provision functions above remain as reference.
