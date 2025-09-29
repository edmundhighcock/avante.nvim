local Path = require("plenary.path")
local Utils = require("avante.utils")
local Helpers = require("avante.llm_tools.helpers")
local Base = require("avante.llm_tools.base")
local Config = require("avante.config")
local History = require("avante.history")

---@class RebaseUpdateLog
---@field stage string Current stage of rebase (e.g., "initializing", "detecting_conflicts", "resolving_conflicts")
---@field details string Detailed description of current action
---@field progress number Percentage of completion (0-100)
---@field files string[] Files currently being processed
---@field errors string[] Any errors encountered

---@class IntelligentRebaseContext
---@field source_branch string
---@field target_branch string
---@field current_attempt integer
---@field max_attempts integer
---@field conflict_files string[]
---@field resolution_logs table[]
---@field initial_head string
---@field on_log? fun(update: {type: string, data: RebaseUpdateLog}): nil
---@field on_messages_add? fun(messages: any[]): nil
---@field on_state_change? fun(state: string): nil
---@field history_messages table[]
---@field current_state string
---@field pending_operations integer Number of pending async operations
---@field has_completed boolean Whether the final completion has been signaled

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "intelligent_rebase"

M.get_description = function()
  return [[Intelligent Git Rebase Tool: Automate and enhance git rebasing with AI-powered conflict resolution.

Features:
- Real-time rebase stage updates
- Detailed conflict detection and resolution logging
- Granular progress tracking
- Multiple resolution attempts
- Safety validation
- Comprehensive logging

Key Capabilities:
1. Start or continue a git rebase operation
2. Detect merge conflicts during rebase
3. Provide detailed resolution logs with stage updates
4. Instruct the LLM to call the resolve_git_conflicts tool when conflicts are detected
5. Continue the rebase process after conflicts are resolved

Workflow:
1. Call intelligent_rebase with source and target branches to start a rebase
2. If conflicts are detected, the tool returns with next_action="resolve_conflicts"
3. Call resolve_git_conflicts with the provided conflict_files
4. Call intelligent_rebase again with continue=true to continue the rebase
5. Repeat steps 2-4 until the rebase is complete (next_action="done")

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
    {
      name = "continue",
      description = "Continue an existing rebase in progress without re-initializing",
      type = "boolean",
      optional = true,
    },
  },
  usage = {
    source_branch = "Name of the source branch to rebase",
    target_branch = "Name of the target branch to rebase onto",
    max_attempts = "Optional maximum number of resolution attempts",
    continue = "Optional flag to continue an existing rebase without re-initializing",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "Whether the rebase was successful or needs further action",
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
  {
    name = "next_action",
    description = "Instructions for the next action the LLM should take (e.g., 'resolve_conflicts', 'continue_rebase', 'done')",
    type = "string",
    optional = true,
  },
  {
    name = "conflict_files",
    description = "List of files with conflicts that need resolution",
    type = "table",
    optional = true,
  },
}

---@brief Track a new asynchronous operation
---@param context IntelligentRebaseContext
local function track_operation(context)
  if not context then return end
  context.pending_operations = (context.pending_operations or 0) + 1
  if context.on_log then
    pcall(context.on_log, {
      type = "operation_tracking",
      data = { action = "start", count = context.pending_operations }
    })
  end
end

---@brief Complete an asynchronous operation and check if all operations are complete
---@param context IntelligentRebaseContext
---@param on_complete function Optional callback to call when all operations are complete
---@param success boolean Whether the operation was successful
---@param error string|nil Error message if the operation failed
local function complete_operation(context, on_complete, success, error)
  if not context then return end

  -- Decrement the pending operations counter
  context.pending_operations = math.max(0, (context.pending_operations or 0) - 1)

  if context.on_log then
    pcall(context.on_log, {
      type = "operation_tracking",
      data = { action = "complete", count = context.pending_operations }
    })
  end

  -- Check if all operations are complete and we haven't already signaled completion
  if context.pending_operations == 0 and not context.has_completed and on_complete then
    context.has_completed = true
    pcall(on_complete, success, error)
  end
end

---@brief Check if all operations are complete and signal completion if they are
---@param context IntelligentRebaseContext
---@param on_complete function Optional callback to call when all operations are complete
---@param success boolean Whether the operation was successful
---@param error string|nil Error message if the operation failed
local function check_completion(context, on_complete, success, error)
  if not context then return end

  -- If there are no pending operations and we haven't already signaled completion
  if context.pending_operations == 0 and not context.has_completed and on_complete then
    context.has_completed = true
    pcall(on_complete, success, error)
  end
end

---@brief Log rebase update with stage, details, and progress
---@param context IntelligentRebaseContext
---@param update RebaseUpdateLog
local function log_rebase_update(context, update)
  -- Ensure context.history_messages is initialized
  context.history_messages = context.history_messages or {}

  -- Add update to context's resolution_logs
  table.insert(context.resolution_logs, {
    timestamp = os.time(),
    stage = update.stage,
    details = update.details,
    progress = update.progress,
    files = update.files or {},
    errors = update.errors or {}
  })

  -- Prepare a detailed, user-friendly message with emoji, timestamp, and clear formatting
  local message_content = string.format(
    "🔄 Intelligent Rebase Update [%s]\n- Stage: %s\n- Details: %s\n- Progress: %d%%\n%s",
    os.date("%H:%M:%S"),  -- Add timestamp for more distinct updates
    update.stage,
    update.details,
    update.progress,
    update.errors and #update.errors > 0 and "- Errors: " .. table.concat(update.errors, ", ") or ""
  )

  -- Always create a history message to ensure sidebar updates
  local history_message = History.Message:new("assistant", message_content, {
    just_for_display = true,
    state = update.stage,
    tool_use_store = {
      name = "intelligent_rebase",
      stage = update.stage,
      progress = update.progress or 0
    }
  })

  -- Store the current state in the context
  context.current_state = update.stage

  -- Add message to history messages
  table.insert(context.history_messages, history_message)

  -- Notify via on_log callback for real-time updates
  if context.on_log then
    pcall(context.on_log, {
      type = "rebase_update",
      data = update
    })
  end

  -- Support on_messages_add callback for incremental history updates
  if context.on_messages_add then
    pcall(context.on_messages_add, { history_message })

    -- Force a redraw to ensure UI updates
    vim.schedule(function()
      vim.cmd("redraw")
    end)
  end

  -- Support on_state_change callback for updating the state in the sidebar
  if context.on_state_change then
    pcall(context.on_state_change, update.stage)
  end
end

---@brief Safely sanitize branch name to prevent shell injection
---@param branch string
---@return string
local function sanitize_branch_name(branch)
  return branch:gsub("[^a-zA-Z0-9_/-]", "")
end

---@brief Check if a branch exists
---@param branch string Name of the branch to check
---@return boolean
local function check_branch_exists(branch)
  local sanitized = sanitize_branch_name(branch)
  local result = vim.fn.system(string.format("git rev-parse --verify %q 2>/dev/null", sanitized))
  return vim.v.shell_error == 0
end

---@brief Check for non-empty tracked changes in the repository
---@return boolean
local function check_non_empty_tracked_changes()
  local status_output = vim.fn.systemlist("git status --porcelain")
  for _, line in ipairs(status_output) do
    -- Ignore untracked directories or files
    if not line:match("^%?%?") then
      -- Check if the change is not just an empty directory
      local file = line:match("^%s*[AMDR]%s+(.+)$")
      if file then
        if not file:match("/$") then  -- Not an empty directory
          return true
        end
      end
    end
  end
  return false
end

---@brief Validate input branches and check for uncommitted changes
---@param source_branch string
---@param target_branch string
---@param max_attempts? integer
---@return IntelligentRebaseContext | nil, string | nil
local function initialize_rebase(source_branch, target_branch, max_attempts)
  -- Set default max_attempts if not provided or ensure it's a number
  local max_attempts_value = 3
  if max_attempts ~= nil then
    if type(max_attempts) ~= "number" or max_attempts < 1 or max_attempts > 10 then
      return nil, "Invalid max_attempts. Must be a number between 1 and 10."
    end
    max_attempts_value = max_attempts
  end

  local context = {
    source_branch = sanitize_branch_name(source_branch),
    target_branch = sanitize_branch_name(target_branch),
    current_attempt = 0,
    max_attempts = max_attempts_value,
    conflict_files = {},
    resolution_logs = {},
    initial_head = vim.fn.system("git rev-parse HEAD"):gsub("\n", ""),
    current_state = "initializing" -- Initialize state
  }

  log_rebase_update(context, {
    stage = "initializing",
    details = string.format("Preparing to rebase %s onto %s", context.source_branch, context.target_branch),
    progress = 10,
  })

  -- Validate input parameters
  if not source_branch or type(source_branch) ~= "string" or source_branch:match("^%s*$") then
    return nil, "Invalid source branch name. Must be a non-empty string."
  end

  if not target_branch or type(target_branch) ~= "string" or target_branch:match("^%s*$") then
    return nil, "Invalid target branch name. Must be a non-empty string."
  end

  -- Use the module-level functions for validation

  if not check_branch_exists(context.source_branch) then
    return nil, string.format("Source branch '%s' does not exist", context.source_branch)
  end

  if not check_branch_exists(context.target_branch) then
    return nil, string.format("Target branch '%s' does not exist", context.target_branch)
  end

  -- Check for uncommitted changes, but allow empty directory changes
  if check_non_empty_tracked_changes() then
    return nil, "Uncommitted changes exist. Please commit or stash changes before rebasing."
  end

  -- Verify git repository integrity
  local repo_check = vim.fn.system("git rev-parse --is-inside-work-tree 2>/dev/null")
  if vim.v.shell_error ~= 0 then
    return nil, "Not inside a git repository or repository is corrupted."
  end

  log_rebase_update(context, {
    stage = "initializing",
    details = "Rebase context successfully initialized",
    progress = 25,
  })

  return context, nil
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
  log_rebase_update(context, {
    stage = "detecting_conflicts",
    details = "Scanning repository for merge conflicts",
    progress = 50,
  })

  -- Set GIT_EDITOR to prevent interactive editor sessions
  local old_git_editor = vim.fn.getenv("GIT_EDITOR")
  vim.fn.setenv("GIT_EDITOR", ":")

  -- Start the rebase process with enhanced error handling
  local rebase_result = vim.fn.system(string.format("git rebase %s %s 2>&1",
    context.target_branch,
    context.source_branch
  ))

  -- Restore original GIT_EDITOR
  if old_git_editor ~= "" then
    vim.fn.setenv("GIT_EDITOR", old_git_editor)
  else
    vim.fn.unsetenv("GIT_EDITOR")
  end

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

      log_rebase_update(context, {
        stage = "detecting_conflicts",
        details = string.format("Found %d conflict(s)", #safe_conflict_files),
        progress = 75,
        files = safe_conflict_files
      })

      return true, nil
    else
      log_rebase_update(context, {
        stage = "detecting_conflicts",
        details = "Rebase failed without clear conflict information",
        progress = 100,
        errors = { rebase_result }
      })
      return false, "Rebase failed without clear conflict information: " .. rebase_result
    end
  end

  log_rebase_update(context, {
    stage = "detecting_conflicts",
    details = "No conflicts detected",
    progress = 100
  })

  return false, nil
end

-- Function removed - now handled by resolve_git_conflicts tool

-- Function removed - now handled by resolve_git_conflicts tool

---@brief Continue the rebase process after resolving conflicts
---@param context IntelligentRebaseContext The rebase context
---@param opts table Options for the rebase process
---@param on_complete function Callback function for completion
local function continue_rebase_process(context, opts, on_complete)
  -- Attempt to continue the rebase
  local continue_result = vim.fn.system("git rebase --continue 2>&1")

  -- Check if the rebase is already in progress
  local rebase_in_progress = vim.fn.system("git rev-parse --git-path rebase-merge 2>/dev/null || git rev-parse --git-path rebase-apply 2>/dev/null")
  local is_rebasing = vim.v.shell_error == 0 and rebase_in_progress ~= ""

  -- If not rebasing anymore, check if it completed successfully
  if not is_rebasing then
    log_rebase_update(context, {
      stage = "completed",
      details = "Rebase completed successfully",
      progress = 100
    })

    return on_complete(true, nil, "done", nil)
  end

  -- Detect conflicts in the current rebase state
  local has_conflicts, conflict_err = detect_conflicts(context)

  -- Handle unexpected errors during conflict detection
  if conflict_err then
    log_rebase_update(context, {
      stage = "error",
      details = "Error during rebase: " .. conflict_err,
      progress = 100,
      errors = { conflict_err }
    })

    return on_complete(false, conflict_err, nil, nil)
  end

  -- If no conflicts, rebase is successful
  if not has_conflicts then
    log_rebase_update(context, {
      stage = "completed",
      details = "Rebase completed successfully",
      progress = 100
    })

    return on_complete(true, nil, "done", nil)
  end

  -- Reset attempt counter for this set of conflicts
  context.current_attempt = 0

  -- Log that conflicts were detected
  log_rebase_update(context, {
    stage = "conflicts_detected",
    details = "Conflicts detected during rebase. LLM should call resolve_git_conflicts tool.",
    progress = 50,
    files = context.conflict_files
  })

  -- Return with instructions to call resolve_git_conflicts
  return on_complete(false, nil, "resolve_conflicts", context.conflict_files)
end

-- Function removed - now handled by resolve_git_conflicts tool

-- Function removed - now handled by resolve_git_conflicts tool

---@brief Rollback to the initial state if rebase fails
---@param context IntelligentRebaseContext
---@return boolean
local function safe_rollback(context)
  log_rebase_update(context, {
    stage = "rollback",
    details = "Reverting changes due to unresolvable conflicts",
    progress = 25,
    errors = {"Rebase failed, rolling back to initial state"}
  })

  -- Reset to the initial HEAD to undo any partial rebase
  local reset_result = vim.fn.system(string.format("git reset --hard %q", context.initial_head))

  log_rebase_update(context, {
    stage = "rollback",
    details = "Rebase rollback completed",
    progress = 100,
    errors = reset_result:match("fatal:") and { reset_result } or nil
  })

  return vim.v.shell_error == 0
end

---@brief Handle final cleanup and completion of the rebase process
---@param context IntelligentRebaseContext The rebase context
---@param success boolean Whether the rebase was successful
---@param error string|nil Error message if the rebase failed
---@param old_git_editor string|nil Original GIT_EDITOR environment variable
---@param is_success boolean Reference to the is_success variable in the main function
---@param final_error any Reference to the final_error variable in the main function
---@param resolution_logs table Reference to the resolution_logs variable in the main function
---@param on_state_change function|nil Callback to update the state in the UI
---@param on_messages_add function|nil Callback to add messages to the UI
local function finalize_rebase(context, success, error, old_git_editor, is_success, final_error, resolution_logs, on_state_change, on_messages_add)
  -- Only execute if we haven't already completed
  if context.has_completed then return end

  -- Mark as completed to prevent further calls
  context.has_completed = true

  -- Set the final results
  is_success = success
  final_error = error
  resolution_logs = context.resolution_logs

  -- If rebase was not successful, rollback
  if not is_success then
    safe_rollback(context)
  end

  -- Restore original GIT_EDITOR environment variable
  if old_git_editor ~= "" then
    vim.fn.setenv("GIT_EDITOR", old_git_editor)
  else
    vim.fn.unsetenv("GIT_EDITOR")
  end

  local final_history_messages = context.history_messages or {}

  -- Ensure final_error is converted to a string
  local error_message = "Unknown error"
  if final_error ~= nil then
    error_message = type(final_error) == "string" and final_error or
    (type(final_error) == "table" and vim.inspect(final_error) or tostring(final_error))
  end

  -- Update final state
  local final_state = is_success and "succeeded" or "failed"
  if on_state_change then
    pcall(on_state_change, final_state)
  end

  -- Generate a retry statistics summary
  local retry_stats = {}
  if context.file_attempt_counters then
    local total_retries = 0
    local files_with_retries = 0
    local max_retries_for_file = 0

    for file, attempts in pairs(context.file_attempt_counters) do
      if attempts > 0 then
        total_retries = total_retries + attempts
        files_with_retries = files_with_retries + 1
        max_retries_for_file = math.max(max_retries_for_file, attempts)
      end
    end

    if files_with_retries > 0 then
      retry_stats = {
        string.format("Files requiring retries: %d", files_with_retries),
        string.format("Total retry attempts: %d", total_retries),
        string.format("Maximum retries for a single file: %d", max_retries_for_file),
        string.format("Average retries per file: %.1f", total_retries / files_with_retries)
      }
    end
  end

  -- Create final status message with appropriate state and retry statistics
  local final_message
  if final_error then
    local message_text = "Rebase Failed: " .. error_message

    -- Add retry statistics if available
    if #retry_stats > 0 then
      message_text = message_text .. "\n\nRetry Statistics:\n- " .. table.concat(retry_stats, "\n- ")
    end

    final_message = History.Message:new("assistant",
      message_text,
      { just_for_display = true, state = "failed" }
    )
  else
    local message_text = "Rebase Completed Successfully"

    -- Add retry statistics if available
    if #retry_stats > 0 then
      message_text = message_text .. "\n\nRetry Statistics:\n- " .. table.concat(retry_stats, "\n- ")
    end

    final_message = History.Message:new("assistant",
      message_text,
      { just_for_display = true, state = "succeeded" }
    )
  end

  -- Add final message to history messages
  table.insert(final_history_messages, final_message)

  -- If on_messages_add is provided, use it to add history messages
  if on_messages_add then
    -- Use pcall to handle potential errors
    pcall(function()
      on_messages_add(final_history_messages)
    end)
  end

  -- Call the original on_complete with the results
  pcall(function()
    context.main_complete_callback(is_success, final_error and error_message or nil)
  end)
end

-- Function removed - now handled by LLM calling resolve_git_conflicts directly

---@type AvanteLLMToolFunc<{ source_branch: string, target_branch: string, max_attempts?: integer, continue?: boolean }>
---@brief Intelligent git rebase tool that instructs the LLM to handle conflicts
---@param input { source_branch: string, target_branch: string, max_attempts?: integer, continue?: boolean } Input parameters
---@param opts table Options for the tool
---@return { success: boolean, error?: string, resolution_logs: table, next_action?: string, conflict_files?: table } Tool results
--- The next_action field will be one of:
--- - "resolve_conflicts": LLM should call resolve_git_conflicts with the provided conflict_files
--- - "done": Rebase completed successfully
--- - "processing": Tool is still running and will return final result through callback
function M.func(input, opts)
  opts = opts or {}
  local on_log = opts.on_log
  -- Ensure on_complete is always a function, even if not provided
  local on_complete = opts.on_complete or function() end
  local on_messages_add = opts.on_messages_add
  local on_state_change = opts.on_state_change
  local session_ctx = opts.session_ctx

  -- Track the overall result and error state
  local is_success = false
  local resolution_logs = {}
  local final_error = nil
  local next_action = nil
  local conflict_files = {}

  -- If continue is true, skip initialization
  local context
  if input.continue then
    context = {
      source_branch = input.source_branch,
      target_branch = input.target_branch,
      current_attempt = 0,
      max_attempts = input.max_attempts or 3,
      conflict_files = {},
      resolution_logs = {},
      initial_head = vim.fn.system("git rev-parse HEAD"):gsub("\n", ""),
      current_state = "continuing",
      pending_operations = 0, -- Initialize pending operations counter
      has_completed = false   -- Initialize completion flag
    }

    log_rebase_update(context, {
      stage = "continuing",
      details = "Continuing an existing rebase in progress",
      progress = 50,
    })
  else
    local init_err
    context, init_err = initialize_rebase(
      input.source_branch,
      input.target_branch,
      input.max_attempts
    )

    if init_err then
      is_success = false
      final_error = init_err
      resolution_logs = {}

      -- Convert error to string to prevent concatenation issues
      local error_str = "Unknown error"
      if type(init_err) == "table" then
        error_str = vim.inspect(init_err)
      elseif init_err ~= nil then
        error_str = tostring(init_err)
      end

      -- Update state to failed
      if on_state_change then
        pcall(on_state_change, "failed")
      end

      -- Create error message
      local history_message = History.Message:new("assistant",
        "Rebase Initialization Failed: " .. error_str,
        { just_for_display = true, state = "failed" }
      )

      -- Add message to sidebar
      if on_messages_add then
        pcall(function()
          on_messages_add({ history_message })
        end)
      end

      -- Return synchronously with error information
      return {
        success = false,
        error = error_str,
        resolution_logs = {}
      }
    end
  end

  -- Add on_log, on_messages_add, and on_state_change callbacks to context for updates
  context.on_log = on_log
  context.on_messages_add = on_messages_add
  context.on_state_change = on_state_change
  context.history_messages = {}

  -- Set GIT_EDITOR to prevent interactive editor sessions for all Git commands
  local old_git_editor = vim.fn.getenv("GIT_EDITOR")
  vim.fn.setenv("GIT_EDITOR", ":")

  -- Callback to handle completion
  local function handle_completion(success, error, action, files)
    -- Restore original GIT_EDITOR environment variable
    if old_git_editor ~= "" then
      vim.fn.setenv("GIT_EDITOR", old_git_editor)
    else
      vim.fn.unsetenv("GIT_EDITOR")
    end

    -- Set return values
    is_success = success
    final_error = error
    next_action = action
    conflict_files = files or {}
    resolution_logs = context.resolution_logs or {}

    -- Return synchronously with the appropriate information
    if on_complete then
      on_complete({
        success = is_success,
        error = final_error,
        resolution_logs = resolution_logs,
        next_action = next_action,
        conflict_files = conflict_files
      })
    end

    return {
      success = is_success,
      error = final_error,
      resolution_logs = resolution_logs,
      next_action = next_action,
      conflict_files = conflict_files
    }
  end

  -- Start or continue the rebase process
  continue_rebase_process(context, opts, handle_completion)

  -- This function now returns synchronously
  return {
    success = false,
    next_action = "processing",
    resolution_logs = {},
    error = "The rebase operation is still processing. The tool will return the final result through the on_complete callback."
  }
end

---@class RebaseInput
---@field source_branch string
---@field target_branch string
---@field max_attempts? integer
---@field continue? boolean

---@type avante.LLMToolOnRender<RebaseInput>
function M.on_render(input, opts)
  local Line = require("avante.ui.line")
  local Highlights = require("avante.highlights")
  local Utils = require("avante.utils")

  local store = opts.store or {}
  local state = opts.state or "initializing"
  local lines = {}

  local icon = "🔄"
  local highlight = Highlights.AVANTE_TASK_RUNNING

  if state == "completed" or state == "succeeded" then
    icon = "✅"
    highlight = Highlights.AVANTE_TASK_COMPLETED
  elseif state == "failed" or state == "error" then
    icon = "❌"
    highlight = Highlights.AVANTE_TASK_FAILED
  elseif state == "conflicts_detected" then
    icon = "⚠️"
    highlight = Highlights.AVANTE_WARNING
  end

  -- Add header
  local header = string.format("%s Intelligent Rebase: %s", Utils.icon(icon .. " "), state)
  table.insert(lines, Line:new({ { header, highlight } }))
  table.insert(lines, Line:new({ { "" } }))

  -- Add branch information
  local branch_info = string.format("  Rebasing %s onto %s",
    input.source_branch or store.source_branch or "source",
    input.target_branch or store.target_branch or "target")
  table.insert(lines, Line:new({ { branch_info } }))

  -- Add progress if available
  if store.progress and type(store.progress) == "number" then
    local progress_text = string.format("  Progress: %d%%", store.progress)
    table.insert(lines, Line:new({ { progress_text } }))
  end

  -- Add current stage if available
  if store.stage and type(store.stage) == "string" and store.stage ~= state then
    local stage_text = string.format("  Current stage: %s", store.stage)
    table.insert(lines, Line:new({ { stage_text } }))
  end

  return lines
end

return M

