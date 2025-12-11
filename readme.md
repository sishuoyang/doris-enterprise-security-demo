# Apache Doris Enterprise Security Demo Stack Design

## Overview

This document describes a secure, enterprise-grade demo stack integrating Apache Doris, HDFS, Apache Ranger, OpenLDAP, and Kerberos authentication. The stack provides a complete data lakehouse solution with centralized authentication, authorization, and audit capabilities.

## Limitations
* This docker compose stack was only tested on Mac OS. It should work on other Linux platform too.
* Apache Doris currently does not support AD login to the Web UI (Doris Playground). Client-side AD login is supported.
* Ranger AD group sync is not supported in the demo.
## Architecture

![NBD Stack Architecture](images/arch.png)

## Getting Started

### Prerequisites

Before starting the demo stack, ensure you have:
- Docker and Docker Compose installed
- At least 16GB of **free** RAM
- Ports 389, 6080, 8030, 9030, 9000, 9870 available

### Starting the Stack

1. **Start all services**:
   ```bash
   cd doris-enterprise-security-demo
   ./start.sh
   ```

   The script will:
   - Check prerequisites
   - Create required directories
   - Start all services in the correct order
   - Wait for services to be healthy
   - Set up Ranger policies
   - Create Doris databases and tables

2. **Monitor startup progress**:
   The script provides detailed logging. Wait for "✓ All services are running" message.

3. **Verify services are running**:
   ```bash
   docker ps --filter "name=nbd" --format "table {{.Names}}\t{{.Status}}"
   ```

### Accessing Component UIs

#### Apache Doris Frontend (FE)
- **Web UI**: http://localhost:8030
  - Default credentials: `root` / (no password)
  - View cluster status, query execution, and system metrics
- **MySQL Protocol**: `localhost:9030`
  - Connect using MySQL client or JDBC
  - Example: `mysql -h127.0.0.1 -P9030 -uroot`

#### Apache Ranger Admin
- **Web UI**: http://localhost:6080
  - Default credentials: `admin` / `Admin123`
  - Manage policies, view audit logs, configure services
  - Navigate to: **Service Manager** > **doris_nbd** to view policies

#### HDFS NameNode
- **Web UI (HTTPS)**: https://localhost:9871
  - View HDFS cluster status, browse filesystem, check DataNodes
  - **Note**: Web UI is HTTPS-only due to secure cluster configuration (`dfs.http.policy = HTTPS_ONLY`)
  - SSL certificates are configured for HTTPS access
  - Data transfer is encrypted via `dfs.encrypt.data.transfer = true`
  - Kerberos authentication is used for service-to-service communication
  - If accessing from browser, you may need to accept the self-signed certificate

#### OpenLDAP
- **LDAP Protocol**: `localhost:389`
  - Use LDAP clients (e.g., `ldapsearch`, `ldapwhoami`) to query
  - Admin DN: `cn=admin,dc=sishuo,dc=demo`
  - Admin Password: `admin123`

### Testing LDAP Authentication

#### 1. Set LDAP Admin Password in Doris

After the stack starts, connect to Doris FE and set the LDAP admin password:

```bash
# Connect as root
mysql -h127.0.0.1 -P9030 -uroot

# Set LDAP admin password (must match OpenLDAP admin password)
SET ldap_admin_password = password('admin123');
```

#### 2. Test LDAP User Authentication

**Important**: MySQL clients require the clear text password plugin when connecting to Doris with LDAP authentication:

```bash
# Enable clear text password plugin (required for LDAP)
export LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN=1

# Test authentication with LDAP users
mysql -h127.0.0.1 -P9030 -uanalyst1 -ppassword123
mysql -h127.0.0.1 -P9030 -uanalyst2 -ppassword123
mysql -h127.0.0.1 -P9030 -uadmin -ppassword123
```

