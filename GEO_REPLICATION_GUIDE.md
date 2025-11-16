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

### Step 5: Authentication Credentials

Both clusters use SCRAM-SHA-512 authentication. Admin users with full privileges have been created for both clusters.

#### Source Cluster (`es-demo`)

- **UI URL**: Get with: `oc get route es-demo-ibm-es-ui -n tools -o jsonpath='{.spec.host}'`
- **Username**: `es-admin`
- **Password**: Retrieve with:
  ```bash
  oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d && echo
  ```

#### Destination Cluster (`es-dest`)

- **UI URL**: Get with: `oc get route es-dest-ibm-es-ui -n event-streams-geo-replication -o jsonpath='{.spec.host}'`
- **Username**: `es-admin`
- **Password**: Retrieve with:
  ```bash
  oc get secret es-admin -n event-streams-geo-replication -o jsonpath='{.data.password}' | base64 -d && echo
  ```

**Note**: The `es-admin` users have full admin privileges including the ability to create topics, which is required for geo-replication setup.

### Step 6: Configure Destination Cluster Connection

Before you can replicate topics, you need to configure the connection between clusters:

1. **Log in to the destination cluster UI** using the `es-admin` credentials
2. Navigate to **Connect to this cluster** → **Geo-replication** tab
3. Click **"I want this cluster to be able to receive topics..."**
4. **Copy the connection snippet** (this contains the destination cluster connection details)
5. **Log in to the source cluster UI** using the `es-admin` credentials
6. Navigate to **Connect to this cluster** → **Geo-replication** tab
7. **Paste the connection snippet** from the destination cluster
8. Click **Save** or **Connect**

This establishes the connection between the two clusters and enables geo-replication.

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

# Get admin passwords
echo "Source cluster admin password:"
oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d && echo

echo "Destination cluster admin password:"
oc get secret es-admin -n event-streams-geo-replication -o jsonpath='{.data.password}' | base64 -d && echo
```

**Login Credentials:**
- **Source Cluster**: Username `es-admin`, password from command above
- **Destination Cluster**: Username `es-admin`, password from command above

#### 1.2: Create a Topic in Source Cluster

1. Open the source Event Streams UI in your browser: `https://${SOURCE_UI}`
2. **Log in** with username `es-admin` and the password retrieved above
3. Navigate to **Topics** → **Create topic**
4. Create a topic named `demo-geo-replication-topic`:
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

1. Open the destination Event Streams UI: `https://${DEST_UI}`
2. **Log in** with username `es-admin` and the password retrieved above
3. Navigate to **Topics**
4. Verify `demo-geo-replication-topic` appears (may take a few seconds)
5. Check topic details match the source topic

#### 1.5: Verify via CLI

```bash
# Get admin passwords
SOURCE_PASSWORD=$(oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d)
DEST_PASSWORD=$(oc get secret es-admin -n event-streams-geo-replication -o jsonpath='{.data.password}' | base64 -d)

# List topics in source cluster (using internal TLS listener)
oc exec -n tools es-demo-kafka-0 -- bin/kafka-topics.sh \
  --bootstrap-server localhost:9093 \
  --command-config <(echo "security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"es-admin\" password=\"${SOURCE_PASSWORD}\";") \
  --list

# List topics in destination cluster (using internal TLS listener)
oc exec -n event-streams-geo-replication es-dest-kafka-0 -- bin/kafka-topics.sh \
  --bootstrap-server localhost:9093 \
  --command-config <(echo "security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"es-admin\" password=\"${DEST_PASSWORD}\";") \
  --list

# Get topic details from destination
oc exec -n event-streams-geo-replication es-dest-kafka-0 -- bin/kafka-topics.sh \
  --bootstrap-server localhost:9093 \
  --command-config <(echo "security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"es-admin\" password=\"${DEST_PASSWORD}\";") \
  --topic demo-geo-replication-topic \
  --describe
```

**Note**: CLI commands require authentication. For easier verification, use the Event Streams UI which handles authentication automatically.

### Demonstration 2: Message Replication

This demonstrates producing messages to the source cluster and verifying they appear in the destination.

#### 2.1: Produce Messages to Source Cluster

Since the clusters use SCRAM-SHA-512 authentication, you need to provide credentials when producing messages. You can use a Python producer application:

**Option A: Using Python Producer (Recommended)**

