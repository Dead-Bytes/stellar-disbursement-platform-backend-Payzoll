#!/bin/bash
set -e

#############################################
# SDP Setup & Deployment Script
# Supports: Linux & macOS
# Purpose: Install dependencies, build, and run SDP
#############################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Detect OS
detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        OS="linux"
        PACKAGE_MANAGER=""
        if command -v apt-get &> /dev/null; then
            PACKAGE_MANAGER="apt"
        elif command -v yum &> /dev/null; then
            PACKAGE_MANAGER="yum"
        elif command -v dnf &> /dev/null; then
            PACKAGE_MANAGER="dnf"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        PACKAGE_MANAGER="brew"
    else
        log_error "Unsupported OS: $OSTYPE"
        exit 1
    fi
    log_info "Detected OS: $OS (Package Manager: $PACKAGE_MANAGER)"
}

# Check if command exists
command_exists() {
    command -v "$1" &> /dev/null
}

# Install Go
install_go() {
    if command_exists go; then
        GO_VERSION=$(go version | awk '{print $3}')
        log_info "Go is already installed: $GO_VERSION"
        return
    fi

    log_info "Installing Go..."

    GO_VERSION="1.23.2"

    if [[ "$OS" == "linux" ]]; then
        GO_ARCH="linux-amd64"
        wget "https://go.dev/dl/go${GO_VERSION}.${GO_ARCH}.tar.gz"
        sudo rm -rf /usr/local/go
        sudo tar -C /usr/local -xzf "go${GO_VERSION}.${GO_ARCH}.tar.gz"
        rm "go${GO_VERSION}.${GO_ARCH}.tar.gz"

        # Add to PATH
        if ! grep -q "/usr/local/go/bin" ~/.bashrc; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
        fi
        if ! grep -q '$HOME/go/bin' ~/.bashrc; then
            echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.bashrc
        fi
        export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin

    elif [[ "$OS" == "macos" ]]; then
        if command_exists brew; then
            brew install go
        else
            log_error "Homebrew not found. Please install Homebrew first: https://brew.sh"
            exit 1
        fi

        # Add to PATH for zsh (default on macOS)
        if ! grep -q '$HOME/go/bin' ~/.zshrc; then
            echo 'export PATH=$PATH:$HOME/go/bin' >> ~/.zshrc
        fi
        export PATH=$PATH:$HOME/go/bin
    fi

    log_success "Go installed successfully: $(go version)"
}

# Install PostgreSQL
install_postgres() {
    if command_exists psql; then
        POSTGRES_VERSION=$(psql --version | awk '{print $3}')
        log_info "PostgreSQL is already installed: $POSTGRES_VERSION"
        return
    fi

    log_info "Installing PostgreSQL..."

    if [[ "$OS" == "linux" ]]; then
        if [[ "$PACKAGE_MANAGER" == "apt" ]]; then
            sudo apt-get update
            sudo apt-get install -y postgresql postgresql-contrib
            sudo systemctl start postgresql
            sudo systemctl enable postgresql
        elif [[ "$PACKAGE_MANAGER" == "yum" || "$PACKAGE_MANAGER" == "dnf" ]]; then
            sudo $PACKAGE_MANAGER install -y postgresql-server postgresql-contrib
            sudo postgresql-setup --initdb
            sudo systemctl start postgresql
            sudo systemctl enable postgresql
        fi
    elif [[ "$OS" == "macos" ]]; then
        brew install postgresql@14
        brew services start postgresql@14
    fi

    log_success "PostgreSQL installed successfully"
}

# Create database
setup_database() {
    log_info "Setting up database..."

    DB_NAME="${DATABASE_NAME:-sdp_mtn}"

    # Check if database exists
    if psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        log_warning "Database '$DB_NAME' already exists. Skipping creation."
    else
        log_info "Creating database: $DB_NAME"
        createdb "$DB_NAME" || {
            log_warning "Could not create database with current user. Trying with postgres user..."
            sudo -u postgres createdb "$DB_NAME" || log_error "Failed to create database"
        }
        log_success "Database '$DB_NAME' created"
    fi
}

# Load environment variables
load_env() {
    log_info "Loading environment variables from .env..."

    if [ ! -f .env ]; then
        log_error ".env file not found!"
        log_info "Please create a .env file from .env.example"
        exit 1
    fi

    # Load environment variables properly handling multiline values
    set -a
    source .env
    set +a

    log_success "Environment variables loaded"
}

# Build the application
build_app() {
    log_info "Building stellar-disbursement-platform..."

    go build -o stellar-disbursement-platform \
        -ldflags "-X main.GitCommit=$(git rev-parse --short HEAD)-$(whoami)" \
        .

    log_success "Build completed: ./stellar-disbursement-platform"
}

# Run database migrations
run_migrations() {
    log_info "Running database migrations..."

    log_info "1/5: Running admin migrations..."
    ./stellar-disbursement-platform db admin migrate up

    log_info "2/5: Running TSS migrations..."
    ./stellar-disbursement-platform db tss migrate up

    log_info "3/5: Running SDP migrations for all tenants..."
    ./stellar-disbursement-platform db sdp migrate up --all

    log_info "4/5: Running auth migrations for all tenants..."
    ./stellar-disbursement-platform db auth migrate up --all

    log_info "5/5: Setting up network-specific data..."
    ./stellar-disbursement-platform db setup-for-network --all

    log_success "All migrations completed successfully"
}

