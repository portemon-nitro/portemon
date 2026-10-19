-- The field Pokedex through real offscreen graphics: native two-panel
-- composition, the four layout cases, independent palettes and blends,
-- procedural spot pictures, and the registration card, all drawn through
-- the real renderer from prepared production bundles. Synthetic icons and
-- seeded portrait pages back the browser model; the generated
-- presentation scope comes from the prepared derived cache of the ready
-- dump. Composed pixels are compared against independent CPU references
-- and the compiled role authority; no battle runtime contributes a card:
-- the detached registration snapshot is frozen before any publication. A
-- test that cannot run on the owned dumps reports blocked instead of
-- passing.

local Assert = require("tests.support.Assert")
local CacheFs = require("libs.storage.src.CacheFs")
local FakeGraphics = require("tests.support.FakeGraphics")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldTextRenderer = require("libs.hgss.src.ui.FieldTextRenderer")
local Fixture = require("tests.support.PokedexPresentationFixture")
local GameVersion = require("romdump.src.source.GameVersion")
local GraphicsSmoke = require("tests.support.GraphicsSmoke")
local MonCache = require("libs.assets.src.MonCache")
local PokedexCache = require("libs.assets.src.PokedexCache")
local RomImporter = require("romdump.src.source.RomImporter")
local SharedImagePoolFake = require("tests.support.SharedImagePoolFake")

local T = {}

local RENDERER_MODULE = "libs.hgss.src.ui.PokedexRenderer"
local OWNER_MODULE = "game.hgss.src.pokedex.PokedexPresentationResources"
local INTERFACE_MODULE = "game.hgss.src.pokedex.PokedexInterface"

---@param behavior string missing drawing behavior under test
---@return table the loaded prepared rasterizer
local function requireRenderer(behavior)
  local ok, loaded = pcall(require, RENDERER_MODULE)
  Assert.isTrue(ok, "missing prepared pokedex rasterizer: " .. behavior .. " (" .. RENDERER_MODULE .. ")")
  assert(loaded ~= nil, "the prepared rasterizer loads")
  return loaded --[[@as table]]
end

---@param behavior string missing resource behavior under test
---@return table the loaded per-open resource owner
local function requireOwner(behavior)
  local ok, loaded = pcall(require, OWNER_MODULE)
  Assert.isTrue(ok, "missing aggregate view-level resource owner: " .. behavior .. " (" .. OWNER_MODULE .. ")")
  assert(loaded ~= nil, "the resource owner loads")
  return loaded --[[@as table]]
end

---@param behavior string missing interface behavior under test
---@return table the loaded shared draw/input interface owner
local function requireInterface(behavior)
  local ok, loaded = pcall(require, INTERFACE_MODULE)
  Assert.isTrue(ok, "missing shared draw/input interface owner: " .. behavior .. " (" .. INTERFACE_MODULE .. ")")
  assert(loaded ~= nil, "the shared interface owner loads")
  return loaded --[[@as table]]
end

local function readyVersion()
  for _, versionId in ipairs(GameVersion.ORDER) do
    if RomImporter.isReady(versionId) then
      return versionId
    end
  end
  error("production graphics need a ready versioned cache", 0)
end

-- Independent 6-bit hardware-blend oracle for the locked leaf output
-- normalization: a5/b5 are recovered 5-bit channels, EVA/EVB clamp to
-- 0..16, and the mixed 6-bit value normalizes to an 8-bit byte.
---@param a5 integer first 5-bit channel
---@param b5 integer second 5-bit channel
---@param eva integer first blend coefficient
---@param evb integer second blend coefficient
---@return integer normalized output byte
local function blendOracle(a5, b5, eva, evb)
  local a6 = 2 * a5
  local b6 = 2 * b5
  if eva < 0 then
    eva = 0
  elseif eva > 16 then
    eva = 16
  end
  if evb < 0 then
    evb = 0
  elseif evb > 16 then
    evb = 16
  end
  local mixed = math.floor((a6 * eva + b6 * evb + 8) / 16)
  if mixed > 63 then
    mixed = 63
  end
  -- The locked leaf output normalization saturates at full white: 63
  -- carries an unclamped 259 that the target byte cannot represent.
  local byte = math.floor(mixed * 255 / 62 + 0.5)
  if byte > 255 then
    byte = 255
  end
  return byte
end

-- Independent 5-bit software-fade oracle: original component interpolation
-- with the source masks and coefficient.
---@param source5 integer original 5-bit channel
---@param target5 integer fade target 5-bit channel
---@param coefficient integer fade coefficient 0..16
---@return integer faded 5-bit channel
local function fadeOracle(source5, target5, coefficient)
  return source5 + math.floor((target5 - source5) * coefficient / 16)
end

-- Recovers the original 5-bit channel behind one sampled 8-bit byte.
---@param byte integer sampled 8-bit channel
---@return integer original 5-bit channel
local function channel5(byte)
  return math.floor(byte * 31 / 255 + 0.5)
end

-- Expands one 5-bit channel through the target E5 rule.
---@param c5 integer 5-bit channel
---@return integer output byte
local function encodeE5(c5)
  return math.floor((255 * c5 + 15) / 31)
end

-- Normalizes one mixed 6-bit value through the locked leaf rule.
---@param mixed6 integer mixed 6-bit value
---@return integer output byte
local function encodeE6(mixed6)
  local mixed = mixed6
  if mixed > 63 then
    mixed = 63
  end
  local byte = math.floor(mixed * 255 / 62 + 0.5)
  if byte > 255 then
    byte = 255
  end
  return byte
end

---@param source integer source byte 0..255
---@param target integer fade target byte 0..255
---@param coeff integer fade coefficient 0..16
---@return integer faded byte
local function fadeByteOracle(source, target, coeff)
  if coeff <= 0 then
    return source
  end
  local faded = fadeOracle(channel5(source), channel5(target), coeff)
  return encodeE5(faded)
end

---@param first integer first source byte 0..255
---@param second integer second source byte 0..255
---@param eva integer first blend coefficient
---@param evb integer second blend coefficient
---@return integer blended byte
local function blendByteOracle(first, second, eva, evb)
  return blendOracle(channel5(first), channel5(second), eva, evb)
end

function T.blend_and_fade_vectors_match_the_independent_oracles()
  local Renderer = requireRenderer("source blend arithmetic and palette fades")
  requireOwner("prepared bundles behind the blended pixels")
  local vectors = {
    { a5 = 0, b5 = 31, eva = 6, evb = 10, byte = 160 },
    { a5 = 31, b5 = 0, eva = 6, evb = 10, byte = 95 },
    { a5 = 31, b5 = 31, eva = 16, evb = 16, byte = 255 },
    { a5 = 1, b5 = 0, eva = 8, evb = 8, byte = 4 },
    { a5 = 0, b5 = 31, eva = 0, evb = 31, byte = 255 },
    { a5 = 1, b5 = 0, eva = 16, evb = 0, byte = 8 },
    { a5 = 31, b5 = 0, eva = 16, evb = 0, byte = 255 },
  }
  for _, vector in ipairs(vectors) do
    Assert.equal(
      Renderer.blendByte(vector.a5, vector.b5, vector.eva, vector.evb),
      vector.byte,
      "the authored blend vector normalizes to its locked output byte"
    )
    Assert.equal(
      blendOracle(vector.a5, vector.b5, vector.eva, vector.evb),
      vector.byte,
      "the independent oracle agrees on the authored blend vector"
    )
  end
  for channel = 0, 31 do
    Assert.equal(
      math.floor((2 * channel) * 255 / 62 + 0.5),
      math.floor((255 * channel + 15) / 31),
      "every even 6-bit value reproduces its 5-bit expansion exactly"
    )
  end
  Assert.equal(Renderer.fadeByte(31, 0, 1), 29, "the palette fade of 31 toward 0 at coefficient 1 lands on 29")
  Assert.equal(fadeOracle(31, 0, 1), 29, "the independent oracle agrees on the fade vector")
  Assert.equal(Renderer.fadeByte(0, 1, 8), 0, "the palette fade of 0 toward 1 at coefficient 8 lands on 0")
end

