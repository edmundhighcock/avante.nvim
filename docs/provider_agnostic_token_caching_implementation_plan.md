# Provider-Agnostic Prompt Caching Implementation Plan

This document outlines a step-by-step plan for implementing provider-agnostic prompt/result caching in the Avante codebase, in accordance with the strategy described in `docs/provider_agnostic_token_caching.md`. Each step is incremental, minimally disruptive, and can be tested independently.

---

## 1. Canonicalization Layer

**Functionality:**
Implement a deterministic canonicalization function that takes a structured prompt (including arrays of messages and optional job sections) plus all relevant parameters, and produces a canonical (sorted, trimmed, normalized) serialization suitable for cache keys.

**Logic Details (Pseudocode):**

```lua
-- Canonicalization function supporting structured prompts with arrays (e.g., messages, jobs)
function canonicalize(prompt_struct, params)
  -- prompt_struct should be a table with keys like 'messages', 'jobs', etc.
  -- Example: {messages = { ... }, jobs = { ... }}

  -- Normalize string fields
  local function normalize_str(s)
    return s:trim()              -- Remove leading/trailing whitespace
      :gsub("%s+", " ")        -- Collapse all whitespace to single space
      :gsub("\r\n", "\n")     -- Normalize newlines
      -- Optionally apply Unicode NFC normalization if a library is available
  end

  -- Deterministically normalize and serialize a message/job element
  local function normalize_obj(obj)
    local out = {}
    -- Sort keys for determinism within each object
    local keys = {}
    for k in pairs(obj) do table.insert(keys, k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = obj[k]
      if type(v) == "string" then
        out[k] = normalize_str(v)
      elseif type(v) == "table" then
        -- Recursively normalize nested objects/arrays
        if #v > 0 then
          out[k] = normalize_array(v)
        else
          out[k] = normalize_obj(v)
        end
      else
        out[k] = v
      end
    end
    return out
  end

  -- Normalize arrays (messages, jobs, etc.)
  local function normalize_array(arr)
    local out = {}
    for i, obj in ipairs(arr) do
      out[i] = normalize_obj(obj)
    end
    return out
  end

  -- Recursively normalize prompt_struct
  local normalized_prompt = {}
  for k, v in pairs(prompt_struct) do
    if type(v) == "table" and #v > 0 then -- array
      normalized_prompt[k] = normalize_array(v)
    elseif type(v) == "table" then         -- object
      normalized_prompt[k] = normalize_obj(v)
    elseif type(v) == "string" then
      normalized_prompt[k] = normalize_str(v)
    else
      normalized_prompt[k] = v
    end
  end

  -- Normalize all relevant parameters (as before)
  local normalized_params = {}
  for k, v in pairs(params) do
    if type(v) == "string" then
      normalized_params[k] = normalize_str(v)
    elseif type(v) == "table" then
      normalized_params[k] = normalize_obj(v)
    else
      normalized_params[k] = v
    end
  end

  -- Compose serialization object
  local serialization_obj = {
    prompt = normalized_prompt,
    params = normalized_params
  }

  -- Serialize to deterministic JSON (sorted keys)
  local json_str = deterministic_json_encode(serialization_obj)

  -- Optionally hash for compact key
  local cache_key = sha256(json_str)
  return cache_key
end

-- Incremental caching interface: supports cache lookup/insertion for each prompt prefix
function cache_prefixes(messages, params)
  -- messages is an array of message objects
  -- For each prefix [messages[1..i]], canonicalize and lookup/save in cache
  for i = 1, #messages do
    local prefix = {table.unpack(messages, 1, i)}
    local prompt_struct = {messages = prefix}
    local key = canonicalize(prompt_struct, params)
    -- Cache:lookup(key) or Cache:save(key, result)
  end
end
```
-- This enables the cache to efficiently support iterative conversations where only the suffix is new.
**Key points:**
- Structured prompts (e.g., arrays of messages and jobs) are recursively normalized and encoded deterministically.
- Each message/job element and all nested arrays/objects are normalized (field order, whitespace, line endings).
- Deterministic JSON serialization ensures arrays of objects (e.g., messages) are preserved in order, and each object is sorted by key for comparison.
- **Incremental caching:** To maximize cache utilization and cost savings, the canonicalization logic and cache interface must support caching and lookup for all prefixes of the messages array. For any prompt, canonicalize and cache the result of every possible prefix (`messages[1..n]`), so that when only new messages are added, the existing prefix cache can be reused and only the new suffix is an API miss. This matches provider best practices and enables efficient reuse in iterative conversations.
- All parameters that affect output (model, temperature, tool list, user_id, etc.) must be included.
- Result may be hashed (SHA256) for compactness.

