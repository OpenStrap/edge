# AI Coach — bring your own key

The AI features in OpenStrap Edge (the Coach chat, the morning and evening
briefings, and the pre-sleep journal) are all powered by a model **you**
provide. There's no OpenStrap AI service: you paste in an API key for any
OpenAI-compatible provider and the app talks to that provider directly.

Your key is stored in the device keychain/keystore and is only ever sent to
the base URL you configure — never to OpenStrap.

The same goes for your data: your chat messages, and the health metrics the
coach's tools pull from the on-device database to answer them, are sent to
the provider you configure. Before enabling the feature, check that
provider's data retention and training policies — or point the app at a
model you host yourself.

## Setup

Open **AI Coach → settings** and fill in three things:

1. **Base URL** — your provider's OpenAI-compatible endpoint (see the table
   below). The app calls `{base URL}/chat/completions`, so enter the base
   only, without the `/chat/completions` part.
2. **API key** — from your provider's dashboard.
3. **Model** — tap **Fetch** to pull your provider's live model list and pick
   one, or just type a model id and it's used as-is.

Tap **Save** and you're done.

## Providers

`gpt-4o` on OpenAI is a known-good default. Any OpenAI-compatible provider
works — here are common base URLs:

| Provider | Base URL |
|---|---|
| OpenAI | `https://api.openai.com/v1` |
| Anthropic (Claude) | `https://api.anthropic.com/v1` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| Groq | `https://api.groq.com/openai/v1` |
| Together AI | `https://api.together.xyz/v1` |
| Mistral | `https://api.mistral.ai/v1` |
| DeepSeek | `https://api.deepseek.com/v1` |
| xAI (Grok) | `https://api.x.ai/v1` |
| Google (Gemini) | `https://generativelanguage.googleapis.com/v1beta/openai` |
| Ollama (self-hosted) | `http://YOUR_SERVER_IP:11434/v1` |
| LM Studio (self-hosted) | `http://YOUR_SERVER_IP:1234/v1` |

Notes:

- **Pick a model that supports tool calling.** The Coach chat is agentic —
  it queries your health data through tools — so bare completion-only models
  will fail or give empty answers. Flagship models from the providers above
  (GPT-4o, Claude, Llama 3.3+, etc.) are fine.
- **Anthropic** works via their OpenAI-compatible endpoint: the app fetches
  the model list from Anthropic's native Models API and strips the sampling
  parameters newer Claude models reject. Anthropic describes the
  compatibility layer as having some limitations versus their native API,
  but none of the missing features (strict tool schemas, prompt caching)
  are used by this app.
- **Local models** (Ollama, LM Studio): your phone can't reach `localhost`
  on your computer — use the machine's LAN or Tailscale IP, make sure the
  server listens on that interface, and enter any non-empty string as the
  API key if your server doesn't check one.
  ⚠️ The `http://` URLs above are plaintext: anyone on the same network can
  read your key and health data in transit. Only use them on a network you
  trust or over an encrypted tunnel (Tailscale traffic is
  WireGuard-encrypted, so `http://` over a Tailscale IP is fine), and never
  expose the server to the internet without TLS and authentication.
- **OpenRouter** is handy for trying many models on one key.

## Troubleshooting

- **"Enter your API key first"** — Fetch needs the key filled in before it
  can list models.
- **"Provider returned no models"** — the provider answered with an empty
  list; type the model id manually.
- **"Models request failed (404)"** — the gateway doesn't implement
  `GET /models` (or the base URL is wrong). If the base URL checks out,
  skip Fetch and type the model id manually.
- **Provider error 401/403** — wrong key, or the key isn't enabled for the
  model you picked.
- **Provider error 404** — the base URL is usually wrong; check it against
  the table above (Groq notably needs `/openai/v1`, not `/v1`).
