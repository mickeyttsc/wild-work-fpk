#!/bin/bash
# build-fpk.sh - Wild Work fnOS FPK auto-build script
# Completely standalone - no local installation required
# Builds from upstream binary and creates complete fpk structure

set -e

VERSION=${1:-v2.2.2}
UPSTREAM_REF=${2:-main}
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"

echo "=== Wild Work FPK Auto-Build ==="
echo "Version: $VERSION"
echo "Upstream ref: $UPSTREAM_REF"
echo "Work dir: $WORK_DIR"

# 1. Clone upstream (auto-detect default branch)
git clone --depth 1 https://github.com/rockswang/wild-work.git upstream
cd upstream

# Auto-detect default branch if specific ref not provided
if [ -n "$UPSTREAM_REF" ] && [ "$UPSTREAM_REF" != "main" ]; then
    REF="$UPSTREAM_REF"
else
    # Check if master exists, otherwise use main
    if git show-ref --verify --quiet refs/remotes/origin/master; then
        REF="master"
    else
        REF="main"
    fi
fi

echo "Using upstream branch: $REF"

# Checkout the correct branch/tag
git checkout "$REF" 2>/dev/null || git checkout -b temp-branch origin/master 2>/dev/null || true

# 2. Build binary
go mod download
go build -o wild-work -ldflags="-s -w" ./cmd/wild-work

# Verify binary exists and is executable
if [ ! -x wild-work ]; then
    echo "ERROR: Binary build failed"
    exit 1
fi

BINARY_SHA256=$(sha256sum wild-work | cut -d' ' -f1)
echo "Binary SHA256: $BINARY_SHA256"

# 3. Create icon files
mkdir -p app/ui/images
if [ -f icon.png ]; then
    if command -v convert &> /dev/null; then
        convert icon.png -resize 64x64 app/ui/images/icon_64.png
        convert icon.png -resize 256x256 app/ui/images/icon_256.png
    else
        # Create minimal valid PNG placeholders
        printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00@\x00\x00\x00@\x02\x03\x06\x00\x00\x00\xec\x8b\x9d\x88\x00\x00\x00\x1cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x1d\xd4\x00\x00\x00\x00IEND\xaeB`\x82' > app/ui/images/icon_64.png
        printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00\x00\x00\x01\x00\x02\x03\x06\x00\x00\x00\x19\x97\x5a\xdc\x00\x00\x00\x8cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x1d\xd4\x00\x00\x00\x00IEND\xaeB`\x82' > app/ui/images/icon_256.png
    fi
else
    # Create minimal PNG placeholders
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00@\x00\x00\x00@\x02\x03\x06\x00\x00\x00\xec\x8b\x9d\x88\x00\x00\x00\x1cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x1d\xd4\x00\x00\x00\x00IEND\xaeB`\x82' > app/ui/images/icon_64.png
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00\x00\x00\x01\x00\x02\x03\x06\x00\x00\x00\x19\x97\x5a\xdc\x00\x00\x00\x8cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x1d\xd4\x00\x00\x00\x00IEND\xaeB`\x82' > app/ui/images/icon_256.png
fi

# 4. Create complete FPK structure (standalone, no local deps)
echo "Creating FPK structure..."

# Create cmd scripts
mkdir -p cmd
cat > cmd/main << 'SCRIPT'
#!/bin/sh
# Wild Work service control script for fnOS
APP_BIN="$TRIM_APPDEST/bin/wild-work"
SOCK_FILE="$TRIM_APPDEST/app.sock"
PID_FILE="$TRIM_PKGVAR/wild-work.pid"
LOG_FILE="$TRIM_PKGVAR/wild-work.log"
PORT="${TRIM_SERVICE_PORT:-7863}"

is_running() {
    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    return 1
}

case "$1" in
    start)
        echo "Starting Wild Work..."
        mkdir -p "$TRIM_PKGVAR"
        nohup "$APP_BIN" --no-tray --port "$PORT" > "$LOG_FILE" 2>&1 &
        echo $! > "$PID_FILE"
        sleep 2
        if is_running; then
            echo "Wild Work started successfully"
            exit 0
        else
            echo "Failed to start Wild Work"
            exit 1
        fi
        ;;
    stop)
        echo "Stopping Wild Work..."
        if is_running; then
            pid=$(cat "$PID_FILE")
            kill "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
            echo "Wild Work stopped"
        else
            echo "Wild Work is not running"
        fi
        ;;
    status)
        if is_running; then
            echo "running"
            exit 0
        else
            echo "stopped"
            exit 1
        fi
        ;;
    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    *)
        echo "Usage: $0 {start|stop|status|restart}"
        exit 1
        ;;
esac
SCRIPT
chmod +x cmd/main

cat > cmd/install_init << 'SCRIPT'
#!/bin/sh
# Installation initialization
echo "Initializing Wild Work installation..."
mkdir -p /vol2/@apphome/wildwork
chown -R wildwork:wildwork /vol2/@apphome/wildwork 2>/dev/null || true
echo "Installation initialized"
SCRIPT
chmod +x cmd/install_init

