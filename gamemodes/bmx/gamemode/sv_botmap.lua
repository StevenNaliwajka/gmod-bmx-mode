--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sv_botmap.lua

    THE BOT ON THE MAP AS IT IS. Peter does his tricks off what the map has --
    its funboxes, its ramps, the kerbs of its planting beds -- and puts nothing
    down of his own (bmx_bot_props 0, the default; sv_bot.lua). This file finds
    those things once per map and hands them to the tricks:

      RAMP FACES for the air tricks. A face is a slope of 12-40 degrees that
      ends in a DECK -- a funbox's top, a table's -- with flat clear ground in
      front of it to sprint at it from. The addon's launch finder
      (BMX.FindLaunch) only takes a slope whose lip DROPS away, a kicker; a
      map's funbox has none, and the only "launches" it found on
      petopia_bmx_fall were its corners, ridden at diagonally, which stalled
      the bike against the edge. Hopped off a face's lip at full sprint the
      bike goes up more than along and comes down on the deck: about 0.85 s
      of air off an 86 u funbox (measured, 2026-10-07). That is a tailwhip, a
      barspin or a pose, not a flip: a flip, a roll and a 360 need 1.1 s and
      more (Bot.AirNeed), so they are only done where a launch gives it.

      LEDGES for the peg grind. A ledge is a long straight edge standing
      10-32 u above the floor beside it with a flat top -- a kerb, a planter,
      a step -- which a bunny hop (about 42 u) reaches. The run closes on it
      from the floor side at grindYaw degrees and hops the pegs onto it
      (Brain:grindRun, the same press timing a laid rail uses).

    Then THE SHOW is what this map can host: a trick with nothing on the map
    for it is left out of the list rather than tried, failed and retried
    (Bot.TrickListFor), and the pose tricks (No-Hander, Can-Can, X-Up,
    Tabletop, Turndown) join it, since a funbox's air is a pose's air.

    Spots are used in turn (the least used first, then the nearest), so the
    show moves round the whole park rather than one funbox.

        bmx_bot_map           what the bot found on this map
        bmx_bot_map_rescan    look again (after the map's city or pieces change)
----------------------------------------------------------------------------]]

BMX = BMX or {}
local Bot = BMX.Bot
local Brain = Bot and Bot.Brain
if not Brain then return end

local UP = Vector(0, 0, 1)
local abs, max, min, floor = math.abs, math.max, math.min, math.floor
local function tick() coroutine.yield() end