**Logic Details (Pseudocode):**

```lua
-- Canonicalization function: ensures logically equivalent requests yield the same cache key
function canonicalize(prompt, params)
  -- 1. Normalize prompt and any string-like parameters
  local function normalize_str(s)
    return s:trim()              -- Remove leading/trailing whitespace
      :gsub("%s+", " ")        -- Collapse all whitespace to single space
      :gsub("\r\n", "\n")     -- Normalize newlines
      -- Optionally apply Unicode NFC normalization if a library is available
  end

  -- 2. Recursively sort all tables (by key), including nested tables and lists-of-tables
  local function sort_table(t)
    if type(t) ~= "table" then return t end
    local keys = {}
    for k in pairs(t) do table.insert(keys, k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
      out[k] = sort_table(t[k])
    end
    return out
  end

  -- 3. Normalize all relevant parameters
  local normalized_params = {}
  for k, v in pairs(params) do
    if type(v) == "string" then
      normalized_params[k] = normalize_str(v)
    elseif type(v) == "table" then
      normalized_params[k] = sort_table(v)   -- Sort recursively
    else
      normalized_params[k] = v               -- Numbers, booleans, etc.
    end
  end

  -- 4. Compose a serialization object
  local serialization_obj = {
    prompt = normalize_str(prompt),
    params = normalized_params
  }

  -- 5. Serialize to JSON with sorted keys (requires deterministic JSON lib)
  local json_str = deterministic_json_encode(serialization_obj)  -- Must serialize tables with sorted keys

  -- 6. Optionally hash the result (e.g., SHA256) for compact cache keys
  local cache_key = sha256(json_str)
  return cache_key
end
```
**Key points:**
- All parameters that affect output (prompt, model, temperature, system prompt, tool list, user_id, provider-specific params, etc.) must be included.
- Parameter objects/lists (e.g., tools) must be sorted deterministically.
- Strings must be trimmed, whitespace-collapsed, and newlines normalized.
- Serialization must be deterministic (JSON with sorted keys or equivalent).
- Resulting string can be hashed (SHA256) for cache key length, but original can be stored for audit/debug.

**Files to Modify/Create:**
- `lua/avante/utils/canonicalize.lua` (new): Implement canonicalization logic for structured prompts, recursively normalizing all objects and arrays.
- `lua/avante/utils/init.lua`: Export the canonicalization function.
- Update provider implementation files to use canonicalizer for cache keys if necessary.

**Testing:**
- Write unit tests for canonicalization edge cases: whitespace, param order, unicode, nested tables, tool list sorting, etc.

---

## 2. Cache Interface and In-Memory Backend

**Functionality:**
Define a provider-agnostic cache API (lookup/save/invalidate) and implement an in-memory LRU cache backend as default.

**Logic Details (Pseudocode):**

```lua
-- Cache interface
local Cache = {}

-- Initialize with LRU backend
function Cache:configure_backend(opts)
  -- opts = {max_size, ttl, backend_type}
  if opts.backend_type == 'memory' or not opts.backend_type then
    self.backend = LRUCache.new(opts.max_size, opts.ttl)
  else
    error('Only in-memory backend implemented in v1')
  end
end

-- LRUCache object
local LRUCache = {}
function LRUCache.new(max_size, ttl)
  -- Returns new LRUCache instance
end

function Cache:lookup(key)
  local entry = self.backend:get(key)
  if entry == nil then return nil end
  if entry.expiry and entry.expiry < now() then
    self.backend:delete(key) -- expired
    return nil
  end
  return entry.value
end

function Cache:save(key, value)
  self.backend:set(key, {value=value, expiry=now()+self.backend.ttl})
end

function Cache:invalidate(key)
  self.backend:delete(key)
end

-- LRUCache methods (simplified)
function LRUCache:get(key) ... end
function LRUCache:set(key, value) ... end
function LRUCache:delete(key) ... end
-- Internally tracks recency and removes least-recently-used when full

-- Utility
def now()
  -- Return current time as epoch seconds
end
```
**Key points:**
- Cache is initialized via `configure_backend`, supporting LRU/TTL config.
- Each cache entry stores `value` and (optionally) `expiry`.
- On lookup, expired entries are deleted and treated as miss.
- LRUCache tracks usage and evicts least-recently-used item on overflow.
- Structure is extendable for future backends (e.g., Redis, file, etc).

