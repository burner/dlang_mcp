#!/bin/bash
# Quick setup script for dlang_mcp with all optional components
# Usage: ./setup.sh [--skip-onnx] [--skip-packages]
# 
# Options:
#   --skip-onnx      Skip ONNX Runtime installation (use TF-IDF only)
#   --skip-packages  Skip package ingestion

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB_DIR="$PROJECT_DIR/lib"
DATA_MODELS="$PROJECT_DIR/data/models"
SKIP_ONNX=false
SKIP_PACKAGES=false

for arg in "$@"; do
    case $arg in
        --skip-onnx) SKIP_ONNX=true ;;
        --skip-packages) SKIP_PACKAGES=true ;;
    esac
done

echo "========================================"
echo "  dlang_mcp Setup Script"
echo "========================================"
echo "Project: $PROJECT_DIR"
echo "Skip ONNX: $SKIP_ONNX"
echo "Skip Packages: $SKIP_PACKAGES"
echo ""

echo "[1/7] Building project..."
cd "$PROJECT_DIR"
dub build

echo ""
echo "[2/7] Installing sqlite-vec..."
if [ ! -f "$DATA_MODELS/vec0.so" ]; then
    cd /tmp
    rm -rf sqlite-vec
    git clone --depth 1 https://github.com/asg017/sqlite-vec
    cd sqlite-vec
    make loadable
    mkdir -p "$DATA_MODELS"
    cp dist/vec0.so "$DATA_MODELS/"
    echo "  ✓ sqlite-vec installed"
else
    echo "  ✓ sqlite-vec already installed"
fi

if [ "$SKIP_ONNX" = false ]; then
    echo ""
    echo "[3/7] Installing ONNX Runtime..."
    if [ ! -f "$LIB_DIR/onnxruntime.so" ]; then
        cd /tmp
        wget -q https://github.com/microsoft/onnxruntime/releases/download/v1.18.0/onnxruntime-linux-x64-1.18.0.tgz
        tar xzf onnxruntime-linux-x64-1.18.0.tgz
        mkdir -p "$LIB_DIR"
        cp onnxruntime-linux-x64-1.18.0/lib/libonnxruntime.so.1.18.0 "$LIB_DIR/"
        cd "$LIB_DIR" && ln -sf libonnxruntime.so.1.18.0 onnxruntime.so
        echo "  ✓ ONNX Runtime installed"
    else
        echo "  ✓ ONNX Runtime already installed"
    fi

    echo ""
    echo "[4/7] Downloading ONNX model..."
    if [ ! -f "$DATA_MODELS/model.onnx" ]; then
        cd "$PROJECT_DIR"
        wget -q -O data/models/model.onnx \
            https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/onnx/model.onnx
        wget -q -O data/models/vocab.txt \
            https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/raw/main/vocab.txt
        echo "  ✓ ONNX model downloaded"
    else
        echo "  ✓ ONNX model already downloaded"
    fi
else
    echo ""
    echo "[3-4/7] Skipping ONNX installation (--skip-onnx)"
fi

echo ""
echo "[5/7] Initializing database..."
cd "$PROJECT_DIR"
./bin/dlang_mcp --init-db

if [ "$SKIP_PACKAGES" = false ]; then
    echo ""
    echo "[6/7] Ingesting packages..."
    echo "  Ingesting phobos (D standard library)..."
    ./bin/dlang_mcp --ingest --package=phobos
    echo "  Ingesting intel-intrinsics..."
    ./bin/dlang_mcp --ingest --package=intel-intrinsics
    
    echo ""
    echo "[7/7] Training embeddings and mining patterns..."
    ./bin/dlang_mcp --train-embeddings
    ./bin/dlang_mcp --mine-patterns
else
    echo ""
    echo "[6-7/7] Skipping package ingestion (--skip-packages)"
fi

echo ""
echo "========================================"
echo "  Setup Complete!"
echo "========================================"
echo ""
echo "Installed components:"
echo "  - sqlite-vec: $DATA_MODELS/vec0.so"
if [ "$SKIP_ONNX" = false ]; then
    echo "  - ONNX Runtime: $LIB_DIR/onnxruntime.so"
    echo "  - ONNX Model: $DATA_MODELS/model.onnx"
fi
echo ""
echo "Usage:"
echo "  ./bin/dlang_mcp --test-search=\"sort array\""
echo "  ./bin/dlang_mcp              # Run MCP server"
echo ""
if [ "$SKIP_ONNX" = true ]; then
    echo "Note: Using TF-IDF embeddings only."
    echo "To enable ONNX neural embeddings, run: ./setup.sh"
fi