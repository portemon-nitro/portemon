-- Opt-in disk read/decode study for generated PNG files.
--
-- Compares, for one sample of already-generated PNG files: stored file
-- bytes, raw decoded RGBA bytes, the private-derivative byte model (index
-- bytes plus palette bytes when the content fits 256 exact colors, else
-- straight RGBA), and -- when a system python3 with zlib is available -- a
-- conventional zlib-compressed size over the same raw bytes. Also reports
-- cold versus warm file-read time, decode time, and classification time.
--
-- Read-only by construction: it never writes into the sample directory,
-- never opens the user ROM, and never imports or mutates the production
-- cache, writer, or pipeline. The writer round-trip check below only
-- *reads* the production encoder through a guarded require to verify the
-- decoded bytes re-encode identically; when that require is unavailable
-- the check is reported as unavailable, never faked.
--
-- Usage (from the repository root):
--   luajit scripts/perf/asset-disk-io-study.lua <derived-png-dir> [max-files]
--
-- The sample directory must hold already-generated PNG files (for example
-- a textures directory inside the private test cache). The script exits
-- nonzero when a sampled file fails to parse, so a corrupt sample is loud
-- instead of silently averaged away.

local DEFAULT_MAX_FILES = 50

local function usage()
  io.stderr:write("usage: luajit scripts/perf/asset-disk-io-study.lua <derived-png-dir> [max-files]\n")
end

local function readU32BE(data, position)
  local a, b, c, d = data:byte(position, position + 3)
  return ((a * 256 + b) * 256 + c) * 256 + d
end

local function readU16LE(data, position)
  local lo, hi = data:byte(position, position + 1)
  return lo + hi * 256
end

