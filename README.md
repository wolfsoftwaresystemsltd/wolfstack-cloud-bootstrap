# wolfstack-cloud-bootstrap

One-command bootstrap scripts that spin up a WolfStack cluster on any
major cloud — Hetzner, AWS, GCP, Azure, DigitalOcean, Vultr, Linode,
Scaleway. The scripts use each provider's CLI to provision N VMs, run
WolfStack's `cloud-setup.sh` via cloud-init on each, and report back so
you can wire the cluster together from the master node's dashboard.

The scripts are deliberately small, readable, and self-contained.
There's no orchestration daemon, no credential storage on our side, no
hosted bootstrap service — your cloud credentials live where they
already do (`~/.aws/credentials`, `HCLOUD_TOKEN`, `gcloud auth`, etc.)
and the script just calls into the provider's CLI on your behalf.

---

## Quick start

```bash
# Clone the repo
git clone https://github.com/wolfsoftwaresystemsltd/wolfstack-cloud-bootstrap.git
cd wolfstack-cloud-bootstrap

# Pick your cloud and run (default: 3× medium nodes in the closest region)
cd hetzner
export HCLOUD_TOKEN="your-token"
./bootstrap.sh
```

90 seconds later you'll have a working 3-node WolfStack cluster.
The bootstrap script auto-forms the cluster — no manual token-paste,
no SSH-and-copy. Open `https://<first-vm-ip>:8553`, log in, and the
dashboard already shows all three nodes online and federated.

## Supported providers