**Files to Modify/Create:**
- `lua/avante/utils/cache.lua` (new): Cache interface with methods: `lookup`, `save`, `invalidate`, `configure_backend`.
- Reuse or extend `lua/avante/utils/lru_cache.lua` for the in-memory backend.

**Testing:**
- Unit tests for LRU eviction, TTL expiry, lookup/save/invalidate logic.
- Simulate overflow and expiry scenarios.

---

## 3. Provider Integration

**Functionality:**
Insert cache lookup/save logic so all provider calls (OpenAI, Bedrock, Anthropic, etc.) first check cache before making API calls and save results after.

**Logic Details (Pseudocode):**

```lua
function call_with_cache(prompt, params)
  local cache_key = canonicalize(prompt, params)
  local cached = Cache:lookup(cache_key)
  if cached then
    log("cache hit", cache_key)
    return cached
  end
  local result = Provider:call_api(prompt, params)
  Cache:save(cache_key, result)
  log("cache miss", cache_key)
  return result
end
```

- Insert this logic in the orchestrator/provider call flow (e.g., in `llm.lua` or provider wrappers).
- Ensure all provider-affecting parameters are included in the canonicalization.
- Avoid double-caching or cache pollution by only saving on completed, successful calls.
- Minimize refactoring in provider-specific files by centralizing cache logic where possible.

**Files to Modify/Create:**
- Provider files (e.g., `providers/bedrock.lua`, `providers/openai.lua`).
- `lua/avante/llm.lua` or orchestrator files handling LLM calls.

**Testing:**
- Simulate both cache hit and miss scenarios for each supported provider.
- Ensure results are only generated by API on cache miss and stored afterward.

---

## 4. Configurability and Backend Extensibility

**Functionality:**
Allow users/config to choose cache backend, set limits (TTL, size), and swap backends at runtime.

**Logic Details (Pseudocode):**

```lua
-- Example config structure
local cache_config = {
  backend_type = 'memory', -- or 'redis', 'file', etc
  max_size = 1000,
  ttl = 7 * 24 * 3600, -- seconds
}

function Cache:configure_backend(opts)
  -- opts: table with backend_type, max_size, ttl
  -- Dynamically instantiate backend based on opts
  if opts.backend_type == 'memory' or not opts.backend_type then
    self.backend = LRUCache.new(opts.max_size, opts.ttl)
  elseif opts.backend_type == 'redis' then
    self.backend = RedisCache.new(opts)
  elseif opts.backend_type == 'file' then
    self.backend = FileCache.new(opts)
  else
    error('Unknown cache backend: ' .. tostring(opts.backend_type))
  end
end

-- Call this when config changes (e.g., user edits config.lua):
function reload_cache_config()
  local new_config = require('avante.config').cache
  Cache:configure_backend(new_config)
end
```
**Key points:**
- All relevant cache parameters (backend type, size, TTL) are set in config.lua.
- Cache can be reconfigured at runtime by calling `Cache:configure_backend()` with new options.
- Extendable for future backends (Redis, file, etc).
- On config change, reload and swap backend without restarting the app.

**Files to Modify/Create:**
- `lua/avante/config.lua`: Add/extend cache config section.
- `lua/avante/utils/cache.lua`: Support dynamic backend selection/config, TTL/eviction logic.

**Testing:**
- Test switching backends/config at runtime and verify old entries are cleared or migrated as appropriate.

---

## 5. Manual and Automatic Invalidation

**Functionality:**
Add API/CLI calls for manual cache purge (per-user, per-model, full), and automatic invalidation on model/provider version change.

**Logic Details (Pseudocode):**

```lua
-- Invalidate cache entry by key
function Cache:invalidate(key)
  self.backend:delete(key)
end

-- Invalidate all entries for a user
function Cache:invalidate_user(user_id)
  for key in self.backend:keys() do
    if key:match(user_id) then
      self.backend:delete(key)
    end
  end
end

-- Invalidate all entries for a model
function Cache:invalidate_model(model_name)
  for key in self.backend:keys() do
    if key:match(model_name) then
      self.backend:delete(key)
    end
  end
end

-- Full cache clear
function Cache:purge()
  self.backend:clear()
end

-- Automatic invalidate on version change
function Cache:auto_invalidate_on_version_change(model_name, version)
  -- Store last-seen version in cache metadata
  local prev_version = self.backend:get_metadata(model_name.."_version")
  if prev_version ~= version then
    self:invalidate_model(model_name)
    self.backend:set_metadata(model_name.."_version", version)
  end
end
```
**Key points:**
- Expose CLI/user commands for manual purge by user/model/full.
- Backend must support iterating all keys (or support prefix deletion for persistent backends).
- Track and compare model/provider version for auto-invalidation.