1. **Create and activate a Python virtual environment (recommended):**
   ```bash
   # Create virtual environment with specific Python version
   # Option 1: Use python3.14 explicitly (if installed)
   python3.14 -m venv venv
   
   # Option 2: Use python3 (uses default Python 3 version)
   # python3 -m venv venv
   
   # Option 3: Use full path to specific Python version
   # /usr/local/bin/python3.14 -m venv venv
   # or
   # /opt/homebrew/bin/python3.14 -m venv venv  # For Homebrew on Apple Silicon
   
   # Activate virtual environment
   # On macOS/Linux:
   source venv/bin/activate
   # On Windows:
   # venv\Scripts\activate
   
   # Verify activation and Python version
   which python  # Should show path to venv/bin/python
   python --version  # Should show Python 3.14.x (or your specified version)
   ```
   
   **Note**: If `python3.14` is not found, check available Python versions:
   ```bash
   # List available Python versions
   ls -la /usr/local/bin/python*  # Common location
   ls -la /opt/homebrew/bin/python*  # Homebrew on Apple Silicon
   which -a python3.14  # Find python3.14 in PATH
   
   # Or use pyenv to manage Python versions
   pyenv versions  # List installed versions
   pyenv local 3.14  # Set local version (if using pyenv)
   ```

2. **Install dependencies:**
   ```bash
   # Install confluent-kafka
   pip install confluent-kafka
   
   # Or install from requirements.txt
   pip install -r requirements.txt
   
   # Verify installation
   pip list | grep confluent-kafka
   ```

3. **Get connection details:**

   **Primary Method: Using External Route (Recommended)**
   ```bash
   # Get bootstrap server (external route on port 9094)
   SOURCE_BOOTSTRAP=$(oc get route es-demo-kafka-bootstrap -n tools -o jsonpath='{.spec.host}'):9094
   echo "Bootstrap server: ${SOURCE_BOOTSTRAP}"
   
   # Get admin password
   ES_ADMIN_PASSWORD=$(oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d)
   echo "Username: es-admin"
   echo "Password: ${ES_ADMIN_PASSWORD}"
   ```
   
   The bootstrap server route should be accessible from your network since the Event Streams UI is accessible at:
   `https://es-demo-ibm-es-ui-tools.apps.6904486b9438192ae56fb793.ap1.techzone.ibm.com`

   **Note**: 
   - You don't need to generate credentials through the Event Streams UI. The `es-admin` user already has full admin privileges.
   - If the external route is not accessible, you can use port forwarding:
     ```bash
     # Terminal 1: Set up port forwarding (keep this running)
     oc port-forward svc/es-demo-kafka-external-bootstrap -n tools 9094:9094
     
     # Terminal 2: Use localhost as bootstrap server
     SOURCE_BOOTSTRAP="localhost:9094"
     ```

4. **Produce messages using the Python producer:**
   ```bash
   # Make sure you're in your virtual environment
   source venv/bin/activate  # or your venv path
   
   # Set up connection details (use external route)
   SOURCE_BOOTSTRAP=$(oc get route es-demo-kafka-bootstrap -n tools -o jsonpath='{.spec.host}'):9094
   ES_ADMIN_PASSWORD=$(oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d)
   
   # Single message
   python3 producer.py \
     --topic demo-geo-replication-topic \
     --bootstrap-server ${SOURCE_BOOTSTRAP} \
     --username es-admin \
     --password "${ES_ADMIN_PASSWORD}" \
     --message "Hello from source cluster"
   
   # Multiple messages
   python3 producer.py \
     --topic demo-geo-replication-topic \
     --bootstrap-server ${SOURCE_BOOTSTRAP} \
     --username es-admin \
     --password "${ES_ADMIN_PASSWORD}" \
     --message "Test message" \
     --count 10
   ```
   
   **Expected output:**
   ```
   ✅ Producer created: es-demo-kafka-bootstrap-tools.apps.6904486b9438192ae56fb793.ap1.techzone.ibm.com:9094
   ✅ Message delivered to demo-geo-replication-topic [partition 0] at offset 0
   ✅ All messages sent
   ```

   **Note**: When you're done, you can deactivate the virtual environment with:
   ```bash
   deactivate
   ```

**Option B: Produce via CLI with Authentication**

```bash
# Get admin password
ES_ADMIN_PASSWORD=$(oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d)

# Get Kafka bootstrap server (using internal TLS listener on port 9093)
SOURCE_BOOTSTRAP="es-demo-kafka-bootstrap.tools.svc.cluster.local:9093"

# Produce messages using Kafka console producer with SCRAM authentication
oc exec -n tools es-demo-kafka-0 -- bin/kafka-console-producer.sh \
  --bootstrap-server ${SOURCE_BOOTSTRAP} \
  --topic demo-geo-replication-topic \
  --producer-property security.protocol=SASL_SSL \
  --producer-property sasl.mechanism=SCRAM-SHA-512 \
  --producer-property sasl.jaas.config="org.apache.kafka.common.security.scram.ScramLoginModule required username=\"es-admin\" password=\"${ES_ADMIN_PASSWORD}\";"

# Type messages and press Enter after each:
# Message 1: Hello from source cluster
# Message 2: This is a test message
# Message 3: Geo-replication is working!
# Press Ctrl+D to exit
```

