-- battle_lobby/state.lua

local bl = battle_lobby

--------------------------------------------------
-- BATTLE STATE
--------------------------------------------------

bl.battle = bl.battle or {
    state      = "idle",      -- "idle","countdown","running","post"
    arena_id   = nil,
    countdown  = 0,
    queue      = {},          -- waiting players
    players    = {},          -- players in current match
    alive      = {},          -- players still alive
}
battle = bl.battle  -- global alias

function bl.is_battle_player(name)
    return battle.players[name] == true
end
is_battle_player = bl.is_battle_player  -- global alias

--------------------------------------------------
-- TUMBLE STATE (minimal stub, expandable)
--------------------------------------------------

bl.tumble = bl.tumble or {
    state      = "idle",
    arena_id   = nil,
    countdown  = 0,
    queue      = {},
    players    = {},
    alive      = {},
}
tumble = bl.tumble  -- global alias
