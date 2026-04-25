#!/usr/bin/env python3
"""
Compare LONG vs COMPACT system prompt on Qwen3.5-4B-MLX-4bit.

Goal: verify that shrinking the prompt for latency doesn't degrade cleanup quality.
Same test cases as cleanup_bench.py, single model, both prompts side-by-side.
"""

from __future__ import annotations

import gc
import time
from pathlib import Path

from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler
import mlx.core as mx


MODEL_ID = "mlx-community/Qwen3.5-4B-MLX-4bit"

# Long prompt — what we shipped before (3 few-shot examples).
PROMPT_LONG = """\
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

# Compact prompt — shipped now in LLMService.swift.
PROMPT_COMPACT = """\
Чисти русскую устную речь. Удаляй слова-паразиты: ну, вот, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой. Не удаляй "вот"/"это" если нужны по смыслу. Исправь очевидные ошибки распознавания. Сохрани смысл и порядок слов, не перефразируй и ничего не добавляй. Верни ТОЛЬКО исправленный текст одной строкой, без кавычек.

Примеры:
Вход: Так ну а теперь давай потестируем нейросеть. В общем как она справляется с этими словами паразитами
Выход: А теперь давай потестируем нейросеть. Как она справляется с этими словами-паразитами

Вход: Короче, в общем, надо запушить ветку в гит и открыть пулл реквест
Выход: Надо запушить ветку в гит и открыть пулл реквест
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

MAX_TOKENS = 256
TEMPERATURE = 0.3
TOP_P = 0.6


def strip_think(s: str) -> str:
    if "</think>" in s:
        start = s.index("<think>") if "<think>" in s else 0
        end = s.index("</think>") + len("</think>")
        s = s[:start] + s[end:]
    return s.strip().strip('"').strip()


def run_case(model, tokenizer, sampler, system: str, raw: str) -> tuple[str, float, int]:
    messages = [
        {"role": "system", "content": system},
        {"role": "user", "content": raw},
    ]
    try:
        prompt = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False,
            enable_thinking=False,
        )
    except TypeError:
        prompt = tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, tokenize=False
        )
    prompt_tokens = len(tokenizer.encode(prompt))

    t0 = time.perf_counter()
    out = generate(
        model, tokenizer, prompt=prompt,
        max_tokens=MAX_TOKENS, sampler=sampler, verbose=False,
    )
    elapsed_ms = (time.perf_counter() - t0) * 1000
    return strip_think(out), elapsed_ms, prompt_tokens


def main() -> None:
    print(f"Loading {MODEL_ID} …")
    model, tokenizer = load(MODEL_ID)
    sampler = make_sampler(temp=TEMPERATURE, top_p=TOP_P)

    # Warm both prompt variants once so first measurement is fair.
    print("Warming up …")
    _ = run_case(model, tokenizer, sampler, PROMPT_LONG, "Привет.")
    _ = run_case(model, tokenizer, sampler, PROMPT_COMPACT, "Привет.")

    # Probe prompt sizes.
    long_pt = len(tokenizer.encode(PROMPT_LONG))
    compact_pt = len(tokenizer.encode(PROMPT_COMPACT))
    print(f"\nPrompt sizes: long={long_pt} tok, compact={compact_pt} tok "
          f"(reduction: {(1 - compact_pt / long_pt) * 100:.0f}%)\n")

    md: list[str] = []
    md.append(f"# Prompt comparison — Qwen3.5-4B-MLX-4bit\n")
    md.append(f"**Long prompt**: {long_pt} tokens.  "
              f"**Compact**: {compact_pt} tokens.  "
              f"Reduction: {(1 - compact_pt / long_pt) * 100:.0f}%.\n")

    long_total, compact_total = 0.0, 0.0

    for name, raw in CASES:
        # Long
        out_l, ms_l, pt_l = run_case(model, tokenizer, sampler, PROMPT_LONG, raw)
        # Compact
        out_c, ms_c, pt_c = run_case(model, tokenizer, sampler, PROMPT_COMPACT, raw)
        long_total += ms_l
        compact_total += ms_c

        delta = ms_l - ms_c
        delta_pct = delta / ms_l * 100 if ms_l > 0 else 0

        md.append(f"\n## `{name}`\n")
        md.append(f"**Input**: {raw}\n")
        md.append(f"| Variant | ms | prompt tok | Output |")
        md.append(f"|---|---:|---:|---|")
        md.append(f"| Long | {ms_l:.0f} | {pt_l} | {out_l} |")
        md.append(f"| **Compact** | **{ms_c:.0f}** | **{pt_c}** | **{out_c}** |")
        md.append(f"| Δ | {delta:+.0f} ms ({delta_pct:+.0f}%) | | |")

        print(f"[{name:25}] long {ms_l:5.0f} ms → compact {ms_c:5.0f} ms  "
              f"(Δ {delta:+.0f} ms / {delta_pct:+.0f}%)")
        print(f"  long:    {out_l}")
        print(f"  compact: {out_c}\n")

    md.append("\n## Summary\n")
    md.append(f"- Total long: {long_total:.0f} ms")
    md.append(f"- Total compact: {compact_total:.0f} ms")
    md.append(f"- Mean per case (long): {long_total / len(CASES):.0f} ms")
    md.append(f"- Mean per case (compact): {compact_total / len(CASES):.0f} ms")
    md.append(f"- Speedup: {(1 - compact_total / long_total) * 100:.0f}%")

    out_path = Path(__file__).parent / "results_prompt_compare.md"
    out_path.write_text("\n".join(md), encoding="utf-8")
    print(f"\nResults written to: {out_path}")

    del model, tokenizer
    gc.collect()
    mx.clear_cache()


if __name__ == "__main__":
    main()
