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
  local provider = Providers[Config.provider]
  if Config.provider:match("copilot") and provider.model and provider.model:match("gpt") then
    return [[Launch a new agent that has access to most tools including file editing, diagnostics, git operations, and web search. This agent can perform complex tasks that require multiple operations. Use this when you need to accomplish tasks that involve reading, modifying, and creating files, or when you need access to advanced capabilities.]]
  end

  return [[Launch a new agent that has access to most tools including: `glob`, `grep`, `ls`, `view`, `str_replace`, `write_to_file`, `insert`, `undo_edit`, `edit_file`, `read_file_toplevel_symbols`, `read_definitions`, `get_diagnostics`, `think`, `git_diff`, `git_commit`, `run_python`, `rag_search`, `web_search`, `fetch`, `move_path`, `copy_path`, `delete_path`, `create_dir`, `read_global_file`, `write_global_file`, `load_mcp_tool`, `delete_tool_use_messages`, and `attempt_completion`.

This agent can perform complex tasks that require multiple operations across your codebase. Use this when you need to:
- Make extensive changes across multiple files
- Perform complex refactoring operations
- Search for information and then apply changes based on findings
- Analyze code structure and make modifications
- Work with git operations
- Search the web or fetch external resources
- Create, move, or delete files and directories

EXCLUDED TOOLS (for safety and to prevent issues):
- `bash` - excluded for security reasons
- `read_todos` / `write_todos` - excluded to avoid interfering with the main agent's task management
- `dispatch_agent` / `dispatch_full_agent` - excluded to prevent infinite recursion

RULES:
- Do not ask for more information than necessary. Use the tools provided to accomplish the user's request efficiently and effectively. When you've completed your task, you must use the attempt_completion tool to present the result to the user. The user may provide feedback, which you can use to make improvements and try again.
- NEVER end attempt_completion result with a question or request to engage in further conversation! Formulate the end of your result in a way that is final and does not require further input from the user.
- Be thorough and systematic in your approach. Since you have access to powerful editing tools, make sure to verify your changes and test when possible.

OBJECTIVE:
1. Analyze the user's task and set clear, achievable goals to accomplish it. Prioritize these goals in a logical order.
2. Work through these goals sequentially, utilizing available tools one at a time as necessary. Each goal should correspond to a distinct step in your problem-solving process. You will be informed on the work completed and what's remaining as you go.
3. Once you've completed the user's task, you must use the attempt_completion tool to present the result of the task to the user. You may also provide a CLI command to showcase the result of your task; this can be particularly useful for web development tasks, where you can run e.g. \`open index.html\` to show the website you've built.

Usage notes:
1. Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses
2. When the agent is done, it will return a single message back to you. The result returned by the agent is not visible to the user. To show the user the result, you should send a text message back to the user with a concise summary of the result.
3. Each agent invocation is stateless. You will not be able to send additional messages to the agent, nor will the agent be able to communicate with you outside of its final report. Therefore, your prompt should contain a highly detailed task description for the agent to perform autonomously and you should specify exactly what information the agent should return back to you in its final and only message to you.
4. The agent's outputs should generally be trusted
5. IMPORTANT: The agent has access to powerful file editing tools (`str_replace`, `write_to_file`, `edit_file`, etc.). Make sure your instructions are clear about what changes to make and where.]]
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
    name = "result",
    description = "The result of the agent",
    type = "string",
  },
  {
    name = "error",
    description = "The error message if the agent fails",
    type = "string",
    optional = true,
  },
}

local function get_available_tools()
  -- Get all tools from init.lua and filter out the excluded ones
  local init = require("avante.llm_tools.init")

  -- Define tools that should be excluded for safety and to prevent issues
  local excluded_tools = {
    "bash", -- excluded for security reasons
    "read_todos", -- excluded to avoid interfering with the main agent's task management
    "write_todos", -- excluded to avoid interfering with the main agent's task management
    "dispatch_agent", -- excluded to prevent infinite recursion
    "dispatch_full_agent", -- excluded to prevent infinite recursion
  }

  -- Get all tools and filter out excluded ones
  local all_tools = init.get_tools("", {})
  local filtered_tools = vim.tbl_filter(function(tool)
    return not vim.tbl_contains(excluded_tools, tool.name)
  end, all_tools)

  return filtered_tools
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
        if tool_use.name == "ls" then
          local path = tool_use.input.path
          if tool_result.is_error then
            summary = string.format("Ls %s: failed", path)
          else
            local ok, filepaths = pcall(vim.json.decode, tool_result.content)
            if ok then summary = string.format("Ls %s: %d paths", path, #filepaths) end
          end
        elseif tool_use.name == "grep" then
          local path = tool_use.input.path
          local query = tool_use.input.query
          if tool_result.is_error then
            summary = string.format("Grep %s in %s: failed", query, path)
          else
            local ok, filepaths = pcall(vim.json.decode, tool_result.content)
            if ok then summary = string.format("Grep %s in %s: %d paths", query, path, #filepaths) end
          end
        elseif tool_use.name == "glob" then
          local path = tool_use.input.path
          local pattern = tool_use.input.pattern
          if tool_result.is_error then
            summary = string.format("Glob %s in %s: failed", pattern, path)
          else
            local ok, result = pcall(vim.json.decode, tool_result.content)
            if ok then
              local matches = result.matches
              if matches then summary = string.format("Glob %s in %s: %d matches", pattern, path, #matches) end
            end
          end
        elseif tool_use.name == "view" then
          local path = tool_use.input.path
          if tool_result.is_error then
            summary = string.format("View %s: failed", path)
          else
            local ok, result = pcall(vim.json.decode, tool_result.content)
            if ok and type(result) == "table" and type(result.content) == "string" then
              local lines = vim.split(result.content, "\n")
              summary = string.format("View %s: %d lines", path, #lines)
            end
          end
        elseif tool_use.name == "str_replace" or tool_use.name == "write_to_file" or tool_use.name == "edit_file" then
          local path = tool_use.input.path
          if tool_result.is_error then
            summary = string.format("%s %s: failed", tool_use.name, path)
          else
            summary = string.format("%s %s: success", tool_use.name, path)
          end
        else
          -- Generic summary for other tools
          if tool_result.is_error then
            summary = string.format("%s: failed", tool_use.name)
          else
            summary = string.format("%s: success", tool_use.name)
          end
        end
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
  table.insert(lines, Line:new({ { icon .. "Full agent task " .. state, hl } }))
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

  local Llm = require("avante.llm")
  if not on_complete then return false, "on_complete not provided" end

  local prompt = input.prompt
  local tools = get_available_tools()
  local start_time = Utils.get_timestamp()

  if on_log then on_log("prompt: " .. prompt) end

  local system_prompt = ([[You are a helpful assistant with access to a comprehensive set of tools for working with code.
Your task is to help the user with their request: "${prompt}"
Be thorough and use the tools available to you to find the most relevant information and make the necessary changes.
When you're done, provide a clear and concise summary of what you found and what changes you made.]]):gsub("${prompt}", prompt)

  local history_messages = {}
  local tool_use_messages = {}

  local total_tokens = 0
  local result = ""

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

  Llm.agent_loop(agent_loop_options)
end

return M
