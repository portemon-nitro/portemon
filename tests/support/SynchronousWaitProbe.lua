-- Deterministic stand-in for the worker a synchronous scene entry blocks on:
-- it counts the polls the borrower issues against a shared image owner, refuses
-- an unbounded hot-poll loop, and replies to the owner after a fixed number of
-- sleeps. Readiness is therefore driven by the wait primitive itself, never by
-- wall-clock timing, and a regression back to busy-polling fails with a clear
-- count instead of hanging the suite.

local SynchronousWaitProbe = {}
SynchronousWaitProbe.__index = SynchronousWaitProbe

---@class SynchronousWaitProbe
---@field owner table shared image owner whose polls and replies the probe drives
---@field polls integer polls the borrower issued so far
---@field sleeps integer sleeps the wait primitive performed so far
---@field pollLimit integer polls allowed before the wait counts as busy-polling
---@field publishAfterSleeps integer sleep that publishes every pending owner ticket
---@field installed boolean

---@param owner table shared image owner providing poll and publish
---@param opts { pollLimit: integer?, publishAfterSleeps: integer? }?
---@return SynchronousWaitProbe
function SynchronousWaitProbe.new(owner, opts)
  opts = opts or {}
  assert(type(owner) == "table" and type(owner.poll) == "function", "the probe needs a pollable image owner")
  assert(type(owner.publish) == "function", "the probe needs an owner it can reply through")
  return setmetatable({
    owner = owner,
    polls = 0,
    sleeps = 0,
    pollLimit = opts.pollLimit or 64,
    publishAfterSleeps = opts.publishAfterSleeps or 2,
    installed = false,
  }, SynchronousWaitProbe)
end

-- Watch the borrower's polls and the wait primitive. A borrower that spins
-- instead of sleeping exceeds the poll limit and fails here.
function SynchronousWaitProbe:install()
  assert(not self.installed, "the synchronous wait probe is already installed")
  self.installed = true
  local owner = self.owner
  local poll = owner.poll
  owner.poll = function(inner, token)
    self.polls = self.polls + 1
    assert(
      self.polls <= self.pollLimit,
      "the synchronous wait polled the shared owner " .. self.polls .. " times without sleeping"
    )
    return poll(inner, token)
  end
  local timer = assert(love and love.timer, "the synchronous wait probe requires love.timer")
  local sleep = timer.sleep
  timer.sleep = function(seconds)
    self.sleeps = self.sleeps + 1
    if self.sleeps == self.publishAfterSleeps then
      owner:publish()
    end
    return sleep(seconds)
  end
  self._poll, self._sleep = poll, sleep
end

-- Restore the owner and the host timer. Idempotent.
function SynchronousWaitProbe:restore()
  if not self.installed then
    return
  end
  self.installed = false
  self.owner.poll = self._poll
  love.timer.sleep = self._sleep
  self._poll, self._sleep = nil, nil
end

return SynchronousWaitProbe
