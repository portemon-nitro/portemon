-- Opening orchestration against subscript_0000_StartEncounter: the wild
-- path prints Go! immediately after the encounter line, every opening
-- send-out holds its health box until the scripted slide, the trainer
-- player throw settles like its foe throw, and the handoff leaves no
-- gauges or intro terrain behind.

local Assert = require("tests.support.Assert")
local BattleAudio = require("libs.hgss.src.audio.BattleAudio")
local BattleTimelineCore = require("game.hgss.src.battle.BattleTimeline")
local BattleTimelineFixture = require("game.hgss.tests.support.BattleTimelineFixture")

local T = {}
local TICK = 1 / 30

local function record(combatant, name, species, own, controller)
  return {
    combatant = combatant,
    participant = combatant,
    side = own and 1 or 2,
    controller = controller or (own and "player" or "wild"),
    active = true,
    position = combatant,
    activation = combatant,
    hp = 50,
    maxHp = 50,
    species = species,
    form = 0,
    name = name,
    level = 10,
    ballKey = "POKE_BALL",
    moves = { { move = "TACKLE", name = "Tackle" } },
  }
end

local function openingView()
  return {
    round = 1,
    status = "running",
    own = { record(1, "LEAD", "EEVEE", true) },
    foes = { record(3, "FOE", "CHIKORITA", false) },
    participants = {},
    playerTrainer = { classKey = "PKMN_TRAINER_ETHAN", name = "ETHAN" },
    foeTrainers = { { classKey = "YOUNGSTER", name = "JOEY" } },
    playerName = "ETHAN",
  }
end

---@param timeline table cue player under inspection
---@return table[] ordered queued cues
local function queued(timeline)
  return timeline._queue
end

---@param timeline table cue player under test driving
---@param budget integer maximum source ticks before giving up
local function drain(timeline, budget)
  for _ = 1, budget do
    timeline:update(TICK, function(_)
      return true
    end)
    if timeline:settled() then
      break
    end
  end
end

function T.wild_has_no_idle_wait_between_encounter_line_and_go()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local queue = queued(timeline)
  local encounterIndex, goIndex = nil, nil
  for index, cue in ipairs(queue) do
    if cue.kind == "message" and type(cue.text) == "string" then
      if cue.text:find("appeared!") ~= nil and encounterIndex == nil then
        encounterIndex = index
      elseif cue.text:find("Go!") ~= nil and encounterIndex ~= nil and goIndex == nil then
        goIndex = index
      end
    end
  end
  Assert.notNil(encounterIndex, "the wild opening prints its encounter line")
  Assert.notNil(goIndex, "the wild opening prints Go! after the encounter line")
  for index = encounterIndex + 1, goIndex - 1 do
    Assert.isFalse(queue[index].kind == "wait", "Go! follows the encounter line with no idle wait")
  end
end