Bot.Map = Bot.Map or {}
local M = Bot.Map
M.Config = {
    step        = 8,     -- u between ground samples along a profile
    minSlope    = 12,    -- deg: a face is at least this steep...
    maxSlope    = 40,    -- ...and at most this (a quarter pipe is not a launch)
    minHeight   = 40,    -- u from foot to lip
    flatRise    = 0.07,  -- rise per u still counted flat (4 deg)
    deckMin     = 96,    -- u of flat top past the lip to come down on
    rollMax     = 420,   -- u past the deck within which it is back on the floor
    dropMax     = 14,    -- u: a bigger single step down past the deck is a drop, not a roll-off
    runup       = 400,   -- u of flat clear ground before the foot (the run starts up to 150 u inside it)
    runWide     = 30,    -- u clear either side of the run-up's line
    gridStep    = 96,    -- u between the grid points a face is also looked for from
    kickerLanding = 380, -- u of open floor past a kicker's lip to come down on and ride away
    minWidth    = 64,    -- u across a face
    airGuess    = 0.85,  -- s of air off a face before one has been flown
    ledgeLo     = 10,    -- u a ledge stands above the floor beside it, at least...
    ledgeHi     = 32,    -- ...and at most (a hop's reach)
    ledgeDeep   = 16,    -- u of top behind the edge
    ledgeMinLen = 240,   -- u of edge
    ledgeProbe  = 40,    -- u out from a floor area's side a ledge's face is looked for
    ledgeEvery  = 24,    -- u between samples along a side
    -- u onto the top the crank point aims for. It must come down within about
    -- 6 u of the edge for the grind to find it, and with the line held through
    -- the preload every hop came down 5.5 u to the floor side of its aim (16
    -- hops, every bed, both ways round): aimed 2 u on, half of them missed.
    ledgeLand   = 7,
    ledgeTol    = 4,     -- u either way of that the press accepts
    -- THE AIM IS LEARNED PER LEDGE. Letting go of the steering at the press
    -- swings the heading a few degrees, and over a hop's 250 u of flight that
    -- is 10-15 u sideways -- consistently on one ledge (+13 u onto the top on
    -- petopia_bmx_fall's north bed, three runs in three), differently on the
    -- next. So each attempt's sideways error is taken off the next aim there.
    ledgeLearn  = 0.7,   -- of a miss's sideways error taken off the next aim at that ledge
    ledgeKeep   = 0.3,   -- ...and of a landed one's, to stay centred
    ledgeBiasMax = 16,   -- u: the most that correction may come to
    grindYaw    = 9,     -- deg the run closes on the ledge's line
    grindRunup  = 720,   -- u of floor before the landing point (at grindYaw, 113 u out
                         -- from the kerb: room to arrive at the start without running into it)
    grindOn     = 160,   -- u of clear edge wanted after the landing point (the short
                         -- beds along the south wall are 240-360 u long)
    grindPrestage = 220, -- u further back along the run line it comes to the start from
    -- { closing angle deg, run-up u[, run-in to the start u] } tried in turn:
    -- the long shallow run first, the short steep ones (a planting bed in a
    -- lane between ramps, come at from the open floor) last. Up to 40 deg
    -- the grind takes.
    grindWays   = { { 9, 720 }, { 9, 560 }, { 18, 480 }, { 28, 450 }, { 34, 340, 100 }, { 38, 300, 80 } },
    budget      = 0.004, -- s of a tick the scan may use
}

--------------------------------------------------------------------------
-- Ground under a point. The map's world and whatever stands still on it
-- count -- a bmx_city_solid kerb is a ledge, a frozen bike-rental machine by
-- the spawn is something to ride round -- while riders, bikes, NPCs and
-- anything loose do not: those move, and the catalog is kept for the map.
--------------------------------------------------------------------------
function M.IsMapSolid(e)
    if not IsValid(e) then return true end
    if e.IsWorld and e:IsWorld() then return true end
    if e:IsPlayer() or e:IsNPC() or e:IsVehicle() or e.IsBMX then return false end
    if e:GetClass() == "bmx_city_solid" then return true end
    local phys = e:GetPhysicsObject()
    if IsValid(phys) then return not phys:IsMotionEnabled() end
    return e:GetMoveType() == MOVETYPE_NONE or e:GetMoveType() == MOVETYPE_PUSH
end
local function traceFilter(e) return M.IsMapSolid(e) end

-- The highest surface under (x, y) between z `top` and `bottom`: z, normal.
function M.Ground(x, y, top, bottom)
    local tr = util.TraceLine({ start = Vector(x, y, top), endpos = Vector(x, y, bottom),
                                mask = MASK_SOLID, filter = traceFilter })
    if tr.Hit and not tr.StartSolid then return tr.HitPos.z, tr.HitNormal end
end

--------------------------------------------------------------------------
-- RAMP FACES
--------------------------------------------------------------------------
-- What a profile of ground heights says, read uphill: `zs[i]` is the ground
-- `(i - 1) * step` along, and index `at` is on the slope. Pure, so tests
-- feed it made-up profiles. Returns { foot = i, lip = i, deck = u,
-- roll = "slope" | "drop" | "wall" | "none" } or nil and why.
function M.ReadFace(zs, at, step, C)
    C = C or M.Config
    local tMin, tMax = math.tan(math.rad(C.minSlope)), math.tan(math.rad(C.maxSlope))
    local function rise(i) return (zs[i + 1] and zs[i]) and (zs[i + 1] - zs[i]) / step or nil end
    local r = rise(at)
    if not r or r < tMin * 0.8 or r > tMax * 1.2 then return nil, "not on a slope" end
    -- Up to the lip: while it keeps climbing.
    local lip = at
    while rise(lip) and rise(lip) > C.flatRise do
        if rise(lip) > tMax * 1.4 then return nil, "it steepens into a wall" end
        lip = lip + 1
    end
    if not zs[lip + 1] then return nil, "the slope runs off the profile" end
    -- Down to the foot: while it keeps falling behind.
    local foot = at
    while foot > 1 and rise(foot - 1) and rise(foot - 1) > C.flatRise do foot = foot - 1 end
    if not zs[foot] or foot == 1 and rise(1) and rise(1) > C.flatRise then return nil, "no foot on the profile" end
    -- The deck: flat from the lip on.
    local d = lip
    while rise(d) and abs(rise(d)) <= C.flatRise do d = d + 1 end
    local deck = (d - lip) * step
    local roll = "none"
    if rise(d) then
        if rise(d) > C.flatRise then roll = "wall"
        else
            -- Down again: a slope or a drop, and back near the foot's height?
            roll = "slope"
            local i = d
            while zs[i + 1] and (i - d) * step <= C.rollMax and zs[i] > zs[foot] + 10 do
                if zs[i] - zs[i + 1] > C.dropMax then roll = "drop" break end
                if zs[i + 1] - zs[i] > C.flatRise * step then roll = "wall" break end
                i = i + 1
            end
            if roll == "slope" and zs[i] > zs[foot] + 10 then roll = "none" end
        end
    end
    return { foot = foot, lip = lip, deck = deck, roll = roll,
             height = zs[lip] - zs[foot], len = (lip - foot) * step }
end

-- The profile through `p` along `dir`: back `back` u and on `fwd` u.
local function profile(p, dir, back, fwd, step, zRef)
    local zs, n0 = {}, floor(back / step)
    local top, bottom = zRef + 260, zRef - 200
    for i = -n0, floor(fwd / step) do
        local q = p + dir * (i * step)
        zs[#zs + 1] = M.Ground(q.x, q.y, top, bottom)
        if not zs[#zs] then zs[#zs] = -1e9 end
    end
    return zs, n0 + 1
end

-- A face from a point on a slope, or nil and why.
function M.FaceAt(p, C)
    C = C or M.Config
    local z, n = M.Ground(p.x, p.y, p.z + 40, p.z - 40)
    if not z then return nil, "no ground" end
    local h = Vector(-n.x, -n.y, 0)
    if h:Length() < 0.05 then return nil, "flat" end
    local dir = h:GetNormalized()
    local slope = math.deg(math.acos(math.Clamp(n.z, -1, 1)))
    if slope < C.minSlope or slope > C.maxSlope then return nil, "slope " .. floor(slope) end
    local step = C.step
    local zs, at = profile(Vector(p.x, p.y, z), dir, 400, 1000, step, z)
    local f, why = M.ReadFace(zs, at, step, C)
    if not f then return nil, why end
    if f.height < C.minHeight then return nil, "only " .. floor(f.height) .. " u high" end
    local base = Vector(p.x, p.y, 0) - dir * ((at - 1) * step)
    local function pt(i) return Vector(base.x, base.y, 0) + dir * ((i - 1) * step) + UP * zs[i] end
    -- A KICKER: no deck, its lip drops straight back to the floor, and open
    -- floor beyond to come down on. The hop off its lip lands on that floor,
    -- the lip's height below: the air a flip needs.
    local kicker = false
    if f.roll == "drop" and f.deck < 40 then
        local lip = pt(f.lip)
        local landZ = M.Ground(lip.x + dir.x * 60, lip.y + dir.y * 60, lip.z, zs[f.foot] - 16)
        local clear = landZ and abs(landZ - zs[f.foot]) <= 6
            and BMX.Launch.Runway(Vector(lip.x, lip.y, landZ) + dir * 40 + UP * 4, dir, C.kickerLanding,
                { filter = traceFilter }) >= C.kickerLanding - 20
        if not clear then return nil, "a kicker with nowhere to land" end
        kicker = true
    else
        if f.deck < C.deckMin then return nil, "no deck to land on (" .. floor(f.deck) .. " u)" end
        if f.roll ~= "slope" then return nil, "no way off the deck (" .. f.roll .. ")" end
    end
    local face = { foot = pt(f.foot), lip = pt(f.lip), dir = dir, height = f.height,
                   length = f.len, angle = math.atan(f.height / max(f.len, 1)), deck = f.deck, kicker = kicker }
    -- Across it: the face is where the ground still leans the same way. Its
    -- middle is the line to ride (a funbox's side narrows toward the top).
    local mid = (face.foot + face.lip) * 0.5
    local side = Vector(-dir.y, dir.x, 0)
    local function extent(s)
        local d = 0
        while d < 800 do
            local q = mid + side * (s * (d + 16))
            local qz, qn = M.Ground(q.x, q.y, mid.z + 60, mid.z - 60)
            if not qz or qn:Dot(n) < 0.995 then break end
            d = d + 16
        end
        return d
    end
    local l, r = extent(1), extent(-1)
    if l + r < C.minWidth then return nil, "too narrow (" .. floor(l + r) .. " u)" end
    local shift = side * ((l - r) * 0.5)
    face.foot, face.lip = face.foot + shift, face.lip + shift
    face.width = l + r
    -- Room to sprint at it, flat and clear, from straight in front, and a
    -- bike's weave either side: a run-up 9 u clear of a ramp beside it was
    -- brushed and the bike stuck. Shifted across the face to find one.
    local best
    for _, off in ipairs({ 0, 32, -32, 64, -64 }) do
        if abs(off) <= face.width * 0.5 - 24 then
            local foot = face.foot + side * off
            local from = foot - dir * 24 + UP * 4
            local run = BMX.Launch.Runway(from, -dir, C.runup + 200, { filter = traceFilter })
            if run >= C.runup then
                local tr = util.TraceHull({ start = from + UP * 2, endpos = from + UP * 2 - dir * (C.runup - 40),
                    mins = Vector(-C.runWide, -C.runWide, 0), maxs = Vector(C.runWide, C.runWide, 24),
                    mask = MASK_SOLID, filter = traceFilter })
                if not tr.Hit and not tr.StartSolid then best = { off = off, run = run } break end
            end
        end
    end
    if not best then return nil, "no clear run-up" end
    face.foot, face.lip = face.foot + side * best.off, face.lip + side * best.off
    face.runup = best.run
    face.key = string.format("%d,%d,%d", floor(face.lip.x / 32), floor(face.lip.y / 32), floor(math.deg(math.atan2(dir.y, dir.x)) / 10 + 0.5))
    return face
end

--------------------------------------------------------------------------
-- LEDGES
--------------------------------------------------------------------------
-- Out from a point on the floor along `out`: a ledge's face within `reach`?
-- Returns the edge point (on the top) and the top's height, or nil.
function M.LedgeAt(p, out, C)
    C = C or M.Config
    local floorZ = p.z
    local probe = function(d)
        local q = p + out * d
        return M.Ground(q.x, q.y, floorZ + C.ledgeHi + 8, floorZ - 8)
    end
    -- The far end first: no top out there, no ledge here (one trace for most sides).
    local zFar = probe(C.ledgeProbe)
    if not zFar or zFar < floorZ + C.ledgeLo or zFar > floorZ + C.ledgeHi then return nil end
    -- The face: the first sample out from the floor that is up on the top.
    local lo, hi = 0, nil
    for d = 4, C.ledgeProbe, 4 do
        local z = probe(d)
        if z and abs(z - zFar) <= 1.5 then hi = d break end
        if not z or abs(z - floorZ) > 2 then return nil end   -- a slope or a step down: not a kerb
        lo = d
    end
    if not hi then return nil end
    for _ = 1, 5 do
        local m = (lo + hi) * 0.5
        local z = probe(m)
        if z and abs(z - zFar) <= 1.5 then hi = m else lo = m end
    end
    -- A top deep enough for the pegs, and level.
    local z2, n2 = probe(hi + C.ledgeDeep)
    if not z2 or abs(z2 - zFar) > 1.5 or (n2 and n2.z < 0.97) then return nil end
    local e = p + out * hi
    return Vector(e.x, e.y, zFar), zFar
end

-- Edge samples to segments: same side, same line, same top, no gap wider than
-- `gap`. Pure. Each sample is { pos = Vector, side = Vector (onto the top) }.
-- Returns { a, b, dir (a to b, ridden with the top on the LEFT), side, top, len }.
function M.JoinLedges(samples, gap, minLen)
    local groups = {}
    for _, s in ipairs(samples) do
        local sd = s.side
        local key = string.format("%d,%d", floor(sd.x * 10 + 0.5), floor(sd.y * 10 + 0.5))
        local along = Vector(sd.y, -sd.x, 0)          -- top on the left
        local line = s.pos.x * sd.x + s.pos.y * sd.y
        local put = false
        for _, g in ipairs(groups) do
            if g.key == key and abs(g.line - line) <= 6 and abs(g.top - s.pos.z) <= 3 then
                g.pts[#g.pts + 1] = s.pos:Dot(along)
                put = true
                break
            end
        end
        if not put then
            groups[#groups + 1] = { key = key, side = sd, along = along, line = line, top = s.pos.z,
                                    pts = { s.pos:Dot(along) } }
        end
    end
    local out = {}
    for _, g in ipairs(groups) do
        table.sort(g.pts)
        local function emit(a, b)
            if b - a >= minLen then
                local base = g.side * g.line
                local pa = Vector(base.x, base.y, g.top) + g.along * a
                local pb = Vector(base.x, base.y, g.top) + g.along * b
                out[#out + 1] = { a = pa, b = pb, dir = g.along, side = g.side, top = g.top, len = b - a }
            end
        end
        local s0, last = g.pts[1], g.pts[1]
        for i = 2, #g.pts do
            if g.pts[i] - last > gap then emit(s0, last) s0 = g.pts[i] end
            last = g.pts[i]
        end
        emit(s0, last)
    end
    table.sort(out, function(p, q) return p.len > q.len end)
    return out
end

-- The ground a ledge's floor is at, and its clear stretch: a pole on the top
-- or a bin by the kerb cuts it short (the grind ends at the last clear pose).
local function ledgeFloor(l, C)
    local mid = (l.a + l.b) * 0.5 - l.side * 24
    return M.Ground(mid.x, mid.y, l.top - 2, l.top - C.ledgeHi - 16)
end

--------------------------------------------------------------------------
-- PIPES: a crank grind's rail. Out from a floor area's side, the first top
-- 10-32 u up; the addon's own rail finder (BMX.FindRail) says whether it is a
-- pipe (both sides drop within Grind.pipeMaxWidth) and which way it runs.
--------------------------------------------------------------------------
function M.PipeAt(p, out, C)
    C = C or M.Config
    local floorZ = p.z
    for d = 2, C.ledgeProbe, 2 do
        local q = p + out * d
        local z = M.Ground(q.x, q.y, floorZ + C.ledgeHi + 8, floorZ - 8)
        if z and z >= floorZ + C.ledgeLo and z <= floorZ + C.ledgeHi then
            local r = BMX.FindRail(Vector(q.x, q.y, z + 2), Vector(-out.y, out.x, 0) * 100, BMX.Config, traceFilter)
            if r and r.kind == "crank" then
                local d2 = Vector(r.dir.x, r.dir.y, 0)
                if d2:Length() > 0.5 then
                    d2:Normalize()
                    return { pos = r.point, dir = d2, ground = floorZ }
                end
            end
            return nil
        elseif z and abs(z - floorZ) > 2 then
            return nil
        end
    end
end

-- Pipe samples to pipes: same line, same top. Pure. { a, b, dir, top, ground, len }.
function M.PipesFrom(samples, C)
    C = C or M.Config
    local groups = {}
    for _, s in ipairs(samples) do
        local d = s.dir
        if abs(d.x) < abs(d.y) then d = d.y < 0 and -d or d else d = d.x < 0 and -d or d end
        local n = Vector(-d.y, d.x, 0)
        local line = s.pos:Dot(n)
        local put
        for _, g in ipairs(groups) do
            if g.d:Dot(d) > 0.98 and abs(g.line - line) <= 4 and abs(g.top - s.pos.z) <= 3 then put = g break end
        end
        if not put then
            put = { d = d, n = n, line = line, top = s.pos.z, ground = s.ground, ts = {} }
            groups[#groups + 1] = put
        end
        put.ts[#put.ts + 1] = s.pos:Dot(d)
    end
    local out = {}
    for _, g in ipairs(groups) do
        table.sort(g.ts)
        local a, b = g.ts[1], g.ts[#g.ts]
        -- The samples come from the floor areas round it, so its ends are
        -- found again by walking along it with the grind's own test.
        local base = g.n * g.line + UP * g.top
        local function on(t)
            local q = base + g.d * t
            local r = BMX.FindRail(Vector(q.x, q.y, g.top + 2), g.d * 100, BMX.Config, traceFilter)
            return r and r.kind == "crank"
        end
        while on(a - 8) and a > g.ts[1] - 2000 do a = a - 8 end
        while on(b + 8) and b < g.ts[#g.ts] + 2000 do b = b + 8 end
        if b - a >= (C.pipeMinLen or 160) then
            out[#out + 1] = { a = base + g.d * a, b = base + g.d * b, dir = g.d, top = g.top, ground = g.ground,
                              len = b - a, key = string.format("p%d,%d,%d", floor((base.x + g.d.x * a) / 32),
                                  floor((base.y + g.d.y * a) / 32), floor(g.top)) }
        end
    end
    return out
end

--------------------------------------------------------------------------
-- THE SCAN: once per map, a few milliseconds a tick.
--------------------------------------------------------------------------
M.cat = M.cat or nil

local function areasOf(nav)
    local flat, sloped = {}, {}
    for _, a in ipairs(navmesh.GetAllNavAreas()) do
        local s = nav.AreaSlope(a)
        if s <= 4 then flat[#flat + 1] = a
        elseif s >= M.Config.minSlope - 2 and s <= M.Config.maxSlope + 2 then sloped[#sloped + 1] = a end
    end
    return flat, sloped
end

function M.Scan()
    local C = M.Config
    local Nav = BMX.Nav
    local cat = { faces = {}, ledges = {}, pipes = {}, map = game.GetMap(), at = CurTime(), why = {} }
    if not (Nav and navmesh and navmesh.GetNavAreaCount and navmesh.GetNavAreaCount() > 0) then
        cat.why.nomesh = true
        return cat
    end
    local t0 = SysTime()
    local function budget()
        if SysTime() - t0 > C.budget then tick() t0 = SysTime() end
    end
    local flat, sloped = areasOf(Nav)
    -- Faces: from every sloped area's centre (and a few points across a big one).
    for _, a in ipairs(sloped) do
        local c = a:GetCenter()
        local f = M.FaceAt(c, C)
        if f then
            local dup = false
            for _, k in ipairs(cat.faces) do
                if k.dir:Dot(f.dir) > 0.98 and k.lip:Distance(f.lip) < max(k.width, 64) * 0.5 + 32 then dup = true break end
            end
            if not dup then cat.faces[#cat.faces + 1] = f end
        end
        budget()
    end
    -- ...and from a coarse grid over the whole play area: a steep kicker
    -- had no nav area on its slope at all (the mesh keeps off a 25 degree
    -- face it cannot path up), so it was never looked at.
    local lo, hi
    if Nav.WorldBox then lo, hi = Nav.WorldBox() end     -- (not `a and f()`: that keeps one value)
    if lo and hi then
        local zTop = hi.z
        for x = lo.x + 32, hi.x - 32, C.gridStep do
            for y = lo.y + 32, hi.y - 32, C.gridStep do
                local tr = util.TraceLine({ start = Vector(x, y, min(zTop, lo.z + 700)), endpos = Vector(x, y, lo.z - 16),
                                            mask = MASK_SOLID, filter = traceFilter })
                if tr.Hit and not tr.StartSolid then
                    local sl = math.deg(math.acos(math.Clamp(tr.HitNormal.z, -1, 1)))
                    if sl >= C.minSlope and sl <= C.maxSlope then
                        local f = M.FaceAt(tr.HitPos + UP * 2, C)
                        if f then
                            local dup = false
                            for _, k in ipairs(cat.faces) do
                                if k.dir:Dot(f.dir) > 0.98 and k.lip:Distance(f.lip) < max(k.width, 64) * 0.5 + 32 then dup = true break end
                            end
                            if not dup then cat.faces[#cat.faces + 1] = f end
                        end
                    end
                end
                budget()
            end
        end
    end
    -- Ledges: along every flat area's four sides.
    local samples, pipeSamples = {}, {}
    local dirs = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0) }
    for _, a in ipairs(flat) do
        local c = a:GetCenter()
        local hx, hy = a:GetSizeX() * 0.5, a:GetSizeY() * 0.5
        for _, out in ipairs(dirs) do
            local along = Vector(-out.y, out.x, 0)
            local half = out.x ~= 0 and hy or hx
            local edge = c + out * (out.x ~= 0 and hx or hy)
            for s = -half + 8, half - 8, C.ledgeEvery do
                local p = edge + along * s
                local gz = M.Ground(p.x, p.y, c.z + 8, c.z - 24)
                if gz then
                    local e = M.LedgeAt(Vector(p.x, p.y, gz), out, C)
                    if e then samples[#samples + 1] = { pos = e, side = out } end
                    local pp = M.PipeAt(Vector(p.x, p.y, gz), out, C)
                    if pp then pipeSamples[#pipeSamples + 1] = pp end
                end
            end
            budget()
        end
    end
    -- Pipes: what the same walk round the floor finds standing 10-32 u up
    -- and too narrow to be a ledge -- the grind's own test says which.
    cat.pipes = M.PipesFrom(pipeSamples, C)
    for _, l in ipairs(M.JoinLedges(samples, C.ledgeEvery * 2.5, C.ledgeMinLen)) do
        local gz = ledgeFloor(l, C)
        if gz and l.top - gz >= C.ledgeLo and l.top - gz <= C.ledgeHi then
            l.ground = gz
            l.key = string.format("%d,%d,%d", floor(l.a.x / 32), floor(l.a.y / 32), floor(l.top))
            -- Pegs on an edge is a peg grind; a pipe (both sides drop within
            -- Grind.pipeMaxWidth) would be a crank grind -- this finds edges.
            l.kind = "peg"
            cat.ledges[#cat.ledges + 1] = l
        end
        budget()
    end
    return cat
end

-- The catalog for this map: built in the background on first ask. Returns it
-- when ready, else nil (and a trick waits for it a little; see Brain:mapCat).
function M.Get()
    if M.cat and M.cat.map == game.GetMap() then return M.cat end
    if not M.job then
        M.job = coroutine.create(function() return M.Scan() end)
    end
    return nil
end

hook.Add("Think", "BMX.BotMap.Scan", function()
    local job = M.job
    if not job then return end
    local ok, res = coroutine.resume(job)
    if not ok then
        M.job = nil
        M.cat = { faces = {}, ledges = {}, map = game.GetMap(), at = CurTime(), why = { error = tostring(res) } }
        ErrorNoHalt("[BMX] bot map scan failed: " .. tostring(res) .. "\n")
    elseif coroutine.status(job) == "dead" then
        M.job = nil
        M.cat = res
        print(string.format("[BMX] bot map: %d ramp faces, %d ledges, %d pipes on %s", #res.faces, #res.ledges, #(res.pipes or {}), res.map))
    end
end)

function Brain:mapCat(wait)
    local t0 = CurTime()
    local cat = M.Get()
    while not cat and coroutine.running() and CurTime() - t0 < (wait or 30) do
        tick()
        cat = M.Get()
    end
    return cat
end

--------------------------------------------------------------------------
-- How each spot has done: air flown off a face, grinds landed on a ledge.
--------------------------------------------------------------------------
M.stats = M.stats or {}
function M.Stat(key)
    local s = M.stats[key]
    if not s then s = { used = 0, landed = 0, missed = 0, air = nil } M.stats[key] = s end
    return s
end

-- The air a face gives: what it has given (the mean of the flights off it), else the guess.
function M.FaceAir(f)
    local s = M.Stat(f.key)
    if s.air then return s.air end
    -- A kicker lands its height below its lip: up ~220 u/s off the hop, then
    -- down past where it left (190 u: 1.24 s; measured 1.17-1.26).
    if f.kicker then
        local vz = 220
        return max((vz + math.sqrt(vz * vz + 1200 * f.height)) / 600 - 0.04, M.Config.airGuess)
    end
    return M.Config.airGuess
end

-- The flight off a launch, timed off the bike's own state: from leaving the
-- lip (Brain:hitLaunch sets launchT) to the wheels' first touch. Only that
-- one, and only on the bike: a tumble after a crash once counted as 1.8 s of
-- "air" and put a flip on a funbox's list.
hook.Add("Think", "BMX.BotMap.Air", function()
    for _, b in pairs(Bot.brains) do
        if b.launchT and IsValid(b.bike) and b.bike.st then
            local st = b.bike.st
            if not b:riding() or CurTime() - b.launchT > 3 then
                b.launchT = nil
            elseif st.grounded and not st.airMode and CurTime() - b.launchT > 0.15 then
                b.lastAir = CurTime() - b.launchT
                b.launchT = nil
            end
        end
    end
end)

--------------------------------------------------------------------------
-- Choosing: the least used first (so the show goes round the park), then
-- the best score less the riding to it.
--------------------------------------------------------------------------
local function pick(b, list, score, at)
    if #list == 0 then return nil end
    local least = math.huge
    for _, it in ipairs(list) do least = min(least, M.Stat(it.key).used) end
    local fresh = {}
    for _, it in ipairs(list) do if M.Stat(it.key).used <= least then fresh[#fresh + 1] = it end end
    if b.pickByPath and Bot.NavReady and Bot.NavReady() then
        local p = b:pickByPath(fresh, score, at)
        if p then return p end
    end
    local here = b.bike:GetPos()
    table.sort(fresh, function(p, q) return score(p) - here:Distance(at(p)) * 0.05 > score(q) - here:Distance(at(q)) * 0.05 end)
    return fresh[1]
end
M.Pick = pick

-- A face that gives `need` s of air, or nil.
function Brain:mapFace(need)
    local cat = self:mapCat()
    if not cat then return nil end
    local good = {}
    for _, f in ipairs(cat.faces) do
        local s = M.Stat(f.key)
        if M.FaceAir(f) >= need and s.missed <= s.landed + 1 then good[#good + 1] = f end
    end
    local f = pick(self, good, function(it) return it.height + it.deck * 0.1 end,
        function(it) return it.foot - it.dir * 300 end)
    if not f then return nil end
    M.Stat(f.key).used = M.Stat(f.key).used + 1
    self.mapFaceKey = f.key
    self:say(string.format("map: a %.0f u ramp face, %.0f deg, %.0f u deck (%.2f s of air expected), %.0f u away",
        f.height, math.deg(f.angle), f.deck, M.FaceAir(f), (f.foot - self.bike:GetPos()):Length()))
    local l = {}
    for k, v in pairs(f) do l[k] = v end
    return l
end

--------------------------------------------------------------------------
-- The launch: a face of the map's first; then whatever came before (the
-- navmesh's catalog, BMX.FindLaunch, and a kicker only with bmx_bot_props 1).
--------------------------------------------------------------------------
Brain.mapOrig = Brain.mapOrig or { launch = Brain.launch }
local O = Brain.mapOrig

-- A catalogued launch ridden off its fall line is a corner, not a ramp: the
-- nav catalog's funbox "launches" were diagonals across a funbox's corner.
function M.OnFallLine(l)
    if not (l and l.foot and l.lip and l.dir) then return false end
    local mid = (l.foot + l.lip) * 0.5
    local z, n = M.Ground(mid.x, mid.y, mid.z + 40, mid.z - 40)
    if not z then return false end
    local h = Vector(-n.x, -n.y, 0)
    if h:Length() < 0.05 then return false end
    return h:GetNormalized():Dot(l.dir) >= 0.94
end

function Brain:launch()
    self.mapFaceKey = nil
    local need = self.needAir or BMX.Launch.Config.minAir
    if self.allowFindRamp then
        local f = self:mapFace(need)
        if f then return f end
    end
    local l = O.launch(self)
    -- A kicker it put down itself (bmx_bot_props 1) is square to its run.
    if not l or l.plates then return l end
    if not M.OnFallLine(l) then
        self:say("that launch is a corner, ridden across: not taking it")
        return nil
    end
    return l
end

-- What came of a trick off a face: its air, landed or not.
if Bot.Perform ~= Bot.mapPerformWrap then Bot.mapPerform = Bot.Perform end
function Bot.mapPerformWrap(b, name, done)
    if b then b.mapFaceKey, b.mapLedgeKey, b.lastAir = nil, nil, nil end
    return Bot.mapPerform(b, name, function(ok, why, ...)
        if b and b.mapFaceKey then
            local s = M.Stat(b.mapFaceKey)
            if ok then s.landed = s.landed + 1 else s.missed = s.missed + 1 end
            if b.lastAir and b.lastAir > 0.3 then
                s.flights = (s.flights or 0) + 1
                s.air = s.air and (s.air + (b.lastAir - s.air) / s.flights) or b.lastAir
            end
            b.mapFaceKey = nil
        end
        if b and b.mapLedgeKey then
            local s = M.Stat(b.mapLedgeKey)
            if ok then s.landed = s.landed + 1 else s.missed = s.missed + 1 end
            -- Came down beside it: aim that much the other way next time.
            if b.grindMissLat and math.abs(b.grindMissLat) < 30 then
                local C = M.Config
                local k = ok and C.ledgeKeep or C.ledgeLearn
                -- lat is measured to the left: toward the top is +hand.
                local hand = b.mapLedgeHand or 1
                s.bias = math.Clamp((s.bias or 0) - hand * b.grindMissLat * k, -C.ledgeBiasMax, C.ledgeBiasMax)
            end
            b.mapLedgeKey = nil
        end
        if done then return done(ok, why, ...) end
    end)
end
Bot.Perform = Bot.mapPerformWrap

--------------------------------------------------------------------------
-- A ledge to grind, as the rail table Brain:grindRun rides (sv_bot.lua).
--------------------------------------------------------------------------
-- A ledge ridden one way or the other learns its aim apart.
function M.LedgeKey(l, rev) return rev and (l.key .. "r") or l.key end

-- How far along `l` from `x` the edge is clear for the bike beside it.
local function clearAlong(l, x, want, rev)
    local dir = rev and -l.dir or l.dir
    local start = (rev and l.b or l.a) + dir * x - l.side * 10 + UP * 4
    local tr = util.TraceHull({ start = start, endpos = start + dir * want,
        mins = Vector(-4, -4, 0), maxs = Vector(4, 4, 36), mask = MASK_SOLID, filter = traceFilter })
    if tr.StartSolid then return 0 end
    return tr.Fraction * want
end

-- The approach to land `x` u along ledge `l`: the rail table, or nil.
-- `x` u along the ledge from the end it is ridden from; `rev` rides it the
-- other way (the top on the right); `yawDeg` how steeply the run closes on it.
function M.LedgeRun(l, x, cfg, C, runup, yawDeg, rev, prestage)
    C = C or M.Config
    runup = runup or C.grindRunup
    local side = l.side
    local dir = rev and -l.dir or l.dir
    local a = rev and l.b or l.a
    -- +1: the top is on the left of the way it is ridden; -1: on the right.
    local hand = Vector(-dir.y, dir.x, 0):Dot(side) > 0 and 1 or -1
    local key = M.LedgeKey(l, rev)
    -- Aimed past where it last came down by what it missed by: the hop and
    -- the landing push the bike sideways by a few units a ledge, not the same
    -- on every one (-9 u on one bed's kerb, +4 on another's).
    local onTop = C.ledgeLand + (l.key and M.Stat(key).bias or 0)
    local ya = yawDeg or C.grindYaw
    local yaw = ya * hand
    local c, s = math.cos(math.rad(ya)), math.sin(math.rad(ya))
    local rideDir = dir * c + side * s
    local landAt = a + dir * x + side * onTop
    -- The rail table grindRun takes: a stretch starting 60 u before landAt.
    local len = l.len - (x - 60)
    if len < 120 then return nil end
    local centre = a + dir * ((x - 60) + len * 0.5)
    centre = Vector(centre.x, centre.y, l.ground)
    local g = { centre = centre, dir = dir, len = len, lateral = onTop * hand, top = l.top - l.ground,
                topZ = l.top, width = 88, yaw = yaw, tol = C.ledgeTol, what = "ledge", side = side,
                steerPreload = true }
    -- Where the run starts: back along the run line from the landing, on the floor.
    local stage = Vector(landAt.x, landAt.y, l.ground) - rideDir * runup
    g.runup = runup
    g.hand, g.key = hand, key
    g.stage = stage
    -- Come to the start along the run line, from further back on it: arriving
    -- from anywhere, the bike had to turn round right beside the kerb, and
    -- could not.
    g.prestageLen = prestage or C.grindPrestage
    g.prestage = stage - rideDir * g.prestageLen
    g.landAt = landAt
    return g, rideDir
end

-- Is the run at it clear: floor all the way, nothing in the way, and the
-- edge clear for a grind after the landing.
function M.LedgeRunClear(l, g, rideDir, C)
    C = C or M.Config
    local stage = g.stage
    local sz = M.Ground(stage.x, stage.y, l.ground + 8, l.ground - 8)
    if not sz or abs(sz - l.ground) > 3 then return false, "no floor at the start" end
    local need = (g.runup or C.grindRunup) - 120
    local run = BMX.Launch.Runway(Vector(stage.x, stage.y, sz) + UP * 4, rideDir, need, { filter = traceFilter })
    if run < need - 20 then return false, string.format("run blocked at %.0f u", run) end
    -- Room behind the start to come into it along the line.
    local pre = g.prestageLen or C.grindPrestage
    local back = BMX.Launch.Runway(Vector(stage.x, stage.y, sz) + UP * 4, -rideDir, pre + 60, { filter = traceFilter })
    if back < pre + 40 then return false, "no room behind the start" end
    return true
end

function Brain:mapRail(name)
    if name == "Crank Grind" then return self:mapPipe() end
    if name ~= "Double Peg Grind" then return nil, "nothing on this map for it" end
    local cat = self:mapCat()
    if not cat then return nil, "the map is still being looked over" end
    local C = M.Config
    local cfg = self.bike:Cfg()
    local cands = {}
    for _, l in ipairs(cat.ledges) do
        -- Each way along it, each its own spot with its own record.
        for _, rev in ipairs({ false, true }) do
            local key = M.LedgeKey(l, rev)
            local s = M.Stat(key)
            if s.missed <= s.landed + 2 then
                -- The first landing point with a clear run and a clear grind:
                -- the long shallow run where it fits; a shorter, steeper one
                -- (a short bed in a lane between ramps, come at from the open
                -- floor) where it does not. The grind takes up to 40 degrees.
                local found = false
                for _, way in ipairs(C.grindWays) do
                    for x = 80, l.len - C.grindOn, 35 do
                        local g, rideDir = M.LedgeRun(l, x, cfg, C, way[2], way[1], rev, way[3])
                        if g and clearAlong(l, x, C.grindOn, rev) >= C.grindOn * 0.9 then
                            if M.LedgeRunClear(l, g, rideDir, C) then
                                cands[#cands + 1] = { key = key, ledge = l, g = g, at = g.stage }
                                found = true
                                break
                            end
                        end
                    end
                    if found then break end
                end
            end
            tick()
        end
    end
    local it = pick(self, cands, function(c) return min(c.ledge.len, 800) * 0.2 end, function(c) return c.at end)
    if not it then return nil, (#cat.ledges > 0) and "no ledge with a clear run at it" or "no ledge on this map" end
    M.Stat(it.key).used = M.Stat(it.key).used + 1
    self.mapLedgeKey = it.key
    self.mapLedgeHand = it.g.hand
    self:say(string.format("map: a %.0f u ledge, %.0f u high, %.0f u long, ridden with the top on the %s, closing at %.0f deg",
        it.ledge.top - it.ledge.ground, it.ledge.top, it.ledge.len, it.g.hand > 0 and "left" or "right", math.abs(it.g.yaw)))
    return it.g
end

-- A pipe to crank grind, ridden straight along from either end, as a laid
-- rail is (the recipe proved on the headless suite): the run starts in line
-- behind its end, the hop lands the crank 60 u along it.
function M.PipeRun(pp, rev, C)
    C = C or M.Config
    local dir = rev and -pp.dir or pp.dir
    local a = rev and pp.b or pp.a
    local centre = (pp.a + pp.b) * 0.5
    local g = { centre = Vector(centre.x, centre.y, pp.ground), dir = dir, len = pp.len, lateral = 0,
                top = pp.top - pp.ground, topZ = pp.top, width = 4, yaw = 0, tol = 2.5, what = "pipe",
                key = pp.key .. (rev and "r" or "") }
    g.stage = Vector(a.x, a.y, pp.ground) - dir * C.grindRunup
    g.prestageLen = C.grindPrestage
    g.prestage = g.stage - dir * g.prestageLen
    return g, dir
end

function Brain:mapPipe()
    local cat = self:mapCat()
    if not cat then return nil, "the map is still being looked over" end
    local C = M.Config
    local cands = {}
    for _, pp in ipairs(cat.pipes or {}) do
        for _, rev in ipairs({ false, true }) do
            local g, dir = M.PipeRun(pp, rev, C)
            local s = M.Stat(g.key)
            if s.missed <= s.landed + 2 and M.LedgeRunClear({ ground = pp.ground }, g, dir, C) then
                cands[#cands + 1] = { key = g.key, g = g, at = g.prestage }
            end
        end
    end
    local it = pick(self, cands, function() return 0 end, function(c) return c.at end)
    if not it then return nil, (#(cat.pipes or {}) > 0) and "no clear run at the pipe" or "no pipe on this map a hop reaches" end
    M.Stat(it.key).used = M.Stat(it.key).used + 1
    self.mapLedgeKey, self.mapLedgeHand = it.key, 1
    self:say(string.format("map: a pipe %.0f u up, %.0f u long", it.g.top, it.g.len))
    return it.g
end

--------------------------------------------------------------------------
-- ROUTES CLEAR OF THE KERBS. The mesh's own path is pulled tight wherever the
-- MESH runs straight, and a mesh runs straight right along a planting bed's
-- kerb: the bike rode the line with its front wheel up on the kerb and fell
-- (twice in eight grinds on petopia_bmx_fall). Here the waypoints are put
-- back through the middles of the areas' shared edges, moved off anything
-- solid within a bike's width and a bit, and pulled tight only where a
-- bike-wide box clears the straight line too.
--------------------------------------------------------------------------
M.PathClear = 28      -- u kept between a waypoint and anything solid
local HULL_MIN, HULL_MAX = Vector(-14, -14, 0), Vector(14, 14, 24)

function M.Clear(a, b)
    local tr = util.TraceHull({ start = a + UP * 6, endpos = b + UP * 6, mins = HULL_MIN, maxs = HULL_MAX,
                                mask = MASK_SOLID, filter = traceFilter })
    return not tr.Hit and not tr.StartSolid
end

-- `p` moved away from anything solid closer than M.PathClear, at kerb height.
function M.Unhug(p)
    local push = Vector(0, 0, 0)
    for _, d in ipairs({ Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0) }) do
        local tr = util.TraceLine({ start = p + UP * 8, endpos = p + UP * 8 + d * M.PathClear,
                                    mask = MASK_SOLID, filter = traceFilter })
        if tr.Hit and not tr.StartSolid then push = push - d * (M.PathClear - tr.Fraction * M.PathClear) end
    end
    return p + push
end

Bot.SegmentClear = function(a, b) return M.Clear(a, b) end

function Bot.PathFor(from, to, opts)
    local Nav = BMX.Nav
    local pts, areas = Nav.Path(from, to, opts)
    if not pts or type(areas) ~= "table" or #areas < 2 then return pts, areas end
    local raw = { from }
    for i = 2, #areas do
        local p = areas[i - 1]:GetClosestPointOnArea(raw[#raw])
        local q = areas[i]:GetClosestPointOnArea(p)
        raw[#raw + 1] = M.Unhug((p + q) * 0.5)
    end
    raw[#raw + 1] = to
    local out, i = { from }, 1
    while i < #raw do
        local j = #raw
        while j > i + 1 and not (Nav.Straight(raw[i], raw[j], { stepUp = 8 }) and M.Clear(raw[i], raw[j])) do
            j = j - 1
        end
        out[#out + 1] = raw[j]
        i = j
    end
    return out, areas
end

--------------------------------------------------------------------------
-- THE POSES, off the same air: each is held through the middle of the
-- flight and let go before the wheels touch (Brain:airPose, sv_bot.lua).
--------------------------------------------------------------------------
Bot.PoseTricks = { "No-Hander", "Can-Can", "X-Up", "Tabletop", "Turndown" }
local POSE = { ["No-Hander"] = "nohander", ["Can-Can"] = "cancan_r", ["X-Up"] = "xup",
               ["Tabletop"] = "tabletop", ["Turndown"] = "turndown" }
Bot.PoseOf = POSE
if Bot.PartTrick then
    for name, pose in pairs(POSE) do
        Bot.PartTrick(name, function(b, t0) return b:airPose(name, pose, t0) end)
    end
end

--------------------------------------------------------------------------
-- THE SHOW this map can host. With bmx_bot_props 1 it is the whole list, as
-- before (anything missing is put down). Without, a trick is in it only if
-- the map has something for it.
--------------------------------------------------------------------------
local AIR_NEED = function(name, cfg)
    if Bot.AirTricks[name] then return Bot.AirNeed(name, cfg) end
    if Bot.PartAir and Bot.PartAir[name] then return Bot.PartAir[name] end
    if POSE[name] or name == "Superman" then return Bot.PoseAir end
end
M.AirNeedOf = AIR_NEED

-- The most air anything on this map has given or should give.
function M.BestAir(cat)
    local best = 0
    for _, f in ipairs(cat.faces) do best = max(best, M.FaceAir(f)) end
    local Nav = BMX.Nav
    local nc = Nav and Nav.catalog
    for _, l in ipairs(nc and nc.launches or {}) do
        if M.OnFallLine(l) and (l.airTime or 0) > 0 then best = max(best, min(l.airTime, 1.0)) end
    end
    return best
end

function M.CanHost(name, cat, cfg)
    local need = AIR_NEED(name, cfg)
    if need then return M.BestAir(cat) >= need end
    if name == "Double Peg Grind" then return #cat.ledges > 0 end
    if name == "Crank Grind" then return #(cat.pipes or {}) > 0 end
    return true
end

local origList = Bot.TrickListFor or function() return Bot.TrickList end
Bot.mapOrigList = Bot.mapOrigList or origList
function Bot.TrickListFor(bike)
    local list = Bot.mapOrigList(bike)
    if list ~= Bot.TrickList then return list end           -- a board runs its own
    local full = {}
    for _, n in ipairs(list) do full[#full + 1] = n end
    for _, n in ipairs(Bot.PoseTricks) do full[#full + 1] = n end
    if Bot.PropsAllowed() then return full end
    local cat = M.cat and M.cat.map == game.GetMap() and M.cat or nil
    if not cat then M.Get() return full end                  -- not looked yet: everything, once
    local cfg = IsValid(bike) and bike.Cfg and bike:Cfg() or BMX.Config
    local out = {}
    for _, n in ipairs(full) do if M.CanHost(n, cat, cfg) then out[#out + 1] = n end end
    return #out > 0 and out or list
end

-- The show waits for the look round the map (a few seconds, once per map)
-- rather than starting with the whole list, flips and all, and missing them.
Brain.mapOrigNext = Brain.mapOrigNext or Brain.nextInShow
function Brain:nextInShow()
    if not Bot.PropsAllowed() and not M.Get() and (not self.queue or #self.queue == 0) then
        self:set({})
        return
    end
    return Brain.mapOrigNext(self)
end

--------------------------------------------------------------------------
-- Console
--------------------------------------------------------------------------
local function reply(ply, msg)
    if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, msg) else print(msg) end
end

concommand.Add("bmx_bot_map", function(ply)
    local cat = M.Get()
    if not cat then reply(ply, "[BMX] bot map: still looking the map over") return end
    reply(ply, string.format("[BMX] bot map %s: %d ramp faces, %d ledges, %d pipes%s", cat.map, #cat.faces, #cat.ledges, #(cat.pipes or {}),
        cat.why.nomesh and " (no navmesh: bmx_nav_build makes one)" or ""))
    for _, f in ipairs(cat.faces) do
        local s = M.Stat(f.key)
        reply(ply, string.format("  face  lip (%.0f %.0f %.0f) heading %.0f, %.0f u high, %.0f deg, deck %.0f, air %.2f s, %d/%d landed",
            f.lip.x, f.lip.y, f.lip.z, math.deg(math.atan2(f.dir.y, f.dir.x)), f.height, math.deg(f.angle), f.deck,
            M.FaceAir(f), s.landed, s.landed + s.missed))
    end
    for _, l in ipairs(cat.ledges) do
        local s, r = M.Stat(l.key), M.Stat(M.LedgeKey(l, true))
        reply(ply, string.format("  ledge (%.0f %.0f) to (%.0f %.0f), %.0f u high, %.0f long, %d/%d landed one way, %d/%d the other",
            l.a.x, l.a.y, l.b.x, l.b.y, l.top - l.ground, l.len, s.landed, s.landed + s.missed, r.landed, r.landed + r.missed))
    end
    for _, pp in ipairs(cat.pipes or {}) do
        local s, r = M.Stat(pp.key), M.Stat(pp.key .. "r")
        reply(ply, string.format("  pipe  (%.0f %.0f) to (%.0f %.0f), %.0f u high, %.0f long, %d/%d landed one way, %d/%d the other",
            pp.a.x, pp.a.y, pp.b.x, pp.b.y, pp.top - pp.ground, pp.len, s.landed, s.landed + s.missed, r.landed, r.landed + r.missed))
    end
    local show = Bot.TrickListFor(nil)
    reply(ply, "  the show here: " .. table.concat(show, ", "))
end)

concommand.Add("bmx_bot_map_rescan", function(ply)
    if IsValid(ply) and not BMX.Can(ply, "BMX - Bot") then return end
    M.cat, M.job = nil, nil
    M.Get()
    reply(ply, "[BMX] bot map: looking again")
end)
