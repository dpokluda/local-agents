# Wiring agent harnesses to the local stack

Every tool below talks to the same place:

```
http://localhost:11434/v1
```

That is Ollama's **OpenAI-compatible endpoint**. Any client that accepts a custom base URL
works against it — including the GitHub Copilot app and Copilot CLI. Most want an API key
too; the shim ignores the value, but clients often refuse to start without one, so pass any
non-empty string (`ollama` by convention).

Most tools read these two variables. Set them in your shell when you need them — there is
no profile doing it for you:

```powershell
$env:OPENAI_BASE_URL = 'http://localhost:11434/v1'
$env:OPENAI_API_KEY  = 'ollama'
```

They only persist for the current shell. For Copilot CLI,
`./scripts/Start-LocalCopilot.ps1` sets everything it needs for the child process so you
don't have to set anything at all.

This page covers **coding agents**. For general chat and non-coding use, see
[chat-apps.md](chat-apps.md).

---

## Before you wire anything up

Confirm the model you intend to use actually emits tool calls through `/v1`:

```powershell
./scripts/Test-LocalStack.ps1 -Model 'qwen3-coder:30b'
```

Look at the `Tools/v1` column. If it is not `pass`, no amount of harness configuration will
fix it — pick a different model. `gpt-oss:20b` is the most reliable tool-caller in this set
and makes a good control when you are debugging.

---

## GitHub Copilot app

> Bringing your own model provider to the Copilot app is in **public preview** and subject
> to change.

The app has native support for local providers — **Ollama and LM Studio are both listed by
name** — so there is no environment-variable wiring to do. This is the lowest-friction way
to use a local model with a full agent UI.

### Setup

1. Open the GitHub Copilot app.
2. Open app settings, then **Model providers**.
3. **Add provider**.
4. Select **Ollama** (or **LM Studio**).
5. Enter the display name and base URL — `http://localhost:11434/v1`.
6. Click **Add provider**.

You can also do this during onboarding the first time you open the app.

The full provider list is OpenAI, Azure OpenAI, Microsoft Foundry, Anthropic, **Ollama**,
Foundry Local, **LM Studio**, and any OpenAI-compatible HTTP endpoint.

### What to expect

- Your local models appear in the **model picker alongside GitHub-hosted ones**, so you can
  switch per session — local for the mechanical work, hosted for the hard parts.
- **Credentials are stored in the system credential store** and never shown in the UI.
  (Irrelevant for local Ollama, which needs no key, but worth knowing for other providers.)
- **You must sign in with a GitHub account**, but you **do not need a Copilot plan** when
  using your own provider. If you do have one, hosted and local models coexist.

### Same model requirements as the CLI

Tool calling, streaming, and a large context window. Verify before you rely on it:

```powershell
./scripts/Test-LocalStack.ps1 -Model 'qwen3-coder:30b'
```

