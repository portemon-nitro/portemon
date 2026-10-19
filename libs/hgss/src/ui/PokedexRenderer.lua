-- Prepared rasterization for the field Pokedex: the one palette-aware 2D
-- renderer behind both the browser panes and the first-catch
-- registration card. The resource owner constructs it once with the
-- borrowed font0 renderer and the host graphics namespace. Drawing runs a
-- finite six-surface serial compositor: four BG planes, top-OBJ color, and
-- top-OBJ metadata, all owned per live lease, reused serially for each
-- pane, and resolved by one final pane shader that applies BG priority
-- order, the OBJ window rule, the selected blend targets, and the locked
-- fade arithmetic. Drawing samples already prepared handles and never
-- requests, decodes, allocates, or advances time. Software palette fades
-- use original 5-bit interpolation and hardware blends use the locked
-- 6-bit normalization; indexed pages bind their exact palette before any
-- custom shader runs.

local Errors = require("libs.errors.src.Errors")
local ImageSampling = require("libs.nds.src.love.ImageSampling")
local LogicalSurface = require("libs.ui.src.LogicalSurface")

---@class PokedexRenderer
---@field _graphics table<string, unknown>? host graphics namespace, absent on headless preparation seams
---@field _text table<string, unknown>? borrowed font0 text renderer
---@field _shader table<string, unknown>? private composite shader, nil until validated
---@field _shaderFailed string? visible composite failure, raised as a draw-time cause
---@field _released boolean
local PokedexRenderer = {}
PokedexRenderer.__index = PokedexRenderer

-- One finite set of 256x192 RGBA8 scratch surfaces per live lease: four
-- BG planes, top-OBJ color, and top-OBJ metadata. The lease realizes them
-- across separate prepare calls under its one-realization allowance and
-- lends them to every draw through the ready bundle; the renderer never
-- creates a surface per marker, species, page, or animation frame.
PokedexRenderer.SURFACE_WIDTH = 256
PokedexRenderer.SURFACE_HEIGHT = 192
PokedexRenderer.SURFACE_BYTES = 256 * 192 * 4
PokedexRenderer.SURFACE_NAMES = { "bg0", "bg1", "bg2", "bg3", "objColor", "objMeta" }

-- Authored native geometry, in half-open pane pixels.
PokedexRenderer.SELECTED_PICTURE_RECT = { x = 8, y = 32, width = 80, height = 80 }
PokedexRenderer.REGISTRATION_PICTURE_RECT = { x = 88, y = 32, width = 80, height = 80 }
PokedexRenderer.FORMS_FRONT_RECT = { x = 24, y = 80, width = 80, height = 80 }
PokedexRenderer.FORMS_BACK_RECT = { x = 152, y = 80, width = 80, height = 80 }
PokedexRenderer.COMPARE_LEFT_RECT = { x = 24, y = 24, width = 80, height = 80 }
PokedexRenderer.COMPARE_RIGHT_RECT = { x = 152, y = 24, width = 80, height = 80 }
PokedexRenderer.ICON_SLOT_SIZE = 32
PokedexRenderer.ICON_GRID_ORIGIN = { x = 48, y = 24 }
PokedexRenderer.ICON_GRID_STEP = { x = 40, y = 40 }
PokedexRenderer.ICON_GRID_COLUMNS = 5
PokedexRenderer.ICON_SLOTS = 15
PokedexRenderer.CURSOR_SIZE = 48
-- The locked source footer window on the information pane: BG stays
-- allowed inside while OBJ is excluded inside; the right edge keeps its
-- hardware inclusive convention and every other plane stays allowed
-- outside.
PokedexRenderer.INFORMATION_WINDOW = { left = 0, top = 152, right = 255, bottom = 192 }
-- Seen-only icons blend against eligible BG with these locked
-- coefficients, independent of the pane blend table.
PokedexRenderer.SEEN_BLEND_EVA = 6
PokedexRenderer.SEEN_BLEND_EVB = 10
-- OBJ template priority carried in the metadata surface: pictures and
-- icons resolve in front of every BG plane and win ties against BG.
PokedexRenderer.OBJ_PRIORITY = 0

