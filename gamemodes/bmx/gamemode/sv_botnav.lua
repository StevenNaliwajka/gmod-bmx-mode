--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sv_botnav.lua

    The trick bot, routed on the navmesh (the addon's lua/bmx/sv_nav.lua).

    sv_bot.lua rides in straight lines: to the start of a run, to a ramp, to
    room for a rail. In a park that is a line straight into a funbox. With a
    mesh loaded, this layer changes three things and nothing else:

      RIDING SOMEWHERE (Brain:rideTo). When the straight line is not ridable on
      the mesh, the bot follows an A* path instead: waypoints pulled tight,
      slowing for the corners, replanning once if it gets stuck. The last leg
      is the original rideTo, so arriving -- and stopping -- is unchanged.

      A LAUNCH for an air trick (Brain:launch). The catalog has every launch on
      the map, found once. The bot picks one by height and angle, how far it
      is ON THE MESH (not as the crow flies), and how often it has used it
      lately, so a show moves round the park instead of hitting one kicker.

      A RUN for a flat trick or a rail (Brain:openRun). When there is no room
      where it stands, it rides to the nearest catalogued runway that is long
      enough, lines up on it and goes.

    Without a mesh every one of these is the original, untouched.

        bmx_bot_nav 1     route on the navmesh when the map has one
----------------------------------------------------------------------------]]

BMX = BMX or {}
local Bot, Nav = BMX.Bot, BMX.Nav
local Brain = Bot and Bot.Brain
if not (Brain and Nav) then return end

local UP = Vector(0, 0, 1)

local cvNav = CreateConVar("bmx_bot_nav", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED),
    "BMX: the trick bot routes on the navmesh when the map has one (bmx_nav_build makes one).")

local function navReady()
    return cvNav:GetBool() and Nav.Meshed()
end
Bot.NavReady = navReady

local function tick() coroutine.yield() end

-- The originals, kept on the Brain table itself: a reload of this file must
-- not wrap a wrapper, and a reload of sv_bot.lua makes a new Brain whose
-- originals are the new ones.
Brain.navOrig = Brain.navOrig or { rideTo = Brain.rideTo, launch = Brain.launch, openRun = Brain.openRun }
local O = Brain.navOrig

--------------------------------------------------------------------------
-- Following a path
--------------------------------------------------------------------------
-- How fast through the corner at waypoint k of `pts`.
local function cornerSpeed(pts, k, speed)
    local a, b, c = pts[k - 1], pts[k], pts[k + 1]
    if not (a and b and c) then return speed end
    local u, v = b - a, c - b
    u.z, v.z = 0, 0
    if u:Length() < 1 or v:Length() < 1 then return speed end
    local ang = math.deg(math.acos(math.Clamp(u:GetNormalized():Dot(v:GetNormalized()), -1, 1)))
    if ang > 75 then return math.min(speed, 90) end
    if ang > 40 then return math.min(speed, 150) end
    if ang > 20 then return math.min(speed, 220) end
    return speed
end

