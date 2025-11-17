# API Connect Login Guide

## Overview

API Connect has two separate interfaces:
- **Admin Console**: For managing organizations, user registries, and platform settings
- **API Manager**: For API development and management (requires a user in API Manager Local User Registry)

## Step 1: Login to Admin Console (Cloud Manager)

**Admin Console** (also called **Cloud Manager**) is where you manage organizations, user registries, and platform settings. You need to login here first to create users in the API Manager Local User Registry.

### Get Admin Console URL and Credentials

Run these commands to get the login information for Cloud Manager:

```bash
# 1. Get Admin Console URL
oc get apiconnectcluster apic-demo -n tools -o jsonpath='{.status.endpoints[?(@.name=="admin")].uri}' && echo

# 2. Get username to login to Cloud Manager
oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.username}' | base64 -d && echo

# 3. Get password to login to Cloud Manager
oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.password}' | base64 -d && echo
```

**Example output:**
```
https://apic-demo-mgmt-admin-tools.apps.example.com/admin
integration-admin
e4a6a8b9128386d439f143c1b406e3
```

### Login Steps

1. **Open the Admin Console URL** in your browser (from command #1 above)
   - The URL should end with `/admin`
   - This is the **Cloud Manager** interface
2. **Enter credentials**:
   - **Username**: Use the username from command #2 above (usually `integration-admin`)
   - **Password**: Use the password from command #3 above
3. Click **"Sign In"** or **"Login"**
4. **First time setup** (if needed):
   - Navigate to **Resources → Organizations**
   - Click **"Create Organization"**
   - Fill in organization details and save
   - This is required before users can access API Manager

## Step 2: Create User in API Manager Local User Registry

API Manager uses a separate Local User Registry. You must create a user there before you can login to API Manager.

### Option A: Check if Script Created User Automatically

The installation script may have automatically created an `apidev` user:

```bash
# Check if apidev credentials exist
oc get secret apic-demo-apidev-credentials -n tools -o jsonpath='{.data.username}' | base64 -d && echo
oc get secret apic-demo-apidev-credentials -n tools -o jsonpath='{.data.password}' | base64 -d && echo
```

If the secret exists, you can use these credentials to login to API Manager (see Step 3).

### Option B: Create User Manually via Admin Console (Cloud Manager)

If the `apidev` user doesn't exist or you want to create a different user:

1. **Login to Admin Console (Cloud Manager)**:
   ```bash
   # Get URL
   oc get apiconnectcluster apic-demo -n tools -o jsonpath='{.status.endpoints[?(@.name=="admin")].uri}' && echo
   
   # Get username
   oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.username}' | base64 -d && echo
   
   # Get password
   oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.password}' | base64 -d && echo
   ```
   - Open the URL in browser and login with the username and password from the commands above
2. Navigate to **Resources → User Registries**
3. Find and click on **"API Manager Local User Registry"** (may also be named "Providers" or similar)
4. Click the **"Users"** tab
5. Click **"Add User"** button
6. Fill in user details:
   - **Username**: Choose a username (e.g., `apidev`, `apiadmin`)
   - **Email**: User email address
   - **Password**: Choose a secure password
   - **First Name**: User's first name
   - **Last Name**: User's last name
7. Click **"Save"**
8. **Add user to organization**:
   - Navigate to **Resources → Organizations** → [Your Organization]
   - Click **"Members"** tab
   - Click **"Add Member"**
   - Select the user you just created
   - Assign role: **Administrator** (or appropriate role)
   - Click **"Save"**

## Step 3: Login to API Manager

### Get API Manager URL

```bash
oc get apiconnectcluster apic-demo -n tools -o jsonpath='{.status.endpoints[?(@.name=="ui")].uri}'
```

### Login Steps

1. Open the API Manager URL from the command above
2. **Important**: Select **"API Manager"** as the login type (NOT "Cloud Pak User registry")
3. Enter credentials:
   - **Username**: The username you created in API Manager Local User Registry (e.g., `apidev`)
   - **Password**: The password you set for that user
4. Click **"Sign In"**

## Troubleshooting

### Can't Find User Registries in Admin Console

- Make sure you're logged into **Admin Console**, not API Manager
- The URL should end with `/admin`
- Check that you have admin privileges

### Login to API Manager Fails

1. **Verify login type**: Make sure you selected **"API Manager"** (not "Cloud Pak User registry")
2. **Check user exists**: Verify the user was created in API Manager Local User Registry (Admin Console → Resources → User Registries → API Manager Local User Registry → Users)
3. **Check organization membership**: Ensure the user is added to an organization with appropriate role
4. **Try different credentials**: If using `apidev`, check the secret:
   ```bash
   oc get secret apic-demo-apidev-credentials -n tools -o yaml
   ```

### No Organization Exists

You must create an organization in Admin Console before users can access API Manager:
1. Login to Admin Console
2. Navigate to **Resources → Organizations**
3. Click **"Create Organization"**
4. Fill in organization details and save

### User Created But Can't Login

- Ensure the user is added to an organization
- Verify the user has appropriate role (Administrator recommended for full access)
- Check that you're using the correct login type: **"API Manager"**

## Quick Reference

```bash
# Admin Console URL (Method 1: from status)
oc get apiconnectcluster apic-demo -n tools -o jsonpath='{.status.endpoints[?(@.name=="admin")].uri}' && echo

# Admin Console URL (Method 2: from route - use if status not ready)
oc get route apic-demo-mgmt-admin -n tools -o jsonpath='https://{.spec.host}/admin' && echo

# Admin Console credentials (Cloud Manager uses Platform Navigator credentials)
oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.username}' | base64 -d && echo
oc get secret integration-admin-initial-temporary-credentials -n ibm-common-services -o jsonpath='{.data.password}' | base64 -d && echo

# API Manager URL
oc get apiconnectcluster apic-demo -n tools -o jsonpath='{.status.endpoints[?(@.name=="ui")].uri}'

# Check if apidev user exists
oc get secret apic-demo-apidev-credentials -n tools 2>/dev/null && \
  echo "Username: $(oc get secret apic-demo-apidev-credentials -n tools -o jsonpath='{.data.username}' | base64 -d)" && \
  echo "Password: $(oc get secret apic-demo-apidev-credentials -n tools -o jsonpath='{.data.password}' | base64 -d)"
```
