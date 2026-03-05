#!/bin/bash

# ==============================================================================
# DQC GKE Pilot Deployment Script
# Automates: API Enablement, GKE Autopilot, Workload Identity, 
# LiteLLM Proxy, and Redis Sidecar.
# ==============================================================================

# --- Configuration (UPDATE THESE) ---
export PROJECT_ID="your-dqc-project-id"
export REGION="us-central1"
export CLUSTER_NAME="dqc-pilot-cluster"
export GSA_NAME="dqc-app-sa"
export KSA_NAME="dqc-ksa"
export NAMESPACE="default"

# --- Colors for Output ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' 

echo -e "${BLUE}Starting DQC Pilot Deployment...${NC}"

# 1. Prerequisites Check
if [[ $PROJECT_ID == "your-dqc-project-id" ]]; then
    echo -e "${RED}Error: Please edit the script and set your PROJECT_ID.${NC}"
    exit 1
fi

# 2. Enable Google Cloud APIs
echo -e "${GREEN}1. Enabling Google Cloud APIs...${NC}"
gcloud services enable \
    container.googleapis.com \
    sqladmin.googleapis.com \
    storage.googleapis.com \
    dlp.googleapis.com \
    modelarmor.googleapis.com \
    redis.googleapis.com \
    --project=$PROJECT_ID

# 3. Create GKE Autopilot Cluster
echo -e "${GREEN}2. Creating GKE Autopilot Cluster (Estimated: 5-8 mins)...${NC}"
gcloud container clusters create-auto $CLUSTER_NAME \
    --region=$REGION \
    --project=$PROJECT_ID

# Get credentials
gcloud container clusters get-credentials $CLUSTER_NAME --region=$REGION --project=$PROJECT_ID

# 4. Setup Workload Identity
echo -e "${GREEN}3. Configuring Workload Identity (Keyless Auth)...${NC}"

# Create Google Service Account (GSA)
gcloud iam service-accounts create $GSA_NAME \
    --display-name="DQC Application Service Account" \
    --project=$PROJECT_ID || echo "GSA already exists, skipping creation."

# Allow KSA to impersonate GSA
gcloud iam service-accounts add-iam-policy-binding \
    $GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com \
    --role="roles/iam.workloadIdentityUser" \
    --member="serviceAccount:$PROJECT_ID.svc.id.goog[$NAMESPACE/$KSA_NAME]" \
    --project=$PROJECT_ID

# 5. Create Configuration & Manifests
echo -e "${GREEN}4. Generating Kubernetes Manifests...${NC}"

# LiteLLM Config with Semantic Caching & Model Armor
cat <<EOF > config.yaml
model_list:
  - model_name: dqc-secure-model
    litellm_params:
      model: vertex_ai/gemini-1.5-pro
      guardrails:
        - guardrail_name: model-armor-shield
          guardrail: model_armor
          mode: [pre_call, post_call]
          template_id: "dqc-security-template"
          project_id: "$PROJECT_ID"
          location: "$REGION"
          mask_request_content: true
          mask_response_content: true

router_settings:
  routing_strategy: "latency-based-routing"
  redis_host: "localhost" 
  redis_port: 6379

litellm_settings:
  cache: true
  cache_params:
    type: "redis"
    host: "localhost"
    port: 6379
  type: "semantic"
  set_verbose: true
EOF

# Kubernetes ConfigMap
kubectl create configmap litellm-config --from-file=config.yaml --dry-run=client -o yaml | kubectl apply -f -

# Deployment with Sidecar Pattern
cat <<EOF > litellm-pilot.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $KSA_NAME
  namespace: $NAMESPACE
  annotations:
    iam.gke.io/gcp-service-account: $GSA_NAME@$PROJECT_ID.iam.gserviceaccount.com
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: litellm-proxy
  namespace: $NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: litellm
  template:
    metadata:
      labels:
        app: litellm
    spec:
      serviceAccountName: $KSA_NAME
      containers:
      - name: litellm
        image: docker.litellm.ai/berriai/litellm:main-stable
        ports:
        - containerPort: 4000
        env:
        - name: LITELLM_CONFIG_PATH
          value: "/app/config/config.yaml"
        volumeMounts:
        - name: config-volume
          mountPath: /app/config
      - name: redis
        image: redis:alpine
        ports:
        - containerPort: 6379
      volumes:
      - name: config-volume
        configMap:
          name: litellm-config
---
apiVersion: v1
kind: Service
metadata:
  name: litellm-service
spec:
  selector:
    app: litellm
  ports:
    - protocol: TCP
      port: 80
      targetPort: 4000
  type: ClusterIP
EOF

# 6. Apply to GKE
echo -e "${GREEN}5. Applying Workloads to GKE...${NC}"
kubectl apply -f litellm-pilot.yaml

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}Deployment Completed Successfully!${NC}"
echo -e "${BLUE}Next Steps:${NC}"
echo -e "Ensure 'dqc-security-template' exists in Model Armor."
echo -e "${BLUE}====================================================${NC}"