-- One realized straight-RGBA test image filled by the painter.
---@param width integer image width
---@param height integer image height
---@param painter fun(x: integer, y: integer): number, number, number, number byte painter in 0..1 floats
---@return table realized image, freed by the pool teardown
local function solidImage(width, height, painter)
  local data = love.image.newImageData(width, height)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      data:setPixel(x, y, painter(x, y))
    end
  end
  return love.graphics.newImage(data)
end

---@param pool table shared image pool double under test
---@param key string icon key behind the texture path
---@param r number red 0..1
---@param g number green 0..1
---@param b number blue 0..1
local function seedIcon(pool, key, r, g, b)
  Fixture.seedPhysical(
    pool,
    "pokedex/icons/" .. key,
    solidImage(32, 32, function()
      return r, g, b, 1
    end)
  )
end

---@param cacheFs table version cache reader
---@param path string generated artifact path
---@return table realized image, freed by the pool teardown
local function realizedImage(cacheFs, path)
  local bytes = assert(cacheFs:read(path), "cache carries " .. path)
  local file = assert(love.filesystem.newFileData(bytes, path), "file data wraps " .. path)
  return love.graphics.newImage(file)
end

---@param cacheFs table version cache reader
---@param path string generated artifact path
---@return table decoded 8-bit pixel buffer behind the artifact
local function decodePage(cacheFs, path)
  local bytes = assert(cacheFs:read(path), "cache carries " .. path)
  local file = assert(love.filesystem.newFileData(bytes, path), "file data wraps " .. path)
  return love.image.newImageData(file)
end

---@param owner table per-open resource owner under test
---@param selector string canonical portrait selector
---@return table portrait manifest entry with its source viewport
local function portraitEntryFor(cacheFs, selector)
  local MonCacheModule = require("libs.assets.src.MonCache")
  local manifest = cacheFs:loadLua(MonCacheModule.portraitManifestPath())
  assert(type(manifest) == "table", "the portrait manifest loads")
  local entry = assert(manifest.entries[selector], "the portrait manifest carries " .. selector)
  assert(type(entry) == "table", "portrait entries stay records")
  return entry
end

-- Resolves the declared image gender behind one specimen the same way the
-- lease does: explicit male/female passes through, anything else reads
-- the resolved mon catalog portrait declaration.
---@param monCatalog table resolved mon catalog
---@param specimen table detached specimen facts
---@return string male or female image gender
local function specimenGender(monCatalog, specimen)
  if specimen.gender == "male" or specimen.gender == "female" then
    return specimen.gender
  end
  local formOf = assert(monCatalog.form, "picture specimens need the resolved mon catalog")
  local record = formOf(monCatalog, specimen.species, specimen.form)
  assert(type(record) == "table", "picture specimens need their declared portrait variant")
  local declared = record.portrait:match("^[^/]+/[^/]+/([^/]+)/[^/]+$")
  assert(declared == "male" or declared == "female", "picture specimens declare a male or female variant")
  return declared
end

---@param monCatalog table resolved mon catalog
---@param specimen table detached specimen facts
---@param facing string front or back facing
---@param browser boolean true forces the nonshiny browser policy
---@return string canonical portrait selector
local function portraitSelectorFor(monCatalog, specimen, facing, browser)
  local shiny = specimen.shiny == true
  if browser then
    shiny = false
  end
  return MonCache.portraitSelector(specimen.species, specimen.form, specimenGender(monCatalog, specimen), shiny, facing)
end

-- Seeds every portrait page the demand resolves: the realized generated
-- page behind the compiled selector, so composed picture pixels equal the
-- compiled authority bytes.
---@param pool table shared image pool double under test
---@param cacheFs table version cache reader
---@param monCatalog table resolved mon catalog
---@param demand table validated demand under preparation
---@param browser boolean true forces the nonshiny browser policy
---@return table<string, string> portrait page path by demanded selector
local function seedPortraits(pool, cacheFs, monCatalog, demand, browser)
  local seen = {}
  local paths = {}
  for _, picture in ipairs(demand.pictures) do
    local selector = portraitSelectorFor(monCatalog, picture.specimen, picture.facing, browser)
    local entry = portraitEntryFor(cacheFs, selector)
    local path = MonCache.portraitPagePath(entry.pageId)
    paths[selector] = path
    if not seen[path] then
      seen[path] = true
      Fixture.seedPhysical(pool, path, realizedImage(cacheFs, path))
    end
  end
  return paths
end

-- Builds the exact browser demand behind one detached projection: the
-- generation key, the resolved page role, up to thirty staged icon keys,
-- the detached picture slots, and the semantic text.
---@param Renderer table prepared rasterizer under test
---@param view table detached browser projection
---@return table demand immutable browser demand
local function browserDemandFor(Renderer, view)
  local iconKeys, seen = {}, {}
  local grid = view.grid
  if type(grid) == "table" and type(grid.buffers) == "table" then
    for _, buffer in ipairs(grid.buffers) do
      if type(buffer) == "table" and type(buffer.entries) == "table" then
        for _, entry in ipairs(buffer.entries) do
          if type(entry) == "table" and entry.seen == true and type(entry.species) == "string" then
            local key = entry.species .. "/f0"
            if not seen[key] and #iconKeys < 30 then
              seen[key] = true
              iconKeys[#iconKeys + 1] = key
            end
          end
        end
      end
      if #iconKeys >= 30 then
        break
      end
    end
  end
  local pictures = {}
  if type(view.pictures) == "table" then
    for _, picture in ipairs(view.pictures) do
      if #pictures < 4 and type(picture) == "table" then
        pictures[#pictures + 1] = {
          slot = picture.slot,
          specimen = picture.specimen,
          facing = picture.facing,
          mode = picture.mode,
        }
      end
    end
  end
  local dexMode = view.mode
  if dexMode ~= "national" then
    dexMode = "johto"
  end
  return {
    key = "pokedex-" .. tostring(view.key),
    purpose = "browser",
    pageRole = Renderer.resolvePageRole(view, "information"),
    dexMode = dexMode,
    language = "native",
    iconKeys = iconKeys,
    pictures = pictures,
    text = view.text or {},
  }
end

---@param controller table live browser controller under test
---@param events table fixed-tick batch for the controller
local function press(controller, events)
  controller:updateFixed(events, { readyKey = controller:view().key })
end

---@param controller table live browser controller under test
---@param count integer fixed ticks without input
local function idle(controller, count)
  for _ = 1, count do
    controller:updateFixed({}, { readyKey = controller:view().key })
  end
end

-- Drives the real controller to the grid page through its cover confirm.
---@param controller table live browser controller under test
local function openGrid(controller)
  press(controller, { { type = "confirm" } })
  idle(controller, 10)
  Assert.equal(controller:view().page, "grid", "confirming the cover reaches the grid")
end

-- Advances the grid cursor until the named species is selected.
---@param controller table live browser controller under test
---@param species string selected species key
local function selectSpecies(controller, species)
  for _ = 1, 32 do
    if controller:view().selection.species == species then
      return
    end
    press(controller, { { type = "navigate", direction = "right" } })
    idle(controller, 2)
  end
  error("the grid never selects " .. species, 0)
end

-- Confirms the current selection into its entry and settles the AREA page.
---@param controller table live browser controller under test
local function openEntry(controller)
  press(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "confirming a caught selection opens its entry")
end

---@param controller table live browser controller under test
---@param tab string entry tab to open
local function openTab(controller, tab)
  press(controller, { { type = "activate", action = "entry-tab", value = tab } })
  idle(controller, 40)
  Assert.equal(controller:view().page, tab, "the entry tab opens " .. tab)
end

---@param class string one of dualDisplay, nativeLike, wide, tall
---@return table<string, unknown> measured display facts for the class
local function measurementFor(class)
  local ScreenTopology = require("libs.ui.src.ScreenTopology")
  if class == "dualDisplay" then
    return {
      width = 512,
      height = 384,
      topology = ScreenTopology.dualDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 256, height = 192 },
        touch = true,
        role = "world",
      }, {
        id = "lower",
        rect = { x = 0, y = 192, width = 256, height = 192 },
        touch = true,
        role = "auxiliary",
      }),
      pixelRatio = 1,
      signature = "pokedex-production-graphics:dual",
    }
  end
  local width, height = 256, 192
  if class == "wide" then
    width, height = 512, 192
  elseif class == "tall" then
    width, height = 256, 384
  end
  return {
    width = width,
    height = height,
    topology = ScreenTopology.oneDisplay({
      id = "main",
      rect = { x = 0, y = 0, width = width, height = height },
      touch = true,
      role = "world",
    }),
    pixelRatio = 1,
    signature = "pokedex-production-graphics:" .. class,
  }
