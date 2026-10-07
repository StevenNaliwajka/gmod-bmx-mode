--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sv_bot.lua

    A bot that rides a BMX and does tricks.

        bmx_bot_spawn [bike]     a bot rider on a bike where you are looking
        bmx_bot_remove           every bot rider gone (and their ramps)
        bmx_bot_trick <name>     the bots do that trick next
        bmx_bot_status           what each bot has tried and landed

        bmx_bot_name   "Peter Griffin"   what the bot is called
        bmx_bot_model  ""                its player model; empty keeps the default

    THE MODEL IS NOT IN THIS ADDON. The addon is public and ships no content
    that is not its own (README, "Licence and content"). A server that wants
    the bot to look like somebody mounts that player model itself -- from the
    Workshop, say -- and points bmx_bot_model at it.

    HOW IT RIDES. The bot is an ordinary bot player sitting on an ordinary
    bike. It does not touch the simulation: it writes the same bike.input a
    rider's keys produce (exactly as the headless harness does, through the
    BMXScripted seam in sv_input.lua), so whatever it can do, a player can.
    Steering is the bike's own: lean, and the lean derives the steer.

    HOW IT DOES TRICKS. Each trick is a coroutine (Bot.Tricks) that finds
    somewhere to do it, rides there, does it, and reports what the ADDON'S OWN
    SCORING said happened -- BMX_TricksLanded and BMX_ComboEnded -- rather than
    what the bot thinks it did. An air trick needs a launch: the bot looks for
    a ramp in the world first (BMX.FindLaunch: a map's kicker, a funbox, a prop
    somebody tilted) and only if there is none puts its own kicker down.

    THE AIR CONTROLLER is the interesting part. A flip is scored as a full
    turn of the spin integral, and landed only if the wheels come down first;
    so the bot predicts when it will touch down and paces the rotation to
    finish just past one turn as it gets there, then brakes the spin.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.Bot = BMX.Bot or {}
local Bot = BMX.Bot

Bot.brains = Bot.brains or {}

local cvName  = CreateConVar("bmx_bot_name", "Peter Griffin", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    "BMX: what a bot rider spawned by bmx_bot_spawn is called.")
local cvModel = CreateConVar("bmx_bot_model", "", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    "BMX: player model for bot riders (empty = the default). The server must have it mounted.")

local TAU = math.pi * 2
local UP = Vector(0, 0, 1)

-- The order the show runs in, and the names the scoring uses.
Bot.TrickList = { "Bunny Hop", "Wheelie", "Stoppie", "Combo", "Backflip",
                  "Frontflip", "Barrel Roll", "360", "Crank Grind", "Double Peg Grind",
                  "Tailwhip", "Barspin", "Superman", "Superman Backflip" }

Bot.Config = {
    -- The run at a launch is SPRINTED (Drive.sprintTorque / sprintCadence):
    -- stopping at the start and pedalling up to 340 reached the lip well
    -- short of it, and 1.06 s of air on a real server is not enough to flip.
    flipSpeed  = 400,   -- u/s wanted at a launch's lip, for the air tricks
    stageBack  = 1100,  -- u behind a launch's foot where the run at it starts
    grindShift = 0,     -- u sideways a grind hop adds (it was not systematic: see the preload hold)
    roamRadius = 3000,  -- u out the bot looks for room to do a trick in
    roamStep   = 300,   -- u between rings of places it looks at
    roamAngles = 10,    -- places looked at on each ring
    margin     = 0.08,  -- rad past a full turn the air controller aims for
    landPitch  = math.rad(10),  -- nose-up attitude a flip is levelled to
    attKp      = 60,    -- attitude hold after a flip, 1/s^2
    attKd      = 14,    -- 1/s
    settle     = 0.15,  -- s before touchdown the spin should be finished
    spinGain   = 9,     -- 1/s, rate loop gain in the air
    -- 1.6: finish the turn early and hold the attitude for the landing. At
    -- 1.35 a backflip on the live park came down 8 degrees short: the ground
    -- it landed on was higher than predicted, so the touchdown came early.
    ahead      = 1.6,   -- how far ahead of an on-time spin to run
    brakeShare = 1.0,   -- of an axis's full braking the pacing counts on
    landRate   = 4,     -- rad/s of spin a landing on the wheels can soak
    attempts   = 3,     -- per trick, before the bot gives up on it
    -- STUCK: busy (a trick running, or off the bike) yet within stuckMove of
    -- one spot for stuckTime is stuck -- wedged on a ledge, a nav route that
    -- never arrives, a bike on its side that will not right. It gives up the
    -- trick and is put back upright on open ground. Standing still on purpose
    -- (resting between tricks, waiting a turn) is not busy and never counts.
    stuckEscape = 4,    -- s without progress before it tries to get itself out
    stuckTime  = 10,    -- s before it gives that up too and is put back on open ground
    stuckMove  = 64,    -- u
    stuckFall  = 2000,  -- u below home: fell out of the world, reset at once
    outOfWorldTime = 1.5, -- s the engine must keep saying "not in the world" before that counts
}

--------------------------------------------------------------------------
-- Brains
--------------------------------------------------------------------------
local Brain = {}
Brain.__index = Brain
Bot.Brain = Brain    -- sv_botnav.lua routes it on the navmesh

function Bot.Attach(ply, bike, opts)
    opts = opts or {}
    local b = setmetatable({
        ply = ply, bike = bike, home = opts.home or bike:GetPos(),
        scored = {}, combos = {}, results = {}, log = {}, props = {},
        allowSpawnRamp = opts.allowSpawnRamp ~= false,
        allowFindRamp  = opts.allowFindRamp ~= false,
        quiet = opts.quiet or false,
        wasScripted = ply.BMXScripted,
    }, Brain)
    ply.BMXScripted = true
    ply.BMXBotBrain = b
    Bot.brains[ply] = b
    b:set({})
    return b
end

function Bot.Detach(b)
    if not b then return end
    for _, e in ipairs(b.props) do SafeRemoveEntity(e) end
    b.props = {}
    if IsValid(b.bike) and b.bike.input then b:set({}) end
    if IsValid(b.ply) then
        b.ply.BMXBotBrain = nil
        b.ply.BMXScripted = b.wasScripted
    end
    Bot.brains[b.ply] = nil
    b.job = nil
end

