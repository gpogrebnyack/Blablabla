# Blablabla — voice cleanup model benchmark

Two complementary scripts:

| Script | Тестирует | Зачем |
|---|---|---|
| `cleanup_bench.py` | локальные MLX 4-bit веса через `mlx-lm` | Точно те же артефакты, что мы загрузим в Swift-приложение. Реальная latency на нашем M4 Max. |
| `openrouter_bench.py` | fp16-веса через OpenRouter | Потолок качества модели. Если модель «не справляется» в cloud — в 4-bit точно не справится. Также позволяет сравнить со «взрослыми» (gpt-4o-mini, claude-haiku) без скачивания. |

Цель: выбрать LLM ≤3B, который чистит русские диктовки лучше всех на данном железе.

## Запуск

### Локальный (mlx-lm)

```bash
pip install "mlx-lm>=0.21"
python benchmark/cleanup_bench.py
```

Первый раз скачает ~10-15 GB моделей в `~/.cache/huggingface/hub/`.
Между моделями выгружается всё → пиковая память ~6 GB.
Результаты — `benchmark/results.md` (Markdown), `benchmark/results.json` (raw).

### Через OpenRouter

```bash
pip install httpx
python benchmark/openrouter_bench.py
```

Ключ читается из `/Users/gpogrebnyak/Downloads/Cursor/Translator (optimized)/.env`
(переменная `OPENROUTER_API_KEY`). Стоимость прогона: ~$0.05-0.10 на весь
список моделей.
Результаты — `benchmark/results_openrouter.md`, `benchmark/results_openrouter.json`.

## Что считаем

- **latency** (ms) — время от отправки до полного ответа.
- **tok/s** — пропускная способность.
- **output** — сам очищенный текст. Качество оцениваем глазами:
  - убраны ли паразиты,
  - сохранён ли смысл,
  - не перефразировал ли модель,
  - не выдумала ли что-то от себя.

## Test cases

Реальные диктовки из логов app + несколько edge cases (короткая фраза с
паразитами, смешанная русско-английская техническая речь, вопрос).
Системный промпт идентичен тому, что зашит в `LLMService.swift`.

## После бенчмарка

Финалист → меняем `modelId` в
`Blablabla/LLMService.swift` и `LabeledContent` в `SettingsView.swift`,
ребилд приложения. Потом 1-2 живых теста через хоткей чтобы убедиться,
что в реальном пайплайне (Parakeet → LLM → AX-вставка) модель ведёт
себя так же, как в скрипте.
