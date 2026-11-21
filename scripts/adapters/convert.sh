#!/bin/sh
set -eu

base_dir=${1:?usage: convert.sh <hf-base-dir> <peft-adapter-dir> <outfile.gguf>}
adapter_dir=${2:?usage: convert.sh <hf-base-dir> <peft-adapter-dir> <outfile.gguf>}
outfile=${3:?usage: convert.sh <hf-base-dir> <peft-adapter-dir> <outfile.gguf>}
llama_cpp_dir=${LLAMA_CPP_DIR:-.}

exec python3 "$llama_cpp_dir/convert_lora_to_gguf.py" --base "$base_dir" "$adapter_dir" --outfile "$outfile"
