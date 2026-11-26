-- Message provider tests over a resident bank store and the selected runtime's
-- source acquirer: active bank lifetime, immutable templates, substitution
-- formatting, and the resident source interest behind each open bank.

local Assert = require("tests.support.Assert")
local Errors = require("libs.errors.src.Errors")
local FieldMessageProvider = require("libs.hgss.src.interaction.FieldMessageProvider")
local FieldMessageText = require("libs.assets.src.field.FieldMessageText")
local FieldMessageFixture = require("tests.support.FieldMessageFixture")
local CacheFs = require("libs.storage.src.CacheFs")
local AssetPreparationQueue = require("libs.hgss.src.presentation.AssetPreparationQueue")
local ResidentAssetCache = require("libs.hgss.src.field.ResidentAssetCache")
local FieldMessageCache = require("libs.assets.src.field.FieldMessageCache")
local ResidentCache = require("libs.storage.src.ResidentCache")

local T = {}

-- One glyph per message whose display text is the message id, so a template's
-- rendered text identifies the message it came from.
local function bankMessages(messageCount)
  local messages = {}
  for id = 0, messageCount - 1 do
    messages[#messages + 1] = {
      FieldMessageFixture.glyph(0x0121 + id, string.char(48 + id)),
      FieldMessageFixture.eos(),
    }
  end
  return messages
end

-- The resident bank store a selected session would have installed: the provider
-- reads these bytes directly, so no test copies a bank payload.
---@param counts table<integer, integer>
local function cacheWith(counts)
  local banks = {}
  for bankId, messageCount in pairs(counts) do
    banks[bankId] = bankMessages(messageCount)
  end
  return FieldMessageFixture.resident("heartgold", banks).reader
end

-- A selected preparation queue over the resident reader; compact acquisition
-- needs no worker, so the fake thread host stays unused.
local function selectedQueue(cache)
  return AssetPreparationQueue.new(cache, {
    decoded = ResidentAssetCache.new({ idleByteLimit = 0, release = function() end }),
  })
end

-- The provider with the selected queue's base source branch behind it.
local function providerWith(cache, acquireSource)
  local queue = selectedQueue(cache)
  local provider = assert(FieldMessageProvider.new(cache, {
    acquireSource = acquireSource or function(reference)
      return queue:acquireSource(reference)
    end,
  }))
  return provider
end

local function glyph(code, text)
  return { kind = "glyph", code = code, text = text, raw = { code } }
end

local function eos()
  return { kind = "eos", raw = { 0xFFFF } }
end

