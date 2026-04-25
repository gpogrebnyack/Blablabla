#!/usr/bin/env python3
"""
Voice-dictation cleanup benchmark.

Goal: pick the best LLM under 3-4B for cleaning Russian voice transcripts,
running on Apple Silicon via MLX. Tests the SAME 4-bit quantized weights we
will ship in the Swift app — no fp16/cloud divergence.

Usage:
    pip install "mlx-lm>=0.21"
    python benchmark/cleanup_bench.py

Notes:
- Each model is downloaded once on first run (~2-6 GB) into the HF cache
  (~/.cache/huggingface/hub by default).
- Model is unloaded between candidates to keep peak memory low.
- Outputs Markdown to stdout AND writes results to benchmark/results.md.
"""

from __future__ import annotations

import gc
import json
import sys
import time
from dataclasses import dataclass
from pathlib import Path

try:
    from mlx_lm import load, generate
    from mlx_lm.sample_utils import make_sampler
    import mlx.core as mx
except ImportError:
    print("Install mlx-lm first:  pip install 'mlx-lm>=0.21'", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------- candidates --
# Order matters: cheap-first so we get partial results fast even if a big one stalls.
CANDIDATES: list[str] = [
    "mlx-community/Qwen3.5-2B-MLX-4bit",
    "mlx-community/Qwen3.5-2B-OptiQ-4bit",
    "mlx-community/Ministral-3-3B-Instruct-2512-4bit",
    "mlx-community/gemma-4-e2b-it-4bit",
    "mlx-community/Llama-3.2-3B-Instruct-4bit",
    "mlx-community/Qwen3.5-4B-MLX-4bit",
    "mlx-community/Qwen3-4B-4bit",  # current baseline shipped in the Swift app
]


# --------------------------------------------------------------- system prompt --
SYSTEM_PROMPT = """\
Ты редактор устной речи. Получаешь сырую транскрипцию.
Задача: вернуть тот же текст, но без слов-паразитов и оговорок.

Слова, которые ВСЕГДА удаляй: ну, вот, это, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой.
Если они в составе осмысленной фразы — оставь. Например: "вот этот стол" — оставить "это" нельзя удалить, "вот" удалить можно.

Исправь очевидные ошибки распознавания. Сохрани смысл и порядок слов. Не перефразируй и не добавляй ничего от себя.
Верни ТОЛЬКО исправленный текст одной строкой, без пояснений и кавычек.

Примеры:
Вход: "Ну короче я думаю это работает как бы нормально"
Выход: "Я думаю, это работает нормально"

Вход: "Так а давай потестируем работу нейросети. В общем как она справляется со словами-паразитами"
Выход: "А давай потестируем работу нейросети. Как она справляется со словами-паразитами"

Вход: "Короче просто хочется сказать что может быть в этот раз всё получилось"
Выход: "Просто хочется сказать, что может быть в этот раз всё получилось"
"""


# ----------------------------------------------------------------- test cases --
# Real dictations captured from the app + a few synthetic edge cases.
CASES: list[tuple[str, str]] = [
    ("counting", "Раз, два, раз, два, три."),
    ("medium_with_fillers",
     "Так, ну а теперь давай потестируем работу нейросети. В общем, как она у нас "
     "справляется со всякими вот этими словами, паузами лишними и всем остальным. "
     "Короче, просто хочется сказать, что может быть правда в этот раз все получилось."),
    ("repeated_starts",
     "Так ну давай еще раз попробуем. Давай потестируем. В общем, короче, как она "
     "у нас справляется со всеми какими словами паразитами. Короче, просто хочется "
     "сказать, что может быть и правда в этот раз все получилось."),
    ("short_filler_only", "Эм, ну, как бы, привет."),
    ("preserve_meaning",
     "Слушай, можешь напомнить вечером купить молоко и хлеб."),
    ("mixed_ru_tech_terms",
     "Короче, в общем, надо запушить ветку в гит и открыть пулл реквест."),
    ("question",
     "Слушай, э-э, а ты не знаешь, во сколько у нас завтра встреча с командой?"),
]


# ---------------------------------------------------------- generation params --
MAX_TOKENS = 256          # safety cap — clean output should rarely exceed input
TEMPERATURE = 0.3
TOP_P = 0.6


@dataclass
class Result:
    model: str
    case: str
    raw: str
    cleaned: str
    latency_ms: float
    output_tokens: int
    tok_per_s: float
    error: str | None = None


def build_prompt(tokenizer, system: str, user: str) -> str:
    """Apply the model's chat template, falling back if it doesn't have one."""
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]
    extra: dict = {}
    # Disable Qwen3 thinking when present.
    extra["enable_thinking"] = False
    try:
        return tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False, **extra
        )
    except TypeError:
        # template doesn't accept enable_thinking
        return tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )


def strip_think(s: str) -> str:
    """Remove Qwen3-style <think>...</think> blocks."""
    if "</think>" in s:
        if "<think>" in s:
            start = s.index("<think>")
        else:
            start = 0
        end = s.index("</think>") + len("</think>")
        s = s[:start] + s[end:]
    return s.strip().strip('"').strip()


