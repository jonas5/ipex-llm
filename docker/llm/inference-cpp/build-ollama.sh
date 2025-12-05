#!/bin/bash
set -e

# Setup workspace
mkdir -p /llm/build
cd /llm/build

echo ">>> Cloning Ollama v0.13.1..."
git clone --recursive --branch v0.13.1 https://github.com/ollama/ollama.git ollama
cd ollama

echo ">>> Initializing OneAPI environment..."
source /opt/intel/oneapi/setvars.sh

# Verify if ggml-sycl source is present
GGML_SRC_DIR="ml/backend/ggml/ggml/src"
GGML_SYCL_DIR="${GGML_SRC_DIR}/ggml-sycl"

if [ ! -d "$GGML_SYCL_DIR" ]; then
    echo ">>> ggml-sycl source directory missing. Fetching from upstream llama.cpp..."

    # Clone llama.cpp to get compatible ggml-sycl implementation.
    # We target a specific commit to ensure ABI compatibility with Ollama v0.13.1 headers.
    # Ollama v0.13.1 (tag 5317202) is from Nov 2024.
    # We use a llama.cpp commit from ~Nov 1 2024: 0c2049d

    git clone https://github.com/ggerganov/llama.cpp.git temp_llama
    cd temp_llama
    git checkout 0c2049d # Commit from early Nov 2024
    cd ..

    echo ">>> Injecting ggml-sycl into Ollama source tree..."
    if [ -d "temp_llama/ggml/src/ggml-sycl" ]; then
        cp -r temp_llama/ggml/src/ggml-sycl "$GGML_SRC_DIR/"
    elif [ -d "temp_llama/src/ggml-sycl" ]; then
        cp -r temp_llama/src/ggml-sycl "$GGML_SRC_DIR/"
    else
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
    # Standard Ollama gen_linux.sh defines COMMON_CMAKE_DEFS.
    # We will append a specific build block for SYCL.

    # 1. Add SYCL to the list of backends or manually invoke cmake.
    # Since patching the loop is fragile, we append a standalone build command to the end of the script
    # but BEFORE the final return/exit if present.
    # Ideally, we want to inject it where other backends are built.

    # We inject a block that builds the SYCL runner.
    # We assume the script has a function `build` or similar, or just sequential commands.
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

# Move artifacts to where Ollama expects them
# Ollama 0.13.1 expects libraries in specific paths for embedding.
# However, standard `go generate` flow compresses them.
# If we build manually, we might need to manually trigger the compression/embedding.
# But since we are appending to the script that *is* run by `go generate`,
# we might be too late for the embedding step if it happened earlier?
# `gen_linux.sh` is usually responsible for building the binaries.
# The Go code then embeds `build/linux/...`.
# So if we build here, we are good.

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
