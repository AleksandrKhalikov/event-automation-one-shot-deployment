#!/bin/sh

# Simple script to upgrade API Connect from 10.0.10.0 to 10.0.11.0
# Note: This requires updating the catalog source first

set -euo pipefail

NAMESPACE="${1:-tools}"

echo "============================================================"
echo "API Connect Upgrade: 10.0.10.0 → 10.0.11.0"
echo "============================================================"
echo ""
echo "⚠️  WARNING: This upgrade will remove all scan records!"
echo "    Archive/export any important scan results before proceeding."
echo ""
read -p "Continue with upgrade? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Upgrade cancelled."
    exit 0
fi

echo ""
echo "Step 1: Checking current version..."
CURRENT_VER=$(oc get apiconnectcluster apic-demo -n "$NAMESPACE" -o jsonpath='{.spec.version}' 2>/dev/null || echo "")
if [ -z "$CURRENT_VER" ]; then
    echo "Error: APIC instance 'apic-demo' not found in namespace $NAMESPACE"
    exit 1
fi
echo "Current version: $CURRENT_VER"

if [ "$CURRENT_VER" = "10.0.11.0" ]; then
    echo "Already at version 10.0.11.0!"
    exit 0
fi

echo ""
echo "Step 2: Updating catalog source to include 10.0.11.0..."
echo "⚠️  Note: You'll need the SHA256 hash for the catalog that includes 10.0.11.0"
echo "    Check IBM documentation or Passport Advantage for the latest catalog."
echo ""
echo "For now, we'll try to use the IBM Operator Catalog which should have it..."

# Try using the generic IBM Operator Catalog
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

echo "Waiting for catalog to be ready..."
for i in 1 2 3 4 5 6; do
    STATE=$(oc get catalogsource ibm-apiconnect-catalog -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "NotReady")
    if [ "$STATE" = "READY" ]; then
        echo "✓ Catalog ready"
        break
    fi
    sleep 10
done

echo ""
echo "Step 3: Checking if operator supports 10.0.11.0..."
# Try to get a newer CSV
APIC_CSV=$(oc get csv -n openshift-operators -l operators.coreos.com/ibm-apiconnect.openshift-operators="" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}' 2>/dev/null || echo "")
if [ -n "$APIC_CSV" ]; then
    SUPPORTED_VER=$(oc get csv "$APIC_CSV" -n openshift-operators -o json | jq -r '.metadata.annotations."alm-examples" | fromjson | [.[] | select(.kind == "APIConnectCluster")] | .[0] | .spec.version' 2>/dev/null || echo "")
    echo "Supported version in CSV: $SUPPORTED_VER"
fi

echo ""
echo "Step 4: Updating APIC instance to 10.0.11.0..."
oc patch apiconnectcluster apic-demo -n "$NAMESPACE" --type merge -p '{"spec":{"version":"10.0.11.0"}}' && \
    echo "✓ Version updated successfully!" || \
    echo "✗ Update failed - you may need to update the catalog source with the correct SHA256 hash"

echo ""
echo "Upgrade process started. Monitor progress with:"
echo "  oc get apiconnectcluster apic-demo -n $NAMESPACE -w"

