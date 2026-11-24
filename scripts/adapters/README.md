# LoRA adapters for llama.cpp

`convert.sh` wraps llama.cpp's `convert_lora_to_gguf.py`:

```sh
LLAMA_CPP_DIR=/path/to/llama.cpp ./convert.sh /path/to/hf-base /path/to/peft-adapter notes.gguf
```

The adapters currently used by Inferoid were trained against all linear layers in the
merged model. That includes Gemma 4's vision and audio towers. They are therefore not
safe to assume compatible with a text-only llama.cpp server. For this runtime, train
text-only adapters with these target modules under `language_model`:

```text
q_proj, k_proj, v_proj, o_proj, gate_proj, up_proj, down_proj
```

Use rank 16. This avoids the vision/audio tower and keeps an adapter near 100 MB,
instead of loading another merged model or carrying multimodal tower deltas.

If a merged checkpoint is all that is available, subtract the base checkpoint from
the merged weights layer by layer, then take a rank-16 SVD of each delta and write the
result as PEFT A/B matrices. This is only an approximation: quantization, merge
rounding, changed layer norms, and any non-LoRA changes are lost or folded into the
factorization. Retraining the adapter with the text-only target list above is safer
and gives llama.cpp a clean mapping for its LoRA matmuls.

The config's adapter `name` is the skill selector (`notes` or `brain`), while llama.cpp
uses the adapter's load-order integer as the request `id`. Adapter files should be
produced from the same Gemma 4 base revision as the installed GGUF.
