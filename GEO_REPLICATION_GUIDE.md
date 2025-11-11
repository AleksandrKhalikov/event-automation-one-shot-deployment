# Event Streams Geo-Replication Setup Guide

This guide explains how to set up geo-replication between two Event Streams instances in the same OpenShift cluster using the `event-streams-ocp-geo-replication-installation.sh` script.

## Overview

Geo-replication allows you to synchronize Kafka topics between separate Event Streams clusters. This setup demonstrates geo-replication within a single OpenShift cluster, which is useful for:
- **Testing and development**: Test geo-replication functionality without multiple clusters
- **Data backup**: Create a backup copy of your topics
- **Disaster recovery preparation**: Understand how geo-replication works before deploying across geographies

### Architecture

- **Source Cluster**: Existing Event Streams instance (default: `es-demo` in `tools` namespace)
- **Destination Cluster**: New Event Streams instance (default: `es-dest` in `event-streams-geo-replication` namespace)
- **Geo-Replicator**: Manages the replication between clusters

## Prerequisites

1. **OpenShift Cluster**: Access to an OpenShift cluster with cluster-admin privileges
2. **Event Streams Operator**: Must be installed (via `ibm_event_automation_oneshot_deployment.sh`)
3. **Source Event Streams Instance**: An existing Event Streams instance that is Ready
4. **IBM Entitlement Key**: Required for pulling container images

## Step-by-Step Installation

### Step 1: Verify Prerequisites

```bash
# Login to OpenShift
oc login --token=YOUR_TOKEN --server=https://YOUR_OPENSHIFT_API

# Verify Event Streams operator is installed
oc get csv -n openshift-operators | grep ibm-eventstreams

# Verify source Event Streams instance exists and is Ready
oc get eventstreams es-demo -n tools
oc get eventstreams es-demo -n tools -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

Expected output: `True` (Ready)

### Step 2: Run the Geo-Replication Setup Script

```bash
# Basic usage (will prompt for entitlement key)
./event-streams-ocp-geo-replication-installation.sh

# Or provide entitlement key directly
./event-streams-ocp-geo-replication-installation.sh -e YOUR_ENTITLEMENT_KEY

# Custom source cluster
./event-streams-ocp-geo-replication-installation.sh \
  -e YOUR_ENTITLEMENT_KEY \
  -s my-namespace \
  -c my-source-cluster

# Custom destination configuration
./event-streams-ocp-geo-replication-installation.sh \
  -e YOUR_ENTITLEMENT_KEY \
  -d my-dest-namespace \
  -n my-dest-cluster \
  -t ocs-storagecluster-cephfs
```

### Step 3: Monitor Installation Progress

The script will:
1. Create the destination namespace
2. Create entitlement secrets
3. Create the destination Event Streams instance
4. Wait for the destination cluster to be Ready (can take 10-20 minutes)
5. Create the EventStreamsGeoReplicator resource

Monitor progress:
```bash
# Watch destination cluster status
oc get eventstreams es-dest -n event-streams-geo-replication -w

# Check pods
oc get pods -n event-streams-geo-replication -w

# Check geo-replicator status
oc get eventstreamsgeoreplicator es-dest -n event-streams-geo-replication
```

### Step 4: Verify Installation

```bash
# Verify both clusters are Ready
oc get eventstreams -A

# Verify geo-replicator is created
oc get eventstreamsgeoreplicator -A

# Check geo-replicator details
oc get eventstreamsgeoreplicator es-dest -n event-streams-geo-replication -o yaml
```

## Step-by-Step Demonstration

### Demonstration 1: Basic Topic Replication

This demonstrates creating a topic in the source cluster and verifying it replicates to the destination.

#### 1.1: Access Event Streams UI

```bash
# Get source cluster UI URL
SOURCE_UI=$(oc get route es-demo-ibm-es-ui -n tools -o jsonpath='{.spec.host}')
echo "Source UI: https://${SOURCE_UI}"

# Get destination cluster UI URL
DEST_UI=$(oc get route es-dest-ibm-es-ui -n event-streams-geo-replication -o jsonpath='{.spec.host}')
echo "Destination UI: https://${DEST_UI}"
```

#### 1.2: Create a Topic in Source Cluster

1. Open the source Event Streams UI in your browser
2. Navigate to **Topics** → **Create topic**
3. Create a topic named `demo-geo-replication-topic`:
   - **Name**: `demo-geo-replication-topic`
   - **Partitions**: `3`
   - **Replication factor**: `3`
   - Click **Create**

#### 1.3: Configure Geo-Replication

1. In the source Event Streams UI, go to **Topics**
2. Click on `demo-geo-replication-topic`
3. Look for **Share** or **Replicate** option
4. Select the destination cluster (`es-dest`)
5. Configure replication settings:
   - **Replication mode**: `Mirror` (recommended)
   - **Sync topics**: `All partitions`
6. Click **Save** or **Enable replication**

#### 1.4: Verify Topic Replication

1. Open the destination Event Streams UI
2. Navigate to **Topics**
3. Verify `demo-geo-replication-topic` appears (may take a few seconds)
4. Check topic details match the source topic

#### 1.5: Verify via CLI

```bash
# List topics in source cluster
oc exec -n tools es-demo-kafka-0 -- bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --list

# List topics in destination cluster
oc exec -n event-streams-geo-replication es-dest-kafka-0 -- bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --list

# Get topic details from destination
oc exec -n event-streams-geo-replication es-dest-kafka-0 -- bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --topic demo-geo-replication-topic \
  --describe
