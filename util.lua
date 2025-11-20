-- battle_lobby/util.lua

local bl = battle_lobby or {}
battle_lobby = bl  -- ensure it's set

--------------------------------------------------
-- BASIC HELPERS
--------------------------------------------------

-- Core chat helpers
function bl.msg(name, text)
    if not name or not text then return end
    minetest.chat_send_player(name,
        minetest.colorize("#00ffcc", "[Battle] ") .. text
    )
end

function bl.broadcast(text)
    if not text then return end
    minetest.chat_send_all(
        minetest.colorize("#00ffcc", "[Battle] ") .. text
    )
end

-- GLOBAL aliases for old code / other files
msg        = bl.msg
broadcast  = bl.broadcast

-- Simple table copy helper
function bl.table_copy(t)
    local nt = {}
    for k,v in pairs(t or {}) do
        nt[k] = v
    end
    return nt
end

--------------------------------------------------
-- ARENA / CONFIG HELPERS
--------------------------------------------------

bl.config = bl.config or {}
config = bl.config  -- global alias

config.arenas = config.arenas or {}

function bl.get_or_create_arena(aid)
    if not config.arenas[aid] then
        config.arenas[aid] = {
            id = aid,
            label = aid,
            enabled = true,
            spawn_points       = {},
            tumble_spawn_points = {},
            center = nil,
            radius = 32,
        }
    end
    return config.arenas[aid]
end

--------------------------------------------------
-- TELEPORT HELPER
--------------------------------------------------

function bl.teleport_player(name, pos)
    local player = minetest.get_player_by_name(name)
    if player and pos then
        player:set_pos(vector.new(pos))
    end
end

teleport_player = bl.teleport_player  -- global alias

--------------------------------------------------
-- POSITION MARKERS (pos1 / pos2)
--------------------------------------------------

bl.battle_pos_marks = bl.battle_pos_marks or {}
battle_pos_marks = bl.battle_pos_marks  -- global alias

minetest.register_chatcommand("battle_pos1", {
    privs = {server = true},
    description = "Set Battle/Tumble region pos1 at your position.",
    func = function(name)
        local p = minetest.get_player_by_name(name)
        if not p then return end
        local pos = vector.round(p:get_pos())
        battle_pos_marks[name] = battle_pos_marks[name] or {}
        battle_pos_marks[name].pos1 = pos
        msg(name, "pos1 set to " .. minetest.pos_to_string(pos))
    end,
})

minetest.register_chatcommand("battle_pos2", {
    privs = {server = true},
    description = "Set Battle/Tumble region pos2 at your position.",
    func = function(name)
        local p = minetest.get_player_by_name(name)
        if not p then return end
        local pos = vector.round(p:get_pos())
        battle_pos_marks[name] = battle_pos_marks[name] or {}
        battle_pos_marks[name].pos2 = pos
        msg(name, "pos2 set to " .. minetest.pos_to_string(pos))
    end,
})

--------------------------------------------------
-- ADMIN CHECK
--------------------------------------------------

function bl.is_admin(name)
    local privs = minetest.get_player_privs(name or "")
    return privs.server or privs.privs or privs.teleport
end
