-- Job-private, in-memory output of one compiled artifact. A stage owns one
-- writable map of logical generated paths to immutable bytes, the owned-root
-- and shared-file declarations the controller reconciles at commit, and the
-- deferred PNG rows its low-priority continuation encodes. Nothing here
-- touches the host filesystem: the sealed entry list travels to the
-- controller, which is the only owner that publishes bytes. The dependency
-- reader supplied at construction is read-only and never written through.
-- Owned roots may be exact files or directories, but they may never overlap
-- each other or swallow a shared file.

local ArtifactState = require("romdump.src.build.ArtifactState")
local Errors = require("libs.errors.src.Errors")
local LuaWriter = require("libs.codec.src.LuaWriter")
local ScopedFs = require("libs.storage.src.ScopedFs")
local StorageErrors = require("libs.storage.src.errors")

-- The CACHE_* codes a chunk load reports through the shared confined loader.
local LOAD_ERRORS = {
  PATH_INVALID = StorageErrors.CACHE_PATH_INVALID,
  FILE_MISSING = StorageErrors.CACHE_FILE_MISSING,
  READ_FAILED = StorageErrors.CACHE_READ_FAILED,
  LUA_PARSE_FAILED = StorageErrors.CACHE_LUA_PARSE_FAILED,
  LUA_EVAL_FAILED = StorageErrors.CACHE_LUA_EVAL_FAILED,
}

---@class PreparedArtifact.DeferredImage
---@field relativePath string logical PNG destination
---@field width integer
---@field height integer
---@field rgba love.Data RGBA rows owned until the continuation writes them
---@class PreparedArtifact.Sealed
---@field kind string
---@field key string
---@field marker string
---@field ownedRoots string[]
---@field sharedPaths string[]
---@field entries PreparedArtifact.Entry[]
---@class PreparedArtifact.Entry
---@field path string logical generated path
---@field data love.Data immutable payload bytes
---@field size integer
---@class PreparedArtifact
---@field private _cacheFs table<string, unknown> read-only dependency reader
---@field private _facts table<string, unknown>? committed dependency facts for this job
---@field private _generationId string
---@field private _epoch integer
---@field private _kind string
---@field private _key string
---@field private _jobKey string
---@field private _ownedRoots table<string, boolean>
---@field private _sharedFiles table<string, boolean>
---@field private _entries table<string, love.Data>
---@field private _deferredImages table<string, PreparedArtifact.DeferredImage>
---@field private _deferredOrder PreparedArtifact.DeferredImage[]
---@field private _status string
---@field private _marker string?
---@field private _sealed PreparedArtifact.Sealed?
local PreparedArtifact = {}
PreparedArtifact.__index = PreparedArtifact

-- The one module a generated chunk may require: the gen4 script DSL emitted
-- by the script cache generator. Mirrors the generated-cache module allowlist;
-- anything wider would let generated output reach process-wide package state.
local ALLOWED_MODULES = { ["gen4.script"] = true }

local function moduleRequire(name)
  assert(ALLOWED_MODULES[name], "generated modules may only require gen4.script")
  return require(name)
end

-- Confined logical path: a cache-relative generated path with no alias,
-- escape, or trailing separator. Real entry confinement is enforced again by
-- the controller's byte store when the batch is prepared.
local function assertSafePath(path, label)
  assert(type(path) == "string" and path ~= "", label .. " must be a non-empty path")
  assert(not path:find("\0", 1, true), label .. " must not contain a NUL byte")
  assert(path:sub(1, 1) ~= "/", label .. " must be relative")
  assert(not path:find("\\", 1, true), label .. " must not contain a backslash")
  assert(path:sub(-1) ~= "/", label .. " must not end with a slash")
  assert(not path:find("//", 1, true), label .. " must be canonical")
  for segment in path:gmatch("[^/]+") do
    assert(segment ~= "." and segment ~= "..", label .. " must not traverse")
  end
end

