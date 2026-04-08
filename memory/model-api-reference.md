# Model API Reference (Tested & Verified 2026-03-10)

## 1. Anthropic Sonnet 4.6 — WORKING
- **Endpoint**: `https://api.anthropic.com/v1/messages`
- **Model ID**: `claude-sonnet-4-6`
- **Auth**: Header `x-api-key: $ANTHROPIC_API_KEY`
- **Extra Header**: `anthropic-version: 2023-06-01`
- **Format**: Anthropic Messages API (NOT OpenAI-compatible)
- **Body**: `{"model":"claude-sonnet-4-6","messages":[{"role":"user","content":"..."}],"max_tokens":4096}`
- **System**: Uses `system` array of blocks with `cache_control`
- **Pricing**: $3.00/$15.00 per M (input/output)

## 2. OpenAI Codex Mini — WORKING (Responses API only)
- **Endpoint**: `https://api.openai.com/v1/responses` (NOT /chat/completions!)
- **Model ID**: `gpt-5.1-codex-mini`
- **Auth**: Header `Authorization: Bearer $OPENAI_API_KEY`
- **Format**: OpenAI Responses API
- **Body**: `{"model":"gpt-5.1-codex-mini","input":[{"role":"user","content":"..."}],"max_output_tokens":16384}`
- **System**: Uses `instructions` field (NOT messages array system role)
- **IMPORTANT**: `max_output_tokens` MINIMUM is 16 (below 16 returns 400!)
- **Output**: `response.output[]` → find `type:"message"` → `content[]` → `type:"output_text"` → `.text`
- **Pricing**: $0.25/$2.00 per M (input/output)
- **Limits**: 4M TPM, 5K RPM

## 3. DeepSeek Chat — WORKING
- **Endpoint**: `https://api.deepseek.com/v1/chat/completions`
- **Model ID**: `deepseek-chat`
- **Auth**: Header `Authorization: Bearer $DEEPSEEK_API_KEY`
- **Format**: OpenAI-compatible Chat Completions
- **Body**: `{"model":"deepseek-chat","messages":[{"role":"system","content":"..."},{"role":"user","content":"..."}],"max_tokens":8192}`
- **Output**: `response.choices[0].message.content`
- **Pricing**: $0.14/$0.28 per M (input/output)
- **IMPORTANT**: `max_tokens` maximum is 8192! (16384 returns 400)

## 4. Kimi (Moonshot) — WORKING
- **Endpoint**: `https://api.moonshot.ai/v1/chat/completions`
- **Model ID**: `moonshot-v1-8k`
- **Auth**: Header `Authorization: Bearer $KIMI_API_KEY`
- **Format**: OpenAI-compatible Chat Completions
- **Body**: `{"model":"moonshot-v1-8k","messages":[{"role":"user","content":"..."}],"max_tokens":16384}`
- **Output**: `response.choices[0].message.content`
- **IMPORTANT**: Use `api.moonshot.ai` NOT `api.moonshot.cn` (times out from US/corporate network)
- **Key source**: https://platform.moonshot.ai/console/api-keys

## 5. MiniMax — WORKING
- **Endpoint**: `https://api.minimax.io/v1/chat/completions`
- **Model ID**: `MiniMax-Text-01`
- **Auth**: Header `Authorization: Bearer $MINIMAX_API_KEY`
- **Format**: OpenAI-compatible Chat Completions
- **Body**: `{"model":"MiniMax-Text-01","messages":[{"role":"user","content":"..."}],"max_tokens":16384}`
- **Output**: `response.choices[0].message.content`
- **IMPORTANT**: Use `api.minimax.io` NOT `api.minimax.chat` (times out)
- **IMPORTANT**: Model is `MiniMax-Text-01` NOT `abab6.5s-chat` (returns 400)
- **Key source**: https://platform.minimax.io/user-center/basic-information/interface-key

## 6. GLM5 (Zhipu) — NOT WORKING (timeout)
- **Endpoint**: `https://open.bigmodel.cn/api/paas/v4/chat/completions`
- **Model ID**: `glm-4-flash`
- **Auth**: Header `Authorization: Bearer $GLM_API_KEY`
- **Status**: Times out from corporate network (China endpoint needs VPN)

## Fallback Chain (in api-client.ps1)
```
Codex Mini (Responses API) → DeepSeek → Kimi → MiniMax
```
Each falls through on failure. First success returns.

## Common Pitfalls
1. Codex Mini uses **Responses API** (`/v1/responses`), NOT Chat Completions
2. Codex Mini requires `max_output_tokens >= 16`
3. Codex Mini system prompt goes in `instructions` field, not messages
4. `Invoke-RestMethod` drops error body on exceptions — use `GetResponseStream()` to read it
5. China endpoints (moonshot.cn, minimax.chat, bigmodel.cn) need VPN from US networks
6. Use `api.moonshot.ai` and `api.minimax.io` (international endpoints)