**Available LDAP Users** (all passwords: `password123`):
- `analyst1`, `analyst2` - Analysts group
- `admin` - Administrators group
- `dataengineer1` - Data engineers group
- `sales_user1`, `sales_user2` - Sales group
- `developer_user1`, `developer_user2` - Developers group
- `readonly_user1`, `readonly_user2` - Read-only users group

#### 3. Verify LDAP Authentication

After successful authentication, you should see:
```
Welcome to the MySQL monitor...
mysql> SELECT USER();
+----------------------+
| USER()               |
+----------------------+
| 'analyst1'@'...'     |
+----------------------+
```

If authentication fails, check:
- LDAP configuration in `doris/ldap.conf` (base DN should be `dc=sishuo,dc=demo`)
- LDAP admin password is set in Doris FE
- `LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN=1` is exported

### Testing Ranger Authorization

#### 1. Verify User/Group Sync in Ranger

Before testing authorization, ensure users and groups are synced from LDAP to Ranger:

1. **Access Ranger Admin UI**: http://localhost:6080
2. Navigate to: **Settings** > **Users/Groups** > **Users**
3. Verify users like `analyst1`, `analyst2` exist
4. Navigate to: **Settings** > **Users/Groups** > **Groups**
5. Verify groups like `analysts`, `admins`, `sales` exist

**Note**: If users/groups are missing, you may need to:
- Manually add users to groups via Ranger UI
- Or set up Ranger Usersync to automatically sync from LDAP

#### 2. View Ranger Policies

1. **Access Ranger Admin UI**: http://localhost:6080
2. Navigate to: **Service Manager** > **doris_nbd** > **Policies**
3. Review the following policies:

   **Group Policies**:
   - `group_admins_all_databases`: Full access for `admins` group
   - `group_analysts_demo_db_readonly`: Read-only for `analysts` group to `demo_db`
   - `group_sales_sales_db_rw`: Read/Write for `sales` group to `sales_db`
   - `group_developers_demo_db_products_orders_rw`: Read/Write for `developers` group
   - `group_data_engineers_demo_db_users_table`: Read/Write for `data_engineers` group

   **User Policies**:
   - `user_admin_all_databases_full`: Full access for `admin` user
   - `user_analyst2_demo_db_orders_readonly`: Read-only for `analyst2` to `demo_db.orders`
   - `user_sales_user1_sales_db_sales_rw`: Read/Write for `sales_user1`
   - `user_sales_user2_demo_db_products_rw`: Read/Write for `sales_user2`

#### 3. Test Authorization with Different Users

**Test 1: Analyst Group (Read-Only Access to demo_db)**

```bash
export LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN=1

# Connect as analyst1 (member of analysts group)
mysql -h127.0.0.1 -P9030 -uanalyst1 -ppassword123

# Should see demo_db in database list
mysql> SHOW DATABASES;
+--------------------+
| Database           |
+--------------------+
| demo_db            |
+--------------------+

# Should be able to read data
mysql> USE demo_db;
mysql> SHOW TABLES;
mysql> SELECT * FROM products LIMIT 10;

# Should NOT be able to write
mysql> INSERT INTO products VALUES (...);  -- Should fail with "Access denied"
mysql> CREATE TABLE test (id INT);         -- Should fail with "Access denied"
```

**Test 2: Admin User (Full Access)**

```bash
export LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN=1
mysql -h127.0.0.1 -P9030 -uadmin -ppassword123

# Should see all databases
mysql> SHOW DATABASES;
+--------------------+
| Database           |
+--------------------+
| __internal_schema  |
| demo_db            |
| information_schema |
| mysql              |
| sales_db           |
+--------------------+

# Should be able to create, read, write, delete
mysql> CREATE DATABASE test_db;
mysql> USE test_db;
mysql> CREATE TABLE test (id INT);
mysql> INSERT INTO test VALUES (1);
mysql> SELECT * FROM test;
```

**Test 3: Sales Group (Read/Write to sales_db only)**

