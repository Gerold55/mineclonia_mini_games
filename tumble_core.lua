-- battle_lobby/tumble_core.lua

local bl = battle_lobby
local tumble = bl.tumble

--------------------------------------------------------------------
-- OVERRIDE SNOWBALL ITEM FOR TUMBLE
--------------------------------------------------------------------
local function battle_lobby_override_snowball()
    local snowball_name = "mcl_throwing:snowball" -- adjust if different

    local def = minetest.registered_items[snowball_name]
    if not def then
        minetest.log("warning", "[battle_lobby] snowball item not found: " .. snowball_name)
        return
    end

    local old_on_use = def.on_use

    minetest.override_item(snowball_name, {
        on_use = function(itemstack, user, pointed_thing)
            if user and user:is_player() and tumble and tumble.state == "running" then
                local name = user:get_player_name()
                if name and tumble.players and tumble.players[name] then
                    -- Spawn our custom Tumble snowball instead of default behavior
                    local pos = user:get_pos()
                    local dir = user:get_look_dir()
                    if not pos or not dir then
                        return itemstack
                    end

                    -- Spawn slightly above player eyes
                    pos = vector.new(pos)
                    pos.y = pos.y + 1.5

                    local obj = minetest.add_entity(pos, "battle_lobby:snowball_tumble")
                    if obj then
                        local vel = vector.multiply(dir, 20)  -- tweak speed if needed
                        obj:set_velocity(vel)
                        obj:set_acceleration({x = 0, y = -9.8, z = 0})

                        local lua = obj:get_luaentity()
                        if lua then
                            lua._thrower = name
                        end

                        itemstack:take_item(1)
                    end

                    return itemstack
                end
            end

            -- Not in Tumble / not a Tumble player? Fallback to original behavior.
            if old_on_use then
                return old_on_use(itemstack, user, pointed_thing)
            end

            return itemstack
        end
    })

    minetest.log("action", "[battle_lobby] Overrode snowball item for Tumble behavior.")
end

--------------------------------------------------------------------
-- CUSTOM TUMBLE SNOWBALL ENTITY
--------------------------------------------------------------------
minetest.register_entity("battle_lobby:snowball_tumble", {
    initial_properties = {
        physical = true,
        collide_with_objects = false,
        collisionbox = {-0.1, -0.1, -0.1, 0.1, 0.1, 0.1},
        visual = "sprite",
        visual_size = {x = 0.5, y = 0.5},
        textures = {"mcl_throwing_snowball.png"}, -- Mineclonia texture
        pointable = false,
    },

    _thrower = nil,
    _life = 0,          -- lifetime in seconds

    on_step = function(self, dtime, moveresult)
        self._life = self._life + dtime
        if self._life > 5 then
            -- safety: snowball disappears after 5s
            self.object:remove()
            return
        end

        -- Only do special behavior while Tumble is running
        if not tumble or tumble.state ~= "running" then
            return
        end

        local thrower_name = self._thrower
        if not thrower_name or not (tumble.players and tumble.players[thrower_name]) then
            return
        end

        local pos = self.object:get_pos()
        if not pos then return end

        -- Round to node grid and check node
        local npos = vector.round(pos)
        local node = minetest.get_node(npos)
        if not node or node.name == "air" or node.name == "ignore" then
            return
        end

        -- You can restrict this if you only want floor blocks, but this version
        -- breaks *any* solid block (like console Tumble where floor is soft)
        if node.name == "mcl_core:bedrock" then
            return -- don't break bedrock
        end

        local def = minetest.registered_nodes[node.name]
        if not def then return end

        if def.walkable then
            -- Force break – use remove_node so literally anything goes
            -- (no drops, just like Tumble)
            minetest.remove_node(npos)

            -- Optional: particle effect / sound here if you want
            -- minetest.sound_play("default_dig_crumbly", {pos = npos, gain = 0.5})

            self.object:remove()
        end
    end,
})

--------------------------------------------------
-- JOIN / LEAVE
--------------------------------------------------

minetest.register_chatcommand("tumble_join", {
    description = "Join Tumble queue.",
    func = function(name)
        for _,n in ipairs(tumble.queue) do
            if n == name then return end
        end
        table.insert(tumble.queue, name)
        msg(name, "You joined the Tumble queue.")
        bl.broadcast(name .. " joined Tumble (" .. #tumble.queue .. " in queue).")
    end,
})

minetest.register_chatcommand("tumble_leave", {
    description = "Leave Tumble queue or match.",
    func = function(name)
        for i,n in ipairs(tumble.queue) do
            if n == name then
                table.remove(tumble.queue, i)
                msg(name, "You left the Tumble queue.")
                return
            end
        end
        if tumble.players[name] then
            tumble.players[name] = nil
            tumble.alive[name] = nil
            msg(name, "You left the Tumble match.")
        end
    end,
})

-- TODO: move your Tumble arena layer generation, snowball instabreak,
--       and spawn handling into this file.
