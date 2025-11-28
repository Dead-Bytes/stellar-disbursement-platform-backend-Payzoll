#!/bin/bash
set -e

#############################################
# SDP Restart Script
# Purpose: Restart SDP on already setup machines
# Includes: DB migrations, rebuild, and service restart
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

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load environment variables
load_env() {
    log_info "Loading environment variables from .env..."

    if [ ! -f .env ]; then
        log_error ".env file not found!"
        exit 1
    fi

    # Load environment variables properly handling multiline values
    set -a
    source .env
    set +a

    log_success "Environment variables loaded"
}

# Stop services
stop_services() {
    log_info "Stopping SDP services..."

    # Stop by PID file
    if [ -f pids/api.pid ]; then
        API_PID=$(cat pids/api.pid)
        if kill -0 "$API_PID" 2>/dev/null; then
            log_info "Stopping API (PID: $API_PID)..."
            kill "$API_PID"
            rm pids/api.pid
        else
            log_warning "API PID file exists but process not found"
            rm pids/api.pid
        fi
    fi

    if [ -f pids/tss.pid ]; then
        TSS_PID=$(cat pids/tss.pid)
        if kill -0 "$TSS_PID" 2>/dev/null; then
            log_info "Stopping TSS (PID: $TSS_PID)..."
            kill "$TSS_PID"
            rm pids/tss.pid
        else
            log_warning "TSS PID file exists but process not found"
            rm pids/tss.pid
        fi
    fi

    # Fallback: kill by process name
    if pgrep -f "stellar-disbursement-platform serve" > /dev/null; then
        log_info "Stopping API by process name..."
        pkill -f "stellar-disbursement-platform serve" || true
    fi

    if pgrep -f "stellar-disbursement-platform tss" > /dev/null; then
        log_info "Stopping TSS by process name..."
        pkill -f "stellar-disbursement-platform tss" || true
    fi

    # Wait for processes to stop
    sleep 2

    log_success "Services stopped"
}

# Pull latest code (optional)
pull_code() {
    if [ "$SKIP_GIT_PULL" != "true" ]; then
        log_info "Pulling latest code from git..."
        git pull || log_warning "Git pull failed or not a git repository"
    else
        log_info "Skipping git pull (SKIP_GIT_PULL=true)"
    fi
}

# Build the application
build_app() {
    log_info "Building stellar-disbursement-platform..."

    # Backup old binary
    if [ -f stellar-disbursement-platform ]; then
        mv stellar-disbursement-platform stellar-disbursement-platform.bak
        log_info "Backed up old binary to stellar-disbursement-platform.bak"
    fi

    go build -o stellar-disbursement-platform \
        -ldflags "-X main.GitCommit=$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')-$(whoami)" \
        . || {
            log_error "Build failed!"
            # Restore backup if build fails
            if [ -f stellar-disbursement-platform.bak ]; then
                mv stellar-disbursement-platform.bak stellar-disbursement-platform
                log_info "Restored previous binary"
            fi
            exit 1
        }

    log_success "Build completed: ./stellar-disbursement-platform"
}

# Create database if it doesn't exist
ensure_database() {
    log_info "Ensuring database exists..."

    # Extract database name from DATABASE_URL
    if [ -n "$DATABASE_URL" ]; then
        DB_NAME=$(echo "$DATABASE_URL" | sed -n 's/.*\/\([^?]*\).*/\1/p')
    else
        DB_NAME="${DATABASE_NAME:-sdp_mtn}"
    fi

    # Check if database exists
    if psql -lqt 2>/dev/null | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
        log_success "Database '$DB_NAME' exists"
    else
        log_warning "Database '$DB_NAME' does not exist. Creating..."
        createdb "$DB_NAME" 2>/dev/null || {
            log_info "Trying with postgres user..."
            sudo -u postgres createdb "$DB_NAME" 2>/dev/null || {
                log_error "Failed to create database. Please create it manually:"
                log_error "  createdb $DB_NAME"
                exit 1
            }
        }
        log_success "Database '$DB_NAME' created"
    fi
}

# Run database migrations
run_migrations() {
    log_info "Running database migrations..."

    log_info "1/5: Admin migrations..."
    ./stellar-disbursement-platform db admin migrate up

    log_info "2/5: TSS migrations..."
    ./stellar-disbursement-platform db tss migrate up

    log_info "3/5: SDP migrations for all tenants..."
    ./stellar-disbursement-platform db sdp migrate up --all

    log_info "4/5: Auth migrations for all tenants..."
    ./stellar-disbursement-platform db auth migrate up --all

    log_info "5/5: Network-specific data setup..."
    ./stellar-disbursement-platform db setup-for-network --all

    log_success "All migrations completed successfully"
}

