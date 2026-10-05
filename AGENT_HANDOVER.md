# Agent Handover — k0rdent BYO Metal3

> Purpose: give an AI coding agent (and a human) everything needed to continue
> this work **in a fresh repository**, without the original chat history.
> Read this top to bottom before acting.

---

## 0. TL;DR

Build and operate a **k0rdent OSS (KCM)** management cluster that provisions
**Metal3 bare-metal** workload clusters using **Cluster API + kubeadm**, by
**Bringing Your Own** provider/cluster templates (OSS k0rdent has no built-in
Metal3 support — that is Enterprise-only).

**Current state:** the full stack is built and validated on `kind` end-to-end
**except real-hardware provisioning**. All artifacts live under `k0rdent/`.

---

## 1. Mission & scope

- **In scope:** k0rdent management cluster + CAPI + CAPM3 + IPAM + kubeadm +
  BMO + Ironic, wired as BYO templates, so k0rdent drives Metal3 provisioning.
- **Out of scope (lab-only):** actually PXE/IPMI-provisioning physical servers.
- **Control-plane choice:** **kubeadm** (not k0s/k0smotron), to stay faithful to
  the existing project-infra Metal3 manifests. (A k0s variant is possible but a
  larger rewrite.)

---

## 2. Hard facts you must not re-derive