See [Context window](#context-window--the-setting-that-will-actually-bite-you) below —
Ollama's default `num_ctx` is far too small for agent work regardless of which Copilot
surface you use.

### Offline — unverified

Because sign-in with a GitHub account is required, **the app's offline behaviour is not
documented**, and this repo has not tested it. Do not assume a signed-in app works on a
plane just because the model is local.

For guaranteed offline use, the documented path is **Copilot CLI with
`COPILOT_OFFLINE=true`** — see [offline.md](offline.md). Use the app for everyday local
work and keep the CLI as the offline answer until the app's behaviour is confirmed.

---

## GitHub Copilot CLI

Copilot CLI supports **BYOK** (Bring Your Own Key), which includes pointing it at a local
Ollama instance. This is the most direct path from this repo to a working offline agent.

### Minimum configuration

```powershell
$env:COPILOT_PROVIDER_BASE_URL = 'http://localhost:11434/v1'
$env:COPILOT_MODEL             = 'qwen3-coder:30b'
copilot
```

Two things to get right:

- **Include the `/v1` suffix.** Same endpoint as every other harness on this page.
- **No API key needed.** `COPILOT_PROVIDER_API_KEY` is only for providers that
  authenticate. A local Ollama instance does not, so leave it unset.

> **Source of truth: `copilot help providers`.**
> The published documentation disagrees on the base URL — GitHub's BYOK page shows the bare
> host, while the installed CLI's own help and [Ollama's integration
> page](https://docs.ollama.com/integrations/copilot-cli) both show `/v1`. The binary on
> your machine wins. If anything here looks wrong, run `copilot help providers` and believe
> that instead.

`COPILOT_MODEL` can also be supplied per-invocation with the `--model` flag:

```powershell
copilot --model gemma4:e4b
```

Or use the script, which sets the variables for the child process only so your shell
environment is left untouched:

```powershell
./scripts/Start-LocalCopilot.ps1                           # uses the default model
./scripts/Start-LocalCopilot.ps1 -Model gpt-oss:20b
./scripts/Start-LocalCopilot.ps1 -Offline                  # also sets COPILOT_OFFLINE=true
./scripts/Start-LocalCopilot.ps1 -WireApi responses        # if tool calls misbehave
```

Anything the script doesn't recognise is forwarded to `copilot`. Pass it explicitly via
`-ArgumentList` — a bare `--` separator is consumed by PowerShell itself and never reaches
the child process:

```powershell
./scripts/Start-LocalCopilot.ps1 -Model qwen3-coder:30b -ArgumentList '--banner'
```

### Environment variables

| Variable | Required | Notes |
|---|---|---|
| `COPILOT_PROVIDER_BASE_URL` | **Yes** | `http://localhost:11434/v1` for local Ollama. Setting it is what activates BYOK mode — GitHub authentication is then not required. |
| `COPILOT_MODEL` | **Yes** | The Ollama tag, e.g. `qwen3-coder:30b`. Or pass `--model`. Sets **both** the model ID and the wire model. |
| `COPILOT_PROVIDER_TYPE` | No | `openai` (default), `azure`, or `anthropic`. The default `openai` type covers Ollama, vLLM, and Foundry Local — any OpenAI-compatible endpoint. Leave it alone for Ollama. |
| `COPILOT_PROVIDER_API_KEY` | No | Not needed for local Ollama. |
| `COPILOT_PROVIDER_API_KEY_COMMAND` | No | A command that prints a fresh API key before every request. For short-lived credentials; irrelevant locally. |
| `COPILOT_PROVIDER_BEARER_TOKEN` | No | Takes precedence over the API key. |
| `COPILOT_PROVIDER_WIRE_API` | No | `completions` (default) or `responses`. See below. |
| `COPILOT_PROVIDER_TRANSPORT` | No | `http` (default) or `websockets`. Websockets is only relevant to the `responses` API. |
| `COPILOT_PROVIDER_HEADERS` | No | Extra HTTP headers sent only to the provider, as newline-separated `Name: Value` pairs. |
| `COPILOT_PROVIDER_MODEL_ID` | No | Well-known model name used to look up capabilities and token limits. Defaults to `COPILOT_MODEL`. |
| `COPILOT_PROVIDER_WIRE_MODEL` | No | Model name actually sent to the provider. Defaults to `COPILOT_MODEL`. |
| `COPILOT_PROVIDER_MAX_PROMPT_TOKENS` | No | Caps prompt tokens. **Worth setting locally** — see below. |
| `COPILOT_PROVIDER_MAX_OUTPUT_TOKENS` | No | Caps generated tokens per response. |
| `COPILOT_OFFLINE` | No | `true` stops the CLI contacting GitHub's servers. See [offline.md](offline.md). |

Run `copilot help providers` for the authoritative list and worked examples.

### Wire API: `completions` vs `responses`

The CLI defaults to `completions`, and its help notes that `responses` is intended for
GPT-5-series models. Ollama's own integration page, however, sets `responses` for Ollama.

Keep the default. If tool calls misbehave — ignored, malformed, or the loop stalls — try the
other one before blaming the model:

```powershell
$env:COPILOT_PROVIDER_WIRE_API = 'responses'
```

### Token limits — set them explicitly for local models

Copilot CLI resolves token limits in order: **manual env vars → built-in model catalog →
defaults.** It uses `COPILOT_PROVIDER_MODEL_ID` to find a model in that catalog and pick up
model-specific tool support, token limits, and prompting strategy.

A local tag like `qwen3-coder:30b` is not in the catalog, so the agent **falls back to
conservative defaults** — which may be well below what your model can actually handle. Set
the limit yourself to match your configured context length:

```powershell
$env:OLLAMA_CONTEXT_LENGTH            = '65536'
$env:COPILOT_PROVIDER_MAX_PROMPT_TOKENS = '60000'   # leave room for the response
```

`./scripts/Start-LocalCopilot.ps1 -MaxPromptTokens 60000` does the same thing for a single
session, without touching your shell environment.

### Model requirements — read this before picking a model

Copilot CLI requires a model that supports **tool calling and streaming**. If the model
lacks either, the CLI returns an error rather than degrading gracefully.

This is exactly what [`Test-LocalStack.ps1`](../scripts/Test-LocalStack.ps1) checks. Run it
against your intended model first and confirm the `Tools/v1` column says `pass`:

```powershell
./scripts/Test-LocalStack.ps1 -Model 'qwen3-coder:30b'
```

A `FAIL` there means Copilot CLI will not work with that model, full stop. Pick another.

### Context window — the setting that will actually bite you

The two sources differ, and both are worth knowing:

- **Ollama's integration page recommends at least 64k tokens.**
- **GitHub's BYOK page recommends at least 128k tokens.**

On a 48 GB machine, **64k is the practical floor and the right starting point**; 128k is
better if your RAM budget absorbs it. The difference is not free — KV cache scales with
context, so a 128k window costs gigabytes on top of the weights. Run the numbers in
[models.md](models.md) before assuming a 19 GB model plus a full 128k context still fits.

The catch: **Ollama's default `num_ctx` is far smaller than the model's maximum** — a few
thousand tokens. The model *can* do 128k; Ollama just is not offering it. The symptom is an
agent that mysteriously forgets the start of the session.

Raise it server-wide:

```powershell
./scripts/Restart-Ollama.ps1 -ContextLength 65536     # or 131072 if RAM allows
```

That applies it to the launchd service and restarts. Setting `$env:OLLAMA_CONTEXT_LENGTH`
in your shell does **not** work — see [setup.md](setup.md#3-environment-knobs).

Or bake it into a specific model with a Modelfile:

```powershell
@'
FROM qwen3-coder:30b
PARAMETER num_ctx 65536
'@ | Set-Content ./Modelfile

ollama create qwen3-coder-64k -f ./Modelfile
$env:COPILOT_MODEL = 'qwen3-coder-64k'
```

Keeping `OLLAMA_KV_CACHE_TYPE=q8_0` (set by [setup.md](setup.md)) roughly halves the KV
cache cost, which is what makes a large window affordable at all.

### Offline

```powershell
$env:COPILOT_PROVIDER_BASE_URL = 'http://localhost:11434/v1'
$env:COPILOT_MODEL             = 'qwen3-coder:30b'
$env:COPILOT_OFFLINE           = 'true'
copilot
```

`COPILOT_OFFLINE=true` prevents the CLI from contacting GitHub's servers. Note that it only
delivers true network isolation if the provider is *also* local — if
`COPILOT_PROVIDER_BASE_URL` points at a remote endpoint, your prompts and code context
still leave the machine. See [offline.md](offline.md).

### Shortcut

Ollama ships a convenience launcher that sets the wiring up for you:

```powershell
ollama launch copilot --model qwen3-coder:30b
```

Handy for a quick try. Prefer the explicit environment variables above when you want
control over context length, offline mode, or the optional provider settings.

---

## Aider

Aider has first-class Ollama support and is the lowest-friction place to start.

```powershell
$env:OLLAMA_API_BASE = 'http://localhost:11434'
aider --model ollama_chat/qwen3-coder:30b
```

Or persist it in `.aider.conf.yml` at the repo root:

```yaml
model: ollama_chat/qwen3-coder:30b
```

Notes:

- Use the `ollama_chat/` prefix, not `ollama/`. The latter routes through a completion API
  that handles chat templates worse.
- Set a context window explicitly if you hit truncation — Aider's default assumption may be
  smaller than the model supports. An `.aider.model.settings.yml` entry handles this.
- Aider leans on diff-format edits. Smaller models sometimes fail to produce valid diffs;
  if you see repeated "failed to apply edit", switch to a larger model or
  `--edit-format whole`.

---

## OpenCode

OpenCode reads a provider config and supports OpenAI-compatible endpoints directly.
In `opencode.json`:

```json
{
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (local)",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {
        "qwen3-coder:30b": { "name": "Qwen3 Coder 30B (local)" },
        "gpt-oss:20b": { "name": "GPT-OSS 20B (local)" }
      }
    }
  }
}
```

Then select the provider/model inside the TUI. Because OpenCode drives a real tool loop,
this is a good end-to-end test of whether a model is genuinely agent-capable rather than
just conversational.

---

## Continue (VS Code / JetBrains)

In `~/.continue/config.yaml`:

```yaml
models:
  - name: Qwen3 Coder 30B (local)
    provider: ollama
    model: qwen3-coder:30b
    roles: [chat, edit, apply]
  - name: Gemma4 E4B (local)
    provider: ollama
    model: gemma4:e4b
    roles: [autocomplete]
```

Pairing a large model for chat/edit with a small one for autocomplete is the right default:
autocomplete fires constantly and latency matters more than depth there.

---

## Raw SDK clients

Any OpenAI SDK works. Point it at the shim and pass a dummy key.

**Python**

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")

response = client.chat.completions.create(
    model="qwen3-coder:30b",
    messages=[{"role": "user", "content": "Explain this stack trace."}],
    tools=[...],          # tool-calling works; verify with Test-LocalStack.ps1 first
)
```

**Node**

```javascript
import OpenAI from "openai";

const client = new OpenAI({
  baseURL: "http://localhost:11434/v1",
  apiKey: "ollama",
});
```

**PowerShell**, for quick experiments without leaving the shell:

```powershell
$body = @{
    model    = 'qwen3-coder:30b'
    messages = @(@{ role = 'user'; content = 'Write a PowerShell function to tail a file.' })
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Uri 'http://localhost:11434/v1/chat/completions' `
    -Method Post -Body $body -ContentType 'application/json' `
    -Headers @{ Authorization = 'Bearer ollama' } |
    ForEach-Object { $_.choices[0].message.content }
```

Or just use the script:

```powershell
./scripts/Invoke-LocalChat.ps1 'Write a PowerShell function to tail a file.'
```

---

## Things that bite you

**Tool-calling silently absent.**
The model answers in prose and the response carries no `tool_calls`. The harness has nothing
to execute, so the loop stalls or spins. This is the single most common local-agent failure.
`Test-LocalStack.ps1` exists to catch it before a harness does.

**Context window truncation.**
Harnesses assume a window; **Ollama's default `num_ctx` is much smaller than the model's
maximum**. Symptoms are the agent "forgetting" the start of the conversation, or a CLI
rejecting the model's advertised limits. Raise it server-wide with
`./scripts/Restart-Ollama.ps1 -ContextLength 131072`, or per model with a Modelfile
`PARAMETER num_ctx`. Remember the KV cache cost — see
[models.md](models.md).

**Cold start timeouts.**
The first request after idle loads the full weights. Some harnesses have aggressive
client-side timeouts and abort. The scripts default `OLLAMA_KEEP_ALIVE` to `-1`, so once a
model is loaded it stays loaded — warm it before starting a session and this stops being a
problem. It bites you when the server was started without the scripts, where Ollama's own
5-minute default applies.

**Two harnesses, two models, one machine.**
Each loaded model holds its own weights resident. Running a 19 GB model in one tool and a
16 GB model in another on a 48 GB machine puts you over budget and into swap. Check with
`./scripts/Get-OllamaStatus.ps1`, and free one with
`./scripts/Dismount-LocalModel.ps1 <tag>`.

**Streaming + tools.**
Some client/model combinations handle streamed tool calls poorly. If tool calls work
non-streaming but break when streaming, disabling streaming in the harness is a valid
workaround — **except with Copilot CLI, which requires streaming**. There, a model that
cannot stream tool calls is simply unusable; switch models instead.

**Model names must match exactly.**
`qwen3-coder:30b` is a different string from `qwen3-coder:30B`. `./scripts/Get-LocalModel.ps1` prints the
exact tags — copy from there.
