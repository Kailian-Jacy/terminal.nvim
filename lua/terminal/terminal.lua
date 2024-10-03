local utils = require("terminal.utils")
local ui = require("terminal.ui")
local active_terminals = require("terminal.active_terminals")

-- TODO!!!: filetype/bufname/project_marker jobs

---@class Terminal
---@field layout table
---@field bufnr number
---@field job_id number
---@field autoclose boolean
---@field cmd string|table
---@field clear_env boolean
---@field cwd string | function
---@field env table
---@field on_exit function
---@field on_stdout function
---@field on_stderr function
local Terminal = {
    layout = { open_cmd = "botright new" },
    cmd = { vim.o.shell, "-l" },
    autoclose = false,
}

---Instantiate a new terminal
---@param term nil | table
---@return Terminal
function Terminal:new(term)
    local config = require("terminal").config
    term = vim.tbl_deep_extend("force", config, term or {})
    setmetatable(term, { __index = self })
    return term
end

---Spawn a new terminal: assign a jobid and bufnr and insert it into active_terminals
---@return boolean
function Terminal:_spawn()
    local cmd = self.cmd
    local opts = {
        detach = 1,
        cwd = type(self.cwd) == "function" and self:cwd() or self.cwd,
        clear_env = self.clear_env,
        env = self.env,
        on_exit = self.on_exit,
        on_stdout = self.on_stdout,
        on_stderr = self.on_stderr,
    }
    -- vim.api.nvim_create_autocmd("TermOpen", {
    --     pattern = '*',
    --     callback = function(args)
    --         print(args.match)
    --         self.jobid = vim.b[args.buf].terminal_job_id
    --         self.bufnr = args.buf
    --         self.title = vim.b[args.buf].term_title
    --         active_terminals[self.jobid] = self
    --         return true
    --     end,
    -- })
    local jobid = vim.fn.termopen(cmd, opts)

    -- on_term_open runs now
    if jobid > 0 then
        self.jobid = jobid
        self.bufnr = vim.api.nvim_get_current_buf()
        self.title = vim.b.term_title
        active_terminals[jobid] = self
        return true
    end
    return false
end

---Return true if the terminal was spawned (has a jobid and bufnr)
---@return boolean
function Terminal:is_attached()
    return self.bufnr and self.jobid
end

---Get the ids of windows displaying the terminal
---@return table window_ids
function Terminal:get_windows()
    if self.bufnr then
        return vim.fn.win_findbuf(self.bufnr)
    end
    return {}
end

---Get the terminal's current index within the sorted active_terminals list
---@return number|nil
function Terminal:get_index()
    return active_terminals:get_term_index(self)
end

---Get the ids of window displaying the terminal in the current tab
---@return table window_ids
--WARN: method is coupled with get_windows
function Terminal:get_current_tab_windows()
    local windows = {}
    for _, winid in ipairs(self:get_windows()) do
        if utils.win_is_in_current_tab(winid) then
            table.insert(windows, winid)
        end
    end
    return windows
end

---Display the terminal in the current tab
---if the terminal was not spawned, it will be spawned
---if the terminal is already displayed, the first window containing it will be focused
---if force is true, a new window for the terminal will always be displayed.
---if layout is given, the terminal will be displayed in the given layout
---@param layout? table
---@param force? boolean
function Terminal:open(layout, force)
    local _, winid = next(self:get_current_tab_windows())
    if winid and not force then
        vim.api.nvim_set_current_win(winid)
        return
    end
    layout = vim.tbl_deep_extend("force", self.layout, layout or {})
    local new_bufnr, new_winid = ui.make_buf_and_win(layout)

    if not self:is_attached() then
        local ok = self:_spawn()
        if not ok then
            vim.notify("Terminal: failed to spawn terminal job", vim.log.levels.ERROR)
        end
    else
        vim.api.nvim_win_set_buf(new_winid, self.bufnr)
        vim.api.nvim_buf_delete(new_bufnr, { force = true })
    end
end

---Close the (first) window in the current tab displaying the terminal
function Terminal:close()
    local _, winid = next(self:get_current_tab_windows())
    if not winid then
        return
    end
    local ok, err = pcall(vim.api.nvim_win_close, winid, true) -- WARN: error won't block window closing
    if not ok then
        vim.notify("Terminal: " .. err, vim.log.levels.ERROR)
        return
    end
    self.winid = nil
end

---Toggle terminal window
---@param layout? table
---@param force? boolean
function Terminal:toggle(layout, force)
    if next(self:get_current_tab_windows()) then
        self:close()
    else
        self:open(layout, force)
    end
end

---Close terminal window and kill the process
function Terminal:kill()
    if not self:is_attached() then
        return
    end
    local ok, confirm = pcall(vim.fn.input, string.format("Terminal: Kill terminal %s? [y/n]: ", self.title))
    if not ok or not confirm:match("^[yY][eE]?[sS]?$") then
        return
    end
    self:close()
    vim.fn.jobstop(self.jobid)
    vim.api.nvim_buf_delete(self.bufnr, { force = true })
    -- on_term_close will handle cleanup
end

---Send data to the terminal
---@param data string | table<string>
function Terminal:send(data)
    data = utils.unindent(data)
    data = utils.skip_blank_lines(data)
    data = utils.add_newline(data)
    vim.fn.chansend(self.jobid, data)
end

---Autocommand to intercept opened terminals
---that were not instances of Terminal
---_spawn() will override the new terminal.
---@param bufnr integer
function Terminal:on_term_open(bufnr)
    local jobid = vim.b[bufnr].terminal_job_id
    if not jobid then
        return
    end
    local title = vim.b[bufnr].term_title
    local info = vim.api.nvim_get_chan_info(jobid)
    local cmd = info.argv
    -- get window layout ?
    active_terminals[jobid] = self:new({
        cmd = cmd,
        jobid = jobid,
        bufnr = bufnr,
        title = title,
    })
end

---autocommand to ensure closed terminals are always removed from active_terminals
---@param bufnr integer
function Terminal:on_term_close(bufnr)
    local idx, term = active_terminals:get_term_by_bufnr(bufnr)
    print("on_term_close", bufnr, idx, term)
    print('active_terminals', vim.inspect(active_terminals))
    if not term then
        return
    end
    if term.autoclose then
        term:close()
        vim.schedule(function()
            vim.api.nvim_buf_delete(bufnr, { force = false })
        end)
    end
    term.bufnr = nil
    term.jobid = nil
    active_terminals[idx] = nil
end

return Terminal