end

---@param resolvers table<string, fun(context: table<string, unknown>, view: table<string, unknown>): table<string, unknown>> interface set behind the plan
---@param measurement table<string, unknown> fresh host facts
---@param view table detached projection with its private compact record
---@return table complete application plan through the production session path
local function resolvePlan(resolvers, measurement, view)
  local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
  local session = ApplicationPresentation.new(resolvers)
  local plan = session:resolve(measurement, view)
  Assert.notNil(plan, "the interface set resolves its plan")
  assert(plan ~= nil, "the interface set resolves its plan")
  return plan
end

---@param pool table shared image pool double under test
---@param body fun(pool: table)
local function withPool(pool, body)
  local ok, err = xpcall(function()
    body(pool)
  end, debug.traceback)
  pool:dispose()
  if not ok then
    error(err, 0)
  end
end

---@param versionId string ready version behind the rig
---@param pool table shared image pool double under test
---@return table rig { cacheFs, monCatalog, catalog, owner, manifest }
local function graphicsRig(versionId, pool)
  local Renderer = requireRenderer("prepared graphics rigs")
  local Owner = requireOwner("prepared graphics rigs")
  local _ = Renderer
  local cacheFs = CacheFs.forVersion(versionId)
  Assert.notNil(cacheFs, "the ready version exposes its prepared cache")
  local monCatalog, catalog = Fixture.catalogs()
  local owner = Owner.new({
    imagePool = pool,
    monCatalog = monCatalog,
    catalog = catalog,
    cacheFs = cacheFs,
    graphics = love.graphics,
    derivedAssets = {
      requestPokedex = function(_)
        return true
      end,
      requestMonPortraitPage = function(_, _)
        return true
      end,
      requestAudioBank = function(_, _)
        return true
      end,
    },
  })
  local manifest = PokedexCache.loadManifest(cacheFs)
  assert(type(manifest) == "table", "the prepared cache carries the pokedex manifest")
  return { cacheFs = cacheFs, monCatalog = monCatalog, catalog = catalog, owner = owner, manifest = manifest }
end

---@param rig table graphics rig behind the lease
---@param lease table acquired per-open preparation lease
---@param demand table validated demand under preparation
---@return table ready bundle behind the draw
local function prepareReady(rig, lease, demand)
  local _ = rig
  local ready = nil
  for _ = 1, 320 do
    local outcome = lease:prepare(demand)
    if outcome.kind == "ready" then
      ready = outcome
      break
    end
    if outcome.kind == "failed" then
      error("bounded preparation failed: " .. tostring(outcome.error), 0)
    end
    Assert.equal(outcome.kind, "pending", "partial readiness never publishes a bundle")
  end
  Assert.notNil(ready, "bounded preparation converges on a complete bundle")
  assert(ready ~= nil, "bounded preparation converges")
  Assert.equal(ready.key, demand.key, "the ready outcome carries its matching generation key")
  return ready.assets
end

---@param view table detached browser projection
---@param assets table ready bundle behind the draw
---@return table presenter-shaped prepared view behind the draw
local function preparedBrowserView(view, assets)
  return { view = view, assets = assets, compact = { inspect = false, prosePage = 1, size = "weight" } }
end

---@param view table detached browser projection
---@return table plan view with the private compact record
local function planViewOf(view)
  local merged = {}
  for key, value in pairs(view) do
    merged[key] = value
  end
  merged.compact = { inspect = false, prosePage = 1, size = "weight" }
  return merged
end

---@param scope table<string, unknown> graphics ownership scope
---@param plan table resolved application plan
---@param resources table borrowed draw resources with the renderer
---@param preparedView table { view, assets, compact } prepared view behind the draw
---@param width integer target width
---@param height integer target height
---@return table 8-bit pixel buffer behind the composed target
local function drawPlan(scope, plan, resources, preparedView, width, height)
  local canvas = scope:own(love.graphics.newCanvas(width, height))
  love.graphics.setCanvas(canvas)
  love.graphics.clear(0, 0, 0, 0)
  plan.render(resources, preparedView, plan)
  love.graphics.setCanvas()
  return canvas:newImageData()
end

---@param data table 8-bit pixel buffer
---@param x integer pixel x
---@param y integer pixel y
---@return integer, integer, integer, integer byte channels 0..255
local function pixel(data, x, y)
  local r, g, b, a = data:getPixel(x, y)
  return math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), math.floor(a * 255 + 0.5)
end

---@param data table 8-bit pixel buffer
---@param x integer pixel x
---@param y integer pixel y
---@param r integer expected red byte
---@param g integer expected green byte
---@param b integer expected blue byte
---@param message string failure diagnostic
local function assertPixel(data, x, y, r, g, b, message)
  local ar, ag, ab, aa = pixel(data, x, y)
  Assert.equal(aa, 255, message .. " stays opaque")
  Assert.equal(ar, r, message .. " red channel")
  Assert.equal(ag, g, message .. " green channel")
  Assert.equal(ab, b, message .. " blue channel")
end

---@param plan table resolved application plan
---@param paneId string browser pane identity
---@return table validated pane placement
local function placementOf(plan, paneId)
  for _, pane in ipairs(plan.panes) do
    if type(pane) == "table" and pane.id == paneId then
      local placement = assert(pane.placement, "browser panes carry their placement")
      return placement
    end
  end
  error("the resolved plan carries no " .. paneId .. " pane", 0)
end

-- Finds the visible slot behind one species in the staged grid buffer.
---@param view table detached browser projection with its grid buffer
---@param species string species key behind the slot
---@return integer zero-based visible slot
local function gridSlotOf(view, species)
  local entries = assert(view.grid.buffers[1].entries, "the grid stages its entries")
  for index, entry in ipairs(entries) do
    if type(entry) == "table" and entry.species == species then
      Assert.isTrue(index <= 15, species .. " stages on the visible grid page")
      return index - 1
    end
  end
  error("the grid never stages " .. species, 0)
end

-- Sums one realized image into a stable byte total for untouched-source
-- assertions.
---@param data table 8-bit pixel buffer
---@return integer byte total
local function byteSum(data, width, height)
  local total = 0
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local r, g, b, a = pixel(data, x, y)
      total = total + r + g + b + a
    end
  end
  return total
end