function Brain:navTo(p, speed, radius, timeout)
    local t0 = CurTime()
    timeout = timeout or 25
    for attempt = 0, 1 do
        local pts, why = Nav.Path(self.bike:GetPos(), p)
        if not pts then
            self:say("nav: " .. tostring(why) .. "; riding straight")
            return O.rideTo(self, p, speed, radius, timeout - (CurTime() - t0))
        end
        -- The caller's timeout is for a straight ride; a route across the
        -- park at run-up pace is longer than that, so it gets its length's worth.
        local len = 0
        for k = 2, #pts do len = len + pts[k]:Distance(pts[k - 1]) end
        timeout = math.max(timeout, (CurTime() - t0) + len / math.max(speed * 0.6, 60) + 8)
        self:say(string.format("nav: %d waypoints, %.0f u, to (%.0f %.0f)", #pts - 1, len, p.x, p.y))
        self.navPath = pts
        local res, why2 = self:followPath(pts, speed, t0, timeout)
        self.navPath = nil
        if res == "arrived" then break end
        if res ~= "stuck" or attempt == 1 then return false, why2 end
        self:say("nav: stuck, planning again")
        self:set({})
    end
    return O.rideTo(self, p, speed, radius, math.max(timeout - (CurTime() - t0), 6))
end

-- Ride the waypoints up to the last one. Returns "arrived", or "stuck" /
-- "failed" and why.
function Brain:followPath(pts, speed, t0, timeout)
    local k, stuckSince, began = 2, nil, CurTime()
    while k < #pts do
        if CurTime() - t0 > timeout then return "failed", "nav: timed out" end
        if not self:riding() then return "failed", "off the bike" end
        local pos = self.bike:GetPos()
        local wp = pts[k]
        local d = wp - pos
        d.z = 0
        local seg = pts[k] - pts[k - 1]
        seg.z = 0
        -- Reached, or passed (a corner cut wide still counts).
        if d:Length() < 70 or (seg:Length() > 1 and d:Dot(seg) < 0) then
            k = k + 1
        else
            -- Aim a little past the waypoint along the next leg: the bike
            -- turns by leaning and needs the turn begun before the corner.
            local aim = wp
            local nxt = pts[k + 1]
            if nxt and d:Length() < 160 then aim = LerpVector(0.35, wp, nxt) end
            local da = aim - pos
            local want = math.deg(math.atan2(da.y, da.x))
            local lean, err = self:steerLean(want)
            local target = cornerSpeed(pts, k, speed)
            if math.abs(err) > 90 then target = math.min(target, 60)
            elseif math.abs(err) > 40 then target = math.min(target, 140) end
            local thr, brk = self:pace(target)
            self:set({ throttle = thr, brakeRear = brk, lean = lean })
            if self:speed() < 8 and CurTime() - began > 2 then
                stuckSince = stuckSince or CurTime()
                if CurTime() - stuckSince > 2.5 then return "stuck", "nav: stuck on the way" end
            else
                stuckSince = nil
            end
            tick()
        end
    end
    return "arrived"
end

-- Straight when straight works; the mesh when it does not.
function Brain:rideTo(p, speed, radius, timeout)
    if navReady() and IsValid(self.bike) then
        local from = self.bike:GetPos()
        local flat = p - from
        flat.z = 0
        if flat:Length() > 150 then
            local ok = Nav.Straight(from, p, { stepUp = 8 })
            if ok then
                -- On the mesh, but a prop (not meshed) may still stand in the way.
                local dir = flat:GetNormalized()
                local clear = BMX.Launch.Runway(from + UP * 4, dir, flat:Length(), { filter = self:filter() })
                ok = clear >= flat:Length() - 40
            end
            if not ok then return self:navTo(p, speed, radius, timeout) end
        end
    end
    return O.rideTo(self, p, speed, radius, timeout)
end

--------------------------------------------------------------------------
-- Choosing where to do it
--------------------------------------------------------------------------
local function spotKey(v) return string.format("%d,%d", math.floor(v.x / 64), math.floor(v.y / 64)) end

-- The best of `list` by `score(item)` minus the cost of getting to `at(item)`
-- on the mesh. Only the few best by straight distance are pathed.
function Brain:pickByPath(list, score, at)
    local here = self.bike:GetPos()
    local rough = {}
    for _, it in ipairs(list) do
        rough[#rough + 1] = { it = it, s = score(it) - here:Distance(at(it)) * 0.05 }
    end
    table.sort(rough, function(a, b) return a.s > b.s end)
    local best, bestS
    for i = 1, math.min(#rough, 5) do
        local it = rough[i].it
        local _, areas = Nav.Path(here, at(it))
        if areas then
            local cost = 0
            for j = 2, #areas do cost = cost + areas[j - 1]:GetCenter():Distance(areas[j]:GetCenter()) end
            local s = score(it) - cost * 0.05
            if not bestS or s > bestS then best, bestS = it, s end
        end
    end
    return best
end

-- Where to start a runway: in from its end (a runway's end is usually a
-- wall, and a bike cannot turn round against one), and how well the bike
-- rides INTO it from where it is (arriving from the far end is a U-turn).
local RUN_INSET = 150
local function runStart(r) return r.from + r.dir * RUN_INSET end
local function runEntry(b, r)
    local to = runStart(r) - b.bike:GetPos()
    to.z = 0
    if to:Length() < 1 then return 0 end
    return to:GetNormalized():Dot(r.dir) * 300
end

function Brain:used(key, n)
    self.navUsed = self.navUsed or {}
    if n then self.navUsed[key] = (self.navUsed[key] or 0) + n end
    return self.navUsed[key] or 0
end

-- What each launch has actually done for the bot on this map, by lip:
-- { landed, missed }. Shared by every bot, kept for the map: the catalog
-- says a ramp LOOKS like a launch (BMX.Launch.Flight assumes one take-off
-- for every ramp), this says whether a trick off it lands. A funbox's lip
-- passes the first and fails the second -- the deck is right there.
Bot.LaunchStats = Bot.LaunchStats or {}
local AIR_FAIL = { ["not enough air"] = true, ["never left the lip"] = true }

function Bot.LaunchScore(l)
    local st = Bot.LaunchStats[spotKey(l.lip)] or { landed = 0, missed = 0 }
    local deg = math.deg(l.angle)
    return l.height * 2 - math.abs(deg - 22) * 3 + st.landed * 40 - st.missed * 90, st
end

-- After a trick that used a catalogued launch, what came of it.
function Bot.LaunchOutcome(key, ok, why)
    local st = Bot.LaunchStats[key] or { landed = 0, missed = 0 }
    Bot.LaunchStats[key] = st
    why = tostring(why or "")
    if ok then st.landed = st.landed + 1
    elseif AIR_FAIL[why] or why:find("too slow", 1, true) or why:find("only %d") then st.missed = st.missed + 1 end
end

Bot.Config.navMinLaunch = Bot.Config.navMinLaunch or 80   -- u: lower is not a flip's worth of air

-- Worth trying: tall enough, and it has not let the bot down more often
-- than it has carried a trick.
function Bot.LaunchUsable(l)
    local _, st = Bot.LaunchScore(l)
    return l.height >= Bot.Config.navMinLaunch and st.missed <= st.landed
end

function Brain:launch()
    self.navLaunch = nil
    if self.allowFindRamp and navReady() then
        local cat = Nav.Spots()
        local good = {}
        for _, it in ipairs(cat.launches) do
            if Bot.LaunchUsable(it) then
                good[#good + 1] = it
            end
        end
        if #good == 0 and self.allowSpawnRamp then
            -- No ramp on this map has earned it: put a kicker down, on the
            -- best long runway the mesh knows -- the ring search from where
            -- the bot stands finds nothing beside a wall.
            local C = BMX.Launch.Config
            local need = Bot.Config.stageBack + 200 + C.landing + 300
            local fits = {}
            for _, r in ipairs(cat.runways) do if r.len >= need + RUN_INSET then fits[#fits + 1] = r end end
            local r = #fits > 0 and self:pickByPath(fits, function(it)
                return runEntry(self, it) - self:used(spotKey(it.from)) * 300
            end, runStart)
            if r then
                self:used(spotKey(r.from), 1)
                self:say(string.format("nav: no ramp here lands a trick; a kicker on a %.0f u runway", r.len))
                if self:navTo(runStart(r), 200, 60, 30) then
                    self:stop(3)
                    self:alignTo(r.dir)
                    local find = self.allowFindRamp
                    self.allowFindRamp = false
                    local l = O.launch(self)
                    self.allowFindRamp = find
                    if l then return l end
                end
            end
        end
        if #good > 0 then
            local l = self:pickByPath(good, function(it)
                return Bot.LaunchScore(it) - self:used(spotKey(it.lip)) * 60
            end, function(it) return it.foot - it.dir * 400 end)
            if l then
                self:used(spotKey(l.lip), 1)
                local _, st = Bot.LaunchScore(l)
                self:say(string.format("nav: launch %.0f u high, %.0f deg, %.0f u away (%d known, %d/%d landed here)",
                    l.height, math.deg(l.angle), (l.foot - self.bike:GetPos()):Length(), #cat.launches,
                    st.landed, st.landed + st.missed))
                self.navLaunch = spotKey(l.lip)
                local copy = {}
                for k, v in pairs(l) do copy[k] = v end
                return copy
            end
        end
    end
    return O.launch(self)
end

-- Every trick's result goes past the launch it used.
if Bot.Perform ~= Bot.navPerformWrap then Bot.navPerform = Bot.Perform end
function Bot.navPerformWrap(b, name, done)
    if b then b.navLaunch = nil end
    return Bot.navPerform(b, name, function(ok, why, ...)
        if b and b.navLaunch then Bot.LaunchOutcome(b.navLaunch, ok, why) b.navLaunch = nil end
        if done then return done(ok, why, ...) end
    end)
end
Bot.Perform = Bot.navPerformWrap

function Brain:openRun(need)
    local dir, len = O.openRun(self, need)
    if (dir and len >= need) or not navReady() then return dir, len end
    local cat = Nav.Spots()
    local fits = {}
    for _, r in ipairs(cat.runways) do if r.len >= need + RUN_INSET + 60 then fits[#fits + 1] = r end end
    if #fits == 0 then return dir, len end
    local r = self:pickByPath(fits, function(it)
        -- Along the park's axes where it can: a rail laid diagonally is
        -- measured by its box, and a 300 u rail at 30 degrees "is 160 wide".
        local axis = (math.abs(it.dir.x) > 0.99 or math.abs(it.dir.y) > 0.99) and 200 or 0
        return math.min(it.len, need * 2) * 0.1 + axis + runEntry(self, it) - self:used(spotKey(it.from)) * 40
    end, runStart)
    if not r then return dir, len end
    self:used(spotKey(r.from), 1)
    self:say(string.format("nav: a %.0f u runway, riding to it", r.len))
    if not self:navTo(runStart(r), 200, 60, 30) then return dir, len end
    self:stop(3)
    self:alignTo(r.dir)
    local l2 = BMX.Launch.Runway(self.bike:GetPos() + UP * 4, r.dir, need + 100, { filter = self:filter() })
    if l2 >= need * 0.8 then return r.dir, l2 end
    return O.openRun(self, need)
end

-- sv_bot.lua reloaded (Lua autorefresh) makes a new Brain without these:
-- put them back on it.
hook.Add("Think", "BMX.BotNav.Reinstall", function()
    if BMX.Bot and BMX.Bot.Brain and BMX.Bot.Brain ~= Brain then include("bmx/gamemode/sv_botnav.lua") end
end)