-- The final pane shader. It samples the six serial surfaces at the pane
-- UV, resolves BG ties by (priority, original layer order), compares the
-- winning OBJ subject to the footer window rule, then applies only the
-- source-selected second target with the locked 5-bit/6-bit arithmetic.
-- BG fades target the winning BG or backdrop pixel, OBJ fades target the
-- winning OBJ pixel; a zero coefficient disables its fade. The carrier
-- draw texture is ignored: every read comes from the six uniform
-- surfaces.
local COMPOSITE_SHADER = [[
uniform Image u_bg0;
uniform Image u_bg1;
uniform Image u_bg2;
uniform Image u_bg3;
uniform Image u_obj;
uniform Image u_meta;
uniform vec3 u_backdrop;
uniform vec4 u_bgPriority;
uniform float u_firstBits;
uniform float u_secondBits;
uniform vec2 u_blend;
uniform vec3 u_bgFadeTarget;
uniform float u_bgFadeCoeff;
uniform vec3 u_objFadeTarget;
uniform float u_objFadeCoeff;
uniform vec4 u_winRect;
uniform float u_winActive;

float channel5(float unit) {
  return floor(unit * 31.0 + 0.5);
}

float encodeE5(float c5) {
  return floor((255.0 * c5 + 15.0) / 31.0) / 255.0;
}

float encodeE6(float mixed6) {
  float m = min(mixed6, 63.0);
  return min(floor(m * 255.0 / 62.0 + 0.5), 255.0) / 255.0;
}

vec3 fadeColor(vec3 bytes, vec3 target, float coeff) {
  if (coeff <= 0.5) {
    return bytes;
  }
  vec3 faded;
  faded.r = encodeE5(channel5(bytes.r) + floor((channel5(target.r) - channel5(bytes.r)) * coeff / 16.0));
  faded.g = encodeE5(channel5(bytes.g) + floor((channel5(target.g) - channel5(bytes.g)) * coeff / 16.0));
  faded.b = encodeE5(channel5(bytes.b) + floor((channel5(target.b) - channel5(bytes.b)) * coeff / 16.0));
  return faded;
}

vec3 blendPixels(vec3 firstBytes, vec3 secondBytes, float eva, float evb) {
  float a5r = channel5(firstBytes.r);
  float a5g = channel5(firstBytes.g);
  float a5b = channel5(firstBytes.b);
  float b5r = channel5(secondBytes.r);
  float b5g = channel5(secondBytes.g);
  float b5b = channel5(secondBytes.b);
  float r = min(floor((2.0 * a5r * eva + 2.0 * b5r * evb + 8.0) / 16.0), 63.0);
  float g = min(floor((2.0 * a5g * eva + 2.0 * b5g * evb + 8.0) / 16.0), 63.0);
  float b = min(floor((2.0 * a5b * eva + 2.0 * b5b * evb + 8.0) / 16.0), 63.0);
  return vec3(encodeE6(r), encodeE6(g), encodeE6(b));
}

float bitSelected(float bits, float bit) {
  return mod(floor(bits / exp2(bit)), 2.0);
}

vec4 effect(vec4 color, Image tex, vec2 uv, vec2 screenCoords) {
  vec2 pane = vec2(floor(uv.x * 256.0), floor(uv.y * 192.0));
  vec4 layers[4];
  layers[0] = Texel(u_bg0, uv);
  layers[1] = Texel(u_bg1, uv);
  layers[2] = Texel(u_bg2, uv);
  layers[3] = Texel(u_bg3, uv);
  float pris[4];
  pris[0] = u_bgPriority.x;
  pris[1] = u_bgPriority.y;
  pris[2] = u_bgPriority.z;
  pris[3] = u_bgPriority.w;
  vec3 bgColor = u_backdrop;
  float bgPri = 255.0;
  float bgLayer = -1.0;
  for (int layer = 0; layer < 4; layer++) {
    if (layers[layer].a > 0.003 && pris[layer] < bgPri) {
      bgPri = pris[layer];
      bgLayer = float(layer);
      bgColor = layers[layer].rgb;
    }
  }
  vec3 objBytes = Texel(u_obj, uv).rgb;
  vec4 meta = Texel(u_meta, uv);
  float objPresent = step(0.5, meta.a * 255.0);
  float objClass = floor(meta.r * 255.0 + 0.5);
  float objPri = floor(meta.g * 255.0 + 0.5);
  bool insideWindow = u_winActive > 0.5
    && pane.x >= u_winRect.x && pane.x <= u_winRect.z
    && pane.y >= u_winRect.y && pane.y < u_winRect.w;
  bool objAllowed = objPresent > 0.5 && !insideWindow;
  bool objFirst = bitSelected(u_firstBits, 4.0) > 0.5;
  float eva = u_blend.x;
  float evb = u_blend.y;
  vec3 outBytes = fadeColor(bgColor, u_bgFadeTarget, u_bgFadeCoeff);
  float outAlpha = 1.0;
  if (objAllowed && objPri <= bgPri) {
    vec3 fadedObj = fadeColor(objBytes, u_objFadeTarget, u_objFadeCoeff);
    if (objFirst) {
      vec3 secondBytes = vec3(0.0);
      bool haveSecond = false;
      for (int layer = 0; layer < 4; layer++) {
        if (!haveSecond && bitSelected(u_secondBits, float(layer)) > 0.5 && layers[layer].a > 0.003) {
          secondBytes = fadeColor(layers[layer].rgb, u_bgFadeTarget, u_bgFadeCoeff);
          haveSecond = true;
        }
      }
      if (!haveSecond && bitSelected(u_secondBits, 5.0) > 0.5) {
        secondBytes = fadeColor(u_backdrop, u_bgFadeTarget, u_bgFadeCoeff);
        haveSecond = true;
      }
      if (haveSecond) {
        outBytes = blendPixels(fadedObj, secondBytes, eva, evb);
      } else {
        outBytes = fadedObj;
      }
    } else if (objClass > 0.5) {
      outBytes = blendPixels(fadedObj, outBytes, 6.0, 10.0);
    } else {
      outBytes = fadedObj;
    }
  } else if (bgLayer >= 0.0) {
    float firstLayer = -1.0;
    for (int layer = 0; layer < 4; layer++) {
      if (bitSelected(u_firstBits, float(layer)) > 0.5 && layers[layer].a > 0.003) {
        firstLayer = float(layer);
        break;
      }
    }
    if (firstLayer >= 0.0) {
      float secondLayer = -1.0;
      for (int layer = 0; layer < 4; layer++) {
        if (float(layer) != firstLayer && bitSelected(u_secondBits, float(layer)) > 0.5 && layers[layer].a > 0.003) {
          secondLayer = float(layer);
          break;
        }
      }
      vec3 firstBytes = fadeColor(layers[int(firstLayer + 0.5)].rgb, u_bgFadeTarget, u_bgFadeCoeff);
      if (secondLayer >= 0.0) {
        vec3 secondBytes = fadeColor(layers[int(secondLayer + 0.5)].rgb, u_bgFadeTarget, u_bgFadeCoeff);
        outBytes = blendPixels(firstBytes, secondBytes, eva, evb);
      } else {
        outBytes = firstBytes;
      }
    }
  }
  return vec4(outBytes, outAlpha);
}
]]

-- The locked target normalization for one blended 8-bit channel: 5-bit
-- source channels double to 6-bit, blend with clamped coefficients, then
-- normalize to the full-range byte the existing assets carry.
---@param value integer mixed 6-bit value
---@return integer normalized output byte
local function normalizeMixed6(value)
  if value > 63 then
    value = 63
  end
  if value < 0 then
    value = 0
  end
  local byte = math.floor(value * 255 / 62 + 0.5)
  if byte > 255 then
    byte = 255
  end
  return byte
end

-- The locked software palette fade: original 5-bit interpolation with the
-- source masks and an independent picture coefficient.
---@param source5 integer original 5-bit channel
---@param target5 integer fade target 5-bit channel
---@param coefficient integer fade coefficient 0..16
---@return integer faded 5-bit channel
local function fadeChannel5(source5, target5, coefficient)
  return source5 + math.floor((target5 - source5) * coefficient / 16)
end

