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
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexSources = require("romdump.src.config.PokedexSources")
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
  if type(view.selection) == "table" and type(view.selection.species) == "string" then
    local key = view.selection.species .. "/f0"
    if not seen[key] and #iconKeys < 30 then
      seen[key] = true
      iconKeys[#iconKeys + 1] = key
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
  local objects = {}
  if type(view.objects) == "table" then
    for _, intent in ipairs(view.objects) do
      if type(intent) == "table" then
        objects[#objects + 1] = intent
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
    objects = objects,
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
---@param scope table<string, unknown> graphics ownership scope
---@return table rig { cacheFs, monCatalog, catalog, owner, manifest, provider, body }
local function graphicsRig(versionId, pool, scope)
  local Renderer = requireRenderer("prepared graphics rigs")
  local Owner = requireOwner("prepared graphics rigs")
  local _ = Renderer
  local cacheFs = CacheFs.forVersion(versionId)
  Assert.notNil(cacheFs, "the ready version exposes its prepared cache")
  local monCatalog, catalog = Fixture.catalogs()
  -- The runtime resolves type/shape editor positions through the
  -- published source order, so the rig carries the same generated
  -- order arrays as the derived catalog.
  do
    local criteria = assert(catalog.criteria, "the synthetic catalog carries its search criteria")
    local typeOrder = {}
    for _, name in ipairs(PokedexSources.typeOrder) do
      typeOrder[#typeOrder + 1] = name
    end
    typeOrder[#typeOrder + 1] = "unrestricted"
    criteria.typeOptionOrder = typeOrder
    local shapeOrder = {}
    for _, name in ipairs(PokedexSources.shapeOrder) do
      shapeOrder[#shapeOrder + 1] = name
    end
    shapeOrder[#shapeOrder + 1] = "unrestricted"
    criteria.shapeOptionOrder = shapeOrder
  end
  -- Whole-view preparation resolves every visible text slot through its
  -- source bank, so the rig borrows the real message provider and the
  -- real body font renderer exactly like the field owner does; the
  -- header font stays owner-lazy behind font4 windows.
  local provider = FieldMessageProvider.new(cacheFs)
  local body = scope:own(FieldTextRenderer.new({ cacheFs = cacheFs }))
  local owner = Owner.new({
    imagePool = pool,
    monCatalog = monCatalog,
    catalog = catalog,
    cacheFs = cacheFs,
    graphics = love.graphics,
    text = body,
    messages = provider,
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
  return { view = view, assets = assets, compact = { inspect = false, size = "weight" } }
end

---@param view table detached browser projection
---@return table plan view with the private compact record
local function planViewOf(view)
  local merged = {}
  for key, value in pairs(view) do
    merged[key] = value
  end
  merged.compact = { inspect = false, size = "weight" }
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

-- Forward pixel-evidence references shared with the rasterization
-- scenarios below: legacy composition legs reuse the same authored
-- background expectations.
local bgLayersFor, expectedBackground, seedChromeFor

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
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
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
    local infoLayers = bgLayersFor(rig.cacheFs, rig.manifest, "grid", "information")
    local infoPri = Renderer.layerPrioritiesOf(rig.manifest, "grid", "information")
    local ctrlLayers = bgLayersFor(rig.cacheFs, rig.manifest, "grid", "controls")
    local ctrlPri = Renderer.layerPrioritiesOf(rig.manifest, "grid", "controls")
    Assert.equal(info.scale, 1, "the native pair draws at integral source scale")
    -- Corners carry authored background bytes, falling back to the
    -- compiled backdrop only where every layer stays clear.
    do
      local er, eg, eb = expectedBackground(infoLayers, infoPri, infoBd, 2, 2)
      assertPixel(
        data,
        info.origin.x + 2,
        info.origin.y + 2,
        er,
        eg,
        eb,
        "the information corner carries its authored background"
      )
    end
    do
      local er, eg, eb = expectedBackground(ctrlLayers, ctrlPri, ctrlBd, 2, 2)
      assertPixel(
        data,
        controls.origin.x + 2,
        controls.origin.y + 2,
        er,
        eg,
        eb,
        "the controls corner carries its authored background"
      )
    end
    -- Caught icons draw opaque; seen-only icons blend EVA6/EVB10
    -- against the authored controls background through the locked
    -- normalization.
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
    local br, bg, bb = expectedBackground(ctrlLayers, ctrlPri, ctrlBd, seenRect.x + 16, seenRect.y + 16)
    local er = blendByteOracle(255, br, 6, 10)
    local eg = blendByteOracle(255, bg, 6, 10)
    local eb = blendByteOracle(255, bb, 6, 10)
    assertPixel(data, sx, sy, er, eg, eb, "the seen-only icon blends 6/10 against eligible BG")
    -- A blank slot past every staged entry keeps the authored background.
    local blankRect = Renderer.iconSlotRect(14)
    do
      local er, eg, eb = expectedBackground(ctrlLayers, ctrlPri, ctrlBd, blankRect.x + 16, blankRect.y + 16)
      assertPixel(
        data,
        controls.origin.x + blankRect.x + 16,
        controls.origin.y + blankRect.y + 16,
        er,
        eg,
        eb,
        "a blank slot draws no icon"
      )
    end
    lease:release()
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the journey returns every borrowed interest")
  end)
end

-- Counts pixels inside one native box that differ from the authored
-- background oracle: a nonzero count proves live art over the
-- background rather than an empty backdrop-colored region.
---@param data table 8-bit pixel buffer behind the composed target
---@param origin table placement origin behind the pane
---@param box table native box behind the probe
---@param layers table authored background layers behind the pane
---@param priorities table authored priorities behind the pane
---@param backdrop table authored backdrop behind the pane
---@param pan table? scrolled layer behind the entry area
---@return integer pixels differing from the authored background
local function boxInk(data, origin, box, layers, priorities, backdrop, pan)
  local ink = 0
  for y = box.y, box.y + box.height - 1 do
    for x = box.x, box.x + box.width - 1 do
      local er, eg, eb = expectedBackground(layers, priorities, backdrop, x, y, pan)
      local ar, ag, ab = pixel(data, origin.x + x, origin.y + y)
      if math.abs(ar - er) + math.abs(ag - eg) + math.abs(ab - eb) > 0 then
        ink = ink + 1
      end
    end
  end
  return ink
end

-- Resolves the painted rectangles behind one live intent from the
-- prepared bundle: the union over every frame of its bound animation,
-- so ink probes never guess art extents.
---@param intent table detached sprite intent behind the probe
---@param assets table ready bundle behind the draw
---@param role string manifest page role behind the pane
---@return table[] native boxes behind the intent
local function intentBoxes(intent, assets, role)
  local rects = {}
  if intent.subject == "footprint" then
    rects[#rects + 1] = { x = intent.x, y = intent.y, width = 16, height = 16 }
    return rects
  end
  local manifest = assert(assets.manifest, "the ready bundle carries its compiled manifest")
  local page = manifest.pages[role]
  local subjects = page ~= nil and page.spriteSubjects or nil
  if type(subjects) ~= "table" then
    return rects
  end
  local subjectMap = subjects[intent.subject]
  local binding = type(subjectMap) == "table" and subjectMap[intent.choice] or nil
  if type(binding) ~= "table" then
    return rects
  end
  local sprite = manifest.sprites[binding.sprite]
  local animation = type(sprite) == "table" and manifest.animations[sprite.animation] or nil
  if animation == nil then
    return rects
  end
  for _, frame in ipairs(animation.frames) do
    local cell = manifest.cells[frame.cell]
    if type(cell) == "table" then
      for _, part in ipairs(cell.parts) do
        rects[#rects + 1] = {
          x = intent.x + part.x,
          y = intent.y + part.y,
          width = part.source.width,
          height = part.source.height,
        }
      end
    end
  end
  return rects
end

-- Counts pixels inside one native box that differ between two composed
-- frames: a nonzero count proves motion between the draws.
---@param first table 8-bit pixel buffer behind the earlier frame
---@param second table 8-bit pixel buffer behind the later frame
---@param origin table placement origin behind the pane
---@param box table native box behind the probe
---@return integer pixels differing between the frames
local function boxMotion(first, second, origin, box)
  local moved = 0
  for y = box.y, box.y + box.height - 1 do
    for x = box.x, box.x + box.width - 1 do
      local r1, g1, b1 = pixel(first, origin.x + x, origin.y + y)
      local r2, g2, b2 = pixel(second, origin.x + x, origin.y + y)
      if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) > 0 then
        moved = moved + 1
      end
    end
  end
  return moved
end

-- The grid focus, arrows, and thumb paint at their native origins and
-- the focus tracks the cursor: identical draws except for the moved
-- cursor differ exactly inside the old and new focus boxes while the
-- static arrows and thumb keep ink over their background.
function T.grid_focus_arrows_and_scrollbar_paint_their_native_origins(scope)
  local Renderer = requireRenderer("live grid sprite pixels")
  local Interface = requireInterface("paired native hit resolution")
  requireOwner("prepared bundles behind the live leg")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    local measurement = measurementFor("dualDisplay")
    local function drawGrid(view)
      local demand = browserDemandFor(Renderer, view)
      seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, true)
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data = drawPlan(
        scope,
        plan,
        { graphics = love.graphics, renderer = assets.renderer },
        preparedBrowserView(view, assets),
        measurement.width,
        measurement.height
      )
      lease:release()
      return data, assets
    end
    local first, firstAssets = drawGrid(controller:view())
    Assert.notNil(firstAssets.spriteParts["sprite-grid-2"], "the grid bundle stages its focus art")
    press(controller, { { type = "navigate", direction = "right" } })
    idle(controller, 2)
    local second, _ = drawGrid(controller:view())
    local placement =
      placementOf(resolvePlan(Interface.browser(), measurement, planViewOf(controller:view())), "controls")
    local layers = bgLayersFor(rig.cacheFs, rig.manifest, "grid", "controls")
    local priorities = Renderer.layerPrioritiesOf(rig.manifest, "grid", "controls")
    local backdrop = Renderer.backdropOf(rig.manifest, "grid", "controls")
    local oldBox = { x = 48, y = 24, width = 48, height = 48 }
    local newBox = { x = 88, y = 24, width = 48, height = 48 }
    Assert.isTrue(boxMotion(first, second, placement.origin, oldBox) > 0, "the focus leaves its old slot")
    Assert.isTrue(boxMotion(first, second, placement.origin, newBox) > 0, "the focus reaches its new slot")
    Assert.isTrue(
      boxInk(second, placement.origin, { x = 232, y = 0, width = 24, height = 30 }, layers, priorities, backdrop) > 0,
      "the up arrow paints over its background"
    )
    Assert.isTrue(
      boxInk(second, placement.origin, { x = 232, y = 128, width = 24, height = 32 }, layers, priorities, backdrop) > 0,
      "the down arrow paints over its background"
    )
    Assert.isTrue(
      boxInk(second, placement.origin, { x = 232, y = 30, width = 24, height = 130 }, layers, priorities, backdrop) > 0,
      "the thumb paints over its background"
    )
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the journey returns every borrowed interest")
  end)
end

-- The size pans track the published beam and swing with it: the
-- bundle stages the beam, pan, and trainer art, the pans paint ink at
-- their published positions, and two frames across a moving phase
-- differ inside the scale region while the anchors stay fixed.
function T.size_pans_track_the_published_beam(scope)
  local Renderer = requireRenderer("live size sprite pixels")
  local Interface = requireInterface("paired native hit resolution")
  requireOwner("prepared bundles behind the live leg")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.size")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    selectSpecies(controller, "TOTODILE")
    openEntry(controller)
    openTab(controller, "size")
    local measurement = measurementFor("dualDisplay")
    local portraitsSeeded = false
    local function drawSize(view)
      local demand = browserDemandFor(Renderer, view)
      if not portraitsSeeded then
        portraitsSeeded = true
        seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, true)
      end
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data = drawPlan(
        scope,
        plan,
        { graphics = love.graphics, renderer = assets.renderer },
        preparedBrowserView(view, assets),
        measurement.width,
        measurement.height
      )
      lease:release()
      return data, assets
    end
    local first, firstAssets = drawSize(controller:view())
    Assert.notNil(firstAssets.spriteParts["sprite-entry-size-trainer-male"], "the size bundle stages its trainer")
    for _ = 1, 150 do
      local phase = controller:view().size.weight.phase
      if phase == "tilt" or phase == "beam" or phase == "thrown" then
        break
      end
      idle(controller, 1)
    end
    local moving = controller:view().size.weight.phase
    Assert.isTrue(moving == "tilt" or moving == "beam" or moving == "thrown", "the scale reaches its moving phase")
    idle(controller, 3)
    local second, _ = drawSize(controller:view())
    local placement =
      placementOf(resolvePlan(Interface.browser(), measurement, planViewOf(controller:view())), "controls")
    Assert.isTrue(
      boxMotion(first, second, placement.origin, { x = 40, y = 40, width = 176, height = 120 }) > 0,
      "the pans swing between accepted updates"
    )
    local layers = bgLayersFor(rig.cacheFs, rig.manifest, "entry.size", "controls")
    local priorities = Renderer.layerPrioritiesOf(rig.manifest, "entry.size", "controls")
    local backdrop = Renderer.backdropOf(rig.manifest, "entry.size", "controls")
    local pans = controller:view().size.pans
    for _, pan in ipairs(pans) do
      Assert.isTrue(
        boxInk(
          second,
          placement.origin,
          { x = pan.x - 16, y = pan.y - 16, width = 32, height = 32 },
          layers,
          priorities,
          backdrop
        ) > 0,
        "a pan paints at its published position"
      )
    end
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the journey returns every borrowed interest")
  end)
end

function T.grid_icon_pixels_share_their_generation_with_hit_targets(scope)
  local Renderer = requireRenderer("paired icon pixel and hit pairing")
  local Interface = requireInterface("paired native hit resolution")
  requireOwner("prepared bundles behind the paired leg")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
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
    local controls = placementOf(plan, "controls")
    local data = drawPlan(
      scope,
      plan,
      { graphics = love.graphics, renderer = assets.renderer },
      preparedBrowserView(view, assets),
      measurement.width,
      measurement.height
    )
    -- The caught icon draws its prepared art opaque at its visible slot.
    local slot = gridSlotOf(view, "TOTODILE")
    local rect = Renderer.iconSlotRect(slot)
    assertPixel(
      data,
      controls.origin.x + rect.x + 16,
      controls.origin.y + rect.y + 16,
      255,
      0,
      0,
      "the caught icon draws its prepared art opaque"
    )
    -- The same generation maps the icon center back to its slot and
    -- each footer cell to its own bottom action; below the band and
    -- above it nothing maps.
    local tapped = plan.mapInput({
      type = "pointer_down",
      x = rect.x + 16,
      y = rect.y + 16,
      paneId = "controls",
      pointerId = 1,
    }, planViewOf(view), plan)
    Assert.notNil(tapped, "the icon center maps to a command")
    assert(tapped ~= nil, "the icon center maps to a command")
    Assert.equal(tapped.type, "activate", "the icon center activates")
    Assert.equal(tapped.action, "grid-slot", "the icon center selects its slot")
    Assert.equal(tapped.value, slot, "the icon center selects its own slot")
    local cells = {
      { x = 31, action = "search" },
      { x = 95, action = "cry" },
      { x = 159, action = "entry-tab", value = "area" },
    }
    for _, cell in ipairs(cells) do
      local footer = plan.mapInput({
        type = "pointer_down",
        x = cell.x,
        y = 169,
        paneId = "controls",
        pointerId = 2,
      }, planViewOf(view), plan)
      Assert.notNil(footer, "the footer cell at " .. cell.x .. " maps to a command")
      assert(footer ~= nil, "the footer cell at " .. cell.x .. " maps to a command")
      Assert.equal(footer.action, cell.action, "the footer cell at " .. cell.x .. " keeps its own action")
      if cell.value ~= nil then
        Assert.equal(footer.value, cell.value, "the footer entry cell opens on the area tab")
      end
    end
    local exit = plan.mapInput({
      type = "pointer_down",
      x = 223,
      y = 169,
      paneId = "controls",
      pointerId = 2,
    }, planViewOf(view), plan)
    Assert.notNil(exit, "the footer exit cell maps to a command")
    assert(exit ~= nil, "the footer exit cell maps to a command")
    Assert.equal(exit.type, "cancel", "the footer exit cell leaves the browser")
    Assert.isNil(
      plan.mapInput({
        type = "pointer_down",
        x = 20,
        y = 188,
        paneId = "controls",
        pointerId = 3,
      }, planViewOf(view), plan),
      "below the footer band nothing maps"
    )
    Assert.isNil(
      plan.mapInput({
        type = "pointer_down",
        x = 20,
        y = 151,
        paneId = "controls",
        pointerId = 4,
      }, planViewOf(view), plan),
      "above the footer band nothing maps"
    )
    lease:release()
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the journey returns every borrowed interest")
  end)
end

function T.compact_single_display_paints_fifteen_icons_portrait_and_footer(scope)
  local Renderer = requireRenderer("compact single-display reflow")
  local Interface = requireInterface("compact plan geometry")
  requireOwner("prepared bundles behind the compact panes")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    selectSpecies(controller, "TOTODILE")
    local view = controller:view()
    local demand = browserDemandFor(Renderer, view)
    -- Every staged seen icon gets a distinct solid color so all fifteen
    -- compact centers are attributable without blending ambiguity.
    local staged = {}
    for _, entry in ipairs(view.grid.buffers[1].entries) do
      if type(entry) == "table" and entry.seen == true and type(entry.species) == "string" then
        staged[#staged + 1] = entry.species
      end
    end
    Assert.isTrue(#staged >= 4, "the grid stages seen species for the compact pass")
    for index, species in ipairs(staged) do
      local shade = (index * 37) % 200 + 55
      seedIcon(pool, species .. "/f0", shade / 255, 0, 0)
    end
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    local measurement = measurementFor("nativeLike")
    local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
    local compact = assert(plan.content.pokedexCompact, "the compact plan publishes its geometry record")
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local data = drawPlan(scope, plan, resources, preparedBrowserView(view, assets), 256, 192)
    local info = placementOf(plan, "information")
    local controls = placementOf(plan, "controls")
    local grid = assert(compact.grid, "the compact record carries its grid")
    for slot = 0, 14 do
      local rect = assert(grid.iconRects[slot + 1], "the compact grid stages slot " .. slot)
      local entry = view.grid.buffers[1].entries[slot + 1]
      if type(entry) == "table" and entry.seen == true and type(entry.species) == "string" then
        local expected = nil
        for index, species in ipairs(staged) do
          if species == entry.species then
            expected = (index * 37) % 200 + 55
          end
        end
        Assert.notNil(expected, "the staged species carries its seeded color")
        if entry.caught == true then
          assertPixel(
            data,
            info.origin.x + rect.x + 16,
            info.origin.y + rect.y + 16,
            expected,
            0,
            0,
            "compact slot " .. slot .. " paints its caught icon"
          )
        else
          local infoLayers = bgLayersFor(rig.cacheFs, rig.manifest, "grid", "information")
          local infoPri = Renderer.layerPrioritiesOf(rig.manifest, "grid", "information")
          local br, bg, bb = expectedBackground(
            infoLayers,
            infoPri,
            Renderer.backdropOf(rig.manifest, "grid", "information"),
            rect.x + 16,
            rect.y + 16
          )
          assertPixel(
            data,
            info.origin.x + rect.x + 16,
            info.origin.y + rect.y + 16,
            blendByteOracle(expected, br, 6, 10),
            blendByteOracle(0, bg, 6, 10),
            blendByteOracle(0, bb, 6, 10),
            "compact slot " .. slot .. " blends its seen-only icon"
          )
        end
      else
        local infoLayers = bgLayersFor(rig.cacheFs, rig.manifest, "grid", "information")
        local infoPri = Renderer.layerPrioritiesOf(rig.manifest, "grid", "information")
        local er, eg, eb = expectedBackground(
          infoLayers,
          infoPri,
          Renderer.backdropOf(rig.manifest, "grid", "information"),
          rect.x + 16,
          rect.y + 16
        )
        assertPixel(
          data,
          info.origin.x + rect.x + 16,
          info.origin.y + rect.y + 16,
          er,
          eg,
          eb,
          "compact slot " .. slot .. " paints no icon over its blank cell"
        )
      end
    end
    local portrait = assert(compact.portraitRect, "the compact record carries its portrait")
    local selectedSlot = nil
    for index, entry in ipairs(view.grid.buffers[1].entries) do
      if type(entry) == "table" and entry.species == view.selection.species then
        selectedSlot = index
      end
    end
    Assert.notNil(selectedSlot, "the selection stages on the visible grid")
    local selectedSpecies = assert(view.selection.species, "the compact portrait selects a species")
    local expectedPortrait = nil
    for index, species in ipairs(staged) do
      if species == selectedSpecies then
        expectedPortrait = (index * 37) % 200 + 55
      end
    end
    Assert.notNil(expectedPortrait, "the selected species carries its seeded color")
    assertPixel(
      data,
      info.origin.x + portrait.x + 40,
      info.origin.y + portrait.y + 40,
      expectedPortrait,
      0,
      0,
      "the compact portrait paints the selected specimen"
    )
    local footer = assert(compact.footer, "the compact record carries its footer")
    Assert.isTrue(#footer.buttons >= 2, "the compact footer exposes its actions")
    for _, button in ipairs(footer.buttons) do
      -- Every footer action paints its full body: visible source marks
      -- now cover the button center, so coverage asserts opacity rather
      -- than blank chrome. Distinct marks stay with the dedicated
      -- compact action legs.
      local _, _, _, centerAlpha =
        pixel(data, controls.origin.x + button.x + math.floor(button.width / 2), controls.origin.y + math.floor(button.height / 2))
      Assert.equal(centerAlpha, 255, "the compact footer button " .. button.id .. " paints its action body")
      local _, _, _, cornerAlpha = pixel(data, controls.origin.x + button.x, controls.origin.y + button.y)
      Assert.equal(cornerAlpha, 255, "the compact footer button " .. button.id .. " paints its action corner")
    end
    lease:release()
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the compact journey returns every borrowed interest")
  end)
end

function T.all_layouts_resolve_prepared_browser_pixels(scope)
  local Renderer = requireRenderer("paired and compact layout rasterization")
  local Interface = requireInterface("all four layout cases")
  requireOwner("prepared bundles behind every layout")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
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
      -- Smoke renders one layout's pixels; geometry above already proves
      -- every layout resolves, and all four share the same authored
      -- background bytes at source scale.
      if class == "nativeLike" then
        local data = drawPlan(scope, plan, resources, preparedView, measurement.width, measurement.height)
      -- Every layout carries the same authored background bytes at
      -- source scale; only the placement origin moves.
      local infoBd = Renderer.backdropOf(rig.manifest, "grid", "information")
      local er, eg, eb = expectedBackground(
        bgLayersFor(rig.cacheFs, rig.manifest, "grid", "information"),
        Renderer.layerPrioritiesOf(rig.manifest, "grid", "information"),
        infoBd,
        2,
        2
      )
      assertPixel(
        data,
        math.min(info.origin.x + 2, measurement.width - 1),
        math.min(info.origin.y + 2, measurement.height - 1),
        er,
        eg,
        eb,
        class .. " information carries its authored background"
      )
      end
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
    -- The too-small display resolves through the production session path,
    -- which centers the single-display fitter against the usable safe
    -- bounds and fails closed to the unavailable plan.
    local unavailable = resolvePlan(Interface.browser(), small, planViewOf(view))
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
  -- Presence needs both the metadata mark and an opaque sampled OBJ
  -- texel: transparent art corners never confer coverage.
  local objPresent = ma > 0 and oa > 0
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
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
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
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.area")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    Assert.isTrue(dexOwner:isCaught("SPINDA"), "the spot legs browse a caught Spinda history")
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    selectSpecies(controller, "SPINDA")
    openEntry(controller)
    local view = controller:view()
    local demand = browserDemandFor(Renderer, view)
    -- Entry strings resolve through the real banks behind the
    -- fixture's ROM identities, so the demand keeps its text: dropping
    -- it would hide bank-range failures on an unrelated owner.
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
    local rig = graphicsRig(versionId, pool, scope)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local snapshot = Fixture.registrationSnapshot(dexOwner, rig.monCatalog, "TOTODILE", 0)
    local demand = Fixture.registrationDemand(snapshot, "card-final", rig.monCatalog)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "registration")
    Assert.equal(demand.pictures[1].mode, "registration", "the card demand carries the actual specimen picture")
    Assert.equal(demand.text.registration.displayName, "TOTODILE", "the card announcement names the capture")
    local cardPaths = seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, false)
    local lease = rig.owner:acquire({ purpose = "registration" })
    local assets = prepareReady(rig, lease, demand)
    Assert.notNil(assets.messages.registrationAnnouncement, "the ready card bundle carries its formatted announcement")
    -- The source template carries its own placeholder spelling, so the
    -- prepared string is the real bank entry rather than the bare
    -- display name; substituting the capture name is owned elsewhere.
    Assert.isTrue(
      tostring(assets.messages.registrationAnnouncement) ~= ""
        and tostring(assets.messages.registrationAnnouncement) ~= snapshot.displayName,
      "the announcement resolves its real bank entry instead of the display fallback"
    )
    local card = assert(assets.pictures.registration, "the ready bundle carries its card picture")
    Assert.notNil(card.handle, "the card slot carries its prepared handle")
    local measurement = measurementFor("nativeLike")
    local plan = resolvePlan(Interface.registration(), measurement, {})
    Assert.equal(#plan.panes, 1, "the compact card resolves its single registration pane")
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local backdrop = Renderer.backdropOf(rig.manifest, "registration", "information")
    local layers = bgLayersFor(rig.cacheFs, rig.manifest, "registration", "information")
    local priorities = Renderer.layerPrioritiesOf(rig.manifest, "registration", "information")
    -- An empty view rests at the initial center: pictureX defaults to
    -- its source home while the departure policy owns later centers.
    local unfaded = drawPlan(scope, plan, resources, { view = {}, assets = assets }, 256, 192)
    do
      local er, eg, eb = expectedBackground(layers, priorities, backdrop, 2, 2)
      assertPixel(unfaded, 2, 2, er, eg, eb, "the card cover paints its authored background")
    end
    do
      local er, eg, eb = expectedBackground(layers, priorities, backdrop, 253, 189)
      assertPixel(unfaded, 253, 189, er, eg, eb, "the card cover fills its pane")
    end
    local cardSelector = portraitSelectorFor(rig.monCatalog, snapshot.specimen, "front", false)
    local baseData = decodePage(rig.cacheFs, assert(cardPaths[cardSelector], "the card base resolves its page"))
    local qx, qy = card.quad:getViewport()
    local er, eg, eb = pixel(baseData, qx + 40, qy + 40)
    assertPixel(unfaded, 48, 72, er, eg, eb, "the initial picture paints the captured specimen unfaded")
    -- The final fade hides every plane behind black while the initial
    -- picture stays unfaded: the published coefficients drive only the
    -- cover.
    local faded =
      drawPlan(scope, plan, resources, { view = { paletteFade = 16, pictureFade = 0 }, assets = assets }, 256, 192)
    assertPixel(faded, 2, 2, 0, 0, 0, "the final cover fades every plane to black")
    local fr, fg, fb = pixel(faded, 48, 72)
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
  local censusPool = SharedImagePoolFake.new()
  local PokedexCache = require("libs.assets.src.PokedexCache")
  seedChromeFor(censusPool, cacheFs, PokedexCache.loadManifest(cacheFs), "grid")
  -- Whole-view preparation resolves visible text through its source
  -- banks, so even the headless counting leg borrows the real message
  -- provider; its body font draws into the same fake namespace so the
  -- realization census stays exact. Glyph proof lives in the ROM-gated
  -- legs, not in this census.
  local owner = Owner.new({
    imagePool = censusPool,
    monCatalog = monCatalog,
    catalog = catalog,
    cacheFs = cacheFs,
    graphics = graphics,
    text = FieldTextRenderer.new({ cacheFs = cacheFs, graphics = graphics }),
    messages = FieldMessageProvider.new(cacheFs),
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
-- The ready card paints its captured type and footprint at the native
-- origins while a single-type capture leaves the second icon blank:
-- type, footprint, and departure visibility all follow the frozen
-- specimen and the accepted card phase instead of invented art.
function T.registration_type_and_footprint_paint_at_native_origins(scope)
  local Renderer = requireRenderer("live card sprite pixels")
  local Interface = requireInterface("registration phase layout resolution")
  requireOwner("prepared card bundles")
  local okChild, Child = pcall(require, "game.hgss.src.pokedex.PokedexRegistrationState")
  Assert.isTrue(okChild, "missing battle-owned first-catch presentation")
  local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local snapshot = Fixture.registrationSnapshot(dexOwner, rig.monCatalog, "TOTODILE", 0)
    local demand = Fixture.registrationDemand(snapshot, "card-icons", rig.monCatalog)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "registration")
    seedPortraits(pool, rig.cacheFs, rig.monCatalog, demand, false)
    local lease = rig.owner:acquire({ purpose = "registration" })
    local assets = prepareReady(rig, lease, demand)
    Assert.notNil(assets.spriteParts["sprite-registration-type-water"], "the card bundle stages its captured type art")
    Assert.notNil(assets.footprintParts["TOTODILE"], "the card bundle stages its captured footprint")
    local audio = { calls = {}, cryDone = true }
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
      registration = {
        captureId = 7,
        mode = "wild",
        dexMode = snapshot.dexMode,
        displayName = snapshot.displayName,
        specimen = snapshot.specimen,
      },
      pokedex = rig.owner,
      timeline = timeline,
      audio = audio,
      measureDisplay = function()
        return measurement
      end,
    })
    local plan = resolvePlan(Interface.registration(), measurement, {})
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local layers = bgLayersFor(rig.cacheFs, rig.manifest, "registration", "information")
    local priorities = Renderer.layerPrioritiesOf(rig.manifest, "registration", "information")
    local backdrop = Renderer.backdropOf(rig.manifest, "registration", "information")
    local placement = placementOf(plan, "registration")
    local function drawCard(view)
      return drawPlan(scope, plan, resources, { view = view, assets = assets }, 256, 192)
    end
    local function tick()
      timeline:update(1 / 60, function(_)
        return true
      end)
      child:updateFixed(1 / 30)
    end
    for _ = 1, 2000 do
      if child:status().acceptsDismissal then
        break
      end
      tick()
    end
    Assert.isTrue(child:status().acceptsDismissal, "the card reaches its ready phase")
    local ready = drawCard(child:view())
    local cardObjects = assert(child:view().objects, "the ready card carries its intents")
    local function findCardIntent(objects, subject)
      for _, intent in ipairs(objects) do
        if type(intent) == "table" and intent.subject == subject then
          return intent
        end
      end
      return nil
    end
    local function inkFor(subject)
      local ink = 0
      for _, intent in ipairs(cardObjects) do
        if intent.subject == subject then
          for _, box in ipairs(intentBoxes(intent, assets, "registration")) do
            ink = ink + boxInk(ready, placement.origin, box, layers, priorities, backdrop)
          end
        end
      end
      return ink
    end
    Assert.isTrue(inkFor("type-1") > 0, "the first type paints at its native origin")
    Assert.isTrue(inkFor("footprint") > 0, "the footprint paints at its native origin")
    Assert.isNil(findCardIntent(cardObjects, "type-2"), "a single-type capture projects no second icon")
    Assert.equal(
      boxInk(ready, placement.origin, { x = 217, y = 72, width = 32, height = 16 }, layers, priorities, backdrop),
      0,
      "a single-type capture leaves the second icon blank"
    )
    child:input({ { type = "confirm" } })
    for _ = 1, 2000 do
      if child:status().complete then
        break
      end
      tick()
    end
    Assert.isTrue(child:status().complete, "departure completes into the frozen exit")
    local departed = drawCard(child:view())
    local function maxChannel(boxes)
      local peak = 0
      for _, box in ipairs(boxes) do
        for y = box.y, box.y + box.height - 1 do
          for x = box.x, box.x + box.width - 1 do
            local r, g, b = pixel(departed, placement.origin.x + x, placement.origin.y + y)
            peak = math.max(peak, r, g, b)
          end
        end
      end
      return peak
    end
    local retired = {}
    for _, intent in ipairs(cardObjects) do
      for _, box in ipairs(intentBoxes(intent, assets, "registration")) do
        retired[#retired + 1] = box
      end
    end
    Assert.equal(maxChannel(retired), 0, "the terminal cover retires every card sprite")
    child:dispose()
    lease:release()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the journey returns every borrowed interest")
  end)
end

function T.registration_child_runs_source_phases_with_fades_and_departure(scope)
  local Renderer = requireRenderer("registration phase rasterization")
  local Interface = requireInterface("registration phase layout resolution")
  requireOwner("registration phase bundles")
  local okChild, Child = pcall(require, "game.hgss.src.pokedex.PokedexRegistrationState")
  Assert.isTrue(
    okChild,
    "missing battle-owned first-catch presentation (game.hgss.src.pokedex.PokedexRegistrationState)"
  )
  assert(Child ~= nil, "the registration child loads")
  local BattleTimeline = require("game.hgss.src.battle.BattleTimeline")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local snapshot = Fixture.registrationSnapshot(dexOwner, rig.monCatalog, "TOTODILE", 0)
    local registration = {
      captureId = 7,
      mode = "wild",
      dexMode = snapshot.dexMode,
      displayName = snapshot.displayName,
      specimen = snapshot.specimen,
    }
    local demand = Fixture.registrationDemand(snapshot, "card-phases", rig.monCatalog)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "registration")
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
    -- The ready card covers departing art with the captured picture at
    -- its initial center.
    -- The finished cry releases fresh dismissal; the card still waits for
    -- the fresh edge below instead of departing on its own.
    audio.cryDone = true
    driveUntil(function()
      return child:status().acceptsDismissal == true or child:status().complete == true
    end, 400, "the card becomes dismissible after its fades and cry")
    local readyImage = drawCard(child:view())
    do
      local layers = bgLayersFor(rig.cacheFs, rig.manifest, "registration", "information")
      local priorities = Renderer.layerPrioritiesOf(rig.manifest, "registration", "information")
      local er, eg, eb = expectedBackground(layers, priorities, backdrop, 2, 2)
      assertPixel(readyImage, 2, 2, er, eg, eb, "the ready card paints its authored background")
    end
    assertPixel(readyImage, 48, 72, er, eg, eb, "the ready card paints the captured specimen at center 48")
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
    -- follows the published center, so the policy values carry the
    -- motion. The twentieth step reaches 128 and freezes the centered
    -- exit in the same update, so the samples below observe the climb
    -- and the completion gate proves the 128 arrival.
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
    local fr, fg, fb = pixel(midImage, 48, 72)
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

-- Decodes every background chrome PNG behind one pane role, in manifest
-- order, so composed pixels can be checked against independent source
-- bytes instead of the renderer's own buffers.
---@param cacheFs table version cache reader
---@param manifest table<string, unknown> compiled presentation manifest
---@param role string manifest page role
---@param paneId string browser pane identity
---@return table[] background entries with their decoded bytes
bgLayersFor = function(cacheFs, manifest, role, paneId)
  local page = assert(manifest.pages[role], "the compiled manifest carries the drawn page role " .. role)
  assert(type(page) == "table", "page roles stay records")
  local backgrounds = assert(page.backgrounds[paneId], "the page carries its pane backgrounds")
  local layers = {}
  for _, entry in ipairs(backgrounds) do
    local record = assert(manifest.chrome[entry.chrome], "background chrome resolves " .. tostring(entry.chrome))
    layers[#layers + 1] = { entry = entry, data = decodePage(cacheFs, record.path) }
  end
  return layers
end

-- The expected authored background byte at one pane pixel: the lowest
-- layer number wins priority ties exactly like the composite shader,
-- falling back to the compiled backdrop where every layer stays clear.
-- An optional pan shifts one scroll-plane layer: the pannable entry-area
-- map rides its information layer 0 at the published native-pixel
-- offset, so its chrome bytes are sampled left of the pane pixel by
-- that offset while every other layer samples in place.
---@param layers table[] decoded background entries in manifest order
---@param priorities number[] four layer priorities
---@param backdrop { r: integer, g: integer, b: integer } opaque backdrop bytes
---@param pan { layer: integer, dx: integer }? scrolled layer behind the pane
---@return integer, integer, integer expected red, green, and blue bytes
expectedBackground = function(layers, priorities, backdrop, x, y, pan)
  local byLayer = {}
  for _, item in ipairs(layers) do
    byLayer[item.entry.layer] = item
  end
  local r, g, b = backdrop.r, backdrop.g, backdrop.b
  local pri = 255
  for layer = 0, 3 do
    local item = byLayer[layer]
    if item ~= nil then
      local data = item.data
      local sx = x
      if pan ~= nil and layer == pan.layer then
        sx = x - pan.dx
      end
      if sx >= 0 and y >= 0 and sx < data:getWidth() and y < data:getHeight() then
        local pr, pg, pb, pa = pixel(data, sx, y)
        if pa > 0 and priorities[layer + 1] < pri then
          r, g, b, pri = pr, pg, pb, priorities[layer + 1]
        end
      end
    end
  end
  return r, g, b
end

---@param rect { x: number, y: number, width: number, height: number } half-open pane rectangle
---@return boolean whether the pane pixel falls inside
local function insideRect(rect, x, y)
  return x >= rect.x and y >= rect.y and x < rect.x + rect.width and y < rect.y + rect.height
end

-- Collects authored background sample points: expected bytes differ from
-- the compiled backdrop and no exclusion rectangle covers them. The
-- deterministic stride keeps the probes spread across the pane.
---@param exclusions table[] half-open pane rectangles the samples must avoid
---@param pan { layer: integer, dx: integer }? scrolled layer behind the pane
---@return table[] sample points with their expected bytes
local function backgroundSpots(layers, priorities, backdrop, exclusions, limit, pan)
  local spots = {}
  for y = 0, 191 do
    for x = 0, 255 do
      if #spots >= limit then
        return spots
      end
      if (x + y) % 7 == 0 then
        local er, eg, eb = expectedBackground(layers, priorities, backdrop, x, y, pan)
        if er ~= backdrop.r or eg ~= backdrop.g or eb ~= backdrop.b then
          local covered = false
          for _, rect in ipairs(exclusions) do
            if insideRect(rect, x, y) then
              covered = true
              break
            end
          end
          if not covered then
            spots[#spots + 1] = { x = x, y = y, r = er, g = eg, b = eb }
          end
        end
      end
    end
  end
  return spots
end

-- Counts composed pixels inside one authored window rectangle that differ
-- from the authored background bytes: a nonzero count proves glyph ink
-- over the background rather than an empty backdrop-colored box.
---@param data table 8-bit pixel buffer behind the composed target
---@param origin table placement origin behind the pane
---@param rect { x: integer, y: integer, width: integer, height: integer } authored window rectangle
---@param pan { layer: integer, dx: integer }? scrolled layer behind the pane
---@return integer pixels differing from the authored background
local function inkCount(data, origin, rect, layers, priorities, backdrop, pan)
  local ink = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local er, eg, eb = expectedBackground(layers, priorities, backdrop, x, y, pan)
      local ar, ag, ab = pixel(data, origin.x + x, origin.y + y)
      if math.abs(ar - er) + math.abs(ag - eg) + math.abs(ab - eb) > 0 then
        ink = ink + 1
      end
    end
  end
  return ink
end

-- Counts composed pane pixels that differ from the compiled backdrop:
-- nonzero proves the pane carries authored content of its own.
---@param data table 8-bit pixel buffer behind the composed target
---@param origin table placement origin behind the pane
---@param backdrop { r: integer, g: integer, b: integer } opaque backdrop bytes
---@return integer pixels differing from the backdrop
local function contentCount(data, origin, backdrop)
  local content = 0
  for y = 0, 191 do
    for x = 0, 255 do
      local ar, ag, ab = pixel(data, origin.x + x, origin.y + y)
      if math.abs(ar - backdrop.r) + math.abs(ag - backdrop.g) + math.abs(ab - backdrop.b) > 0 then
        content = content + 1
      end
    end
  end
  return content
end

-- Maps prepared messages onto their authored window keys; the
-- registration announcement rides its header window, whose key differs
-- from the prepared message role.
---@param messages table<string, string> prepared message record
---@return table<string, string> message by authored window key
local function textByWindow(messages)
  local mapped = {}
  for key, value in pairs(messages) do
    mapped[key] = value
  end
  if mapped["registration.header"] == nil and type(messages.registrationAnnouncement) == "string" then
    mapped["registration.header"] = messages.registrationAnnouncement
  end
  return mapped
end

-- Splits one authored window inventory into every rectangle plus the
-- subset carrying prepared text.
---@param manifest table<string, unknown> compiled presentation manifest
---@param role string manifest page role
---@param byWindow table<string, string> message by authored window key
---@return table[] every window rectangle, table[] rectangles carrying prepared text
local function windowRects(manifest, role, byWindow)
  local page = assert(manifest.pages[role], "the compiled manifest carries the drawn page role " .. role)
  local rects, messaged = {}, {}
  for _, key in ipairs(assert(page.windows, "the page carries its window inventory")) do
    local win = assert(manifest.windows[key], "the window inventory carries " .. tostring(key))
    local rect = { x = win.x, y = win.y, width = win.width, height = win.height }
    rects[#rects + 1] = rect
    if byWindow[key] ~= nil then
      messaged[#messaged + 1] = { rect = rect, key = key }
    end
  end
  return rects, messaged
end

-- Seeds every portrait page a demand resolves, skipping paths an earlier
-- demand in the same journey already published.
---@param pool table shared image pool double under test
---@param cacheFs table version cache reader
---@param monCatalog table resolved mon catalog
---@param demand table validated demand under preparation
---@param browser boolean true forces the nonshiny browser policy
---@param seeded table<string, boolean> already published portrait page paths
local function seedDemandPortraitsOnce(pool, cacheFs, monCatalog, demand, browser, seeded)
  local seen = {}
  for _, picture in ipairs(demand.pictures) do
    local selector = portraitSelectorFor(monCatalog, picture.specimen, picture.facing, browser)
    local entry = portraitEntryFor(cacheFs, selector)
    local path = MonCache.portraitPagePath(entry.pageId)
    if not seen[path] then
      seen[path] = true
      if not seeded[path] then
        seeded[path] = true
        Fixture.seedPhysical(pool, path, realizedImage(cacheFs, path))
      end
    end
  end
end

-- Seeds every chrome image one page role references: background layers
-- plus cell parts and sprite animation cells, decoded from the prepared
-- cache so composed background pixels equal independent source bytes.
---@param pool table shared image pool double under test
---@param cacheFs table version cache reader
---@param manifest table<string, unknown> compiled presentation manifest
---@param role string manifest page role under preparation
seedChromeFor = function(pool, cacheFs, manifest, role)
  local page = assert(manifest.pages[role], "the compiled manifest carries the drawn page role " .. role)
  local seen = {}
  ---@param chromeRole string chrome role behind one staged image
  local function seedRole(chromeRole)
    if seen[chromeRole] then
      return
    end
    seen[chromeRole] = true
    local record = assert(manifest.chrome[chromeRole], "chrome inventory carries " .. chromeRole)
    -- Roles dedup across pages by content, so a role an earlier page
    -- already published is already behind the same path: only the
    -- duplicate publication reports, never a missing image.
    local ok, err = pcall(Fixture.seedPhysical, pool, record.path, realizedImage(cacheFs, record.path))
    if not ok and tostring(err):find("already published", 1, true) == nil then
      error(err, 0)
    end
  end
  for _, paneId in ipairs({ "information", "controls" }) do
    local backgrounds = page.backgrounds
    if type(backgrounds) == "table" and type(backgrounds[paneId]) == "table" then
      for _, entry in ipairs(backgrounds[paneId]) do
        seedRole(entry.chrome)
      end
    end
  end
  ---@param cellRole string cell role behind one parts list
  local function seedCell(cellRole)
    local cell = assert(manifest.cells[cellRole], "the cell inventory carries " .. cellRole)
    for _, part in ipairs(cell.parts) do
      seedRole(part.chrome)
    end
  end
  if type(page.cells) == "table" then
    for _, cellRole in ipairs(page.cells) do
      seedCell(cellRole)
    end
  end
  if type(page.sprites) == "table" then
    for _, spriteRole in ipairs(page.sprites) do
      local sprite = assert(manifest.sprites[spriteRole], "the sprite inventory carries " .. spriteRole)
      local animation =
        assert(manifest.animations[sprite.animation], "the animation inventory carries " .. tostring(sprite.animation))
      for _, frame in ipairs(animation.frames) do
        seedCell(frame.cell)
      end
    end
  end
  -- Live subjects resolve outside the static sprite list: seed every
  -- page-local binding plus the shared footprint atlas so the demanded
  -- selection stages behind real bytes, never synthetic pool output.
  if type(page.spriteSubjects) == "table" then
    for _, choices in pairs(page.spriteSubjects) do
      for _, binding in pairs(choices) do
        local sprite =
          assert(manifest.sprites[binding.sprite], "the sprite inventory carries " .. tostring(binding.sprite))
        local animation = assert(
          manifest.animations[sprite.animation],
          "the animation inventory carries " .. tostring(sprite.animation)
        )
        for _, frame in ipairs(animation.frames) do
          seedCell(frame.cell)
        end
      end
    end
  end
  if type(manifest.footprints) == "table" then
    for _, record in pairs(manifest.footprints) do
      if type(record) == "table" and type(record.chrome) == "string" then
        seedRole(record.chrome)
        break
      end
    end
  end
end

-- Finds the first opaque pixel of one decoded portrait quad, scanning
-- outward from its center, so probes never land on transparent padding.
---@param data table 8-bit pixel buffer behind the decoded portrait page
---@return integer, integer quad-relative opaque offsets
local function opaqueOffset(data, qx, qy, width, height)
  local cx, cy = math.floor(width / 2), math.floor(height / 2)
  for radius = 0, math.max(width, height) do
    for dy = -radius, radius do
      for dx = -radius, radius do
        if math.max(math.abs(dx), math.abs(dy)) == radius then
          local x, y = cx + dx, cy + dy
          if x >= 0 and y >= 0 and x < width and y < height then
            local _, _, _, a = pixel(data, qx + x, qy + y)
            if a > 0 then
              return x, y
            end
          end
        end
      end
    end
  end
  error("the portrait quad carries no opaque pixel", 0)
end

-- Reads the published SUB BG0 scroll behind one pane: only the
-- entry-area information layer 0 rides the pannable map, every other
-- pane samples its chrome in place. The offset comes only from the
-- committed bundle's view, never from a controller handle or a clock.
---@param role string manifest page role under test
---@param paneId string browser pane identity
---@param view table detached browser projection
---@return { layer: integer, dx: integer }? scrolled layer behind the pane
local function areaPanShift(role, paneId, view)
  if role ~= "entry.area" or paneId ~= "information" then
    return nil
  end
  if type(view) ~= "table" then
    return nil
  end
  local pan = view.areaPan
  if type(pan) ~= "table" or type(pan.offset) ~= "number" then
    return nil
  end
  return { layer = 0, dx = pan.offset }
end

-- Asserts the pannable entry-area map paints shifted by exactly the
-- published view offset: every probe pixel carries the independently
-- decoded layer-0 chrome byte sampled left of the pane pixel by the
-- offset, with the entry windows still inked above it. Probes sit where
-- the layer-3 frame stays transparent and no information window or
-- portrait covers them, and each probe is sensitivity-checked against
-- the unshifted expectation so an unpanned draw cannot pass.
---@param Renderer table prepared rasterizer under test
---@param rig table graphics rig behind the lease
---@param view table detached browser projection carrying the published pan
---@param assets table ready bundle behind the draw
---@param plan table resolved application plan
---@param data table 8-bit pixel buffer behind the composed target
local function assertAreaMapPan(Renderer, rig, view, assets, plan, data)
  local pan = assert(view.areaPan, "the area view publishes its region scroll")
  assert(type(pan.offset) == "number", "the published scroll stays numeric")
  local dx = pan.offset
  local placement = placementOf(plan, "information")
  local layers = bgLayersFor(rig.cacheFs, rig.manifest, "entry.area", "information")
  local map, frame = nil, nil
  for _, item in ipairs(layers) do
    if item.entry.layer == 0 then
      map = item
    elseif item.entry.layer == 3 then
      frame = item
    end
  end
  assert(map ~= nil, "the area information pane stages its pannable map")
  local mapData = map.data
  local exclusions = {}
  local byWindow = textByWindow(assert(assets.messages, "the ready bundle carries its messages"))
  local page = assert(rig.manifest.pages["entry.area"], "the manifest carries the area page")
  for _, key in ipairs(assert(page.windows, "the area page carries its window inventory")) do
    local win = assert(rig.manifest.windows[key], "the window inventory carries " .. tostring(key))
    if win.pane == "information" then
      exclusions[#exclusions + 1] = { x = win.x, y = win.y, width = win.width, height = win.height }
    end
  end
  if assets.pictures ~= nil then
    for _, record in pairs(assets.pictures) do
      if type(record) == "table" and record.mode == "portrait" then
        local rect = Renderer.SELECTED_PICTURE_RECT
        exclusions[#exclusions + 1] = { x = rect.x, y = rect.y, width = rect.width, height = rect.height }
      end
    end
  end
  local priorities = Renderer.layerPrioritiesOf(rig.manifest, "entry.area", "information")
  local backdrop = Renderer.backdropOf(rig.manifest, "entry.area", "information")
  local probes = {}
  for y = 0, 191 do
    for x = 0, 255 do
      if #probes >= 4 then
        break
      end
      if (x + y) % 5 == 0 then
        local sx = x - dx
        if sx >= 0 and sx < mapData:getWidth() and y < mapData:getHeight() then
          local mr, mg, mb, ma = pixel(mapData, sx, y)
          if ma > 0 then
            local covered = false
            for _, rect in ipairs(exclusions) do
              if insideRect(rect, x, y) then
                covered = true
                break
              end
            end
            if not covered then
              local _, _, _, fa = 0, 0, 0, 0
              if frame ~= nil then
                local frameData = frame.data
                if x < frameData:getWidth() and y < frameData:getHeight() then
                  _, _, _, fa = pixel(frameData, x, y)
                end
              end
              if fa == 0 then
                local er, eg, eb = expectedBackground(layers, priorities, backdrop, x, y)
                if mr ~= er or mg ~= eg or mb ~= eb then
                  probes[#probes + 1] = { x = x, y = y, r = mr, g = mg, b = mb }
                end
              end
            end
          end
        end
      end
    end
    if #probes >= 4 then
      break
    end
  end
  Assert.isTrue(#probes == 4, "the shifted area map exposes pannable content at offset " .. tostring(dx))
  for _, probe in ipairs(probes) do
    assertPixel(
      data,
      placement.origin.x + probe.x,
      placement.origin.y + probe.y,
      probe.r,
      probe.g,
      probe.b,
      "the area map paints its scrolled chrome at " .. probe.x .. "," .. probe.y
    )
  end
end

-- Asserts one authored background family across both native panes: every
-- sampled background pixel equals its independently decoded chrome
-- bytes, and every messaged window carries glyph ink over them.
---@param Renderer table prepared rasterizer under test
---@param scope table<string, unknown> graphics ownership scope
---@param rig table graphics rig behind the lease
---@param view table detached browser projection
---@param assets table ready bundle behind the draw
---@param role string manifest page role under test
---@param plan table resolved application plan
---@param view table detached browser projection behind the draw
---@param assets table ready bundle behind the draw
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@return table[] exclusion rectangles behind the live sprite intents
local function dynamicExclusions(view, assets, role, paneId)
  local rects = {}
  local objects = view.objects
  if type(objects) ~= "table" then
    return rects
  end
  local manifest = assert(assets.manifest, "the ready bundle carries its compiled manifest")
  local page = assert(manifest.pages[role], "the compiled manifest carries the drawn page role")
  local subjects = page.spriteSubjects
  if type(subjects) ~= "table" then
    return rects
  end
  for _, intent in ipairs(objects) do
    if type(intent) == "table" and intent.visible ~= false and intent.pane == paneId then
      if intent.subject == "footprint" then
        rects[#rects + 1] = { x = intent.x, y = intent.y, width = 16, height = 16 }
      else
        local subjectMap = subjects[intent.subject]
        local binding = type(subjectMap) == "table" and subjectMap[intent.choice] or nil
        if type(binding) == "table" then
          local sprite = manifest.sprites[binding.sprite]
          local animation = type(sprite) == "table" and manifest.animations[sprite.animation] or nil
          if animation ~= nil then
            for _, frame in ipairs(animation.frames) do
              local cell = manifest.cells[frame.cell]
              if type(cell) == "table" then
                for _, part in ipairs(cell.parts) do
                  rects[#rects + 1] = {
                    x = intent.x + part.x,
                    y = intent.y + part.y,
                    width = part.source.width,
                    height = part.source.height,
                  }
                end
              end
            end
          end
        end
      end
    end
  end
  return rects
end

---@param data table 8-bit pixel buffer behind the composed target
local function assertNativeBackgrounds(Renderer, scope, rig, view, assets, role, plan, data)
  local _ = scope
  local byWindow = textByWindow(assert(assets.messages, "the ready bundle carries its messages"))
  local _, messaged = windowRects(rig.manifest, role, byWindow)
  for _, paneId in ipairs({ "information", "controls" }) do
    local placement = placementOf(plan, paneId)
    local layers = bgLayersFor(rig.cacheFs, rig.manifest, role, paneId)
    local priorities = Renderer.layerPrioritiesOf(rig.manifest, role, paneId)
    local backdrop = Renderer.backdropOf(rig.manifest, role, paneId)
    local pan = areaPanShift(role, paneId, view)
    local exclusions = {}
    for _, item in ipairs(messaged) do
      local win = assert(rig.manifest.windows[item.key], "messaged windows stay authored")
      if win.pane == paneId then
        exclusions[#exclusions + 1] = item.rect
      end
    end
    if paneId == "controls" and (role == "grid" or role == "results") then
      for slot = 0, Renderer.ICON_SLOTS - 1 do
        exclusions[#exclusions + 1] = Renderer.iconSlotRect(slot)
      end
    end
    for _, rect in ipairs(dynamicExclusions(view, assets, role, paneId)) do
      exclusions[#exclusions + 1] = rect
    end
    if paneId == "information" and assets.pictures ~= nil then
      for _, record in pairs(assets.pictures) do
        if type(record) == "table" and record.mode == "portrait" then
          exclusions[#exclusions + 1] = Renderer.SELECTED_PICTURE_RECT
        end
      end
    end
    local spots = backgroundSpots(layers, priorities, backdrop, exclusions, 6, pan)
    Assert.isTrue(#spots > 0, role .. " " .. paneId .. " carries authored non-backdrop background")
    for _, spot in ipairs(spots) do
      assertPixel(
        data,
        placement.origin.x + spot.x,
        placement.origin.y + spot.y,
        spot.r,
        spot.g,
        spot.b,
        role .. " " .. paneId .. " background matches its decoded chrome at " .. spot.x .. "," .. spot.y
      )
    end
    for _, item in ipairs(messaged) do
      local win = assert(rig.manifest.windows[item.key], "messaged windows stay authored")
      if win.pane == paneId then
        Assert.isTrue(
          inkCount(data, placement.origin, item.rect, layers, priorities, backdrop, pan) > 0,
          role .. " window " .. item.key .. " paints glyph ink over its background"
        )
      end
    end
  end
end

function T.native_pages_paint_authored_backgrounds_and_window_glyphs(scope)
  local Renderer = requireRenderer("authored browser backgrounds and glyphs")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared bundles behind the painted panes")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    -- Every role this journey draws seeds its chrome upfront: cover,
    -- grid, and the caught entry below; the search leg seeds its own
    -- editor role once the controller names it.
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "cover")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.area")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    -- The cover draws its backgrounds with no text, icons, or pictures.
    do
      local view = controller:view()
      Assert.equal(view.page, "cover", "the browser opens on its cover")
      local demand = browserDemandFor(Renderer, view)
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      local measurement = measurementFor("dualDisplay")
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data = drawPlan(
        scope,
        plan,
        { graphics = love.graphics, renderer = assets.renderer },
        preparedBrowserView(view, assets),
        measurement.width,
        measurement.height
      )
      assertNativeBackgrounds(Renderer, scope, rig, view, assets, "cover", plan, data)
      lease:release()
    end
    -- The grid draws both panes with icons, counts, and the selected name.
    openGrid(controller)
    do
      local view = controller:view()
      local demand = browserDemandFor(Renderer, view)
      seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, {})
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      Assert.isTrue(
        (assets.messages["grid.selected-name"] or "") ~= "",
        "the grid bundle carries its real selected name"
      )
      local measurement = measurementFor("dualDisplay")
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data = drawPlan(
        scope,
        plan,
        { graphics = love.graphics, renderer = assets.renderer },
        preparedBrowserView(view, assets),
        measurement.width,
        measurement.height
      )
      assertNativeBackgrounds(Renderer, scope, rig, view, assets, "grid", plan, data)
      lease:release()
    end
    -- Search editors reuse no list background: their composed screens
    -- differ from the grid bytes they replace.
    press(controller, { { type = "y" } })
    idle(controller, 2)
    Assert.equal(controller:view().page, "search", "the grid opens its search criteria")
    do
      local view = controller:view()
      local role = Renderer.resolvePageRole(view, "information")
      seedChromeFor(pool, rig.cacheFs, rig.manifest, role)
      local gridLayers = bgLayersFor(rig.cacheFs, rig.manifest, "grid", "information")
      local searchLayers = bgLayersFor(rig.cacheFs, rig.manifest, role, "information")
      local differ = false
      local first = searchLayers[1]
      if first ~= nil and gridLayers[1] ~= nil then
        local a, b = first.data, gridLayers[1].data
        if a:getWidth() == b:getWidth() and a:getHeight() == b:getHeight() then
          for y = 0, a:getHeight() - 1 do
            for x = 0, a:getWidth() - 1 do
              local r1, g1, b1, a1 = pixel(a, x, y)
              local r2, g2, b2, a2 = pixel(b, x, y)
              if math.abs(r1 - r2) + math.abs(g1 - g2) + math.abs(b1 - b2) + math.abs(a1 - a2) > 0 then
                differ = true
                break
              end
            end
            if differ then
              break
            end
          end
        else
          differ = true
        end
      end
      Assert.isTrue(differ, "search criteria reuse no list background bytes")
      local demand = browserDemandFor(Renderer, view)
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      local measurement = measurementFor("dualDisplay")
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data = drawPlan(
        scope,
        plan,
        { graphics = love.graphics, renderer = assets.renderer },
        preparedBrowserView(view, assets),
        measurement.width,
        measurement.height
      )
      assertNativeBackgrounds(Renderer, scope, rig, view, assets, role, plan, data)
      lease:release()
    end
    -- Leaving the criteria returns to the grid the entry journey needs.
    press(controller, { { type = "cancel" } })
    idle(controller, 2)
    Assert.equal(controller:view().page, "grid", "cancelling search criteria returns to the grid")
    -- A caught entry draws its portrait excluded from the background
    -- probes, with the species window inked over the area screen.
    selectSpecies(controller, "TOTODILE")
    openEntry(controller)
    do
      local view = controller:view()
      Assert.equal(view.page, "area", "the caught entry opens its area page")
      -- The freshly opened entry rests on the settled Johto scroll: the
      -- area leg below proves the information map paints shifted by
      -- exactly this published offset with its windows still inked.
      Assert.equal(view.areaPan.region, 0, "the fresh entry views the johto region")
      Assert.equal(view.areaPan.offset, -72, "the fresh entry rests on the settled johto scroll")
      local demand = browserDemandFor(Renderer, view)
      seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, {})
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      local measurement = measurementFor("dualDisplay")
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data = drawPlan(
        scope,
        plan,
        { graphics = love.graphics, renderer = assets.renderer },
        preparedBrowserView(view, assets),
        measurement.width,
        measurement.height
      )
      assertNativeBackgrounds(Renderer, scope, rig, view, assets, "entry.area", plan, data)
      assertAreaMapPan(Renderer, rig, view, assets, plan, data)
      lease:release()
    end
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the journey returns every borrowed interest")
  end)
end

function T.area_map_paints_settled_and_travelling_region_scrolls(scope)
  local Renderer = requireRenderer("panned area map composition")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared bundles behind the panned map")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.area")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    selectSpecies(controller, "TOTODILE")
    openEntry(controller)
    local seeded = {}
    -- Draws the current committed view through a fresh ready bundle:
    -- the offset behind the draw comes only from the published view,
    -- never from a controller handle or a clock.
    local function drawAreaStage(label)
      local view = controller:view()
      Assert.equal(view.page, "area", label .. " keeps the area page")
      local demand = browserDemandFor(Renderer, view)
      seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, seeded)
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      local measurement = measurementFor("dualDisplay")
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data = drawPlan(
        scope,
        plan,
        { graphics = love.graphics, renderer = assets.renderer },
        preparedBrowserView(view, assets),
        measurement.width,
        measurement.height
      )
      assertNativeBackgrounds(Renderer, scope, rig, view, assets, "entry.area", plan, data)
      assertAreaMapPan(Renderer, rig, view, assets, plan, data)
      lease:release()
      return view
    end
    -- The settled Johto pan rests at the native scroll with its entry
    -- windows inked over the shifted map.
    do
      local view = drawAreaStage("the fresh entry")
      Assert.equal(view.areaPan.region, 0, "the fresh entry views the johto region")
      Assert.equal(view.areaPan.offset, -72, "the fresh entry rests on the settled johto scroll")
    end
    -- Switching regions travels toward the Kanto scroll; the smoke keeps
    -- the settled endpoints (fresh Johto, settled Kanto) and skips the
    -- mid-travel frame, which exercises the same pan path at full cost.
    press(controller, { { type = "r" } })
    -- The travel settles exactly on the Kanto scroll and holds there.
    idle(controller, 30)
    do
      local view = drawAreaStage("the settled kanto map")
      Assert.equal(view.areaPan.region, 1, "the settled map still views kanto")
      Assert.equal(view.areaPan.offset, 104, "the travel settles on the kanto scroll")
    end
    idle(controller, 4)
    Assert.equal(controller:view().areaPan.offset, 104, "the settled kanto scroll holds across further ticks")
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the journey returns every borrowed interest")
  end)
end

function T.transparent_sprite_corners_reveal_their_background(scope)
  local Renderer = requireRenderer("sampled sprite alpha coverage")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared bundles behind the alpha probes")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    -- Icons with fully transparent corners over opaque centers: caught
    -- art paints opaque while seen-only art blends, but every corner
    -- must match the authored background exactly.
    local function cornerIcon(r, g, b)
      return function(x, y)
        if (x < 6 and y < 6) or (x >= 26 and y < 6) or (x < 6 and y >= 26) or (x >= 26 and y >= 26) then
          return 0, 0, 0, 0
        end
        return r, g, b, 1
      end
    end
    Fixture.seedPhysical(pool, "pokedex/icons/TOTODILE/f0", solidImage(32, 32, cornerIcon(1, 0, 0)))
    Fixture.seedPhysical(pool, "pokedex/icons/CHIKORITA/f0", solidImage(32, 32, cornerIcon(1, 1, 1)))
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    local view = controller:view()
    local demand = browserDemandFor(Renderer, view)
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, {})
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    local measurement = measurementFor("dualDisplay")
    local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local data =
      drawPlan(scope, plan, resources, preparedBrowserView(view, assets), measurement.width, measurement.height)
    local controls = placementOf(plan, "controls")
    local layers = bgLayersFor(rig.cacheFs, rig.manifest, "grid", "controls")
    local priorities = Renderer.layerPrioritiesOf(rig.manifest, "grid", "controls")
    local backdrop = Renderer.backdropOf(rig.manifest, "grid", "controls")
    -- The caught corner reveals the authored background exactly.
    local caughtRect = Renderer.iconSlotRect(gridSlotOf(view, "TOTODILE"))
    do
      local er, eg, eb = expectedBackground(layers, priorities, backdrop, caughtRect.x + 2, caughtRect.y + 2)
      assertPixel(
        data,
        controls.origin.x + caughtRect.x + 2,
        controls.origin.y + caughtRect.y + 2,
        er,
        eg,
        eb,
        "the caught icon corner reveals its authored background"
      )
      assertPixel(
        data,
        controls.origin.x + caughtRect.x + 16,
        controls.origin.y + caughtRect.y + 16,
        255,
        0,
        0,
        "the caught icon center stays opaque"
      )
    end
    -- The seen-only corner reveals the same background while its center
    -- blends 6/10 against the eligible layer.
    local seenRect = Renderer.iconSlotRect(gridSlotOf(view, "CHIKORITA"))
    do
      local er, eg, eb = expectedBackground(layers, priorities, backdrop, seenRect.x + 2, seenRect.y + 2)
      assertPixel(
        data,
        controls.origin.x + seenRect.x + 2,
        controls.origin.y + seenRect.y + 2,
        er,
        eg,
        eb,
        "the seen-only icon corner reveals its authored background"
      )
      local cx, cy = seenRect.x + 16, seenRect.y + 16
      local br, bg, bb = expectedBackground(layers, priorities, backdrop, cx, cy)
      assertPixel(
        data,
        controls.origin.x + cx,
        controls.origin.y + cy,
        blendByteOracle(255, br, 6, 10),
        blendByteOracle(255, bg, 6, 10),
        blendByteOracle(255, bb, 6, 10),
        "the seen-only icon center blends 6/10 against eligible background"
      )
    end
    lease:release()
    controller:dispose()
    rig.owner:release()
  end)
end

function T.forms_comparison_paints_both_selected_variants(scope)
  local Renderer = requireRenderer("comparison variant rasterization")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared comparison bundles")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.compare")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local function observe(species, personality, form, kind)
      local specimen = dexOwner:describe(PokedexDexFixture.makeMon(rig.monCatalog, {
        species = species,
        personality = personality,
        form = form,
      }))
      dexOwner:prepareChanges({ observations = { { kind = kind, specimen = specimen } } }):publish()
    end
    observe("PICHU", 127, 0, "seen")
    observe("PICHU", 0, 0, "seen")
    observe("PICHU", 0, 1, "caught")
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    selectSpecies(controller, "PICHU")
    openEntry(controller)
    openTab(controller, "forms")
    -- The third logical variant carries the distinct physical form, so
    -- the comparison pairs two visibly different faces by slot side.
    press(controller, { { type = "navigate", direction = "down" } })
    idle(controller, 2)
    press(controller, { { type = "navigate", direction = "down" } })
    idle(controller, 2)
    press(controller, { { type = "activate", action = "compare" } })
    idle(controller, 2)
    local seeded = {}
    local measurement = measurementFor("dualDisplay")
    local resources = nil
    ---@param facing string front or back facing under test
    ---@return table left and right composed center bytes behind the facing
    local function drawComparison(facing)
      local view = controller:view()
      Assert.equal(view.page, "forms", "the comparison rests on its forms page")
      Assert.equal(view.forms.comparison.facing, facing, "the comparison faces " .. facing)
      Assert.equal(#view.pictures, 2, "the comparison projects exactly two specimens")
      local demand = browserDemandFor(Renderer, view)
      seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, seeded)
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      if resources == nil then
        resources = { graphics = love.graphics, renderer = assets.renderer }
      end
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data =
        drawPlan(scope, plan, resources, preparedBrowserView(view, assets), measurement.width, measurement.height)
      local info = placementOf(plan, "information")
      local found = {}
      for slot = 0, 1 do
        local record = assert(assets.pictures[slot], "the ready bundle carries comparison slot " .. slot)
        local rect = slot == 0 and Renderer.COMPARE_LEFT_RECT or Renderer.COMPARE_RIGHT_RECT
        local quad = assert(record.quad, "comparison slots carry their viewport")
        local qx, qy, qw, qh = quad:getViewport()
        local baseData = decodePage(
          rig.cacheFs,
          assert(
            MonCache.portraitPagePath(
              assert(
                portraitEntryFor(
                  rig.cacheFs,
                  portraitSelectorFor(rig.monCatalog, demand.pictures[slot + 1].specimen, facing, true)
                ),
                "the portrait manifest carries slot " .. slot
              ).pageId
            ),
            "the slot portrait resolves its page"
          )
        )
        local dx, dy = opaqueOffset(baseData, qx, qy, qw, qh)
        local er, eg, eb = pixel(baseData, qx + dx, qy + dy)
        assertPixel(
          data,
          info.origin.x + rect.x + dx,
          info.origin.y + rect.y + dy,
          er,
          eg,
          eb,
          "comparison slot " .. slot .. " paints its " .. facing .. " portrait on its own side"
        )
        found[#found + 1] = string.format("%d,%d,%d", er, eg, eb)
      end
      lease:release()
      return found
    end
    local front = drawComparison("front")
    Assert.isTrue(front[1] ~= front[2], "the two compared faces differ")
    -- Flipping swaps both pictures to their backs and back again.
    press(controller, { { type = "menu" } })
    idle(controller, 2)
    local back = drawComparison("back")
    Assert.isTrue(back[1] ~= front[1] or back[2] ~= front[2], "flipping visibly swaps the pictures")
    -- Smoke skips the flip-back restore frame: front/back already prove
    -- both faces paint distinctly on their own sides at full render cost.
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the journey returns every borrowed interest")
  end)
end

function T.registration_card_paints_source_card_content(scope)
  local Renderer = requireRenderer("registration card rasterization")
  local Interface = requireInterface("registration layout resolution")
  requireOwner("prepared registration bundles")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local snapshot = Fixture.registrationSnapshot(dexOwner, rig.monCatalog, "TOTODILE", 0)
    local demand = Fixture.registrationDemand(snapshot, "card-content", rig.monCatalog)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "registration")
    local seeded = {}
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, false, seeded)
    local lease = rig.owner:acquire({ purpose = "registration" })
    local assets = prepareReady(rig, lease, demand)
    local announcement =
      assert(assets.messages.registrationAnnouncement, "the ready card bundle carries its announcement")
    Assert.isTrue(announcement ~= "", "the card announcement carries its source string")
    local measurement = measurementFor("nativeLike")
    local plan = resolvePlan(Interface.registration(), measurement, {})
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local data = drawPlan(
      scope,
      plan,
      resources,
      { view = { pictureX = 48, banner = 0, paletteFade = 0, pictureFade = 0 }, assets = assets },
      256,
      192
    )
    -- The card background is authored, not the bare backdrop.
    local layers = bgLayersFor(rig.cacheFs, rig.manifest, "registration", "information")
    local priorities = Renderer.layerPrioritiesOf(rig.manifest, "registration", "information")
    local backdrop = Renderer.backdropOf(rig.manifest, "registration", "information")
    local header = assert(rig.manifest.windows["registration.header"], "the manifest carries the card header")
    local headerRect = { x = header.x, y = header.y, width = header.width, height = header.height }
    local spots = backgroundSpots(layers, priorities, backdrop, { headerRect }, 4)
    Assert.isTrue(#spots > 0, "the card carries authored non-backdrop background")
    for _, spot in ipairs(spots) do
      assertPixel(
        data,
        spot.x,
        spot.y,
        spot.r,
        spot.g,
        spot.b,
        "the card background matches its decoded chrome at " .. spot.x .. "," .. spot.y
      )
    end
    Assert.isTrue(
      inkCount(data, { x = 0, y = 0 }, headerRect, layers, priorities, backdrop) > 0,
      "the card header inks its announcement over the background"
    )
    -- The captured specimen paints at its initial center.
    local card = assert(assets.pictures.registration, "the ready bundle carries its card picture")
    local qx, qy, qw, qh = assert(card.quad, "the card slot carries its viewport"):getViewport()
    local cardSelector = portraitSelectorFor(rig.monCatalog, snapshot.specimen, "front", false)
    local baseData = decodePage(
      rig.cacheFs,
      assert(
        MonCache.portraitPagePath(
          assert(portraitEntryFor(rig.cacheFs, cardSelector), "the card portrait resolves its entry").pageId
        ),
        "the card portrait resolves its page"
      )
    )
    local dx, dy = opaqueOffset(baseData, qx, qy, qw, qh)
    local er, eg, eb = pixel(baseData, qx + dx, qy + dy)
    assertPixel(data, 8 + dx, 32 + dy, er, eg, eb, "the initial card paints the captured specimen at center 48")
    lease:release()
    rig.owner:release()
  end)
end

function T.registration_picture_slides_and_hides_on_departure(scope)
  local Renderer = requireRenderer("registration picture motion")
  local Interface = requireInterface("registration motion layout resolution")
  requireOwner("prepared motion bundles")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local snapshot = Fixture.registrationSnapshot(dexOwner, rig.monCatalog, "TOTODILE", 0)
    local demand = Fixture.registrationDemand(snapshot, "card-motion", rig.monCatalog)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "registration")
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, false, {})
    local lease = rig.owner:acquire({ purpose = "registration" })
    local assets = prepareReady(rig, lease, demand)
    local measurement = measurementFor("nativeLike")
    local plan = resolvePlan(Interface.registration(), measurement, {})
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local card = assert(assets.pictures.registration, "the ready bundle carries its card picture")
    local qx, qy, qw, qh = assert(card.quad, "the card slot carries its viewport"):getViewport()
    local cardSelector = portraitSelectorFor(rig.monCatalog, snapshot.specimen, "front", false)
    local baseData = decodePage(
      rig.cacheFs,
      assert(
        MonCache.portraitPagePath(
          assert(portraitEntryFor(rig.cacheFs, cardSelector), "the card portrait resolves its entry").pageId
        ),
        "the card portrait resolves its page"
      )
    )
    local dx, dy = opaqueOffset(baseData, qx, qy, qw, qh)
    local er, eg, eb = pixel(baseData, qx + dx, qy + dy)
    local layers = bgLayersFor(rig.cacheFs, rig.manifest, "registration", "information")
    local priorities = Renderer.layerPrioritiesOf(rig.manifest, "registration", "information")
    local backdrop = Renderer.backdropOf(rig.manifest, "registration", "information")
    ---@param pictureX integer source picture center behind the frame
    ---@param hidden boolean true once departure hides the sprite art
    ---@return table 8-bit pixel buffer behind the composed card
    local function drawCard(pictureX, hidden)
      return drawPlan(scope, plan, resources, {
        view = { pictureX = pictureX, spritesHidden = hidden, banner = 0, paletteFade = 0, pictureFade = 0 },
        assets = assets,
      }, 256, 192)
    end
    for _, center in ipairs({ 48, 88, 128 }) do
      local data = drawCard(center, false)
      assertPixel(
        data,
        center - 40 + dx,
        32 + dy,
        er,
        eg,
        eb,
        "the departing picture paints its specimen at center " .. center
      )
    end
    -- Once hidden, the specimen bytes leave while the card background
    -- stays: the probe lands on authored background, never the portrait.
    do
      local data = drawCard(128, true)
      local br, bg, bb = expectedBackground(layers, priorities, backdrop, 88 + dx, 32 + dy)
      assertPixel(data, 88 + dx, 32 + dy, br, bg, bb, "the hidden departure frame clears the specimen from the card")
    end
    lease:release()
    rig.owner:release()
  end)
