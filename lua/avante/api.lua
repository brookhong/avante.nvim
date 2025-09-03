local Config = require("avante.config")
local Utils = require("avante.utils")
local PromptInput = require("avante.ui.prompt_input")
local CursorSpinner = require("avante.ui.cursor_spinner")

---@class avante.ApiToggle
---@operator call(): boolean
---@field debug ToggleBind.wrap
---@field hint ToggleBind.wrap

---@class avante.Api
---@field toggle avante.ApiToggle
local M = {}

---@param target_provider avante.SelectorProvider
function M.switch_selector_provider(target_provider)
  require("avante.config").override({
    selector = {
      provider = target_provider,
    },
  })
end

---@param target_provider avante.InputProvider
function M.switch_input_provider(target_provider)
  require("avante.config").override({
    input = {
      provider = target_provider,
    },
  })
end

---@param target avante.ProviderName
function M.switch_provider(target) require("avante.providers").refresh(target) end

---@param path string
local function to_windows_path(path)
  local winpath = path:gsub("/", "\\")

  if winpath:match("^%a:") then winpath = winpath:sub(1, 2):upper() .. winpath:sub(3) end

  winpath = winpath:gsub("\\$", "")

  return winpath
end

---@param opts? {source: boolean}
function M.build(opts)
  opts = opts or { source = true }
  local dirname = Utils.trim(string.sub(debug.getinfo(1).source, 2, #"/init.lua" * -1), { suffix = "/" })
  local git_root = vim.fs.find(".git", { path = dirname, upward = true })[1]
  local build_directory = git_root and vim.fn.fnamemodify(git_root, ":h") or (dirname .. "/../../")

  if opts.source and not vim.fn.executable("cargo") then
    error("Building avante.nvim requires cargo to be installed.", 2)
  end

  ---@type string[]
  local cmd
  local os_name = Utils.get_os_name()

  if vim.tbl_contains({ "linux", "darwin" }, os_name) then
    cmd = {
      "sh",
      "-c",
      string.format("make BUILD_FROM_SOURCE=%s -C %s", opts.source == true and "true" or "false", build_directory),
    }
  elseif os_name == "windows" then
    build_directory = to_windows_path(build_directory)
    cmd = {
      "powershell",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      string.format("%s\\Build.ps1", build_directory),
      "-WorkingDirectory",
      build_directory,
      "-BuildFromSource",
      string.format("%s", opts.source == true and "true" or "false"),
    }
  else
    error("Unsupported operating system: " .. os_name, 2)
  end

  ---@type integer
  local pid
  local exit_code = { 0 }

  local ok, job_or_err = pcall(vim.system, cmd, { text = true }, function(obj)
    local stderr = obj.stderr and vim.split(obj.stderr, "\n") or {}
    local stdout = obj.stdout and vim.split(obj.stdout, "\n") or {}
    if vim.tbl_contains(exit_code, obj.code) then
      local output = stdout
      if #output == 0 then
        table.insert(output, "")
        Utils.debug("build output:", output)
      else
        Utils.debug("build error:", stderr)
      end
    end
  end)
  if not ok then Utils.error("Failed to build the command: " .. cmd .. "\n" .. job_or_err, { once = true }) end
  pid = job_or_err.pid
  return pid
end

---@class AskOptions
---@field question? string optional questions
---@field win? table<string, any> windows options similar to |nvim_open_win()|
---@field ask? boolean
---@field floating? boolean whether to open a floating input to enter the question
---@field new_chat? boolean whether to open a new chat
---@field without_selection? boolean whether to open a new chat without selection
---@field sidebar_pre_render? fun(sidebar: avante.Sidebar)
---@field sidebar_post_render? fun(sidebar: avante.Sidebar)
---@field project_root? string optional project root
---@field show_logo? boolean whether to show the logo

function M.full_view_ask()
  M.ask({
    show_logo = true,
    sidebar_post_render = function(sidebar)
      sidebar:toggle_code_window()
      -- vim.wo[sidebar.containers.result.winid].number = true
      -- vim.wo[sidebar.containers.result.winid].relativenumber = true
    end,
  })
end

M.zen_mode = M.full_view_ask

---@param opts? AskOptions
function M.ask(opts)
  -- to avoid duplicate UUID generated from math.random in avante.utils for different messages
  math.randomseed(os.time())
  opts = opts or {}
  Config.ask_opts = opts
  if type(opts) == "string" then
    Utils.warn("passing 'ask' as string is deprecated, do {question = '...'} instead", { once = true })
    opts = { question = opts }
  end

  local has_question = opts.question ~= nil and opts.question ~= ""
  local new_chat = opts.new_chat == true

  if Utils.is_sidebar_buffer(0) and not has_question and not new_chat then
    require("avante").close_sidebar()
    return false
  end

  opts = vim.tbl_extend("force", { selection = Utils.get_visual_selection_and_range() }, opts)

  ---@param input string | nil
  local function ask(input)
    if input == nil or input == "" then input = opts.question end
    local sidebar = require("avante").get()
    if sidebar and sidebar:is_open() and sidebar.code.bufnr ~= vim.api.nvim_get_current_buf() then
      sidebar:close({ goto_code_win = false })
    end
    require("avante").open_sidebar(opts)
    sidebar = require("avante").get()
    if new_chat then sidebar:new_chat() end
    if opts.without_selection then
      sidebar.code.selection = nil
      sidebar.file_selector:reset()
      if sidebar.containers.selected_files then sidebar.containers.selected_files:unmount() end
    end
    if input == nil or input == "" then return true end
    vim.api.nvim_exec_autocmds("User", { pattern = "AvanteInputSubmitted", data = { request = input } })
    return true
  end

  if opts.floating == true or (Config.windows.ask.floating == true and not has_question and opts.floating == nil) then
    local prompt_input = PromptInput:new({
      submit_callback = function(input) ask(input) end,
      close_on_submit = true,
      win_opts = {
        border = Config.windows.ask.border,
        title = { { "Avante Ask", "FloatTitle" } },
      },
      start_insert = Config.windows.ask.start_insert,
      default_value = opts.question,
    })
    prompt_input:open()
    return true
  end

  return ask()
end

---@param request? string
---@param line1? integer
---@param line2? integer
function M.edit(request, line1, line2)
  local _, selection = require("avante").get()
  if not selection then require("avante")._init(vim.api.nvim_get_current_tabpage()) end
  _, selection = require("avante").get()
  if not selection then return end
  selection:create_editing_input(request, line1, line2)
  if request ~= nil and request ~= "" then
    vim.api.nvim_exec_autocmds("User", { pattern = "AvanteEditSubmitted", data = { request = request } })
  end
end

---@return avante.Suggestion | nil
function M.get_suggestion()
  local _, _, suggestion = require("avante").get()
  return suggestion
end

---@param opts? AskOptions
function M.refresh(opts)
  opts = opts or {}
  local sidebar = require("avante").get()
  if not sidebar then return end
  if not sidebar:is_open() then return end
  local curbuf = vim.api.nvim_get_current_buf()

  local focused = sidebar.containers.result.bufnr == curbuf or sidebar.containers.input.bufnr == curbuf
  if focused or not sidebar:is_open() then return end
  local listed = vim.api.nvim_get_option_value("buflisted", { buf = curbuf })

  if Utils.is_sidebar_buffer(curbuf) or not listed then return end

  local curwin = vim.api.nvim_get_current_win()

  sidebar:close()
  sidebar.code.winid = curwin
  sidebar.code.bufnr = curbuf
  sidebar:render(opts)
end

---@param opts? AskOptions
function M.focus(opts)
  opts = opts or {}
  local sidebar = require("avante").get()
  if not sidebar then return end

  local curbuf = vim.api.nvim_get_current_buf()
  local curwin = vim.api.nvim_get_current_win()

  if sidebar:is_open() then
    if curbuf == sidebar.containers.input.bufnr then
      if sidebar.code.winid and sidebar.code.winid ~= curwin then vim.api.nvim_set_current_win(sidebar.code.winid) end
    elseif curbuf == sidebar.containers.result.bufnr then
      if sidebar.code.winid and sidebar.code.winid ~= curwin then vim.api.nvim_set_current_win(sidebar.code.winid) end
    else
      if sidebar.containers.input.winid and sidebar.containers.input.winid ~= curwin then
        vim.api.nvim_set_current_win(sidebar.containers.input.winid)
      end
    end
  else
    if sidebar.code.winid then vim.api.nvim_set_current_win(sidebar.code.winid) end
    ---@cast opts SidebarOpenOptions
    sidebar:open(opts)
    if sidebar.containers.input.winid then vim.api.nvim_set_current_win(sidebar.containers.input.winid) end
  end
end

function M.select_model() require("avante.model_selector").open() end

function M.select_history()
  local buf = vim.api.nvim_get_current_buf()
  require("avante.history_selector").open(buf, function(filename)
    vim.api.nvim_buf_call(buf, function()
      if not require("avante").is_sidebar_open() then require("avante").open_sidebar({}) end
      local Path = require("avante.path")
      Path.history.save_latest_filename(buf, filename)
      local sidebar = require("avante").get()
      sidebar:update_content_with_history()
      sidebar:create_todos_container()
      sidebar:initialize_token_count()
      vim.schedule(function() sidebar:focus_input() end)
    end)
  end)
end

function M.add_buffer_files()
  local sidebar = require("avante").get()
  if not sidebar then
    require("avante.api").ask()
    sidebar = require("avante").get()
  end
  if not sidebar:is_open() then sidebar:open({}) end
  sidebar.file_selector:add_buffer_files()
end

function M.add_selected_file(filepath)
  local rel_path = Utils.uniform_path(filepath)

  local sidebar = require("avante").get()
  if not sidebar then
    require("avante.api").ask()
    sidebar = require("avante").get()
  end
  if not sidebar:is_open() then sidebar:open({}) end
  sidebar.file_selector:add_selected_file(rel_path)
end

function M.remove_selected_file(filepath)
  ---@diagnostic disable-next-line: undefined-field
  local stat = vim.uv.fs_stat(filepath)
  local files
  if stat and stat.type == "directory" then
    files = Utils.scan_directory({ directory = filepath, add_dirs = true })
  else
    files = { filepath }
  end

  local sidebar = require("avante").get()
  if not sidebar then
    require("avante.api").ask()
    sidebar = require("avante").get()
  end
  if not sidebar:is_open() then sidebar:open({}) end

  for _, file in ipairs(files) do
    local rel_path = Utils.uniform_path(file)
    sidebar.file_selector:remove_selected_file(rel_path)
  end
end

function M.stop() require("avante.llm").cancel_inflight_request() end

local spinner = CursorSpinner:new({
  highlight_group = "IncSearch",
  spinner_chars = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  virt_text_pos = "overlay",
})
--- Explains the selected code directly using LLM and displays the result in a floating window
---@param opts? {system_prompt: string?, user_template: string?, selection: string?, filetype: string?, win_opts?: table} Optional parameters with selection and filetype
function M.explain(opts)
  opts = opts or {}

  -- Return early if spinner is already active
  if spinner.spinner_active then return end

  local api = vim.api

  -- Get the selected code if not provided
  local content_to_explain = opts.selection
  if not content_to_explain then
    local selection = Utils.get_visual_selection_and_range()
    if selection then
      if
        selection.range.start.lnum == selection.range.finish.lnum
        and selection.range.start.col < selection.range.finish.col
      then
        content_to_explain = selection.content:sub(selection.range.start.col, selection.range.finish.col)
      else
        content_to_explain = selection.content
      end
    else
      content_to_explain = ""
    end
    vim.api.nvim_input("<Esc>")
  end

  if content_to_explain == "" then
    Utils.warn("No code selected to explain.")
    return
  end

  -- Variables for delayed window creation
  local result_bufnr
  local response_content = ""

  local cursor_win = vim.api.nvim_get_current_win()

  spinner:start()

  -- Prepare the system prompt
  local system_prompt = opts.system_prompt and opts.system_prompt
    or [[
You are an expert coding assistant. Your task is to explain the provided code.
Be concise but thorough. Focus on:
1. What the code does
2. Key functions or variables
3. Any patterns or techniques being used
4. Potential issues or optimizations

Keep your explanation clear and to the point.
]]

  -- Prepare the user prompt
  -- Add filetype context if available
  local filetype = opts.filetype and opts.filetype or vim.bo.filetype

  local user_template = opts.user_template and opts.user_template
    or "The code is written in <FILE_TYPE>.\nExplain this code:\n\n<SELECTION>"
  local user_prompt = user_template:gsub("<FILE_TYPE>", filetype):gsub("<SELECTION>", content_to_explain)
    or content_to_explain

  local Llm = require("avante.llm")
  local provider = require("avante.providers")[Config.provider]

  -- Function to create the window and buffer
  local function create_window_and_buffer()
    if result_bufnr then return end

    -- Switch back to the buffer where LLM started if needed
    local current_bufnr = vim.api.nvim_get_current_buf()
    if current_bufnr ~= spinner.bufnr and vim.api.nvim_buf_is_valid(spinner.bufnr) then
      -- Find a window containing the buffer
      local win_with_buf = nil
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == spinner.bufnr then
          win_with_buf = win
          break
        end
      end

      if win_with_buf then vim.api.nvim_set_current_win(win_with_buf) end
    end

    -- Use the cursor position directly (which is where the spinner is displayed)
    local screen_row, screen_col

    -- Get the screen position directly from the cursor position we stored earlier
    if vim.api.nvim_win_is_valid(cursor_win) then
      -- Convert cursor position to screen coordinates
      local pos = vim.fn.screenpos(cursor_win, spinner.row + 1, spinner.col + 1)
      screen_row = pos.row - 1 -- Convert to 0-indexed for nvim_open_win
      screen_col = pos.col - 1 -- Convert to 0-indexed for nvim_open_win
    else
      -- Fallback to center of screen
      screen_row = math.floor((vim.o.lines - 20) / 2)
      screen_col = math.floor((vim.o.columns - 80) / 2)
    end

    spinner:stop()
    -- Create a buffer for the explanation
    result_bufnr = api.nvim_create_buf(false, true)
    vim.bo[result_bufnr].bufhidden = "wipe"
    vim.bo[result_bufnr].filetype = "markdown"

    -- Adjust position to ensure window is visible
    local width = 80
    local height = 20

    -- Ensure the window doesn't go off-screen
    if screen_col + width > vim.o.columns then screen_col = vim.o.columns - width - 2 end
    if screen_row + height > vim.o.lines then screen_row = vim.o.lines - height - 2 end

    local win_opts = vim.tbl_deep_extend("force", {
      relative = "editor",
      width = width,
      height = height,
      col = screen_col,
      row = screen_row,
      style = "minimal",
      border = Config.windows.edit.border,
      title = { { "Explanation from " .. Config.provider, "FloatTitle" } },
      title_pos = "center",
      footer = { { "Press q or <Esc> to close this window", "FloatFooter" } },
      footer_pos = "right",
    }, opts.win_opts or {})

    -- Create the window
    local winid = api.nvim_open_win(result_bufnr, true, win_opts)

    -- Set window options
    vim.wo[winid].wrap = true
    vim.wo[winid].conceallevel = 2
    vim.wo[winid].concealcursor = "n"
    vim.wo[winid].winfixbuf = true

    -- Add keymaps to close the window
    local function close_window()
      if api.nvim_win_is_valid(winid) then api.nvim_win_close(winid, true) end
    end

    api.nvim_buf_set_keymap(result_bufnr, "n", "q", "", {
      callback = close_window,
      noremap = true,
      silent = true,
    })

    api.nvim_buf_set_keymap(result_bufnr, "n", "<Esc>", "", {
      callback = close_window,
      noremap = true,
      silent = true,
    })
  end

  Llm.curl({
    provider = provider,
    prompt_opts = {
      system_prompt = system_prompt,
      messages = {
        {
          role = "user",
          content = user_prompt,
        },
      },
    },
    handler_opts = {
      on_start = function(_) end,
      on_chunk = function(chunk)
        if not chunk then return end

        -- Append the chunk to our accumulated response
        response_content = response_content .. chunk

        -- Create window on first chunk if not already created
        create_window_and_buffer()

        if not result_bufnr or not api.nvim_buf_is_valid(result_bufnr) then return end

        -- Update the buffer with the current content
        vim.bo[result_bufnr].modifiable = true
        local lines = vim.split(response_content, "\n")
        api.nvim_buf_set_lines(result_bufnr, 0, -1, false, lines)
        vim.bo[result_bufnr].modifiable = false
      end,
      on_stop = function(stop_opts)
        -- Stop the spinner if it's still active
        spinner:stop()

        -- Create window if not already created (in case we got no chunks but have an error)
        create_window_and_buffer()

        if not result_bufnr or not api.nvim_buf_is_valid(result_bufnr) then return end

        vim.bo[result_bufnr].modifiable = true

        if stop_opts.error ~= nil then
          local error_message = "Error explaining code: " .. vim.inspect(stop_opts.error)
          api.nvim_buf_set_lines(result_bufnr, 0, -1, false, vim.split(error_message, "\n"))
        elseif stop_opts.reason == "complete" then
          -- Clean up the response if needed
          response_content = Utils.trim(response_content)
          api.nvim_buf_set_lines(result_bufnr, 0, -1, false, vim.split(response_content, "\n"))
        elseif stop_opts.reason == "cancelled" then
          api.nvim_buf_set_lines(result_bufnr, 0, -1, false, { "Code explanation was cancelled." })
        end

        vim.bo[result_bufnr].modifiable = false
      end,
    },
  })
end

return setmetatable(M, {
  __index = function(t, k)
    local module = require("avante")
    ---@class AvailableApi: ApiCaller
    ---@field api? boolean
    local has = module[k]
    if type(has) ~= "table" or not has.api then
      Utils.warn(k .. " is not a valid avante's API method", { once = true })
      return
    end
    t[k] = has
    return t[k]
  end,
}) --[[@as avante.Api]]