| Fact | Value |
|---|---|
| k0rdent edition | **OSS / KCM** (not Enterprise). Metal3 is NOT built in → BYO required. |
| KCM version | **v1.11.0**, chart `oci://ghcr.io/k0rdent/kcm/charts/kcm` |
| CAPI bundled by KCM | **v1.13.4** |
| CAPM3 / IPAM | **v1.14.1** (compatible with CAPI 1.13.4 — verified, no downgrade) |
| kubeadm providers | **v1.13.4** (match KCM's CAPI) |
| BMO / IRSO / Ironic / keepalived | **release-0.14 / release-0.10 / release-38.0 / release-0.9** |
| operator API | **operator.cluster.x-k8s.io/v1alpha2** (served by KCM v1.11.0) |
| KCM default providers | AWS/Azure/GCP/OpenStack/VMware/KubeVirt/Infoblox/IPAM-in-cluster/**k0smotron**/sveltos. **No kubeadm, no metal3.** |

**Pin every component to a release branch/tag — never `main`.** (User rule.)

---

## 3. Repository contents (what to copy to the new repo)

Copy the entire `k0rdent/` tree:

```
k0rdent/
  README.md                         # comprehensive reference (read it)
  AGENT_HANDOVER.md                 # this file
  config.env                        # site values — MUST edit REGISTRY_HOST, sshPublicKey, network params
  install.sh                        # orchestrator: kind+networking → KCM → templates → BMO/Ironic
  charts/capm3-standalone-cp/       # ClusterTemplate (Metal3 + kubeadm) — ported from project-infra manifests
  charts/capm3-provider/            # ProviderTemplate chart:
        templates/providers.yaml            → 4 operator provider CRs
        templates/providerinterface.yaml    → REQUIRED ProviderInterface (critical, see §5.1)
  providers/00..30-*.yaml           # Flux HelmRepository, ProviderTemplate, ClusterTemplate, Management patch
  deploy/                           # stub Credential + ConfigMap + example ClusterDeployment
  scripts/deploy-ironic-bmo.sh      # BMO + IRSO + Ironic (pinned branches; auto-discovers prov NIC)
  host-setup/                       # COPIED from project-infra: host L2 networking (02_configure_host.sh), lib/
```

The source Metal3 manifests this was ported from live in the project-infra repo:
`jenkins/scripts/bare_metal_lab/bml_test/manifests/{cluster,controlplane,workers}_centos.yaml`.

---

## 4. The deployment flow (and how each piece fits)

1. **Base cluster + networking** — `install.sh` runs
   `host-setup/02_configure_host.sh` when `SETUP_HOST_NETWORK=true` (default):
   creates the kind cluster AND the provisioning/external L2 (bridges, docker
   nets, kind-node attach at `172.22.0.9`/`192.168.111.9`, httpd, registry).
   `SETUP_HOST_NETWORK=false` → plain kind; `--skip-kind` → reuse context.
   Then `helm install kcm … --version 1.11.0`.
2. Push `capm3-provider` + `capm3-standalone-cp` charts to an OCI registry
   (`REGISTRY_HOST`). Flux `HelmRepository` (label `k0rdent.mirantis.com/managed: "true"`,
   `insecure: true` for plain-HTTP registries) serves them.
3. Apply `ProviderTemplate` (cluster-scoped) + `ClusterTemplate` (in `kcm-system`).
4. Patch `Management.spec.providers` → add `{name: cluster-api-provider-metal3,
   template: cluster-api-provider-metal3-0-1-0}`. The **cluster-api-operator**
   then installs CAPM3, IPAM, kubeadm bootstrap/control-plane, and the
   ProviderInterface (all from the `capm3-provider` chart).
5. Deploy **BMO + IRSO + Ironic** via `scripts/deploy-ironic-bmo.sh` (pinned
   branches `release-0.14` / `release-0.10`; the Ironic CR `networking.interface`
   is **auto-discovered** = the kind node's `PROVISION_CIDR` NIC, not `eno49`).
   Validated kind-only alternative: `kubectl apply -k bmo/config` +
   `kubectl apply -k irso/config/default` + a minimal `Ironic` CR.
6. Apply stub `Credential` + resource-template `ConfigMap`.
7. (lab) enroll `BareMetalHost`s, set `sshPublicKey`, apply the
   `ClusterDeployment`.

---

## 5. Critical gotchas (these cost real debugging time — do not re-learn)

### 5.1 ProviderInterface is required, with exact properties
CD webhook error `unsupported infrastructure provider infrastructure-metal3`
means the `ProviderInterface` is missing/invalid. It MUST:
- be **installed by the Helm chart** (not `kubectl apply`) so it carries
  `app.kubernetes.io/managed-by=Helm` + `helm.toolkit.fluxcd.io/name|namespace`
  — KCM's cached client won't see a hand-applied object;
- have label `cluster.x-k8s.io/provider: infrastructure-metal3`;
- declare `clusterIdentityKinds: [Secret]` (match the stub Secret Credential).
Already implemented in `charts/capm3-provider/templates/providerinterface.yaml`.
(Red herrings that wasted time: cache staleness, controller restarts, extra
labels — none of these were the cause.)

### 5.2 Install BMO before enabling CAPM3
CAPM3 crash-loops (`no matches for kind "BareMetalHost"`) until BMO installs the
`baremetalhosts.metal3.io` CRD. Order: BMO first (or concurrently).

### 5.3 operator CRDs appear a few minutes after KCM install
Don't conclude they're missing — wait for core CAPI to reconcile.

### 5.4 Flux OCI over HTTP needs `insecure: true` + `helm push --plain-http`.

### 5.5 BMO install: deploy.sh vs kustomize
`scripts/deploy-ironic-bmo.sh` uses BMO's `tools/deploy.sh -b -k -t` (the
project-infra way: basic-auth + keepalived + TLS). A plain `kubectl apply -k
bmo/config` also works and needs **no** secrets — the `-b -k -t` flags only add
optional components. Both are valid; the script path matches the lab.

---

## 6. Validation commands (how to prove it works again)

```bash
# providers installed & ready
kubectl get infrastructureproviders,ipamproviders,bootstrapproviders,controlplaneproviders -A
# capm3 running (needs BMO's CRD first)
kubectl -n kcm-system get pods | grep -E 'capm3|ipam-controller'
# templates valid
kubectl get providertemplate cluster-api-provider-metal3-0-1-0 -o jsonpath='{.status.valid}'
kubectl -n kcm-system get clustertemplate capm3-standalone-cp-0-1-0 -o jsonpath='{.status.valid}'
# ClusterDeployment accepted (dry-run; needs Credential + ProviderInterface)
kubectl apply --dry-run=server -f deploy/clusterdeployment-example.yaml
# BMO / IRSO / Ironic
kubectl -n baremetal-operator-system get pods
kubectl -n ironic-standalone-operator-system get pods
kubectl -n baremetal-operator-system get ironic ironic -o jsonpath='{.status.conditions}'
```

Expected on a dev `kind`: everything READY **except** the Ironic instance (needs
provisioning NIC + IPA source) and real provisioning.

---

## 7. Open items / next steps

1. **Ironic on real hardware** — run `install.sh` (or `scripts/deploy-ironic-bmo.sh`)
   on the lab host; `SETUP_HOST_NETWORK=true` builds the provisioning bridge via
   `host-setup/02_configure_host.sh`. Confirm the Ironic CR reaches `Ready`.
2. **Full ClusterDeployment on hardware** — enroll BMHs, apply the CD, watch
   `bmh`/`clusterdeployment` reach provisioned/ready.
3. **(optional) ServiceTemplate-ify BMO/IRSO/Ironic** — deploy them as k0rdent
   `ServiceTemplate`s (support Helm + kustomize) so k0rdent/Flux manages them.
4. **config.env** — fill `REGISTRY_HOST`, `sshPublicKey`, keepalived VIP, DHCP
   range, httpd base URL. `PROVISION_INTERFACE` can stay empty (auto-discovered).
5. **Chart versioning** — if you change a chart, bump its version and the
   `-X-Y-Z` suffix in the ProviderTemplate/ClusterTemplate names + `install.sh`.

---

## 8. Environment assumptions

- Tools: `kubectl`, `helm` (≥3.13 for `--plain-http`), `kind` (dev), `docker`,
  `jq`, `git`.
- Lab: host attached to the bare-metal provisioning network; an OCI registry
  reachable from the management cluster; httpd serving target OS images.
- Dev: `kind` with internet (to pull KCM, CAPI, CAPM3, BMO, IRSO images).

---

## 9. Guardrails (user preferences)

- Pin components to **release branches**, never `main`.
- Install BMO/Ironic the **project-infra way** (kustomize/IRSO), not ad-hoc.
- Keep changes scoped; prefer editing existing artifacts over new ones.
- Hardcoded lab interfaces (`eno49`, `eno50`, `eno49.3`, worker `enp1s0`) in the
  ClusterTemplate are intentional for the current lab; lift to values only if asked.

---

## 10. Reproduce / validate on kind (no hardware)

The management + provider layer can be fully exercised on `kind` without bare
metal. This is how it was validated:

```bash
# 1. kind + KCM (skip host networking on a dev box)
kind create cluster --name kcm-byo-test
helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm --version 1.11.0 \
  -n kcm-system --create-namespace
kubectl -n kcm-system rollout status deploy/kcm-controller-manager --timeout=600s

# 2. in-cluster OCI registry (kind can't resolve a host :5000 by DNS)
kubectl create ns registry
kubectl -n registry create deployment registry --image=registry:2.8.3
kubectl -n registry expose deployment registry --port=5000
kubectl -n registry port-forward svc/registry 5001:5000 &   # host:5001 → registry

# 3. push the BYO charts (plain HTTP)
helm package charts/capm3-provider charts/capm3-standalone-cp -d /tmp/byo
helm push /tmp/byo/capm3-provider-0.1.0.tgz oci://localhost:5001/k0rdent-byo --plain-http
helm push /tmp/byo/capm3-standalone-cp-0.1.0.tgz oci://localhost:5001/k0rdent-byo --plain-http

# 4. HelmRepository must point at the in-cluster svc AND be insecure:
#    url: oci://registry.registry.svc.cluster.local:5000/k0rdent-byo , insecure: true
kubectl apply -f providers/10-providertemplate-metal3.yaml
kubectl apply -f providers/20-clustertemplate-capm3-standalone-cp.yaml

# 5. enable metal3, then validate (see §6)
kubectl patch management kcm --type=json -p \
 '[{"op":"add","path":"/spec/providers/-","value":{"name":"cluster-api-provider-metal3","template":"cluster-api-provider-metal3-0-1-0"}}]'
```

BMO/IRSO on kind (needed for CAPM3's BareMetalHost CRD dependency):
```bash
git clone -b release-0.14 https://github.com/metal3-io/baremetal-operator /tmp/bmo
kubectl apply -k /tmp/bmo/config
git clone -b release-0.10 https://github.com/metal3-io/ironic-standalone-operator /tmp/irso
kubectl apply -k /tmp/irso/config/default
# minimal Ironic CR (stays Init/not-Ready on kind — no provisioning NIC — EXPECTED)
kubectl -n baremetal-operator-system apply -f - <<EOF
apiVersion: ironic.metal3.io/v1alpha1
kind: IronicWhich do you mean? If it's the 03 script, I'll delete it and clean the doc refs. If you really want to drop PROVISION_MACS, tell me how you intend to feed the MACs to Ironic instead, since the active deploy depends on it.


metadata: {name: ironic, namespace: baremetal-operator-system}
spec: {}
EOF
```

---

## 11. Teardown

```bash
kind delete cluster --name metal3-mgmt        # dev (cluster only)
./clean.sh                                     # scoped: this lab's cluster + docker nets + bridges/veth + its iptables rules
# or KCM only:
kubectl delete management.k0rdent kcm ; helm uninstall kcm -n kcm-system
```

---

## 12. Values to change for a NEW lab/environment

These are hardcoded to the current BML lab — review before reusing elsewhere:

- **`config.env`**: `REGISTRY_HOST`, `SSH_PUBLIC_KEY_FILE`, `KEEPALIVED_VIP`,
  `DHCP_RANGE_*`, `PROVISION_CIDR`, `IMAGE_BASE_URL`, `CONTROLPLANE_VIP`, pools.
- **`host-setup/02_configure_host.sh` + `host-setup/lib/vars.sh`**: physical NICs
  `eno49` (provisioning) and `bmext`/`EXTERNAL_IFACE` (external), `IRONIC_DATA_DIR`
  (`/opt/metal3-dev-env`), the `sudo su -l <user>` user, and the node-image
  download URL (`artifactory.nordix.org`).
- **`charts/capm3-standalone-cp`** (cloud-init in `templates/controlplane.yaml` /
  `templates/workers.yaml`): interfaces `eno49`/`eno50`/`eno49.3`/`enp1s0`, VLAN
  `3`, control-plane VIP `192.168.111.249`, insecure registry `192.168.111.1:5000`,
  embedded SSH key.
- **`deploy/clusterdeployment-example.yaml`**: `sshPublicKey`, pools, VIP, versions.
