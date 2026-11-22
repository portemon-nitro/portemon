-- Test-only selected mod packages: tiny synthetic ZIPs written into the private
-- test save root's `mods/<versionId>/` directory, plus the ordered config file a
-- selection reads, and observation of the payload reads they cause. Every byte
-- is synthetic and built by the repository's own zip helper, so no commercial
-- content and no production writer is involved. Nothing here is imported by
-- production code.
--
-- Every helper removes exactly what it wrote, and the observation wrappers
-- restore the wrapped platform function on both the success and the failure
-- path, so a failing scenario cannot leave a config, a package, a read spy, or
-- a write spy behind for the next one.

local AudioCache = require("libs.assets.src.audio.AudioCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local LuaWriter = require("libs.codec.src.LuaWriter")
local ZipBuilder = require("tests.support.ZipBuilder")

local ModPackageFixture = {}

ModPackageFixture.SCHEMA = "portemon-mod-v1"

---@param versionId string
---@return string
function ModPackageFixture.root(versionId)
  return "mods/" .. versionId
end

---@param versionId string
---@return string
function ModPackageFixture.configPath(versionId)
  return ModPackageFixture.root(versionId) .. "/load-order.lua"
end

---@param versionId string
---@param basename string
---@return string
function ModPackageFixture.archivePath(versionId, basename)
  return ModPackageFixture.root(versionId) .. "/" .. basename
end

-- A selection's ordered package list, low priority first.
---@param versionId string
---@param basenames string[]
function ModPackageFixture.writeConfig(versionId, basenames)
  assert(love.filesystem.createDirectory(ModPackageFixture.root(versionId)), "the mods directory must be creatable")
  local path = ModPackageFixture.configPath(versionId)
  local wrote, err = love.filesystem.write(path, LuaWriter.encode(basenames))
  assert(wrote, "the ordered package config must be writable: " .. path .. ": " .. tostring(err))
end

---@param versionId string
function ModPackageFixture.removeConfig(versionId)
  love.filesystem.remove(ModPackageFixture.configPath(versionId))
end

-- One manifest record over the members the package declares. `files` is dense
-- and lexically sorted, exactly as the format requires; sizes are the actual
-- uncompressed bytes each member carries.
---@param options { versionId: string, id: string, revision: string?, assetRevision: number, scriptApi: number, paths: string[], sizes: table<string, integer>, schema: string? }
---@return table
function ModPackageFixture.manifest(options)
  local sorted = {}
  for position, path in ipairs(options.paths) do
    sorted[position] = path
  end
  table.sort(sorted)
  local files = {}
  for position, path in ipairs(sorted) do
    files[position] = { path = path, size = assert(options.sizes[path], "a declared member needs its size: " .. path) }
  end
  return {
    schema = options.schema or ModPackageFixture.SCHEMA,
    id = options.id,
    revision = options.revision or "1",
    versionId = options.versionId,
    assetRevision = options.assetRevision,
    scriptApi = options.scriptApi,
    files = files,
  }
end

---@class ModPackageFixture.PackageSpec
---@field id string
---@field revision string?
---@field schema string? manifest schema override for malformed-metadata cases
---@field files table<string, string|love.Data> generated members by logical path
---@field extra string|table<string, string>? a member the manifest never declares, or extra members by name
---@field manifest string? raw manifest source overriding the derived record
---@field declaredSizes table<string, integer>? manifest sizes overriding the member bytes

-- Write one package archive under the version's mods directory. The manifest
-- declares exactly `spec.files` unless the case under test overrides it, and
-- `spec.extra` adds members the manifest never lists (unlisted members must
-- stay inaccessible).
---@param versionId string
---@param basename string
---@param identity { versionId: string, assetRevision: number, scriptApi: number }
---@param spec ModPackageFixture.PackageSpec
---@return string archivePath save-relative selected archive
function ModPackageFixture.writeArchive(versionId, basename, identity, spec)
  local members = {}
  local paths, sizes = {}, {}
  local function addMember(name, data)
    local text = type(data) == "userdata" and data:getString() or data
    assert(type(text) == "string", "a package member carries bytes: " .. name)
    members[#members + 1] = { name = name, data = text }
    return text
  end
  for path, data in pairs(spec.files) do
    local text = type(data) == "userdata" and data:getString() or data
    paths[#paths + 1] = path
    sizes[path] = #text
  end
  if spec.declaredSizes ~= nil then
    for path, size in pairs(spec.declaredSizes) do
      sizes[path] = size
    end
  end
  local manifestSource = spec.manifest
  if manifestSource == nil then
    manifestSource = LuaWriter.encode(ModPackageFixture.manifest({
      versionId = identity.versionId,
      id = spec.id,
      revision = spec.revision,
      schema = spec.schema,
      assetRevision = identity.assetRevision,
      scriptApi = identity.scriptApi,
      paths = paths,
      sizes = sizes,
    }))
  end
  addMember("mod.lua", manifestSource)
  for path, data in pairs(spec.files) do
    addMember(path, data)
  end
  if spec.extra ~= nil then
    if type(spec.extra) == "string" then
      addMember("data/generated/acceptance-unused/unlisted.bin", spec.extra)
    else
      for name, data in pairs(spec.extra) do
        addMember(name, data)
      end
    end
  end
  assert(love.filesystem.createDirectory(ModPackageFixture.root(versionId)), "the mods directory must be creatable")
  local archivePath = ModPackageFixture.archivePath(versionId, basename)
  local wrote, err = love.filesystem.write(archivePath, ZipBuilder.build(members))
  assert(wrote, "a selected package archive must be writable: " .. archivePath .. ": " .. tostring(err))
  return archivePath
end

---@param versionId string
---@param basename string
function ModPackageFixture.removeArchive(versionId, basename)
  love.filesystem.remove(ModPackageFixture.archivePath(versionId, basename))
end

-- Remove every package, the config, and the directory itself. Callers close
-- (unmount) their selection first: a package still mounted must not be removed
-- underneath its own owner.
---@param versionId string
function ModPackageFixture.cleanup(versionId)
  local root = ModPackageFixture.root(versionId)
  local info = love.filesystem.getInfo(root)
  if info ~= nil and info.type == "directory" then
    for _, name in ipairs(love.filesystem.getDirectoryItems(root)) do
      love.filesystem.remove(root .. "/" .. name)
    end
    love.filesystem.remove(root)
  end
  local modsRoot = "mods"
  local modsInfo = love.filesystem.getInfo(modsRoot)
  if modsInfo ~= nil and modsInfo.type == "directory" and #love.filesystem.getDirectoryItems(modsRoot) == 0 then
    love.filesystem.remove(modsRoot)
  end
end

-- The full selected identity a boot installs, read from the runner-prepared
-- snapshot this process hydrated: the package contract compares the identity
-- fields it names, so the fixture must offer the real values rather than
-- literals that drift with the asset contract.
---@param versionId string
---@return { versionId: string, assetRevision: number, scriptApi: number }
function ModPackageFixture.identity(versionId)
  local GeneratedCacheFixture = require("tests.support.GeneratedCacheFixture")
  local view = GeneratedCacheFixture.view(versionId)
  local identity = view.candidate.identity
  assert(type(identity) == "table", "the prepared snapshot carries its generation identity")
  assert(identity.versionId == versionId, "the prepared snapshot belongs to the selected version")
  assert(type(identity.assetRevision) == "number", "the installed identity names its asset revision")
  assert(type(identity.scriptApi) == "number", "the installed identity names its script API")
  return identity
end

-- One compact message bank member whose first message displays `text`: every
-- character is its own glyph token, so the decoded display text is exactly the
-- synthetic string.
---@param bankId integer
---@param text string
---@return love.Data
function ModPackageFixture.messageBank(bankId, text)
  local FieldMessageFixture = require("tests.support.FieldMessageFixture")
  assert(type(text) == "string" and text ~= "", "a synthetic message needs its display text")
  local tokens = {}
  for position = 1, #text do
    tokens[#tokens + 1] = FieldMessageFixture.glyph(position, text:sub(position, position))
  end
  tokens[#tokens + 1] = FieldMessageFixture.eos()
  return FieldMessageFixture.encode(FieldMessageFixture.bank(bankId, { tokens }))
end

---@param bankId integer
---@return string
function ModPackageFixture.messageBankPath(bankId)
  return FieldMessageCache.bankPath(bankId)
end

-- Every generated member of a synthetic audio bundle, keyed by its logical
-- generated path, so a package can supply the audio family a selected runtime
-- reads.
---@param bundle AudioFixture.Bundle
---@return table<string, string|love.Data>
function ModPackageFixture.audioMembers(bundle)
  local AudioFixture = require("tests.support.AudioFixture")
  local physical = AudioFixture.readyCache(bundle)
  local members = {}
  local function collect(relative)
    for _, name in ipairs(physical:getDirectoryItems(relative)) do
      local child = relative == "" and name or relative .. "/" .. name
      local info = physical:getInfo(child)
      if info ~= nil and info.type == "directory" then
        collect(child)
      elseif info ~= nil then
        local bytes = assert(physical:read(child), "an audio fixture payload must be readable: " .. child)
        if #bytes > 0 then
          members[child] = bytes
        end
      end
    end
  end
  collect("")
  assert(members[AudioCache.indexPath()] ~= nil, "the audio fixture carries its family index")
  return members
end

-- One synthetic packed PCM sample as generated audio bytes, plus the frame
-- count it claims, so a compact consumer reads real packed frames in place.
---@param frames integer
---@param value integer?
---@return { path: string, data: love.Data, frames: integer }
function ModPackageFixture.pcmSample(frames, value)
  local AudioFixture = require("tests.support.AudioFixture")
  value = value or 1000
  local samples = {}
  for frame = 1, frames do
    samples[frame] = value
  end
  return {
    path = AudioCache.samplePath(AudioFixture.key(3)),
    data = assert(love.data.newByteData(AudioFixture.pcm16le(samples))),
    frames = frames,
  }
end

---@class ModPackageFixture.ReadLog
---@field reads string[] every platform read this state performed, in order
---@field failOn table<string, boolean>? a path whose read must not happen

---@return ModPackageFixture.ReadLog
function ModPackageFixture.newReadLog()
  return { reads = {} }
end

-- Observe this state's platform reads for the duration of `fn`. The mounted
-- package members are read through `love.filesystem.read`, so the log names
-- every payload this state touched; a member no consumer requests is read by no
-- state at all. A read of a `failOn` logical path (matched by suffix, because a
-- mount point prefixes the physical path) raises, which is how a scenario fails
-- when an unrequested package member is opened.
---@param log ModPackageFixture.ReadLog
---@param fn fun(): unknown
---@return unknown
function ModPackageFixture.withReadLog(log, fn)
  local filesystem = love.filesystem
  local originalRead = filesystem.read
  local function refused(path)
    local failOn = log.failOn
    if failOn == nil or type(path) ~= "string" then
      return false
    end
    for logicalPath in pairs(failOn) do
      if path:sub(-#logicalPath) == logicalPath then
        return true
      end
    end
    return false
  end
  filesystem.read = function(container, name)
    local path
    if type(container) == "string" and name == nil then
      path = container
    else
      path = name
    end
    log.reads[#log.reads + 1] = path
    if refused(path) then
      error("an unrequested package member was read: " .. tostring(path), 0)
    end
    if type(container) == "string" and name == nil then
      return originalRead(container)
    end
    return originalRead(container, name)
  end
  local ok, result = pcall(fn)
  filesystem.read = originalRead
  if not ok then
    error(result, 0)
  end
  return result
end

-- Reads whose path ends with one logical generated path.
---@param log ModPackageFixture.ReadLog
---@param logicalPath string
---@return integer
function ModPackageFixture.payloadReadCount(log, logicalPath)
  local count = 0
  for _, path in ipairs(log.reads) do
    if type(path) == "string" and path:sub(-#logicalPath) == logicalPath then
      count = count + 1
    end
  end
  return count
end

-- Observe base-snapshot mutations for the duration of `fn`: a selected package
-- failure may never write, replace, or delete the version's generated archive.
---@param fn fun(writes: string[]): unknown
---@return unknown
function ModPackageFixture.withSnapshotWriteLog(fn)
  local filesystem = love.filesystem
  local original = {
    write = filesystem.write,
    remove = filesystem.remove,
    createDirectory = filesystem.createDirectory,
  }
  local writes = {}
  filesystem.write = function(path, ...)
    writes[#writes + 1] = path
    return original.write(path, ...)
  end
  filesystem.remove = function(path)
    writes[#writes + 1] = path
    return original.remove(path)
  end
  filesystem.createDirectory = function(path)
    writes[#writes + 1] = path
    return original.createDirectory(path)
  end
  local ok, result = pcall(fn, writes)
  filesystem.write = original.write
  filesystem.remove = original.remove
  filesystem.createDirectory = original.createDirectory
  if not ok then
    error(result, 0)
  end
  return result
end

return ModPackageFixture
