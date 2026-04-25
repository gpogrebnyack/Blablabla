<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="Blablabla app icon">
</p>

<h1 align="center">Blablabla</h1>

<p align="center">
  Snappy native voice dictation for Mac. Fully local — speech recognition on the Neural Engine, optional LLM cleanup, zero cloud calls.
</p>

<p align="center">
  <em>Hold a key, talk, get clean text in any app — fast.</em>
</p>

<p align="center">
  <a href="https://github.com/gpogrebnyack/Blablabla/releases/latest"><img src="https://img.shields.io/badge/Download-DMG-E86B3B.svg?style=for-the-badge&logo=apple&logoColor=white" alt="Download DMG"></a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-000000.svg" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.0-F05138.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/Apple%20Silicon-only-333333.svg" alt="Apple Silicon only">
  <img src="https://img.shields.io/badge/STT-Parakeet%20TDT%20v3-brightgreen.svg" alt="Parakeet TDT v3">
  <img src="https://img.shields.io/badge/LLM-Qwen3.5%204B-orange.svg" alt="Qwen3.5 4B">
</p>

---

Blablabla is a hold-to-talk dictation menu-bar app. Hit your hotkey, speak, release. The text appears at your cursor in any app — TextEdit, Slack, Cursor, Telegram, terminal, browser. Speech runs on Apple's Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio); the optional cleanup LLM (Qwen3.5-4B 4-bit) runs through [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm). Nothing ever leaves your Mac.

## What it does

**Dictation** — Hold the right Option key (configurable), talk, release. Recognized text is inserted at the cursor, character by character, while the model is still producing it. Works system-wide.

**Three cleanup modes** — Pick how much polish you want. Off keeps Parakeet's raw output. Fast strips filler words ("ну", "вот", "короче", …) via deterministic regex in microseconds. Full sends the text through a local 4B LLM that fixes recognition errors, hyphenates compound words ("слова паразиты" → "слова-паразиты"), and removes fillers in context.

**Smart fast paths** — Single words and short clean utterances (≤30 chars without filler-word starters) skip the LLM entirely so quick replies don't pay 500-1500 ms of latency.

**Streaming insertion** — Text appears as the model produces it, not in one chunk at the end. AX-friendly apps see character-by-character animation; terminals fall back to a single paste at release.

**Hardware advisor** — Settings reads your chip, RAM, and free disk space and recommends the right mode. Warns if you're under-RAM'd before you blow 2.4 GB on a download.

## Performance

On M4 Max, 48 GB RAM:

| Stage | Time |
|---|---|
| Hotkey released → Parakeet ready | ~80 ms |
| Parakeet on a 3 s utterance | ~120 ms |
| Regex cleanup | <1 ms |
| Qwen3.5-4B-MLX-4bit generation | ~50 tokens / sec |
| End-to-end Off / Fast | ~100-150 ms |
| End-to-end Full (3 s utterance, ~30 char output) | ~600-900 ms |

Memory while idle in Full mode: ~5 GB resident (Parakeet + Qwen3.5-4B + MLX runtime).
Off / Fast: ~2 GB.

## Limitations

- **Apple Silicon only.** MLX is M-series exclusive; Parakeet's Neural Engine path doesn't exist on Intel.
- **macOS 26+** as the deployment target. Earlier versions may compile but aren't tested.
- **Russian + 24 European languages** via Parakeet TDT v3 (auto-detect). No CJK support.
- **Permissions required.** Microphone for capture, Accessibility for cursor-aware insertion. The app degrades gracefully if Accessibility is missing — it falls back to clipboard + Cmd+V.

## Get it

