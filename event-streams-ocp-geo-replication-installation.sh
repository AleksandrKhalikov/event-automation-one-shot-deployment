#!/bin/sh

set -euo pipefail

# Event Streams Geo-Replication Setup Script for OpenShift
# This script sets up geo-replication between two Event Streams instances
# in the same OpenShift cluster:
# - Source cluster: Existing Event Streams instance (default: es-demo in tools namespace)
# - Destination cluster: New Event Streams instance in event-streams-geo-replication namespace
#
# References:
# - IBM Event Automation: https://ibm.github.io/event-automation/
# - Geo-Replication: https://ibm.github.io/event-automation/es/georeplication/about/
# - Setting up geo-replication: https://ibm.github.io/event-automation/es/georeplication/setting-up/

SCRIPT_NAME="$(basename "$0")"

# Default configuration
SOURCE_NAMESPACE="tools"
SOURCE_CLUSTER_NAME="es-demo"
DEST_NAMESPACE="event-streams-geo-replication"
DEST_CLUSTER_NAME="es-dest"
ENTITLEMENT_KEY=""
STORAGE_CLASS=""

print_usage() {
    cat <<EOF
${SCRIPT_NAME} - Event Streams Geo-Replication Setup for OpenShift

This script sets up geo-replication between two Event Streams instances in the same cluster:
- Source: Existing Event Streams instance (default: es-demo in tools namespace)
- Destination: New Event Streams instance in event-streams-geo-replication namespace

Usage:
  ${SCRIPT_NAME} [options]

Options:
  -s, --source-namespace NS    Source Event Streams namespace (default: ${SOURCE_NAMESPACE})
  -c, --source-cluster NAME     Source Event Streams cluster name (default: ${SOURCE_CLUSTER_NAME})
  -d, --dest-namespace NS      Destination namespace (default: ${DEST_NAMESPACE})
  -n, --dest-cluster NAME      Destination Event Streams cluster name (default: ${DEST_CLUSTER_NAME})
  -e, --entitlement-key KEY     IBM Entitlement key (from IBM Container Library)
  -t, --storage-class NAME      StorageClass for persistent storage (optional)
  -h, --help                    Show this help and exit

Prerequisites:
  - Logged into OpenShift as cluster-admin (run 'oc login' first)
  - Event Streams operator must be installed (via ibm_event_automation_oneshot_deployment.sh)
  - Source Event Streams instance must exist and be ready
  - IBM Entitlement key required for cp.icr.io image pulls

Example:
  ${SCRIPT_NAME} -e YOUR_ENTITLEMENT_KEY

Docs:
  - Geo-Replication: https://ibm.github.io/event-automation/es/georeplication/about/
  - Setting up: https://ibm.github.io/event-automation/es/georeplication/setting-up/
EOF
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--source-namespace)
            SOURCE_NAMESPACE="$2"; shift 2;;
        -c|--source-cluster)
            SOURCE_CLUSTER_NAME="$2"; shift 2;;
        -d|--dest-namespace)
            DEST_NAMESPACE="$2"; shift 2;;
        -n|--dest-cluster)
            DEST_CLUSTER_NAME="$2"; shift 2;;
        -e|--entitlement-key)
            ENTITLEMENT_KEY="$2"; shift 2;;
        -t|--storage-class)
            STORAGE_CLASS="$2"; shift 2;;
        -h|--help)
            print_usage; exit 0;;
        *)
            echo "Error: Unknown option: $1" 1>&2
            print_usage; exit 1;;
    esac
done

echo "============================================================"
echo "Event Streams Geo-Replication Setup"
echo "============================================================"
echo "Source Cluster: ${SOURCE_CLUSTER_NAME} (namespace: ${SOURCE_NAMESPACE})"
echo "Destination Cluster: ${DEST_CLUSTER_NAME} (namespace: ${DEST_NAMESPACE})"
echo ""

# Validate prerequisites
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: Missing required command: $1" 1>&2
        exit 1
    fi
}

echo "Checking prerequisites..."
require_cmd oc
require_cmd jq

if ! oc whoami >/dev/null 2>&1; then
    echo "Error: You are not logged in to OpenShift." 1>&2
    echo "Please run 'oc login' first." 1>&2
    exit 1
fi

