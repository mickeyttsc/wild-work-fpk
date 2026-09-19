#!/bin/bash
# build-fpk.sh - Wild Work fpk 自动打包脚本
# 复用现有 cmd/main+wwbridge+ui，只替换二进制

set -e

VERSION=${1:-v2.2.2}
UPSTREAM_REF=${2:-main}
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR"

echo "=== Wild Work FPK Auto-Build ==="
echo "Version: $VERSION"
echo "Upstream ref: $UPSTREAM_REF"
echo "Work dir: $WORK_DIR"

# 1. Clone upstream
git clone --depth 1 --branch "$UPSTREAM_REF" https://github.com/rockswang/wild-work.git upstream
cd upstream

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

# 3. Copy icon
if [ -f icon.png ]; then
    # Use ImageMagick if available, otherwise create placeholder
    if command -v convert &> /dev/null; then
        convert icon.png -resize 64x64 app/ui/images/icon_64.png
        convert icon.png -resize 256x256 app/ui/images/icon_256.png
    else
        # Minimal PNG placeholders (will be replaced later)
        printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00@\x00\x00\x00@\x02\x03\x06\x00\x00\x00\xec\x8b\x9d\x88\x00\x00\x00\x1cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x1d\xd4\x00\x00\x00\x00IEND\xaeB`\x82' > app/ui/images/icon_64.png
        printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00\x00\x00\x01\x00\x02\x03\x06\x00\x00\x00\x19\x97\x5a\xdc\x00\x00\x00\x8cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x1d\xd4\x00\x00\x00\x00IEND\xaeB`\x82' > app/ui/images/icon_256.png
    fi
else
    # Create minimal placeholders
    mkdir -p app/ui/images
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00@\x00\x00\x00@\x02\x03\x06\x00\x00\x00\xec\x8b\x9d\x88\x00\x00\x00\x1cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x1d\xd4\x00\x00\x00\x00IEND\xaeB`\x82' > app/ui/images/icon_64.png
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x01\x00\x00\x00\x01\x00\x02\x03\x06\x00\x00\x00\x19\x97\x5a\xdc\x00\x00\x00\x8cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00\x05\x1d\xd4\x00\x00\x00\x00IEND\xaeB`\x82' > app/ui/images/icon_256.png
fi

# 3. Copy from existing installation (reuse cmd, ui, config)
EXISTING_VAR="/var/apps/wildwork"

if [ -d "$EXISTING_VAR" ]; then
    echo "Reusing fpk structure from $EXISTING_VAR"
    
    # Copy cmd scripts
    mkdir -p cmd
    cp "$EXISTING_VAR/cmd/main" cmd/
    cp "$EXISTING_VAR/cmd/install_init" cmd/
    cp "$EXISTING_VAR/cmd/install_callback" cmd/
    cp "$EXISTING_VAR/cmd/upgrade_init" cmd/
    cp "$EXISTING_VAR/cmd/upgrade_callback" cmd/
    cp "$EXISTING_VAR/cmd/uninstall_init" cmd/
    cp "$EXISTING_VAR/cmd/uninstall_callback" cmd/
    cp "$EXISTING_VAR/cmd/config_init" cmd/
    cp "$EXISTING_VAR/cmd/config_callback" cmd/
    
    # Copy UI components (wwbridge + web interface)
    EXISTING_APP="/vol2/@appcenter/wildwork"
    if [ -d "$EXISTING_APP/ui" ]; then
        cp -r "$EXISTING_APP/ui" .
    fi
    
    # Copy config and wizard
    mkdir -p config wizard
    if [ -f "$EXISTING_APP/config/privilege" ]; then
        cp "$EXISTING_APP/config/privilege" config/
    fi
    if [ -f "$EXISTING_APP/config/resource" ]; then
        cp "$EXISTING_APP/config/resource" config/
    fi
    for w in install upgrade config; do
        if [ -f "$EXISTING_VAR/wizard/$w" ]; then
            cp "$EXISTING_VAR/wizard/$w" wizard/
        elif [ -f "$EXISTING_APP/wizard/$w" ]; then
            cp "$EXISTING_APP/wizard/$w" wizard/
        else
            echo '[]' > wizard/$w
        fi
    done
    
    # Copy ICON files
    for icon_src in "$EXISTING_VAR" "$EXISTING_APP"; do
        if [ -f "$icon_src/ICON.PNG" ]; then
            cp "$icon_src/ICON.PNG" .
            break
        fi
    done
    for icon_src in "$EXISTING_VAR" "$EXISTING_APP"; do
        if [ -f "$icon_src/ICON_256.PNG" ]; then
            cp "$icon_src/ICON_256.PNG" .
            break
        fi
    done
else
    echo "WARNING: Existing installation not found, creating minimal structure"
    
    # Create minimal structures (fallback)
    mkdir -p ui/images
    cp app/ui/images/icon_64.png ui/images/
    cp app/ui/images/icon_256.png ui/images/
    
    cat > config/privilege << 'EOF'
[{"name":"wildwork","description":"Wild Work application user","uid":0,"gid":0}]
EOF

    cat > config/resource << 'EOF'
[{"name":"wildwork-storage","description":"Storage for Wild Work","path":"/vol2/@apphome/wildwork","read_write":true}]
EOF

    echo '[]' > wizard/install
    echo '[]' > wizard/upgrade
    echo '[]' > wizard/config
    
    # Create minimal icons
    cp app/ui/images/icon_64.png ICON.PNG
    cp app/ui/images/icon_256.png ICON_256.PNG
fi

# 5. Create manifest (overwrite version only)
cat > manifest << EOF
appname=wildwork
version=$VERSION
display_name=Wild Work
source=thirdparty
platform=x86
ctl_stop=true
service_port=7863
desktop_uidir=ui
desktop_applaunchname=wildwork.main
changelog=v$VERSION - $(date +%Y-%m-%d)
EOF

# 6. Set up app directory structure
mkdir -p app/bin
cp wild-work app/bin/

# 7. Build FPK package
echo "Building FPK package..."
if ! command -v fnpack &> /dev/null; then
    echo "Downloading fnpack..."
    wget -q https://static2.fnnas.com/fnpack/fnpack-1.2.1-linux-amd64 -O /tmp/fnpack
    chmod +x /tmp/fnpack
    export PATH="/tmp:$PATH"
fi

fnpack build -d .

# 8. Verify and output
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
