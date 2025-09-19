local Utils = require("avante.utils")
local Clipboard = require("avante.clipboard")
local P = require("avante.providers")
local HistoryMessage = require("avante.history.message")
local JsonParser = require("avante.libs.jsonparser")
local Config = require("avante.config")

---@class AvanteProviderFunctor
local M = {}

M.api_key_name = "ANTHROPIC_API_KEY"
M.support_prompt_caching = true

M.role_map = {
  user = "user",
  assistant = "assistant",
}

---@param message table
---@param index integer
---@return boolean
function M:is_static_content(message, index)
  -- System prompts are typically static
  if message.role == "system" then
    return true
  end

  -- Consider first user message as static (usually contains context/instructions)
  -- Use the configured static_message_count or default to 2
  local static_message_count = Config.prompt_caching and Config.prompt_caching.static_message_count or 2
  if index <= static_message_count then
    return true
  end

  -- Check if message content is marked as context (usually static)
  if message.is_context then
    return true
  end

  return false
end

---@param messages table[]
---@param system_prompt string
---@param index integer
---@return integer
function M:count_tokens_before(messages, system_prompt, index)
  local token_count = 0

  -- Count tokens in system prompt
  if system_prompt and system_prompt ~= "" then
    token_count = token_count + Utils.tokens.calculate_tokens(system_prompt)
  end

  -- Count tokens in messages up to the index
  for i = 1, index do
    local message = messages[i]
    local content = message.content

    if type(content) == "string" then
      token_count = token_count + Utils.tokens.calculate_tokens(content)
    elseif type(content) == "table" then
      for _, item in ipairs(content) do
        if type(item) == "string" then
          token_count = token_count + Utils.tokens.calculate_tokens(item)
        elseif type(item) == "table" and item.type == "text" then
          token_count = token_count + Utils.tokens.calculate_tokens(item.text)
        end
      end
    end
  end

  return token_count
end

---@param headers table<string, string>
---@return integer|nil
function M:get_rate_limit_sleep_time(headers)
  local remaining_tokens = tonumber(headers["anthropic-ratelimit-tokens-remaining"])
  if remaining_tokens == nil then return end
  if remaining_tokens > 10000 then return end
  local reset_dt_str = headers["anthropic-ratelimit-tokens-reset"]
  if remaining_tokens ~= 0 then reset_dt_str = reset_dt_str or headers["anthropic-ratelimit-requests-reset"] end
  local reset_dt, err = Utils.parse_iso8601_date(reset_dt_str)
  if err then
    Utils.warn(err)
    return
  end
  local now = Utils.utc_now()
  return Utils.datetime_diff(tostring(now), tostring(reset_dt))
end

---@param tool AvanteLLMTool
---@return AvanteClaudeTool
function M:transform_tool(tool)
  local input_schema_properties, required = Utils.llm_tool_param_fields_to_json_schema(tool.param.fields)
  return {
    name = tool.name,
    description = tool.get_description and tool.get_description() or tool.description,
    input_schema = {
      type = "object",
      properties = input_schema_properties,
      required = required,
    },
  }
end

function M:is_disable_stream() return false end