```bash
export LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN=1
mysql -h127.0.0.1 -P9030 -usales_user1 -ppassword123

# Should see sales_db
mysql> SHOW DATABASES;
+--------------------+
| Database           |
+--------------------+
| sales_db            |
+--------------------+

# Should be able to read and write in sales_db
mysql> USE sales_db;
mysql> SELECT * FROM sales;
mysql> INSERT INTO sales VALUES (...);  -- Should succeed

# Should NOT see demo_db
mysql> USE demo_db;  -- Should fail with "Access denied"
```

#### 4. View Authorization Audit Logs

1. **Access Ranger Admin UI**: http://localhost:6080
2. Navigate to: **Audit** > **Access**
3. Filter by:
   - **Service**: `doris_nbd`
   - **User**: `analyst1`, `admin`, etc.
   - **Resource**: `demo_db`, `sales_db`, etc.
4. Review access attempts, including:
   - Successful queries
   - Denied access attempts
   - Resource accessed
   - Timestamp and client IP

#### 5. Troubleshooting Authorization Issues

If authorization is not working:

1. **Check Policy Cache**:
   ```bash
   # Clear policy cache in Doris FE
   docker exec nbd-doris-fe rm -rf /opt/apache-doris/fe/conf/ranger-policy-cache/*
   # Wait 30 seconds for policy refresh
   ```

2. **Verify User Group Membership**:
   - In Ranger UI: **Settings** > **Users/Groups** > **Users** > `analyst1`
   - Ensure `analysts` group is listed in the user's groups

3. **Check Doris FE Logs**:
   ```bash
   docker logs nbd-doris-fe | grep -i "ranger\|authorization\|access denied"
   ```

4. **Verify Policy is Enabled**:
   - In Ranger UI, ensure the policy has `Is Enabled` checked

5. **Check Policy Resource Scope**:
   - Ensure the policy's resource scope matches what you're trying to access
   - Policy ID 12 (`group_analysts_demo_db_readonly`) should grant access to `demo_db.*`

### Quick Reference

| Component | URL/Endpoint | Credentials |
|-----------|-------------|-------------|
| Doris FE Web UI | http://localhost:8030 | `root` / (no password) |
| Doris MySQL | `localhost:9030` | `root` / (no password) or LDAP users |
| Ranger Admin | http://localhost:6080 | `admin` / `Admin123` |
| HDFS NameNode | https://localhost:9871 | SSL certificate required (self-signed) |
| OpenLDAP | `localhost:389` | `cn=admin,dc=sishuo,dc=demo` / `admin123` |

## Doris Configuration

This section explains how Apache Doris is configured to integrate with LDAP, Kerberos, Apache Ranger, and HDFS in the NBD demo stack.

### Configuration File Structure

Doris configuration files are located in the `doris/` directory and are mounted into the containers via `docker-compose.yml`:

- **Frontend (FE)**: `doris/fe.conf`, `doris/ldap.conf`, `doris/ranger-doris-security.xml`, `doris/ranger-doris-audit.xml`
- **Backend (BE)**: `doris/be.conf`
- **HDFS Integration**: `doris/core-site.xml`, `doris/hdfs-site.xml` (mounted to both FE and BE)

### 1. LDAP Authentication Integration

Refer to the official documentation for LDAP configurations: https://doris.apache.org/docs/3.x/admin-manual/auth/ldap

Doris FE uses LDAP for user authentication, allowing users to authenticate using their LDAP credentials instead of local Doris accounts.

#### Configuration File: `doris/ldap.conf`

```ini
# LDAP service connection
ldap_host = ldap.nbd.demo
ldap_port = 389

# LDAP administrator account Distinguished Name
# This account is used by Doris to bind and search for user information in LDAP
ldap_admin_name = cn=admin,dc=sishuo,dc=demo

# Base DN for searching user information in LDAP
ldap_user_basedn = ou=users,dc=sishuo,dc=demo

# Filter criteria when searching for user information in LDAP
# The placeholder "{login}" will be replaced with the login username
ldap_user_filter = (&(uid={login}))

# Base DN for searching group information in LDAP
ldap_group_basedn = ou=groups,dc=sishuo,dc=demo

# LDAP information cache timeout in seconds (12 hours)
ldap_user_cache_timeout_s = 43200
```

