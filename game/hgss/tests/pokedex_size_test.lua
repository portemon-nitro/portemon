-- Height presentation and the fixed weight recurrence: all seventeen
-- classes in both heavier-side directions, both trainer genders, drop
-- timing, tilt/throw/landing/escape traces, restarts, and the private
-- quantized trigonometry. Real knowledge owner and compact synthetic
-- catalogs with pinned measurement rows; only readiness is stubbed. No
-- renderer, GPU, audio device, ROM, or worker is touched.

local Assert = require("tests.support.Assert")
local PokedexDexFixture = require("libs.hgss.tests.mons.pokedex_dex_fixture")
local PokedexKnowledge = require("libs.hgss.src.mons.PokedexKnowledge")

local CONTROLLER_MODULE = "game.hgss.src.pokedex.PokedexController"

local T = {}

---@param behavior string missing browser behavior under test
---@return table the loaded browser controller owner
local function requirePresent(behavior)
  local ok, loaded = pcall(require, CONTROLLER_MODULE)
  Assert.isTrue(ok, "missing browser state owner: " .. behavior .. " (" .. CONTROLLER_MODULE .. ")")
  assert(loaded ~= nil, "the browser module loads")
  return loaded --[[@as table]]
end

---@param angle integer source sixteen-bit angle
---@return integer sine scaled by 4096
---@return integer cosine scaled by 4096
local function quantizedTrig(angle)
  local reduced = angle % 65536
  local index = math.floor(reduced / 16)
  local theta = 2 * math.pi * index / 4096
  local function quantize(value)
    local scaled = value * 4096
    if scaled >= 0 then
      return math.floor(scaled + 0.5)
    end
    return -math.floor(-scaled + 0.5)
  end
  return quantize(math.sin(theta)), quantize(math.cos(theta))
end

local function catalogs()
  local monCatalog = PokedexDexFixture.makeCatalog()
  local catalog = PokedexDexFixture.buildPokedexCatalog()
  return monCatalog, catalog
end

---@param catalog table generated catalog under test ownership
---@param weightHg integer weight to pin for the fixture species
local function pinEeveeWeight(catalog, weightHg)
  catalog.measurementProfiles.base.measurements["EEVEE"].weightHg = weightHg
end

local function enabledOwner(monCatalog, catalog)
  local owner = PokedexKnowledge.new(PokedexDexFixture.refs(monCatalog, catalog))
  owner:prepareChanges({ flags = { dexEnabled = true, nationalDex = true } }):publish()
  return owner
end

---@param owner table knowledge owner under test
---@param monCatalog table resolved mon catalog
---@param species string species to record as caught
---@param personality integer pinned personality
---@param form integer|nil physical form
local function catch(owner, monCatalog, species, personality, form)
  local specimen = owner:describe(PokedexDexFixture.makeMon(monCatalog, {
    species = species,
    personality = personality,
    form = form or 0,
  }))
  owner:prepareChanges({ observations = { { kind = "caught", specimen = specimen } } }):publish()
end

local function newBrowser(PokedexController, owner, monCatalog, catalog, playerGender)
  return PokedexController.new({
    catalog = catalog,
    monCatalog = monCatalog,
    dex = owner,
    playerGender = playerGender or "male",
    playerPosition = { mapX = 10, mapY = 10 },
    nativeLanguage = "english",
  })
end

---@param controller table browser under test
---@return table preparation carrying the currently demanded ready key
local function readyPrep(controller)
  return { readyKey = controller:view().key }
end

---@param controller table browser under test
---@param events table|nil semantic batch for one fixed update
local function tick(controller, events)
  controller:updateFixed(events or {}, readyPrep(controller))
end

---@param controller table browser under test
---@param count integer fixed updates to advance with no input
local function idle(controller, count)
  for _ = 1, count do
    tick(controller)
  end
end

