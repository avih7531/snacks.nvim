local Spawn = require("snacks.util.spawn")

---@class snacks.image.convert
local M = {}

local uv = vim.uv or vim.loop

---@class snacks.image.Info
---@field format string
---@field size snacks.image.Size
---@field dpi snacks.image.Size

---@class snacks.image.convert.Opts
---@field src string

---@class snacks.image.meta
---@field src string
---@field info? snacks.image.Info
---@field [string] string|number|boolean

---@alias snacks.image.args (number|string)[] | fun(): ((number|string)[])

---@class snacks.image.Proc
---@field cmd string
---@field cwd? string
---@field args snacks.image.args

---@class snacks.image.step
---@field name string
---@field file string
---@field ft string
---@field cmd snacks.image.cmd
---@field meta snacks.image.meta
---@field done? boolean
---@field err? string
---@field proc? snacks.spawn.Proc

---@class snacks.image.cmd
---@field cmd (fun(step: snacks.image.step):(snacks.image.Proc|snacks.image.Proc[])?)|snacks.image.Proc|snacks.image.Proc[]
---@field ft? string
---@field file? fun(convert: snacks.image.Convert, meta: snacks.image.meta): string
---@field depends? string[]
---@field on_done? fun(step: snacks.image.step)
---@field on_error? fun(step: snacks.image.step):boolean? when return true, continue to next step
---@field pipe? boolean

