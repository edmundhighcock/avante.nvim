local Providers = require("avante.providers")
local Config = require("avante.config")
local Utils = require("avante.utils")
local Base = require("avante.llm_tools.base")
local History = require("avante.history")
local Line = require("avante.ui.line")
local Highlights = require("avante.highlights")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "dispatch_full_agent"

M.get_description = function()
  return [[Launch a comprehensive agent with advanced tool management and constraint handling.

This agent provides:
- Strict tool usage constraints
- Recursive launch prevention
- Dependency resolution
- Advanced error handling
- Token consumption tracking

When to use:
- Complex tasks requiring multiple tool interactions
- Scenarios with potential recursive tool usage
- Tasks needing sophisticated error management

RULES:
- Prevents launching forbidden or nested agents
- Limits total tool uses per execution
- Tracks and manages token consumption
- Provides sophisticated error recovery strategies

Unique Features:
- Advanced dependency resolution
- Granular tool usage tracking
- Intelligent error handling]]
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "prompt",
      description = "The task for the agent to perform",
      type = "string",
    },
  },
  required = { "prompt" },
  usage = {
    prompt = "The task for the agent to perform",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "results",
    description = "Results from executed tools",
    type = "table",
  },
  {
    name = "error",
    description = "Error message if the agent fails",
    type = "string",
    optional = true,
  },
}

local function get_available_tools()
  return {
    require("avante.llm_tools.ls"),
    require("avante.llm_tools.grep"),
    require("avante.llm_tools.glob"),
    require("avante.llm_tools.view"),
    require("avante.llm_tools.attempt_completion"),
  }
end

---@class avante.DispatchFullAgentInput
---@field prompt string

---@type avante.LLMToolOnRender<avante.DispatchFullAgentInput>
function M.on_render(input, opts)
  local result_message = opts.result_message
  local store = opts.store or {}
  local messages = store.messages or {}
  local tool_use_summary = {}

  for _, msg in ipairs(messages) do
    local summary
    local tool_use = History.Helpers.get_tool_use_data(msg)
    if tool_use then
      local tool_result = History.Helpers.get_tool_result(tool_use.id, messages)
      if tool_result then
        summary = string.format("Tool %s: %s", tool_use.name, tool_result.is_error and "failed" or "succeeded")
      end
      if summary then summary = "  " .. Utils.icon("🛠️ ") .. summary end
    else
      summary = History.Helpers.get_text_data(msg)
    end
    if summary then table.insert(tool_use_summary, summary) end
  end

  local state = "running"
  local icon = Utils.icon("🔄 ")
  local hl = Highlights.AVANTE_TASK_RUNNING

  if result_message then
    local result = History.Helpers.get_tool_result_data(result_message)
    if result then
      if result.is_error then
        state = "failed"
        icon = Utils.icon("❌ ")
        hl = Highlights.AVANTE_TASK_FAILED
      else
        state = "completed"
        icon = Utils.icon("✅ ")
        hl = Highlights.AVANTE_TASK_COMPLETED
      end
    end
  end

  local lines = {}
  table.insert(lines, Line:new({ { icon .. "Full Agent " .. state, hl } }))
  table.insert(lines, Line:new({ { "" } }))
  table.insert(lines, Line:new({ { "  Task:" } }))

  local prompt_lines = vim.split(input.prompt or "", "\n")
  for _, line in ipairs(prompt_lines) do
    table.insert(lines, Line:new({ { "    " .. line } }))
  end

  table.insert(lines, Line:new({ { "" } }))
  table.insert(lines, Line:new({ { "  Task summary:" } }))

  for _, summary in ipairs(tool_use_summary) do
    local summary_lines = vim.split(summary, "\n")
    for _, line in ipairs(summary_lines) do
      table.insert(lines, Line:new({ { "    " .. line } }))
    end
  end

  return lines
end

---@type AvanteLLMToolFunc<avante.DispatchFullAgentInput>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local session_ctx = opts.session_ctx

  if not on_complete then return false, "on_complete not provided" end

  local prompt = input.prompt
  local tools = get_available_tools()
  local start_time = Utils.get_timestamp()

  if on_log then on_log("prompt: " .. prompt) end

  local system_prompt = ([[You are an advanced agent with comprehensive tool management capabilities.
Your task is to help the user with their request: "${prompt}"
Use available tools thoroughly and intelligently to find the most relevant information.
Apply strict usage constraints and provide a clear, concise summary of your findings.]]):gsub("${prompt}", prompt)

  local history_messages = {}
  local tool_use_messages = {}

  local total_tokens = 0
  local result = {}

  ---@type avante.AgentLoopOptions
  local agent_loop_options = {
    system_prompt = system_prompt,
    user_input = "start",
    tools = tools,
    on_tool_log = session_ctx.on_tool_log,
    on_messages_add = function(msgs)
      msgs = vim.islist(msgs) and msgs or { msgs }
      for _, msg in ipairs(msgs) do
        local idx = nil
        for i, m in ipairs(history_messages) do
          if m.uuid == msg.uuid then
            idx = i
            break
          end
        end
        if idx ~= nil then
          history_messages[idx] = msg
        else
          table.insert(history_messages, msg)
        end
      end
      if opts.set_store then opts.set_store("messages", history_messages) end
      for _, msg in ipairs(msgs) do
        local tool_use = History.Helpers.get_tool_use_data(msg)
        if tool_use then
          tool_use_messages[msg.uuid] = true
          if tool_use.name == "attempt_completion" and tool_use.input and tool_use.input.result then
            result = tool_use.input.result
          end
        end
      end
    end,
    session_ctx = session_ctx,
    on_start = session_ctx.on_start,
    on_chunk = function(chunk)
      if not chunk then return end
      total_tokens = total_tokens + (#vim.split(chunk, " ") * 1.3)
    end,
    on_complete = function(err)
      if err ~= nil then
        err = string.format("dispatch_full_agent failed: %s", vim.inspect(err))
        on_complete(err, nil)
        return
      end

      local end_time = Utils.get_timestamp()
      local elapsed_time = Utils.datetime_diff(start_time, end_time)
      local tool_use_count = vim.tbl_count(tool_use_messages)

      local summary = "dispatch_full_agent Done ("
        .. (tool_use_count <= 1 and "1 tool use" or tool_use_count .. " tool uses")
        .. " · "
        .. math.ceil(total_tokens)
        .. " tokens · "
        .. elapsed_time
        .. "s)"

      if session_ctx.on_messages_add then
        local message = History.Message:new("assistant", "\n\n" .. summary, {
          just_for_display = true,
        })
        session_ctx.on_messages_add({ message })
      end

      on_complete(result, nil)
    end,
  }

  local Llm = require("avante.llm")
  Llm.agent_loop(agent_loop_options)
end

return M