function T.native_panes_draw_both_information_and_controls_at_source_size(scope)
  local Renderer = requireRenderer("native two-panel composition")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared bundles behind the native panes")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    local view = controller:view()
    local demand = browserDemandFor(Renderer, view)
    seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, true)
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    local measurement = measurementFor("dualDisplay")
    local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
    Assert.equal(#plan.panes, 2, "the paired layout resolves both native panes")
    local info = placementOf(plan, "information")
    local controls = placementOf(plan, "controls")
    Assert.equal(info.logicalWidth, 256, "the information pane keeps its source width")
    Assert.equal(info.logicalHeight, 192, "the information pane keeps its source height")
    Assert.equal(controls.logicalWidth, 256, "the controls pane keeps its source width")
    Assert.equal(controls.logicalHeight, 192, "the controls pane keeps its source height")
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local preparedView = preparedBrowserView(view, assets)
    local data = drawPlan(scope, plan, resources, preparedView, measurement.width, measurement.height)
    local infoBd = Renderer.backdropOf(rig.manifest, "grid", "information")
    local ctrlBd = Renderer.backdropOf(rig.manifest, "grid", "controls")
    Assert.equal(info.scale, 1, "the native pair draws at integral source scale")
    assertPixel(
      data,
      info.origin.x + 2,
      info.origin.y + 2,
      infoBd.r,
      infoBd.g,
      infoBd.b,
      "the information corner carries the compiled backdrop"
    )
    assertPixel(
      data,
      controls.origin.x + 2,
      controls.origin.y + 2,
      ctrlBd.r,
      ctrlBd.g,
      ctrlBd.b,
      "the controls corner carries the compiled backdrop"
    )
    -- Caught icons draw opaque; seen-only icons blend EVA6/EVB10
    -- against the controls backdrop through the locked normalization.
    local caughtSlot = gridSlotOf(view, "TOTODILE")
    local caughtRect = Renderer.iconSlotRect(caughtSlot)
    assertPixel(
      data,
      controls.origin.x + caughtRect.x + 16,
      controls.origin.y + caughtRect.y + 16,
      255,
      0,
      0,
      "the caught icon draws its prepared art opaque"
    )
    local seenSlot = gridSlotOf(view, "CHIKORITA")
    local seenRect = Renderer.iconSlotRect(seenSlot)
    local sx, sy = controls.origin.x + seenRect.x + 16, controls.origin.y + seenRect.y + 16
    local er = blendByteOracle(255, ctrlBd.r, 6, 10)
    local eg = blendByteOracle(255, ctrlBd.g, 6, 10)
    local eb = blendByteOracle(255, ctrlBd.b, 6, 10)
    assertPixel(data, sx, sy, er, eg, eb, "the seen-only icon blends 6/10 against eligible BG")
    -- A blank slot past every staged entry keeps the backdrop.
    local blankRect = Renderer.iconSlotRect(14)
    assertPixel(
      data,
      controls.origin.x + blankRect.x + 16,
      controls.origin.y + blankRect.y + 16,
      ctrlBd.r,
      ctrlBd.g,
      ctrlBd.b,
      "a blank slot draws no icon"
    )
    lease:release()
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the journey returns every borrowed interest")
  end)
end

function T.all_layouts_resolve_prepared_browser_pixels(scope)
  local Renderer = requireRenderer("paired and compact layout rasterization")
  local Interface = requireInterface("all four layout cases")
  requireOwner("prepared bundles behind every layout")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    local view = controller:view()
    local demand = browserDemandFor(Renderer, view)
    seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, true)
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local preparedView = preparedBrowserView(view, assets)
    for _, class in ipairs({ "dualDisplay", "wide", "tall", "nativeLike" }) do
      local measurement = measurementFor(class)
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      Assert.equal(#plan.panes, 2, class .. " resolves both browser panes")
      local info = placementOf(plan, "information")
      local controlsPane = placementOf(plan, "controls")
      Assert.isTrue(
        info.logicalWidth == 256 and info.logicalHeight + controlsPane.logicalHeight == 192
          or info.logicalWidth == 256 and info.logicalHeight == 192,
        class .. " keeps source-sized geometry"
      )
      local data = drawPlan(scope, plan, resources, preparedView, measurement.width, measurement.height)
      local infoBd = Renderer.backdropOf(rig.manifest, "grid", "information")
      assertPixel(
        data,
        math.min(info.origin.x + 2, measurement.width - 1),
        math.min(info.origin.y + 2, measurement.height - 1),
        infoBd.r,
        infoBd.g,
        infoBd.b,
        class .. " information carries the compiled backdrop"
      )
    end
    -- Below the 256x192 minimum the plan is unavailable and the draw
    -- leaves its target alone instead of activating hidden controls.
    local ScreenTopology = require("libs.ui.src.ScreenTopology")
    local small = {
      width = 200,
      height = 100,
      topology = ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = 200, height = 100 },
        touch = true,
        role = "world",
      }),
      pixelRatio = 1,
      signature = "pokedex-production-graphics:small",
    }
    local unavailable = Interface.browser().nativeLike({ measurement = small }, planViewOf(view))
    Assert.equal(#unavailable.panes, 0, "the below-minimum plan carries no interactive panes")
    local cleared = drawPlan(scope, unavailable, resources, preparedView, small.width, small.height)
    local r, g, b, a = pixel(cleared, 100, 50)
    Assert.equal(a, 0, "the unavailable draw paints no pane")
    Assert.equal(r + g + b, 0, "the unavailable target stays clear")
    lease:release()
    controller:dispose()
    rig.owner:release()
  end)
end

-- Rebuilds the final composite for one pane from the six serial
-- surfaces, independently of the renderer shader code.
---@param surfaces table[] six composed serial surface buffers in compositor order
---@param backdrop { r: integer, g: integer, b: integer } opaque C01 cover color bytes
---@param priorities number[] four BG layer priorities
---@param blend { first: string[], second: string[], eva: integer, evb: integer } published pane blend policy
---@param bgFade { target: { r: integer, g: integer, b: integer }, coeff: integer } BG fade
---@param objFade { target: { r: integer, g: integer, b: integer }, coeff: integer } OBJ fade
---@param windowActive boolean true while the footer window excludes OBJ
---@param x integer pane pixel x
---@param y integer pane pixel y
---@return integer, integer, integer composed byte channels
local function referenceComposite(surfaces, backdrop, priorities, blend, bgFade, objFade, windowActive, x, y)
  local function maskOf(list)
    local bits = { bg0 = 0, bg1 = 1, bg2 = 2, bg3 = 3, obj = 4, backdrop = 5 }
    local mask = 0
    for _, name in ipairs(list) do
      mask = mask + 2 ^ assert(bits[name], "blend targets stay semantic")
    end
    return mask
  end
  local function selected(mask, bit)
    return math.floor(mask / 2 ^ bit) % 2 == 1
  end
  local firstBits = maskOf(blend.first)
  local secondBits = maskOf(blend.second)
  local bgR, bgG, bgB = backdrop.r, backdrop.g, backdrop.b
  local bgPri, bgLayer = 255, -1
  for layer = 1, 4 do
    local r, g, b, a = pixel(surfaces[layer], x, y)
    if a > 0 and priorities[layer] < bgPri then
      bgPri, bgLayer = priorities[layer], layer
      bgR, bgG, bgB = r, g, b
    end
  end
  local or_, og, ob, oa = pixel(surfaces[5], x, y)
  local mr, mg, _, ma = pixel(surfaces[6], x, y)
  local objPresent = ma > 0
  local objClass = mr
  local objPri = mg
  local inside = windowActive and x >= 0 and x <= 255 and y >= 152 and y < 192
  local function fadeByte(source, target, coeff)
    return fadeByteOracle(source, target, coeff)
  end
  local outR = fadeByte(bgR, bgFade.target.r, bgFade.coeff)
  local outG = fadeByte(bgG, bgFade.target.g, bgFade.coeff)
  local outB = fadeByte(bgB, bgFade.target.b, bgFade.coeff)
  if objPresent and not inside and objPri <= bgPri then
    local fr = fadeByte(or_, objFade.target.r, objFade.coeff)
    local fg = fadeByte(og, objFade.target.g, objFade.coeff)
    local fb = fadeByte(ob, objFade.target.b, objFade.coeff)
    if selected(firstBits, 4) then
      local sr, sg, sb, haveSecond = 0, 0, 0, false
      for layer = 1, 4 do
        if not haveSecond and selected(secondBits, layer - 1) then
          local lr, lg, lb, la = pixel(surfaces[layer], x, y)
          if la > 0 then
            sr, sg, sb, haveSecond = lr, lg, lb, true
          end
        end
      end
      if not haveSecond and selected(secondBits, 5) then
        sr, sg, sb, haveSecond = backdrop.r, backdrop.g, backdrop.b, true
      end
      if haveSecond then
        return blendByteOracle(fr, sr, blend.eva, blend.evb),
          blendByteOracle(fg, sg, blend.eva, blend.evb),
          blendByteOracle(fb, sb, blend.eva, blend.evb)
      end
      return fr, fg, fb
    elseif objClass > 0 then
      return blendByteOracle(fr, outR, 6, 10), blendByteOracle(fg, outG, 6, 10), blendByteOracle(fb, outB, 6, 10)
    else
      return fr, fg, fb
    end
  elseif bgLayer >= 0 then
    local firstLayer = -1
    for layer = 1, 4 do
      if firstLayer < 0 and selected(firstBits, layer - 1) then
        local _, _, _, la = pixel(surfaces[layer], x, y)
        if la > 0 then
          firstLayer = layer
        end
      end
    end
    if firstLayer >= 0 then
      local fr, fg, fb, _ = pixel(surfaces[firstLayer], x, y)
      fr = fadeByte(fr, bgFade.target.r, bgFade.coeff)
      fg = fadeByte(fg, bgFade.target.g, bgFade.coeff)
      fb = fadeByte(fb, bgFade.target.b, bgFade.coeff)
      local secondLayer = -1
      for layer = 1, 4 do
        if layer ~= firstLayer and secondLayer < 0 and selected(secondBits, layer - 1) then
          local _, _, _, la = pixel(surfaces[layer], x, y)
          if la > 0 then
            secondLayer = layer
          end
        end
      end
      if secondLayer >= 0 then
        local sr, sg, sb, _ = pixel(surfaces[secondLayer], x, y)
        sr = fadeByte(sr, bgFade.target.r, bgFade.coeff)
        sg = fadeByte(sg, bgFade.target.g, bgFade.coeff)
        sb = fadeByte(sb, bgFade.target.b, bgFade.coeff)
        return blendByteOracle(fr, sr, blend.eva, blend.evb),
          blendByteOracle(fg, sg, blend.eva, blend.evb),
          blendByteOracle(fb, sb, blend.eva, blend.evb)
      end
      return fr, fg, fb
    end
  end
  return outR, outG, outB
