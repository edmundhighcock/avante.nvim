# Provider-Agnostic Token Caching Framework for LLM Cost Reduction

## Introduction

As large language model (LLM) usage increases, the costs of repeated or highly similar prompts can escalate rapidly. To address this, all major LLM API providers (AWS Bedrock, OpenAI, Anthropic, etc.) recommend leveraging *prompt/result caching* to reduce redundant calls and overall expenditure. This document proposes a general, provider-agnostic framework for token caching suitable for integration into the Avante codebase and adaptable to any LLM backend.

---

## Rationale and Best Practices

### General Principles
- **Prompt Caching** enables storing the result of an API call for a given prompt and set of parameters, so that identical future requests can return the cached result instead of re-invoking the provider.
- **Cost Reduction:** Caching reduces both token usage and latency for repeated or template-driven workloads.
- **Provider Support:** AWS Bedrock, OpenAI, and Anthropic all support prompt caching at the application level; none provide automatic caching.
- **Canonicalization:** To avoid false cache hits, prompts and relevant parameters must be canonicalized (e.g., whitespace, parameter order, model, temperature, etc.).

### Provider-Specific Notes
- **AWS Bedrock:** Recommends prompt/result caching for repetitive tasks. See [AWS Bedrock Best Practices](https://docs.aws.amazon.com/bedrock/latest/userguide/best-practices.html).
- **OpenAI:** Caching results for identical prompt+params can reduce costs by up to 50% for large prompts. See [OpenAI API Pricing and Best Practices](https://platform.openai.com/docs/guides/rate-limits/best-practices).
- **Anthropic:** Suggests prompt/result caching for few-shot and many-shot scenarios. Caching does not reduce output token costs, but helps with prompt reuse. See [Anthropic Claude API docs](https://docs.anthropic.com/claude/reference).

---

## Framework Design Overview

### Goals
- **Provider Agnostic:** Usable with Bedrock, OpenAI, Anthropic, or any compatible LLM API.
- **Extensible:** Pluggable storage backends (file, memory, database, etc.).
- **Configurable:** Cache key can be tuned to include/exclude parameters as needed.
- **Transparent:** Cache logic sits between the user-facing API and provider invocation.
- **Safe:** Avoids stale cache hits and handles invalidation.

### Architecture

```
User Prompt + Params
       ↓
[Canonicalization Layer]
       ↓
[Cache Lookup]
       ↓         ↘
Cache Hit      Cache Miss
   ↓               ↓
[Return Result]  [Provider API Call]
                      ↓
                 [Cache Save]
                      ↓
                [Return Result]
```

#### Canonicalization Layer
- Generates a normalized string or hash from the prompt, model name, temperature, system prompt, tools, and any other relevant params.
- Ensures that logically equivalent requests produce identical cache keys.

#### Cache Storage
- Maps canonicalized request keys to provider responses (including partials if streaming).
- Pluggable (simple file, SQLite, Redis, memory, etc.).
- Stores metadata (timestamp, provider, version, etc.) for invalidation.

#### API Integration Points
- **Pre-call:** Check cache before making provider call. If cache hit, return result.
- **Post-call:** Store result in cache after successful provider call.
- **Invalidation:** Expose hooks for cache expiry, manual purge, or version migration.

---

## Proposed API (Lua Pseudocode)

```lua
---@class LLMCache
local Cache = {}

function Cache:lookup(key) ... end  -- returns cached result or nil
function Cache:save(key, result) ... end
function Cache:invalidate(key) ... end
function Cache:canonicalize(prompt, params) ... end -- returns canonical key
```

### Usage Example

```lua
local canonical_key = Cache:canonicalize(prompt, {
  model = "claude-3-opus",
  temperature = 0.2,
  tools = {"search"},
  system_prompt = "You are helpful"
})

local cached_result = Cache:lookup(canonical_key)
if cached_result then
  return cached_result
end

local result = Provider:call_api(prompt, params)
Cache:save(canonical_key, result)
return result
```

---

## Integration with Avante Codebase

- **Provider Abstraction:** Integrate cache checks and saves within the provider/model handler layer (e.g., in `bedrock.lua`, `openai.lua`, etc.).
- **Canonicalization:** Leverage existing message parsing to generate keys. Include all parameters that affect output.
- **Config:** Allow the user to configure the cache backend and key generation strategy.
- **Prompt Logger:** The cache is complementary to prompt logging, which is for UX/history, not cost reduction.

---

## Best Practices & Recommendations

- Always canonicalize all input and relevant parameters for accurate cache hits.
- Periodically expire or prune old cache entries to manage disk/memory usage.
- For streaming completions, consider caching only complete results or chunked by offset.
- Provide clear user controls for manual cache purge/refresh.
- Log cache hits/misses for observability and debugging.

---

## References
- [AWS Bedrock Best Practices](https://docs.aws.amazon.com/bedrock/latest/userguide/best-practices.html)
- [OpenAI API Rate Limits & Caching](https://platform.openai.com/docs/guides/rate-limits/best-practices)
- [Anthropic Claude API Reference](https://docs.anthropic.com/claude/reference)

