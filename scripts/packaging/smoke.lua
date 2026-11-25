-- Build-only archive probe. This wrapper is copied beside a payload and is never
-- included in the product archive.

local function fail(message)
  io.stderr:write("archive smoke: " .. tostring(message) .. "\n")
  love.event.quit(1)
end

local App
local pool
local service
local frames = 0

local function readMember(path)
  local bytes = love.filesystem.read(path)
  if bytes == nil then
    fail("missing packaged member " .. path)
  end
  return bytes
end

local function runProbe()
  package.path = "./?.lua;./?/init.lua"
  local BuildInfo = require("app.src.BuildInfo")
  assert(BuildInfo.version == os.getenv("PORTEMON_SMOKE_VERSION"), "wrong packaged version")
  assert(BuildInfo.commit == os.getenv("PORTEMON_SMOKE_COMMIT"), "wrong packaged commit")

  for _, path in ipairs({
    "assets/fonts/galmuri/Galmuri11.ttf",
    "assets/fonts/galmuri/Galmuri11-Bold.ttf",
    "assets/fonts/mplus1p/MPLUS1p-Regular.ttf",
    "assets/ui/launcher/icons/add-game.png",
    "assets/audio/launcher/boot.ogg",
    "libs/nds/src/love/shaders/map.glsl",
    "gen4/battle.lua",
    "data/scripts/overrides/common.pokecenter_pc.lua",
  }) do
    assert(#readMember(path) > 0, "empty packaged member " .. path)
  end

  local font = assert(love.filesystem.newFileData(readMember("assets/fonts/galmuri/Galmuri11.ttf"), "Galmuri11.ttf"))
  local loadedFont = assert(love.graphics.newFont(font))
  loadedFont:release()
  local image = assert(love.filesystem.newFileData(readMember("assets/ui/launcher/icons/add-game.png"), "add-game.png"))
  local loadedImage = assert(love.graphics.newImage(image))
  loadedImage:release()

  local RepoFs = require("libs.storage.src.RepoFs")
  local source = RepoFs.new("outside-checkout", love.filesystem)
  local override = "data/scripts/overrides/common.pokecenter_pc.lua"
  assert(source:read(override) == readMember(override), "archived override did not use source-first reads")
  assert(type(require("gen4.battle")) == "table", "packaged battle facade did not load")

  App = require("app.src.App")
  App.load({ dev = false })
  for _ = 1, 150 do
    App.update(1 / 60)
    App.draw()
    frames = frames + 1
  end
  local GameSelectState = require("app.src.launcher.GameSelectState")
  assert(App.state and getmetatable(App.state) == GameSelectState, "ROM-free boot did not reach game selection")
  local view = App.state:view()
  assert(view.version == BuildInfo.version, "selection did not expose packaged identity")
  assert(#view.games == 0 and view.status == nil, "empty library was not presented")
  assert(view.focusedId == "add-game", "empty library must focus Add game")

  local CacheService = require("app.src.CacheService")
  service = CacheService.new()
  assert(service:select({ versionId = "heartgold" }), "controller worker did not start")
  service:update()
  service:shutdown()

  local CompilerPool = require("romdump.src.build.CompilerPool")
  pool = CompilerPool.new({ mode = "interactive" })
  assert(#pool.workers > 0, "compiler workers did not start")
  assert(pool:shutdown(), "compiler workers did not retire")

  App.quit()
  print(string.format("ARCHIVE_SMOKE_OK version=%s commit=%s frames=%d", BuildInfo.version, BuildInfo.commit, frames))
  love.event.quit(0)
end

function love.load()
  local ok, failure = xpcall(runProbe, debug.traceback)
  if not ok then
    fail(failure)
  end
end

function love.update()
  if App and frames >= 150 then
    App.update(1 / 60)
    App.draw()
  end
end

function love.draw()
  if App and frames < 150 then
    App.update(1 / 60)
    App.draw()
    frames = frames + 1
  end
end

function love.quit()
  if App then
    App.quit()
  end
  if pool and not pool.closed then
    pool:shutdown()
  end
  if service then
    service:shutdown()
  end
end
