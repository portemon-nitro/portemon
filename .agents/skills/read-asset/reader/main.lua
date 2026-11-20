-- Windowless inspector. Read generated logical bytes through CacheFs so
-- physical compression, checksums, and version confinement stay canonical.
local function parse(argv)
  local opts = {}
  local valid = {
    ["--repo-root"] = "root",
    ["--version"] = "version",
    ["--path"] = "path",
    ["--output"] = "output",
    ["--list"] = "list",
    ["--message-text"] = "messageText",
  }
  if #argv % 2 ~= 0 then
    error("each reader option requires a value")
  end
  for i = 1, #argv, 2 do
    local key = valid[argv[i]]
    if not key or opts[key] ~= nil or not argv[i + 1] or argv[i + 1] == "" then
      error("invalid or duplicate option: " .. tostring(argv[i]))
    end
    opts[key] = argv[i + 1]
  end
  if not opts.root or (opts.version ~= "heartgold" and opts.version ~= "soulsilver") then
    error("reader requires --repo-root and a supported --version")
  end
  local modes = 0
  for _, mode in ipairs({ "path", "list", "messageText" }) do
    if opts[mode] ~= nil then
      modes = modes + 1
    end
  end
  if modes ~= 1 then
    error("reader requires exactly one of --list DIRECTORY, --path FILE, or --message-text BANK")
  end
  if opts.list ~= nil and opts.output ~= nil then
    error("--list takes no --output")
  end
  if opts.list == nil and opts.output == nil then
    error("--path and --message-text require --output FILE")
  end
  return opts
end

-- Writes one output file through the checked open/write/close sequence, so a
-- failed write never leaves a partial decoded file behind.
local function writeOutput(output, bytes)
  local file, openError = io.open(output, "wb")
  if not file then
    error("could not open decoded output: " .. tostring(openError))
  end
  local written, writeError = file:write(bytes)
  local closed, closeError = file:close()
  if not written or not closed then
    os.remove(output)
    error("could not write decoded output: " .. tostring(writeError or closeError))
  end
end

local function sha1hex(bytes)
  return (love.data.hash("sha1", bytes):gsub(".", function(char)
    return string.format("%02x", char:byte())
  end))
end

local function report(cachePath, output, bytes)
  print("decoded_file=" .. output)
  print("cache_path=" .. cachePath)
  print("bytes=" .. #bytes)
  print("sha1=" .. sha1hex(bytes))
end

local function readAsset(cacheFs, path, output)
  local bytes = cacheFs:read(path)
  if bytes == nil then
    error("cache file is absent after preparation: " .. path)
  end
  writeOutput(output, bytes)
  report(path, output, bytes)
end

-- Human-readable export of one compact message bank: the authoritative codec
-- decodes every message in id order, and LuaWriter serializes the result. The
-- export keeps normalized tokens because display text alone cannot show
-- trainer-name packing, control arguments, or tokens after EOS.
local function exportMessages(cacheFs, path, output, modules)
  local FieldMessageCache = modules.FieldMessageCache
  local FieldMessageAsset = modules.FieldMessageAsset
  local digits = path:match("^data/generated/field/messages/banks/(%d+)%.g4msg$")
  if digits == nil then
    error("message export requires one canonical message bank path, got: " .. path)
  end
  local bankId = tonumber(digits)
  if FieldMessageCache.bankPath(bankId) ~= path then
    error("message export requires the canonical bank path for bank " .. tostring(bankId))
  end
  local bytes = cacheFs:read(path)
  if bytes == nil then
    error("cache file is absent after preparation: " .. path)
  end
  FieldMessageAsset.validate(bytes, bankId)
  local view = FieldMessageAsset.open(bytes, bankId)
  local messages = {}
  for messageId = 0, view.messageCount - 1 do
    local template = FieldMessageAsset.message(view, messageId)
    messages[messageId] = { text = template.text, tokens = template.tokens }
  end
  local chunk = modules.LuaWriter.encode({
    bankId = bankId,
    messageCount = view.messageCount,
    messages = messages,
  })
  writeOutput(output, chunk)
  report(path, output, chunk)
end

local function listAssets(cacheFs, directory)
  if not cacheFs:exists(directory, "directory") then
    error("cache directory is absent after preparation: " .. directory)
  end
  local count = 0
  local function walk(path)
    local entries = cacheFs:getDirectoryItems(path)
    table.sort(entries)
    for _, name in ipairs(entries) do
      local child = path == "" and name or path .. "/" .. name
      local info = cacheFs:getInfo(child)
      if info and info.type == "directory" then
        walk(child)
      elseif info and info.type == "file" then
        count = count + 1
        if count > 2000 then
          error("listing exceeds 2000 files; choose a narrower directory")
        end
        print(child)
      end
    end
  end
  walk(directory)
  print("listed_files=" .. count)
end

function love.load(argv)
  local ok, result = pcall(function()
    local opts = parse(argv)
    package.path = opts.root .. "/?.lua;" .. opts.root .. "/?/init.lua;" .. package.path
    local CacheFs = require("libs.storage.src.CacheFs")
    local cacheFs = CacheFs.forVersion(opts.version)
    if opts.messageText then
      exportMessages(cacheFs, opts.messageText, opts.output, {
        FieldMessageCache = require("libs.assets.src.field.FieldMessageCache"),
        FieldMessageAsset = require("libs.assets.src.field.FieldMessageAsset"),
        LuaWriter = require("libs.codec.src.LuaWriter"),
      })
    elseif opts.path then
      readAsset(cacheFs, opts.path, opts.output)
    else
      listAssets(cacheFs, opts.list)
    end
  end)
  if not ok then
    io.stderr:write("read-asset: " .. tostring(result) .. "\n")
    love.event.quit(1)
  else
    love.event.quit(0)
  end
end