# Setup channel accounts
setup_channel_accounts() {
    log_info "Setting up channel accounts..."

    NUM_CHANNELS="${NUM_CHANNEL_ACCOUNTS:-2}"

    # Check if channel accounts already exist
    EXISTING_CHANNELS=$(./stellar-disbursement-platform channel-accounts view 2>/dev/null | grep -c "Public Key:" || echo "0")

    if [ "$EXISTING_CHANNELS" -gt 0 ]; then
        log_warning "Found $EXISTING_CHANNELS existing channel accounts. Skipping creation."
    else
        log_info "Creating $NUM_CHANNELS channel accounts..."
        ./stellar-disbursement-platform channel-accounts create "$NUM_CHANNELS"
        log_success "Channel accounts created"
    fi
}

# Start services
start_services() {
    log_info "Starting SDP services..."

    # Check if services are already running
    if pgrep -f "stellar-disbursement-platform serve" > /dev/null; then
        log_warning "SDP API is already running"
    else
        log_info "Starting SDP API server on port 8000..."
        nohup ./stellar-disbursement-platform serve > logs/api.log 2>&1 &
        echo $! > pids/api.pid
        log_success "SDP API started (PID: $(cat pids/api.pid))"
    fi

    if pgrep -f "stellar-disbursement-platform tss" > /dev/null; then
        log_warning "TSS is already running"
    else
        log_info "Starting Transaction Submission Service..."
        nohup ./stellar-disbursement-platform tss > logs/tss.log 2>&1 &
        echo $! > pids/tss.pid
        log_success "TSS started (PID: $(cat pids/tss.pid))"
    fi

    sleep 2

    # Health check
    log_info "Performing health check..."
    if curl -s http://localhost:8000/health > /dev/null; then
        log_success "SDP is healthy and running!"
        echo ""
        log_info "Services are running:"
        log_info "  - API: http://localhost:8000"
        log_info "  - Admin API: http://localhost:${ADMIN_PORT:-8003}"
        log_info "  - TSS Metrics: http://localhost:${TSS_METRICS_PORT:-9002}/metrics"
    else
        log_error "Health check failed. Check logs in ./logs/"
    fi
}

# Stop services
stop_services() {
    log_info "Stopping SDP services..."

    if [ -f pids/api.pid ]; then
        kill $(cat pids/api.pid) 2>/dev/null || log_warning "API process not found"
        rm pids/api.pid
    fi

    if [ -f pids/tss.pid ]; then
        kill $(cat pids/tss.pid) 2>/dev/null || log_warning "TSS process not found"
        rm pids/tss.pid
    fi

    log_success "Services stopped"
}

# View logs
view_logs() {
    log_info "Viewing logs (Ctrl+C to exit)..."
    tail -f logs/api.log logs/tss.log
}

# Main setup function
main_setup() {
    log_info "======================================"
    log_info "  SDP Setup & Deployment Script"
    log_info "======================================"
    echo ""

    # Create necessary directories
    mkdir -p logs pids

    detect_os
    install_go
    install_postgres
    load_env
    setup_database
    build_app
    run_migrations
    setup_channel_accounts

    log_success "Setup completed successfully!"
    echo ""
    log_info "To start services, run: $0 start"
}

# Usage information
usage() {
    cat <<EOF
Usage: $0 [COMMAND]

Commands:
    setup       Full setup (install dependencies, build, migrate)
    install     Install dependencies only (Go, PostgreSQL)
    build       Build the application
    migrate     Run database migrations
    channels    Setup channel accounts
    start       Start SDP services (API + TSS)
    stop        Stop SDP services
    restart     Restart SDP services
    logs        View service logs
    status      Check service status
    help        Show this help message

Examples:
    $0 setup              # Full setup from scratch
    $0 start              # Start services after setup
    $0 logs               # View running logs
    $0 restart            # Restart all services

EOF
}

# Check service status
check_status() {
    log_info "Checking service status..."

    if pgrep -f "stellar-disbursement-platform serve" > /dev/null; then
        log_success "SDP API is running (PID: $(pgrep -f 'stellar-disbursement-platform serve'))"
    else
        log_warning "SDP API is not running"
    fi

    if pgrep -f "stellar-disbursement-platform tss" > /dev/null; then
        log_success "TSS is running (PID: $(pgrep -f 'stellar-disbursement-platform tss'))"
    else
        log_warning "TSS is not running"
    fi
}

# Parse command line arguments
case "${1:-setup}" in
    setup)
        main_setup
        ;;
    install)
        detect_os
        install_go
        install_postgres
        ;;
    build)
        build_app
        ;;
    migrate)
        load_env
        run_migrations
        ;;
    channels)
        load_env
        setup_channel_accounts
        ;;
    start)
        load_env
        start_services
        ;;
    stop)
        stop_services
        ;;
    restart)
        stop_services
        sleep 2
        load_env
        start_services
        ;;
    logs)
        view_logs
        ;;
    status)
        check_status
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