---@param controller table browser under test
local function openSize(controller)
  tick(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "grid", "cover confirm opens the grid before the entry")
  tick(controller, { { type = "confirm" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "area", "the entry opens on its area page")
  tick(controller, { { type = "activate", action = "entry-tab", value = "size" } })
  idle(controller, 40)
  Assert.equal(controller:view().page, "size", "the entry tab reaches the size page")
end

---@param controller table browser under test
---@return table weight projection snapshot
local function weightOf(controller)
  return controller:view().size.weight
end

---@param controller table browser under test
---@param seen integer[] beam angles sampled so far
local function sampleAngle(controller, seen)
  seen[#seen + 1] = weightOf(controller).beamAngle
end

local CLASS_DELTAS = { 0, 1, 2, 3, 4, 5, 6, 7, 10, 20, 40, 60, 90, 130, 200, 300, 400 }
local CLASS_SOUNDS = {
  "SEQ_SE_GS_ZUKAN01",
  "SEQ_SE_GS_ZUKAN01",
  "SEQ_SE_GS_ZUKAN01",
  "SEQ_SE_GS_ZUKAN01",
  "SEQ_SE_GS_ZUKAN01",
  "SEQ_SE_GS_ZUKAN01",
  "SEQ_SE_GS_ZUKAN01",
  "SEQ_SE_GS_ZUKAN01",
  "SEQ_SE_GS_ZUKAN01",
  "SEQ_SE_GS_ZUKAN02",
  "SEQ_SE_GS_ZUKAN02",
  "SEQ_SE_GS_ZUKAN02",
  "SEQ_SE_GS_ZUKAN03",
  "SEQ_SE_GS_ZUKAN03",
  "SEQ_SE_GS_ZUKAN03",
  "SEQ_SE_GS_ZUKAN03",
  "SEQ_SE_GS_ZUKAN04",
}

---@param controller table browser under test
---@param limit integer bounded updates before giving up
---@return integer[] sampled beam angles
local function runUntilSettled(controller, limit)
  local angles = {}
  for _ = 1, limit do
    tick(controller)
    sampleAngle(controller, angles)
  end
  return angles
end

function T.quantized_trigonometry_matches_every_pinned_anchor()
  requirePresent("numeric size traces and authored height presentation")
  local anchors = {
    { angle = 0, sin = 0, cos = 4096 },
    { angle = 0x100, sin = 101, cos = 4095 },
    { angle = 0xA00, sin = 995, cos = 3973 },
    { angle = 0x4000, sin = 4096, cos = 0 },
    { angle = 0x8000, sin = 0, cos = -4096 },
    { angle = 0xF600, sin = -995, cos = 3973 },
  }
  for _, anchor in ipairs(anchors) do
    local sin, cos = quantizedTrig(anchor.angle)
    Assert.equal(sin, anchor.sin, "sine matches at angle " .. anchor.angle)
    Assert.equal(cos, anchor.cos, "cosine matches at angle " .. anchor.angle)
  end
  local negSin, _ = quantizedTrig(0xF600)
  Assert.equal(negSin, -995, "negative products floor away from zero, never truncate")
end

function T.every_class_runs_thirty_drops_then_its_sound()
  local PokedexController = requirePresent("numeric size traces and authored height presentation")
  for class = 0, 16 do
    local monCatalog, catalog = catalogs()
    pinEeveeWeight(catalog, 400 + CLASS_DELTAS[class + 1])
    local owner = enabledOwner(monCatalog, catalog)
    catch(owner, monCatalog, "EEVEE", 31)
    local controller = newBrowser(PokedexController, owner, monCatalog, catalog, "male")
    openSize(controller)
    Assert.equal(#controller:view().size.figures, 2, "the weight motion runs exactly two figures")
    local dropMoves = 0
    local previousFx = 0
    for _ = 1, 200 do
      tick(controller)
      local fx = weightOf(controller).dropVelocity
      if fx ~= previousFx then
        Assert.equal(fx, previousFx + 0x400, "class " .. class .. " accumulates the authored drop step")
        previousFx = fx
        dropMoves = dropMoves + 1
      end
      if weightOf(controller).beamAngle ~= 0 then
        break
      end
    end
    Assert.equal(dropMoves, 30, "class " .. class .. " runs exactly thirty drop movement updates")
    Assert.equal(previousFx, 30 * 0x400, "class " .. class .. " rests at the full drop velocity")
    for _, figure in ipairs(controller:view().size.figures) do
      Assert.equal(figure.y, 88, "class " .. class .. " clamps every figure at the beam")
    end
    Assert.equal(weightOf(controller).class, class, "class " .. class .. " resolves from its difference bucket")
    local sounded = false
    for _, effect in ipairs(controller:drainEffects()) do
      if effect.kind == "sound" and effect.role == CLASS_SOUNDS[class + 1] then
        sounded = true
      end
    end
    Assert.isTrue(sounded, "class " .. class .. " plays its authored sound")
    controller:dispose()
  end
end

function T.heavier_side_mirrors_small_tilts_and_clamps_large_ones()
  local PokedexController = requirePresent("numeric size traces and authored height presentation")
  local traces = {}
  for _, sign in ipairs({ 1, -1 }) do
    local monCatalog, catalog = catalogs()
    pinEeveeWeight(catalog, 400 + sign * 3)
    local owner = enabledOwner(monCatalog, catalog)
    catch(owner, monCatalog, "EEVEE", 31)
    local controller = newBrowser(PokedexController, owner, monCatalog, catalog, "male")
    openSize(controller)
    traces[sign] = runUntilSettled(controller, 120)
    controller:dispose()
  end
  Assert.equal(#traces[1], #traces[-1], "both heavier-side directions run the same update count")
  for index, angle in ipairs(traces[1]) do
    Assert.equal(angle, -traces[-1][index], "small tilts mirror by the actual heavier side")
  end
  local final = traces[1][#traces[1]]
  Assert.isTrue(final ~= 0, "a decided tilt never snaps back to horizontal")
  local steady = true
  for index = #traces[1] - 9, #traces[1] do
    if traces[1][index] ~= final then
      steady = false
    end
  end
  Assert.isTrue(steady, "a small tilt stops once its speed reaches the terminal value")
  local wide = {}
  for _, sign in ipairs({ 1, -1 }) do
    local monCatalog, catalog = catalogs()
    pinEeveeWeight(catalog, 400 + sign * 200)
    local owner = enabledOwner(monCatalog, catalog)
    catch(owner, monCatalog, "EEVEE", 31)
    local controller = newBrowser(PokedexController, owner, monCatalog, catalog, "male")
    openSize(controller)
    wide[sign] = runUntilSettled(controller, 120)
    controller:dispose()
  end
  local peak = 0
  for _, angle in ipairs(wide[1]) do
    peak = math.max(peak, math.abs(angle))
  end
  Assert.equal(peak, 0x0A00, "large tilts clamp at the authored limit")
  for index, angle in ipairs(wide[1]) do
    Assert.equal(angle, -wide[-1][index], "large tilts mirror by the actual heavier side")
  end
end

function T.thrown_figures_start_on_the_limit_update_and_land_or_escape()
  local PokedexController = requirePresent("numeric size traces and authored height presentation")
  local monCatalog, catalog = catalogs()
  pinEeveeWeight(catalog, 400 + 40)
  local owner = enabledOwner(monCatalog, catalog)
  catch(owner, monCatalog, "EEVEE", 31)
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog, "male")
  openSize(controller)
  local limitTick = nil
  local figureAtLimit = nil
  for _ = 1, 200 do
    tick(controller)
    if math.abs(weightOf(controller).beamAngle) == 0x0A00 then
      limitTick = true
      local ys = {}
      for _, figure in ipairs(controller:view().size.figures) do
        ys[#ys + 1] = figure.y
      end
      figureAtLimit = ys
      break
    end
  end
  Assert.notNil(limitTick, "the beam reaches its limit")
  local moved = false
  for _, y in ipairs(figureAtLimit) do
    if y ~= 88 then
      moved = true
    end
  end
  Assert.isTrue(moved, "the thrown high-side figure moves on the same update the limit is reached")
  local landed = false
  for _ = 1, 400 do
    tick(controller)
    local settled = weightOf(controller)
    local figures = controller:view().size.figures
    local pans = controller:view().size.pans
    for _, figure in ipairs(figures) do
      for _, pan in ipairs(pans) do
        if figure.y == pan.y - 16 and (settled.throwVelocity or 0) >= 0 then
          landed = true
        end
      end
    end
    if landed then
      break
    end
  end
  Assert.isTrue(landed, "an ordinary throw lands its figure at pan height minus sixteen")
  controller:dispose()
  local escapeCatalogs, escapeCatalog = catalogs()
  pinEeveeWeight(escapeCatalog, 400 + 400)
  local escapeOwner = enabledOwner(escapeCatalogs, escapeCatalog)
  catch(escapeOwner, escapeCatalogs, "EEVEE", 31)
  local escape = newBrowser(PokedexController, escapeOwner, escapeCatalogs, escapeCatalog, "male")
  openSize(escape)
  local escaped = false
  for _ = 1, 200 do
    tick(escape)
    local figures = escape:view().size.figures
    local gone = true
    for _, figure in ipairs(figures) do
      if figure.visible ~= false and figure.y > -256 then
        gone = false
      end
    end
    if gone then
      escaped = true
      break
    end
  end
  Assert.isTrue(escaped, "the lightest class escapes upward without a return")
  Assert.equal(escape:view().page, "size", "the escape never leaves the size page")
  escape:dispose()
end

function T.restart_finishes_its_old_motion_before_a_fresh_drop()
  local PokedexController = requirePresent("numeric size traces and authored height presentation")
  local monCatalog, catalog = catalogs()
  pinEeveeWeight(catalog, 400 + 3)
  local owner = enabledOwner(monCatalog, catalog)
  catch(owner, monCatalog, "EEVEE", 31)
  local controller = newBrowser(PokedexController, owner, monCatalog, catalog, "male")
  openSize(controller)
  for _ = 1, 10 do
    tick(controller)
  end
  local underway = false
  for _ = 1, 120 do
    tick(controller)
    if controller:view().size.figures[1].y ~= -16 then
      underway = true
      break
    end
  end
  Assert.isTrue(underway, "the drop is underway before the restart")
  local before = controller:view().size.figures[1].y
  tick(controller, { { type = "activate", action = "size-restart" } })
  local after = controller:view().size.figures[1].y
  Assert.isTrue(after ~= -16, "restart never jumps the figures straight back to their start")
  Assert.isTrue(after >= before, "the old motion step runs before the restart takes effect")
  local reset = false
  for _ = 1, 240 do
    tick(controller)
    if controller:view().size.figures[1].y == -16 and weightOf(controller).beamAngle == 0 then
      reset = true
      break
    end
  end
  Assert.isTrue(reset, "the restart rebuilds into a fresh drop")
  Assert.equal(weightOf(controller).class, 3, "the fresh drop keeps its difference class")
  controller:dispose()
end

function T.height_uses_trainer_gender_records_and_the_giratina_profile()
  local PokedexController = requirePresent("numeric size traces and authored height presentation")
  local monCatalog, catalog = catalogs()
  catalog.measurementProfiles.base.measurements["EEVEE"].yOffset = {
    male = { trainer = 4, mon = 2 },
    female = { trainer = 8, mon = 6 },
  }
  local owner = enabledOwner(monCatalog, catalog)
  catch(owner, monCatalog, "EEVEE", 31)
  local male = newBrowser(PokedexController, owner, monCatalog, catalog, "male")
  openSize(male)
  Assert.equal(male:view().size.height.mon.yOffset, 2, "the male mon height uses its gender record")
  Assert.equal(male:view().size.height.trainer.yOffset, 4, "the male trainer height uses its gender record")
  Assert.keySet(male:view().size.height, "mon,trainer", "the height projection carries no portrait gender slots")
  male:dispose()
  local female = newBrowser(PokedexController, owner, monCatalog, catalog, "female")
  openSize(female)
  Assert.equal(female:view().size.height.mon.yOffset, 6, "the female mon height uses its gender record")
  Assert.equal(female:view().size.height.trainer.yOffset, 8, "the female trainer height uses its gender record")
  female:dispose()
  local originCatalogs, originCatalog = catalogs()
  local originOwner = enabledOwner(originCatalogs, originCatalog)
  catch(originOwner, originCatalogs, "GIRATINA", 31, 1)
  catch(originOwner, originCatalogs, "EEVEE", 31)
  local origin = newBrowser(PokedexController, originOwner, originCatalogs, originCatalog, "male")
  openSize(origin)
  tick(origin, { { type = "cancel" } })
  idle(origin, 40)
  Assert.equal(origin:view().page, "grid", "leaving the first-seen size page returns to the grid")
  do
    local entries = origin:view().grid.buffers[1].entries
    local cursor = origin:view().grid.cursor
    local target = nil
    for index, entry in ipairs(entries) do
      if entry.species == "GIRATINA" then
        target = index - 1
      end
    end
    assert(target ~= nil, "the giratina slot is on the grid")
    local moves = target - cursor
    local direction = moves > 0 and "right" or "left"
    for _ = 1, math.abs(moves) do
      tick(origin, { { type = "navigate", direction = direction } })
    end
  end
  tick(origin, { { type = "confirm" } })
  idle(origin, 40)
  Assert.equal(origin:view().page, "area", "confirming the giratina slot opens its entry")
  tick(origin, { { type = "activate", action = "entry-tab", value = "size" } })
  idle(origin, 40)
  Assert.equal(origin:view().page, "size", "the entry tab reaches the giratina size page")
  Assert.equal(
    origin:view().size.height.mon.dm,
    69,
    "an origin first observation selects the origin profile for the whole open"
  )
  origin:dispose()
  local baseCatalogs, baseCatalog = catalogs()
  local baseOwner = enabledOwner(baseCatalogs, baseCatalog)
  catch(baseOwner, baseCatalogs, "GIRATINA", 31, 0)
  catch(baseOwner, baseCatalogs, "EEVEE", 31)
  local base = newBrowser(PokedexController, baseOwner, baseCatalogs, baseCatalog, "male")
  openSize(base)
  tick(base, { { type = "cancel" } })
  idle(base, 40)
  Assert.equal(base:view().page, "grid", "leaving the first-seen size page returns to the grid")
  do
    local entries = base:view().grid.buffers[1].entries
    local cursor = base:view().grid.cursor
    local target = nil
    for index, entry in ipairs(entries) do
      if entry.species == "GIRATINA" then
        target = index - 1
      end
    end
    assert(target ~= nil, "the giratina slot is on the grid")
    local moves = target - cursor
    local direction = moves > 0 and "right" or "left"
    for _ = 1, math.abs(moves) do
      tick(base, { { type = "navigate", direction = direction } })
    end
  end
  tick(base, { { type = "confirm" } })
  idle(base, 40)
  Assert.equal(base:view().page, "area", "confirming the giratina slot opens its entry")
  tick(base, { { type = "activate", action = "entry-tab", value = "size" } })
  idle(base, 40)
  Assert.equal(base:view().page, "size", "the entry tab reaches the giratina size page")
  Assert.equal(base:view().size.height.mon.dm, 17, "a base first observation keeps the base profile")
  base:dispose()
end

function T.missing_measurement_rows_fail_and_size_stays_caught_only()
  local PokedexController = requirePresent("numeric size traces and authored height presentation")
  local monCatalog, catalog = catalogs()
  catalog.measurementProfiles.base.measurements["EEVEE"] = nil
  catalog.measurementProfiles.giratina_origin.measurements["EEVEE"] = nil
  local owner = enabledOwner(monCatalog, catalog)
  catch(owner, monCatalog, "EEVEE", 31)
  local ok = pcall(function()
    local controller = newBrowser(PokedexController, owner, monCatalog, catalog, "male")
    openSize(controller)
    controller:dispose()
  end)
  Assert.isFalse(ok, "a missing legal measurement row fails instead of inventing data")
  local seenCatalogs, seenCatalog = catalogs()
  local seenOwner = enabledOwner(seenCatalogs, seenCatalog)
  local specimen = seenOwner:describe(PokedexDexFixture.makeMon(seenCatalogs, {
    species = "EEVEE",
    personality = 31,
  }))
  seenOwner:prepareChanges({ observations = { { kind = "seen", specimen = specimen } } }):publish()
  local seenOnly = newBrowser(PokedexController, seenOwner, seenCatalogs, seenCatalog, "male")
  tick(seenOnly, { { type = "confirm" } })
  idle(seenOnly, 40)
  tick(seenOnly, { { type = "activate", action = "entry-tab", value = "size" } })
  idle(seenOnly, 40)
  Assert.equal(seenOnly:view().page, "area", "the size tab stays inert for a seen-only species")
  seenOnly:dispose()
end

return { tests = T }