function T.opening_reveals_hold_hud_until_their_slide()
  for _, wild in ipairs({ true, false }) do
    local timeline = BattleTimelineFixture.new({})
    local view = openingView()
    timeline:reset(view)
    timeline:intro(view, wild)
    local queue = queued(timeline)
    local reveals = {}
    for index, cue in ipairs(queue) do
      if cue.kind == "reveal" then
        reveals[#reveals + 1] = { cue = cue, index = index }
      end
    end
    Assert.isTrue(#reveals >= 1, "the opening reveals its sent-out battlers")
    for _, entry in ipairs(reveals) do
      Assert.isTrue(entry.cue.holdHud == true, "opening reveals hold their health box")
      local combatant = entry.cue.combatant
      local found = false
      for later = entry.index + 1, #queue do
        local next = queue[later]
        if next.kind == "hud-slide" and next.combatant == combatant and next.direction == "in" then
          found = true
          break
        end
      end
      Assert.isTrue(found, "combatant " .. tostring(combatant) .. " slides its health box in after its reveal")
    end
  end
end

function T.trainer_player_throw_overlaps_its_visuals_within_the_scripted_96()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)
  local queue = queued(timeline)
  local goIndex = nil
  for index, cue in ipairs(queue) do
    if cue.kind == "message" and type(cue.text) == "string" and cue.text:find("Go!") ~= nil then
      goIndex = index
      break
    end
  end
  Assert.notNil(goIndex, "the trainer opening prints Go! for the player lead")
  local throwCue, revealCue, waitCue, hasSlide = nil, nil, nil, false
  for index = goIndex + 1, #queue do
    local cue = queue[index]
    if cue.kind == "ball-throw" and throwCue == nil then
      throwCue = cue
    end
    if cue.kind == "reveal" and cue.combatant == 1 and revealCue == nil then
      revealCue = cue
    end
    if cue.kind == "wait" and waitCue == nil then
      waitCue = cue
    end
    if cue.kind == "hud-slide" and cue.combatant == 1 and cue.direction == "in" then
      hasSlide = true
    end
    if cue.kind == "opening-presentation" then
      break
    end
  end
  Assert.notNil(throwCue, "the player throw queues its ball flight")
  Assert.notNil(revealCue, "the player send-out queues its poof")
  Assert.notNil(waitCue, "the player throw holds a settle wait")
  Assert.equal(
    waitCue.duration + throwCue.nominalTicks + revealCue.duration,
    96,
    "the settle keeps 96 minus the serial visuals (throw plus poof): "
      .. "Task_ThrowPokeball and Task_PokemonSlideIn run while subscript_0000 counts"
  )
  Assert.isTrue(hasSlide, "the player health box slides in after its settle")
end

function T.wild_handoff_leaves_no_gauges_behind()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the wild opening drains fully")
  local opening = timeline:openingPresentation()
  Assert.notNil(opening, "the drained opening keeps its presentation")
  Assert.equal(opening.playerGaugeVisible, true, "the wild handoff shows the player row for command input")
  Assert.equal(opening.enemyGaugeVisible, false, "the wild handoff keeps the enemy row hidden")
end

function T.trainer_handoff_publishes_both_command_rows()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the trainer opening drains fully")
  local opening = timeline:openingPresentation()
  Assert.notNil(opening, "the drained opening keeps its presentation")
  Assert.equal(opening.playerGaugeVisible, true, "the trainer handoff shows the player row for command input")
  Assert.equal(opening.enemyGaugeVisible, true, "the trainer handoff shows the enemy row for command input")
end

function T.trainer_handoff_clears_intro_terrain()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the trainer opening drains fully")
  local opening = timeline:openingPresentation()
  Assert.notNil(opening, "the drained opening keeps its presentation")
  for _, slide in ipairs(opening.terrainSlides or {}) do
    Assert.equal(slide.visible, false, "intro terrain hands off to the battle background")
  end
end

function T.trainer_foe_ball_bursts_where_it_opens()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, false)
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the trainer intro drains fully")
  local bursts = {}
  for _, start in ipairs(timeline:takeBallParticleStarts()) do
    if type(start) == "table" and start.effect == "burst" then
      bursts[#bursts + 1] = start
    end
  end
  Assert.equal(#bursts, 2, "both throws burst where their balls open")
  local byPos = {}
  for _, burst in ipairs(bursts) do
    byPos[burst.x .. "," .. burst.y] = true
  end
  Assert.isTrue(byPos["192,86"] == true, "the foe ball bursts at its in-place open")
  Assert.isTrue(
    byPos["64,144"] == true,
    "the player ball bursts at its arc landing: BallThrow_InitThrowTarget kind 6 lands 32 below the mon spot"
  )
end

function T.wild_terrain_stays_through_the_encounter_line()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local seen = false
  for _ = 1, 3000 do
    timeline:update(TICK, function(_)
      return true
    end)
    local message = timeline:message()
    if type(message) == "string" and message:find("appeared!") ~= nil then
      seen = true
      break
    end
    if timeline:settled() then
      break
    end
  end
  Assert.isTrue(seen, "the encounter line reaches the screen")
  local opening = timeline:openingPresentation()
  Assert.notNil(opening, "the encounter line keeps its presentation")
  for _, slide in ipairs(opening.terrainSlides or {}) do
    Assert.equal(slide.visible, true, "intro terrain stays up through the encounter line")
  end
end

function T.wild_foe_slide_travels_offscreen_to_settled()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local function foeOffset()
    for _, shown in ipairs(timeline:battlers()) do
      if shown.combatant == 3 then
        return shown.pictureXOffset
      end
    end
    error("the wild foe stays installed through its slide", 0)
  end
  Assert.equal(foeOffset(), -272, "the wild foe starts offscreen at source x=-80")
  for _ = 1, 40 do
    timeline:update(TICK, function(_)
      return true
    end)
  end
  local traveled = foeOffset()
  Assert.isTrue(type(traveled) == "number" and traveled > -272, "the wild foe slides right off its start")
  Assert.isTrue(traveled <= 0, "the wild foe never overshoots its settled position")
end

---@param foes integer foe count under staging, defaulting to one
---@param own integer player-side count under staging, defaulting to one
---@return table detached opening view with doubled sides behind the intro
local function doublesView(foes, own)
  local view = openingView()
  if foes > 1 then
    view.foes[#view.foes + 1] = record(5, "FOE2", "PIDGEY", false)
    view.foeTrainers[#view.foeTrainers + 1] = { classKey = "BUG_CATCHER", name = "ARNIE" }
  end
  if own > 1 then
    view.own[#view.own + 1] = record(2, "BACKUP", "PIDGEY", true)
  end
  return view
end

---@param timeline table cue player under inspection
---@param combatant integer battler identity under lookup
---@return table[] hud-slide cues for the combatant in queue order
local function hudSlidesFor(timeline, combatant)
  local slides = {}
  for _, cue in ipairs(queued(timeline)) do
    if cue.kind == "hud-slide" and cue.combatant == combatant and cue.direction == "in" then
      slides[#slides + 1] = cue
    end
  end
  return slides
end

function T.wild_doubles_encounter_names_both_foes()
  local timeline = BattleTimelineFixture.new({})
  local view = doublesView(2, 1)
  timeline:reset(view)
  timeline:intro(view, true)
  local queue = queued(timeline)
  local line = nil
  for _, cue in ipairs(queue) do
    if cue.kind == "message" and type(cue.text) == "string" and cue.text:find("appeared!") ~= nil then
      line = cue.text
    end
  end
  Assert.notNil(line, "the wild doubles opening prints its encounter line")
  Assert.isTrue(line:find("FOE and") ~= nil, "the line names the lead foe: " .. line)
  Assert.isTrue(line:find("FOE2") ~= nil, "the line names the partner foe: " .. line)
  Assert.equal(#hudSlidesFor(timeline, 3), 1, "the lead foe slides its health box in")
  Assert.equal(#hudSlidesFor(timeline, 5), 1, "the partner foe slides its health box in")
end

function T.trainer_doubles_foe_send_out_batches_behind_one_settle()
  local timeline = BattleTimelineFixture.new({})
  local view = doublesView(2, 1)
  timeline:reset(view)
  timeline:intro(view, false)
  local queue = queued(timeline)
  local lines = {}
  local waits, throws, reveals, slides = {}, {}, {}, {}
  local inFoeBatch = false
  for _, cue in ipairs(queue) do
    if
      cue.kind == "message"
      and type(cue.text) == "string"
      and (cue.text:find("sent out") ~= nil or cue.text:find("sent\nout") ~= nil)
    then
      lines[#lines + 1] = cue.text
      inFoeBatch = true
    elseif inFoeBatch then
      if cue.kind == "ball-throw" or cue.kind == "trainer-exit" then
        throws[#throws + 1] = cue
      elseif cue.kind == "reveal" and cue.combatant ~= 1 then
        reveals[#reveals + 1] = cue
      elseif cue.kind == "wait" then
        waits[#waits + 1] = cue
      elseif cue.kind == "hud-slide" and (cue.combatant == 3 or cue.combatant == 5) then
        slides[#slides + 1] = cue
        if #slides == 2 then
          inFoeBatch = false
        end
      end
    end
  end
  Assert.equal(#lines, 1, "the foe send-out prints once for the batch")
  Assert.isTrue(lines[1]:find("FOE") ~= nil and lines[1]:find("FOE2") ~= nil, "the line names both foes")
  Assert.equal(#throws, 2, "each foe exits its trainer")
  Assert.equal(#reveals, 2, "both foes poof in")
  Assert.equal(#waits, 1, "the batch settles once behind the scripted WaitTime 112")
  Assert.equal(#slides, 2, "both foe boxes slide in")
  local visualTicks = 0
  for _, cue in ipairs(throws) do
    visualTicks = visualTicks + assert(cue.nominalTicks, "throws carry their nominal ticks")
  end
  for _, cue in ipairs(reveals) do
    visualTicks = visualTicks + cue.duration
  end
  Assert.equal(
    waits[1].duration + visualTicks,
    112,
    "the settle keeps 112 minus the batched visuals, so the boxes land on the retail tick"
  )
end

function T.trainer_doubles_player_go_names_both_mons_and_clamps_its_settle()
  local timeline = BattleTimelineFixture.new({})
  local view = doublesView(1, 2)
  timeline:reset(view)
  timeline:intro(view, false)
  local queue = queued(timeline)
  local goIndex = nil
  for index, cue in ipairs(queue) do
    if cue.kind == "message" and type(cue.text) == "string" and cue.text:find("Go!") ~= nil then
      goIndex = index
      Assert.isTrue(cue.text:find("BACKUP") ~= nil, "Go! names the partner: " .. cue.text)
      break
    end
  end
  Assert.notNil(goIndex, "the trainer doubles opening prints Go! for the player pair")
  local arcOnly = 0
  local waitDuration = nil
  local slides = 0
  for index = goIndex + 1, #queue do
    local cue = queue[index]
    if cue.kind == "ball-throw" then
      if cue.arcOnly == true then
        arcOnly = arcOnly + 1
      end
    elseif cue.kind == "wait" and waitDuration == nil then
      waitDuration = cue.duration
    elseif cue.kind == "hud-slide" and cue.direction == "in" then
      slides = slides + 1
    elseif cue.kind == "opening-presentation" then
      break
    end
  end
  Assert.equal(arcOnly, 1, "the partner arcs from the first throw's release point")
  Assert.equal(
    waitDuration,
    0,
    "two player arcs cannot fit inside WaitTime 96, so the settle clamps to zero "
      .. "and the box lands as soon as the visuals finish"
  )
  Assert.equal(slides, 2, "both player boxes slide in")
end

function T.wild_doubles_player_go_stays_singular()
  local timeline = BattleTimelineFixture.new({})
  local view = doublesView(2, 2)
  timeline:reset(view)
  timeline:intro(view, true)
  local queue = queued(timeline)
  local lines = {}
  for _, cue in ipairs(queue) do
    if cue.kind == "message" and type(cue.text) == "string" and cue.text:find("Go!") ~= nil then
      lines[#lines + 1] = cue.text
    end
  end
  -- subscript_0000 prints plain msg_0197_00979 on the wild path even for
  -- doubles; only trainer intros vary the Go! line.
  Assert.equal(#lines, 1, "the wild doubles opening prints one Go! line")
  Assert.isTrue(lines[1]:find(" and") == nil, "the wild Go! stays singular: " .. lines[1])
end

-- subscript_0000_StartEncounter never waits for a cry: the wild foe's
-- encounter task retires once its mon animation starts playing
-- (Task_PokemonEncounter waits only for anim state 1, still unfinished)
-- while PlayMonAnimAndCry's delayed cry overlaps the box slide and the
-- encounter line. The encounter line and the handoff therefore proceed
-- with an unfinished foe cry, and no acknowledgement is required
-- anywhere in the intro: both waits are timed and skippable.
function T.wild_intro_overlaps_unfinished_cries_without_acknowledgement()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local function soundComplete(_)
    return false
  end
  local sawEncounter = false
  local sawGo = false
  local settled = false
  for _ = 1, 3000 do
    timeline:update(TICK, function(_)
      return true
    end, soundComplete)
    local message = timeline:message()
    if type(message) == "string" and message:find("appeared!", 1, true) ~= nil then
      sawEncounter = true
    end
    if type(message) == "string" and message:find("Go!", 1, true) ~= nil then
      sawGo = true
    end
    if timeline:settled() then
      settled = true
      break
    end
  end
  Assert.isTrue(sawEncounter, "the encounter line prints with the foe cry still unfinished")
  Assert.isTrue(sawGo, "Go! follows the encounter line with an unfinished player cry")
  Assert.isTrue(settled, "the intro reaches its handoff with every voice still unfinished")
  Assert.isTrue(
    (timeline:message():find("Go!", 1, true) ~= nil),
    "the handoff keeps the Go! line up: " .. timeline:message()
  )
  local foeCries, ownCries = 0, 0
  for _, cue in ipairs(timeline:drainSounds()) do
    if type(cue) == "table" and cue.kind == "cry" then
      if cue.foe == true then
        foeCries = foeCries + 1
      else
        ownCries = ownCries + 1
      end
    end
  end
  Assert.equal(foeCries, 1, "the wild foe still cries once, overlapping the line")
  Assert.equal(ownCries, 1, "the player lead still cries once, overlapping the handoff")
end

-- Retail follow-mon openings (OpponentData_ThrowPokeball with a set
-- follow slot runs Task_ThrowPokeballWithFollowMon, and the send-out
-- runs Task_FollowMonSlideIn): the trainer walks off with no ball, no
-- seal, and no ball sound behind it, and the follower appears with no
-- ball-color poof before its cry.
function T.follower_lead_skips_the_ball_but_walks_the_trainer_off()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  view.followMonSlot = 0
  view.own[1].slot = 0
  timeline:reset(view)
  timeline:intro(view, true)
  local queue = queued(timeline)
  local throws = {}
  for _, cue in ipairs(queue) do
    if cue.kind == "ball-throw" then
      throws[#throws + 1] = cue
    end
  end
  Assert.equal(#throws, 1, "the follower send-out still walks the trainer off behind one throw cue")
  Assert.isTrue(
    throws[1].noBall == true,
    "the follower slides in with no ball behind it: Task_FollowMonSlideIn runs no BallThrow"
  )
  Assert.isTrue(
    type(BattleAudio.SINK_SOUNDS.followerSlide) == "string",
    "the follower slide has its staged switch sound"
  )
  local slideSounds = 0
  for _, cue in ipairs(queue) do
    if cue.kind == "sound" and type(cue.cue) == "table" then
      Assert.isTrue(cue.cue.symbol ~= BattleAudio.SINK_SOUNDS.ballOpen, "no ball sound voices without a ball opening")
      if cue.cue.symbol == BattleAudio.SINK_SOUNDS.followerSlide then
        slideSounds = slideSounds + 1
        Assert.equal(
          cue.cue.pan,
          BattleAudio.SIDE_PAN.player,
          "the slide switch sound voices on the player side"
        )
      end
    end
    if cue.kind == "ball-particles" then
      Assert.isTrue(cue.effect ~= "seal", "no seal sparkle starts without a ball opening")
    end
    if cue.kind == "reveal" and cue.combatant == 1 then
      Assert.equal(
        cue.duration,
        BattleTimelineCore.FOLLOW_SLIDE_TICKS,
        "the follower slides home over the source 20 ticks: Task_FollowMonSlideIn places it full-size on the edge"
      )
    end
  end
  Assert.equal(slideSounds, 1, "the anim-41 slide voices its switch sound once")
  drain(timeline, 3000)
  Assert.isTrue(timeline:settled(), "the follower opening drains fully")
  Assert.equal(#timeline:takeBallParticleStarts(), 0, "no ball effects start for the follower")
  local opening = timeline:openingPresentation()
  Assert.notNil(opening, "the drained opening keeps its presentation")
  Assert.equal(opening.playerTrainerVisible, false, "the trainer still leaves with the follower")
end

-- BallThrow_InitThrowTarget for the player send-out kinds (6/8/7): the
-- ball lands on the mon's screen spot plus 32 pixels, per side type.
function T.player_arcs_target_the_mon_spot_per_side_type()
  local timeline = BattleTimelineFixture.new({})
  local view = openingView()
  timeline:reset(view)
  timeline:intro(view, true)
  local singles = {}
  for _, cue in ipairs(queued(timeline)) do
    if cue.kind == "ball-throw" then
      singles[#singles + 1] = cue
    end
  end
  Assert.equal(#singles, 1, "the singles opening throws once")
  Assert.equal(singles[1].targetX, 64, "the solo arc lands on the player mon spot")
  Assert.equal(singles[1].targetY, 144, "the solo arc lands 32 pixels below the mon anchor")
  local doubled = BattleTimelineFixture.new({})
  local two = doublesView(1, 2)
  doubled:reset(two)
  doubled:intro(two, true)
  local arcs = {}
  for _, cue in ipairs(queued(doubled)) do
    if cue.kind == "ball-throw" then
      arcs[#arcs + 1] = cue
    end
  end
  Assert.equal(#arcs, 2, "the doubles opening throws once per player mon")
  Assert.equal(arcs[1].targetX, 40, "the first slot arcs to its own mon spot")
  Assert.equal(arcs[1].targetY, 144, "the first slot lands 32 pixels below its mon anchor")
  Assert.equal(arcs[2].targetX, 80, "the partner arcs to its own mon spot")
  Assert.equal(arcs[2].targetY, 152, "the partner lands 32 pixels below its mon anchor")
end

-- Doubles with a follower lead: the first throw walks the trainer off
-- with no ball, and the partner still arcs from its own release point.
function T.follower_lead_doubles_still_arcs_the_partner()
  local timeline = BattleTimelineFixture.new({})
  local view = doublesView(1, 2)
  view.followMonSlot = 0
  view.own[1].slot = 0
  timeline:reset(view)
  timeline:intro(view, true)
  local throws = {}
  for _, cue in ipairs(queued(timeline)) do
    if cue.kind == "ball-throw" then
      throws[#throws + 1] = cue
    end
  end
  Assert.equal(#throws, 2, "both player send-outs queue their throw")
  Assert.isTrue(throws[1].noBall == true, "the follower lead throws no ball")
  Assert.isTrue(throws[2].arcOnly == true, "the partner arcs without its own windup")
  Assert.equal(throws[2].targetX, 80, "the partner arc keeps its own mon spot")
  Assert.equal(throws[2].targetY, 152, "the partner arc keeps its own landing")
  local queue = queued(timeline)
  local goIndex = nil
  for index, cue in ipairs(queue) do
    if cue.kind == "message" and type(cue.text) == "string" and cue.text:find("Go!") ~= nil then
      goIndex = index
      break
    end
  end
  Assert.notNil(goIndex, "the wild doubles opening prints Go!")
  local playerWaits = {}
  for index = goIndex + 1, #queue do
    if queue[index].kind == "wait" then
      playerWaits[#playerWaits + 1] = queue[index]
    end
  end
  Assert.equal(#playerWaits, 1, "the doubles opening settles once")
  Assert.equal(
    playerWaits[1].duration,
    4,
    "the settle keeps 96 minus the serial visuals (21 exit plus 20 slide for the follower, 39 arc plus 12 reveal for the partner)"
  )
end

-- Task_FollowMonSlideIn holds a doubles second-slot follower twelve
-- ticks before placing it (battle_controller_opponent.c state 1): the
-- slide still runs its full twenty ticks once the hold releases.
function T.follower_partner_waits_twelve_ticks_before_sliding()
  local timeline = BattleTimelineFixture.new({})
  local view = doublesView(1, 2)
  view.followMonSlot = 1
  view.own[2].slot = 1
  timeline:reset(view)
  timeline:intro(view, true)
  local reveal = nil
  for _, cue in ipairs(queued(timeline)) do
    if cue.kind == "reveal" and cue.combatant == 2 then
      reveal = cue
    end
  end
  Assert.notNil(reveal, "the follower partner queues its send-out reveal")
  Assert.equal(
    reveal.duration,
    12 + BattleTimelineCore.FOLLOW_SLIDE_TICKS,
    "the hold plus the slide keep the source thirty-two ticks"
  )
  Assert.equal(
    reveal.slideOffset,
    -160,
    "the partner starts 160 px left of its spot (offscreen -80 to home 80)"
  )
  local revealTicks = 0
  local done = false
  local seenHidden = false
  local seenTravel = false
  for _ = 1, 4000 do
    if timeline:messageActive() then
      timeline:ack()
    end
    timeline:update(TICK, function(_)
      return true
    end)
    if timeline._active == reveal then
      revealTicks = revealTicks + 1
      local shown = nil
      for _, entry in ipairs(timeline:battlers()) do
        if entry.combatant == 2 then
          shown = entry
        end
      end
      Assert.notNil(shown, "the follower partner stays pictured through its reveal")
      if revealTicks <= 12 then
        seenHidden = seenHidden or shown.visible ~= true
      elseif shown.visible == true then
        seenTravel = seenTravel
          or (type(shown.pictureXOffset) == "number" and shown.pictureXOffset < 0)
      end
    elseif revealTicks > 0 then
      done = true
      break
    end
  end
  Assert.isTrue(done, "the follower partner reveal completes")
  Assert.isTrue(seenHidden, "the partner stays hidden through the twelve-tick hold")
  Assert.isTrue(seenTravel, "the partner travels horizontally once the hold releases")
  local settled = nil
  for _, entry in ipairs(timeline:battlers()) do
    if entry.combatant == 2 then
      settled = entry
    end
  end
  Assert.isTrue(settled ~= nil and settled.visible == true, "the partner stays out after its slide")
  Assert.isNil(settled ~= nil and settled.pictureXOffset or nil, "the slide settles exactly on its row")
  Assert.isTrue(reveal.animStarted == true, "the partner still starts its animation with its reveal")
  -- The cry voices after the default species delay through the
  -- side-channel countdown, even past the short slide reveal.
  for _ = 1, 8 do
    timeline:update(TICK, function(_)
      return true
    end)
  end
  local cried = false
  for _, cue in ipairs(timeline:drainSounds()) do
    if type(cue) == "table" and cue.kind == "cry" then
      cried = true
    end
  end
  Assert.isTrue(cried, "the partner still cries after its delay")
end

return { tests = T }
