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
- **Purpose:** Ensure that logically equivalent requests (identical meaning/output) always yield the same cache key, and that trivial formatting differences do not produce cache misses.
- **Normalization:**
  - Canonicalize all string fields: trim leading/trailing whitespace, collapse redundant whitespace, and apply Unicode normalization (e.g., NFC).
  - For prompts and system prompts, remove inconsistent line endings and convert to a standard (e.g., `\n`).
  - Sort all parameter objects (e.g., tool lists, config dictionaries) by key for determinism.
- **Parameter Inclusion:**
  - The cache key **must** include all parameters that affect output, at a minimum: prompt, model name, temperature, system prompt, tool list, user identifier (if present), and any provider-specific parameters (e.g., top_p, max_tokens, stop sequences).
  - For complex params (e.g., tool objects or config tables), serialize using sorted JSON or a deterministic encoding.
- **Serialization:**
  - Use a deterministic serialization format (e.g., JSON with sorted keys, canonical protobuf, stable hash) for the cache key. Avoid Lua tables with non-deterministic key order.
  - If provider-specific quirks are suspected (e.g., undocumented OpenAI params), include as much metadata as possible and store original params alongside the cache value for future auditing or migration.
  - Example: `{prompt, model, temperature, system_prompt, tools, user_id, provider_params}` → canonical JSON, then hash (e.g., SHA256).
- **Provider Notes:**
  - **OpenAI:** All params affecting output (including undocumented ones) may alter results. When in doubt, be conservative and include extra params.
  - **AWS Bedrock & Anthropic:** Follow their recommendations for parameter normalization (see references). For tool use, sort tool lists and tool parameter objects.
- **References:**
  - [OpenAI prompt caching best practices](https://platform.openai.com/docs/guides/rate-limits/best-practices)
  - [AWS Bedrock prompt caching](https://docs.aws.amazon.com/bedrock/latest/userguide/best-practices.html)

- Ensures that logically equivalent requests produce identical cache keys.

#### Cache Storage, Privacy & Security, and Invalidation
- Maps canonicalized request keys to provider responses. For streaming/chunked completions, only complete and successfully delivered responses are cached; partial results produced during streaming, or results from cancelled/incomplete streams, are not cached. This ensures cache consistency and avoids storing incomplete or inconsistent outputs. Most providers (e.g., OpenAI, Anthropic) do not support partial streaming response caching, so the framework standardizes on caching only full results.
- **Privacy & Security:**
  - Support per-user or per-namespace isolation so that users cannot access each other's cached data in multi-tenant environments.
  - Encrypt persistent cache data at rest and in transit, especially for production deployments or when storing sensitive information.
  - Enforce access controls on cache operations to ensure only authorized users or services can access or modify cache entries.
  - Support GDPR and right-to-erasure by allowing targeted removal (purge) of individual user's cached items on request.
- Supports pluggable storage backends (file, SQLite, Redis, memory, etc.).
- **Backend Requirements:**
  - All backends must support atomic read/write operations to avoid race conditions.
  - Backends should enable safe concurrent access from multiple threads or processes.
  - Durable backends (e.g., file, SQLite, Redis) should ensure persistence across restarts; memory backends are for ephemeral use.
  - Hot-reloading (dynamic backend reconfiguration) is recommended for production but optional for local/dev use.
  - The framework should allow runtime backend swapping via config, environment variable, or API call.
  - **Recommended defaults:** Use a file or memory backend for development, Redis or SQLite for production deployments.
- **Expiration & Eviction:**
  - Configurable policies: TTL (time-to-live), LRU (least recently used), and/or maximum size.
  - Recommended default TTL is one week (as per OpenAI); LRU eviction is recommended for bounded caches.
  - Cache entries should be versioned by provider/model. On provider/model version change, all affected cache entries must be invalidated automatically to prevent stale results. Automatic migration of cache entries is not supported by default for safety; manual review and purge/migration is recommended if model output compatibility is unclear.
- **Partial Invalidation:**
  - Support for manual purge (per-user, per-model, or full cache).
  - Allow cache entries to be partitioned by user or model, enabling targeted invalidation if needed (e.g., user data erasure, rolling model upgrades).
- **Manual Controls:**
  - Expose hooks and/or CLI commands for explicit cache purge or refresh.
- Stores metadata (timestamp, provider, version, etc.) for invalidation and observability.

#### API Integration Points
- **Pre-call:** Check cache before making provider call. If cache hit, return result.
- **Post-call:** Store result in cache after successful provider call.
- **Invalidation:** Expose hooks for cache expiry, manual purge, or version migration.

#### Error Handling & Observability
- **Error Handling:** Treat the cache as a non-critical optimization. If the cache backend fails or is slow to respond, log a warning or error and fall back to a direct provider call. Never allow a cache outage to block completions.
- **Observability:** Implement unified logging and metrics for cache operations:
  - Track cache hits, misses, errors, and latency.
  - Integrate with existing logging/metrics systems (if present) for visibility and debugging.
  - Provide dashboards or reports to monitor cache performance and health.

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

- **Provider Abstraction:**
  - The cache framework is fully generic and integrates at the provider/model handler layer (e.g., in `bedrock.lua`, `openai.lua`, etc.), requiring no provider-specific hooks.
  - All prompt/result cache logic sits between the user-facing API and the provider abstraction, so providers do not need to be modified individually.
- **Prompt Logger Integration:**
  - The cache is fully complementary to prompt logging, which exists for UX/history purposes, not cost reduction.
  - Prompt logs and cache entries are kept separate; cache hits and misses should be clearly logged and optionally surfaced in the user interface to distinguish between reused and new completions.
- **User Experience:**
  - Users may be shown indicators or logs of whether a completion was served from cache or generated fresh, for transparency.
- **Configuration:**
  - Allow configuration of cache backend, expiration, and cache key strategy via the same config abstraction used elsewhere in Avante.

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

