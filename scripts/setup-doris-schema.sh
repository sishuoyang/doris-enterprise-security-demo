#!/bin/bash
#
# Setup Doris Databases and Tables
#
# This script creates sample databases and tables in Doris for the NBD demo.
# It connects to Doris FE using MySQL protocol and creates:
# - demo_db: Main demo database with sample tables
# - sales_db: Sales database with customer and order tables
#
# Usage: ./setup-doris-schema.sh [options]
#   --host HOST       Doris FE host (default: 127.0.0.1)
#   --port PORT       Doris FE MySQL port (default: 9030)
#   --user USER       Doris user (default: root)
#   --password PASS    Doris password (default: empty)
#   --skip-existing   Skip creating databases/tables that already exist
#   --help            Show this help message

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default configuration
DORIS_HOST="${DORIS_HOST:-127.0.0.1}"
DORIS_PORT="${DORIS_PORT:-9030}"
DORIS_USER="${DORIS_USER:-root}"
DORIS_PASSWORD="${DORIS_PASSWORD:-}"
SKIP_EXISTING=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --host)
            DORIS_HOST="$2"
            shift 2
            ;;
        --port)
            DORIS_PORT="$2"
            shift 2
            ;;
        --user)
            DORIS_USER="$2"
            shift 2
            ;;
        --password)
            DORIS_PASSWORD="$2"
            shift 2
            ;;
        --skip-existing)
            SKIP_EXISTING=true
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --host HOST       Doris FE host (default: 127.0.0.1)"
            echo "  --port PORT       Doris FE MySQL port (default: 9030)"
            echo "  --user USER        Doris user (default: root)"
            echo "  --password PASS    Doris password (default: empty)"
            echo "  --skip-existing   Skip creating databases/tables that already exist"
            echo "  --help             Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}→${NC} $1"
}

# Check if MySQL client is available
check_mysql_client() {
    if ! command -v mysql &> /dev/null; then
        log_error "MySQL client not found. Please install mysql-client:"
        log_error "  macOS: brew install mysql-client"
        log_error "  Ubuntu/Debian: apt-get install mysql-client"
        log_error "  RHEL/CentOS: yum install mysql"
        exit 1
    fi
}

# Connect to Doris and execute SQL
execute_sql() {
    local sql="$1"
    local db="${2:-}"
    
    local mysql_cmd="mysql --protocol=TCP -h${DORIS_HOST} -P${DORIS_PORT} -u${DORIS_USER}"
    
    if [ -n "$DORIS_PASSWORD" ]; then
        mysql_cmd="${mysql_cmd} -p${DORIS_PASSWORD}"
    fi
    
    if [ -n "$db" ]; then
        mysql_cmd="${mysql_cmd} ${db}"
    fi
    
    eval "${mysql_cmd} -e \"${sql}\"" 2>&1 || {
        log_error "Failed to execute SQL: ${sql}"
        return 1
    }
}

# Check if database exists
database_exists() {
    local db_name="$1"
    local result=$(execute_sql "SHOW DATABASES LIKE '${db_name}';" 2>/dev/null || echo "")
    echo "$result" | grep -q "^${db_name}$" && return 0 || return 1
}

# Check if table exists
table_exists() {
    local db_name="$1"
    local table_name="$2"
    local result=$(execute_sql "USE ${db_name}; SHOW TABLES LIKE '${table_name}';" 2>/dev/null || echo "")
    echo "$result" | grep -q "^${table_name}$" && return 0 || return 1
}

# Wait for Doris FE to be ready
wait_for_doris() {
    log_step "Waiting for Doris FE to be ready..."
    local max_attempts=30
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        if execute_sql "SELECT 1;" &>/dev/null; then
            log_info "Doris FE is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    
    log_error "Doris FE is not ready after $((max_attempts * 2)) seconds"
    return 1
}

