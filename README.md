# IBM Event Automation One-Shot Deployment (DON'T USE IN PRODUCTION)

Automated installation script for IBM Cloud Pak for Integration components on OpenShift.

## Quick Start

### Prerequisites

- OpenShift cluster with cluster-admin access
- `oc` CLI installed and logged in
- IBM Entitlement key ([Get it here](https://myibm.ibm.com/products-services/containerlibrary))

### Installation

```bash
# Install all Event Automation components (Event Streams, Event Processing, Event Endpoint Management)
./ibm_event_automation_oneshot_deployment.sh

# Install with additional components (MQ, ACE, APIC)
./ibm_event_automation_oneshot_deployment.sh --install-mq --install-ace --install-apic

# Custom namespace
./ibm_event_automation_oneshot_deployment.sh -n my-namespace

# With storage class
./ibm_event_automation_oneshot_deployment.sh -s ocs-storagecluster-cephfs
```

The script will:
1. Install IBM Operator Catalog
2. Install component operators (Event Streams, Event Processing, Event Endpoint Management, etc.)
3. Create component instances
4. Configure authentication credentials
5. Display access URLs and credentials

**Installation time:** ~30-45 minutes

## What Gets Installed

### By Default
- **Platform Navigator** - Unified console for CP4I components
- **Event Streams** - Kafka cluster with 3 nodes
- **Event Processing** - Stream processing authoring UI
- **Event Endpoint Management** - API catalog and gateway
- **Apache Flink** - Stream processing engine (required for Event Processing)

### Optional (with flags)
- **IBM MQ** - Message queue manager (`--install-mq`)
- **AppConnect Enterprise** - Integration dashboard (`--install-ace`)
- **API Connect** - API management platform (`--install-apic`)

## Access Information

After installation, the script displays access URLs and credentials. You can also retrieve them:

### Platform Navigator
```bash
oc get route cp4i-navigator-pn -n tools -o jsonpath='{.spec.host}'
oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.username}' | base64 -d && echo
oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.password}' | base64 -d && echo
```

### Event Streams
```bash
oc get route es-demo-ibm-es-ui -n tools -o jsonpath='{.spec.host}'
# No authentication required by default
```

### Event Processing
```bash
oc get route ep-demo-ibm-ep-rt -n tools -o jsonpath='{.spec.host}'
oc get secret ep-demo-ibm-ep-user-credentials -n tools -o jsonpath='{.data.user-credentials\.json}' | base64 -d | jq -r '.users[] | select(.username=="ep-admin") | .password'
# Username: ep-admin
```

### Event Endpoint Management
```bash
oc get route eem-demo-mgr-ibm-eem-manager -n tools -o jsonpath='{.spec.host}'
oc get secret eem-demo-mgr-ibm-eem-user-credentials -n tools -o jsonpath='{.data.user-credentials\.json}' | base64 -d | jq -r '.users[] | select(.username=="eem-admin") | .password'
# Username: eem-admin
```

### API Connect
See [README_APIC_LOGIN.md](README_APIC_LOGIN.md) for detailed instructions.

## Geo-Replication Setup

To set up geo-replication between two Event Streams instances:

```bash
# First, install Event Streams (source cluster)
./ibm_event_automation_oneshot_deployment.sh

# Then, set up geo-replication (destination cluster)
./event-streams-ocp-geo-replication-installation.sh -e YOUR_ENTITLEMENT_KEY
```

See [GEO_REPLICATION_GUIDE.md](GEO_REPLICATION_GUIDE.md) for detailed instructions.

## Script Options

```bash
./ibm_event_automation_oneshot_deployment.sh [options]

Options:
  -n, --namespace NAME       Target namespace (default: tools)
  -e, --entitlement-key KEY  IBM Entitlement key
  -s, --storage-class NAME   StorageClass for persistent storage
  -v, --cp4i-version VER     CP4I version: CD or SC2 (default: CD)
      --no-eem              Do not install Event Endpoint Management
      --no-ep               Do not install Event Processing
      --no-es               Do not install Event Streams
      --no-flink            Do not install Flink
      --no-nav              Do not install Platform Navigator
      --install-mq          Install IBM MQ
      --install-ace         Install AppConnect Enterprise
      --install-apic        Install API Connect
  -h, --help                Show help
```

## Troubleshooting

### Check Installation Status

```bash
# Check component status
oc get eventstreams,eventprocessing,eventendpointmanagement,eventgateway,flinkdeployment -n tools

# Check pods
oc get pods -n tools

# Check operator subscriptions
oc get subscription -n openshift-operators | grep -E "eventstreams|eventprocessing|eventendpointmanagement"
```

### Common Issues

**Components not ready:**
- Wait longer (installation can take 30-45 minutes)
- Check pod logs: `oc logs <pod-name> -n tools`
- Check events: `oc get events -n tools --sort-by='.lastTimestamp'`

**Image pull errors:**
- Verify entitlement key is correct
- Check secret: `oc get secret ibm-entitlement-key -n tools`

**Storage issues:**
- If no storage class specified, components use ephemeral storage
- For production, specify a storage class: `-s <storage-class-name>`

## Documentation

- [Event Automation Documentation](https://ibm.github.io/event-automation/)
- [Cloud Pak for Integration](https://www.ibm.com/docs/en/cloud-paks/cp-integration)
- [Geo-Replication Guide](GEO_REPLICATION_GUIDE.md)
- [API Connect Login Guide](README_APIC_LOGIN.md)

## Support

For issues or questions:
1. Check component logs: `oc logs <pod-name> -n tools`
2. Review [troubleshooting section](#troubleshooting)
3. Consult IBM documentation links above