---@param opts { graphics: table<string, unknown>?, text: table<string, unknown>? }
---@return PokedexRenderer
function PokedexRenderer.new(opts)
  assert(type(opts) == "table", "the pokedex renderer needs its collaborators")
  local graphics = opts.graphics
  if graphics == nil then
    graphics = love and love.graphics
  end
  local self = setmetatable({
    _graphics = graphics,
    _text = opts.text,
    _shader = nil,
    _shaderFailed = nil,
    _released = false,
  }, PokedexRenderer)
  if graphics ~= nil and type(graphics.newShader) == "function" then
    local ok, shader = pcall(graphics.newShader, COMPOSITE_SHADER)
    if ok then
      self._shader = shader
    else
      self._shaderFailed = tostring(shader)
    end
  else
    self._shaderFailed = "the pokedex compositor requires its host shader compiler"
  end
  return self
end

-- Draws the current blended byte for one channel pair through the locked
-- normalization. Pure arithmetic over prepared coefficients; no graphics.
---@param a5 integer first 5-bit channel
---@param b5 integer second 5-bit channel
---@param eva integer first blend coefficient
---@param evb integer second blend coefficient
---@return integer normalized output byte
function PokedexRenderer.blendByte(a5, b5, eva, evb)
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
  return normalizeMixed6(math.floor((2 * a5 * eva + 2 * b5 * evb + 8) / 16))
end

-- Draws the faded 5-bit channel through the locked software interpolation.
-- Pure arithmetic over prepared coefficients; no graphics.
---@param source5 integer original 5-bit channel
---@param target5 integer fade target 5-bit channel
---@param coefficient integer fade coefficient 0..16
---@return integer faded 5-bit channel
function PokedexRenderer.fadeByte(source5, target5, coefficient)
  return fadeChannel5(source5, target5, coefficient)
end

-- Maps a blend target name to its composite bit: bg0..bg3 read bits 0..3,
-- the top OBJ reads bit 4, and the C01 backdrop reads bit 5.
---@param name string semantic blend target
---@return integer composite bit
local function targetBit(name)
  if name == "bg0" then
    return 0
  elseif name == "bg1" then
    return 1
  elseif name == "bg2" then
    return 2
  elseif name == "bg3" then
    return 3
  elseif name == "obj" then
    return 4
  end
  assert(name == "backdrop", "blend targets name a BG plane, OBJ, or the backdrop")
  return 5
end

-- Encodes a target list as the float bitmask the composite shader reads.
---@param targets string[] semantic blend targets
---@return integer bitmask
local function targetMask(targets)
  local mask = 0
  for _, name in ipairs(targets) do
    mask = mask + 2 ^ targetBit(name)
  end
  return mask
end

-- Resolves the manifest page role behind one browser pane: the entry
-- pages read their own role, the forms comparison reads its own role, and
-- the search editors read their own criteria role.
---@param view table<string, unknown> detached browser projection
---@param paneId string browser pane identity
---@return string manifest page role
function PokedexRenderer.resolvePageRole(view, paneId)
  assert(type(view) == "table", "page roles resolve from the detached projection")
  if paneId == "registration" then
    return "registration"
  end
  local page = view.page
  if page == "cover" or page == "grid" or page == "results" then
    return page
  end
  if page == "search" then
    local search = view.search
    if type(search) == "table" and type(search.editor) == "table" then
      local kinds = {
        order = "search.order",
        name = "search.name",
        type = "search.type",
        height = "search.height",
        weight = "search.weight",
        area = "search.area",
        shape = "search.shape",
      }
      local role = kinds[search.editor.kind]
      if role ~= nil then
        return role
      end
    end
    return "search.criteria"
  end
  if page == "area" or page == "size" or page == "forms" or page == "return" then
    if page == "forms" and type(view.forms) == "table" and view.forms.comparison ~= nil then
      return "entry.compare"
    end
    return "entry." .. page
  end
  return "grid"
end

-- Reads the pane blend policy the controller publishes independently of
-- its palette fades: explicit empty sets stay empty, and the coefficients
-- travel unchanged.
---@param view table<string, unknown> detached browser projection
---@param paneId string browser pane identity
---@return { first: string[], second: string[], eva: integer, evb: integer } pane blend policy
function PokedexRenderer.paneBlendOf(view, paneId)
  assert(type(view) == "table", "blend policies resolve from the detached projection")
  local visual = view.visual
  if type(visual) ~= "table" then
    return { first = {}, second = {}, eva = 0, evb = 0 }
  end
  local blend = visual.blend
  if type(blend) ~= "table" then
    return { first = {}, second = {}, eva = 0, evb = 0 }
  end
  local policy = blend[paneId]
  if type(policy) ~= "table" then
    return { first = {}, second = {}, eva = 0, evb = 0 }
  end
  local first = policy.first
  local second = policy.second
  if type(first) ~= "table" then
    first = {}
  end
  if type(second) ~= "table" then
    second = {}
  end
  return { first = first, second = second, eva = policy.eva or 0, evb = policy.evb or 0 }
end

-- Resolves the authored per-pane backdrop from the compiled page record:
-- the exact C01 color behind every plane, before fades apply.
---@param manifest table<string, unknown> compiled presentation manifest
---@param role string manifest page role
---@param paneId string browser pane identity
---@return { r: integer, g: integer, b: integer } opaque backdrop color bytes
function PokedexRenderer.backdropOf(manifest, role, paneId)
  assert(type(manifest) == "table", "backdrops resolve from the compiled manifest")
  local pages = assert(manifest.pages, "the compiled manifest carries its page roles")
  assert(type(pages) == "table", "page roles stay a record")
  local page = assert(pages[role], "the compiled manifest carries the drawn page role " .. tostring(role))
  assert(type(page) == "table", "page roles stay records")
  local backdrop = assert(page.backdrop, "page roles carry their per-pane backdrop")
  assert(type(backdrop) == "table", "page backdrops stay records")
  local pane = assert(backdrop[paneId], "page backdrops carry the drawn pane " .. tostring(paneId))
  assert(type(pane) == "table", "pane backdrops stay records")
  return { r = pane.r or 0, g = pane.g or 0, b = pane.b or 0 }
end