# Create demo_db database and tables
create_demo_db() {
    log_step "Creating demo_db database..."
    
    if database_exists "demo_db"; then
        if [ "$SKIP_EXISTING" = true ]; then
            log_info "Database 'demo_db' already exists, skipping..."
            return 0
        else
            log_warn "Database 'demo_db' already exists"
        fi
    fi
    
    execute_sql "CREATE DATABASE IF NOT EXISTS demo_db;"
    log_info "✓ Database 'demo_db' created"
    
    # Create users table
    log_step "Creating users table..."
    if ! table_exists "demo_db" "users"; then
        execute_sql "USE demo_db; CREATE TABLE IF NOT EXISTS users (
            id BIGINT NOT NULL,
            username VARCHAR(50) NOT NULL,
            email VARCHAR(100),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            status VARCHAR(20) DEFAULT 'active'
        ) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 10
        PROPERTIES (
            'replication_num' = '1',
            'storage_format' = 'V2'
        );"
        log_info "✓ Table 'users' created"
    else
        log_info "Table 'users' already exists"
    fi
    
    # Create products table
    log_step "Creating products table..."
    if ! table_exists "demo_db" "products"; then
        execute_sql "USE demo_db; CREATE TABLE IF NOT EXISTS products (
            id BIGINT NOT NULL,
            name VARCHAR(200) NOT NULL,
            category VARCHAR(50),
            price DECIMAL(10,2),
            stock INT DEFAULT 0,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        ) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 10
        PROPERTIES (
            'replication_num' = '1',
            'storage_format' = 'V2'
        );"
        log_info "✓ Table 'products' created"
    else
        log_info "Table 'products' already exists"
    fi
    
    # Create orders table
    log_step "Creating orders table..."
    if ! table_exists "demo_db" "orders"; then
        execute_sql "USE demo_db; CREATE TABLE IF NOT EXISTS orders (
            id BIGINT NOT NULL,
            user_id BIGINT NOT NULL,
            product_id BIGINT NOT NULL,
            quantity INT DEFAULT 1,
            total_amount DECIMAL(10,2),
            order_date DATETIME DEFAULT CURRENT_TIMESTAMP,
            status VARCHAR(20) DEFAULT 'pending'
        ) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 10
        PROPERTIES (
            'replication_num' = '1',
            'storage_format' = 'V2'
        );"
        log_info "✓ Table 'orders' created"
    else
        log_info "Table 'orders' already exists"
    fi
}

# Create sales_db database and tables
create_sales_db() {
    log_step "Creating sales_db database..."
    
    if database_exists "sales_db"; then
        if [ "$SKIP_EXISTING" = true ]; then
            log_info "Database 'sales_db' already exists, skipping..."
            return 0
        else
            log_warn "Database 'sales_db' already exists"
        fi
    fi
    
    execute_sql "CREATE DATABASE IF NOT EXISTS sales_db;"
    log_info "✓ Database 'sales_db' created"
    
    # Create customers table
    log_step "Creating customers table..."
    if ! table_exists "sales_db" "customers"; then
        execute_sql "USE sales_db; CREATE TABLE IF NOT EXISTS customers (
            customer_id BIGINT NOT NULL,
            customer_name VARCHAR(100) NOT NULL,
            email VARCHAR(100),
            phone VARCHAR(20),
            address VARCHAR(200),
            city VARCHAR(50),
            country VARCHAR(50),
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        ) DUPLICATE KEY(customer_id) DISTRIBUTED BY HASH(customer_id) BUCKETS 10
        PROPERTIES (
            'replication_num' = '1',
            'storage_format' = 'V2'
        );"
        log_info "✓ Table 'customers' created"
    else
        log_info "Table 'customers' already exists"
    fi
    
    # Create sales table
    log_step "Creating sales table..."
    if ! table_exists "sales_db" "sales"; then
        execute_sql "USE sales_db; CREATE TABLE IF NOT EXISTS sales (
            sale_id BIGINT NOT NULL,
            customer_id BIGINT NOT NULL,
            product_name VARCHAR(200),
            quantity INT DEFAULT 1,
            unit_price DECIMAL(10,2),
            total_price DECIMAL(10,2),
            sale_date DATETIME DEFAULT CURRENT_TIMESTAMP,
            salesperson VARCHAR(50)
        ) DUPLICATE KEY(sale_id) DISTRIBUTED BY HASH(sale_id) BUCKETS 10
        PROPERTIES (
            'replication_num' = '1',
            'storage_format' = 'V2'
        );"
        log_info "✓ Table 'sales' created"
    else
        log_info "Table 'sales' already exists"
    fi
}

# Main execution
main() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Setting up Doris Databases and Tables${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    log_info "Configuration:"
    log_info "  Host: ${DORIS_HOST}"
    log_info "  Port: ${DORIS_PORT}"
    log_info "  User: ${DORIS_USER}"
    echo ""
    
    # Check prerequisites
    check_mysql_client
    
    # Wait for Doris to be ready
    wait_for_doris || exit 1
    
    # Create databases and tables
    create_demo_db
    create_sales_db
    
    echo ""
    log_info "✓ Database setup completed successfully"
    echo ""
    log_info "Created databases:"
    log_info "  - demo_db (users, products, orders)"
    log_info "  - sales_db (customers, sales)"
    echo ""
}

# Run main function
main "$@"