---@type table<string, snacks.image.cmd>
local commands = {
  url = {
    cmd = {
      {
        cmd = "curl",
        args = { "-L", "-o", "{file}", "{src}" },
      },
      {
        cmd = "wget",
        args = { "-O", "{file}", "{src}" },
      },
    },
    file = function(convert, ctx)
      local src = M.norm(ctx.src)
      return M.is_uri(src) and convert:tmpfile("data") or src
    end,
  },
  cache = {
    file = function(convert, ctx)
      return convert:tmpfile(convert:ft(ctx.src))
    end,
    cmd = function(step)
      uv.fs_copyfile(step.meta.src, step.file)
    end,
  },
  typ = {
    ft = "pdf",
    cmd = {
      {
        cmd = "typst",
        args = { "compile", "--format", "pdf", "--pages", 1, "{src}", "{file}" },
      },
    },
  },
  tex = {
    ft = "pdf",
    file = function(convert, ctx)
      ctx.pdf = Snacks.image.config.cache .. "/" .. vim.fs.basename(ctx.src):gsub("%.tex$", ".pdf")
      return convert:tmpfile("pdf")
    end,
    cmd = {
      {
        cwd = "{dirname}",
        cmd = "tectonic",
        args = { "-Z", "continue-on-errors", "--outdir", "{cache}", "{src}" },
      },
      {
        cmd = "pdflatex",
        cwd = "{dirname}",
        args = { "-output-directory={cache}", "-interaction=nonstopmode", "{src}" },
      },
    },
    on_done = function(step)
      local pdf = assert(step.meta.pdf, "No pdf file")
      if uv.fs_stat(pdf) then
        uv.fs_rename(pdf, step.file)
      end
    end,
    on_error = function(step)
      local pdf = assert(step.meta.pdf, "No pdf file")
      if step.meta.pdf and vim.fn.getfsize(pdf) > 0 then
        return true
      end
    end,
  },
  mmd = {
    cmd = {
      cmd = "mmdc",
      args = Snacks.image.config.convert.mermaid,
    },
    file = function(convert, ctx)
      return convert:tmpfile(vim.o.background .. ".png")
    end,
  },
  identify = {
    pipe = false,
    file = function(convert, ctx)
      return convert:tmpfile(convert:ft() .. ".info")
    end,
    cmd = {
      {
        cmd = "magick",
        args = { "identify", "-format", "%m %[fx:w]x%[fx:h] %xx%y", "{src}[0]" },
      },
      {
        cmd = "identify",
        args = { "-format", "%m %[fx:w]x%[fx:h] %xx%y", "{src}[0]" },
      },
    },
    on_done = function(step)
      local file = step.file
      if step.proc then
        local fd = assert(io.open(file, "w"), "Failed to open file: " .. file)
        fd:write(step.proc:out())
        fd:close()
      end
      local fd = assert(io.open(file, "r"), "Failed to open file: " .. file)
      local info = vim.trim(fd:read("*a"))
      fd:close()
      local format, w, h, x, y = info:match("^(%w+)%s+(%d+)x(%d+)%s+(%d+%.?%d*)x(%d+%.?%d*)$")
      if not format then
        return
      end
      step.meta.info = {
        format = format:lower(),
        size = { width = tonumber(w) or 0, height = tonumber(h) or 0 },
        dpi = { width = tonumber(x) or 0, height = tonumber(y) or 0 },
      }
    end,
  },
  convert = {
    ft = "png",
    cmd = function(step)
      local formats = vim.deepcopy(Snacks.image.config.convert.magick or {})
      local args = formats.default or { "{src}[0]" }
      local info = step.meta.info
      local format = info and info.format or vim.fn.fnamemodify(step.meta.src, ":e")

      local vector = vim.tbl_contains({ "pdf", "svg", "eps", "ai", "mvg" }, format)
      if vector then
        args = formats.vector or args
      end

      local fts = { vim.fs.basename(step.file):match("%.([^%.]+)%.png") } ---@type string[]
      fts[#fts + 1] = format

      for _, ft in ipairs(fts) do
        local fmt = formats[ft]
        if fmt then
          args = type(fmt) == "function" and fmt() or fmt
          break
        end
      end
      args = type(args) == "function" and args() or args
      ---@cast args (string|number)[]

      vim.list_extend(args, { "-write", "{file}", "-identify", "-format", "%m %[fx:w]x%[fx:h] %xx%y", "{file}.info" })
      return {
        { cmd = "magick", args = args },
        not Snacks.util.is_win and { cmd = "convert", args = args } or nil,
      }
    end,
  },
  plotly = {
    cmd = {
      cmd = "plotly_cli.py",
      args = function()
        return { "{src}", "--output_png", "{file}" }
      end,
    },
    file = function(convert, ctx)
      return convert:tmpfile(vim.o.background .. ".png")
    end,
  },
}

local have = {} ---@type table<string, boolean>

---@class snacks.image.Convert
---@field opts snacks.image.convert.Opts
---@field src string
---@field file string
---@field prefix string
---@field meta snacks.image.meta
---@field steps snacks.image.step[]
---@field _done? boolean
---@field _err? string
---@field tpl_data table<string, string>
local Convert = {}
Convert.__index = Convert

---@param opts snacks.image.convert.Opts
function Convert.new(opts)
  vim.fn.mkdir(Snacks.image.config.cache, "p")
  local self = setmetatable({}, Convert)
  opts.src = M.norm(opts.src)
  self.opts = opts
  self.src = opts.src
  local base = vim.fn.fnamemodify(opts.src, ":t:r")
  if M.is_uri(self.opts.src) then
    base = self.opts.src:gsub("%?.*", ""):match("^%w%w+://(.*)$") or base
  end
  self.prefix = vim.fn.sha256(self.opts.src):sub(1, 8) .. "-" .. base:gsub("[^%w%.]+", "-")
  self.meta = { src = opts.src }
  self.steps = {}
  self.tpl_data = {
    cache = Snacks.image.config.cache,
    bg = vim.o.background,
    scale = tostring(Snacks.image.terminal.size().scale or 1),
  }
  self:resolve()
  return self
end

function Convert:current()
  for _, step in ipairs(self.steps) do
    if not step.done then
      return step
    end
  end
end

function Convert:ready()
  return self:done() and not self:error()
end

function Convert:done()
  return self._done or false
end

function Convert:error()
  return self._err
end

---@param ft string
function Convert:tmpfile(ft)
  return Snacks.image.config.cache .. "/" .. self.prefix .. "." .. ft
end

---@param target string
function Convert:_resolve(target)
  local cmd = assert(commands[target], "No command for target: " .. target)
  assert(cmd.file or cmd.ft, "No file or ft for target: " .. target)
  for _, dep in ipairs(cmd.depends or {}) do
    self:_resolve(dep)
  end
  local file = cmd.file and cmd.file(self, self.meta) or self:tmpfile(cmd.ft)
  ---@type snacks.image.step
  local step = {
    name = target,
    file = file,
    ft = self:ft(file),
    meta = self.meta,
    done = uv.fs_stat(file) ~= nil,
    cmd = cmd,
  }
  if cmd.pipe ~= false then
    self.meta = setmetatable({ src = file }, { __index = self.meta })
  end
  table.insert(self.steps, step)
end

---@param src? string
---@return string
function Convert:ft(src)
  return vim.fn.fnamemodify(src or self.meta.src, ":e"):lower()
end

function Convert:resolve()
  if M.is_uri(self.src) then
    self:_resolve("url")
    self:_resolve("identify")
  end
  while self:ft() ~= "png" do
    local ft = self:ft()
    local target = commands[ft] and ft or "convert"
    if self:_resolve(target) then
      break
    end
  end
  self:_resolve("identify")
  self.file = self.meta.src
end

---@param cb fun(convert: snacks.image.Convert)
function Convert:run(cb)
  if #self.steps == 0 then
    self._done = true
    return cb(self)
  end

  local s = 0
  local next ---@type fun()

  ---@param step? snacks.image.step
  ---@param err? string
  local function done(step, err)
    if step then
      step.done = true
      step.err = err
    end
    if step and err and step.cmd.on_error and step.cmd.on_error(step) then
      -- keep going
    elseif err then
      if Snacks.image.config.convert.notify then
        local title = step and ("Conversion failed at step `%s`"):format(step.name) or "Conversion failed"
        if step and step.proc then
          step.proc:debug({ title = title })
        else
          Snacks.notify.error("# " .. title .. "\n" .. err, { title = "Snacks Image" })
        end
      end
      self._err = err
      self._done = true
      return cb(self)
    end
    if step and step.cmd.on_done then
      step.cmd.on_done(step)
    end
    if s == #self.steps then
      self._done = true
      return cb(self)
    end
    next()
  end

  if not M.is_uri(self.src) and vim.fn.filereadable(self.src) == 0 then
    local f = M.is_uri(self.src) and self.src or vim.fn.fnamemodify(self.src, ":p:~")
    done(nil, ("File not found\n- `%s`"):format(f))
    return
  end

  next = function()
    s = s + 1
    assert(s <= #self.steps, "No more steps")
    local step = self.steps[s]
    step.done = step.done or (uv.fs_stat(step.file) ~= nil)
    if step.done then
      return done(step)
    end

    local cmd = step.cmd.cmd
    if type(cmd) == "function" then
      local ok, c = pcall(cmd, step)
      if ok and c then
        cmd = c
      else
        return done(step, not ok and (c or "error") or nil)
      end
    end

    local cmds = cmd.cmd and { cmd } or cmd
    ---@cast cmds snacks.image.Proc[]
    for _, c in ipairs(cmds) do
      if have[c.cmd] == nil then
        have[c.cmd] = vim.fn.executable(c.cmd) == 1
      end
      if have[c.cmd] then
        local args = type(c.args) == "function" and c.args() or c.args
        ---@cast args (number|string)[]
        args = vim.deepcopy(args)
        local data = vim.tbl_extend("keep", {
          file = step.file,
          basename = vim.fs.basename(step.file),
          name = vim.fn.fnamemodify(step.file, ":t:r"),
          dirname = vim.fs.dirname(step.meta.src),
          src = step.meta.src,
        }, self.tpl_data)
        for a, arg in ipairs(args) do
          if type(arg) == "string" then
            args[a] = Snacks.picker.util.tpl(arg, data)
          end
        end
        step.proc = Spawn.new({
          debug = Snacks.image.config.debug.convert,
          cwd = c.cwd and Snacks.picker.util.tpl(c.cwd, data) or nil,
          cmd = c.cmd,
          args = args,
          on_exit = function(proc, err)
            local out = vim.trim(proc:out() .. "\n" .. proc:err())
            vim.schedule(function()
              done(step, err and out or nil)
            end)
          end,
        })
        return
      end
    end
    return done(step, "No command available")
  end
  next()
end

---@param src string
function M.is_url(src)
  return src:find("^https?://") == 1
end

---@param src string
function M.is_uri(src)
  return src:find("^%w%w+://") == 1
end

---@param src string
function M.norm(src)
  if src:find("^file://") then
    src = vim.uri_to_fname(src)
  end
  if not M.is_uri(src) then
    src = svim.fs.normalize(vim.fn.fnamemodify(src, ":p"))
  end
  return src
end

---@param opts snacks.image.convert.Opts
function M.convert(opts)
  return Convert.new(opts)
end

return M