-- Resolves the winning BG priority per layer from the compiled
-- backgrounds: the lowest authored priority number paints in front, and
-- an undrawn layer never wins.
---@param manifest table<string, unknown> compiled presentation manifest
---@param role string manifest page role
---@param paneId string browser pane identity
---@return number[] four layer priorities, undrawn layers stay behind every OBJ
function PokedexRenderer.layerPrioritiesOf(manifest, role, paneId)
  local priorities = { 255, 255, 255, 255 }
  if type(manifest) ~= "table" then
    return priorities
  end
  local pages = manifest.pages
  if type(pages) ~= "table" then
    return priorities
  end
  local page = pages[role]
  if type(page) ~= "table" then
    return priorities
  end
  local backgrounds = page.backgrounds
  if type(backgrounds) ~= "table" then
    return priorities
  end
  local entries = backgrounds[paneId]
  if type(entries) ~= "table" then
    return priorities
  end
  for _, entry in ipairs(entries) do
    if type(entry) == "table" and type(entry.layer) == "number" then
      local layer = entry.layer + 1
      if layer >= 1 and layer <= 4 and type(entry.priority) == "number" then
        if entry.priority < priorities[layer] then
          priorities[layer] = entry.priority
        end
      end
    end
  end
  return priorities
end

-- Maps one icon slot to its authored 32x32 controls rectangle: slot order
-- runs left to right, top to bottom from the (48,24) center origin on the
-- 40px grid, and only the first fifteen slots are visible.
---@param slot integer zero-based icon slot
---@return { x: integer, y: integer, width: integer, height: integer } authored icon rectangle
function PokedexRenderer.iconSlotRect(slot)
  assert(type(slot) == "number" and slot % 1 == 0 and slot >= 0 and slot < 15, "icons draw their fifteen visible slots")
  local column = slot % PokedexRenderer.ICON_GRID_COLUMNS
  local row = math.floor(slot / PokedexRenderer.ICON_GRID_COLUMNS)
  local centerX = PokedexRenderer.ICON_GRID_ORIGIN.x + PokedexRenderer.ICON_GRID_STEP.x * column
  local centerY = PokedexRenderer.ICON_GRID_ORIGIN.y + PokedexRenderer.ICON_GRID_STEP.y * row
  local half = PokedexRenderer.ICON_SLOT_SIZE / 2
  return {
    x = centerX - half,
    y = centerY - half,
    width = PokedexRenderer.ICON_SLOT_SIZE,
    height = PokedexRenderer.ICON_SLOT_SIZE,
  }
end

-- Maps the grid cursor to its authored 48x48 controls rectangle around
-- the selected slot center.
---@param slot integer zero-based cursor slot
---@return { x: integer, y: integer, width: integer, height: integer } authored cursor rectangle
function PokedexRenderer.cursorRectFor(slot)
  local icon = PokedexRenderer.iconSlotRect(slot)
  local centerX = icon.x + PokedexRenderer.ICON_SLOT_SIZE / 2
  local centerY = icon.y + PokedexRenderer.ICON_SLOT_SIZE / 2
  local half = PokedexRenderer.CURSOR_SIZE / 2
  return {
    x = centerX - half,
    y = centerY - half,
    width = PokedexRenderer.CURSOR_SIZE,
    height = PokedexRenderer.CURSOR_SIZE,
  }
end

