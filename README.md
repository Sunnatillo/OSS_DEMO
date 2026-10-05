# k0rdent BYO Metal3 — Management Cluster for Bare Metal

This directory contains a **Bring-Your-Own (BYO)** integration that lets
**k0rdent open-source (KCM)** act as the management cluster for provisioning
**Metal3** bare-metal clusters via **Cluster API + kubeadm**.

It is the k0rdent-driven replacement for the imperative management-cluster
bootstrap in the original project-infra repo.

> **AI agents / new maintainers:** start with [`AGENT_HANDOVER.md`](AGENT_HANDOVER.md)
> — it has the hard facts, gotchas (with red herrings), a kind-reproduction
> recipe, teardown, and the per-lab values to change.

---

## 1. Why this exists (background)

The existing BML flow builds its management plane imperatively on a `kind`
cluster: `clusterctl init` + BMO + IPAM + IRSO + Ironic, all wired by hand.

The goal here is to let **k0rdent** own that management plane declaratively.

### Key constraint discovered
k0rdent's **turnkey Metal3 support is Enterprise-only** (Mirantis
`registry.mirantis.com/k0rdent-bm`, k0s-based). **k0rdent OSS ships no
bare-metal / Metal3 provider** — its default providers are AWS, Azure, GCP,
OpenStack, VMware, KubeVirt, and it uses **k0smotron (k0s)**, not kubeadm.

Therefore, on OSS we must **Bring Our Own**:
- a **ProviderTemplate** that installs Metal3 (CAPM3 + IPAM) + kubeadm providers,
- a **ClusterTemplate** that renders the Metal3/kubeadm cluster,
- **BMO + Ironic** deployed separately (they are not CAPI providers).

---

## 2. Architecture

```
┌─────────────────────────── Management cluster (kind in dev, lab host in prod) ───────────────────────────┐
│                                                                                                          │
│  KCM (k0rdent) ── installs ──► Cluster API core (v1.13.4) + cluster-api-operator                         │
│      │                                                                                                   │
│      │ Management.spec.providers += cluster-api-provider-metal3                                          │
│      ▼                                                                                                   │
│  ProviderTemplate (capm3-provider chart) ──► operator installs:                                         │
│       • InfrastructureProvider metal3  (CAPM3 v1.14.1)                                                   │
│       • IPAMProvider          metal3  (IPAM  v1.14.1)                                                    │
│       • BootstrapProvider     kubeadm (v1.13.4)                                                          │
│       • ControlPlaneProvider  kubeadm (v1.13.4)                                                          │
│       • ProviderInterface     cluster-api-provider-metal3   (REQUIRED by CD webhook)                     │
│                                                                                                          │
│  BMO (release-0.14, kustomize)   ── provides BareMetalHost CRD + controller                              │
│  IRSO (release-0.10, kustomize)  ── reconciles the Ironic CR                                             │
│  Ironic instance (Ironic CR)     ── DHCP/PXE/HTTP over the provisioning network                          │
│                                                                                                          │
│  ClusterDeployment (metal3-cluster template) ──► renders CAPI/Metal3 objects                            │
└──────────────────────────────────────────────────────────────────────────────┬───────────────────────┘
                                                                                 │ PXE / IPMI
                                                                                 ▼
                                                        Real bare-metal servers → workload cluster "test1"
```

Two layers to keep straight:
- **What the cluster is built with:** CAPI core + CAPM3 (infra) + kubeadm (bootstrap/control-plane) + IPAM.
- **What provisions the hardware:** BMO + Ironic (driven by CAPM3). These are **not** CAPI providers, so k0rdent does not install them — we deploy them ourselves.

---

## 3. Component versions (pinned)

| Component | Version / branch | Notes |
|---|---|---|
| KCM (k0rdent OSS) | **v1.11.0** | bundles CAPI **v1.13.4**; `oci://ghcr.io/k0rdent/kcm/charts/kcm` |
| CAPM3 (infra provider) | **v1.14.1** | operator-installed |
| IPAM (metal3) | **v1.14.1** | operator-installed |
| kubeadm bootstrap/control-plane | **v1.13.4** | match KCM's bundled CAPI |
| BMO | **release-0.14** | kustomize; provides `BareMetalHost` CRD |
| IRSO | **release-0.10** | kustomize; reconciles `Ironic` CR |
| Ironic (service) | **release-38.0** | via IRSO |
| keepalived | **release-0.9** | via Ironic CR |
| cluster-api-operator API | **operator.cluster.x-k8s.io/v1alpha2** | confirmed served by KCM v1.11.0 |

> **Rule:** pin every component to a specific release branch/tag — never `main`.
> CAPM3 1.14 ↔ BMO 0.14 ↔ IRSO 0.10 is the correct pairing (per CAPM3 1.14 release notes).
> CAPM3 1.14.1 is **compatible** with KCM's CAPI 1.13.4 — no downgrade needed.

