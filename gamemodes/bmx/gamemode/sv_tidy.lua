--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/sv_tidy.lua

    LEFT ALONE, IT GOES. Anything a player spawned -- a prop, a Q-menu entity,
    a park piece, a bike, a rental, a toolgun contraption -- is removed once
    nobody has touched it for bmx_idle_cleanup seconds (120 by default; 0 is
    off). A public park fills up with abandoned bikes and half-built ramps
    otherwise, and the next player rides into somebody else's mess.

    TOUCHED means any of:
      - ridden or driven (a bike, a car, a seat)
      - held: in a physgun or gravity gun, or a weapon in someone's hands
      - used (E), punted, or aimed at with the toolgun
      - moved (pushed, knocked, rolling, part of a working contraption)
      - in contact with a player: one standing on it, leaning on it, or riding
        over it (a player inside its bounds plus a hand's width)
    Things welded or otherwise constrained together count as one: riding one
    piece of a welded park keeps the whole park.

    WHAT IS TRACKED is what a player spawned: the sandbox spawn hooks
    (PlayerSpawnedProp, ...SENT, ...Vehicle, ...NPC, ...Ragdoll, ...Effect,
    ...SWEP) and anything handed to cleanup.Add (the toolgun, bmx_spawn, the
    rental machine). Map entities are never tracked, and neither are
    constraints themselves or parented parts (they go with what they hang on).
----------------------------------------------------------------------------]]

BMXMode = BMXMode or {}
BMXMode.Tidy = BMXMode.Tidy or {}
local T = BMXMode.Tidy

T.SWEEP = 5     -- s: how often the sweep runs
T.REACH = 16    -- u: how close to something counts as touching it

local idle = CreateConVar("bmx_idle_cleanup", "120", bit.bor(FCVAR_ARCHIVE, FCVAR_NOTIFY, FCVAR_REPLICATED),
    "BMX (Mode): remove anything a player spawned once nobody has touched it for this many seconds (0 = never).")

T.Tracked = T.Tracked or {}     -- ent -> { owner, last, pos }
T.Held = T.Held or {}           -- ent -> true while in a physgun or gravity gun

-- Constraints are entities too, but they are part of what they join.
local function isConstraint(ent)
    if ent.IsConstraint and ent:IsConstraint() then return true end
    local c = ent:GetClass() or ""
    return c:find("^phys_") ~= nil or c:find("rope") ~= nil or c == "logic_collision_pair"
end

function T.Track(ent, ply)
    if not IsValid(ent) or ent:IsPlayer() or T.Tracked[ent] then return end
    if isConstraint(ent) or IsValid(ent:GetParent()) then return end
    T.Tracked[ent] = { owner = ply, last = CurTime(), pos = ent:GetPos() }
end