function Brain:say(msg)
    self.log[#self.log + 1] = string.format("%.2f %s", CurTime(), msg)
    if #self.log > 200 then table.remove(self.log, 1) end
end

-- Write the bike's input the way a rider's keys would. Omitted is neutral.
function Brain:set(t)
    local i = self.bike.input
    if not i then return end
    i.throttle    = t.throttle   or 0
    i.brakeRear   = t.brakeRear  or 0
    i.brakeFront  = t.brakeFront or 0
    i.leanTarget  = t.lean       or 0
    i.pitchTarget = t.pitch      or 0
    i.tuck        = t.tuck       or false
    i.sprint      = t.sprint     or false
    i.wheelieMod  = t.wheelieMod or false
    -- Frame and bar spins and style poses (sv_tricks.lua).
    i.whip        = t.whip or 0
    i.bar         = t.bar or 0
    i.pose        = t.pose
end

function Brain:st() return self.bike.st or {} end
function Brain:speed() return self:st().speed or 0 end
function Brain:yaw() return self.bike:GetAngles().y end
function Brain:riding() return IsValid(self.bike) and self.bike:GetDriver() == self.ply end

-- What the scoring paid since `t0`, by trick name.
function Brain:scoredSince(t0, name)
    for _, s in ipairs(self.scored) do
        if s.t >= t0 and (not name or s.name == name) then return s end
    end
end
function Brain:comboSince(t0)
    for _, c in ipairs(self.combos) do
        if c.t >= t0 and c.landed and c.n >= 2 then return c end
    end
end

hook.Add("BMX_TricksLanded", "BMX.Bot.Score", function(ent, driver, tricks)
    local b = IsValid(driver) and driver.BMXBotBrain
    if not b or b.bike ~= ent then return end
    for _, t in ipairs(tricks) do
        b.scored[#b.scored + 1] = { t = CurTime(), name = t.name, count = t.count, points = t.points }
        b:say("scored " .. t.name)
    end
end)

hook.Add("BMX_Crashed", "BMX.Bot.Crash", function(ent, driver, reason, severity)
    local b = IsValid(driver) and driver.BMXBotBrain
    if b and b.bike == ent then b:say(string.format("crash: %s (%.2f)", tostring(reason), severity or 0)) end
end)

hook.Add("BMX_ComboEnded", "BMX.Bot.Combo", function(ent, driver, c, landed, bonus)
    local b = IsValid(driver) and driver.BMXBotBrain
    if not b or b.bike ~= ent then return end
    b.combos[#b.combos + 1] = { t = CurTime(), n = c.n, landed = landed, bonus = bonus }
end)

--------------------------------------------------------------------------
-- Riding. All of these run inside a trick's coroutine and yield a tick.
--------------------------------------------------------------------------
local function tick() coroutine.yield() end

-- Lean to bring the bike's heading to `want` (degrees). The bike turns the
-- way it leans (D, +, is right, and right is yaw going DOWN), so the lean is
-- against the heading error, damped by the yaw rate so it does not weave.
function Brain:steerLean(want)
    local err = math.AngleDifference(want, self:yaw())
    local w = self:st().angVel
    local yawRate = w and math.deg(w.z) or 0
    return math.Clamp(-err / 25 + yawRate / 260, -1, 1), err
end

-- Throttle and brake toward a target speed.
function Brain:pace(target)
    local v = self:speed()
    if v < target then return math.Clamp((target - v) / 45 + 0.3, 0, 1), 0 end
    if v > target + 40 then return 0, 0.6 end
    if v > target + 12 then return 0, 0.2 end
    return 0.15, 0
end

-- Heading that brings the bike onto the line through `a` along `dir`.
function Brain:lineHeading(a, dir)
    local p = self.bike:GetPos()
    local rel = p - a
    local lateral = dir.x * rel.y - dir.y * rel.x       -- + is left of the line
    local lineYaw = math.deg(math.atan2(dir.y, dir.x))
    -- On a grind run the line matters to a few units, but a stiff gain
    -- weaves, and a bike that takes off weaving leaves the rail's line at an
    -- angle: firmer, and allowed only a small correction.
    if self.tightLine then
        return lineYaw - math.Clamp(lateral * 0.8, -10, 10), lateral, rel:Dot(dir)
    end
    return lineYaw - math.Clamp(lateral * 0.5, -35, 35), lateral, rel:Dot(dir)
end

-- Ride along a line at `speed` until `done()` says so or `timeout` passes.
-- `extra(t)` may return fields to merge into the input (tuck, pitch, ...).
function Brain:rideLine(a, dir, speed, done, timeout, extra)
    local t0 = CurTime()
    while CurTime() - t0 < (timeout or 10) do
        if not self:riding() then return false, "off the bike" end
        local want, lateral, along = self:lineHeading(a, dir)
        local lean = self:steerLean(want)
        local thr, brk = self:pace(speed)
        local inp = { throttle = thr, brakeRear = brk, lean = lean }
        if extra then for k, v in pairs(extra(CurTime() - t0, along, lateral) or {}) do inp[k] = v end end
        -- In the air A/D are roll, not steering: a line held through a hop
        -- rolled the bike 68 u off a rail and onto its side.
        local st = self:st()
        if st.airMode or not st.grounded then
            inp.lean = inp.airLean or 0
            inp.throttle = 0
        end
        inp.airLean = nil
        -- Braking on the front wheel, a lean is a fall: hold the line only as
        -- hard as the speed can carry (a combo's stoppie tipped over at 62 u/s).
        if (inp.brakeFront or 0) > 0 then inp.lean = inp.lean * math.Clamp(self:speed() / 250, 0, 1) * 0.5 end
        self:set(inp)
        if done and done(along, lateral) then return true end
        tick()
    end
    return false, "timed out"
end

-- Ride to a point and stop near it.
function Brain:rideTo(p, speed, radius, timeout)
    local t0 = CurTime()
    local stuckSince = nil
    while CurTime() - t0 < (timeout or 15) do
        if not self:riding() then return false, "off the bike" end
        -- Stuck (against something, wheels spinning): no use waiting out
        -- the whole timeout.
        if self:speed() < 8 and CurTime() - t0 > 2 then
            stuckSince = stuckSince or CurTime()
            if CurTime() - stuckSince > 2.5 then return false, "stuck on the way to the spot" end
        else
            stuckSince = nil
        end
        local d = p - self.bike:GetPos()
        d.z = 0
        local dist = d:Length()
        if dist < (radius or 60) then
            self:set({ brakeRear = 1 })
            return true
        end
        local want = math.deg(math.atan2(d.y, d.x))
        local lean, err = self:steerLean(want)
        -- A big turn is taken slowly: lean-steering cannot turn round on the
        -- spot at speed, and walking pace steers directly.
        local target = math.min(speed, math.abs(err) > 90 and 60 or (math.abs(err) > 40 and 140 or speed))
        if dist < 250 then target = math.min(target, 90 + dist * 0.4) end
        local thr, brk = self:pace(target)
        self:set({ throttle = thr, brakeRear = brk, lean = lean })
        tick()
    end
    return false, "could not reach the spot"
end

-- Stop and stand still.
function Brain:stop(timeout)
    local t0 = CurTime()
    while self:speed() > 10 and CurTime() - t0 < (timeout or 4) do
        self:set({ brakeRear = 1, brakeFront = 0.3 })
        tick()
    end
    self:set({})
end

function Brain:wait(s)
    local t0 = CurTime()
    while CurTime() - t0 < s do tick() end
end

-- Wait until the bike has been on the ground (or off the bike) for `hold`.
function Brain:waitLanded(hold, timeout)
    local t0, since = CurTime(), nil
    while CurTime() - t0 < (timeout or 4) do
        if not self:riding() then return false end
        if self:st().grounded and not self:st().airMode then
            since = since or CurTime()
            if CurTime() - since >= hold then return true end
        else
            since = nil
        end
        tick()
    end
    return false
end

-- SOMEWHERE ELSE TO DO IT. A park is not a field: from wherever the bot
-- happens to stand there is usually no 600 u straight and no usable ramp,
-- and on gm_skatepark it stood still retrying the same spot forever. So it
-- looks around -- rings of points out to Bot.Config.roamRadius -- for the
-- nearest one that has what the trick needs (`test(point)` returns a truthy
-- answer), and rides there. Yields between points: the search is spread
-- over ticks, not done in one.
function Brain:findSpot(test, label)
    -- Two passes: first only places reachable at ground level (a sweep from
    -- 4 u up, so a box in the way is in the way); then, if that found
    -- nothing, places visible at rider height -- on the live park the strict
    -- pass rejected every place round a bot standing among kerbs and ramp
    -- edges, and it looked at nothing at all.
    for pass = 1, 2 do
        local g, ans = self:findSpotPass(test, label, pass == 1 and 4 or 24)
        if g then return g, ans end
    end
    return nil
end

function Brain:findSpotPass(test, label, sightZ)
    local here = self.bike:GetPos()
    local R, step, n = Bot.Config.roamRadius, Bot.Config.roamStep, Bot.Config.roamAngles
    local filter = self:filter()
    local tried = 0
    for r = step, R, step do
        local offset = math.random() * 360
        for k = 0, n - 1 do
            local a = math.rad(offset + k * 360 / n)
            local p = here + Vector(math.cos(a), math.sin(a), 0) * r
            -- Ground under it, and nothing solid between here and there at
            -- rider height (not inside a wall, not behind one).
            local tr = util.TraceLine({ start = p + UP * 300, endpos = p - UP * 1500, filter = filter, mask = MASK_SOLID })
            if tr.Hit and not tr.StartSolid and tr.HitNormal.z > 0.95 then
                local g = tr.HitPos
                -- From just off the ground: a sweep 20 u up passed over park
                -- boxes and ledges, and the ride there got stuck on them.
                local seen = util.TraceHull({ start = here + UP * sightZ, endpos = g + UP * sightZ,
                    mins = Vector(-12, -12, 0), maxs = Vector(12, 12, 40), filter = filter, mask = MASK_SOLID })
                if not seen.Hit then
                    tried = tried + 1
                    local ans = test(g)
                    if ans then
                        self:say(string.format("%s: a spot %.0f u away (%d looked at)", label or "room", r, tried))
                        return g, ans
                    end
                end
            end
            tick()
        end
    end
    self:say(string.format("%s: nowhere within %d u (%d looked at)", label or "room", R, tried))
    return nil
end

-- The best heading from `p` and its runway, as a plain function of a point.
local function bestRun(p, need, filter)
    local best, bestLen = nil, 0
    for k = 0, 11 do
        local dir = BMX.Launch.DirOf(k * 30)
        local len = BMX.Launch.Runway(p + UP * 4, dir, need + 100, { filter = filter })
        if len > bestLen then best, bestLen = dir, len end
        if len >= need then return dir, len end
    end
    return best, bestLen
end

-- A straight run from here: the heading with the most clear ground ahead,
-- preferring the way the bike already points. Returns a unit dir and length.
-- With none here, it rides to a spot that has one.
function Brain:openRun(need)
    local dir, len = self:openRunHere(need)
    if dir and len >= need then return dir, len end
    local spot, found = self:findSpot(function(p)
        local d, l = bestRun(p, need, self:filter())
        return l >= need and d or nil
    end, string.format("a %d u run", need))
    if not spot then return dir, len end
    if not self:rideTo(spot, 180, 50, 25) then return dir, len end
    self:stop(3)
    -- THE DIRECTION FOUND THERE, from where the bike actually stopped: a
    -- fresh search from its own heading tried other directions than the one
    -- that had room, and came back with "no room" on arrival.
    local l2 = BMX.Launch.Runway(self.bike:GetPos() + UP * 4, found, need + 100, { filter = self:filter() })
    if l2 >= need * 0.8 then return found, l2 end
    return self:openRunHere(need)
end

function Brain:openRunHere(need)
    local p = self.bike:GetPos()
    local opts = { filter = self:filter() }
    local cur = self:yaw()
    local best, bestLen = nil, 0
    for k = 0, 11 do
        local yaw = cur + (k % 2 == 0 and 1 or -1) * math.floor((k + 1) / 2) * 30
        local dir = BMX.Launch.DirOf(yaw)
        local len = BMX.Launch.Runway(p, dir, need + 100, opts)
        if len >= need then return dir, len end
        if len > bestLen then best, bestLen = dir, len end
    end
    return best, bestLen
end

function Brain:filter()
    local f = { self.bike, self.ply }
    if IsValid(self.bike) and self.bike.GetPod then f[#f + 1] = self.bike:GetPod() end
    for _, e in ipairs(self.props) do if e.BMXRail then f[#f + 1] = e end end
    return f
end

-- Turn to face `dir` at walking pace, where A/D steer the bars directly and
-- the bike can turn on the spot. Sprinting off in whatever direction the bike
-- happened to point and carving round at speed threw the rider (bot_360).
function Brain:alignTo(dir, timeout)
    local want = math.deg(math.atan2(dir.y, dir.x))
    local t0 = CurTime()
    while CurTime() - t0 < (timeout or 6) do
        if not self:riding() then return false end
        local err = math.AngleDifference(want, self:yaw())
        if math.abs(err) < 12 then break end
        local thr, brk = self:pace(30)
        self:set({ throttle = thr, brakeRear = brk, lean = math.Clamp(-err / 20, -1, 1) })
        tick()
    end
    return true
end

-- Face along `dir` and pull away along it from where the bike is now.
function Brain:lineUp(dir, speed, dist)
    local a = self.bike:GetPos()
    return self:rideLine(a, dir, speed, function(along) return along >= (dist or 0) end, 8)
end

--------------------------------------------------------------------------
-- In the air: pace one axis's spin to finish just past a full turn as the
-- bike touches down, then brake it.
--------------------------------------------------------------------------

-- Seconds until the bike's wheels reach the ground below its flight path.
function Brain:timeToLand()
    local phys = self.bike:GetPhysicsObject()
    if not IsValid(phys) then return 0 end
    local p, v = self.bike:GetPos(), phys:GetVelocity()
    local g = physenv.GetGravity():Length()
    local floor = self.bike:Cfg().Wheel.radius
    local t = 0.3
    for _ = 1, 3 do
        local at = p + Vector(v.x, v.y, 0) * t
        local tr = util.TraceLine({ start = at + UP * 64, endpos = at - UP * 2000,
                                    filter = self:filter(), mask = MASK_SOLID })
        local gz = tr.Hit and tr.HitPos.z or (p.z - 2000)
        local h = p.z - floor - gz
        -- z(t) = h + vz t - g t^2 / 2 = 0
        local disc = v.z * v.z + 2 * g * math.max(h, 0)
        t = (v.z + math.sqrt(disc)) / g
    end
    return t
end

local AXES = {
    pitch = { spin = "spinPitch", input = "pitch",  accel = "pitchAccel",
              rate = function(st, e) return (st.angVel or vector_origin):Dot(e:GetRight()) end },
    roll  = { spin = "spinRoll",  input = "lean",   accel = "rollAccel",
              rate = function(st, e) return (st.angVel or vector_origin):Dot(e:GetForward()) end },
    yaw   = { spin = "spinYaw",   input = "lean",   accel = "yawAccel", wheelieMod = true,
              rate = function(st, e) return (st.angVel or vector_origin):Dot(e:GetUp()) end },
}
Bot.Axes = AXES

-- The input in -1..1 that drives an axis's rate toward `want`, given the
-- air model: a = u * accel * tuck - (damping / tuck) * w.
function Bot.SpinInput(want, w, A, accel, tuck)
    local k = tuck and 1.35 or 1
    local damp = A.damping / k
    local need = damp * want + Bot.Config.spinGain * (want - w)
    return math.Clamp(need / (accel * k), -1, 1)
end

-- The pacing: how fast the axis should be spinning with `remaining` radians
-- to go and `tLeft` seconds to do them in.
--
-- TWO LIMITS, and the second is the one that lands it. Spinning just fast
-- enough to finish on time front-loads nothing, falls behind while the spin
-- builds, and arrives at full rate -- and a bike at 10 rad/s cannot stop in
-- the few degrees left, so it went 45 degrees past and came down on its back
-- wheel at 82 (the offline plant, first try). So the rate is also capped at
-- what can be braked to nothing in the rotation remaining, sqrt(2 a r), and
-- the schedule runs `ahead` of time.
function Bot.SpinPace(remaining, tLeft, maxRate, brakeAccel)
    if remaining <= 0 then return 0 end
    local onTime = remaining / math.max(tLeft, 0.05) * Bot.Config.ahead
    local stoppable = math.sqrt(2 * (brakeAccel or math.huge) * remaining)
    return math.min(onTime, stoppable, maxRate)
end

-- Fly one air trick. `axis` is pitch / roll / yaw, `sign` its direction
-- (+1 nose up / right / left), `target` the spin to finish on, radians.
function Brain:flySpin(axis, sign, target, pose)
    local Ax = AXES[axis]
    local A = self.bike:Cfg().Air
    local accel = A[Ax.accel]
    local maxRate = accel * 1.35 / (A.damping / 1.35) * 0.95
    local landedFor = 0
    local touched = false
    while true do
        if not self:riding() then
            self:say(string.format("thrown: spin %.0f deg", math.deg((self:st()[Ax.spin] or 0) * sign)))
            return false
        end
        local st = self:st()
        if not touched and st.grounded then
            touched = true
            local att = select(2, BMX.Attitude(self.bike, UP))
            local roll = select(1, BMX.Attitude(self.bike, UP))
            self:say(string.format("touchdown: spin %.0f deg, rate %.1f rad/s, pitch %.0f, roll %.0f",
                math.deg((st[Ax.spin] or 0) * sign), Ax.rate(st, self.bike) * sign, math.deg(att), math.deg(roll)))
        end
        if st.grounded and not st.airMode then
            landedFor = landedFor + engine.TickInterval()
            if landedFor > 0.1 then return true end
        else
            landedFor = 0
        end
        local spun = (st[Ax.spin] or 0) * sign
        local remaining = target - spun
        if CurTime() >= (self.nextFlightLog or 0) then
            self.nextFlightLog = CurTime() + 0.15
            self:say(string.format("  flight: spun %.0f, rate %.1f, land in %.2f, pitch %.0f, roll %.0f",
                math.deg(spun), Ax.rate(st, self.bike) * sign, self:timeToLand(),
                math.deg(select(2, BMX.Attitude(self.bike, UP))), math.deg(select(1, BMX.Attitude(self.bike, UP)))))
        end
        local w = Ax.rate(st, self.bike) * sign
        local tLeft = self:timeToLand() - Bot.Config.settle
        -- A spin's landing attitude hardly matters (it lands flat whatever
        -- its heading), so a 360 goes flat out until it has to brake: paced
        -- to the touchdown it fell short on a real server, twice.
        local want = Bot.SpinPace(remaining, axis == "yaw" and 0.01 or tLeft, maxRate, accel * Bot.Config.brakeShare)
        local u = Bot.SpinInput(want, w, A, accel, true) * sign
        if remaining <= 0 then
            if axis == "pitch" then
                -- Turned enough: now put the wheels under it. Steer the
                -- attitude toward a slight nose-up landing (rear wheel first),
                -- but only reverse as far as the spin beyond a full turn
                -- allows: the scoring counts the integral, and taking back
                -- more than the overshoot would un-flip the flip.
                local att = select(2, BMX.Attitude(self.bike, UP))
                local want = Bot.Config.landPitch
                local cmd = (Bot.Config.attKp * (want - att) - Bot.Config.attKd * Ax.rate(st, self.bike)) / accel
                local budget = spun - TAU - 0.03
                if cmd * sign < 0 and budget <= 0 then
                    cmd = sign * math.Clamp(-Bot.Config.spinGain * 2 * w / accel, -1, 0)
                end
                u = math.Clamp(cmd, -1, 1)
            elseif axis == "roll" then
                -- The same for a barrel roll: wheels under it, flat. One
                -- landed rolled 40 degrees at 7.6 rad/s and fell over.
                local roll = select(1, BMX.Attitude(self.bike, UP))
                local cmd = (Bot.Config.attKp * (0 - roll) - Bot.Config.attKd * Ax.rate(st, self.bike)) / accel
                local budget = spun - TAU - 0.03
                if cmd * sign < 0 and budget <= 0 then
                    cmd = sign * math.Clamp(-Bot.Config.spinGain * 2 * w / accel, -1, 0)
                end
                u = math.Clamp(cmd, -1, 1)
            else
                -- Brake the spin, never reverse it (that would take back
                -- rotation the scoring has already counted).
                u = sign * math.Clamp(-Bot.Config.spinGain * 2 * w / accel, -1, 0)
            end
        end
        local inp = { tuck = remaining > 0 }
        -- A pose to hold during the spin: pose(spun, target) -> a pose name
        -- or nil (the Superman Backflip's superman).
        if pose then inp.pose = pose(spun, target) end
        inp[Ax.input] = u
        if Ax.wheelieMod then inp.wheelieMod = true end
        self:set(inp)
        tick()
    end
end

--------------------------------------------------------------------------
-- Launches: find one in the world, or put a kicker down.
--------------------------------------------------------------------------
-- How much air a trick needs: the shortest flight in which Bot.MaxSpin turns
-- the axis far enough, with margin. A map's ramps are often small -- 37 u
-- lips giving 1.1 s -- which is a flip but not a frontflip off a steep
-- takeoff, and the bot used to take any ramp and come down short.
function Bot.AirNeed(name, cfg)
    local A = Bot.AirTricks[name]
    if not A then return BMX.Launch.Config.minAir end
    local Air = (cfg or BMX.Config).Air
    local accel = Air[AXES[A.axis].accel]
    local target = (TAU + Bot.Config.margin) * 1.04
    if A.axis == "pitch" and A.sign < 0 then target = target + math.rad(25) end
    for t = 0.6, 2.5, 0.05 do
        if Bot.MaxSpin(Air, accel, t - Bot.Config.settle * 0.5) >= target then return t end
    end
    return 2.5
end

function Brain:launch()
    local here = self.bike:GetPos()
    local need = self.needAir or BMX.Launch.Config.minAir
    local cfgNeed = setmetatable({ minAir = need }, { __index = BMX.Launch.Config })
    if self.allowFindRamp then
        local l, n, rejected = BMX.FindLaunch(here, { filter = self:filter(), config = cfgNeed })
        if l then
            self:say(string.format("found a launch: %.0f u high, %.0f deg, %.0f u away (%d seen)",
                l.height, math.deg(l.angle), (l.foot - here):Length(), n))
            return l
        end
        self:say("no launch in the world here (" .. n .. " seen" ..
            ((rejected and rejected ~= "") and (": " .. rejected) or "") .. ")")
        -- Look for one from elsewhere in the park (a cheaper, coarser search
        -- from each place: it only has to notice a ramp is there).
        local coarse = setmetatable({ headings = 12, step = 30, reach = 1400, minAir = need }, { __index = BMX.Launch.Config })
        local found
        local spot = self:findSpot(function(p)
            local l2 = BMX.FindLaunch(p + UP * 4, { filter = self:filter(), config = coarse })
            if l2 then found = l2 end
            return l2
        end, "a ramp")
        if found then
            self:say(string.format("found a launch from there: %.0f u high, %.0f deg", found.height, math.deg(found.angle)))
            return found
        end
    end
    if not self.allowSpawnRamp then return nil end
    local C = BMX.Launch.Config
    local opts = { filter = self:filter(), config = setmetatable({ runup = Bot.Config.stageBack }, { __index = C }) }
    local foot, yaw = BMX.Launch.PlanKicker(here, opts)
    if not foot then
        -- No room for a kicker here: go where there is.
        local plan
        local spot = self:findSpot(function(p)
            local f, y = BMX.Launch.PlanKicker(p + UP * 4, opts)
            if f then plan = { foot = f, yaw = y, from = p } end
            return f
        end, "room for a kicker")
        if not spot then return nil end
        if not self:rideTo(spot, 180, 50, 25) then return nil end
        self:stop(3)
        here = self.bike:GetPos()
        foot, yaw = BMX.Launch.PlanKicker(here, opts)
        -- Planned from where the bike stopped if that still works, else the
        -- plan made at the spot (the bike is beside it).
        if not foot and plan then foot, yaw = plan.foot, plan.yaw end
        if not foot then return nil end
    end
    local e, l, plates = BMX.SpawnKicker(foot, yaw)
    if not e then return nil end
    for _, pe in ipairs(plates or { e }) do self.props[#self.props + 1] = pe end
    self:say(string.format("put a kicker down: %.0f u high", l.height))
    return l
end

-- Ride at a launch and leave its lip with a hop. Returns true once airborne.
function Brain:hitLaunch(l, speed)
    -- Measured from just behind the foot, past the ramp itself: from the foot
    -- the hull starts touching the slope and every ramp had "no room".
    local filter = self:filter()
    if IsValid(l.entity) then filter[#filter + 1] = l.entity end
    for _, pe in ipairs(l.plates or {}) do filter[#filter + 1] = pe end
    local from = l.foot - l.dir * 30
    local back = math.min(Bot.Config.stageBack,
        BMX.Launch.Runway(from, -l.dir, Bot.Config.stageBack, { filter = filter }) + 30)
    if back < 300 then return false, string.format("no room to ride at it (%.0f u)", back) end
    local stage = l.foot - l.dir * back
    self:say(string.format("riding to the start of the run, %.0f u away", (stage - self.bike:GetPos()):Length()))
    local ok, why = self:rideTo(stage, 160, 90, 20)
    if not ok then return false, why end
    self:say("at the start: riding at it")
    self:alignTo(l.dir)
    -- No stop: straight on to the line from the stage, sprinting.
    -- Ride the line through the foot and the lip; preload the hop so it is
    -- released on the lip, and go once the wheels leave the ramp.
    local C = self.bike:Cfg()
    local lipAlong = (l.lip - l.foot):Dot(l.dir)
    local held, released = false, false
    local airborne, tooSlow = false, false
    ok, why = self:rideLine(l.foot, l.dir, speed, function(along)
        local st = self:st()
        if released and (st.airMode or not st.grounded) then airborne = true return true end
        local toLip = lipAlong - along
        -- At the foot too slow to clear it -- something on the run-in held the
        -- bike up -- and it is a stall on the ramp, not a jump: give up the
        -- run (the show tries again) rather than roll back down it.
        if along > -40 and along < 0 and self:speed() < speed * 0.75 then
            tooSlow = true
            return true
        end
        if not held and toLip <= self:speed() * (C.Hop.chargeTime + 0.03) then
            self.bike.hopHeld, self.bike.hopCharge, held = true, 0, true
        end
        if held and not released and toLip <= 8 then
            self.bike.hopRelease, released = true, true
        end
        return false
    end, 14, function() return { sprint = true } end)
    if tooSlow then
        self:stop(3)
        return false, string.format("too slow at the ramp (%.0f u/s)", self:speed())
    end
    if not airborne then return false, why or "never left the lip" end
    local v = self.bike:GetVelocity()
    self:say(string.format("off the lip at %.0f u/s (vz %.0f), pitch %.0f, %s",
        self:speed(), v.z, math.deg(select(2, BMX.Attitude(self.bike, UP))),
        released and "hopped" or "no hop"))
    return true
end

--------------------------------------------------------------------------
-- The tricks. Each returns ok, why.
--------------------------------------------------------------------------
Bot.Tricks = {}
local T = Bot.Tricks

T["Bunny Hop"] = function(b)
    local dir, len = b:openRun(600)
    if not dir or len < 400 then return false, "no room" end
    local ok, why = b:lineUp(dir, 200)
    if not ok then return false, why end
    local a = b.bike:GetPos()
    b:rideLine(a, dir, 200, function() return b:speed() >= 185 end, 6)
    local t0 = CurTime()
    b.bike.hopHeld, b.bike.hopCharge = true, 0
    b:rideLine(a, dir, 200, function() return CurTime() - t0 >= b.bike:Cfg().Hop.chargeTime + 0.05 end, 1)
    b.bike.hopRelease = true
    local flew = false
    b:rideLine(a, dir, 200, function()
        if b:st().airMode or not b:st().grounded then flew = true end
        return flew and b:st().grounded and not b:st().airMode
    end, 3)
    if not flew then return false, "did not leave the ground" end
    if not b:waitLanded(0.5) then return false, "did not land on it" end
    b:say("landed a Bunny Hop")
    return true
end

T["Wheelie"] = function(b)
    local dir, len = b:openRun(800)
    if not dir or len < 600 then return false, "no room" end
    local t0 = CurTime()
    b:lineUp(dir, 150)
    local a = b.bike:GetPos()
    b:rideLine(a, dir, 150, function() return b:speed() >= 140 end, 6)
    local start = CurTime()
    b:rideLine(a, dir, 170, function() return CurTime() - start > 2.2 end, 3,
        function() return { throttle = 1, pitch = 1 } end)
    b:rideLine(a, dir, 120, function() return CurTime() - start > 3.0 end, 1)
    if b:scoredSince(t0, "Wheelie") then return true end
    return false, "no wheelie scored"
end

T["Stoppie"] = function(b)
    local dir, len = b:openRun(900)
    if not dir or len < 700 then return false, "no room" end
    local t0 = CurTime()
    b:lineUp(dir, 230)
    local a = b.bike:GetPos()
    b:rideLine(a, dir, 240, function() return b:speed() >= 220 end, 6)
    b:rideLine(a, dir, 0, function() return b:speed() < 4 end, 4,
        function() return { throttle = 0, brakeRear = 0, brakeFront = 1, pitch = -0.6 } end)
    b:set({})
    b:wait(0.6)
    if b:scoredSince(t0, "Stoppie") then return true end
    return false, "no stoppie scored"
end

-- Two tricks chained, landed: a wheelie, the front wheel down for a moment,
-- and a second wheelie inside Combo.grace. (Wheelie into stoppie was the
-- first version; on a real server the stoppie after a wheelie's landing was
-- marginal -- the bike still pitching, the rear on and off -- and the chain
-- landed only some of the time. Two wheelies are the bot's surest pair.)
T["Combo"] = function(b)
    local dir, len = b:openRun(1100)
    if not dir or len < 900 then return false, "no room" end
    local t0 = CurTime()
    b:lineUp(dir, 150)
    local a = b.bike:GetPos()
    b:rideLine(a, dir, 150, function() return b:speed() >= 140 end, 6)
    for i = 1, 2 do
        local start = CurTime()
        b:rideLine(a, dir, 170, function() return CurTime() - start > 1.6 end, 3,
            function() return { throttle = 1, pitch = 1 } end)
        if i == 1 then
            local down = CurTime()
            b:rideLine(a, dir, 160, function() return CurTime() - down > 0.3 end, 1,
                function() return { throttle = 0.5 } end)
        end
    end
    b:rideLine(a, dir, 120, function() return false end, 1.6)
    if b:comboSince(t0) then return true end
    return false, "no combo landed"
end

-- The air tricks, and the axis and direction each spins.
Bot.AirTricks = {
    ["Backflip"]    = { axis = "pitch", sign =  1 },
    ["Frontflip"]   = { axis = "pitch", sign = -1 },
    ["Barrel Roll"] = { axis = "roll",  sign =  1 },
    ["360"]         = { axis = "yaw",   sign =  1 },
}

-- The most an axis can turn in `t` seconds and still be slowed to a
-- landable rate by the end: spin up tucked, flat out, until braking
-- (untucked, flat out) has just enough room to get down to `landRate` in
-- what is left. Not to zero: a landing on the wheels soaks up the rest
-- (Crash.soakSpin). Simulated with the air model, so it answers for the
-- bike's real numbers.
function Bot.MaxSpin(A, accel, t, landRate)
    landRate = landRate or Bot.Config.landRate
    local w, th, dt = 0, 0, 0.01
    local n = math.floor(t / dt)
    for i = 1, n do
        local left = (n - i) * dt
        local brakeA = accel + A.damping * w
        if (w - landRate) / brakeA >= left then
            w = math.max(w - brakeA * dt, 0)
        else
            w = w + (accel * 1.35 - A.damping / 1.35 * w) * dt
        end
        th = th + w * dt
    end
    return th
end

-- The part of an air trick done in the air: from takeoff to touchdown, and
-- the landing checked. Its own function so a bike already in the air -- off
-- a map's gap, or a test's launch -- can do it too.
function Brain:airPart(name, t0, pose, scored)
    local A = Bot.AirTricks[name]
    -- Aim to finish on a turn plus margin; a frontflip leaves a nose-up ramp,
    -- so it turns that much further to come down level.
    local target = TAU + Bot.Config.margin
    if A.axis == "pitch" and A.sign < 0 then
        local p0 = select(2, BMX.Attitude(self.bike, UP))
        target = math.max(target, TAU + p0)
    end
    local tLand = self:timeToLand()
    self:say(string.format("airborne: %.2f s to land, aiming for %.0f deg", tLand, math.deg(target)))
    -- NOT ENOUGH AIR, NOT STARTED. Half a flip is a landing on the head; the
    -- bot keeps its wheels under it and calls it a miss instead.
    local Air = self.bike:Cfg().Air
    local can = Bot.MaxSpin(Air, Air[AXES[A.axis].accel], tLand - Bot.Config.settle * 0.5)
    -- With margin: a trick that only just fits on paper came down short
    -- off a slow run at a map ramp (331 of 365 degrees).
    if can < target * 1.06 then
        self:say(string.format("only %.0f deg of spin in %.2f s of air: not starting", math.deg(can), tLand))
        self:set({})
        self:waitLanded(0.5, 3)
        return false, "not enough air"
    end
    self:flySpin(A.axis, A.sign, target, pose)
    self:set({})
    self:waitLanded(0.8, 3)
    if self:scoredSince(t0, scored or name) and self:riding() then return true end
    local got = self:scoredSince(t0)
    return false, got and ("scored " .. got.name .. " instead") or "nothing scored"
end

for name in pairs(Bot.AirTricks) do
    T[name] = function(b)
        b.needAir = Bot.AirNeed(name, b.bike:Cfg())
        local l = b:launch()
        b.needAir = nil
        if not l then return false, "nowhere to get air" end
        local t0 = CurTime()
        local ok, why = b:hitLaunch(l, Bot.Config.flipSpeed)
        if not ok then return false, why end
        return b:airPart(name, t0)
    end
end

--------------------------------------------------------------------------
-- Frame and bar spins, and poses (G03, G17). Written to the same bike.input a
-- rider's keys make: inp.whip / inp.bar / inp.pose (sv_input.lua).
--------------------------------------------------------------------------

-- Turn a part (st.parts[field]) in the air until it is past the 270 degrees
-- from which letting go finishes it, then let go. `name` is what the scoring
-- calls it.
function Brain:airPartSpin(name, field, t0)
    local want = TAU * 0.85
    self:say(string.format("airborne: %.2f s to land, spinning the %s", self:timeToLand(), field))
    local landedFor, released = 0, false
    while true do
        if not self:riding() then return false end
        local st = self:st()
        if st.grounded and not st.airMode then
            landedFor = landedFor + engine.TickInterval()
            if landedFor > 0.1 then break end
        else
            landedFor = 0
        end
        local part = st.parts and st.parts[field]
        local inp = {}
        -- ONE turn, then hands off. A finished part settles back to an angle
        -- of 0, and "less than 85% round" then pressed again: a second whip
        -- began, and the bike landed halfway through it ("crash: whip").
        if part and math.abs(part.angle) >= want then released = true end
        if st.airMode and not released then inp[field] = 1 end
        self:set(inp)
        tick()
    end
    self:set({})
    self:waitLanded(0.8, 3)
    if self:scoredSince(t0, name) and self:riding() then return true end
    local got = self:scoredSince(t0)
    return false, got and ("scored " .. got.name .. " instead") or "nothing scored"
end

-- Hold a pose through the middle of the air, and be out of it well before
-- touchdown (landing in a pose bails).
function Brain:airPose(name, pose, t0)
    self:say(string.format("airborne: %.2f s to land, holding %s", self:timeToLand(), pose))
    local landedFor = 0
    while true do
        if not self:riding() then return false end
        local st = self:st()
        if st.grounded and not st.airMode then
            landedFor = landedFor + engine.TickInterval()
            if landedFor > 0.1 then break end
        else
            landedFor = 0
        end
        local inp = {}
        if st.airMode and (st.airTime or 0) >= 0.12 and self:timeToLand() > 0.4 then inp.pose = pose end
        self:set(inp)
        tick()
    end
    self:set({})
    self:waitLanded(0.8, 3)
    if self:scoredSince(t0, name) and self:riding() then return true end
    local got = self:scoredSince(t0)
    return false, got and ("scored " .. got.name .. " instead") or "nothing scored"
end

local function partTrick(name, fn)
    T[name] = function(b)
        b.needAir = 1.0
        local l = b:launch()
        b.needAir = nil
        if not l then return false, "nowhere to get air" end
        local t0 = CurTime()
        local ok, why = b:hitLaunch(l, Bot.Config.flipSpeed)
        if not ok then return false, why end
        return fn(b, t0)
    end
end
partTrick("Tailwhip", function(b, t0) return b:airPartSpin("Tailwhip", "whip", t0) end)
partTrick("Barspin",  function(b, t0) return b:airPartSpin("Barspin",  "bar",  t0) end)
partTrick("Superman", function(b, t0) return b:airPose("Superman", "superman", t0) end)

-- A backflip with the superman held through the middle of it: one compound,
-- "Backflip Superman". The pose is up from a fifth of the way round to
-- three quarters, long enough to count and over before it comes down.
partTrick("Superman Backflip", function(b, t0)
    return b:airPart("Backflip", t0, function(spun, target)
        local f = spun / target
        return (f >= 0.2 and f <= 0.72) and "superman" or nil
    end, "Backflip Superman")
end)

-- Run just the air part of a trick on a bike already in the air.
function Bot.PerformAir(b, name, done)
    b.jobRode, b.jobStart = false, CurTime()
    b.job = coroutine.create(function() return b:airPart(name, CurTime() - 0.01) end)
    b.jobDone = function(ok, why) b.job = nil if done then done(ok, why) end end
end

-- A rail to grind: a thin pole (crank) or a beam (pegs), raised `top` u and
-- laid along `dir`. The recipe is the headless grind_hop_on case's, which is
-- the one proved on a real server: 18 u up, met at 6 degrees, at 260 u/s.
local RAILS = {
    -- Three signpoles end to end: one is 110 u, which at grinding speed is a
    -- third of a second -- too short to land on reliably.
    ["Crank Grind"]      = { model = "models/props_c17/signpole001.mdl", top = 18, edge = false, count = 3 },
    ["Double Peg Grind"] = { model = "models/hunter/blocks/cube025x8x025.mdl", top = 18, edge = true, count = 1 },
}
Bot.Rails = RAILS
-- Straight along the rail's axis, not at the 6 degrees the headless case
-- uses: the case teleports onto its line, and a bot riding one has to hold
-- it to a few units, which a line along the rail makes easiest.
local GRIND_SPEED, GRIND_YAW = 220, 0

-- Lay a rail: RAILS[kind].count pieces end to end along `dir`, centred on
-- `centre`. Returns the first piece and the union of their world bounds.
function Brain:layRail(kind, centre, dir)
    local R = RAILS[kind]
    local n = R.count or 1
    local first = self:layPiece(kind, centre, dir)
    if not first or n == 1 then return first end
    local lo, hi = first:WorldSpaceAABB()
    local len = math.abs((hi - lo):Dot(dir))
    local pieces = { first }
    for i = 2, n do
        local e = self:layPiece(kind, centre + dir * (len * (i - 1)), dir)
        if e then pieces[#pieces + 1] = e end
    end
    -- Re-centre the whole run on `centre`.
    local back = dir * (len * (#pieces - 1) * 0.5)
    for _, e in ipairs(pieces) do
        local at = e:GetPos() - back
        e:SetPos(at)
        local p = e:GetPhysicsObject()
        if IsValid(p) then p:SetPos(at) p:EnableMotion(false) end
    end
    if coroutine.running() then for _ = 1, 3 do tick() end end
    first.BMXRailPieces = pieces
    return first
end

-- The world bounds of a whole rail, all its pieces.
function Bot.RailBounds(e)
    local lo, hi = e:WorldSpaceAABB()
    for _, p in ipairs(e.BMXRailPieces or {}) do
        local a, b = p:WorldSpaceAABB()
        lo = Vector(math.min(lo.x, a.x), math.min(lo.y, a.y), math.min(lo.z, a.z))
        hi = Vector(math.max(hi.x, b.x), math.max(hi.y, b.y), math.max(hi.z, b.z))
    end
    return lo, hi
end

function Brain:layPiece(kind, centre, dir)
    local R = RAILS[kind]
    local e = ents.Create("prop_physics")
    if not IsValid(e) then return nil end
    e:SetModel(R.model)
    local mn, mx = e:OBBMins(), e:OBBMaxs()
    local size = mx - mn
    local yaw = math.deg(math.atan2(dir.y, dir.x))
    -- Lay the model's long axis along dir.
    local ang
    if size.z >= size.x and size.z >= size.y then ang = Angle(90, yaw, 0)
    elseif size.y >= size.x then ang = Angle(0, yaw - 90, 0)
    else ang = Angle(0, yaw, 0) end
    -- Spawned, frozen, and only THEN measured: the world bounds of a prop
    -- that has not spawned are not rotated yet, and a signpole read that way
    -- was put 91 u under the ground (the headless railProp helper does it in
    -- this order too, and waits for the engine to catch up).
    e:SetPos(centre)
    e:SetAngles(ang)
    e:Spawn()
    local p = e:GetPhysicsObject()
    if IsValid(p) then p:SetPos(centre) p:SetAngles(ang) p:EnableMotion(false) end
    if coroutine.running() then for _ = 1, 6 do tick() end end
    -- Centre it over `centre`, its top R.top above the ground there.
    local lo, hi = e:WorldSpaceAABB()
    local shift = Vector(centre.x - (lo.x + hi.x) * 0.5, centre.y - (lo.y + hi.y) * 0.5,
                         centre.z + R.top - hi.z)
    local at = e:GetPos() + shift
    e:SetPos(at)
    if IsValid(p) then p:SetPos(at) p:EnableMotion(false) end
    if coroutine.running() then for _ = 1, 3 do tick() end end
    e.BMXRail = true
    self.props[#self.props + 1] = e
    return e
end

-- The line to ride at a rail along `dir` (unit) centred at `centre`, of
-- length `len` and width `w`, so the crank point arrives over `lateral`
-- (left of the rail's axis) 60 u along it as the hop comes down onto it.
-- Returns the point to press the hop at and the direction to ride in.
function Bot.GrindApproach(cfg, centre, dir, len, lateral, top, g)
    local H = cfg.Hop
    local left = Vector(-dir.y, dir.x, 0)
    local vz = H.popSpeed / math.sqrt(1 + H.forwardBias ^ 2)
    local crank0 = BMX.RestHeight(cfg) + BMX.GrindCrankPoint(cfg).z
    local rise = top + 4 - crank0
    local tDown = (vz + math.sqrt(math.max(vz * vz - 2 * g * rise, 0))) / g
    local t = H.chargeTime + 0.05 + tDown
    -- The hop also kicks the bike FORWARD (Hop.forwardBias): over the flight
    -- that is tens of units, and leaving it out landed past the rail's start.
    local kick = H.popSpeed * H.forwardBias / math.sqrt(1 + H.forwardBias ^ 2)
    local c, s = math.cos(math.rad(GRIND_YAW)), math.sin(math.rad(GRIND_YAW))
    local press = centre + dir * (-len * 0.5 + 60 - GRIND_SPEED * c * t)
                         + left * (lateral - GRIND_SPEED * s * t)
    return press, (dir * c + left * s):GetNormalized(), t, H.chargeTime + 0.05, tDown, kick
end

local function grindTrick(name)
    T[name] = function(b)
        local dir, len = b:openRun(1400)
        if not dir or len < 1100 then return false, "no room" end
        local cfg = b.bike:Cfg()
        local start = b.bike:GetPos()
        local ground = start - UP * BMX.RestHeight(cfg)
        local e = b:layRail(name, ground + dir * 950, dir)
        if not e then return false, "could not lay a rail" end
        local lo, hi = Bot.RailBounds(e)
        local centre = (lo + hi) * 0.5
        centre.z = ground.z
        -- From the MODEL's box, not the world one: a rail laid at 30 degrees
        -- has a world box 142 u wide, and the peg grind aimed 69 u off it.
        local mn, mx = e:OBBMins(), e:OBBMaxs()
        local dims = { mx.x - mn.x, mx.y - mn.y, mx.z - mn.z }
        table.sort(dims)
        local width = dims[1]
        local railLen = dims[3] * #(e.BMXRailPieces or { e })
        -- A peg grind lands on the near (right-hand) edge, a crank on the middle.
        local lateral = RAILS[name].edge and (-width * 0.5 + 2) or 0
        local press, rideDir, flight, tCharge, tDown, kick = Bot.GrindApproach(cfg, centre, dir, railLen, lateral,
            RAILS[name].top, physenv.GetGravity():Length())
        -- Where the crank point should come down: 60 u along the rail.
        local landAt = centre + dir * (-railLen * 0.5 + 60) + Vector(-dir.y, dir.x, 0) * lateral
        -- The run at it starts where the bot stands (the rail is laid
        -- 950 u ahead), not behind it: a stage 900 u back from the press
        -- point was 335 u BEHIND the bot, in ground nobody had checked.
        local stage = start + rideDir * 15
        local ok, why = b:rideTo(stage, 200, 60, 20)
        if not ok then return false, why end
        b:stop(3)
        -- Face along the rail first, at walking pace: the run at a rail is
        -- only ~550 u, and a bike starting it pointed elsewhere was still
        -- swinging onto the line at the press (45 u off on the live park).
        b:alignTo(rideDir)
        local t0 = CurTime()
        local pressedAt, released = nil, false
        local missedWindow = false
        local C = cfg
        b.tightLine = true
        b:say(string.format("rail %s: %.0f long, %.1f wide, top +%.0f; hop at %.0f u/s",
            name, railLen, width, hi.z - ground.z, GRIND_SPEED))
        local closest, overAt = math.huge, nil
        ok, why = b:rideLine(press, rideDir, GRIND_SPEED, function(along)
            if b:st().grind then return true end
            if pressedAt then
                local c = b.bike:LocalToWorld(BMX.GrindCrankPoint(cfg))
                local rel = c - centre
                local u = rel:Dot(dir)
                if math.abs(u) < railLen * 0.5 then
                    local lat = rel:Dot(Vector(-dir.y, dir.x, 0)) - lateral
                    local d = math.abs(c.z - hi.z) + math.abs(lat)
                    if d < closest then
                        closest = d
                        overAt = string.format("%.0f along, %.1f off line, %.1f above top, %.0f u/s, vz %.0f, roll %.0f",
                            u + railLen * 0.5, lat, c.z - hi.z, b:speed(), b.bike:GetVelocity().z,
                            math.deg(select(1, BMX.Attitude(b.bike, UP))))
                    end
                end
            end
            -- Pressed when the crank point is one hop's flight from where it
            -- should land, AT THE SPEED ACTUALLY RIDDEN: a fixed press point
            -- assumed 260 u/s, and at 335 the bike came down past the rail.
            if not pressedAt then
                local c = b.bike:LocalToWorld(BMX.GrindCrankPoint(cfg))
                local toLand = (landAt - c):Dot(rideDir)
                -- Coasting from here (see the input below), so: the preload
                -- at this speed, then the flight at this speed plus the kick.
                local reach = b:speed() * tCharge + (b:speed() + kick) * tDown
                -- AND ONLY WHEN IT WILL COME DOWN ON THE LINE. A bike holding a
                -- line weaves by a few units, and a pipe is 2.8 wide: pressed
                -- 4 u right while drifting left, it landed 5 u left and missed.
                -- So the press waits, inside a window 40 u either side of the
                -- ideal, for the moment the drift carries it onto the pipe.
                local left = Vector(-rideDir.y, rideDir.x, 0)
                local lat = (c - landAt):Dot(left)
                local vlat = b.bike:GetVelocity():Dot(left)
                -- Plus the shift the preload and the pop add, which the drift
                -- before the press does not show: about -9 u, the same in every
                -- run on the dev server (4.1 -> -5.2, 3.6 -> -6.1, ...).
                local landLat = lat + vlat * (tCharge + tDown) + Bot.Config.grindShift
                local inWindow = toLand <= reach + 40
                -- NO FORCED PRESS. Past the window without a moment the drift
                -- would land it on the pipe, it rides by without hopping and
                -- the trick is tried again: a hop "at the last chance" with
                -- the landing predicted 16 u off only ever missed.
                if toLand < reach - 40 then
                    missedWindow = true
                    return true
                end
                local last = false
                if inWindow and math.abs(landLat) < 2.5 then
                    b.bike.hopHeld, b.bike.hopCharge, pressedAt = true, 0, CurTime()
                    b:say(string.format("hop pressed: %.0f u/s, crank %.1f u off the line drifting %.1f u/s (lands %.1f off), heading %.1f off, %.0f u to go of %.0f%s",
                        b:speed(), lat, vlat, landLat,
                        math.AngleDifference(b:yaw(), math.deg(math.atan2(rideDir.y, rideDir.x))),
                        toLand, reach, last and " (the last chance)" or ""))
                end
            end
            if pressedAt and not released and CurTime() - pressedAt >= C.Hop.chargeTime + 0.05 then
                b.bike.hopRelease, released = true, true
            end
            return released and CurTime() - pressedAt > 2
        end, 16, function()
            -- Pressed: coast, so the speed the timing was worked out at holds,
            -- and STOP STEERING: the landing was predicted from the drift at
            -- the press, and line corrections through the preload changed it
            -- (the same bot landed 9 u left on one map and 9 u right on another).
            if pressedAt then
                -- And in the air, HOLD IT LEVEL. The crank point is ~21 u
                -- below the mass centre, so 28 degrees of roll in flight puts
                -- it 10 u to the side of a 2.8 u pipe: a press dead on the
                -- line still missed. In the air A/D are roll, so: a roll PD.
                local st = b:st()
                local roll = select(1, BMX.Attitude(b.bike, UP))
                local w = (st.angVel or vector_origin):Dot(b.bike:GetForward())
                local A = cfg.Air
                return { throttle = 0, brakeRear = 0, lean = 0,
                         airLean = math.Clamp((-Bot.Config.attKp * roll - Bot.Config.attKd * w) / A.rollAccel, -1, 1) }
            end
        end)
        if missedWindow then
            b:say("never lined up on the rail closely enough to hop: riding by")
            b:stop(3)
            return false, "never lined up"
        end
        b:say("closest the crank point came: " .. (overAt or "never over the rail"))
        b.tightLine = false
        -- On it: hold still and let the rail's end finish it.
        local tg = CurTime()
        while b:st().grind and CurTime() - tg < 6 do b:set({}) tick() end
        b:waitLanded(0.6, 3)
        if b:scoredSince(t0, name) and b:riding() then return true end
        local got = b:scoredSince(t0)
        return false, got and ("scored " .. got.name .. " instead") or (why or "no grind scored")
    end
end
grindTrick("Crank Grind")
grindTrick("Double Peg Grind")

--------------------------------------------------------------------------
-- VERT TRICKS (G06): "Air 180" and "Spine Transfer". Not in TrickList (so the
-- show and the SKATE game do not pick them, and no bot_* headless case is made
-- for them): they need a park piece, which is only here when the bot lays one
-- (BMX.Park, G27), so they are asked for by name -- `bmx_bot_trick Air 180`.
--
-- The ramp finder (BMX.FindLaunch) looks for 12-40 degree kickers and turns a
-- quarter pipe down on purpose ("it sends you straight up, not over"), so a
-- vert wall is laid, not found: a tall quarter pipe for the 180, a spine for
-- the transfer, at the end of the longest clear run, and ridden at sprinting.
--------------------------------------------------------------------------
-- A park piece laid `run` units ahead along the clearest heading, its
-- transition starting there. Returns the piece, the heading and the start of the
-- run, or nil and why.
function Brain:layPark(shape, params, run)
    if not (BMX.Park and BMX.Park.Place and BMX.Park.Build) then return nil, "no park pieces" end
    local dir, len = self:openRun(run + 400)
    if not dir or len < run + 200 then return nil, string.format("no room for a run of %.0f u", run) end
    local b = BMX.Park.Build(shape, params)
    local from = self.bike:GetPos()
    local foot = from + dir * run
    local tr = util.TraceLine({ start = foot + UP * 200, endpos = foot - UP * 600,
        filter = self:filter(), mask = MASK_SOLID })
    if not tr.Hit then return nil, "no ground to stand the piece on" end
    local yaw = math.deg(math.atan2(dir.y, dir.x))
    local e, why = BMX.Park.Place(nil, shape, params, Vector(foot.x, foot.y, tr.HitPos.z) + dir * b.hl,
        Angle(0, yaw, 0))
    if not e then return nil, why end
    e.BMXRail = true            -- the bot's own traces let it be (Brain:filter)
    self.props[#self.props + 1] = e
    if coroutine.running() then for _ = 1, 6 do tick() end end
    return e, dir, from
end

-- Ride at the wall sprinting until the bike leaves it. True if it did.
function Brain:rideAtWall(dir, from)
    self:alignTo(dir)
    self:rideLine(from, dir, 420, function() return self:st().airMode end, 10,
        function() return { sprint = true } end)
    return self:st().airMode and true or false
end

Bot.Tricks["Air 180"] = function(b)
    local _, dir, from = b:layPark("quarterpipe", { 2, 3 }, 800)
    if not _ then return false, dir end
    local t0 = CurTime()
    if not b:rideAtWall(dir, from) then return false, "never left the coping" end
    local st = b:st()
    b:say(string.format("off the coping: %s, vz %.0f", tostring(st.launchKind), b:bike_vz()))
    if st.launchKind ~= "vert" then
        b:set({})
        b:waitLanded(0.5, 4)
        return false, "left it as " .. tostring(st.launchKind) .. ", not vert"
    end
    -- D until a half turn is done (the assist carries it from there and the
    -- landing aims it back down the wall), then hands off.
    local t1 = CurTime()
    while b:riding() and st.airMode and CurTime() - t1 < 3 do
        if math.abs(st.vertSpin or 0) >= math.pi * 0.9 then b:set({}) else b:set({ lean = 1 }) end
        tick()
    end
    b:set({})
    b:waitLanded(0.8, 4)
    if b:scoredSince(t0, "Air 180") and b:riding() then return true end
    return false, "nothing scored"
end

Bot.Tricks["Spine Transfer"] = function(b)
    local _, dir, from = b:layPark("spine", { 2, 3 }, 800)
    if not _ then return false, dir end
    local t0 = CurTime()
    if not b:rideAtWall(dir, from) then return false, "never left the coping" end
    local st = b:st()
    -- A fresh W once the far face is seen: a press, held a moment, as a rider's is.
    local t1, pressed = CurTime(), nil
    while b:riding() and st.airMode and CurTime() - t1 < 3 do
        if st.spineTarget and not pressed then pressed = CurTime() end
        if pressed and CurTime() - pressed < 0.35 then b:set({ pitch = -1 }) else b:set({}) end
        tick()
    end
    b:set({})
    b:waitLanded(0.8, 4)
    if b:scoredSince(t0, "Spine Transfer") and b:riding() then return true end
    return false, pressed and "no transfer scored" or "never saw the far face"
end

function Brain:bike_vz() return self.bike:GetVelocity().z end

--------------------------------------------------------------------------
-- Running: one trick at a time, recovered from crashes.
--------------------------------------------------------------------------

-- Start a trick. The brain runs it from its Think; `done(ok, why)` is called
-- when it finishes. Returns false if there is no such trick.
function Bot.Perform(b, name, done)
    local fn = Bot.Tricks[name]
    if not fn then return false end
    local r = b.results[name] or { tries = 0, landed = 0 }
    b.results[name] = r
    r.tries = r.tries + 1
    b.current = name
    b.jobRode, b.jobStart = false, CurTime()
    b.job = coroutine.create(function()
        local ok, why = fn(b)
        return ok, why
    end)
    b.jobDone = function(ok, why)
        b.current = nil
        if ok then r.landed = r.landed + 1 end
        r.last = ok and "landed" or ("missed: " .. tostring(why))
        b:say(name .. ": " .. r.last)
        if not b.quiet and ok and IsValid(b.ply) then
            for _, p in ipairs(player.GetHumans()) do
                p:ChatPrint(string.format("[BMX] %s landed a %s!", b.ply:Nick(), name))
            end
        end
        -- Tidy: a ramp or rail it put down for this trick goes.
        for _, e in ipairs(b.props) do SafeRemoveEntity(e) end
        b.props = {}
        if done then done(ok, why) end
    end
    return true
end

-- Back on the bike after a crash: the tumble ends, the player respawns
-- beside it, and gets on (which picks a fallen bike up).
function Brain:recover()
    local ply, bike = self.ply, self.bike
    if not IsValid(bike) then return end
    if ply.BMXTumbling or not ply:Alive() then return end
    if IsValid(ply:GetVehicle()) then return end
    if (self.nextMount or 0) > CurTime() then return end
    self.nextMount = CurTime() + 0.5
    ply:SetPos(BMX.ExitPoint and BMX.ExitPoint(bike, ply) or bike:GetPos() + Vector(0, 40, 8))
    ply:EnterVehicle(bike:GetPod())
end

-- Open ground to put a stuck bot back on: its home, else the spawn points
-- nearest the bike. A spot is open when a bike-sized box drops onto ground
-- there without starting inside anything.
function Bot.OpenSpot(b)
    local cands = {}
    if b.home then cands[#cands + 1] = b.home end
    local here = IsValid(b.bike) and b.bike:GetPos() or vector_origin
    local spawns = {}
    for _, c in ipairs({ "info_player_start", "info_player_deathmatch" }) do
        for _, e in ipairs(ents.FindByClass(c)) do spawns[#spawns + 1] = e:GetPos() end
    end
    table.sort(spawns, function(p, q) return p:DistToSqr(here) < q:DistToSqr(here) end)
    for _, p in ipairs(spawns) do cands[#cands + 1] = p end
    local filter = { b.bike, b.ply }
    for _, p in ipairs(cands) do
        local tr = util.TraceHull({ start = p + UP * 80, endpos = p - UP * 200, mins = Vector(-40, -40, 0),
                                    maxs = Vector(40, 40, 60), filter = filter, mask = MASK_SOLID })
        if tr.Hit and not tr.StartSolid then return tr.HitPos end
    end
    return b.home or here
end

-- Give up what it was doing and stand the bike up on open ground.
function Brain:unstick(why)
    local bike = self.bike
    self.escape = nil
    self.unstuck = (self.unstuck or 0) + 1
    self.stuckAt, self.stuckSince = nil, nil
    if self.job then
        local done = self.jobDone
        self.job = nil
        if done then done(false, "stuck: " .. why) end
    end
    local at = Bot.OpenSpot(self)
    -- Through the physics object: Entity:SetPos is not how a body is moved.
    local pos, ang = at + UP * (BMX.RestHeight(bike:Cfg()) + 0.5), Angle(0, bike:GetAngles().y, 0)
    local phys = bike:GetPhysicsObject()
    if not IsValid(phys) then
        bike:SetPos(pos)
        bike:SetAngles(ang)
    else
        phys:SetAngles(ang)
        phys:SetPos(pos)
        phys:SetVelocity(vector_origin)
        phys:SetAngleVelocity(vector_origin)
        phys:Wake()
    end
    self:set({})
    if not self:riding() then self:recover() end
    self:say(string.format("stuck (%s): back on open ground at (%.0f %.0f %.0f)", why, at.x, at.y, at.z))
end

function Brain:watchStuck()
    local pos = self.bike:GetPos()
    local home = self.home
    -- Fallen far below home is out of the world at once. The engine's own
    -- test is only believed when it holds: the bike's origin dips into a
    -- ramp's brush for a tick on a hard landing, and on the live park that
    -- reset a Superman Backflip in mid-air.
    if home and pos.z < home.z - Bot.Config.stuckFall then return self:unstick("out of the world") end
    if util.IsInWorld and not util.IsInWorld(pos) then
        self.outSince = self.outSince or CurTime()
        if CurTime() - self.outSince > Bot.Config.outOfWorldTime then
            self.outSince = nil
            return self:unstick("out of the world")
        end
    else
        self.outSince = nil
    end
    if self.escape then return end
    local busy = self.job ~= nil or not self:riding()
    if not busy or not self.stuckAt or pos:DistToSqr(self.stuckAt) > Bot.Config.stuckMove ^ 2 then
        self.stuckAt, self.stuckSince = pos, CurTime()
        return
    end
    local t = CurTime() - self.stuckSince
    if t > Bot.Config.stuckEscape then self:startEscape(string.format("no progress in %.0f s", t)) end
end

-- GETTING ITSELF OUT, the way a rider does before anyone helps: hop out of
-- it toward open ground, then walk the bike backwards and turn it to face
-- the open side, then hop again. Moving clear of the spot ends it; running
-- out of moves (stuckTime in all) is the reset.
Bot.EscapeMoves = {
    { name = "bounce",  secs = 1.8 },
    { name = "back up", secs = 1.6 },
    { name = "bounce",  secs = 1.8 },
}

-- The heading (degrees) with the most room in front of the bike.
function Bot.OpenHeading(b)
    local p = b.bike:GetPos() + UP * 20
    local best, bestYaw = -1, b.bike:GetAngles().y
    for i = 0, 7 do
        local yaw = bestYaw + i * 45
        local dir = Angle(0, yaw, 0):Forward()
        local tr = util.TraceLine({ start = p, endpos = p + dir * 400, filter = { b.bike, b.ply }, mask = MASK_SOLID })
        local room = tr.Fraction * 400
        if room > best + 1 then best, bestYaw = room, yaw end
    end
    return bestYaw
end

function Brain:startEscape(why)
    if self.job then
        local done = self.jobDone
        self.job = nil
        if done then done(false, "stuck: " .. why) end
    end
    self.escape = { stage = 1, t0 = CurTime(), from = self.bike:GetPos(), why = why, yaw = Bot.OpenHeading(self),
                    started = CurTime() }
    self:say(string.format("stuck (%s): trying to get out", why))
end

function Brain:runEscape()
    local e, bike = self.escape, self.bike
    local pos = bike:GetPos()
    if pos:DistToSqr(e.from) > (Bot.Config.stuckMove * 1.5) ^ 2 and self:riding() then
        self.escape = nil
        self.escaped = (self.escaped or 0) + 1
        self.stuckAt, self.stuckSince = pos, CurTime()
        self:set({})
        self:say("got out (" .. Bot.EscapeMoves[math.min(e.stage, #Bot.EscapeMoves)].name .. ")")
        return
    end
    local move = Bot.EscapeMoves[e.stage]
    if not move or CurTime() - e.started > Bot.Config.stuckTime then
        self.escape = nil
        return self:unstick(e.why)
    end
    if not self:riding() then self:recover() return end
    local t = CurTime() - e.t0
    if move.name == "bounce" then
        local lean = self:steerLean(e.yaw)
        self:set({ throttle = 1, sprint = true, lean = lean })
        if t < 0.45 then
            if not e.charging then bike.hopHeld, bike.hopCharge, e.charging = true, 0, true end
        elseif not e.popped then
            bike.hopRelease, e.popped = true, true
        end
    else
        self:set({})
        local phys = bike:GetPhysicsObject()
        if t < 0.6 and IsValid(phys) then
            phys:SetVelocity(-bike:GetForward() * 140 + UP * 30)
        elseif not e.turned then
            if IsValid(phys) then phys:SetAngles(Angle(0, e.yaw, 0)) else bike:SetAngles(Angle(0, e.yaw, 0)) end
            e.turned = true
        end
    end
    if t > move.secs then
        e.stage, e.t0, e.charging, e.popped, e.turned = e.stage + 1, CurTime(), nil, nil, nil
        e.yaw = Bot.OpenHeading(self)
    end
end

function Bot.Think()
    for ply, b in pairs(Bot.brains) do
        if not IsValid(ply) or not IsValid(b.bike) then
            Bot.Detach(b)
        else
            b:watchStuck()
            if b.escape then
                b:runEscape()
            elseif not b:riding() and b.job and not b.jobRode then
                -- Not on yet (still getting up from the last crash, say): a
                -- trick waits to get on before it starts, a while, rather than
                -- counting a crash it was never part of.
                b:recover()
                if CurTime() - (b.jobStart or CurTime()) > 8 then
                    local done = b.jobDone
                    b.job = nil
                    if done then done(false, "could not get on the bike") end
                end
            elseif not b:riding() then
                if b.job then
                    local st = b.bike.st or {}
                    b:say(string.format("thrown off: spin p/r/y %.0f/%.0f/%.0f deg, pitch %.0f, roll %.0f, grounded %s, air %s, speed %.0f",
                        math.deg(st.spinPitch or 0), math.deg(st.spinRoll or 0), math.deg(st.spinYaw or 0),
                        math.deg(select(2, BMX.Attitude(b.bike, UP))), math.deg(select(1, BMX.Attitude(b.bike, UP))),
                        tostring(st.grounded), tostring(st.airMode), st.speed or 0))
                    local done = b.jobDone
                    b.job = nil
                    if done then done(false, "crashed") end
                end
                b:recover()
            elseif b.job then
                b.jobRode = true
                local ok, a, c = coroutine.resume(b.job)
                if not ok then
                    b.job = nil
                    ErrorNoHalt("[BMX] bot trick failed: " .. tostring(a) .. "\n")
                    if b.jobDone then b.jobDone(false, "error: " .. tostring(a)) end
                elseif coroutine.status(b.job) == "dead" then
                    b.job = nil
                    if b.jobDone then b.jobDone(a, c) end
                end
            elseif b.show then
                b:nextInShow()
            end
        end
    end
end
hook.Add("Think", "BMX.Bot", Bot.Think)

-- The show: every trick in the list, over and over, retrying a miss.
function Brain:nextInShow()
    if (self.showRest or 0) > CurTime() then
        self:set({})
        return
    end
    local name = table.remove(self.queue or {}, 1)
    if not name then
        self.queue = {}
        for _, n in ipairs(Bot.TrickListFor and Bot.TrickListFor(self.bike) or Bot.TrickList) do self.queue[#self.queue + 1] = n end
        name = table.remove(self.queue, 1)
    end
    Bot.Perform(self, name, function(ok)
        local r = self.results[name]
        if not ok and (self.retries or 0) < Bot.Config.attempts - 1 then
            self.retries = (self.retries or 0) + 1
            table.insert(self.queue, 1, name)
        else
            self.retries = 0
        end
        self.showRest = CurTime() + 1.5
    end)
end

--------------------------------------------------------------------------
-- The bot player: its name, its model, kept through every respawn.
--------------------------------------------------------------------------
hook.Add("PlayerSetModel", "BMX.Bot.Model", function(ply)
    local m = ply.BMXBotModel
    if m and m ~= "" then
        ply:SetModel(m)
        return true
    end
end)

function Bot.Spawn(at, yaw, bikeId)
    if #player.GetAll() >= game.MaxPlayers() then return nil, "no free player slot" end
    local ply = player.CreateNextBot(cvName:GetString())
    if not IsValid(ply) then return nil, "could not create a bot" end
    local model = cvModel:GetString()
    if model ~= "" and util.IsValidModel(model) then
        ply.BMXBotModel = model
        ply:SetModel(model)
    elseif model ~= "" then
        ErrorNoHalt("[BMX] bmx_bot_model " .. model .. " is not mounted on this server; default model used\n")
    end
    local class = BMX.ClassFor(bikeId or "stock") or "bmx_base"
    local bike = ents.Create(class)
    if not IsValid(bike) then ply:Kick("no bike") return nil, "could not create the bike" end
    bike:SetPos(at + Vector(0, 0, BMX.RestHeight(bike:Cfg()) + 0.5))
    bike:SetAngles(Angle(0, yaw or 0, 0))
    bike:Spawn()
    bike:Activate()
    bike.BMXBotBike = true
    ply:SetPos(at + Vector(0, 40, 8))
    ply:EnterVehicle(bike:GetPod())
    local b = Bot.Attach(ply, bike, { home = at })
    b.show = true
    return b
end

-- The console always may; a player needs the CAMI privilege "BMX - Bot"
-- (admin by default, see sh_permissions.lua).
local function allowed(ply)
    return BMX.Can(ply, "BMX - Bot")
end

concommand.Add("bmx_bot_spawn", function(ply, _, args)
    if not allowed(ply) then return end
    local at, yaw = Vector(0, 0, 0), 0
    if IsValid(ply) then
        local tr = ply:GetEyeTrace()
        at, yaw = tr.HitPos, ply:EyeAngles().y
    else
        local s = ents.FindByClass("info_player_start")[1]
        if IsValid(s) then at = s:GetPos() end
    end
    local b, err = Bot.Spawn(at, yaw, args[1])
    local msg = b and ("[BMX] " .. b.ply:Nick() .. " is riding") or ("[BMX] no bot: " .. tostring(err))
    if IsValid(ply) then ply:ChatPrint(msg) else print(msg) end
end)

concommand.Add("bmx_bot_remove", function(ply)
    if not allowed(ply) then return end
    for p, b in pairs(Bot.brains) do
        local bike = b.bike
        Bot.Detach(b)
        if IsValid(p) and p:IsBot() then p:Kick("BMX bot removed") end
        if IsValid(bike) and bike.BMXBotBike then SafeRemoveEntity(bike) end
    end
end)

concommand.Add("bmx_bot_trick", function(ply, _, args)
    if not allowed(ply) then return end
    local name = table.concat(args, " ")
    if not Bot.Tricks[name] then
        local m = "[BMX] tricks: " .. table.concat(Bot.TrickList, ", ")
        if IsValid(ply) then ply:ChatPrint(m) else print(m) end
        return
    end
    for _, b in pairs(Bot.brains) do
        b.queue = b.queue or {}
        table.insert(b.queue, 1, name)
    end
end)

function Bot.Status(b)
    local out = { b.ply:Nick() .. (b.current and (" -- doing " .. b.current) or "") }
    for _, name in ipairs(Bot.TrickList) do
        local r = b.results[name]
        out[#out + 1] = string.format("  %-16s %s", name,
            r and string.format("%d/%d  %s", r.landed, r.tries, r.last or "") or "not tried")
    end
    return out
end

concommand.Add("bmx_bot_status", function(ply)
    for _, b in pairs(Bot.brains) do
        for _, line in ipairs(Bot.Status(b)) do
            if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, line) else print(line) end
        end
    end
end)
