local Path = require("plenary.path")
local Utils = require("avante.utils")
local Helpers = require("avante.llm_tools.helpers")
local Base = require("avante.llm_tools.base")
local Config = require("avante.config")

---@class IntelligentRebaseContext
---@field source_branch string
---@field target_branch string
---@field current_attempt integer
---@field max_attempts integer
---@field conflict_files string[]
---@field resolution_logs table[]
---@field initial_head string

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "intelligent_rebase"

M.get_description = function()
  return [[Intelligent Git Rebase Tool: Automate and enhance git rebasing with AI-powered conflict resolution.

Features:
- Automatic conflict detection
- Contextual conflict resolution
- Multiple resolution attempts
- Safety validation
- Comprehensive logging

Key Capabilities:
1. Detect merge conflicts during rebase
2. Analyze code context for intelligent resolution
3. Apply safe, context-aware conflict resolution strategies
4. Provide detailed resolution logs
5. Limit maximum resolution attempts to prevent infinite loops

When to Use:
- Complex rebasing scenarios with multiple conflicts
- Projects requiring nuanced conflict resolution
- Situations where manual intervention is time-consuming

Important Notes:
- Always review changes before finalizing
- Provides detailed logs for transparency
- Prioritizes code integrity and original intent]]
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "source_branch",
      description = "The branch to be rebased",
      type = "string",
    },
    {
      name = "target_branch",
      description = "The branch to rebase onto",
      type = "string",
    },
    {
      name = "max_attempts",
      description = "Maximum number of resolution attempts (default: 3)",
      type = "number",
      optional = true,
    },
  },
  usage = {
    source_branch = "Name of the source branch to rebase",
    target_branch = "Name of the target branch to rebase onto",
    max_attempts = "Optional maximum number of resolution attempts",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "Whether the rebase was successful",
    type = "boolean",
  },
  {
    name = "resolution_logs",
    description = "Detailed logs of the rebase process and conflict resolutions",
    type = "table",
  },
  {
    name = "error",
    description = "Error message if the rebase failed",
    type = "string",
    optional = true,
  },
}

---@brief Safely sanitize branch name to prevent shell injection
---@param branch string
---@return string
local function sanitize_branch_name(branch)
  return branch:gsub("[^a-zA-Z0-9_/-]", "")
end

---@brief Validate input branches and check for uncommitted changes
---@param source_branch string
---@param target_branch string
---@param max_attempts? integer
---@return IntelligentRebaseContext | nil, string | nil
local function initialize_rebase(source_branch, target_branch, max_attempts)
  -- Validate input parameters
  if not source_branch or type(source_branch) ~= "string" or source_branch:match("^%s*$") then
    return nil, "Invalid source branch name. Must be a non-empty string."
  end

  if not target_branch or type(target_branch) ~= "string" or target_branch:match("^%s*$") then
    return nil, "Invalid target branch name. Must be a non-empty string."
  end

  -- Validate max attempts
  max_attempts = max_attempts or 3
  if type(max_attempts) ~= "number" or max_attempts < 1 or max_attempts > 10 then
    return nil, "Invalid max_attempts. Must be a number between 1 and 10."
  end

  -- Validate branches exist
  local function branch_exists(branch)
    local sanitized = sanitize_branch_name(branch)
    local result = vim.fn.system(string.format("git rev-parse --verify %q 2>/dev/null", sanitized))
    return vim.v.shell_error == 0
  end

  local sanitized_source = sanitize_branch_name(source_branch)
  local sanitized_target = sanitize_branch_name(target_branch)

  if not branch_exists(sanitized_source) then
    return nil, string.format("Source branch '%s' does not exist", sanitized_source)
  end

  if not branch_exists(sanitized_target) then
    return nil, string.format("Target branch '%s' does not exist", sanitized_target)
  end

  -- Check for uncommitted changes with enhanced safety
  local status_result = vim.fn.system("git status --porcelain")
  if status_result ~= "" then
    return nil, "Uncommitted changes exist. Please commit or stash changes before rebasing."
  end

  -- Verify git repository integrity
  local repo_check = vim.fn.system("git rev-parse --is-inside-work-tree 2>/dev/null")
  if vim.v.shell_error ~= 0 then
    return nil, "Not inside a git repository or repository is corrupted."
  end

  return {
    source_branch = sanitized_source,
    target_branch = sanitized_target,
    current_attempt = 0,
    max_attempts = max_attempts,
    conflict_files = {},
    resolution_logs = {},
    initial_head = vim.fn.system("git rev-parse HEAD"):gsub("\n", "") -- Track initial HEAD for potential rollback
  }, nil
end

---@brief Safely check if a file is binary
---@param file string Path to the file
---@return boolean
local function is_binary_file(file)
  local result = vim.fn.system(string.format("file -b --mime-type %q", file))
  return result:match("binary") ~= nil
end

