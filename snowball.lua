--------------------------------------------------------------------
-- SNOWBALL BREAKER: ALWAYS BREAKS THE BLOCK IT HITS
-- (Debug version to prove it works; we can later restrict to Tumble)
--------------------------------------------------------------------

--------------------------------------------------------------------
-- Helper: break exactly one block (pointed target)
--------------------------------------------------------------------
local function battle_lobby_break_pointed_block(pos)
    if not pos then return end

    local p = {
        x = math.floor(pos.x + 0.5),
        y = math.floor(pos.y + 0.5),
        z = math.floor(pos.z + 0.5),
    }

    local node = minetest.get_node(p)
    if not node or node.name == "air" or node.name == "ignore" then
        return
    end

    -- Don't break bedrock (or add more unbreakables here)
    if node.name == "mcl_core:bedrock" then
        return
    end

    minetest.remove_node(p)

    minetest.log("action",
        "[battle_lobby] snowball_breaker broke pointed " ..
        node.name .. " at " .. minetest.pos_to_string(p))
end

-- Helper: actually break a block (instant, no drops)
local function battle_lobby_break_any_block(pos)
    if not pos then return end

    -- Check node just below the snowball (floor)
    local p = {
        x = math.floor(pos.x + 0.5),
        y = math.floor(pos.y - 0.5),
        z = math.floor(pos.z + 0.5),
    }

    local node = minetest.get_node(p)
    if not node or node.name == "air" or node.name == "ignore" then
        return
    end

    -- Don't break bedrock
    if node.name == "mcl_core:bedrock" then
        return
    end

    -- Instant break; no drops
    minetest.remove_node(p)
    minetest.log("action",
        "[battle_lobby] snowball_breaker broke " ..
        node.name .. " at " .. minetest.pos_to_string(p))
end

--------------------------------------------------------------------
-- Our own snowball entity
--------------------------------------------------------------------
minetest.register_entity("battle_lobby:snowball_breaker", {
    initial_properties = {
        physical = false,              -- let it fly through, we'll sample below
        collide_with_objects = false,
        collisionbox = {-0.1,-0.1,-0.1, 0.1,0.1,0.1},
        visual = "sprite",
        visual_size = {x = 0.5, y = 0.5},
        textures = {"mcl_throwing_snowball.png"}, -- Mineclonia snowball tex
        pointable = false,
    },

    _life = 0,

    -- IMPORTANT: simple on_step signature (self, dtime)
    on_step = function(self, dtime)
        self._life = self._life + dtime
        if self._life > 5 then
            self.object:remove()
            return
        end

        local pos = self.object:get_pos()
        if not pos then return end

        -- Try to break block under us
        battle_lobby_break_any_block(pos)
    end,
})

--------------------------------------------------------------------
-- Override Mineclonia snowball item to use our entity
--------------------------------------------------------------------
local function battle_lobby_override_snowball_item_debug()
    local snowball_name = "mcl_throwing:snowball"
    local def = minetest.registered_items[snowball_name]
    if not def then
        minetest.log("warning",
            "[battle_lobby] Could not find snowball item: " .. snowball_name)
        return
    end

    local old_on_use = def.on_use

    minetest.override_item(snowball_name, {
        on_use = function(itemstack, user, pointed_thing)
            if user and user:is_player() then
                local name = user:get_player_name() or "?"
                minetest.chat_send_player(name,
                    "[battle_lobby] DEBUG: snowball on_use override called")

                local pos = user:get_pos()
                local dir = user:get_look_dir()
                if not pos or not dir then
                    return itemstack
                end

                pos = vector.new(pos)
                pos.y = pos.y + 1.5

                local obj = minetest.add_entity(pos, "battle_lobby:snowball_breaker")
                if obj then
                    local vel = vector.multiply(dir, 20)
                    obj:set_velocity(vel)
                    obj:set_acceleration({x = 0, y = -9.8, z = 0})
                    itemstack:take_item(1)
                else
                    minetest.chat_send_player(name,
                        "[battle_lobby] DEBUG: failed to spawn snowball_breaker")
                end

                return itemstack
            end

            -- Fallback to original if somehow not a player
            if old_on_use then
                return old_on_use(itemstack, user, pointed_thing)
            end
            return itemstack
        end
    })

    minetest.log("action",
        "[battle_lobby] DEBUG: mcl_throwing:snowball now uses battle_lobby:snowball_breaker")
end

--------------------------------------------------------------------
-- Ensure override runs *after* all mods (and Mineclonia) loaded
--------------------------------------------------------------------
minetest.register_on_mods_loaded(function()
    battle_lobby_override_snowball_item_debug()
end)

--------------------------------------------------------------------
-- Extra debug: command to spawn the snowball entity at your feet
--------------------------------------------------------------------
minetest.register_chatcommand("tumble_debug_spawn_snowball", {
    privs = { server = true },
    description = "Spawn a battle_lobby:snowball_breaker at your position.",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return end

        local pos = player:get_pos()
        pos.y = pos.y + 1.5
        local obj = minetest.add_entity(pos, "battle_lobby:snowball_breaker")
        if obj then
            obj:set_velocity({x=0, y=0, z=0})
            minetest.chat_send_player(name,
                "[battle_lobby] DEBUG: spawned snowball_breaker at your feet.")
        else
            minetest.chat_send_player(name,
                "[battle_lobby] DEBUG: FAILED to spawn snowball_breaker.")
        end
    end,
})