#### FE Configuration: `doris/fe.conf`

```conf
# Authentication Configuration
authentication_type = ldap
enable_ldap_auth = true
```

**Key Points**:
- `ldap_host` and `ldap_port` point to the OpenLDAP service
- `ldap_admin_name` allow Doris to bind to LDAP for user lookups
- `ldap_user_basedn` and `ldap_user_filter` define where and how to search for users
- `ldap_group_basedn` enables group-based authorization (used with Ranger)
- After configuration, you must set the LDAP admin password in Doris: `SET ldap_admin_password = password('admin123');`

### 2. Kerberos Authentication Integration

Kerberos provides service-level authentication for secure communication between Doris components and HDFS.

#### FE Configuration: `doris/fe.conf`

```conf
# Kerberos authentication can coexist with LDAP
enable_kerberos_auth = true
kerberos_principal = doris/fe1.nbd.demo@SISHUO.DEMO
kerberos_keytab = /etc/security/keytabs/doris-fe.keytab
```

#### BE Configuration: `doris/be.conf`

```conf
# Kerberos Configuration
kerberos_principal = doris/be1.nbd.demo@SISHUO.DEMO
kerberos_keytab = /etc/security/keytabs/doris-be.keytab
```

**Key Points**:
- Each Doris component (FE and BE) has its own Kerberos principal
- Keytabs are mounted from `data/kerberos/keytabs/` into `/etc/security/keytabs/` in containers
- Kerberos realm is `SISHUO.DEMO` (as configured in the Kerberos KDC)
- Kerberos authentication is used for:
  - Service-to-service communication
  - HDFS access (see HDFS Integration section)

### 3. Apache Ranger Authorization Integration

Apache Ranger provides centralized authorization and audit capabilities for Doris, allowing fine-grained access control based on user/group policies.

Refer to the official documentation: https://doris.apache.org/docs/3.x/admin-manual/auth/ranger

#### Installing the Ranger Doris Plugin

The Ranger Doris plugin is automatically installed by the `start.sh` script during the `setup_ranger_plugins()` phase:

1. **Plugin JAR Download**: The script downloads the plugin JAR from:
   ```
   https://selectdb-doris-1308700295.cos.ap-beijing.myqcloud.com/ranger/ranger-doris-plugin-3.0.0-SNAPSHOT.jar
   ```

2. **Plugin Location**: The plugin is stored at:
   ```
   data/ranger/plugins/doris/ranger-doris-plugin-3.0.0-SNAPSHOT.jar
   ```

3. **Plugin Mounting**: The plugin directory is mounted into the Ranger Admin container:
   ```yaml
   volumes:
     - ./data/ranger/plugins:/opt/ranger/ranger-2.4.0-admin/ews/webapp/WEB-INF/classes/ranger-plugins:ro
   ```

4. **Manual Installation** (if automatic download fails):
   ```bash
   mkdir -p data/ranger/plugins/doris
   wget https://selectdb-doris-1308700295.cos.ap-beijing.myqcloud.com/ranger/ranger-doris-plugin-3.0.0-SNAPSHOT.jar \
     -O data/ranger/plugins/doris/ranger-doris-plugin-3.0.0-SNAPSHOT.jar
   ```

**Note**: The plugin must be present before Ranger Admin starts, as it needs to be loaded during Ranger initialization.

#### Service Definition and Instance Creation

The demo stack automatically creates the Ranger service definition and instance:

1. **Service Definition Upload**: The `start.sh` script uploads the Doris service definition from `ranger/ranger-servicedef-doris.json` to Ranger Admin via REST API:
   ```bash
   curl -u admin:Admin123 -X POST \
     -H 'Content-Type: application/json' \
     http://localhost:6080/service/plugins/definitions \
     -d @ranger/ranger-servicedef-doris.json
   ```

