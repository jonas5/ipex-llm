# init ollama first
mkdir -p /llm/ollama
cd /llm/ollama
# init-ollama
export OLLAMA_NUM_GPU=999
export ZES_ENABLE_SYSMAN=1

# Source OneAPI environment for SYCL runtime
source /opt/intel/oneapi/setvars.sh

# start ollama service
(ollama serve > ollama.log) &
