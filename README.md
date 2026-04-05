# VVC BYOC Pod Injector

A config-driven Kubernetes MutatingWebhook that injects secrets, certificates, 
environment variables, and initContainers into Flink pods running on 
Ververica Cloud BYOC — without hardcoding, without code changes, without 
modifying the Ververica platform.

## Repository Structure

```
vvc-byoc-pod-injector/
├── build.sh                    # One-command build, push, and test
├── development/                # Internal — source code (do NOT share with customers)
│   ├── webhook-server/         
│   │   ├── main.go             # Config-driven Go webhook server
│   │   ├── go.mod              # Go dependencies
│   │   └── Dockerfile          # Multi-stage Docker build
│   ├── vvc-byoc-pod-injector.sh # Main deploy/manage script
│   ├── templates/              # Annotated config templates
│   ├── examples/               # Example configs (Streamzee, SASL, full kitchen sink)
│   └── README.md               # Internal documentation
├── distribution/               # Customer delivery (this is what they get)
│   ├── push-image.sh           # Pushes Docker image to customer's ECR
│   ├── vvc-byoc-pod-injector.sh # Deploy, add, remove, list, status, destroy
│   ├── injection-config.yaml   # Pre-filled for customer's auth method
│   ├── secrets.yaml            # Template — customer fills in passwords
│   └── README.md               # Customer-facing setup guide
├── docs/
│   └── vvc-byoc-pod-injector-guide.pptx  # 15-slide technical presentation
└── .gitignore
```

## Quick Start (Internal — Building & Testing)

```bash
# Place development.zip and distribution.zip in a Claude/ folder, then:
./build.sh eu-central-1
```

Or manually:

```bash
# Build the Docker image
cd development/webhook-server
docker build --platform linux/amd64 -t vvc-byoc-pod-injector:v1 .

# Export tarball for customer
docker save vvc-byoc-pod-injector:v1 -o distribution/vvc-byoc-pod-injector-v1.tar

# Package customer delivery
zip -j customer-delivery.zip distribution/*
```

## Customer Delivery

Send `customer-delivery.zip` (+ the Docker image tarball) to the customer.

They run:

```bash
# 1. Push image to their registry
./push-image.sh <region>

# 2. Edit secrets.yaml with real passwords, place cert files in folder

# 3. Deploy
./vvc-byoc-pod-injector.sh deploy \
  --webhook-image <URI_FROM_PUSH> \
  --config injection-config.yaml \
  --secrets secrets.yaml
```

## Authentication Support

| Auth Method | Flink SQL | JAR Deployment |
|-------------|-----------|----------------|
| SSL (mTLS, PEM) | Webhook alone | Webhook alone |
| SSL (mTLS, JKS) | Webhook + initContainer (JKS→PEM) | Webhook alone |
| SASL/PLAIN | Webhook + VVC Secret Values | Webhook alone |
| SASL/PLAIN + SSL | Webhook + initContainer + VVC Secret Values | Webhook alone |

## Tested On

- VVC BYOC AWS (EKS) — eu-central-1, ap-south-1
- VVC BYOC Azure (AKS)
- Coexists with Ververica Pyxis webhooks
- Multi-namespace with independent credentials

## Version History

| Version | Date | Changes |
|---------|------|---------|
| v1.0 | 2026-03-15 | Initial release — config-driven webhook, multi-namespace, AWS/Azure support |