# Check if source cluster exists
echo "Checking source Event Streams cluster..."
if ! oc get eventstreams "${SOURCE_CLUSTER_NAME}" -n "${SOURCE_NAMESPACE}" >/dev/null 2>&1; then
    echo "Error: Source Event Streams cluster '${SOURCE_CLUSTER_NAME}' not found in namespace '${SOURCE_NAMESPACE}'" 1>&2
    echo "Please ensure the source cluster exists and try again." 1>&2
    exit 1
fi

SOURCE_STATUS=$(oc get eventstreams "${SOURCE_CLUSTER_NAME}" -n "${SOURCE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
if [ "${SOURCE_STATUS}" != "True" ]; then
    echo "Warning: Source cluster '${SOURCE_CLUSTER_NAME}' is not in Ready state"
    echo "Current status: ${SOURCE_STATUS}"
    echo "Geo-replication may not work until the source cluster is Ready"
    read -p "Continue anyway? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        exit 1
    fi
fi

echo "✓ Source cluster found: ${SOURCE_CLUSTER_NAME}"

# Check if Event Streams operator is installed
echo "Checking Event Streams operator..."
OPERATOR_FOUND=false

# Check for CSV by display name (most reliable)
if oc get csv -n openshift-operators -o json 2>/dev/null | jq -r '.items[] | select(.spec.displayName | test("Event Streams"; "i")) | .metadata.name' 2>/dev/null | grep -q .; then
    OPERATOR_FOUND=true
fi

# Also check for Subscription (backup method)
if oc get subscription -n openshift-operators 2>/dev/null | grep -qi "eventstreams"; then
    OPERATOR_FOUND=true
fi

# Check for CSV by name pattern (backup method)
if oc get csv -n openshift-operators 2>/dev/null | grep -qi "eventstreams"; then
    OPERATOR_FOUND=true
fi

# Final check: verify operator can manage EventStreams CRD
if oc get crd eventstreams.eventstreams.ibm.com 2>/dev/null >/dev/null; then
    OPERATOR_FOUND=true
fi

if [ "${OPERATOR_FOUND}" = "false" ]; then
    echo "Error: Event Streams operator not found in openshift-operators namespace" 1>&2
    echo "" 1>&2
    echo "Debugging information:" 1>&2
    echo "  CSV list:" 1>&2
    oc get csv -n openshift-operators 2>/dev/null | grep -i event || echo "    (none found)" 1>&2
    echo "  Subscription list:" 1>&2
    oc get subscription -n openshift-operators 2>/dev/null | grep -i event || echo "    (none found)" 1>&2
    echo "" 1>&2
    echo "Please install Event Streams operator first using ibm_event_automation_oneshot_deployment.sh" 1>&2
    exit 1
fi
echo "✓ Event Streams operator is installed"

# Prompt for entitlement key
if [ -z "${ENTITLEMENT_KEY}" ]; then
    echo ""
    echo "Enter your IBM Entitlement key (from https://myibm.ibm.com/products-services/containerlibrary):"
    printf "Entitlement Key: "
    read ENTITLEMENT_KEY
fi

if [ -z "${ENTITLEMENT_KEY}" ]; then
    echo "Error: Entitlement key is required." 1>&2
    exit 1
fi

# Detect storage class
if [ -z "${STORAGE_CLASS}" ]; then
    STORAGE_CLASS=$(oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${STORAGE_CLASS}" ]; then
        echo "Warning: No default storage class found, using ephemeral storage"
    else
        echo "Using storage class: ${STORAGE_CLASS}"
    fi
fi

# Create entitlement secret function
create_entitlement_secret() {
    NS="$1"
    echo "Creating IBM entitlement secret in ${NS}..."
    # Check if secret already exists
    if oc get secret ibm-entitlement-key -n "$NS" >/dev/null 2>&1; then
        echo "  Secret already exists, updating..."
        oc -n "$NS" delete secret ibm-entitlement-key >/dev/null 2>&1 || true
    fi
    oc -n "$NS" create secret docker-registry ibm-entitlement-key \
        --docker-server=cp.icr.io \
        --docker-username=cp \
        --docker-password="${ENTITLEMENT_KEY}" \
        --docker-email="na@example.com" >/dev/null 2>&1 || \
    oc -n "$NS" create secret docker-registry ibm-entitlement-key \
        --docker-server=cp.icr.io \
        --docker-username=cp \
        --docker-password="${ENTITLEMENT_KEY}" \
        --docker-email="na@example.com" \
        --dry-run=client -o yaml | oc -n "$NS" apply -f - >/dev/null 2>&1
    
    # Link secret to service accounts
    for SA in default builder deployer; do
        oc patch serviceaccount "$SA" -n "$NS" --type merge \
            -p '{"imagePullSecrets":[{"name":"ibm-entitlement-key"}]}' >/dev/null 2>&1 || true
    done
}

# Function to wait for Event Streams to be ready
wait_for_eventstreams() {
    CLUSTER_NAME="$1"
    NS="$2"
    MAX_WAIT=1800  # 30 minutes
    COUNT=0
    
    echo "Waiting for Event Streams '${CLUSTER_NAME}' to be ready..."
    while [ $COUNT -lt $MAX_WAIT ]; do
        STATUS=$(oc get eventstreams "${CLUSTER_NAME}" -n "${NS}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "${STATUS}" = "True" ]; then
            echo "✓ Event Streams '${CLUSTER_NAME}' is Ready"
            return 0
        fi
        
        # Show progress every 30 seconds
        if [ $((COUNT % 30)) -eq 0 ] && [ $COUNT -gt 0 ]; then
            echo "  Still waiting... (${COUNT}/${MAX_WAIT} seconds)"
            oc get eventstreams "${CLUSTER_NAME}" -n "${NS}" -o jsonpath='{.status.conditions[*].type}:{.status.conditions[*].status}' 2>/dev/null | tr ',' '\n' || echo "  Status: Pending"
        fi
        
        sleep 5
        COUNT=$((COUNT + 5))
    done
    
    echo "⚠ Timeout waiting for Event Streams '${CLUSTER_NAME}' to be ready"
    echo "  Current status:"
    oc get eventstreams "${CLUSTER_NAME}" -n "${NS}" -o yaml | grep -A 10 "status:" || echo "  Status not available"
    return 1
}

# Step 1: Create destination namespace
echo ""
echo "============================================================"
echo "Step 1: Creating destination namespace"
echo "============================================================"
echo "Creating namespace ${DEST_NAMESPACE}..."
oc get ns "${DEST_NAMESPACE}" >/dev/null 2>&1 || oc new-project "${DEST_NAMESPACE}"
echo "✓ Namespace created"

# Step 2: Create entitlement secret
echo ""
echo "============================================================"
echo "Step 2: Creating entitlement secret"
echo "============================================================"
create_entitlement_secret "${DEST_NAMESPACE}"
echo "✓ Entitlement secret created"

# Step 3: Get license from source cluster or use default
echo ""
echo "============================================================"
echo "Step 3: Preparing Event Streams configuration"
echo "============================================================"
ES_LICENSE=$(oc get eventstreams "${SOURCE_CLUSTER_NAME}" -n "${SOURCE_NAMESPACE}" -o jsonpath='{.spec.license.license}' 2>/dev/null || echo "")
if [ -z "${ES_LICENSE}" ]; then
    ES_LICENSE="L-CYBH-K48BZQ"  # Default license
    echo "Using default license: ${ES_LICENSE}"
else
    echo "Using license from source cluster: ${ES_LICENSE}"
fi

# Step 4: Create destination Event Streams instance
echo ""
echo "============================================================"
echo "Step 4: Creating destination Event Streams instance"
echo "============================================================"
echo "Creating Event Streams instance '${DEST_CLUSTER_NAME}' in namespace '${DEST_NAMESPACE}'..."

oc apply -f - <<EOF
apiVersion: eventstreams.ibm.com/v1beta2
kind: EventStreams
metadata:
  name: ${DEST_CLUSTER_NAME}
  namespace: ${DEST_NAMESPACE}
  labels:
    backup.eventstreams.ibm.com/component: eventstreams
    eventstreams.ibm.com/cluster: ${DEST_CLUSTER_NAME}
spec:
  version: latest
  license:
    accept: true
    license: ${ES_LICENSE}
    use: EventAutomationNonProduction
  adminApi: {}
  adminUI:
    authentication:
      - type: scram-sha-512
  apicurioRegistry: {}
  collector: {}
  restProducer: {}
  security:
    internalTls: TLSv1.2
  strimziOverrides:
    kafka:
      authorization:
        type: simple
      config:
        offsets.topic.replication.factor: 1
        transaction.state.log.min.isr: 1
        transaction.state.log.replication.factor: 1
        auto.create.topics.enable: false
      listeners:
        - name: external
          port: 9094
          type: route
          tls: true
          authentication:
            type: scram-sha-512
        - name: tls
          port: 9093
          type: internal
          tls: true
          authentication:
            type: scram-sha-512
      metricsConfig:
        type: jmxPrometheusExporter
        valueFrom:
          configMapKeyRef:
            key: kafka-metrics-config.yaml
            name: ${DEST_CLUSTER_NAME}-metrics-config
    nodePools:
      - name: kafka
        replicas: 3
        storage:
$(if [ -z "${STORAGE_CLASS}" ]; then
  echo "          type: ephemeral"
else
  echo "          type: persistent-claim"
  echo "          class: ${STORAGE_CLASS}"
  echo "          size: 20Gi"
fi)
        roles:
          - broker
          - controller
EOF

echo "✓ Destination Event Streams instance created"
echo ""

# Check if destination cluster already exists and needs authorization
EXISTING_AUTH=$(oc get eventstreams "${DEST_CLUSTER_NAME}" -n "${DEST_NAMESPACE}" -o jsonpath='{.spec.strimziOverrides.kafka.authorization.type}' 2>/dev/null || echo "")
if [ -z "${EXISTING_AUTH}" ]; then
    echo "Updating existing destination cluster with authorization configuration..."
    oc patch eventstreams "${DEST_CLUSTER_NAME}" -n "${DEST_NAMESPACE}" --type='json' -p='[
        {
            "op": "add",
            "path": "/spec/strimziOverrides/kafka/authorization",
            "value": {
                "type": "simple"
            }
        }
    ]' 2>/dev/null || echo "Note: Authorization will be added when the instance is recreated"
fi

echo "Waiting for destination cluster to be ready..."
wait_for_eventstreams "${DEST_CLUSTER_NAME}" "${DEST_NAMESPACE}"

# Step 5: Update source Event Streams instance with authentication (if needed)
echo ""
echo "============================================================"
echo "Step 5: Configuring source cluster authentication"
echo "============================================================"
echo "Updating source Event Streams instance '${SOURCE_CLUSTER_NAME}' with authentication for geo-replication..."

# Check if source cluster already has authenticated listeners
# Check for ROUTE listener with SCRAM-SHA-512 auth
HAS_ROUTE_AUTH=$(oc get eventstreams "${SOURCE_CLUSTER_NAME}" -n "${SOURCE_NAMESPACE}" -o jsonpath='{.spec.strimziOverrides.kafka.listeners[?(@.type=="route")].authentication.type}' 2>/dev/null | grep -q "scram-sha-512" && echo "yes" || echo "")
# Check for INTERNAL listener with SCRAM-SHA-512 auth (TLS listener)
HAS_INTERNAL_AUTH=$(oc get eventstreams "${SOURCE_CLUSTER_NAME}" -n "${SOURCE_NAMESPACE}" -o jsonpath='{.spec.strimziOverrides.kafka.listeners[?(@.type=="internal" && @.tls==true)].authentication.type}' 2>/dev/null | grep -q "scram-sha-512" && echo "yes" || echo "")

if [ -z "${HAS_ROUTE_AUTH}" ] || [ -z "${HAS_INTERNAL_AUTH}" ]; then
    echo "Updating source cluster listeners to support geo-replication..."
    oc patch eventstreams "${SOURCE_CLUSTER_NAME}" -n "${SOURCE_NAMESPACE}" --type='json' -p='[
        {
            "op": "replace",
            "path": "/spec/security/internalTls",
            "value": "TLSv1.2"
        },
        {
            "op": "replace",
            "path": "/spec/adminUI",
            "value": {
                "authentication": [
                    {
                        "type": "scram-sha-512"
                    }
                ]
            }
        },
        {
            "op": "replace",
            "path": "/spec/strimziOverrides/kafka/authorization",
            "value": {
                "type": "simple"
            }
        },
        {
            "op": "replace",
            "path": "/spec/strimziOverrides/kafka/listeners",
            "value": [
                {
                    "name": "external",
                    "port": 9094,
                    "type": "route",
                    "tls": true,
                    "authentication": {
                        "type": "scram-sha-512"
                    }
                },
                {
                    "name": "tls",
                    "port": 9093,
                    "type": "internal",
                    "tls": true,
                    "authentication": {
                        "type": "scram-sha-512"
                    }
                }
            ]
        }
    ]'
    if [ $? -eq 0 ]; then
        echo "✓ Source cluster updated successfully"
        echo "Waiting for source cluster to reconcile (this may take a few minutes)..."
        # Wait for the cluster to be ready again after the change
        wait_for_eventstreams "${SOURCE_CLUSTER_NAME}" "${SOURCE_NAMESPACE}"
    else
        echo "⚠ Warning: Failed to patch source cluster. You may need to update it manually."
        echo "The source cluster must have:"
        echo "  - A ROUTE listener with SCRAM-SHA-512 authentication"
        echo "  - An INTERNAL TLS listener with SCRAM-SHA-512 authentication"
    fi
else
    echo "✓ Source cluster already has authenticated listeners configured"
fi

# Step 6: Create EventStreamsGeoReplicator
echo ""
echo "============================================================"
echo "Step 6: Setting up Geo-Replication"
echo "============================================================"
echo "Creating EventStreamsGeoReplicator resource..."

oc apply -f - <<EOF
apiVersion: eventstreams.ibm.com/v1beta1
kind: EventStreamsGeoReplicator
metadata:
  name: ${DEST_CLUSTER_NAME}
  namespace: ${DEST_NAMESPACE}
  labels:
    eventstreams.ibm.com/cluster: ${DEST_CLUSTER_NAME}
spec:
  version: latest
  replicas: 3
EOF

echo "✓ EventStreamsGeoReplicator created"
echo ""
echo "Geo-replication setup complete!"
echo ""

# Step 7: Display summary and next steps
echo "============================================================"
echo "GEO-REPLICATION SETUP COMPLETE"
echo "============================================================"
echo ""
echo "Configuration Summary:"
echo "  Source Cluster:"
echo "    Name: ${SOURCE_CLUSTER_NAME}"
echo "    Namespace: ${SOURCE_NAMESPACE}"
SOURCE_UI=$(oc get route ${SOURCE_CLUSTER_NAME}-ibm-es-ui -n "${SOURCE_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "${SOURCE_UI}" ]; then
    echo "    UI: https://${SOURCE_UI}"
fi
echo ""
echo "  Destination Cluster:"
echo "    Name: ${DEST_CLUSTER_NAME}"
echo "    Namespace: ${DEST_NAMESPACE}"
DEST_UI=$(oc get route ${DEST_CLUSTER_NAME}-ibm-es-ui -n "${DEST_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [ -n "${DEST_UI}" ]; then
    echo "    UI: https://${DEST_UI}"
fi
echo ""
echo "  Geo-Replicator:"
echo "    Name: ${DEST_CLUSTER_NAME}"
echo "    Namespace: ${DEST_NAMESPACE}"
echo ""
echo "============================================================"
echo "NEXT STEPS"
echo "============================================================"
echo ""
echo "1. Monitor geo-replication status:"
echo "   oc get eventstreamsgeoreplicator ${DEST_CLUSTER_NAME} -n ${DEST_NAMESPACE} -w"
echo ""
echo "2. Check geo-replication health:"
echo "   oc get eventstreamsgeoreplicator ${DEST_CLUSTER_NAME} -n ${DEST_NAMESPACE} -o yaml"
echo ""
echo "3. Configure topics to replicate:"
echo "   - Login to Event Streams UI (source cluster)"
echo "   - Navigate to Topics"
echo "   - Select topics you want to replicate"
echo "   - Use the 'Share' or 'Replicate' option to set up replication"
echo ""
echo "4. Verify replication:"
echo "   - Create a topic in the source cluster"
echo "   - Produce messages to the topic"
echo "   - Check if the topic appears in the destination cluster"
echo "   - Verify messages are replicated"
echo ""
echo "For more information:"
echo "  - Geo-Replication docs: https://ibm.github.io/event-automation/es/georeplication/about/"
echo "  - Setting up: https://ibm.github.io/event-automation/es/georeplication/setting-up/"
echo "  - Monitoring: https://ibm.github.io/event-automation/es/georeplication/health/"
echo ""
echo "============================================================"

