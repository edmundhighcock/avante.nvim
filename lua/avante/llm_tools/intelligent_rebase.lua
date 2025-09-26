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
- AI-powered contextual conflict resolution
- Multiple resolution attempts
- Safety validation
- Comprehensive logging

Key Capabilities:
1. Detect merge conflicts during rebase
2. Analyze code context for intelligent resolution
3. Apply safe, context-aware conflict resolution strategies
4. Provide detailed resolution logs with stage updates
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
    state = update.stage
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

---@brief Handle completion of verification agent
---@param result string The result from the verification agent
---@param err string|nil Any error that occurred
---@param context IntelligentRebaseContext The rebase context
---@param conflict_file string Path to the file being verified
---@param opts table Options passed to the verification function
---@param verification_callback fun(is_valid: boolean, issues: table|nil): nil Callback to report verification results
local function handle_verification_complete(result, err, context, conflict_file, opts, verification_callback)
  if err then
    log_rebase_update(context, {
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
    log_rebase_update(context, {
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
    log_rebase_update(context, {
      stage = "verifying_resolution",
      details = string.format("Verification passed for file: %s", conflict_file),
      progress = 70
    })
  else
    log_rebase_update(context, {
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

---@brief Verify a conflict resolution using a verification agent
---@param conflict_file string Path to the resolved file
---@param context IntelligentRebaseContext
---@param opts table Optional configuration options
---@param verification_callback fun(is_valid: boolean, issues: table|nil): nil Callback to be called when verification is complete
local function verify_conflict_resolution(conflict_file, context, opts, verification_callback)
  if not vim.fn.filereadable(conflict_file) then
    return verification_callback(false, {"File is not readable"})
  end

  -- Track this operation as a pending asynchronous operation
  track_operation(context)

  log_rebase_update(context, {
    stage = "verifying_resolution",
    details = string.format("Verifying conflict resolution quality for file: %s", conflict_file),
    progress = 60,
    files = { conflict_file }
  })

  -- Read the file content to be verified
  local file_content = vim.fn.readfile(conflict_file)
  local file_content_str = table.concat(file_content, "\n")

  -- Use a separate verification agent to verify the resolution
  local Utils = require("avante.utils")

  -- Create a dedicated function for verification completion
  local function on_verification_complete(result, err)
    handle_verification_complete(result, err, context, conflict_file, opts, verification_callback)
  end

  require("avante.llm_tools.dispatch_full_agent").func({
    prompt = Utils.read_template("_conflict-verification.avanterules", {
      conflict_file = conflict_file,
      file_content_str = file_content_str:sub(1, 8000) -- Limit size to avoid token issues
    })
  }, {
    on_log = opts.on_log or function() end,
    on_complete = on_verification_complete,
    session_ctx = opts.session_ctx or {},
    store = {
      messages = {}
    }
  })
end

---@brief Process a single conflict file
---@param index integer Index of the conflict file to process
---@param context IntelligentRebaseContext
---@param opts table Optional configuration options
---@param resolution_errors table Table to collect resolution errors
---@param callback fun(success: boolean, error: string | nil): nil Final callback
local function process_next_conflict(index, context, opts, resolution_errors, callback)
  -- Check if we've processed all conflicts
  if index > #context.conflict_files then
    -- All conflicts processed, check for errors
    if #resolution_errors > 0 then
      log_rebase_update(context, {
        stage = "resolving_conflicts",
        details = string.format("Partial resolution failure (%d errors)", #resolution_errors),
        progress = 90,
        errors = vim.tbl_map(function(err) return err.error end, resolution_errors)
      })
      return callback(false, "Some conflicts could not be resolved automatically")
    end

    -- Set GIT_EDITOR to prevent interactive editor sessions
    local old_git_editor = vim.fn.getenv("GIT_EDITOR")
    vim.fn.setenv("GIT_EDITOR", ":")

    -- Continue the rebase with error handling
    local continue_result = vim.fn.system("git rebase --continue 2>&1")

    -- Restore original GIT_EDITOR
    if old_git_editor ~= "" then
      vim.fn.setenv("GIT_EDITOR", old_git_editor)
    else
      vim.fn.unsetenv("GIT_EDITOR")
    end

    if vim.v.shell_error ~= 0 then
      log_rebase_update(context, {
        stage = "resolving_conflicts",
        details = "Failed to continue rebase",
        progress = 100,
        errors = { continue_result }
      })
      return callback(false, "Failed to continue rebase: " .. continue_result)
    end

    log_rebase_update(context, {
      stage = "resolving_conflicts",
      details = string.format("Successfully resolved conflicts (Attempt %d)", context.current_attempt),
      progress = 100
    })

    return callback(true, nil)
  end

  -- Get the current conflict file to process
  local conflict_file = context.conflict_files[index]

  log_rebase_update(context, {
    stage = "resolving_conflicts",
    details = string.format("Analyzing conflict in file: %s", conflict_file),
    progress = 50,
    files = { conflict_file }
  })

  -- Validate file before attempting resolution
  if not vim.fn.filereadable(conflict_file) then
    table.insert(resolution_errors, {
      file = conflict_file,
      error = "File is not readable"
    })
    -- Process the next conflict file
    return process_next_conflict(index + 1, context, opts, resolution_errors, callback)
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
    -- Process the next conflict file
    return process_next_conflict(index + 1, context, opts, resolution_errors, callback)
  end

  -- Track this operation as a pending asynchronous operation
  track_operation(context)

  local Utils = require("avante.utils")

  -- Use dispatch_full_agent to analyze and resolve conflicts
  require("avante.llm_tools.dispatch_full_agent").func({
    prompt = Utils.read_template("_conflict-resolution.avanterules", {
      conflict_file = conflict_file,
      file_content_str = file_content_str:sub(1, 4000), -- Limit size to avoid token issues
    })
  }, {
    on_log = opts.on_log or function() end,
    on_complete = function(result, err)
      if err then
        log_rebase_update(context, {
          stage = "resolving_conflicts",
          details = string.format("Agent resolution failed for file: %s", conflict_file),
          progress = 75,
          errors = { err }
        })

        table.insert(resolution_errors, {
          file = conflict_file,
          error = err
        })
      else
        -- Log resolution completion
        log_rebase_update(context, {
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

          log_rebase_update(context, {
            stage = "resolving_conflicts",
            details = "Verification failed - file not readable",
            progress = 80,
            errors = { error_msg }
          })

          -- Complete this operation and move to next file
          complete_operation(context, nil, false, error_msg)
          return process_next_conflict(index + 1, context, opts, resolution_errors, callback)
        end

        -- Use the verification agent to verify the resolution quality
        verify_conflict_resolution(conflict_file, context, opts, function(is_valid, issues)
          if not is_valid then
            -- Resolution verification failed - create a more detailed error message
            local conflict_markers_found = false
            local duplicate_code_found = false
            local other_issues = {}

            -- Categorize issues for better reporting
            if issues then
              for _, issue in ipairs(issues) do
                if issue:match("conflict marker") or issue:match("<<<<<<<") or issue:match("=======") or issue:match(">>>>>>>") then
                  conflict_markers_found = true
                elseif issue:match("duplicate") or issue:match("repeated") then
                  duplicate_code_found = true
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
            if #other_issues > 0 then
              table.insert(error_details, "Other issues: " .. table.concat(other_issues, "; "))
            end

            local error_msg = "Resolution verification failed: " .. table.concat(error_details, ". ")

            -- Log the detailed error
            table.insert(resolution_errors, {
              file = conflict_file,
              error = error_msg,
              issues = issues -- Store original issues for potential retry
            })

            -- Update with categorized errors for better user feedback
            log_rebase_update(context, {
              stage = "resolving_conflicts",
              details = "Resolution verification failed - " ..
                        (conflict_markers_found and "conflict markers remain" or
                         duplicate_code_found and "duplicate code detected" or
                         "see issues for details"),
              progress = 80,
              errors = issues or {"Unknown verification issues"}
            })

            -- If we still have attempts left, try again with the same file
            if context.current_attempt < context.max_attempts then
              log_rebase_update(context, {
                stage = "resolving_conflicts",
                details = string.format("Retrying resolution for file: %s (failed verification)", conflict_file),
                progress = 80,
                errors = issues or {"Unknown verification issues"}
              })

              -- Complete this operation but don't move to next file yet
              complete_operation(context, nil, false, error_msg)

              -- Process the same file again (don't increment index)
              return process_next_conflict(index, context, opts, resolution_errors, callback)
            else
              -- Max attempts reached for this file, log and move on
              log_rebase_update(context, {
                stage = "resolving_conflicts",
                details = string.format("Maximum resolution attempts reached for file: %s", conflict_file),
                progress = 80,
                errors = {"Failed to resolve after maximum attempts"}
              })

              -- Complete this operation and move to next file
              complete_operation(context, nil, false, error_msg)
              return process_next_conflict(index + 1, context, opts, resolution_errors, callback)
            end
          else
            -- Verification passed, proceed with staging
            log_rebase_update(context, {
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

              log_rebase_update(context, {
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

                log_rebase_update(context, {
                  stage = "resolving_conflicts",
                  details = "Staging verification failed",
                  progress = 85,
                  errors = { error_msg }
                })
              else
                log_rebase_update(context, {
                  stage = "resolving_conflicts",
                  details = string.format("Successfully verified and staged resolved file: %s", conflict_file),
                  progress = 85,
                  files = { conflict_file }
                })
              end
            end

            -- Complete this operation and move to next file
            complete_operation(context, nil, true, nil)
            return process_next_conflict(index + 1, context, opts, resolution_errors, callback)
          end
        })

        -- Don't proceed to the next file yet - the verification callback will handle that
        return
      end

      -- Complete this operation and decrement the pending operations counter
      complete_operation(context, nil, err == nil, err)

      -- Process the next conflict file
      process_next_conflict(index + 1, context, opts, resolution_errors, callback)
    end,
    session_ctx = opts.session_ctx or {},
    store = {
      messages = {}
    }
  })
end

---@brief Resolve conflicts using AI-powered strategies with enhanced safety
---@param context IntelligentRebaseContext
---@param opts? table Optional configuration options
---@param callback fun(success: boolean, error: string | nil): nil Callback to be called when all conflicts are resolved
local function resolve_conflicts(context, opts, callback)
  context.current_attempt = context.current_attempt + 1

  log_rebase_update(context, {
    stage = "resolving_conflicts",
    details = string.format("Attempting to resolve conflicts (Attempt %d/%d)", context.current_attempt, context.max_attempts),
    progress = 25,
    files = context.conflict_files
  })

  if context.current_attempt > context.max_attempts then
    log_rebase_update(context, {
      stage = "resolving_conflicts",
      details = "Maximum resolution attempts exceeded",
      progress = 100,
      errors = { "Could not resolve conflicts after maximum attempts" }
    })
    return callback(false, "Maximum resolution attempts exceeded")
  end

  local resolution_errors = {}

  -- Start processing the first conflict file
  process_next_conflict(1, context, opts, resolution_errors, callback)

  -- The function now uses callbacks, so we don't need this synchronous return.
  -- All completion logic is handled in the process_next_conflict function.
end

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

  -- Create final status message with appropriate state
  local final_message
  if final_error then
    final_message = History.Message:new("assistant",
      "Rebase Failed: " .. error_message,
      { just_for_display = true, state = "failed" }
    )
  else
    final_message = History.Message:new("assistant",
      "Rebase Completed Successfully",
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

---@brief Attempt to resolve conflicts during rebase
---@param context IntelligentRebaseContext The rebase context
---@param opts table Options for the resolution
---@param callback fun(success: boolean, error: string|nil): nil Callback to be called when resolution completes
local function attempt_resolution(context, opts, callback)
  -- Use resolve_conflicts with a callback
  resolve_conflicts(context, opts, function(resolution_success, resolution_err)
    if resolution_success then
      -- If resolution was successful, continue the rebase process
      continue_rebase_process(context, opts)
    else
      -- Check if we've reached max attempts
      if context.current_attempt >= context.max_attempts then
        -- Report completion with failure
        context.finalize_rebase(false, resolution_err or "Failed to resolve conflicts")
      else
        -- Try again with the next attempt
        -- resolve_conflicts will increment the attempt counter
        attempt_resolution(context, opts, callback)
      end
    end
  end)
end

---@brief Continue the rebase process after resolving conflicts
---@param context IntelligentRebaseContext The rebase context
---@param opts table Options for the rebase process
local function continue_rebase_process(context, opts)
  -- Attempt to continue the rebase
  local continue_result = vim.fn.system("git rebase --continue 2>&1")

  -- Detect conflicts in the current rebase state
  local has_conflicts, conflict_err = detect_conflicts(context)

  -- Handle unexpected errors during conflict detection
  if conflict_err then
    context.finalize_rebase(false, conflict_err)
    return
  end

  -- If no conflicts, rebase is successful
  if not has_conflicts then
    context.finalize_rebase(true, nil)
    return
  end

  -- Reset attempt counter for this set of conflicts
  context.current_attempt = 0

  -- Start the resolution process
  attempt_resolution(context, opts)
end

---@type AvanteLLMToolFunc<{ source_branch: string, target_branch: string, max_attempts?: integer }>
---@note This function is fully asynchronous and requires on_complete callback for results
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

        -- Mark as completed to prevent further operations
        context.has_completed = true

      -- Complete with error
      pcall(function()
        on_complete(is_success, error_str)
      end)

      return -- Exit early but don't return values
    end
  end

  -- Add on_log, on_messages_add, and on_state_change callbacks to context for updates
  context.on_log = on_log
  context.on_messages_add = on_messages_add
  context.on_state_change = on_state_change
  context.history_messages = {}

  -- Store the main completion callback in the context
  context.main_complete_callback = on_complete

  -- Set GIT_EDITOR to prevent interactive editor sessions for all Git commands
  local old_git_editor = vim.fn.getenv("GIT_EDITOR")
  vim.fn.setenv("GIT_EDITOR", ":")

  -- Use the module-level finalize_rebase function
  local function local_finalize_rebase(success, error)
    finalize_rebase(
      context,
      success,
      error,
      old_git_editor,
      is_success,
      final_error,
      resolution_logs,
      on_state_change,
      on_messages_add
    )
  end

  -- Store the finalize function in the context
  context.finalize_rebase = finalize_rebase

  -- Use the module-level continue_rebase_process function
  -- Start the rebase process
  continue_rebase_process(context, opts)

  -- No direct return values - fully asynchronous pattern
  -- All completion handling is done through callbacks
end

return M