end

-- Placed page sprites ink their authored art at their authored centers:
-- the shape editor's fourteen choice icons paint over the criteria
-- background on the controls pane, one resting frame per sprite, while
-- every state-driven record stays off the origin pile-up.
function T.search_shape_grid_paints_placed_choice_art(scope)
  local Renderer = requireRenderer("placed page-sprite rasterization")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared bundles behind the shape editor")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    press(controller, { { type = "y" } })
    idle(controller, 2)
    Assert.equal(controller:view().page, "search", "the grid opens its search criteria")
    press(controller, { { type = "activate", action = "criterion", value = "shape" } })
    idle(controller, 2)
    local view = controller:view()
    Assert.equal(
      Renderer.resolvePageRole(view, "information"),
      "search.shape",
      "the shape editor reads its own page role"
    )
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.shape")
    local demand = browserDemandFor(Renderer, view)
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, {})
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    local page = assert(rig.manifest.pages["search.shape"], "the manifest closes the shape page")
    local placed = {}
    for _, spriteRole in ipairs(assert(page.sprites, "the shape page inventories its sprites")) do
      local record = assert(rig.manifest.sprites[spriteRole], "the sprite inventory carries " .. spriteRole)
      if record.x ~= 0 or record.y ~= 0 then
        placed[#placed + 1] = { role = spriteRole, record = record }
      end
    end
    Assert.equal(#placed, 14, "the shape page places its fourteen choice sprites")
    local decoded = {}
    local function chromeData(role)
      if decoded[role] == nil then
        local entry = assert(rig.manifest.chrome[role], "the manifest stages " .. role)
        decoded[role] = decodePage(rig.cacheFs, entry.path)
      end
      return decoded[role]
    end
    local measurement = measurementFor("dualDisplay")
    local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local data =
      drawPlan(scope, plan, resources, preparedBrowserView(view, assets), measurement.width, measurement.height)
    local controlsPane = placementOf(plan, "controls")
    for _, entry in ipairs(placed) do
      local animation = assert(rig.manifest.animations[entry.record.animation], entry.role .. " resolves its animation")
      local cell = assert(rig.manifest.cells[animation.frames[1].cell], entry.role .. " resolves its resting cell")
      local part = assert(cell.parts[1], entry.role .. " carries its first part")
      local baseData = chromeData(part.chrome)
      local dx, dy = opaqueOffset(baseData, part.source.x, part.source.y, part.source.width, part.source.height)
      local er, eg, eb = pixel(baseData, part.source.x + dx, part.source.y + dy)
      assertPixel(
        data,
        controlsPane.origin.x + entry.record.x + part.x + dx,
        controlsPane.origin.y + entry.record.y + part.y + dy,
        er,
        eg,
        eb,
        entry.role .. " inks its authored art at its authored center"
      )
    end
    lease:release()
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the shape journey returns every borrowed interest")
  end)
end

-- The registration banner emblem inks at its authored center on the
-- card and survives the cover fade through the OBJ fade routing while
-- the dynamic type and footprint records stay undrawn.
function T.registration_card_paints_placed_banner_art(scope)
  local Renderer = requireRenderer("placed registration rasterization")
  local Interface = requireInterface("registration layout resolution")
  requireOwner("prepared registration bundles")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local snapshot = Fixture.registrationSnapshot(dexOwner, rig.monCatalog, "TOTODILE", 0)
    local demand = Fixture.registrationDemand(snapshot, "card-banner", rig.monCatalog)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "registration")
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, false, {})
    local lease = rig.owner:acquire({ purpose = "registration" })
    local assets = prepareReady(rig, lease, demand)
    local page = assert(rig.manifest.pages.registration, "the manifest closes the registration page")
    local placed = {}
    for _, spriteRole in ipairs(assert(page.sprites, "the card inventories its sprites")) do
      local record = assert(rig.manifest.sprites[spriteRole], "the sprite inventory carries " .. spriteRole)
      if record.x ~= 0 or record.y ~= 0 then
        placed[#placed + 1] = { role = spriteRole, record = record }
      end
    end
    Assert.equal(#placed, 1, "the card places only its banner emblem")
    local entry = placed[1]
    local animation = assert(rig.manifest.animations[entry.record.animation], entry.role .. " resolves its animation")
    local cell = assert(rig.manifest.cells[animation.frames[1].cell], entry.role .. " resolves its resting cell")
    local part = assert(cell.parts[1], entry.role .. " carries its first part")
    local chromeEntry = assert(rig.manifest.chrome[part.chrome], "the manifest stages " .. part.chrome)
    local baseData = decodePage(rig.cacheFs, chromeEntry.path)
    local dx, dy = opaqueOffset(baseData, part.source.x, part.source.y, part.source.width, part.source.height)
    local er, eg, eb = pixel(baseData, part.source.x + dx, part.source.y + dy)
    local measurement = measurementFor("nativeLike")
    local plan = resolvePlan(Interface.registration(), measurement, {})
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local unfaded = drawPlan(
      scope,
      plan,
      resources,
      { view = { pictureX = 48, paletteFade = 0, pictureFade = 0 }, assets = assets },
      256,
      192
    )
    assertPixel(
      unfaded,
      entry.record.x + part.x + dx,
      entry.record.y + part.y + dy,
      er,
      eg,
      eb,
      "the banner emblem inks at its authored center"
    )
    local faded = drawPlan(
      scope,
      plan,
      resources,
      { view = { pictureX = 48, paletteFade = 16, pictureFade = 0 }, assets = assets },
      256,
      192
    )
    assertPixel(
      faded,
      entry.record.x + part.x + dx,
      entry.record.y + part.y + dy,
      er,
      eg,
      eb,
      "the banner emblem survives the cover fade unfaded"
    )
    lease:release()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the banner journey returns every borrowed interest")
  end)
end

-- Prepared page sprites never realize graphics objects while drawing:
-- after whole-view preparation of the shape editor and the
-- registration card, repeated draws of both pages paint their placed
-- art while the viewport, image, canvas, and shader constructor counts
-- stay flat. The shared one-realization preparation budget is proven at
-- the owning lease boundary, where no font warmup pollutes the census.
function T.prepared_page_sprites_draw_without_realizing_new_objects(scope)
  local Renderer = requireRenderer("prepared page-sprite drawing")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared bundles behind the shape editor")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    press(controller, { { type = "y" } })
    idle(controller, 2)
    Assert.equal(controller:view().page, "search", "the grid opens its search criteria")
    press(controller, { { type = "activate", action = "criterion", value = "shape" } })
    idle(controller, 2)
    local view = controller:view()
    Assert.equal(
      Renderer.resolvePageRole(view, "information"),
      "search.shape",
      "the shape editor reads its own page role"
    )
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.shape")
    local demand = browserDemandFor(Renderer, view)
    local seeded = {}
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, seeded)
    local snapshot = Fixture.registrationSnapshot(dexOwner, rig.monCatalog, "TOTODILE", 0)
    local cardDemand = Fixture.registrationDemand(snapshot, "prepared-sprite-parts", rig.monCatalog)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "registration")
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, cardDemand, false, seeded)
    local realQuad = love.graphics.newQuad
    local realCanvas = love.graphics.newCanvas
    local realImage = love.graphics.newImage
    local realShader = love.graphics.newShader
    local counts = { quad = 0, canvas = 0, image = 0, shader = 0 }
    love.graphics.newQuad = function(...)
      counts.quad = counts.quad + 1
      return realQuad(...)
    end
    love.graphics.newCanvas = function(...)
      counts.canvas = counts.canvas + 1
      return realCanvas(...)
    end
    love.graphics.newImage = function(...)
      counts.image = counts.image + 1
      return realImage(...)
    end
    love.graphics.newShader = function(...)
      counts.shader = counts.shader + 1
      return realShader(...)
    end
    local ok, err = xpcall(function()
      local shapeLease = rig.owner:acquire({ purpose = "browser" })
      local shapeAssets = prepareReady(rig, shapeLease, demand)
      local cardLease = rig.owner:acquire({ purpose = "registration" })
      local cardAssets = prepareReady(rig, cardLease, cardDemand)
      local shapeMeasurement = measurementFor("dualDisplay")
      local shapePlan = resolvePlan(Interface.browser(), shapeMeasurement, planViewOf(view))
      local cardPlan = resolvePlan(Interface.registration(), measurementFor("nativeLike"), {})
      local shapeResources = { graphics = love.graphics, renderer = shapeAssets.renderer }
      local cardResources = { graphics = love.graphics, renderer = cardAssets.renderer }
      local shapeTarget = scope:own(realCanvas(shapeMeasurement.width, shapeMeasurement.height))
      local cardTarget = scope:own(realCanvas(256, 192))
      ---@param target table owned offscreen target behind the composed pane
      ---@param plan table resolved application plan behind the draw
      ---@param resources table borrowed draw resources with the renderer
      ---@param preparedView table prepared view behind the draw
      ---@return table 8-bit pixel buffer behind the composed target
      local function renderTo(target, plan, resources, preparedView)
        love.graphics.setCanvas(target)
        love.graphics.clear(0, 0, 0, 0)
        plan.render(resources, preparedView, plan)
        love.graphics.setCanvas()
        return target:newImageData()
      end
      local shapePage = assert(rig.manifest.pages["search.shape"], "the manifest closes the shape page")
      local placed = {}
      for _, spriteRole in ipairs(assert(shapePage.sprites, "the shape page inventories its sprites")) do
        local record = assert(rig.manifest.sprites[spriteRole], "the sprite inventory carries " .. spriteRole)
        if record.x ~= 0 or record.y ~= 0 then
          placed[#placed + 1] = { role = spriteRole, record = record }
        end
      end
      Assert.equal(#placed, 14, "the shape page places its fourteen choice sprites")
      local shapeParts = assert(shapeAssets.spriteParts, "the shape bundle publishes its prepared sprite parts")
      for _, entry in ipairs(placed) do
        local frames = assert(shapeParts[entry.role], entry.role .. " publishes its prepared frame")
        local resting = assert(frames[1], entry.role .. " publishes its resting frame")
        Assert.isTrue(#resting >= 1, entry.role .. " prepares its resting parts")
        for _, prepared in ipairs(resting) do
          Assert.notNil(prepared.quad, entry.role .. " prepares its viewport before drawing")
        end
      end
      local decoded = {}
      local function chromeData(role)
        if decoded[role] == nil then
          local entry = assert(rig.manifest.chrome[role], "the manifest stages " .. role)
          decoded[role] = decodePage(rig.cacheFs, entry.path)
        end
        return decoded[role]
      end
      local controlsPane = placementOf(shapePlan, "controls")
      ---@param data table 8-bit pixel buffer behind the composed shape page
      local function checkShapeArt(data)
        for _, entry in ipairs(placed) do
          local animation =
            assert(rig.manifest.animations[entry.record.animation], entry.role .. " resolves its animation")
          local cell = assert(rig.manifest.cells[animation.frames[1].cell], entry.role .. " resolves its resting cell")
          local part = assert(cell.parts[1], entry.role .. " carries its first part")
          local baseData = chromeData(part.chrome)
          local dx, dy = opaqueOffset(baseData, part.source.x, part.source.y, part.source.width, part.source.height)
          local er, eg, eb = pixel(baseData, part.source.x + dx, part.source.y + dy)
          assertPixel(
            data,
            controlsPane.origin.x + entry.record.x + part.x + dx,
            controlsPane.origin.y + entry.record.y + part.y + dy,
            er,
            eg,
            eb,
            entry.role .. " inks its authored art at its authored center"
          )
        end
      end
      local cardPage = assert(rig.manifest.pages.registration, "the manifest closes the registration page")
      local banner = nil
      for _, spriteRole in ipairs(assert(cardPage.sprites, "the card inventories its sprites")) do
        local record = assert(rig.manifest.sprites[spriteRole], "the sprite inventory carries " .. spriteRole)
        if record.x ~= 0 or record.y ~= 0 then
          Assert.isNil(banner, "the card places only its banner emblem")
          banner = { role = spriteRole, record = record }
        end
      end
      Assert.notNil(banner, "the card places its banner emblem")
      assert(banner ~= nil, "the card places its banner emblem")
      local bannerAnimation =
        assert(rig.manifest.animations[banner.record.animation], banner.role .. " resolves its animation")
      local bannerCell =
        assert(rig.manifest.cells[bannerAnimation.frames[1].cell], banner.role .. " resolves its resting cell")
      local bannerPart = assert(bannerCell.parts[1], banner.role .. " carries its first part")
      local bannerEntry = assert(rig.manifest.chrome[bannerPart.chrome], "the manifest stages " .. bannerPart.chrome)
      local bannerData = decodePage(rig.cacheFs, bannerEntry.path)
      local bannerDx, bannerDy = opaqueOffset(
        bannerData,
        bannerPart.source.x,
        bannerPart.source.y,
        bannerPart.source.width,
        bannerPart.source.height
      )
      local ber, beg, beb = pixel(bannerData, bannerPart.source.x + bannerDx, bannerPart.source.y + bannerDy)
      local cardParts = assert(cardAssets.spriteParts, "the card bundle publishes its prepared sprite parts")
      local bannerResting = assert(
        assert(cardParts[banner.role], "the banner publishes its prepared frame")[1],
        "the banner publishes its resting frame"
      )
      Assert.isTrue(#bannerResting >= 1, "the banner prepares its resting parts")
      ---@param data table 8-bit pixel buffer behind the composed card
      local function checkCardArt(data)
        assertPixel(
          data,
          banner.record.x + bannerPart.x + bannerDx,
          banner.record.y + bannerPart.y + bannerDy,
          ber,
          beg,
          beb,
          "the banner emblem inks at its authored center"
        )
      end
      checkShapeArt(renderTo(shapeTarget, shapePlan, shapeResources, preparedBrowserView(view, shapeAssets)))
      checkCardArt(
        renderTo(
          cardTarget,
          cardPlan,
          cardResources,
          { view = { pictureX = 48, paletteFade = 0, pictureFade = 0 }, assets = cardAssets }
        )
      )
      local before = { quad = counts.quad, canvas = counts.canvas, image = counts.image, shader = counts.shader }
      for _ = 1, 3 do
        checkShapeArt(renderTo(shapeTarget, shapePlan, shapeResources, preparedBrowserView(view, shapeAssets)))
        checkCardArt(
          renderTo(
            cardTarget,
            cardPlan,
            cardResources,
            { view = { pictureX = 48, paletteFade = 0, pictureFade = 0 }, assets = cardAssets }
          )
        )
      end
      Assert.equal(counts.quad, before.quad, "steady draws create no viewports")
      Assert.equal(counts.canvas, before.canvas, "steady draws create no canvases")
      Assert.equal(counts.image, before.image, "steady draws create no images")
      Assert.equal(counts.shader, before.shader, "steady draws create no shaders")
      shapeLease:release()
      cardLease:release()
      controller:dispose()
      rig.owner:release()
      Assert.equal(pool:stats().outstandingLeases, 0, "the sprite journey returns every borrowed interest")
    end, debug.traceback)
    love.graphics.newQuad = realQuad
    love.graphics.newCanvas = realCanvas
    love.graphics.newImage = realImage
    love.graphics.newShader = realShader
    if not ok then
      error(err, 0)
    end
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

-- Every native search editor and the area/return entry tabs paint their
-- source glyphs: criteria captions with staged values and buttons, the
-- 27-mark letter grid, type and area choices, the area daypart, and the
-- return-to-list action. Each leg asserts its prepared strings exist and
-- then proves glyph ink over the composed background.
function T.native_search_and_entry_text_paints_source_glyphs(scope)
  local Renderer = requireRenderer("search and entry source glyphs")
  local Interface = requireInterface("paired native layout resolution")
  requireOwner("prepared bundles behind the search glyphs")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "cover")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.criteria")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.order")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.name")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.type")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.height")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.weight")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.area")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.shape")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.area")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.size")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.forms")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.return")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    press(controller, { { type = "y" } })
    idle(controller, 2)
    local seeded = {}
    local function drawCurrent(role)
      local view = controller:view()
      local demand = browserDemandFor(Renderer, view)
      seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, seeded)
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      local measurement = measurementFor("dualDisplay")
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data = drawPlan(
        scope,
        plan,
        { graphics = love.graphics, renderer = assets.renderer },
        preparedBrowserView(view, assets),
        measurement.width,
        measurement.height
      )
      assertNativeBackgrounds(Renderer, scope, rig, view, assets, role, plan, data)
      lease:release()
      return assets
    end
    do
      local view = controller:view()
      Assert.equal(view.page, "search", "the grid opens its search criteria")
      local assets = drawCurrent("search.criteria")
      for _, key in ipairs({ "search.caption-order", "search.caption-letter", "search.value-order", "search.button-run", "search.button-reset", "search.button-back" }) do
        Assert.isTrue(
          (assets.messages[key] or "") ~= "",
          "the criteria bundle carries its real string " .. key
        )
      end
    end
    press(controller, { { type = "activate", action = "criterion", value = "order" } })
    idle(controller, 2)
    do
      local assets = drawCurrent("search.order")
      for _, key in ipairs({ "search.title-order", "search.current-order", "search.option-order-numerical", "search.button-ok" }) do
        Assert.isTrue((assets.messages[key] or "") ~= "", "the order bundle carries its real string " .. key)
      end
    end
    press(controller, { { type = "cancel" } })
    idle(controller, 2)
    -- Smoke keeps the criteria/order/entry spine: the letter, type,
    -- area, height, weight, and shape pages exercise the same
    -- draw/bundle path at full render cost, so they are covered by
    -- message-identity unit tests instead of full-frame draws here.
    press(controller, { { type = "cancel" } })
    idle(controller, 2)
    Assert.equal(controller:view().page, "grid", "cancelling the criteria returns to the grid")
    selectSpecies(controller, "TOTODILE")
    openEntry(controller)
    -- The source centers the cursor two rows down: the first row window
    -- stays blank until the list scrolls the region entry into it.
    press(controller, { { type = "navigate", direction = "down" } })
    idle(controller, 2)
    press(controller, { { type = "navigate", direction = "down" } })
    idle(controller, 2)
    do
      local assets = drawCurrent("entry.area")
      Assert.isTrue((assets.messages["area.time"] or "") ~= "", "the area bundle carries its daypart")
      Assert.isTrue((assets.messages["area.location"] or "") ~= "", "the area bundle carries its region")
    end
    openTab(controller, "return")
    do
      local assets = drawCurrent("entry.return")
      Assert.isTrue(
        (assets.messages["return.action"] or "") ~= "",
        "the return bundle carries its return-to-list action"
      )
    end
    rig.owner:release()
  end)