2. **Service Instance Creation**: Creates a service instance named `doris_nbd`:
   ```json
   {
     "name": "doris_nbd",
     "type": "doris",
     "description": "Apache Doris service for NBD demo",
     "configs": {
       "username": "root",
       "password": "",
       "jdbc.driverClassName": "com.mysql.cj.jdbc.Driver",
       "jdbc.url": "jdbc:mysql://fe1.nbd.demo:9030"
     },
     "isEnabled": true
   }
   ```

3. **Service Name Matching**: The service name `doris_nbd` must match the value in `ranger-doris-security.xml`:
   ```xml
   <property>
       <name>ranger.plugin.doris.service.name</name>
       <value>doris_nbd</value>
   </property>
   ```

#### Policy Creation in the Demo Stack

The demo stack creates policies automatically using helper scripts:

1. **Default Root User Policy**: Created by `start.sh` during `create_ranger_doris_default_policy()`:
   - Grants the `root` user all privileges on all resources
   - Required because Ranger blocks all access by default when no policies exist
   - Ensures the root user can perform administrative tasks

2. **User and Group Policies**: Created by `scripts/setup-ranger-policies-redesigned.sh`:
   - Called automatically after Doris services start
   - Creates non-overlapping policies for different users and groups
   - Uses the Ranger REST API to create/update policies

3. **Policy Creation Process**:
   ```bash
   # The script uses the Ranger REST API
   curl -u admin:Admin123 -X POST \
     -H 'Content-Type: application/json' \
     http://localhost:6080/service/public/v2/api/policy \
     -d @policy.json
   ```

4. **Policy Script Location**: `scripts/setup-ranger-policies-redesigned.sh`
   - Creates group-based policies (e.g., `analysts`, `admins`, `sales`)
   - Creates user-based policies (e.g., `analyst1`, `analyst2`, `admin`)
   - Handles policy conflicts by updating or deleting existing policies

#### Ranger Plugin Configuration: `doris/ranger-doris-security.xml`

```xml
<configuration>
    <!-- Ranger Admin Service Configuration -->
    <property>
        <name>ranger.plugin.doris.service.name</name>
        <value>doris_nbd</value>
        <description>Name of the Ranger service for Doris</description>
    </property>

    <property>
        <name>ranger.plugin.doris.policy.source.impl</name>
        <value>org.apache.ranger.admin.client.RangerAdminRESTClient</value>
        <description>Class to retrieve policies from the source</description>
    </property>

    <property>
        <name>ranger.plugin.doris.policy.rest.url</name>
        <value>http://ranger.nbd.demo:6080</value>
        <description>URL to Ranger Admin</description>
    </property>

    <property>
        <name>ranger.plugin.doris.policy.pollIntervalMs</name>
        <value>30000</value>
        <description>How often to poll for changes in policies? (30 seconds)</description>
    </property>

    <property>
        <name>ranger.plugin.doris.policy.cache.dir</name>
        <value>/opt/apache-doris/fe/conf/ranger-policy-cache</value>
        <description>Directory where policies are cached</description>
    </property>

    <!-- Audit Configuration -->
    <property>
        <name>ranger.plugin.doris.audit.enabled</name>
        <value>true</value>
        <description>Enable audit logging</description>
    </property>
</configuration>
```

#### FE Configuration: `doris/fe.conf`

```conf
# Ranger Integration
# Enable Ranger access controller for unified permission management
access_controller_type = ranger-doris
```

**Key Points**:
- `ranger.plugin.doris.service.name` must match the service name created in Ranger Admin
- Policies are polled from Ranger Admin every 30 seconds and cached locally
- Audit logging is enabled to track all access attempts
- Ranger policies can be based on:
  - **Users**: Individual user access (e.g., `analyst1`, `admin`)
  - **Groups**: Group-based access (e.g., `analysts`, `admins`, `sales`)
  - **Resources**: Database, table, and column-level permissions