cat > cmd/install_callback << 'SCRIPT'
#!/bin/sh
# Post-installation callback
echo "Wild Work installation completed successfully"
SCRIPT
chmod +x cmd/install_callback

cat > cmd/upgrade_init << 'SCRIPT'
#!/bin/sh
# Pre-upgrade initialization
echo "Preparing for upgrade..."
SCRIPT
chmod +x cmd/upgrade_init

cat > cmd/upgrade_callback << 'SCRIPT'
#!/bin/sh
# Post-upgrade callback
echo "Wild Work upgraded successfully"
SCRIPT
chmod +x cmd/upgrade_callback

cat > cmd/uninstall_init << 'SCRIPT'
#!/bin/sh
# Pre-uninitialization
echo "Preparing for uninstall..."
SCRIPT
chmod +x cmd/uninstall_init

cat > cmd/uninstall_callback << 'SCRIPT'
#!/bin/sh
# Post-uninstall callback
echo "Wild Work uninstalled successfully"
SCRIPT
chmod +x cmd/uninstall_callback

cat > cmd/config_init << 'SCRIPT'
#!/bin/sh
# Pre-config-change initialization
echo "Preparing for configuration change..."
SCRIPT
chmod +x cmd/config_init

cat > cmd/config_callback << 'SCRIPT'
#!/bin/sh
# Post-config-change callback
echo "Configuration changed successfully"
SCRIPT
chmod +x cmd/config_callback

# Create UI directory with index.cgi and config
mkdir -p ui/images
cp app/ui/images/icon_64.png ui/images/
cp app/ui/images/icon_256.png ui/images/

# Create ui/config (required by fnOS)
cat > ui/config << 'JSON'
{
  "name": "Wild Work",
  "icon": "/ui/images/icon_64.png",
  "url": "/app/wildwork",
  "description": "Multi-channel account aggregator for OpenAI-compatible API"
}
JSON

cat > ui/index.cgi << 'CGI'
#!/bin/sh
# Wild Work Web UI entry point
echo "Content-Type: text/html"
echo ""
cat << 'HTML'
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><title>Wild Work</title></head>
<body><h1>Wild Work</h1><p>Loading...</p></body>
</html>
HTML
CGI
chmod +x ui/index.cgi

# Create config files
mkdir -p config
cat > config/privilege << 'JSON'
{
  "defaults": {
    "run-as": "package"
  },
  "username": "wildwork",
  "groupname": "wildwork"
}
JSON

cat > config/resource << 'JSON'
{
  "wildwork-storage": {
    "description": "Storage for Wild Work",
    "path": "/vol2/@apphome/wildwork",
    "read_write": true
  }
}
JSON

# Create wizard files (required by fnpack)
mkdir -p wizard
echo '[]' > wizard/install
echo '[]' > wizard/upgrade
echo '[]' > wizard/config

# Copy ICON files
cp app/ui/images/icon_64.png ICON.PNG
cp app/ui/images/icon_256.png ICON_256.PNG

# Create manifest
cat > manifest << EOF
appname=wildwork
version=$VERSION
display_name=Wild Work
desc=Wild Work - Multi-channel account aggregator for OpenAI-compatible API
maintainer=Mickey
distributor=Mickey
source=thirdparty
platform=x86
ctl_stop=true
service_port=7863
desktop_uidir=ui
desktop_applaunchname=wildwork.main
changelog=v$VERSION - $(date +%Y-%m-%d)
EOF

# Set up app directory structure
mkdir -p app/bin
cp wild-work app/bin/

# 5. Build FPK package
echo "Building FPK package..."
if ! command -v fnpack &> /dev/null; then
    echo "Downloading fnpack..."
    wget -q https://static2.fnnas.com/fnpack/fnpack-1.2.1-linux-amd64 -O /tmp/fnpack
    chmod +x /tmp/fnpack
    export PATH="/tmp:$PATH"
fi

fnpack build -d .

# 6. Verify and output
FPK_FILE="wildwork-$VERSION.fpk"
mv wildwork.fpk "$FPK_FILE"

# Calculate checksums
FPK_MD5=$(md5sum "$FPK_FILE" | cut -d' ' -f1)
FPK_SHA256=$(sha256sum "$FPK_FILE" | cut -d' ' -f1)

echo ""
echo "=== Build Complete ==="
echo "FPK file: $FPK_FILE"
echo "Size: $(ls -lh "$FPK_FILE" | awk '{print $5}')"
echo "MD5: $FPK_MD5"
echo "SHA256: $FPK_SHA256"
echo "Binary SHA256: $BINARY_SHA256"
echo ""
echo "Package contents:"
tar tzf "$FPK_FILE" | head -20

# Clean up work dir
cd /
rm -rf "$WORK_DIR"

# Output artifact path
echo ""
echo "Artifact ready: $PWD/$FPK_FILE"
