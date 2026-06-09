# OpenClicky Local Vision

Local vision-language runtime for notch intent experiments.

Installed model:

- `mlx-community/Qwen3-VL-4B-Instruct-4bit`

Runtime:

- Apple MLX through `mlx-vlm`
- PyTorch/Transformers is still available in the venv for fallback experiments
- local virtualenv: `AppResources/OpenClicky/LocalVision/.venv`
- local model snapshot: `AppResources/OpenClicky/LocalVision/models/Qwen3-VL-4B-Instruct-4bit`

Install or refresh:

```sh
scripts/install-local-vision-model.sh
```

Run a one-shot image prompt:

```sh
AppResources/OpenClicky/LocalVision/.venv/bin/python \
  AppResources/OpenClicky/LocalVision/local_vision_intent.py \
  --image "Screenshot 2026-05-31 at 20.35.58.png" \
  --image-label "latest focused window" \
  --prompt "Describe the visible UI in four short lines."
```

Run the detailed JSON lane:

```sh
AppResources/OpenClicky/LocalVision/.venv/bin/python \
  AppResources/OpenClicky/LocalVision/local_vision_intent.py \
  --analysis-mode detailed \
  --expect-json \
  --max-tokens 4096 \
  --image "Screenshot 2026-05-31 at 20.35.58.png" \
  --image-label "latest focused window" \
  --prompt "Return a detailed JSON object describing the visible UI, user intent, takeover options, and skill opportunities."
```

Response/profile logs:

- fast/default path: `AppResources/OpenClicky/LocalVision/logs/vision-responses.jsonl`
- detailed JSON path: `AppResources/OpenClicky/LocalVision/logs/detailed-vision-responses.jsonl`
- includes backend, model path, prompt, per-image labels/metadata, response text, token counts, and timings.
- detailed mode also stores `response_json` when the model returns parseable JSON, or `response_json_error` with the raw response for profiling.
- disable for a run with `--no-log`.

Model override:

```sh
OPENCLICKY_LOCAL_VISION_MODEL_NAME=YourModelDir \
OPENCLICKY_LOCAL_VISION_REPO=owner/repo \
scripts/install-local-vision-model.sh
```
