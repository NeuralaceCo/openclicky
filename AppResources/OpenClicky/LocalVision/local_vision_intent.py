#!/usr/bin/env python3
"""Run OpenClicky's local tiny vision model for one-shot image understanding."""

from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image


DEFAULT_MODEL_NAME = "Qwen3-VL-4B-Instruct-4bit"
DEFAULT_MAX_TOKENS = 320

os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")


def default_model_path() -> Path:
    model_name = os.environ.get("OPENCLICKY_LOCAL_VISION_MODEL_NAME", DEFAULT_MODEL_NAME)
    return Path(__file__).resolve().parent / "models" / model_name


def default_log_path() -> Path:
    return Path(__file__).resolve().parent / "logs" / "vision-responses.jsonl"


def default_detailed_log_path() -> Path:
    return Path(__file__).resolve().parent / "logs" / "detailed-vision-responses.jsonl"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="OpenClicky local vision intent runner")
    parser.add_argument(
        "--backend",
        choices=["transformers", "mlx"],
        default=os.environ.get("OPENCLICKY_LOCAL_VISION_BACKEND", "mlx"),
        help="Inference backend. MLX is the verified default for the quantized Qwen model.",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("OPENCLICKY_LOCAL_VISION_MODEL", str(default_model_path())),
        help="Local model directory or Hugging Face repo id.",
    )
    parser.add_argument(
        "--analysis-mode",
        choices=["fast", "detailed"],
        default=os.environ.get("OPENCLICKY_LOCAL_VISION_ANALYSIS_MODE", "fast"),
        help="Fast is for live notch text. Detailed is for async JSON screen understanding logs.",
    )
    parser.add_argument(
        "--image",
        action="append",
        required=True,
        help="Image path. Pass multiple times for a small frame sequence.",
    )
    parser.add_argument(
        "--image-label",
        action="append",
        default=[],
        help="Human-readable label for an image. Pass once per --image in the same order.",
    )
    parser.add_argument(
        "--prompt",
        default=(
            "Infer what the user is trying to do from these recent screen frames. "
            "Return exactly four detailed lines: exact visible task, evidence, takeover option, skill opportunity. "
            "Never say settle on active task, ask for handoff context, continue current task, or continue reviewing files."
        ),
        help="Prompt for the vision model.",
    )
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    parser.add_argument("--temperature", type=float, default=0.0)
    parser.add_argument(
        "--log-path",
        default=os.environ.get("OPENCLICKY_LOCAL_VISION_LOG"),
        help="JSONL response/profile log path. Defaults by analysis mode. Set to empty with --no-log to disable.",
    )
    parser.add_argument(
        "--expect-json",
        action="store_true",
        help="Parse the response as JSON when logging, preserving raw text if parsing fails.",
    )
    parser.add_argument("--no-log", action="store_true", help="Disable JSONL response logging.")
    return parser.parse_args()


def resolved_model_path(model: str) -> str:
    expanded = Path(model).expanduser()
    return str(expanded.resolve()) if expanded.exists() else model


def normalized_image_labels(raw_labels: list[str], image_count: int) -> list[str]:
    labels = [label.strip() for label in raw_labels[:image_count]]
    while len(labels) < image_count:
        labels.append(f"image {len(labels) + 1}")
    return labels


def effective_log_path(args: argparse.Namespace) -> Path | None:
    if args.no_log:
        return None
    if args.log_path is not None:
        log_path_text = str(args.log_path).strip()
        return Path(log_path_text).expanduser() if log_path_text else None
    if args.analysis_mode == "detailed":
        return default_detailed_log_path()
    return default_log_path()


def prompt_with_image_labels(prompt: str, labels: list[str]) -> str:
    if not labels:
        return prompt
    label_lines = "\n".join(f"{index + 1}. {label}" for index, label in enumerate(labels))
    return f"{prompt}\n\nImage labels:\n{label_lines}"


