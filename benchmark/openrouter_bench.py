#!/usr/bin/env python3
"""
Voice-dictation cleanup benchmark via OpenRouter.

Companion to cleanup_bench.py — gives us a quality-ceiling view across many
candidates without downloading anything. OpenRouter serves fp16/bf16 weights,
so quality here is an UPPER BOUND for what the same model will produce after
4-bit MLX quantization.

Usage:
    pip install httpx
    python benchmark/openrouter_bench.py

The script reads the OpenRouter API key from this hardcoded path so we don't
copy secrets into this project:
    /Users/gpogrebnyak/Downloads/Cursor/Translator (optimized)/.env
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
from dataclasses import dataclass
from pathlib import Path

try:
    import httpx
except ImportError:
    print("Install httpx first:  pip install httpx", file=sys.stderr)
    sys.exit(1)


ENV_PATH = Path("/Users/gpogrebnyak/Downloads/Cursor/Translator (optimized)/.env")


def read_api_key() -> str:
    if not ENV_PATH.exists():
        sys.exit(f"Env file not found: {ENV_PATH}")
    for line in ENV_PATH.read_text().splitlines():
        m = re.match(r"^\s*OPENROUTER_API_KEY\s*=\s*(.+?)\s*$", line)
        if m:
            return m.group(1).strip().strip('"').strip("'")
    sys.exit("OPENROUTER_API_KEY not found in env file")


# ---------------------------------------------------------------- candidates --
# Mix of small instruct candidates + a few "ceilings" to see what the task allows.
CANDIDATES: list[str] = [
    # Mistral edge family (Ministral 3 series, Dec 2025)
    "mistralai/ministral-3b-2512",
    "mistralai/ministral-8b-2512",
    # Qwen3.5 — only 9B+ exposed on OpenRouter; smaller sizes are local-only.
    "qwen/qwen3.5-9b",
    # Gemma 3n — Google's edge family (E2B / E4B). Closest analogue to "small Gemma 4".
    "google/gemma-3n-e2b-it:free",
    "google/gemma-3n-e4b-it",
    # Gemma 3 baseline at 4B
    "google/gemma-3-4b-it",
    # Llama small
    "meta-llama/llama-3.2-3b-instruct",
    # Phi
    "microsoft/phi-4",
    # Ceilings — what does the task allow at all?
    "anthropic/claude-haiku-4.5",
    "openai/gpt-4o-mini",
    "google/gemini-2.5-flash-lite",
]


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


@dataclass
class Result:
    model: str
    case: str
    raw: str
    cleaned: str
    latency_ms: float
    prompt_tokens: int
    completion_tokens: int
    cost_usd: float
    error: str | None = None


def call_openrouter(client: httpx.Client, api_key: str, model: str, raw: str) -> Result:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": raw},
        ],
        "temperature": 0.3,
        "top_p": 0.6,
        "max_tokens": 256,
        # Keep responses focused; some providers honor this header.
        "usage": {"include": True},
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "HTTP-Referer": "https://blablabla.local",
        "X-Title": "Blablabla voice-cleanup bench",
    }
    t0 = time.perf_counter()
    try:
        resp = client.post(
            "https://openrouter.ai/api/v1/chat/completions",
            json=payload,
            headers=headers,
            timeout=60.0,
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000
        if resp.status_code != 200:
            return Result(model=model, case="", raw=raw, cleaned="",
                          latency_ms=elapsed_ms, prompt_tokens=0,
                          completion_tokens=0, cost_usd=0,
                          error=f"HTTP {resp.status_code}: {resp.text[:200]}")
        data = resp.json()
    except Exception as e:
        return Result(model=model, case="", raw=raw, cleaned="",
                      latency_ms=(time.perf_counter() - t0) * 1000,
                      prompt_tokens=0, completion_tokens=0, cost_usd=0,
                      error=str(e))

    msg = data["choices"][0]["message"]
    content = msg.get("content") or msg.get("reasoning") or ""
    content = content.strip().strip('"').strip()
    usage = data.get("usage", {})
    return Result(
        model=model,
        case="",
        raw=raw,
        cleaned=content,
        latency_ms=elapsed_ms,
        prompt_tokens=usage.get("prompt_tokens", 0),
        completion_tokens=usage.get("completion_tokens", 0),
        cost_usd=float(usage.get("cost", 0) or 0),
    )


def bench_model(client: httpx.Client, api_key: str, model: str) -> list[Result]:
    print(f"\n=== {model} ===", flush=True)
    results: list[Result] = []
    for name, raw in CASES:
        r = call_openrouter(client, api_key, model, raw)
        r.case = name
        results.append(r)
        if r.error:
            print(f"  [{name}] ERROR  {r.error}", flush=True)
        else:
            print(f"  [{name}] {r.latency_ms:5.0f} ms  "
                  f"({r.completion_tokens} tok)  -> {r.cleaned[:80]}", flush=True)
    return results


def render_markdown(all_results: list[Result]) -> str:
    out: list[str] = []
    out.append(f"# OpenRouter cleanup benchmark — {time.strftime('%Y-%m-%d %H:%M')}\n")

    by_case: dict[str, list[Result]] = {}
    for r in all_results:
        by_case.setdefault(r.case, []).append(r)

    for case_name, rows in by_case.items():
        sample_raw = next((r.raw for r in rows if r.raw), "")
        out.append(f"## Case `{case_name}`\n")
        out.append(f"**Input** ({len(sample_raw)} chars): {sample_raw}\n")
        out.append("| Model | ms | tok | $ | Output |")
        out.append("|---|---:|---:|---:|---|")
        for r in sorted(rows, key=lambda x: x.latency_ms):
            if r.error:
                out.append(f"| {r.model} | — | — | — | ⚠️ {r.error[:60]} |")
            else:
                out.append(f"| {r.model} | {r.latency_ms:.0f} "
                           f"| {r.completion_tokens} "
                           f"| {r.cost_usd:.4f} | {r.cleaned} |")
        out.append("")

    out.append("## Summary\n")
    out.append("| Model | mean ms | total $ | failures |")
    out.append("|---|---:|---:|---:|")
    by_model: dict[str, list[Result]] = {}
    for r in all_results:
        by_model.setdefault(r.model, []).append(r)
    rows = []
    for mid, rs in by_model.items():
        ok = [r for r in rs if not r.error]
        fail = [r for r in rs if r.error]
        if ok:
            mean_ms = sum(r.latency_ms for r in ok) / len(ok)
            total_cost = sum(r.cost_usd for r in ok)
            rows.append((mid, mean_ms, total_cost, len(fail)))
        else:
            rows.append((mid, float("inf"), 0, len(fail)))
    rows.sort(key=lambda x: x[1])
    for mid, ms, cost, fails in rows:
        ms_str = f"{ms:.0f}" if ms != float("inf") else "—"
        out.append(f"| {mid} | {ms_str} | {cost:.4f} | {fails} |")
    return "\n".join(out)


def main() -> None:
    api_key = read_api_key()
    print(f"Using OpenRouter key from {ENV_PATH}: ...{api_key[-6:]}")

    all_results: list[Result] = []
    with httpx.Client() as client:
        for mid in CANDIDATES:
            all_results.extend(bench_model(client, api_key, mid))

    md = render_markdown(all_results)
    out_path = Path(__file__).parent / "results_openrouter.md"
    out_path.write_text(md, encoding="utf-8")
    print("\n" + "=" * 72)
    print(md)
    print("=" * 72)
    print(f"\nResults written to: {out_path}")

    json_path = Path(__file__).parent / "results_openrouter.json"
    json_path.write_text(
        json.dumps([r.__dict__ for r in all_results], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"Raw JSON:           {json_path}")


if __name__ == "__main__":
    main()
