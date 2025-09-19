# Implementation Plan: Prompt Caching for Claude Models via Copilot Provider

This document outlines the implementation plan for enabling prompt caching for Claude models when accessed through the GitHub Copilot provider in avante.nvim.

## Background

Prompt caching is already successfully implemented for Claude models through:
- The direct Claude provider (`lua/avante/providers/claude.lua`)
- The AWS Bedrock provider (`lua/avante/providers/bedrock/claude.lua`)

This implementation plan extends that functionality to Claude models accessed through the Copilot provider.

## 1. Claude Model Detection in Copilot Provider

First, we need to detect when a Claude model is being used through the Copilot provider:

```lua
-- Add to the Copilot provider (lua/avante/providers/copilot.lua)
-- Function to detect if the current model is a Claude model
function M:is_claude_model()
  local provider_conf = Providers.parse_config(self)
  local model_name = provider_conf.model:lower()
  return model_name:match("claude") ~= nil
end
```

## 2. Add Prompt Caching Support Flag

Add the prompt caching support flag to the Copilot provider:

```lua
-- Add to the Copilot provider (lua/avante/providers/copilot.lua)
M.support_prompt_caching = true
```

## 3. Modify Request Generation for Claude Models

Update the `parse_curl_args` function to handle Claude-specific prompt caching:

```lua
-- Modify in the Copilot provider (lua/avante/providers/copilot.lua)
function M:parse_curl_args(prompt_opts)
  -- Existing code for refreshing tokens and getting provider config

  -- Check if this is a Claude model and if prompt caching is enabled
  local is_claude = self:is_claude_model()
  local prompt_caching_enabled = Config.prompt_caching and
                                Config.prompt_caching.enabled and
                                Config.prompt_caching.providers.copilot

  local headers = self:build_headers()

  -- Add Claude-specific headers for prompt caching if applicable
  if is_claude and prompt_caching_enabled then
    headers["anthropic-beta"] = "prompt-caching-2024-07-31"
  end

  -- Process messages with cache_control for Claude models
  local messages = self:parse_messages(prompt_opts)
  local tools = {}

  -- Add tools processing similar to other providers
  if not disable_tools and prompt_opts.tools then
    for _, tool in ipairs(prompt_opts.tools) do
      table.insert(tools, OpenAI:transform_tool(tool))
    end
  end

  -- Add cache_control to messages if prompt caching is enabled for Claude models
  if is_claude and self.support_prompt_caching and prompt_caching_enabled and #messages > 0 then
    local found = false
    for i = #messages, 1, -1 do
      local message = messages[i]
      message = vim.deepcopy(message)
      -- Handle content differently based on whether it's a string or array
      if type(message.content) == "string" then
        -- For string content, convert to object with cache_control
        if message.role == "user" then
          message.content = {
            { type = "text", text = message.content, cache_control = { type = "ephemeral" } }
          }
          found = true
          break
        end
      else
        -- For array content, add cache_control to the last text item
        for j = #message.content, 1, -1 do
          local item = message.content[j]
          if item.type == "text" then
            item.cache_control = { type = "ephemeral" }
            found = true
            break
          end
        end
      end
      if found then
        messages[i] = message
        break
      end
    end
  end

  -- Add cache_control to tools if prompt caching is enabled for Claude models
  if is_claude and self.support_prompt_caching and prompt_caching_enabled and #tools > 0 then
    local last_tool = vim.deepcopy(tools[#tools])
    last_tool.cache_control = { type = "ephemeral" }
    tools[#tools] = last_tool
  end

  -- Continue with existing request building code
  return {
    url = H.chat_completion_url(M.state.github_token.endpoints.api or provider_conf.endpoint),
    timeout = provider_conf.timeout,
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    headers = Utils.tbl_override(headers, self.extra_headers),
    body = vim.tbl_deep_extend("force", {
      model = provider_conf.model,
      messages = messages,
      stream = true,
      tools = tools,
    }, request_body),
  }
end
```

## 4. Implement Token Usage Tracking

Add token usage tracking for cached prompts:

```lua
-- Add to the Copilot provider (lua/avante/providers/copilot.lua)
-- If the provider already has a response parsing function, modify it to handle cache stats

-- Reuse or adapt the Claude provider's transform_anthropic_usage function
function M.transform_copilot_claude_usage(usage)
  if not usage then return nil end

  -- Calculate cache stats
  local cache_hit_tokens = usage.cache_read_input_tokens or 0
  local cache_write_tokens = usage.cache_creation_input_tokens or 0
  local total_input_tokens = usage.input_tokens or 0
  local cache_hit_rate = total_input_tokens > 0 and (cache_hit_tokens / total_input_tokens) or 0

  -- Record stats for visualization
  if not M.cache_stats then M.cache_stats = {} end
  table.insert(M.cache_stats, {
    timestamp = os.time(),
    cache_hit_tokens = cache_hit_tokens,
    cache_write_tokens = cache_write_tokens,
    total_input_tokens = total_input_tokens,
    cache_hit_rate = cache_hit_rate
  })

  -- Return usage info with cache metrics
  return {
    prompt_tokens = total_input_tokens + cache_write_tokens,
    completion_tokens = usage.output_tokens,
    cache_hit_tokens = cache_hit_tokens,
    cache_write_tokens = cache_write_tokens,
    cache_hit_rate = cache_hit_rate
  }
end
```

## 5. Update Configuration

Update the configuration to include Copilot in the prompt caching providers list:

```lua
-- Modify in config.lua
M._defaults = {
  -- existing config...
  prompt_caching = {
    enabled = true,  -- Global enable/disable
    providers = {
      claude = true,
      bedrock = true,
      copilot = true  -- Add this line
    }
  },
  -- rest of the config...
}
```

## 6. Testing Approach

1. Test with different Claude models through Copilot:
   - Test with Claude 3 Sonnet, Claude 3 Opus, etc.
   - Verify prompt caching headers are correctly added
   - Verify cache_control is correctly added to messages and tools

2. Test with non-Claude models through Copilot:
   - Verify that Claude-specific modifications are not applied
   - Ensure normal functionality is maintained

3. Test with prompt caching disabled:
   - Set `Config.prompt_caching.enabled = false` and verify no caching occurs
   - Set `Config.prompt_caching.providers.copilot = false` and verify no caching occurs

4. Test token usage tracking:
   - Verify cache hit rates are correctly calculated
   - Verify stats are recorded for visualization

## 7. Documentation Updates

Add documentation explaining prompt caching for Claude models through Copilot:

1. Update any relevant documentation files
2. Add examples of how to configure prompt caching for Copilot
3. Document any limitations or considerations specific to Copilot's implementation

## Implementation Notes

- This implementation follows the same patterns used in the existing Claude and Bedrock provider implementations
- The detection of Claude models is based on the model name containing "claude" (case-insensitive)
- The implementation adds the necessary headers and message modifications only when a Claude model is detected
- Token usage tracking is implemented to monitor cache hit rates and performance improvements

## Potential Challenges

1. **API Compatibility**: The Copilot API might handle Claude models differently than direct API access. Testing with actual Claude models through Copilot will be necessary.

2. **Headers Passthrough**: It's unclear from the documentation whether the Copilot API passes through all headers to the underlying Claude API. This will need to be verified.

3. **Model Detection**: The current implementation relies on the model name containing "claude". This might need refinement based on how Copilot names Claude models.

4. **Response Format**: The response format for cached prompts might differ between direct Claude access and Copilot access. The token usage tracking will need to account for these differences.

