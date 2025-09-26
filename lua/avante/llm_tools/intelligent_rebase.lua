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

  -- Validate branches exist
  local function branch_exists(branch)
    local sanitized = sanitize_branch_name(branch)
    local result = vim.fn.system(string.format("git rev-parse --verify %q 2>/dev/null", sanitized))
    return vim.v.shell_error == 0
  end

  if not branch_exists(context.source_branch) then
    return nil, string.format("Source branch '%s' does not exist", context.source_branch)
  end

  if not branch_exists(context.target_branch) then
    return nil, string.format("Target branch '%s' does not exist", context.target_branch)
  end

  -- Check for non-empty tracked changes
  local function has_non_empty_tracked_changes()
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

  -- Check for uncommitted changes, but allow empty directory changes
  if has_non_empty_tracked_changes() then
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

  -- Process conflict files sequentially
  local function process_next_conflict(index)
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
      return process_next_conflict(index + 1)
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
      return process_next_conflict(index + 1)
    end

    -- Track this operation as a pending asynchronous operation
    track_operation(context)

    -- Use dispatch_full_agent to analyze and resolve conflicts
    require("avante.llm_tools.dispatch_full_agent").func({
      prompt = string.format(
        "# Git Conflict Resolution Task\n\n" ..
        "## File Information\n" ..
        "- File path: %s\n" ..
        "- This file contains git merge conflicts that must be resolved\n\n" ..
        "## Conflict File Content\n\n```\n%s\n```\n\n" ..
        "## CRITICAL RESOLUTION REQUIREMENTS\n\n" ..
        "1. **REMOVE ALL CONFLICT MARKERS COMPLETELY**:\n" ..
        "   - You MUST remove ALL of these markers: `<<<<<<<`, `=======`, and `>>>>>>>` \n" ..
        "   - A single remaining marker = FAILED resolution\n" ..
        "   - After your changes, run a final check with `view` tool to verify NO markers remain\n\n" ..
        "2. **AVOID DUPLICATE CODE**:\n" ..
        "   - Never include the same code twice\n" ..
        "   - Don't paste both versions - merge them intelligently\n" ..
        "   - Look for repeated functions, variables, or logic blocks\n" ..
        "   - If you see the same or similar code twice, merge it into a single instance\n\n" ..
        "3. **PRESERVE FUNCTIONALITY**:\n" ..
        "   - Keep important code from both versions\n" ..
        "   - When in doubt, include logic from both sides unless they directly contradict\n\n" ..
        "## STEP-BY-STEP RESOLUTION PROCESS\n\n" ..
        "1. **IDENTIFY CONFLICT BOUNDARIES**:\n" ..
        "   - Locate ALL `<<<<<<<`, `=======`, and `>>>>>>>` markers\n" ..
        "   - For each conflict section, clearly identify:\n" ..
        "     - The HEAD version (between `<<<<<<<` and `=======`)\n" ..
        "     - The incoming version (between `=======` and `>>>>>>>`)\n\n" ..
        "2. **ANALYZE EACH CONFLICT**:\n" ..
        "   - For EACH conflict section, determine:\n" ..
        "     - What exactly changed between versions?\n" ..
        "     - Is it simple (comments, formatting) or complex (logic changes)?\n" ..
        "     - Do the changes contradict or complement each other?\n\n" ..
        "3. **RESOLVE EACH CONFLICT**:\n" ..
        "   - For simple changes (formatting, comments):\n" ..
        "     - Choose the most comprehensive version\n" ..
        "   \n" ..
        "   - For variable/function name changes:\n" ..
        "     - Use the most descriptive name\n" ..
        "     - Update all references consistently\n" ..
        "   \n" ..
        "   - For added/removed functionality:\n" ..
        "     - Usually keep the added functionality\n" ..
        "     - Only remove code if it's clearly replaced\n" ..
        "   \n" ..
        "   - For modified logic:\n" ..
        "     - If changes don't conflict, include both\n" ..
        "     - If changes conflict, choose the approach that matches surrounding code\n\n" ..
        "4. **REMOVE ALL MARKERS**:\n" ..
        "   - Delete ALL instances of:\n" ..
        "     - `<<<<<<< HEAD` (and variants)\n" ..
        "     - `=======`\n" ..
        "     - `>>>>>>> branch-name` (and variants)\n\n" ..
        "5. **CHECK FOR DUPLICATES**:\n" ..
        "   - Look for repeated:\n" ..
        "     - Function definitions\n" ..
        "     - Variable declarations\n" ..
        "     - Import statements\n" ..
        "     - Logic blocks\n" ..
        "   - Merge any duplicates you find\n\n" ..
        "## COMMON CONFLICT PATTERNS AND RESOLUTIONS\n\n" ..
        "### Example 1: Simple Comment/Formatting Changes\n" ..
        "```\n" ..
        "<<<<<<< HEAD\n" ..
        "function doThing() {\n" ..
        "  // Old comment\n" ..
        "  return x + y;\n" ..
        "}\n" ..
        "=======\n" ..
        "function doThing() {\n" ..
        "  // Updated comment\n" ..
        "  return x + y;\n" ..
        "}\n" ..
        ">>>>>>> feature-branch\n" ..
        "```\n" ..
        "✅ CORRECT resolution:\n" ..
        "```\n" ..
        "function doThing() {\n" ..
        "  // Updated comment\n" ..
        "  return x + y;\n" ..
        "}\n" ..
        "```\n\n" ..
        "### Example 2: Added Functionality\n" ..
        "```\n" ..
        "<<<<<<< HEAD\n" ..
        "function process() {\n" ..
        "  step1();\n" ..
        "  step2();\n" ..
        "}\n" ..
        "=======\n" ..
        "function process() {\n" ..
        "  step1();\n" ..
        "  step2();\n" ..
        "  step3(); // New step\n" ..
        "}\n" ..
        ">>>>>>> feature-branch\n" ..
        "```\n" ..
        "✅ CORRECT resolution:\n" ..
        "```\n" ..
        "function process() {\n" ..
        "  step1();\n" ..
        "  step2();\n" ..
        "  step3(); // New step\n" ..
        "}\n" ..
        "```\n\n" ..
        "### Example 3: Contradicting Changes\n" ..
        "```\n" ..
        "<<<<<<< HEAD\n" ..
        "const MAX_RETRY = 5;\n" ..
        "=======\n" ..
        "const MAX_RETRY = 10;\n" ..
        ">>>>>>> feature-branch\n" ..
        "```\n" ..
        "✅ CORRECT resolution (choose one):\n" ..
        "```\n" ..
        "const MAX_RETRY = 10; // Choose the newer value\n" ..
        "```\n\n" ..
        "## MANDATORY VERIFICATION STEPS - MUST COMPLETE ALL\n\n" ..
        "1. **CONFLICT MARKER CHECK**:\n" ..
        "   - After your changes, use the `view` tool to read the ENTIRE file\n" ..
        "   - Search for EACH of these patterns:\n" ..
        "     - `<<<<<<<` (seven less-than signs)\n" ..
        "     - `=======` (seven equal signs)\n" ..
        "     - `>>>>>>>` (seven greater-than signs)\n" ..
        "   - If ANY of these patterns exist, you MUST fix them before continuing\n\n" ..
        "2. **DUPLICATE CODE CHECK**:\n" ..
        "   - Scan the entire file for these duplicate patterns:\n" ..
        "     - Repeated function definitions (look for `function` or `def` keywords appearing twice with similar names)\n" ..
        "     - Duplicate variable declarations (same variable defined multiple times)\n" ..
        "     - Repeated blocks of 3+ similar lines\n" ..
        "     - Identical or nearly identical comments\n" ..
        "   - For each duplicate found, merge them properly\n\n" ..
        "3. **FINAL VERIFICATION COMMAND**:\n" ..
        "   - You MUST run this exact command as your final step:\n" ..
        "     ```\n" ..
        "     view path=\"%s\"\n" ..
        "     ```\n" ..
        "   - After viewing the file, explicitly confirm:\n" ..
        "     \"I have verified that NO conflict markers remain and NO duplicate code exists.\"\n\n" ..
        "## TOOL USAGE REQUIREMENTS\n\n" ..
        "- DO NOT use git commands directly to edit files\n" ..
        "- DO NOT use bash commands to edit files\n" ..
        "- Use ONLY the replace_in_file tool for making changes\n" ..
        "- Use the view tool to verify your changes\n" ..
        "- DO NOT invoke any interactive tools or editors\n\n" ..
        "## FINAL CHECKLIST\n\n" ..
        "Before completing the task, verify:\n" ..
        "1. [ ] ALL conflict markers are completely removed\n" ..
        "2. [ ] NO duplicate code exists in the file\n" ..
        "3. [ ] The code is syntactically valid\n" ..
        "4. [ ] All functionality from both versions is preserved\n\n" ..
        "After you completely resolve all conflicts, I will manually stage the file for you. DO NOT attempt to stage the file yourself.",
        conflict_file,
        file_content_str:sub(1, 4000), -- Limit size to avoid token issues
        conflict_file -- Add missing parameter for the third %s placeholder
      )
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
          -- Log staging attempt
          log_rebase_update(context, {
            stage = "resolving_conflicts",
            details = string.format("Staging resolved file: %s", conflict_file),
            progress = 80,
            files = { conflict_file }
          })

          -- Verify file exists before staging
          if vim.fn.filereadable(conflict_file) ~= 1 then
            local error_msg = string.format("Cannot stage file: %s does not exist or is not readable", conflict_file)
            table.insert(resolution_errors, {
              file = conflict_file,
              error = error_msg
            })

            log_rebase_update(context, {
              stage = "resolving_conflicts",
              details = "Staging failed - file not readable",
              progress = 85,
              errors = { error_msg }
            })
          else
            -- Verify no conflict markers remain
            local file_content = vim.fn.readfile(conflict_file)
            local file_content_str = table.concat(file_content, "\n")

            if file_content_str:match("<<<<<<< HEAD") or
               file_content_str:match("=======") or
               file_content_str:match(">>>>>>>") then

              local error_msg = "Conflict markers still present in resolved file"
              table.insert(resolution_errors, {
                file = conflict_file,
                error = error_msg
              })

              log_rebase_update(context, {
                stage = "resolving_conflicts",
                details = "Staging failed - conflict markers remain",
                progress = 85,
                errors = { error_msg }
              })
            else
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
                    details = string.format("Successfully staged resolved file: %s", conflict_file),
                    progress = 85,
                    files = { conflict_file }
                  })
                end
              end
            end
          end
        end

        -- Complete this operation and decrement the pending operations counter
        complete_operation(context, nil, err == nil, err)

        -- Process the next conflict file
        process_next_conflict(index + 1)
      end,
      session_ctx = opts.session_ctx or {},
      store = {
        messages = {}
      }
    })
  end

  -- Start processing the first conflict file
  process_next_conflict(1)

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

  -- Define a function to handle final cleanup and completion
  local function finalize_rebase(success, error)
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

  -- Store the finalize function in the context
  context.finalize_rebase = finalize_rebase

  -- Define a function to handle the rebase process
  local function continue_rebase_process()
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

    -- Define a recursive function to handle resolution attempts
    local function attempt_resolution()
      -- Use resolve_conflicts with a callback
      resolve_conflicts(context, opts, function(resolution_success, resolution_err)
        if resolution_success then
          -- If resolution was successful, continue the rebase process
          continue_rebase_process()
        else
          -- Check if we've reached max attempts
          if context.current_attempt >= context.max_attempts then
            -- Report completion with failure
            context.finalize_rebase(false, resolution_err or "Failed to resolve conflicts")
          else
            -- Try again with the next attempt
            -- resolve_conflicts will increment the attempt counter
            attempt_resolution()
          end
        end
      end)
    end

    -- Start the resolution process
    attempt_resolution()
  end

  -- Start the rebase process
  continue_rebase_process()

  -- No direct return values - fully asynchronous pattern
  -- All completion handling is done through callbacks
end

return M

