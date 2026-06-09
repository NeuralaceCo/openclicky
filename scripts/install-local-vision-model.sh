#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VISION_DIR="$ROOT_DIR/AppResources/OpenClicky/LocalVision"
VENV_DIR="$VISION_DIR/.venv"
MODEL_NAME="${OPENCLICKY_LOCAL_VISION_MODEL_NAME:-Qwen3-VL-4B-Instruct-4bit}"
MODEL_REPO="${OPENCLICKY_LOCAL_VISION_REPO:-mlx-community/Qwen3-VL-4B-Instruct-4bit}"
MODEL_DIR="${OPENCLICKY_LOCAL_VISION_MODEL_DIR:-$VISION_DIR/models/$MODEL_NAME}"

command -v uv >/dev/null 2>&1 || {
  echo "uv is required. Install it first: https://docs.astral.sh/uv/"
  exit 1
}

mkdir -p "$VISION_DIR" "$MODEL_DIR"

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  uv venv --python 3.11 "$VENV_DIR"
fi
uv pip install --python "$VENV_DIR/bin/python" mlx-vlm huggingface-hub pillow torch torchvision

"$VENV_DIR/bin/python" - <<PY
from huggingface_hub import snapshot_download

snapshot_download(
    repo_id="${MODEL_REPO}",
    local_dir="${MODEL_DIR}",
)
print("${MODEL_DIR}")
PY

echo "OpenClicky local vision model installed:"
echo "  repo: ${MODEL_REPO}"
echo "  path: ${MODEL_DIR}"
