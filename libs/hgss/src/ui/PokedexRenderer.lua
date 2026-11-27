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
---@field _metaShader table<string, unknown>? private OBJ metadata shader, nil until validated
---@field _metaShaderFailed string? visible metadata failure, raised as a draw-time cause
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
-- The registration picture is an 80x80 specimen quad addressed by its
-- source center: top-left is (pictureX - 40, 32), sliding from center 48
-- to center 128 over departure.
PokedexRenderer.REGISTRATION_PICTURE_SIZE = 80
PokedexRenderer.REGISTRATION_PICTURE_Y = 32
PokedexRenderer.REGISTRATION_PICTURE_HOME = 48
PokedexRenderer.FORMS_FRONT_RECT = { x = 24, y = 80, width = 80, height = 80 }
PokedexRenderer.FORMS_BACK_RECT = { x = 152, y = 80, width = 80, height = 80 }
PokedexRenderer.COMPARE_LEFT_RECT = { x = 24, y = 80, width = 80, height = 80 }
PokedexRenderer.COMPARE_RIGHT_RECT = { x = 152, y = 80, width = 80, height = 80 }
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
uniform vec3 u_bg0FadeTarget;
uniform float u_bg0FadeCoeff;
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
  // The registration picture plane carries its own fade coefficient;
  // every other BG plane, the backdrop, and the popup OBJ share the
  // palette fade. Browser passes set both coefficients equal.
  vec3 faded0 = fadeColor(layers[0].rgb, u_bg0FadeTarget, u_bg0FadeCoeff);
  vec3 faded1 = fadeColor(layers[1].rgb, u_bgFadeTarget, u_bgFadeCoeff);
  vec3 faded2 = fadeColor(layers[2].rgb, u_bgFadeTarget, u_bgFadeCoeff);
  vec3 faded3 = fadeColor(layers[3].rgb, u_bgFadeTarget, u_bgFadeCoeff);
  vec3 fadedBackdrop = fadeColor(u_backdrop, u_bgFadeTarget, u_bgFadeCoeff);
  // The visible stack: the topmost opaque BG by (priority, layer) with
  // ties to the lower layer number, then the backdrop. Only the one
  // winning OBJ ever joins the stack: OBJ beats BG on equal priority.
  vec3 bgColor = fadedBackdrop;
  float bgPri = 255.0;
  float bgLayer = -1.0;
  for (int layer = 0; layer < 4; layer++) {
    if (layers[layer].a > 0.003 && pris[layer] < bgPri) {
      bgPri = pris[layer];
      bgLayer = float(layer);
      if (layer == 0) { bgColor = faded0; }
      else if (layer == 1) { bgColor = faded1; }
      else if (layer == 2) { bgColor = faded2; }
      else { bgColor = faded3; }
    }
  }
  vec4 objSample = Texel(u_obj, uv);
  vec3 objBytes = objSample.rgb;
  vec4 meta = Texel(u_meta, uv);
  // Metadata never confers presence by itself: the pixel is an OBJ
  // candidate only when its actual sampled texel is opaque as well.
  float objPresent = step(0.5, meta.a * 255.0) * step(0.003, objSample.a);
  float objClass = floor(meta.r * 255.0 + 0.5);
  float objPri = floor(meta.g * 255.0 + 0.5);
  bool insideWindow = u_winActive > 0.5
    && pane.x >= u_winRect.x && pane.x <= u_winRect.z
    && pane.y >= u_winRect.y && pane.y < u_winRect.w;
  bool objAllowed = objPresent > 0.5 && !insideWindow;
  float eva = u_blend.x;
  float evb = u_blend.y;
  vec3 outBytes = bgColor;
  float outAlpha = 1.0;
  if (objAllowed && objPri <= bgPri) {
    vec3 fadedObj = fadeColor(objBytes, u_objFadeTarget, u_objFadeCoeff);
    // The blend pair is the foremost pixel and the immediately
    // underlying visible pixel only: never a deeper layer past the
    // winner, and never another OBJ.
    float secondBit = 5.0;
    vec3 secondBytes = fadedBackdrop;
    if (bgLayer >= 0.0) {
      secondBit = bgLayer;
      secondBytes = bgColor;
    }
    if (bitSelected(u_firstBits, 4.0) > 0.5 && bitSelected(u_secondBits, secondBit) > 0.5) {
      outBytes = blendPixels(fadedObj, secondBytes, eva, evb);
    } else if (objClass > 0.5) {
      outBytes = blendPixels(fadedObj, outBytes, 6.0, 10.0);
    } else {
      outBytes = fadedObj;
    }
  } else if (bgLayer >= 0.0) {
    if (bitSelected(u_firstBits, bgLayer) > 0.5) {
      // The immediately underlying visible pixel: the visible BG plane
      // ranked just below the winner, else the backdrop. No scanning
      // past the blocking winner.
      float secondLayer = -1.0;
      float secondPri = 255.0;
      for (int layer = 0; layer < 4; layer++) {
        if (float(layer) != bgLayer && layers[layer].a > 0.003
            && (pris[layer] > bgPri || (pris[layer] == bgPri && float(layer) > bgLayer))) {
          if (pris[layer] < secondPri || (pris[layer] == secondPri && float(layer) < secondLayer)) {
            secondPri = pris[layer];
            secondLayer = float(layer);
          }
        }
      }
      vec3 underBytes = fadedBackdrop;
      float underBit = 5.0;
      if (secondLayer >= 0.0) {
        underBit = secondLayer;
        if (secondLayer < 0.5) { underBytes = faded0; }
        else if (secondLayer < 1.5) { underBytes = faded1; }
        else if (secondLayer < 2.5) { underBytes = faded2; }
        else { underBytes = faded3; }
      }
      if (bitSelected(u_secondBits, underBit) > 0.5) {
        outBytes = blendPixels(bgColor, underBytes, eva, evb);
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
    _metaShader = nil,
    _metaShaderFailed = nil,
    _released = false,
  }, PokedexRenderer)
  if graphics ~= nil and type(graphics.newShader) == "function" then
    local ok, shader = pcall(graphics.newShader, COMPOSITE_SHADER)
    if ok then
      self._shader = shader
    else
      self._shaderFailed = tostring(shader)
    end
    -- The metadata shader samples the identical exact texel rule as
    -- the color path but outputs the command's class and priority only
    local metaSource = ImageSampling.samplingGlsl()
      .. "\nuniform float u_metaClass;\n"
      .. "uniform float u_metaPriority;\n"
      .. "vec4 effect(vec4 color, Image tex, vec2 texCoord, vec2 screenCoords) {\n"
      .. "  vec4 texel = resolveExactTexel(Texel(tex, texCoord));\n"
      .. "  if (texel.a < 0.01) {\n"
      .. "    discard;\n"
      .. "  }\n"
      .. "  return vec4(u_metaClass / 255.0, u_metaPriority / 255.0, 0.0, 1.0);\n"
      .. "}\n"
    local metaOk, metaShader = pcall(graphics.newShader, metaSource)
    if metaOk then
      self._metaShader = metaShader
    else
      self._metaShaderFailed = tostring(metaShader)
    end
  else
    self._shaderFailed = "the pokedex compositor requires its host shader compiler"
    self._metaShaderFailed = "the pokedex metadata pass requires its host shader compiler"
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
        letter = "search.name",
        type = "search.type",
        height = "search.height",
        weight = "search.weight",
        area = "search.area",
        shape = "search.shape",
      }
      -- The editor view names its criterion; either spelling resolves,
      -- matching the demand-side role projection.
      local editorKind = search.editor.kind or search.editor.criterion
      local role = kinds[editorKind]
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

