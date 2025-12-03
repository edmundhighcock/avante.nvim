local Providers = require("avante.providers")
local Config = require("avante.config")
local Utils = require("avante.utils")
local Base = require("avante.llm_tools.base")
local DispatchAgent = require("avante.llm_tools.dispatch_agent")

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
  return DispatchAgent._render_agent_task(input, opts, "Full agent task")
end

---@type AvanteLLMToolFunc<avante.DispatchFullAgentInput>
function M.func(input, opts)
  local system_prompt_template = [[You are a helpful assistant with access to a comprehensive set of tools for working with code.
Your task is to help the user with their request: "${prompt}"
Be thorough and use the tools available to you to find the most relevant information and make the necessary changes.
When you're done, provide a clear and concise summary of what you found and what changes you made.]]

  return DispatchAgent._execute_agent_loop(input, opts, {
    tools = get_available_tools(),
    system_prompt_template = system_prompt_template,
    agent_name = "dispatch_full_agent",
  })
end

return M