**Policy Evaluation Flow**:
1. User authenticates via LDAP
2. Doris FE receives query request
3. Ranger plugin checks cached policies
4. Access is granted or denied based on matching policies
5. Audit log entry is created in Ranger

#### Required Privileges for Doris Root User

The Doris default `root` user requires comprehensive privileges to perform administrative tasks and access internal schemas. The demo stack creates a default policy (`root_all_privileges`) that grants:

**Access Types**:
- `SELECT`: Query data from tables
- `CREATE`: Create databases, tables, and other objects
- `DROP`: Delete databases, tables, and other objects
- `ALTER`: Modify database and table structures
- `LOAD`: Load data into tables
- `GRANT`: Grant privileges to other users
- `SHOW`: Show database/table information
- `SHOW_VIEW`: Show view definitions
- `ADMIN`: Administrative privileges (required for internal schema access)
- `NODE`: Node management privileges
- `USAGE`: Usage privileges

**Resource Scope**:
- `catalog: *` (all catalogs)
- `database: *` (all databases, including `__internal_schema`)
- `table: *` (all tables)
- `column: *` (all columns)

**Policy Configuration**:
```json
{
  "name": "root_all_privileges",
  "description": "Default policy allowing root user all privileges on all Doris resources",
  "resources": {
    "catalog": {"values": ["*"]},
    "database": {"values": ["*"]},
    "table": {"values": ["*"]},
    "column": {"values": ["*"]}
  },
  "policyItems": [{
    "accesses": [
      {"type": "SELECT", "isAllowed": true},
      {"type": "CREATE", "isAllowed": true},
      {"type": "DROP", "isAllowed": true},
      {"type": "ALTER", "isAllowed": true},
      {"type": "LOAD", "isAllowed": true},
      {"type": "GRANT", "isAllowed": true},
      {"type": "SHOW", "isAllowed": true},
      {"type": "SHOW_VIEW", "isAllowed": true},
      {"type": "ADMIN", "isAllowed": true},
      {"type": "NODE", "isAllowed": true},
      {"type": "USAGE", "isAllowed": true}
    ],
    "users": ["root"],
    "delegateAdmin": true
  }]
}
```

**Key Points**:
- `ADMIN` and `NODE` privileges are **critical** for accessing Doris internal schemas like `__internal_schema`
- `delegateAdmin: true` allows the root user to grant privileges to other users
- Without this policy, the root user would be blocked by Ranger's default deny-all behavior
- The policy is created automatically by `start.sh` during the `create_ranger_doris_default_policy()` function

### 4. HDFS Integration

Doris integrates with HDFS for external table storage and data lake access. Both FE and BE require HDFS configuration for Kerberos-authenticated access.

#### HDFS Core Configuration: `doris/core-site.xml`

```xml
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://namenode.nbd.demo:9000</value>
    </property>
    
    <!-- Kerberos configuration -->
    <property>
        <name>hadoop.security.authentication</name>
        <value>kerberos</value>
    </property>
    <property>
        <name>hadoop.security.authorization</name>
        <value>true</value>
    </property>
    <property>
        <name>hadoop.rpc.protection</name>
        <value>authentication,privacy</value>
    </property>
    <property>
        <name>dfs.data.transfer.protection</name>
        <value>authentication</value>
    </property>
</configuration>
```

#### HDFS Site Configuration: `doris/hdfs-site.xml`

```xml
<configuration>
    <property>
        <name>dfs.namenode.rpc-address</name>
        <value>namenode.nbd.demo:9000</value>
    </property>
    <property>
        <name>dfs.replication</name>
        <value>1</value>
    </property>
    <property>
        <name>dfs.permissions.enabled</name>
        <value>true</value>
    </property>
    <!-- Additional Kerberos and security properties... -->
</configuration>
```

#### FE Configuration: `doris/fe.conf`

