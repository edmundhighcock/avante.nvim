local Config = require("avante.config")
local Utils = require("avante.utils")

---@class TokenUsageTracker
local TokenUsageTracker = {}

---Initialize the token usage tracker
---@param config table Configuration for token usage tracking
function TokenUsageTracker:new(config)
  local obj = setmetatable({}, self)
  self.__index = self

  obj.config = config or {}
  obj.usage_log = obj:load_usage_log()
  obj.cache = require('avante.utils.lru_cache'):new(config.max_records or 1000)

  return obj
end

---Load existing usage log from persistent storage
---@return table
function TokenUsageTracker:load_usage_log()
  local log_path = self.config.logging.log_path
  if not vim.fn.filereadable(log_path) then return {} end

  local ok, content = pcall(vim.fn.readfile, log_path)
  if not ok then return {} end

  return vim.json.decode(table.concat(content, '\n')) or {}
end

---Record token usage for a specific provider and model
---@param usage_data table Token usage information
function TokenUsageTracker:record_usage(usage_data)
  if not self.config.enabled then return end

  usage_data.timestamp = os.time()

  -- Add to in-memory cache
  self.cache:set(usage_data.conversation_id or tostring(os.time()), usage_data)

  -- Add to persistent log
  table.insert(self.usage_log, usage_data)

  -- Prune old records
  self:prune_usage_log()

  -- Async save to disk
  vim.schedule(function()
    self:save_usage_log()
  end)
end

---Prune usage log based on time window and max records
function TokenUsageTracker:prune_usage_log()
  local time_window = self.config.time_window_hours * 3600  -- Convert hours to seconds
  local current_time = os.time()

  self.usage_log = vim.iter(self.usage_log)
    :filter(function(log_entry)
      return current_time - log_entry.timestamp <= time_window
    end)
    :take(self.config.max_records)
    :totable()
end

---Save usage log to persistent storage
function TokenUsageTracker:save_usage_log()
  if not self.config.logging.persist then return end

  local log_path = self.config.logging.log_path
  local log_dir = vim.fn.fnamemodify(log_path, ":h")

  -- Ensure log directory exists
  vim.fn.mkdir(log_dir, "p")

  local json_content = vim.json.encode(self.usage_log)
  local ok, _ = pcall(vim.fn.writefile, {json_content}, log_path)

  if not ok then
    print("Failed to save token usage log")
  end
end

---Analyze token usage across providers and models
---@return table
function TokenUsageTracker:analyze_usage()
  local providers = {}
  local total_tokens = 0

  for _, usage in ipairs(self.usage_log) do
    providers[usage.provider] = providers[usage.provider] or {}
    providers[usage.provider][usage.model] =
      (providers[usage.provider][usage.model] or 0) + usage.total_tokens
    total_tokens = total_tokens + usage.total_tokens
  end

  return {
    providers = providers,
    total_tokens = total_tokens,
    avg_tokens_per_request = total_tokens / #self.usage_log
  }
end

---Create a global token usage tracker
---@return TokenUsageTracker
function TokenUsageTracker:get_tracker()
  if not self._global_tracker then
    self._global_tracker = TokenUsageTracker:new(Config.behaviour.token_usage_tracking)
  end
  return self._global_tracker
end

return TokenUsageTracker

