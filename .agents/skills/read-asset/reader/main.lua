-- Windowless inspector. Read generated logical bytes through CacheFs so
-- physical compression, checksums, and version confinement stay canonical.
local function parse(argv)
  local opts = {}
  local valid = { ["--repo-root"] = "root", ["--version"] = "version", ["--path"] = "path", ["--output"] = "output", ["--list"] = "list" }
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
  if (opts.path ~= nil) == (opts.list ~= nil) or (opts.path ~= nil) ~= (opts.output ~= nil) then
    error("reader requires either --list DIRECTORY or --path FILE --output FILE")
  end
  return opts
end

local function readAsset(cacheFs, path, output)
  local bytes = cacheFs:read(path)
  if bytes == nil then
    error("cache file is absent after preparation: " .. path)
  end
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
  local digest = love.data.hash("sha1", bytes):gsub(".", function(char)
    return string.format("%02x", char:byte())
  end)
  print("decoded_file=" .. output)
  print("cache_path=" .. path)
  print("bytes=" .. #bytes)
  print("sha1=" .. digest)
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
    if opts.path then
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
