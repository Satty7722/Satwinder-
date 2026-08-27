# Hermes Agent: "No inference provider configured"

This note captures the fix for the Hermes Agent (Nous Research) runtime error:

```
No inference provider configured.
Run hermes model to choose a provider and model, or set an API key
(OPENROUTER_API_KEY, OPENAI_API_KEY, etc.) in ~/.hermes/.env.
```

This is a **local runtime error**, not a crash of the desktop/TUI itself. The
chat UI loaded fine, but when a message is sent, the agent tries to call an
LLM and finds no usable provider + credentials.

## What "inference provider" means

Hermes is an agent shell — it does not ship a built-in model. Every reply
must go through one of:

- **Cloud APIs**: OpenRouter, OpenAI, Anthropic, Nous Portal, Copilot, xAI,
  DeepSeek, etc.
- **A local OpenAI-compatible server**: Ollama, LM Studio, vLLM, llama.cpp

The install deliberately does not pick a default vendor, so a fresh (or
reset) `~/.hermes` has no provider until you configure one.

## Why it appears

The agent runtime looks for a provider in this order (simplified):

1. `model.provider` / `model.default` in `~/.hermes/config.yaml`
2. Env vars / keys in `~/.hermes/.env` (`OPENROUTER_API_KEY`,
   `OPENAI_API_KEY`, and other provider-specific keys)
3. OAuth tokens in `~/.hermes/auth.json` (Nous Portal, Copilot, Codex,
   Claude, …)
4. Named custom endpoints

If all of those are empty or unusable, it throws `no_provider_configured`.

Common causes:

| Cause | What happened |
| --- | --- |
| First-run / skipped wizard | Installer finished, but `hermes model` / `hermes setup` was never run |
| Keys in the wrong place | Key exported in the shell, or put in `config.yaml` instead of `~/.hermes/.env` |
| Wrong home directory | Configured as user A, but the desktop app / gateway / cron runs as user B or root, so it reads a different `~/.hermes` |
| OAuth logged in, runtime not bound | Setup looked green but no default `model.provider` was written |
| Session vs global config | An older bot/session stored a bare provider like `"custom"` that resume cannot resolve |

## How to fix it

Run these outside the chat, in a normal terminal — not `/model` inside a
session (that only switches among providers that already exist).

**1. Run the wizard (recommended)**

```bash
hermes model
```

Pick a provider, authenticate (API key or OAuth), then pick a model. This
writes:

- non-secrets → `~/.hermes/config.yaml`
- secrets → `~/.hermes/.env`
- OAuth → `~/.hermes/auth.json`

**2. Confirm it stuck**

```bash
hermes doctor
hermes config show
hermes status
```

You want a real `model.provider` and a matching key or OAuth entry.

**3. Quick key-only path (if you already have an API key)**

```bash
hermes config set OPENROUTER_API_KEY sk-or-...
# or
echo 'OPENROUTER_API_KEY=sk-or-...' >> ~/.hermes/.env
```

Then set provider + model in `config.yaml`, or just run `hermes model`
again so both are consistent. Do not put API keys in `config.yaml`.

**4. Local models**

In `hermes model`, choose a custom / Ollama / LM Studio endpoint, e.g.
`http://localhost:11434/v1`, and a model name the local server actually
serves.

**5. If it still fails**

Check that the process serving the desktop UI is using the same home
directory:

```bash
echo $HOME
ls -la ~/.hermes/
cat ~/.hermes/config.yaml | head -40
# look for keys without printing full secrets:
grep -E '^[A-Z0-9_]+=' ~/.hermes/.env | cut -d= -f1
```

If the gateway or desktop service runs as another user (common with
systemd as root), either run that service as your user or copy
`~/.hermes` to that user's home. Then use **Retry** in the error card, or
start a new chat tab (existing tabs keep the runtime they started with).

## Error card buttons

- **Retry** — resends the last message after you fix config
- **Open logs** — `~/.hermes/logs/` (or the in-app log viewer); look for
  `no_provider_configured` / auth resolution
- **Send diagnostics / Copy error details** — useful if you file a GitHub
  issue

Once a provider is configured for the same user the app runs as, sending a
message should go through instead of the red error panel.
