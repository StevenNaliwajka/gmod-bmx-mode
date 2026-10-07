--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/cl_botavatar.lua

    The bot rider's picture (bmx_bot_avatar, sv_botavatar.lua): drawn over the
    "?" every AvatarImage shows for a bot -- the sandbox scoreboard, TTT's,
    anyone's, since they all make one with vgui.Create("AvatarImage") -- and on
    a card in the corner when the bot joins.

    A URL is fetched once and kept in data/bmx/ (the name is the URL's CRC, so
    a new picture is a new file); a material path is used as it is.
----------------------------------------------------------------------------]]

BMX = BMX or {}
BMX.BotAvatar = BMX.BotAvatar or {}
local A = BMX.BotAvatar

-- The server's bmx_bot_avatar, as a networked global (a replicated convar
-- cannot be created on the client).
local function source() return GetGlobalString and GetGlobalString("BMXBotAvatar", "") or "" end

A.mat, A.src, A.loading = A.mat, A.src, false

local function isBotRider(ply)
    return IsValid(ply) and ply:IsPlayer() and ply:IsBot() and ply:GetNWBool("BMXBot", false)
end
A.IsBotRider = isBotRider

-- The picture, loading it when the convar has changed. `cb(mat)` when ready.
function A.Get(cb)
    local src = source()
    if src == "" then A.mat, A.src = nil, "" if cb then cb(nil) end return nil end
    if A.src == src and A.mat then if cb then cb(A.mat) end return A.mat end
    if A.src ~= src then A.mat, A.src = nil, src end
    if not src:match("^https?://") then
        A.mat = Material(src, "smooth mips")
        if A.mat:IsError() then A.mat = nil end
        if cb then cb(A.mat) end
        return A.mat
    end
    local ext = src:lower():match("%.jpe?g$") and ".jpg" or ".png"
    local name = "bmx/bot_avatar_" .. util.CRC(src) .. ext
    if file.Exists(name, "DATA") then
        A.mat = Material("../data/" .. name, "smooth mips")
        if cb then cb(A.mat) end
        return A.mat
    end
    A.waiting = A.waiting or {}
    if cb then A.waiting[#A.waiting + 1] = cb end
    if A.loading then return nil end
    A.loading = true
    http.Fetch(src, function(body, _, _, code)
        A.loading = false
        if code == 200 and body and #body > 0 then
            file.CreateDir("bmx")
            file.Write(name, body)
            if A.src == src then A.mat = Material("../data/" .. name, "smooth mips") end
        end
        local w = A.waiting
        A.waiting = {}
        for _, f in ipairs(w) do f(A.mat) end
    end, function()
        A.loading = false
        local w = A.waiting
        A.waiting = {}
        for _, f in ipairs(w) do f(nil) end
    end)
    return nil
end

--------------------------------------------------------------------------
-- Every AvatarImage: remember whose it is, and paint the picture over a bot's.
--------------------------------------------------------------------------
local function adopt(p)
    if p.BMXAvatar then return end
    p.BMXAvatar = true
    local setPlayer = p.SetPlayer
    p.SetPlayer = function(self, ply, size, ...)
        self.BMXPly = ply
        if isBotRider(ply) then A.Get() end
        return setPlayer(self, ply, size, ...)
    end
    local over = p.PaintOver
    p.PaintOver = function(self, w, h)
        if over then over(self, w, h) end
        local ply = self.BMXPly
        if A.mat and isBotRider(ply) then
            surface.SetDrawColor(255, 255, 255, 255)
            surface.SetMaterial(A.mat)
            surface.DrawTexturedRect(0, 0, w, h)
        end
    end
end
A.Adopt = adopt

if vgui and vgui.Create then
    A.create = A.create or vgui.Create
    function vgui.Create(class, parent, name, ...)
        local p = A.create(class, parent, name, ...)
        if class == "AvatarImage" and IsValid(p) then adopt(p) end
        return p
    end
end

--------------------------------------------------------------------------
-- The join card.
--------------------------------------------------------------------------
if surface and surface.CreateFont then
surface.CreateFont("BMXBotCardName", { font = "Roboto", size = 22, weight = 800 })
surface.CreateFont("BMXBotCardLine", { font = "Roboto", size = 16, weight = 500 })
end

function A.Card(ply, nick)
    if IsValid(A.card) then A.card:Remove() end
    local W, H, pad = 320, 88, 12
    local card = vgui.Create("DPanel")
    A.card = card
    card:SetSize(W, H)
    card:SetPos(ScrW() - W - 16, -H)
    card:MoveTo(ScrW() - W - 16, 96, 0.35, 0, 0.3)
    card.born = RealTime()
    card:SetMouseInputEnabled(false)
    card:SetKeyboardInputEnabled(false)
    function card:Paint(w, h)
        draw.RoundedBox(10, 0, 0, w, h, Color(20, 24, 32, 235))
        draw.RoundedBox(10, 0, 0, 6, h, Color(80, 200, 120))
        local s = h - pad * 2
        if A.mat then
            surface.SetDrawColor(255, 255, 255)
            surface.SetMaterial(A.mat)
            surface.DrawTexturedRect(pad + 4, pad, s, s)
        else
            draw.RoundedBox(6, pad + 4, pad, s, s, Color(60, 66, 80))
        end
        draw.SimpleText(nick, "BMXBotCardName", pad + 4 + s + 12, h * 0.5 - 2, color_white, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM)
        draw.SimpleText("rolled into the park on a BMX", "BMXBotCardLine", pad + 4 + s + 12, h * 0.5 + 4,
            Color(190, 200, 210), TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    end
    function card:Think()
        local age = RealTime() - self.born
        if age > 7 and not self.leaving then
            self.leaving = true
            self:AlphaTo(0, 0.5, 0, function() if IsValid(self) then self:Remove() end end)
        end
    end
end

net.Receive("bmx_bot_joined", function()
    local ply = net.ReadEntity()
    local nick = net.ReadString()
    chat.AddText(Color(80, 200, 120), nick, Color(230, 230, 230), " rolled into the park on a BMX.")
    A.Get(function() A.Card(ply, nick) end)
end)