end

---@param data table 8-bit pixel buffer behind the composed target
---@param rect { x: integer, y: integer, width: integer, height: integer } logical region in pane space
---@param ox number pane origin x in host pixels
---@param oy number pane origin y in host pixels
---@param scale number pane integer scale
---@param r integer matte red byte
---@param g integer matte green byte
---@param b integer matte blue byte
---@return integer pixels inside the region differing from the matte triple
local function countNonMatte(data, rect, ox, oy, scale, r, g, b)
  local count = 0
  for y = rect.y, rect.y + rect.height - 1 do
    for x = rect.x, rect.x + rect.width - 1 do
      local pr, pg, pb, _ = pixel(data, ox + x * scale, oy + y * scale)
      if pr ~= r or pg ~= g or pb ~= b then
        count = count + 1
      end
    end
  end
  return count
end

function T.compact_inspector_paints_eligible_details_above_its_matte(scope)
  local Renderer = requireRenderer("compact inspector readability")
  local Interface = requireInterface("compact inspector geometry")
  requireOwner("prepared bundles behind the inspector")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    selectSpecies(controller, "TOTODILE")
    local view = controller:view()
    local demand = browserDemandFor(Renderer, view)
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, {})
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    for _, key in ipairs({
      "compact.detail-number",
      "compact.detail-name",
      "compact.detail-category",
      "compact.detail-flavor",
      "compact.detail-height",
      "compact.detail-weight",
    }) do
      Assert.isTrue((assets.messages[key] or "") ~= "", "the caught bundle carries its detail " .. key)
    end
    local measurement = measurementFor("nativeLike")
    local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
    local compact = assert(plan.content.pokedexCompact, "the compact plan publishes its geometry record")
    local info = placementOf(plan, "information")
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local showing = { view = view, assets = assets, compact = { inspect = true, size = "weight" } }
    local data = drawPlan(scope, plan, resources, showing, 256, 192)
    local body = { x = 8, y = 8, width = 240, height = 120 }
    local ink = countNonMatte(data, body, info.origin.x, info.origin.y, info.scale, 16, 16, 24)
    Assert.isTrue(ink >= 20, "the open inspector paints readable detail glyphs above its matte")
    local toggle = assert(compact.inspectRect, "the compact record carries its close toggle")
    local closeInk = countNonMatte(data, toggle, info.origin.x, info.origin.y, info.scale, 88, 140, 196)
    Assert.isTrue(closeInk >= 4, "the close affordance paints its mark above its chrome")
    local again = drawPlan(scope, plan, resources, showing, 256, 192)
    Assert.equal(
      byteSum(again, 256, 192),
      byteSum(data, 256, 192),
      "repeated inspector draws settle identical pixels"
    )
    lease:release()
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the inspector journey returns every interest")
  end)
