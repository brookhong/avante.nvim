local P = require("avante.providers")

local M = {}

M.role_map = {
  user = "user",
  assistant = "assistant",
}

M.parse_messages = P.openai.parse_messages
M.is_o_series_model = P.openai.is_o_series_model

function M:is_disable_stream() return false end

function M:parse_curl_args(prompt_opts)
  local provider_conf, request_body = P.parse_config(self)
  return {
    url = provider_conf.endpoint .. "/chat",
    headers = {
      ["Accept"] = "application/json",
      ["Content-Type"] = "application/json",
    },
    body = {
      model = provider_conf.model,
      options = {
        num_ctx = 16384,
      },
      messages = self:parse_messages(prompt_opts),
      stream = true,
    },
  }
end

function M:parse_stream_data(ctx, data, opts)
  local json_data = vim.fn.json_decode(data)
  if json_data then
    if json_data.done then
      vim.schedule(function() opts.on_stop({ reason = "complete" }) end)
    elseif json_data.message and json_data.message.content then
      local content = json_data.message.content
      opts.on_chunk(content)
    end
  end
end

return M