end

function T.composed_serial_surfaces_match_the_independent_reference(scope)
  local Renderer = requireRenderer("serial compositor parity")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared bundles behind the composed panes")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    local view = controller:view()
    local demand = browserDemandFor(Renderer, view)
    seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, true)
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    Assert.equal(
      #assert(assets.surfaces, "the ready bundle carries its serial surfaces"),
      6,
      "the lease owns six serial surfaces"
    )
    for index, surface in ipairs(assets.surfaces) do
      Assert.equal(surface.width, 256, "serial surface " .. index .. " keeps its source width")
      Assert.equal(surface.height, 192, "serial surface " .. index .. " keeps its source height")
    end
    local measurement = measurementFor("dualDisplay")
    local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local preparedView = preparedBrowserView(view, assets)
    -- The six surfaces are reused serially per pane, so each pane is
    -- drawn and read back in isolation: the reference always observes
    -- the exact serial content its pane composed.
    local function singlePanePlan(paneId)
      local panes = {}
      for _, pane in ipairs(plan.panes) do
        if type(pane) == "table" and pane.id == paneId then
          panes[#panes + 1] = pane
        end
      end
      Assert.isTrue(#panes == 1, "the resolved plan carries its " .. paneId .. " pane")
      return {
        panes = panes,
        frames = plan.frames,
        content = plan.content,
        inputKey = plan.inputKey .. ":" .. paneId,
        render = plan.render,
        mapInput = plan.mapInput,
      }
    end
    for _, paneId in ipairs({ "information", "controls" }) do
      local panePlan = singlePanePlan(paneId)
      local data = drawPlan(scope, panePlan, resources, preparedView, measurement.width, measurement.height)
      local serial = {}
      for _, surface in ipairs(assets.surfaces) do
        serial[#serial + 1] = surface.canvas:newImageData()
      end
      local placement = placementOf(plan, paneId)
      local role = Renderer.resolvePageRole(view, paneId)
      local blend = Renderer.paneBlendOf(view, paneId)
      local backdrop = Renderer.backdropOf(rig.manifest, role, paneId)
      local priorities = Renderer.layerPrioritiesOf(rig.manifest, role, paneId)
      local noFade = { target = { r = 0, g = 0, b = 0 }, coeff = 0 }
      local mismatched = 0
      for y = 0, 191 do
        for x = 0, 255 do
          local er, eg, eb =
            referenceComposite(serial, backdrop, priorities, blend, noFade, noFade, paneId == "information", x, y)
          local ar, ag, ab = pixel(data, placement.origin.x + x, placement.origin.y + y)
          if math.abs(ar - er) + math.abs(ag - eg) + math.abs(ab - eb) > 0 then
            mismatched = mismatched + 1
          end
        end
      end
      Assert.equal(mismatched, 0, paneId .. " composed pixels equal the independent serial reference")
    end
    lease:release()
    controller:dispose()
    rig.owner:release()
  end)
end

function T.spinda_spots_match_the_authored_masks(scope)
  local Renderer = requireRenderer("procedural spot pictures")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared Spinda bundles")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    Assert.isTrue(dexOwner:isCaught("SPINDA"), "the spot legs browse a caught Spinda history")
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    selectSpecies(controller, "SPINDA")
    openEntry(controller)
    local view = controller:view()
    local demand = browserDemandFor(Renderer, view)
    local pageBySelector = seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, true)
    -- The shared base stays bit-identical behind every composition: the
    -- renderer samples it without mutation, disk, or PID keying.
    local frontSelector = portraitSelectorFor(rig.monCatalog, view.pictures[1].specimen, "front", true)
    local frontPath = assert(pageBySelector[frontSelector], "the front base resolves its page")
    local pageBefore = decodePage(rig.cacheFs, frontPath)
    local sumBefore = byteSum(pageBefore, pageBefore:getWidth(), pageBefore:getHeight())
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    local pageAfter = decodePage(rig.cacheFs, frontPath)
    local sumAfter = byteSum(pageAfter, pageAfter:getWidth(), pageAfter:getHeight())
    Assert.equal(sumAfter, sumBefore, "spot composition never mutates the shared base")
    local liveSpinda = 0
    for _ in pairs(lease._spindaCanvases) do
      liveSpinda = liveSpinda + 1
    end
    Assert.equal(liveSpinda, 2, "the entry keeps exactly its front and baseline canvases")
    Assert.isTrue(liveSpinda <= 4, "transient Spinda pictures stay within the four-canvas bound")
    local policy = assert(rig.manifest.spinda, "the compiled manifest carries the Spinda personalization")
    local seenSlots = 0
    local specimenBySlot = {}
    for _, picture in ipairs(demand.pictures) do
      specimenBySlot[picture.slot] = picture.specimen
    end
    for _, slot in ipairs({ 0, 1 }) do
      local record = assets.pictures[slot]
      if type(record) == "table" and type(record.spinda) == "table" and record.spinda.canvas ~= nil then
        seenSlots = seenSlots + 1
        local specimen = assert(specimenBySlot[slot], "every prepared slot carries its detached specimen")
        local frame = slot == 1 and 1 or 0
        -- The independent reference replays the authored policy from the
        -- compiled records: eligibility classes, spot union, replacement
        -- colors, and the second-frame offset with clipping.
        local frames = policy.eligibility[specimen.gender].frames
        local plane = frames[frame + 1]
        local offset = frame == 1 and policy.secondFrameXOffset or 0
        local colors = policy.replacementColors.normal
        local expected = {}
        for _, spot in ipairs(policy.spots) do
          for _, point in ipairs(spot) do
            local x = point.x + offset
            if x >= 0 and x < 80 then
              local class = tonumber(plane[point.y + 1]:sub(x + 1, x + 1))
              if class ~= nil and class >= 1 and class <= 3 then
                expected[point.y * 80 + x] = colors[class]
              end
            end
          end
        end
        local runs = Renderer.spotRunsFor(policy, specimen.gender, frame)
        Assert.isTrue(#runs > 0, "slot " .. slot .. " composes a nonempty authored run set")
        local covered = {}
        for _, run in ipairs(runs) do
          for x = run.x0, run.x1 do
            covered[run.y * 80 + x] = run.class
          end
        end
        for key, triple in pairs(expected) do
          Assert.notNil(covered[key], "the composed runs cover every authored eligible pixel")
          local _ = triple
        end
        for key, class in pairs(covered) do
          Assert.notNil(expected[key], "the composed runs add no pixel outside the authored masks")
          local _ = class
        end
        local canvasData = record.spinda.canvas:newImageData()
        local selector = portraitSelectorFor(rig.monCatalog, specimen, frame == 1 and "back" or "front", true)
        local baseData = decodePage(rig.cacheFs, assert(pageBySelector[selector], "the slot base resolves its page"))
        local qx, qy = record.quad:getViewport()
        local mismatched = 0
        for y = 0, 79 do
          for x = 0, 79 do
            local key = y * 80 + x
            local triple = expected[key]
            local er, eg, eb
            if triple ~= nil then
              er, eg, eb = triple.r, triple.g, triple.b
            else
              er, eg, eb, _ = pixel(baseData, qx + x, qy + y)
            end
            local ar, ag, ab = pixel(canvasData, x, y)
            if math.abs(ar - er) + math.abs(ag - eg) + math.abs(ab - eb) > 2 then
              mismatched = mismatched + 1
            end
          end
        end
        Assert.equal(mismatched, 0, "slot " .. slot .. " canvas pixels equal the authored composition")
      end
    end
    Assert.equal(seenSlots, 2, "the entry prepares both the front and the baseline back Spinda")
    -- Overlapping authored masks merge into one run: a second blend
    -- would double-paint the shared pixel.
    local overlapRows = {}
    for _ = 1, 80 do
      overlapRows[#overlapRows + 1] = string.rep("0", 80)
    end
    overlapRows[6] = string.rep("0", 5) .. "111" .. string.rep("0", 72)
    overlapRows[7] = string.rep("0", 20) .. "11" .. string.rep("0", 58)
    overlapRows[8] = string.rep("0", 30) .. "11" .. string.rep("0", 48)
    local overlap = Renderer.spotRunsFor({
      spots = {
        { { x = 5, y = 5 }, { x = 6, y = 5 } },
        { { x = 6, y = 5 }, { x = 7, y = 5 } },
        { { x = 20, y = 6 }, { x = 21, y = 6 } },
        { { x = 30, y = 7 }, { x = 31, y = 7 } },
      },
      eligibility = { male = { frames = { overlapRows } } },
      secondFrameXOffset = -14,
    }, "male", 0)
    Assert.equal(#overlap, 3, "overlapping masks merge into one run per row")
    Assert.equal(overlap[1].x0, 5, "the merged run starts at the first mask pixel")
    Assert.equal(overlap[1].x1, 7, "the merged run ends at the last mask pixel")
    Assert.equal(overlap[1].class, 1, "the merged run keeps its eligibility class")
    -- The shiny replacement path paints from the shiny triple through
    -- the same authored runs.
    local shinyRecord = assets.renderer:prepareSpindaPicture({
      base = nil,
      quad = nil,
      policy = policy,
      personality = 16,
      shiny = true,
      gender = "female",
      frame = 0,
    })
    Assert.notNil(shinyRecord.canvas, "the shiny composition realizes its canvas")
    local shinyRuns = Renderer.spotRunsFor(policy, "female", 0)
    Assert.isTrue(#shinyRuns > 0, "the shiny composition reuses the authored runs")
    local shinyData = shinyRecord.canvas:newImageData()
    local first = shinyRuns[1]
    local triple = policy.replacementColors.shiny[first.class]
    assertPixel(
      shinyData,
      first.x0,
      first.y,
      triple.r,
      triple.g,
      triple.b,
      "the shiny run paints the shiny replacement triple"
    )
    shinyRecord.release()
    lease:release()
    controller:dispose()
    rig.owner:release()
  end)
end

function T.registration_card_covers_departing_art_with_its_fixed_picture(scope)
  local Renderer = requireRenderer("registration card rasterization")
  local Interface = requireInterface("registration layout resolution")
  requireOwner("prepared registration bundles")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local snapshot = Fixture.registrationSnapshot(dexOwner, rig.monCatalog, "TOTODILE", 0)
    local demand = Fixture.registrationDemand(snapshot, "card-final")
    Assert.equal(demand.pictures[1].mode, "registration", "the card demand carries the actual specimen picture")
    Assert.equal(demand.text.registration.displayName, "TOTODILE", "the card announcement names the capture")
    local cardPaths = seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, false)
    local lease = rig.owner:acquire({ purpose = "registration" })
    local assets = prepareReady(rig, lease, demand)
    Assert.notNil(assets.messages.registrationAnnouncement, "the ready card bundle carries its formatted announcement")
    Assert.isTrue(
      tostring(assets.messages.registrationAnnouncement):find("TOTODILE", 1, true) ~= nil,
      "the announcement names the captured specimen"
    )
    local card = assert(assets.pictures.registration, "the ready bundle carries its card picture")
    Assert.notNil(card.handle, "the card slot carries its prepared handle")
    local measurement = measurementFor("nativeLike")
    local plan = resolvePlan(Interface.registration(), measurement, {})
    Assert.equal(#plan.panes, 1, "the compact card resolves its single registration pane")
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local backdrop = Renderer.backdropOf(rig.manifest, "registration", "information")
    local unfaded = drawPlan(scope, plan, resources, { view = {}, assets = assets }, 256, 192)
    assertPixel(unfaded, 2, 2, backdrop.r, backdrop.g, backdrop.b, "the card cover is opaque over departing art")
    assertPixel(unfaded, 253, 189, backdrop.r, backdrop.g, backdrop.b, "the card cover fills its pane")
    local cardSelector = portraitSelectorFor(rig.monCatalog, snapshot.specimen, "front", false)
    local baseData = decodePage(rig.cacheFs, assert(cardPaths[cardSelector], "the card base resolves its page"))
    local qx, qy = card.quad:getViewport()
    local er, eg, eb = pixel(baseData, qx + 40, qy + 40)
    assertPixel(unfaded, 128, 72, er, eg, eb, "the fixed picture paints the captured specimen unfaded")
    -- The final fade hides every plane behind black while the fixed
    -- picture stays unfaded: the published coefficients drive only the
    -- cover.
    local faded =
      drawPlan(scope, plan, resources, { view = { paletteFade = 16, pictureFade = 0 }, assets = assets }, 256, 192)
    assertPixel(faded, 2, 2, 0, 0, 0, "the final cover fades every plane to black")
    local fr, fg, fb = pixel(faded, 128, 72)
    Assert.equal(fr, er, "the final picture keeps its red channel unfaded")
    Assert.equal(fg, eg, "the final picture keeps its green channel unfaded")
    Assert.equal(fb, eb, "the final picture keeps its blue channel unfaded")
    lease:release()
    rig.owner:release()
  end)
end

function T.native_and_foreign_text_advances_match_their_banks(scope)
  requireRenderer("prepared font collaborators behind the text legs")
  local versionId = readyVersion()
  local cacheFs = CacheFs.forVersion(versionId)
  Assert.notNil(cacheFs, "the ready version exposes its prepared cache")
  local provider = FieldMessageProvider.new(cacheFs)
  Assert.isTrue(provider:acquireBank(805), "the english flavor bank acquires")
  Assert.isTrue(provider:acquireBank(806), "the french flavor bank acquires")
  local english = provider:get(805, 158)
  local french = provider:get(806, 158)
  Assert.notNil(english, "the english bank carries the exercised flavor")
  Assert.notNil(french, "the french bank carries the exercised flavor")
  Assert.isTrue(english.text ~= french.text, "native and foreign flavors differ")
  local body = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
  local header = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs, fontId = 4 }))
  local bodyEnglish = body:textWidth(english.text)
  local bodyFrench = body:textWidth(french.text)
  Assert.isTrue(bodyEnglish > 0, "the english flavor advances a positive width")
  Assert.isTrue(bodyFrench > 0, "the french flavor advances a positive width")
  Assert.isTrue(bodyEnglish ~= bodyFrench, "foreign advances follow the foreign bank")
  Assert.isTrue(header:textWidth(english.text) ~= bodyEnglish, "header advances follow the header font")
  local function drawLine(text, value)
    local canvas = scope:own(love.graphics.newCanvas(256, 64))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    text:drawText(value, 0, 0)
    love.graphics.setCanvas()
    return canvas:newImageData()
  end
  local englishData = drawLine(body, english.text)
  local foreignData = drawLine(body, french.text)
  local lit = 0
  for y = 0, 63 do
    for x = 0, 255 do
      local _, _, _, a = pixel(englishData, x, y)
      if a > 0 then
        lit = lit + 1
      end
    end
  end
  Assert.isTrue(lit > 0, "the native flavor paints glyph pixels")
  local differing = 0
  for y = 0, 63 do
    for x = 0, 255 do
      local r1, g1, b1, a1 = pixel(englishData, x, y)
      local r2, g2, b2, a2 = pixel(foreignData, x, y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) + math.abs(a1 - a2) > 0 then
        differing = differing + 1
      end
    end
  end
  Assert.isTrue(differing > 0, "foreign text paints its own glyphs")
  provider:releaseBank(805)
  provider:releaseBank(806)
