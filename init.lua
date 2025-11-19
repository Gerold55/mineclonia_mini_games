-- battle_lobby/init.lua
-- Mineclonia Battle + Tumble minigame pack for servers.

local storage   = minetest.get_mod_storage()
local worldpath = minetest.get_worldpath()
local VoxelArea = VoxelArea

------------------------------------------------------------
-- GLOBAL STATE
------------------------------------------------------------

local battle = {}
local tumble = {
    state     = "idle",   -- "idle", "countdown", "running"
    countdown = 0,
    queue     = {},
    players   = {},
    alive     = {},
    arena_id  = nil,
}

-- per-player slot mapping (for pills) – only used for Battle
local battle_slot_for_player = {}  -- [player_name] = slot (1..8)
local battle_player_for_slot = {}  -- [slot] = player_name

-- revive HUD (viewer -> bar ids)
local battle_revive_hud = {}       -- [viewer_name] = { bg = {[slot]=id}, fg = {[slot]=id}, slots = {slot,...} }

-- armor HUD (per player, during Battle)
local battle_armor_hud = {}        -- [player_name] = { head=id, chest=id, legs=id, feet=id }

-- legacy atmo tracker
local LEGACY_ATMOS_ENABLED = true
local legacy_atmos_players = {}

-- region marks for snapshots (map reset)
local battle_pos_marks = {}        -- [player_name] = { pos1, pos2 }

-- Stores original groups for nodes we override for Tumble
local tumble_original_groups = {}

------------------------------------------------------------
-- CONFIG (PERSISTENT)
------------------------------------------------------------

local config = {
    lobby_spawn = { x = 0, y = 10, z = 0 },
    player_spawns = {},          -- [name] = pos
    arenas = {
        cove = {
            label = "Cove",
            spawn_points = {},
            spectator_spawn = nil,
            center = nil,
            radius = 128,
            max_players = 8,
            enabled = true,
            chests = {},
            reset_schematic = nil,   -- e.g. "battle_cove_reset.mts"
            reset_origin    = nil,   -- {x,y,z} = corner used when saving schematic
            tumble_spawn_points = nil,
            tumble_layers   = {},    -- multi-layer Tumble floors
        },
    },
}

local function load_config()
    local raw = storage:get_string("config")
    if raw ~= "" then
        local ok, data = pcall(minetest.deserialize, raw)
        if ok and type(data) == "table" then
            config = data
            config.arenas        = config.arenas or {}
            config.player_spawns = config.player_spawns or {}
        end
    end
end

local function save_config()
    storage:set_string("config", minetest.serialize(config))
end

load_config()

local function get_default_spawn_for(name)
    if config.player_spawns[name] then
        return config.player_spawns[name]
    end
    return config.lobby_spawn
end

local function get_or_create_arena(id)
    if not config.arenas[id] then
        config.arenas[id] = {
            label = id,
            spawn_points = {},
            spectator_spawn = nil,
            center = nil,
            radius = 128,
            max_players = 8,
            enabled = true,
            chests = {},
            reset_schematic = nil,
            reset_origin    = nil,
            tumble_spawn_points = nil,
            tumble_layers   = {},
        }
    else
        local a = config.arenas[id]
        a.spawn_points        = a.spawn_points        or {}
        a.chests              = a.chests              or {}
        a.reset_schematic     = a.reset_schematic     or nil
        a.reset_origin        = a.reset_origin        or nil
        a.tumble_spawn_points = a.tumble_spawn_points or nil
        a.tumble_layers       = a.tumble_layers       or {}
    end
    return config.arenas[id]
end

local function iter_enabled_arenas()
    local list = {}
    for id, arena in pairs(config.arenas) do
        if arena.enabled ~= false then
            table.insert(list, { id = id, arena = arena })
        end
    end
    table.sort(list, function(a,b)
        return (a.arena.label or a.id) < (b.arena.label or b.id)
    end)
    return list
end

