AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

function ENT:Initialize()
    self:SetModel(self.Model)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_VPHYSICS)
    self:SetSolid(SOLID_VPHYSICS)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end   -- a sign stays where it is put
end

-- Stood on its edge, facing the player who placed it.
function ENT:SpawnFunction(ply, tr, class)
    if not tr.Hit then return end
    local ent = ents.Create(class)
    if not IsValid(ent) then return end
    local yaw = IsValid(ply) and (ply:EyeAngles().y + 180) or 0
    ent:SetPos(tr.HitPos + tr.HitNormal * 60)
    ent:SetAngles(Angle(90, yaw, 0))
    ent:Spawn()
    ent:Activate()
    return ent
end

-- Chosen from the console by an admin: bmx_leaderboard_set <stat|all> [bike]
-- on the sign they are looking at.
concommand.Add("bmx_leaderboard_set", function(ply, _, args)
    if not IsValid(ply) or not ply:IsAdmin() then return end
    local e = ply:GetEyeTrace().Entity
    if not IsValid(e) or e:GetClass() ~= "bmx_leaderboard" then
        ply:ChatPrint("[BMX] look at a leaderboard sign first")
        return
    end
    local stat = args[1] or "all"
    local ok = stat == "all"
    for _, s in ipairs(BMX.Scores.Stats) do if s == stat then ok = true end end
    if not ok then
        ply:ChatPrint("[BMX] stat: all, " .. table.concat(BMX.Scores.Stats, ", "))
        return
    end
    e:SetStat(stat == "all" and "" or stat)
    local bike = args[2] or ""
    e:SetBike(BMX.Bikes[bike] and bike or "")
end)
