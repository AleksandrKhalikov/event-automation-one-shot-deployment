# Event Streams Geo-Replication Setup Guide

This guide explains how to set up geo-replication between two Event Streams instances using the `event-streams-ocp-geo-replication-installation.sh` script.

## Overview

Geo-replication synchronizes Kafka topics between separate Event Streams clusters. This setup creates a destination cluster in the same OpenShift cluster for testing and development.

**Architecture:**
- **Source Cluster**: `es-demo` in `tools` namespace
- **Destination Cluster**: `es-dest` in `event-streams-geo-replication` namespace
- **Geo-Replicator**: Manages replication between clusters

## Prerequisites

1. OpenShift cluster with cluster-admin access
2. Event Streams operator installed (via `ibm_event_automation_oneshot_deployment.sh`)
3. Source Event Streams instance (`es-demo`) must be Ready
4. IBM Entitlement key

## Installation

### Step 1: Run the Script

```bash
# Basic usage (will prompt for entitlement key)
./event-streams-ocp-geo-replication-installation.sh

# Or provide entitlement key directly
./event-streams-ocp-geo-replication-installation.sh -e YOUR_ENTITLEMENT_KEY
```

The script will:
1. Create destination namespace
2. Create destination Event Streams instance
3. Wait for destination cluster to be Ready (~10-20 minutes)
4. Configure source cluster for geo-replication
5. Create EventStreamsGeoReplicator resource

### Step 2: Monitor Progress

```bash
# Watch destination cluster status
oc get eventstreams es-dest -n event-streams-geo-replication -w

# Check geo-replicator
oc get eventstreamsgeoreplicator es-dest -n event-streams-geo-replication
```

## Configuration

### Get Credentials

**Source Cluster:**
```bash
# Get UI URL
oc get route es-demo-ibm-es-ui -n tools -o jsonpath='{.spec.host}'

# Get admin password
oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d && echo
```

**Destination Cluster:**
```bash
# Get UI URL
oc get route es-dest-ibm-es-ui -n event-streams-geo-replication -o jsonpath='{.spec.host}'

# Get admin password
oc get secret es-admin -n event-streams-geo-replication -o jsonpath='{.data.password}' | base64 -d && echo
```

**Login:** Username `es-admin`, password from commands above

### Connect Clusters

1. **Login to destination cluster UI** with `es-admin` credentials
2. Navigate to **Connect to this cluster** → **Geo-replication** tab
3. Click **"I want this cluster to be able to receive topics..."**
4. **Copy the connection snippet**
5. **Login to source cluster UI** with `es-admin` credentials
6. Navigate to **Connect to this cluster** → **Geo-replication** tab
7. **Paste the connection snippet** from destination
8. Click **Save**

## Testing Geo-Replication

### Step 1: Create a Topic in Source Cluster

1. Login to source Event Streams UI
2. Navigate to **Topics** → **Create topic**
3. Create topic: `demo-geo-replication-topic`
   - Partitions: `3`
   - Replication factor: `3`
4. Click **Create**

### Step 2: Enable Replication

1. In source UI, go to **Topics** → `demo-geo-replication-topic`
2. Click **Share** or **Replicate**
3. Select destination cluster (`es-dest`)
4. Configure: **Replication mode**: `Mirror`
5. Click **Save**

### Step 3: Verify Replication

1. Login to destination Event Streams UI
2. Navigate to **Topics**
3. Verify `demo-geo-replication-topic` appears (may take a few seconds)

### Step 4: Produce and Verify Messages

Use the REST API producer to send messages:

```bash
# Get REST API URL
REST_API_URL=$(oc get route es-demo-ibm-es-recapi-external -n tools -o jsonpath='{.spec.host}')
REST_API_URL="https://${REST_API_URL}"

# Get admin password
ES_ADMIN_PASSWORD=$(oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d)

# Produce messages
python3 producer.py \
  --topic demo-geo-replication-topic \
  --rest-api-url "${REST_API_URL}" \
  --username es-admin \
  --password "${ES_ADMIN_PASSWORD}" \
  --message "Geo-Replicated message" \
  --count 10
```

Verify messages appear in destination cluster UI.

## Troubleshooting

### Destination Cluster Not Ready

```bash
# Check status
oc get eventstreams es-dest -n event-streams-geo-replication -o yaml | grep -A 10 "status:"

# Check pods
oc get pods -n event-streams-geo-replication

# Check logs
oc logs -n event-streams-geo-replication es-dest-kafka-0 --tail=50
```

### Topic Not Replicating

1. Verify clusters are connected (check source cluster UI)
2. Verify topic exists in source cluster
3. Check geo-replicator status:
   ```bash
   oc get eventstreamsgeoreplicator es-dest -n event-streams-geo-replication -o yaml
   ```
4. Check replicator logs:
   ```bash
   oc logs -n event-streams-geo-replication -l app.kubernetes.io/component=geo-replicator --tail=50
   ```

### UI Credential Generation Error

The `es-admin` user already has full privileges. You don't need to generate new credentials through the UI. Use the `es-admin` credentials directly.

## More Information

- [Geo-Replication Documentation](https://ibm.github.io/event-automation/es/georeplication/about/)
- [Setting up Geo-Replication](https://ibm.github.io/event-automation/es/georeplication/setting-up/)