local function get_random_arena()
    local list = iter_enabled_arenas()
    if #list == 0 then return nil end
    local i = math.random(1,#list)
    return list[i].id, list[i].arena
end

------------------------------------------------------------
-- BASIC HELPERS
------------------------------------------------------------

local function table_contains(t, v)
    for _,x in ipairs(t) do if x == v then return true end end
    return false
end

local function remove_from_list(t, v)
    for i,x in ipairs(t) do
        if x == v then table.remove(t,i) return end
    end
end

local function count_set(tbl)
    local n=0
    for _ in pairs(tbl) do n=n+1 end
    return n
end

local function broadcast(msg)
    minetest.chat_send_all(minetest.colorize("#FFD700","[Battle] "..msg))
end

local function msg(name, m)
    minetest.chat_send_player(name, minetest.colorize("#FFD700","[Battle] "..m))
end

local function teleport_player(name, pos)
    local p = minetest.get_player_by_name(name)
    if p and pos then p:set_pos(pos) end
end

------------------------------------------------------------
-- UTILS: DEEPCOPY + TUMBLE LAYER HISTORY
------------------------------------------------------------

local function deepcopy(v)
    if type(v) ~= "table" then
        return v
    end
    local t = {}
    for k, val in pairs(v) do
        t[k] = deepcopy(val)
    end
    return t
end

-- Stores the previous tumble_layers for each arena_id
local tumble_layers_history = {}   -- [arena_id] = { ...tumble_layers... }

local function backup_tumble_layers(aid, arena)
    arena.tumble_layers = arena.tumble_layers or {}
    tumble_layers_history[aid] = deepcopy(arena.tumble_layers)
end

local function is_battle_player(name)
    return battle
       and battle.state == "running"
       and name
       and battle.players[name]
end

------------------------------------------------------------
-- PROTECTION: NO BLOCK BREAKING / PLACING DURING BATTLE
------------------------------------------------------------

local old_is_protected = minetest.is_protected or function() return false end

function minetest.is_protected(pos, name)
    if battle
    and battle.state == "running"
    and name
    and battle.players[name]
    then
        if minetest.check_player_privs(name, { protection_bypass = true }) then
            return old_is_protected(pos, name)
        end

        local node = minetest.get_node(pos)
        local nname = node and node.name or ""

        if nname == "mcl_chests:chest" or nname == "mcl_chests:trapped_chest" then
            return old_is_protected(pos, name)
        end

        return true
    end

    return old_is_protected(pos, name)
end

------------------------------------------------------------
-- BARRIER OVERRIDE + HIGHLIGHT WHILE HELD
------------------------------------------------------------

minetest.override_item("mcl_core:barrier", {
    walkable = false,
    buildable_to = false,
    floodable = false,
    pointable = true,
    diggable = true,
})

minetest.register_entity("battle_lobby:barrier_marker", {
    visual = "cube",
    visual_size = {x=1.02, y=1.02},
    textures = {
        "battle_lobby_flow_barrier.png",
        "battle_lobby_flow_barrier.png",
        "battle_lobby_flow_barrier.png",
        "battle_lobby_flow_barrier.png",
        "battle_lobby_flow_barrier.png",
        "battle_lobby_flow_barrier.png",
    },
    use_texture_alpha = true,
    physical = false,
    collide_with_objects = false,
    collisionbox = {0,0,0,0,0,0},
    pointable = false,
    static_save = false,
    glow = 10,
})

local barrier_debug = {}
local barrier_timer = 0

local function clear_markers_for(name)
    local data = barrier_debug[name]
    if not data or not data.markers then return end
    for _,obj in ipairs(data.markers) do
        if obj and obj:get_luaentity() then obj:remove() end
    end
    data.markers = {}
end

minetest.register_globalstep(function(dtime)
    barrier_timer = barrier_timer + dtime
    if barrier_timer < 0.5 then return end
    barrier_timer = 0

    for _,player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        local wield = player:get_wielded_item():get_name()
        local data = barrier_debug[name] or {markers={},holding=false}
        barrier_debug[name] = data

        if wield == "mcl_core:barrier" then
            if not data.holding then
                data.holding = true
            end
            clear_markers_for(name)

            local pos = player:get_pos()
            local r = 10
            local minp = vector.subtract(pos,r)
            local maxp = vector.add(pos,r)
            local nodes = minetest.find_nodes_in_area(minp,maxp,{"mcl_core:barrier"})
            for _,bpos in ipairs(nodes) do
                local mp = {x=bpos.x+0.5,y=bpos.y+0.5,z=bpos.z+0.5}
                local obj = minetest.add_entity(mp,"battle_lobby:barrier_marker")
                if obj then table.insert(data.markers,obj) end
            end
        else
            if data.holding then
                data.holding = false
                clear_markers_for(name)
            end
        end
    end
end)

------------------------------------------------------------
-- LEGACY-STYLE ATMOSPHERE + MINIMAP
------------------------------------------------------------

local function apply_legacy_atmosphere(player)
    if not LEGACY_ATMOS_ENABLED then return end
    if not player or not player:is_player() then return end
    local name = player:get_player_name()
    if not name then return end

    player:set_sky({
        type="regular",
        sky_color = {
            day_sky       = "#7f8ea5",
            day_horizon   = "#9faec0",
            dawn_sky      = "#7a7f93",
            dawn_horizon  = "#9a9fb3",
            night_sky     = "#050713",
            night_horizon = "#151827",
            indoor        = "#3a3a3a",
        },
    })
    player:override_day_night_ratio(0.8)
    player:set_lighting({
        saturation = 0.55,
    })
    player:set_clouds({
        density   = 0.4,
        color     = "#c0c0c0",
        ambient   = "#b0b0b0",
        height    = 120,
        thickness = 16,
        speed     = {x=-2,y=0},
    })

    legacy_atmos_players[name] = true
end

local function clear_legacy_atmosphere(player)
    if not player or not player:is_player() then return end
    local name = player:get_player_name()
    if not name then return end
    player:set_sky({type="regular"})
    player:override_day_night_ratio(nil)
    player:set_clouds(nil)
    player:set_lighting({})
    legacy_atmos_players[name] = nil
end

local function battle_enable_minimap(player)
    if player and player.hud_set_flags then
        player:hud_set_flags({
            minimap = true,
            minimap_radar = true,
        })
    end
end

------------------------------------------------------------
-- LOOT TABLES (Battle)
------------------------------------------------------------

local loot_tables = {
    center_initial = {
        {name="mcl_core:iron_sword",       min=1,max=1,chance=1.0},
        {name="mcl_core:bow",              min=1,max=1,chance=0.8},
        {name="mcl_core:arrow",            min=8,max=16,chance=1.0},
        {name="mcl_armor:iron_chestplate", min=1,max=1,chance=0.7},
        {name="mcl_armor:iron_helmet",     min=1,max=1,chance=0.7},
        {name="mcl_potions:healing",       min=1,max=2,chance=0.6},
        {name="mcl_core:golden_apple",     min=1,max=1,chance=0.4},
        {name="mcl_core:bread",            min=2,max=4,chance=1.0},
    },
    center_refill = {
        {name="mcl_core:stone_sword",      min=1,max=1,chance=0.9},
        {name="mcl_core:bow",              min=1,max=1,chance=0.4},
        {name="mcl_core:arrow",            min=4,max=8,chance=0.8},
        {name="mcl_core:bread",            min=1,max=3,chance=1.0},
        {name="mcl_potions:swiftness",     min=1,max=1,chance=0.3},
    },
    valuable = {
        {name="mcl_core:iron_sword",       min=1,max=1,chance=1.0},
        {name="mcl_core:shield",           min=1,max=1,chance=0.7},
        {name="mcl_armor:iron_leggings",   min=1,max=1,chance=0.7},
        {name="mcl_armor:iron_boots",      min=1,max=1,chance=0.7},
        {name="mcl_potions:strength",      min=1,max=1,chance=0.3},
        {name="mcl_core:steak",            min=2,max=4,chance=1.0},
    },
    regular = {
        {name="mcl_core:stone_sword",      min=1,max=1,chance=0.4},
        {name="mcl_core:wooden_sword",     min=1,max=1,chance=0.7},
        {name="mcl_core:bread",            min=1,max=3,chance=1.0},
        {name="mcl_core:apple",            min=1,max=3,chance=0.8},
        {name="mcl_core:arrow",            min=2,max=6,chance=0.6},
        {name="mcl_potions:healing",       min=1,max=1,chance=0.2},
    },
    special = {
        {name="mcl_core:iron_sword",       min=1,max=1,chance=0.9},
        {name="mcl_armor:iron_chestplate", min=1,max=1,chance=0.9},
        {name="mcl_core:golden_apple",     min=1,max=1,chance=0.6},
        {name="mcl_potions:healing",       min=1,max=2,chance=0.7},
        {name="mcl_potions:swiftness",     min=1,max=1,chance=0.7},
    },
}

local function add_loot(inv, listname, tbl)
    if not tbl then return end
    for _,def in ipairs(tbl) do
        if math.random() <= (def.chance or 1) then
            local cmin = def.min or 1
            local cmax = def.max or cmin
            local count = math.random(cmin,cmax)
            inv:add_item(listname, ItemStack(def.name.." "..count))
        end
    end
end

local function loot_for_type(ctype, is_initial)
    if ctype == "center" then
        return is_initial and loot_tables.center_initial or loot_tables.center_refill
    elseif ctype == "valuable" then
        return loot_tables.valuable
    elseif ctype == "special" then
        return loot_tables.special
    else
        return loot_tables.regular
    end
end

battle.chest_runtime = nil -- {arena_id=..., chests={ {pos,ctype,next_refill_at} }}

local function prepare_battle_chests(arena_id, arena)
    battle.chest_runtime = { arena_id=arena_id, chests={} }
    if not arena.chests then return end
    for idx,info in ipairs(arena.chests) do
        local pos = info.pos
        local ctype = info.ctype or "regular"
        local node = minetest.get_node(pos)
        if node and (node.name=="mcl_chests:chest" or node.name=="mcl_chests:trapped_chest") then
            local inv = minetest.get_inventory({type="node",pos=pos})
            if inv and inv:get_list("main") then
                inv:set_list("main",{})
                add_loot(inv,"main", loot_for_type(ctype,true))
                battle.chest_runtime.chests[idx] = {
                    pos = vector.new(pos),
                    ctype = ctype,
                    next_refill_at = os.time()+30,
                }
            end
        end
    end
end

local function update_battle_chest_refills()
    if battle.state ~= "running" then return end
    local rt = battle.chest_runtime
    if not rt or not rt.chests then return end
    local now = os.time()
    for _,c in ipairs(rt.chests) do
        if c and now >= (c.next_refill_at or 0) then
            local inv = minetest.get_inventory({type="node",pos=c.pos})
            if inv and inv:get_list("main") and inv:is_empty("main") then
                add_loot(inv,"main", loot_for_type(c.ctype,false))
                c.next_refill_at = now+30
            end
        end
    end
end

------------------------------------------------------------
-- TUMBLE: MULTI-LAYER SPLEEF FLOOR GENERATION
------------------------------------------------------------

-- arena.tumble_layers is a list like:
-- {
--   { y = 6, radius = 10, palette = {"mcl_core:snow_block","mcl_core:gravel"} },
--   { y = -10, radius = 12, palette = {...} },
-- }

local function build_tumble_layers_for_arena(arena)
    if not arena or not arena.center then
        return
    end
    if not arena.tumble_layers or #arena.tumble_layers == 0 then
        return
    end

    local cx, cz = arena.center.x, arena.center.z

    for _,layer in ipairs(arena.tumble_layers) do
        local y      = layer.y
        local radius = layer.radius
        local palette = layer.palette or {}

        -- Enforce Y range at runtime (safety)
        if y and y >= -30 and y <= 6 and radius and radius > 0 and #palette > 0 then
            for dx = -radius, radius do
                for dz = -radius, radius do
                    if (dx * dx + dz * dz) <= (radius * radius + 1) then
                        local pos = { x = cx + dx, y = y, z = cz + dz }
                        local cur = minetest.get_node(pos)
                        if cur.name ~= "mcl_core:bedrock" then
                            local chosen = palette[math.random(1,#palette)]
                            minetest.set_node(pos, { name = chosen })
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- BATTLE + TUMBLE MATCH FLOW + MAP VOTING
------------------------------------------------------------

battle.state = "idle"
battle.countdown = 0
battle.arena_id = nil
battle.players = {}
battle.alive = {}
battle.queue = {}
battle.vote_active = false
battle.votes = {}

local MIN_PLAYERS    = 2
local COUNTDOWN_TIME = 15

local function show_map_vote_formspec(name)
    local list = iter_enabled_arenas()
    if #list == 0 then
        msg(name,"No arenas available to vote for.")
        return
    end
    local fs = {
        "formspec_version[4]",
        "size[8,7]",
        "label[0.5,0.3;Battle Map Voting]",
        "label[0.5,0.8;Click the map you want to play:]",
    }
    local y = 1.3
    for _,e in ipairs(list) do
        local id = e.id
        local a = e.arena
        local label = a.label or id
        table.insert(fs, ("button[1,%f;6,0.7;bvote_%s;%s]"):format(
            y, id, minetest.formspec_escape(label.." ("..id..")")))
        y = y + 0.85
        if y > 6.3 then break end
    end
    minetest.show_formspec(name,"battle_lobby:vote",table.concat(fs,""))
end

local function pick_arena_from_votes()
    local counts = {}
    for _,aid in pairs(battle.votes) do
        local a = config.arenas[aid]
        if a and a.enabled ~= false then
            counts[aid] = (counts[aid] or 0)+1
        end
    end
    local best_count = 0
    local best_ids = {}
    for aid,c in pairs(counts) do
        if c > best_count then
            best_count = c
            best_ids = {aid}
        elseif c == best_count then
            table.insert(best_ids,aid)
        end
    end
    if best_count == 0 or #best_ids == 0 then return nil end
    return best_ids[math.random(1,#best_ids)], config.arenas[best_ids[1]]
end

------------------------------------------------------------
-- CHEST FORMSPEC: ONLY HOTBAR DURING BATTLE
------------------------------------------------------------

local function make_battle_chest_formspec(pos)
    local spos = ("%d,%d,%d"):format(pos.x, pos.y, pos.z)
    return "formspec_version[4]" ..
        "size[9,7]" ..
        "label[0,0;Chest]" ..
        "list[nodemeta:" .. spos .. ";main;0,0.5;9,3;]" ..
        "list[current_player;main;0,5.0;9,1;]" ..
        "listring[nodemeta:" .. spos .. ";main]" ..
        "listring[current_player;main]"
end

local function override_chest_for_battle(chest_name)
    local def = minetest.registered_nodes[chest_name]
    if not def then
        minetest.log("warning", "[battle_lobby] Chest node not found: " .. chest_name)
        return
    end

    local old_on_rightclick = def.on_rightclick

    minetest.override_item(chest_name, {
        on_rightclick = function(pos, node, clicker, itemstack, pointed_thing)
            local name = clicker and clicker:get_player_name()
            if name and is_battle_player(name) then
                minetest.show_formspec(
                    name,
                    "battle_lobby:chest_" .. minetest.pos_to_string(pos),
                    make_battle_chest_formspec(pos)
                )
                return itemstack
            end

            if old_on_rightclick then
                return old_on_rightclick(pos, node, clicker, itemstack, pointed_thing)
            end
            return itemstack
        end
    })
end

------------------------------------------------------------
-- INVENTORY LOCK DURING BATTLE
------------------------------------------------------------

minetest.register_on_player_receive_fields(function(player, formname, fields)
    local name = player:get_player_name()
    if not name then return end

    if battle.state == "running" and battle.players[name] then
        if formname:sub(1,14) == "mcl_inventory:" then
            msg(name, "Inventory is disabled during Battle. Use your hotbar only.")
            minetest.close_formspec(name, formname)
            return true
        end
    end
end)

------------------------------------------------------------
-- MAP RESET / SNAPSHOT + TUMBLE LAYERS
------------------------------------------------------------

local function battle_reset_arena_map(aid)
    if not aid then return end
    local arena = config.arenas[aid]
    if not arena then return end

    if not arena.reset_schematic or not arena.reset_origin then
        build_tumble_layers_for_arena(arena)
        return
    end

    local filename = worldpath .. "/" .. arena.reset_schematic
    local ok, err = pcall(minetest.place_schematic,
        arena.reset_origin, filename, "0", nil, true)
    if not ok then
        minetest.log("error", "[battle_lobby] Failed to reset arena '" ..
            aid .. "': " .. tostring(err))
    else
        minetest.log("action", "[battle_lobby] Reset arena '" .. aid .. "' from snapshot.")
    end

    build_tumble_layers_for_arena(arena)
end

local function reset_match_state()
    battle.state = "idle"
    battle.countdown = 0
    battle.arena_id = nil
    battle.players = {}
    battle.alive = {}
    battle.queue = {}
    battle.vote_active = false
    battle.votes = {}
    battle.chest_runtime = nil

    battle_slot_for_player = {}
    battle_player_for_slot = {}

    for vname,ui in pairs(battle_revive_hud) do
        local p = minetest.get_player_by_name(vname)
        if p then
            for _,id in pairs(ui.bg or {}) do p:hud_remove(id) end
            for _,id in pairs(ui.fg or {}) do p:hud_remove(id) end
        end
    end
    battle_revive_hud = {}

    for pname,hud in pairs(battle_armor_hud) do
        local p = minetest.get_player_by_name(pname)
        if p then
            for _,id in pairs(hud) do p:hud_remove(id) end
        end
    end
    battle_armor_hud = {}
end

local function start_countdown_if_ready()
    if battle.state ~= "idle" and battle.state ~= "countdown" then return end
    if #battle.queue < MIN_PLAYERS then return end
    if battle.state ~= "countdown" then
        battle.state = "countdown"
        battle.countdown = COUNTDOWN_TIME
        battle.vote_active = true
        battle.votes = {}
        broadcast("Match starting soon! "..#battle.queue.." players in queue. ("..COUNTDOWN_TIME.."s)")
        for _,name in ipairs(battle.queue) do
            minetest.after(0.5,function() show_map_vote_formspec(name) end)
        end
    end
end

local function start_match()
    if #battle.queue < MIN_PLAYERS then
        broadcast("Not enough players to start the match.")
        reset_match_state()
        return
    end

    local aid, arena = pick_arena_from_votes()
    if not aid or not arena then
        aid, arena = get_random_arena()
    end
    if not aid or not arena then
        broadcast("No arenas configured!")
        reset_match_state()
        return
    end

    prepare_battle_chests(aid, arena)

    local max_players = math.min(arena.max_players or 8, 8)

    local slots = {}
    for slot=1,max_players do
        local pos = arena.spawn_points[slot]
        if pos then table.insert(slots,{slot=slot,pos=pos}) end
    end
    if #slots < MIN_PLAYERS then
        broadcast("Arena "..aid.." does not have enough spawn slots ("..#slots..").")
        reset_match_state()
        return
    end

    local players_in_match = math.min(#battle.queue, #slots)
    if players_in_match < MIN_PLAYERS then
        broadcast("Not enough players to fill the arena.")
        reset_match_state()
        return
    end

    battle.state = "running"
    battle.arena_id = aid
    battle.players = {}
    battle.alive = {}
    battle.vote_active = false

    local label = arena.label or aid
    broadcast("Starting Battle on "..label.." with "..players_in_match.." players.")

    for i=1,players_in_match do
        local pname = battle.queue[i]
        local slot_info = slots[i]
        if pname and slot_info then
            local player = minetest.get_player_by_name(pname)
            if player then
                teleport_player(pname, slot_info.pos)
                battle.players[pname] = true
                battle.alive[pname] = true

                local slot = slot_info.slot or i
                battle_slot_for_player[pname] = slot
                battle_player_for_slot[slot] = pname

                msg(pname,"You are in slot #"..slot.." on '"..label.."'. Fight!")
            end
        end
    end

    if #battle.queue > players_in_match then
        local newq = {}
        for i=players_in_match+1,#battle.queue do
            local pname = battle.queue[i]
            msg(pname,"Arena full this round. You stay queued for next match.")
            table.insert(newq,pname)
        end
        battle.queue = newq
    else
        battle.queue = {}
    end
end

local function end_match(winner)
    local finished_arena = battle.arena_id

    if winner then
        broadcast("Battle over! Winner: "..winner)
    else
        broadcast("Battle ended.")
    end

    for pname,_ in pairs(battle.players) do
        teleport_player(pname, get_default_spawn_for(pname))
    end

    if finished_arena then
        battle_reset_arena_map(finished_arena)
    end

    reset_match_state()
end


-- Shallow copy helper
local function copy_groups(tbl)
    local t = {}
    if tbl then
        for k,v in pairs(tbl) do
            t[k] = v
        end
    end
    return t
end

-- Make a node instant-break for Tumble
local function tumble_make_instabreak(nodename)
    local def = minetest.registered_nodes[nodename]
    if not def then
        minetest.log("warning", "[battle_lobby] Tumble instabreak: unknown node '" .. nodename .. "'")
        return
    end

    -- Only override once, keep original groups
    if tumble_original_groups[nodename] then
        return
    end

    tumble_original_groups[nodename] = copy_groups(def.groups)

    local new_groups = copy_groups(def.groups)
    -- dig_immediate = 3 -> instant break by hand
    new_groups.dig_immediate = 3
    -- Make sure it's not marked unbreakable, if some mod did that
    new_groups.unbreakable = nil

    minetest.override_item(nodename, {
        groups = new_groups,
    })

    minetest.log("action", "[battle_lobby] Tumble: made '" .. nodename .. "' instabreak.")
end

-- Restore original groups when Tumble ends
local function tumble_restore_instabreak_nodes()
    for nodename, groups in pairs(tumble_original_groups) do
        local def = minetest.registered_nodes[nodename]
        if def then
            minetest.override_item(nodename, {
                groups = copy_groups(groups),
            })
        end
    end
    tumble_original_groups = {}
    minetest.log("action", "[battle_lobby] Tumble: restored original node groups.")
end

------------------------------------------------------------
-- REVIVE-LIKE BARS HUD (Battle only)
------------------------------------------------------------

local function revive_build_for_player(viewer)
    if not viewer or not viewer:is_player() then return end
    local vname = viewer:get_player_name()
    if not vname then return end

    if battle_revive_hud[vname] then
        local old = battle_revive_hud[vname]
        for _,id in pairs(old.bg or {}) do viewer:hud_remove(id) end
        for _,id in pairs(old.fg or {}) do viewer:hud_remove(id) end
    end

    local slot_list = {}
    for slot = 1, 8 do
        table.insert(slot_list, slot)
    end

    local ui = { bg = {}, fg = {}, slots = slot_list }

    if #slot_list == 0 then
        battle_revive_hud[vname] = ui
        return ui
    end

    local spacing = 26
    local total_w = (#slot_list - 1) * spacing
    local base_x = -math.floor(total_w / 2)
    local hud_y = 0.86

    for idx, slot in ipairs(slot_list) do
        local off_x = base_x + (idx - 1) * spacing

        local bg_id = viewer:hud_add({
            hud_elem_type = "image",
            position      = { x = 0.5, y = hud_y },
            offset        = { x = off_x, y = 0 },
            alignment     = { x = 0, y = 0 },
            scale         = { x = 24, y = 4 },
            text          = "battle_lobby_bar_bg.png",
        })

        local fg_id = viewer:hud_add({
            hud_elem_type = "image",
            position      = { x = 0.5, y = hud_y },
            offset        = { x = off_x, y = 0 },
            alignment     = { x = 0, y = 0 },
            scale         = { x = 24, y = 4 },
            text          = "",
        })

        ui.bg[slot] = bg_id
        ui.fg[slot] = fg_id
    end

    battle_revive_hud[vname] = ui
    return ui
end

local function revive_update_all()
    if battle.state ~= "running" then
        for vname,ui in pairs(battle_revive_hud) do
            local p = minetest.get_player_by_name(vname)
            if p then
                for _,id in pairs(ui.bg or {}) do p:hud_remove(id) end
                for _,id in pairs(ui.fg or {}) do p:hud_remove(id) end
            end
        end
        battle_revive_hud = {}
        return
    end

    local players = minetest.get_connected_players()
    for _,viewer in ipairs(players) do
        local vname = viewer:get_player_name()
        local ui = battle_revive_hud[vname]
        if not ui then
            ui = revive_build_for_player(viewer)
        end

        if ui and ui.fg then
            for slot = 1, 8 do
                local fg_id = ui.fg[slot]
                if fg_id then
                    local pname = battle_player_for_slot[slot]
                    local alive = pname and battle.alive[pname]
                    viewer:hud_change(
                        fg_id,
                        "text",
                        alive and "battle_lobby_bar_alive.png" or ""
                    )
                end
            end
        end
    end
end

------------------------------------------------------------
-- ARMOR HUD (Battle)
------------------------------------------------------------

local function clear_armor_hud(player)
    if not player or not player:is_player() then return end
    local name = player:get_player_name()
    local hud = battle_armor_hud[name]
    if not hud then return end
    for _,id in pairs(hud) do
        player:hud_remove(id)
    end
    battle_armor_hud[name] = nil
end

local function update_armor_hud(player)
    if not player or not player:is_player() then return end
    local name = player:get_player_name()
    if not name then return end

    if not (battle.state == "running" and battle.players[name]) then
        if battle_armor_hud[name] then
            clear_armor_hud(player)
        end
        return
    end

    local inv = player:get_inventory()
    if not inv then return end

    local lists = {
        head  = "armor_head",
        chest = "armor_torso",
        legs  = "armor_legs",
        feet  = "armor_feet",
    }

    local y_start = 0.35
    local y_step  = 0.1
    local hud = battle_armor_hud[name] or {}
    battle_armor_hud[name] = hud

    local order = {"head","chest","legs","feet"}
    for index,slot in ipairs(order) do
        local listname = lists[slot]
        local stack
        if listname and inv:get_size(listname) and inv:get_size(listname) > 0 then
            stack = inv:get_stack(listname, 1)
        end

        local icon = ""
        if stack and not stack:is_empty() then
            local def = minetest.registered_items[stack:get_name()] or {}
            icon = def.inventory_image or def.wield_image or ""
        end

        local id = hud[slot]
        local ypos = y_start + (index-1)*y_step

        if icon == "" then
            if id then
                player:hud_change(id,"text","")
            end
        else
            if not id then
                id = player:hud_add({
                    hud_elem_type = "image",
                    position      = {x=0.06,y=ypos},
                    offset        = {x=0,y=0},
                    alignment     = {x=0,y=0},
                    scale         = {x=24,y=24},
                    text          = icon,
                })
                hud[slot] = id
            else
                player:hud_change(id,"text",icon)
            end
        end
    end
end

------------------------------------------------------------
-- GLOBALSTEP (battle + tumble countdown / border / chest / HUD)
------------------------------------------------------------

local timer_accum = 0

minetest.register_globalstep(function(dtime)
    timer_accum = timer_accum + dtime
    if timer_accum < 1 then return end
    timer_accum = 0

    ----------------------------------------------------------------
    -- BATTLE COUNTDOWN
    ----------------------------------------------------------------
    if battle.state == "countdown" then
        battle.countdown = battle.countdown - 1
        if battle.countdown <= 0 then
            start_match()
        else
            if battle.countdown == 10 or battle.countdown == 5 or battle.countdown <= 3 then
                broadcast("Battle starting in " .. battle.countdown .. "s...")
            end
        end
    end

    ----------------------------------------------------------------
    -- TUMBLE COUNTDOWN
    ----------------------------------------------------------------
    if tumble.state == "countdown" then
        tumble.countdown = tumble.countdown - 1

        if tumble.countdown <= 0 then
            -- pick an arena
            local aid, arena = get_random_arena()
            if not aid or not arena then
                broadcast("No arenas for Tumble.")
                tumble.state = "idle"
            else
                tumble.arena_id = aid
                tumble.state = "running"
                tumble.players = {}
                tumble.alive = {}

                -- make all Tumble layer palette nodes instabreak
                if arena.tumble_layers then
                    local seen = {}
                    for _, layer in ipairs(arena.tumble_layers) do
                        if layer.palette then
                            for _, nodename in ipairs(layer.palette) do
                                if not seen[nodename] then
                                    seen[nodename] = true
                                    tumble_make_instabreak(nodename)
                                end
                            end
                        end
                    end
                end

                broadcast("Starting Tumble on " .. (arena.label or aid) ..
                    " with " .. #tumble.queue .. " players.")

                local max_slots = arena.max_players or 8
                for i, pname in ipairs(tumble.queue) do
                    if i > max_slots then
                        msg(pname, "Tumble arena full, you'll be in next round.")
                    else
                        local slot = i
                        local spawns = arena.tumble_spawn_points or arena.spawn_points
                        local pos = spawns and spawns[slot]
                        if pos then
                            teleport_player(pname, pos)
                            tumble.players[pname] = true
                            tumble.alive[pname] = true
                        else
                            msg(pname, "No Tumble spawn slot " .. slot ..
                                " set for arena " .. aid)
                        end
                    end
                end

                tumble.queue = {}
            end
        else
            if tumble.countdown == 5 or tumble.countdown <= 3 then
                broadcast("Tumble starting in " .. tumble.countdown .. "s...")
            end
        end
    end

    ----------------------------------------------------------------
    -- BATTLE BORDER CHECK
    ----------------------------------------------------------------
    if battle.state == "running" and battle.arena_id then
        local arena = config.arenas[battle.arena_id]
        if arena and arena.center and arena.radius then
            for name,_ in pairs(battle.alive) do
                local p = minetest.get_player_by_name(name)
                if p then
                    local pos = p:get_pos()
                    local dx = pos.x - arena.center.x
                    local dz = pos.z - arena.center.z
                    if dx*dx + dz*dz > arena.radius*arena.radius then
                        msg(name, "You reached the edge of the arena!")
                        teleport_player(name, arena.center)
                    end
                end
            end
        end
    end

    ----------------------------------------------------------------
    -- OTHER PERIODIC UPDATES
    ----------------------------------------------------------------
    update_battle_chest_refills()
    revive_update_all()

    for _,player in ipairs(minetest.get_connected_players()) do
        update_armor_hud(player)
    end
end)

-- Patch all snowball-like entities so they can break blocks in Tumble
local function patch_snowballs_for_tumble()
    local patched = {}

    -- Helper: shallow copy groups (used elsewhere already)
    local function break_block_at(pos)
        if not pos then return end
        pos = vector.round(pos)
        local node = minetest.get_node(pos)
        if not node or node.name == "air" or node.name == "ignore" then
            return
        end
        if node.name ~= "mcl_core:bedrock" then
            minetest.dig_node(pos)
            minetest.log("action", "[battle_lobby] Snowball broke block at " ..
                minetest.pos_to_string(pos) .. " (" .. node.name .. ")")
        end
    end

    -- DEBUG: set true to test *without* Tumble running
    local DEBUG_ALWAYS_BREAK = true

    for name, def in pairs(minetest.registered_entities) do
        -- Catch anything that looks like a snowball entity
        if name:find("snowball") then
            local old_step = def.on_step

            minetest.registered_entities[name].on_step = function(self, dtime, moveresult)
                -- Call original behavior (movement, lifetime, etc.)
                if old_step then
                    local ok, err = pcall(old_step, self, dtime, moveresult)
                    if not ok then
                        minetest.log("error",
                            "[battle_lobby] Error in original snowball on_step (" ..
                            name .. "): " .. tostring(err))
                    end
                end

                -- Who threw it?
                local thrower_name = self._thrower or self._owner or self._shooter

                -- Only break in Tumble, unless debug mode is on
                if not DEBUG_ALWAYS_BREAK then
                    if tumble.state ~= "running" then
                        return
                    end
                    if not thrower_name or not tumble.players[thrower_name] then
                        return
                    end
                end

                -- Use moveresult collisions if available
                if moveresult and moveresult.collisions then
                    for _, col in ipairs(moveresult.collisions) do
                        if col.type == "node" and col.node_pos then
                            break_block_at(col.node_pos)
                            self.object:remove()
                            return
                        end
                    end
                else
                    -- Fallback: check current position
                    local pos = self.object:get_pos()
                    if pos then
                        break_block_at(pos)
                        -- If we broke something (now air), remove the snowball
                        local node = minetest.get_node(vector.round(pos))
                        if node.name == "air" then
                            self.object:remove()
                        end
                    end
                end
            end

            table.insert(patched, name)
        end
    end

    if #patched == 0 then
        minetest.log("warning", "[battle_lobby] No snowball-like entities found to patch.")
    else
        minetest.log("action", "[battle_lobby] Patched snowball-like entities: " ..
            table.concat(patched, ", "))
    end
end


------------------------------------------------------------
-- PLAYER EVENTS
------------------------------------------------------------

minetest.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    apply_legacy_atmosphere(player)
    battle_enable_minimap(player)

    minetest.after(0.1,function()
        if battle.state == "running" and battle.players[name] then
            local arena = battle.arena_id and config.arenas[battle.arena_id]
            if arena and arena.spectator_spawn then
                teleport_player(name, arena.spectator_spawn)
            else
                teleport_player(name, get_default_spawn_for(name))
            end
        elseif tumble.state == "running" and tumble.players[name] then
            local arena = tumble.arena_id and config.arenas[tumble.arena_id]
            if arena and arena.center then
                teleport_player(name, arena.center)
            else
                teleport_player(name, get_default_spawn_for(name))
            end
        else
            teleport_player(name, get_default_spawn_for(name))
        end
    end)
end)

local function end_tumble_match(winner)
    local finished_arena = tumble.arena_id

    broadcast("Tumble over! Winner: "..(winner or "none"))
    for pname,_ in pairs(tumble.players) do
        teleport_player(pname, get_default_spawn_for(pname))
    end

    if finished_arena then
        battle_reset_arena_map(finished_arena)
    end

    tumble.state   = "idle"
    tumble.players = {}
    tumble.alive   = {}
    tumble.arena_id = nil
end

minetest.register_on_leaveplayer(function(player)
    local name = player:get_player_name()
    clear_legacy_atmosphere(player)
    clear_armor_hud(player)

    if battle_revive_hud[name] then
        local ui = battle_revive_hud[name]
        for _,id in pairs(ui.bg or {}) do player:hud_remove(id) end
        for _,id in pairs(ui.fg or {}) do player:hud_remove(id) end
        battle_revive_hud[name] = nil
    end

    remove_from_list(battle.queue,name)
    if tumble.queue then remove_from_list(tumble.queue,name) end

    if battle.alive[name] then
        battle.alive[name] = nil
        if battle.state=="running" and count_set(battle.alive)<=1 then
            local winner
            for n,_ in pairs(battle.alive) do winner=n end
            end_match(winner)
        end
    end

    if tumble.alive[name] then
        tumble.alive[name] = nil
        if tumble.state=="running" and count_set(tumble.alive)<=1 then
            local winner
            for n,_ in pairs(tumble.alive) do winner=n end
            end_tumble_match(winner)
        end
    end
end)

minetest.register_on_dieplayer(function(player)
    local name = player:get_player_name()

    if battle.state=="running" and battle.alive[name] then
        battle.alive[name] = nil
        local arena = battle.arena_id and config.arenas[battle.arena_id]
        if arena and arena.spectator_spawn then
            minetest.after(0.1,function()
                local p = minetest.get_player_by_name(name)
                if p then p:set_pos(arena.spectator_spawn) end
            end)
        else
            minetest.after(0.1,function()
                teleport_player(name,get_default_spawn_for(name))
            end)
        end
        if count_set(battle.alive)<=1 then
            local winner
            for n,_ in pairs(battle.alive) do winner=n end
            end_match(winner)
        end
    elseif tumble.state=="running" and tumble.alive[name] then
        tumble.alive[name]=nil
        minetest.after(0.1,function()
            teleport_player(name,get_default_spawn_for(name))
        end)
        if count_set(tumble.alive)<=1 then
            local winner
            for n,_ in pairs(tumble.alive) do winner=n end
            end_tumble_match(winner)
        end
    end
end)

minetest.register_on_respawnplayer(function(player)
    local name = player:get_player_name()
    if battle.state=="running" and battle.players[name] then
        local arena = battle.arena_id and config.arenas[battle.arena_id]
        if arena and arena.spectator_spawn then
            player:set_pos(arena.spectator_spawn)
        else
            player:set_pos(get_default_spawn_for(name))
        end
        return true
    elseif tumble.state=="running" and tumble.players[name] then
        player:set_pos(get_default_spawn_for(name))
        return true
    else
        player:set_pos(get_default_spawn_for(name))
        return true
    end
end)

------------------------------------------------------------
-- FORMSPEC HANDLER: MAP VOTING
------------------------------------------------------------

minetest.register_on_player_receive_fields(function(player, formname, fields)
    if formname ~= "battle_lobby:vote" then return end
    local name = player:get_player_name()
    if not name then return end
    for field,_ in pairs(fields) do
        if field:sub(1,6) == "bvote_" then
            local aid = field:sub(7)
            local a = config.arenas[aid]
            if a and a.enabled ~= false then
                battle.votes[name] = aid
                msg(name,"You voted for "..(a.label or aid))
                minetest.after(0.05,function() show_map_vote_formspec(name) end)
            else
                msg(name,"Arena not available.")
            end
            return
        end
    end
end)

------------------------------------------------------------
-- CHAT COMMANDS: BATTLE JOIN / CONFIG / VOTE
------------------------------------------------------------

minetest.register_chatcommand("battle_join",{
    description="Join next Battle match.",
    func=function(name,param)
        if battle.state=="running" then
            msg(name,"A match is already running.")
            return
        end
        if table_contains(battle.queue,name) then
            msg(name,"You are already queued.")
            return
        end
        table.insert(battle.queue,name)
        msg(name,"You joined the Battle queue.")
        broadcast(name.." joined Battle queue ("..#battle.queue.." players).")
        start_countdown_if_ready()
    end
})

minetest.register_chatcommand("battle_leave",{
    description="Leave Battle queue.",
    func=function(name,param)
        if table_contains(battle.queue,name) then
            remove_from_list(battle.queue,name)
            msg(name,"You left the Battle queue.")
            broadcast(name.." left the Battle queue ("..#battle.queue.." players).")
        else
            msg(name,"You are not in the queue.")
        end
    end
})

minetest.register_chatcommand("battle_vote",{
    description="Open Battle map vote.",
    func=function(name,param)
        if battle.state=="running" then
            msg(name,"Can't vote while a match is running.")
            return
        end
        show_map_vote_formspec(name)
    end
})

minetest.register_chatcommand("battle_forcestart",{
    privs={server=true},
    description="Force Battle to start in 3s.",
    func=function(name,param)
        if #battle.queue<1 then
            msg(name,"No players in queue.")
            return
        end
        battle.state="countdown"
        battle.countdown=3
        battle.vote_active=true
        battle.votes={}
        broadcast("Admin "..name.." forced Battle start (3s).")
        for _,pname in ipairs(battle.queue) do
            minetest.after(0.5,function() show_map_vote_formspec(pname) end)
        end
    end
})

minetest.register_chatcommand("battle_reset",{
    privs={server=true},
    description="Reset Battle system.",
    func=function(name,param)
        reset_match_state()
        broadcast("Battle reset by "..name..".")
    end
})

minetest.register_chatcommand("battle_set_lobby_spawn",{
    privs={server=true},
    description="Set lobby spawn to your position.",
    func=function(name,param)
        local p = minetest.get_player_by_name(name); if not p then return end
        local pos = vector.round(p:get_pos())
        config.lobby_spawn = pos
        save_config()
        msg(name,"Lobby spawn set to "..minetest.pos_to_string(pos))
    end
})

minetest.register_chatcommand("battle_set_my_spawn",{
    privs={server=true},
    description="Set your personal default spawn.",
    func=function(name,param)
        local p = minetest.get_player_by_name(name); if not p then return end
        local pos = vector.round(p:get_pos())
        config.player_spawns[name] = pos
        save_config()
        msg(name,"Your spawn set to "..minetest.pos_to_string(pos))
    end
})

minetest.register_chatcommand("battle_clear_my_spawn",{
    privs={server=true},
    description="Clear your personal spawn.",
    func=function(name,param)
        if config.player_spawns[name] then
            config.player_spawns[name]=nil
            save_config()
            msg(name,"Personal spawn cleared.")
        else
            msg(name,"You don't have a personal spawn set.")
        end
    end
})

minetest.register_chatcommand("battle_set_spawn",{
    privs={server=true},
    params="<arena_id> <slot>",
    description="Set Battle spawn slot 1-8 for arena at your position.",
    func=function(name,param)
        local aid,slot_s = param:match("^(%S+)%s+(%S+)$")
        if not aid or not slot_s then
            msg(name,"Usage: /battle_set_spawn <arena_id> <slot 1-8>")
            return
        end
        local slot = tonumber(slot_s)
        if not slot or slot<1 or slot>8 then
            msg(name,"Slot must be 1..8")
            return
        end
        local p = minetest.get_player_by_name(name); if not p then return end
        local pos = vector.round(p:get_pos())
        local arena = get_or_create_arena(aid)
        arena.spawn_points[slot] = pos
        save_config()
        msg(name,"Set Battle spawn slot #"..slot.." for '"..aid.."' at "..minetest.pos_to_string(pos))
    end
})

minetest.register_chatcommand("battle_set_spec",{
    privs={server=true},
    params="<arena_id>",
    description="Set spectator spawn for arena.",
    func=function(name,param)
        local aid = param ~= "" and param or "cove"
        local p = minetest.get_player_by_name(name); if not p then return end
        local pos = vector.round(p:get_pos())
        local arena = get_or_create_arena(aid)
        arena.spectator_spawn = pos
        save_config()
        msg(name,"Spectator spawn for '"..aid.."' set to "..minetest.pos_to_string(pos))
    end
})

minetest.register_chatcommand("battle_set_center",{
    privs={server=true},
    params="<arena_id>",
    description="Set arena center (for border/Tumble) to your position.",
    func=function(name,param)
        local aid = param ~= "" and param or "cove"
        local p = minetest.get_player_by_name(name); if not p then return end
        local pos = vector.round(p:get_pos())
        local arena = get_or_create_arena(aid)
        arena.center = pos
        save_config()
        msg(name,"Center for '"..aid.."' set to "..minetest.pos_to_string(pos))
    end
})

minetest.register_chatcommand("battle_set_radius",{
    privs={server=true},
    params="<arena_id> <radius>",
    description="Set arena radius.",
    func=function(name,param)
        local aid,rs = param:match("^(%S+)%s+(%S+)$")
        if not aid or not rs then
            msg(name,"Usage: /battle_set_radius <arena_id> <radius>")
            return
        end
        local r = tonumber(rs)
        if not r or r<=0 then
            msg(name,"Radius must be > 0")
            return
        end
        local arena = get_or_create_arena(aid)
        arena.radius = r
        save_config()
        msg(name,"Radius for '"..aid.."' set to "..r)
    end
})

minetest.register_chatcommand("battle_mark_chest",{
    privs={server=true},
    params="<arena_id> <center|valuable|regular|special>",
    description="Mark chest under you as Battle loot chest.",
    func=function(name,param)
        local aid,ctype = param:match("^(%S+)%s+(%S+)$")
        if not aid or not ctype then
            msg(name,"Usage: /battle_mark_chest <arena_id> <center|valuable|regular|special>")
            return
        end
        ctype = ctype:lower()
        if not (ctype=="center" or ctype=="valuable" or ctype=="regular" or ctype=="special") then
            msg(name,"Type must be center/valuable/regular/special")
            return
        end
        local p = minetest.get_player_by_name(name); if not p then return end
        local pos = p:get_pos()
        local cpos = vector.round({x=pos.x,y=pos.y-1,z=pos.z})
        local node = minetest.get_node(cpos)
        if not node or (node.name~="mcl_chests:chest" and node.name~="mcl_chests:trapped_chest") then
            msg(name,"No Mineclonia chest directly under you.")
            return
        end
        local arena = get_or_create_arena(aid)
        arena.chests = arena.chests or {}
        table.insert(arena.chests,{pos=cpos,ctype=ctype})
        save_config()
        msg(name,("Registered %s chest at %s for '%s'"):format(
            ctype,minetest.pos_to_string(cpos),aid))
    end
})

minetest.register_chatcommand("battle_set_enabled",{
    privs={server=true},
    params="<arena_id> <true|false>",
    description="Enable/disable arena for selection.",
    func=function(name,param)
        local aid,flag = param:match("^(%S+)%s+(%S+)$")
        if not aid or not flag then
            msg(name,"Usage: /battle_set_enabled <arena_id> <true|false>")
            return
        end
        local arena = get_or_create_arena(aid)
        if flag=="true" then arena.enabled=true
        elseif flag=="false" then arena.enabled=false
        else msg(name,"Second arg must be true/false"); return end
        save_config()
        msg(name,"Arena '"..aid.."' enabled="..tostring(arena.enabled))
    end
})

minetest.register_chatcommand("battle_legacy_atmosphere",{
    privs={server=true},
    params="<on|off>",
    description="Toggle Legacy-style sky/lighting.",
    func=function(name,param)
        param = (param or ""):lower()
        if param~="on" and param~="off" then
            msg(name,"Usage: /battle_legacy_atmosphere <on|off>")
            return
        end
        LEGACY_ATMOS_ENABLED = (param=="on")
        for _,p in ipairs(minetest.get_connected_players()) do
            if LEGACY_ATMOS_ENABLED then apply_legacy_atmosphere(p)
            else clear_legacy_atmosphere(p) end
        end
        msg(name,"Legacy atmosphere: "..param)
    end
})

------------------------------------------------------------
-- CHAT COMMANDS: MAP RESET SNAPSHOTS
------------------------------------------------------------

minetest.register_chatcommand("battle_pos1", {
    privs = { server = true },
    description = "Set pos1 for Battle arena snapshot region.",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return end
        local pos = vector.round(player:get_pos())
        battle_pos_marks[name] = battle_pos_marks[name] or {}
        battle_pos_marks[name].pos1 = pos
        msg(name, "battle_pos1 set to " .. minetest.pos_to_string(pos))
    end,
})

minetest.register_chatcommand("battle_pos2", {
    privs = { server = true },
    description = "Set pos2 for Battle arena snapshot region.",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return end
        local pos = vector.round(player:get_pos())
        battle_pos_marks[name] = battle_pos_marks[name] or {}
        battle_pos_marks[name].pos2 = pos
        msg(name, "battle_pos2 set to " .. minetest.pos_to_string(pos))
    end,
})

minetest.register_chatcommand("battle_save_snapshot", {
    privs = { server = true },
    params = "<arena_id>",
    description = "Save/reset snapshot for an arena using your battle_pos1/pos2.",
    func = function(name, param)
        local aid = param ~= "" and param or nil
        if not aid then
            msg(name, "Usage: /battle_save_snapshot <arena_id>")
            return
        end

        local marks = battle_pos_marks[name]
        if not marks or not marks.pos1 or not marks.pos2 then
            msg(name, "You must set /battle_pos1 and /battle_pos2 first.")
            return
        end

        local p1 = marks.pos1
        local p2 = marks.pos2
        local minp = {
            x = math.min(p1.x, p2.x),
            y = math.min(p1.y, p2.y),
            z = math.min(p1.z, p2.z),
        }
        local maxp = {
            x = math.max(p1.x, p2.x),
            y = math.max(p1.y, p2.y),
            z = math.max(p1.z, p2.z),
        }

        local filename = worldpath .. "/battle_" .. aid .. "_reset.mts"

        minetest.chat_send_player(name, "Saving schematic to: " .. filename)
        local ok, err = pcall(minetest.create_schematic, minp, maxp, nil, filename)
        if not ok then
            msg(name, "Failed to create schematic: " .. tostring(err))
            return
        end

        local arena = get_or_create_arena(aid)
        arena.reset_schematic = "battle_" .. aid .. "_reset.mts"
        arena.reset_origin = minp
        save_config()

        msg(name, "Snapshot for arena '" .. aid .. "' saved.")
        msg(name, "It will be used to reset the map after each match.")
    end,
})

minetest.register_chatcommand("battle_restore_now", {
    privs = { server = true },
    params = "<arena_id>",
    description = "Immediately restore an arena from its snapshot.",
    func = function(name, param)
        local aid = param ~= "" and param or nil
        if not aid then
            msg(name, "Usage: /battle_restore_now <arena_id>")
            return
        end

        local arena = config.arenas[aid]
        if not arena or not arena.reset_schematic or not arena.reset_origin then
            msg(name, "Arena '" .. aid .. "' has no snapshot saved.")
            return
        end

        local filename = worldpath .. "/" .. arena.reset_schematic
        minetest.chat_send_player(name, "Restoring from: " .. filename)

        local ok, err = pcall(minetest.place_schematic,
            arena.reset_origin, filename, "0", nil, true)
        if not ok then
            msg(name, "Failed to restore arena: " .. tostring(err))
        else
            msg(name, "Arena '" .. aid .. "' restored from snapshot.")
        end

        build_tumble_layers_for_arena(arena)
    end,
})

------------------------------------------------------------
-- CHAT COMMANDS: TUMBLE
------------------------------------------------------------

minetest.register_chatcommand("tumble_join",{
    description="Join next Tumble match.",
    func=function(name,param)
        if tumble.state=="running" then
            msg(name,"Tumble is in progress; wait for next round.")
            return
        end
        if table_contains(tumble.queue,name) then
            msg(name,"You are already in the Tumble queue.")
            return
        end
        table.insert(tumble.queue,name)
        msg(name,"You joined the Tumble queue.")
        broadcast(name.." joined Tumble queue ("..#tumble.queue.." players).")
        if tumble.state=="idle" and #tumble.queue>=2 then
            tumble.state="countdown"
            tumble.countdown=10
            broadcast("Tumble match starting soon ("..tumble.countdown.."s).")
        end
    end
})

minetest.register_chatcommand("tumble_leave",{
    description="Leave Tumble queue.",
    func=function(name,param)
        if table_contains(tumble.queue,name) then
            remove_from_list(tumble.queue,name)
            msg(name,"You left the Tumble queue.")
        else
            msg(name,"You are not in the Tumble queue.")
        end
    end
})

minetest.register_chatcommand("tumble_set_spawn",{
    privs={server=true},
    params="<arena_id> <slot>",
    description="Set Tumble spawn slot 1-8 (or reuse Battle spawns).",
    func=function(name,param)
        local aid,slot_s = param:match("^(%S+)%s+(%S+)$")
        if not aid or not slot_s then
            msg(name,"Usage: /tumble_set_spawn <arena_id> <slot 1-8>")
            return
        end
        local slot = tonumber(slot_s)
        if not slot or slot<1 or slot>8 then
            msg(name,"Slot must be 1..8")
            return
        end
        local p = minetest.get_player_by_name(name); if not p then return end
        local pos = vector.round(p:get_pos())
        local arena = get_or_create_arena(aid)
        arena.tumble_spawn_points = arena.tumble_spawn_points or {}
        arena.tumble_spawn_points[slot] = pos
        save_config()
        msg(name,"Tumble spawn slot #"..slot.." for '"..aid.."' at "..minetest.pos_to_string(pos))
    end
})

-- Add a multi-block layer – max 3 layers, Y clamped between 6 and -30
minetest.register_chatcommand("tumble_add_layer", {
    privs = { server = true },
    params = "<arena_id> <y> <radius> <node1,node2,...>",
    description = "Add a Tumble spleef layer with a mixed block palette.",
    func = function(name, param)
        local aid, y_s, r_s, list = param:match("^(%S+)%s+(%S+)%s+(%S+)%s+(.+)$")
        if not aid or not y_s or not r_s or not list then
            msg(name, "Usage: /tumble_add_layer <arena_id> <y> <radius> <node1,node2,...>")
            return
        end

        local y = tonumber(y_s)
        local radius = tonumber(r_s)
        if not y or not radius or radius <= 0 then
            msg(name, "y must be a number, radius must be > 0")
            return
        end

        local original_y = y
        if y > 6 then y = 6 end
        if y < -30 then y = -30 end
        if y ~= original_y then
            msg(name, ("Layer Y clamped from %d to %d (allowed range: 6..-30)."):format(original_y, y))
        end

        local palette = {}
for node in list:gmatch("([^,]+)") do
    node = node:match("^%s*(.-)%s*$") -- trim
    if node ~= "" then
        table.insert(palette, node)
    end
end
if #palette == 0 then
    msg(name, "You must specify at least one node name.")
    return
end

-- NEW: validate against registered nodes
local reg = minetest.registered_nodes
local valid_palette = {}
for _, nodename in ipairs(palette) do
    if reg[nodename] then
        table.insert(valid_palette, nodename)
    else
        msg(name, "Warning: unknown node '" .. nodename .. "' – it will be ignored.")
    end
end

if #valid_palette == 0 then
    msg(name, "No valid node names found in palette after validation.")
    return
end

palette = valid_palette

        local arena = get_or_create_arena(aid)
        if not arena.center then
            msg(name, "Arena '" .. aid .. "' needs a center first (use /battle_set_center).")
            return
        end

        arena.tumble_layers = arena.tumble_layers or {}

        if #arena.tumble_layers >= 3 then
            msg(name, ("Arena '%s' already has 3 layers. Use /tumble_clear_layers or /tumble_undo_layers first."):format(aid))
            return
        end

        backup_tumble_layers(aid, arena)

        table.insert(arena.tumble_layers, {
            y = y,
            radius = radius,
            palette = palette,
        })
        save_config()

        msg(name, ("Added Tumble layer to '%s': y=%d, radius=%d, palette={%s}")
            :format(aid, y, radius, table.concat(palette, ", ")))

        build_tumble_layers_for_arena(arena)
    end,
})

-- Clear all layers
minetest.register_chatcommand("tumble_clear_layers", {
    privs = { server = true },
    params = "<arena_id>",
    description = "Remove all Tumble spleef layers for an arena.",
    func = function(name, param)
        local aid = param ~= "" and param or nil
        if not aid then
            msg(name, "Usage: /tumble_clear_layers <arena_id>")
            return
        end

        local arena = config.arenas[aid]
        if not arena then
            msg(name, "Arena '" .. aid .. "' not found.")
            return
        end

        arena.tumble_layers = arena.tumble_layers or {}

        backup_tumble_layers(aid, arena)

        arena.tumble_layers = {}
        save_config()
        msg(name, "Cleared all Tumble layers for arena '" .. aid .. "'.")
    end,
})

-- Undo last layer change
minetest.register_chatcommand("tumble_undo_layers", {
    privs = { server = true },
    params = "<arena_id>",
    description = "Undo the last Tumble layer edit for an arena.",
    func = function(name, param)
        local aid = param ~= "" and param or nil
        if not aid then
            msg(name, "Usage: /tumble_undo_layers <arena_id>")
            return
        end

        local arena = config.arenas[aid]
        if not arena then
            msg(name, "Arena '" .. aid .. "' not found.")
            return
        end

        local prev = tumble_layers_history[aid]
        if not prev then
            msg(name, "No previous Tumble layer state stored for '" .. aid .. "'.")
            return
        end

        arena.tumble_layers = deepcopy(prev)
        save_config()

        msg(name, "Undid last Tumble layer change for arena '" .. aid .. "'.")
        build_tumble_layers_for_arena(arena)
    end,
})

------------------------------------------------------------
-- UNKNOWN NODE CLEANER
------------------------------------------------------------

local function battle_clean_unknown_in_arena(aid, replacement)
    local arena = config.arenas[aid]
    if not arena or not arena.center or not arena.radius then
        return false, "Arena has no center/radius set."
    end

    local rep_def = minetest.registered_nodes[replacement]
    if not rep_def then
        return false, "Replacement node '"..replacement.."' is not registered."
    end

    local c_rep = minetest.get_content_id(replacement)

    local r = arena.radius
    local y_min = -64
    local y_max = 64

    local minp = {x = arena.center.x - r, y = y_min, z = arena.center.z - r}
    local maxp = {x = arena.center.x + r, y = y_max, z = arena.center.z + r}

    local vm = minetest.get_voxel_manip()
    local emin, emax = vm:read_from_map(minp, maxp)
    local data = vm:get_data()
    local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})

    local reg_nodes = minetest.registered_nodes
    local changed = 0

    for z = emin.z, emax.z do
        for y = emin.y, emax.y do
            for x = emin.x, emax.x do
                local vi = area:index(x,y,z)
                local cid = data[vi]
                local name = minetest.get_name_from_content_id(cid)
                if not reg_nodes[name] or name == "unknown:unknown" then
                    data[vi] = c_rep
                    changed = changed + 1
                end
            end
        end
    end

    if changed > 0 then
        vm:set_data(data)
        vm:write_to_map(true)
        vm:update_map()
    end

    return true, changed
end

minetest.register_chatcommand("battle_clean_unknown", {
    privs = { server = true },
    params = "<arena_id> <replacement_node>",
    description = "Replace unknown nodes in arena radius with a replacement node.",
    func = function(name, param)
        local aid, rep = param:match("^(%S+)%s+(%S+)$")
        if not aid or not rep then
            msg(name, "Usage: /battle_clean_unknown <arena_id> <replacement_node>")
            return
        end

        local ok, changed_or_err = battle_clean_unknown_in_arena(aid, rep)
        if not ok then
            msg(name, "Error: "..changed_or_err)
            return
        end

        msg(name, ("Replaced %d unknown nodes in arena '%s' with '%s'.")
            :format(changed_or_err, aid, rep))
    end,
})

------------------------------------------------------------
-- SNOWBALL OVERRIDE: TUMBLE BLOCK BREAKING
------------------------------------------------------------

-- Nodes that snowballs can break (Mineclonia IDs)
local SNOWBALL_BREAKABLE = {
    -- Glass / Ice
    ["mcl_core:glass"] = true,
    ["mcl_core:glass_black"] = true, -- obsidian-like black glass
    ["mcl_core:packed_ice"] = true,
    ["mcl_core:ice"] = true,

    -- Dirt / Grass
    ["mcl_core:dirt"] = true,
    ["mcl_core:dirt_with_grass"] = true,
    ["mcl_core:dirt_with_grass_dry"] = true,
    ["mcl_core:dirt_with_rainforest_litter"] = true,
    ["mcl_core:dirt_with_coniferous_litter"] = true,

    -- Sand / Gravel / Clay
    ["mcl_core:sand"] = true,
    ["mcl_core:red_sand"] = true,
    ["mcl_core:silver_sand"] = true, -- if present
    ["mcl_core:gravel"] = true,
    ["mcl_core:clay"] = true,

    -- Snow
    ["mcl_core:snow"] = true,
    ["mcl_core:snowblock"] = true,
}

-- Configuration
local config = {
    break_chance = 1.0,                 -- 100% chance to break blocks
    break_radius = 0,                   -- 0 = just the hit node
    enable_particles = true,
    break_sound = "default_break_glass", -- change to a Mineclonia sound if you like
}

--------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------

local function break_node_at(pos)
    local node = minetest.get_node(pos)
    local def = minetest.registered_nodes[node.name]
    if not def then
        return false
    end

    if not SNOWBALL_BREAKABLE[node.name] then
        return false
    end

    -- Chance to break
    if math.random() > config.break_chance then
        return false
    end

    minetest.remove_node(pos)

    if config.break_sound then
        minetest.sound_play(config.break_sound, {
            pos = pos,
            gain = 0.5,
            max_hear_distance = 16,
        })
    end

    if config.enable_particles then
        minetest.add_particlespawner({
            amount = 8,
            time = 0.1,
            minpos = {x = pos.x - 0.5, y = pos.y - 0.5, z = pos.z - 0.5},
            maxpos = {x = pos.x + 0.5, y = pos.y + 0.5, z = pos.z + 0.5},
            minvel = {x = -2, y = -2, z = -2},
            maxvel = {x = 2, y = 2, z = 2},
            minacc = {x = 0, y = -9.81, z = 0},
            maxacc = {x = 0, y = -9.81, z = 0},
            minexptime = 0.5,
            maxexptime = 1.0,
            minsize = 0.5,
            maxsize = 1.0,
            collisiondetection = true,
            texture = "default_item_smoke.png", -- swap to a Mineclonia texture if you want
        })
    end

    return true
end

local function break_nodes_around(pos)
    local r = math.floor(config.break_radius or 0)
    local broke_any = false

    if r <= 0 then
        return break_node_at(pos)
    end

    for dx = -r, r do
        for dy = -r, r do
            for dz = -r, r do
                local p = { x = pos.x + dx, y = pos.y + dy, z = pos.z + dz }
                if break_node_at(p) then
                    broke_any = true
                end
            end
        end
    end

    return broke_any
end

--------------------------------------------------------------------
-- This is what battle_lobby calls in on_mods_loaded
--------------------------------------------------------------------

-- MUST be global so the callback can see it
function patch_snowball_for_tumble()
    -- Try Mineclonia's snowball entity name(s)
    local snowball_def =
        minetest.registered_entities["mcl_throwing:snowball"]
        or minetest.registered_entities["mcl_throwing:snowball_entity"]

    if not snowball_def then
        minetest.log("error",
            "[battle_lobby] Snowball entity not found; Tumble snowball patch skipped.")
        return
    end

    -- Avoid double patching
    if snowball_def._battle_lobby_snowball_patched then
        return
    end
    snowball_def._battle_lobby_snowball_patched = true

    local old_on_step = snowball_def.on_step

    snowball_def.on_step = function(self, dtime, moveresult)
        -- Call original behavior first to keep Mineclonia logic
        if old_on_step then
            -- Extra arg is harmless if the original only accepts (self, dtime)
            old_on_step(self, dtime, moveresult)
        end

        -- If the snowball was removed by original logic, bail
        if not self.object or not self.object:get_pos() then
            return
        end

        -- Use moveresult collisions from Luanti 5.14
        if not (moveresult and moveresult.collisions) then
            return
        end

        for _, collision in ipairs(moveresult.collisions) do
            if collision.type == "node" and collision.node_pos then
                local hit_pos = collision.node_pos

                -- Try breaking the node (or nodes in radius)
                if break_nodes_around(hit_pos) then
                    -- Remove snowball only if we actually broke something
                    self.object:remove()
                    return
                end
            end
        end
    end

    minetest.log("action",
        "[battle_lobby] Snowball entity patched for Tumble (block breaking enabled).")
end

--------------------------------------------------------------------
-- Chat command to toggle behaviour
--------------------------------------------------------------------

minetest.register_chatcommand("snowball_break", {
    params = "<on|off|list>",
    description = "Control snowball block breaking",
    func = function(name, param)
        if param == "on" then
            config.break_chance = 1.0
            return true, "Snowball block breaking enabled"
        elseif param == "off" then
            config.break_chance = 0.0
            return true, "Snowball block breaking disabled"
        elseif param == "list" then
            local count = 0
            for _ in pairs(SNOWBALL_BREAKABLE) do
                count = count + 1
            end
            return true, "Snowballs can break " .. count .. " different block types"
        else
            return false, "Usage: /snowball_break <on|off|list>"
        end
    end
})

minetest.log("action",
    "[battle_lobby] Snowball breaker logic loaded (waiting for patch_snowball_for_tumble()).")

minetest.register_chatcommand("remove_unknown", {
    params = "<radius>",
    description = "Remove unknown nodes in a cube around you (admin only).",
    privs = { server = true },
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "Player not found."
        end

        local r = tonumber(param)
        if not r or r <= 0 then
            return false, "Usage: /remove_unknown <radius> (positive number)"
        end

        -- Clamp radius a bit so you don't accidentally nuke half the map
        if r > 50 then
            r = 50
            minetest.chat_send_player(name, "Radius clamped to 50 to avoid lag.")
        end

        local pos = vector.round(player:get_pos())
        local minp = vector.subtract(pos, r)
        local maxp = vector.add(pos, r)

        local t0 = minetest.get_us_time()

        local vm = minetest.get_voxel_manip()
        local emin, emax = vm:read_from_map(minp, maxp)
        local area = VoxelArea:new{ MinEdge = emin, MaxEdge = emax }
        local data = vm:get_data()

        local c_air = minetest.get_content_id("air")

        local removed = 0
        local seen_ids = {}

        for vi in area:iter(emin.x, emin.y, emin.z, emax.x, emax.y, emax.z) do
            local cid = data[vi]

            -- Cache lookups by content ID
            local info = seen_ids[cid]
            if info == nil then
                local nname = minetest.get_name_from_content_id(cid)
                -- unknown if no name OR not registered as a node
                if not nname or not minetest.registered_nodes[nname] then
                    info = "unknown"
                else
                    info = "ok"
                end
                seen_ids[cid] = info
            end

            if info == "unknown" then
                data[vi] = c_air
                removed = removed + 1
            end
        end

        vm:set_data(data)
        vm:write_to_map()
        vm:update_map()

        local dt = (minetest.get_us_time() - t0) / 1e6
        minetest.chat_send_player(name,
            ("Removed %d unknown nodes in radius %d (%.2f s)")
            :format(removed, r, dt))

        return true
    end,
})

minetest.register_chatcommand("tumble_remove_layer", {
    privs = { server = true },
    params = "<arena_id> <index>",
    description = "Remove a single Tumble layer by index (1 = first layer).",
    func = function(name, param)
        local aid, idx_s = param:match("^(%S+)%s+(%S+)$")
        if not aid or not idx_s then
            msg(name, "Usage: /tumble_remove_layer <arena_id> <index>")
            return
        end

        local idx = tonumber(idx_s)
        if not idx or idx < 1 then
            msg(name, "Index must be a positive number (1 = first layer).")
            return
        end

        local arena = config.arenas[aid]
        if not arena or not arena.tumble_layers then
            msg(name, "Arena '" .. aid .. "' has no Tumble layers.")
            return
        end

        if idx > #arena.tumble_layers then
            msg(name, ("Arena '%s' only has %d layer(s)."):format(aid, #arena.tumble_layers))
            return
        end

        backup_tumble_layers(aid, arena) -- use the existing backup

        local removed = table.remove(arena.tumble_layers, idx)
        save_config()

        msg(name, ("Removed layer #%d from '%s' (y=%s, radius=%s).")
            :format(idx, aid, tostring(removed.y), tostring(removed.radius)))

        build_tumble_layers_for_arena(arena)
    end,
})

------------------------------------------------------------
-- MODS LOADED PATCHES: CHESTS + SNOWBALL
------------------------------------------------------------

minetest.register_on_mods_loaded(function()
    override_chest_for_battle("mcl_chests:chest")
    override_chest_for_battle("mcl_chests:trapped_chest")
    patch_snowball_for_tumble()
end)

minetest.register_alias("default:pine_wood", "mcl_trees:wood_spruce")
-- Stairs
minetest.register_alias("stairs:stair_pine_wood", "mcl_stairs:stair_spruce")
minetest.register_alias("stairs:stair_pine_tree", "mcl_stairs:stair_log_spruce") -- if present

-- Slabs
minetest.register_alias("stairs:slab_pine_wood", "mcl_stairs:slab_spruce")
minetest.register_alias("stairs:slab_pine_tree", "mcl_stairs:slab_spruce_bark") -- if present
--minetest.register_alias("default:mese", "mcl_redstone_torch:redstoneblock") -- if present
minetest.register_alias("walls:cobble", "mcl_walls:cobble") -- if present

-- Convert Minetest Game lava to Mineclonia lava
minetest.register_alias("default:lava_source", "mcl_core:lava_source")
minetest.register_alias("default:lava_flowing", "mcl_core:lava_flowing")

minetest.register_alias("nether:brick", "mcl_nether:nether_brick")
minetest.register_alias("default:fence_wood", "mcl_fences:oak_fence")
minetest.register_alias("default:fence_pine_wood", "mcl_fences:spruce_fence")
minetest.register_alias("default:fence_rail_pine_wood", "mcl_fences:spruce_fence_gate")

minetest.register_alias("xdecor:stone_rune", "mcl_core:stonebrickcarved")
minetest.register_alias("xdecor:stone_tile", "mcl_core:stone_smooth")