```

### Demonstration 2: Message Replication

This demonstrates producing messages to the source cluster and verifying they appear in the destination.

#### 2.1: Produce Messages to Source Cluster

```bash
# Get Kafka bootstrap server
SOURCE_BOOTSTRAP=$(oc get route es-demo-kafka-bootstrap -n tools -o jsonpath='{.spec.host}' 2>/dev/null || \
  echo "es-demo-kafka-bootstrap.tools.svc.cluster.local:9092")

# Produce messages using Kafka console producer
oc exec -n tools es-demo-kafka-0 -- bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic demo-geo-replication-topic

# Type messages and press Enter after each:
# Message 1: Hello from source cluster
# Message 2: This is a test message
# Message 3: Geo-replication is working!
# Press Ctrl+D to exit
```

#### 2.2: Consume Messages from Destination Cluster

```bash
# Consume messages from destination cluster
oc exec -n event-streams-geo-replication es-dest-kafka-0 -- bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic demo-geo-replication-topic \
  --from-beginning

# You should see the messages you produced in the source cluster
```

#### 2.3: Verify Message Count

```bash
# Count messages in source topic
oc exec -n tools es-demo-kafka-0 -- bin/kafka-run-class.sh \
  kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic demo-geo-replication-topic \
  --time -1

# Count messages in destination topic
oc exec -n event-streams-geo-replication es-dest-kafka-0 -- bin/kafka-run-class.sh \
  kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic demo-geo-replication-topic \
  --time -1

# Both should show the same offsets if replication is working
```

### Demonstration 3: Monitoring Geo-Replication Health

#### 3.1: Check Geo-Replicator Status

```bash
# Get detailed status
oc get eventstreamsgeoreplicator es-dest -n event-streams-geo-replication -o yaml

# Check replicator pods
oc get pods -n event-streams-geo-replication | grep georeplicator

# Check replicator logs
oc logs -n event-streams-geo-replication -l app.kubernetes.io/component=geo-replicator --tail=50
```

#### 3.2: Monitor Replication Metrics

```bash
# Get replicator pod name
REPLICATOR_POD=$(oc get pods -n event-streams-geo-replication -l app.kubernetes.io/component=geo-replicator -o jsonpath='{.items[0].metadata.name}')

# Check metrics endpoint
oc exec -n event-streams-geo-replication ${REPLICATOR_POD} -- \
  curl -s http://localhost:8080/metrics | grep -i mirror
```

## Troubleshooting

### Destination Cluster Not Ready

```bash
# Check Event Streams status
oc get eventstreams es-dest -n event-streams-geo-replication -o yaml | grep -A 10 "status:"

# Check pods
oc get pods -n event-streams-geo-replication

# Check pod logs
oc logs -n event-streams-geo-replication es-dest-kafka-0
```

### Geo-Replicator Not Starting

```bash
# Check replicator status
oc get eventstreamsgeoreplicator es-dest -n event-streams-geo-replication -o yaml

# Check replicator pods
oc get pods -n event-streams-geo-replication | grep georeplicator

# Check events
oc get events -n event-streams-geo-replication --sort-by='.lastTimestamp'
```

### Topics Not Replicating

1. Verify geo-replication is enabled for the topic in the source cluster UI
2. Check replicator logs:
   ```bash
   oc logs -n event-streams-geo-replication -l app.kubernetes.io/component=geo-replicator --tail=100
   ```
3. Verify network connectivity between clusters:
   ```bash
   oc exec -n event-streams-geo-replication es-dest-kafka-0 -- \
     nc -zv es-demo-kafka-bootstrap.tools.svc.cluster.local 9092
   ```

### Messages Not Appearing in Destination

1. Check consumer lag:
   ```bash
   oc exec -n event-streams-geo-replication es-dest-kafka-0 -- \
     bin/kafka-consumer-groups.sh \
     --bootstrap-server localhost:9092 \
     --group mirrormaker2 \
     --describe
   ```
2. Verify topic exists in destination:
   ```bash
   oc exec -n event-streams-geo-replication es-dest-kafka-0 -- \
     bin/kafka-topics.sh \
     --bootstrap-server localhost:9092 \
     --list
   ```

## Cleanup

To remove the geo-replication setup:

```bash
# Delete geo-replicator
oc delete eventstreamsgeoreplicator es-dest -n event-streams-geo-replication

# Delete destination Event Streams instance
oc delete eventstreams es-dest -n event-streams-geo-replication

# Delete namespace (optional)
oc delete namespace event-streams-geo-replication
```

## Additional Resources

- **IBM Event Automation Documentation**: https://ibm.github.io/event-automation/
- **Geo-Replication Overview**: https://ibm.github.io/event-automation/es/georeplication/about/
- **Setting Up Geo-Replication**: https://ibm.github.io/event-automation/es/georeplication/setting-up/
- **Monitoring Geo-Replication**: https://ibm.github.io/event-automation/es/georeplication/health/
- **Planning Geo-Replication**: https://ibm.github.io/event-automation/es/georeplication/planning/

## Script Options Reference

```bash
./event-streams-ocp-geo-replication-installation.sh [options]

Options:
  -s, --source-namespace NS    Source Event Streams namespace (default: tools)
  -c, --source-cluster NAME     Source Event Streams cluster name (default: es-demo)
  -d, --dest-namespace NS      Destination namespace (default: event-streams-geo-replication)
  -n, --dest-cluster NAME      Destination Event Streams cluster name (default: es-dest)
  -e, --entitlement-key KEY     IBM Entitlement key (required)
  -t, --storage-class NAME      StorageClass for persistent storage (optional)
  -h, --help                    Show help
```

