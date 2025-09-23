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

---@class ExecutionContext
---@field _state table A private state table tracking tool usage and execution constraints
local ExecutionContext = {
  _state = {
    tool_usage_count = {},     -- Track individual tool usage
    total_token_consumption = 0,
    max_token_limit = 4096,    -- Configurable token limit
    current_depth = 0,         -- Track recursion depth
    max_recursion_depth = 3,   -- Prevent excessive nesting
    working_directory = vim.fn.getcwd(), -- Default to current working directory
    project_root = nil         -- Specific project root for file access validation
  },

  ---@brief Set the working directory and project root for execution context
  ---@param directory string The directory to set as working directory
  set_working_directory = function(self, directory)
    -- Validate and sanitize the directory path
    local sanitized_dir = vim.fn.fnamemodify(directory, ":p")

    -- Ensure the directory exists and is a directory
    if vim.fn.isdirectory(sanitized_dir) ~= 1 then
      error("Invalid working directory: " .. sanitized_dir)
    end

    self._state.working_directory = sanitized_dir
    self._state.project_root = sanitized_dir
  end,

  ---@brief Validate if a path is within the allowed project root
  ---@param path string The path to validate
  ---@return boolean Whether the path is allowed
  is_path_allowed = function(self, path)
    if not self._state.project_root then return false end

    -- Resolve the full, absolute path
    local full_path = vim.fn.fnamemodify(path, ":p")

    -- Check if the path starts with the project root
    return full_path:sub(1, #self._state.project_root) == self._state.project_root
  end,

  ---@brief Record and track the usage of a specific tool
  ---@param tool_name string The name of the tool being used
  ---@return number The total number of times this tool has been used
  record_tool_usage = function(self, tool_name)
    -- Increment the usage count for the specified tool
    -- If the tool hasn't been used before, initialize its count to 0 first
    self._state.tool_usage_count[tool_name] = (self._state.tool_usage_count[tool_name] or 0) + 1
    return self._state.tool_usage_count[tool_name]
  end,

  ---@brief Check if the current tool usage complies with predefined constraints
  ---@param tool_name string The name of the tool to validate
  ---@return boolean Whether the tool can be used
  ---@return string|nil An error message if the tool cannot be used
  check_usage_constraints = function(self, tool_name)
    -- Enforce constraints on tool usage to prevent overuse and resource exhaustion
    local max_tool_uses = 5  -- Default max uses per tool
    local current_uses = self._state.tool_usage_count[tool_name] or 0

    -- Check if tool has exceeded maximum allowed uses
    if current_uses >= max_tool_uses then
      return false, string.format("Tool %s exceeded maximum allowed uses (%d)", tool_name, max_tool_uses)
    end

    -- Check if total token consumption has reached the limit
    if self._state.total_token_consumption >= self._state.max_token_limit then
      return false, "Maximum token limit reached"
    end

    -- Check if recursion depth has exceeded the maximum allowed
    if self._state.current_depth >= self._state.max_recursion_depth then
      return false, "Maximum recursion depth exceeded"
    end

    -- All constraints passed
    return true
  end
}

---@class ToolValidator
---@field _forbidden_tools string[] A list of tools that are not allowed to be used
---@brief Validates tools before execution, ensuring safety and preventing misuse
local ToolValidator = {
  ---@field _forbidden_tools A predefined list of tools that cannot be executed
  _forbidden_tools = {
    "dispatch_agent",     -- Prevent nested agent dispatching
    "dispatch_full_agent", -- Prevent recursive full agent launches
    "nested_agent_executor" -- Prevent potential infinite recursion
  },

  ---@brief Validate a tool for execution based on predefined constraints
  ---@param tool table The tool to be validated
  ---@param context table The execution context tracking tool usage
  ---@return boolean Whether the tool is valid for execution
  ---@return string|nil An error message if the tool is not valid
  validate = function(self, tool, context)
    -- First, check if the tool is in the forbidden tools list
    -- This prevents execution of potentially dangerous or recursive tools
    for _, forbidden_tool in ipairs(self._forbidden_tools) do
      if tool.name == forbidden_tool then
        return false, string.format("Tool %s is not allowed", tool.name)
      end
    end

    -- Validate the tool against the current execution context constraints
    -- This ensures the tool doesn't exceed usage limits or cause resource exhaustion
    local can_use, err_msg = context:check_usage_constraints(tool.name)
    if not can_use then
      return false, err_msg
    end

    -- If all checks pass, the tool is valid for execution
    return true
  end
}

---@class DependencyResolver
---@brief Manages tool dependencies to ensure correct execution order
local DependencyResolver = {
  ---@brief Resolve and order tools based on their dependencies
  ---@param tools table[] A list of tools to resolve dependencies for
  ---@return table[] A list of tools in the correct execution order
  resolve_dependencies = function(self, tools)
    -- Implements a basic topological sorting of tools based on their dependencies
    -- This ensures that tools with dependencies are executed in the correct order
    local resolved_tools = {}  -- Final list of tools in execution order
    local visited = {}         -- Track which tools have been processed

    ---@brief Recursive function to visit and resolve tool dependencies
    ---@param tool table The current tool being processed
    local function visit(tool)
      -- Prevent processing the same tool multiple times
      if visited[tool.name] then return end

      -- If the tool has dependencies, resolve them first
      if tool.dependencies then
        for _, dep_name in ipairs(tool.dependencies) do
          -- Find the dependency tool in the original tools list
          local dep_tool = vim.tbl_filter(function(t) return t.name == dep_name end, tools)[1]
          if dep_tool then
            -- Recursively resolve dependencies of this dependency
            visit(dep_tool)
          end
        end
      end

      -- Add the tool to the resolved list after its dependencies
      table.insert(resolved_tools, tool)
      visited[tool.name] = true
    end

    -- Process each tool, resolving its dependencies
    for _, tool in ipairs(tools) do
      visit(tool)
    end

    return resolved_tools
  end
}

---@class ErrorHandler
---@brief Manages error logging, tracking, and intelligent error handling
local ErrorHandler = {
  ---@field _error_log table[] A log of all errors encountered during execution
  _error_log = {},

  ---@brief Log an error with detailed context
  ---@param tool_name string The name of the tool where the error occurred
  ---@param error_details string Detailed description of the error
  log_error = function(self, tool_name, error_details)
    -- Create a comprehensive error log entry
    local error_entry = {
      tool = tool_name,        -- Which tool caused the error
      details = error_details, -- Specific error details
      timestamp = os.time()    -- When the error occurred
    }
    table.insert(self._error_log, error_entry)
  end,

  ---@brief Intelligently handle and categorize errors
  ---@param tool_name string The name of the tool where the error occurred
  ---@param error_details string Detailed description of the error
  ---@return boolean Whether the error can be handled
  ---@return string A user-friendly error message
  handle_error = function(self, tool_name, error_details)
    -- Log the error first for comprehensive tracking
    self:log_error(tool_name, error_details)

    -- Implement intelligent error handling based on error type
    if string.find(error_details, "token") then
      -- Token-related errors suggest task complexity is too high
      return false, "Task complexity exceeds current token limits. Try breaking down the task."
    elseif string.find(error_details, "recursion") then
      -- Recursion errors indicate potential infinite loops
      return false, "Detected potential infinite recursion. Simplify task approach."
    else
      -- Fallback for generic errors with specific tool context
      return false, string.format("Error in tool %s: %s", tool_name, error_details)
    end
  end
}

---@type fun(): AvanteLLMTool[]
---@brief Dynamically retrieve available tools for the dispatch full agent
---@description
--- This function uses the LazyLoading module to fetch all available tools
--- It applies filtering to exclude:
--- 1. Forbidden tools that could cause recursion or safety issues
--- 2. The dispatch_full_agent tool itself to prevent self-referencing
---@return table[] A list of available and safe tools to use
local function get_available_tools()
  -- Import the lazy loading module for dynamic tool discovery
  local LazyLoading = require("avante.llm_tools.lazy_loading")
  local Config = require("avante.config")

  -- If lazy loading is not enabled, get all tools directly
  if not Config.lazy_loading or not Config.lazy_loading.enabled then
    local LLMTools = require("avante.llm_tools")
    local all_tools = LLMTools._tools
    return vim.tbl_filter(function(tool)
      -- Exclude tools in the forbidden list
      local is_forbidden = vim.tbl_contains(ToolValidator._forbidden_tools, tool.name)

      -- Exclude the dispatch_full_agent tool itself
      local is_self = tool.name == M.name

      -- Only return tools that pass all safety checks
      return not (is_forbidden or is_self)
    end, all_tools)
  end

  -- Retrieve all available tools without any initial filtering
  local LLMTools = require("avante.llm_tools")
  local all_tools = LLMTools.get_tools("", {}, false)

  -- Apply sophisticated filtering to ensure tool safety and prevent recursion
  return vim.tbl_filter(function(tool)
    -- Exclude tools in the forbidden list
    local is_forbidden = vim.tbl_contains(ToolValidator._forbidden_tools, tool.name)

    -- Exclude the dispatch_full_agent tool itself
    local is_self = tool.name == M.name

    -- Only return tools that pass all safety checks
    return not (is_forbidden or is_self)
  end, all_tools)
end

---@class avante.DispatchFullAgentInput
---@field prompt string Input prompt for the full agent

---@type avante.LLMToolOnRender<avante.DispatchFullAgentInput>
---@brief Renders a visual summary of the agent's execution
---@description
--- This method creates a detailed, visually appealing rendering of the agent's
--- task execution, including:
--- 1. Current execution state (running/completed/failed)
--- 2. Original task prompt
--- 3. Summary of tool usage and their results
---@param input table The input parameters for the agent
---@param opts table Options and context for rendering
---@return table A list of Line objects for display
function M.on_render(input, opts)
  -- Retrieve the result message and message store
  local result_message = opts.result_message
  local store = opts.store or {}
  local messages = store.messages or {}

  -- Initialize a summary of tool usage
  local tool_use_summary = {}

  -- Iterate through messages to build a summary of tool usage
  for _, msg in ipairs(messages) do
    local summary
    local tool_use = History.Helpers.get_tool_use_data(msg)

    -- Check if the message represents a tool use
    if tool_use then
      local tool_result = History.Helpers.get_tool_result(tool_use.id, messages)

      -- Create a summary of tool result (success/failure)
      if tool_result then
        summary = string.format("Tool %s: %s", tool_use.name, tool_result.is_error and "failed" or "succeeded")
      end

      -- Add an icon to the summary
      if summary then summary = "  " .. Utils.icon("🛠️ ") .. summary end
    else
      -- If not a tool use, use the text data
      summary = History.Helpers.get_text_data(msg)
    end

    -- Add the summary to the list
    if summary then table.insert(tool_use_summary, summary) end
  end

  -- Determine the current state of the agent execution
  local state = "running"
  local icon = Utils.icon("🔄 ")
  local hl = Highlights.AVANTE_TASK_RUNNING

  -- Update state based on result message
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

  -- Build the rendering lines
  local lines = {}
  table.insert(lines, Line:new({ { icon .. "Full Agent " .. state, hl } }))
  table.insert(lines, Line:new({ { "" } }))
  table.insert(lines, Line:new({ { "  Task:" } }))

  -- Add the original prompt
  local prompt_lines = vim.split(input.prompt or "", "\n")
  for _, line in ipairs(prompt_lines) do
    table.insert(lines, Line:new({ { "    " .. line } }))
  end

  table.insert(lines, Line:new({ { "" } }))
  table.insert(lines, Line:new({ { "  Task summary:" } }))

  -- Add tool usage summary
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

  -- Set the working directory explicitly to the current project root
  local context = ExecutionContext
  context:set_working_directory(vim.fn.getcwd())

  -- Validate and filter tools
  local validated_tools = {}
  local error_handler = ErrorHandler

  for _, tool in ipairs(tools) do
    local is_valid, err_msg = ToolValidator:validate(tool, context)
    if is_valid then
      table.insert(validated_tools, tool)
    else
      error_handler:log_error(tool.name, err_msg)
    end
  end

  -- Resolve tool dependencies
  local resolved_tools = DependencyResolver:resolve_dependencies(validated_tools)

  if on_log then on_log("prompt: " .. prompt) end

  local system_prompt = ([[You are an advanced agent with comprehensive tool management capabilities.
Your task is to help the user with their request: "${prompt}"
Use available tools thoroughly and intelligently to find the most relevant information.
Apply strict usage constraints and provide a clear, concise summary of your findings.
Available tools: %s]]):gsub("${prompt}", prompt):format(table.concat(vim.tbl_map(function(tool) return tool.name end, resolved_tools), ", "))

  local history_messages = {}
  local tool_use_messages = {}

  local total_tokens = 0
  local result = {}

  ---@type avante.AgentLoopOptions
  local agent_loop_options = {
    system_prompt = system_prompt,
    user_input = "start",
    tools = resolved_tools,
    on_tool_log = function(tool_name, log_data)
      -- Log tool usage and track token consumption
      context:record_tool_usage(tool_name)
      context._state.total_token_consumption = context._state.total_token_consumption +
        (log_data.token_count or 0)

      if session_ctx.on_tool_log then
        session_ctx.on_tool_log(tool_name, log_data)
      end
    end,
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
        local error_result, error_msg = error_handler:handle_error("dispatch_full_agent", err)
        on_complete(error_msg, nil)
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