# Verify channel accounts
verify_channels() {
    log_info "Verifying channel accounts..."

    NUM_CHANNELS=$(./stellar-disbursement-platform channel-accounts view 2>/dev/null | grep -c "Public Key:" || echo "0")

    if [ "$NUM_CHANNELS" -eq 0 ]; then
        log_warning "No channel accounts found!"
        log_info "Creating ${NUM_CHANNEL_ACCOUNTS:-2} channel accounts..."
        ./stellar-disbursement-platform channel-accounts create "${NUM_CHANNEL_ACCOUNTS:-2}"
    else
        log_success "Found $NUM_CHANNELS channel accounts"
    fi
}

# Start services
start_services() {
    log_info "Starting SDP services..."

    # Create necessary directories
    mkdir -p logs pids

    log_info "Starting SDP API server on port ${PORT:-8000}..."
    nohup ./stellar-disbursement-platform serve > logs/api.log 2>&1 &
    echo $! > pids/api.pid
    log_success "SDP API started (PID: $(cat pids/api.pid))"

    log_info "Starting Transaction Submission Service..."
    nohup ./stellar-disbursement-platform tss > logs/tss.log 2>&1 &
    echo $! > pids/tss.pid
    log_success "TSS started (PID: $(cat pids/tss.pid))"

    # Wait for services to start
    sleep 3

    # Health check
    log_info "Performing health check..."
    if curl -s http://localhost:${PORT:-8000}/health > /dev/null 2>&1; then
        log_success "SDP is healthy and running!"
        echo ""
        log_info "Services are running:"
        log_info "  - API: http://localhost:${PORT:-8000}"
        log_info "  - Admin API: http://localhost:${ADMIN_PORT:-8003}"
        log_info "  - TSS Metrics: http://localhost:${TSS_METRICS_PORT:-9002}/metrics"
        echo ""
        log_info "View logs: tail -f logs/api.log logs/tss.log"
    else
        log_error "Health check failed!"
        log_info "Check logs:"
        log_info "  - API logs: tail -f logs/api.log"
        log_info "  - TSS logs: tail -f logs/tss.log"
        exit 1
    fi
}

# Show service status
show_status() {
    log_info "Service Status:"
    echo ""

    if [ -f pids/api.pid ] && kill -0 $(cat pids/api.pid) 2>/dev/null; then
        log_success "SDP API: Running (PID: $(cat pids/api.pid))"
    else
        log_warning "SDP API: Not running"
    fi

    if [ -f pids/tss.pid ] && kill -0 $(cat pids/tss.pid) 2>/dev/null; then
        log_success "TSS: Running (PID: $(cat pids/tss.pid))"
    else
        log_warning "TSS: Not running"
    fi
}

# Main restart function
main_restart() {
    log_info "======================================"
    log_info "  SDP Restart Script"
    log_info "======================================"
    echo ""

    # Parse options
    SKIP_GIT_PULL=false
    SKIP_BUILD=false
    SKIP_MIGRATIONS=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --skip-git)
                SKIP_GIT_PULL=true
                shift
                ;;
            --skip-build)
                SKIP_BUILD=true
                shift
                ;;
            --skip-migrations)
                SKIP_MIGRATIONS=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    load_env
    stop_services

    if [ "$SKIP_GIT_PULL" != "true" ]; then
        pull_code
    fi

    if [ "$SKIP_BUILD" != "true" ]; then
        build_app
    fi

    if [ "$SKIP_MIGRATIONS" != "true" ]; then
        ensure_database
        run_migrations
    fi

    verify_channels
    start_services

    log_success "Restart completed successfully!"
}

# Quick restart (no build, no migrations)
quick_restart() {
    log_info "======================================"
    log_info "  Quick Restart (No Build/Migrations)"
    log_info "======================================"
    echo ""

    load_env
    stop_services
    start_services

    log_success "Quick restart completed!"
}

# Usage information
usage() {
    cat <<EOF
Usage: $0 [COMMAND] [OPTIONS]

Commands:
    restart         Full restart (default: git pull, build, migrate, restart)
    quick           Quick restart (only stop and start services)
    stop            Stop services only
    start           Start services only
    status          Show service status
    logs            View service logs (follow mode)
    help            Show this help message

Options:
    --skip-git          Skip git pull
    --skip-build        Skip application build
    --skip-migrations   Skip database migrations

Examples:
    $0                              # Full restart (default)
    $0 restart                      # Full restart
    $0 restart --skip-git           # Restart without git pull
    $0 restart --skip-migrations    # Restart without migrations
    $0 quick                        # Quick restart (no build)
    $0 stop                         # Stop services
    $0 logs                         # View logs

Environment Variables:
    SKIP_GIT_PULL           Set to 'true' to skip git pull
    NUM_CHANNEL_ACCOUNTS    Number of channel accounts (default: 2)

EOF
}

# Parse command
COMMAND="${1:-restart}"
shift || true

case "$COMMAND" in
    restart|--restart)
        main_restart "$@"
        ;;
    quick|--quick)
        quick_restart
        ;;
    stop|--stop)
        load_env
        stop_services
        ;;
    start|--start)
        load_env
        start_services
        ;;
    status|--status)
        show_status
        ;;
    logs|--logs)
        log_info "Viewing logs (Ctrl+C to exit)..."
        tail -f logs/api.log logs/tss.log
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
