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
    git clone https://github.com/ggerganov/llama.cpp.git temp_llama
    cd temp_llama
    git checkout ba6f62eb # Commit from early Nov 2024
    cd ..

    echo ">>> Injecting ggml-sycl into Ollama source tree..."
    if [ -d "temp_llama/ggml/src/ggml-sycl" ]; then
        cp -r temp_llama/ggml/src/ggml-sycl "$GGML_SRC_DIR/"
    elif [ -d "temp_llama/src/ggml-sycl" ]; then
        cp -r temp_llama/src/ggml-sycl "$GGML_SRC_DIR/"
    else
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

    # We append a specific build block for SYCL.
    # Crucially, we must move the artifacts to where Ollama expects them for embedding.
    # Standard Ollama builds artifacts into `build/linux/${ARCH}/`.
    # We will build SYCL there.

    cat >> "$GEN_SCRIPT" << 'EOF'

echo ">>> Building SYCL runner..."
ARCH=$(uname -m)
BUILD_DIR="build/linux/${ARCH}/sycl"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Configure cmake with SYCL backend
cmake ../../../.. \
    -DGGML_SYCL=ON \
    -DCMAKE_C_COMPILER=icx \
    -DCMAKE_CXX_COMPILER=icpx \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF

make -j$(nproc)

echo ">>> Installing SYCL runner..."
# Ollama's discovery logic looks for runners in the distribution payload.
# By default, `go generate` compresses the output of `gen_linux.sh`.
# We need to place our runner alongside the others (cpu, cuda, etc).
# The standard script usually places binaries in `build/linux/${ARCH}/`.
# We copy our result `ollama_llama_server` to `build/linux/${ARCH}/ollama_llama_server_sycl`.
# Note: Ollama might expect specific naming conventions (e.g., using `ggml-sycl` tag).
# If we name it `ollama_llama_server` it might overwrite the CPU one (which is fine if we want SYCL only).
# But safest is to let it be a separate runner if supported.
# However, patching the Go discovery code is hard.
# Overwriting the default CPU runner with the SYCL runner ensures it is used!
# This is a brute-force fix but effective for a custom Docker image.

# Assuming the binary is named `ollama_llama_server` by cmake
if [ -f "bin/ollama_llama_server" ]; then
    cp "bin/ollama_llama_server" "../ollama_llama_server"
    echo ">>> Replaced default runner with SYCL runner."
elif [ -f "ollama_llama_server" ]; then
    cp "ollama_llama_server" "../ollama_llama_server"
    echo ">>> Replaced default runner with SYCL runner."
else
    echo ">>> Warning: Could not find SYCL runner binary to install."
fi

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
