local api, lsp = vim.api, vim.lsp
local saga_conf = require('lspsaga').config
local util = {}
local saga_augroup = require('lspsaga').saga_augroup

util.iswin = vim.loop.os_uname().sysname == 'Windows_NT'
util.ismac = vim.loop.os_uname().sysname == 'Darwin'

util.path_sep = util.iswin and '\\' or '/'

function util.get_path_info(buf, level)
  level = level or 1
  local fname = api.nvim_buf_get_name(buf)
  local tbl = vim.split(fname, util.path_sep, { trimempty = true })
  if level == 1 then
    return { tbl[#tbl] }
  end
  local index = level > #tbl and #tbl or level
  return { unpack(tbl, #tbl - index + 1, #tbl) }
end

--get icon hlgroup color
function util.icon_from_devicon(ft, color)
  color = color ~= nil and color or false
  if not util.devicons then
    local ok, devicons = pcall(require, 'nvim-web-devicons')
    if not ok then
      return { '' }
    end
    util.devicons = devicons
  end
  local icon, hl = util.devicons.get_icon_by_filetype(ft)
  if color then
    local _, rgb = util.devicons.get_icon_color_by_filetype(ft)
    return { icon and icon .. ' ' or '', rgb }
  end
  return { icon and icon .. ' ' or '', hl }
end

function util.get_home_dir()
  if util.is_win then
    return os.getenv('USERPROFILE')
  end
  return os.getenv('HOME')
end

function util.tbl_index(tbl, val)
  for index, v in pairs(tbl) do
    if v == val then
      return index
    end
  end
end

function util.has_value(filetypes, val)
  if type(filetypes) == 'table' then
    for _, v in pairs(filetypes) do
      if v == val then
        return true
      end
    end
  elseif type(filetypes) == 'string' then
    if filetypes == val then
      return true
    end
  end
  return false
end

function util.check_lsp_active(silent)
  silent = silent or true
  local current_buf = api.nvim_get_current_buf()
  local active_clients = lsp.get_active_clients({ bufnr = current_buf })
  if next(active_clients) == nil then
    if not silent then
      vim.notify('[LspSaga] Current buffer does not have any lsp server')
    end
    return false
  end
  return true
end

function util.merge_table(t1, t2)
  for _, v in pairs(t2) do
    table.insert(t1, v)
  end
end

function util.get_lsp_root_dir()
  if not util.check_lsp_active() then
    return
  end

  local cur_buf = api.nvim_get_current_buf()
  local clients = lsp.get_active_clients({ bufnr = cur_buf })
  for _, client in pairs(clients) do
    if client.config.filetypes and client.config.root_dir then
      if util.has_value(client.config.filetypes, vim.bo[cur_buf].filetype) then
        return client.config.root_dir
      end
    else
      for name, fts in pairs(saga_conf.server_filetype_map) do
        for _, ft in pairs(fts) do
          if ft == vim.bo.filetype and client.config.name == name and client.config.root_dir then
            return client.config.root_dir
          end
        end
      end
    end
  end
  return nil
end

function util.get_config_lsp_filetypes()
  local ok, lsp_config = pcall(require, 'lspconfig.configs')
  if not ok then
    return
  end

  local filetypes = {}
  for _, config in pairs(lsp_config) do
    if config.filetypes then
      for _, ft in pairs(config.filetypes) do
        table.insert(filetypes, ft)
      end
    end
  end

  if next(saga_conf.server_filetype_map) == nil then
    return filetypes
  end

  for _, fts in pairs(saga_conf.server_filetype_map) do
    if type(fts) == 'table' then
      for _, ft in pairs(fts) do
        table.insert(filetypes, ft)
      end
    elseif type(fts) == 'string' then
      table.insert(filetypes, fts)
    end
  end

  return filetypes
end

function util.close_preview_autocmd(bufnr, winids, events, callback)
  api.nvim_create_autocmd(events, {
    group = saga_augroup,
    buffer = bufnr,
    once = true,
    callback = function()
      local window = require('lspsaga.window')
      window.nvim_close_valid_window(winids)
      if callback then
        callback()
      end
    end,
  })
end

function util.find_buffer_by_filetype(ft)
  local all_bufs = vim.fn.getbufinfo()
  local filetype = ''
  for _, bufinfo in pairs(all_bufs) do
    filetype = api.nvim_buf_get_option(bufinfo['bufnr'], 'filetype')

    if type(ft) == 'table' and util.has_value(ft, filetype) then
      return true, bufinfo['bufnr']
    end

    if filetype == ft then
      return true, bufinfo['bufnr']
    end
  end

  return false, nil
end

function util.removeElementByKey(tbl, key)
  local tmp = {}

  for i in pairs(tbl) do
    table.insert(tmp, i)
  end

  local newTbl = {}
  local i = 1
  while i <= #tmp do
    local val = tmp[i]
    if val == key then
      table.remove(tmp, i)
    else
      newTbl[val] = tbl[val]
      i = i + 1
    end
  end
  return newTbl
end

function util.generate_empty_table(length)
  local empty_tbl = {}
  if length == 0 then
    return empty_tbl
  end

  for _ = 1, length do
    table.insert(empty_tbl, '   ')
  end
  return empty_tbl
end

function util.add_client_filetypes(client, fts)
  if not client.config.filetypes then
    client.config.filetypes = fts
  end
end

-- get client by capabilities
function util.get_client_by_cap(caps)
  local client_caps = {
    ['string'] = function(instance)
      util.add_client_filetypes(instance, { vim.bo.filetype })
      if
        instance.server_capabilities[caps]
        and util.has_value(instance.config.filetypes, vim.bo.filetype)
      then
        return instance
      end
      return nil
    end,
    ['table'] = function(instance)
      util.add_client_filetypes(instance, { vim.bo.filetype })
      if
        vim.tbl_get(instance.server_capabilities, unpack(caps))
        and util.has_value(instance.config.filetypes, vim.bo.filetype)
      then
        return instance
      end
      return nil
    end,
  }

  local clients = lsp.get_active_clients({ bufnr = 0 })
  local client
  for _, instance in pairs(clients) do
    client = client_caps[type(caps)](instance)
    if client ~= nil then
      break
    end
  end
  return client
end

local function feedkeys(key)
  local k = api.nvim_replace_termcodes(key, true, false, true)
  api.nvim_feedkeys(k, 'x', false)
end

function util.scroll_in_preview(bufnr, preview_winid)
  local config = require('lspsaga').config
  if preview_winid and api.nvim_win_is_valid(preview_winid) then
    for i, map in ipairs({ config.scroll_preview.scroll_down, config.scroll_preview.scroll_up }) do
      api.nvim_buf_set_keymap(bufnr, 'n', map, '', {
        noremap = true,
        nowait = true,
        callback = function()
          if api.nvim_win_is_valid(preview_winid) then
            api.nvim_win_call(preview_winid, function()
              local key = i == 1 and '<C-d>' or '<C-u>'
              feedkeys(key)
            end)
            return
          end
          util.delete_scroll_map(bufnr)
        end,
      })
    end
  end
end

function util.delete_scroll_map(bufnr)
  local config = require('lspsaga').config
  pcall(api.nvim_buf_del_keymap, bufnr, 'n', config.scroll_preview.scroll_down)
  pcall(api.nvim_buf_del_keymap, bufnr, 'n', config.scroll_preview.scroll_up)
end

function util.jump_beacon(bufpos, width)
  if not saga_conf.beacon.enable then
    return
  end

  if width == 0 or not width then
    return
  end

  local opts = {
    relative = 'win',
    bufpos = bufpos,
    height = 1,
    width = width,
    row = 0,
    col = 0,
    anchor = 'NW',
    focusable = false,
    no_size_override = true,
    noautocmd = true,
  }

  local window = require('lspsaga.window')
  local _, winid = window.create_win_with_border({
    contents = { '' },
    noborder = true,
    winblend = 0,
    highlight = {
      normal = 'SagaBeacon',
    },
  }, opts)

  local timer = vim.loop.new_timer()
  timer:start(
    0,
    60,
    vim.schedule_wrap(function()
      if not api.nvim_win_is_valid(winid) then
        return
      end
      local blend = vim.wo[winid].winblend + saga_conf.beacon.frequency
      if blend > 100 then
        blend = 100
      end
      vim.wo[winid].winblend = blend
      if vim.wo[winid].winblend == 100 and not timer:is_closing() then
        timer:stop()
        timer:close()
        api.nvim_win_close(winid, true)
      end
    end)
  )
end

function util.gen_truncate_line(width)
  local char = '─'
  return char:rep(math.floor(width / api.nvim_strwidth(char)))
end

return util