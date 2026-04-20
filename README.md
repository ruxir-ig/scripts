# Windows Dev CLI Bootstrap

Installs Node.js, npm, OpenAI Codex CLI, and OpenCode CLI on Windows with one command.

## What it does

- Reuses an existing Node.js install when possible.
- Downloads the latest official Node.js LTS from `nodejs.org` when Node.js is missing.
- Ensures the required PATH entries are added automatically.
- Sets npm's global prefix to `%APPDATA%\npm` so global CLIs work without manual PATH edits.
- Installs `@openai/codex` and `opencode-ai` only when they are missing.

## One-line install

```powershell
irm https://raw.githubusercontent.com/ruxir-ig/scripts/main/install-dev-tools.ps1 | iex
```

If the user is already in `cmd.exe`, this also works:

```bat
curl -fsSL https://raw.githubusercontent.com/ruxir-ig/scripts/main/install-dev-tools.cmd -o %TEMP%\install-dev-tools.cmd && %TEMP%\install-dev-tools.cmd
```

## Local run

```powershell
.\install-dev-tools.ps1
```

or:

```bat
install-dev-tools.cmd
```

## Optional switches

```powershell
.\install-dev-tools.ps1 -ReinstallNode
.\install-dev-tools.ps1 -ReinstallCodex
.\install-dev-tools.ps1 -ReinstallOpenCode
```