-- Composes the authored Spinda spot runs from the compiled
-- personalization: the four spot arrays union over the gender
-- eligibility classes with the second-frame offset and portrait clipping.
-- Overlapping masks merge into one run per row and class so overlapping
-- spots never blend twice. Returns sorted horizontal runs.
---@param policy table<string, unknown> compiled Spinda personalization
---@param gender string male or female eligibility
---@param frame integer 0 for the front frame, 1 for the offset second frame
---@return { y: integer, x0: integer, x1: integer, class: integer }[] merged spot runs
function PokedexRenderer.spotRunsFor(policy, gender, frame)
  assert(type(policy) == "table", "spot composition reads the authored policy")
  assert(gender == "male" or gender == "female", "spot composition reads a declared gender")
  assert(frame == 0 or frame == 1, "spot composition reads the front or second frame")
  local spots = assert(policy.spots, "the authored policy carries its four spot arrays")
  assert(type(spots) == "table" and #spots == 4, "the authored policy carries four spot arrays")
  local eligibility = assert(policy.eligibility, "the authored policy carries its eligibility rows")
  assert(type(eligibility) == "table", "eligibility rows stay a record")
  local rows = assert(eligibility[gender], "eligibility covers the drawn gender")
  assert(type(rows) == "table", "gender eligibility stays a record")
  local frames = assert(rows.frames, "gender eligibility carries its frames")
  assert(type(frames) == "table", "eligibility frames stay a list")
  local plane = assert(frames[frame + 1], "eligibility carries the drawn frame")
  assert(type(plane) == "table", "eligibility frames stay row lists")
  local offset = 0
  if frame == 1 then
    offset = assert(policy.secondFrameXOffset, "the second frame carries the source offset")
    assert(type(offset) == "number", "the second-frame offset stays numeric")
  end
  local claimed = {}
  for _, spot in ipairs(spots) do
    assert(type(spot) == "table" and #spot > 0, "spot arrays stay nonempty")
    for _, point in ipairs(spot) do
      assert(type(point) == "table", "spot points stay records")
      assert(type(point.x) == "number" and type(point.y) == "number", "spot points carry coordinates")
      local x = point.x + offset
      local y = point.y
      if x >= 0 and x < 80 and y >= 0 and y < 80 then
        local row = plane[y + 1]
        assert(type(row) == "string", "eligibility rows stay 80-wide strings")
        local class = tonumber(row:sub(x + 1, x + 1))
        if class ~= nil and class >= 1 and class <= 3 then
          local key = y * 80 + x
          if claimed[key] == nil then
            claimed[key] = class
          end
        end
      end
    end
  end
  local byRow = {}
  for key, class in pairs(claimed) do
    local y = math.floor(key / 80)
    local x = key % 80
    local bucket = byRow[y]
    if bucket == nil then
      bucket = {}
      byRow[y] = bucket
    end
    bucket[#bucket + 1] = { x = x, class = class }
  end
  local runs = {}
  for y, pixels in pairs(byRow) do
    table.sort(pixels, function(left, right)
      if left.x == right.x then
        return left.class < right.class
      end
      return left.x < right.x
    end)
    local open = nil
    for _, pixel in ipairs(pixels) do
      if open ~= nil and open.class == pixel.class and pixel.x <= open.x1 + 1 then
        open.x1 = pixel.x
      else
        if open ~= nil then
          runs[#runs + 1] = { y = y, x0 = open.x0, x1 = open.x1, class = open.class }
        end
        open = { x0 = pixel.x, x1 = pixel.x, class = pixel.class }
      end
    end
    if open ~= nil then
      runs[#runs + 1] = { y = y, x0 = open.x0, x1 = open.x1, class = open.class }
    end
  end
  table.sort(runs, function(left, right)
    if left.y == right.y then
      return left.x0 < right.x0
    end
    return left.y < right.y
  end)
  return runs
end

---@param prepared table<string, unknown> browser bundle with view, assets, and compact state
---@param plan table<string, unknown> the resolved application plan
local function checkBrowserPrepared(prepared, plan)
  assert(type(prepared) == "table", "browser drawing requires its prepared view")
  assert(type(prepared.view) == "table", "browser drawing requires the detached projection")
  assert(type(prepared.assets) == "table", "browser drawing requires its prepared bundle")
  assert(type(plan) == "table" and type(plan.panes) == "table", "browser drawing requires its resolved plan")
end

-- The lease-owned serial surfaces behind one draw: all six canvases stay
-- realized and exactly 256x192, and the bundle carries them in serial
-- order.
---@param assets table<string, unknown> prepared bundle behind the draw
---@return table[] six realized serial surfaces in compositor order
local function checkSurfaces(assets)
  local surfaces = assert(assets.surfaces, "browser drawing reuses its six lease surfaces")
  assert(type(surfaces) == "table" and #surfaces == 6, "the compositor owns four BG planes plus OBJ color and metadata")
  for index, surface in ipairs(surfaces) do
    assert(type(surface) == "table", "serial surfaces stay records")
    assert(surface.name == PokedexRenderer.SURFACE_NAMES[index], "serial surfaces keep their compositor order")
    local canvas = assert(surface.canvas, "serial surfaces realize before any draw")
    assert(
      type(canvas.getWidth) == "function" and type(canvas.getHeight) == "function",
      "serial surfaces carry canvases"
    )
    assert(
      canvas:getWidth() == PokedexRenderer.SURFACE_WIDTH and canvas:getHeight() == PokedexRenderer.SURFACE_HEIGHT,
      "serial surfaces stay 256x192 RGBA8"
    )
  end
  return surfaces
end

-- Draws one prepared handle at its authored rectangle through the shared
-- exact sampler. Indexed pages bind their palette before the draw;
-- straight pages sample unchanged. Sampling draws always run at opaque
-- white so metadata marks elsewhere in the serial passes never tint art.
---@param graphics table<string, unknown> host graphics namespace
---@param handle table<string, unknown> pooled sampling handle behind the art
---@param quad table<string, unknown>? prepared source viewport
---@param x number logical left
---@param y number logical top
local function drawSampled(graphics, handle, quad, x, y)
  assert(type(handle) == "table", "sampling draws carry their prepared handle")
  assert(handle.image ~= nil, "sampling handles carry their borrowed image")
  assert(type(graphics.setColor) == "function", "sampling draws reset their tint")
  graphics.setColor(1, 1, 1, 1)
  ImageSampling.draw(graphics, handle, quad, x, y)
end

---@param graphics table<string, unknown> host graphics namespace
---@param surface table<string, unknown> realized serial surface
local function clearSurface(graphics, surface)
  assert(type(graphics.setCanvas) == "function", "serial passes target their surfaces")
  assert(type(graphics.clear) == "function", "serial passes clear their surfaces")
  graphics.setCanvas(surface.canvas)
  graphics.clear(0, 0, 0, 0)
end

-- Marks one authored OBJ rectangle in the metadata surface: blend class 0
-- draws opaque, class 1 blends as seen-only, with the OBJ template
-- priority and full coverage.
---@param graphics table<string, unknown> host graphics namespace
---@param meta table<string, unknown> realized OBJ metadata surface
---@param rect { x: number, y: number, width: number, height: number } authored OBJ rectangle
---@param blendClass integer 0 for opaque, 1 for seen-only
local function markObjRect(graphics, meta, rect, blendClass)
  assert(type(graphics.setCanvas) == "function", "metadata passes target their surface")
  assert(type(graphics.setColor) == "function", "metadata passes encode their classes")
  assert(type(graphics.rectangle) == "function", "metadata passes mark their rectangles")
  graphics.setCanvas(meta.canvas)
  graphics.setColor(blendClass / 255, PokedexRenderer.OBJ_PRIORITY / 255, 0, 1)
  graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height)
end

-- Draws the controls icon grid into the OBJ pair: caught icons opaque,
-- seen-only icons marked for the locked seen blend, blanks untouched.
-- Only the first fifteen staged slots are visible.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with the lease-owned icons
---@param grid table<string, unknown>? staged grid or results buffer behind the page
---@param surfaces table[] six realized serial surfaces in compositor order
local function drawControlIcons(graphics, assets, grid, surfaces)
  if type(grid) ~= "table" then
    return
  end
  local buffers = grid.buffers
  if type(buffers) ~= "table" then
    return
  end
  local first = buffers[1]
  if type(first) ~= "table" or type(first.entries) ~= "table" then
    return
  end
  local icons = assets.icons
  assert(type(icons) == "table", "icon drawing borrows the lease-owned provider")
  assert(type(icons.handleFor) == "function", "icon drawing resolves prepared handles")
  local color, meta = surfaces[5], surfaces[6]
  assert(type(graphics.setCanvas) == "function", "icon passes target their surfaces")
  for slot = 0, PokedexRenderer.ICON_SLOTS - 1 do
    local entry = first.entries[slot + 1]
    if type(entry) == "table" and entry.seen == true and type(entry.species) == "string" then
      local key = entry.species .. "/f0"
      local handle = icons:handleFor(key)
      assert(type(handle) == "table", "prepared icon keys resolve their handle: " .. key)
      local quad = nil
      if type(icons.quadFor) == "function" then
        quad = icons:quadFor(key)
      end
      local rect = PokedexRenderer.iconSlotRect(slot)
      graphics.setCanvas(color.canvas)
      if quad ~= nil then
        drawSampled(graphics, handle, quad, rect.x, rect.y)
      else
        drawSampled(graphics, handle, nil, rect.x, rect.y)
      end
      if entry.caught == true then
        markObjRect(graphics, meta, rect, 0)
      else
        markObjRect(graphics, meta, rect, 1)
      end
    end
  end
end

-- Selects the authored information rectangle for one picture slot: the
-- selected portrait on ordinary pages, the forms pair on the forms page,
-- and the comparison pair on the comparison page.
---@param role string manifest page role behind the pane
---@param slot string|integer picture slot behind the record
---@param facing string front or back facing behind the record
---@param backYOffset number authored back vertical correction
---@return { x: integer, y: integer, width: integer, height: integer }? authored picture rectangle, nil for undrawn slots
local function informationRectFor(role, slot, facing, backYOffset)
  if role == "registration" then
    return nil
  end
  if role == "entry.compare" then
    if facing == "back" or slot == 1 or slot == 3 then
      return PokedexRenderer.COMPARE_RIGHT_RECT
    end
    return PokedexRenderer.COMPARE_LEFT_RECT
  end
  if role == "entry.forms" then
    if facing == "back" or slot == 1 or slot == 3 then
      return {
        x = PokedexRenderer.FORMS_BACK_RECT.x,
        y = PokedexRenderer.FORMS_BACK_RECT.y + backYOffset,
        width = PokedexRenderer.FORMS_BACK_RECT.width,
        height = PokedexRenderer.FORMS_BACK_RECT.height,
      }
    end
    return PokedexRenderer.FORMS_FRONT_RECT
  end
  if facing == "back" then
    return nil
  end
  return PokedexRenderer.SELECTED_PICTURE_RECT
end

-- Draws the information picture slots into the OBJ pair through their
-- authored rectangles: prepared portrait quads, owned Spinda canvases, or
-- the fixed unknown silhouette policy the projection already selected.
-- Silhouette slots without prepared art stay undrawn; a missing required
-- portrait handle fails the draw instead of substituting another species.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with pictures and the manifest
---@param pictures table<string, unknown> prepared picture records by slot
---@param role string manifest page role behind the pane
---@param surfaces table[] six realized serial surfaces in compositor order
local function drawInformationPictures(graphics, assets, pictures, role, surfaces)
  local _ = assets
  local color, meta = surfaces[5], surfaces[6]
  assert(type(graphics.setCanvas) == "function", "picture passes target their surfaces")
  for slot, record in pairs(pictures) do
    if type(record) == "table" then
      local facing = record.facing
      if facing ~= "front" and facing ~= "back" then
        facing = "front"
      end
      local backYOffset = record.backYOffset
      if type(backYOffset) ~= "number" then
        backYOffset = 0
      end
      local rect = informationRectFor(role, slot, facing, backYOffset)
      if rect ~= nil and record.mode ~= "silhouette" then
        local spinda = record.spinda
        if type(spinda) == "table" and spinda.canvas ~= nil then
          graphics.setCanvas(color.canvas)
          assert(type(graphics.setColor) == "function", "picture passes reset their tint")
          assert(type(graphics.draw) == "function", "picture passes blit their canvases")
          graphics.setColor(1, 1, 1, 1)
          graphics.draw(spinda.canvas, rect.x, rect.y)
          markObjRect(graphics, meta, rect, 0)
        else
          local handle = assert(record.handle, "prepared picture slots carry their handle")
          graphics.setCanvas(color.canvas)
          drawSampled(graphics, handle, record.quad, rect.x, rect.y)
          markObjRect(graphics, meta, rect, 0)
        end
      end
    end
  end
end

-- Runs the serial passes for one pane on the identity transform: every
-- pass clears then paints exactly one preallocated lease surface, and the
-- previous target returns before the composite reads them.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with icons, pictures, and chrome
---@param view table<string, unknown> detached projection selecting content
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param surfaces table[] six realized serial surfaces in compositor order
local function runSerialPasses(graphics, assets, view, role, paneId, surfaces)
  assert(type(graphics.push) == "function", "serial passes preserve their graphics state")
  assert(type(graphics.origin) == "function", "serial passes draw on the identity transform")
  graphics.push("all")
  graphics.origin()
  local ok, err = pcall(function()
    for _, surface in ipairs(surfaces) do
      clearSurface(graphics, surface)
    end
    local previous = nil
    if type(graphics.getCanvas) == "function" then
      previous = graphics.getCanvas()
    end
    if paneId == "controls" then
      drawControlIcons(graphics, assets, view.grid, surfaces)
    else
      local pictures = assets.pictures
      if type(pictures) == "table" then
        drawInformationPictures(graphics, assets, pictures, role, surfaces)
      end
    end
    graphics.setCanvas(previous)
  end)
  if type(graphics.pop) == "function" then
    graphics.pop()
  end
  if not ok then
    error(err, 0)
  end
end

-- Resolves the composite uniforms for one pane: authored backdrop and
-- layer priorities, the published blend targets and coefficients, the
-- fade coefficients, and the footer window rule.
---@param manifest table<string, unknown> compiled presentation manifest
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param blend { first: string[], second: string[], eva: integer, evb: integer } published pane blend policy
---@param bgFade { target: { r: integer, g: integer, b: integer }, coeff: integer } BG fade
---@param objFade { target: { r: integer, g: integer, b: integer }, coeff: integer } OBJ fade
---@param windowActive boolean true while the footer window excludes OBJ
---@return table<string, unknown> composite uniform record
local function compositeUniforms(manifest, role, paneId, blend, bgFade, objFade, windowActive)
  local backdrop = PokedexRenderer.backdropOf(manifest, role, paneId)
  local priorities = PokedexRenderer.layerPrioritiesOf(manifest, role, paneId)
  local uniforms = {
    u_backdrop = { backdrop.r / 255, backdrop.g / 255, backdrop.b / 255 },
    u_bgPriority = { priorities[1], priorities[2], priorities[3], priorities[4] },
    u_firstBits = targetMask(blend.first),
    u_secondBits = targetMask(blend.second),
    u_blend = { blend.eva, blend.evb },
    u_bgFadeTarget = { bgFade.target.r / 255, bgFade.target.g / 255, bgFade.target.b / 255 },
    u_bgFadeCoeff = bgFade.coeff,
    u_objFadeTarget = { objFade.target.r / 255, objFade.target.g / 255, objFade.target.b / 255 },
    u_objFadeCoeff = objFade.coeff,
    u_winActive = 0,
    u_winRect = { 0, 0, 0, 0 },
  }
  if windowActive then
    local window = PokedexRenderer.INFORMATION_WINDOW
    uniforms.u_winActive = 1
    uniforms.u_winRect = { window.left, window.top, window.right, window.bottom }
  end
  return uniforms
end

-- Composites one pane from the six serial surfaces through the final pane
-- shader: binds every surface, sends the authored uniforms, and draws the
-- carrier inside the plan placement exactly once.
---@param renderer PokedexRenderer
---@param graphics table<string, unknown> host graphics namespace
---@param manifest table<string, unknown> compiled presentation manifest
---@param placement table<string, unknown> validated pane placement
---@param uniforms table<string, unknown> composite uniform record
---@param surfaces table[] six realized serial surfaces in compositor order
local function compositePane(renderer, graphics, manifest, placement, uniforms, surfaces)
  local _ = manifest
  local shader = assert(renderer._shader, tostring(renderer._shaderFailed))
  assert(type(graphics.setShader) == "function", "the composite binds its shader")
  assert(type(graphics.draw) == "function", "the composite draws its carrier")
  local names = { "u_bg0", "u_bg1", "u_bg2", "u_bg3", "u_obj", "u_meta" }
  for index, uniform in ipairs(names) do
    assert(type(shader.send) == "function", "the composite shader receives its surfaces")
    shader:send(uniform, surfaces[index].canvas)
  end
  shader:send("u_backdrop", uniforms.u_backdrop)
  shader:send("u_bgPriority", uniforms.u_bgPriority)
  shader:send("u_firstBits", uniforms.u_firstBits)
  shader:send("u_secondBits", uniforms.u_secondBits)
  shader:send("u_blend", uniforms.u_blend)
  shader:send("u_bgFadeTarget", uniforms.u_bgFadeTarget)
  shader:send("u_bgFadeCoeff", uniforms.u_bgFadeCoeff)
  shader:send("u_objFadeTarget", uniforms.u_objFadeTarget)
  shader:send("u_objFadeCoeff", uniforms.u_objFadeCoeff)
  shader:send("u_winRect", uniforms.u_winRect)
  shader:send("u_winActive", uniforms.u_winActive)
  local previous = nil
  if type(graphics.getShader) == "function" then
    previous = graphics.getShader()
  end
  graphics.setShader(shader)
  local ok, err = pcall(function()
    LogicalSurface.draw(graphics, placement, function()
      graphics.draw(surfaces[1].canvas, 0, 0)
    end)
  end)
  graphics.setShader(previous)
  if not ok then
    error(err, 0)
  end
end

-- The browser raster pass: per-pane serial passes through the six lease
-- surfaces, then one final composite per pane. Draws only already
-- prepared values and restores the borrowed graphics state even when a
-- pane raises.
---@param prepared { view: table<string, unknown>, assets: table<string, unknown>, compact: table<string, unknown>? }
---@param plan table<string, unknown> the resolved application plan
function PokedexRenderer:drawBrowser(prepared, plan)
  assert(not self._released, "a released pokedex renderer draws nothing")
  checkBrowserPrepared(prepared, plan)
  local graphics = assert(self._graphics, "browser drawing requires its host graphics namespace")
  local assets = prepared.assets --[[@as table<string, unknown>]]
  local view = prepared.view --[[@as table<string, unknown>]]
  local manifest = assert(assets.manifest, "prepared bundles carry their compiled manifest")
  local surfaces = checkSurfaces(assets)
  local _ = prepared.compact
  assert(type(graphics.push) == "function", "browser drawing requires its host state stack")
  graphics.push("all")
  local ok, err = pcall(function()
    for _, pane in ipairs(plan.panes) do
      if type(pane) == "table" and (pane.id == "information" or pane.id == "controls") then
        local placement = assert(pane.placement, "browser panes carry their placement")
        local paneId = pane.id --[[@as string]]
        local role = PokedexRenderer.resolvePageRole(view, paneId)
        runSerialPasses(graphics, assets, view, role, paneId, surfaces)
        local blend = PokedexRenderer.paneBlendOf(view, paneId)
        local noFade = { target = { r = 0, g = 0, b = 0 }, coeff = 0 }
        local uniforms = compositeUniforms(manifest, role, paneId, blend, noFade, noFade, paneId == "information")
        compositePane(self, graphics, manifest, placement, uniforms, surfaces)
      end
    end
  end)
  if type(graphics.pop) == "function" then
    graphics.pop()
  end
  if not ok then
    Errors.raise("POKEDEX_DRAW_FAILED", "the pokedex browser failed to draw: " .. tostring(err), {})
  end
end

-- The registration raster pass: one opaque card cover over the departing
-- battle art with the fixed 80x80 captured picture unfaded, driven by the
-- independently published palette and picture coefficients. Draws only
-- already prepared values and restores the borrowed graphics state.
---@param prepared { view: table<string, unknown>, assets: table<string, unknown> }
---@param plan table<string, unknown> the resolved application plan
function PokedexRenderer:drawRegistration(prepared, plan)
  assert(not self._released, "a released pokedex renderer draws nothing")
  assert(type(prepared) == "table", "registration drawing requires its prepared view")
  assert(type(prepared.view) == "table", "registration drawing requires its terminal card view")
  assert(type(prepared.assets) == "table", "registration drawing requires its prepared bundle")
  assert(type(plan) == "table" and type(plan.panes) == "table", "registration drawing requires its resolved plan")
  local graphics = assert(self._graphics, "registration drawing requires its host graphics namespace")
  local assets = prepared.assets --[[@as table<string, unknown>]]
  local view = prepared.view --[[@as table<string, unknown>]]
  local manifest = assert(assets.manifest, "prepared bundles carry their compiled manifest")
  local surfaces = checkSurfaces(assets)
  local paletteFade = view.paletteFade
  if type(paletteFade) ~= "number" then
    paletteFade = 0
  end
  local pictureFade = view.pictureFade
  if type(pictureFade) ~= "number" then
    pictureFade = 0
  end
  assert(type(graphics.push) == "function", "registration drawing requires its host state stack")
  graphics.push("all")
  local ok, err = pcall(function()
    for _, pane in ipairs(plan.panes) do
      if type(pane) == "table" and pane.id == "registration" then
        local placement = assert(pane.placement, "registration panes carry their placement")
        runSerialPasses(graphics, assets, view, "registration", "registration", surfaces)
        local pictures = assets.pictures
        if type(pictures) == "table" then
          local card = pictures.registration
          if type(card) == "table" then
            local color = surfaces[5]
            local meta = surfaces[6]
            local rect = PokedexRenderer.REGISTRATION_PICTURE_RECT
            graphics.push("all")
            graphics.origin()
            local spinda = card.spinda
            if type(spinda) == "table" and spinda.canvas ~= nil then
              graphics.setCanvas(color.canvas)
              assert(type(graphics.setColor) == "function", "registration draws reset their tint")
              assert(type(graphics.draw) == "function", "registration draws its captured picture")
              graphics.setColor(1, 1, 1, 1)
              graphics.draw(spinda.canvas, rect.x, rect.y)
            else
              local handle = assert(card.handle, "prepared card slots carry their handle")
              graphics.setCanvas(color.canvas)
              drawSampled(graphics, handle, card.quad, rect.x, rect.y)
            end
            markObjRect(graphics, meta, rect, 0)
            graphics.setCanvas(nil)
            graphics.pop()
          end
        end
        local blend = { first = {}, second = {}, eva = 0, evb = 0 }
        local black = { r = 0, g = 0, b = 0 }
        -- The card inherits the battle Main/top placement but keeps the
        -- compiled information backdrop as its opaque cover color.
        local uniforms = compositeUniforms(
          manifest,
          "registration",
          "information",
          blend,
          { target = black, coeff = paletteFade },
          { target = black, coeff = pictureFade },
          false
        )
        compositePane(self, graphics, manifest, placement, uniforms, surfaces)
      end
    end
  end)
  if type(graphics.pop) == "function" then
    graphics.pop()
  end
  if not ok then
    Errors.raise("POKEDEX_DRAW_FAILED", "the pokedex registration card failed to draw: " .. tostring(err), {})
  end
end

-- Realizes one owned 80x80 Spinda canvas from the authored spot policy:
-- the shared base samples correctly, eligible spot runs union with
-- replace blending so overlapping masks never blend twice, and the
-- caller owns the returned canvas under the lease rules. The frame
-- selects the front spots or the offset second-frame spots; only the
-- eligibility classes 1..3 take the normal or shiny replacement colors.
-- Without host canvases the record stays a lightweight bound the draw
-- pass skips.
---@param spec { base: table<string, unknown>?, quad: table<string, unknown>?, policy: table<string, unknown>, personality: integer, shiny: boolean, gender: string, frame: integer? }
---@return { canvas: table<string, unknown>?, width: integer, height: integer, release: fun() }
function PokedexRenderer:prepareSpindaPicture(spec)
  assert(not self._released, "a released pokedex renderer prepares nothing")
  assert(type(spec) == "table", "spinda preparation requires its picture record")
  assert(type(spec.policy) == "table", "spinda preparation requires the authored spot policy")
  assert(type(spec.personality) == "number", "spinda preparation requires its personality")
  local gender = spec.gender
  if gender ~= "male" and gender ~= "female" then
    gender = "male"
  end
  local frame = spec.frame
  if frame ~= 1 then
    frame = 0
  end
  local shiny = spec.shiny == true
  local graphics = self._graphics
  local released = false
  local record = { canvas = nil, width = 80, height = 80 }
  local runs = PokedexRenderer.spotRunsFor(spec.policy, gender, frame)
  if graphics ~= nil and type(graphics.newCanvas) == "function" then
    local ok, canvas = pcall(graphics.newCanvas, 80, 80)
    if ok then
      record.canvas = canvas
      local completed, failure = pcall(function()
        assert(type(graphics.push) == "function", "spinda preparation preserves its graphics state")
        assert(type(graphics.origin) == "function", "spinda preparation draws on the identity transform")
        graphics.push("all")
        graphics.origin()
        local previous = nil
        if type(graphics.getCanvas) == "function" then
          previous = graphics.getCanvas()
        end
        graphics.setCanvas(canvas)
        graphics.clear(0, 0, 0, 0)
        local base = spec.base
        if type(base) == "table" and base.image ~= nil then
          drawSampled(graphics, base, spec.quad, 0, 0)
        end
        local colors = spec.policy.replacementColors
        assert(type(colors) == "table", "the authored policy carries its replacement colors")
        local palette = colors[shiny and "shiny" or "normal"]
        assert(type(palette) == "table" and #palette == 3, "replacement colors carry their triple")
        local previousMode = nil
        if type(graphics.getBlendMode) == "function" then
          previousMode = { graphics.getBlendMode() }
        end
        if type(graphics.setBlendMode) == "function" then
          graphics.setBlendMode("replace")
        end
        for _, run in ipairs(runs) do
          local triple = palette[run.class]
          assert(type(triple) == "table", "replacement colors carry every class")
          assert(type(graphics.setColor) == "function", "spinda preparation paints its runs")
          assert(type(graphics.rectangle) == "function", "spinda preparation paints its runs")
          graphics.setColor((triple.r or 0) / 255, (triple.g or 0) / 255, (triple.b or 0) / 255, 1)
          graphics.rectangle("fill", run.x0, run.y, run.x1 - run.x0 + 1, 1)
        end
        if type(graphics.setBlendMode) == "function" and previousMode ~= nil then
          graphics.setBlendMode(previousMode[1], previousMode[2])
        end
        graphics.setCanvas(previous)
        graphics.pop()
      end)
      if not completed then
        if type(canvas.release) == "function" then
          canvas:release()
        end
        record.canvas = nil
        error(failure, 0)
      end
    end
  end
  function record.release()
    if released then
      return
    end
    released = true
    local canvas = record.canvas
    record.canvas = nil
    if canvas ~= nil and type(canvas.release) == "function" then
      canvas:release()
    end
  end
  return record
end

-- Releases only the renderer's private shader resources. Prepared canvases
-- stay owned by the resource lease that admitted them, and borrowed pool,
-- text, and message owners stay alive.
function PokedexRenderer:release()
  if self._released then
    return
  end
  self._released = true
  local shader = self._shader
  self._shader = nil
  self._shaderFailed = nil
  if shader ~= nil and type(shader.release) == "function" then
    shader:release()
  end
end

return PokedexRenderer
