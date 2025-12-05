# init ollama first
mkdir -p /llm/ollama
cd /llm/ollama
# init-ollama
export OLLAMA_NUM_GPU=999
export ZES_ENABLE_SYSMAN=1

# Source OneAPI environment for SYCL runtime
# We use || true to avoid exit on code 3 (already loaded)
source /opt/intel/oneapi/setvars.sh || true

# Performance and Stability settings for Intel Arc (A770)
export SYCL_PI_LEVEL_ZERO_USE_IMMEDIATE_COMMANDLISTS=1
export SYCL_CACHE_PERSISTENT=1
export OLLAMA_DEBUG=1

# start ollama service
(ollama serve > ollama.log) &
