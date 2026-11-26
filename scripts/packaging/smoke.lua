-- Build-only archive probe. This wrapper is copied beside a payload and is never
-- included in the product archive.

local App
local pool
local service
local frames = 0
local complete = false

local function fail(message)
  io.stderr:write("archive smoke: " .. tostring(message) .. "\n")
  love.event.quit(1)
end

local function readMember(path)
  local bytes = love.filesystem.read(path)
  if bytes == nil then
    fail("missing packaged member " .. path)
  end
  return bytes
end

local function shutdown()
  if App then
    App.quit()
    App = nil
  end
  if pool and not pool.closed then
    pool:shutdown()
  end
  pool = nil
  if service then
    service:shutdown()
    service = nil
  end
end

local function verifySelection()
  local GameSelectState = require("app.src.launcher.GameSelectState")
  assert(App.state and getmetatable(App.state) == GameSelectState, "ROM-free boot did not reach game selection")
  local view = App.state:view()
  local BuildInfo = require("app.src.BuildInfo")
  local GameVersion = require("romdump.src.source.GameVersion")
  assert(#GameVersion.ORDER == 2, "the packaged edition catalog must contain two slots")
  assert(#view.games == #GameVersion.ORDER, "selection did not expose both edition slots")
  for index, versionId in ipairs(GameVersion.ORDER) do
    local game = view.games[index]
    assert(game.versionId == versionId, "selection changed the edition order")
    assert(game.installed == false, "ROM-free smoke found an unexpected managed source")
  end
  local validFocus = view.focusedId == view.games[1].versionId or view.focusedId == view.games[2].versionId
  assert(validFocus, "selection did not focus an edition slot")
  assert(view.version == BuildInfo.version, "selection did not expose packaged identity")
  assert(view.mode == "selection" and view.import == nil, "selection has an unexpected import operation")
  assert(App.importer == nil, "selection retained a busy ROM importer")
end

local function verifyWorkers()
  local CacheService = require("app.src.CacheService")
  service = CacheService.new()
  assert(service:select({ versionId = "heartgold" }), "controller worker did not start")
  service:update()
  service:shutdown()
  service = nil

  local CompilerPool = require("romdump.src.build.CompilerPool")
  pool = CompilerPool.new({ mode = "interactive" })
  assert(#pool.workers > 0, "compiler workers did not start")
  assert(pool:shutdown(), "compiler workers did not retire")
  pool = nil
end

local function finish()
  verifySelection()
  verifyWorkers()
  shutdown()
  local BuildInfo = require("app.src.BuildInfo")
  print(string.format("ARCHIVE_SMOKE_OK version=%s commit=%s frames=%d", BuildInfo.version, BuildInfo.commit, frames))
  complete = true
  love.event.quit(0)
end

local function runProbe()
  package.path = "./?.lua;./?/init.lua"
  local BuildInfo = require("app.src.BuildInfo")
  assert(BuildInfo.version == os.getenv("PORTEMON_SMOKE_VERSION"), "wrong packaged version")
  assert(BuildInfo.commit == os.getenv("PORTEMON_SMOKE_COMMIT"), "wrong packaged commit")

  for _, path in ipairs({
    "assets/fonts/galmuri/Galmuri9.ttf",
    "assets/fonts/galmuri/Galmuri11.ttf",
    "assets/fonts/galmuri/Galmuri11-Bold.ttf",
    "assets/fonts/galmuri/LICENSE.txt",
    "assets/fonts/mplus1p/MPLUS1p-Bold.ttf",
    "assets/fonts/mplus1p/MPLUS1p-Regular.ttf",
    "assets/fonts/mplus1p/OFL.txt",
    "assets/audio/launcher/boot.ogg",
    "assets/audio/launcher/focus.ogg",
    "assets/audio/launcher/confirm.ogg",
    "assets/audio/launcher/back.ogg",
    "assets/audio/launcher/error.ogg",
    "assets/logo.png",
    "assets/ui/mainmenu/sign-out-left.png",
    "assets/ui/mainmenu/LICENSE.phosphor.txt",
    "libs/nds/src/love/shaders/map.glsl",
    "gen4/battle.lua",
    "data/scripts/overrides/common.pokecenter_pc.lua",
  }) do
    assert(#readMember(path) > 0, "empty packaged member " .. path)
  end

  for path, name in pairs({
    ["assets/fonts/galmuri/Galmuri9.ttf"] = "Galmuri9.ttf",
    ["assets/fonts/galmuri/Galmuri11.ttf"] = "Galmuri11.ttf",
    ["assets/fonts/mplus1p/MPLUS1p-Bold.ttf"] = "MPLUS1p-Bold.ttf",
  }) do
    local font = assert(love.filesystem.newFileData(readMember(path), name))
    local loadedFont = assert(love.graphics.newFont(font))
    font:release()
    loadedFont:release()
  end
  if type(love.sound) == "table" and type(love.sound.newSoundData) == "function" then
    local cue = assert(love.filesystem.newFileData(readMember("assets/audio/launcher/boot.ogg"), "boot.ogg"))
    local decoded = assert(love.sound.newSoundData(cue))
    cue:release()
    decoded:release()
  end

  local logoPath = "assets/logo.png"
  local logoData = assert(love.filesystem.newFileData(readMember(logoPath), "logo.png"))
  local logo = assert(love.graphics.newImage(logoData), "packaged boot logo must decode")
  logoData:release()
  local logoWidth, logoHeight = logo:getDimensions()
  assert(logoWidth == 451 and logoHeight == 115, "packaged boot logo must be 451x115")
  logo:release()

  local iconPath = "assets/ui/mainmenu/sign-out-left.png"
  local iconData = assert(love.filesystem.newFileData(readMember(iconPath), "sign-out-left.png"))
  local icon = assert(love.graphics.newImage(iconData), "packaged Return icon must decode")
  iconData:release()
  local iconWidth, iconHeight = icon:getDimensions()
  assert(iconWidth == 20 and iconHeight == 20, "packaged Return icon must be 20x20")
  icon:release()

  local RepoFs = require("libs.storage.src.RepoFs")
  local source = RepoFs.new("outside-checkout", love.filesystem)
  local override = "data/scripts/overrides/common.pokecenter_pc.lua"
  assert(source:read(override) == readMember(override), "archived override did not use source-first reads")
  assert(type(require("gen4.battle")) == "table", "packaged battle facade did not load")

  App = require("app.src.App")
  App.load({ dev = false })
end

function love.load()
  local ok, failure = xpcall(runProbe, debug.traceback)
  if not ok then
    fail(failure)
  end
end

function love.update()
  if App and not complete then
    App.update(1 / 60)
  end
end

function love.draw()
  if not App or complete then
    return
  end
  local ok, failure = xpcall(function()
    App.draw()
    frames = frames + 1
    local GameSelectState = require("app.src.launcher.GameSelectState")
    if App.state and getmetatable(App.state) == GameSelectState then
      finish()
    elseif frames >= 360 then
      error("ROM-free boot did not reach two-slot selection within 360 frames", 0)
    end
  end, debug.traceback)
  if not ok then
    fail(failure)
  end
end

function love.quit()
  shutdown()
end