---@return AvanteClaudeMessage[]
function M:parse_messages(opts)
  ---@type AvanteClaudeMessage[]
  local messages = {}

  local provider_conf, _ = P.parse_config(self)

  -- Separate static and dynamic content
  local static_messages = {}
  local dynamic_messages = {}

  -- First pass: categorize messages as static or dynamic
  for idx, message in ipairs(opts.messages) do
    if self:is_static_content(message, idx) then
      table.insert(static_messages, { idx = idx, message = message })
    else
      table.insert(dynamic_messages, { idx = idx, message = message })
    end
  end

  -- Preserve original order within each category
  table.sort(static_messages, function(a, b) return a.idx < b.idx end)
  table.sort(dynamic_messages, function(a, b) return a.idx < b.idx end)

  -- Create a new ordered list with static content first, followed by dynamic content
  local ordered_messages = {}
  for _, item in ipairs(static_messages) do
    table.insert(ordered_messages, item.message)
  end
  for _, item in ipairs(dynamic_messages) do
    table.insert(ordered_messages, item.message)
  end

  ---@type {idx: integer, length: integer}[]
  local messages_with_length = {}
  for idx, message in ipairs(ordered_messages) do
    table.insert(messages_with_length, { idx = idx, length = Utils.tokens.calculate_tokens(message.content) })
  end

  table.sort(messages_with_length, function(a, b) return a.length > b.length end)

  local has_tool_use = false
  for _, message in ipairs(ordered_messages) do
    local content_items = message.content
    local message_content = {}
    if type(content_items) == "string" then
      if message.role == "assistant" then content_items = content_items:gsub("%s+$", "") end
      if content_items ~= "" then
        table.insert(message_content, {
          type = "text",
          text = content_items,
        })
      end
    elseif type(content_items) == "table" then
      ---@cast content_items AvanteLLMMessageContentItem[]
      for _, item in ipairs(content_items) do
        if type(item) == "string" then
          if message.role == "assistant" then item = item:gsub("%s+$", "") end
          table.insert(message_content, { type = "text", text = item })
        elseif type(item) == "table" and item.type == "text" then
          table.insert(message_content, { type = "text", text = item.text })
        elseif type(item) == "table" and item.type == "image" then
          table.insert(message_content, { type = "image", source = item.source })
        elseif not provider_conf.disable_tools and type(item) == "table" and item.type == "tool_use" then
          has_tool_use = true
          table.insert(message_content, { type = "tool_use", name = item.name, id = item.id, input = item.input })
        elseif
          not provider_conf.disable_tools
          and type(item) == "table"
          and item.type == "tool_result"
          and has_tool_use
        then
          table.insert(
            message_content,
            { type = "tool_result", tool_use_id = item.tool_use_id, content = item.content, is_error = item.is_error }
          )
        elseif type(item) == "table" and item.type == "thinking" then
          table.insert(message_content, { type = "thinking", thinking = item.thinking, signature = item.signature })
        elseif type(item) == "table" and item.type == "redacted_thinking" then
          table.insert(message_content, { type = "redacted_thinking", data = item.data })
        end
      end
    end
    if #message_content > 0 then
      table.insert(messages, {
        role = self.role_map[message.role],
        content = message_content,
      })
    end
  end

  if Clipboard.support_paste_image() and opts.image_paths and #opts.image_paths > 0 then
    local message_content = messages[#messages].content
    for _, image_path in ipairs(opts.image_paths) do
      table.insert(message_content, {
        type = "image",
        source = {
          type = "base64",
          media_type = "image/png",
          data = Clipboard.get_base64_content(image_path),
        },
      })
    end
    messages[#messages].content = message_content
  end

  return messages
end

---@param usage avante.AnthropicTokenUsage | nil
---@return avante.LLMTokenUsage | nil
function M.transform_anthropic_usage(usage)
  if not usage then return nil end

  -- Calculate cache stats
  local cache_hit_tokens = usage.cache_read_input_tokens or 0
  local cache_write_tokens = usage.cache_creation_input_tokens or 0
  local total_input_tokens = usage.input_tokens or 0
  local cache_hit_rate = total_input_tokens > 0 and (cache_hit_tokens / total_input_tokens) or 0

  -- Record stats for visualization
  if not M.cache_stats then M.cache_stats = {} end
  table.insert(M.cache_stats, {
    timestamp = os.time(),
    cache_hit_tokens = cache_hit_tokens,
    cache_write_tokens = cache_write_tokens,
    total_input_tokens = total_input_tokens,
    cache_hit_rate = cache_hit_rate,
    conversation_id = usage.conversation_id or "unknown",
    model = usage.model or "unknown"
  })

  -- Log detailed cache info if debug is enabled
  if Config.prompt_caching and Config.prompt_caching.debug then
    Utils.info(string.format(
      "Cache performance: hit_rate=%.2f%%, hit_tokens=%d, write_tokens=%d, total_tokens=%d",
      cache_hit_rate * 100,
      cache_hit_tokens,
      cache_write_tokens,
      total_input_tokens
    ))
  end

  -- Return usage info with cache metrics
  ---@type avante.LLMTokenUsage
  local res = {
    prompt_tokens = total_input_tokens + cache_write_tokens,
    completion_tokens = usage.output_tokens,
    cache_hit_tokens = cache_hit_tokens,
    cache_write_tokens = cache_write_tokens,
    cache_hit_rate = cache_hit_rate
  }
  return res
end

-- Add a function to analyze cache performance
function M.analyze_cache_performance()
  if not M.cache_stats or #M.cache_stats == 0 then
    return "No cache statistics available"
  end

  local total_hit_rate = 0
  local total_hit_tokens = 0
  local total_write_tokens = 0
  local total_input_tokens = 0

  for _, stat in ipairs(M.cache_stats) do
    total_hit_rate = total_hit_rate + stat.cache_hit_rate
    total_hit_tokens = total_hit_tokens + stat.cache_hit_tokens
    total_write_tokens = total_write_tokens + stat.cache_write_tokens
    total_input_tokens = total_input_tokens + stat.total_input_tokens
  end

  local avg_hit_rate = total_hit_rate / #M.cache_stats

  return {
    average_hit_rate = avg_hit_rate,
    total_hit_tokens = total_hit_tokens,
    total_write_tokens = total_write_tokens,
    total_input_tokens = total_input_tokens,
    sample_count = #M.cache_stats
  }
end

function M:parse_response(ctx, data_stream, event_state, opts)
  if event_state == nil then
    if data_stream:match('"message_start"') then
      event_state = "message_start"
    elseif data_stream:match('"message_delta"') then
      event_state = "message_delta"
    elseif data_stream:match('"message_stop"') then
      event_state = "message_stop"
    elseif data_stream:match('"content_block_start"') then
      event_state = "content_block_start"
    elseif data_stream:match('"content_block_delta"') then
      event_state = "content_block_delta"
    elseif data_stream:match('"content_block_stop"') then
      event_state = "content_block_stop"
    end
  end
  if ctx.content_blocks == nil then ctx.content_blocks = {} end

  ---@param content AvanteLLMMessageContentItem
  ---@param uuid? string
  ---@return avante.HistoryMessage
  local function new_assistant_message(content, uuid)
    assert(
      event_state == "content_block_start"
        or event_state == "content_block_delta"
        or event_state == "content_block_stop",
      "called with unexpected event_state: " .. event_state
    )
    return HistoryMessage:new("assistant", content, {
      state = event_state == "content_block_stop" and "generated" or "generating",
      turn_id = ctx.turn_id,
      uuid = uuid,
    })
  end

  if event_state == "message_start" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    ctx.usage = jsn.message.usage
  elseif event_state == "content_block_start" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    local content_block = jsn.content_block
    content_block.stoppped = false
    ctx.content_blocks[jsn.index + 1] = content_block
    if content_block.type == "text" then
      local msg = new_assistant_message(content_block.text)
      content_block.uuid = msg.uuid
      if opts.on_messages_add then opts.on_messages_add({ msg }) end
    elseif content_block.type == "thinking" then
      if opts.on_chunk then opts.on_chunk("<think>\n") end
      if opts.on_messages_add then
        local msg = new_assistant_message({
          type = "thinking",
          thinking = content_block.thinking,
          signature = content_block.signature,
        })
        content_block.uuid = msg.uuid
        opts.on_messages_add({ msg })
      end
    elseif content_block.type == "tool_use" then
      if opts.on_messages_add then
        local incomplete_json = JsonParser.parse(content_block.input_json)
        local msg = new_assistant_message({
          type = "tool_use",
          name = content_block.name,
          id = content_block.id,
          input = incomplete_json or {},
        })
        content_block.uuid = msg.uuid
        opts.on_messages_add({ msg })
        -- opts.on_stop({ reason = "tool_use", streaming_tool_use = true })
      end
    end
  elseif event_state == "content_block_delta" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    local content_block = ctx.content_blocks[jsn.index + 1]
    if jsn.delta.type == "input_json_delta" then
      if not content_block.input_json then content_block.input_json = "" end
      content_block.input_json = content_block.input_json .. jsn.delta.partial_json
      return
    elseif jsn.delta.type == "thinking_delta" then
      content_block.thinking = content_block.thinking .. jsn.delta.thinking
      if opts.on_chunk then opts.on_chunk(jsn.delta.thinking) end
      if opts.on_messages_add then
        local msg = new_assistant_message({
          type = "thinking",
          thinking = content_block.thinking,
          signature = content_block.signature,
        }, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    elseif jsn.delta.type == "text_delta" then
      content_block.text = content_block.text .. jsn.delta.text
      if opts.on_chunk then opts.on_chunk(jsn.delta.text) end
      if opts.on_messages_add then
        local msg = new_assistant_message(content_block.text, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    elseif jsn.delta.type == "signature_delta" then
      if ctx.content_blocks[jsn.index + 1].signature == nil then ctx.content_blocks[jsn.index + 1].signature = "" end
      ctx.content_blocks[jsn.index + 1].signature = ctx.content_blocks[jsn.index + 1].signature .. jsn.delta.signature
    end
  elseif event_state == "content_block_stop" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    local content_block = ctx.content_blocks[jsn.index + 1]
    content_block.stoppped = true
    if content_block.type == "text" then
      if opts.on_messages_add then
        local msg = new_assistant_message(content_block.text, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    elseif content_block.type == "thinking" then
      if opts.on_chunk then
        if content_block.thinking and content_block.thinking ~= vim.NIL and content_block.thinking:sub(-1) ~= "\n" then
          opts.on_chunk("\n</think>\n\n")
        else
          opts.on_chunk("</think>\n\n")
        end
      end
      if opts.on_messages_add then
        local msg = new_assistant_message({
          type = "thinking",
          thinking = content_block.thinking,
          signature = content_block.signature,
        }, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    elseif content_block.type == "tool_use" then
      if opts.on_messages_add then
        local ok_, complete_json = pcall(vim.json.decode, content_block.input_json)
        if not ok_ then
          Utils.warn("Failed to parse tool_use input_json: " .. content_block.input_json)
          return
        end
        local msg = new_assistant_message({
          type = "tool_use",
          name = content_block.name,
          id = content_block.id,
          input = complete_json or {},
        }, content_block.uuid)
        opts.on_messages_add({ msg })
      end
    end
  elseif event_state == "message_delta" then
    local ok, jsn = pcall(vim.json.decode, data_stream)
    if not ok then return end
    if jsn.usage and ctx.usage then ctx.usage.output_tokens = ctx.usage.output_tokens + jsn.usage.output_tokens end
    if jsn.delta.stop_reason == "end_turn" then
      opts.on_stop({ reason = "complete", usage = M.transform_anthropic_usage(ctx.usage) })
    elseif jsn.delta.stop_reason == "max_tokens" then
      opts.on_stop({ reason = "max_tokens", usage = M.transform_anthropic_usage(ctx.usage) })
    elseif jsn.delta.stop_reason == "tool_use" then
      opts.on_stop({
        reason = "tool_use",
        usage = M.transform_anthropic_usage(ctx.usage),
      })
    end
    return
  elseif event_state == "error" then
    opts.on_stop({ reason = "error", error = vim.json.decode(data_stream) })
  end
end

---@param prompt_opts AvantePromptOptions
---@return table
function M:parse_curl_args(prompt_opts)
  local provider_conf, request_body = P.parse_config(self)
  local disable_tools = provider_conf.disable_tools or false

  local headers = {
    ["Content-Type"] = "application/json",
    ["anthropic-version"] = "2023-06-01",
    ["anthropic-beta"] = "prompt-caching-2024-07-31",
  }

  if P.env.require_api_key(provider_conf) then headers["x-api-key"] = self.parse_api_key() end

  local messages = self:parse_messages(prompt_opts)

  local tools = {}
  if not disable_tools and prompt_opts.tools then
    for _, tool in ipairs(prompt_opts.tools) do
      -- Only include tool if lazy loading is disabled, or if it's always eager, or if it's been requested
      local LazyLoading = require("avante.llm_tools.lazy_loading")

      if LazyLoading.should_include_tool(tool.name, tool.server_name) then
        if Config.mode == "agentic" then
          if tool.name == "create_file" then goto continue end
          if tool.name == "view" then goto continue end
          if tool.name == "str_replace" then goto continue end
          if tool.name == "create" then goto continue end
          if tool.name == "insert" then goto continue end
          if tool.name == "undo_edit" then goto continue end
          if tool.name == "replace_in_file" then goto continue end
        end
        table.insert(tools, self:transform_tool(tool))
      end
      ::continue::
    end
  end

  if prompt_opts.tools and #prompt_opts.tools > 0 and Config.mode == "agentic" then
    if provider_conf.model:match("claude%-sonnet%-4") then
      table.insert(tools, {
        type = "text_editor_20250429",
        name = "str_replace_based_edit_tool",
      })
    elseif provider_conf.model:match("claude%-3%-7%-sonnet") then
      table.insert(tools, {
        type = "text_editor_20250124",
        name = "str_replace_editor",
      })
    elseif provider_conf.model:match("claude%-3%-5%-sonnet") then
      table.insert(tools, {
        type = "text_editor_20250124",
        name = "str_replace_editor",
      })
    end
  end

  -- Check if prompt caching is enabled for this provider
  local prompt_caching_enabled = Config.prompt_caching and Config.prompt_caching.enabled and Config.prompt_caching.providers.claude

  -- Determine minimum token threshold based on model
  local min_tokens = 1024  -- Default
  if Config.prompt_caching and Config.prompt_caching.min_tokens_threshold then
    if provider_conf.model:match("claude%-3%-5%-haiku") and Config.prompt_caching.min_tokens_threshold["claude-3-5-haiku"] then
      min_tokens = Config.prompt_caching.min_tokens_threshold["claude-3-5-haiku"]
    elseif provider_conf.model:match("claude%-3%-7%-sonnet") and Config.prompt_caching.min_tokens_threshold["claude-3-7-sonnet"] then
      min_tokens = Config.prompt_caching.min_tokens_threshold["claude-3-7-sonnet"]
    elseif Config.prompt_caching.min_tokens_threshold.default then
      min_tokens = Config.prompt_caching.min_tokens_threshold.default
    end
  end

  -- Track token count for threshold check
  local current_tokens = 0

  if self.support_prompt_caching and prompt_caching_enabled then
    -- Get the cache strategy from config
    local cache_strategy = Config.prompt_caching and Config.prompt_caching.strategy or "simplified"

    if #messages > 0 then
      if cache_strategy == "simplified" then
        -- Simplified approach: place a single cache checkpoint at the end of static content
        -- This allows the model to automatically find the best cache match
        local static_boundary_idx = 0
        for i = 1, #messages do
          if self:is_static_content(messages[i], i) then
            -- Count tokens up to this point to check threshold
            current_tokens = self:count_tokens_before(messages, prompt_opts.system_prompt, i)

            -- Only consider this as a boundary if we've reached the token threshold
            if current_tokens >= min_tokens then
              static_boundary_idx = i
            end
          else
            break
          end
        end

        -- Add cache checkpoint at the end of static content if we found any
        if static_boundary_idx > 0 then
          local message = vim.deepcopy(messages[static_boundary_idx])
          ---@cast message AvanteClaudeMessage
          local content = message.content
          ---@cast content AvanteClaudeMessageContentTextItem[]
          for j = #content, 1, -1 do
            local item = content[j]
            if item.type == "text" then
              item.cache_control = { type = "ephemeral" }
              messages[static_boundary_idx] = message
              break
            end
          end
        end
      else
        -- Manual approach: place cache checkpoints at multiple points
        -- This gives more control but may be less effective than the simplified approach
        for i = 1, #messages do
          if self:is_static_content(messages[i], i) then
            -- Count tokens up to this point to check threshold
            current_tokens = self:count_tokens_before(messages, prompt_opts.system_prompt, i)

            -- Only add cache checkpoint if we've reached the minimum token threshold
            if current_tokens >= min_tokens then
              local message = vim.deepcopy(messages[i])
              ---@cast message AvanteClaudeMessage
              local content = message.content
              ---@cast content AvanteClaudeMessageContentTextItem[]
              for j = #content, 1, -1 do
                local item = content[j]
                if item.type == "text" then
                  item.cache_control = { type = "ephemeral" }
                  messages[i] = message
                  break
                end
              end
            end
          end
        end
      end
    end
    if #tools > 0 then
      local last_tool = vim.deepcopy(tools[#tools])
      last_tool.cache_control = { type = "ephemeral" }
      tools[#tools] = last_tool
    end
  end

  return {
    url = Utils.url_join(provider_conf.endpoint, "/v1/messages"),
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    headers = Utils.tbl_override(headers, self.extra_headers),
    body = vim.tbl_deep_extend("force", {
      model = provider_conf.model,
      system = {
        {
          type = "text",
          text = prompt_opts.system_prompt,
          cache_control = self.support_prompt_caching and { type = "ephemeral" } or nil,
        },
      },
      messages = messages,
      tools = tools,
      stream = true,
    }, request_body),
  }
end

function M.on_error(result)
  if result.status == 429 then return end
  if not result.body then
    return Utils.error("API request failed with status " .. result.status, { once = true, title = "Avante" })
  end

  local ok, body = pcall(vim.json.decode, result.body)
  if not (ok and body and body.error) then
    return Utils.error("Failed to parse error response", { once = true, title = "Avante" })
  end

  local error_msg = body.error.message
  local error_type = body.error.type

  if error_type == "insufficient_quota" then
    error_msg = "You don't have any credits or have exceeded your quota. Please check your plan and billing details."
  elseif error_type == "invalid_request_error" and error_msg:match("temperature") then
    error_msg = "Invalid temperature value. Please ensure it's between 0 and 1."
  end

  Utils.error(error_msg, { once = true, title = "Avante" })
end

return M