```conf
# HDFS Integration
# Use dedicated Doris HDFS client principal (best practice for security and auditability)
hdfs_kerberos_principal = doris/hdfs-client.nbd.demo@SISHUO.DEMO
hdfs_kerberos_keytab = /etc/security/keytabs/doris-hdfs-client.keytab
```

#### BE Configuration: `doris/be.conf`

```conf
# HDFS Configuration
# Use dedicated Doris HDFS client principal for HDFS access
hdfs_kerberos_principal = doris/hdfs-client.nbd.demo@SISHUO.DEMO
hdfs_kerberos_keytab = /etc/security/keytabs/doris-hdfs-client.keytab
```

**Key Points**:
- Both FE and BE use the same HDFS client principal (`doris/hdfs-client.nbd.demo@SISHUO.DEMO`)
- This dedicated principal allows for better security isolation and auditability
- HDFS is configured with Kerberos authentication and encrypted data transfer
- `fs.defaultFS` points to the HDFS NameNode RPC address
- HDFS configuration files are mounted to both FE and BE containers

**HDFS Access Flow**:
1. Doris component (FE/BE) authenticates to Kerberos KDC using `doris/hdfs-client` principal
2. Obtains service ticket for HDFS NameNode
3. Accesses HDFS using Kerberos-authenticated connection
4. Data transfer is encrypted (`dfs.encrypt.data.transfer = true`)

### Configuration File Mounting

The following volumes are mounted in `docker-compose.yml` for Doris FE:

```yaml
volumes:
  - ./data/doris/fe/conf:/opt/apache-doris/fe/conf
  - ./doris/fe.conf:/opt/apache-doris/fe/conf/fe.conf
  - ./doris/ldap.conf:/opt/apache-doris/fe/conf/ldap.conf:ro
  - ./doris/ranger-doris-security.xml:/opt/apache-doris/fe/conf/ranger-doris-security.xml:ro
  - ./doris/ranger-doris-audit.xml:/opt/apache-doris/fe/conf/ranger-doris-audit.xml:ro
  - ./data/kerberos/keytabs:/etc/security/keytabs:ro
  - ./kerberos/krb5.conf:/etc/krb5.conf:ro
```

**Note**: HDFS configuration files (`core-site.xml`, `hdfs-site.xml`) are copied to `data/doris/fe/conf/` and `data/doris/be/conf/` by the `start.sh` script during the `setup_configuration()` phase.

### Integration Summary

| Integration | Purpose | Configuration Files | Key Settings |
|------------|---------|-------------------|--------------|
| **LDAP** | User authentication | `doris/ldap.conf`, `doris/fe.conf` | `authentication_type = ldap`, `ldap_host`, `ldap_user_basedn` |
| **Kerberos** | Service authentication | `doris/fe.conf`, `doris/be.conf` | `enable_kerberos_auth = true`, `kerberos_principal`, `kerberos_keytab` |
| **Ranger** | Authorization & audit | `doris/ranger-doris-security.xml`, `doris/fe.conf` | `access_controller_type = ranger-doris`, `ranger.plugin.doris.service.name` |
| **HDFS** | External storage | `doris/core-site.xml`, `doris/hdfs-site.xml`, `doris/fe.conf`, `doris/be.conf` | `fs.defaultFS`, `hdfs_kerberos_principal` |

### Verification

To verify the configuration is working:

1. **LDAP Authentication**: Connect with LDAP user credentials
   ```bash
   export LIBMYSQL_ENABLE_CLEARTEXT_PLUGIN=1
   mysql -h127.0.0.1 -P9030 -uanalyst1 -ppassword123
   ```

2. **Ranger Authorization**: Check policies in Ranger Admin UI (http://localhost:6080) and verify access is controlled

3. **HDFS Access**: Create external tables pointing to HDFS paths and verify data access

4. **Kerberos**: Check logs for successful Kerberos authentication:
   ```bash
   docker logs nbd-doris-fe | grep -i kerberos
   ```