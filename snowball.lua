--------------------------------------------------------------------
-- SNOWBALL DEBUG: ALWAYS BREAK BLOCKS
-- Once this works, we can restrict it to Tumble only.
--------------------------------------------------------------------

-- Helper: actually break a block (instant, no drops)
local function battle_lobby_break_any_block(pos)
    if not pos then return end

    -- Check both current pos and slightly below to catch floor
    local candidates = {
        vector.round(pos),
        vector.round({ x = pos.x, y = pos.y - 0.3, z = pos.z }),
    }

    for _, p in ipairs(candidates) do
        local node = minetest.get_node(p)
        if node and node.name ~= "air" and node.name ~= "ignore" then
            if node.name == "mcl_core:bedrock" then
                -- don't break bedrock
                return
            end

            minetest.remove_node(p)
            minetest.log("action", "[battle_lobby] Snowball broke "
                .. node.name .. " at " .. minetest.pos_to_string(p))
            return
        end
    end
end

--------------------------------------------------------------------
-- Our own snowball entity that ALWAYS breaks blocks it hits
--------------------------------------------------------------------
minetest.register_entity("battle_lobby:snowball_breaker", {
    initial_properties = {
        physical = true,
        collide_with_objects = false,
        collisionbox = {-0.1, -0.1, -0.1, 0.1, 0.1, 0.1},
        visual = "sprite",
        visual_size = {x = 0.5, y = 0.5},
        textures = {"mcl_throwing_snowball.png"}, -- Mineclonia texture
        pointable = false,
    },

    _life = 0,

    on_step = function(self, dtime, moveresult)
        self._life = self._life + dtime
        if self._life > 5 then
            self.object:remove()
            return
        end

        local pos = self.object:get_pos()
        if not pos then return end

        -- If the engine gives us collisions, prefer those
        if moveresult and moveresult.collisions and #moveresult.collisions > 0 then
            for _, col in ipairs(moveresult.collisions) do
                if col.type == "node" and col.node_pos then
                    battle_lobby_break_any_block(col.node_pos)
                    self.object:remove()
                    return
                end
            end
        end

        -- Fallback: check node at/under current position
        battle_lobby_break_any_block(pos)
        -- If it broke something, that function already removed it;
        -- but it's safe to just remove the snowball now.
        self.object:remove()
    end,
})

--------------------------------------------------------------------
-- Override the snowball item to use OUR entity for now
--------------------------------------------------------------------
local function battle_lobby_override_snowball_item_debug()
    local snowball_name = "mcl_throwing:snowball"
    local def = minetest.registered_items[snowball_name]
    if not def then
        minetest.log("warning", "[battle_lobby] Could not find snowball item: "
            .. snowball_name)
        return
    end

    local old_on_use = def.on_use

    minetest.override_item(snowball_name, {
        on_use = function(itemstack, user, pointed_thing)
            -- DEBUG VERSION: always use our projectile, everywhere
            if user and user:is_player() then
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
                end

                return itemstack
            end

            -- fallback: if something weird, use original
            if old_on_use then
                return old_on_use(itemstack, user, pointed_thing)
            end
            return itemstack
        end
    })

    minetest.log("action", "[battle_lobby] DEBUG override: mcl_throwing:snowball now uses battle_lobby:snowball_breaker")
end

minetest.register_on_mods_loaded(function()
    battle_lobby_override_snowball_item_debug()
end)
