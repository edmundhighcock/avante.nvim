local Path = require("plenary.path")
local Utils = require("avante.utils")
local Helpers = require("avante.llm_tools.helpers")
local Base = require("avante.llm_tools.base")
local History = require("avante.history")

---@class ConflictResolutionContext
---@field conflict_files string[] List of files with conflicts
---@field file_attempt_counters table<string, integer> Counts of resolution attempts per file
---@field max_attempts integer Maximum number of resolution attempts
---@field current_attempt integer Current global attempt number
---@field on_log? fun(update: {type: string, data: any}): nil
---@field on_messages_add? fun(messages: any[]): nil
---@field on_state_change? fun(state: string): nil
---@field history_messages table[]
---@field current_state string
---@field pending_operations integer Number of pending async operations
---@field has_completed boolean Whether the final completion has been signaled

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "resolve_git_conflicts"

M.get_description = function()
  return [[Git Conflict Resolution Tool: AI-powered resolution of merge conflicts in git repositories.

Features:
- Intelligent analysis of conflict markers
- Context-aware resolution strategies
- Multiple resolution attempts with verification
- Detailed resolution logging
- File-specific and global attempt tracking

Key Capabilities:
1. Detect and analyze merge conflicts in files
2. Apply AI-powered conflict resolution strategies
3. Verify resolution quality to ensure code integrity
4. Handle multiple resolution attempts if initial attempts fail
5. Track resolution progress with detailed logs

When to Use:
- During git merge, rebase, or cherry-pick operations with conflicts
- When manual conflict resolution would be time-consuming
- For projects with complex merge conflicts across multiple files

Important Notes:
- Always review AI-resolved conflicts before finalizing
- Resolution quality verification ensures code integrity
- Multiple resolution attempts improve success rates]]
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "conflict_files",
      description = "List of files with merge conflicts to resolve",
      type = "array",
      items = { name = "file", description = "Path to a file with merge conflicts", type = "string" },
    },
    {
      name = "max_attempts",
      description = "Maximum number of resolution attempts per file (default: 3)",
      type = "number",
      optional = true,
    },
    {
      name = "current_attempt",
      description = "Current global attempt number (for continuing resolution)",
      type = "number",
      optional = true,
    },
  },
  required = { "conflict_files" },
  usage = {
    conflict_files = "Array of paths to files with merge conflicts",
    max_attempts = "Optional maximum number of resolution attempts",
    current_attempt = "Optional current attempt number for continuing resolution",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "success",
    description = "Whether all conflicts were successfully resolved",
    type = "boolean",
  },
  {
    name = "resolution_logs",
    description = "Detailed logs of the conflict resolution process",
    type = "table",
  },
  {
    name = "error",
    description = "Error message if resolution failed",
    type = "string",
    optional = true,
  },
}

-- Forward declarations for functions referenced before their definitions
local verify_conflict_resolution
local handle_verification_result

-- Helper functions for conflict resolution