Every script supports `--size small|medium|large` (default: medium).
4 GB RAM (most clouds' "small" tier default) is too tight for real
Docker / LXC / VM workloads — that's why **medium is the default**.

| Provider | small (2 vCPU / 4 GB) | **medium (recommended)** | large (16 GB+) |
|---|---|---|---|
| **Hetzner** | cx22 — €4.51/mo | **cx32 (4 vCPU / 8 GB / 80 GB) — €9.42/mo** | cx42 (8 / 16 / 160) — €19.69/mo |
| **Scaleway** | DEV1-S — €3.65/mo | **DEV1-L (4 / 8 / 80) — €14.61/mo** | PRO2-S (4 / 16 / 40) — ~€36/mo |
| **DigitalOcean** | s-2vcpu-4gb — $24/mo | **s-4vcpu-8gb (4 / 8 / 160) — $48/mo** | s-8vcpu-16gb (8 / 16 / 320) — $96/mo |
| **Vultr** | vc2-2c-4gb — $24/mo | **vc2-4c-8gb (4 / 8 / 160) — $48/mo** | vc2-6c-16gb (6 / 16 / 320) — $96/mo |
| **Linode** | g6-standard-2 — $24/mo | **g6-standard-4 (4 / 8 / 160) — $48/mo** | g6-standard-6 (6 / 16 / 320) — $96/mo |
| **GCP** | e2-medium — ~$24/mo | **e2-standard-2 (2 / 8 / 100 GB) — ~$48/mo** | e2-standard-4 (4 / 16 / 200) — ~$96/mo |
| **AWS** | t3.medium — ~$30/mo | **t3.large (2 / 8 / 100 EBS) — ~$60/mo** | t3.xlarge (4 / 16 / 200) — ~$120/mo |
| **Azure** | Standard_B2s — ~$30/mo | **Standard_B2ms (2 / 8 / 100) — ~$60/mo** | Standard_B4ms (4 / 16 / 200) — ~$120/mo |

3-node cluster on **medium** ranges from €28/mo (Hetzner) to ~$180/mo (Azure).
Pricing is May 2026 list price, ex-VAT/tax. Each script prints a live cost
estimate from the provider's API before provisioning anything.

For workloads that don't fit small/medium/large, pass `--type` directly
with any provider-specific instance type (`--type cpx41`, `--type m5.large`,
`--type Standard_D4s_v5`, etc.).

## What every script does

1. **Validates** the provider's CLI is installed and authenticated
2. **Validates** your chosen region, instance type, and SSH key
3. **Resolves --size** to a concrete provider-specific instance type
4. **Estimates the monthly cost** of the cluster (provider's published price × N nodes)
5. **Asks for confirmation** (skip with `--yes`)
6. **Generates a cluster secret** (one per cluster, ephemeral, never persisted on your laptop)
7. **Provisions N VMs in parallel** — cloud-init writes the cluster secret to
   `/etc/wolfstack/custom-cluster-secret` on each, then runs `cloud-setup.sh`
   which sets the hostname and installs WolfStack via `setup.sh --yes`
8. **Polls** each node's `:8553` until WolfStack responds
9. **Auto-forms the cluster** — SSHes into each VM, fetches its `node_id`,
   builds a unified `nodes.json` with every peer (with `join_verified=true`),
   pushes it to all VMs, restarts `wolfstack` so the cluster polling loop
   discovers the topology
10. **Cleans up partial failures** — if VM 3 fails to launch, VMs 1 & 2
    are deleted automatically so you're not billed for orphans

Tear-down is a single command on every provider:

```bash
./bootstrap.sh --destroy --prefix wolfstack
```

This removes the VMs, security groups / firewall rules / NSGs, SSH keys,
and (on Azure) the entire resource group. Nothing is retained.

## Common options

Every script supports the same baseline flags:

| Flag | Purpose | Default |
|---|---|---|
| `--nodes N` | Number of VMs to create | `3` |
| `--prefix STR` | Hostname / tag prefix | `wolfstack` |
| `--region STR` | Provider-specific region/zone | varies |
| `--type STR` | Provider-specific VM size | varies |
| `--ssh-key PATH` | Public SSH key | auto-detected |
| `--beta` | Install WolfStack from beta branch | off |
| `--destroy` | Tear down resources matching the prefix | off |
| `--yes`, `-y` | Skip confirmation prompts | off |
| `--help`, `-h` | Show the script's full help | — |

Provider-specific flags are documented in each script's `--help`.

## Architecture

Each VM is configured via cloud-init to:

1. **`write_files`** pre-creates `/etc/wolfstack/custom-cluster-secret` with the
   cluster's shared secret (mode 0600). This must exist before WolfStack
   starts so inter-node `X-WolfStack-Secret` auth works.
2. **`runcmd`** fetches `cloud-setup.sh` from the WolfStack repo, which sets
   the hostname and runs `setup.sh --yes` non-interactively.

After all VMs are reachable on `:8553`, the bootstrap script SSHes into each
one to fetch its self-generated `/etc/wolfstack/node_id`, builds a unified
`nodes.json` containing every peer with `join_verified=true`, pushes it to
each VM, and restarts `wolfstack`. The cluster polling loop (every 10s)
takes over from there and the cluster forms itself within ~10 seconds.

This is functionally equivalent to manually pasting each node's join token
into the master's Add Node form — but automated end-to-end. If any node
fails to auto-join, the manual flow still works as a fallback (every node
still has its individual join token at `/etc/wolfstack/join-token`).

### Threat model note on the cluster secret

The cluster secret transits via the cloud provider's user-data store
briefly (cloud-init metadata). On every provider tested, that metadata is
owner-scoped, encrypted at rest by the provider, and removed when the VM
is destroyed. This is the same threat model anyone using cloud-init for
secrets accepts. For environments with strict regulatory requirements
(SOC2/HIPAA/PCI auditors who specifically forbid credentials in cloud-init
metadata), use the manual-token-paste flow — provision the VMs without
auto-join, then add each via the dashboard.

## Security notes

* **Credentials never leave your machine.** The scripts call into the
  provider CLI directly. Wolf Software Systems Ltd never sees, stores,
  or proxies your cloud credentials.
* **SSH keys** are uploaded to the provider's IAM/SSH-key service and
  reused. Generate a fresh key for cluster bootstrapping if you don't
  want your existing key associated with the cluster:
  `ssh-keygen -t ed25519 -f ~/.ssh/wolfstack-cluster -C "wolfstack-cluster"`
* **Default firewall rules** open the ports WolfStack needs (22, 8553,
  8554 TCP; 9600, 9601 UDP) to `0.0.0.0/0`. Lock these down to your
  office IP or the cluster's WireGuard bridge once it's live.
* **The dashboard uses a self-signed TLS certificate** by default; the
  scripts' health-check ignores cert errors. Switch to Let's Encrypt
  via the Certificates page once the cluster is up.

## Licence

This repo is licensed under the same dual-licence as WolfStack itself:
**PolyForm Noncommercial 1.0.0** for personal & non-commercial use, plus
a commercial licence granted automatically to active subscribers of any
WolfStack paid tier (Homelab, Team, MSP, Enterprise).

See [LICENSE](LICENSE) for the full text.

## Contributing

Bug reports and pull requests welcome. Adding a new provider follows the
same shape as the existing scripts — see [`hetzner/bootstrap.sh`](hetzner/bootstrap.sh)
as the canonical template, and `lib/common.sh` for the shared helpers.

Contributions are accepted under the same dual-licence terms via the
[Contributor Licence Agreement](https://github.com/wolfsoftwaresystemsltd/WolfStack/blob/master/CLA.md).