def image_metadata(image_paths: list[str], image_labels: list[str]) -> list[dict[str, object]]:
    metadata: list[dict[str, object]] = []
    for index, image_path in enumerate(image_paths):
        path = Path(image_path)
        entry: dict[str, object] = {
            "index": index + 1,
            "path": str(path),
            "name": path.name,
            "label": image_labels[index] if index < len(image_labels) else "",
        }
        try:
            entry["bytes"] = path.stat().st_size
        except OSError:
            pass
        try:
            with Image.open(path) as image:
                entry["width"] = image.width
                entry["height"] = image.height
                entry["mode"] = image.mode
        except OSError:
            entry["imageError"] = "unreadable"
        metadata.append(entry)
    return metadata


def write_profile_log(args: argparse.Namespace, record: dict[str, object]) -> None:
    log_path = effective_log_path(args)
    if log_path is None:
        return

    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, ensure_ascii=False))
        handle.write("\n")


def strip_json_fence(text: str) -> str:
    stripped = text.strip()
    if not stripped.startswith("```"):
        return stripped
    lines = stripped.splitlines()
    if len(lines) >= 2 and lines[0].strip().startswith("```"):
        if lines[-1].strip() == "```":
            lines = lines[1:-1]
        else:
            lines = lines[1:]
    return "\n".join(lines).strip()


def parse_model_json_output(text: str) -> tuple[object | None, str | None]:
    candidate = strip_json_fence(text)
    decoder = json.JSONDecoder()
    try:
        parsed, end_index = decoder.raw_decode(candidate)
    except json.JSONDecodeError as error:
        first_brace = candidate.find("{")
        last_brace = candidate.rfind("}")
        if first_brace >= 0 and last_brace > first_brace:
            object_candidate = candidate[first_brace:last_brace + 1]
            try:
                parsed = json.loads(object_candidate)
                return parsed, "json object extracted from surrounding text"
            except json.JSONDecodeError:
                pass
        return None, str(error)
    trailing = candidate[end_index:].strip()
    if trailing:
        return parsed, f"non-json trailing text after character {end_index}"
    return parsed, None


def run_transformers(args: argparse.Namespace, model_path: str, image_paths: list[str]) -> tuple[str, dict[str, object]]:
    import torch
    from transformers import AutoModelForImageTextToText, AutoProcessor
    from transformers.utils import logging

    timings: dict[str, object] = {}
    logging.set_verbosity_error()
    try:
        logging.disable_progress_bar()
    except AttributeError:
        pass

    use_mps = torch.backends.mps.is_available()
    dtype = torch.float16 if use_mps else torch.float32
    load_started = time.perf_counter()
    processor = AutoProcessor.from_pretrained(model_path)
    model = AutoModelForImageTextToText.from_pretrained(model_path, dtype=dtype)
    if use_mps:
        model = model.to("mps")
    timings["load_ms"] = round((time.perf_counter() - load_started) * 1000, 2)

    preprocess_started = time.perf_counter()
    content = []
    for image_path in image_paths:
        content.append({
            "type": "image",
            "image": Image.open(image_path).convert("RGB"),
        })
    content.append({"type": "text", "text": args.prompt})
    messages = [{"role": "user", "content": content}]

    inputs = processor.apply_chat_template(
        messages,
        add_generation_prompt=True,
        tokenize=True,
        return_dict=True,
        return_tensors="pt",
    )
    if use_mps:
        inputs = {key: value.to("mps") if hasattr(value, "to") else value for key, value in inputs.items()}
    timings["preprocess_ms"] = round((time.perf_counter() - preprocess_started) * 1000, 2)

    generation_started = time.perf_counter()
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=args.max_tokens,
            do_sample=args.temperature > 0,
            temperature=args.temperature if args.temperature > 0 else None,
        )
    timings["generation_ms"] = round((time.perf_counter() - generation_started) * 1000, 2)
    input_length = inputs["input_ids"].shape[-1]
    text = processor.decode(outputs[0][input_length:], skip_special_tokens=True).strip()
    timings["input_tokens"] = int(input_length)
    timings["output_tokens"] = int(outputs.shape[-1] - input_length)
    timings["device"] = "mps" if use_mps else "cpu"
    timings["dtype"] = str(dtype).replace("torch.", "")
    return text, timings


