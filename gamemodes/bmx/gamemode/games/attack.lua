--[[--------------------------------------------------------------------------
    gamemodes/bmx/gamemode/games/attack.lua

    TRICK ATTACK, the Tony Hawk two-minute run: everyone scores for the same
    2:00 and the biggest total wins. A player's total is every trick they land
    PLUS the bonus on every combo they bank, i.e. what the in-game score would
    have gone up by. (Not the BMX_ComboBanked `total`: that includes the
    chain's own points, which the tricks have already paid.)
----------------------------------------------------------------------------]]

BMX.Games.Timed("attack", {
    name = "Trick Attack", min = 1, max = 8, lateJoin = true, seconds = 120,
    blurb = "Biggest total wins.",
    onTrick = function(total, points) return total + points end,
    onCombo = function(total, chain) return total + (chain.bonus or 0) end,
})