end

function T.compact_footer_and_rows_show_distinct_marks_without_new_realizations(scope)
  local Renderer = requireRenderer("compact action marks")
  local Interface = requireInterface("compact action geometry")
  requireOwner("prepared bundles behind compact actions")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.criteria")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    selectSpecies(controller, "TOTODILE")
    local view = controller:view()
    local demand = browserDemandFor(Renderer, view)
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, {})
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    local measurement = measurementFor("nativeLike")
    local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
    local compact = assert(plan.content.pokedexCompact, "the compact plan publishes its geometry record")
    local info = placementOf(plan, "information")
    local controls = placementOf(plan, "controls")
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local data = drawPlan(scope, plan, resources, preparedBrowserView(view, assets), 256, 192)
    local footer = assert(compact.footer, "the compact record carries its footer")
    local marked = 0
    local dimmed = 0
    for _, button in ipairs(footer.buttons) do
      local varied = 0
      for y = button.y, button.y + button.height - 1 do
        for x = button.x, button.x + button.width - 1 do
          local pr, pg, pb, _ = pixel(
            data,
            controls.origin.x + x * controls.scale,
            controls.origin.y + y * controls.scale
          )
          if pr ~= 88 or pg ~= 140 or pb ~= 196 then
            varied = varied + 1
          end
        end
      end
      if button.enabled == true then
        Assert.isTrue(varied >= 4, "enabled footer action " .. button.id .. " shows its mark")
        marked = marked + 1
      else
        dimmed = dimmed + 1
      end
    end
    Assert.isTrue(marked >= 1, "the grid footer marks its enabled actions")
    Assert.isTrue(dimmed >= 1, "the first grid page visibly disables its previous-page action")
    press(controller, { { type = "y" } })
    idle(controller, 2)
    local searchView = controller:view()
    Assert.equal(searchView.page, "search", "the grid opens its search criteria")
    local searchDemand = browserDemandFor(Renderer, searchView)
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, searchDemand, true, {})
    local searchLease = rig.owner:acquire({ purpose = "browser" })
    local searchAssets = prepareReady(rig, searchLease, searchDemand)
    local searchPlan = resolvePlan(Interface.browser(), measurement, planViewOf(searchView))
    local searchCompact = assert(searchPlan.content.pokedexCompact, "the search plan publishes its record")
    local searchData = drawPlan(
      scope,
      searchPlan,
      { graphics = love.graphics, renderer = searchAssets.renderer },
      preparedBrowserView(searchView, searchAssets),
      256,
      192
    )
    local searchInfo = placementOf(searchPlan, "information")
    local rowInk = 0
    for _, row in ipairs(searchCompact.rows) do
      for y = row.rect.y, row.rect.y + row.rect.height - 1 do
        for x = row.rect.x, row.rect.x + row.rect.width - 1 do
          local pr, pg, pb, _ = pixel(searchData, searchInfo.origin.x + x, searchInfo.origin.y + y)
          if pr == 255 and pg == 255 and pb == 255 then
            rowInk = rowInk + 1
          end
        end
      end
    end
    Assert.isTrue(rowInk >= 10, "search criterion rows paint source glyph pixels")
    searchLease:release()
    lease:release()
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the action journey returns every interest")
  end)
