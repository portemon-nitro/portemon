-- Real ROM-import composition over an owned host directory and the process
-- save filesystem. Threads, channels, validation, publication, and source
-- reopening stay production-owned; the host controls only scheduling and
-- injects failures at the same filesystem/thread boundaries the app uses.

local Assert = require("tests.support.Assert")
local NdsBuilder = require("tests.support.NdsBuilder")
local DumpFixture = require("tests.support.DumpFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local RomImporter = require("romdump.src.source.RomImporter")
local RomSource = require("romdump.src.source.RomSource")
local SnapshotArchive = require("tests.support.SnapshotArchive")

local Fixture = {}

local nextFixture = 0

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function removeHostTree(root)
  assert(root ~= "" and root ~= "/", "refusing to remove an unowned host root")
  local status = os.execute("rm -rf -- " .. shellQuote(root))
  Assert.isTrue(status == 0 or status == true, "owned host cleanup failed: " .. root)
end

local function writeHostFile(path, bytes)
  local file = assert(io.open(path, "wb"))
  file:write(bytes)
  Assert.isTrue(file:close(), "fixture file did not close: " .. path)
end

local function cartridge(label, options)
  options = options or {}
  local spec = DumpFixture.spec()
  local codeSeed = 0
  for index = 1, #label do
    codeSeed = (codeSeed * 31 + label:byte(index)) % 1000
  end
  local gameCode = options.gameCode or ("M" .. string.format("%03d", codeSeed))
  spec.gameCode = gameCode
  spec.banner = options.banner
  spec.overlays9 = { "MANAGED-" .. label }
  local data = NdsBuilder.build(spec)
  local sha1 = RomSource.fromString(data):sha1()
  local info = {
    id = "managed" .. label,
    label = "Synthetic " .. label,
    displayName = "Synthetic " .. label,
    sha1 = sha1,
    gameCode = gameCode,
    expectedSize = #data,
    cachePrefix = "managed" .. label .. "/",
  }
  local versions = {
    info = function(versionId)
      return versionId == info.id and info or nil
    end,
    forSha1 = function(value)
      return value == sha1 and info or nil
    end,
    forGameCode = function(value)
      return value == gameCode and info or nil
    end,
  }
  versions.ORDER = { info.id }
  return { data = data, sha1 = sha1, info = info, versions = versions }
end

local function channel(raw, host)
  local proxy = { raw = raw, held = nil }
  function proxy:push(value)
    return self.raw:push(value)
  end
  function proxy:pop()
    if self.held ~= nil then
      return nil
    end
    local value = self.raw:pop()
    if type(value) == "table" and value.kind == "test-trace" then
      host.trace[#host.trace + 1] = value
    end
    if host.holdValidation and type(value) == "table" and value.kind == "validated" then
      self.held = value
      return nil
    end
    return value
  end
  function proxy:demand()
    return self:pop()
  end
  function proxy:getCount()
    return self.raw:getCount() + (self.held ~= nil and 1 or 0)
  end
  function proxy:releaseValidation()
    Assert.notNil(self.held, "the worker must reach its validation gate first")
    local value = self.held
    self.held = nil
    self.raw:push(value)
  end
  function proxy:discardValidation()
    self.held = nil
  end
  return proxy
end

local function newHost(options)
  options = options or {}
  local host = {
    threads = {},
    importers = {},
    trace = {},
    holdValidation = options.holdValidation == true,
    holdCommit = options.holdCommit == true,
    failNextStart = false,
    prelude = nil,
    control = assert(love.thread.newChannel()),
  }
  local realNewThread = love.thread.newThread
  local realNewChannel = love.thread.newChannel
  local newImporter = RomImporter.new
  love.thread.newChannel = function()
    return channel(assert(realNewChannel()), host)
  end
  love.thread.newThread = function(code)
    local controlForThread = false
    if host.prelude ~= nil or host.holdCommit then
      controlForThread = true
      local prelude = host.prelude or ""
      if host.holdCommit then
        prelude = prelude
          .. [[
local control = select(4, ...)
local rawInbox = inbox
inbox = {
  push = function(_, packet) return rawInbox:push(packet) end,
  pop = function() return rawInbox:pop() end,
  demand = function()
    local packet = rawInbox:demand()
    if type(packet) == "table" and packet.op == "commit" then
      outbox:push({ kind = "test-trace", event = "commit-held" })
      while control:pop() == nil do
        love.timer.sleep(0.001)
      end
    end
    return packet
  end,
}
]]
      end
      host.prelude = nil
      local replaced, count = code:gsub("Worker%.run%(inbox, outbox%)", function()
        return prelude .. "\nWorker.run(inbox, outbox)"
      end, 1)
      Assert.equal(count, 1, "the test host must wrap the production worker entry")
      code = replaced
    end
    local raw = assert(realNewThread(code))
    local proxy = { raw = raw }
    function proxy:start(...)
      if host.failNextStart then
        host.failNextStart = false
        return false, "injected worker startup failure"
      end
      local args = { ... }
      for index = 1, select("#", ...) do
        local value = args[index]
        if type(value) == "table" and value.raw ~= nil then
          args[index] = value.raw
        end
      end
      if controlForThread then
        args[#args + 1] = host.control
      end
      local result = self.raw:start(unpack(args))
      if result ~= false then
        host.threads[#host.threads + 1] = proxy
      end
      return result
    end
    function proxy:isRunning()
      return self.raw:isRunning()
    end
    function proxy:getError()
      return self.raw:getError()
    end
    function proxy:wait()
      return self.raw:wait()
    end
    function proxy:kill(reason)
      return self.raw:kill(reason)
    end
    return proxy
  end

  function host:importer(cart, onComplete, expectedVersionId)
    local importer = newImporter({
      versions = cart.versions,
      expectedVersionId = expectedVersionId,
      cacheFactory = function(versionId)
        return require("libs.storage.src.CacheFs").forVersion(versionId)
      end,
      onComplete = onComplete,
    })
    self.importers[#self.importers + 1] = importer
    return importer
  end

  function host:waitFor(predicate, label)
    local deadline = love.timer.getTime() + 20
    while love.timer.getTime() < deadline do
      if predicate() then
        return
      end
      love.timer.sleep(0.002)
    end
    local status = host.currentImporter and host.currentImporter:status() or {}
    error(
      "timed out waiting for "
        .. label
        .. ": state="
        .. tostring(status.state)
        .. " stage="
        .. tostring(status.stage)
        .. " error="
        .. tostring(status.errorCode)
        .. " detail="
        .. tostring(status.error)
        .. " thread="
        .. tostring(
          host.currentImporter and host.currentImporter._queued and host.currentImporter._queued.thread:getError()
        )
    )
  end

  function host:validationGate(importer)
    host.currentImporter = importer
    local session = assert(importer._queued, "the real worker must own a live session")
    self:waitFor(function()
      importer:update()
      return session.outbox.held ~= nil
    end, "the worker validation gate")
    Assert.notNil(session.outbox.held, "the controlled channel must hold the validated packet")
    return session
  end

  function host:commitGate(importer)
    host.currentImporter = importer
    local session = assert(importer._queued, "the real worker must own a live session")
    self:waitFor(function()
      importer:update()
      for _, event in ipairs(host.trace) do
        if event.event == "commit-held" then
          return true
        end
      end
      return false
    end, "the worker commit gate")
    Assert.isTrue(importer._commitSent, "sending commit is the publication linearization point")
    return session
  end

  function host:releaseCommit()
    host.control:push(true)
  end

  function host:finish(importer, expectedState)
    host.currentImporter = importer
    local thread = importer._queued and importer._queued.thread or nil
    self:waitFor(function()
      importer:update()
      return importer.state == expectedState
        or (expectedState ~= "idle" and (importer.state == "complete" or importer.state == "error"))
    end, "importer " .. tostring(expectedState))
    Assert.equal(
      importer.state,
      expectedState,
      "importer reached " .. tostring(importer.state) .. " instead of " .. tostring(expectedState)
    )
    if thread ~= nil then
      self:waitFor(function()
        importer:update()
        return not thread:isRunning()
      end, "physical worker exit")
    end
    importer:update()
  end

  function host:close()
    for _, session in pairs(host.importers) do
      pcall(session.cancelQueued, session)
    end
    for _ = 1, 4 do
      for _, importer in ipairs(host.importers) do
        pcall(importer.update, importer)
      end
    end
    host.control:push(true)
    for _, thread in ipairs(host.threads) do
      local deadline = love.timer.getTime() + 2
      while thread:isRunning() and love.timer.getTime() < deadline do
        love.timer.sleep(0.002)
      end
      if thread:isRunning() then
        pcall(thread.kill, thread, "managed import test cleanup")
      end
      pcall(thread.wait, thread)
    end
    for _, importer in ipairs(host.importers) do
      pcall(importer.update, importer)
    end
    love.thread.newThread = realNewThread
    love.thread.newChannel = realNewChannel
  end

  return host
end

function Fixture.with(fn, options)
  options = options or {}
  nextFixture = nextFixture + 1
  local handle = assert(io.popen("mktemp -d"))
  local root = (handle:read("*l") or ""):gsub("^%s+", ""):gsub("%s+$", "")
  Assert.isTrue(handle:close(), "mktemp did not exit successfully")
  Assert.isTrue(root ~= "", "mktemp produced no root")
  local rootToken = assert(root:match("([^/]+)$")):gsub("[^%w_-]", "")
  local label = string.format("%02d-%s", nextFixture, rootToken)
  local cart = cartridge(label, options)
  Assert.isNil(GameVersion.VERSIONS[cart.info.id], "synthetic version root must be unowned")
  Assert.isNil(love.filesystem.getInfo(cart.info.id), "synthetic version directory must be unowned")
  local canonical = "roms/" .. cart.sha1 .. ".zip"
  Assert.isNil(love.filesystem.getInfo(canonical), "synthetic managed archive must be unowned")
  GameVersion.VERSIONS[cart.info.id] = cart.info
  local host = newHost()
  local temporaryFiles = {}
  local fixture = { cart = cart, host = host, root = root, label = label, mountSequence = 0 }
  fixture.originalPath = root .. "/original.nds"
  fixture.archivePath = root .. "/original.zip"
  fixture.canonical = canonical
  fixture.stage = canonical .. ".new"
  fixture.backup = canonical .. ".bak"
  fixture.icon = "roms/" .. cart.sha1 .. ".png"
  fixture.iconStage = fixture.icon .. ".new"
  fixture.iconBackup = fixture.icon .. ".bak"
  function fixture:originalExists()
    local file = io.open(self.originalPath, "rb")
    if file == nil then
      return false
    end
    return file:close() == true
  end
  writeHostFile(fixture.originalPath, cart.data)
  writeHostFile(
    fixture.archivePath,
    require("tests.support.ZipBuilder").build({
      { name = "notes.txt", data = "not part of the managed source" },
      { name = "nested/ORIGINAL.NDS", data = cart.data },
    })
  )
  function fixture:writeTemporary(token, bytes)
    Assert.isTrue(token:match("^[A-Za-z0-9_-]+$"), "temporary token must be owned and safe")
    local path = "imports/" .. self.label .. "-" .. token .. ".nds"
    Assert.isNil(temporaryFiles[path], "temporary path must be written once")
    Assert.isTrue(love.filesystem.createDirectory("imports"), "temporary root setup failed")
    Assert.isTrue(love.filesystem.write(path, bytes or self.cart.data), "temporary fixture write failed")
    temporaryFiles[path] = true
    return path
  end
  function fixture:writePickerTemporary(requestId, bytes)
    Assert.isTrue(
      requestId:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil,
      "picker request must be a UUID"
    )
    Assert.isTrue(love.filesystem.createDirectory("imports"), "temporary root setup failed")
    local path = "imports/" .. requestId .. ".nds"
    Assert.isNil(temporaryFiles[path], "temporary path must be written once")
    Assert.isTrue(love.filesystem.write(path, bytes or self.cart.data), "temporary fixture write failed")
    temporaryFiles[path] = true
    return path
  end
  function fixture:managedMembers(fileName)
    local path = fileName and ("roms/" .. fileName) or self.canonical
    Assert.notNil(love.filesystem.getInfo(path), "managed archive must exist: " .. path)
    local bytes = assert(love.filesystem.read(path), "managed archive must be readable")
    self.mountSequence = self.mountSequence + 1
    local namespace = "managed-test-" .. label .. "-" .. self.mountSequence
    local data = love.filesystem.newFileData(bytes, "managed-test.zip")
    Assert.isTrue(love.filesystem.mount(data, namespace), "managed archive must mount as ZIP")
    local names = {}
    local function walk(directory)
      for _, name in ipairs(love.filesystem.getDirectoryItems(directory)) do
        local full = directory .. "/" .. name
        local info = love.filesystem.getInfo(full)
        if info.type == "directory" then
          walk(full)
        else
          names[#names + 1] = full:sub(#namespace + 2)
        end
      end
    end
    local ok, result = pcall(function()
      walk(namespace)
      table.sort(names)
      return { names = names, bytes = assert(love.filesystem.read(namespace .. "/game.nds")) }
    end)
    love.filesystem.unmount(data:getFilename())
    if not ok then
      error(result, 0)
    end
    return result
  end
  local ok, err = pcall(fn, fixture)
  host:close()
  for path in pairs(temporaryFiles) do
    pcall(love.filesystem.remove, path)
  end
  for _, path in ipairs({
    fixture.canonical,
    fixture.stage,
    fixture.backup,
    fixture.icon,
    fixture.iconStage,
    fixture.iconBackup,
  }) do
    pcall(love.filesystem.remove, path)
  end
  SnapshotArchive.removeTree(cart.info.id)
  GameVersion.VERSIONS[cart.info.id] = nil
  pcall(removeHostTree, root)
  if not ok then
    error(err, 0)
  end
end

return Fixture
