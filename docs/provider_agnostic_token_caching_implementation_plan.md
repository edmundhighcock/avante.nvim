# Provider-Agnostic Prompt Caching Implementation Plan

This document outlines a step-by-step plan for implementing provider-agnostic prompt/result caching in the Avante codebase, in accordance with the strategy described in `docs/provider_agnostic_token_caching.md`. Each step is incremental, minimally disruptive, and can be tested independently.

---

## 1. Canonicalization Layer

**Functionality:**
Implement a deterministic canonicalization function that takes a prompt and all relevant parameters and produces a canonical (sorted, trimmed, normalized) serialization suitable for cache keys.

**Files to Modify/Create:**
- `lua/avante/utils/canonicalize.lua` (new): Implement canonicalization logic.
- `lua/avante/utils/init.lua`: Export the canonicalization function.
- Update provider implementation files to use canonicalizer for cache keys if necessary.

**Details:**
- Create a function: `canonicalize(prompt, params) -> string`.
- Write unit tests for canonicalization edge cases.

---

## 2. Cache Interface and In-Memory Backend

**Functionality:**
Define a provider-agnostic cache API (lookup/save/invalidate) and implement an in-memory LRU cache backend as default.

**Files to Modify/Create:**
- `lua/avante/utils/cache.lua` (new): Cache interface with methods: `lookup`, `save`, `invalidate`, `configure_backend`.
- Reuse or extend `lua/avante/utils/lru_cache.lua` for the in-memory backend.

**Details:**
- New module with the cache API and LRU-backed implementation.
- Export cache API via `utils/init.lua`.

---

## 3. Provider Integration

**Functionality:**
Insert cache lookup/save logic so all provider calls (OpenAI, Bedrock, Anthropic, etc.) first check cache before making API calls and save results after.

**Files to Modify/Create:**
- Provider files (e.g., `providers/bedrock.lua`, `providers/openai.lua`).
- `lua/avante/llm.lua` or orchestrator files handling LLM calls.

**Details:**
- Canonicalize prompt+params, check cache, return result if hit, else call provider and save to cache.
- Minimal branching to avoid breaking provider logic.

---

## 4. Configurability and Backend Extensibility

**Functionality:**
Allow users/config to choose cache backend, set limits (TTL, size), and swap backends at runtime.

**Files to Modify/Create:**
- `lua/avante/config.lua`: Add cache config section (backend type, size, TTL, etc.).
- `lua/avante/utils/cache.lua`: Support dynamic backend selection/config, TTL/eviction logic.

**Details:**
- Expose options in config.
- Add logic to reload cache backend on config change.

---

## 5. Manual and Automatic Invalidation

**Functionality:**
Add API/CLI calls for manual cache purge (per-user, per-model, full), and automatic invalidation on model/provider version change.

**Files to Modify/Create:**
- `lua/avante/utils/cache.lua`: Add invalidate methods.
- CLI or Neovim user commands for invalidation.
- Provider integration files: trigger invalidation on relevant events.

**Details:**
- Functions to clear cache based on key prefix, user, or model.
- Hooks to auto-invalidate on version change.

---

## 6. Observability and Logging

**Functionality:**
Log cache hits, misses, errors, and latency. Optionally surface this in UI or logs.

**Files to Modify/Create:**
- `lua/avante/utils/cache.lua`: Add logging.
- Provider/llm integration files: log when result is from cache/not.

**Details:**
- Log at each cache check/insert/error.
- Optionally provide cache statistics summary function.

---

## 7. Privacy, Security, and Partitioning

**Functionality:**
Support optional per-user cache partitioning, and stubs for persistent backends with encryption.

**Files to Modify/Create:**
- `lua/avante/utils/cache.lua`: Add optional user/namespace partitioning.
- Documentation and stubs for encryption if persistent backends are added.

**Details:**
- Partition cache keys by user ID/namespace where needed.

---

## 8. Test Coverage

**Functionality:**
Add unit tests for canonicalization, cache API, and integration flow.

**Files to Modify/Create:**
- `tests/test_cache.lua`, `tests/test_canonicalization.lua` (new).

**Details:**
- Unit and integration tests for new logic.

---

## 9. Documentation

**Functionality:**
Document configuration, usage, and backend extension in the codebase.

**Files to Modify/Create:**
- `docs/provider_agnostic_token_caching.md`: Update with concrete usage instructions.
- `README.md`, inline comments.

**Details:**
- Clear documentation for setup and usage.

---

## Summary Table

| Step | Functionality                    | Files Affected                                 |
|------|----------------------------------|------------------------------------------------|
| 1    | Canonicalization function        | utils/canonicalize.lua, providers, utils/init   |
| 2    | Cache API & LRU backend          | utils/cache.lua, lru_cache.lua, utils/init     |
| 3    | Provider integration             | providers/*, llm.lua                           |
| 4    | Config/backend choice            | config.lua, utils/cache.lua                    |
| 5    | Invalidation                     | utils/cache.lua, CLI/user commands             |
| 6    | Logging/observability            | utils/cache.lua, providers/llm.lua             |
| 7    | Privacy/partitioning             | utils/cache.lua                                |
| 8    | Tests                            | tests/                                         |
| 9    | Documentation                    | docs/, README.md                               |

---

This plan enables robust, provider-agnostic caching with minimal disruption and clear, incremental progress.

