# Azure sandbox — Terraform

Provisions the sandbox infrastructure for LLM inference experiments: one GPU
VM, persistent model storage, restricted networking, and an auto-shutdown
schedule.

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

### 3. Resource provider registration

The auto-shutdown schedule needs `Microsoft.DevTestLab`:

```bash
az provider register --namespace Microsoft.DevTestLab
az provider show --namespace Microsoft.DevTestLab --query registrationState
```

Wait for `Registered`. Alternatively set `auto_shutdown_enabled = false` and
manage deallocation yourself — but then nothing catches a forgotten VM.

### 4. Confirm the SKU exists and is unrestricted in your region

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
# edit terraform.tfvars — at minimum items 1-2 from the decisions table

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

cd /opt/stack
docker compose up -d
docker compose ps
```

Open WebUI is available at `http://<public-ip>:3000`. The vLLM
OpenAI-compatible API is available at `http://<public-ip>:8000/v1`.

The root [compose.yaml](compose.yaml) mirrors the file created on the VM at
`/opt/stack/compose.yaml`. Both run vLLM with the `qwen36-27b` served model
name, Qwen3 reasoning parser, and Hermes tool-call parser.

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

**The inference endpoint is unauthenticated and public.** The temporary NSG
rule `allow-anywhere-temp` (priority 105) permits any IPv4 address to reach
ports 8000 (vLLM) and 3000 (Open WebUI). SSH is not allowed by a custom NSG
rule. Do not send sensitive prompts or expose this VM beyond the intended
temporary use.

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



