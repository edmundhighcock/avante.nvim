## Implementation Plan

### 1. Fix the `log_rebase_update` Function

The `log_rebase_update` function is responsible for logging updates during the rebase process, but it doesn't properly use the `on_messages_add` callback to update the sidebar.

```lua
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

  -- Prepare a detailed, user-friendly message with emoji and clear formatting
  local message_content = string.format(
    "🔄 Intelligent Rebase Update\n- Stage: %s\n- Details: %s\n- Progress: %d%%\n%s",
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
  end

  -- Support on_state_change callback for updating the state in the sidebar
  if context.on_state_change then
    pcall(context.on_state_change, update.stage)
  end
end
```

### 2. Update the `IntelligentRebaseContext` Class Definition

Add new fields to the context to support state management and message passing:

```lua
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
```

### 3. Fix Initialization in the `func` Function

Ensure proper initialization of the context and handling of initialization errors:

```lua
---@type AvanteLLMToolFunc<{ source_branch: string, target_branch: string, max_attempts?: integer }>
function M.func(input, opts)
  opts = opts or {}
  local on_log = opts.on_log
  local on_complete = opts.on_complete
  local on_messages_add = opts.on_messages_add
  local on_state_change = opts.on_state_change
  local session_ctx = opts.session_ctx

  -- Track the overall result and error state
  local is_success = false
  local resolution_logs = {}
  local final_error = nil

  local context, init_err = initialize_rebase(
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

    -- Complete with error
    if on_complete then
      pcall(function()
        on_complete(is_success, error_str)
      end)
    end

    return is_success, final_error
  end

  -- Add on_log, on_messages_add, and on_state_change callbacks to context for updates
  context.on_log = on_log
  context.on_messages_add = on_messages_add
  context.on_state_change = on_state_change
  context.history_messages = {}
```

### 4. Improve State Management in Subfunctions

Update the `initialize_rebase` function to properly track state:

```lua
local function initialize_rebase(source_branch, target_branch, max_attempts)
  local context = {
    source_branch = sanitize_branch_name(source_branch),
    target_branch = sanitize_branch_name(target_branch),
    current_attempt = 0,
    max_attempts = max_attempts or 3,
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

  -- ... (existing validation code)

  log_rebase_update(context, {
    stage = "initializing",
    details = "Rebase context successfully initialized",
    progress = 25,
  })

  return context, nil
end
```

### 5. Fix Completion Signaling

Ensure proper completion signaling at the end of the `func` function:

```lua
  -- If rebase was not successful after all attempts, rollback
  if not is_success then
    safe_rollback(context)
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

  -- If on_complete is provided, call it with the results
  if on_complete then
    -- Use pcall to handle potential errors
    pcall(function()
      on_complete(is_success, error_message)
    end)
  end

  -- If on_complete is not provided, return the results directly
  if not on_complete then
    if final_error then
      return is_success, final_error
    end
    return is_success, nil
  end
```

### 6. Update the `detect_conflicts` and `resolve_conflicts` Functions

Ensure these functions also properly update the state and log messages:

```lua
local function detect_conflicts(context)
  log_rebase_update(context, {
    stage = "detecting_conflicts",
    details = "Scanning repository for merge conflicts",
    progress = 50,
  })

  -- ... (existing code)
end

local function resolve_conflicts(context, opts)
  context.current_attempt = context.current_attempt + 1

  log_rebase_update(context, {
    stage = "resolving_conflicts",
    details = string.format("Attempting to resolve conflicts (Attempt %d/%d)", context.current_attempt, context.max_attempts),
    progress = 25,
    files = context.conflict_files
  })

  -- ... (existing code)
end
```

### 7. Update the `safe_rollback` Function

Ensure the rollback function also properly updates the state:

```lua
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
```

## Expected Results

After implementing these changes, the `intelligent_rebase` tool should:

1. Provide real-time updates in the sidebar during operation
2. Properly display the current state of the rebase process
3. Correctly handle errors and display them in the sidebar
4. Successfully signal completion to the sidebar, preventing it from hanging

The user will see a much more responsive interface with clear progress indicators and status updates throughout the rebase process.

## Testing Plan

1. Test successful rebase scenario
2. Test rebase with conflicts that are successfully resolved
3. Test rebase with conflicts that cannot be resolved
4. Test rebase with initialization errors
5. Test rebase with other error conditions
6. Verify that the sidebar updates correctly in all scenarios
7. Verify that the sidebar doesn't hang when the tool completes

## Conclusion

The issues with the `intelligent_rebase` tool are primarily related to improper message passing, state management, and completion signaling. By implementing the proposed changes, the tool will provide real-time updates in the sidebar during operation and will properly signal completion, preventing the sidebar from hanging.

