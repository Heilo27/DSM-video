#!/bin/bash
# Validate SPK file against Synology requirements

set -euo pipefail

SPK_FILE="${1:-build/spk/DSVideoServer-0.1.0-armv8.spk}"

if [ ! -f "$SPK_FILE" ]; then
    echo "❌ SPK file not found: $SPK_FILE"
    exit 1
fi

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "Validating SPK: $(basename "$SPK_FILE")"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

ERRORS=0
WARNINGS=0

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

cd "$TEMP_DIR"

# Extract SPK
if ! tar -xzf "$SPK_FILE" 2>&1; then
    echo "❌ ERROR: SPK is not a valid tar.gz file"
    exit 1
fi

echo "✅ SPK is valid tar.gz"
echo ""

# Check required files
echo "📋 Checking required files..."

if [ ! -f "INFO" ]; then
    echo "❌ ERROR: INFO file missing"
    ERRORS=$((ERRORS + 1))
else
    echo "   ✅ INFO file present"
fi

if [ ! -f "package.tgz" ]; then
    echo "❌ ERROR: package.tgz missing"
    ERRORS=$((ERRORS + 1))
else
    echo "   ✅ package.tgz present"
fi

if [ ! -d "scripts" ]; then
    echo "⚠️  WARNING: scripts/ directory missing (optional but recommended)"
    WARNINGS=$((WARNINGS + 1))
else
    echo "   ✅ scripts/ directory present"
fi

echo ""

# Validate INFO file
if [ -f "INFO" ]; then
    echo "📄 Validating INFO file..."
    
    # Check for trailing newline
    if [ "$(tail -c 1 INFO | od -An -tu1)" != "" ] && [ "$(tail -c 1 INFO)" = "" ]; then
        echo "   ⚠️  WARNING: INFO file has trailing newline (should end without newline)"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "   ✅ INFO file ends correctly (no trailing newline)"
    fi
    
    # Check for required fields
    REQUIRED_FIELDS=("package" "version" "displayname" "arch" "os_min_ver")
    for field in "${REQUIRED_FIELDS[@]}"; do
        if grep -q "^${field}=" INFO; then
            echo "   ✅ Required field '${field}' present"
        else
            echo "   ❌ ERROR: Required field '${field}' missing"
            ERRORS=$((ERRORS + 1))
        fi
    done
    
    # Check for empty fields (should be removed)
    if grep -q '=""$' INFO; then
        echo "   ⚠️  WARNING: INFO contains empty fields (should be removed)"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "   ✅ No empty fields in INFO"
    fi
    
    # Check line endings (should be Unix LF)
    if file INFO | grep -q "CRLF"; then
        echo "   ❌ ERROR: INFO file has Windows line endings (CRLF)"
        ERRORS=$((ERRORS + 1))
    else
        echo "   ✅ INFO file has Unix line endings (LF)"
    fi
    
    echo ""
fi

# Validate package.tgz
if [ -f "package.tgz" ]; then
    echo "📦 Validating package.tgz..."
    
    if ! tar -tzf package.tgz >/dev/null 2>&1; then
        echo "   ❌ ERROR: package.tgz is not a valid tar.gz"
        ERRORS=$((ERRORS + 1))
    else
        echo "   ✅ package.tgz is valid tar.gz"
        
        # Check for binary
        if tar -tzf package.tgz | grep -q "dsvideo-backend"; then
            echo "   ✅ Binary found in package"
            
            # Extract and check binary type
            tar -xzf package.tgz target/backend/dsvideo-backend 2>/dev/null || true
            if [ -f "target/backend/dsvideo-backend" ]; then
                BINARY_TYPE=$(file target/backend/dsvideo-backend | cut -d: -f2)
                if echo "$BINARY_TYPE" | grep -q "ELF.*ARM\|ELF.*x86-64"; then
                    echo "   ✅ Binary is Linux format: $(echo "$BINARY_TYPE" | cut -d, -f1)"
                elif echo "$BINARY_TYPE" | grep -q "Mach-O"; then
                    echo "   ❌ ERROR: Binary is macOS format (should be Linux)"
                    ERRORS=$((ERRORS + 1))
                else
                    echo "   ⚠️  WARNING: Unknown binary format: $BINARY_TYPE"
                    WARNINGS=$((WARNINGS + 1))
                fi
            fi
        else
            echo "   ❌ ERROR: Binary not found in package"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    echo ""
fi

# Validate scripts
if [ -d "scripts" ]; then
    echo "📜 Validating scripts..."
    
    if [ -f "scripts/start-stop-status" ]; then
        if [ -x "scripts/start-stop-status" ]; then
            echo "   ✅ start-stop-status is executable"
        else
            echo "   ❌ ERROR: start-stop-status is not executable"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo "   ⚠️  WARNING: start-stop-status script not found"
        WARNINGS=$((WARNINGS + 1))
    fi
    echo ""
fi

# Summary
echo "═══════════════════════════════════════════════════════════════════════════════"
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    echo "✅ SPK validation passed! No errors or warnings."
    exit 0
elif [ $ERRORS -eq 0 ]; then
    echo "⚠️  SPK validation passed with $WARNINGS warning(s)."
    echo "   The package should install, but consider fixing warnings."
    exit 0
else
    echo "❌ SPK validation failed with $ERRORS error(s) and $WARNINGS warning(s)."
    echo "   Fix errors before attempting installation."
    exit 1
fi
