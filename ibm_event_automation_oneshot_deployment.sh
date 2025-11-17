#!/bin/sh

set -euo pipefail

# IBM Event Automation one-shot installer for OpenShift
# Based on IBM official documentation and operator CatalogSource definitions
# References:
# - IBM Event Automation: https://ibm.github.io/event-automation/
# - IBM Cloud Pak for Integration: https://www.ibm.com/docs/en/cloud-paks/cp-integration
# - IBM Container Library: https://myibm.ibm.com/products-services/containerlibrary

SCRIPT_NAME="$(basename "$0")"

# Default configuration
NAMESPACE="tools"
ENTITLEMENT_KEY=""
STORAGE_CLASS=""
CP4I_VERSION="CD"  # CD (v16.1.1) or SC2 (v16.1.0 LTS)

# Components
INSTALL_NAV="true"  # Platform Navigator (console for CP4I components) - install first!
INSTALL_ES="true"   # Event Streams
INSTALL_EP="true"   # Event Processing (needs Flink first)
INSTALL_FLINK="true" # Apache Flink (prerequisite for EP)
INSTALL_EEM="true"  # Event Endpoint Management
INSTALL_MQ="false"  # IBM MQ
INSTALL_ACE="false" # AppConnect Enterprise
INSTALL_APIC="false" # API Connect

print_usage() {
    cat <<EOF
${SCRIPT_NAME} - IBM Event Automation Installer for OpenShift

Usage:
  ${SCRIPT_NAME} [options]

Options:
  -n, --namespace NAME       Target namespace (default: ${NAMESPACE})
  -e, --entitlement-key KEY  IBM Entitlement key (from IBM Container Library)
  -s, --storage-class NAME   StorageClass for persistent storage (optional)
  -v, --cp4i-version VER     CP4I version: CD or SC2 (default: ${CP4I_VERSION})
      --no-eem              Do not install Event Endpoint Management
      --no-ep               Do not install Event Processing
      --no-es               Do not install Event Streams
      --no-flink            Do not install Flink (required for EP if --no-flink used)
      --no-nav              Do not install Platform Navigator (console for CP4I)
      --install-mq          Install IBM MQ
      --install-ace         Install AppConnect Enterprise
      --install-apic        Install API Connect
  -h, --help                Show this help and exit

Prerequisites:
  - Logged into OpenShift as cluster-admin (run 'oc login' first)
  - IBM Operator Catalog will be installed automatically
  - Entitlement key required for cp.icr.io image pulls

Installation Order:
  1. Install IBM Operator Catalog in openshift-marketplace
  2. Install EA-specific CatalogSources (ES, EEM, EP, Flink)
  3. Install Operators via Subscriptions
  4. Create EA instances (ES, EP, EEM Manager, EEM Gateway)

Docs:
  - Event Automation: https://ibm.github.io/event-automation/
  - Cloud Pak for Integration: https://www.ibm.com/docs/en/cloud-paks/cp-integration
EOF
}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace)
            NAMESPACE="$2"; shift 2;;
        -e|--entitlement-key)
            ENTITLEMENT_KEY="$2"; shift 2;;
        -s|--storage-class)
            STORAGE_CLASS="$2"; shift 2;;
        -v|--cp4i-version)
            CP4I_VERSION="$2"; shift 2;;
        --no-eem)
            INSTALL_EEM="false"; shift 1;;
        --no-ep)
            INSTALL_EP="false"; shift 1;;
        --no-es)
            INSTALL_ES="false"; shift 1;;
        --no-flink)
            INSTALL_FLINK="false"; shift 1;;
        --no-nav)
            INSTALL_NAV="false"; shift 1;;
        --install-mq)
            INSTALL_MQ="true"; shift 1;;
        --install-ace)
            INSTALL_ACE="true"; shift 1;;
        --install-apic)
            INSTALL_APIC="true"; shift 1;;
        -h|--help)
            print_usage; exit 0;;
        *)
            echo "Error: Unknown option: $1" 1>&2
            print_usage; exit 1;;
    esac
done

echo "============================================================"
echo "IBM Event Automation Installer"
echo "============================================================"
echo "Namespace: ${NAMESPACE}"
echo "CP4I Version: ${CP4I_VERSION}"
echo "Components: ES=${INSTALL_ES} Flink=${INSTALL_FLINK} EP=${INSTALL_EP} EEM=${INSTALL_EEM} Navigator=${INSTALL_NAV} MQ=${INSTALL_MQ} ACE=${INSTALL_ACE} APIC=${INSTALL_APIC}"
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

if ! oc whoami >/dev/null 2>&1; then
    echo "Error: You are not logged in to OpenShift." 1>&2
    echo "Please run 'oc login' first." 1>&2
    exit 1
fi

# Prompt for entitlement key
if [ -z "${ENTITLEMENT_KEY}" ]; then
    echo "Enter your IBM Entitlement key (from https://myibm.ibm.com/products-services/containerlibrary):"
    printf "Entitlement Key: "
    read ENTITLEMENT_KEY
fi

if [ -z "${ENTITLEMENT_KEY}" ]; then
    echo "Error: Entitlement key is required." 1>&2
    exit 1
fi

# Create or verify namespace
echo ""
echo "Creating namespace ${NAMESPACE}..."
oc get ns "${NAMESPACE}" >/dev/null 2>&1 || oc new-project "${NAMESPACE}"

# Create entitlement secret
create_entitlement_secret() {
    NS="$1"
    echo "Creating IBM entitlement secret in ${NS}..."
    oc -n "$NS" create secret docker-registry ibm-entitlement-key \
        --docker-server=cp.icr.io \
        --docker-username=cp \
        --docker-password="${ENTITLEMENT_KEY}" \
        --docker-email="na@example.com" \
        --dry-run=client -o yaml | oc -n "$NS" apply -f - >/dev/null
    
    # Link secret to service accounts
    for SA in default builder deployer; do
        oc patch serviceaccount "$SA" -n "$NS" --type merge \
            -p '{"imagePullSecrets":[{"name":"ibm-entitlement-key"}]}' >/dev/null 2>&1 || true
    done
}

create_entitlement_secret "${NAMESPACE}"

