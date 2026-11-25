# Inferoid for Windows (work in progress)

Tauri 2 (Rust core) + React. Same meeting folder layout and prompts as the Mac app in `apps/notes`, so data is portable.

Status: first port of the Nov 23 Mac app (meetings, recording via WASAPI loopback + whisper.cpp, notes, chat, Brain + Orbit).
Not yet: Library, Journal, assistant chat, web search; bundled llama-server/whisper/model; code signing.

CI (`.github/workflows/desktop.yml`) builds and tests it on Windows and uploads the installer as an artifact.
Local build on Windows: install Rust (rustup), Node 20 and pnpm 9, then `pnpm install && pnpm tauri build` in this folder.
Engine settings: copy `src-tauri/config/engine.example.json` and point it at `llama-server.exe`, `whisper-cli.exe` and a model.
