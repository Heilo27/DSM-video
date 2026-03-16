#!/bin/bash
# Validate SPK file against Synology requirements

set -euo pipefail

SPK_FILE="${1:-build/spk/DSVideoServer-0.1.0-armv8.spk}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Convert to absolute path if relative (tar runs after we cd into a temp dir)
if [[ "$SPK_FILE" != /* ]]; then
    SPK_FILE="$REPO_ROOT/$SPK_FILE"
fi

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

SPK_TYPE="$(file -b "$SPK_FILE" 2>/dev/null || true)"
if echo "$SPK_TYPE" | grep -qi "gzip compressed"; then
    echo "⚠️  WARNING: SPK outer archive is gzip-compressed ($SPK_TYPE)"
    echo "   DSM expects the outer .spk to be an uncompressed tar (see spk/SPK-PACKAGING.md)."
    WARNINGS=$((WARNINGS + 1))
    echo ""
fi

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

cd "$TEMP_DIR"

extract_spk() {
    # DSM expects a plain tar outer archive. Some tools/users accidentally gzip it.
    if tar -tf "$SPK_FILE" >/dev/null 2>&1; then
        tar -xf "$SPK_FILE"
        echo "✅ SPK is valid plain tar"
        return 0
    fi
    if tar -tzf "$SPK_FILE" >/dev/null 2>&1; then
        tar -xzf "$SPK_FILE"
        echo "⚠️  WARNING: SPK is a tar.gz (outer archive should be plain tar for DSM)"
        WARNINGS=$((WARNINGS + 1))
        return 0
    fi
    return 1
}

if ! extract_spk; then
    echo "❌ ERROR: SPK is not a valid tar archive (plain tar preferred)"
    exit 1
fi
echo ""

# Determine package root (some broken archives include an extra DSVideoServer/ prefix).
ROOT="."
if [ ! -f "INFO" ] && [ -f "DSVideoServer/INFO" ]; then
    ROOT="DSVideoServer"
fi
if [ ! -f "${ROOT}/INFO" ]; then
    FOUND_INFO="$(find . -maxdepth 2 -name INFO -print -quit 2>/dev/null || true)"
    if [ -n "${FOUND_INFO}" ]; then
        ROOT="$(dirname "${FOUND_INFO}")"
    fi
fi

if [ "${ROOT}" != "." ]; then
    echo "⚠️  WARNING: SPK contents are nested under '${ROOT}/' (INFO not at archive root)."
    echo "   This often breaks install/repair. Use spk/build-spk-macos.sh to build a standard SPK."
    WARNINGS=$((WARNINGS + 1))
    echo ""
fi

# Check required files
echo "📋 Checking required files..."

if [ ! -f "${ROOT}/INFO" ]; then
    echo "❌ ERROR: INFO file missing"
    ERRORS=$((ERRORS + 1))
else
    echo "   ✅ INFO file present"
fi

if [ ! -f "${ROOT}/package.tgz" ]; then
    echo "❌ ERROR: package.tgz missing"
    ERRORS=$((ERRORS + 1))
else
    echo "   ✅ package.tgz present"
fi

if [ ! -d "${ROOT}/scripts" ]; then
    echo "⚠️  WARNING: scripts/ directory missing (optional but recommended)"
    WARNINGS=$((WARNINGS + 1))
else
    echo "   ✅ scripts/ directory present"
fi

echo ""

# Validate INFO file
if [ -f "${ROOT}/INFO" ]; then
    echo "📄 Validating INFO file..."
    
    # Check for trailing newline
    if [ "$(tail -c 1 "${ROOT}/INFO" 2>/dev/null || true)" = "" ]; then
        echo "   ⚠️  WARNING: INFO file has trailing newline (should end without newline)"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "   ✅ INFO file ends correctly (no trailing newline)"
    fi
    
    # Check for required fields
    REQUIRED_FIELDS=("package" "version" "displayname" "arch" "os_min_ver")
    for field in "${REQUIRED_FIELDS[@]}"; do
        if grep -q "^${field}=" "${ROOT}/INFO"; then
            echo "   ✅ Required field '${field}' present"
        else
            echo "   ❌ ERROR: Required field '${field}' missing"
            ERRORS=$((ERRORS + 1))
        fi
    done
    
    # Check for empty fields (should be removed)
    if grep -q '=""$' "${ROOT}/INFO"; then
        echo "   ⚠️  WARNING: INFO contains empty fields (should be removed)"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "   ✅ No empty fields in INFO"
    fi
    
    # Check line endings (should be Unix LF)
    if file "${ROOT}/INFO" | grep -q "CRLF"; then
        echo "   ❌ ERROR: INFO file has Windows line endings (CRLF)"
        ERRORS=$((ERRORS + 1))
    else
        echo "   ✅ INFO file has Unix line endings (LF)"
    fi
    
    echo ""
fi

# Validate package.tgz
if [ -f "${ROOT}/package.tgz" ]; then
    echo "📦 Validating package.tgz..."
    
    if ! tar -tzf "${ROOT}/package.tgz" >/dev/null 2>&1; then
        echo "   ❌ ERROR: package.tgz is not a valid tar.gz"
        ERRORS=$((ERRORS + 1))
    else
        echo "   ✅ package.tgz is valid tar.gz"
        
        # Check for binary
        if tar -tzf "${ROOT}/package.tgz" | grep -q "backend/dsvideo-backend"; then
            echo "   ✅ Binary found in package"
            
            # Extract and check binary type
            tar -xzf "${ROOT}/package.tgz" backend/dsvideo-backend 2>/dev/null || true
            if [ -f "backend/dsvideo-backend" ]; then
                BINARY_TYPE=$(file backend/dsvideo-backend | cut -d: -f2)
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

        # DSM desktop icon requires ui/config inside package.tgz (not only at SPK root)
        if tar -tzf "${ROOT}/package.tgz" | grep -q "^ui/config$"; then
            echo "   ✅ ui/config present in package.tgz"
        else
            echo "   ⚠️  WARNING: ui/config missing from package.tgz (DSM icon may not appear)"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
    echo ""
fi

# Validate scripts
if [ -d "${ROOT}/scripts" ]; then
    echo "📜 Validating scripts..."
    
    if [ -f "${ROOT}/scripts/start-stop-status" ]; then
        if [ -x "${ROOT}/scripts/start-stop-status" ]; then
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