def run_mlx(args: argparse.Namespace, model_path: str, image_paths: list[str]) -> tuple[str, dict[str, object]]:
    from mlx_vlm import generate, load
    from mlx_vlm.prompt_utils import apply_chat_template

    timings: dict[str, object] = {}
    load_started = time.perf_counter()
    model, processor = load(model_path)
    timings["load_ms"] = round((time.perf_counter() - load_started) * 1000, 2)
    preprocess_started = time.perf_counter()
    prompt = apply_chat_template(
        processor,
        model.config,
        args.prompt,
        num_images=len(image_paths),
    )
    timings["preprocess_ms"] = round((time.perf_counter() - preprocess_started) * 1000, 2)
    generation_started = time.perf_counter()
    output = generate(
        model,
        processor,
        prompt,
        image=image_paths,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        verbose=False,
    )
    timings["generation_ms"] = round((time.perf_counter() - generation_started) * 1000, 2)
    if hasattr(output, "prompt_tokens"):
        timings["input_tokens"] = int(getattr(output, "prompt_tokens"))
    if hasattr(output, "generation_tokens"):
        timings["output_tokens"] = int(getattr(output, "generation_tokens"))
    if hasattr(output, "peak_memory"):
        timings["peak_memory_gb"] = float(getattr(output, "peak_memory"))
    return getattr(output, "text", str(output)).strip(), timings


def main() -> None:
    invocation_id = str(uuid.uuid4())
    started_at = datetime.now(timezone.utc)
    total_started = time.perf_counter()
    args = parse_args()
    images = [str(Path(image).expanduser().resolve()) for image in args.image]
    image_labels = normalized_image_labels(args.image_label, len(images))
    args.prompt = prompt_with_image_labels(args.prompt, image_labels)
    model_path = resolved_model_path(args.model)

    base_record: dict[str, object] = {
        "id": invocation_id,
        "timestamp": started_at.isoformat().replace("+00:00", "Z"),
        "backend": args.backend,
        "analysis_mode": args.analysis_mode,
        "model": model_path,
        "prompt": args.prompt,
        "max_tokens": args.max_tokens,
        "temperature": args.temperature,
        "images": image_metadata(images, image_labels),
        "image_labels": image_labels,
        "host": {
            "platform": platform.platform(),
            "python": sys.version.split()[0],
        },
    }

    try:
        if args.backend == "mlx":
            output, timings = run_mlx(args, model_path, images)
        else:
            output, timings = run_transformers(args, model_path, images)
        total_ms = round((time.perf_counter() - total_started) * 1000, 2)
        record = {
            **base_record,
            "status": "success",
            "response": output,
            "response_length": len(output),
            "timings": {
                **timings,
                "total_ms": total_ms,
            },
        }
        if args.expect_json or args.analysis_mode == "detailed":
            parsed_json, parse_error = parse_model_json_output(output)
            if parsed_json is not None:
                record["response_json"] = parsed_json
                if parse_error:
                    record["response_json_note"] = parse_error
            elif parse_error:
                record["response_json_error"] = parse_error
        write_profile_log(args, record)
        print(output)
    except Exception as error:
        total_ms = round((time.perf_counter() - total_started) * 1000, 2)
        record = {
            **base_record,
            "status": "error",
            "error": {
                "type": type(error).__name__,
                "message": str(error),
            },
            "timings": {
                "total_ms": total_ms,
            },
        }
        write_profile_log(args, record)
        raise


if __name__ == "__main__":
    main()
