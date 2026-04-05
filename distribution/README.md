# VVC BYOC Pod Injector — Setup Guide

Automatically injects Kafka SSL credentials and certificates into your
Ververica Cloud BYOC Flink pods. No hardcoded secrets. No manual pod configuration.

## Prerequisites

- AWS CLI configured (`aws sts get-caller-identity` works)
- Docker running (Docker Desktop)
- kubectl connected to your EKS cluster
- python3 installed with pyyaml (`pip3 install pyyaml` or `brew install pyyaml`)
- A running Flink job in your VVC workspace (even a test datagen→blackhole job)
- Your `kafka-truststore.jks` and `kafka-keystore.jks` files

## Files

| File | What It Is | Edit? |
|------|-----------|-------|
| `vvc-byoc-pod-injector-v1.tar` | Pre-built webhook Docker image | No |
| `push-image.sh` | Pushes image to your ECR | No |
| `vvc-byoc-pod-injector.sh` | Main deployment script | No |
| `injection-config.yaml` | Defines what gets injected into pods | Only if mount paths change |
| `secrets.yaml` | Your passwords and file paths | **YES — fill in your values** |

## Setup (3 Steps)

### Step 1: Push the image to your ECR

```bash
chmod +x push-image.sh
./push-image.sh <your-region>
```

Example: `./push-image.sh ap-south-1`

This outputs your image URI. Copy it for the next step.

### Step 2: Edit secrets.yaml

Open `secrets.yaml` and replace the placeholder passwords with your actual values:

```yaml
secrets:
  kafka-credentials:
    literals:
      truststore_password: "YOUR_ACTUAL_TRUSTSTORE_PASSWORD"
      keystore_password: "YOUR_ACTUAL_KEYSTORE_PASSWORD"
```

Place your `kafka-truststore.jks` and `kafka-keystore.jks` files in the
same folder as this file.

### Step 3: Deploy

```bash
chmod +x vvc-byoc-pod-injector.sh
./vvc-byoc-pod-injector.sh deploy \
  --webhook-image <IMAGE_URI_FROM_STEP_1> \
  --config injection-config.yaml \
  --secrets secrets.yaml
```

That's it. The script auto-discovers your Flink namespace, creates the
Kubernetes secrets, deploys the webhook, and verifies injection.

## What Happens

Every Flink pod your VVC workspace creates will automatically get:

- `KAFKA_TRUSTSTORE_PASSWORD` environment variable
- `KAFKA_KEYSTORE_PASSWORD` environment variable
- `/opt/certs/kafka-truststore.jks` file
- `/opt/certs/kafka-keystore.jks` file

Your existing Flink job configuration stays exactly the same:

```yaml
ssl.truststore.location: "/opt/certs/kafka-truststore.jks"
ssl.truststore.password: "${KAFKA_TRUSTSTORE_PASSWORD}"
ssl.keystore.location: "/opt/certs/kafka-keystore.jks"
ssl.keystore.password: "${KAFKA_KEYSTORE_PASSWORD}"
```

## Adding More Workspaces

```bash
./vvc-byoc-pod-injector.sh add \
  --namespace <new-workspace-namespace> \
  --config injection-config.yaml \
  --secrets secrets.yaml
```

## Useful Commands

```bash
./vvc-byoc-pod-injector.sh list      # Show managed namespaces
./vvc-byoc-pod-injector.sh status    # Health check
./vvc-byoc-pod-injector.sh remove --namespace <ns>   # Remove a namespace
./vvc-byoc-pod-injector.sh destroy   # Remove everything
```

## Updating Passwords or Certificates

1. Edit `secrets.yaml` with new values
2. Replace the JKS files if changed
3. Re-run: `./vvc-byoc-pod-injector.sh add --namespace <ns> --config injection-config.yaml --secrets secrets.yaml`
4. Restart your Flink job to pick up new values

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `push-image.sh` access denied | Attach `AmazonEC2ContainerRegistryPowerUser` to your IAM user |
| `ModuleNotFoundError: yaml` | Run `pip3 install pyyaml` or `brew install pyyaml` |
| Pods show `ImagePullBackOff` | Check node role has `AmazonEC2ContainerRegistryReadOnly` |
| Env vars not injected | Run `./vvc-byoc-pod-injector.sh status` to check webhook health |
| No Flink pods found | Deploy a test Flink job in VVC first, then re-run |

## Support

Contact Ververica Technical Sales Engineering for assistance.