**Files to Modify/Create:**
- `lua/avante/utils/cache.lua`: Add invalidate methods.
- CLI or Neovim user commands for invalidation.
- Provider integration files: trigger invalidation on relevant events.

**Testing:**
- Test API/CLI invalidation hooks and version-change auto-invalidation logic.

---

## 6. Observability and Logging

**Functionality:**
Log cache hits, misses, errors, and latency. Optionally surface this in UI or logs.

**Logic Details (Pseudocode):**

```lua
function Cache:lookup(key)
  local t0 = now()
  local entry = self.backend:get(key)
  if entry == nil then
    log("cache miss", key, now()-t0)
    return nil
  end
  if entry.expiry and entry.expiry < now() then
    self.backend:delete(key)
    log("cache expired", key, now()-t0)
    return nil
  end
  log("cache hit", key, now()-t0)
  return entry.value
end

function Cache:save(key, value)
  local t0 = now()
  self.backend:set(key, {value=value, expiry=now()+self.backend.ttl})
  log("cache save", key, now()-t0)
end

function Cache:handle_error(err, key)
  log("cache error", key, err)
end

function Cache:stats()
  -- Return summary statistics: hits, misses, evictions, errors, avg latency
end

function log(event, key, ...)
  -- Write log event, key, details to file or to Neovim message area
end
```
**Key points:**
- Log every cache hit, miss, expired, save, and error, including latency.
- Optionally provide a `stats` method to summarize cache usage.
- Use the logging mechanism best suited for the environment (stdout, file, Neovim message area, etc).

**Files to Modify/Create:**
- `lua/avante/utils/cache.lua`: Add logging.
- Provider/llm integration files: log when result is from cache/not.

**Testing:**
- Simulate cache activity and confirm logs and stats reflect reality.

---

## 7. Privacy, Security, and Partitioning

**Functionality:**
Support optional per-user cache partitioning, and stubs for persistent backends with encryption.

**Logic Details (Pseudocode):**

```lua
-- Example: Add user or namespace to cache key
function Cache:make_partitioned_key(key, user_id, namespace)
  local partition = user_id or "_global"
  if namespace then partition = partition .. ":" .. namespace end
  return partition .. ":" .. key
end

-- To use partitioning: always call make_partitioned_key when storing/retrieving
function Cache:save(key, value, user_id, namespace)
  local part_key = self:make_partitioned_key(key, user_id, namespace)
  self.backend:set(part_key, value)
end

function Cache:lookup(key, user_id, namespace)
  local part_key = self:make_partitioned_key(key, user_id, namespace)
  return self.backend:get(part_key)
end

-- Persistent backend stub
function Cache:enable_encryption(password)
  -- Stub for future: encrypt values before storage, decrypt on retrieval
end
```
**Key points:**
- Partition cache by user/namespace where required.
- Provide hooks/stubs for persistent+encrypted backends.
- Document limitations of ephemeral memory backend for privacy.

**Files to Modify/Create:**
- `lua/avante/utils/cache.lua`: Add optional user/namespace partitioning.
- Documentation and stubs for encryption if persistent backends are added.

**Details:**
- Partition cache keys by user ID/namespace where needed.

---

## 8. Test Coverage

**Functionality:**
Add unit tests for canonicalization, cache API, and integration flow.

**Logic Details:**
- Create a suite of tests covering:
  - Canonicalization edge cases: whitespace variations, parameter order, unicode, nested tables, tool list sorting, prompt normalization.
  - Cache API: lookup, save, invalidate, configure_backend, expiry/TTL, LRU eviction.
  - Provider integration flow: simulate cache hit/miss, ensure correct cache key usage, verify provider only called on miss.
  - Privacy/partitioning: checks for isolation between users/namespaces.
  - Observability: verify logging/statistics for hits, misses, errors, evictions.
  - Invalidation: manual and automatic (version change), targeted and full purge.

**Files to Modify/Create:**
- `tests/test_cache.lua`, `tests/test_canonicalization.lua` (new).

**Details:**
- Implement unit and integration tests for all new logic, using mocks/stubs for provider calls and time when needed.
- Include negative and edge cases for robustness.

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