local function color(args)
  local raw = { 0xFFFE, 0xFF00, #args }
  for _, arg in ipairs(args) do
    raw[#raw + 1] = arg
  end
  return { kind = "style", control = 0xFF00, name = "COLOR", args = args, raw = raw }
end

local function yesno(args)
  local raw = { 0xFFFE, 0x0200, #args }
  for _, arg in ipairs(args) do
    raw[#raw + 1] = arg
  end
  return { kind = "focus_indicator", control = 0x0200, name = "YESNO", args = args, raw = raw }
end

local function template(messageId, tokens)
  return { bankId = 543, messageId = messageId, text = "", tokens = tokens }
end

-- Active acquisition is the only bank lifetime: references are counted
-- while consumers hold the bank, the final release removes its record instead
-- of leaving an idle copy behind, and a returned template never depends on the
-- record that produced it.
function T.release_ends_the_active_acquisition_without_invalidating_returned_templates()
  local cache = cacheWith({ [542] = 2, [543] = 2 })
  local openedReads = 0
  local queue = selectedQueue(cache)
  local provider = assert(FieldMessageProvider.new(cache, {
    acquireSource = function(reference)
      openedReads = openedReads + 1
      return queue:acquireSource(reference)
    end,
  }))

  local bank = assert(provider:acquireBank(542))
  Assert.equal(bank.bankId, 542)
  Assert.equal(provider:stats().loads, 1)
  Assert.equal(provider:acquireBank(542), bank, "two active acquisitions share one bank view")
  Assert.equal(provider:stats().hits, 1)
  Assert.equal(provider:stats().references, 2)
  assert(provider:acquireBank(543), "another bank is acquired independently")
  Assert.equal(provider:stats().live, 2)

  local template = assert(provider:get(542, 1))
  local formatted = provider:format(template, {})
  Assert.equal(formatted.text, "1")

  provider:releaseBank(542)
  Assert.equal(provider:stats().references, 2, "a partial release keeps the active record")
  Assert.equal(assert(provider:get(542, 1)).text, "1", "a still-acquired bank keeps serving its messages")

  provider:releaseBank(542)
  Assert.equal(provider:stats().live, 1, "the final release removes only that bank's record")
  Assert.equal(provider:stats().disposals, 1)

  local formattedAfterRelease = provider:format(template, {})
  Assert.deepEqual(formattedAfterRelease.tokens, formatted.tokens, "a returned template outlives its bank record")
  Assert.equal(formattedAfterRelease.text, "1")

  local readsBeforeGet = openedReads
  local missing, err = provider:get(542, 1)
  Assert.isNil(missing)
  Assert.equal(assert(err).code, FieldMessageProvider.MESSAGE_BANK_NOT_ACQUIRED)
  Assert.equal(openedReads, readsBeforeGet, "a get on an unacquired bank reads no bytes")

  assert(provider:acquireBank(542), "a released bank is opened again on reacquisition")
  Assert.equal(provider:stats().loads, 3, "the reacquisition is the third new bank view")
  Assert.equal(openedReads, readsBeforeGet + 1, "reacquisition reads the compact payload again")
  local reopenedTemplate = assert(provider:get(542, 1))
  Assert.deepEqual(reopenedTemplate.tokens, template.tokens, "reacquisition decodes the same message")
  Assert.equal(reopenedTemplate.text, template.text)
  Assert.equal(template.text, "1", "the earlier template stays unchanged across release and reacquisition")
  Assert.equal(provider:stats().live, 2)

  provider:dispose()
  Assert.equal(provider:stats().live, 0, "dispose releases every active record")
  Assert.equal(provider:stats().references, 0)
  Assert.equal(provider:stats().loads, 0, "a disposed provider reports no stale loads")
  Assert.equal(provider:stats().hits, 0, "a disposed provider reports no stale hits")
  Assert.equal(provider:stats().disposals, 0, "a disposed provider reports no stale disposals")
  local disposed, disposedErr = provider:get(543, 0)
  Assert.isNil(disposed)
  Assert.equal(assert(disposedErr).code, FieldMessageProvider.MESSAGE_BANK_NOT_ACQUIRED)
  Assert.equal(provider:format(template, {}).text, "1", "disposal never invalidates a returned template")
end

-- A bank is borrowed from the selected resident source: acquisition takes one
-- interest over the bytes the resident store already owns, the returned
-- template is self-contained, and the final release (or a failed open) returns
-- that interest exactly once instead of leaving an idle compact copy behind.
function T.bank_acquisition_borrows_the_resident_source_and_returns_it_once()
  local version = "heartgold"
  local sourceId = "base:message-provider-source"
  local banks = { [542] = FieldMessageFixture.encode(FieldMessageFixture.bank(542, bankMessages(2))) }
  banks[543] = assert(love.data.newByteData("G4MS not a readable bank"))
  local store = ResidentCache.new(version, sourceId)
  local entries = {}
  for bankId, data in pairs(banks) do
    local path = FieldMessageCache.bankPath(bankId)
    entries[#entries + 1] = {
      path = path,
      data = data,
      size = data:getSize(),
      sourceId = sourceId,
      contentId = version .. "\0" .. path,
    }
  end
  store:commit(store:prepare(entries))
  local cache = CacheFs.fromStore(store)

  local acquisitions, releases, borrowed = 0, 0, {}
  local function acquireSource(reference)
    Assert.notNil(reference, "a compact bank must resolve its resident reference before it is borrowed")
    acquisitions = acquisitions + 1
    borrowed[#borrowed + 1] = reference.data
    local lease = { value = reference.data }
    function lease:release()
      if self.value == nil then
        return
      end
      self.value = nil
      releases = releases + 1
    end
    return lease
  end

  local provider = assert(FieldMessageProvider.new(cache, { acquireSource = acquireSource }))
  local bank = assert(provider:acquireBank(542), "an acquired resident bank yields its compact view")
  Assert.equal(bank.messageCount, 2, "the borrowed bank keeps its message count")
  Assert.equal(acquisitions, 1, "acquiring a bank takes exactly one resident source interest")
  Assert.isTrue(borrowed[1] == banks[542], "the bank is opened over the bytes the resident store owns")

  local template = assert(provider:get(542, 1))
  Assert.equal(template.text, "1", "the selected message still formats from the borrowed bank")
  provider:acquireBank(542)
  Assert.equal(acquisitions, 1, "a repeated acquisition reuses the active bank interest")
  provider:releaseBank(542)
  Assert.equal(releases, 0, "one remaining reference keeps the resident interest alive")
  provider:releaseBank(542)
  Assert.equal(releases, 1, "the final bank release returns its source interest exactly once")
  Assert.equal(provider:stats().live, 0, "no idle compact bank copy survives the final release")
  Assert.equal(provider:format(template, {}).text, template.text, "a returned template outlives its bank source")

  local malformed, malformedErr = provider:acquireBank(543)
  Assert.isNil(malformed, "an unreadable bank yields no view")
  Assert.equal(assert(malformedErr).code, "MESSAGE_BANK_MISSING")
  Assert.equal(acquisitions, 2, "a malformed bank still acquires its staged source")
  Assert.equal(releases, 2, "a failed open returns the staged source interest immediately")
  Assert.equal(provider:stats().live, 0, "a failed open installs no bank record")

  assert(provider:acquireBank(542))
  provider:dispose()
  Assert.equal(releases, 3, "disposal returns every still-active source interest exactly once")
end

function T.get_returns_immutable_templates_and_bounds_errors()
  local provider = providerWith(cacheWith({ [543] = 3 }))
  provider:acquireBank(543)
  local firstTemplate = assert(provider:get(543, 1))
  Assert.equal(firstTemplate.bankId, 543)
  Assert.equal(firstTemplate.messageId, 1)
  Assert.equal(firstTemplate.text, "1") -- modder-facing text rides on the template
  Assert.equal(firstTemplate.tokens[1].kind, "glyph")

  local missing, err = provider:get(543, 9)
  Assert.isNil(missing)
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "MESSAGE_ID_OUT_OF_RANGE")

  local unacquired, unacquiredErr = provider:get(542, 0)
  Assert.isNil(unacquired)
  Assert.equal(assert(unacquiredErr).code, "MESSAGE_BANK_NOT_ACQUIRED")
end

function T.missing_bank_artifact_is_typed()
  local provider = providerWith(cacheWith({}))
  local bank, err = provider:acquireBank(542)
  Assert.isNil(bank)
  Assert.isTrue(Errors.is(err))
  Assert.equal(assert(err).code, "MESSAGE_BANK_MISSING")
end

function T.format_substitutes_before_wrapping_and_never_mutates()
  local provider = providerWith(cacheWith({ [542] = 1 }))
  provider:acquireBank(542)
  local formattedTemplate = assert(provider:get(542, 0))
  local context = { playerName = "GOLD" }
  local fontDef = {
    charmap = {
      ["G"] = 0x0131,
      ["O"] = 0x013B,
      ["L"] = 0x0138,
      ["D"] = 0x012E,
    },
  }
  local resolvers = {
    [0x0103] = function(_, _, ctx)
      return FieldMessageProvider.asciiGlyphTokens(ctx.playerName, fontDef)
    end,
  }
  local formatted = provider:format(formattedTemplate, context, resolvers)
  Assert.isFalse(formatted.hadUnresolvedSubstitutions)
  Assert.equal(formatted.messageId, 0)
  Assert.equal(formatted.text, "0")

  -- A substitution token spliced in stays glyph-kind and ordered.
  local withSub = provider:format({
    bankId = 542,
    messageId = 0,
    text = "{STRVAR_1 3, 0, 0}",
    tokens = {
      { kind = "substitution", control = 0x0103, args = { 0, 0 }, raw = { 0xFFFE, 0x0103, 0x0002, 0, 0 } },
      { kind = "eos", raw = { 0xFFFF } },
    },
  }, context, resolvers)
  Assert.equal(#withSub.tokens, 5) -- G O L D + eos
  Assert.equal(withSub.tokens[1].text, "G")
  Assert.equal(withSub.tokens[4].text, "D")
  -- The formatted asset carries the substituted display text.
  Assert.equal(withSub.text, "GOLD")

  -- The template is untouched by formatting.
  Assert.equal(#formattedTemplate.tokens, 2)
end

function T.unresolved_substitution_stays_visible_and_traced()
  local provider = providerWith(cacheWith({ [542] = 1 }))
  local tokens = {
    { kind = "substitution", control = 0x0103, args = { 0, 0 }, raw = { 0xFFFE, 0x0103, 0x0002, 0, 0 } },
    { kind = "eos", raw = { 0xFFFF } },
  }
  local formatted = provider:format({ bankId = 542, messageId = 0, tokens = tokens }, {})
  Assert.isTrue(formatted.hadUnresolvedSubstitutions)
  Assert.equal(formatted.tokens[1].kind, "substitution")
  Assert.equal(formatted.tokens[1].control, 0x0103)
end

function T.ascii_glyph_tokens_cover_the_demo_name()
  -- The text->code mapping comes from the generated font definition's
  -- charmap metadata, never from a runtime reference import.
  local fontDef = { charmap = { ["G"] = 0x0131, ["O"] = 0x013B, ["L"] = 0x0138, ["D"] = 0x012E, ["é"] = 0x0188 } }
  local tokens = assert(FieldMessageProvider.asciiGlyphTokens("GOLD", fontDef))
  Assert.equal(#tokens, 4)
  Assert.equal(tokens[1].code, 0x0131) -- 'G'
  Assert.equal(tokens[4].code, 0x012E) -- 'D'
  local bad, err = FieldMessageProvider.asciiGlyphTokens("GOLD!", fontDef)
  Assert.isNil(bad)
  Assert.equal(assert(err).code, "MESSAGE_SUBSTITUTION_UNRESOLVED")
  local accented = assert(FieldMessageProvider.asciiGlyphTokens("é", fontDef))
  Assert.equal(accented[1].code, 0x0188)
end

function T.dispose_releases_everything()
  local provider = providerWith(cacheWith({ [542] = 1 }))
  provider:acquireBank(542)
  provider:dispose()
  Assert.equal(provider:stats().live, 0)
end

function T.prepared_glyphs_carry_the_default_color()
  local provider = providerWith(cacheWith({}))
  local formatted = provider:format(template(4, { glyph(0x0121, "A"), eos() }), {})
  Assert.equal(#formatted.tokens, 2)
  Assert.equal(formatted.tokens[1].kind, "glyph")
  Assert.equal(formatted.tokens[1].colorIndex, 0, "plain glyphs use the source default color")
end

function T.prepared_glyphs_follow_ordinary_color_spans()
  local provider = providerWith(cacheWith({}))
  local formatted = provider:format(
    template(5, {
      glyph(0x0121, "A"),
      color({ 1 }),
      glyph(0x0121, "B"),
      color({ 0 }),
      glyph(0x0121, "C"),
      eos(),
    }),
    {}
  )
  local colors = {}
  for _, token in ipairs(formatted.tokens) do
    if token.kind == "glyph" then
      colors[#colors + 1] = token.colorIndex
    end
  end
  Assert.deepEqual(colors, { 0, 1, 0 })
  -- The zero-width COLOR controls stay in the stream at source position.
  local active = {}
  for _, token in ipairs(formatted.tokens) do
    if token.kind == "style" then
      active[#active + 1] = token.args[1]
    end
  end
  Assert.deepEqual(active, { 1, 0 })
end

function T.substitution_replacement_glyphs_inherit_the_active_color()
  local provider = providerWith(cacheWith({}))
  local fontDef = { charmap = { ["X"] = 0x0121 } }
  local formatted = provider:format(
    template(6, {
      color({ 1 }),
      { kind = "substitution", control = 0x0103, args = { 0, 0 }, raw = { 0xFFFE, 0x0103, 0x0002, 0, 0 } },
      color({ 0 }),
      eos(),
    }),
    {},
    {
      [0x0103] = function()
        return FieldMessageProvider.asciiGlyphTokens("XX", fontDef)
      end,
    }
  )
  local colors = {}
  for _, token in ipairs(formatted.tokens) do
    if token.kind == "glyph" then
      colors[#colors + 1] = token.colorIndex
    end
  end
  Assert.deepEqual(colors, { 1, 1 }, "replacement glyphs inherit the color active at the substitution")
end

function T.color_save_and_swap_follow_source_state()
  local provider = providerWith(cacheWith({}))
  local formatted = provider:format(
    template(7, {
      color({ 2 }),
      color({ 105 }), -- save color 5; active color stays 2
      color({ 1 }),
      color({ 0xFF }), -- swap active and saved: 5 active, 1 saved
      glyph(0x0121, "A"),
      eos(),
    }),
    {}
  )
  local last = formatted.tokens[#formatted.tokens - 1]
  Assert.equal(last.kind, "glyph")
  Assert.equal(last.colorIndex, 5, "the glyph after a swap uses the restored color")

  -- A first 0xFF with nothing saved captures the current color (0) instead.
  local boot = provider:format(
    template(8, {
      color({ 0xFF }),
      color({ 2 }),
      color({ 0xFF }), -- swap back to 0
      glyph(0x0121, "B"),
      eos(),
    }),
    {}
  )
  Assert.equal(boot.tokens[#boot.tokens - 1].colorIndex, 0)
end

function T.valid_indicator_fields_survive_as_zero_width_tokens()
  local provider = providerWith(cacheWith({}))
  local formatted = provider:format(
    template(9, {
      yesno({ 0 }),
      yesno({ 1 }),
      yesno({ 2 }),
      yesno({ 3 }),
      glyph(0x0121, "A"),
      eos(),
    }),
    {}
  )
  local fields = {}
  for _, token in ipairs(formatted.tokens) do
    if token.kind == "focus_indicator" then
      fields[#fields + 1] = token.args[1]
    end
  end
  Assert.deepEqual(fields, { 0, 1, 2, 3 })
  Assert.equal(formatted.tokens[1].control, FieldMessageText.YESNO)
end

function T.invalid_indicator_arguments_are_typed()
  local provider = providerWith(cacheWith({}))
  for _, spec in ipairs({
    { args = {}, label = "missing argument" },
    { args = { 0, 1 }, label = "extra arguments" },
    { args = { -1 }, label = "negative field" },
    { args = { 4 }, label = "field at the frame count" },
    { args = { 0.5 }, label = "non-integer field" },
  }) do
    local err = Assert.throws(function()
      provider:format(template(10, { yesno(spec.args), eos() }), {})
    end, "YESNO " .. spec.label .. " must be rejected")
    Assert.isTrue(Errors.is(err))
    Assert.equal(err.code, FieldMessageProvider.MESSAGE_CONTROL_ARGUMENT_INVALID)
    Assert.equal(err.context.bankId, 543)
    Assert.equal(err.context.messageId, 10)
    Assert.equal(err.context.control, FieldMessageText.YESNO)
  end
end

function T.invalid_color_arguments_are_typed()
  local provider = providerWith(cacheWith({}))
  for _, spec in ipairs({
    { args = {}, label = "missing argument" },
    { args = { 1, 2 }, label = "extra arguments" },
    { args = { 7 }, label = "beyond the palette count" },
    { args = { 99 }, label = "mid range" },
    { args = { 107 }, label = "save index past 106" },
    { args = { 254 }, label = "near the swap sentinel" },
    { args = { 256 }, label = "above a byte" },
  }) do
    local err = Assert.throws(function()
      provider:format(template(11, { color(spec.args), eos() }), {})
    end, "COLOR " .. spec.label .. " must be rejected")
    Assert.isTrue(Errors.is(err))
    Assert.equal(err.code, FieldMessageProvider.MESSAGE_CONTROL_ARGUMENT_INVALID)
    Assert.equal(err.context.bankId, 543)
    Assert.equal(err.context.messageId, 11)
    Assert.equal(err.context.control, FieldMessageText.COLOR)
  end
end

function T.unsupported_printer_controls_are_typed_rejections()
  local provider = providerWith(cacheWith({}))
  local cases = {
    { kind = "wait", control = 0x0202, name = "WAIT", args = {}, raw = { 0xFFFE, 0x0202, 0 }, label = "PAUSE/WAIT" },
    {
      kind = "style",
      control = 0xFF02,
      name = "UNK_FF02",
      args = { 1, 0 },
      raw = { 0xFFFE, 0xFF02, 2, 1, 0 },
      label = "UNK_FF02",
    },
    -- The inline cursor offsets (CURSOR_X/CURSOR_Y) are the one consumed
    -- family: this port's line printer has no mid-line offset, so it drops the
    -- control instead of faulting (see the dedicated row-rendering case).
    {
      kind = "unsupported_control",
      control = 0x0707,
      name = nil,
      args = {},
      raw = { 0xFFFE, 0x0707, 0 },
      label = "unknown control",
    },
  }
  for _, spec in ipairs(cases) do
    local token = {
      kind = spec.kind,
      control = spec.control,
      name = spec.name,
      args = spec.args,
      raw = spec.raw,
    }
    local err = Assert.throws(function()
      provider:format(template(12, { token, eos() }), {})
    end, spec.label .. " must be rejected at playback preparation")
    Assert.isTrue(Errors.is(err))
    Assert.equal(err.code, FieldMessageProvider.MESSAGE_CONTROL_UNSUPPORTED)
    Assert.equal(err.context.bankId, 543)
    Assert.equal(err.context.messageId, 12)
    Assert.equal(err.context.control, spec.control)
    Assert.equal(err.context.kind, spec.kind)
    Assert.equal(err.context.name, spec.name)
    Assert.deepEqual(err.context.args, spec.args)
  end
end

local function size(args)
  return { kind = "style", control = 0xFF01, name = "SIZE", args = args, raw = { 0xFFFE, 0xFF01, #args, unpack(args) } }
end

-- SIZE 200 stretches the glyphs after it until SIZE 100 restores them.
function T.size_controls_toggle_glyph_stretching()
  local provider = providerWith(cacheWith({}))
  local formatted = provider:format(
    template(14, {
      glyph(0x0121, "A"),
      size({ 200 }),
      glyph(0x0122, "B"),
      size({ 100 }),
      glyph(0x0123, "C"),
      eos(),
    }),
    {}
  )
  local stretched = {}
  for _, token in ipairs(formatted.tokens) do
    if token.kind == "glyph" then
      stretched[#stretched + 1] = token.stretched == true
    end
  end
  Assert.deepEqual(stretched, { false, true, false })
end

function T.size_controls_reject_unknown_arguments()
  local provider = providerWith(cacheWith({}))
  for _, args in ipairs({ {}, { 150 }, { 100, 1 } }) do
    local err = Assert.throws(function()
      provider:format(template(15, { size(args), glyph(0x0121, "A"), eos() }), {})
    end)
    Assert.equal(err.code, FieldMessageProvider.MESSAGE_CONTROL_ARGUMENT_INVALID)
  end
end

function T.formatting_is_immutable_across_reuse()
  local provider = providerWith(cacheWith({}))
  local source = template(13, {
    color({ 1 }),
    { kind = "substitution", control = 0x0103, args = { 0, 0 }, raw = { 0xFFFE, 0x0103, 0x0002, 0, 0 } },
    glyph(0x0121, "A"),
    color({ 0 }),
    eos(),
  })
  local fontDef = { charmap = { ["X"] = 0x0121 } }
  local resolvers = {
    [0x0103] = function()
      return FieldMessageProvider.asciiGlyphTokens("X", fontDef)
    end,
  }
  local first = provider:format(source, {}, resolvers)
  local second = provider:format(source, { playerName = "other" }, resolvers)
  local third = provider:format(source, {}, resolvers)
  Assert.deepEqual(second.tokens, first.tokens, "a later format never changes a prior result")
  Assert.deepEqual(third.tokens, first.tokens, "re-formatting the same template is deterministic")
  for _, token in ipairs(source.tokens) do
    Assert.isNil(token.colorIndex, "a template token must never gain runtime color metadata")
  end
  for _, token in ipairs(first.tokens) do
    if token.kind == "glyph" then
      Assert.equal(token.colorIndex, 1)
    end
  end
end

-- The standard menu bank's parent rows place their level text with an inline
-- cursor offset ({CURSOR_X 90}); this port's line printer draws one
-- left-aligned line per message, so the control is consumed instead of
-- faulting and every glyph keeps its source order.
function T.inline_cursor_offsets_are_consumed_by_the_line_printer()
  local tokens = {
    { kind = "glyph", code = 0x012B, raw = { 0x012B }, text = "A" },
    { kind = "unsupported_control", control = 0x0203, args = { 90 }, raw = { 0x0203, 90 } },
    { kind = "glyph", code = 0x012C, raw = { 0x012C }, text = "B" },
    { kind = "eos", raw = { 0xFFFF } },
  }
  local provider = providerWith(cacheWith({}))
  local formatted = provider:format({ bankId = 191, messageId = 136, tokens = tokens }, {})
  Assert.isFalse(formatted.hadUnresolvedSubstitutions)
  local texts = {}
  for _, token in ipairs(formatted.tokens) do
    if token.kind == "glyph" then
      texts[#texts + 1] = token.text
    end
  end
  Assert.deepEqual(texts, { "A", "B" }, "the offset leaves no fault and keeps the glyph order")
end

return { tests = T }
