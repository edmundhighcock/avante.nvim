local stub = require("luassert.stub")
local match = require("luassert.match")

describe("dispatch_full_agent", function()
  local DispatchFullAgent
  local Config
  local Providers
  local DispatchAgent
  local init
  local config_stub
  local providers_stub
  local dispatch_agent_render_stub
  local dispatch_agent_execute_stub
  local init_get_tools_stub

  before_each(function()
    -- Reset package cache to get fresh modules
    package.loaded["avante.llm_tools.dispatch_full_agent"] = nil
    package.loaded["avante.config"] = nil
    package.loaded["avante.providers"] = nil
    package.loaded["avante.llm_tools.dispatch_agent"] = nil
    package.loaded["avante.llm_tools.init"] = nil

    -- Load modules
    Config = require("avante.config")
    Providers = require("avante.providers")
    DispatchAgent = require("avante.llm_tools.dispatch_agent")
    init = require("avante.llm_tools.init")

    -- Setup default config
    Config.provider = "claude"
    Config.disabled_tools = {}
    Config.custom_tools = {}
    Config.lazy_loading = { enabled = false }

    -- Setup default providers
    Providers.claude = { model = "claude-3-5-sonnet-20241022" }
    Providers.copilot = { model = "gpt-4o" }
    Providers.openai = { model = "gpt-4o" }

    -- Stub the dispatch agent functions
    dispatch_agent_render_stub = stub(DispatchAgent, "_render_agent_task")
    dispatch_agent_execute_stub = stub(DispatchAgent, "_execute_agent_loop")

    -- Stub init.get_tools to return a controlled set of tools
    init_get_tools_stub = stub(init, "get_tools")
    init_get_tools_stub.returns({
      { name = "glob" },
      { name = "grep" },
      { name = "ls" },
      { name = "view" },
      { name = "str_replace" },
      { name = "write_to_file" },
      { name = "bash" },
      { name = "read_todos" },
      { name = "write_todos" },
      { name = "dispatch_agent" },
      { name = "dispatch_full_agent" },
      { name = "git_diff" },
      { name = "git_commit" },
      { name = "web_search" },
      { name = "attempt_completion" },
    })

    -- Now load the module under test
    DispatchFullAgent = require("avante.llm_tools.dispatch_full_agent")
  end)

  after_each(function()
    -- Restore stubs
    if dispatch_agent_render_stub then dispatch_agent_render_stub:revert() end
    if dispatch_agent_execute_stub then dispatch_agent_execute_stub:revert() end
    if init_get_tools_stub then init_get_tools_stub:revert() end
  end)

  describe("get_description", function()
    it("should return short description for copilot with gpt model", function()
      Config.provider = "copilot"
      Providers.copilot = { model = "gpt-4o" }

      local description = DispatchFullAgent.get_description()

      assert.is_string(description)
      assert.is_true(#description > 0)
      -- Should be shorter and not contain the detailed rules
      assert.is_nil(description:match("EXCLUDED TOOLS"))
    end)

    it("should return full description for claude provider", function()
      Config.provider = "claude"

      local description = DispatchFullAgent.get_description()

      assert.is_string(description)
      -- Should contain the full description with rules
      assert.is_true(description:match("EXCLUDED TOOLS") ~= nil)
      assert.is_true(description:match("RULES:") ~= nil)
      assert.is_true(description:match("OBJECTIVE:") ~= nil)
    end)

    it("should return full description for openai provider", function()
      Config.provider = "openai"

      local description = DispatchFullAgent.get_description()

      assert.is_string(description)
      assert.is_true(description:match("EXCLUDED TOOLS") ~= nil)
    end)

    it("should mention excluded tools in full description", function()
      Config.provider = "claude"

      local description = DispatchFullAgent.get_description()

      assert.is_true(description:match("bash") ~= nil)
      assert.is_true(description:match("read_todos") ~= nil)
      assert.is_true(description:match("write_todos") ~= nil)
      assert.is_true(description:match("dispatch_agent") ~= nil)
      assert.is_true(description:match("dispatch_full_agent") ~= nil)
    end)
  end)

  describe("param", function()
    it("should have correct parameter structure", function()
      assert.equals("table", DispatchFullAgent.param.type)
      assert.equals(1, #DispatchFullAgent.param.fields)
      assert.equals("prompt", DispatchFullAgent.param.fields[1].name)
      assert.equals("string", DispatchFullAgent.param.fields[1].type)
      assert.equals("The task for the agent to perform", DispatchFullAgent.param.fields[1].description)
    end)

    it("should have prompt as required field", function()
      assert.is_true(vim.tbl_contains(DispatchFullAgent.param.required, "prompt"))
    end)
  end)

  describe("returns", function()
    it("should have correct return structure", function()
      assert.equals(2, #DispatchFullAgent.returns)

      local result_return = DispatchFullAgent.returns[1]
      assert.equals("result", result_return.name)
      assert.equals("string", result_return.type)
      assert.equals("The result of the agent", result_return.description)

      local error_return = DispatchFullAgent.returns[2]
      assert.equals("error", error_return.name)
      assert.equals("string", error_return.type)
      assert.equals("The error message if the agent fails", error_return.description)
      assert.is_true(error_return.optional)
    end)
  end)

  describe("on_render", function()
    it("should call DispatchAgent._render_agent_task with correct parameters", function()
      dispatch_agent_render_stub.returns({})

      local input = { prompt = "test task" }
      local opts = { result_message = "test result", store = {} }

      DispatchFullAgent.on_render(input, opts)

      assert.stub(dispatch_agent_render_stub).was_called(1)
      assert.stub(dispatch_agent_render_stub).was_called_with(input, opts, "Full agent task")
    end)

    it("should pass through the return value from _render_agent_task", function()
      local expected_lines = { "line1", "line2" }
      dispatch_agent_render_stub.returns(expected_lines)

      local input = { prompt = "test task" }
      local opts = {}

      local result = DispatchFullAgent.on_render(input, opts)

      assert.equals(expected_lines, result)
    end)
  end)

  describe("func", function()
    it("should call DispatchAgent._execute_agent_loop with correct parameters", function()
      dispatch_agent_execute_stub.returns(true, nil)

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      DispatchFullAgent.func(input, opts)

      assert.stub(dispatch_agent_execute_stub).was_called(1)

      -- Check the arguments passed to _execute_agent_loop
      local call_args = dispatch_agent_execute_stub.calls[1].vals
      -- Use match.is_table() to check that the arguments are tables with the expected structure
      assert.is_table(call_args[1])
      assert.equals("test task", call_args[1].prompt)
      assert.is_table(call_args[2])

      -- Check the config table
      local config = call_args[3]
      assert.is_table(config.tools)
      assert.is_string(config.system_prompt_template)
      assert.equals("dispatch_full_agent", config.agent_name)
    end)

    it("should pass tools that exclude the forbidden tools", function()
      dispatch_agent_execute_stub.returns(true, nil)

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      DispatchFullAgent.func(input, opts)

      -- Get the tools passed to _execute_agent_loop
      local call_args = dispatch_agent_execute_stub.calls[1].vals
      local config = call_args[3]
      local tools = config.tools

      -- Check that forbidden tools are excluded
      local tool_names = vim.tbl_map(function(tool) return tool.name end, tools)

      assert.is_false(vim.tbl_contains(tool_names, "bash"))
      assert.is_false(vim.tbl_contains(tool_names, "read_todos"))
      assert.is_false(vim.tbl_contains(tool_names, "write_todos"))
      assert.is_false(vim.tbl_contains(tool_names, "dispatch_agent"))
      assert.is_false(vim.tbl_contains(tool_names, "dispatch_full_agent"))
    end)

    it("should pass tools that include allowed tools", function()
      dispatch_agent_execute_stub.returns(true, nil)

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      DispatchFullAgent.func(input, opts)

      -- Get the tools passed to _execute_agent_loop
      local call_args = dispatch_agent_execute_stub.calls[1].vals
      local config = call_args[3]
      local tools = config.tools

      -- Check that allowed tools are included
      local tool_names = vim.tbl_map(function(tool) return tool.name end, tools)

      assert.is_true(vim.tbl_contains(tool_names, "glob"))
      assert.is_true(vim.tbl_contains(tool_names, "grep"))
      assert.is_true(vim.tbl_contains(tool_names, "ls"))
      assert.is_true(vim.tbl_contains(tool_names, "view"))
      assert.is_true(vim.tbl_contains(tool_names, "str_replace"))
      assert.is_true(vim.tbl_contains(tool_names, "write_to_file"))
      assert.is_true(vim.tbl_contains(tool_names, "git_diff"))
      assert.is_true(vim.tbl_contains(tool_names, "git_commit"))
      assert.is_true(vim.tbl_contains(tool_names, "web_search"))
      assert.is_true(vim.tbl_contains(tool_names, "attempt_completion"))
    end)

    it("should use correct system prompt template", function()
      dispatch_agent_execute_stub.returns(true, nil)

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      DispatchFullAgent.func(input, opts)

      -- Get the config passed to _execute_agent_loop
      local call_args = dispatch_agent_execute_stub.calls[1].vals
      local config = call_args[3]

      assert.is_string(config.system_prompt_template)
      assert.is_true(config.system_prompt_template:match("${prompt}") ~= nil)
      assert.is_true(config.system_prompt_template:match("comprehensive set of tools") ~= nil)
    end)

    it("should return the result from _execute_agent_loop", function()
      dispatch_agent_execute_stub.returns(true, nil)

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      local success, err = DispatchFullAgent.func(input, opts)

      assert.is_true(success)
      assert.is_nil(err)
    end)

    it("should propagate errors from _execute_agent_loop", function()
      dispatch_agent_execute_stub.returns(false, "test error")

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      local success, err = DispatchFullAgent.func(input, opts)

      assert.is_false(success)
      assert.equals("test error", err)
    end)
  end)

  describe("name", function()
    it("should have correct name", function() assert.equals("dispatch_full_agent", DispatchFullAgent.name) end)
  end)

  describe("tool filtering", function()
    it("should filter out exactly 5 excluded tools", function()
      dispatch_agent_execute_stub.returns(true, nil)

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      DispatchFullAgent.func(input, opts)

      -- Get the tools passed to _execute_agent_loop
      local call_args = dispatch_agent_execute_stub.calls[1].vals
      local config = call_args[3]
      local tools = config.tools

      -- We started with 15 tools, should have 10 after filtering
      assert.equals(10, #tools)
    end)

    it("should handle empty tools list", function()
      init_get_tools_stub.returns({})
      dispatch_agent_execute_stub.returns(true, nil)

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      DispatchFullAgent.func(input, opts)

      -- Get the tools passed to _execute_agent_loop
      local call_args = dispatch_agent_execute_stub.calls[1].vals
      local config = call_args[3]
      local tools = config.tools

      assert.equals(0, #tools)
    end)

    it("should handle tools list with only excluded tools", function()
      init_get_tools_stub.returns({
        { name = "bash" },
        { name = "read_todos" },
        { name = "write_todos" },
        { name = "dispatch_agent" },
        { name = "dispatch_full_agent" },
      })
      dispatch_agent_execute_stub.returns(true, nil)

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      DispatchFullAgent.func(input, opts)

      -- Get the tools passed to _execute_agent_loop
      local call_args = dispatch_agent_execute_stub.calls[1].vals
      local config = call_args[3]
      local tools = config.tools

      assert.equals(0, #tools)
    end)

    it("should preserve tool properties when filtering", function()
      init_get_tools_stub.returns({
        { name = "glob", description = "glob tool", param = { type = "table" } },
        { name = "bash", description = "bash tool" },
      })
      dispatch_agent_execute_stub.returns(true, nil)

      local input = { prompt = "test task" }
      local opts = { on_log = function() end, on_complete = function() end, session_ctx = {} }

      DispatchFullAgent.func(input, opts)

      -- Get the tools passed to _execute_agent_loop
      local call_args = dispatch_agent_execute_stub.calls[1].vals
      local config = call_args[3]
      local tools = config.tools

      assert.equals(1, #tools)
      assert.equals("glob", tools[1].name)
      assert.equals("glob tool", tools[1].description)
      assert.is_table(tools[1].param)
    end)
  end)
end)

