# teddy_talks

Wake word → STT → GPT-3.5 → TTS for a plush companion.

## Build an APK in the cloud (no Android SDK needed)

1) Put your Porcupine file
- Place your real keyword file at `assets/wake/hey_teddy.ppn`.

2) Generate Base64 for GitHub secret (Windows)
- Right-click `scripts/encode_ppn.ps1` → Run with PowerShell.
- It creates `hey_teddy_base64.txt` in the project root. Open it and copy the single long line.

3) Add GitHub Actions secrets
- On GitHub → Settings → Secrets and variables → Actions → New repository secret.
	- `OPENAI_API_KEY` = your OpenAI key
	- `PICOVOICE_ACCESS_KEY` = your Picovoice key
	- `HEY_TEDDY_PPN_BASE64` = paste the content of `hey_teddy_base64.txt`

4) Run the cloud build
- On GitHub → Actions → Build Android APK → Run workflow (branch: main).
- When it finishes, download the `teddy-talks-debug-apk` artifact → get `app-debug.apk`.

5) Sideload
- Copy `app-debug.apk` to your Android phone and install (enable “Install unknown apps” if prompted).
- Grant microphone permission. Say “Hey Teddy”.

## Local run (optional)
- In VS Code, install Flutter/Dart extensions. Update `.vscode/launch.json` with your keys. Connect an Android device and run the preset.