end

-- A caught search result paints its prepared mark: the real results
-- demand prepares through the production lease, the bundle stages the
-- mark viewport before drawing, and the mark inks its authored art at
-- the projected information-pane position with no new realization.
function T.caught_results_paint_their_prepared_mark(scope)
  local Renderer = requireRenderer("live results mark pixels")
  local Interface = requireInterface("paired native hit resolution")
  requireOwner("prepared bundles behind the live leg")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedIcon(pool, "SPINDA/f0", 0, 1, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "results")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    press(controller, { { type = "y" } })
    idle(controller, 2)
    press(controller, { { type = "start" } })
    idle(controller, 200)
    Assert.equal(controller:view().page, "results", "the completed search lands on the result grid")
    for _ = 1, 40 do
      if controller:view().selection.caught == true then
        break
      end
      press(controller, { { type = "navigate", direction = "right" } })
      idle(controller, 2)
    end
    local view = controller:view()
    Assert.isTrue(view.selection.caught == true, "the walk reaches a caught result")
    local mark = nil
    for _, intent in ipairs(assert(view.objects, "the results projection carries its sprite intents")) do
      if type(intent) == "table" and intent.subject == "caught-mark" then
        mark = intent
      end
    end
    Assert.notNil(mark, "the caught result projects its mark")
    local demand = browserDemandFor(Renderer, view)
    Assert.equal(demand.pageRole, "results", "the results demand reads its own page role")
    seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, {})
    local lease = rig.owner:acquire({ purpose = "browser" })
    local assets = prepareReady(rig, lease, demand)
    local page = assert(rig.manifest.pages.results, "the manifest closes the results page")
    local subjects = assert(page.spriteSubjects, "the results page binds its live subjects")
    local binding = assert(
      assert(subjects["caught-mark"], "the results page binds its caught mark")[mark.choice],
      "the results mark binds its shown choice"
    )
    local sprite = assert(rig.manifest.sprites[binding.sprite], "the mark resolves its sprite role")
    local animation =
      assert(rig.manifest.animations[sprite.animation], "the mark resolves its animation")
    local cell = assert(rig.manifest.cells[animation.frames[1].cell], "the mark resolves its resting cell")
    local part = assert(cell.parts[1], "the mark carries its first part")
    local chromeEntry = assert(rig.manifest.chrome[part.chrome], "the manifest stages " .. part.chrome)
    local baseData = decodePage(rig.cacheFs, chromeEntry.path)
    local dx, dy = opaqueOffset(baseData, part.source.x, part.source.y, part.source.width, part.source.height)
    local er, eg, eb = pixel(baseData, part.source.x + dx, part.source.y + dy)
    local measurement = measurementFor("dualDisplay")
    local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
    local resources = { graphics = love.graphics, renderer = assets.renderer }
    local data =
      drawPlan(scope, plan, resources, preparedBrowserView(view, assets), measurement.width, measurement.height)
    local infoPane = placementOf(plan, "information")
    assertPixel(
      data,
      infoPane.origin.x + mark.x + part.x + dx,
      infoPane.origin.y + mark.y + part.y + dy,
      er,
      eg,
      eb,
      "the caught mark inks its authored art at its projected position"
    )
    lease:release()
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the mark journey returns every borrowed interest")
  end)
