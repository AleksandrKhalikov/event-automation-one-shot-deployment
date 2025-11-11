# API Connect API Manager Login Instructions

## The Problem
API Manager uses a separate Local User Registry (LUR) from the Admin Console. By default, no users exist in the API Manager LUR, so you cannot login to API Manager directly.

## Solution: Access via Admin Console

### Step 1: Login to Admin Console
- URL: https://apic-demo-mgmt-admin-tools.apps.6904486b9438192ae56fb793.ap1.techzone.ibm.com/admin
- Username: `admin@apiconnect.net`
- Password: `c509T2!zz=)C~!(0(x,&<^cx`

### Step 2: Navigate to User Registries
In the Admin Console:
1. Click on **"Resources"** (top menu)
2. Click on **"User Registries"** in the left sidebar
3. You should see several registries listed

### Step 3: Find the API Manager Local User Registry
Look for a registry with type "Local User Registry" that is associated with API Manager. It might be named:
- "Providers" (default)
- "API Manager Local User Registry"
- Or similar

### Step 4: Add Users
1. Click on the API Manager Local User Registry
2. Click on the **"Users"** tab
3. Click **"Add User"** button
4. Fill in:
   - Username: `admin` (or your preferred username)
   - Email: `admin@example.com`
   - Password: (choose a password)
   - First Name: Admin
   - Last Name: User
5. Click **"Save"**

### Step 5: Login to API Manager
Now you can login to API Manager:
- URL: https://apic-demo-mgmt-api-manager-tools.apps.6904486b9438192ae56fb793.ap1.techzone.ibm.com/auth/manager/sign-in/
- Username: `admin` (the one you just created)
- Password: (the password you set)
- **Important:** Select "API Manager" as the login type (not "Cloud Pak User registry")

## Alternative: Check if Default User Exists
Sometimes API Connect creates a default user. Try:
- Username: `admin`
- Password: Same as Admin Console password (`c509T2!zz=)C~!(0(x,&<^cx`)
- Login Type: API Manager

## If You Still Can't Find User Registries
1. Make sure you're logged into the Admin Console (Cloud Manager), not API Manager
2. Check that you have admin privileges
3. The User Registries section might be under "Settings" → "User Registries" instead of "Resources"