local function isPathUnder(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function pathsOverlap(first, second)
  return isPathUnder(first, second) or isPathUnder(second, first)
end

local function sortedKeys(set)
  local result = {}
  for path in pairs(set) do
    result[#result + 1] = path
  end
  table.sort(result)
  return result
end

local function serializedError(value)
  if Errors.is(value) then
    return {
      code = value.code,
      message = value.message,
      context = value.context,
    }
  end
  return { message = tostring(value) }
end

---@param stringOrData string|love.Data
---@return love.Data bytes adopted as-is, or converted once from a string
local function byteDataOf(stringOrData)
  local bytes = stringOrData
  if type(bytes) == "string" then
    local host = rawget(_G, "love")
    assert(
      type(host) == "table" and type(host.data) == "table" and type(host.data.newByteData) == "function",
      "artifact output requires love.data.newByteData"
    )
    bytes = host.data.newByteData(bytes)
  end
  assert(type(bytes) == "userdata", "artifact output must be a string or Data")
  ---@cast bytes love.Data
  return bytes
end

---@param options table<string, unknown>
---@return PreparedArtifact
local function newInstance(options)
  assert(type(options) == "table", "prepared artifact options are required")
  assert(options.cacheFs and options.cacheFs.versionId, "prepared artifact requires its dependency reader")
  local generationId = options.generationId
  assert(type(generationId) == "string" and generationId ~= "", "prepared artifact generation is required")
  local epoch = options.epoch
  assert(type(epoch) == "number" and epoch % 1 == 0, "prepared artifact epoch must be an integer")
  local kind = options.kind
  assert(type(kind) == "string" and kind ~= "", "prepared artifact kind is required")
  local key = options.key
  assert(type(key) == "string" and key ~= "", "prepared artifact key is required")
  local jobKey = options.jobKey
  assert(type(jobKey) == "string" and jobKey ~= "", "prepared artifact job key is required")
  assert(jobKey == kind .. ":" .. key, "prepared artifact job identity must match its kind and key")
  ArtifactState.validateKey(kind, key)
  if options.facts ~= nil then
    assert(type(options.facts) == "table", "prepared artifact dependency facts must be a record map")
  end
  return setmetatable({
    _cacheFs = options.cacheFs,
    _facts = options.facts,
    _generationId = generationId,
    _epoch = epoch,
    _kind = kind,
    _key = key,
    _jobKey = jobKey,
    _ownedRoots = {},
    _sharedFiles = {},
    _entries = {},
    _deferredImages = {},
    _deferredOrder = {},
    _status = "open",
  }, PreparedArtifact)
end

---@param options table<string, unknown>
---@return PreparedArtifact
function PreparedArtifact.new(options)
  return newInstance(options)
end

-- The low-priority PNG continuation resumes the parent's authored output from
-- the packet its own worker held: payload bytes, ownership declarations, and
-- the remaining RGBA rows travel back by reference, so the continuation
-- encodes into the same map and seals it exactly once.
---@param packet { generationId: string, epoch: integer, kind: string, key: string, jobKey: string, entries: PreparedArtifact.Entry[], ownedRoots: string[], sharedPaths: string[], images: { relativePath: string, width: integer, height: integer, rgba: love.Data }[] }
---@param options { cacheFs: table<string, unknown>, facts: table<string, unknown>? }
---@return PreparedArtifact
function PreparedArtifact.fromPending(packet, options)
  assert(type(packet) == "table", "pending artifact packet is required")
  assert(type(options) == "table" and options.cacheFs ~= nil, "pending artifact requires its dependency reader")
  local artifact = newInstance({
    cacheFs = options.cacheFs,
    facts = options.facts,
    generationId = packet.generationId,
    epoch = packet.epoch,
    kind = packet.kind,
    key = packet.key,
    jobKey = packet.jobKey,
  })
  for _, root in ipairs(packet.ownedRoots) do
    artifact:addOwnedRoot(root)
  end
  for _, path in ipairs(packet.sharedPaths) do
    artifact:addSharedFile(path)
  end
  for _, entry in ipairs(packet.entries) do
    assertSafePath(entry.path, "pending artifact entry")
    artifact._entries[entry.path] = byteDataOf(entry.data)
  end
  for _, image in ipairs(packet.images) do
    artifact:deferImage(image.relativePath, image.width, image.height, image.rgba)
  end
  return artifact
end

---@return table<string, unknown> read-only dependency reader
function PreparedArtifact:cacheFs()
  return self._cacheFs
end

---@param kind string
---@param key string
---@return table<string, unknown>|nil committed dependency fact
function PreparedArtifact:dependencyFact(kind, key)
  assert(self._facts ~= nil, "prepared artifact carries no dependency facts")
  return ArtifactState.read(self._facts, kind, key)
end

---@return string
function PreparedArtifact:jobKey()
  return self._jobKey
end

function PreparedArtifact:addOwnedRoot(path)
  assert(self._status == "open", "prepared artifact is already finalized")
  assertSafePath(path, "owned root")
  if self._ownedRoots[path] then
    return
  end
  for existing in pairs(self._ownedRoots) do
    assert(not pathsOverlap(path, existing), "prepared artifact owned roots overlap: " .. path)
  end
  for shared in pairs(self._sharedFiles) do
    assert(not isPathUnder(shared, path), "prepared artifact owned root contains a shared file: " .. path)
  end
  assert(not self._sharedFiles[path], "prepared artifact path is both owned and shared")
  self._ownedRoots[path] = true
end

function PreparedArtifact:addSharedFile(path)
  assert(self._status == "open", "prepared artifact is already finalized")
  assertSafePath(path, "shared file")
  if self._sharedFiles[path] then
    return
  end
  assert(not self._ownedRoots[path], "prepared artifact path is both owned and shared")
  for root in pairs(self._ownedRoots) do
    assert(not isPathUnder(path, root), "prepared artifact shared file is owned: " .. path)
  end
  self._sharedFiles[path] = true
end

-- One private output file. A string becomes Data once here; a supplied Data is
-- adopted without copying and must never be mutated after this call.
---@param path string
---@param contents string|love.Data
function PreparedArtifact:write(path, contents)
  assert(self._status == "open", "prepared artifact is already finalized")
  assertSafePath(path, "artifact output")
  self._entries[path] = byteDataOf(contents)
end

---@param path string
---@param value table<string, unknown>
function PreparedArtifact:writeLua(path, value)
  assert(type(value) == "table", "artifact Lua output must be a table: " .. tostring(path))
  self:write(path, LuaWriter.encode(value))
end

---@param path string
---@return string|nil
function PreparedArtifact:read(path)
  local data = self._entries[path]
  if data == nil then
    return nil
  end
  return data:getString()
end

---@param path string
---@return love.Data|nil
function PreparedArtifact:readData(path)
  return self._entries[path]
end

---@param path string
---@param expectedType string?
---@return boolean
function PreparedArtifact:exists(path, expectedType)
  if self._entries[path] ~= nil then
    return expectedType == nil or expectedType == "file"
  end
  if expectedType == "file" then
    return false
  end
  local prefix = path == "" and "" or path .. "/"
  for entryPath in pairs(self._entries) do
    if prefix == "" or entryPath:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

---@param path string
---@return string[] sorted immediate child names
function PreparedArtifact:getDirectoryItems(path)
  local prefix = path == "" and "" or path .. "/"
  local names = {}
  local seen = {}
  for entryPath in pairs(self._entries) do
    if entryPath:sub(1, #prefix) == prefix then
      local rest = entryPath:sub(#prefix + 1)
      local name = rest:match("^([^/]+)")
      if name ~= nil and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  return names
end

---@return ScopedFs.Backend chunk-loading view over the private output map
function PreparedArtifact:_chunkBackend()
  local function entryInfo(_, path)
    if self._entries[path] ~= nil then
      return { type = "file" }
    end
    return nil
  end
  local function entryRead(_, path)
    local data = self._entries[path]
    if data == nil then
      return nil, "no such artifact entry"
    end
    return data:getString()
  end
  return { getInfo = entryInfo, read = entryRead }
end

---@param path string
---@return table<string, unknown>|nil
---@return unknown? load failure
function PreparedArtifact:loadLua(path)
  local ok, result, loadErr = pcall(ScopedFs.loadChunk, self:_chunkBackend(), path, path, LOAD_ERRORS)
  if ok then
    return result, loadErr
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result, 0)
end

---@param path string
---@return table<string, unknown>|nil
---@return unknown? load failure
function PreparedArtifact:loadModule(path)
  local ok, result, loadErr = pcall(ScopedFs.loadChunk, self:_chunkBackend(), path, path, LOAD_ERRORS, {
    require = moduleRequire,
  })
  if ok then
    return result, loadErr
  end
  if Errors.is(result) then
    return nil, result
  end
  error(result, 0)
end

-- A producer that already owns finished RGBA rows defers their PNG encode and
-- write to the owning job's low-priority continuation instead of spending its
-- source phase on compression. The stage stays open until every image is
-- written into it; finishSuccess then validates and seals once.
---@param relativePath string logical PNG destination path
---@param width integer
---@param height integer
---@param rgba string|love.Data RGBA rows, width*height*4 bytes
function PreparedArtifact:deferImage(relativePath, width, height, rgba)
  assert(self._status == "open", "prepared artifact is already finalized")
  assertSafePath(relativePath, "deferred image")
  assert(not self._deferredImages[relativePath], "deferred image is registered twice: " .. relativePath)
  assert(type(width) == "number" and width % 1 == 0 and width > 0, "deferred image width must be positive")
  assert(type(height) == "number" and height % 1 == 0 and height > 0, "deferred image height must be positive")
  local bytes = byteDataOf(rgba)
  assert(bytes:getSize() == width * height * 4, "deferred image RGBA size does not match its dimensions")
  local record = { relativePath = relativePath, width = width, height = height, rgba = bytes }
  self._deferredImages[relativePath] = record
  self._deferredOrder[#self._deferredOrder + 1] = record
end

---@return PreparedArtifact.DeferredImage[] images in the order they were deferred
function PreparedArtifact:pendingImages()
  local images = {}
  for index, image in ipairs(self._deferredOrder) do
    images[index] = image
  end
  return images
end

---@param relativePath string
---@return boolean
function PreparedArtifact:hasDeferredImage(relativePath)
  return self._deferredImages[relativePath] ~= nil
end

-- Every deferred image must belong to the roots that install it and must
-- already be written by its continuation: a sealed result carries complete
-- pixels only, and nothing may be written outside the owned roots.
function PreparedArtifact:_assertDeferredImagesStaged()
  for _, image in ipairs(self._deferredOrder) do
    local path = image.relativePath
    assert(not self._sharedFiles[path], "prepared artifact deferred image is also shared: " .. path)
    local owned = false
    for root in pairs(self._ownedRoots) do
      if path ~= root and isPathUnder(path, root) then
        owned = true
        break
      end
    end
    assert(owned, "prepared artifact deferred image escapes its owned roots: " .. path)
    assert(self._entries[path] ~= nil, "prepared artifact deferred image was not staged: " .. path)
  end
  self._deferredImages = {}
  self._deferredOrder = {}
end

---@param marker string? final result marker, absent for a marker-only job
---@return PreparedArtifact.Sealed
function PreparedArtifact:_seal(marker)
  assert(type(marker) == "string" and marker ~= "", "prepared artifact result marker is required")
  local entries = {}
  for path, data in pairs(self._entries) do
    entries[#entries + 1] = { path = path, data = data, size = data:getSize() }
  end
  table.sort(entries, function(left, right)
    return left.path < right.path
  end)
  local sealed = {
    kind = self._kind,
    key = self._key,
    marker = marker,
    ownedRoots = sortedKeys(self._ownedRoots),
    sharedPaths = sortedKeys(self._sharedFiles),
    entries = entries,
  }
  self._sealed = sealed
  self._marker = marker
  return sealed
end

-- Shared PNGs are addressed by a content identity while their bytes embed the
-- host zlib's deflate output, so a host toolchain change contradicts
-- byte-identical pixels. The logical PNG identity below is the IHDR plus every
-- non-IDAT chunk plus the decompressed scanlines: two files sharing it render
-- the same pixels. The controller uses it while reconciling shared content so
-- an encoder drift converges on the newer bytes instead of failing the job.
local PNG_SIGNATURE = "\137PNG\r\n\26\n"

---@param bytes string raw file bytes
---@param pos integer 1-based offset of the chunk length field
---@return string? ctype chunk type
---@return string? data chunk payload
---@return integer? nextPos 1-based offset past the chunk CRC
local function readPngChunk(bytes, pos)
  if pos + 7 > #bytes then
    return nil
  end
  local b1, b2, b3, b4 = string.byte(bytes, pos, pos + 3)
  if b1 == nil or b2 == nil or b3 == nil or b4 == nil then
    return nil
  end
  local length = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
  if length < 0 or pos + 11 + length > #bytes then
    return nil
  end
  return bytes:sub(pos + 4, pos + 7), bytes:sub(pos + 8, pos + 7 + length), pos + 12 + length
end

---@param bytes string raw file bytes
---@return string? identity canonical logical identity, nil unless a well-formed PNG
local function pngLogicalIdentity(bytes)
  if bytes:sub(1, 8) ~= PNG_SIGNATURE then
    return nil
  end
  local host = rawget(_G, "love")
  if type(host) ~= "table" or type(host.data) ~= "table" or type(host.data.decompress) ~= "function" then
    return nil
  end
  local pos, ihdr, idats, rest = 9, nil, {}, {}
  while true do
    if pos > #bytes then
      return nil
    end
    local ctype, data, nextPos = readPngChunk(bytes, pos)
    if ctype == nil or data == nil or nextPos == nil then
      return nil
    end
    if ctype == "IDAT" then
      idats[#idats + 1] = data
    else
      if ctype == "IHDR" then
        if ihdr ~= nil then
          return nil
        end
        ihdr = data
      end
      rest[#rest + 1] = ctype .. "\0" .. data
    end
    pos = nextPos
    if ctype == "IEND" then
      break
    end
  end
  if pos ~= #bytes + 1 or ihdr == nil or #idats == 0 then
    return nil
  end
  local decoded, raw = pcall(host.data.decompress, "string", "zlib", table.concat(idats))
  if not decoded or type(raw) ~= "string" then
    return nil
  end
  return table.concat(rest, "\1") .. "\1IDAT\0" .. raw
end

-- Whether two copies of one logical generated path carry the same content:
-- exact bytes, or PNG files that render the same pixels.
---@param path string logical path, used only to decide the comparison
---@param first love.Data
---@param second love.Data
---@return boolean
function PreparedArtifact.equalContent(path, first, second)
  if type(first) ~= "userdata" or type(second) ~= "userdata" then
    return false
  end
  ---@cast first love.Data
  ---@cast second love.Data
  local firstBytes, secondBytes = first:getString(), second:getString()
  if firstBytes == secondBytes then
    return true
  end
  if not path:lower():match("%.png$") then
    return false
  end
  local firstIdentity, secondIdentity = pngLogicalIdentity(firstBytes), pngLogicalIdentity(secondBytes)
  return firstIdentity ~= nil and firstIdentity == secondIdentity
end

---@param result table<string, unknown>|nil
---@return PreparedArtifact.Sealed
function PreparedArtifact:finishSuccess(result)
  assert(self._status == "open", "prepared artifact is already finalized")
  assert(result == nil or type(result) == "table", "prepared artifact result must be a table")
  local marker = result and result.marker
  self:_assertDeferredImagesStaged()
  local sealed = self:_seal(marker)
  self._status = "sealed"
  return sealed
end

---@param failure unknown
---@param traceback string|nil
---@return table<string, unknown> serialized failure record
function PreparedArtifact:finishFailure(failure, traceback)
  assert(self._status == "open", "prepared artifact is already finalized")
  local errorRecord = serializedError(failure)
  if traceback then
    errorRecord.traceback = traceback
  end
  self._entries = {}
  self._deferredImages = {}
  self._deferredOrder = {}
  self._status = "failed"
  return errorRecord
end

function PreparedArtifact:abort()
  assert(self._status == "open", "only an open artifact can be aborted")
  self._entries = {}
  self._deferredImages = {}
  self._deferredOrder = {}
  self._status = "aborted"
  return true
end

---@return string
function PreparedArtifact:status()
  return self._status
end

---@return PreparedArtifact.Sealed
function PreparedArtifact:sealed()
  assert(self._sealed ~= nil, "prepared artifact has not been sealed")
  return self._sealed
end

-- The open output map and ownership declarations, published by reference so a
-- deferred PNG continuation can resume the same artifact from its packet.
---@return { ownedRoots: string[], sharedPaths: string[], entries: PreparedArtifact.Entry[] }
function PreparedArtifact:captureOutput()
  assert(self._status == "open", "prepared artifact is already finalized")
  local entries = {}
  for path, data in pairs(self._entries) do
    entries[#entries + 1] = { path = path, data = data, size = data:getSize() }
  end
  table.sort(entries, function(left, right)
    return left.path < right.path
  end)
  return {
    ownedRoots = sortedKeys(self._ownedRoots),
    sharedPaths = sortedKeys(self._sharedFiles),
    entries = entries,
  }
end

return PreparedArtifact