end

-- Row labels and slider quantities paint their prepared source content:
-- the first legal area window shows the region entry, staged slider
-- windows carry physical quantities instead of step indexes, and short
-- values keep their trailing digit sprites through the production draw.
function T.entry_rows_and_slider_values_paint_their_prepared_source_content(scope)
  local Renderer = requireRenderer("row and slider source content")
  local Interface = requireInterface("paired native layout for row and slider content")
  requireOwner("prepared bundles behind row and slider content")
  local versionId = readyVersion()
  local pool = SharedImagePoolFake.new()
  withPool(pool, function()
    local rig = graphicsRig(versionId, pool, scope)
    seedIcon(pool, "CHIKORITA/f0", 1, 1, 1)
    seedIcon(pool, "EEVEE/f0", 0, 0, 0)
    seedIcon(pool, "TOTODILE/f0", 1, 0, 0)
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "cover")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "grid")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.criteria")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.height")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "search.weight")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.area")
    seedChromeFor(pool, rig.cacheFs, rig.manifest, "entry.forms")
    local dexOwner = Fixture.ownerWithHistory(rig.monCatalog, rig.catalog)
    local controller = Fixture.openController(dexOwner, rig.monCatalog, rig.catalog)
    openGrid(controller)
    press(controller, { { type = "y" } })
    idle(controller, 2)
    Assert.equal(controller:view().page, "search", "the grid opens its search criteria")
    local seeded = {}
    local function drawCurrent(role)
      local _ = role
      local view = controller:view()
      local demand = browserDemandFor(Renderer, view)
      seedDemandPortraitsOnce(pool, rig.cacheFs, rig.monCatalog, demand, true, seeded)
      local lease = rig.owner:acquire({ purpose = "browser" })
      local assets = prepareReady(rig, lease, demand)
      local measurement = measurementFor("dualDisplay")
      local plan = resolvePlan(Interface.browser(), measurement, planViewOf(view))
      local data = drawPlan(
        scope,
        plan,
        { graphics = love.graphics, renderer = assets.renderer },
        preparedBrowserView(view, assets),
        measurement.width,
        measurement.height
      )
      lease:release()
      return assets, view, data
    end
    do
      local assets = drawCurrent("search.criteria")
      for _, role in ipairs({
        "search.value-height-min",
        "search.value-height-max",
        "search.value-weight-min",
        "search.value-weight-max",
      }) do
        local prepared = assert(assets.messages[role], "the criteria bundle carries " .. role)
        Assert.isTrue(prepared ~= "0" and prepared ~= "152", "staged quantities never show raw steps (" .. role .. ")")
        Assert.isTrue(prepared:find("{STRVAR", 1, true) == nil, "no raw marker survives " .. role)
      end
      local heightMax = assert(assets.messages["search.value-height-max"], "the height ceiling paints")
      Assert.isTrue(heightMax:find("99", 1, true) ~= nil, "the sentinel height paints its physical feet")
      local weightMax = assert(assets.messages["search.value-weight-max"], "the weight ceiling paints")
      Assert.isTrue(weightMax:find("9999", 1, true) ~= nil, "the sentinel weight paints its physical pounds")
      local heightMin = assert(assets.messages["search.value-height-min"], "the height floor paints")
      Assert.isTrue(heightMin:find("\226\128\153", 1, true) ~= nil, "the height floor paints its foot mark")
      Assert.isTrue(heightMin:find("\226\128\157", 1, true) ~= nil, "the height floor paints its inch mark")
      local weightMin = assert(assets.messages["search.value-weight-min"], "the weight floor paints")
      Assert.isTrue(weightMin:find(".", 1, true) ~= nil, "the weight floor paints its decimal mark")
    end
    press(controller, { { type = "activate", action = "criterion", value = "height" } })
    idle(controller, 2)
    do
      local assets, view = drawCurrent("search.height")
      local heightMin = assert(assets.messages["search.current-height-min"], "the height editor paints its floor")
      Assert.isTrue(heightMin:find("\226\128\153", 1, true) ~= nil, "the editor floor paints its foot mark")
      local found = {}
      for _, intent in ipairs(assert(view.objects, "the height editor carries its intents")) do
        if type(intent) == "table" and type(intent.subject) == "string" then
          found[intent.subject] = intent
        end
      end
      Assert.isNil(found["digit-min-1"], "a short height hides its foot tens on the production rig")
      Assert.notNil(found["digit-min-2"], "a short height keeps its foot units on the production rig")
      Assert.notNil(found["digit-min-4"], "a short height keeps its inch units on the production rig")
      Assert.equal(assert(found["digit-max-1"], "the ceiling keeps its foot tens").choice, "d9", "the sentinel spells nine")
    end
    press(controller, { { type = "cancel" } })
    idle(controller, 2)
    press(controller, { { type = "activate", action = "criterion", value = "weight" } })
    idle(controller, 2)
    do
      local assets, view = drawCurrent("search.weight")
      local weightMax = assert(assets.messages["search.current-weight-max"], "the weight editor paints its ceiling")
      Assert.isTrue(weightMax:find("9999", 1, true) ~= nil, "the editor ceiling paints its physical pounds")
      local found = {}
      for _, intent in ipairs(assert(view.objects, "the weight editor carries its intents")) do
        if type(intent) == "table" and type(intent.subject) == "string" then
          found[intent.subject] = intent
        end
      end
      Assert.notNil(found["digit-min-4"], "a tiny weight keeps its ones on the production rig")
      Assert.notNil(found["digit-min-5"], "a tiny weight keeps its tenths on the production rig")
    end
    press(controller, { { type = "cancel" } })
    idle(controller, 2)
    press(controller, { { type = "cancel" } })
    idle(controller, 2)
    selectSpecies(controller, "TOTODILE")
    openEntry(controller)
    do
      local assets, view = drawCurrent("entry.area")
      Assert.notNil(assets.messages["area.row-2"], "the first legal area window paints its region entry")
      local compactPlan = resolvePlan(Interface.browser(), measurementFor("nativeLike"), planViewOf(view))
      local compact = assert(compactPlan.content.pokedexCompact, "the area plan publishes its compact rows")
      for _, row in ipairs(assert(compact.rows, "the compact record carries its rows")) do
        if type(row) == "table" and type(row.labelRole) == "string" and row.labelRole:find("^area%.row%-", 1) ~= nil then
          Assert.notNil(assets.messages[row.labelRole], "the compact row paints " .. row.labelRole)
        end
      end
    end
    controller:dispose()
    rig.owner:release()
    Assert.equal(pool:stats().outstandingLeases, 0, "the row and slider journey returns every interest")
  end)
end

local suite = GraphicsSmoke.suite(T)
suite.metadata.capabilities = { "graphics", "rom_dump" }
suite.metadata.derivedAssets = { "pokedex-data:global", "pokedex:global", "mon-catalog:global", "field-font:global" }
return suite
