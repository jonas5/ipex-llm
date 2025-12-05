#!/bin/bash
set -e

# Setup workspace
mkdir -p /llm/build
cd /llm/build

echo ">>> Cloning Ollama v0.13.1..."
git clone --recursive --branch v0.13.1 https://github.com/ollama/ollama.git ollama
cd ollama

echo ">>> Initializing OneAPI environment..."
# setvars.sh returns 3 if already run, which triggers set -e. We accept this.
source /opt/intel/oneapi/setvars.sh || true

# Verify if ggml-sycl source is present
GGML_SRC_DIR="ml/backend/ggml/ggml/src"
GGML_SYCL_DIR="${GGML_SRC_DIR}/ggml-sycl"

if [ ! -d "$GGML_SYCL_DIR" ]; then
    echo ">>> ggml-sycl source directory missing. Fetching from upstream llama.cpp..."

    # Clone llama.cpp to get compatible ggml-sycl implementation.
    # We target a specific commit to ensure ABI compatibility with Ollama v0.13.1 headers.
    # Ollama v0.13.1 (tag 5317202) is from Nov 2024.
    # We use a llama.cpp commit from ~Nov 1 2024: ba6f62eb (Fri Nov 1 17:31:51 2024 +0200)

    git clone https://github.com/ggerganov/llama.cpp.git temp_llama
    cd temp_llama
    git checkout ba6f62eb
    cd ..

    echo ">>> Injecting ggml-sycl into Ollama source tree..."
    if [ -d "temp_llama/ggml/src/ggml-sycl" ]; then
        cp -r temp_llama/ggml/src/ggml-sycl "$GGML_SRC_DIR/"
    elif [ -d "temp_llama/src/ggml-sycl" ]; then
        cp -r temp_llama/src/ggml-sycl "$GGML_SRC_DIR/"
    else
        # Fallback for older layout
        echo "Warning: Standard ggml-sycl paths not found. Searching..."
        find temp_llama -name "ggml-sycl" -exec cp -r {} "$GGML_SRC_DIR/" \;
    fi
    rm -rf temp_llama
    echo ">>> ggml-sycl source restored."
fi

echo ">>> Patching build scripts for SYCL support..."
# Locate the generation script
GEN_SCRIPT=$(find llm -name "gen_linux.sh")

if [ -n "$GEN_SCRIPT" ]; then
    echo ">>> Found generation script: $GEN_SCRIPT"

    # We need to inject the SYCL build configuration.
    # We inject a block that builds the SYCL runner.
    # We'll just append to the file, which runs after the standard builds.

    cat >> "$GEN_SCRIPT" << 'EOF'

echo ">>> Building SYCL runner..."
BUILD_DIR="build/linux/x86_64/sycl"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake ../../../.. \
    -DGGML_SYCL=ON \
    -DCMAKE_C_COMPILER=icx \
    -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF
make -j$(nproc)

echo ">>> SYCL runner built."
cd -
EOF
    echo ">>> Injected SYCL build logic into $GEN_SCRIPT"
else
    echo "Warning: gen_linux.sh not found. Proceeding with environment variables only."
fi

echo ">>> Configuring build environment..."
export CMAKE_ARGS="-DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx"
export GGML_SYCL=1

echo ">>> Running go generate..."
go generate ./...

echo ">>> Building Ollama binary..."
go build .

echo ">>> Installation..."
mv ollama /usr/local/bin/ollama

echo ">>> Cleanup..."
cd /llm
rm -rf /llm/build

echo ">>> Build and install complete."