function T.Touch(ent)
    local t = IsValid(ent) and T.Tracked[ent]
    if t then t.last = CurTime() end
    -- a seat is touched through what it is parented to (a bike's pod)
    if IsValid(ent) and IsValid(ent:GetParent()) then T.Touch(ent:GetParent()) end
end

-- Ridden, held, or in someone's hands right now.
function T.InUse(ent)
    if T.Held[ent] then return true end
    if ent.GetDriver and IsValid(ent:GetDriver()) then return true end
    if ent.IsWeapon and ent:IsWeapon() and IsValid(ent:GetOwner()) then return true end
    return false
end

-- Is a player in contact with it: inside its world box, give or take a hand?
local function near(ent, bodies)
    if #bodies == 0 then return false end
    local mn, mx = ent:WorldSpaceAABB()
    local r = T.REACH
    for _, p in ipairs(bodies) do
        if p.x >= mn.x - r and p.x <= mx.x + r and p.y >= mn.y - r and p.y <= mx.y + r
            and p.z >= mn.z - r and p.z <= mx.z + r then return true end
    end
    return false
end

-- Everything constrained to `ent` (itself included), where the engine can say.
local function group(ent)
    if constraint.GetAllConstrainedEntities then
        local all = constraint.GetAllConstrainedEntities(ent)
        if all and next(all) then return all end
    end
    return { [ent] = ent }
end

function T.Sweep()
    local limit = idle:GetFloat()
    local now = CurTime()

    local bodies = {}
    for _, p in ipairs(player.GetAll()) do
        if p:Alive() then bodies[#bodies + 1] = p:GetPos() end
    end

    for ent, t in pairs(T.Tracked) do
        if not IsValid(ent) then
            T.Tracked[ent] = nil
        else
            local pos = ent:GetPos()
            if T.InUse(ent) or pos:DistToSqr(t.pos) > 4 or near(ent, bodies) then t.last = now end
            t.pos = pos
        end
    end
    if limit <= 0 then return 0 end

    -- A constrained group lives as long as its most recently touched member.
    local gone, told = {}, {}
    for ent, t in pairs(T.Tracked) do
        local last = t.last
        for _, other in pairs(group(ent)) do
            local o = T.Tracked[other]
            if o and o.last > last then last = o.last end
        end
        if now - last >= limit then gone[#gone + 1] = ent end
    end
    for _, ent in ipairs(gone) do
        local t = T.Tracked[ent]
        T.Tracked[ent] = nil
        T.Held[ent] = nil
        if IsValid(t.owner) and t.owner:IsPlayer() then told[t.owner] = (told[t.owner] or 0) + 1 end
        SafeRemoveEntity(ent)
    end
    for ply, n in pairs(told) do
        ply:ChatPrint(string.format("[BMX] cleared %d thing%s you spawned: nobody touched %s for %d seconds.",
            n, n == 1 and "" or "s", n == 1 and "it" or "them", math.floor(limit)))
    end
    return #gone
end
timer.Create("BMXMode.Tidy", T.SWEEP, 0, T.Sweep)

--------------------------------------------------------------------------
-- What gets tracked: every way sandbox lets a player spawn something, and
-- cleanup.Add (the toolgun's contraptions, bmx_spawn, the rental machine).
--------------------------------------------------------------------------
hook.Add("PlayerSpawnedProp",    "BMXMode.Tidy", function(ply, _, ent) T.Track(ent, ply) end)
hook.Add("PlayerSpawnedRagdoll", "BMXMode.Tidy", function(ply, _, ent) T.Track(ent, ply) end)
hook.Add("PlayerSpawnedEffect",  "BMXMode.Tidy", function(ply, _, ent) T.Track(ent, ply) end)
hook.Add("PlayerSpawnedSENT",    "BMXMode.Tidy", function(ply, ent) T.Track(ent, ply) end)
hook.Add("PlayerSpawnedVehicle", "BMXMode.Tidy", function(ply, ent) T.Track(ent, ply) end)
hook.Add("PlayerSpawnedNPC",     "BMXMode.Tidy", function(ply, ent) T.Track(ent, ply) end)
hook.Add("PlayerSpawnedSWEP",    "BMXMode.Tidy", function(ply, ent) T.Track(ent, ply) end)

if cleanup and not T.cleanupWrapped then
    T.cleanupWrapped = true
    local add = cleanup.Add
    cleanup.Add = function(ply, kind, ent, ...)
        T.Track(ent, ply)
        return add(ply, kind, ent, ...)
    end
end

--------------------------------------------------------------------------
-- Touches the sweep cannot see from where things are.
--------------------------------------------------------------------------
hook.Add("PlayerUse", "BMXMode.Tidy", function(_, ent) T.Touch(ent) end)
hook.Add("PlayerEnteredVehicle", "BMXMode.Tidy", function(_, veh) T.Touch(veh) end)
hook.Add("PlayerLeaveVehicle", "BMXMode.Tidy", function(_, veh) T.Touch(veh) end)
hook.Add("OnPhysgunPickup", "BMXMode.Tidy", function(_, ent) T.Held[ent] = true T.Touch(ent) end)
hook.Add("PhysgunDrop", "BMXMode.Tidy", function(_, ent) T.Held[ent] = nil T.Touch(ent) end)
hook.Add("GravGunOnPickedUp", "BMXMode.Tidy", function(_, ent) T.Held[ent] = true T.Touch(ent) end)
hook.Add("GravGunOnDropped", "BMXMode.Tidy", function(_, ent) T.Held[ent] = nil T.Touch(ent) end)
hook.Add("GravGunPunt", "BMXMode.Tidy", function(_, ent) T.Touch(ent) end)
hook.Add("CanTool", "BMXMode.Tidy", function(_, tr) if tr then T.Touch(tr.Entity) end end)