---

## 4. Directory layout

```
k0rdent/
├── README.md                         # this file
├── AGENT_HANDOVER.md                 # handover doc for continuing in a new repo
├── config.env                        # all site-specific values (edit before a lab run)
├── install.sh                        # orchestrator (kind → KCM → templates → BMO/Ironic)
├── clean.sh                          # scoped teardown (this lab's cluster/networks only)
├── charts/
│   ├── metal3-cluster/               # ClusterTemplate chart (Metal3 + kubeadm cluster)
│   │   ├── Chart.yaml                #   declares providers via cluster.x-k8s.io/provider annotation
│   │   ├── values.yaml               #   lab defaults (CENTOS_10, v1.36.2, httpd image URL, VIP, pools)
│   │   └── templates/                #   cluster, ippools, controlplane, workers, _helpers
│   └── capm3-provider/               # ProviderTemplate chart
│       ├── Chart.yaml
│       ├── values.yaml               #   capm3/ipam v1.14.1, capi v1.13.4
│       └── templates/
│           ├── providers.yaml        #   4 cluster-api-operator provider CRs
│           └── providerinterface.yaml#   REQUIRED ProviderInterface (see §6 gotcha)
├── providers/
│   ├── 00-helmrepository.yaml        # Flux OCI source for the BYO charts
│   ├── 10-providertemplate-metal3.yaml
│   └── 20-clustertemplate-metal3-cluster.yaml
├── deploy/
│   ├── credential.yaml               # stub Secret + Credential (bare metal has no cloud identity)
│   ├── resource-template-configmap.yaml
│   └── clusterdeployment.yaml
└── scripts/
    └── deploy-ironic-bmo.sh          # BMO + IRSO + Ironic (pinned branches; auto-discovers prov NIC)

host-setup/                           # COPIED from the original project-infra repo (jenkins/scripts/bare_metal_lab/bml_test)
  02_configure_host.sh                #   host provisioning/external bridges, veth, docker nets, kind node attach, httpd, registry
  kind-network-topology.md            #   networking topology diagram
  lib/                                #   vars.sh, ironic_basic_auth.sh, ironic_tls_setup.sh, _clouds_yaml/
```

> `host-setup/` is a verbatim copy so `k0rdent/` is self-contained and movable to
> a new repo. `install.sh` runs `02_configure_host.sh` automatically when
> `SETUP_HOST_NETWORK=true` (default) — see §5 and §6.7.

---

## 5. How it is deployed (end-to-end)

`install.sh` orchestrates the following (read it before running in the lab):

1. **Base cluster + networking** — with `SETUP_HOST_NETWORK=true` (default),
   `install.sh` runs `host-setup/02_configure_host.sh` to create the kind cluster
   *and* the provisioning/external L2 (bridges, docker nets, kind-node attach,
   httpd, registry). Set it `false` for a plain `kind` cluster, or `--skip-kind`
   to reuse the current context.
2. **KCM** — `helm install kcm oci://ghcr.io/k0rdent/kcm/charts/kcm --version 1.11.0`.
3. **(optional) Trim providers** — drop the default cloud providers from `Management` (faster, lighter).
4. **Publish BYO charts** — `helm package` + `helm push` `capm3-provider` and `metal3-cluster` to the lab OCI registry (hardcoded `192.168.111.1:5000`).
5. **Register templates** — apply `providers/00,10,20` (HelmRepository, ProviderTemplate, ClusterTemplate).
6. **Enable Metal3** — patch `Management.spec.providers` to add `cluster-api-provider-metal3`. The operator then installs CAPM3, IPAM, kubeadm providers, and the ProviderInterface.
7. **Deploy BMO + Ironic** — `scripts/deploy-ironic-bmo.sh` (BMO + IRSO + Ironic CR) on the provisioning host.
8. **Credential** — apply `deploy/credential.yaml` + `deploy/resource-template-configmap.yaml`.
9. **(lab) Provision** — enroll `BareMetalHost` objects (create the manifests
   manually), set `sshPublicKey`, then
   `kubectl apply -f deploy/clusterdeployment.yaml`.

### Prerequisites (lab)
- Host provisioning networking is created automatically by `install.sh`
  (`SETUP_HOST_NETWORK=true` → `host-setup/02_configure_host.sh`); requires the lab
  physical NICs (`eno49`, `bmext`) and sudo.
