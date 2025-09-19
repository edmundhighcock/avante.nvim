---@class AvanteBedrockClaudeTextMessage
---@field type "text"
---@field text string
---
---@class AvanteBedrockClaudeMessage
---@field role "user" | "assistant"
---@field content [AvanteBedrockClaudeTextMessage][]

local P = require("avante.providers")
local Claude = require("avante.providers.claude")
local Config = require("avante.config")

---@class AvanteBedrockModelHandler
local M = {}

M.support_prompt_caching = true
M.role_map = {
  user = "user",
  assistant = "assistant",
}

M.is_disable_stream = Claude.is_disable_stream
M.parse_messages = Claude.parse_messages
M.parse_response = Claude.parse_response
M.transform_tool = Claude.transform_tool
M.transform_anthropic_usage = Claude.transform_anthropic_usage

---@param provider AvanteProviderFunctor
---@param prompt_opts AvantePromptOptions
---@param request_body table
---@return table
function M.build_bedrock_payload(provider, prompt_opts, request_body)
  local system_prompt = prompt_opts.system_prompt or ""
  local messages = provider:parse_messages(prompt_opts)
  local max_tokens = request_body.max_tokens or 2000

  local provider_conf, _ = P.parse_config(provider)
  local disable_tools = provider_conf.disable_tools or false
  local tools = {}
  if not disable_tools and prompt_opts.tools then
    for _, tool in ipairs(prompt_opts.tools) do
      table.insert(tools, provider:transform_tool(tool))
    end
  end

  -- Check if prompt caching is enabled for this provider
  local prompt_caching_enabled = Config.prompt_caching and Config.prompt_caching.enabled and Config.prompt_caching.providers.bedrock

  -- Add cache_control to system prompt if prompt caching is supported and enabled
  if M.support_prompt_caching and prompt_caching_enabled and system_prompt ~= "" then
    system_prompt = {
      type = "text",
      text = system_prompt,
      cache_control = { type = "ephemeral" }
    }
  end

  -- Add cache_control to messages if prompt caching is supported and enabled
  if M.support_prompt_caching and prompt_caching_enabled and #messages > 0 then
    local found = false
    for i = #messages, 1, -1 do
      local message = messages[i]
      message = vim.deepcopy(message)
      local content = message.content
      for j = #content, 1, -1 do
        local item = content[j]
        if item.type == "text" then
          item.cache_control = { type = "ephemeral" }
          found = true
          break
        end
      end
      if found then
        messages[i] = message
        break
      end
    end
  end

  -- Add cache_control to tools if prompt caching is supported and enabled
  if M.support_prompt_caching and prompt_caching_enabled and #tools > 0 then
    local last_tool = vim.deepcopy(tools[#tools])
    last_tool.cache_control = { type = "ephemeral" }
    tools[#tools] = last_tool
  end

  local payload = {
    anthropic_version = "bedrock-2023-05-31",
    max_tokens = max_tokens,
    messages = messages,
    tools = tools,
    system = system_prompt,
  }
  return vim.tbl_deep_extend("force", payload, request_body or {})
end

return M