-- Adler-32 over a string with plain arithmetic; no bit library needed.
local function adler32(data)
  local a, b = 1, 0
  for index = 1, #data do
    a = (a + data:byte(index)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

-- Decodes one stored-DEFLATE truecolor-alpha PNG (the deterministic shape
-- the project writer emits: 8-bit truecolor with alpha, filter method 0,
-- filter type 0 on every scanline, one zlib stream of stored blocks).
-- Returns width, height, and the raw row-major RGBA bytes. Any other shape
-- raises with the reason named; callers count that file as skipped, never
-- as a zero.
local function decodeStoredPng(path, bytes)
  assert(bytes:sub(1, 8) == "\137PNG\r\n\26\n", path .. ": not a PNG file")
  local position, width, height, idat = 9, nil, nil, {}
  while position <= #bytes do
    if position + 7 > #bytes then
      error(path .. ": truncated chunk header", 0)
    end
    local length, kind = readU32BE(bytes, position), bytes:sub(position + 4, position + 7)
    local dataStart, dataEnd = position + 8, position + 7 + length
    if dataEnd + 4 > #bytes then
      error(path .. ": truncated " .. kind .. " chunk", 0)
    end
    local data = bytes:sub(dataStart, dataEnd)
    if kind == "IHDR" then
      width, height = readU32BE(data, 1), readU32BE(data, 5)
      local depth, color, compression, filter, interlace = data:byte(9, 13)
      if depth ~= 8 or color ~= 6 then
        error(path .. ": unsupported color shape (depth " .. depth .. " color " .. color .. ")", 0)
      end
      if compression ~= 0 or filter ~= 0 or interlace ~= 0 then
        error(path .. ": unsupported PNG method triple", 0)
      end
    elseif kind == "IDAT" then
      idat[#idat + 1] = data
    elseif kind == "IEND" then
      break
    end
    position = dataEnd + 5
  end
  if width == nil then
    error(path .. ": missing IHDR", 0)
  end
  local stream = table.concat(idat)
  if #stream < 6 or stream:byte(1) ~= 0x78 or stream:byte(2) ~= 0x01 then
    error(path .. ": unsupported zlib wrapper (stored blocks required)", 0)
  end
  local raw, cursor = {}, 3
  while true do
    if cursor > #stream - 4 then
      error(path .. ": truncated deflate block", 0)
    end
    local header = stream:byte(cursor)
    local final, kind = header % 2, math.floor(header / 2) % 4
    if kind ~= 0 then
      error(path .. ": unsupported deflate block type " .. kind .. " (stored only)", 0)
    end
    local length = readU16LE(stream, cursor + 1)
    local inverse = readU16LE(stream, cursor + 3)
    if length + inverse ~= 65535 then
      error(path .. ": stored block length mismatch", 0)
    end
    raw[#raw + 1] = stream:sub(cursor + 5, cursor + 4 + length)
    cursor = cursor + 5 + length
    if final == 1 then
      break
    end
  end
  local body = table.concat(raw)
  local storedAdler = readU32BE(stream, cursor)
  if adler32(body) ~= storedAdler then
    error(path .. ": adler32 mismatch", 0)
  end
  local stride, expected = width * 4, height * (1 + width * 4)
  if #body ~= expected then
    error(path .. ": raw length " .. #body .. " does not match dimensions", 0)
  end
  local rows = {}
  for row = 0, height - 1 do
    local base = row * (stride + 1)
    if body:byte(base + 1) ~= 0 then
      error(path .. ": unsupported scanline filter on row " .. row .. " (filter zero only)", 0)
    end
    rows[#rows + 1] = body:sub(base + 2, base + 1 + stride)
  end
  return width, height, table.concat(rows)
end

-- Classifies decoded RGBA bytes into the private-derivative byte model:
-- one index byte per pixel plus one RGBA tuple per distinct color when the
-- content fits 256 exact colors, else straight RGBA bytes. Stops counting
-- past 257 distinct tuples; transparent RGB participates exactly.
local function classifyDerivativeModel(rgba)
  local seen, colors, pixels = {}, 0, #rgba / 4
  for offset = 1, #rgba, 4 do
    local key = rgba:sub(offset, offset + 3)
    if seen[key] == nil then
      seen[key] = true
      colors = colors + 1
      if colors > 257 then
        break
      end
    end
  end
  if colors <= 256 then
    return colors, pixels + colors * 4, "indexed"
  end
  return colors, pixels * 4, "straight"
end

local function readWholeFile(path)
  local handle = assert(io.open(path, "rb"))
  local bytes = handle:read("*a")
  handle:close()
  return bytes
end

-- Guarded production-encoder round trip: re-encodes the decoded bytes and
-- compares against the file on disk. Returns true, false, or nil when the
-- encoder cannot be loaded in this interpreter (reported, never faked).
local function tryWriterRoundTrip(width, height, rgba, fileBytes)
  local ok, writer = pcall(function()
    local script = debug.getinfo(1, "S").source:gsub("^@", "")
    local root = script:gsub("scripts/perf/asset%-disk%-io%-study%.lua$", "")
    package.path = root .. "?.lua;" .. root .. "?/init.lua;" .. package.path
    return require("libs.assets.src.PngWriter")
  end)
  if not ok or type(writer) ~= "table" then
    return nil
  end
  if writer.encodedSize(width, height) ~= #fileBytes then
    return false
  end
  local encodedOk, encoded = pcall(writer.encode, width, height, rgba)
  if not encodedOk then
    return nil
  end
  return encoded == fileBytes
end

-- Conventional-deflate candidate size over the concatenated raw bytes of
-- the whole sample, measured once through a system zlib when available.
-- Scratch lives in the process temp directory; the sample is untouched.
-- Returns compressed bytes and milliseconds, or nil with the reason.
local function tryConventionalDeflate(rawPath)
  local probe = io.popen("command -v python3 2>/dev/null")
  local found = probe ~= nil and probe:read("*l") or nil
  if probe ~= nil then
    probe:close()
  end
  if found == nil or found == "" then
    return nil, "no system python3 with zlib"
  end
  local snippet = "import sys,time,zlib;raw=open(sys.argv[1],'rb').read();t=time.perf_counter();"
    .. "out=zlib.compress(raw,6);print(len(out),round((time.perf_counter()-t)*1000,2))"
  local command = string.format("python3 -c %q %q", snippet, rawPath)
  local handle = io.popen(command)
  if handle == nil then
    return nil, "deflate probe failed to start"
  end
  local line = handle:read("*l")
  handle:close()
  local size, ms = nil, nil
  if line ~= nil then
    size, ms = line:match("^(%d+)%s+([%d%.]+)$")
  end
  if size == nil then
    return nil, "deflate probe reported nothing"
  end
  return tonumber(size), tonumber(ms)
end

local function listPngFiles(directory, limit)
  local quoted = string.format("%q", directory)
  local handle = io.popen("find " .. quoted .. " -type f -name '*.png' 2>/dev/null | sort | head -n " .. limit)
  if handle == nil then
    return {}
  end
  local files = {}
  for line in handle:lines() do
    files[#files + 1] = line
  end
  handle:close()
  return files
end

local function main(arguments)
  local directory, maxFiles = arguments[1], tonumber(arguments[2]) or DEFAULT_MAX_FILES
  if directory == nil then
    usage()
    return 2
  end
  local files = listPngFiles(directory, maxFiles)
  if #files == 0 then
    io.stderr:write("asset-disk-io-study: no PNG files under " .. directory .. "\n")
    return 2
  end
  local totals = {
    files = 0,
    skipped = 0,
    storedBytes = 0,
    rawBytes = 0,
    modelBytes = 0,
    indexedFiles = 0,
    coldReadMs = 0,
    warmReadMs = 0,
    decodeMs = 0,
    classifyMs = 0,
    roundTripOk = 0,
    roundTripUnavailable = 0,
  }
  local failures, raws = {}, {}
  io.write(
    "file\tstored_bytes\traw_bytes\tmodel_bytes\tmodel_kind\tcolors\tcold_read_ms\twarm_read_ms\tdecode_ms\tclassify_ms\twriter_roundtrip\n"
  )
  for _, path in ipairs(files) do
    local started = os.clock()
    local fileBytes = readWholeFile(path)
    local coldMs = (os.clock() - started) * 1000
    started = os.clock()
    readWholeFile(path)
    local second = readWholeFile(path)
    local warmMs = (os.clock() - started) * 1000 / 2
    started = os.clock()
    local decodedOk, width, height, rgba = pcall(decodeStoredPng, path, fileBytes)
    local decodeMs = (os.clock() - started) * 1000
    if not decodedOk then
      totals.skipped = totals.skipped + 1
      failures[#failures + 1] = tostring(width)
      io.write(path .. "\tskipped: " .. tostring(width) .. "\n")
    else
      started = os.clock()
      local colors, modelBytes, kind = classifyDerivativeModel(rgba)
      local classifyMs = (os.clock() - started) * 1000
      local roundTrip = tryWriterRoundTrip(width, height, rgba, fileBytes)
      totals.files = totals.files + 1
      totals.storedBytes = totals.storedBytes + #fileBytes
      totals.rawBytes = totals.rawBytes + #rgba
      totals.modelBytes = totals.modelBytes + modelBytes
      totals.coldReadMs = totals.coldReadMs + coldMs
      totals.warmReadMs = totals.warmReadMs + warmMs
      totals.decodeMs = totals.decodeMs + decodeMs
      totals.classifyMs = totals.classifyMs + classifyMs
      if kind == "indexed" then
        totals.indexedFiles = totals.indexedFiles + 1
      end
      if roundTrip == true then
        totals.roundTripOk = totals.roundTripOk + 1
      elseif roundTrip == nil then
        totals.roundTripUnavailable = totals.roundTripUnavailable + 1
      else
        failures[#failures + 1] = path .. ": writer round trip mismatch"
      end
      raws[#raws + 1] = rgba
      assert(second == fileBytes, path .. ": warm re-read must return identical bytes")
      io.write(
        string.format(
          "%s\t%d\t%d\t%d\t%s\t%d\t%.2f\t%.2f\t%.2f\t%.2f\t%s\n",
          path,
          #fileBytes,
          #rgba,
          modelBytes,
          kind,
          colors,
          coldMs,
          warmMs,
          decodeMs,
          classifyMs,
          roundTrip == true and "identical" or (roundTrip == nil and "unavailable" or "MISMATCH")
        )
      )
    end
  end
  local conventional, conventionalMs, conventionalNote = nil, nil, nil
  if #raws > 0 then
    local scratch = (os.getenv("TMPDIR") or "/tmp")
      .. "/asset-disk-io-study-"
      .. tostring(math.floor(os.clock() * 1000))
      .. ".raw"
    local handle = assert(io.open(scratch, "wb"))
    for _, raw in ipairs(raws) do
      handle:write(raw)
    end
    handle:close()
    conventional, conventionalMs = tryConventionalDeflate(scratch)
    if conventional == nil then
      conventionalNote = conventionalMs
    end
    os.remove(scratch)
  end
  io.write("--- totals ---\n")
  io.write(
    string.format(
      "files=%d skipped=%d stored_bytes=%d raw_bytes=%d derivative_model_bytes=%d indexed_files=%d\n",
      totals.files,
      totals.skipped,
      totals.storedBytes,
      totals.rawBytes,
      totals.modelBytes,
      totals.indexedFiles
    )
  )
  io.write(
    string.format(
      "cold_read_ms=%.2f warm_read_ms=%.2f decode_ms=%.2f classify_ms=%.2f writer_roundtrip_identical=%d unavailable=%d\n",
      totals.coldReadMs,
      totals.warmReadMs,
      totals.decodeMs,
      totals.classifyMs,
      totals.roundTripOk,
      totals.roundTripUnavailable
    )
  )
  if conventional ~= nil then
    io.write(string.format("conventional_deflate_bytes=%d deflate_ms=%.2f\n", conventional, conventionalMs))
  else
    io.write("conventional_deflate_bytes=not-measured (" .. tostring(conventionalNote) .. ")\n")
  end
  if #failures > 0 then
    io.stderr:write("asset-disk-io-study failures:\n")
    for _, failure in ipairs(failures) do
      io.stderr:write("  " .. failure .. "\n")
    end
    return 1
  end
  return 0
end

local code = main(arg or {})
os.exit(code, true)