**Download the DMG** from [the latest release](https://github.com/gpogrebnyack/Blablabla/releases/latest).

Drag `Blablabla.app` into `/Applications`. **First launch:** right-click → **Open** → **Open** (the build is ad-hoc signed for personal install, not Apple-notarized — Gatekeeper warns once, then never again).

**Or build from source:**

```bash
git clone https://github.com/gpogrebnyack/Blablabla.git
cd Blablabla
open Blablabla.xcodeproj
# Trust & enable macros when prompted, then ⌘R
```

**Or build the DMG yourself:**

```bash
bash scripts/build-dmg.sh
open build/Blablabla.dmg
```

First launch:
1. macOS asks for Microphone — allow.
2. macOS asks for Accessibility — allow, then quit and relaunch (macOS doesn't grant the permission to a running process).
3. If you pick Full mode, the LLM downloads on first activation (~2.4 GB).
4. Parakeet downloads on first dictation (~2.3 GB).

## Tech stack

| Layer | Choice |
|---|---|
| STT | NVIDIA Parakeet TDT v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio) (CoreML, Apple Neural Engine) |
| LLM | Qwen3.5-4B 4-bit via [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) |
| HF integration | [swift-huggingface](https://github.com/huggingface/swift-huggingface) + [swift-transformers](https://github.com/huggingface/swift-transformers) |
| Audio | AVFoundation (`AVAudioEngine` tap, 16 kHz mono Float32 ring buffer) |
| Hotkey | Carbon `RegisterEventHotKey` for hold-to-talk |
| Insertion | `AXUIElement` with `kAXSelectedTextAttribute`, paste fallback for terminal-class apps |
| UI | SwiftUI menu-bar app (`MenuBarExtra`) |
| Language | Swift 6.0 |
| Platform | macOS 26+, Apple Silicon |

## Cleanup modes

| Mode | Latency | What it does |
|---|---|---|
| **Off** | ~100 ms | Insert raw recognition output verbatim. |
| **Fast** | ~100 ms | `RegexCleaner.clean(...)` strips filler-word sequences at sentence boundaries; case-aware. |
| **Full** | 500-1500 ms | Local 4B LLM with a tight system prompt and few-shot examples. Cleans fillers, fixes recognition errors, normalizes punctuation. Streams character-by-character. |

The Full pipeline is bypassed for utterances ≤2 words or ≤30 chars without leading filler words — those don't benefit from LLM cleanup, and the heuristic saves the entire 500-1500 ms LLM hop.

## How it works

```
[Hold hotkey] ──► AVAudioEngine tap ──► 16 kHz mono Float32 buffer
                                              │ (release)
                                              ▼
                                        Parakeet TDT v3 (ANE)
                                              │ raw text
                                              ▼
                                       ┌──────┴──────┐
                                       │             │
                                  short/clean?    everything else
                                       │             │
                                       ▼             ▼
                                  raw insert    cleanup mode
                                                   │
                                          ┌────────┼─────────┐
                                          │        │         │
                                         Off      Fast      Full
                                          │        │         │
                                          ▼        ▼         ▼
                                        verbatim  regex   Qwen3.5-4B
                                                          (streamed)
                                                   │
                                                   ▼
                                              AX insert at cursor
                                              (paste fallback for
                                              Terminal / iTerm /
                                              Ghostty / Warp / …)
```

## Privacy

- All speech recognition runs on the Apple Neural Engine, locally.
- The optional LLM runs on Metal/MLX, locally. The app never makes outbound requests at runtime.
- The only network calls are model downloads from Hugging Face on first use, gated by your mode choice.
- Models are cached in `~/Documents/huggingface/models/` (LLM) and `~/Library/Application Support/FluidAudio/Models/` (STT). Delete those folders to reset.

## Repo layout

```
Blablabla/
├── Blablabla/                     # Swift sources (the app target)
│   ├── BlablablaApp.swift         # @main, MenuBarExtra + Settings scene
│   ├── AppCoordinator.swift       # Pipeline orchestration
│   ├── AudioRecorder.swift        # AVAudioEngine tap + VU meter
│   ├── HotkeyManager.swift        # Carbon hotkey registration
│   ├── STTService.swift           # FluidAudio + Parakeet wrapper
│   ├── LLMService.swift           # mlx-swift-lm + Qwen3.5 wrapper, streaming
│   ├── RegexCleaner.swift         # Deterministic filler-word stripper
│   ├── Inserter.swift             # AX insertion with paste fallback
│   ├── CleanupMode.swift          # Off / Fast / Full enum
│   ├── SystemAdvisor.swift        # Hardware-aware mode recommendation
│   ├── Permissions.swift
│   ├── SettingsView.swift         # SwiftUI Settings (HIG-style)
│   └── Assets.xcassets/           # App icon + menu-bar SVGs
├── scripts/
│   └── build-dmg.sh               # Release build + ad-hoc sign + DMG package
├── assets/                        # README artwork
└── Blablabla.xcodeproj/
```

## Building the DMG

`scripts/build-dmg.sh` produces a compressed UDZO disk image with the .app bundle and an `/Applications` symlink. The script forces `arch=arm64`, ad-hoc signs the bundle so Gatekeeper allows local install, and packages everything via `hdiutil`.

Requirements:
- Full Xcode at `/Applications/Xcode.app` (Command Line Tools alone aren't enough).
- The script auto-detects Xcode and sets `DEVELOPER_DIR`, no `sudo xcode-select` needed.

For distribution outside your own machine you'd need an Apple Developer ID, proper signing, and notarization — not in scope here.

## Acknowledgements

Standing on the shoulders of:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Swift CoreML wrapper for Parakeet that does the heavy lifting on the Neural Engine.
- [MacParakeet](https://github.com/moona3k/macparakeet) — open-source reference for system-wide Parakeet dictation on macOS.
- [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) — Apple's LLM toolkit for MLX.
- [NVIDIA Parakeet TDT](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) — the speech model.
- [Qwen3.5](https://huggingface.co/Qwen) — the cleanup model.

## License

MIT — see [LICENSE](LICENSE).
