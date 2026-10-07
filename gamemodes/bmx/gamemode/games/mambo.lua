--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/games/mambo.lua

    COMBO MAMBO: one minute, and only your single biggest banked combo counts.
    A player who lands thirty small tricks loses to one who chains three big
    ones, which is the point: it is the opposite of Trick Attack.
----------------------------------------------------------------------------]]

BMX.Games.Timed("mambo", {
    name = "Combo Mambo", min = 1, max = 8, lateJoin = true, seconds = 60,
    blurb = "Best single combo wins.",
    onCombo = function(best, chain, total) return math.max(best, total) end,
})
