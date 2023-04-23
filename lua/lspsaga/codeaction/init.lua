local api, lsp = vim.api, vim.lsp
local config = require('lspsaga').config
local window = require('lspsaga.window')
local nvim_buf_set_keymap = api.nvim_buf_set_keymap
local preview = require('lspsaga.codeaction.preview')
local util = require('lspsaga.util')

local act = {}
local ctx = {}

act.__index = act
function act.__newindex(t, k, v)
  rawset(t, k, v)
end

local function clean_ctx()
  for k, _ in pairs(ctx) do
    ctx[k] = nil
  end
end

local function clean_msg(msg)
  if msg:find('%(.+%)%S$') then
    return msg:gsub('%(.+%)%S$', '')
  end
  return msg
end

function act:check_server_support_codeaction(bufnr)
  local clients = lsp.get_active_clients({ bufnr = bufnr })
  for _, client in ipairs(clients) do
    if not client.config.filetypes and next(config.server_filetype_map) ~= nil then
      for _, fts in ipairs(config.server_filetype_map) do
        if util.has_value(fts, vim.bo[bufnr].filetype) then
          client.config.filetypes = fts
          break
        end
      end
    end

    if
      client.supports_method('textDocument/codeAction')
      and util.has_value(client.config.filetypes, vim.bo[bufnr].filetype)
    then
      return true
    end
  end

  return false
end

