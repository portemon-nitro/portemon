-- The Naming Screen renderer owns player presentation from the generated
-- manifest and delegates only non-player subjects to its host: one recording
-- callback proves the seam carries Pokemon subjects while player snapshots
-- never reach it.

local Assert = require("tests.support.Assert")
local NamingScreenRenderer = require("libs.hgss.src.ui.NamingScreenRenderer")
local FieldUiFixture = require("tests.support.FieldUiFixture")

local T = { tests = {} }

local function namingManifest(nonVanillaAnchors)
  local manifest = FieldUiFixture.namingSemanticsManifest()
  local naming = manifest.namingScreen
  naming.pokemonSubject.frames[1].parts = { { iconFrame = 1, offset = { x = -3, y = 4 } } }
  naming.pokemonSubject.frames[2].parts = { { iconFrame = 1, offset = { x = 6, y = -7 } } }
  if nonVanillaAnchors then
    naming.pokemonSubject.anchor = { x = -12, y = 5 }
    naming.pokemonGenderMarkers.anchor = { x = 301, y = -9 }
  end
  return manifest
end

local function imageLoader()
  local seen = { loads = {} }
  local loader = function(path)
    seen.loads[#seen.loads + 1] = path
    return { path = path, release = function() end, setFilter = function() end }
  end
  return loader, seen
end

local function graphicsFake()
  local calls = { push = 0, pop = 0, scaled = 0, draws = {} }
  local graphics = {
    push = function()
      calls.push = calls.push + 1
    end,
    pop = function()
      calls.pop = calls.pop + 1
    end,
    translate = function() end,
    scale = function()
      calls.scaled = calls.scaled + 1
    end,
    setColor = function() end,
    rectangle = function() end,
    newQuad = function(x, y, w, h, imgW, imgH)
      return { x = x, y = y, w = w, h = h, imgW = imgW, imgH = imgH }
    end,
    draw = function(image, quad, x, y)
      if type(quad) == "number" then
        quad, x, y = nil, quad, x
      end
      calls.draws[#calls.draws + 1] = { image = image, quad = quad, x = x, y = y }
    end,
  }
  return graphics, calls
end

local function textFake()
  return {
    drawText = function() end,
    textWidth = function(value)
      return #value * 8
    end,
  }
end

local function canonicalLayout()
  local cells = {}
  for row = 1, 6 do
    cells[row] = {}
    for column = 1, 13 do
      cells[row][column] = { x = 28 + (column - 1) * 16, y = 88 + (row - 2) * 19, width = 17, height = 20 }
    end
  end
  return {
    surface = { x = 0, y = 0, width = 256, height = 192 },
    nameSlots = { x = 32, y = 22, width = 192, height = 24 },
    subject = { x = 8, y = 8, width = 48, height = 42 },
    keyboard = { x = 8, y = 58, width = 240, height = 106 },
    cells = cells,
    controls = {
      upper = { x = 25, y = 60, width = 32, height = 23 },
      lower = { x = 57, y = 60, width = 32, height = 23 },
      symbols = { x = 89, y = 60, width = 32, height = 23 },
      back = { x = 157, y = 60, width = 33, height = 23 },
      ok = { x = 197, y = 60, width = 33, height = 23 },
    },
  }
end

local function snapshot(subject, presentation)
  local grid = {}
  for row = 1, 6 do
    grid[row] = {}
    for column = 1, 13 do
      grid[row][column] = { kind = "glyph", glyph = "A" }
    end
  end
  return {
    kind = subject.kind,
    page = "upper",
    cursor = { row = 2, column = 1 },
    text = "",
    maxLength = 7,
    grid = grid,
    subject = subject,
    presentation = presentation or { subjectTick = 0, cursorTick = 0, entrySlotTick = 0, glowAngle = 180 },
  }
end

function T.tests.player_subjects_render_from_the_manifest_while_pokemon_delegates()
  local graphics, calls = graphicsFake()
  local manifest = namingManifest(true)
  local seen = {}
  local loader, loaded = imageLoader()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function(hostGraphics, subject, placement)
      seen[#seen + 1] = { graphics = hostGraphics, subject = subject, placement = placement }
    end,
    manifest = manifest,
    imageLoader = loader,
  })
  for _, gender in ipairs({ "male", "female" }) do
    local marker = manifest.namingScreen.pokemonGenderMarkers[gender]
    local markerPath = manifest.assets[marker.frames[1].asset].image
    local acquisitions = 0
    for _, path in ipairs(loaded.loads) do
      if path == markerPath then
        acquisitions = acquisitions + 1
      end
    end
    Assert.equal(acquisitions, 1, gender .. " marker atlas is acquired once despite its repeated frames")
  end
  local layout = canonicalLayout()
  local playerSubject = { kind = "player", gender = 1 }
  renderer:draw(snapshot(playerSubject), layout)
  Assert.equal(#seen, 0, "a player subject never reaches the host callback")
  local female = manifest.namingScreen.playerSubjects.female
  local femaleFrame = female.frames[1]
  local femalePath = manifest.assets[femaleFrame.asset].image
  local femaleDraws = {}
  for _, draw in ipairs(calls.draws) do
    if draw.image.path == femalePath then
      femaleDraws[#femaleDraws + 1] = draw
    end
  end
  Assert.equal(#femaleDraws, 1, "the female player subject draws its manifest visual once")
  Assert.deepEqual({ x = femaleDraws[1].x, y = femaleDraws[1].y }, {
    x = female.anchor.x + femaleFrame.offset.x,
    y = female.anchor.y + femaleFrame.offset.y,
  })
  local pokemonSubject = { kind = "pokemon", species = 25, form = 0, gender = "male" }
  renderer:draw(snapshot(pokemonSubject), layout)
  Assert.equal(#seen, 1, "the visible semantic Pokemon part draws through the host callback")
  Assert.deepEqual(seen[1].subject, pokemonSubject)
  Assert.deepEqual(seen[1].placement, { x = -15, y = 9, frameIndex = 1 })
  renderer:draw(
    snapshot(pokemonSubject, { subjectTick = 20, cursorTick = 0, entrySlotTick = 0, glowAngle = 180 }),
    layout
  )
  Assert.equal(#seen, 2, "the animated Pokemon subject continues to draw one semantic part")
  Assert.deepEqual(seen[2].placement, { x = -6, y = -2, frameIndex = 1 }, "semantic placement follows its tick")

  local markers = manifest.namingScreen.pokemonGenderMarkers
  local function assertMarkerUsesAnchor(draws, record)
    for _, draw in ipairs(draws) do
      local matchesFrame = false
      for _, frame in ipairs(record.frames) do
        if
          draw.x == math.floor(markers.anchor.x + frame.offset.x + 0.5)
          and draw.y == math.floor(markers.anchor.y + frame.offset.y + 0.5)
        then
          matchesFrame = true
          break
        end
      end
      Assert.isTrue(matchesFrame, "the marker uses its semantic anchor and generated frame offset")
    end
  end
  local function drawsFor(record)
    local path = manifest.assets[record.frames[1].asset].image
    local draws = {}
    for _, draw in ipairs(calls.draws) do
      if draw.image.path == path then
        draws[#draws + 1] = { x = draw.x, y = draw.y }
      end
    end
    return draws
  end
  local maleMarkerDraws = drawsFor(markers.male)
  Assert.equal(#maleMarkerDraws, 2, "male subject frames draw the generated male marker")
  assertMarkerUsesAnchor(maleMarkerDraws, markers.male)
  Assert.equal(#drawsFor(markers.female), 0, "male subjects do not draw the female marker")
  local femaleSubject = { kind = "pokemon", species = 25, form = 0, gender = "female" }
  renderer:draw(snapshot(femaleSubject), layout)
  local femaleMarkerDraws = drawsFor(markers.female)
  Assert.equal(#femaleMarkerDraws, 1, "female subjects draw the generated female marker")
  assertMarkerUsesAnchor(femaleMarkerDraws, markers.female)
  local genderlessSubject = { kind = "pokemon", species = 25, form = 0, gender = "genderless" }
  renderer:draw(snapshot(genderlessSubject), layout)
  Assert.equal(#drawsFor(markers.male), 2, "genderless subjects do not draw a gender marker")
  Assert.equal(#drawsFor(markers.female), 1, "genderless subjects do not draw a gender marker")
  Assert.equal(calls.push, calls.pop)
  Assert.equal(calls.scaled, 0)
  renderer:dispose()
end

function T.tests.pokemon_subject_animation_accepts_one_semantic_part_per_frame()
  local graphics = graphicsFake()
  local loader = imageLoader()
  local renderer = NamingScreenRenderer.new({
    graphics = graphics,
    text = textFake(),
    drawSubject = function() end,
    manifest = namingManifest(),
    imageLoader = loader,
  })
  renderer:dispose()
end

function T.tests.subject_callback_is_a_required_constructor_collaborator()
  local graphics = graphicsFake()
  Assert.throws(function()
    NamingScreenRenderer.new({ graphics = graphics, text = textFake() })
  end, "a renderer without its host subject callback must fail at construction")
end

return T