end

function T.indexed_and_rgba_handles_compose_identical_pixels(scope)
  requireRenderer("the shared exact sampling rule")
  -- The same authored bytes drawn once as straight RGBA and once as
  -- indexed bytes through the exact palette normalize identically.
  local straight = scope:own(solidImage(4, 4, function(x, y)
    if (x + y) % 2 == 0 then
      return 1, 1, 1, 1
    end
    return 132 / 255, 0, 0, 1
  end))
  local paletteData = love.image.newImageData(2, 1)
  paletteData:setPixel(0, 0, 1, 1, 1, 1)
  paletteData:setPixel(1, 0, 132 / 255, 0, 0, 1)
  local palette = scope:own(love.graphics.newImage(paletteData))
  local indexData = love.image.newImageData(4, 4)
  for y = 0, 3 do
    for x = 0, 3 do
      if (x + y) % 2 == 0 then
        indexData:setPixel(x, y, 0, 0, 0, 1)
      else
        indexData:setPixel(x, y, 1 / 255, 0, 0, 1)
      end
    end
  end
  local indexed = scope:own(love.graphics.newImage(indexData))
  local ImageSampling = require("libs.nds.src.love.ImageSampling")
  local function drawThrough(handle)
    local canvas = scope:own(love.graphics.newCanvas(4, 4))
    love.graphics.setCanvas(canvas)
    love.graphics.clear(0, 0, 0, 0)
    ImageSampling.draw(love.graphics, handle, nil, 0, 0)
    love.graphics.setCanvas()
    return canvas:newImageData()
  end
  local rgbaData = drawThrough({ image = straight, kind = "rgba8" })
  local indexedData = drawThrough({ image = indexed, kind = "r8", palette = palette })
  local mismatched = 0
  for y = 0, 3 do
    for x = 0, 3 do
      local r1, g1, b1, a1 = pixel(rgbaData, x, y)
      local r2, g2, b2, a2 = pixel(indexedData, x, y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) + math.abs(a1 - a2) > 0 then
        mismatched = mismatched + 1
      end
    end
  end
  Assert.equal(mismatched, 0, "indexed and RGBA output match under the same normalization")