---@brief Log resolution update with stage, details, and progress
---@param context ConflictResolutionContext
---@param update {stage: string, details: string, progress: number, files?: string[], errors?: string[]}
local function log_resolution_update(context, update)
  -- Ensure context.history_messages is initialized
  context.history_messages = context.history_messages or {}

  -- Add update to context's resolution_logs
  context.resolution_logs = context.resolution_logs or {}
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
    "🔄 Git Conflict Resolution Update [%s]\n- Stage: %s\n- Details: %s\n- Progress: %d%%\n%s",
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
      stage = update.stage,
      progress = update.progress or 0,
    },
  })

  -- Store the current state in the context
  context.current_state = update.stage

  -- Add message to history messages
  table.insert(context.history_messages, history_message)

  -- Notify via on_log callback for real-time updates
  if context.on_log then
    pcall(context.on_log, {
      type = "resolution_update",
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

---@brief Track a new asynchronous operation
---@param context ConflictResolutionContext
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
---@param context ConflictResolutionContext
---@param on_complete function? Optional callback to call when all operations are complete
---@param success boolean Whether the operation was successful
---@param error string|nil Error message if the operation failed
local function complete_operation(context, on_complete, success, error)
  if not context then return end

  -- Ensure we have a valid operation count before decrementing
  if not context.pending_operations or context.pending_operations <= 0 then
    -- Log warning about operation tracking mismatch
    if context.on_log then
      pcall(context.on_log, {
        type = "operation_tracking",
        data = {
          action = "warning",
          message = "Attempted to complete operation when no operations were pending",
          count = 0
        }
      })
    end
    context.pending_operations = 0
  else
    -- Decrement the pending operations counter
    context.pending_operations = context.pending_operations - 1
  end

  -- Log the operation completion for debugging
  if context.on_log then
    pcall(context.on_log, {
      type = "operation_tracking",
      data = {
        action = "complete",
        count = context.pending_operations,
        success = success,
        error = error or "none"
      }
    })
  end

  -- First, check if we have a specific on_complete callback
  if on_complete then
    pcall(on_complete, success, error)
  end

  -- Then, check if all operations for the current file are complete and we should continue processing
  if context.pending_operations == 0 and not context.has_completed then
    -- If we have a main callback and no more files to process, signal completion
    if context.current_file_index > #context.conflict_files and context.main_callback then
      context.has_completed = true
      pcall(context.main_callback, success, error)
      return
    end

    -- If we have more files to process and we're not already processing the next file
    if not context.processing_next_file and context.current_file_index <= #context.conflict_files then
      context.processing_next_file = true

      -- Schedule the next file processing to avoid stack overflow and ensure clean async boundaries
      vim.schedule(function()
        -- If retry_current_file is set, don't increment the file index
        if not context.retry_current_file then
          context.current_file_index = context.current_file_index + 1
        end

        -- Clear the retry flag
        context.retry_current_file = nil

        -- Process the next file if we haven't completed yet
        if not context.has_completed then
          process_conflict_files(
            context,
            context.process_opts,
            context.process_resolution_errors,
            context.main_callback
          )
        end
      end)
    end
  end
end

---@brief Check if all operations are complete and signal completion if they are
---@param context ConflictResolutionContext
---@param on_complete function Optional callback to call when all operations are complete
---@param success boolean Whether the operation was successful
---@param error string|nil Error message if the operation failed
local function check_completion(context, on_complete, success, error)
  if not context then return end

  -- Log the check operation for debugging
  if context.on_log then
    pcall(context.on_log, {
      type = "operation_tracking",
      data = {
        action = "check_completion",
        count = context.pending_operations or 0,
        has_completed = context.has_completed or false
      }
    })
  end

  -- If there are no pending operations and we haven't already signaled completion
  if (context.pending_operations or 0) == 0 and not context.has_completed and on_complete then
    context.has_completed = true
    pcall(on_complete, success, error)
  end
end

---@brief Safely check if a file is binary
---@param file string Path to the file
---@return boolean
local function is_binary_file(file)
  local result = vim.fn.system(string.format("file -b --mime-type %q", file))
  return result:match("binary") ~= nil
end

---@brief Handle completion of verification agent
---@param result string The result from the verification agent
---@param err string|nil Any error that occurred
---@param context ConflictResolutionContext The resolution context
---@param conflict_file string Path to the file being verified
---@param opts table Options passed to the verification function
---@param verification_callback fun(is_valid: boolean, issues: table|nil): nil Callback to report verification results
local function handle_verification_complete(result, err, context, conflict_file, opts, verification_callback)
  if err then
    log_resolution_update(context, {
      stage = "verifying_resolution",
      details = string.format("Verification agent failed for file: %s", conflict_file),
      progress = 65,
      errors = { err }
    })

    -- Complete this operation and decrement the pending operations counter
    complete_operation(context, nil, false, err)

    -- Return verification failure due to agent error
    return verification_callback(false, {"Verification agent failed: " .. err})
  end

  -- Parse the verification result
  local verification_result = nil
  local parse_success, parse_error = pcall(function()
    -- Extract JSON from the result
    local json_str = result:match("```json%s*(.-)%s*```") or
                     result:match("{%s*\"passed\".-}") or
                     result

    -- Parse the JSON
    verification_result = vim.fn.json_decode(json_str)
  end)

  if not parse_success or not verification_result or type(verification_result) ~= "table" or
     verification_result.passed == nil then
    log_resolution_update(context, {
      stage = "verifying_resolution",
      details = "Failed to parse verification result",
      progress = 65,
      errors = { "Invalid verification result format" }
    })

    -- Complete this operation
    complete_operation(context, nil, false, "Invalid verification result format")

    -- Return verification failure due to parsing error
    return verification_callback(false, {"Failed to parse verification result"})
  end

  -- Log verification result
  if verification_result.passed then
    log_resolution_update(context, {
      stage = "verifying_resolution",
      details = string.format("Verification passed for file: %s", conflict_file),
      progress = 70
    })
  else
    log_resolution_update(context, {
      stage = "verifying_resolution",
      details = string.format("Verification failed for file: %s", conflict_file),
      progress = 70,
      errors = verification_result.issues or {"Unknown verification issues"}
    })
  end

  -- Complete this operation
  complete_operation(context, nil, verification_result.passed, verification_result.passed and nil or "Verification failed")

  -- Return verification result
  return verification_callback(verification_result.passed, verification_result.issues)
end

---@brief Process conflict files using a queue-based approach
---@param context ConflictResolutionContext
---@param opts table Optional configuration options
---@param resolution_errors table Table to collect resolution errors
---@param callback fun(success: boolean, error: string | nil): nil Final callback
local function process_conflict_files(context, opts, resolution_errors, callback)
  -- Initialize file index if not already set
  context.current_file_index = context.current_file_index or 1

  -- Check if we've processed all conflicts
  if context.current_file_index > #context.conflict_files then
    -- All conflicts processed, check for errors
    if #resolution_errors > 0 then
      -- Count how many files had errors
      local failed_files = {}
      for _, err in ipairs(resolution_errors) do
        failed_files[err.file] = true
      end
      local failed_file_count = vim.tbl_count(failed_files)

      -- Group errors by file for better reporting
      local errors_by_file = {}
      for _, err in ipairs(resolution_errors) do
        errors_by_file[err.file] = errors_by_file[err.file] or {}
        table.insert(errors_by_file[err.file], err.error)
      end

      -- Create a summary of errors
      local error_summary = {}
      for file, errors in pairs(errors_by_file) do
        table.insert(error_summary, string.format("File %s: %s", file, table.concat(errors, "; ")))
      end

      log_resolution_update(context, {
        stage = "resolving_conflicts",
        details = string.format("Partial resolution failure (%d/%d files)", failed_file_count, #context.conflict_files),
        progress = 90,
        errors = error_summary
      })
      return callback(false, string.format("%d/%d files could not be resolved automatically", failed_file_count, #context.conflict_files))
    end

    -- Create a summary of successful resolutions
    local success_summary = string.format(
      "Successfully resolved all conflicts in %d files (Global attempt %d/%d)",
      #context.conflict_files,
      context.current_attempt,
      context.max_attempts
    )

    log_resolution_update(context, {
      stage = "resolving_conflicts",
      details = success_summary,
      progress = 100
    })

    return callback(true, nil)
  end

  -- Get the current conflict file to process
  local conflict_file = context.conflict_files[context.current_file_index]

  -- Get current attempt for this file
  local file_attempt = (context.file_attempt_counters or {})[conflict_file] or 0
  local is_retry = file_attempt > 0

  -- Flag to ensure we only process the next file once
  context.processing_next_file = false

  -- Log with retry information if applicable
  if is_retry then
    log_resolution_update(context, {
      stage = "resolving_conflicts",
      details = string.format("Retrying conflict resolution for file: %s (attempt %d/%d)",
                            conflict_file,
                            file_attempt + 1,
                            context.max_attempts),
      progress = 50,
      files = { conflict_file }
    })
  else
    log_resolution_update(context, {
      stage = "resolving_conflicts",
      details = string.format("Analyzing conflict in file: %s", conflict_file),
      progress = 50,
      files = { conflict_file }
    })
  end

  -- Validate file before attempting resolution
  if not vim.fn.filereadable(conflict_file) then
    table.insert(resolution_errors, {
      file = conflict_file,
      error = "File is not readable"
    })
    -- Move to the next file
    context.current_file_index = context.current_file_index + 1
    return process_conflict_files(context, opts, resolution_errors, callback)
  end

  -- Read the conflict file content
  local file_content = vim.fn.readfile(conflict_file)
  local file_content_str = table.concat(file_content, "\n")

  -- Check if the file actually has conflict markers
  if not file_content_str:match("<<<<<<< HEAD") then
    -- No conflict markers found, just stage the file as is
    local stage_result = vim.fn.system(string.format("git add %q", conflict_file))
    if vim.v.shell_error ~= 0 then
      table.insert(resolution_errors, {
        file = conflict_file,
        error = "Failed to stage file without conflict markers: " .. stage_result
      })
    end
    -- Move to the next file
    context.current_file_index = context.current_file_index + 1
    return process_conflict_files(context, opts, resolution_errors, callback)
  end

  -- Track this operation as a pending asynchronous operation
  track_operation(context)

  local Utils = require("avante.utils")

  -- Define a callback function for handling resolution completion
  local function on_resolution_complete(result, err)
    if err then
      log_resolution_update(context, {
        stage = "resolving_conflicts",
        details = string.format("Agent resolution failed for file: %s", conflict_file),
        progress = 75,
        errors = { err }
      })

      table.insert(resolution_errors, {
        file = conflict_file,
        error = err
      })

      -- Complete this operation
      complete_operation(context, nil, false, err)

      -- Only move to the next file if we haven't already started processing it
      if not context.processing_next_file then
        context.processing_next_file = true
        context.current_file_index = context.current_file_index + 1
        process_conflict_files(context, opts, resolution_errors, callback)
      end
    else
      -- Log resolution completion
      log_resolution_update(context, {
        stage = "resolving_conflicts",
        details = string.format("Resolution completed for file: %s, verifying quality", conflict_file),
        progress = 75,
        files = { conflict_file }
      })

      -- Verify file exists before verification
      if vim.fn.filereadable(conflict_file) ~= 1 then
        local error_msg = string.format("Cannot verify file: %s does not exist or is not readable", conflict_file)
        table.insert(resolution_errors, {
          file = conflict_file,
          error = error_msg
        })

        log_resolution_update(context, {
          stage = "resolving_conflicts",
          details = "Verification failed - file not readable",
          progress = 80,
          errors = { error_msg }
        })

        -- Complete this operation
        complete_operation(context, nil, false, error_msg)

        -- Only move to the next file if we haven't already started processing it
        if not context.processing_next_file then
          context.processing_next_file = true
          context.current_file_index = context.current_file_index + 1
          process_conflict_files(context, opts, resolution_errors, callback)
        end
        return
      end

      -- Define a dedicated verification callback
      local function verification_handler(is_valid, issues)
        -- Handle verification result will be called from the verification callback
        handle_verification_result(is_valid, issues, conflict_file, context, opts, resolution_errors, callback)
      end

      -- Use the verification agent to verify the resolution quality
      verify_conflict_resolution(conflict_file, context, opts, verification_handler)
    end
  end

  -- Use dispatch_full_agent to analyze and resolve conflicts
  local Path = require("avante.path")
  require("avante.llm_tools.dispatch_full_agent").func({
    prompt = Path.prompts.render_file("_conflict-resolution.avanterules", {
      ask = "Resolve git conflicts",
      conflict_file = conflict_file,
      file_content_str = file_content_str:sub(1, 4000), -- Limit size to avoid token issues
    })
  }, {
    on_log = opts.on_log or function() end,
    on_complete = on_resolution_complete,
    session_ctx = opts.session_ctx or {},
    store = {
      messages = {}
    }
  })
end

---@brief Resolve conflicts using AI-powered strategies with enhanced safety
---@param context ConflictResolutionContext
---@param opts? table Optional configuration options
---@param callback fun(success: boolean, error: string | nil): nil Callback to be called when all conflicts are resolved
local function resolve_conflicts(context, opts, callback)
  -- Initialize the global attempt counter if not already set
  context.current_attempt = context.current_attempt + 1

  -- Initialize file-specific attempt counters if they don't exist
  context.file_attempt_counters = context.file_attempt_counters or {}

  log_resolution_update(context, {
    stage = "resolving_conflicts",
    details = string.format("Attempting to resolve conflicts (Global attempt %d/%d)",
                          context.current_attempt,
                          context.max_attempts),
    progress = 25,
    files = context.conflict_files
  })

  -- Check if we've exceeded the global maximum attempts
  if context.current_attempt > context.max_attempts then
    log_resolution_update(context, {
      stage = "resolving_conflicts",
      details = "Maximum global resolution attempts exceeded",
      progress = 100,
      errors = { "Could not resolve conflicts after maximum attempts" }
    })
    return callback(false, "Maximum global resolution attempts exceeded")
  end

  local resolution_errors = {}

  -- Start processing the first conflict file
  process_conflict_files(context, opts, resolution_errors, callback)

  -- The function now uses callbacks, so we don't need this synchronous return.
  -- All completion logic is handled in the process_next_conflict function.
end

---@brief Verify a conflict resolution using a verification agent
---@param conflict_file string Path to the resolved file
---@param context ConflictResolutionContext
---@param opts table Optional configuration options
---@param verification_callback fun(is_valid: boolean, issues: table|nil): nil Callback to be called when verification is complete
verify_conflict_resolution = function(conflict_file, context, opts, verification_callback)
  if not vim.fn.filereadable(conflict_file) then
    return verification_callback(false, {"File is not readable"})
  end

  -- Track this operation as a pending asynchronous operation
  track_operation(context)

  -- Get current attempt for this file for better logging
  local file_attempt = (context.file_attempt_counters or {})[conflict_file] or 0
  local is_retry = file_attempt > 0

  -- Enhanced logging with retry information
  if is_retry then
    log_resolution_update(context, {
      stage = "verifying_resolution",
      details = string.format("Verifying conflict resolution quality for file: %s (verification attempt %d/%d)",
                            conflict_file,
                            file_attempt,
                            context.max_attempts),
      progress = 60,
      files = { conflict_file }
    })
  else
    log_resolution_update(context, {
      stage = "verifying_resolution",
      details = string.format("Verifying conflict resolution quality for file: %s", conflict_file),
      progress = 60,
      files = { conflict_file }
    })
  end

  -- Read the file content to be verified
  local file_content = vim.fn.readfile(conflict_file)
  local file_content_str = table.concat(file_content, "\n")

  -- Use a separate verification agent to verify the resolution
  local Path = require("avante.path")

  -- Simplify callback structure by using a direct callback function
  require("avante.llm_tools.dispatch_full_agent").func({
    prompt = Path.prompts.render_file("_conflict-verification.avanterules", {
      ask = "Verify git conflict resolution",
      conflict_file = conflict_file,
      file_content_str = file_content_str:sub(1, 8000), -- Limit size to avoid token issues
      attempt_number = file_attempt, -- Pass attempt information to the verification agent
      max_attempts = context.max_attempts
    })
  }, {
    on_log = opts.on_log or function() end,
    on_complete = function(result, err)
      handle_verification_complete(result, err, context, conflict_file, opts, verification_callback)
    end,
    session_ctx = opts.session_ctx or {},
    store = {
      messages = {}
    }
  })
end

---@class ConflictResolutionInput
---@field conflict_files string[]
---@field max_attempts? number
---@field current_attempt? number

---@type avante.LLMToolOnRender<ConflictResolutionInput>
function M.on_render(input, opts)
  local Line = require("avante.ui.line")
  local Highlights = require("avante.highlights")
  local Utils = require("avante.utils")

  local store = opts.store or {}
  local state = opts.state or "initializing"
  local lines = {}

  local icon = "🔄"
  local highlight = Highlights.AVANTE_TASK_RUNNING

  if state == "completed" then
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
  local header = string.format("%s Git Conflict Resolution: %s", Utils.icon(icon .. " "), state)
  table.insert(lines, Line:new({ { header, highlight } }))
  table.insert(lines, Line:new({ { "" } }))

  -- Add file information
  local num_files = input.conflict_files and #input.conflict_files or 0
  local file_info = string.format("  Resolving %d conflict file(s)", num_files)
  table.insert(lines, Line:new({ { file_info } }))

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

---@type AvanteLLMToolFunc<ConflictResolutionInput>
function M.func(input, opts)
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local session_ctx = opts.session_ctx

  if not on_complete then return false, "on_complete not provided" end

  -- Validate input parameters
  if not input.conflict_files or type(input.conflict_files) ~= "table" or #input.conflict_files == 0 then
    return false, "No conflict files provided or invalid format"
  end

  -- Set default max_attempts if not provided
  local max_attempts = input.max_attempts or 3
  if type(max_attempts) ~= "number" or max_attempts < 1 then
    max_attempts = 3
  end

  -- Initialize context for conflict resolution
  local context = {
    conflict_files = input.conflict_files,
    max_attempts = max_attempts,
    current_attempt = input.current_attempt or 0,
    file_attempt_counters = {},
    resolution_logs = {},
    history_messages = {},
    current_state = "initializing",
    pending_operations = 0,
    has_completed = false,
    on_log = function(update)
      if on_log then on_log("Resolution update: " .. vim.inspect(update)) end
    end,
    on_messages_add = opts.on_messages_add,
    on_state_change = function(state)
      if opts.set_store then opts.set_store("state", state) end
    end,
  }

  -- Log initial state
  log_resolution_update(context, {
    stage = "initializing",
    details = "Preparing to resolve conflicts in " .. #input.conflict_files .. " files",
    progress = 10,
    files = input.conflict_files
  })

  -- Start the conflict resolution process
  resolve_conflicts(context, {
    on_log = on_log,
    session_ctx = session_ctx
  }, function(success, error)
    if error then
      log_resolution_update(context, {
        stage = "completed",
        details = "Conflict resolution failed: " .. error,
        progress = 100,
        errors = { error }
      })
      on_complete(false, error)
    else
      log_resolution_update(context, {
        stage = "completed",
        details = "All conflicts successfully resolved",
        progress = 100
      })
      on_complete({
        success = true,
        resolution_logs = context.resolution_logs
      }, nil)
    end
  end)
end

---@brief Handle verification result from conflict resolution
---@param is_valid boolean Whether the verification passed
---@param issues table|nil Issues found during verification
---@param conflict_file string Path to the file being verified
---@param context ConflictResolutionContext
---@param opts table Optional configuration options
---@param resolution_errors table Table to collect resolution errors
---@param callback fun(success: boolean, error: string | nil): nil Final callback
handle_verification_result = function(is_valid, issues, conflict_file, context, opts, resolution_errors, callback)
  if not is_valid then
    -- Resolution verification failed - create a more detailed error message
    local conflict_markers_found = false
    local duplicate_code_found = false
    local syntax_errors_found = false
    local other_issues = {}

    -- Categorize issues for better reporting and user action
    if issues then
      for _, issue in ipairs(issues) do
        if issue:match("conflict marker") or issue:match("<<<<<<<") or issue:match("=======") or issue:match(">>>>>>>") then
          conflict_markers_found = true
        elseif issue:match("duplicate") or issue:match("repeated") or issue:match("redundant") then
          duplicate_code_found = true
        elseif issue:match("syntax") or issue:match("error") or issue:match("invalid") then
          syntax_errors_found = true
        else
          table.insert(other_issues, issue)
        end
      end
    end

    -- Create a detailed error message based on issue categories
    local error_details = {}
    if conflict_markers_found then
      table.insert(error_details, "Conflict markers still present in file")
    end
    if duplicate_code_found then
      table.insert(error_details, "Duplicate code found in resolution")
    end
    if syntax_errors_found then
      table.insert(error_details, "Possible syntax errors in resolved file")
    end
    if #other_issues > 0 then
      table.insert(error_details, "Other issues: " .. table.concat(other_issues, "; "))
    end

    local error_msg = "Resolution verification failed: " .. table.concat(error_details, ". ")

    -- Store file-specific attempt counter if it doesn't exist
    context.file_attempt_counters = context.file_attempt_counters or {}
    context.file_attempt_counters[conflict_file] = (context.file_attempt_counters[conflict_file] or 0) + 1
    local file_attempt = context.file_attempt_counters[conflict_file]

    -- Log the detailed error with attempt information
    table.insert(resolution_errors, {
      file = conflict_file,
      error = error_msg,
      issues = issues, -- Store original issues for potential retry
      attempt = file_attempt -- Track which attempt this was
    })

    -- Update with categorized errors for better user feedback
    log_resolution_update(context, {
      stage = "resolving_conflicts",
      details = string.format("Resolution verification failed (attempt %d/%d) - %s",
                file_attempt,
                context.max_attempts,
                (conflict_markers_found and "conflict markers remain" or
                 duplicate_code_found and "duplicate code detected" or
                 syntax_errors_found and "syntax errors detected" or
                 "see issues for details")),
      progress = 80,
      errors = issues or {"Unknown verification issues"}
    })

    -- If we still have attempts left for this file, set retry flag to true
    if file_attempt < context.max_attempts then
      log_resolution_update(context, {
        stage = "resolving_conflicts",
        details = string.format("Retrying resolution for file: %s (attempt %d/%d)",
                              conflict_file,
                              file_attempt + 1,
                              context.max_attempts),
        progress = 80,
        errors = issues or {"Unknown verification issues"}
      })

      -- Store necessary context for file processing
      context.process_opts = opts
      context.process_resolution_errors = resolution_errors
      context.main_callback = callback

      -- Set retry flag to true - don't increment file index
      context.retry_current_file = true

      -- Complete this operation - will trigger next file processing in complete_operation
      complete_operation(context, nil, false, error_msg)
    else
      -- Max attempts reached for this file, log and move on
      log_resolution_update(context, {
        stage = "resolving_conflicts",
        details = string.format("Maximum resolution attempts (%d) reached for file: %s",
                              context.max_attempts,
                              conflict_file),
        progress = 80,
        errors = {"Failed to resolve after maximum attempts"}
      })

      -- Store necessary context for file processing
      context.process_opts = opts
      context.process_resolution_errors = resolution_errors
      context.main_callback = callback

      -- Set retry flag to false - increment file index
      context.retry_current_file = false

      -- Complete this operation - will trigger next file processing in complete_operation
      complete_operation(context, nil, false, error_msg)
    end
  else
    -- Verification passed, proceed with staging
    log_resolution_update(context, {
      stage = "resolving_conflicts",
      details = string.format("Verification passed, staging file: %s", conflict_file),
      progress = 80,
      files = { conflict_file }
    })

    -- Apply the resolution with safety checks
    local apply_result = vim.fn.system(string.format("git add %q", conflict_file))

    if vim.v.shell_error ~= 0 then
      local error_msg = "Failed to stage resolved file: " .. apply_result
      table.insert(resolution_errors, {
        file = conflict_file,
        error = error_msg
      })

      log_resolution_update(context, {
        stage = "resolving_conflicts",
        details = "Git add command failed",
        progress = 85,
        errors = { error_msg }
      })
    else
      -- Verify file was actually staged
      local staged_status = vim.fn.system(string.format("git status --porcelain %q", conflict_file))

      if not staged_status:match("^M") and not staged_status:match("^A") then
        local error_msg = "File was not properly staged despite successful git add"
        table.insert(resolution_errors, {
          file = conflict_file,
          error = error_msg
        })

        log_resolution_update(context, {
          stage = "resolving_conflicts",
          details = "Staging verification failed",
          progress = 85,
          errors = { error_msg }
        })
      else
        log_resolution_update(context, {
          stage = "resolving_conflicts",
          details = string.format("Successfully verified and staged resolved file: %s", conflict_file),
          progress = 85,
          files = { conflict_file }
        })
      end
    end

    -- Store necessary context for file processing
    context.process_opts = opts
    context.process_resolution_errors = resolution_errors
    context.main_callback = callback

    -- Set retry flag to false - increment file index
    context.retry_current_file = false

    -- Complete this operation - will trigger next file processing in complete_operation
    complete_operation(context, nil, true, nil)
  end
end

return M