def run_one(model, tokenizer, sampler, raw: str, model_id: str) -> Result:
    prompt = build_prompt(tokenizer, SYSTEM_PROMPT, raw)
    prompt_tokens = tokenizer.encode(prompt)

    t0 = time.perf_counter()
    out = generate(
        model,
        tokenizer,
        prompt=prompt,
        max_tokens=MAX_TOKENS,
        sampler=sampler,
        verbose=False,
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000

    out_tokens = len(tokenizer.encode(out)) - len(prompt_tokens)
    out_tokens = max(out_tokens, 1)

    cleaned = strip_think(out)
    return Result(
        model=model_id,
        case="",  # filled by caller
        raw=raw,
        cleaned=cleaned,
        latency_ms=elapsed_ms,
        output_tokens=out_tokens,
        tok_per_s=out_tokens / (elapsed_ms / 1000),
    )


def bench_model(model_id: str) -> list[Result]:
    print(f"\n=== {model_id} ===", flush=True)
    try:
        t = time.perf_counter()
        model, tokenizer = load(model_id)
        load_ms = (time.perf_counter() - t) * 1000
        print(f"  loaded in {load_ms:.0f} ms", flush=True)
    except Exception as e:
        print(f"  LOAD FAILED: {e}", flush=True)
        return [Result(model=model_id, case="<load>", raw="", cleaned="",
                       latency_ms=0, output_tokens=0, tok_per_s=0,
                       error=f"load failed: {e}")]

    sampler = make_sampler(temp=TEMPERATURE, top_p=TOP_P)

    # Warmup so the first case isn't penalized for kernel compilation.
    try:
        _ = run_one(model, tokenizer, sampler, "Привет.", model_id)
    except Exception as e:
        print(f"  warmup error: {e}", flush=True)

    results: list[Result] = []
    for name, raw in CASES:
        try:
            r = run_one(model, tokenizer, sampler, raw, model_id)
            r.case = name
            results.append(r)
            print(f"  [{name}] {r.latency_ms:5.0f} ms  "
                  f"({r.tok_per_s:5.1f} tok/s)  -> {r.cleaned[:80]}", flush=True)
        except Exception as e:
            results.append(Result(model=model_id, case=name, raw=raw, cleaned="",
                                  latency_ms=0, output_tokens=0, tok_per_s=0,
                                  error=str(e)))
            print(f"  [{name}] ERROR: {e}", flush=True)

    # Free memory before next model.
    del model, tokenizer, sampler
    gc.collect()
    mx.clear_cache()

    return results


def render_markdown(all_results: list[Result]) -> str:
    out: list[str] = []
    out.append(f"# Voice-cleanup benchmark — {time.strftime('%Y-%m-%d %H:%M')}\n")
    out.append(f"**Sampler**: temp={TEMPERATURE}, top_p={TOP_P}, max_tokens={MAX_TOKENS}\n")

    # Per-case grouping so it's easy to compare model outputs side-by-side.
    by_case: dict[str, list[Result]] = {}
    for r in all_results:
        by_case.setdefault(r.case, []).append(r)

    for case_name, rows in by_case.items():
        if case_name == "<load>":
            continue
        sample_raw = next((r.raw for r in rows if r.raw), "")
        out.append(f"## Case `{case_name}`\n")
        out.append(f"**Input** ({len(sample_raw)} chars): {sample_raw}\n")
        out.append("| Model | ms | tok/s | Output |")
        out.append("|---|---:|---:|---|")
        for r in sorted(rows, key=lambda x: x.latency_ms):
            short_id = r.model.replace("mlx-community/", "")
            if r.error:
                out.append(f"| {short_id} | — | — | ⚠️ {r.error} |")
            else:
                out.append(f"| {short_id} | {r.latency_ms:.0f} "
                           f"| {r.tok_per_s:.1f} | {r.cleaned} |")
        out.append("")

    # Mean latency summary.
    out.append("## Summary (mean over successful cases)\n")
    out.append("| Model | mean ms | mean tok/s | failures |")
    out.append("|---|---:|---:|---:|")
    by_model: dict[str, list[Result]] = {}
    for r in all_results:
        by_model.setdefault(r.model, []).append(r)
    rows = []
    for mid, rs in by_model.items():
        ok = [r for r in rs if not r.error and r.case != "<load>"]
        fail = [r for r in rs if r.error]
        if ok:
            mean_ms = sum(r.latency_ms for r in ok) / len(ok)
            mean_tps = sum(r.tok_per_s for r in ok) / len(ok)
            rows.append((mid, mean_ms, mean_tps, len(fail)))
        else:
            rows.append((mid, float("inf"), 0, len(fail)))
    rows.sort(key=lambda x: x[1])
    for mid, ms, tps, fails in rows:
        short_id = mid.replace("mlx-community/", "")
        ms_str = f"{ms:.0f}" if ms != float("inf") else "—"
        out.append(f"| {short_id} | {ms_str} | {tps:.1f} | {fails} |")
    return "\n".join(out)


def main() -> None:
    all_results: list[Result] = []
    for mid in CANDIDATES:
        all_results.extend(bench_model(mid))

    md = render_markdown(all_results)
    out_path = Path(__file__).parent / "results.md"
    out_path.write_text(md, encoding="utf-8")
    print("\n" + "=" * 72)
    print(md)
    print("=" * 72)
    print(f"\nResults written to: {out_path}")

    # Also dump raw JSON for further analysis.
    json_path = Path(__file__).parent / "results.json"
    json_path.write_text(
        json.dumps([r.__dict__ for r in all_results], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"Raw JSON:           {json_path}")


if __name__ == "__main__":
    main()
