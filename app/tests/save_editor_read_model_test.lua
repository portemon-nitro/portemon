-- Readonly and editable Party views share derived data without owning edits.

local Assert = require("tests.support.Assert")
local ApplicationPresentation = require("libs.ui.src.ApplicationPresentation")
local Controller = require("app.src.saveeditor.SaveEditorController")
local DisplayContext = require("libs.ui.src.DisplayContext")
local Draft = require("app.src.saveeditor.SaveEditorMonDraft")
local Fixture = require("app.tests.support.SaveEditorFixture")
local CatalogFixture = require("libs.mons.tests.catalog_fixture")
local HgssMonService = require("libs.hgss.src.mons.HgssMonService")
local Interface = require("app.src.saveeditor.SaveEditorInterface")
local PartyView = require("app.src.saveeditor.SaveEditorPartyView")
local FieldInput = require("libs.hgss.src.field.FieldInput")
local ScreenTopology = require("libs.ui.src.ScreenTopology")
local State = require("app.src.saveeditor.SaveEditorState")

local T = {}

local function withParty(count)
  local fixture = Fixture.new()
  local profile = fixture.initial.playerData.profile
  local service = HgssMonService.new({
    catalog = fixture.context.monCatalog,
    bucket = fixture.initial.mons,
    profile = { name = profile.name, gender = profile.gender, trainerId = profile.trainerId },
    game = fixture.initial.versionId,
    language = fixture.context.language,
    charmap = CatalogFixture.CHARMAP,
    games = CatalogFixture.GAMES,
    languages = CatalogFixture.LANGUAGES,
    date = CatalogFixture.metDate(),
    mapSection = 7,
  })
  for index = 1, count do
    Assert.isTrue(service:giveMon({
      species = index == 1 and "EEVEE" or "CHIKORITA",
      level = index == 1 and 9 or 5,
      location = 7,
      date = CatalogFixture.metDate(),
    }))
  end
  local candidate = fixture.copy(fixture.initial)
  candidate.mons = service:capture()
  Assert.isTrue(fixture.store:save(candidate), "the Party fixture must remain canonically valid")
  fixture.initial = assert(fixture.store:load(fixture.saveId))
  local Session = require("app.src.saveeditor.SaveEditorSession")
  local session, err = Session.new({
    record = fixture.initial,
    context = fixture.context,
    saveStore = fixture.store,
    saveFs = fixture.saveFs,
    validateRecord = fixture.validateRecord,
    symbols = fixture.symbols,
  })
  Assert.isNil(err)
  return fixture, assert(session)
end

local function rowById(rows, fieldId)
  for _, row in ipairs(rows) do
    if row.id == fieldId then
      return row
    end
  end
  error("missing Party row " .. fieldId, 2)
end

