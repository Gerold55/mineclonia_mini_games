-- battle_lobby/battle_core.lua

-- battle_lobby/battle_core.lua

local bl = battle_lobby
local battle = bl.battle

-- Safety fallback for msg()
local msg = msg or bl.msg or function(name, text)
    if name and text then
        minetest.chat_send_player(name, text)
    end
end

--------------------------------------------------
-- QUEUE HELPERS
--------------------------------------------------

local function add_to_queue(name)
    for _,n in ipairs(battle.queue) do
        if n == name then return end
    end
    table.insert(battle.queue, name)
end

local function remove_from_queue(name)
    for i,n in ipairs(battle.queue) do
        if n == name then
            table.remove(battle.queue, i)
            return
        end
    end
end

--------------------------------------------------
-- SPAWNPOINT SETUP
--------------------------------------------------

minetest.register_chatcommand("battle_set_spawn", {
    privs = {server = true},
    params = "<arena_id> <slot 1-8>",
    description = "Set Battle spawnpoint for a given arena/slot at your position.",
    func = function(name, param)
        local aid, slot_str = param:match("^(%S+)%s+(%d+)$")
        if not aid or not slot_str then
            msg(name, "Usage: /battle_set_spawn <arena_id> <slot 1-8>")
            return
        end
        local slot = tonumber(slot_str)
        if not slot or slot < 1 or slot > 8 then
            msg(name, "Slot must be between 1 and 8.")
            return
        end
        local player = minetest.get_player_by_name(name)
        if not player then return end
        local pos = vector.round(player:get_pos())

        local arena = bl.get_or_create_arena(aid)
        arena.spawn_points = arena.spawn_points or {}
        arena.spawn_points[slot] = pos
        msg(name, ("Battle spawn slot %d set for arena '%s' at %s."):format(
            slot, aid, minetest.pos_to_string(pos)))
    end,
})

--------------------------------------------------
-- JOIN / LEAVE COMMANDS
--------------------------------------------------

minetest.register_chatcommand("battle_join", {
    description = "Join Battle queue.",
    func = function(name)
        add_to_queue(name)
        msg(name, "You joined the Battle queue.")
        bl.broadcast(name .. " joined Battle (" .. #battle.queue .. " in queue).")
    end,
})

minetest.register_chatcommand("battle_leave", {
    description = "Leave Battle queue or match.",
    func = function(name)
        remove_from_queue(name)
        if battle.players[name] then
            battle.players[name] = nil
            battle.alive[name] = nil
            msg(name, "You left the Battle match.")
        else
            msg(name, "You left the Battle queue.")
        end
    end,
})

--------------------------------------------------
-- STARTING A MATCH
--------------------------------------------------

local function pick_arena_for_battle()
    -- Very simple: first enabled arena
    for aid, a in pairs(config.arenas) do
        if a.enabled ~= false then return aid, a end
    end
    return nil, nil
end

local function start_match()
    local aid, arena = pick_arena_for_battle()
    if not aid or not arena then
        bl.broadcast("No Battle arena configured.")
        battle.state = "idle"
        battle.queue = {}
        return
    end

    battle.arena_id = aid
    battle.state = "running"
    battle.players = {}
    battle.alive = {}

    local spawns = arena.spawn_points or {}
    local max_slots = #spawns
    if max_slots == 0 then
        bl.broadcast("Arena '" .. aid .. "' has no spawn points set.")
        battle.state = "idle"
        battle.queue = {}
        return
    end

    bl.broadcast("Starting Battle on " .. (arena.label or aid) ..
        " with " .. math.min(#battle.queue, max_slots) .. " players.")

    for i, name in ipairs(battle.queue) do
        if i > max_slots then
            msg(name, "Battle arena full, you'll be in the next round.")
        else
            local pos = spawns[i]
            if pos then
                bl.teleport_player(name, pos)
                battle.players[name] = true
                battle.alive[name] = true
            else
                msg(name, "No spawn slot " .. i .. " for arena " .. aid)
            end
        end
    end

    battle.queue = {}
end

minetest.register_chatcommand("battle_start", {
    privs = {server = true},
    description = "Force start Battle match immediately.",
    func = function(name)
        start_match()
    end,
})

--------------------------------------------------
-- BASIC GAME LOOP (BOUNDARY CHECKS ETC.)
--------------------------------------------------

local timer_accum = 0

minetest.register_globalstep(function(dtime)
    timer_accum = timer_accum + dtime
    if timer_accum < 1 then return end
    timer_accum = 0

    if battle.state == "running" and battle.arena_id then
        local arena = config.arenas[battle.arena_id]
        if arena and arena.center and arena.radius then
            for pname,_ in pairs(battle.alive) do
                local p = minetest.get_player_by_name(pname)
                if p then
                    local pos = p:get_pos()
                    local dx = pos.x - arena.center.x
                    local dz = pos.z - arena.center.z
                    if dx*dx + dz*dz > arena.radius*arena.radius then
                        msg(pname, "You reached the edge of the arena!")
                        bl.teleport_player(pname, arena.center)
                    end
                end
            end
        end
    end
end)

--------------------------------------------------
-- SIMPLE DEATH HANDLER (MARK AS DEAD IN BATTLE)
--------------------------------------------------

minetest.register_on_dieplayer(function(player)
    local name = player:get_player_name()
    if name and battle.players[name] and battle.alive[name] then
        battle.alive[name] = false
        bl.broadcast(name .. " has been eliminated from Battle.")
    end
end)