function act:action_callback()
  local contents = {}

  for index, client_with_actions in pairs(self.action_tuples) do
    local action_title = ''
    if #client_with_actions ~= 2 then
      vim.notify('There is something wrong in aciton_tuples')
      return
    end
    if client_with_actions[2].title then
      action_title = '[' .. index .. '] ' .. clean_msg(client_with_actions[2].title)
    end
    if config.code_action.show_server_name == true then
      if type(client_with_actions[1]) == 'string' then
        action_title = action_title .. '  (' .. client_with_actions[1] .. ')'
      else
        action_title = action_title
          .. '  ('
          .. lsp.get_client_by_id(client_with_actions[1]).name
          .. ')'
      end
    end
    contents[#contents + 1] = action_title
  end

  local content_opts = {
    contents = contents,
    filetype = 'sagacodeaction',
    buftype = 'nofile',
    enter = true,
    highlight = {
      normal = 'CodeActionNormal',
      border = 'CodeActionBorder',
    },
  }

  local opt = {}
  local max_height = math.floor(vim.o.lines * 0.5)
  opt.height = max_height < #contents and max_height or #contents
  local max_width = math.floor(vim.o.columns * 0.7)
  local max_len = window.get_max_content_length(contents)
  opt.width = max_len + 10 < max_width and max_len + 5 or max_width
  opt.no_size_override = true

  if config.ui.title then
    opt.title = {
      { config.ui.code_action .. ' CodeActions', 'TitleString' },
    }
  end

  self.action_bufnr, self.action_winid = window.create_win_with_border(content_opts, opt)
  vim.wo[self.action_winid].conceallevel = 2
  vim.wo[self.action_winid].concealcursor = 'niv'
  -- initial position in code action window
  api.nvim_win_set_cursor(self.action_winid, { 1, 1 })

  api.nvim_create_autocmd('CursorMoved', {
    buffer = self.action_bufnr,
    callback = function()
      self:set_cursor()
    end,
  })

  for i = 1, #contents, 1 do
    local row = i - 1
    local col = contents[i]:find('%]')
    api.nvim_buf_add_highlight(self.action_bufnr, -1, 'CodeActionText', row, 0, -1)
    api.nvim_buf_add_highlight(self.action_bufnr, 0, 'CodeActionNumber', row, 0, col)
  end

  self:apply_action_keys()
  if config.code_action.num_shortcut then
    self:num_shortcut(self.action_bufnr)
  end
end

local function map_keys(mode, keys, action, options)
  if type(keys) == 'string' then
    keys = { keys }
  end
  for _, key in ipairs(keys) do
    vim.keymap.set(mode, key, action, options)
  end
end

---@private
---@param bufnr integer
---@param mode "v"|"V"
---@return table {start={row, col}, end={row, col}} using (1, 0) indexing
local function range_from_selection(bufnr, mode)
  -- TODO: Use `vim.region()` instead https://github.com/neovim/neovim/pull/13896
  -- [bufnum, lnum, col, off]; both row and column 1-indexed
  local start = vim.fn.getpos('v')
  local end_ = vim.fn.getpos('.')
  local start_row = start[2]
  local start_col = start[3]
  local end_row = end_[2]
  local end_col = end_[3]

  -- A user can start visual selection at the end and move backwards
  -- Normalize the range to start < end
  if start_row == end_row and end_col < start_col then
    end_col, start_col = start_col, end_col
  elseif end_row < start_row then
    start_row, end_row = end_row, start_row
    start_col, end_col = end_col, start_col
  end
  if mode == 'V' then
    start_col = 1
    local lines = api.nvim_buf_get_lines(bufnr, end_row - 1, end_row, true)
    end_col = #lines[1]
  end
  return {
    ['start'] = { start_row, start_col - 1 },
    ['end'] = { end_row, end_col - 1 },
  }
end

function act:send_request(main_buf, options, callback)
  self.bufnr = main_buf
  local params
  local mode = api.nvim_get_mode().mode
  if options.range then
    assert(type(options.range) == 'table', 'code_action range must be a table')
    local start = assert(options.range.start, 'range must have a `start` property')
    local end_ = assert(options.range['end'], 'range must have an `end` property')
    params = lsp.util.make_given_range_params(start, end_)
  elseif mode == 'v' or mode == 'V' then
    local range = range_from_selection(0, mode)
    params = lsp.util.make_given_range_params(range.start, range['end'])
  else
    params = lsp.util.make_range_params()
  end
  params.context = options.context

  self.enriched_ctx = { bufnr = main_buf, method = 'textDocument/codeAction', params = params }

  lsp.buf_request_all(main_buf, 'textDocument/codeAction', params, function(results)
    self.pending_request = false
    self.action_tuples = {}

    for client_id, result in pairs(results) do
      for _, action in pairs(result.result or {}) do
        self.action_tuples[#self.action_tuples + 1] = { client_id, action }
      end
    end

    if config.code_action.extend_gitsigns then
      local res = self:extend_gitsign(params)
      if res then
        for _, action in pairs(res) do
          self.action_tuples[#self.action_tuples + 1] = { 'gitsigns', action }
        end
      end
    end

    if #self.action_tuples == 0 then
      vim.notify('No code actions available', vim.log.levels.INFO)
      return
    end

    if callback then
      callback(vim.deepcopy(self.action_tuples), vim.deepcopy(self.enriched_ctx))
    end
  end)
end

local function get_num()
  local num
  local cur_text = api.nvim_get_current_line()
  num = cur_text:match('%[(%d+)%]%s+%S')
  if num then
    num = tonumber(num)
  end
  return num
end

function act:set_cursor()
  local col = 1
  local current_line = api.nvim_win_get_cursor(self.action_winid)[1]

  if current_line == #self.action_tuples + 1 then
    api.nvim_win_set_cursor(self.action_winid, { 1, col })
  else
    api.nvim_win_set_cursor(self.action_winid, { current_line, col })
  end

  local num = get_num()
  if not num or not self.action_tuples[num] then
    return
  end
  local tuple = self.action_tuples[num]
  preview.action_preview(self.action_winid, self.bufnr, 'CodeActionBorder', tuple)
end

local function apply_action(action, client, enriched_ctx)
  if action.edit then
    lsp.util.apply_workspace_edit(action.edit, client.offset_encoding)
  end
  if action.command then
    local command = type(action.command) == 'table' and action.command or action
    local func = client.commands[command.command] or lsp.commands[command.command]
    if func then
      enriched_ctx.client_id = client.id
      func(command, enriched_ctx)
    else
      local params = {
        command = command.command,
        arguments = command.arguments,
        workDoneToken = command.workDoneToken,
      }
      client.request('workspace/executeCommand', params, nil, enriched_ctx.bufnr)
    end
  end
  clean_ctx()
end

local function do_code_action(action, client, enriched_ctx)
  if
    not action.edit
    and client
    and vim.tbl_get(client.server_capabilities, 'codeActionProvider', 'resolveProvider')
  then
    client.request('codeAction/resolve', action, function(err, resolved_action)
      if err then
        vim.notify(err.code .. ': ' .. err.message, vim.log.levels.ERROR)
        return
      end
      apply_action(resolved_action, client, enriched_ctx)
    end)
  elseif action.action and type(action.action) == 'function' then
    action.action()
  else
    apply_action(action, client, enriched_ctx)
  end
end

function act:do_code_action(action, client, enriched_ctx)
  do_code_action(action, client, enriched_ctx)
end

function act:apply_action_keys()
  map_keys('n', config.code_action.keys.exec, function()
    local num = get_num()
    if not num then
      return
    end
    local action = vim.deepcopy(self.action_tuples[num][2])
    local client = lsp.get_client_by_id(self.action_tuples[num][1])
    self:close_action_window()
    do_code_action(action, client)
  end, { buffer = self.action_bufnr })

  map_keys('n', config.code_action.keys.quit, function()
    self:close_action_window()
    clean_ctx()
  end, { buffer = self.action_bufnr })
end

function act:num_shortcut(bufnr)
  for num, _ in pairs(self.action_tuples or {}) do
    nvim_buf_set_keymap(bufnr, 'n', tostring(num), '', {
      noremap = true,
      nowait = true,
      callback = function()
        if not self.action_tuples or not self.action_tuples[num] then
          return
        end
        local action = vim.deepcopy(self.action_tuples[num][2])
        local client = lsp.get_client_by_id(self.action_tuples[num][1])
        self:close_action_window()
        do_code_action(action, client)
      end,
    })
  end
end

function act:code_action(options)
  if self.pending_request then
    vim.notify(
      '[lspsaga.nvim] there is already a code action request please wait',
      vim.log.levels.WARN
    )
    return
  end
  self.pending_request = true
  options = options or {}
  if not options.context then
    options.context = {
      diagnostics = require('lspsaga.diagnostic'):get_cursor_diagnostic(),
    }
  end

  self:send_request(api.nvim_get_current_buf(), options, function()
    self:action_callback()
  end)
end

function act:close_action_window()
  if self.action_winid and api.nvim_win_is_valid(self.action_winid) then
    api.nvim_win_close(self.action_winid, true)
  end
  preview.preview_win_close()
end

function act:clean_context()
  clean_ctx()
end

function act:extend_gitsign(params)
  local ok, gitsigns = pcall(require, 'gitsigns')
  if not ok then
    return
  end

  local gitsigns_actions = gitsigns.get_actions()
  if not gitsigns_actions or vim.tbl_isempty(gitsigns_actions) then
    return
  end

  local name_to_title = function(name)
    return name:sub(1, 1):upper() .. name:gsub('_', ' '):sub(2)
  end

  local actions = {}
  local range_actions = { ['reset_hunk'] = true, ['stage_hunk'] = true }
  local mode = vim.api.nvim_get_mode().mode
  for name, action in pairs(gitsigns_actions) do
    local title = name_to_title(name)
    local cb = action
    if (mode == 'v' or mode == 'V') and range_actions[name] then
      title = title:gsub('hunk', 'selection')
      cb = function()
        action({ params.range.start.line, params.range['end'].line })
      end
    end
    actions[#actions + 1] = {
      title = title,
      action = function()
        local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
        vim.api.nvim_buf_call(bufnr, cb)
      end,
    }
  end
  return actions
end

return setmetatable(ctx, act)