- An OCI registry reachable from the management cluster (the lab's `:5000`).
- Target OS images served over httpd (as today).

---

## 6. Known gotchas & findings (hard-won)

### 6.1 ProviderInterface is mandatory for ClusterDeployment
k0rdent's ClusterDeployment admission webhook
(`internal/util/validation/cd.go`) rejects a CD with
`unsupported infrastructure provider infrastructure-metal3` unless a
`ProviderInterface` exists that:
- carries the label `cluster.x-k8s.io/provider: infrastructure-metal3`,
- is **installed via the Helm chart** (so it has the Helm labels
  `app.kubernetes.io/managed-by=Helm`, `helm.toolkit.fluxcd.io/name|namespace`
  that KCM's cached client expects — a hand-applied object is invisible to the
  webhook's cache),
- declares a **ClusterIdentity kind matching the Credential**. CAPM3 uses no
  cloud identity, so we advertise `clusterIdentityKinds: [Secret]` to match the
  stub Secret-based Credential.

This is shipped in `charts/capm3-provider/templates/providerinterface.yaml`.

### 6.2 CAPM3 hard-depends on the BareMetalHost CRD
Without BMO installed, `capm3-controller-manager` **CrashLoopBackOffs** with
`no matches for kind "BareMetalHost" in version "metal3.io/v1alpha1"`.
**Install BMO before (or together with) enabling the Metal3 provider.**

### 6.3 cluster-api-operator CRDs appear late
On a fresh KCM install the `operator.cluster.x-k8s.io` CRDs are missing for the
first few minutes — they appear only after core CAPI reconciles. Not a bug,
just timing.

### 6.4 KCM ships no kubeadm / no metal3 by default
KCM uses k0smotron. Our `capm3-provider` chart therefore also installs the
kubeadm bootstrap + control-plane providers.

### 6.5 Flux OCI over plain HTTP
For an in-cluster / insecure registry, the `HelmRepository` needs
`spec.insecure: true` and `helm push --plain-http`.

### 6.6 BMO kustomize needs no secrets for the base
`tools/deploy.sh -b -k -t` only **adds** optional components (basic-auth,
keepalived, TLS). `kubectl apply -k bmo/config` deploys the base operator + CRDs
cleanly. BMO even ships a `config/use-irso` overlay (BMO wired to IRSO).

### 6.7 Provisioning networking (wired in)
For a server to PXE-boot, the management `kind` node must sit on the provisioning
L2 (`172.22.0.0/24`) with the servers, and Ironic must bind the kind node's
provisioning NIC. Both are now handled:
1. When `SETUP_HOST_NETWORK=true` (default), `install.sh` runs
   `host-setup/02_configure_host.sh` instead of a plain `kind create` — it builds
   the bridges, `ironicendpoint` veth, docker nets `bml-provisioning`/`bml-external`
   bound to the host bridges, attaches the kind node at `172.22.0.9`/`192.168.111.9`,
   and starts httpd + the registry. Set `SETUP_HOST_NETWORK=false` for a plain dev
   cluster with no bare-metal networking.
2. `scripts/deploy-ironic-bmo.sh` auto-discovers the kind-node provisioning NIC
   (the one on `PROVISION_CIDR`) and uses it for the Ironic CR `networking.interface`
   — not the host `eno49`. `ipAddress` stays the keepalived VIP `172.22.0.2`. Set
   `PROVISION_INTERFACE` in `config.env` only to override (non-kind Ironic host).

---

## 7. Validation status

| Stage | Where | Status |
|---|---|---|
| KCM install | kind + KCM v1.11.0 | ✅ |
| BYO charts lint/template/package | local | ✅ |
| ProviderTemplate / ClusterTemplate valid | live | ✅ |
| Operator installs CAPM3/IPAM/kubeadm (READY) | live | ✅ |
| CAPM3 controller running | live | ✅ |
| BMO + IRSO via kustomize | live | ✅ 1/1 Running |
| Ironic CR reconciled by IRSO | live | ✅ Ready on kind |
| ClusterDeployment accepted by webhook | live (dry-run) | ✅ (after ProviderInterface fix) |
| Host networking + Ironic NIC discovery wired in | code (`bash -n`) | ✅ syntax; runtime lab-only |
| Real BareMetalHost provisioning | — | ✅ lab/hardware only |

---

## 8. Remaining gaps

- **Worker join**: `charts/metal3-cluster/templates/workers.yaml` has an
  `enp1s0`/`eno49` mismatch in its NetworkManager files and `nmcli` commands
  (the control-plane template is correct). Fix before setting `worker.replicas > 0`.
- **HA control plane**: validated with a single control-plane node; multi-replica untested.

---

## 9. Future direction (optional)

Deploy BMO + IRSO + Ironic as k0rdent **`ServiceTemplate`s** (which support
Helm *and* kustomize), so k0rdent/Flux manages their lifecycle too — instead of
the out-of-band `deploy-ironic-bmo.sh`. This keeps the whole stack GitOps-native.