local function stateFor(session, fixture, slot0)
  local controller = Controller.new()
  controller:setSection("Party")
  controller:selectPartySlot(slot0)
  local graphics = {
    getDimensions = function()
      return 256, 192
    end,
    getDPIScale = function()
      return 1
    end,
  }
  local displayContext = DisplayContext.new({
    graphics = graphics,
    topologyProvider = function(width, height)
      return ScreenTopology.oneDisplay({
        id = "main",
        rect = { x = 0, y = 0, width = width, height = height },
        touch = false,
        role = "world",
      })
    end,
  })
  local context = {
    monCatalog = fixture.context.monCatalog,
    itemCatalog = fixture.context.itemCatalog,
  }
  return setmetatable({
    width = 256,
    height = 192,
    status = "ready",
    message = "Ready",
    versionId = fixture.initial.versionId,
    saveId = fixture.initial.saveId,
    session = session,
    dependencies = {
      context = context,
    },
    partyView = PartyView.new(context),
    controller = controller,
    renderer = {
      metrics = function()
        return { lineHeight = 14, measure = function(text) return #text * 7 end }
      end,
    },
    presentation = ApplicationPresentation.new(Interface.defaults()),
    displayContext = displayContext,
    fieldInput = FieldInput.new(),
    inputTick = 0,
    scopeEpoch = 0,
    activeScopeId = nil,
    scrollOffsets = {},
    pendingLocationSave = nil,
    locationService = nil,
    monDraft = nil,
  }, State)
end

function T.readonly_and_raw_draft_rows_share_live_partial_projection()
  local fixture, session = withParty(1)
  local state = stateFor(session, fixture, 0)
  local original = session:partySnapshot().members[1].mon
  local readonly = state:_partyView()
  for _, fieldId in ipairs({ "nature", "gender", "shiny" }) do
    Assert.isFalse(
      rowById(readonly.partyRows, fieldId).value == "Unavailable",
      "readonly inspection must show the same derivations without opening Edit"
    )
  end
  state.controller:selectPartySubpage("Training")
  readonly = state:_partyView()
  Assert.isTrue(type(rowById(readonly.partyRows, "level").value) == "number")
  state.controller:selectPartySubpage("Stats")
  readonly = state:_partyView()
  Assert.isTrue(type(rowById(readonly.partyRows, "max-hp").value) == "number")

  local projectRecord = Draft.projectRecord
  Assert.isTrue(type(projectRecord) == "function", "readonly and draft views share the projection owner")
  local expected = projectRecord(original, { catalog = fixture.context.monCatalog })
  local editableTraining = rowById(PartyView.rows(state.partyView, original, expected, "Training", true), "experience")
  Assert.equal(editableTraining.editor.fieldId, editableTraining.id, "editable row identifies its raw field")
  Assert.equal(editableTraining.editor.setter, "scalar", "editable row carries its owning raw setter")
  local initialIdentity = state:_partyView().partyRows
  Assert.equal(rowById(initialIdentity, "max-hp").value, expected.stats.hp)
  local speciesOptions = rowById(PartyView.rows(state.partyView, original, expected, "Identity", true), "species").editor.options
  local cachedLabel = speciesOptions[1].label
  speciesOptions[1].label = "consumer mutation"
  Assert.equal(
    rowById(PartyView.rows(state.partyView, original, expected, "Identity", true), "species").editor.options[1].label,
    cachedLabel,
    "consumers cannot mutate the context-owned catalog choice cache"
  )

  local draft = assert(session:beginMonEdit(0))
  state.monDraft = draft
  state.controller:openPartyDraft("edit", 0)
  state.controller:selectPartySubpage("Training")
  Assert.isTrue(draft:setScalar("experience", 130))
  state.controller:selectPartySubpage("Stats")
  Assert.isTrue(draft:setIV("attack", 31))
  local rawBefore = draft:record()
  local editableProjection = draft:projection()
  state.controller:selectPartySubpage("Training")
  local updated = state:_partyView()
  Assert.equal(rowById(updated.partyRows, "level").value, editableProjection.level)
  state.controller:selectPartySubpage("Stats")
  updated = state:_partyView()
  Assert.equal(rowById(updated.partyRows, "stat:attack").value, editableProjection.stats.attack)
  Assert.deepEqual(draft:record(), rawBefore, "reading projections does not rewrite raw fields")
  Assert.isNil(draft:record().level, "derived values never become raw fields")
end

function T.snapshot_and_dirty_queries_do_not_capture_or_validate_the_whole_save()
  local fixture, session = withParty(1)
  local state = stateFor(session, fixture, 0)
  local catalogEnumerations = 0
  local originals = {}
  for _, pair in ipairs({
    { fixture.context.monCatalog, "speciesKeys" },
    { fixture.context.itemCatalog, "itemKeys" },
  }) do
    local catalog, method = pair[1], pair[2]
    local implementation = catalog[method]
    originals[#originals + 1] = { catalog = catalog, method = method, implementation = implementation }
    catalog[method] = function(self, ...)
      catalogEnumerations = catalogEnumerations + 1
      return implementation(self, ...)
    end
  end
  local captures, validations = 0, 0
  local capture = session.captureCandidate
  session.captureCandidate = function(self)
    captures = captures + 1
    return capture(self)
  end
  local validate = session._validateRecord
  session._validateRecord = function(record)
    validations = validations + 1
    return validate(record)
  end

  state:view()
  catalogEnumerations = 0
  captures, validations = 0, 0
  for _ = 1, 3 do
    state:view()
  end
  state.controller:setFocus("party:readonly:species")
  state:view()
  state:resize(320, 240)
  state:view()
  Assert.isTrue(session:setMoney(4500).changed)
  local changedView = state:view()
  Assert.isTrue(changedView.dirtySections.money)
  Assert.isTrue(changedView.dirty)
  local readCatalogEnumerations = catalogEnumerations
  local readCaptures, readValidations = captures, validations

  Assert.isTrue(session:save().ok)
  Assert.isTrue(captures > 0, "an explicit save still assembles a complete candidate")
  Assert.isTrue(validations > 0, "an explicit save still uses the authoritative validator")
  Assert.isTrue(
    readCatalogEnumerations == 0 and readCaptures == 0 and readValidations == 0,
    string.format(
      "State view/focus/resize reads must avoid catalog enumeration and whole-save work; got %d catalog enumerations, %d candidate captures, %d complete validations",
      readCatalogEnumerations,
      readCaptures,
      readValidations
    )
  )
  state.presentation:dispose()
  for _, original in ipairs(originals) do
    original.catalog[original.method] = original.implementation
  end
end

function T.raw_revisions_revert_and_owned_snapshots_do_not_leak_cached_values()
  local fixture, session = withParty(2)
  local first = assert(session:beginMonEdit(0))
  local second = assert(session:beginMonEdit(1))
  Assert.isTrue(type(first.revision) == "function", "raw edits expose a monotonic local revision")
  local initialRevision = first:revision()
  local initialPersonality = first:record().personality
  Assert.isTrue(first:setScalar("personality", initialPersonality))
  Assert.equal(first:revision(), initialRevision, "an accepted no-op does not invalidate derived reads")
  Assert.isTrue(first:setScalar("personality", initialPersonality + 1))
  local changedRevision = first:revision()
  Assert.isTrue(changedRevision > initialRevision)
  Assert.isTrue(first:setScalar("personality", initialPersonality))
  Assert.isTrue(first:revision() > changedRevision)
  Assert.isFalse(first:isDirty(), "raw equality, not monotonic revision, determines dirtiness")
  Assert.isTrue(second:setScalar("personality", first:record().personality + 1))

  local returned = first:projection()
  returned.stats.hp = -1
  Assert.isFalse(first:projection().stats.hp == -1, "projection records are owned by the caller")
  Assert.isFalse(first:projection().nature == second:projection().nature)

  local snapshot = session:snapshot()
  snapshot.flags[50000] = false
  Assert.equal(session:snapshot().flags[50000], true, "mutating a returned snapshot cannot poison a cached read")
  local beforeAdd = fixture.copy(session:captureCandidate())
  local abandoned = assert(session:beginMonAdd("EEVEE", {
    location = 7,
    date = CatalogFixture.metDate(),
  }))
  abandoned:projection()
  Assert.deepEqual(session:captureCandidate(), beforeAdd, "an abandoned Add cannot publish its candidate or RNG")
end

function T.focused_raw_field_help_is_reachable_in_the_rendered_party_plan()
  local fixture, session = withParty(1)
  local state = stateFor(session, fixture, 0)
  local mon = session:partySnapshot().members[1].mon
  local projection = Draft.projectRecord(mon, { catalog = fixture.context.monCatalog })
  local function helpFor(focusId, subpage)
    return rowById(PartyView.rows(state.partyView, mon, projection, subpage, true, focusId), "help").value
  end
  Assert.isTrue(helpFor("party:field:personality", "Identity"):find("nature", 1, true) ~= nil)
  Assert.isTrue(helpFor("party:field:trainerId", "Origin"):find("shininess", 1, true) ~= nil)
  Assert.isTrue(helpFor("party:field:iv:attack", "Stats"):find("computed stats", 1, true) ~= nil)
  Assert.equal(
    helpFor("party:field:level", "Origin"),
    "met level must track the experience-derived level"
  )
  state.controller.focus = "party:field:experience"
  local view = state:view()
  local help = rowById(view.partyRows, "help")
  Assert.equal(help.value, "Experience determines level; level, IVs, and EVs determine stats.")
  local focusable = false
  for _, targetId in ipairs(view.layout.focusOrder) do
    if targetId == "party:readonly:help" then focusable = true end
  end
  Assert.isTrue(focusable, "focused-field help has a semantic input identity")

  state.controller.focus = "party:readonly:help"
  state:_revealFocusedRow(view.layout.focusOrder)
  view = state:view()
  Assert.notNil(view.layout.targets["party:readonly:help"], "focused help is revealed for the renderer")
  local renderedHelp
  for _, row in ipairs(view.layout.rows) do
    if row.targetId == "party:readonly:help" then renderedHelp = row end
  end
  Assert.notNil(renderedHelp, "renderer layout includes the visible help row")
  Assert.equal(renderedHelp.label, "Field help")
  state.presentation:dispose()
end

return { tests = T }