**Note**: The Python producer is recommended as it's easier to use and provides better feedback on message delivery.

#### 2.2: Consume Messages from Destination Cluster

**Option A: Consume via UI (Recommended)**
1. Log in to the destination Event Streams UI with `es-admin` credentials
2. Navigate to **Topics** → `demo-geo-replication-topic`
3. Click **Consume messages**
4. You should see the messages that were replicated from the source cluster

**Option B: Consume via CLI with Authentication**

```bash
# Get admin password
ES_ADMIN_PASSWORD=$(oc get secret es-admin -n event-streams-geo-replication -o jsonpath='{.data.password}' | base64 -d)

# Get Kafka bootstrap server (using internal TLS listener on port 9093)
DEST_BOOTSTRAP="es-dest-kafka-bootstrap.event-streams-geo-replication.svc.cluster.local:9093"

# Consume messages from destination cluster with SCRAM authentication
oc exec -n event-streams-geo-replication es-dest-kafka-0 -- bin/kafka-console-consumer.sh \
  --bootstrap-server ${DEST_BOOTSTRAP} \
  --topic demo-geo-replication-topic \
  --from-beginning \
  --consumer-property security.protocol=SASL_SSL \
  --consumer-property sasl.mechanism=SCRAM-SHA-512 \
  --consumer-property sasl.jaas.config="org.apache.kafka.common.security.scram.ScramLoginModule required username=\"es-admin\" password=\"${ES_ADMIN_PASSWORD}\";"

# You should see the messages you produced in the source cluster
```

#### 2.3: Verify Message Count

**Option A: Verify via UI (Recommended)**
1. In both source and destination UIs, navigate to the topic
2. Check the message count/offsets - they should match (after replication completes)

**Option B: Verify via CLI**

```bash
# Get admin passwords
SOURCE_PASSWORD=$(oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d)
DEST_PASSWORD=$(oc get secret es-admin -n event-streams-geo-replication -o jsonpath='{.data.password}' | base64 -d)

# Count messages in source topic
oc exec -n tools es-demo-kafka-0 -- bin/kafka-run-class.sh \
  kafka.tools.GetOffsetShell \
  --broker-list localhost:9093 \
  --topic demo-geo-replication-topic \
  --time -1 \
  --command-config <(echo "security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"es-admin\" password=\"${SOURCE_PASSWORD}\";")

# Count messages in destination topic
oc exec -n event-streams-geo-replication es-dest-kafka-0 -- bin/kafka-run-class.sh \
  kafka.tools.GetOffsetShell \
  --broker-list localhost:9093 \
  --topic demo-geo-replication-topic \
  --time -1 \
  --command-config <(echo "security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"es-admin\" password=\"${DEST_PASSWORD}\";")

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

### Connection Issues

If you get connection errors when running the producer:

**Solution 1: Use Port Forwarding**

If the external route is not accessible from your network:

```bash
# Terminal 1: Set up port forwarding (keep this running)
oc port-forward svc/es-demo-kafka-external-bootstrap -n tools 9094:9094

# Terminal 2: Run producer with localhost
SOURCE_BOOTSTRAP="localhost:9094"
ES_ADMIN_PASSWORD=$(oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d)

python3 producer.py \
  --topic demo-geo-replication-topic \
  --bootstrap-server ${SOURCE_BOOTSTRAP} \
  --username es-admin \
  --password "${ES_ADMIN_PASSWORD}" \
  --message "Test message"
```

**Solution 2: Verify Installation**

Make sure confluent-kafka is properly installed:

```bash
pip install --upgrade confluent-kafka
```

### UI Credential Generator Error

If you see an error when trying to generate credentials in the Event Streams UI (e.g., "An error occurred while generating your credentials"), follow these troubleshooting steps:

**Step 1: Run Troubleshooting Script**

```bash
# For source cluster
./troubleshoot-credential-generation.sh tools es-demo

# For destination cluster
./troubleshoot-credential-generation.sh event-streams-geo-replication es-dest
```

**Step 2: Fix RBAC Permissions (if needed)**

If the troubleshooting script shows missing RBAC permissions:

```bash
# For source cluster
./fix-adminui-credentials.sh tools es-demo

# For destination cluster
./fix-adminui-credentials.sh event-streams-geo-replication es-dest
```

**Step 2b: Fix Kafka User Permissions**

The adminAPI may require explicit `cluster.alter` permission. Update the es-admin user:

```bash
# For source cluster
./fix-ui-credential-generation.sh tools es-demo es-admin