-- Reads the exact per-page native priority vector the producer compiled
-- for the drawn pane: a dense BG0..BG3 assignment, values 0..3, with no
-- fallback to unrelated pages. An inactive empty layer stays transparent
-- in the serial passes, so the vector alone decides the order.
---@param manifest table<string, unknown> compiled presentation manifest
---@param role string manifest page role
---@param paneId string browser pane identity
---@return number[] four explicit native layer priorities behind the pane
function PokedexRenderer.layerPrioritiesOf(manifest, role, paneId)
  assert(type(manifest) == "table", "page priorities resolve from the compiled manifest")
  local pages = assert(manifest.pages, "the compiled manifest carries its page roles")
  assert(type(pages) == "table", "page roles stay a record")
  local page = assert(pages[role], "the compiled manifest carries the drawn page role " .. tostring(role))
  assert(type(page) == "table", "page roles stay records")
  local vectors =
    assert(page.layerPriorities, "the drawn page carries its explicit layer priorities: " .. tostring(role))
  assert(type(vectors) == "table", "page priorities stay a record: " .. tostring(role))
  local vector = assert(vectors[paneId], "page priorities carry the drawn pane: " .. tostring(paneId))
  assert(type(vector) == "table" and #vector == 4, "pane priorities cover all four native layers")
  local priorities = {}
  for layer = 1, 4 do
    local priority = vector[layer]
    assert(
      type(priority) == "number" and priority % 1 == 0 and priority >= 0 and priority <= 3,
      "pane priorities stay inside the native 0..3 range"
    )
    priorities[layer] = priority
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
-- Extra placement arguments (rotation, scale, origin for flipped parts)
-- forward to the sampled draw.
---@param graphics table<string, unknown> host graphics namespace
---@param handle table<string, unknown> pooled sampling handle behind the art
---@param quad table<string, unknown>? prepared source viewport
---@param x number logical left
---@param y number logical top
---@param ... number optional extra placement arguments forwarded to the sampled draw
local function drawSampled(graphics, handle, quad, x, y, ...)
  assert(type(handle) == "table", "sampling draws carry their prepared handle")
  assert(handle.image ~= nil, "sampling handles carry their borrowed image")
  assert(type(graphics.setColor) == "function", "sampling draws reset their tint")
  graphics.setColor(1, 1, 1, 1)
  ImageSampling.draw(graphics, handle, quad, x, y, ...)
end

---@param graphics table<string, unknown> host graphics namespace
---@param surface table<string, unknown> realized serial surface
local function clearSurface(graphics, surface)
  assert(type(graphics.setCanvas) == "function", "serial passes target their surfaces")
  assert(type(graphics.clear) == "function", "serial passes clear their surfaces")
  graphics.setCanvas(surface.canvas)
  graphics.clear(0, 0, 0, 0)
end

-- One draw-local OBJ command behind a pane flush. A sampled part paints one
-- prepared texture with identical placement on the color and metadata
-- surfaces; a fill paints one deliberate rectangle; a text command paints
-- compact glyphs on the color surface only, riding the fill beneath it.
-- `priority` is the source OAM priority (0 foremost) and `order` the
-- collection sequence, which follows the deterministic template, part, and
-- intent order of the pass that submitted it. `clip` optionally bounds the
-- command to its caller scissor. `bare` fills paint color only, like the
-- slider tracks and selection rings that never carried metadata.
---@param commands table[] draw-local OBJ command buffer behind one pane
---@param cmd table<string, unknown> one fill, part, or text command
local function submitObjCommand(commands, cmd)
  assert(type(commands) == "table", "OBJ commands collect behind their pane buffer")
  assert(type(cmd) == "table", "OBJ commands stay records")
  cmd.order = #commands + 1
  commands[#commands + 1] = cmd
end

-- Runs one placement body under the command's owner and source-frame
-- geometry: the owner pose (translate, pivot, rotate, scale) applies
-- outside the cell-local frame pose (translate, rotate, scale), so color
-- and metadata share the transformed vertices and texel sampling.
---@param graphics table<string, unknown> host graphics namespace
---@param cmd table<string, unknown> placed part command behind the flush
---@param body fun() placement body behind the geometry
local function withPartPlacement(graphics, cmd, body)
  local owner, frame = cmd.owner, cmd.frame
  if owner == nil and frame == nil then
    body()
    return
  end
  assert(type(graphics.push) == "function", "placed parts preserve their graphics state")
  graphics.push("all")
  if owner ~= nil then
    assert(type(graphics.translate) == "function", "placed parts translate to their origin")
    graphics.translate(owner.x, owner.y)
    graphics.translate(owner.pivotX, owner.pivotY)
    if owner.rotation ~= nil then
      assert(type(graphics.rotate) == "function", "rotated parts declare rotation")
      graphics.rotate(owner.rotation)
    end
    if owner.scale ~= nil then
      assert(type(graphics.scale) == "function", "scaled parts declare scale")
      graphics.scale(owner.scale, owner.scale)
    end
    graphics.translate(-owner.pivotX, -owner.pivotY)
  end
  if frame ~= nil then
    assert(type(graphics.translate) == "function", "framed parts translate to their cell")
    graphics.translate(frame.offsetX, frame.offsetY)
    if frame.rotation ~= 0 then
      assert(type(graphics.rotate) == "function", "framed parts rotate with their cell")
      graphics.rotate(frame.rotation)
    end
    if frame.scaleX ~= 1 or frame.scaleY ~= 1 then
      assert(type(graphics.scale) == "function", "framed parts scale with their cell")
      graphics.scale(frame.scaleX, frame.scaleY)
    end
  end
  body()
  if type(graphics.pop) == "function" then
    graphics.pop()
  end
end

-- Paints one part command on the OBJ color surface through the shared
-- exact sampler, under its placement geometry.
---@param graphics table<string, unknown> host graphics namespace
---@param cmd table<string, unknown> placed part command behind the flush
local function paintPartColor(graphics, cmd)
  withPartPlacement(graphics, cmd, function()
    if cmd.hasExtra == true then
      drawSampled(graphics, cmd.handle, cmd.quad, cmd.x, cmd.y, cmd.r, cmd.sx, cmd.sy, cmd.ox, cmd.oy)
    else
      drawSampled(graphics, cmd.handle, cmd.quad, cmd.x, cmd.y)
    end
  end)
end

-- Paints one part command on the OBJ metadata surface: the identical
-- geometry and texel sampling as the color pass, but the command's
-- class and priority only where the sampled texel is opaque. Transparent
-- texels discard, so they never donate coverage over an earlier opaque
-- contributor.
---@param graphics table<string, unknown> host graphics namespace
---@param metaShader table<string, unknown> private OBJ metadata shader behind the flush
---@param cmd table<string, unknown> placed part command behind the flush
local function paintPartMeta(graphics, metaShader, cmd)
  withPartPlacement(graphics, cmd, function()
    local handle = assert(cmd.handle, "part commands carry their prepared handle")
    assert(handle.image ~= nil, "part commands carry their borrowed image")
    handle.image:setFilter("nearest", "nearest")
    if handle.kind == "r8" then
      local palette = assert(handle.palette, "indexed part commands carry their palette")
      palette:setFilter("nearest", "nearest")
    end
    local previous = nil
    if type(graphics.getShader) == "function" then
      previous = graphics.getShader()
    end
    assert(type(graphics.setShader) == "function", "metadata passes bind their shader")
    graphics.setShader(metaShader)
    if handle.kind == "r8" then
      local palette = assert(handle.palette, "indexed part commands carry their palette")
      metaShader:send("u_usePalette", true)
      metaShader:send("u_paletteCount", palette:getWidth())
      metaShader:send("u_palette", palette)
      metaShader:send("u_paletteOffset", 0)
    else
      metaShader:send("u_usePalette", false)
    end
    metaShader:send("u_metaClass", cmd.blendClass)
    metaShader:send("u_metaPriority", cmd.priority)
    if cmd.hasExtra == true then
      graphics.draw(handle.image, cmd.quad, cmd.x, cmd.y, cmd.r, cmd.sx, cmd.sy, cmd.ox, cmd.oy)
    elseif cmd.quad ~= nil then
      graphics.draw(handle.image, cmd.quad, cmd.x, cmd.y)
    else
      graphics.draw(handle.image, cmd.x, cmd.y)
    end
    graphics.setShader(previous)
  end)
end

-- Runs one body clipped to the command's caller scissor, restoring the
-- previous scissor even when the body fails.
---@param graphics table<string, unknown> host graphics namespace
---@param clip table<string, unknown>? caller clip rectangle behind the command
---@param body fun() paint body behind the clip
local function withCommandClip(graphics, clip, body)
  if clip == nil then
    body()
    return
  end
  assert(type(graphics.getScissor) == "function", "clipped commands read their scissor")
  assert(type(graphics.setScissor) == "function", "clipped commands write their scissor")
  local saveX, saveY, saveW, saveH = graphics.getScissor()
  graphics.setScissor(clip.x, clip.y, clip.width, clip.height)
  local ok, err = pcall(body)
  if saveX ~= nil then
    graphics.setScissor(saveX, saveY, saveW, saveH)
  else
    graphics.setScissor()
  end
  if not ok then
    error(err, 0)
  end
end

-- Flushes one pane's collected OBJ commands: sort draws the foremost
-- contributor last so ordinary alpha blending resolves the single
-- winning color, and the identical order with alpha-tested metadata
-- sampling resolves the matching class and priority. Native panes sort
-- back-to-front by (priority, collection order); compact panes keep
-- their deliberate collection order. Text and bare fills paint color
-- only; every other command paints both surfaces.
---@param graphics table<string, unknown> host graphics namespace
---@param metaShader table<string, unknown> private OBJ metadata shader behind the flush
---@param commands table[] draw-local OBJ command buffer behind one pane
---@param surfaces table[] six realized serial surfaces in compositor order
---@param sorted boolean true for native back-to-front order, false for compact collection order
local function flushObjCommands(graphics, metaShader, commands, surfaces, sorted)
  assert(metaShader ~= nil, "the OBJ flush requires its metadata shader")
  if sorted then
    table.sort(commands, function(left, right)
      if left.priority ~= right.priority then
        return left.priority > right.priority
      end
      return left.order > right.order
    end)
  end
  local color, meta = surfaces[5], surfaces[6]
  assert(type(graphics.setCanvas) == "function", "OBJ flushes target their surfaces")
  local outerCanvas = nil
  if type(graphics.getCanvas) == "function" then
    outerCanvas = graphics.getCanvas()
  end
  local previousMode = nil
  if type(graphics.getBlendMode) == "function" then
    previousMode = { graphics.getBlendMode() }
  end
  if type(graphics.setBlendMode) == "function" then
    graphics.setBlendMode("alpha")
  end
  local ok, err = pcall(function()
    graphics.setCanvas(color.canvas)
    for _, cmd in ipairs(commands) do
      withCommandClip(graphics, cmd.clip, function()
        if cmd.kind == "fill" then
          assert(type(graphics.setColor) == "function", "OBJ fills set their tint")
          assert(type(graphics.rectangle) == "function", "OBJ fills fill their rectangles")
          local tint = assert(cmd.color, "fill commands carry their tint")
          graphics.setColor(tint.r / 255, tint.g / 255, tint.b / 255, 1)
          graphics.rectangle("fill", cmd.x, cmd.y, cmd.width, cmd.height)
          graphics.setColor(1, 1, 1, 1)
        elseif cmd.kind == "part" then
          paintPartColor(graphics, cmd)
        elseif cmd.kind == "text" then
          local font = assert(cmd.font, "text commands carry their font")
          assert(type(font.drawTextWithPalette) == "function", "text commands draw through the palette path")
          font:drawTextWithPalette(cmd.text, cmd.x, cmd.y, cmd.palette)
        else
          error("the OBJ flush carries no " .. tostring(cmd.kind) .. " command", 0)
        end
      end)
    end
    graphics.setCanvas(meta.canvas)
    for _, cmd in ipairs(commands) do
      if (cmd.kind == "fill" or cmd.kind == "part") and cmd.bare ~= true then
        withCommandClip(graphics, cmd.clip, function()
          if cmd.kind == "fill" then
            assert(type(graphics.setColor) == "function", "metadata fills encode their classes")
            assert(type(graphics.rectangle) == "function", "metadata fills fill their rectangles")
            graphics.setColor(cmd.blendClass / 255, cmd.priority / 255, 0, 1)
            graphics.rectangle("fill", cmd.x, cmd.y, cmd.width, cmd.height)
            graphics.setColor(1, 1, 1, 1)
          else
            paintPartMeta(graphics, metaShader, cmd)
          end
        end)
      end
    end
  end)
  if type(graphics.setBlendMode) == "function" and previousMode ~= nil then
    graphics.setBlendMode(previousMode[1], previousMode[2])
  end
  graphics.setCanvas(outerCanvas)
  if not ok then
    error(err, 0)
  end
end

-- Reads the published X scroll behind one background entry. List-family
-- scroll planes follow the cover/list drag offset; the entry-area map
-- follows its region pan. Every other layer paints at its authored x.
---@param view table<string, unknown> detached projection carrying the published offsets
---@param entry table<string, unknown> authored background record
---@return number horizontal shift in native pixels behind the layer
local function bgScrollShift(view, entry)
  local scroll = entry.scroll
  if scroll == nil then
    return 0
  end
  if scroll == "cover" then
    local visual = view.visual
    if type(visual) == "table" and type(visual.coverOffset) == "number" then
      return visual.coverOffset
    end
    return 0
  end
  if scroll == "areaPan" then
    local pan = view.areaPan
    if type(pan) == "table" and type(pan.offset) == "number" then
      return pan.offset
    end
    return 0
  end
  return 0
end

-- Draws one page background entry onto its declared BG layer: the
-- prepared chrome image paints whole at its authored offset, so source
-- RGBA including palette index0 alpha survives without subrect quads.
-- A missing prepared handle in a ready bundle fails the draw instead of
-- painting an empty fake page.
---@param graphics table<string, unknown> host graphics namespace
---@param chrome table<string, unknown> prepared role-keyed chrome handles
---@param entry table<string, unknown> authored background record
---@param surfaces table[] six realized serial surfaces in compositor order
---@param dx number horizontal scroll-plane shift in native pixels
local function drawBackgroundEntry(graphics, chrome, entry, surfaces, dx)
  assert(type(entry.layer) == "number", "background entries name their BG layer")
  local handle = assert(chrome[entry.chrome], "prepared bundles carry background chrome " .. tostring(entry.chrome))
  assert(type(handle) == "table", "prepared chrome handles stay records")
  local surface = assert(surfaces[entry.layer + 1], "background layers address their serial surface")
  graphics.setCanvas(surface.canvas)
  drawSampled(graphics, handle, nil, (entry.x or 0) + (dx or 0), entry.y or 0)
end

-- Paints every authored background of one pane onto its declared BG
-- layer 0..3, in manifest order, so later entries cover earlier ones on
-- a shared layer. The registration card reads the staged information
-- backgrounds behind its battle Main/top placement.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with chrome and the manifest
---@param view table<string, unknown> detached projection carrying the published pan
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param surfaces table[] six realized serial surfaces in compositor order
local function drawPageBackgrounds(graphics, assets, view, role, paneId, surfaces)
  local manifest = assert(assets.manifest, "prepared bundles carry their compiled manifest")
  assert(type(manifest) == "table", "compiled manifests stay records")
  local pages = assert(manifest.pages, "the compiled manifest carries its page roles")
  local page = assert(pages[role], "the compiled manifest carries the drawn page role " .. tostring(role))
  local contentPane = paneId
  if paneId == "registration" then
    contentPane = "information"
  end
  local backgrounds = page.backgrounds
  if type(backgrounds) ~= "table" then
    return
  end
  local entries = backgrounds[contentPane]
  if type(entries) ~= "table" then
    return
  end
  local chrome = assert(assets.chrome, "prepared bundles carry their chrome handles")
  for _, entry in ipairs(entries) do
    local layer = entry.layer
    assert(type(layer) == "number", "background entries name their BG layer")
    drawBackgroundEntry(graphics, chrome, entry, surfaces, -bgScrollShift(view, entry))
  end
end

-- Converts one authored 0..255 window color to the 0..1 triple the
-- palette text path consumes.
---@param color table<string, unknown> authored window color
---@return table<string, unknown> palette color triple
local function paletteColor(color)
  assert(type(color) == "table", "window colors stay records")
  local alpha = color.a
  if alpha == nil then
    alpha = 1
  else
    alpha = alpha / 255
  end
  return { r = color.r, g = color.g, b = color.b, a = alpha }
end

-- Resolves the authored window font from the prepared pair: font 0 reads
-- the borrowed body renderer, font 4 the owned header renderer.
---@param assets table<string, unknown> prepared bundle with the font pair
---@param window table<string, unknown> authored window record
---@param key string authored window key behind the attribution
---@return table<string, unknown> prepared font renderer behind the window
local function windowFont(assets, window, key)
  local fonts = assert(assets.fonts, "prepared bundles carry their font pair")
  assert(type(fonts) == "table", "prepared font pairs stay records")
  if window.font == 4 then
    return assert(fonts.header, "prepared bundles carry the header font for " .. tostring(key))
  end
  return assert(fonts.body, "prepared bundles carry the body font for " .. tostring(key))
end

-- Maps prepared messages onto their authored window keys. The
-- registration card keeps separate battle announcement and banner header
-- roles, so the header window reads only its own prepared string.
-- Windows without a prepared string stay blank: missing optional content
-- is absent, never guessed.
---@param messages table<string, unknown> prepared message record
---@return table<string, string> message by authored window key
local function textByWindow(messages)
  local mapped = {}
  for key, value in pairs(messages) do
    mapped[key] = value
  end
  return mapped
end

local function withClip(graphics, rect, fn)
  local previous = nil
  if type(graphics.getScissor) == "function" then
    previous = { graphics.getScissor() }
  end
  if type(graphics.setScissor) == "function" then
    graphics.setScissor(rect.x, rect.y, rect.width, rect.height)
  end
  fn()
  if type(graphics.setScissor) == "function" then
    if previous ~= nil and previous[1] ~= nil then
      graphics.setScissor(previous[1], previous[2], previous[3], previous[4])
    else
      graphics.setScissor()
    end
  end
end

-- Paints one authored window and its prepared text into the window's
-- assigned BG layer at source logical coordinates: an opaque window
-- background fills first, then lines step by the compiled line advance
-- from the compiled local print origin inside the real window clip. The
-- native multiline block centers on its widest line and left-aligns
-- every line; other alignments anchor each measured line at the print
-- origin. Draws the prepared strings verbatim; no runtime bank lookup
-- happens here.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with fonts and messages
---@param window table<string, unknown> authored window record
---@param key string authored window key behind the attribution
---@param text string prepared string behind the window
---@param surfaces table[] six realized serial surfaces in compositor order
---@param dy integer? vertical row-scroll shift
---@param dx number? horizontal plane-scroll shift
local function drawWindowText(graphics, assets, window, key, text, surfaces, dy, dx)
  dy = dy or 0
  dx = dx or 0
  local x0, y0 = window.x + dx, window.y + dy
  local surface = assert(surfaces[window.layer + 1], "window layers address their serial surface")
  local lineAdvance = assert(window.lineAdvance, "windows carry their source line advance: " .. tostring(key))
  assert(
    type(lineAdvance) == "number" and lineAdvance % 1 == 0 and lineAdvance > 0,
    "windows carry a positive line advance: " .. tostring(key)
  )
  local printX = assert(window.printX, "windows carry their print origin x: " .. tostring(key))
  assert(
    type(printX) == "number" and printX % 1 == 0 and printX >= 0 and printX <= window.width,
    "windows carry a print origin inside their clip: " .. tostring(key)
  )
  local printY = assert(window.printY, "windows carry their print origin y: " .. tostring(key))
  assert(
    type(printY) == "number" and printY % 1 == 0 and printY >= 0 and printY <= window.height,
    "windows carry a print origin inside their clip: " .. tostring(key)
  )
  withClip(graphics, { x = x0, y = y0, width = window.width, height = window.height }, function()
    graphics.setCanvas(surface.canvas)
    local background = window.background
    if type(background) == "table" and (background.a or 0) > 0 then
      assert(type(graphics.setColor) == "function", "window passes paint their background")
      assert(type(graphics.rectangle) == "function", "window passes paint their background")
      graphics.setColor(background.r / 255, background.g / 255, background.b / 255, background.a / 255)
      graphics.rectangle("fill", x0, y0, window.width, window.height)
      graphics.setColor(1, 1, 1, 1)
    end
    local font = windowFont(assets, window, key)
    assert(type(font.textWidth) == "function", "window fonts measure their advances")
    assert(type(font.drawTextWithPalette) == "function", "window fonts draw through their palette path")
    local palette = {
      foreground = paletteColor(assert(window.foreground, "windows carry their foreground")),
      shadow = paletteColor(assert(window.shadow, "windows carry their shadow")),
      background = paletteColor(assert(window.background, "windows carry their background")),
    }
    local maxLines = math.max(1, math.floor(window.height / lineAdvance))
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
      if #lines >= maxLines then
        break
      end
      lines[#lines + 1] = line
    end
    local baseY = y0 + printY
    if window.align == "block-center" or (window.align == "center" and #lines > 1) then
      local widest = 0
      for _, line in ipairs(lines) do
        widest = math.max(widest, font:textWidth(line))
      end
      local x = x0 + math.floor((window.width - widest) / 2)
      for index, line in ipairs(lines) do
        font:drawTextWithPalette(line, x, baseY + (index - 1) * lineAdvance, palette)
      end
      return
    end
    for index, line in ipairs(lines) do
      local width = font:textWidth(line)
      local x = x0 + printX
      if window.align == "center" then
        x = x0 + printX - math.floor(width / 2)
      elseif window.align == "right" then
        x = x0 + printX - width
      end
      font:drawTextWithPalette(line, x, baseY + (index - 1) * lineAdvance, palette)
    end
  end)
end

-- Paints the page-local window inventory of one pane plus every prepared
-- string behind it, into each window's assigned BG layer. Page
-- inventories mix panes, so only windows authored for the drawn pane
-- paint here.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with fonts, messages, and the manifest
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param surfaces table[] six realized serial surfaces in compositor order
---@param view table<string, unknown>? detached projection carrying row-scroll offsets
local function drawPageWindowsAndText(graphics, assets, role, paneId, surfaces, view)
  local manifest = assert(assets.manifest, "prepared bundles carry their compiled manifest")
  assert(type(manifest) == "table", "compiled manifests stay records")
  local pages = assert(manifest.pages, "the compiled manifest carries its page roles")
  local page = assert(pages[role], "the compiled manifest carries the drawn page role " .. tostring(role))
  local contentPane = paneId
  if paneId == "registration" then
    contentPane = "information"
  end
  local keys = page.windows
  if type(keys) ~= "table" then
    return
  end
  local inventory = assert(manifest.windows, "the compiled manifest carries its window inventory")
  local messages = assert(assets.messages, "prepared bundles carry their messages")
  assert(type(messages) == "table", "prepared messages stay records")
  local byWindow = textByWindow(messages)
  -- The cover keeps its count windows on the 512-wide cover/list scroll
  -- plane, so they slide out with the plane instead of pinning to the
  -- pane. The list view reads its counts from the fixed MAIN3 strip. The
  -- shift negates the published offset exactly like the background plane.
  local dx = 0
  if role == "cover" and contentPane == "controls" and type(view) == "table" then
    local visual = view.visual
    if type(visual) == "table" and type(visual.coverOffset) == "number" then
      dx = -visual.coverOffset
    end
  end
  for _, key in ipairs(keys) do
    local window = assert(inventory[key], "the window inventory carries " .. tostring(key))
    assert(type(window) == "table", "window records stay records")
    if window.pane == contentPane then
      local text = byWindow[window.textRole or key]
      if text ~= nil then
        assert(type(text) == "string", "prepared window strings stay strings")
        local dy = 0
        if type(view) == "table" then
          if role == "entry.area" and (key == "area.location" or key:find("^area%.row%-") ~= nil) then
            local area = view.area
            if type(area) == "table" and type(area.scroll) == "table" then
              dy = area.scroll.offset or 0
            end
          elseif role == "entry.forms" and key:find("^forms%.row%-") ~= nil then
            local forms = view.forms
            if type(forms) == "table" and type(forms.scroll) == "table" then
              dy = forms.scroll.offset or 0
            end
          end
        end
        drawWindowText(graphics, assets, window, key, text, surfaces, dy, dx)
      end
    end
  end
end

-- Draws the runtime dex-mode label cell onto the cover's MAIN0 plane:
-- the native JOHTO/NATIONAL label scrolls with the cover offset. While
-- national mode stays locked the switch row of the compiled plane is
-- replaced by the source fill patch and the switch sprite never appears.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with chrome and the manifest
---@param view table<string, unknown> detached projection carrying the mode
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param surfaces table[] six realized serial surfaces in compositor order
local function drawDexModeLabel(graphics, assets, view, role, paneId, surfaces)
  if role ~= "cover" or paneId ~= "controls" then
    return
  end
  local manifest = assert(assets.manifest, "prepared bundles carry their compiled manifest")
  local label = assert(manifest.dexModeLabel, "the manifest carries its dex mode label")
  local chrome = assert(assets.chrome, "prepared bundles carry their chrome handles")
  local visual = view.visual
  local offset = 0
  if type(visual) == "table" and type(visual.coverOffset) == "number" then
    offset = visual.coverOffset
  end
  local surface = assert(surfaces[1], "the dex mode label rides BG0")
  graphics.setCanvas(surface.canvas)
  local mode = view.mode == "national" and "national" or "johto"
  local handle = assert(chrome[label[mode]], "prepared bundles carry the dex mode label")
  drawSampled(graphics, handle, nil, label.x - offset, label.y)
  if view.nationalUnlocked ~= true then
    local locked = assert(label.locked, "the manifest carries its dex mode locked fill")
    local patch = assert(chrome[locked.role], "prepared bundles carry the dex mode locked fill")
    drawSampled(graphics, patch, nil, locked.x - offset, locked.y)
  end
end

-- Draws the runtime dex-number strip on the controls pane's BG3: the
-- caught marker plus three zero-padded digits per visible slot, sampled
-- from the compiled MAIN3 glyph roles.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with chrome and the manifest
---@param view table<string, unknown> detached projection carrying the grid buffer
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param surfaces table[] six realized serial surfaces in compositor order
local function drawListNumbers(graphics, assets, view, role, paneId, surfaces)
  if paneId ~= "controls" or (role ~= "grid" and role ~= "results") then
    return
  end
  local grid = view.grid
  if type(grid) ~= "table" or type(grid.buffers) ~= "table" then
    return
  end
  local buffers = grid.buffers
  local first = buffers[1]
  if type(first) ~= "table" or type(first.entries) ~= "table" then
    return
  end
  local manifest = assert(assets.manifest, "prepared bundles carry their compiled manifest")
  local atlas = assert(manifest.numberAtlas, "the manifest carries its number atlas")
  local chrome = assert(assets.chrome, "prepared bundles carry their chrome handles")
  local marker = assert(chrome[atlas.marker], "prepared bundles carry the caught marker")
  local caughtDigits, seenDigits = {}, {}
  for digit = 1, atlas.digits do
    caughtDigits[digit] = assert(chrome[atlas.caught[digit]], "prepared bundles carry caught digits")
    seenDigits[digit] = assert(chrome[atlas.seen[digit]], "prepared bundles carry seen digits")
  end
  local surface = assert(surfaces[4], "background number passes target BG3")
  graphics.setCanvas(surface.canvas)
  local function drawNumbers(buffer, dx)
    if type(buffer) ~= "table" or type(buffer.entries) ~= "table" then
      return
    end
    for slot = 0, PokedexRenderer.ICON_SLOTS - 1 do
      local entry = buffer.entries[slot + 1]
      if type(entry) == "table" and type(entry.dexNumber) == "number" then
        local rect = PokedexRenderer.iconSlotRect(slot)
        local x, y = rect.x + dx, rect.y
        local caught = entry.caught == true
        local row = caught and caughtDigits or seenDigits
        if caught then
          drawSampled(graphics, marker, nil, x, y)
        end
        local text = string.format("%03d", math.max(0, math.floor(entry.dexNumber)))
        for position = 1, 3 do
          local digit = tonumber(text:sub(position, position)) + 1
          drawSampled(graphics, assert(row[digit], "the number row carries its digit"), nil, x + position * 8, y)
        end
      end
    end
  end
  local turn = grid.turn
  if type(turn) == "table" and type(buffers[2]) == "table" then
    local direction = turn.direction == -1 and -1 or 1
    local shift = turn.offset
    withClip(graphics, { x = 8, y = 0, width = 240, height = 132 }, function()
      drawNumbers(buffers[1], -shift * direction)
      drawNumbers(buffers[2], (120 - shift) * direction)
    end)
    return
  end
  drawNumbers(buffers[1], 0)
end

-- Collects the page-local placed sprites as OBJ commands: records
-- anchored off the unplaced origin sentinel paint their animation's
-- resting frame at the authored center with per-part flips. Static
-- resting cells keep their authored placement; the flush resolves the
-- winning contributor and its alpha-tested coverage. Records without an
-- authored anchor stay uncollected: state-driven art (cursors, arrows,
-- scrollbars, tab cursors, digits, type/footprint/mon-picture art,
-- language icons) has no static placement and must never pile at the
-- origin. Native panes only; the compact reflow keeps its own chrome
-- scheme and draws no page sprites.
---@param assets table<string, unknown> prepared bundle with chrome and the manifest
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawPageSprites(assets, role, paneId, commands)
  local manifest = assert(assets.manifest, "prepared bundles carry their compiled manifest")
  assert(type(manifest) == "table", "compiled manifests stay records")
  local pages = assert(manifest.pages, "the compiled manifest carries its page roles")
  local page = assert(pages[role], "the compiled manifest carries the drawn page role " .. tostring(role))
  local contentPane = paneId
  if paneId == "registration" then
    contentPane = "information"
  end
  local keys = page.sprites
  if type(keys) ~= "table" then
    return
  end
  local inventory = assert(manifest.sprites, "the compiled manifest carries its sprite inventory")
  local animations = assert(manifest.animations, "the compiled manifest carries its animations")
  local cells = assert(manifest.cells, "the compiled manifest carries its cells")
  local prepared = assert(assets.spriteParts, "prepared bundles carry their sprite parts")
  for _, key in ipairs(keys) do
    local sprite = assert(inventory[key], "the sprite inventory carries " .. tostring(key))
    assert(type(sprite) == "table", "sprite records stay records")
    if (sprite.x ~= 0 or sprite.y ~= 0) and sprite.pane == contentPane then
      local animation =
        assert(animations[sprite.animation], "placed sprites resolve their animation: " .. tostring(key))
      assert(type(animation) == "table", "animation records stay records")
      local frames = assert(animation.frames, "placed sprites carry art: " .. tostring(key))
      assert(#frames >= 1, "placed sprites carry art: " .. tostring(key))
      local cell = assert(cells[frames[1].cell], "placed sprites resolve their resting cell: " .. tostring(key))
      assert(type(cell) == "table", "cell records stay records")
      assert(type(cell.parts) == "table", "placed cells carry their parts")
      local resting = assert(prepared[key], "prepared bundles carry sprite parts for placed sprite " .. tostring(key))
      local restingParts = assert(resting[1], "placed sprites carry their prepared resting frame: " .. tostring(key))
      assert(#restingParts == #cell.parts, "prepared parts match the resting cell: " .. tostring(key))
      for index, part in ipairs(cell.parts) do
        assert(type(part) == "table", "cell parts stay records")
        local source = assert(part.source, "placed parts carry their source viewport")
        local entry = assert(restingParts[index], "prepared parts cover the resting cell: " .. tostring(key))
        local viewport = assert(entry.quad, "prepared parts carry their viewport: " .. tostring(key))
        local handle = assert(entry.handle, "prepared parts carry their chrome handle: " .. tostring(key))
        local cmd = {
          kind = "part",
          handle = handle,
          quad = viewport,
          x = sprite.x + part.x,
          y = sprite.y + part.y,
          blendClass = 0,
          priority = sprite.priority,
        }
        if part.flipX == true or part.flipY == true then
          local sx, sy, ox, oy = 1, 1, 0, 0
          if part.flipX == true then
            sx, ox = -1, source.width
          end
          if part.flipY == true then
            sy, oy = -1, source.height
          end
          cmd.hasExtra = true
          cmd.r, cmd.sx, cmd.sy, cmd.ox, cmd.oy = 0, sx, sy, ox, oy
        end
        submitObjCommand(commands, cmd)
      end
    end
  end
end

-- Selects the visible animation frame for an accepted source age: a
-- single frame stays put, a one-shot rests on its last frame, and a
-- loop runs its prefix once before cycling from the authored loop
-- origin. Ages count accepted fixed updates, never wall-clock time or
-- draw calls.
---@param animation table<string, unknown> generated animation descriptor behind the subject
---@param age integer non-negative accepted age behind the intent
---@return integer 1-based visible frame index behind the age
local function frameAtOwner(animation, age)
  assert(type(age) == "number" and age % 1 == 0 and age >= 0, "animation ages stay non-negative")
  local frames = assert(animation.frames, "animations carry their frames")
  assert(type(frames) == "table" and #frames >= 1, "animations carry at least one frame")
  if #frames == 1 then
    return 1
  end
  if animation.once == true then
    local elapsed = age --[[@as number]]
    for index, frame in ipairs(frames) do
      assert(type(frame) == "table", "animation frames stay records")
      local duration = assert(frame.duration, "animation frames carry their duration")
      assert(type(duration) == "number" and duration >= 0, "animation durations stay non-negative")
      if elapsed < duration then
        return index
      end
      elapsed = elapsed - duration
    end
    return #frames
  end
  local loopFrom = animation.loopFrom or 1
  assert(
    type(loopFrom) == "number" and loopFrom % 1 == 0 and loopFrom >= 1 and loopFrom <= #frames,
    "loop origins address a frame"
  )
  local elapsed = age --[[@as number]]
  for index = 1, loopFrom - 1 do
    local duration = assert(frames[index].duration, "animation frames carry their duration")
    assert(type(duration) == "number" and duration >= 0, "animation durations stay non-negative")
    if elapsed < duration then
      return index
    end
    elapsed = elapsed - duration
  end
  local loopDuration = 0
  for index = loopFrom, #frames do
    loopDuration = loopDuration + assert(frames[index].duration, "loop frames carry their duration")
  end
  if loopDuration <= 0 then
    return #frames
  end
  elapsed = elapsed % loopDuration
  for index = loopFrom, #frames do
    local duration = assert(frames[index].duration, "loop frames carry their duration")
    if elapsed < duration then
      return index
    end
    elapsed = elapsed - duration
  end
  return #frames
end

-- Collects the detached live sprite intents as OBJ commands: each visible
-- intent resolves its page-local subject binding, selects the source
-- frame by its accepted age, and stages the prepared parts at the
-- native origin with per-part flips. The source frame pose applies in
-- cell-local coordinates before the owner pose, identically on both
-- passes. Area markers keep their source translucency class; every
-- other subject stages opaque. Footprint intents sample the prepared
-- atlas rectangle centered on the published specimen center through the
-- prepared anchor offset. No constructor runs on this path; a missing
-- prepared frame is a preparation failure.
---@param assets table<string, unknown> prepared bundle with the manifest and parts
---@param view table<string, unknown> detached projection carrying the intents
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawDynamicSprites(assets, view, role, paneId, commands)
  local objects = view.objects
  if type(objects) ~= "table" then
    return
  end
  local manifest = assert(assets.manifest, "prepared bundles carry their compiled manifest")
  local pages = assert(manifest.pages, "the compiled manifest carries its page roles")
  local page = assert(pages[role], "the compiled manifest carries the drawn page role " .. tostring(role))
  local subjects = page.spriteSubjects
  if subjects == nil then
    if #objects > 0 then
      error("the drawn page binds no live subjects: " .. tostring(role), 0)
    end
    return
  end
  local contentPane = paneId
  if paneId == "registration" then
    contentPane = "information"
  end
  local inventory = assert(manifest.sprites, "the compiled manifest carries its sprite inventory")
  local animations = assert(manifest.animations, "the compiled manifest carries its animations")
  local cells = assert(manifest.cells, "the compiled manifest carries its cells")
  local prepared = assert(assets.spriteParts, "prepared bundles carry their sprite parts")
  local footprintParts = assert(assets.footprintParts, "prepared bundles carry their footprint parts")
  for _, intent in ipairs(objects) do
    if type(intent) == "table" and intent.visible ~= false and intent.pane == contentPane then
      local subject = assert(intent.subject, "dynamic intents name their subject")
      if subject == "footprint" then
        local choice = assert(intent.choice, "footprint intents name their species")
        local part = assert(footprintParts[choice], "prepared bundles carry footprints for " .. tostring(choice))
        local anchorX = assert(part.anchorX, "footprint parts carry their center anchor for " .. tostring(choice))
        assert(type(anchorX) == "number", "footprint anchors stay numeric for " .. tostring(choice))
        local anchorY = assert(part.anchorY, "footprint parts carry their center anchor for " .. tostring(choice))
        assert(type(anchorY) == "number", "footprint anchors stay numeric for " .. tostring(choice))
        local footprintPriority = type(intent.priority) == "number" and intent.priority or 3
        submitObjCommand(commands, {
          kind = "part",
          handle = assert(part.handle, "footprint parts carry their handle"),
          quad = assert(part.quad, "footprint parts carry their quad"),
          x = intent.x + anchorX,
          y = intent.y + anchorY,
          blendClass = 0,
          priority = footprintPriority,
        })
      else
        local subjectMap = assert(subjects[subject], "the drawn page binds the subject " .. tostring(subject))
        local binding =
          assert(subjectMap[intent.choice], "the drawn subject binds the choice " .. tostring(intent.choice))
        assert(binding.pane == intent.pane, "drawn intents keep their authored pane")
        local sprite = assert(inventory[binding.sprite], "the sprite inventory carries " .. tostring(binding.sprite))
        local animation = assert(animations[sprite.animation], "drawn subjects resolve their animation")
        local frameIndex = frameAtOwner(animation, intent.age)
        local roleParts =
          assert(prepared[binding.sprite], "prepared bundles carry parts for " .. tostring(binding.sprite))
        local frameParts = assert(roleParts[frameIndex], "prepared parts cover the drawn frame")
        local frame = assert(animation.frames[frameIndex], "drawn subjects resolve their frame")
        local cell = assert(cells[frame.cell], "drawn frames resolve their cell")
        assert(#frameParts == #cell.parts, "prepared parts match the drawn cell")
        local rotation = type(intent.rotation) == "number" and intent.rotation or nil
        local scale = type(intent.scale) == "number" and intent.scale or nil
        -- The owner pose always applies outside the cell-local frame
        -- pose, even without an intent transform: a plain translate keeps
        -- the authored placement while a frame rotation still turns the
        -- part offset before the owner shift.
        local owner = {
          x = intent.x,
          y = intent.y,
          rotation = rotation,
          scale = scale,
          pivotX = type(intent.pivotX) == "number" and intent.pivotX or 0,
          pivotY = type(intent.pivotY) == "number" and intent.pivotY or 0,
        }
        local cellFrame = {
          offsetX = frame.offsetX or 0,
          offsetY = frame.offsetY or 0,
          rotation = frame.rotation or 0,
          scaleX = frame.scaleX or 1,
          scaleY = frame.scaleY or 1,
        }
        -- Area markers blink through their source translucency; every
        -- other live subject covers opaquely like its static anchor.
        local blendClass = subject == "marker" and 1 or 0
        local objPriority = type(intent.priority) == "number" and intent.priority or binding.priority
        for index, part in ipairs(cell.parts) do
          local entry = assert(frameParts[index], "prepared parts cover the drawn cell")
          local viewport = assert(entry.quad, "prepared parts carry their viewport")
          local handle = assert(entry.handle, "prepared parts carry their chrome handle")
          local source = assert(part.source, "drawn parts carry their source viewport")
          local cmd = {
            kind = "part",
            handle = handle,
            quad = viewport,
            x = part.x,
            y = part.y,
            owner = owner,
            frame = cellFrame,
            blendClass = blendClass,
            priority = objPriority,
          }
          if entry.flipX == true or entry.flipY == true then
            local sx, sy, ox, oy = 1, 1, 0, 0
            if entry.flipX == true then
              sx, ox = -1, source.width
            end
            if entry.flipY == true then
              sy, oy = -1, source.height
            end
            cmd.hasExtra = true
            cmd.r, cmd.sx, cmd.sy, cmd.ox, cmd.oy = 0, sx, sy, ox, oy
          end
          submitObjCommand(commands, cmd)
        end
      end
    end
  end
end

-- Collects one prepared icon at an explicit rectangle: the sampled art
-- with its seen/caught blend class, sharing one alpha-tested coverage on
-- both passes.
---@param icons table<string, unknown> prepared icon provider
---@param key string prepared icon key
---@param rect { x: integer, y: integer, width: integer, height: integer } destination rectangle
---@param caught boolean true for opaque caught icons
---@param commands table[] draw-local OBJ command buffer behind one pane
---@param priority integer? source mon-icon OBJ priority
---@param clip table<string, unknown>? caller clip rectangle behind the command
local function drawIconAt(icons, key, rect, caught, commands, priority, clip)
  local handle = icons:handleFor(key)
  assert(type(handle) == "table", "prepared icon keys resolve their handle: " .. key)
  local quad = nil
  if type(icons.quadFor) == "function" then
    quad = icons:quadFor(key)
  end
  local objPriority = priority
  if objPriority == nil then
    objPriority = 3
  end
  local blendClass = 1
  if caught == true then
    blendClass = 0
  end
  submitObjCommand(commands, {
    kind = "part",
    handle = handle,
    quad = quad,
    x = rect.x,
    y = rect.y,
    blendClass = blendClass,
    priority = objPriority,
    clip = clip,
  })
end

-- Collects the controls icon grid as OBJ commands: caught icons opaque,
-- seen-only icons marked for the locked seen blend, blanks untouched.
-- Only the first fifteen staged slots are visible.
---@param assets table<string, unknown> prepared bundle with the lease-owned icons
---@param grid table<string, unknown>? staged grid or results buffer behind the page
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawControlIcons(assets, grid, commands)
  if type(grid) ~= "table" then
    return
  end
  local buffers = grid.buffers
  if type(buffers) ~= "table" then
    return
  end
  local icons = assets.icons
  assert(type(icons) == "table", "icon drawing borrows the lease-owned provider")
  assert(type(icons.handleFor) == "function", "icon drawing resolves prepared handles")
  local turnClip = nil
  local turn = grid.turn
  if type(turn) == "table" and type(buffers[2]) == "table" then
    turnClip = { x = 8, y = 0, width = 240, height = 132 }
  end
  local function drawBuffer(buffer, dx)
    if type(buffer) ~= "table" or type(buffer.entries) ~= "table" then
      return
    end
    for slot = 0, PokedexRenderer.ICON_SLOTS - 1 do
      local entry = buffer.entries[slot + 1]
      if type(entry) == "table" and entry.seen == true and type(entry.species) == "string" then
        local rect = PokedexRenderer.iconSlotRect(slot)
        drawIconAt(icons, entry.species .. "/f0", {
          x = rect.x + dx,
          y = rect.y,
          width = rect.width,
          height = rect.height,
        }, entry.caught == true, commands, nil, turnClip)
      end
    end
  end
  if turnClip ~= nil then
    local direction = turn.direction == -1 and -1 or 1
    local shift = turn.offset
    drawBuffer(buffers[1], -shift * direction)
    drawBuffer(buffers[2], (120 - shift) * direction)
    return
  end
  drawBuffer(buffers[1], 0)
end

-- Native form-list icon geometry (DrawFormListIcons stages six icons
-- at x 0x30, y 14 stepping 24 per row; ShowFormCompareSprites stages
-- the compared pair at 0x40,0x50 and 0xC0,0x50): per-visible-row mon
-- icons beside the six text rows, and the compared pair beside the
-- portraits. Portraits, the side selector, and the corner frames keep
-- their existing draws. Icon art resolves outside the native sprite
-- archive, so the demanded icon keys paint here from the live forms
-- projection; a key missing from preparation fails the draw instead
-- of substituting another variant.
local FORMS_ICON_X = 32
local FORMS_ICON_FIRST_Y = -2
local FORMS_ICON_STEP_Y = 24
local COMPARE_ICON_LEFT = { x = 48, y = 64 }
local COMPARE_ICON_RIGHT = { x = 176, y = 64 }

---@param assets table<string, unknown> prepared bundle with the lease-owned icons
---@param view table<string, unknown> detached projection carrying the forms list or comparison
---@param role string manifest page role behind the pane
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawFormsIcons(assets, view, role, commands)
  local forms = view.forms
  if type(forms) ~= "table" or type(forms.variants) ~= "table" then
    return
  end
  local selection = view.selection
  local species = type(selection) == "table" and selection.species or nil
  if type(species) ~= "string" then
    return
  end
  local caught = selection.caught == true
  local icons = assets.icons
  assert(type(icons) == "table", "forms icon drawing borrows the lease-owned provider")
  assert(type(icons.handleFor) == "function", "forms icon drawing resolves prepared handles")
  local variants = forms.variants
  if role == "entry.compare" then
    local comparison = forms.comparison
    if type(comparison) ~= "table" or type(comparison.indices) ~= "table" then
      return
    end
    local indices = comparison.indices
    local spots = { COMPARE_ICON_LEFT, COMPARE_ICON_RIGHT }
    for side = 1, 2 do
      local compared = indices[side]
      if type(compared) == "number" then
        local variant = variants[math.floor(compared) + 1]
        if type(variant) == "table" and type(variant.form) == "number" then
          drawIconAt(
            icons,
            species .. "/f" .. math.floor(variant.form),
            { x = spots[side].x, y = spots[side].y, width = 32, height = 32 },
            caught,
            commands
          )
        end
      end
    end
    return
  end
  if role ~= "entry.forms" or forms.comparison ~= nil then
    return
  end
  local row = forms.row
  if type(row) ~= "number" then
    row = 0
  end
  row = math.floor(row)
  local iconOffset = 0
  if type(forms.scroll) == "table" and type(forms.scroll.iconOffset) == "number" then
    iconOffset = forms.scroll.iconOffset
  end
  for position = 1, 6 do
    local variant = variants[row + position - 1]
    if type(variant) == "table" and type(variant.form) == "number" then
      drawIconAt(icons, species .. "/f" .. math.floor(variant.form), {
        x = FORMS_ICON_X,
        y = FORMS_ICON_FIRST_Y + (position - 1) * FORMS_ICON_STEP_Y + iconOffset,
        width = 32,
        height = 32,
      }, caught, commands)
    end
  end
end

-- Draws the mon weight figure on the size page: the selected icon at the
-- simulated mon figure origin over its pan, moving with the drop, throw,
-- and escape the Size helper publishes. The trainer figure beside it rides
-- the existing trainer subject intent and the height portrait keeps its
-- sourced scale and y offset from the height draw above. The icon key
-- uses the first seen form, matching the source size icon pair.
---@param assets table<string, unknown> prepared bundle with the lease-owned icons
---@param view table<string, unknown> detached projection carrying the size simulation
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawSizeFigures(assets, view, commands)
  local size = view.size
  if type(size) ~= "table" then
    return
  end
  local figures, pans = size.figures, size.pans
  if type(figures) ~= "table" or type(pans) ~= "table" or type(pans[1]) ~= "table" then
    return
  end
  local selection = view.selection
  local species = type(selection) == "table" and selection.species or nil
  if type(species) ~= "string" then
    return
  end
  local form = type(selection.form) == "number" and math.floor(selection.form) or 0
  local figureY = nil
  local visible = false
  for _, figure in ipairs(figures) do
    if type(figure) == "table" and figure.side == "mon" then
      figureY = figure.y
      visible = figure.visible ~= false
    end
  end
  if type(figureY) ~= "number" or visible ~= true then
    return
  end
  local icons = assets.icons
  assert(type(icons) == "table", "size figure drawing borrows the lease-owned provider")
  assert(type(icons.handleFor) == "function", "size figure drawing resolves prepared handles")
  drawIconAt(
    icons,
    species .. "/f" .. form,
    { x = math.floor(pans[1].x), y = math.floor(figureY), width = 32, height = 32 },
    true,
    commands,
    0
  )
end

-- Selects the authored information rectangle for one picture slot: the
-- selected portrait on ordinary pages, the forms pair on the forms page,
-- and the comparison pair strictly by slot side, never by facing. Facing
-- selects which prepared portrait handle the bundle carries, not which
-- side receives the image.
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
    local rect = slot == 1 and PokedexRenderer.COMPARE_RIGHT_RECT or PokedexRenderer.COMPARE_LEFT_RECT
    if facing == "back" then
      return { x = rect.x, y = rect.y + backYOffset, width = rect.width, height = rect.height }
    end
    return rect
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

-- Collects one prepared picture record at an explicit rectangle as an
-- OBJ command: the Spinda canvas, sampled portrait handle, or nothing
-- for silhouettes.
---@param record table<string, unknown> prepared picture slot
---@param rect { x: integer, y: integer, width: integer, height: integer } destination rectangle
---@param commands table[] draw-local OBJ command buffer behind one pane
---@param owner table<string, unknown>? owner pose behind a scaled portrait
local function drawPictureRecordAt(record, rect, commands, owner)
  if record.mode == "silhouette" then
    return
  end
  local spinda = record.spinda
  local handle, quad = nil, nil
  if type(spinda) == "table" and spinda.canvas ~= nil then
    handle = { kind = "rgba8", image = spinda.canvas }
  else
    handle = assert(record.handle, "prepared picture slots carry their handle")
    quad = record.quad
  end
  submitObjCommand(commands, {
    kind = "part",
    handle = handle,
    quad = quad,
    x = rect.x,
    y = rect.y,
    owner = owner,
    blendClass = 0,
    priority = 3,
  })
end

-- Draws the height-comparison mon portrait from sourced geometry: the
-- prepared front portrait scaled by the catalog magnification factor
-- (256 native units per 1x, staged per species and trainer gender)
-- about the authored portrait rect's bottom center, then shifted up by the
-- catalog mon y offset (the native BG scroll is 0x10 - ypos). Absent or
-- identity geometry draws the fixed authored rect exactly, so weight-only
-- projections never change.
---@param assets table<string, unknown> prepared bundle with the entry pictures
---@param view table<string, unknown> detached projection carrying the size simulation
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawSizeHeightPortrait(assets, view, commands)
  local pictures = assets.pictures
  local record = type(pictures) == "table" and pictures[0] or nil
  if type(record) ~= "table" then
    return
  end
  local size = view.size
  local height = type(size) == "table" and size.height or nil
  local mon = type(height) == "table" and height.mon or nil
  local factor = 1
  local yOffset = 0
  if type(mon) == "table" and type(mon.yOffset) == "number" then
    yOffset = mon.yOffset
  end
  local scale = type(height) == "table" and height.scale or nil
  if type(scale) == "table" and type(scale.mon) == "number" and scale.mon > 0 then
    factor = scale.mon
  end
  local rect = {
    x = PokedexRenderer.SELECTED_PICTURE_RECT.x,
    y = PokedexRenderer.SELECTED_PICTURE_RECT.y - yOffset,
    width = PokedexRenderer.SELECTED_PICTURE_RECT.width,
    height = PokedexRenderer.SELECTED_PICTURE_RECT.height,
  }
  local owner = nil
  if factor ~= 1 then
    owner = {
      x = 0,
      y = 0,
      rotation = nil,
      scale = factor,
      pivotX = rect.x + rect.width / 2,
      pivotY = rect.y + rect.height,
    }
  end
  drawPictureRecordAt(record, rect, commands, owner)
end

-- Collects the information picture slots as OBJ commands through their
-- authored rectangles: prepared portrait quads, owned Spinda canvases, or
-- the fixed unknown silhouette policy the projection already selected.
-- Comparison slots iterate in slot order so the left record always
-- collects before the right one. Silhouette slots without prepared art
-- stay undrawn; a missing required portrait handle fails the draw
-- instead of substituting another species.
---@param pictures table<string, unknown> prepared picture records by slot
---@param role string manifest page role behind the pane
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawInformationPictures(pictures, role, commands)
  local slots = {}
  for slot in pairs(pictures) do
    slots[#slots + 1] = slot
  end
  table.sort(slots, function(left, right)
    if type(left) == "number" and type(right) == "number" then
      return left < right
    end
    return tostring(left) < tostring(right)
  end)
  for _, slot in ipairs(slots) do
    local record = pictures[slot]
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
      if rect ~= nil then
        drawPictureRecordAt(record, rect, commands, nil)
      end
    end
  end
end

-- Distinctive compact chrome behind footer and inspection-toggle
-- buttons, asserted by the compact pixel legs.
local COMPACT_CHROME = { r = 88, g = 140, b = 196 }
local COMPACT_LEFT_PICTURE = { x = 8, y = 48, width = 80, height = 80 }

-- Collects one opaque chrome rectangle as an OBJ command so the compact
-- action stays visible over its background on both passes.
---@param rect { x: integer, y: integer, width: integer, height: integer } destination rectangle
---@param commands table[] draw-local OBJ command buffer behind one pane
---@param clip table<string, unknown>? caller clip rectangle behind the command
local function fillChromeRect(rect, commands, clip)
  submitObjCommand(commands, {
    kind = "fill",
    color = COMPACT_CHROME,
    x = rect.x,
    y = rect.y,
    width = rect.width,
    height = rect.height,
    blendClass = 0,
    priority = 0,
    clip = clip,
  })
end

-- Dark inspector/row panel bytes behind compact glyphs.
local COMPACT_MATTE = { r = 16, g = 16, b = 24 }
local COMPACT_INK = { r = 255, g = 255, b = 255 }
local COMPACT_DIM = { r = 128, g = 128, b = 128 }
local COMPACT_SHADOW = { r = 0, g = 0, b = 0 }

-- Resolves the compact text palette over one painted background: white
-- glyphs with a dark shadow when enabled, dim gray when disabled. The
-- background class matches the painted surface so glyph boxes blend in
-- instead of stamping a visible text box.
---@param background table<string, integer> painted surface color behind the glyphs
---@param disabled boolean true for dimmed disabled actions
---@return table<string, table<string, number>> palette triple for the glyph renderer
local function compactPalette(background, disabled)
  local ink = COMPACT_INK
  if disabled then
    ink = COMPACT_DIM
  end
  return {
    foreground = { r = ink.r, g = ink.g, b = ink.b, a = 1 },
    shadow = { r = COMPACT_SHADOW.r, g = COMPACT_SHADOW.g, b = COMPACT_SHADOW.b, a = 1 },
    background = { r = background.r, g = background.g, b = background.b, a = 1 },
  }
end

-- Reads one prepared message role for a compact control: a missing role
-- on an enabled control fails with control attribution instead of
-- leaving a blank control; a disabled control skips silently absent
-- text like its blank native window.
---@param assets table<string, unknown> prepared bundle with the lease-owned messages
---@param role string prepared message role behind the control
---@param required boolean true when the control needs its visible mark
---@param what string control attribution behind the lookup
---@return string? prepared message behind the control
local function compactRoleText(assets, role, required, what)
  local messages = assert(assets.messages, "compact controls borrow the prepared messages")
  assert(type(messages) == "table", "prepared messages stay a record")
  local text = messages[role]
  if text == nil then
    if not required then
      return nil
    end
    error(what .. " needs its prepared message: " .. tostring(role), 0)
  end
  assert(type(text) == "string", "prepared messages stay strings: " .. tostring(role))
  return text
end

-- Collects one prepared line through the body font at its aligned offset
-- inside the caller clip as a color-only OBJ command: the glyphs ride
-- the fill beneath them and never donate metadata of their own.
---@param font table<string, unknown> prepared body font renderer
---@param text string prepared line behind the glyphs
---@param x integer region left in pane-local coordinates
---@param y integer baseline top in pane-local coordinates
---@param maxWidth integer region width bounding the alignment
---@param align string left, center, or right alignment behind the offset
---@param palette table<string, table<string, number>> glyph palette triple
---@param commands table[] draw-local OBJ command buffer behind one pane
---@param clip table<string, unknown>? caller clip rectangle behind the command
local function drawCompactLine(font, text, x, y, maxWidth, align, palette, commands, clip)
  assert(type(font.textWidth) == "function", "compact text measures its advances")
  assert(type(font.drawTextWithPalette) == "function", "compact text draws through its palette path")
  local width = font:textWidth(text)
  local dx = x
  if align == "center" then
    dx = x + math.floor((maxWidth - width) / 2)
  elseif align == "right" then
    dx = x + maxWidth - width
  end
  submitObjCommand(commands, {
    kind = "text",
    font = font,
    text = text,
    x = dx,
    y = y,
    palette = palette,
    clip = clip,
  })
end

-- Wraps one prepared paragraph to the fixed region width on space
-- boundaries: overlong single words keep their own line and clip at the
-- caller scissor instead of cutting multibyte characters.
---@param font table<string, unknown> prepared body font renderer
---@param text string prepared paragraph behind the lines
---@param maxWidth integer region width bounding the wrap
---@return string[] wrapped lines behind the paragraph
local function wrapCompactText(font, text, maxWidth)
  assert(type(font.textWidth) == "function", "compact wrapping measures its advances")
  local lines = {}
  for paragraph in (text .. "\n"):gmatch("([^\n]*)\n") do
    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      local current = ""
      for word in paragraph:gmatch("%S+") do
        local trial = word
        if current ~= "" then
          trial = current .. " " .. word
        end
        if font:textWidth(trial) <= maxWidth then
          current = trial
        else
          if current ~= "" then
            lines[#lines + 1] = current
          end
          current = word
        end
      end
      if current ~= "" then
        lines[#lines + 1] = current
      end
    end
  end
  return lines
end

-- Collects a 1px white inset border inside a selected rectangle so the
-- focused row or tab reads distinctly without covering its glyphs. The
-- strips paint color only, riding the fill metadata beneath them.
---@param rect { x: integer, y: integer, width: integer, height: integer } selected rectangle
---@param commands table[] draw-local OBJ command buffer behind one pane
local function strokeCompactSelection(rect, commands)
  local white = { r = 255, g = 255, b = 255 }
  local strips = {
    { x = rect.x, y = rect.y, width = rect.width, height = 1 },
    { x = rect.x, y = rect.y + rect.height - 1, width = rect.width, height = 1 },
    { x = rect.x, y = rect.y + 1, width = 1, height = rect.height - 2 },
    { x = rect.x + rect.width - 1, y = rect.y + 1, width = 1, height = rect.height - 2 },
  }
  for _, strip in ipairs(strips) do
    submitObjCommand(commands, {
      kind = "fill",
      bare = true,
      color = white,
      x = strip.x,
      y = strip.y,
      width = strip.width,
      height = strip.height,
      blendClass = 0,
      priority = 0,
    })
  end
end

-- Collects one bound source subject at an explicit compact position as
-- OBJ commands: the page-local sprite binding resolves its animation
-- frame by the live intent age when the view projects one, and the
-- authored parts stage centered on the destination.
---@param assets table<string, unknown> prepared bundle with the manifest and parts
---@param view table<string, unknown> detached projection carrying the live intents
---@param role string manifest page role behind the pane
---@param subject string semantic subject behind the pictogram
---@param choice string selected animation choice behind the pictogram
---@param rect { x: integer, y: integer, width: integer, height: integer } destination rectangle
---@param commands table[] draw-local OBJ command buffer behind one pane
---@param clip table<string, unknown>? caller clip rectangle behind the command
local function drawSubjectAt(assets, view, role, subject, choice, rect, commands, clip)
  local manifest = assert(assets.manifest, "compact pictograms borrow the compiled manifest")
  assert(type(manifest) == "table", "compiled manifests stay records")
  local pages = assert(manifest.pages, "the compiled manifest carries its page roles")
  local page = assert(pages[role], "compact pictograms resolve their page role " .. tostring(role))
  assert(type(page) == "table", "page roles stay records")
  local subjects = assert(page.spriteSubjects, "the drawn page binds its subjects: " .. tostring(role))
  local subjectMap = assert(subjects[subject], "the drawn page binds the subject " .. tostring(subject))
  local binding =
    assert(subjectMap[choice], "the drawn subject binds the choice " .. tostring(subject .. "/" .. choice))
  local age = 0
  if type(view.objects) == "table" then
    for _, intent in ipairs(view.objects) do
      if type(intent) == "table" and intent.subject == subject and type(intent.age) == "number" then
        age = intent.age
        break
      end
    end
  end
  local inventory = assert(manifest.sprites, "the compiled manifest carries its sprite inventory")
  local animations = assert(manifest.animations, "the compiled manifest carries its animations")
  local cells = assert(manifest.cells, "the compiled manifest carries its cells")
  local prepared = assert(assets.spriteParts, "prepared bundles carry their sprite parts")
  local sprite = assert(inventory[binding.sprite], "the sprite inventory carries " .. tostring(binding.sprite))
  local animation = assert(animations[sprite.animation], "drawn subjects resolve their animation")
  local frameParts = assert(prepared[binding.sprite], "prepared parts cover " .. tostring(binding.sprite))
  local frameIndex = frameAtOwner(animation, age)
  local parts = assert(frameParts[frameIndex], "prepared parts cover the drawn frame")
  local cell = assert(cells[animation.frames[frameIndex].cell], "drawn frames resolve their cell")
  assert(#parts == #cell.parts, "prepared parts match the drawn cell")
  local minX, minY, maxX, maxY = nil, nil, nil, nil
  for _, part in ipairs(cell.parts) do
    local source = assert(part.source, "drawn parts carry their source viewport")
    if minX == nil or part.x < minX then
      minX = part.x
    end
    if minY == nil or part.y < minY then
      minY = part.y
    end
    if maxX == nil or part.x + source.width > maxX then
      maxX = part.x + source.width
    end
    if maxY == nil or part.y + source.height > maxY then
      maxY = part.y + source.height
    end
  end
  assert(minX ~= nil, "compact pictograms span their parts")
  local artWidth, artHeight = maxX - minX, maxY - minY
  local dx = rect.x + math.floor((rect.width - artWidth) / 2) - minX
  local dy = rect.y + math.floor((rect.height - artHeight) / 2) - minY
  for index, part in ipairs(cell.parts) do
    local entry = assert(parts[index], "prepared parts cover the drawn cell")
    local quad = assert(entry.quad, "prepared parts carry their viewport")
    local handle = assert(entry.handle, "prepared parts carry their chrome handle")
    local source = assert(part.source, "drawn parts carry their source viewport")
    local cmd = {
      kind = "part",
      handle = handle,
      quad = quad,
      x = dx + part.x,
      y = dy + part.y,
      blendClass = 0,
      priority = 0,
      clip = clip,
    }
    if entry.flipX == true or entry.flipY == true then
      local sx, sy, ox, oy = 1, 1, 0, 0
      if entry.flipX == true then
        sx, ox = -1, source.width
      end
      if entry.flipY == true then
        sy, oy = -1, source.height
      end
      cmd.hasExtra = true
      cmd.r, cmd.sx, cmd.sy, cmd.ox, cmd.oy = 0, sx, sy, ox, oy
    end
    submitObjCommand(commands, cmd)
  end
end

-- Collects the fifteen compact icons into the information region plus
-- the focus ring around the cursor cell as a border that never covers
-- neighboring cells.
---@param assets table<string, unknown> prepared bundle with the lease-owned icons
---@param grid table<string, unknown>? staged grid or results buffer behind the page
---@param cursor integer? zero-based cursor slot behind the focus ring
---@param iconRects { x: integer, y: integer, width: integer, height: integer }[] compact icon rectangles
---@param cursorRects { x: integer, y: integer, width: integer, height: integer }[] compact focus rectangles
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawCompactIcons(assets, grid, cursor, iconRects, cursorRects, commands)
  if type(grid) ~= "table" or type(grid.buffers) ~= "table" then
    return
  end
  local first = grid.buffers[1]
  if type(first) ~= "table" or type(first.entries) ~= "table" then
    return
  end
  local icons = assets.icons
  assert(type(icons) == "table", "compact icon drawing borrows the lease-owned provider")
  assert(type(icons.handleFor) == "function", "compact icon drawing resolves prepared handles")
  for slot = 0, 14 do
    local entry = first.entries[slot + 1]
    if type(entry) == "table" and entry.seen == true and type(entry.species) == "string" then
      local rect = assert(iconRects[slot + 1], "the compact grid stages fifteen icon rectangles")
      drawIconAt(icons, entry.species .. "/f0", rect, entry.caught == true, commands)
    end
  end
  if type(cursor) == "number" then
    local ring = cursorRects[cursor + 1]
    if type(ring) == "table" then
      local strips = {
        { x = ring.x, y = ring.y, width = ring.width, height = 2 },
        { x = ring.x, y = ring.y + ring.height - 2, width = ring.width, height = 2 },
        { x = ring.x, y = ring.y + 2, width = 2, height = ring.height - 4 },
        { x = ring.x + ring.width - 2, y = ring.y + 2, width = 2, height = ring.height - 4 },
      }
      for _, strip in ipairs(strips) do
        fillChromeRect(strip, commands, nil)
      end
    end
  end
end

-- Collects the compact portrait as OBJ commands: the prepared entry
-- picture when the bundle carries one (comparison sides reach their own
-- halves), otherwise the selected icon at double integer scale over the
-- portrait region.
---@param assets table<string, unknown> prepared bundle with pictures and icons
---@param view table<string, unknown> detached projection selecting content
---@param compact table<string, unknown> shared compact geometry record
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawCompactPortrait(assets, view, compact, commands)
  local pictures = assets.pictures
  local comparison = nil
  if type(view.forms) == "table" then
    comparison = view.forms.comparison
  end
  if type(pictures) == "table" and comparison ~= nil then
    local left, right = pictures[0], pictures[1]
    if type(left) == "table" then
      drawPictureRecordAt(left, COMPACT_LEFT_PICTURE, commands, nil)
    end
    if type(right) == "table" then
      drawPictureRecordAt(right, compact.portraitRect, commands, nil)
    end
    return
  end
  if type(pictures) == "table" and type(pictures[0]) == "table" then
    drawPictureRecordAt(pictures[0], compact.portraitRect, commands, nil)
    return
  end
  local selection = view.selection
  local species = nil
  if type(selection) == "table" then
    species = selection.species
  end
  if type(species) ~= "string" then
    return
  end
  local icons = assets.icons
  if type(icons) ~= "table" or type(icons.handleFor) ~= "function" then
    return
  end
  local key = species .. "/f0"
  local handle = icons:handleFor(key)
  assert(type(handle) == "table", "prepared icon keys resolve their handle: " .. key)
  local quad = nil
  if type(icons.quadFor) == "function" then
    quad = icons:quadFor(key)
  end
  local rect = assert(compact.portraitRect, "the compact record carries its portrait")
  local drawn = math.floor((rect.x + rect.width / 2 - 32) / 2)
  local top = math.floor((rect.y + rect.height / 2 - 32) / 2)
  local blendClass = 1
  if selection.caught == true then
    blendClass = 0
  end
  submitObjCommand(commands, {
    kind = "part",
    handle = handle,
    quad = quad,
    x = drawn,
    y = top,
    owner = { x = 0, y = 0, rotation = nil, scale = 2, pivotX = 0, pivotY = 0 },
    blendClass = blendClass,
    priority = 0,
  })
end

-- Paints one footer button from the shared record: chrome, then the
-- source mark clipped inside it -- a bound arrow pictogram with its
-- truthful enabled/disabled choice, the selected species icon, or the
-- prepared message centered in the button. Disabled buttons dim their
-- available mark and skip silently absent marks; enabled buttons fail
-- with role attribution instead of staying blank.
---@param assets table<string, unknown> prepared bundle with messages, icons, and parts
---@param view table<string, unknown> detached projection carrying the live intents
---@param role string manifest page role behind the pane
---@param button table<string, unknown> drawn footer record with its visible mark
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawCompactButton(assets, view, role, button, commands)
  local rect = { x = button.x, y = button.y, width = button.width, height = button.height }
  fillChromeRect(rect, commands, nil)
  local disabled = button.enabled == false
  if button.iconRole == "arrow-up" or button.iconRole == "arrow-down" then
    local choice = button.iconChoice
    if choice ~= "enabled" and choice ~= "disabled" then
      choice = "enabled"
    end
    drawSubjectAt(assets, view, role, button.iconRole, choice, rect, commands, rect)
  elseif button.iconRole == "species-icon" then
    if not disabled and type(button.iconSpecies) == "string" then
      local icons = assert(assets.icons, "compact buttons borrow the lease-owned provider")
      assert(type(icons.handleFor) == "function", "compact buttons resolve prepared handles")
      local key = button.iconSpecies .. "/f0"
      local handle = icons:handleFor(key)
      assert(type(handle) == "table", "prepared icon keys resolve their handle: " .. key)
      local quad = nil
      if type(icons.quadFor) == "function" then
        quad = icons:quadFor(key)
      end
      submitObjCommand(commands, {
        kind = "part",
        handle = handle,
        quad = quad,
        x = rect.x,
        y = rect.y - 4,
        blendClass = 0,
        priority = 0,
        clip = rect,
      })
    end
  elseif button.labelRole ~= nil then
    local message = compactRoleText(assets, button.labelRole, not disabled, "compact button " .. tostring(button.id))
    if message ~= nil and message ~= "" then
      local fonts = assert(assets.fonts, "compact buttons borrow the prepared fonts")
      local font = assert(fonts.body, "compact buttons borrow the prepared body font")
      drawCompactLine(
        font,
        message,
        rect.x,
        rect.y + 4,
        rect.width,
        "center",
        compactPalette(COMPACT_CHROME, disabled),
        commands,
        rect
      )
    end
  end
  if button.selected == true then
    strokeCompactSelection(rect, commands)
  end
end

-- Paints one compact action row from the shared record: a dark panel
-- with the source label left-aligned and staged values right-aligned,
-- plus a white inset border while selected. Invisible option rows stay
-- blank like their native windows; enabled rows fail with role
-- attribution instead of staying blank.
---@param assets table<string, unknown> prepared bundle with the lease-owned messages
---@param row table<string, unknown> drawn row record with its visible roles
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawCompactRow(assets, row, commands)
  local rect = assert(row.rect, "compact rows carry their rectangle")
  submitObjCommand(commands, {
    kind = "fill",
    color = COMPACT_MATTE,
    x = rect.x,
    y = rect.y,
    width = rect.width,
    height = rect.height,
    blendClass = 0,
    priority = 0,
  })
  local disabled = row.enabled == false
  local fonts = assert(assets.fonts, "compact rows borrow the prepared fonts")
  local font = assert(fonts.body, "compact rows borrow the prepared body font")
  local palette = compactPalette(COMPACT_MATTE, disabled)
  if row.labelRole ~= nil then
    local label = compactRoleText(assets, row.labelRole, not disabled, "compact row")
    if label ~= nil and label ~= "" then
      drawCompactLine(font, label, rect.x + 2, rect.y + 1, rect.width - 4, "left", palette, commands, rect)
    end
  end
  local valueRole = row.valueRole
  if valueRole ~= nil then
    local values = {}
    if type(valueRole) == "table" then
      for _, nested in ipairs(valueRole) do
        values[#values + 1] = nested
      end
    else
      values[#values + 1] = valueRole
    end
    local staged = {}
    for _, nested in ipairs(values) do
      local value = compactRoleText(assets, nested, not disabled, "compact row value")
      if value ~= nil and value ~= "" then
        staged[#staged + 1] = value
      end
    end
    if #staged > 0 then
      drawCompactLine(
        font,
        table.concat(staged, " "),
        rect.x + 2,
        rect.y + 1,
        rect.width - 4,
        "right",
        palette,
        commands,
        rect
      )
    end
  end
  if row.selected == true then
    strokeCompactSelection(rect, commands)
  end
end

-- Collects one compact slider track from the shared record as OBJ
-- commands: the staged caption and current bound plus a white thumb at
-- the staged position. Bounds read the published criteria through the
-- same view the mapper gates, so the painted thumb and the captured
-- drag agree. The track carries metadata; the thumb paints color only.
---@param assets table<string, unknown> prepared bundle with the lease-owned messages
---@param view table<string, unknown> detached projection carrying the staged bounds
---@param slider table<string, unknown> drawn slider record with its visible roles
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawCompactSlider(assets, view, slider, commands)
  local rect = assert(slider.rect, "compact sliders carry their rectangle")
  local caption = compactRoleText(assets, slider.captionRole, true, "compact slider")
  assert(type(caption) == "string", "compact sliders paint their caption")
  local value = compactRoleText(assets, slider.valueRole, true, "compact slider bound")
  assert(type(value) == "string", "compact sliders paint their bound")
  local fonts = assert(assets.fonts, "compact sliders borrow the prepared fonts")
  local font = assert(fonts.body, "compact sliders borrow the prepared body font")
  local captionClip = { x = rect.x, y = rect.y - 18, width = rect.width, height = 18 }
  local palette = compactPalette(COMPACT_MATTE, false)
  drawCompactLine(font, caption, rect.x, rect.y - 18, rect.width, "left", palette, commands, captionClip)
  drawCompactLine(font, value, rect.x, rect.y - 18, rect.width, "right", palette, commands, captionClip)
  submitObjCommand(commands, {
    kind = "fill",
    color = COMPACT_MATTE,
    x = rect.x,
    y = rect.y,
    width = rect.width,
    height = rect.height,
    blendClass = 0,
    priority = 0,
  })
  local bound = nil
  if type(view.search) == "table" and type(view.search.criteria) == "table" then
    local criteria = view.search.criteria
    local kind = slider.target:gsub("%-min$", ""):gsub("%-max$", "")
    local staged = criteria[kind]
    if type(staged) == "table" then
      if slider.target:sub(-4) == "-min" then
        bound = staged.min
      else
        bound = staged.max
      end
    end
  end
  assert(type(bound) == "number", "compact sliders read their staged bound")
  local thumbWidth = 4
  local travel = math.max(rect.width - thumbWidth, 1)
  local thumbX = rect.x + math.floor(bound / 152 * travel + 0.5)
  submitObjCommand(commands, {
    kind = "fill",
    bare = true,
    color = { r = 255, g = 255, b = 255 },
    x = thumbX,
    y = rect.y,
    width = thumbWidth,
    height = rect.height,
    blendClass = 0,
    priority = 0,
  })
end

-- Collects the inspector close mark centered in its toggle rectangle as
-- a color-only OBJ command.
---@param assets table<string, unknown> prepared bundle with the lease-owned messages
---@param closeRect { x: integer, y: integer, width: integer, height: integer } close toggle rectangle
---@param closeRole string? prepared message role behind the close mark
---@param background table<string, integer> painted surface color behind the glyphs
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawInspectorClose(assets, closeRect, closeRole, background, commands)
  if closeRole == nil then
    return
  end
  local message = compactRoleText(assets, closeRole, true, "compact inspector close")
  if message == nil or message == "" then
    return
  end
  local fonts = assert(assets.fonts, "compact inspector borrows the prepared fonts")
  local font = assert(fonts.body, "compact inspector borrows the prepared body font")
  drawCompactLine(
    font,
    message,
    closeRect.x,
    closeRect.y + 2,
    closeRect.width,
    "center",
    compactPalette(background, false),
    commands,
    closeRect
  )
end

-- Collects the inspector body lines behind the published roles: number
-- and name, the caught-only category, wrapped source flavor, and the
-- measurements. Only roles the ready bundle actually carries produce
-- lines, so unseen selections never leak previously seen details.
---@param assets table<string, unknown> prepared bundle with the lease-owned messages
---@param roles table<string, string?> named detail roles behind the inspector
---@return string[] body lines behind the published selection
local function inspectorBodyLines(assets, roles)
  local messages = assert(assets.messages, "compact inspector borrows the prepared messages")
  assert(type(messages) == "table", "prepared messages stay a record")
  local fonts = assert(assets.fonts, "compact inspector borrows the prepared fonts")
  local font = assert(fonts.body, "compact inspector borrows the prepared body font")
  local lines = {}
  local number = type(roles.number) == "string" and messages[roles.number] or nil
  local name = type(roles.name) == "string" and messages[roles.name] or nil
  if type(number) == "string" and number ~= "" and type(name) == "string" and name ~= "" then
    local joined = number .. " " .. name
    if font:textWidth(joined) <= 240 then
      lines[#lines + 1] = joined
    else
      lines[#lines + 1] = number
      lines[#lines + 1] = name
    end
  elseif type(number) == "string" and number ~= "" then
    lines[#lines + 1] = number
  elseif type(name) == "string" and name ~= "" then
    lines[#lines + 1] = name
  end
  if type(roles.category) == "string" then
    local category = messages[roles.category]
    if type(category) == "string" and category ~= "" then
      lines[#lines + 1] = category
    end
  end
  if type(roles.flavor) == "string" then
    local flavor = messages[roles.flavor]
    if type(flavor) == "string" and flavor ~= "" then
      for _, wrapped in ipairs(wrapCompactText(font, flavor, 240)) do
        lines[#lines + 1] = wrapped
      end
    end
  end
  local measures = {}
  for _, key in ipairs({ "height", "weight" }) do
    local role = roles[key]
    if type(role) == "string" then
      local measure = messages[role]
      if type(measure) == "string" and measure ~= "" then
        measures[#measures + 1] = measure
      end
    end
  end
  if #measures == 2 then
    local joined = measures[1] .. "  " .. measures[2]
    if font:textWidth(joined) <= 240 then
      lines[#lines + 1] = joined
    else
      lines[#lines + 1] = measures[1]
      lines[#lines + 1] = measures[2]
    end
  elseif #measures == 1 then
    lines[#lines + 1] = measures[1]
  end
  return lines
end

-- Collects the compact passes for one pane on the identity transform:
-- the same committed backgrounds, windows, and text as native, then the
-- reflowed icons, portrait, inspection toggle, footer actions, and the
-- open inspection overlay drawn from the one shared geometry record.
-- OBJ contributions collect as draw-local commands in deliberate
-- collection order; the caller flushes them after the passes.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with icons, pictures, chrome, and text
---@param view table<string, unknown> detached projection carrying the shown page
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param surfaces table[] six realized serial surfaces in compositor order
---@param compact table<string, unknown> shared compact geometry record
---@param inspectOn boolean true while the inspection overlay stays open
---@param commands table[] draw-local OBJ command buffer behind one pane
local function runCompactPasses(graphics, assets, view, role, paneId, surfaces, compact, inspectOn, commands)
  assert(type(graphics.push) == "function", "compact passes preserve their graphics state")
  assert(type(graphics.origin) == "function", "compact passes draw on the identity transform")
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
    drawPageBackgrounds(graphics, assets, view, role, paneId, surfaces)
    drawDexModeLabel(graphics, assets, view, role, paneId, surfaces)
    drawPageWindowsAndText(graphics, assets, role, paneId, surfaces, view)
    if paneId == "information" then
      local geometry = assert(compact.grid, "the compact record carries its grid")
      local cursor = nil
      if type(view.grid) == "table" then
        cursor = view.grid.cursor
      end
      drawCompactIcons(assets, view.grid, cursor, geometry.iconRects, geometry.cursorRects, commands)
      drawCompactPortrait(assets, view, compact, commands)
      if type(compact.rows) == "table" then
        for _, row in ipairs(compact.rows) do
          if type(row) == "table" and type(row.rect) == "table" then
            drawCompactRow(assets, row, commands)
          end
        end
      end
      if type(compact.sliders) == "table" then
        for _, slider in ipairs(compact.sliders) do
          if type(slider) == "table" then
            drawCompactSlider(assets, view, slider, commands)
          end
        end
      end
      local toggle = assert(compact.inspectRect, "the compact record carries its toggle")
      local inspection = compact.inspection
      if type(inspection) ~= "table" then
        inspection = {}
      end
      fillChromeRect(toggle, commands, nil)
      drawInspectorClose(assets, toggle, inspection.closeRole, COMPACT_CHROME, commands)
      if inspectOn then
        submitObjCommand(commands, {
          kind = "fill",
          color = COMPACT_MATTE,
          x = 0,
          y = 0,
          width = 256,
          height = 168,
          blendClass = 0,
          priority = 0,
        })
        local roles = inspection.roles
        if type(roles) ~= "table" then
          roles = {}
        end
        local fonts = assert(assets.fonts, "compact inspector borrows the prepared fonts")
        local font = assert(fonts.body, "compact inspector borrows the prepared body font")
        local palette = compactPalette(COMPACT_MATTE, false)
        local lines = inspectorBodyLines(assets, roles)
        local panelClip = { x = 0, y = 0, width = 256, height = 168 }
        local y = 8
        for _, line in ipairs(lines) do
          if y + 16 > 128 or line == nil then
            break
          end
          if line ~= "" then
            drawCompactLine(font, line, 8, y, 240, "left", palette, commands, panelClip)
          end
          y = y + 16
        end
        drawInspectorClose(assets, toggle, inspection.closeRole, COMPACT_MATTE, commands)
      end
    elseif paneId == "controls" then
      local footer = assert(compact.footer, "the compact record carries its footer")
      assert(type(footer.buttons) == "table", "compact footers carry their buttons")
      for _, button in ipairs(footer.buttons) do
        assert(type(button) == "table", "compact footers carry their button records")
        drawCompactButton(assets, view, role, button, commands)
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

-- Pressed-control flash and entry fade drawing: the retail button
-- palettes swap normal->flash->normal over 4 ticks on the pressed rect,
-- and entry tab switches fade out/in on every plane. Flash rects are the
-- authored native controls-pane rectangles in half-open pane pixels;
-- controls without a painted rect still publish flash state and tick out.
local FLASH_RECTS = {
  ["entry-tab:area"] = { x = 7, y = 168, width = 51, height = 16 },
  ["entry-tab:size"] = { x = 71, y = 168, width = 51, height = 16 },
  ["entry-tab:forms"] = { x = 135, y = 168, width = 51, height = 16 },
  ["entry-tab:return"] = { x = 199, y = 168, width = 51, height = 16 },
  ["search-run"] = { x = 88, y = 160, width = 80, height = 32 },
  ["search-reset"] = { x = 0, y = 160, width = 80, height = 32 },
  ["search-back"] = { x = 176, y = 160, width = 80, height = 32 },
  ["search-option:order"] = { x = 128, y = 8, width = 88, height = 16 },
  ["search-option:letter"] = { x = 56, y = 32, width = 72, height = 16 },
  ["search-option:type"] = { x = 56, y = 56, width = 128, height = 16 },
  ["search-option:height"] = { x = 56, y = 80, width = 112, height = 16 },
  ["search-option:weight"] = { x = 56, y = 104, width = 160, height = 16 },
  ["search-option:area"] = { x = 56, y = 128, width = 56, height = 16 },
  ["search-option:shape"] = { x = 208, y = 56, width = 32, height = 32 },
  ["editor-ok"] = { x = 4, y = 164, width = 72, height = 24 },
  ["editor-cancel"] = { x = 180, y = 164, width = 72, height = 24 },
  ["size-restart"] = { x = 8, y = 8, width = 96, height = 24 },
  ["compare"] = { x = 200, y = 8, width = 48, height = 24 },
  ["compare-side:0"] = { x = 8, y = 140, width = 48, height = 24 },
  ["compare-side:1"] = { x = 64, y = 140, width = 48, height = 24 },
  ["compare-flip"] = { x = 120, y = 140, width = 48, height = 24 },
  ["compare-back"] = { x = 176, y = 140, width = 48, height = 24 },
}

-- Reads the painted flash rectangle behind one published flash target.
---@param flash table<string, unknown> published flash view
---@return { x: integer, y: integer, width: integer, height: integer }? painted rect, nil without authored geometry
local function flashRectFor(flash)
  if type(flash) ~= "table" or flash.active ~= true then
    return nil
  end
  local rect = FLASH_RECTS[flash.target]
  if type(rect) ~= "table" then
    return nil
  end
  return rect
end

-- Resolves the per-pane black fade behind one view: the published
-- palette fades first, then the entry fade envelope, else no fade.
---@param view table<string, unknown> detached projection carrying the visual fields
---@param paneId string browser pane identity
---@return { target: { r: integer, g: integer, b: integer }, coeff: integer } bgFade
---@return { target: { r: integer, g: integer, b: integer }, coeff: integer } objFade
local function fadeForView(view, paneId)
  local noFade = { target = { r = 0, g = 0, b = 0 }, coeff = 0 }
  local visual = type(view) == "table" and view.visual or nil
  if type(visual) ~= "table" then
    return noFade, noFade
  end
  local fades = visual.paletteFades
  if type(fades) == "table" then
    for _, entry in ipairs(fades) do
      if type(entry) == "table" and entry.pane == paneId and type(entry.coeff) == "number" then
        local target = entry.target
        if type(target) ~= "table" then
          target = { r = 0, g = 0, b = 0 }
        end
        local fade = { target = target, coeff = entry.coeff }
        return fade, fade
      end
    end
  end
  local transition = visual.transition
  if type(transition) == "table" and transition.phase == "fade" and type(transition.tick) == "number" then
    local tick = transition.tick
    local half = 4
    local coefficient = 0
    if tick < half then
      coefficient = (tick + 1) * 4
    else
      coefficient = (8 - tick) * 4
    end
    if coefficient < 0 then
      coefficient = 0
    end
    if coefficient > 16 then
      coefficient = 16
    end
    local fade = { target = { r = 0, g = 0, b = 0 }, coeff = coefficient }
    return fade, fade
  end
  return noFade, noFade
end

-- Collects one pressed-control flash as an opaque white OBJ command over
-- the pressed button, marked opaque so it composites above its
-- background.
---@param rect { x: integer, y: integer, width: integer, height: integer } painted flash rectangle
---@param commands table[] draw-local OBJ command buffer behind one pane
local function drawFlashRect(rect, commands)
  submitObjCommand(commands, {
    kind = "fill",
    color = { r = 255, g = 255, b = 255 },
    x = rect.x,
    y = rect.y,
    width = rect.width,
    height = rect.height,
    blendClass = 0,
    priority = 0,
  })
end

-- Collects the serial passes for one pane on the identity transform:
-- backgrounds, windows, and text paint immediately onto their BG planes
-- while every OBJ contribution collects as a draw-local command for the
-- caller to flush before compositing. The registration card reads its
-- staged information content the same way. A hidden popup retires every
-- sprite intent and placed sprite, including the anchored emblem, while
-- windows, chrome, and the captured picture stay.
---@param graphics table<string, unknown> host graphics namespace
---@param assets table<string, unknown> prepared bundle with icons, pictures, chrome, and text
---@param view table<string, unknown> detached projection selecting content
---@param role string manifest page role behind the pane
---@param paneId string browser pane identity
---@param surfaces table[] six realized serial surfaces in compositor order
---@param commands table[] draw-local OBJ command buffer behind one pane
---@param opts table<string, unknown>? pass options; hideSprites retires popup OBJ
local function runSerialPasses(graphics, assets, view, role, paneId, surfaces, commands, opts)
  assert(type(graphics.push) == "function", "serial passes preserve their graphics state")
  assert(type(graphics.origin) == "function", "serial passes draw on the identity transform")
  local hideSprites = type(opts) == "table" and opts.hideSprites == true
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
    drawPageBackgrounds(graphics, assets, view, role, paneId, surfaces)
    drawDexModeLabel(graphics, assets, view, role, paneId, surfaces)
    drawPageWindowsAndText(graphics, assets, role, paneId, surfaces, view)
    drawListNumbers(graphics, assets, view, role, paneId, surfaces)
    if not hideSprites then
      drawPageSprites(assets, role, paneId, commands)
      drawDynamicSprites(assets, view, role, paneId, commands)
    end
    if paneId == "controls" then
      if not hideSprites then
        drawControlIcons(assets, view.grid, commands)
        drawFormsIcons(assets, view, role, commands)
      end
      local visual = view.visual
      if type(visual) == "table" then
        local rect = flashRectFor(visual.flash)
        if rect ~= nil then
          drawFlashRect(rect, commands)
        end
      end
    elseif paneId == "information" then
      if role == "entry.size" then
        if not hideSprites then
          drawSizeHeightPortrait(assets, view, commands)
          drawSizeFigures(assets, view, commands)
        end
      else
        local pictures = assets.pictures
        if type(pictures) == "table" and not hideSprites then
          drawInformationPictures(pictures, role, commands)
        end
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
---@param bg0Fade { target: { r: integer, g: integer, b: integer }, coeff: integer }? BG0-only fade, defaults to the BG fade
---@return table<string, unknown> composite uniform record
local function compositeUniforms(manifest, role, paneId, blend, bgFade, objFade, windowActive, bg0Fade)
  local backdrop = PokedexRenderer.backdropOf(manifest, role, paneId)
  local priorities = PokedexRenderer.layerPrioritiesOf(manifest, role, paneId)
  local plane0 = bg0Fade
  if plane0 == nil then
    plane0 = bgFade
  end
  local uniforms = {
    u_backdrop = { backdrop.r / 255, backdrop.g / 255, backdrop.b / 255 },
    u_bgPriority = { priorities[1], priorities[2], priorities[3], priorities[4] },
    u_firstBits = targetMask(blend.first),
    u_secondBits = targetMask(blend.second),
    u_blend = { blend.eva, blend.evb },
    u_bgFadeTarget = { bgFade.target.r / 255, bgFade.target.g / 255, bgFade.target.b / 255 },
    u_bgFadeCoeff = bgFade.coeff,
    u_bg0FadeTarget = { plane0.target.r / 255, plane0.target.g / 255, plane0.target.b / 255 },
    u_bg0FadeCoeff = plane0.coeff,
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
  shader:send("u_bg0FadeTarget", uniforms.u_bg0FadeTarget)
  shader:send("u_bg0FadeCoeff", uniforms.u_bg0FadeCoeff)
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
-- surfaces, one OBJ flush, then one final composite per pane. Draws only
-- already prepared values and restores the borrowed graphics state even
-- when a pane raises. The footer window rule applies only while the
-- view explicitly arms the retract mask.
---@param prepared { view: table<string, unknown>, assets: table<string, unknown>, compact: table<string, unknown>? }
---@param plan table<string, unknown> the resolved application plan
function PokedexRenderer:drawBrowser(prepared, plan)
  assert(not self._released, "a released pokedex renderer draws nothing")
  checkBrowserPrepared(prepared, plan)
  local graphics = assert(self._graphics, "browser drawing requires its host graphics namespace")
  local metaShader = assert(self._metaShader, tostring(self._metaShaderFailed))
  local assets = prepared.assets --[[@as table<string, unknown>]]
  local view = prepared.view --[[@as table<string, unknown>]]
  local manifest = assert(assets.manifest, "prepared bundles carry their compiled manifest")
  local surfaces = checkSurfaces(assets)
  local compact = nil
  if type(plan.content) == "table" then
    local record = plan.content.pokedexCompact
    if type(record) == "table" then
      compact = record
    end
  end
  local inspectOn = type(prepared.compact) == "table" and prepared.compact.inspect == true
  assert(type(graphics.push) == "function", "browser drawing requires its host state stack")
  graphics.push("all")
  local ok, err = pcall(function()
    for _, pane in ipairs(plan.panes) do
      if type(pane) == "table" and (pane.id == "information" or pane.id == "controls") then
        local placement = assert(pane.placement, "browser panes carry their placement")
        local paneId = pane.id --[[@as string]]
        local role = PokedexRenderer.resolvePageRole(view, paneId)
        local commands = {}
        if compact ~= nil then
          runCompactPasses(graphics, assets, view, role, paneId, surfaces, compact, inspectOn, commands)
          flushObjCommands(graphics, metaShader, commands, surfaces, false)
        else
          runSerialPasses(graphics, assets, view, role, paneId, surfaces, commands, nil)
          flushObjCommands(graphics, metaShader, commands, surfaces, true)
        end
        local blend = PokedexRenderer.paneBlendOf(view, paneId)
        local bgFade, objFade = fadeForView(view, paneId)
        local visual = view.visual
        local windowActive = paneId == "information" and type(visual) == "table" and visual.informationClip == true
        local uniforms = compositeUniforms(manifest, role, paneId, blend, bgFade, objFade, windowActive)
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

-- The registration raster pass: the staged card backgrounds, windows,
-- and announcement paint through the serial passes while the 80x80
-- captured picture rides the BG0 plane at its published source center,
-- all unfaded except through the independently published palette and
-- picture coefficients. The picture center starts at 48 (top-left 8,32)
-- and slides to 128 (top-left 88,32); once the departure hides the
-- sprites the picture stays while the card layers remain. Draws only
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
  local metaShader = assert(self._metaShader, tostring(self._metaShaderFailed))
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
  local pictureX = view.pictureX
  if type(pictureX) ~= "number" then
    pictureX = PokedexRenderer.REGISTRATION_PICTURE_HOME
  end
  assert(type(graphics.push) == "function", "registration drawing requires its host state stack")
  graphics.push("all")
  local ok, err = pcall(function()
    for _, pane in ipairs(plan.panes) do
      if type(pane) == "table" and pane.id == "registration" then
        local placement = assert(pane.placement, "registration panes carry their placement")
        local commands = {}
        runSerialPasses(graphics, assets, view, "registration", "registration", surfaces, commands, {
          hideSprites = view.spritesHidden == true,
        })
        local outerCanvas = nil
        if type(graphics.getCanvas) == "function" then
          outerCanvas = graphics.getCanvas()
        end
        assert(type(graphics.push) == "function", "registration passes preserve their graphics state")
        assert(type(graphics.origin) == "function", "registration passes draw on the identity transform")
        graphics.push("all")
        graphics.origin()
        if view.banner == 7 then
          local page = assert(manifest.pages.registration, "the manifest carries the registration page")
          local flash = assert(page.bannerFlash, "the registration page carries its banner strip")
          local chrome = assert(assets.chrome, "prepared bundles carry their chrome handles")
          local handle = assert(chrome[flash.chrome], "prepared bundles carry the banner strip")
          local surface = assert(surfaces[flash.layer + 1], "the banner strip names a serial surface")
          graphics.setCanvas(surface.canvas)
          local previousMode = nil
          if type(graphics.getBlendMode) == "function" then
            previousMode = { graphics.getBlendMode() }
          end
          if type(graphics.setBlendMode) == "function" then
            graphics.setBlendMode("replace")
          end
          drawSampled(graphics, handle, nil, flash.x, flash.y)
          if type(graphics.setBlendMode) == "function" and previousMode ~= nil then
            graphics.setBlendMode(previousMode[1], previousMode[2])
          end
        end
        -- The captured specimen rides BG0 at its source center, never
        -- the OBJ pair: hiding the popup sprites at departure retires
        -- the anchored emblem while the centered picture stays. The
        -- picture fades only on its own coefficient.
        do
          local pictures = assets.pictures
          assert(type(pictures) == "table", "prepared card bundles carry their pictures")
          local card = assert(pictures.registration, "prepared card bundles carry their captured picture")
          assert(type(card) == "table", "prepared card slots stay records")
          local bg0 = assert(surfaces[1], "the registration picture rides BG0")
          graphics.setCanvas(bg0.canvas)
          local rectX = pictureX - PokedexRenderer.REGISTRATION_PICTURE_SIZE / 2
          local rectY = PokedexRenderer.REGISTRATION_PICTURE_Y
          local spinda = card.spinda
          if type(spinda) == "table" and spinda.canvas ~= nil then
            assert(type(graphics.setColor) == "function", "registration draws reset their tint")
            assert(type(graphics.draw) == "function", "registration draws its captured picture")
            graphics.setColor(1, 1, 1, 1)
            graphics.draw(spinda.canvas, rectX, rectY)
          else
            local handle = assert(card.handle, "prepared card slots carry their handle")
            drawSampled(graphics, handle, card.quad, rectX, rectY)
          end
        end
        graphics.setCanvas(outerCanvas)
        if type(graphics.pop) == "function" then
          graphics.pop()
        end
        -- The serial banner and picture passes above leave the caller
        -- target bound: sampling a surface while it is bound for writing
        -- is invalid and drops the card on alternating banner phases.
        flushObjCommands(graphics, metaShader, commands, surfaces, true)
        graphics.setCanvas(outerCanvas)
        local blend = { first = {}, second = {}, eva = 0, evb = 0 }
        local black = { r = 0, g = 0, b = 0 }
        -- The card inherits the battle Main/top placement but keeps the
        -- compiled information backdrop as its opaque cover color. The
        -- palette fade covers BG1-3, the backdrop, and popup OBJ while
        -- the picture fade covers BG0 alone.
        local uniforms = compositeUniforms(
          manifest,
          "registration",
          "information",
          blend,
          { target = black, coeff = paletteFade },
          { target = black, coeff = paletteFade },
          false,
          { target = black, coeff = pictureFade }
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
  local metaShader = self._metaShader
  self._metaShader = nil
  self._metaShaderFailed = nil
  if metaShader ~= nil and type(metaShader.release) == "function" then
    metaShader:release()
  end
end

return PokedexRenderer
