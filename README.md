# Azure sandbox — Terraform

Provisions the sandbox infrastructure for LLM inference experiments: one GPU
VM, persistent model storage, restricted networking, and an auto-shutdown
schedule.

---

## Decisions you need to make

Terraform cannot determine these. The first three are required and `apply` will
prompt for them if unset; the rest have defaults that may not suit you.

| # | Decision | Where | Notes |
|---|---|---|---|
| 1 | **Subscription ID** | `subscription_id` | The sandbox subscription. |
| 2 | **Corporate CIDR ranges** | `allowed_source_cidrs` | Which networks may reach SSH and port 8000. Validation rejects `0.0.0.0/0`. Ask Network or Security if you don't know the ranges. |
| 3 | **Cost centre code** | `cost_center` | Tagged on every resource for chargeback. |
| 4 | **Region** | `location` | Defaults to `germanywestcentral`. Must match the region where you hold NCADSH100v5 quota. |
| 5 | **VM SKU** | `vm_size` | Defaults to `Standard_NC40ads_H100_v5` (1× H100 NVL 94 GB). Must be in the NCADSH100v5 family. |
| 6 | **Encryption at host** | `encryption_at_host_enabled` | Defaults to false. See "Security items" below. |
| 7 | **Shutdown time** | `auto_shutdown_time` | Defaults to 19:00 Paris time. |

Two further items are outside Terraform entirely and are covered in
Prerequisites: **GPU quota approval** and **resource provider registration**.

---

## Prerequisites

### 1. Tools

```bash
terraform -version   # 1.9.0 or later
az version           # Azure CLI
az login
az account set --subscription "<subscription-id>"
```

### 2. SSH key

```bash
ls ~/.ssh/id_rsa.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

If you generate an ed25519 key, set `ssh_public_key_path` accordingly.

### 3. GPU quota — do this first, it is the long pole

Quota is an approval workflow, not a Terraform resource. The azurerm provider
has never supported it. Requests on GPU families often fall through to manual
support review, so file early.

Check what you currently hold:

```bash
az vm list-usage --location germanywestcentral -o table | grep -i "H100"
```

If the `Standard NCADSH100v5 Family vCPUs` limit is below 40, request an
increase in the portal under **Quotas → Compute**, selecting that family.
Justification text:

> AI R&D sandbox for internal LLM inference experiments. Single GPU VM,
> short-term pay-as-you-go, no production workloads, no customer data.

Do not run `apply` until quota is granted. It will fail.

### 4. Resource provider registration

The auto-shutdown schedule needs `Microsoft.DevTestLab`:

```bash
az provider register --namespace Microsoft.DevTestLab
az provider show --namespace Microsoft.DevTestLab --query registrationState
```

Wait for `Registered`. Alternatively set `auto_shutdown_enabled = false` and
manage deallocation yourself — but then nothing catches a forgotten VM.

### 5. Confirm the SKU exists and is unrestricted in your region

```bash
az vm list-skus --location germanywestcentral --size Standard_NC40ads_H100_v5 \
  --query "[].{name:name, restrictions:restrictions[].reasonCode}" -o table
```

An empty `restrictions` column means it is available to you.

---

## Usage

### First apply

```bash
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars — at minimum items 1-3 from the decisions table

terraform init
terraform plan     # read it; confirm the SKU and region are what you expect
terraform apply
```

Apply takes 3-5 minutes. Host bootstrap continues for a further 8-12 minutes
afterwards and ends with an automatic reboot, so the VM will briefly become
unreachable. That is expected.

### After apply

`terraform output post_apply_checklist` prints the sequence. In short:

```bash
ssh azureuser@$(terraform output -raw public_ip)

ls /var/lib/cloud/stack-bootstrap-complete   # bootstrap finished
sudo cat /var/log/stack-bootstrap.log        # if it did not
nvidia-smi                                   # GPU visible
df -h /models                                # persistent disk mounted

docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi

hf download Qwen/Qwen3.6-27B --local-dir /models/qwen36-27b
```

### Daily lifecycle

Compute billing stops on deallocate. The `/models` disk persists, so weights are
not re-downloaded.

```bash
az vm deallocate -g rg-gpuvm-sandbox -n vm-gpuvm-sandbox   # end of day
az vm start      -g rg-gpuvm-sandbox -n vm-gpuvm-sandbox   # next morning
```

Auto-shutdown at 19:00 is a backstop for when you forget, not a substitute for
deallocating when you finish.

### Teardown

```bash
terraform destroy
```

Destroys the model disk too. Copy anything you want to keep first.

---

## Security items to raise before applying

**Encryption at host requires a subscription feature registration.**

```bash
az feature register --namespace Microsoft.Compute --name EncryptionAtHost
az feature show --namespace Microsoft.Compute --name EncryptionAtHost \
  --query properties.state
```

Only set `encryption_at_host_enabled = true` once that reports `Registered`.
Enabling it otherwise fails the deployment. Data at rest is encrypted with
platform-managed keys regardless.

**The inference endpoint is unauthenticated.** vLLM on port 8000 has no auth
layer. The NSG is the only control, which is why `allowed_source_cidrs` is
required and why `0.0.0.0/0` is rejected.

---

## Design notes

**Why a separate model disk.** The SKU's local and temp storage is wiped on
deallocation. Since deallocating nightly is the main cost lever, weights on local
disk would mean re-downloading many GB every morning — enough friction that
you would stop deallocating, and the saving would evaporate. `/models` is a
managed disk that survives, and the format step is guarded so re-running never
destroys existing weights.

**Why CUDA 13.2 is blocked at the apt level.** That build is known to silently
corrupt model outputs on some workloads. The failure mode is wrong answers
rather than a crash, so an apt pin with priority -1 is safer than relying on
discipline.

**Why cloud-init rather than the GPU extension.** The `NvidiaGpuDriverLinux`
extension lags on new GPU generations. The bootstrap falls back through three
driver install strategies, so a wrong `nvidia_driver_branch` degrades rather
than fails.

**Why bootstrap is a script file.** cloud-init runs inline `runcmd` strings
through `sh`, not bash. `set -o pipefail` is not POSIX and would fail there.

---

## Not validated

This configuration has not been run through `terraform validate` or `plan`
against a live subscription. Run `terraform plan` and read it before applying.