---@brief Detect conflicts during rebase with enhanced safety checks
---@param context IntelligentRebaseContext
---@return boolean, string | nil
local function detect_conflicts(context)
  -- Start the rebase process with enhanced error handling
  local rebase_result = vim.fn.system(string.format("git rebase %s %s 2>&1",
    context.target_branch,
    context.source_branch
  ))

  -- Check if rebase encountered conflicts
  if vim.v.shell_error ~= 0 then
    -- Identify conflict files with additional filtering
    local conflict_files = vim.fn.systemlist("git diff --name-only --diff-filter=U")
    local safe_conflict_files = {}

    -- Filter out binary files and problematic files
    for _, file in ipairs(conflict_files) do
      -- Skip binary files and files outside the repository
      if not is_binary_file(file) and
         file:match("^[%w_.-/]+$") and  -- Basic path safety check
         not file:match("%.lock$") then -- Avoid lock files
        table.insert(safe_conflict_files, file)
      end
    end

    if #safe_conflict_files > 0 then
      context.conflict_files = safe_conflict_files
      table.insert(context.resolution_logs, {
        type = "conflict_detected",
        files = safe_conflict_files,
        timestamp = os.time(),
        raw_rebase_output = rebase_result
      })

      return true, nil
    else
      return false, "Rebase failed without clear conflict information: " .. rebase_result
    end
  end

  return false, nil
end

---@brief Resolve conflicts using AI-powered strategies with enhanced safety
---@param context IntelligentRebaseContext
---@return boolean, string | nil
local function resolve_conflicts(context)
  context.current_attempt = context.current_attempt + 1

  if context.current_attempt > context.max_attempts then
    return false, "Maximum resolution attempts exceeded"
  end

  local resolution_errors = {}

  for _, conflict_file in ipairs(context.conflict_files) do
    -- Validate file before attempting resolution
    if not vim.fn.filereadable(conflict_file) then
      table.insert(resolution_errors, {
        file = conflict_file,
        error = "File is not readable"
      })
      goto continue
    end

    -- Use dispatch_full_agent to analyze and resolve conflicts
    local agent_result, agent_error = require("avante.llm_tools.dispatch_full_agent").func({
      prompt = string.format(
        "Analyze and resolve git merge conflict in file: %s\n" ..
        "Provide a resolution strategy that preserves code intent and minimizes changes.\n" ..
        "Include reasoning and proposed code changes.\n" ..
        "CRITICAL SAFETY INSTRUCTIONS:\n" ..
        "1. Do not modify binary files\n" ..
        "2. Preserve original code structure and intent\n" ..
        "3. Minimize changes\n" ..
        "4. Avoid introducing new syntax errors\n" ..
        "5. Maintain existing code style and formatting",
        conflict_file
      )
    })

    if agent_error then
      table.insert(resolution_errors, {
        file = conflict_file,
        error = agent_error
      })
    else
      -- Apply the resolution with safety checks
      local apply_result = vim.fn.system(string.format("git add %q", conflict_file))

      if vim.v.shell_error ~= 0 then
        table.insert(resolution_errors, {
          file = conflict_file,
          error = "Failed to stage resolved file: " .. apply_result
        })
      end
    end

    ::continue::
  end

  if #resolution_errors > 0 then
    table.insert(context.resolution_logs, {
      type = "partial_resolution_failure",
      errors = resolution_errors,
      timestamp = os.time()
    })
    return false, "Some conflicts could not be resolved automatically"
  end

  -- Continue the rebase with error handling
  local continue_result = vim.fn.system("git rebase --continue")

  if vim.v.shell_error ~= 0 then
    return false, "Failed to continue rebase: " .. continue_result
  end

  table.insert(context.resolution_logs, {
    type = "conflicts_resolved",
    attempt = context.current_attempt,
    timestamp = os.time()
  })

  return true, nil
end

---@brief Rollback to the initial state if rebase fails
---@param context IntelligentRebaseContext
---@return boolean
local function safe_rollback(context)
  -- Reset to the initial HEAD to undo any partial rebase
  local reset_result = vim.fn.system(string.format("git reset --hard %q", context.initial_head))

  table.insert(context.resolution_logs, {
    type = "rollback",
    initial_head = context.initial_head,
    timestamp = os.time(),
    success = vim.v.shell_error == 0
  })

  return vim.v.shell_error == 0
end

---@type AvanteLLMToolFunc<{ source_branch: string, target_branch: string, max_attempts?: integer }>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete

  if not on_complete then
    return false, "on_complete callback is required"
  end

  local context, init_err = initialize_rebase(
    input.source_branch,
    input.target_branch,
    input.max_attempts
  )

  if init_err then
    on_complete(false, {}, { error = init_err })
    return
  end

  local function attempt_rebase()
    local has_conflicts, conflict_err = detect_conflicts(context)

    if conflict_err then
      safe_rollback(context)
      on_complete(false, context.resolution_logs, { error = conflict_err })
      return
    end

    if not has_conflicts then
      on_complete(true, context.resolution_logs, nil)
      return
    end

    local resolution_success, resolution_err = resolve_conflicts(context)

    if resolution_success then
      on_complete(true, context.resolution_logs, nil)
    elseif context.current_attempt < context.max_attempts then
      -- Retry rebase if max attempts not reached
      attempt_rebase()
    else
      safe_rollback(context)
      on_complete(false, context.resolution_logs, {
        error = resolution_err or "Failed to resolve conflicts"
      })
    end
  end

  -- Start the rebase process
  attempt_rebase()
end

return M