# Detect storage class
if [ -z "${STORAGE_CLASS}" ]; then
    STORAGE_CLASS=$(oc get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
    if [ -z "${STORAGE_CLASS}" ]; then
        echo "Warning: No default storage class found, using ephemeral storage"
    else
        echo "Using storage class: ${STORAGE_CLASS}"
    fi
fi

# Function to wait for catalog source
wait_for_catalog() {
    CATALOG="$1"
    echo "Waiting for catalog ${CATALOG} to be ready..."
    while true; do
        STATE=$(oc get catalogsource "$CATALOG" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "NotReady")
        if [ "$STATE" = "READY" ]; then
            echo "✓ Catalog ${CATALOG} is ready"
            return 0
        fi
        sleep 5
    done
}

# Function to apply with retry
apply_with_retry() {
    local YAML_CONTENT="$(cat)"
    RETRIES=3
    COUNT=0
    while [ $COUNT -lt $RETRIES ]; do
        if echo "$YAML_CONTENT" | oc apply -f - 2>&1; then
            return 0
        fi
        COUNT=$((COUNT+1))
        if [ $COUNT -lt $RETRIES ]; then
            echo "Retry ${COUNT}/${RETRIES} after 10 seconds..."
            sleep 10
        fi
    done
    echo "⚠ Failed after ${RETRIES} retries"
    return 1
}

# Step 1: Install IBM Operator Catalog
echo ""
echo "============================================================"
echo "Step 1: Installing IBM Operator Catalog"
echo "============================================================"
echo "Installing IBM Operator Catalog in openshift-marketplace..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-operator-catalog
  namespace: openshift-marketplace
spec:
  displayName: IBM Operator Catalog
  image: icr.io/cpopen/ibm-operator-catalog:latest
  publisher: IBM
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 45m
EOF
wait_for_catalog "ibm-operator-catalog"

# Step 2: Install EA-specific CatalogSources (CD version)
if [ "${CP4I_VERSION}" = "CD" ]; then
    echo ""
    echo "============================================================"
    echo "Step 2: Installing Event Automation Catalog Sources (CD)"
    echo "============================================================"
    
    if [ "${INSTALL_ES}" = "true" ]; then
        echo "Installing Event Streams catalog..."
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-eventstreams
  namespace: openshift-marketplace
spec:
  displayName: ibm-eventstreams-12.0.2
  publisher: IBM
  image: icr.io/cpopen/ibm-eventstreams-catalog@sha256:3463090457277471b51e0f50890a744600b515a453fa32045bf77c98b65a6ddb
  sourceType: grpc
EOF
        wait_for_catalog "ibm-eventstreams"
    fi
    
    if [ "${INSTALL_EEM}" = "true" ]; then
        echo "Installing Event Endpoint Management catalog..."
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-eventendpointmanagement-catalog
  namespace: openshift-marketplace
spec:
  displayName: ibm-eventendpointmanagement-11.6.4
  publisher: IBM
  image: icr.io/cpopen/ibm-eventendpointmanagement-operator-catalog@sha256:b293422dbcabb76e48c9832b4b65b5f56a014fbd0b328b50c1b42476130772b0
  sourceType: grpc
EOF
        wait_for_catalog "ibm-eventendpointmanagement-catalog"
    fi
    
    if [ "${INSTALL_FLINK}" = "true" ]; then
        echo "Installing Apache Flink catalog..."
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-eventautomation-flink-catalog
  namespace: openshift-marketplace
spec:
  displayName: ibm-eventautomation-flink-1.4.4
  publisher: IBM
  image: icr.io/cpopen/ibm-eventautomation-flink-operator-catalog@sha256:764cddeab9d6547499088b1af9aeae0c250470df6a8c82566676d40a74a01900
  sourceType: grpc
EOF
        wait_for_catalog "ibm-eventautomation-flink-catalog"
    fi
    
    if [ "${INSTALL_EP}" = "true" ]; then
        echo "Installing Event Processing catalog..."
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-eventprocessing-catalog
  namespace: openshift-marketplace
spec:
  displayName: ibm-eventprocessing-1.4.4
  publisher: IBM
  image: icr.io/cpopen/ibm-eventprocessing-operator-catalog@sha256:15a43df8db1cf81e5cd9a3865ec2e94087ea5497a11dd83c0c13a88a9cf7c2f8
  sourceType: grpc
EOF
        wait_for_catalog "ibm-eventprocessing-catalog"
    fi
    
    # Install Platform Navigator catalog if requested
    if [ "${INSTALL_NAV}" = "true" ]; then
        echo "Installing Platform Navigator catalog..."
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-integration-platform-navigator-catalog
  namespace: openshift-marketplace
spec:
  displayName: ibm-integration-platform-navigator-8.1.3
  publisher: IBM
  image: icr.io/cpopen/ibm-integration-platform-navigator-catalog@sha256:c7817c4a57a0ccf1fe8e7e95d61efbcd54783239ebe95fddbb5815220762d410
  sourceType: grpc
EOF
        wait_for_catalog "ibm-integration-platform-navigator-catalog"
    fi
    
    # Install MQ catalog if requested
    if [ "${INSTALL_MQ}" = "true" ]; then
        echo "Installing IBM MQ catalog..."
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibmmq-operator-catalogsource
  namespace: openshift-marketplace
spec:
  displayName: ibm-mq-3.7.1
  publisher: IBM
  image: icr.io/cpopen/ibm-mq-operator-catalog@sha256:216871e1c0268fb53fb66b92d73ce81bf1386ed3f245582f9580ce1386dfcda6
  sourceType: grpc
EOF
        wait_for_catalog "ibmmq-operator-catalogsource"
    fi
    
    # Install AppConnect Enterprise catalog if requested
    if [ "${INSTALL_ACE}" = "true" ]; then
        echo "Installing AppConnect Enterprise catalog..."
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: appconnect-operator-catalogsource
  namespace: openshift-marketplace
spec:
  displayName: ibm-appconnect-12.16.0
  publisher: IBM
  image: icr.io/cpopen/appconnect-operator-catalog@sha256:3941262c1a0e13809c962f1ea42c8c2f2afc2ec03f95bf364c5abebce6bb1784
  sourceType: grpc
EOF
        wait_for_catalog "appconnect-operator-catalogsource"
    fi
    
    # Install API Connect catalog if requested (using ibm-operator-catalog for 10.0.11.0)
    if [ "${INSTALL_APIC}" = "true" ]; then
        echo "Installing API Connect catalog (version 10.0.11.0)..."
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-apiconnect-catalog
  namespace: openshift-marketplace
spec:
  displayName: ibm-apiconnect-catalog
  publisher: IBM
  image: icr.io/cpopen/ibm-operator-catalog:latest
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 30m0s
EOF
        wait_for_catalog "ibm-apiconnect-catalog"
    fi
else
    echo "Error: SC2 version catalog sources not implemented yet. Use CP4I_VERSION=CD"
    exit 1
fi

# Step 3: Install Operators
echo ""
echo "============================================================"
echo "Step 3: Installing Operators"
echo "============================================================"

# Function to wait for CSV
wait_for_csv() {
    PKG="$1"; LAST_PHASE=""; TICK=0
    echo "Waiting for ${PKG} operator..."
    while true; do
        CSV_NAME=$(oc get subscription "$PKG" -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
        if [ -n "$CSV_NAME" ]; then
            PHASE=$(oc get csv "$CSV_NAME" -n openshift-operators -o jsonpath='{.status.phase}' 2>/dev/null || true)
            if [ "$PHASE" = "Succeeded" ]; then
                echo "✓ ${PKG} operator is ready"
                return 0
            fi
            if [ "$PHASE" != "$LAST_PHASE" ] && [ -n "$PHASE" ]; then
                echo "  CSV phase: $PHASE"
                LAST_PHASE="$PHASE"
            fi
        fi
        TICK=$((TICK+1))
        if [ $((TICK % 12)) -eq 0 ]; then
            echo "  Still waiting..."
        fi
        sleep 10
    done
}

# Install Flink first (prerequisite for EP)
if [ "${INSTALL_FLINK}" = "true" ]; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-eventautomation-flink
  namespace: openshift-operators
spec:
  channel: v1.4
  name: ibm-eventautomation-flink
  source: ibm-eventautomation-flink-catalog
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    wait_for_csv "ibm-eventautomation-flink"
fi

# Install Event Streams
if [ "${INSTALL_ES}" = "true" ]; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-eventstreams
  namespace: openshift-operators
spec:
  channel: v12.0
  name: ibm-eventstreams
  source: ibm-eventstreams
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    wait_for_csv "ibm-eventstreams"
fi

# Install Event Endpoint Management
if [ "${INSTALL_EEM}" = "true" ]; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-eventendpointmanagement
  namespace: openshift-operators
spec:
  channel: v11.6
  name: ibm-eventendpointmanagement
  source: ibm-eventendpointmanagement-catalog
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    wait_for_csv "ibm-eventendpointmanagement"
fi

# Install Event Processing
if [ "${INSTALL_EP}" = "true" ]; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-eventprocessing
  namespace: openshift-operators
spec:
  channel: v1.4
  name: ibm-eventprocessing
  source: ibm-eventprocessing-catalog
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    wait_for_csv "ibm-eventprocessing"
fi

# Install Platform Navigator operator if requested
if [ "${INSTALL_NAV}" = "true" ]; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-integration-platform-navigator
  namespace: openshift-operators
spec:
  channel: v8.1
  name: ibm-integration-platform-navigator
  source: ibm-integration-platform-navigator-catalog
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    wait_for_csv "ibm-integration-platform-navigator"
fi

# Install IBM MQ operator if requested
if [ "${INSTALL_MQ}" = "true" ]; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-mq
  namespace: openshift-operators
spec:
  channel: v3.7
  name: ibm-mq
  source: ibmmq-operator-catalogsource
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    wait_for_csv "ibm-mq"
fi

# Install AppConnect Enterprise operator if requested
if [ "${INSTALL_ACE}" = "true" ]; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-appconnect
  namespace: openshift-operators
spec:
  channel: v12.16
  name: ibm-appconnect
  source: appconnect-operator-catalogsource
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    wait_for_csv "ibm-appconnect"
fi

# Install DataPower Gateway operator (required for APIC)
if [ "${INSTALL_APIC}" = "true" ]; then
    echo "Installing DataPower Gateway operator (required for API Connect)..."
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: datapower-operator
  namespace: openshift-operators
spec:
  channel: v1.16
  name: datapower-operator
  source: ibm-operator-catalog
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    wait_for_csv "datapower-operator"
fi

# Install API Connect operator if requested
if [ "${INSTALL_APIC}" = "true" ]; then
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ibm-apiconnect
  namespace: openshift-operators
spec:
  channel: v6.1
  name: ibm-apiconnect
  source: ibm-apiconnect-catalog
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF
    wait_for_csv "ibm-apiconnect"
fi

# Step 4: Create instances
echo ""
echo "============================================================"
echo "Step 4: Creating Component Instances"
echo "============================================================"

# Create Platform Navigator instance first (console for all components)
if [ "${INSTALL_NAV}" = "true" ]; then
    echo "Creating Platform Navigator instance..."
    # Get license from CSV
    NAV_CSV_NAME=$(oc get subscription ibm-integration-platform-navigator -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    NAV_LIC=""
    NAV_VER=""
    if [ -n "${NAV_CSV_NAME}" ]; then
        NAV_LIC=$(oc get csv "${NAV_CSV_NAME}" -n openshift-operators -o json | jq -r '.metadata.annotations."alm-examples" | fromjson | [.[] | select(.kind == "PlatformNavigator")] | .[] | select(.metadata.name == "integration-quickstart") | .spec.license.license' 2>/dev/null || echo "")
        NAV_VER=$(oc get csv "${NAV_CSV_NAME}" -n openshift-operators -o json | jq -r '.metadata.annotations."alm-examples" | fromjson | [.[] | select(.kind == "PlatformNavigator")] | .[] | select(.metadata.name == "integration-quickstart") | .spec.version' 2>/dev/null || echo "")
    fi
    if [ -z "${NAV_LIC}" ]; then
        NAV_LIC="L-PLYA-C5PY42"  # Default license
    fi
    if [ -z "${NAV_VER}" ]; then
        NAV_VER="2024.4.1"  # Default version
    fi
    
    apply_with_retry <<EOF
apiVersion: integration.ibm.com/v1beta1
kind: PlatformNavigator
metadata:
  name: cp4i-navigator
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: ${NAV_LIC}
  replicas: 1
  version: ${NAV_VER}
  integrationAssistant:
    enabled: true
EOF
    echo "✓ Platform Navigator instance created"
fi

# Create Event Streams instance
if [ "${INSTALL_ES}" = "true" ]; then
    echo "Creating Event Streams instance..."
    oc apply -f - <<EOF
apiVersion: eventstreams.ibm.com/v1beta2
kind: EventStreams
metadata:
  name: es-demo
  namespace: ${NAMESPACE}
  labels:
    backup.eventstreams.ibm.com/component: eventstreams
spec:
  version: latest
  license:
    accept: true
    license: L-CYBH-K48BZQ
    use: EventAutomationNonProduction
  adminApi: {}
  adminUI: {}
  apicurioRegistry: {}
  collector: {}
  restProducer: {}
  security:
    internalTls: NONE
  strimziOverrides:
    kafka:
      config:
        offsets.topic.replication.factor: 1
        transaction.state.log.min.isr: 1
        transaction.state.log.replication.factor: 1
        auto.create.topics.enable: false
        min.insync.replicas: 2
        default.replication.factor: 3
      listeners:
        - name: plain
          port: 9092
          type: internal
          tls: false
      metricsConfig:
        type: jmxPrometheusExporter
        valueFrom:
          configMapKeyRef:
            key: kafka-metrics-config.yaml
            name: es-demo-metrics-config
    nodePools:
      - name: kafka
        replicas: 3
        storage:
          type: ephemeral
        roles:
          - broker
          - controller
EOF
    echo "✓ Event Streams instance created"
fi

# Create Flink instance (prerequisite for EP)
if [ "${INSTALL_FLINK}" = "true" ] && [ "${INSTALL_EP}" = "true" ]; then
    echo "Creating Apache Flink instance (prerequisite for Event Processing)..."
    # Create flink serviceAccount if it doesn't exist
    oc get serviceaccount flink -n "${NAMESPACE}" >/dev/null 2>&1 || oc create serviceaccount flink -n "${NAMESPACE}"
    apply_with_retry <<EOF
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata:
  name: ea-flink-demo
  namespace: ${NAMESPACE}
spec:
  flinkConfiguration:
    license.accept: 'true'
    license.license: L-CYBH-K48BZQ
    license.use: EventAutomationNonProduction
    taskmanager.numberOfTaskSlots: '2'
  serviceAccount: flink
  mode: native
  jobManager:
    resource:
      memory: 2048m
      cpu: 1
  taskManager:
    resource:
      memory: 2048m
      cpu: 1
EOF
    echo "✓ Apache Flink instance created"
fi

# Create Event Processing instance
if [ "${INSTALL_EP}" = "true" ]; then
    echo "Creating Event Processing instance..."
    if [ -n "${STORAGE_CLASS}" ]; then
        oc apply -f - <<EOF
apiVersion: events.ibm.com/v1beta1
kind: EventProcessing
metadata:
  name: ep-demo
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: L-CYBH-K48BZQ
    use: EventAutomationNonProduction
  flink:
    endpoint: 'ea-flink-demo-rest:8081'
  authoring:
    authConfig:
      authType: LOCAL
    storage:
      storageClassName: ${STORAGE_CLASS}
      type: persistent-claim
      size: 100M
EOF
    else
        oc apply -f - <<EOF
apiVersion: events.ibm.com/v1beta1
kind: EventProcessing
metadata:
  name: ep-demo
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: L-CYBH-K48BZQ
    use: EventAutomationNonProduction
  flink:
    endpoint: 'ea-flink-demo-rest:8081'
  authoring:
    authConfig:
      authType: LOCAL
    storage:
      type: ephemeral
      size: 100M
EOF
    fi
    echo "✓ Event Processing instance created"
fi

# Create Event Endpoint Management Manager
if [ "${INSTALL_EEM}" = "true" ]; then
    echo "Creating Event Endpoint Management Manager instance..."
    if [ -n "${STORAGE_CLASS}" ]; then
        oc apply -f - <<EOF
apiVersion: events.ibm.com/v1beta1
kind: EventEndpointManagement
metadata:
  name: eem-demo-mgr
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: L-CYPF-CRPF3H
    metric: VIRTUAL_PROCESSOR_CORE
    use: CloudPakForIntegrationNonProduction
  manager:
    authConfig:
      authType: LOCAL
    storage:
      storageClassName: ${STORAGE_CLASS}
      type: persistent-claim
EOF
    else
        oc apply -f - <<EOF
apiVersion: events.ibm.com/v1beta1
kind: EventEndpointManagement
metadata:
  name: eem-demo-mgr
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: L-CYPF-CRPF3H
    metric: VIRTUAL_PROCESSOR_CORE
    use: CloudPakForIntegrationNonProduction
  manager:
    authConfig:
      authType: LOCAL
    storage:
      type: ephemeral
EOF
    fi
    echo "✓ EEM Manager instance created"
    
    # Create EEM Gateway (needs manager to be ready first)
    echo "Creating Event Endpoint Management Gateway instance..."
    # Get the EEM Manager Gateway route
    EEM_GATEWAY_ROUTE=$(oc get route eem-demo-mgr-ibm-eem-gateway -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -z "${EEM_GATEWAY_ROUTE}" ]; then
        echo "  Warning: EEM Gateway route not found, using service DNS instead"
        EEM_GATEWAY_ROUTE="eem-demo-mgr-ibm-eem-gateway.${NAMESPACE}.svc"
    fi
    
    if [ -n "${STORAGE_CLASS}" ]; then
        oc apply -f - <<EOF
apiVersion: events.ibm.com/v1beta1
kind: EventGateway
metadata:
  name: eem-demo-gw
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: L-CYPF-CRPF3H
    metric: VIRTUAL_PROCESSOR_CORE
    use: CloudPakForIntegrationNonProduction
  managerEndpoint: https://${EEM_GATEWAY_ROUTE}
  gatewayGroupName: egw-group
  gatewayID: egw-1
  tls:
    caSecretName: eem-demo-mgr-ibm-eem-manager-ca
  gateway:
    replicas: 1
    storage:
      storageClassName: ${STORAGE_CLASS}
      type: persistent-claim
EOF
    else
        oc apply -f - <<EOF
apiVersion: events.ibm.com/v1beta1
kind: EventGateway
metadata:
  name: eem-demo-gw
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: L-CYPF-CRPF3H
    metric: VIRTUAL_PROCESSOR_CORE
    use: CloudPakForIntegrationNonProduction
  managerEndpoint: https://${EEM_GATEWAY_ROUTE}
  gatewayGroupName: egw-group
  gatewayID: egw-1
  tls:
    caSecretName: eem-demo-mgr-ibm-eem-manager-ca
  gateway:
    replicas: 1
    storage:
      type: ephemeral
EOF
    fi
    echo "✓ EEM Gateway instance created"
fi

# Create IBM MQ instance
if [ "${INSTALL_MQ}" = "true" ]; then
    echo "Creating IBM MQ instance..."
    # Get license and version from CSV
    MQ_CSV_NAME=$(oc get subscription ibm-mq -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    MQ_LIC=""
    MQ_VER=""
    if [ -n "${MQ_CSV_NAME}" ]; then
        MQ_LIC=$(oc get csv "${MQ_CSV_NAME}" -n openshift-operators -o json | jq -r '.metadata.annotations."alm-examples" | fromjson | [.[] | select(.kind == "QueueManager")] | .[] | select(.metadata.name == "quickstart-cp4i") | .spec.license.license' 2>/dev/null || echo "")
        MQ_VER=$(oc get csv "${MQ_CSV_NAME}" -n openshift-operators -o json | jq -r '.metadata.annotations."alm-examples" | fromjson | [.[] | select(.kind == "QueueManager")] | .[] | select(.metadata.name == "quickstart-cp4i") | .spec.version' 2>/dev/null || echo "")
    fi
    if [ -z "${MQ_LIC}" ]; then
        MQ_LIC="L-CYPF-CRPF3H"  # Default license
    fi
    if [ -z "${MQ_VER}" ]; then
        MQ_VER="9.4.4.0-r1"  # Default version for CD
    fi
    
    MQ_STORAGE="storageClassName: ${STORAGE_CLASS}"
    if [ -z "${STORAGE_CLASS}" ]; then
        MQ_STORAGE="type: ephemeral"
    else
        MQ_STORAGE="type: persistent-claim
      storageClassName: ${STORAGE_CLASS}"
    fi
    
    oc apply -f - <<EOF
apiVersion: mq.ibm.com/v1beta1
kind: QueueManager
metadata:
  name: qmgr-demo
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: ${MQ_LIC}
    use: NonProduction
  queueManager:
    name: QMGRDEMO
    storage:
      queueManager:
        ${MQ_STORAGE}
    availability:
      type: SingleInstance
  version: ${MQ_VER}
  web:
    enabled: true
EOF
    echo "✓ IBM MQ instance created"
fi

# Create AppConnect Enterprise Dashboard instance
if [ "${INSTALL_ACE}" = "true" ]; then
    echo "Creating AppConnect Enterprise Dashboard instance..."
    # Get license and version from CSV
    ACE_CSV_NAME=$(oc get subscription ibm-appconnect -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    ACE_LIC=""
    ACE_VER=""
    if [ -n "${ACE_CSV_NAME}" ]; then
        ACE_LIC=$(oc get csv "${ACE_CSV_NAME}" -n openshift-operators -o json | jq -r '.metadata.annotations."alm-examples" | fromjson | [.[] | select(.kind == "Dashboard")] | .[] | select(.metadata.name == "db-01-quickstart") | .spec.license.license' 2>/dev/null || echo "")
        ACE_VER=$(oc get csv "${ACE_CSV_NAME}" -n openshift-operators -o json | jq -r '.metadata.annotations."alm-examples" | fromjson | [.[] | select(.kind == "Dashboard")] | .[] | select(.metadata.name == "db-01-quickstart") | .spec.version' 2>/dev/null || echo "")
    fi
    if [ -z "${ACE_LIC}" ]; then
        ACE_LIC="L-KPRV-AUG9NC"  # Default license
    fi
    if [ -z "${ACE_VER}" ]; then
        ACE_VER="13.0"  # Default version (string format)
    fi
    
    if [ -z "${STORAGE_CLASS}" ]; then
        ACE_STORAGE="type: ephemeral"
    else
        ACE_STORAGE="type: persistent-claim
    class: ${STORAGE_CLASS}
    size: 5Gi"
    fi
    
    oc apply -f - <<EOF
apiVersion: appconnect.ibm.com/v1beta1
kind: Dashboard
metadata:
  name: ace-demo-dashboard
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: ${ACE_LIC}
    use: CloudPakForIntegrationNonProduction
  replicas: 1
  storage:
    ${ACE_STORAGE}
  version: '${ACE_VER}'
  api:
    enabled: true
EOF
    echo "✓ AppConnect Enterprise Dashboard instance created"
fi

# Create API Connect instance
if [ "${INSTALL_APIC}" = "true" ]; then
    echo "Creating API Connect instance..."
    # Get license and version from CSV
    APIC_CSV_NAME=$(oc get subscription ibm-apiconnect -n openshift-operators -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    APIC_LIC=""
    APIC_VER=""
    if [ -n "${APIC_CSV_NAME}" ]; then
        APIC_LIC=$(oc get csv "${APIC_CSV_NAME}" -n openshift-operators -o json | jq -r '.metadata.annotations."alm-examples" | fromjson | [.[] | select(.kind == "APIConnectCluster")] | .[0] | .spec.license.license' 2>/dev/null || echo "")
        APIC_VER=$(oc get csv "${APIC_CSV_NAME}" -n openshift-operators -o json | jq -r '.metadata.annotations."alm-examples" | fromjson | [.[] | select(.kind == "APIConnectCluster")] | .[0] | .spec.version' 2>/dev/null || echo "")
    fi
    if [ -z "${APIC_LIC}" ]; then
        APIC_LIC="L-KYAL-S3RCBM"  # Default license for 10.0.11.0
    fi
    if [ -z "${APIC_VER}" ]; then
        APIC_VER="10.0.11.0"  # Default version (latest)
    fi
    
    # Build storageClassName line conditionally
    APIC_STORAGE_LINE=""
    if [ -n "${STORAGE_CLASS}" ]; then
        APIC_STORAGE_LINE="  storageClassName: ${STORAGE_CLASS}"
    fi
    
    oc apply -f - <<EOF
apiVersion: apiconnect.ibm.com/v1beta1
kind: APIConnectCluster
metadata:
  name: apic-demo
  namespace: ${NAMESPACE}
spec:
  license:
    accept: true
    license: ${APIC_LIC}
    metric: VIRTUAL_PROCESSOR_CORE
    use: nonproduction
  profile: n1xc16.m72
  version: ${APIC_VER}
${APIC_STORAGE_LINE}
  management:
    discovery:
      enabled: true
    governance:
      enabled: true
    testAndMonitor:
      enabled: true
EOF
    echo "✓ API Connect instance created"
fi

# Wait for instances to become ready
echo ""
echo "============================================================"
echo "Waiting for instances to be ready..."
echo "============================================================"

wait_for_cr() {
    KIND="$1"; NAME="$2"; NS="$3"; MAX_WAIT=120
    COUNT=0
    while [ $COUNT -lt $MAX_WAIT ]; do
        # For FlinkDeployment, check lifecycleState instead of phase
        if [ "$KIND" = "flinkdeployment" ]; then
            PHASE=$(oc get "$KIND" "$NAME" -n "$NS" -o jsonpath='{.status.lifecycleState}' 2>/dev/null || echo "Pending")
            if [ "$PHASE" = "STABLE" ]; then
                echo "✓ ${KIND}/${NAME} is ${PHASE}"
                return 0
            fi
        # For PlatformNavigator, check for Ready condition
        elif [ "$KIND" = "platformnavigator" ]; then
            READY=$(oc get "$KIND" "$NAME" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
            if [ "$READY" = "True" ]; then
                echo "✓ ${KIND}/${NAME} is Ready"
                return 0
            fi
            PHASE="Pending"
        else
            PHASE=$(oc get "$KIND" "$NAME" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
            if [ "$PHASE" = "Ready" ] || [ "$PHASE" = "Running" ] || [ "$PHASE" = "Online" ]; then
                echo "✓ ${KIND}/${NAME} is ${PHASE}"
                return 0
            fi
        fi
        if [ $((COUNT % 12)) -eq 0 ]; then
            echo "  ${KIND}/${NAME} state: ${PHASE}..."
        fi
        COUNT=$((COUNT+1))
        sleep 10
    done
    echo "⚠ ${KIND}/${NAME} still starting (state: ${PHASE})"
}

# Wait for Platform Navigator first (if installed) so console is available
if [ "${INSTALL_NAV}" = "true" ]; then
    wait_for_cr "platformnavigator" "cp4i-navigator" "${NAMESPACE}" || true
fi

if [ "${INSTALL_ES}" = "true" ]; then
    wait_for_cr "eventstreams" "es-demo" "${NAMESPACE}" || true
    
    # Configure Event Streams for UI credential generation
    echo ""
    echo "============================================================"
    echo "Configuring Event Streams for UI Credential Generation"
    echo "============================================================"
    
    CLUSTER_NAME="es-demo"
    ADMIN_UI_DEPLOYMENT="${CLUSTER_NAME}-ibm-es-ui"
    SERVICE_ACCOUNT="${CLUSTER_NAME}-ibm-es-ui"
    ROLE_NAME="${CLUSTER_NAME}-ibm-es-ui"
    KAFKA_USER="es-admin"
    
    # Wait for adminUI deployment to exist
    echo "Waiting for adminUI deployment to be ready..."
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if oc get deployment "${ADMIN_UI_DEPLOYMENT}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            echo "✓ AdminUI deployment found"
            break
        fi
        if [ $i -lt 12 ]; then
            sleep 10
        fi
    done
    
    # Step 1: Create RBAC permissions for adminUI service account to create KafkaUser resources
    echo "Creating RBAC permissions for adminUI service account..."
    oc apply -f - <<EOF >/dev/null 2>&1
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}-kafkauser
  namespace: ${NAMESPACE}
rules:
- apiGroups:
  - eventstreams.ibm.com
  resources:
  - kafkausers
  verbs:
  - create
  - get
  - list
  - update
  - patch
  - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${ROLE_NAME}-kafkauser
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${ROLE_NAME}-kafkauser
subjects:
- kind: ServiceAccount
  name: ${SERVICE_ACCOUNT}
  namespace: ${NAMESPACE}
EOF
    echo "✓ RBAC permissions created"
    
    # Step 2: Create or update es-admin KafkaUser with explicit permissions
    echo "Creating es-admin KafkaUser with explicit permissions..."
    
    # Check if KafkaUser already exists
    if oc get kafkauser "${KAFKA_USER}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        echo "  KafkaUser ${KAFKA_USER} already exists, updating permissions..."
        # Update to have explicit Alter permission instead of "All"
        oc patch kafkauser "${KAFKA_USER}" -n "${NAMESPACE}" --type='json' -p='[
            {
                "op": "replace",
                "path": "/spec/authorization/acls/0/operations",
                "value": ["Alter", "AlterConfigs", "ClusterAction", "Create", "Describe", "DescribeConfigs", "IdempotentWrite"]
            }
        ]' >/dev/null 2>&1 || echo "  Note: KafkaUser update may require manual intervention"
    else
        echo "  Creating new KafkaUser ${KAFKA_USER}..."
        oc apply -f - <<EOF >/dev/null 2>&1
apiVersion: eventstreams.ibm.com/v1beta2
kind: KafkaUser
metadata:
  name: ${KAFKA_USER}
  namespace: ${NAMESPACE}
  labels:
    eventstreams.ibm.com/cluster: ${CLUSTER_NAME}
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
    - resource:
        type: cluster
      operations:
      - Alter
      - AlterConfigs
      - ClusterAction
      - Create
      - Describe
      - DescribeConfigs
      - IdempotentWrite
    - resource:
        type: topic
        name: "*"
        patternType: literal
      operations:
      - All
    - resource:
        type: group
        name: "*"
        patternType: literal
      operations:
      - All
    - resource:
        type: transactionalId
        name: "*"
        patternType: literal
      operations:
      - All
EOF
    fi
    
    # Wait for KafkaUser to be ready
    echo "  Waiting for KafkaUser to be ready..."
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
        STATUS=$(oc get kafkauser "${KAFKA_USER}" -n "${NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "${STATUS}" = "True" ]; then
            echo "✓ KafkaUser ${KAFKA_USER} is ready"
            break
        fi
        if [ $i -lt 30 ]; then
            sleep 2
        fi
    done
    
    # Step 3: Restart adminAPI to refresh permissions
    echo "Restarting adminAPI to refresh permissions..."
    if oc get deployment "${CLUSTER_NAME}-ibm-es-admapi" -n "${NAMESPACE}" >/dev/null 2>&1; then
        oc rollout restart deployment/"${CLUSTER_NAME}-ibm-es-admapi" -n "${NAMESPACE}" >/dev/null 2>&1
        echo "✓ AdminAPI restart initiated"
    else
        echo "  Note: AdminAPI deployment not found yet, will pick up changes when created"
    fi
    
    echo "✓ Event Streams UI credential generation configured"
    echo ""
fi

if [ "${INSTALL_FLINK}" = "true" ] && [ "${INSTALL_EP}" = "true" ]; then
    wait_for_cr "flinkdeployment" "ea-flink-demo" "${NAMESPACE}" || true
fi

if [ "${INSTALL_EP}" = "true" ]; then
    wait_for_cr "eventprocessing" "ep-demo" "${NAMESPACE}" || true
fi

if [ "${INSTALL_EEM}" = "true" ]; then
    wait_for_cr "eventendpointmanagement" "eem-demo-mgr" "${NAMESPACE}" || true
    wait_for_cr "eventgateway" "eem-demo-gw" "${NAMESPACE}" || true
fi

if [ "${INSTALL_MQ}" = "true" ]; then
    wait_for_cr "queuemanager" "qmgr-demo" "${NAMESPACE}" || true
fi

if [ "${INSTALL_ACE}" = "true" ]; then
    wait_for_cr "dashboard" "ace-demo-dashboard" "${NAMESPACE}" || true
fi

if [ "${INSTALL_APIC}" = "true" ]; then
    wait_for_cr "apiconnectcluster" "apic-demo" "${NAMESPACE}" || true
fi

# Configure LOCAL authentication credentials AFTER instances are created
echo ""
echo "============================================================"
echo "Configuring LOCAL Authentication Credentials"
echo "============================================================"

# Function to generate random password
generate_password() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-'
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 16
    else
        echo "$(date +%s)$RANDOM"
    fi
}

# Function to create API Connect API Developer user with required roles
create_apic_developer_user() {
    APIC_NAME="apic-demo"
    DEV_USERNAME="apidev"
    DEV_PASSWORD=$(generate_password)
    DEV_EMAIL="apidev@example.com"
    
    echo "Creating API Connect API Developer user..."
    
    # Wait longer for Platform API to be available (up to 5 minutes)
    PLATFORM_API_URL=""
    echo "  Waiting for Platform API to be ready..."
    for i in $(seq 1 30); do
        PLATFORM_API_URL=$(oc get apiconnectcluster "${APIC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status.endpoints[?(@.name=="platformApi")].uri}' 2>/dev/null || echo "")
        if [ -n "${PLATFORM_API_URL}" ]; then
            # Verify the API is actually responding
            if curl -k -s -o /dev/null -w "%{http_code}" "${PLATFORM_API_URL}api/cloud/orgs" | grep -q "200\|401\|403"; then
                echo "  ✓ Platform API is ready"
                break
            fi
        fi
        if [ $i -lt 30 ]; then
            echo "    Waiting... ($i/30)"
            sleep 10
        fi
    done
    
    if [ -z "${PLATFORM_API_URL}" ]; then
        echo "⚠ Platform API not available after waiting, storing credentials for manual creation"
        echo "   You can create the user manually via Admin Console after APIC is fully ready"
        oc create secret generic "${APIC_NAME}-apidev-credentials" -n "${NAMESPACE}" \
            --from-literal=username="${DEV_USERNAME}" \
            --from-literal=password="${DEV_PASSWORD}" \
            --from-literal=email="${DEV_EMAIL}" \
            --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
        echo "   Credentials stored in secret: ${APIC_NAME}-apidev-credentials"
        return 0
    fi
    
    # Get admin credentials
    ADMIN_USER=$(oc get secret "${APIC_NAME}-mgmt-admin-pass" -n "${NAMESPACE}" -o jsonpath='{.data.email}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    ADMIN_PASS=$(oc get secret "${APIC_NAME}-mgmt-admin-pass" -n "${NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -z "${ADMIN_USER}" ] || [ -z "${ADMIN_PASS}" ]; then
        echo "⚠ Admin credentials not found, storing credentials for manual creation"
        oc create secret generic "${APIC_NAME}-apidev-credentials" -n "${NAMESPACE}" \
            --from-literal=username="${DEV_USERNAME}" \
            --from-literal=password="${DEV_PASSWORD}" \
            --from-literal=email="${DEV_EMAIL}" \
            --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
        echo "   Credentials stored in secret: ${APIC_NAME}-apidev-credentials"
        return 0
    fi
    
    # Get OAuth client credentials
    CLIENT_ID=$(oc get secret "${APIC_NAME}-cp4i-creds" -n "${NAMESPACE}" -o jsonpath='{.data.client_id}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    CLIENT_SECRET=$(oc get secret "${APIC_NAME}-cp4i-creds" -n "${NAMESPACE}" -o jsonpath='{.data.client_secret}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    if [ -z "${CLIENT_ID}" ] || [ -z "${CLIENT_SECRET}" ]; then
        echo "⚠ OAuth credentials not found, storing credentials for manual creation"
        oc create secret generic "${APIC_NAME}-apidev-credentials" -n "${NAMESPACE}" \
            --from-literal=username="${DEV_USERNAME}" \
            --from-literal=password="${DEV_PASSWORD}" \
            --from-literal=email="${DEV_EMAIL}" \
            --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
        echo "   Credentials stored in secret: ${APIC_NAME}-apidev-credentials"
        return 0
    fi
    
    # Try to get access token - API Connect 10.0 uses OAuth2
    TOKEN_URL="${PLATFORM_API_URL}api/token"
    echo "  Authenticating to Platform API..."
    
    # Try with realm admin/default-idp-1
    TOKEN_RESPONSE=$(curl -k -s -X POST "${TOKEN_URL}" \
        -H "Content-Type: application/json" \
        -d "{
            \"grant_type\": \"password\",
            \"username\": \"${ADMIN_USER}\",
            \"password\": \"${ADMIN_PASS}\",
            \"realm\": \"admin/default-idp-1\",
            \"client_id\": \"${CLIENT_ID}\",
            \"client_secret\": \"${CLIENT_SECRET}\"
        }" 2>/dev/null)
    
    ACCESS_TOKEN=$(echo "${TOKEN_RESPONSE}" | jq -r '.access_token' 2>/dev/null)
    
    if [ -z "${ACCESS_TOKEN}" ] || [ "${ACCESS_TOKEN}" = "null" ]; then
        echo "⚠ Could not authenticate to Platform API"
        ERROR_MSG=$(echo "${TOKEN_RESPONSE}" | jq -r '.message // .status // "Unknown error"' 2>/dev/null || echo "Unknown error")
        echo "   Error: ${ERROR_MSG}"
        echo "   Storing credentials for manual creation via Admin Console"
        oc create secret generic "${APIC_NAME}-apidev-credentials" -n "${NAMESPACE}" \
            --from-literal=username="${DEV_USERNAME}" \
            --from-literal=password="${DEV_PASSWORD}" \
            --from-literal=email="${DEV_EMAIL}" \
            --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
        echo "   Credentials stored in secret: ${APIC_NAME}-apidev-credentials"
        echo "   Manual creation steps:"
        echo "     1. Login to Admin Console as ${ADMIN_USER}"
        echo "     2. Go to Resources → User Registries → API Manager Local User Registry"
        echo "     3. Create user '${DEV_USERNAME}' with password '${DEV_PASSWORD}'"
        return 0
    fi
    
    echo "  ✓ Authenticated successfully"
    
    # Find API Manager Local User Registry
    echo "  Finding API Manager Local User Registry..."
    LUR_LIST=$(curl -k -s -X GET "${PLATFORM_API_URL}api/cloud/user-registries" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" 2>/dev/null)
    
    LUR_ID=$(echo "${LUR_LIST}" | jq -r '.results[] | select(.type=="local" and (.title | contains("Provider") or contains("API Manager"))) | .id' 2>/dev/null | head -1)
    
    if [ -z "${LUR_ID}" ]; then
        # Try finding any local registry
        LUR_ID=$(echo "${LUR_LIST}" | jq -r '.results[] | select(.type=="local") | .id' 2>/dev/null | head -1)
    fi
    
    if [ -z "${LUR_ID}" ]; then
        echo "⚠ Could not find API Manager Local User Registry"
        echo "   Storing credentials for manual creation"
        oc create secret generic "${APIC_NAME}-apidev-credentials" -n "${NAMESPACE}" \
            --from-literal=username="${DEV_USERNAME}" \
            --from-literal=password="${DEV_PASSWORD}" \
            --from-literal=email="${DEV_EMAIL}" \
            --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
        echo "   Credentials stored in secret: ${APIC_NAME}-apidev-credentials"
        return 0
    fi
    
    echo "  ✓ Found Local User Registry: ${LUR_ID}"
    
    # Check if user already exists
    USERS_LIST=$(curl -k -s -X GET "${PLATFORM_API_URL}api/cloud/user-registries/${LUR_ID}/users" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" 2>/dev/null)
    
    EXISTING_USER=$(echo "${USERS_LIST}" | jq -r ".results[] | select(.username==\"${DEV_USERNAME}\") | .id" 2>/dev/null)
    
    if [ -n "${EXISTING_USER}" ]; then
        echo "⚠ User '${DEV_USERNAME}' already exists (ID: ${EXISTING_USER})"
        echo "   Updating stored credentials with generated password"
        oc create secret generic "${APIC_NAME}-apidev-credentials" -n "${NAMESPACE}" \
            --from-literal=username="${DEV_USERNAME}" \
            --from-literal=password="${DEV_PASSWORD}" \
            --from-literal=email="${DEV_EMAIL}" \
            --from-literal=user_id="${EXISTING_USER}" \
            --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
        echo "   Note: The existing user's password was NOT changed. Use Admin Console to reset it if needed."
        return 0
    fi
    
    # Create user
    echo "  Creating user '${DEV_USERNAME}'..."
    CREATE_RESPONSE=$(curl -k -s -X POST "${PLATFORM_API_URL}api/cloud/user-registries/${LUR_ID}/users" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"${DEV_USERNAME}\",
            \"password\": \"${DEV_PASSWORD}\",
            \"email\": \"${DEV_EMAIL}\",
            \"first_name\": \"API\",
            \"last_name\": \"Developer\"
        }" 2>/dev/null)
    
    USER_ID=""
    if echo "${CREATE_RESPONSE}" | jq -e '.id' >/dev/null 2>&1; then
        USER_ID=$(echo "${CREATE_RESPONSE}" | jq -r '.id')
        echo "  ✓ API Developer user created successfully! (ID: ${USER_ID})"
        
        # Store credentials in secret
        oc create secret generic "${APIC_NAME}-apidev-credentials" -n "${NAMESPACE}" \
            --from-literal=username="${DEV_USERNAME}" \
            --from-literal=password="${DEV_PASSWORD}" \
            --from-literal=email="${DEV_EMAIL}" \
            --from-literal=user_id="${USER_ID}" \
            --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
        
        # Try to assign roles automatically
        echo "  Assigning roles to API Developer user..."
        
        # Get organizations
        ORGS_RESPONSE=$(curl -k -s -X GET "${PLATFORM_API_URL}api/cloud/orgs" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" 2>/dev/null)
        
        ORG_ID=$(echo "${ORGS_RESPONSE}" | jq -r '.results[0].id' 2>/dev/null)
        
        if [ -n "${ORG_ID}" ] && [ "${ORG_ID}" != "null" ]; then
            # Add user to organization with admin role
            MEMBER_RESPONSE=$(curl -k -s -X POST "${PLATFORM_API_URL}api/cloud/orgs/${ORG_ID}/members" \
                -H "Authorization: Bearer ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{
                    \"user_url\": \"${PLATFORM_API_URL}api/cloud/user-registries/${LUR_ID}/users/${USER_ID}\",
                    \"role\": \"admin\"
                }" 2>/dev/null)
            
            if echo "${MEMBER_RESPONSE}" | jq -e '.url' >/dev/null 2>&1; then
                echo "  ✓ User added to organization with admin role"
            else
                echo "  ⚠ Could not automatically assign roles. User created but roles need manual assignment:"
                echo "     - Login to Admin Console"
                echo "     - Go to Resources → Organizations → [Your Org] → Members"
                echo "     - Add user '${DEV_USERNAME}' with admin role"
            fi
        else
            echo "  ⚠ No organizations found. User created but needs to be added to an organization manually."
        fi
        
    elif echo "${CREATE_RESPONSE}" | jq -e '.message' 2>/dev/null | grep -qi "already exists\|duplicate"; then
        echo "⚠ User ${DEV_USERNAME} already exists (detected via error message)"
        # Extract user ID from error or query for it
        USER_ID=$(echo "${USERS_LIST}" | jq -r ".results[] | select(.username==\"${DEV_USERNAME}\") | .id" 2>/dev/null || echo "")
        oc create secret generic "${APIC_NAME}-apidev-credentials" -n "${NAMESPACE}" \
            --from-literal=username="${DEV_USERNAME}" \
            --from-literal=password="${DEV_PASSWORD}" \
            --from-literal=email="${DEV_EMAIL}" \
            --from-literal=user_id="${USER_ID}" \
            --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
        echo "   Password stored in secret: ${APIC_NAME}-apidev-credentials"
        echo "   Note: The existing user's password was NOT changed. Use Admin Console to reset it if needed."
    else
        echo "⚠ Failed to create user via Platform API"
        ERROR_MSG=$(echo "${CREATE_RESPONSE}" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "${CREATE_RESPONSE}")
        echo "   Error: ${ERROR_MSG}"
        echo "   Storing credentials for manual creation"
        oc create secret generic "${APIC_NAME}-apidev-credentials" -n "${NAMESPACE}" \
            --from-literal=username="${DEV_USERNAME}" \
            --from-literal=password="${DEV_PASSWORD}" \
            --from-literal=email="${DEV_EMAIL}" \
            --dry-run=client -o yaml | oc apply -f - >/dev/null 2>&1 || true
        echo "   Credentials stored in secret: ${APIC_NAME}-apidev-credentials"
        echo "   Manual creation steps:"
        echo "     1. Login to Admin Console as ${ADMIN_USER}"
        echo "     2. Go to Resources → User Registries → API Manager Local User Registry"
        echo "     3. Create user '${DEV_USERNAME}' with password '${DEV_PASSWORD}'"
    fi
}

# Configure Event Processing credentials
if [ "${INSTALL_EP}" = "true" ]; then
    echo "Configuring Event Processing LOCAL auth credentials..."
    # Wait for secrets to be created by operator
    echo "  Waiting for secrets to be created..."
    for i in 1 2 3 4 5 6; do
        oc get secret ep-demo-ibm-ep-user-credentials -n "${NAMESPACE}" >/dev/null 2>&1 && break
        sleep 10
    done
    EP_ADMIN_PWD=$(generate_password)
    # Write JSON to temp file then base64 encode to avoid shell escaping issues
    printf "{\"users\":[{\"username\":\"ep-admin\",\"password\":\"${EP_ADMIN_PWD}\"}]}" > /tmp/ep-user-credentials.json
    EP_B64=$(base64 -i /tmp/ep-user-credentials.json 2>/dev/null || base64 /tmp/ep-user-credentials.json | tr -d '\n')
    oc patch secret ep-demo-ibm-ep-user-credentials -n "${NAMESPACE}" --patch "{\"data\":{\"user-credentials.json\":\"$EP_B64\"}}" --type=merge 2>/dev/null || echo "  Failed to patch credentials"
    printf '{"mappings":[{"id":"ep-admin","roles":["user"]}]}' > /tmp/ep-user-roles.json
    EP_ROLE_B64=$(base64 -i /tmp/ep-user-roles.json 2>/dev/null || base64 /tmp/ep-user-roles.json | tr -d '\n')
    oc patch secret ep-demo-ibm-ep-user-roles -n "${NAMESPACE}" --patch "{\"data\":{\"user-mapping.json\":\"$EP_ROLE_B64\"}}" --type=merge 2>/dev/null || echo "  Failed to patch role mapping"
    rm -f /tmp/ep-user-credentials.json /tmp/ep-user-roles.json
    echo "  ep-admin password: ${EP_ADMIN_PWD}"
fi

# Configure Event Endpoint Management credentials
if [ "${INSTALL_EEM}" = "true" ]; then
    echo "Configuring Event Endpoint Management LOCAL auth credentials..."
    # Wait for secrets to be created by operator
    echo "  Waiting for secrets to be created..."
    for i in 1 2 3 4 5 6; do
        oc get secret eem-demo-mgr-ibm-eem-user-credentials -n "${NAMESPACE}" >/dev/null 2>&1 && break
        sleep 10
    done
    EEM_ADMIN_PWD=$(generate_password)
    # Write JSON to temp file then base64 encode to avoid shell escaping issues
    printf "{\"users\":[{\"username\":\"eem-admin\",\"password\":\"${EEM_ADMIN_PWD}\"}]}" > /tmp/eem-user-credentials.json
    EEM_B64=$(base64 -i /tmp/eem-user-credentials.json 2>/dev/null || base64 /tmp/eem-user-credentials.json | tr -d '\n')
    oc patch secret eem-demo-mgr-ibm-eem-user-credentials -n "${NAMESPACE}" --patch "{\"data\":{\"user-credentials.json\":\"$EEM_B64\"}}" --type=merge 2>/dev/null || echo "  Failed to patch credentials"
    printf '{"mappings":[{"id":"eem-admin","roles":["author"]}]}' > /tmp/eem-user-roles.json
    EEM_ROLE_B64=$(base64 -i /tmp/eem-user-roles.json 2>/dev/null || base64 /tmp/eem-user-roles.json | tr -d '\n')
    oc patch secret eem-demo-mgr-ibm-eem-user-roles -n "${NAMESPACE}" --patch "{\"data\":{\"user-mapping.json\":\"$EEM_ROLE_B64\"}}" --type=merge 2>/dev/null || echo "  Failed to patch role mapping"
    rm -f /tmp/eem-user-credentials.json /tmp/eem-user-roles.json
    echo "  eem-admin password: ${EEM_ADMIN_PWD}"
fi

# Create API Developer user if APIC is installed
if [ "${INSTALL_APIC}" = "true" ]; then
    echo ""
    echo "Creating API Connect API Developer User..."
    create_apic_developer_user
fi

# Final summary
echo ""
echo "============================================================"
echo "✓ INSTALLATION COMPLETE!"
echo "============================================================"
echo "Event Automation components installed in namespace: ${NAMESPACE}"
echo ""

# Show installation summary
echo "WHAT WAS INSTALLED:"
echo ""
echo "1. INFRASTRUCTURE:"
echo "   - Namespace: ${NAMESPACE}"
echo "   - IBM entitlement secret for container registry access"
CATALOG_COUNT=1
[ "${INSTALL_ES}" = "true" ] && CATALOG_COUNT=$((CATALOG_COUNT+1))
[ "${INSTALL_EEM}" = "true" ] && CATALOG_COUNT=$((CATALOG_COUNT+1))
[ "${INSTALL_FLINK}" = "true" ] && CATALOG_COUNT=$((CATALOG_COUNT+1))
[ "${INSTALL_EP}" = "true" ] && CATALOG_COUNT=$((CATALOG_COUNT+1))
[ "${INSTALL_NAV}" = "true" ] && CATALOG_COUNT=$((CATALOG_COUNT+1))
[ "${INSTALL_MQ}" = "true" ] && CATALOG_COUNT=$((CATALOG_COUNT+1))
[ "${INSTALL_ACE}" = "true" ] && CATALOG_COUNT=$((CATALOG_COUNT+1))
[ "${INSTALL_APIC}" = "true" ] && CATALOG_COUNT=$((CATALOG_COUNT+1))
echo "   - ${CATALOG_COUNT} catalog sources in openshift-marketplace"
echo ""
echo "2. OPERATORS:"
OP_COUNT=0
[ "${INSTALL_FLINK}" = "true" ] && { echo "   - ibm-eventautomation-flink operator (v1.4.4)"; OP_COUNT=$((OP_COUNT+1)); }
[ "${INSTALL_ES}" = "true" ] && { echo "   - ibm-eventstreams operator (v12.0.2)"; OP_COUNT=$((OP_COUNT+1)); }
[ "${INSTALL_EEM}" = "true" ] && { echo "   - ibm-eventendpointmanagement operator (v11.6.4)"; OP_COUNT=$((OP_COUNT+1)); }
[ "${INSTALL_EP}" = "true" ] && { echo "   - ibm-eventprocessing operator (v1.4.4)"; OP_COUNT=$((OP_COUNT+1)); }
[ "${INSTALL_NAV}" = "true" ] && { echo "   - ibm-integration-platform-navigator operator (v8.1.3)"; OP_COUNT=$((OP_COUNT+1)); }
[ "${INSTALL_NAV}" = "true" ] && echo "   - ibm-common-service-operator (auto-installed for Platform Nav)"
[ "${INSTALL_MQ}" = "true" ] && { echo "   - ibm-mq operator (v3.7)"; OP_COUNT=$((OP_COUNT+1)); }
[ "${INSTALL_ACE}" = "true" ] && { echo "   - ibm-appconnect operator (v12.16)"; OP_COUNT=$((OP_COUNT+1)); }
[ "${INSTALL_APIC}" = "true" ] && { echo "   - ibm-apiconnect operator (v6.1)"; OP_COUNT=$((OP_COUNT+1)); }
[ "${INSTALL_APIC}" = "true" ] && { echo "   - datapower-operator (v1.16) - required for API Connect"; OP_COUNT=$((OP_COUNT+1)); }
echo ""
echo "3. COMPONENT INSTANCES:"
[ "${INSTALL_ES}" = "true" ] && echo "   - Event Streams (es-demo) - Kafka cluster with 3 nodes"
[ "${INSTALL_FLINK}" = "true" ] && [ "${INSTALL_EP}" = "true" ] && echo "   - Apache Flink (ea-flink-demo) - Stream processing engine"
[ "${INSTALL_EP}" = "true" ] && echo "   - Event Processing (ep-demo) - Stream processing authoring UI"
[ "${INSTALL_EEM}" = "true" ] && echo "   - Event Endpoint Management Manager (eem-demo-mgr) - API catalog"
[ "${INSTALL_EEM}" = "true" ] && echo "   - Event Gateway (eem-demo-gw) - Runtime gateway"
[ "${INSTALL_NAV}" = "true" ] && echo "   - Platform Navigator (cp4i-navigator) - Unified console"
[ "${INSTALL_MQ}" = "true" ] && echo "   - IBM MQ (qmgr-demo) - Message queue manager"
[ "${INSTALL_ACE}" = "true" ] && echo "   - AppConnect Enterprise Dashboard (ace-demo-dashboard) - Integration dashboard"
[ "${INSTALL_APIC}" = "true" ] && echo "   - API Connect (apic-demo) - API management platform"
echo ""
echo "4. SECURITY:"
echo "   - LOCAL authentication configured"
echo "   - Auto-generated passwords"
echo "   - Role-based access control"
echo ""
echo "TOTAL INSTALLATION TIME:"
echo "  ~30-45 minutes (depending on cluster resources)"
echo ""

# Get access URLs and credentials
echo "============================================================"
echo "ACCESS INFORMATION"
echo "============================================================"
echo ""

# API Connect setup instructions (if APIC is installed)
if [ "${INSTALL_APIC}" = "true" ]; then
    echo "============================================================"
    echo "API CONNECT SETUP INSTRUCTIONS"
    echo "============================================================"
    echo ""
    echo "After API Connect installation completes, you need to:"
    echo ""
    echo "1. CREATE AN ORGANIZATION (Required):"
    echo "   - Login to Admin Console:"
    APIC_ADMIN_UI=$(oc get apiconnectcluster apic-demo -n "${NAMESPACE}" -o jsonpath='{.status.endpoints[?(@.name=="adminUi")].uri}' 2>/dev/null || echo "")
    if [ -n "${APIC_ADMIN_UI}" ]; then
        echo "     ${APIC_ADMIN_UI}"
    else
        echo "     (Admin Console URL will be available after installation)"
    fi
    echo "   - Use admin credentials from secret: apic-demo-mgmt-admin-pass"
    echo "   - Navigate to: Resources → Organizations"
    echo "   - Click 'Create Organization'"
    echo "   - Fill in organization details (name, title, etc.)"
    echo "   - Click 'Save'"
    echo ""
    echo "2. CREATE API MANAGER USER (Optional - for API development):"
    echo "   - In Admin Console, go to: Resources → User Registries"
    echo "   - Click 'API Manager Local User Registry'"
    echo "   - Create user 'apidev' with credentials from secret: apic-demo-apidev-credentials"
    echo "   - Add user to organization with Administrator role"
    echo ""
    echo "3. ACCESS API MANAGER:"
    echo "   - URL: (shown below after installation)"
    echo "   - Select 'API Manager' as login type (NOT 'Cloud Pak User registry')"
    echo "   - Use API Manager Local User Registry credentials"
    echo ""
    echo "============================================================"
    echo ""
fi

if [ "${INSTALL_NAV}" = "true" ]; then
    NAV_UI=$(oc get route cp4i-navigator-pn -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${NAV_UI}" ]; then
        NAV_USER=$(oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "integration-admin")
        NAV_PWD=$(oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        echo "PLATFORM NAVIGATOR CONSOLE:"
        echo "  URL: https://${NAV_UI}"
        echo "  Username: ${NAV_USER}"
        [ -n "${NAV_PWD}" ] && echo "  Password: ${NAV_PWD}"
        echo ""
    fi
fi

if [ "${INSTALL_ES}" = "true" ]; then
    ES_UI=$(oc get route es-demo-ibm-es-ui -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${ES_UI}" ]; then
        echo "EVENT STREAMS:"
        echo "  URL: https://${ES_UI}"
        echo "  Authentication: None required"
        echo ""
    fi
fi

if [ "${INSTALL_EP}" = "true" ]; then
    EP_UI=$(oc get route ep-demo-ibm-ep-rt -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${EP_UI}" ]; then
        echo "EVENT PROCESSING:"
        echo "  URL: https://${EP_UI}"
        EP_STORED=$(oc get secret ep-demo-ibm-ep-user-credentials -n "${NAMESPACE}" -o jsonpath='{.data.user-credentials\.json}' 2>/dev/null | base64 -d | jq -r '.users[] | select(.username=="ep-admin") | .password' 2>/dev/null || echo "")
        if [ -n "${EP_STORED}" ]; then
            echo "  Username: ep-admin"
            echo "  Password: ${EP_STORED}"
        else
            echo "  Credentials: To be configured (check secret ep-demo-ibm-ep-user-credentials)"
        fi
        echo ""
    fi
fi

if [ "${INSTALL_EEM}" = "true" ]; then
    EEM_UI=$(oc get route eem-demo-mgr-ibm-eem-manager -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "${EEM_UI}" ]; then
        echo "EVENT ENDPOINT MANAGEMENT:"
        echo "  URL: https://${EEM_UI}"
        EEM_STORED=$(oc get secret eem-demo-mgr-ibm-eem-user-credentials -n "${NAMESPACE}" -o jsonpath='{.data.user-credentials\.json}' 2>/dev/null | base64 -d | jq -r '.users[] | select(.username=="eem-admin") | .password' 2>/dev/null || echo "")
        if [ -n "${EEM_STORED}" ]; then
            echo "  Username: eem-admin"
            echo "  Password: ${EEM_STORED}"
        else
            echo "  Credentials: To be configured (check secret eem-demo-mgr-ibm-eem-user-credentials)"
        fi
        echo ""
    fi
fi

if [ "${INSTALL_APIC}" = "true" ]; then
    APIC_MGR_UI=$(oc get apiconnectcluster apic-demo -n "${NAMESPACE}" -o jsonpath='{.status.endpoints[?(@.name=="ui")].uri}' 2>/dev/null || echo "")
    
    if [ -n "${APIC_MGR_UI}" ]; then
        echo "API CONNECT:"
        echo "  API Manager:"
        echo "    URL: ${APIC_MGR_UI}/auth/manager/sign-in/"
        echo "    Login Type: Select 'API Manager' (not 'Cloud Pak User registry')"
        
        # Get API Developer credentials from secret
        APIC_DEV_USER=$(oc get secret apic-demo-apidev-credentials -n "${NAMESPACE}" -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        APIC_DEV_PASS=$(oc get secret apic-demo-apidev-credentials -n "${NAMESPACE}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
        
        if [ -n "${APIC_DEV_USER}" ] && [ -n "${APIC_DEV_PASS}" ]; then
            echo "    Username: ${APIC_DEV_USER}"
            echo "    Password: ${APIC_DEV_PASS}"
        else
            echo "    Username: apidev"
            echo "    Password: Check secret apic-demo-apidev-credentials for password"
        fi
        echo ""
    fi
fi

echo "============================================================"
echo "WHAT YOU CAN DO NOW:"
echo "============================================================"
echo "  - Access all components via Platform Navigator"
echo "  - Create Kafka topics in Event Streams"
echo "  - Build stream processing apps in Event Processing"
echo "  - Catalog and manage APIs in Event Endpoint Management"
if [ "${INSTALL_NAV}" = "true" ]; then
echo "  - Install additional CP4I components (MQ, ACE, APIC) from Platform Navigator catalog"
fi
echo "  - Scale components as needed"
echo ""
echo "The script handles everything automatically! 🎉"
echo ""
echo "============================================================"
echo "USEFUL COMMANDS:"
echo "============================================================"
echo "  # Check status:"
echo "  oc get pods -n ${NAMESPACE}"
echo "  oc get eventstreams,eventprocessing,eventendpointmanagement,eventgateway,flinkdeployment -n ${NAMESPACE}"
echo ""
echo "  # Retrieve credentials later:"
echo "  oc get secret ep-demo-ibm-ep-user-credentials -n ${NAMESPACE} -o jsonpath='{.data.user-credentials\.json}' | base64 -d | jq"
echo "  oc get secret eem-demo-mgr-ibm-eem-user-credentials -n ${NAMESPACE} -o jsonpath='{.data.user-credentials\.json}' | base64 -d | jq"
echo ""
echo "Documentation:"
echo "  - Event Automation: https://ibm.github.io/event-automation/"
echo "  - Demo guide: https://github.com/IBM/event-automation-demo"
echo ""
echo "============================================================"
echo ""

