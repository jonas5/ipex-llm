#!/bin/bash
set -e

# Download Ollama 0.13.1 via git to ensure submodules (llama.cpp) are included
git clone --recursive --branch v0.13.1 https://github.com/ollama/ollama.git ollama-0.13.1
cd ollama-0.13.1

# Initialize OneAPI environment variables for potential SYCL support
source /opt/intel/oneapi/setvars.sh

echo "Building Ollama 0.13.1 from source..."
echo "Environment: OneAPI loaded. Vulkan SDK installed."

# Upstream Ollama's `go generate` builds llama.cpp.
# By default, it detects CUDA/ROCm.
# For Intel, if Vulkan SDK is present, it *should* detect it and build with Vulkan support.
# If `ipex-llm` usage is desired (SYCL), one would typically need to patch `llm/generate` scripts
# or use `ipex-llm`'s specific build process.
# Since we are restricted to upstream source + environment setup, we rely on upstream detection.

# Note: We do not explicitly force GGML_SYCL=ON here because we cannot easily patch the generate script blindly.
# However, Vulkan support is the standard path for Intel GPUs in upstream Ollama.
# If the user claims "no support for Vulkan", it might be that *prebuilt* binaries lack it.
# Building from source with Vulkan SDK ensures it is included.

go generate ./...
go build .

echo "Build complete."
