# OpenRouter cleanup benchmark — 2026-04-25 15:59

## Case `counting`

**Input** (24 chars): Раз, два, раз, два, три.

| Model | ms | tok | $ | Output |
|---|---:|---:|---:|---|
| mistralai/ministral-8b-2512 | 368 | 8 | 0.0001 | Раз, два, три. |
| google/gemma-3-4b-it | 541 | 7 | 0.0000 | Раз, два, три. |
| meta-llama/llama-3.2-3b-instruct | 546 | 7 | 0.0000 | Раз, два, три. |
| microsoft/phi-4 | 616 | 15 | 0.0000 | Раз, два, раз, два, три. |
| openai/gpt-4o-mini | 795 | 11 | 0.0001 | Раз, два, раз, два, три. |
| google/gemini-2.5-flash-lite | 1241 | 10 | 0.0000 | Раз, два, раз, два, три. |
| anthropic/claude-haiku-4.5 | 1414 | 16 | 0.0005 | Раз, два, раз, два, три. |
| mistralai/ministral-3b-2512 | 1928 | 8 | 0.0001 | Раз, два, три. |
| google/gemma-3n-e4b-it | 2362 | 12 | 0.0000 | Раз, два, раз, два, три. |
| google/gemma-3n-e2b-it:free | — | — | — | ⚠️ HTTP 400: {"error":{"message":"Provider returned error","cod |
| qwen/qwen3.5-9b | 3843 | 256 | 0.0001 | Thinking Process:

1.  **Analyze the Request:**
    *   Role: Editor of spoken language (transcription cleaner).
    *   Task: Remove filler words and stutters (e.g., ну, вот, это, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой) unless they are part of a meaningful phrase (e.g., "вот этот стол" -> "вот" can be removed, "этот" stays).
    *   Constraints: Fix obvious recognition errors, keep meaning and word order, do not paraphrase or add anything.
    *   Output Format: ONLY the corrected text in a single line, no explanations, no quotes.
    *   Input: "Раз, два, раз, два, три."

2.  **Analyze the Input:**
    *   Text: "Раз, два, раз, два, три."
    *   Context: This looks like a counting rhyme or a rhythmic phrase (like "Raz, dva, raz, dva, tri").
    *   Filler words check: Are there any filler words like "ну", "вот |

## Case `medium_with_fillers`

**Input** (232 chars): Так, ну а теперь давай потестируем работу нейросети. В общем, как она у нас справляется со всякими вот этими словами, паузами лишними и всем остальным. Короче, просто хочется сказать, что может быть правда в этот раз все получилось.

| Model | ms | tok | $ | Output |
|---|---:|---:|---:|---|
| mistralai/ministral-3b-2512 | 504 | 57 | 0.0000 | Так давайте протестируем работу нейросети. Как она справляется со словами-паразитами, паузами и остальными лишними элементами. Просто хочется сказать, что может быть в этот раз всё получилось. |
| meta-llama/llama-3.2-3b-instruct | 638 | 46 | 0.0000 | Тестируем работу нейросети. В общем, как она справляется со словами-паразитами. Просто хочется сказать, что может быть правда, что в этот раз все получилось. |
| mistralai/ministral-8b-2512 | 878 | 54 | 0.0000 | Давай потестируем работу нейросети. Как она справляется со всякими словами, паузами, лишними элементами и остальным. Хочется сказать, что может быть правда в этот раз всё получилось. |
| google/gemma-3-4b-it | 965 | 40 | 0.0000 | Давай потестируем работу нейросети. Как она справляется со словами, паузами и всем остальным. Просто хочется сказать, что может быть правда в этот раз все получилось. |
| google/gemma-3n-e2b-it:free | — | — | — | ⚠️ HTTP 400: {"error":{"message":"Provider returned error","cod |
| anthropic/claude-haiku-4.5 | 1240 | 77 | 0.0009 | А теперь давай потестируем работу нейросети. Как она у нас справляется со всякими этими словами, паузами лишними и всем остальным. Просто хочется сказать, что может быть правда в этот раз все получилось. |
| openai/gpt-4o-mini | 1262 | 47 | 0.0001 | А теперь давай потестируем работу нейросети. Как она у нас справляется со всякими словами, паузами лишними и всем остальным. Просто хочется сказать, что может быть правда в этот раз всё получилось. |
| google/gemini-2.5-flash-lite | 1281 | 47 | 0.0001 | А теперь давай потестируем работу нейросети. Как она у нас справляется со всякими словами, паузами лишними и всем остальным. Просто хочется сказать, что может быть правда в этот раз все получилось. |
| google/gemma-3n-e4b-it | 3904 | 44 | 0.0000 | Давай потестируем работу нейросети. Как она у нас справляется со словами, паузами лишними и всем остальным. Просто хочется сказать, что может быть правда в этот раз всё получилось. |
| qwen/qwen3.5-9b | 4165 | 256 | 0.0001 | Thinking Process:

1.  **Analyze the Request:**
    *   Role: Editor of spoken language.
    *   Input: Raw transcription.
    *   Task: Remove filler words and stutters, fix obvious recognition errors, preserve meaning and word order, do not paraphrase or add anything.
    *   Output Format: Only the corrected text, single line, no explanations, no quotes.
    *   Specific Fillers to Remove: ну, вот, это, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой (unless part of a meaningful phrase).
    *   Examples provided show how to handle punctuation and flow.

2.  **Analyze the Input Text:**
    "Так, ну а теперь давай потестируем работу нейросети. В общем, как она у нас справляется со всякими вот этими словами, паузами лишними и всем остальным. Короче, просто хочется сказать, что может быть правда в этот раз все получилось."

3.  **Step-by-Step Processing:**

    *   Segment 1: "Так, ну а теперь давай потестируем работу |
| microsoft/phi-4 | 8160 | 79 | 0.0001 | Давай потестируем работу нейросети. Как она у нас справляется со всякими словами, паузами лишними и всем остальным. Просто хочется сказать, что может быть правда в этот раз все получилось. |

## Case `repeated_starts`

**Input** (212 chars): Так ну давай еще раз попробуем. Давай потестируем. В общем, короче, как она у нас справляется со всеми какими словами паразитами. Короче, просто хочется сказать, что может быть и правда в этот раз все получилось.

| Model | ms | tok | $ | Output |
|---|---:|---:|---:|---|
| meta-llama/llama-3.2-3b-instruct | 483 | 12 | 0.0000 | Я справляется со словами-паразитами. |
| mistralai/ministral-3b-2512 | 620 | 37 | 0.0001 | Давайте протестируем, как она справляется со всеми словами-паразитами. Просто хочется сказать, что в этот раз всё получилось. |
| google/gemma-3-4b-it | 809 | 34 | 0.0000 | Давай потестируем, как она справляется со словами-паразитами. Просто хочется сказать, что может быть и правда в этот раз все получилось. |
| mistralai/ministral-8b-2512 | 977 | 46 | 0.0001 | Давай еще раз попробуем. Потестируем, как справляется со всеми словами-паразитами. Хочется сказать, что может быть и правда в этот раз всё получилось. |
| google/gemma-3n-e2b-it:free | — | — | — | ⚠️ HTTP 400: {"error":{"message":"Provider returned error","cod |
| openai/gpt-4o-mini | 1040 | 37 | 0.0001 | Давай потестируем. Как она у нас справляется со всеми словами-паразитами. Просто хочется сказать, что может быть и правда в этот раз всё получилось. |
| microsoft/phi-4 | 1226 | 72 | 0.0000 | Давай еще раз попробуем. Давай потестируем. Как она у нас справляется со всеми словами-паразитами. Просто хочется сказать, что может быть и правда в этот раз все получилось. |
| google/gemini-2.5-flash-lite | 1608 | 44 | 0.0001 | Давай еще раз попробуем. Давай потестируем. Как она у нас справляется со всеми какими словами паразитами. Просто хочется сказать, что может быть и правда в этот раз все получилось. |
| anthropic/claude-haiku-4.5 | 1691 | 72 | 0.0009 | Давай еще раз попробуем. Давай потестируем. Как она у нас справляется со всеми какими словами паразитами. Просто хочется сказать, что может быть и правда в этот раз все получилось. |
| google/gemma-3n-e4b-it | 2681 | 37 | 0.0000 | Давай потестируем. Как она у нас справляется со всеми словами-паразитами? Просто хочется сказать, что может быть и правда в этот раз всё получилось. |
| qwen/qwen3.5-9b | 3893 | 256 | 0.0001 | Thinking Process:

1.  **Analyze the Request:**
    *   Role: Editor of spoken language (transcription cleaner).
    *   Task: Remove filler words and stutters, correct obvious recognition errors, preserve meaning and word order, do not paraphrase or add anything.
    *   Output Format: ONLY the corrected text, single line, no explanations, no quotes.
    *   Specific Filler Words to Remove (unless part of a meaningful phrase): ну, вот, это, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой.
    *   Input Text: "Так ну давай еще раз попробуем. Давай потестируем. В общем, короче, как она у нас справляется со всеми какими словами паразитами. Короче, просто хочется сказать, что может быть и правда в этот раз все получилось."

2.  **Process the Input Text:**
    *   Segment 1: "Так ну давай еще раз попробуем."
        *   "Так" -> Filler (remove).
        *   "ну" -> Filler (remove).
        * |

## Case `short_filler_only`

**Input** (23 chars): Эм, ну, как бы, привет.

| Model | ms | tok | $ | Output |
|---|---:|---:|---:|---|
| mistralai/ministral-8b-2512 | 313 | 4 | 0.0001 | Привет. |
| google/gemma-3-4b-it | 445 | 3 | 0.0000 | Привет. |
| microsoft/phi-4 | 448 | 5 | 0.0000 | Привет. |
| mistralai/ministral-3b-2512 | 527 | 4 | 0.0001 | Привет. |
| meta-llama/llama-3.2-3b-instruct | 592 | 5 | 0.0000 | Привет. |
| openai/gpt-4o-mini | 603 | 4 | 0.0001 | Привет. |
| google/gemma-3n-e4b-it | 1016 | 4 | 0.0000 | Привет. |
| google/gemma-3n-e2b-it:free | — | — | — | ⚠️ HTTP 400: {"error":{"message":"Provider returned error","cod |
| google/gemini-2.5-flash-lite | 1070 | 2 | 0.0000 | Привет. |
| anthropic/claude-haiku-4.5 | 1541 | 7 | 0.0005 | Привет. |
| qwen/qwen3.5-9b | 6143 | 256 | 0.0001 | Thinking Process:

1.  **Analyze the Request:**
    *   Role: Editor of spoken language (transcription cleaner).
    *   Input: Raw transcription.
    *   Task: Remove filler words and stutters, correct obvious recognition errors, preserve meaning and word order, do not paraphrase or add anything.
    *   Output Format: ONLY the corrected text, single line, no explanations, no quotes.
    *   Specific Rules:
        *   Always remove: ну, вот, это, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой.
        *   Exception: If filler words are part of a meaningful phrase (e.g., "вот этот стол" -> "вот" can be removed, "этот" is part of the phrase, wait, the instruction says "вот этот стол" -> "вот" remove, "это" remove? Let's re-read carefully: "Если они в составе осмысленной фразы — оставь. Например: "вот этот стол" — оставить "это" нельзя удалить, "вот" удалить можно." -> Actually, |

## Case `preserve_meaning`

**Input** (54 chars): Слушай, можешь напомнить вечером купить молоко и хлеб.

| Model | ms | tok | $ | Output |
|---|---:|---:|---:|---|
| mistralai/ministral-3b-2512 | 496 | 19 | 0.0000 | Слушай, напомни вечером купить молоко и хлеб. |
| google/gemma-3-4b-it | 592 | 15 | 0.0000 | Слушай, можешь напомнить купить молоко и хлеб. |
| microsoft/phi-4 | 615 | 21 | 0.0000 | Напомни вечером купить молоко и хлеб. |
| meta-llama/llama-3.2-3b-instruct | 657 | 14 | 0.0000 | Могу купить молоко и хлеб вечером. |
| mistralai/ministral-8b-2512 | 695 | 19 | 0.0001 | Слушай, напомни вечером купить молоко и хлеб. |
| openai/gpt-4o-mini | 870 | 16 | 0.0001 | Слушай, можешь напомнить вечером купить молоко и хлеб. |
| anthropic/claude-haiku-4.5 | 994 | 25 | 0.0006 | Можешь напомнить вечером купить молоко и хлеб. |
| google/gemma-3n-e2b-it:free | — | — | — | ⚠️ HTTP 400: {"error":{"message":"Provider returned error","cod |
| google/gemini-2.5-flash-lite | 1154 | 15 | 0.0000 | Слушай, можешь напомнить вечером купить молоко и хлеб. |
| google/gemma-3n-e4b-it | 1646 | 17 | 0.0000 | Слушай, можешь напомнить вечером купить молоко и хлеб. |
| qwen/qwen3.5-9b | 4174 | 256 | 0.0001 | Thinking Process:

1.  **Analyze the Request:**
    *   Role: Editor of spoken language (transcription cleaner).
    *   Task: Remove filler words and stutters, correct obvious recognition errors, preserve meaning and word order, do not paraphrase or add anything.
    *   Output Format: ONLY the corrected text, single line, no explanations, no quotes.
    *   Specific Filler Words to Remove (unless part of a meaningful phrase): ну, вот, это, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой.
    *   Input Text: "Слушай, можешь напомнить вечером купить молоко и хлеб."

2.  **Analyze the Input Text:**
    *   "Слушай" (Listen/Hey) - Often a filler or discourse marker in spoken Russian. In this context, it's an interjection to get attention. Should it be removed? The instructions say "ну, вот, это, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой". "Слу |

## Case `mixed_ru_tech_terms`

**Input** (66 chars): Короче, в общем, надо запушить ветку в гит и открыть пулл реквест.

| Model | ms | tok | $ | Output |
|---|---:|---:|---:|---|
| mistralai/ministral-3b-2512 | 350 | 19 | 0.0000 | Запушить ветку в гит и открыть пулл-реквест. |
| meta-llama/llama-3.2-3b-instruct | 477 | 21 | 0.0000 | Надо запушить ветку в гит и открыть пулл реквест. |
| mistralai/ministral-8b-2512 | 520 | 20 | 0.0000 | Надо запушить ветку в гит и открыть пулл-реквест. |
| google/gemma-3-4b-it | 696 | 18 | 0.0000 | Надо запушить ветку в Git и открыть пулл реквест. |
| microsoft/phi-4 | 715 | 27 | 0.0000 | Надо запушить ветку в гит и открыть пулл реквест. |
| openai/gpt-4o-mini | 912 | 18 | 0.0001 | Надо запушить ветку в гит и открыть пулл реквест. |
| google/gemma-3n-e2b-it:free | — | — | — | ⚠️ HTTP 400: {"error":{"message":"Provider returned error","cod |
| google/gemini-2.5-flash-lite | 1132 | 17 | 0.0000 | Надо запустить ветку в гит и открыть пулл реквест. |
| anthropic/claude-haiku-4.5 | 1540 | 26 | 0.0006 | Надо запушить ветку в гит и открыть пулл реквест. |
| google/gemma-3n-e4b-it | 2397 | 15 | 0.0000 | Надо запустить ветку в Git и открыть pull request. |
| qwen/qwen3.5-9b | 3789 | 256 | 0.0001 | Thinking Process:

1.  **Analyze the Request:**
    *   Role: Editor of spoken language (transcription cleaner).
    *   Task: Remove filler words and stutters, correct obvious recognition errors, preserve meaning and word order, do not paraphrase or add anything.
    *   Input: Raw transcription.
    *   Output: Only the corrected text, single line, no explanations, no quotes.
    *   Specific fillers to remove (unless part of a meaningful phrase): ну, вот, это, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой.
    *   Example logic: "вот этот стол" -> "вот этот стол" (wait, the prompt says "вот этот стол" — оставить "это" нельзя удалить, "вот" удалить можно. Actually, looking at the example: "вот этот стол" -> "вот этот стол" is not an example. The example says: "вот этот стол" — оставить "это" нельзя удалить, "вот" удалить можно. Wait, let's re-read carefully: "Если они в составе осмыслен |

## Case `question`

**Input** (72 chars): Слушай, э-э, а ты не знаешь, во сколько у нас завтра встреча с командой?

| Model | ms | tok | $ | Output |
|---|---:|---:|---:|---|
| mistralai/ministral-3b-2512 | 340 | 20 | 0.0000 | Слушай, не знаешь, во сколько у нас завтра встреча с командой? |
| mistralai/ministral-8b-2512 | 609 | 19 | 0.0001 | Слушай, ты не знаешь, во сколько завтра встреча с командой? |
| google/gemma-3-4b-it | 653 | 18 | 0.0000 | Слушай, не знаешь, во сколько у нас завтра встреча с командой? |
| meta-llama/llama-3.2-3b-instruct | 677 | 18 | 0.0000 | Я не знаю, когда у нас завтра встреча с командой. |
| microsoft/phi-4 | 758 | 34 | 0.0000 | Слушай, ты не знаешь, во сколько у нас завтра встреча с командой? |
| openai/gpt-4o-mini | 864 | 22 | 0.0001 | Слушай, а ты не знаешь, во сколько у нас завтра встреча с командой? |
| anthropic/claude-haiku-4.5 | 932 | 29 | 0.0006 | А ты не знаешь, во сколько у нас завтра встреча с командой? |
| google/gemma-3n-e2b-it:free | — | — | — | ⚠️ HTTP 400: {"error":{"message":"Provider returned error","cod |
| google/gemini-2.5-flash-lite | 1149 | 19 | 0.0000 | Слушай, а ты не знаешь, во сколько у нас завтра встреча с командой? |
| google/gemma-3n-e4b-it | 1730 | 21 | 0.0000 | Слушай, а ты не знаешь, во сколько у нас завтра встреча с командой? |
| qwen/qwen3.5-9b | 4465 | 256 | 0.0001 | Thinking Process:

1.  **Analyze the Request:**
    *   Role: Editor of spoken language.
    *   Input: Raw transcription.
    *   Task: Remove filler words and stutters, correct obvious recognition errors, preserve meaning and word order, do not paraphrase or add anything.
    *   Output Format: Only the corrected text, single line, no explanations, no quotes.
    *   Specific Filler Words to Remove: ну, вот, это, как бы, короче, типа, в общем, так, значит, эм, э-э, м-м, ага, ой (unless part of a meaningful phrase).
    *   Input Text: "Слушай, э-э, а ты не знаешь, во сколько у нас завтра встреча с командой?"

2.  **Analyze the Input Text:**
    *   "Слушай" (Listen) - This is often a discourse marker/filler in spoken Russian, but can also be an imperative verb. In this context ("Слушай, э-э, а ты не знаешь..."), it functions more like a filler to get attention or start the sentence. However, looking at |

## Summary

| Model | mean ms | total $ | failures |
|---|---:|---:|---:|
| meta-llama/llama-3.2-3b-instruct | 581 | 0.0002 | 0 |
| mistralai/ministral-8b-2512 | 623 | 0.0004 | 0 |
| google/gemma-3-4b-it | 672 | 0.0001 | 0 |
| mistralai/ministral-3b-2512 | 681 | 0.0003 | 0 |
| openai/gpt-4o-mini | 907 | 0.0004 | 0 |
| google/gemini-2.5-flash-lite | 1234 | 0.0003 | 0 |
| anthropic/claude-haiku-4.5 | 1336 | 0.0047 | 0 |
| microsoft/phi-4 | 1791 | 0.0003 | 0 |
| google/gemma-3n-e4b-it | 2248 | 0.0002 | 0 |
| qwen/qwen3.5-9b | 4353 | 0.0005 | 0 |
| google/gemma-3n-e2b-it:free | — | 0.0000 | 7 |