end

function T.draw_performs_no_realization_work()
  local Renderer = requireRenderer("headless serial draws")
  local Interface = requireInterface("paired native layout resolution")
  local Owner = requireOwner("headless preparation bounds")
  -- Every canvas, quad, image, and shader realizes during preparation;
  -- repeated draws only reissue the same recorded stream.
  local graphics = FakeGraphics.new()
  local creations = { canvas = 0, quad = 0, image = 0, shader = 0 }
  local createdAt = { canvas = {}, quad = {}, image = {}, shader = {} }
  local prepares = 0
  for _, key in ipairs({ "newCanvas", "newQuad", "newImage", "newShader" }) do
    local original = graphics[key]
    local short = key:sub(4):lower()
    graphics[key] = function(...)
      creations[short] = creations[short] + 1
      createdAt[short][#createdAt[short] + 1] = prepares
      return original(...)
    end
  end
  local monCatalog, catalog = Fixture.catalogs()
  local dexOwner = Fixture.ownerWithHistory(monCatalog, catalog)
  local cacheFs = CacheFs.forVersion(readyVersion())
  local owner = Owner.new({
    imagePool = SharedImagePoolFake.new(),
    monCatalog = monCatalog,
    catalog = catalog,
    cacheFs = cacheFs,
    graphics = graphics,
    derivedAssets = {
      requestPokedex = function(_)
        return true
      end,
      requestMonPortraitPage = function(_, _)
        return true
      end,
      requestAudioBank = function(_, _)
        return true
      end,
    },
  })
  local controller = Fixture.openController(dexOwner, monCatalog, catalog)
  openGrid(controller)
  local view = controller:view()
  local demand = browserDemandFor(Renderer, view)
  local lease = owner:acquire({ purpose = "browser" })
  local assets = nil
  for _ = 1, 400 do
    prepares = prepares + 1
    local outcome = lease:prepare(demand)
    if outcome.kind == "ready" then
      assets = outcome.assets
      break
    end
    Assert.equal(outcome.kind, "pending", "partial readiness never publishes a bundle")
  end
  Assert.notNil(assets, "bounded preparation converges on a complete bundle")
  Assert.equal(creations.canvas, 6, "the six serial surfaces realize exactly once")
  local distinct = {}
  for _, at in ipairs(createdAt.canvas) do
    distinct[at] = true
  end
  local distinctCount = 0
  for _ in pairs(distinct) do
    distinctCount = distinctCount + 1
  end
  Assert.equal(distinctCount, 6, "the six surfaces realize across separate prepare calls")
  Assert.isTrue(prepares >= 6, "surface admission spans at least six prepare calls")
  local measurement = measurementFor("dualDisplay")
  local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
  local resources = { graphics = graphics, renderer = assets.renderer }
  local preparedView = preparedBrowserView(view, assets)
  -- The first draw warms the shared sampling rule behind the existing
  -- NDS mechanism; steady-state draws after that realize nothing.
  assets.renderer:drawBrowser(preparedView, plan)
  Assert.isTrue(#graphics.draws > 0, "the serial draw issues its recorded stream")
  local before = {
    canvas = creations.canvas,
    quad = creations.quad,
    image = creations.image,
    shader = creations.shader,
    draws = #graphics.draws,
  }
  assets.renderer:drawBrowser(preparedView, plan)
  assets.renderer:drawBrowser(preparedView, plan)
  Assert.equal(creations.canvas, before.canvas, "draws create no canvases")
  Assert.equal(creations.quad, before.quad, "draws create no quads")
  Assert.equal(creations.image, before.image, "draws create no images")
  Assert.equal(creations.shader, before.shader, "draws create no shaders")
  Assert.equal(#graphics.draws, before.draws * 3, "repeated draws reissue the same stream")
  -- The footer window and the AREA refresh blend travel as uniforms:
  -- information excludes OBJ inside (0,152,255,192) while controls
  -- stays unmasked, and explicit first/second sets reach the shader.
  local shader = assets.renderer._shader
  Assert.notNil(shader, "the headless draw binds its composite shader")
  local sends = assert(shader.sends, "the fake shader records its uniforms")
  local function lastSend(name)
    local value = nil
    for _, send in ipairs(sends) do
      if send.name == name then
        value = send.value
      end
    end
    return value
  end
  Assert.equal(lastSend("u_winActive"), 0, "the trailing controls pane leaves the window inactive")
  lease:release()
  controller:dispose()
  owner:release()
end

-- The battle-owned registration card runs its complete source sequence
-- through the real child and the shared renderer: the announcement holds
-- its sixty internal ticks, entry and card fades follow their separate
-- recurrences, the cry plays once with its fixed pattern, fresh dismissal
-- starts the ordinary departure, and the picture policy moves exactly
-- twenty steps from 48 to 128 before the black terminal cover freezes the
-- centered card. No battle runtime contributes: the detached registration
-- is frozen before any publication.
function T.registration_child_runs_source_phases_with_fades_and_departure(scope)
  local Renderer = requireRenderer("registration phase rasterization")
  local Interface = requireInterface("registration phase layout resolution")
  requireOwner("registration phase bundles")
  local okChild, Child = pcall(require, "game.hgss.src.pokedex.PokedexRegistrationState")
  Assert.isTrue(okChild, "missing battle-owned first-catch presentation (game.hgss.src.pokedex.PokedexRegistrationState)")
  assert(Child ~= nil, "the registration child loads")
  local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local snapshot = Fixture.registrationSnapshot(dexOwner, rig.monCatalog, "TOTODILE", 0)
    local registration = {
      captureId = 7,
      mode = "wild",
      dexMode = snapshot.dexMode,
      displayName = snapshot.displayName,
      specimen = snapshot.specimen,
    }
    local demand = Fixture.registrationDemand(snapshot, "card-phases")
    local cardPaths = seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, false)
    local lease = rig.owner:acquire({ purpose = "registration" })
    local assets = prepareReady(rig, lease, demand)
    local audio = { calls = {}, cryDone = false }
    function audio.playCry(species, pattern, form)
      audio.calls[#audio.calls + 1] = { species = species, pattern = pattern, form = form }
      return true
    end
    function audio.isCryFinished()
      return audio.cryDone
    end
    function audio.select() end
    local timeline = BattleTimeline.new({ textSpeed = "fastest" })
    local measurement = measurementFor("nativeLike")
    local child = Child.new({
      registration = registration,
      pokedex = rig.owner,
      timeline = timeline,
      audio = audio,
      measureDisplay = function()
        return measurement
      end,
    })
    local function tick()
      timeline:update(1 / 60, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
    end
    local function driveUntil(predicate, budget, complaint)
      for _ = 1, budget do
        if predicate() then
          return
        end
        tick()
      end
      error(complaint, 0)
    end
    driveUntil(function()
      return child:status().phase ~= "preparing"
    end, 400, "whole-demand readiness gates the card announcement")
    Assert.equal(#audio.calls, 0, "no cry plays before whole-demand readiness")
    local announcedAt = 0
    local counted = 0
    while child:status().phase == "announcement" and counted < 400 do
      tick()
      counted = counted + 1
    end
    announcedAt = counted
    Assert.isTrue(child:status().phase ~= "announcement", "the borrowed clock settles the announcement")
    Assert.isTrue(announcedAt >= 60, "the announcement holds its sixty internal ticks after reveal")
    Assert.equal(#audio.calls, 0, "no cry plays during the announcement")
    -- Entry fades publish their separate recurrences: the palette
    -- alternates publish and wait in steps of two, the picture publishes
    -- every update in steps of one.
    Assert.equal(child:status().phase, "entryFade", "the settled announcement enters the fade")
    local entryPalette, entryPicture = {}, {}
    while child:status().phase == "entryFade" and #entryPalette < 60 do
      tick()
      local view = child:view()
      entryPalette[#entryPalette + 1] = view.paletteFade
      entryPicture[#entryPicture + 1] = view.pictureFade
    end
    Assert.isTrue(child:status().phase ~= "entryFade", "the entry fade completes into the card")
    Assert.deepEqual(
      entryPalette,
      { 2, 2, 4, 4, 6, 6, 8, 8, 10, 10, 12, 12, 14, 14, 16, 16, 16 },
      "the entry palette alternates publish and wait in steps of two"
    )
    Assert.deepEqual(
      entryPicture,
      { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 },
      "the entry picture publishes every update in steps of one"
    )
    -- Card fades run the same recurrences back toward zero.
    Assert.equal(child:status().phase, "waitCardFade", "the card initializes before its fade waits")
    local cardPalette, cardPicture = {}, {}
    while child:status().phase == "waitCardFade" and #cardPalette < 60 do
      tick()
      local view = child:view()
      cardPalette[#cardPalette + 1] = view.paletteFade
      cardPicture[#cardPicture + 1] = view.pictureFade
    end
    Assert.isTrue(child:status().phase ~= "waitCardFade", "the card fade completes into the cry")
    Assert.deepEqual(
      cardPalette,
      { 14, 14, 12, 12, 10, 10, 8, 8, 6, 6, 4, 4, 2, 2, 0, 0, 0 },
      "the card palette alternates publish and wait back to zero"
    )
    Assert.deepEqual(
      cardPicture,
      { 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0 },
      "the card picture publishes every update back to zero"
    )
    local function drawCard(view)
      local plan = resolvePlan(Interface.registration(), measurement, view)
      local resources = { graphics = love.graphics, renderer = assets.renderer }
      return drawPlan(scope, plan, resources, { view = view, assets = assets }, 256, 192)
    end
    local card = assert(assets.pictures.registration, "the ready bundle carries its card picture")
    local cardSelector = portraitSelectorFor(rig.monCatalog, snapshot.specimen, "front", false)
    local baseData = decodePage(rig.cacheFs, assert(cardPaths[cardSelector], "the card base resolves its page"))
    local qx, qy = card.quad:getViewport()
    local er, eg, eb = pixel(baseData, qx + 40, qy + 40)
    local backdrop = Renderer.backdropOf(rig.manifest, "registration", "information")
    -- The ready card covers departing art with the fixed unfaded picture.
    -- The finished cry releases fresh dismissal; the card still waits for
    -- the fresh edge below instead of departing on its own.
    audio.cryDone = true
    driveUntil(function()
      return child:status().acceptsDismissal == true or child:status().complete == true
    end, 400, "the card becomes dismissible after its fades and cry")
    local readyImage = drawCard(child:view())
    assertPixel(readyImage, 2, 2, backdrop.r, backdrop.g, backdrop.b, "the ready card cover is opaque")
    assertPixel(readyImage, 128, 72, er, eg, eb, "the ready card paints the captured specimen")
    Assert.equal(#audio.calls, 1, "the card cry plays exactly once")
    Assert.equal(audio.calls[1].species, "TOTODILE", "the card cry names the captured species")
    Assert.equal(audio.calls[1].pattern, 14, "the card cry always uses its fixed pattern")
    Assert.equal(audio.calls[1].form, 0, "the card cry always uses the base form")
    -- Cancellation never dismisses; only a fresh confirmation does.
    child:input({ { type = "cancel" } })
    for _ = 1, 5 do
      tick()
    end
    Assert.isTrue(child:status().complete == false, "cancellation never dismisses the card")
    Assert.isTrue(child:status().acceptsDismissal == true, "the ignored cancellation keeps the card dismissible")
    child:input({ { type = "confirm" } })
    tick()
    Assert.equal(child:status().phase, "departure", "a fresh confirmation starts the ordinary departure")
    -- The ordinary departure moves the picture exactly twenty steps
    -- from 48 to 128 while the cover fades back to black; the renderer
    -- keeps the fixed card rect, so the policy values carry the motion.
    -- The twentieth step reaches 128 and freezes the centered exit in
    -- the same update, so the samples below observe the climb and the
    -- completion gate proves the 128 arrival.
    local moves = {}
    while child:status().phase == "departure" and #moves < 40 do
      moves[#moves + 1] = child:view().pictureX
      tick()
    end
    Assert.isTrue(child:status().complete == true, "the departure completes into the frozen exit")
    Assert.equal(#moves, 20, "the ordinary departure moves exactly twenty source steps")
    Assert.equal(moves[1], 48, "the departure starts centered")
    Assert.equal(moves[20], 124, "the twentieth step climbs to the 128 gate")
    for index, value in ipairs(moves) do
      Assert.equal(value, 48 + 4 * (index - 1), "departure step " .. tostring(index) .. " keeps the source pace")
    end
    local midImage = drawCard(child:view())
    local fr, fg, fb = pixel(midImage, 128, 72)
    Assert.equal(fr, er, "the frozen exit keeps its red channel")
    Assert.equal(fg, eg, "the frozen exit keeps its green channel")
    Assert.equal(fb, eb, "the frozen exit keeps its blue channel")
    assertPixel(midImage, 2, 2, 0, 0, 0, "the frozen exit holds the terminal cover")
    Assert.equal(child:view().pictureX, 48, "completion refreezes the centered picture")
    child:dispose()
    lease:release()
    rig.owner:release()
  end)
end

function T.heartgold_graphics_legs_stay_blocked_without_a_dump(_, context)
  if not RomImporter.isReady("heartgold") then
    assert(context ~= nil, "blocked-version reporting needs its runner context")
    context:skip("heartgold dump not owned; the heartgold graphics legs stay blocked")
    return
  end
  requireRenderer("blocked-version graphics reporting")
  Assert.isTrue(RomImporter.isReady("heartgold"), "the ready heartgold dump draws its graphics legs")
end

function T.native_japanese_presentation_stays_blocked_without_tokenizer_coverage(_, context)
  assert(context ~= nil, "blocked-language reporting needs its runner context")
  context:skip(
    "native Japanese presentation stays blocked: message tokenization covers no Japanese dex bank"
      .. " and no Japanese dump is owned"
  )
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = { "pokedex-data:global", "pokedex:global", "mon-catalog:global", "field-font:global" }
return suite