# For destination cluster  
./fix-ui-credential-generation.sh event-streams-geo-replication es-dest es-admin
```

This script:
- Updates the KafkaUser to have explicit permissions (including `Alter`) instead of "All"
- Restarts the adminAPI to refresh permissions
- Provides next steps for testing

**Step 3: Restart Pods**

After fixing permissions, restart the adminUI and adminAPI pods:

```bash
# Source cluster
oc rollout restart deployment/es-demo-ibm-es-ui -n tools
oc rollout restart deployment/es-demo-ibm-es-admapi -n tools

# Destination cluster
oc rollout restart deployment/es-dest-ibm-es-ui -n event-streams-geo-replication
oc rollout restart deployment/es-dest-ibm-es-admapi -n event-streams-geo-replication
```

Wait for pods to be ready (about 1-2 minutes), then:
1. **Clear your browser cache** (Ctrl+Shift+Delete or Cmd+Shift+Delete)
2. **Hard refresh the Event Streams UI** (Ctrl+Shift+R or Cmd+Shift+R)
3. **Log out and log back in** to the Event Streams UI
4. Try generating credentials again

**Step 4: Enable Debug Logging**

Enable debug logging to get more detailed error messages:

```bash
# Source cluster
./enable-debug-logging.sh tools es-demo

# Destination cluster
./enable-debug-logging.sh event-streams-geo-replication es-dest
```

Wait for the pod to restart, then try generating credentials again and check the logs.

**Step 5: Check Browser Console**

If the error persists:
1. Open browser Developer Tools (F12)
2. Go to the Console tab
3. Try generating credentials again
4. Look for detailed error messages in the console
5. Check the Network tab for failed API requests
6. Look for the specific API endpoint that's failing (usually something like `/api/v1/kafka/users`)

**Step 6: Manual Workaround**

If credential generation still doesn't work, you can manually create KafkaUser resources using `oc`:

```bash
# Create a new KafkaUser manually
oc apply -f - <<EOF
apiVersion: eventstreams.ibm.com/v1beta2
kind: KafkaUser
metadata:
  name: my-external-user
  namespace: tools
  labels:
    eventstreams.ibm.com/cluster: es-demo
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
    - resource:
        type: topic
        name: '*'
        patternType: literal
      operations:
      - Read
      - Write
      - Create
      - Delete
EOF

# Get the generated credentials
oc get secret my-external-user -n tools -o jsonpath='{.data.username}' | base64 -d && echo
oc get secret my-external-user -n tools -o jsonpath='{.data.password}' | base64 -d && echo
```

**Solution 2: Use Existing Admin Credentials**

Alternatively, you can use the existing `es-admin` credentials without generating new ones:

```bash
# Get bootstrap server (correct port is 9094, not 443)
SOURCE_BOOTSTRAP=$(oc get route es-demo-kafka-bootstrap -n tools -o jsonpath='{.spec.host}'):9094
echo "Bootstrap server: ${SOURCE_BOOTSTRAP}"

# Get admin password
ES_ADMIN_PASSWORD=$(oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d)

# Use these credentials directly in your producer
python producer.py \
  --topic demo-geo-replication-topic \
  --bootstrap-server ${SOURCE_BOOTSTRAP} \
  --username es-admin \
  --password "${ES_ADMIN_PASSWORD}" \
  --message "Test message"
```

**Important Notes**:
- The correct port is **9094** (not 443)
- The bootstrap server format: `es-demo-kafka-bootstrap-tools.apps.6904486b9438192ae56fb793.ap1.techzone.ibm.com:9094`
- The `es-admin` user already has full admin privileges - no need to generate new credentials
- The UI credential generator error can be safely ignored

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

## Authentication Reference

### Retrieving Credentials

To retrieve admin passwords at any time:

```bash
# Source cluster admin password
oc get secret es-admin -n tools -o jsonpath='{.data.password}' | base64 -d && echo

# Destination cluster admin password
oc get secret es-admin -n event-streams-geo-replication -o jsonpath='{.data.password}' | base64 -d && echo
```

### Creating Additional Admin Users

If you need to create additional admin users with full privileges:

```bash
# For source cluster
cat <<EOF | oc apply -f -
apiVersion: eventstreams.ibm.com/v1beta2
kind: KafkaUser
metadata:
  name: your-admin-user
  namespace: tools
  labels:
    eventstreams.ibm.com/cluster: es-demo
spec:
  authentication:
    type: scram-sha-512
  authorization:
    type: simple
    acls:
      - resource:
          type: cluster
        operations:
          - All
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

# Password will be in secret: your-admin-user
oc get secret your-admin-user -n tools -o jsonpath='{.data.password}' | base64 -d && echo
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

