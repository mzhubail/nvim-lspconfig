-- This entire module will only be usfeul for Nvim older than 0.11, since vim.lsp.config makes this module obsolete. So
-- it's easier to just disable all warnings for now and remove this file when it's no longer relevant.
--- @diagnostic disable: assign-type-mismatch
--- @diagnostic disable: param-type-mismatch

local util = require 'lspconfig.util'
local async = require 'lspconfig.async'
local api, lsp, fn = vim.api, vim.lsp, vim.fn
local tbl_deep_extend = vim.tbl_deep_extend

local configs = {}

--- @alias lspconfig.Config.command {[1]:string|fun(args: vim.api.keyset.create_user_command.command_args)}|vim.api.keyset.user_command

--- @class lspconfig.Config : vim.lsp.ClientConfig
--- @field enabled? boolean
--- @field single_file_support? boolean
--- @field silent? boolean
--- @field filetypes? string[]
--- @field filetype? string
--- @field on_new_config? fun(new_config: lspconfig.Config?, new_root_dir: string)
--- @field autostart? boolean
--- @field package _on_attach? fun(client: vim.lsp.Client, bufnr: integer)
--- @field root_dir? string|fun(filename: string, bufnr: number)
--- @field commands? table<string, lspconfig.Config.command>

---@param t table
---@param config_name string
---@param config_def table Config definition read from `lspconfig.configs.<name>`.
function configs.__newindex(t, config_name, config_def)
  if config_def.default_config.deprecate then
    vim.deprecate(
      config_name,
      config_def.default_config.deprecate.to,
      config_def.default_config.deprecate.version,
      'lspconfig',
      false
    )
  end

  config_def.commands = config_def.commands or {}

  local M = {}

  local default_config = tbl_deep_extend('keep', config_def.default_config, util.default_config)

  -- Force this part.
  default_config.name = config_name

  --- @param user_config lspconfig.Config
  function M.setup(user_config)
    local lsp_group = api.nvim_create_augroup('lspconfig', { clear = false })

    local config = tbl_deep_extend('keep', user_config, default_config)

    if util.on_setup then
      pcall(util.on_setup, config, user_config)
    end

    if config.autostart == true then
      local event_conf = config.filetypes and { event = 'FileType', pattern = config.filetypes }
        or { event = 'BufReadPost' }
      api.nvim_create_autocmd(event_conf.event, {
        pattern = event_conf.pattern or '*',
        callback = function(opt)
          M.manager:try_add(opt.buf, nil, config.silent)
        end,
        group = lsp_group,
        desc = string.format(
          'Checks whether server %s should start a new instance or attach to an existing one.',
          config.name
        ),
      })
    end

    local get_root_dir = config.root_dir

    function M.launch(bufnr)
      bufnr = bufnr or api.nvim_get_current_buf()
      if not api.nvim_buf_is_valid(bufnr) then
        return
      end
      local bufname = api.nvim_buf_get_name(bufnr)
      if (#bufname == 0 and not config.single_file_support) or (#bufname ~= 0 and not util.bufname_valid(bufname)) then
        return
      end

      local pwd = vim.uv.cwd()

      async.run(function()
        local root_dir
        if type(get_root_dir) == 'function' then
          root_dir = get_root_dir(vim.fs.normalize(bufname), bufnr)
          async.reenter()
          if not api.nvim_buf_is_valid(bufnr) then
            return
          end
        elseif type(get_root_dir) == 'string' then
          root_dir = get_root_dir
        end

        if root_dir then
          api.nvim_create_autocmd('BufReadPost', {
            pattern = fn.fnameescape(root_dir) .. '/*',
            callback = function(arg)
              if #M.manager:clients() == 0 then
                return true
              end
              M.manager:try_add_wrapper(arg.buf, root_dir)
            end,
            group = lsp_group,
            desc = string.format(
              'Checks whether server %s should attach to a newly opened buffer inside workspace %q.',
              config.name,
              root_dir
            ),
          })

          for _, buf in ipairs(api.nvim_list_bufs()) do
            local buf_name = api.nvim_buf_get_name(buf)
            if util.bufname_valid(buf_name) then
              local buf_dir = vim.fs.normalize(buf_name)
              if buf_dir:sub(1, root_dir:len()) == root_dir then
                M.manager:try_add_wrapper(buf, root_dir)
              end
            end
          end
        elseif config.single_file_support then
          -- This allows on_new_config to use the parent directory of the file
          -- Effectively this is the root from lspconfig's perspective, as we use
          -- this to attach additional files in the same parent folder to the same server.
          -- We just no longer send rootDirectory or workspaceFolders during initialization.
          if not api.nvim_buf_is_valid(bufnr) or (#bufname ~= 0 and not util.bufname_valid(bufname)) then
            return
          end
          local pseudo_root = #bufname == 0 and pwd or vim.fs.dirname(vim.fs.normalize(bufname))
          M.manager:add(pseudo_root, true, bufnr, config.silent)
        end
      end)
    end

    -- Used by :LspInfo (evil, mutable aliases?)
    M.get_root_dir = get_root_dir
    M.filetypes = config.filetypes
    M.handlers = config.handlers
    M.cmd = config.cmd
    M.autostart = config.autostart

    -- In the case of a reload, close existing things.
    local reload = false
    if M.manager then
      for _, client in ipairs(M.manager:clients()) do
        client.stop(true)
      end
      reload = true
      M.manager = nil
    end

    local make_config = function(root_dir)
      local new_config = tbl_deep_extend('keep', vim.empty_dict(), config) --[[@as lspconfig.Config]]
      new_config.capabilities = tbl_deep_extend('keep', new_config.capabilities, {
        workspace = {
          configuration = true,
        },
      })

      if config_def.on_new_config then
        pcall(config_def.on_new_config, new_config, root_dir)
      end
      if config.on_new_config then
        pcall(config.on_new_config, new_config, root_dir)
      end

      new_config.on_init = util.add_hook_after(new_config.on_init, function(client, result)
        -- Handle offset encoding by default
        if result.offsetEncoding then
          client.offset_encoding = result.offsetEncoding
        end

        -- Send `settings` to server via workspace/didChangeConfiguration
        function client.workspace_did_change_configuration(settings)
          if not settings then
            return
          end
          if vim.tbl_isempty(settings) then
            settings = { [vim.type_idx] = vim.types.dictionary }
          end
          return client.notify('workspace/didChangeConfiguration', {
            settings = settings,
          })
        end
      end)

      -- Save the old _on_attach so that we can reference it via the BufEnter.
      new_config._on_attach = new_config.on_attach
      new_config.on_attach = function(client, bufnr)
        if bufnr == api.nvim_get_current_buf() then
          M._setup_buffer(client.id, bufnr)
        else
          if api.nvim_buf_is_valid(bufnr) then
            api.nvim_create_autocmd('BufEnter', {
              callback = function()
                M._setup_buffer(client.id, bufnr)
              end,
              group = lsp_group,
              buffer = bufnr,
              once = true,
              desc = 'Reattaches the server with the updated configurations if changed.',
            })
          end
        end
      end

      new_config.root_dir = root_dir
      new_config.workspace_folders = {
        {
          uri = vim.uri_from_fname(root_dir),
          name = string.format('%s', root_dir),
        },
      }
      return new_config
    end

    local manager = require('lspconfig.manager').new(config, make_config)

    M.manager = manager
    M.make_config = make_config
    if reload and config.autostart ~= false then
      for _, bufnr in ipairs(api.nvim_list_bufs()) do
        manager:try_add_wrapper(bufnr)
      end
    end
  end

  function M._setup_buffer(client_id, bufnr)
    local client = lsp.get_client_by_id(client_id)
    if not client then
      return
    end
    local config = client.config --[[@as lspconfig.Config]]
    if config._on_attach then
      config._on_attach(client, bufnr)
    end
    if client.config.commands and not vim.tbl_isempty(client.config.commands) then
      M.commands = vim.tbl_deep_extend('force', M.commands, client.config.commands)
    end
    if not M.commands_created and not vim.tbl_isempty(M.commands) then
      util.create_module_commands(config_name, M.commands)
    end
  end

  M.commands = config_def.commands
  M.name = config_name
  -- Expose the (original?) values of a config (non-active, or before `setup()`).
  M.config_def = config_def
  M.document_config = config_def -- For back-compat.

  rawset(t, config_name, M)
end

return setmetatable({}, configs)
