# VVC BYOC Pod Injector

A config-driven Kubernetes MutatingWebhook that injects secrets, files, environment variables, and initContainers into Flink pods running on Ververica Cloud BYOC. 

No hardcoded values. No code changes. Everything configured via YAML.

## How It Works

```
You write two YAML files:
  injection-config.yaml  →  WHAT to inject (env vars, volumes, mounts)
  secrets.yaml           →  WHERE the credentials/files come from

                    ┌─────────────────────────────┐
                    │ VVC creates a Flink pod      │
                    └──────────┬──────────────────┘
                               │
                    ┌──────────▼──────────────────┐
                    │ K8s API Server               │
                    │   → calls our webhook        │
                    └──────────┬──────────────────┘
                               │
                    ┌──────────▼──────────────────┐
                    │ vvc-byoc-pod-injector        │
                    │   reads ConfigMap            │
                    │   matches pod labels         │
                    │   patches pod spec:          │
                    │     + env vars from secrets  │
                    │     + volumes + mounts       │
                    │     + initContainers         │
                    └──────────┬──────────────────┘
                               │
                    ┌──────────▼──────────────────┐
                    │ Flink pod starts with        │
                    │ everything injected          │
                    └─────────────────────────────┘
```

## Quick Start

```bash
# 1. First-time deploy (auto-discovers namespace, builds image, deploys webhook)
./vvc-byoc-pod-injector.sh deploy \
  --config templates/injection-config.yaml \
  --secrets secrets.yaml \
  --region ap-south-1

# 2. Add another workspace
./vvc-byoc-pod-injector.sh add \
  --config templates/injection-config.yaml \
  --secrets secrets.yaml \
  --namespace <new-flink-namespace>

# 3. Check status
./vvc-byoc-pod-injector.sh status

# 4. List managed namespaces
./vvc-byoc-pod-injector.sh list

# 5. Remove a namespace
./vvc-byoc-pod-injector.sh remove --namespace <ns>

# 6. Destroy everything
./vvc-byoc-pod-injector.sh destroy
```

## Files

```
vvc-byoc-pod-injector/
├── vvc-byoc-pod-injector.sh    # Main script (deploy, add, remove, list, status, destroy)
├── webhook-server/
│   ├── main.go                  # Generic config-driven webhook (never edit)
│   ├── go.mod                   # Go dependencies
│   └── Dockerfile               # Multi-stage build
├── templates/
│   ├── injection-config.yaml    # Template: what to inject (edit this)
│   └── secrets.yaml             # Template: credentials and files (edit this)
├── examples/
│   ├── streamzee-kafka-ssl.yaml # Streamzee Kafka mTLS config
│   ├── streamzee-secrets.yaml   # Streamzee secrets
│   ├── kafka-sasl-ssl.yaml      # Kafka SASL_PLAIN + SSL config
│   └── full-kitchen-sink.yaml   # Everything: Kafka + DB + config + logging + init
└── README.md                    # This file
```

## Configuration

### injection-config.yaml — What to inject

```yaml
targeting:
  labels:
    system: ververica-platform    # Match Flink pods

envVars:                          # Env vars from K8s Secrets
  - name: KAFKA_PASSWORD          # Env var name in the pod
    secret: kafka-credentials     # K8s Secret name
    key: password                 # Key within the Secret

volumes:                          # Files mounted into pods
  - name: kafka-certs             # Volume name
    type: secret                  # "secret" or "configmap"
    source: kafka-tls-stores      # K8s Secret/ConfigMap name
    mountPath: /opt/certs         # Mount path in container
    readOnly: true
```

### secrets.yaml — Credentials and files

```yaml
secrets:
  kafka-credentials:              # Creates K8s Secret "kafka-credentials"
    literals:
      password: "my-password"
      username: "my-user"

  kafka-tls-stores:               # Creates K8s Secret "kafka-tls-stores"
    files:
      - key: truststore.jks       # Key name in the Secret
        path: ./truststore.jks    # Local file path
```

## Multi-Namespace

The webhook uses a label selector. Any namespace with the label gets injection:

```bash
# Deploy covers the first namespace automatically
./vvc-byoc-pod-injector.sh deploy --config ... --secrets ...

# Each "add" labels a new namespace and creates secrets in it
./vvc-byoc-pod-injector.sh add --namespace ns2 --config ... --secrets ...
./vvc-byoc-pod-injector.sh add --namespace ns3 --config ... --secrets ...

# Different namespaces can have different secrets
./vvc-byoc-pod-injector.sh add --namespace ns4 --config ... --secrets other-secrets.yaml
```

## Cloud Support

| Cloud | Image Registry | Auto-detected |
|-------|---------------|---------------|
| AWS   | ECR           | Yes           |
| Azure | ACR           | Yes           |
| Custom| Any / local   | Fallback      |

If ECR/ACR access is denied, the script automatically falls back to loading the image directly into cluster nodes — no registry needed.

## Verified On

| Detail | Value |
|--------|-------|
| VVC BYOC AWS (EKS) | Tested and working |
| VVC BYOC Azure (AKS) | Tested and working |
| Pod labels | `system=ververica-platform` (confirmed) |
| ServiceAccount | `flink-job-sa-vvc` |
| Coexists with | `0100-pyxis-mutating-webhook` |
| ResourceQuota | Handled (test pods include resource limits) |

## Troubleshooting

```bash
# Check webhook pods
kubectl get pods -n kube-system -l app=vvc-byoc-pod-injector

# Check webhook logs
kubectl logs -n kube-system -l app=vvc-byoc-pod-injector -f

# Check active config
./vvc-byoc-pod-injector.sh status

# Check if a namespace is managed
./vvc-byoc-pod-injector.sh list

# Check webhook registration
kubectl get mutatingwebhookconfiguration vvc-byoc-pod-injector -o yaml
```
