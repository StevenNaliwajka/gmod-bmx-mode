include("shared.lua")

local COL_BG   = Color(14, 16, 20, 245)
local COL_FG   = Color(232, 236, 242)
local COL_DIM  = Color(150, 158, 170)
local COL_GOLD = Color(255, 214, 90)

surface.CreateFont("BMX.Sign.Title", { font = "Roboto", size = 64, weight = 800 })
surface.CreateFont("BMX.Sign.Row",   { font = "Roboto", size = 40, weight = 600 })

-- Ask for the table while somebody is close enough to read it, and only then.
-- The server answers each player once a second at most (sv_scores.lua), so a
-- sign that asks on every frame would just be ignored; this asks every 20 s.
function ENT:Think()
    if not BMX.Scores or not BMX.Scores.Request then return end
    local lp = LocalPlayer()
    if not IsValid(lp) or lp:GetPos():DistToSqr(self:GetPos()) > self.ReadRange ^ 2 then return end
    local c = BMX.ScoresCache and BMX.ScoresCache()
    if c and c.bike == self:GetBike() and CurTime() - c.at < 20 then return end
    BMX.Scores.Request(self:GetBike())
end

function ENT:CurrentStat()
    local s = self:GetStat()
    if s ~= "" then return s end
    local list = BMX.Scores.Stats
    return list[math.floor(CurTime() / self.CycleSeconds) % #list + 1]
end

function ENT:Draw()
    self:DrawModel()
    local lp = LocalPlayer()
    if not IsValid(lp) or lp:GetPos():DistToSqr(self:GetPos()) > self.ReadRange ^ 2 then return end

    -- The board's face: the plate stands on its edge (pitch 90), so its
    -- former top is the face the sign is drawn on. 0.1 u/px and a 600 x 400
    -- canvas fits the plate2x3.
    local mins, maxs = self:OBBMins(), self:OBBMaxs()
    local pos = self:LocalToWorld(Vector(0, 0, maxs.z + 0.2))
    local ang = self:LocalToWorldAngles(Angle(0, 90, 0))
    local S = BMX.Scores
    local stat = self:CurrentStat()

    cam.Start3D2D(pos, ang, 0.1)
        local w, h = 720, 480
        draw.RoundedBox(12, -w / 2, -h / 2, w, h, COL_BG)
        draw.SimpleText(S.Labels[stat] or "Scores", "BMX.Sign.Title", 0, -h / 2 + 16,
            COL_GOLD, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)

        local c = BMX.ScoresCache and BMX.ScoresCache()
        local top = c and c.stats[stat] and c.stats[stat].top or {}
        if #top == 0 then
            draw.SimpleText("nobody yet", "BMX.Sign.Row", 0, 0, COL_DIM,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
        for i, e in ipairs(top) do
            local y = -h / 2 + 96 + (i - 1) * 36
            local col = e.mine and COL_GOLD or COL_FG
            draw.SimpleText(i .. ".", "BMX.Sign.Row", -w / 2 + 24, y, COL_DIM, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            draw.SimpleText(e.name, "BMX.Sign.Row", -w / 2 + 90, y, col, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
            draw.SimpleText(S.Format(stat, e.v), "BMX.Sign.Row", w / 2 - 24, y, col,
                TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
        end
    cam.End3D2D()
end
