# Chat apps for non-coding use

The rest of this repo is aimed at agent harnesses. But once the stack is up, the same models
answer ordinary questions, and a plain chat window is often what you actually want — drafting,
summarising, rubber-ducking, explaining something you half-remember.

Three options, in the order most people should try them.

---

## 1. GitHub Copilot app

If you already added Ollama as a model provider ([harnesses.md](harnesses.md#github-copilot-app)),
your local models are in the model picker. Start a chat session and select one. Nothing
further to set up.

Good when you want one interface for both coding agents and general chat, and you want to
switch between a local model and a hosted one mid-task.

---

## 2. LM Studio

```powershell
brew install --cask lm-studio
```

A desktop GUI: chat interface, model browser with search and one-click downloads, parameter
controls, and an **MLX backend** for Apple Silicon. It also runs its own OpenAI-compatible
server, so it can serve as a **Copilot app provider** — LM Studio is in the app's native
provider list alongside Ollama.

**On speed:** both can run MLX, but matching backend names do not guarantee matching
weights, quantization, batching, or throughput. **LM Studio offers a model-browsing UI**;
benchmark equivalent configurations rather than choosing on an assumed speed advantage.
The following compares variants installed in Ollama, not LM Studio's API:

```powershell
./scripts/Test-LocalStack.ps1 -Model 'qwen3.8:27b*' -UnloadAfterEach
```

---

## 3. Ollama desktop app

```powershell
brew install --cask ollama-app
```

A simpler chat UI over the same models. Less to configure than LM Studio, less to look at.

> **It conflicts with the `ollama` formula.** The desktop app **bundles its own server** and
> also wants port **11434**. Running it alongside the brew-managed service means two servers
> fighting over one port, and you will get confusing failures. **Run one or the other.**

To switch to the app, stop the formula's service first:

```powershell
./scripts/Stop-Ollama.ps1     # brew services stop - also removes the login item
```

To switch back, quit the desktop app, then:

```powershell
./scripts/Start-Ollama.ps1
```

Everything in this repo targets `http://localhost:11434` and works against whichever server
is listening — `Test-LocalStack.ps1`, `Get-OllamaStatus.ps1` and friends do not care which
one it is. But the service-control scripts (`Start-Ollama.ps1`, `Stop-Ollama.ps1`,
`Restart-Ollama.ps1`) manage the **brew formula**, so they will not do anything useful while
the desktop app is the one running.

---

## Which to use

| You want | Use |
|---|---|
| One app for coding agents and chat | Copilot app |
| To browse, download, and compare models | LM Studio |
| A minimal chat window, nothing else | Ollama desktop app |
| A chat window inside your terminal | `./scripts/Invoke-LocalChat.ps1 'question'` |

The last one is easy to forget and is genuinely the fastest path for a one-liner:

```powershell
./scripts/Invoke-LocalChat.ps1 'What is the difference between a git worktree and a clone?'
./scripts/Invoke-LocalChat.ps1 'Summarise this.' -Model gemma4:e4b
```

---

## Model choice for chat

Chat is less demanding than agent work — no tool calling, shorter context — so you can go
smaller than your coding model:

- **`gemma4:e4b` (7.5 GB)** is genuinely usable for general Q&A and loads in seconds. For
  casual chat it is often the right choice over a 19 GB model you then have to unload.
- **`qwen3.8:27b` (18 GB)** when you want the best reasoning the machine can hold.
- **`gemma4:26b` (16 GB)** is multimodal, so it accepts images.

See [models.md](models.md) for the full set and the RAM math. Remember that a chat model
left loaded occupies memory exactly like an agent model does —
`./scripts/Dismount-LocalModel.ps1` frees it. With the default `OLLAMA_KEEP_ALIVE=-1` it
will not expire on its own, and `OLLAMA_MAX_LOADED_MODELS=1` means switching between a chat
model and a coding model swaps rather than stacks them. See
[setup.md](setup.md#when-its-not-in-use).
