local api = vim.api
local Config = require("avante.config")

local namespace = api.nvim_create_namespace("avante_cursor_spinner")

---@class avante.ui.CursorSpinner
---@field spinner_chars table
---@field spinner_index integer
---@field spinner_timer uv.uv_timer_t | nil
---@field spinner_active boolean
---@field extmark_id integer | nil
---@field highlight_group string
---@field bufnr integer Buffer number where the spinner was started
local CursorSpinner = {}
CursorSpinner.__index = CursorSpinner

---@class avante.ui.CursorSpinnerOptions
---@field spinner_chars? table
---@field highlight_group? string

---@param opts? avante.ui.CursorSpinnerOptions
function CursorSpinner:new(opts)
  opts = opts or {}
  local obj = setmetatable({}, CursorSpinner)
  obj.spinner_chars = opts.spinner_chars or Config.windows.spinner.editing
  obj.spinner_index = 1
  obj.spinner_timer = nil
  obj.spinner_active = false
  obj.extmark_id = nil
  obj.highlight_group = opts.highlight_group or "IncSearch"
  return obj
end

---Start the spinner at the current cursor position
function CursorSpinner:start()
  self:stop()
  self.spinner_active = true
  self.spinner_index = 1
  self.bufnr = api.nvim_get_current_buf() -- Store the current buffer number
  local cursor_pos = api.nvim_win_get_cursor(0)
  self.row = cursor_pos[1] - 1 -- Convert to 0-indexed
  self.col = cursor_pos[2] -- Already 0-indexed, no need to add 1

  self.spinner_timer = vim.loop.new_timer()
  local spinner_timer = self.spinner_timer

  if self.spinner_timer then
    self.spinner_timer:start(0, 100, function()
      vim.schedule(function()
        if not self.spinner_active or spinner_timer ~= self.spinner_timer then return end
        self.spinner_index = (self.spinner_index % #self.spinner_chars) + 1
        self:update()
      end)
    end)
  end

  -- Initial update to show the spinner immediately
  self:update()
end

---Stop the spinner and remove the virtual text
function CursorSpinner:stop()
  self.spinner_active = false
  if self.spinner_timer then
    self.spinner_timer:stop()
    self.spinner_timer:close()
    self.spinner_timer = nil
  end

  -- Remove the extmark if it exists
  if self.extmark_id then
    api.nvim_buf_del_extmark(self.bufnr, namespace, self.extmark_id)
    self.extmark_id = nil
  end
end

---Update the spinner display
function CursorSpinner:update()
  -- Check if the buffer is valid and visible
  if not self.bufnr or not api.nvim_buf_is_valid(self.bufnr) then
    self:stop()
    return
  end

  -- Check if the buffer where the spinner was started is visible in any window
  local buffer_is_visible = false
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == self.bufnr then
      buffer_is_visible = true
      break
    end
  end

  -- Skip update if the buffer where the spinner was started is not visible
  if not buffer_is_visible then return end

  -- Remove previous extmark if it exists
  if self.extmark_id then pcall(api.nvim_buf_del_extmark, self.bufnr, namespace, self.extmark_id) end

  -- Validate row is within buffer bounds
  local line_count = api.nvim_buf_line_count(self.bufnr)
  if self.row >= line_count then
    self:stop()
    return
  end

  -- Validate column is within line bounds
  local line = api.nvim_buf_get_lines(self.bufnr, self.row, self.row + 1, false)[1] or ""
  local line_length = #line
  local col = math.min(self.col, line_length)

  -- Get current spinner character
  local spinner_char = self.spinner_chars[self.spinner_index]

  -- Set new extmark with virtual text at cursor position
  local opts = {
    virt_text = { { spinner_char, self.highlight_group } },
    virt_text_pos = "overlay",
    priority = 100,
  }

  self.extmark_id = api.nvim_buf_set_extmark(self.bufnr, namespace, self.row, col, opts)
end

---Set custom spinner characters
---@param chars table
function CursorSpinner:set_spinner_chars(chars)
  self.spinner_chars = chars
  self.spinner_index = 1
  if self.spinner_active then self:update() end
end

---Set custom highlight group
---@param highlight_group string
function CursorSpinner:set_highlight_group(highlight_group)
  self.highlight_group = highlight_group
  if self.spinner_active then self:update() end
end

return CursorSpinner
