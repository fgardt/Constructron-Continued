require("util")

local chunk_util = require("script/chunk_util")
local debug_lib = require("script/debug_lib")
local color_lib = require("script/color_lib")

local me = {}

me.pathfinder = {
    -- just a template, check pathfinder.lua for implementation
    request_path = (function(_,_,_,_) end)
}

me.ensure_globals = function()
    global.registered_entities = global.registered_entities or {}
    global.constructron_statuses = global.constructron_statuses or {}
    global.ignored_entities = {}
    global.allowed_items = {}
    global.stack_cache = {}

    global.ghost_entities = global.ghost_entities or {}
    global.deconstruction_entities = global.deconstruction_entities or {}
    global.upgrade_entities = global.upgrade_entities or {}
    global.repair_entities = global.repair_entities or {}

    global.construct_queue = global.construct_queue or {}
    global.deconstruct_queue = global.deconstruct_queue or {}
    global.upgrade_queue = global.upgrade_queue or {}
    global.repair_queue = global.repair_queue or {}

    global.job_bundles = global.job_bundles or {}

    global.constructrons = global.constructrons or {}
    global.service_stations = global.service_stations or {}

    global.constructrons_count = global.constructrons_count or {}
    global.stations_count = global.stations_count or {}

    for s, surface in pairs(game.surfaces) do
        global.constructrons_count[surface.index] = global.constructrons_count[surface.index] or 0
        global.stations_count[surface.index] = global.stations_count[surface.index] or 0
        global.construct_queue[surface.index] = global.construct_queue[surface.index] or {}
        global.deconstruct_queue[surface.index] = global.deconstruct_queue[surface.index] or {}
        global.upgrade_queue[surface.index] = global.upgrade_queue[surface.index] or {}
        global.repair_queue[surface.index] = global.repair_queue[surface.index] or {}
    end

    -- settings
    global.construction_job_toggle = settings.global["construct_jobs"].value
    global.rebuild_job_toggle = settings.global["rebuild_jobs"].value
    global.deconstruction_job_toggle = settings.global["deconstruct_jobs"].value
    global.ground_decon_job_toggle = settings.global["decon_ground_items"].value
    global.upgrade_job_toggle = settings.global["upgrade_jobs"].value
    global.repair_job_toggle = settings.global["repair_jobs"].value
    global.debug_toggle = settings.global["constructron-debug-enabled"].value
    global.landfill_job_toggle = settings.global["allow_landfill"].value
    global.job_start_delay = (settings.global["job-start-delay"].value * 60)
    global.desired_robot_count = settings.global["desired_robot_count"].value
    global.desired_robot_name = settings.global["desired_robot_name"].value
    global.max_worker_per_job = 1
    global.construction_mat_alert = (settings.global["construction_mat_alert"].value * 60)
    global.max_jobtime = (settings.global["max-jobtime-per-job"].value * 60 * 60)
    global.entities_per_tick = settings.global["entities_per_tick"].value
    global.clear_robots_when_idle = settings.global["clear_robots_when_idle"].value
end

me.get_service_stations = function(index)
    local stations_on_surface = {}
    for s, station in pairs(global.service_stations) do
        if station and station.valid then
            if (index == station.surface.index) then
                stations_on_surface[station.unit_number] = station
            end
        else
            global.service_stations[s] = nil
        end
    end
    return stations_on_surface or {}
end

--- Unused Function
-- Explain ...
-- me.get_constructrons = function()
--     local constructrons_on_surface = {}
--     for c, constructron in pairs(global.constructrons) do
--         if constructron and constructron.valid then
--             table.insert(constructrons_on_surface, constructron)
--         else
--             global.constructrons[c] = nil
--         end
--     end
--     return constructrons_on_surface
-- end

me.constructrons_need_reload = function(constructrons)
    for c, constructron in ipairs(constructrons) do
        if not constructron.valid then
            return
        end
        local trunk_inventory = constructron.get_inventory(defines.inventory.spider_trunk)
        local trunk = {}
        for i = 1, #trunk_inventory do
            local item = trunk_inventory[i]
            if item.valid_for_read then
                trunk[item.name] = (trunk[item.name] or 0) + item.count
            end
        end
        for i = 1, constructron.request_slot_count do
            local request = constructron.get_vehicle_logistic_slot(i)
            if request then
                if not (((trunk[request.name] or 0) >= request.min) and ((trunk[request.name] or 0) <= request.max)) then
                    return true
                end
            end
        end
    end
    return false
end

me.calculate_required_inventory_slot_count = function(required_items, divisor)
    local slots = 0
    local stack_size

    for name, count in pairs(required_items) do
        if not global.stack_cache[name] then
            stack_size = game.item_prototypes[name].stack_size
            global.stack_cache[name] = stack_size
        else
            stack_size = global.stack_cache[name]
        end
        slots = slots + math.ceil(count / stack_size / divisor)
    end
    return slots
end


---@param item_name string
---return boolean
me.check_item_allowed = function(item_name)
    if not global.allowed_items[item_name] then
        if not game.item_prototypes[item_name].has_flag("hidden") then
            global.allowed_items[item_name] = true
            return true
        end
        local recipes = game.get_filtered_recipe_prototypes(
            {
                {filter = "has-product-item", elem_filters = {{filter = "name", name = item_name}}, mode = "and"}
            }
        )
        for _ , recipe in pairs(recipes) do
            -- !! refactor force call
            if game.forces["player"].recipes[recipe.name].enabled and not game.forces["player"].recipes[recipe.name].hidden then
                global.allowed_items[item_name] = true
                return true
            end
        end
        global.allowed_items[item_name] = false
        return false
    else
        return true
    end
end

me.process_entity = function(entity, target_entity, build_type, queue)
    local chunk = chunk_util.chunk_from_position(entity.position)
    local key = chunk.y .. ',' .. chunk.x
    local entity_surface = entity.surface.index
    local entity_pos_y = entity.position.y
    local entity_pos_x = entity.position.x
    -- local entity_key = entity_pos_y .. ',' .. entity_pos_x

    queue[entity_surface] = queue[entity_surface] or {}

    local queue_surface_key = queue[entity_surface][key]

    if not queue_surface_key then -- initialize queued_chunk
        queue_surface_key = {
            key = key,
            surface = entity.surface.index,
            -- entity_key = entity,
            force = entity.force.name,
            position = chunk_util.position_from_chunk(chunk),
            area = chunk_util.get_area_from_chunk(chunk),
            minimum = {
                x = entity_pos_x,
                y = entity_pos_y
            },
            maximum = {
                x = entity_pos_x,
                y = entity_pos_y
            },
            required_items = {},
            trash_items = {}
        }
    else -- add to existing queued_chunk
        -- queue_surface_key[entity_key] = entity
        if entity_pos_x < queue_surface_key['minimum'].x then
            queue_surface_key['minimum'].x = entity_pos_x
        elseif entity_pos_x > queue_surface_key['maximum'].x then
            queue_surface_key['maximum'].x = entity_pos_x
        end
        if entity_pos_y < queue_surface_key['minimum'].y then
            queue_surface_key['minimum'].y = entity_pos_y
        elseif entity_pos_y > queue_surface_key['maximum'].y then
            queue_surface_key['maximum'].y = entity_pos_y
        end
    end
    -- ghosts
    if (build_type == "ghost") and not (entity.type == 'item-request-proxy') then
        for _, item in ipairs(entity.ghost_prototype.items_to_place_this) do
            if me.check_item_allowed(item.name) then
                queue_surface_key['required_items'][item.name] = (queue_surface_key['required_items'][item.name] or 0) + item.count
            end
        end
    end
    -- module-requests
    if (build_type ~= "deconstruction") and (entity.type == 'entity-ghost' or entity.type == 'item-request-proxy') then
        for name, count in pairs(entity.item_requests) do
            if me.check_item_allowed(name) then
                queue_surface_key['required_items'][name] = (queue_surface_key['required_items'][name] or 0) + count
            end
        end
    end
    -- repair
    if (build_type == "repair") then
        queue_surface_key['required_items']['repair-pack'] = (queue_surface_key['required_items']['repair-pack'] or 0) + 3
    end
    -- cliff demolition
    if (build_type == "deconstruction") and entity.type == "cliff" then
            queue_surface_key['required_items']['cliff-explosives'] = (queue_surface_key['required_items']['cliff-explosives'] or 0) + 1
    end
    -- mining/deconstruction results
    if (build_type == "deconstruction") and entity.prototype.mineable_properties.products then
        for _, item in ipairs(entity.prototype.mineable_properties.products) do
            local amount = item.amount or item.amount_max
            if me.check_item_allowed(item.name) then
                queue_surface_key['trash_items'][item.name] = (queue_surface_key['trash_items'][item.name] or 0) + amount
            end
        end
    end
    -- entity upgrades
    if target_entity then
        -- log("target_entity.name" .. serpent.block(target_entity.name))
        -- log("target_entity.items_to_place_this" .. serpent.block(target_entity.items_to_place_this))
        for _, item in ipairs(target_entity.items_to_place_this) do
            if me.check_item_allowed(item.name) then
                queue_surface_key['required_items'][item.name] = (queue_surface_key['required_items'][item.name] or 0) + item.count
            end
        end
    end
    queue[entity_surface][key] = queue_surface_key
end

me.add_entities_to_chunks = function(build_type) -- build_type: deconstruction, upgrade, ghost, repair
    local entities, queue, event_tick
    local entity_counter = 0

    if build_type == "deconstruction" then
        entities = global.deconstruction_entities -- array, call by ref
        queue = global.deconstruct_queue -- array, call by ref
        event_tick = global.deconstruct_marked_tick or 0 -- call by value, it is used as read_only
    elseif build_type == "ghost" then --- =/
        entities = global.ghost_entities -- array, call by ref
        queue = global.construct_queue -- array, call by ref
        event_tick = global.ghost_tick or 0 -- call by value, it is used as read_only
    elseif build_type == "upgrade" then
        entities = global.upgrade_entities -- array, call by ref
        queue = global.upgrade_queue -- array, call by ref
        event_tick = global.upgrade_marked_tick or 0 -- call by value, it is used as read_only
    elseif build_type == "repair" then
        entities = global.repair_entities -- array, call by ref
        queue = global.repair_queue -- array, call by ref
        event_tick = global.repair_marked_tick or 0 -- call by value, it is used as read_only
    end

    if next(entities) and (game.tick - event_tick) > global.job_start_delay then -- if the entity isn't processed in 5 seconds or 300 ticks(default setting).
        for entity_key, entity in pairs(entities) do
            local target_entity

            if build_type == "upgrade" then
                target_entity = entity.target
                entity = entity.entity
                if entity.valid and not entity.to_be_upgraded() then
                    entity = nil
                end
            end

            if build_type == "deconstruction" and entity ~= nil and entity.valid and not entity.to_be_deconstructed() then
                entity = nil
            end

            if entity and entity.valid then
                me.process_entity(entity, target_entity, build_type, queue)
            end

            entities[entity_key] = nil

            if entity_counter >= global.entities_per_tick then
                break
            else
                entity_counter = entity_counter + 1
            end
        end
    end
end

me.robots_active = function(network)
    local cell = network.cells[1]
    local all_construction_robots = network.all_construction_robots
    local stationed_bots = cell.stationed_construction_robot_count
    local charging_robots = cell.charging_robots
    local to_charge_robots = cell.to_charge_robots
    local active_bots = (all_construction_robots) - (stationed_bots)

    if ((active_bots == 0) and not next(charging_robots) and not next(to_charge_robots)) then
        return false -- robots are not active
    else
        return true -- robots are active
    end
end

me.graceful_wrapup = function(job)
    for k, value in pairs(global.job_bundles[job.bundle_index]) do
        if not value.returning_home and not (value.action == "clear_items") and not (value.action == "retire") and not (value.action == "check_build_chunk") and not (value.action == "check_decon_chunk") then
            global.job_bundles[job.bundle_index][k] = nil
        end
    end
    local new_t = {}
    local i = 1
    for _,v in pairs(global.job_bundles[job.bundle_index]) do
        new_t[i] = v
        i = i + 1
    end
    global.job_bundles[job.bundle_index] = new_t
end

me.do_until_leave = function(job)
    -- action is what to do, a function.
    -- action_args is going to be unpacked to action function. first argument of action must be constructron.
    -- leave_condition is a function, leave_args is a table to unpack to leave_condition as arguments
    -- leave_condition should have constructron as first argument

    if job.constructrons[1] then
        if not job.active then
            if (job.action == 'go_to_position') then
                local new_pos_goal = me.actions[job.action](job.constructrons, table.unpack(job.action_args or {}))
                job.leave_args[1] = new_pos_goal
                job.start_tick = game.tick
                job.lastpos = {}
            else
                me.actions[job.action](job.constructrons, table.unpack(job.action_args or {}))
                job.start_tick = game.tick
            end
        end
        local status = me.conditions[job.leave_condition](job.constructrons, table.unpack(job.leave_args or {}))
        if status == true then
            table.remove(global.job_bundles[job.bundle_index], 1)
            -- for c, constructron in ipairs(constructrons) do
            --     table.remove(global.constructron_jobs[constructron.unit_number], 1)
            -- end
            return true -- returning true means you can remove this job from job list
        elseif status == "graceful_wrapup" then
            me.graceful_wrapup(job)
        elseif (job.action == 'go_to_position') and (game.tick - job.start_tick) > 600 then
            for c, constructron in ipairs(job.constructrons) do
                if constructron.valid then
                    if not constructron.autopilot_destination then
                        me.actions[job.action](job.constructrons, table.unpack(job.action_args or {}))
                        job.start_tick = game.tick
                    else -- waypoint orbit & stuck recovery
                        if not job.lastpos[c] then
                            job.lastpos[c] = constructron.position
                        else
                            local lastpos = job.lastpos[c]
                            local distance = chunk_util.distance_between(lastpos, constructron.position)
                            if distance < 5 then
                                me.actions[job.action](job.constructrons, table.unpack(job.action_args or {}))
                                job.start_tick = game.tick
                                job.lastpos[c] = nil
                            else
                                job.start_tick = game.tick
                                job.lastpos[c] = nil
                            end
                        end
                    end
                else
                    job.constructrons[c] = nil
                end
            end
        elseif (job.action == 'request_items') then
            local timer = game.tick - job.start_tick
            if timer > global.construction_mat_alert then
                for k, v in pairs(game.players) do
                    v.add_alert(job.constructrons[1], defines.alert_type.no_material_for_construction)
                end
            end
            if timer > global.max_jobtime and (global.stations_count[(job.constructrons[1].surface.index)] > 0) then
                local closest_station = me.get_closest_service_station(job.constructrons[1])
                for unit_number, station in pairs(job.unused_stations) do
                    if not station.valid then
                        job.unused_stations[unit_number] = nil
                    end
                end
                job.unused_stations[closest_station.unit_number] = nil
                if not (next(job.unused_stations)) then
                    job.unused_stations = me.get_service_stations(job.constructrons[1].surface.index)
                    if not #job.unused_stations == 1 then
                        job.unused_stations[closest_station.unit_number] = nil
                    end
                end
                local next_station = me.get_closest_unused_service_station(job.constructrons[1], job.unused_stations)
                for _, constructron in ipairs(job.constructrons) do
                    me.pathfinder.request_path({constructron}, "constructron_pathing_dummy" , next_station.position)
                end
                job.start_tick = game.tick
                debug_lib.DebugLog('request_items action timed out, moving to new station')
            end
        end
    else
        return true
    end
end

-------------------------------------------------------------------------------
--  Actions
-------------------------------------------------------------------------------

me.actions = {
    go_to_position = function(constructrons, position, find_path)
        debug_lib.DebugLog('ACTION: go_to_position')
        if find_path and constructrons[1].valid then
            return me.pathfinder.request_path(constructrons, "constructron_pathing_dummy" , position)
        else
            for c, constructron in ipairs(constructrons) do
                if constructron.valid then
                    constructron.autopilot_destination = position -- does not use path finder!
                end
            end
        end
    end,
    build = function(constructrons)
        debug_lib.DebugLog('ACTION: build')
        -- I want to enable construction only when in the construction area
        -- however there doesn't seem to be a way to do this with the current api
        -- enable_logistic_while_moving is doing somewhat what I want however I wish there was a way to check
        -- whether or not logistics was enabled. there doesn't seem to be a way.
        -- so I'm counting on robots that they will be triggered in two second or 120 ticks.
        if constructrons[1].valid then
            for c, constructron in ipairs(constructrons) do
                constructron.enable_logistics_while_moving = false
                me.set_constructron_status(constructron, 'build_tick', game.tick)
            end
        else
            return true
        end
        -- enable construct
    end,
    deconstruct = function(constructrons)
        debug_lib.DebugLog('ACTION: deconstruct')
        -- I want to enable construction only when in the construction area
        -- however there doesn't seem to be a way to do this with the current api
        -- enable_logistic_while_moving is doing somewhat what I want however I wish there was a way to check
        -- whether or not logistics was enabled. there doesn't seem to be a way.
        -- so I'm counting on robots that they will be triggered in two second or 120 ticks.
        for c, constructron in ipairs(constructrons) do
            if constructron.valid then
                constructron.enable_logistics_while_moving = false
                me.set_constructron_status(constructron, 'deconstruct_tick', game.tick)
            else
                return true
            end
        end
        -- enable construct
    end,
    request_items = function(constructrons, request_items)
        debug_lib.DebugLog('ACTION: request_items')
        if global.stations_count[constructrons[1].surface.index] > 0 then
            local closest_station = me.get_closest_service_station(constructrons[1]) -- they must go to the same station even if they are not in the same station.
            for c, constructron in ipairs(constructrons) do
                me.pathfinder.request_path({constructron}, "constructron_pathing_dummy" , closest_station.position)
                local merged_items = table.deepcopy(request_items)
                for _, inv in pairs({"spider_trash", "spider_trunk"}) do
                    local inventory_items = me.get_inventory(constructron,inv)
                    for item_name, _ in pairs(inventory_items) do
                        if not merged_items[item_name] then
                            merged_items[item_name] = 0
                        end
                    end
                end
                local slot = 1
                for name, count in pairs(merged_items) do
                    constructron.set_vehicle_logistic_slot(slot, {
                        name = name,
                        min = count,
                        max = count
                    })
                    slot = slot + 1
                end
                if global.clear_robots_when_idle then
                    constructron.set_vehicle_logistic_slot(slot, {
                        name = global.desired_robot_name,
                        min = global.desired_robot_count,
                        max = global.desired_robot_count
                    })
                end
            end
        end
    end,
    clear_items = function(constructrons)
        debug_lib.DebugLog('ACTION: clear_items')
        -- for when the constructron returns to service station and needs to empty it's inventory.
        local slot = 1
        local desired_robot_count = global.desired_robot_count
        local desired_robot_name = global.desired_robot_name
        for c, constructron in ipairs(constructrons) do
            if constructron.valid then
                local inventory = constructron.get_inventory(defines.inventory.spider_trunk)
                local filtered_items = {}
                local robot_count = 0
                for i = 1, #inventory do
                    local item = inventory[i]
                    if item.valid_for_read then
                        if not global.clear_robots_when_idle then
                            if not (item.prototype.place_result and item.prototype.place_result.type == "construction-robot") then
                                if not filtered_items[item.name] then
                                    constructron.set_vehicle_logistic_slot(slot, {
                                        name = item.name,
                                        min = 0,
                                        max = 0
                                    })
                                    slot = slot + 1
                                    filtered_items[item.name] = true
                                end
                            else
                                robot_count = robot_count + item.count
                                if robot_count > desired_robot_count then
                                    if not filtered_items[item.name] then
                                        if item.name == desired_robot_name then
                                            constructron.set_vehicle_logistic_slot(slot, {
                                                name = item.name,
                                                min = desired_robot_count,
                                                max = desired_robot_count
                                            })
                                        else
                                            constructron.set_vehicle_logistic_slot(slot, {
                                                name = item.name,
                                                min = 0,
                                                max = 0
                                            })
                                        end
                                        slot = slot + 1
                                        filtered_items[item.name] = true
                                    end
                                end
                            end
                        else
                            if not filtered_items[item.name] then
                                constructron.set_vehicle_logistic_slot(slot, {
                                    name = item.name,
                                    min = 0,
                                    max = 0
                                })
                                slot = slot + 1
                                filtered_items[item.name] = true
                            end
                        end
                    end
                end
            else
                return true
            end
        end
    end,
    retire = function(constructrons)
        debug_lib.DebugLog('ACTION: retire')
        for c, constructron in ipairs(constructrons) do
            if constructron.valid then
                me.set_constructron_status(constructron, 'busy', false)
                me.paint_constructron(constructron, 'idle')
                if (global.constructrons_count[constructron.surface.index] > 10) then
                    local distance = 5 + math.random(5)
                    local alpha = math.random(360)
                    local offset = {x = (math.cos(alpha) * distance), y = (math.sin(alpha) * distance)}
                    local new_position = {x = (constructron.position.x + offset.x), y = (constructron.position.y + offset.y)}
                    constructron.autopilot_destination = new_position
                end
            end
        end
    end,
    add_to_check_chunk_done_queue = function(_, chunk) -- legacy, remove after 20/4/22
        debug_lib.DebugLog('ACTION: check_build_chunk')
        local entity_names = {}
        for name, _ in pairs(chunk.required_items) do
            table.insert(entity_names, name)
        end
        local surface = game.surfaces[chunk.surface]

        if (chunk.minimum.x == chunk.maximum.x) and (chunk.minimum.y == chunk.maximum.y) then
            chunk.minimum.x = chunk.minimum.x - 1
            chunk.minimum.y = chunk.minimum.y - 1
            chunk.maximum.x = chunk.maximum.x + 1
            chunk.maximum.y = chunk.maximum.y + 1
        end

        debug_lib.draw_rectangle(chunk.minimum, chunk.maximum, surface, color_lib.color_alpha(color_lib.colors.blue, 0.5))

        local ghosts = surface.find_entities_filtered {
            area = {chunk.minimum, chunk.maximum},
            type = {"entity-ghost", "tile-ghost", "item-request-proxy"},
            force = "player"
        } or {}
        if next(ghosts) then -- if there are ghosts because inventory doesn't have the items for them, add them to be built for the next job
            debug_lib.DebugLog('added ' .. #ghosts .. ' unbuilt ghosts.')

            for i, entity in ipairs(ghosts) do
                local key =  entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y
                global.ghost_entities[key] = entity
            end
        end
    end,
    check_build_chunk = function(_, chunk)
        debug_lib.DebugLog('ACTION: check_build_chunk')
        local entity_names = {}
        for name, _ in pairs(chunk.required_items) do
            table.insert(entity_names, name)
        end
        local surface = game.surfaces[chunk.surface]

        if (chunk.minimum.x == chunk.maximum.x) and (chunk.minimum.y == chunk.maximum.y) then
            chunk.minimum.x = chunk.minimum.x - 1
            chunk.minimum.y = chunk.minimum.y - 1
            chunk.maximum.x = chunk.maximum.x + 1
            chunk.maximum.y = chunk.maximum.y + 1
        end

        debug_lib.draw_rectangle(chunk.minimum, chunk.maximum, surface, color_lib.color_alpha(color_lib.colors.blue, 0.5))

        local ghosts = surface.find_entities_filtered {
            area = {chunk.minimum, chunk.maximum},
            type = {"entity-ghost", "tile-ghost", "item-request-proxy"},
            force = "player"
        } or {}
        if next(ghosts) then -- if there are ghosts because inventory doesn't have the items for them, add them to be built for the next job
            debug_lib.DebugLog('added ' .. #ghosts .. ' unbuilt ghosts.')

            for i, entity in ipairs(ghosts) do
                local key =  entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y
                global.ghost_entities[key] = entity
            end
        end
    end,
    check_decon_chunk = function(_, chunk)
        debug_lib.DebugLog('ACTION: check_decon_chunk')
        local surface = game.surfaces[chunk.surface]

        if (chunk.minimum.x == chunk.maximum.x) and (chunk.minimum.y == chunk.maximum.y) then
            chunk.minimum.x = chunk.minimum.x - 1
            chunk.minimum.y = chunk.minimum.y - 1
            chunk.maximum.x = chunk.maximum.x + 1
            chunk.maximum.y = chunk.maximum.y + 1
        end

        debug_lib.draw_rectangle(chunk.minimum, chunk.maximum, surface, color_lib.color_alpha(color_lib.colors.red, 0.5))

        local decons = surface.find_entities_filtered {
            area = {chunk.minimum, chunk.maximum},
            to_be_deconstructed = true,
            force = {"player", "neutral"}
        } or {}
        if next(decons) then -- if there are ghosts because inventory doesn't have the items for them, add them to be built for the next job
            debug_lib.DebugLog('added ' .. #decons .. ' to be deconstructed.')

            for i, entity in ipairs(decons) do
                local key =  entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y
                global.deconstruction_entities[key] = entity
            end
        end
    end,
    check_upgrade_chunk = function(_, chunk)
        debug_lib.DebugLog('ACTION: check_upgrade_chunk')
        local surface = game.surfaces[chunk.surface]

        if (chunk.minimum.x == chunk.maximum.x) and (chunk.minimum.y == chunk.maximum.y) then
            chunk.minimum.x = chunk.minimum.x - 1
            chunk.minimum.y = chunk.minimum.y - 1
            chunk.maximum.x = chunk.maximum.x + 1
            chunk.maximum.y = chunk.maximum.y + 1
        end

        debug_lib.draw_rectangle(chunk.minimum, chunk.maximum, surface, color_lib.color_alpha(color_lib.colors.green, 0.5))

        local upgrades = surface.find_entities_filtered {
            area = {chunk.minimum, chunk.maximum},
            force = "player",
            to_be_upgraded = true
        }

        if next(upgrades) then
            for i, entity in ipairs(upgrades) do
                debug_lib.DebugLog('added ' .. #upgrades .. ' missed entity upgrades.')

                local key =  entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y
                global.upgrade_entities[key] = {
                    entity = entity,
                    target = entity.get_upgrade_target()
                }
            end
        end
    end
}

-------------------------------------------------------------------------------
--  Conditions
-------------------------------------------------------------------------------

me.conditions = {
    position_done = function(constructrons, position) -- this is condition for action "go_to_position"
        debug_lib.VisualDebugText("Moving to position", constructrons[1], -3, 1)
        for c, constructron in ipairs(constructrons) do
            if (constructron.valid == false) then
                return true
            end
            if (chunk_util.distance_between(constructron.position, position) > 5) then
                return false
            end
        end
        return true
    end,
    build_done = function(constructrons, _, _, _)
        debug_lib.VisualDebugText("Constructing", constructrons[1], -3, 1)
        if constructrons[1].valid then
            local build_tick = me.get_constructron_status(constructrons[1], 'build_tick')
            local game_tick = game.tick

            if (game_tick - build_tick) > 120 then
                local logistic_network = constructrons[1].logistic_network
                if logistic_network then
                    if (me.robots_active(logistic_network)) then
                        me.set_constructron_status(constructrons[1], 'build_tick', game.tick)
                        return false -- robots are active
                    else
                        local cell = logistic_network.cells[1]
                        local area = chunk_util.get_area_from_position(constructrons[1].position, cell.construction_radius)
                        local ghosts = constructrons[1].surface.find_entities_filtered {
                            area = area,
                            name = {"entity-ghost", "tile-ghost"},
                            force = constructrons[1].force.name
                        }

                        for _, entity in pairs(ghosts) do
                            -- is the entity in range?
                            if cell.is_in_construction_range(entity.position) then
                                -- can the entity be built?
                                if logistic_network.can_satisfy_request(entity.ghost_prototype.items_to_place_this[1].name, 1) then
                                    -- construction not yet complete
                                    me.set_constructron_status(constructrons[1], 'build_tick', game.tick)
                                    return false
                                end
                            end
                        end
                    end
                    return true -- condition is satisfied
                else
                    return "graceful_wrapup" -- missing roboports.. leave
                end
            end
            return false
        else
            return true -- leader is invalidated.. skip action
        end
    end,
    deconstruction_done = function(constructrons)
        debug_lib.VisualDebugText("Deconstructing", constructrons[1], -3, 1)
        if constructrons[1].valid then
            local decon_tick = me.get_constructron_status(constructrons[1], 'deconstruct_tick')
            local game_tick = game.tick

            if (game_tick - decon_tick) > 120 then
                local logistic_network = constructrons[1].logistic_network
                if logistic_network then
                    if (me.robots_active(logistic_network)) then
                        local empty_stacks = 0
                        local inventory = constructrons[1].get_inventory(defines.inventory.spider_trunk)
                        empty_stacks = empty_stacks + (inventory.count_empty_stacks())
                        if empty_stacks > 0 then
                            me.set_constructron_status(constructrons[1], 'deconstruct_tick', game.tick)
                            return false -- robots are active
                        else
                            return "graceful_wrapup" -- there is no inventory space.. leave
                        end
                    else
                        local cell = logistic_network.cells[1]
                        local area = chunk_util.get_area_from_position(constructrons[1].position, cell.construction_radius)
                        local decons = constructrons[1].surface.find_entities_filtered {
                            area = area,
                            to_be_deconstructed = true,
                            force = {constructrons[1].force.name, "neutral"}
                        }

                        -- are the entities actually in range?
                        if not ((game_tick - decon_tick) < 900) then
                            for _, entity in pairs(decons) do
                                if cell.is_in_construction_range(entity.position) then
                                    -- construction not yet complete
                                    me.set_constructron_status(constructrons[1], 'deconstruct_tick', game.tick)
                                    return false
                                end
                            end
                        end
                        return true -- condition is satisfied
                    end
                else
                    return "graceful_wrapup" -- missing roboports.. leave
                end
            end
            return false
        else
            return true -- leader is invalidated.. skip action
        end
    end,
    upgrade_done = function(constructrons, _, _, _)
        debug_lib.VisualDebugText("Constructing", constructrons[1], -3, 1)
        if constructrons[1].valid then
            local build_tick = me.get_constructron_status(constructrons[1], 'build_tick')
            local game_tick = game.tick

            if (game_tick - build_tick) > 120 then
                local logistic_network = constructrons[1].logistic_network
                if logistic_network then
                    if (me.robots_active(logistic_network)) then
                        me.set_constructron_status(constructrons[1], 'build_tick', game.tick)
                        return false -- robots are active
                    else
                        local cell = logistic_network.cells[1]
                        local area = chunk_util.get_area_from_position(constructrons[1].position, cell.construction_radius)
                        local upgrades = constructrons[1].surface.find_entities_filtered {
                            area = area,
                            to_be_upgraded = true,
                            force = constructrons[1].force.name
                        }

                        for _, entity in pairs(upgrades) do
                            -- is the entity in range?
                            if cell.is_in_construction_range(entity.position) then
                                -- can the entity be built?
                                local target = entity.get_upgrade_target()
                                if logistic_network.can_satisfy_request(target.items_to_place_this[1].name, 1) then
                                    -- construction not yet complete
                                    me.set_constructron_status(constructrons[1], 'build_tick', game.tick)
                                    return false
                                end
                            end
                        end
                    end
                    return true -- condition is satisfied
                else
                    return "graceful_wrapup" -- missing roboports.. leave
                end
            end
            return false
        else
            return true -- leader is invalidated.. skip action
        end
    end,
    request_done = function(constructrons)
        debug_lib.VisualDebugText("Processing logistics", constructrons[1], -3, 1)
        if me.constructrons_need_reload(constructrons) then
            return false
        else
            for c, constructron in ipairs(constructrons) do
                if constructron.valid then
                    for i = 1, constructron.request_slot_count do
                        constructron.clear_vehicle_logistic_slot(i)
                    end
                else
                    return true
                end
            end
        end
        return true
    end,
    pass = function(_)
        return true
    end
}

-------------------------------------------------------------------------------

me.get_inventory = function(entity,inventory_type)
    local items = {}
    if entity.valid then
        local inventory
        if inventory_type == "spider_trash" then
            inventory = entity.get_inventory(defines.inventory.spider_trash)
        elseif inventory_type == "spider_trunk" then
            inventory = entity.get_inventory(defines.inventory.spider_trunk)
        end
        inventory = inventory or {}
        for i = 1, #inventory do
            local item = inventory[i]
            if item.valid_for_read and item.name ~= global.desired_robot_name then
                items[item.name] = (items[item.name] or 0) + item.count
            end
        end
    end
    return items
end

me.create_job = function(job_bundle_index, job)
    if not global.job_bundles then
        global.job_bundles = {}
    end
    if not global.job_bundles[job_bundle_index] then
        global.job_bundles[job_bundle_index] = {}
    end
    local index = #global.job_bundles[job_bundle_index] + 1
    job.index = index
    job.bundle_index = job_bundle_index
    global.job_bundles[job_bundle_index][index] = job
end

me.get_worker = function()
    for _, constructron in pairs(global.constructrons) do
        if constructron and constructron.valid and not me.get_constructron_status(constructron, 'busy') then
            if not constructron.logistic_network then
                debug_lib.VisualDebugText("Needs Equipment", constructron, 0.4, 3)
            else
                local desired_robot_count = global.desired_robot_count
                local logistic_network = constructron.logistic_network
                if (logistic_network.all_construction_robots == desired_robot_count) and not (me.robots_active(logistic_network)) then
                    constructron.enable_logistics_while_moving = false
                    return constructron
                else
                    if not global.clear_robots_when_idle then
                        if global.stations_count[constructron.surface.index] > 0 then
                            debug_lib.DebugLog('ACTION: Stage')
                            local desired_robot_name = global.desired_robot_name
                            if game.item_prototypes[desired_robot_name] then
                                if global.stations_count[constructron.surface.index] > 0 then
                                    debug_lib.VisualDebugText("Requesting Construction Robots", constructron, 0.4, 3)
                                    constructron.set_vehicle_logistic_slot(1, {
                                        name = desired_robot_name,
                                        min = desired_robot_count,
                                        max = desired_robot_count
                                    })
                                    if me.get_constructron_status(constructron, 'staged') then return end
                                    local closest_station = me.get_closest_service_station(constructron)
                                    me.pathfinder.request_path({constructron}, "constructron_pathing_dummy" , closest_station.position)
                                    me.set_constructron_status(constructron, 'staged', true)
                                else
                                    debug_lib.VisualDebugText("No Stations", constructron, 0.4, 3)
                                end
                            else
                                debug_lib.DebugLog('desired_robot_name name is not valid in mod settings')
                            end
                        end
                    end
                end
            end
        end
    end
end


-- This function is a Mess: refactor - carefull, recursion!!!
me.get_chunks_and_constructrons = function(queued_chunks, preselected_constructrons, max_constructron)
    local inventory = preselected_constructrons[1].get_inventory(defines.inventory.spider_trunk) -- only checking if things can fit in the first constructron. expecting others to be the exact same.
    local empty_stack_count = inventory.count_empty_stacks()
    local function get_job_chunks_and_constructrons(chunks, constructron_count, total_required_slots, requested_items)
        local merged_chunk

        for i, chunk1 in ipairs(chunks) do
            for j, chunk2 in ipairs(chunks) do
                if not (i == j) then
                    local merged_area = chunk_util.merge_direct_neighbour(chunk1.area, chunk2.area) -- checks if chunks are near to each other on the game map

                    if merged_area then
                        local required_slots1 = 0
                        local required_slots2 = 0

                        if not chunk1.merged then
                            required_slots1 = me.calculate_required_inventory_slot_count(chunk1.required_items or {}, constructron_count)
                            required_slots1 = required_slots1 + me.calculate_required_inventory_slot_count(chunk1.trash_items or {}, constructron_count)
                            for name, count in pairs(chunk1['required_items']) do
                                requested_items[name] = math.ceil(((requested_items[name] or 0) * constructron_count + count) / constructron_count)
                            end
                        end
                        if not chunk2.merged then
                            required_slots2 = me.calculate_required_inventory_slot_count(chunk2.required_items or {}, constructron_count)
                            required_slots2 = required_slots2 + me.calculate_required_inventory_slot_count(chunk2.trash_items or {}, constructron_count)
                            for name, count in pairs(chunk2['required_items']) do
                                requested_items[name] = math.ceil(((requested_items[name] or 0) * constructron_count + count) / constructron_count)
                            end
                        end

                        if ((total_required_slots + required_slots1 + required_slots2) < empty_stack_count) then -- Actually merge the chunks
                            total_required_slots = total_required_slots + required_slots1 + required_slots2
                            merged_chunk = chunk_util.merge_neighbour_chunks(merged_area, chunk1, chunk2)
                            merged_chunk.merged = true

                            -- create a new table for remaining chunks
                            local remaining_chunks = {}
                            local remaining_counter = 1

                            remaining_chunks[1] = merged_chunk
                            for k, chunk in ipairs(chunks) do
                                if (not (k == i)) and (not (k == j)) then
                                    remaining_counter = remaining_counter + 1
                                    remaining_chunks[remaining_counter] = chunk
                                end
                            end
                            -- !!! recursive call
                            return get_job_chunks_and_constructrons(remaining_chunks, constructron_count, total_required_slots, requested_items)
                        elseif constructron_count < max_constructron and constructron_count < #preselected_constructrons then
                            -- use the original chunks and empty merge_chunks and start over
                            -- !!! recursive call
                            return get_job_chunks_and_constructrons(queued_chunks, constructron_count + 1, 0, {})
                        end
                    end
                end
            end
        end

        local my_constructrons = {}

        for c = 1, constructron_count do
            my_constructrons[c] = preselected_constructrons[c]
        end

        -- if the chunks didn't merge. there are unmerged chunks. they should be added as job if they can be.

        local used_chunks = {}
        local used_chunk_counter = 1

        local unused_chunks = {}
        local unused_chunk_counter = 1

        requested_items = {}
        total_required_slots = 0

        for i, chunk in ipairs(chunks) do
            local required_slots = me.calculate_required_inventory_slot_count(chunk.required_items or {}, constructron_count)

            required_slots = required_slots + me.calculate_required_inventory_slot_count(chunk.trash_items or {}, constructron_count)
            if ((total_required_slots + required_slots) < empty_stack_count) then
                total_required_slots = total_required_slots + required_slots
                for name, count in pairs(chunk['required_items']) do
                    requested_items[name] = math.ceil(((requested_items[name] or 0) * constructron_count + count) / constructron_count)
                end
                used_chunks[used_chunk_counter] = chunk
                used_chunk_counter = used_chunk_counter + 1
            else
                unused_chunks[unused_chunk_counter] = chunk
                unused_chunk_counter = unused_chunk_counter + 1
            end
        end

        used_chunks.requested_items = requested_items
        return used_chunks, my_constructrons, unused_chunks
    end
    return get_job_chunks_and_constructrons(queued_chunks, 1, 0, {})
end

me.get_job = function(constructrons)
    local managed_surfaces = game.surfaces -- revisit as all surfaces are scanned, even ones without service stations or constructrons.
    for _, surface in pairs(managed_surfaces) do -- iterate each surface
        if (global.constructrons_count[surface.index] > 0) and (global.stations_count[surface.index] > 0) then
            if (next(global.construct_queue[surface.index]) or next(global.deconstruct_queue[surface.index]) or next(global.upgrade_queue[surface.index]) or next(global.repair_queue[surface.index])) then -- this means they are processed as chunks or it's empty.
                local max_worker = 1
                local chunks = {}
                local job_type
                local chunk_counter = 0
                local worker = me.get_worker()
                local available_constructrons = {}

                available_constructrons[1] = worker
                if available_constructrons[1] then
                    me.set_constructron_status(available_constructrons[1], 'staged', false)
                    if next(global.deconstruct_queue[surface.index]) then -- deconstruction have priority over construction.
                        for key, chunk in pairs(global.deconstruct_queue[surface.index]) do
                            chunk_counter = chunk_counter + 1
                            chunks[chunk_counter] = chunk
                        end
                        job_type = 'deconstruct'

                    elseif next(global.construct_queue[surface.index]) then
                        for key, chunk in pairs(global.construct_queue[surface.index]) do
                            chunk_counter = chunk_counter + 1
                            chunks[chunk_counter] = chunk
                        end
                        job_type = 'construct'

                    elseif next(global.upgrade_queue[surface.index]) then
                        for key, chunk in pairs(global.upgrade_queue[surface.index]) do
                            chunk_counter = chunk_counter + 1
                            chunks[chunk_counter] = chunk
                        end
                        job_type = 'upgrade'

                    elseif next(global.repair_queue[surface.index]) then
                        for key, chunk in pairs(global.repair_queue[surface.index]) do
                            chunk_counter = chunk_counter + 1
                            chunks[chunk_counter] = chunk
                        end
                        job_type = 'repair'
                    end

                    if not next(chunks) then
                        return
                    end

                    local combined_chunks, selected_constructrons, unused_chunks = me.get_chunks_and_constructrons(chunks, available_constructrons, max_worker)

                    local queue
                    if job_type == 'deconstruct' then
                        queue = global.deconstruct_queue
                    elseif job_type == 'construct' then
                        queue = global.construct_queue
                    elseif job_type == 'upgrade' then
                        queue = global.upgrade_queue
                    elseif job_type == 'repair' then
                        queue = global.repair_queue
                    end

                    queue[surface.index] = {}

                    for i, chunk in ipairs(unused_chunks) do
                        queue[surface.index][chunk.key] = chunk
                    end

                    local request_items_job = {
                        action = 'request_items',
                        action_args = {combined_chunks.requested_items},
                        leave_condition = 'request_done',
                        constructrons = selected_constructrons,
                        unused_stations = me.get_service_stations(selected_constructrons[1].surface.index)
                    }

                    global.job_bundle_index = (global.job_bundle_index or 0) + 1
                    me.create_job(global.job_bundle_index, request_items_job)
                    for i, chunk in ipairs(combined_chunks) do
                        chunk['positions'] = chunk_util.calculate_construct_positions({chunk.minimum, chunk.maximum}, selected_constructrons[1].logistic_cell.construction_radius * 0.85) -- 15% tolerance
                        chunk['surface'] = surface.index
                        local find_path = false
                        for p, position in ipairs(chunk.positions) do
                            if p == 1 then
                                find_path = true
                            end
                            me.create_job(global.job_bundle_index, {
                                action = 'go_to_position',
                                action_args = {position, find_path},
                                leave_condition = 'position_done',
                                leave_args = {position},
                                constructrons = selected_constructrons,
                            })
                            if not (job_type == 'deconstruct') then
                                if not (job_type == 'upgrade') then
                                    me.create_job(global.job_bundle_index, {
                                        action = 'build',
                                        leave_condition = 'build_done',
                                        leave_args = {chunk.required_items, chunk.minimum, chunk.maximum},
                                        constructrons = selected_constructrons,
                                        job_class = job_type
                                    })
                                else
                                    me.create_job(global.job_bundle_index, {
                                        action = 'build',
                                        leave_condition = 'upgrade_done',
                                        leave_args = {chunk.required_items, chunk.minimum, chunk.maximum},
                                        constructrons = selected_constructrons,
                                        job_class = job_type
                                    })
                                end
                                if (job_type == 'construct') then
                                    for c, constructron in ipairs(selected_constructrons) do
                                        me.paint_constructron(constructron, 'construct')
                                    end
                                elseif (job_type == 'repair') then
                                    for c, constructron in ipairs(selected_constructrons) do
                                        me.paint_constructron(constructron, 'repair')
                                    end
                                end
                            elseif (job_type == 'deconstruct') then
                                me.create_job(global.job_bundle_index, {
                                    action = 'deconstruct',
                                    leave_condition = 'deconstruction_done',
                                    constructrons = selected_constructrons
                                })
                            end
                            for c, constructron in ipairs(selected_constructrons) do
                                me.paint_constructron(constructron, job_type)
                            end
                        end
                        if (job_type == 'construct') then
                            me.create_job(global.job_bundle_index, {
                                action = 'check_build_chunk',
                                action_args = {chunk},
                                leave_condition = 'pass', -- there is no leave condition
                                constructrons = selected_constructrons
                            })
                        end
                        if (job_type == 'deconstruct') then
                            me.create_job(global.job_bundle_index, {
                                action = 'check_decon_chunk',
                                action_args = {chunk},
                                leave_condition = 'pass', -- there is no leave condition
                                constructrons = selected_constructrons
                            })
                        end
                        if (job_type == 'upgrade') then
                            me.create_job(global.job_bundle_index, {
                                action = 'check_upgrade_chunk',
                                action_args = {chunk},
                                leave_condition = 'pass', -- there is no leave condition
                                constructrons = selected_constructrons
                            })
                        end
                    end
                    -- go back to a service_station when job is done.
                    local closest_station = me.get_closest_service_station(selected_constructrons[1])
                    local home_position = closest_station.position
                    me.create_job(global.job_bundle_index, {
                        action = 'go_to_position',
                        action_args = {home_position, true},
                        leave_condition = 'position_done',
                        leave_args = {home_position},
                        constructrons = selected_constructrons,
                        returning_home = true
                    })

                    me.create_job(global.job_bundle_index, {
                        action = 'clear_items',
                        leave_condition = 'request_done',
                        constructrons = selected_constructrons
                    })
                    me.create_job(global.job_bundle_index, {
                        action = 'retire',
                        leave_condition = 'pass',
                        leave_args = {home_position},
                        constructrons = selected_constructrons
                    })
                end
            end
        end
    end
end

me.do_job = function(job_bundles)
    if not next(job_bundles) then return end

    for i, job_bundle in pairs(job_bundles) do
        local job = job_bundle[1]
        if job then
            for c, constructron in ipairs(job.constructrons) do
                if not job.active then
                    me.set_constructron_status(constructron, 'busy', true)
                end
            end
            if job.constructrons[1] then
                me.do_until_leave(job)
                job.active = true
            else
                return true
            end
        else
            job_bundles[i] = nil
        end
    end
end

me.process_job_queue = function(_)
    me.get_job(global.constructrons)
    me.do_job(global.job_bundles)
end

me.perform_surface_cleanup = function(_)
    debug_lib.DebugLog('Surface job validation & cleanup')
    for s, surface in pairs(game.surfaces) do
        if not global.constructrons_count[surface.index] or not global.stations_count[surface.index] then
            global.constructrons_count[surface.index] = 0
            global.stations_count[surface.index] = 0
        end
        if (global.constructrons_count[surface.index] <= 0) or (global.stations_count[surface.index] <= 0) then
            debug_lib.DebugLog('No Constructrons or Service Stations found on ' .. surface.name)
            me.force_surface_cleanup(surface)
        end
    end
end

me.force_surface_cleanup = function(surface)
    debug_lib.DebugLog('All job queues on '.. surface.name ..' cleared!')
    global.construct_queue[surface.index] = {}
    global.deconstruct_queue[surface.index] = {}
    global.upgrade_queue[surface.index] = {}
    global.repair_queue[surface.index] = {}
end


me.is_floor_tile = function(entity_name)
    if global.landfill_job_toggle then
        return false
    end
    local floor_tiles
    floor_tiles = { ['landfill'] = true, ['se-space-platform-scaffold'] = true, ['se-space-platform-plating'] = true, ['se-spaceship-floor'] = true }
    -- ToDo:
    --  find landfill-like tiles based on collision layer
    --  this list should be build at loading time not everytime
    if floor_tiles[entity_name] then
        return true
    else
        return false
    end
end

me.mod_settings_changed = function(event)
    log("mod setting change: " .. event.setting)
    local setting = event.setting
    if setting == "construct_jobs" then
        global.construction_job_toggle = settings.global["construct_jobs"].value
    elseif setting == "rebuild_jobs" then
        global.rebuild_job_toggle = settings.global["rebuild_jobs"].value
    elseif setting == "deconstruct_jobs" then
        global.deconstruction_job_toggle = settings.global["deconstruct_jobs"].value
    elseif setting == "decon_ground_items" then
        global.ground_decon_job_toggle = settings.global["decon_ground_items"].value
    elseif setting == "upgrade_jobs" then
        global.upgrade_job_toggle = settings.global["upgrade_jobs"].value
    elseif setting == "repair_jobs" then
        global.repair_job_toggle = settings.global["repair_jobs"].value
    elseif setting == "constructron-debug-enabled" then
        global.debug_toggle = settings.global["constructron-debug-enabled"].value
    elseif setting == "allow_landfill" then
        global.landfill_job_toggle = settings.global["allow_landfill"].value
    elseif setting == "job-start-delay" then
        global.job_start_delay = (settings.global["job-start-delay"].value * 60)
    elseif setting == "desired_robot_count" then
        global.desired_robot_count = settings.global["desired_robot_count"].value
    elseif setting == "desired_robot_name" then
        global.desired_robot_name = settings.global["desired_robot_name"].value
    elseif setting == "max-worker-per-job" then
        global.max_worker_per_job = 1
    elseif setting == "construction_mat_alert" then
        global.construction_mat_alert = (settings.global["construction_mat_alert"].value * 60)
    elseif setting == "max-jobtime-per-job" then
        global.max_jobtime = (settings.global["max-jobtime-per-job"].value * 60 * 60)
    elseif setting == "entities_per_tick" then
        global.entities_per_tick = settings.global["entities_per_tick"].value
    elseif setting == "clear_robots_when_idle" then
        global.clear_robots_when_idle = settings.global["clear_robots_when_idle"].value
    end
end

me.on_built_entity = function(event) -- for entity creation
    if not global.construction_job_toggle then return end
    local entity = event.entity or event.created_entity

    local key = entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y
    local entity_type = entity.type

    if entity_type == 'item-request-proxy' then
        global.ghost_entities[key] = entity
        global.ghost_tick = event.tick
    else
        if entity_type == 'entity-ghost' or entity_type == 'tile-ghost' then
            local entity_name = entity.ghost_name
            -- Need to separate ghosts and tiles in different tables
            if global.ignored_entities[entity_name] == nil then
                local items_to_place_this = entity.ghost_prototype.items_to_place_this
                global.ignored_entities[entity_name] = (me.check_item_allowed(items_to_place_this[1].name) == false)
                -- if me.is_floor_tile(entity_name) then -- we need to find a way to improve pathing before floor tiles can be built. So ignore landfill and similiar tiles.
                --     global.ignored_entities[entity_name] = true
                -- end
            end
            if not global.ignored_entities[entity_name] == true then
                if not me.is_floor_tile(entity_name) then
                    global.ghost_entities[key] = entity
                    global.ghost_tick = event.tick
                end
            end
        elseif entity.name == 'constructron' or entity.name == "constructron-rocket-powered" then
            local registration_number = script.register_on_entity_destroyed(entity)
            me.set_constructron_status(entity, 'busy', false)
            me.set_constructron_status(constructron, 'staged', false)
            me.paint_constructron(entity, 'idle')
            entity.enable_logistics_while_moving = false
            global.constructrons[entity.unit_number] = entity
            global.registered_entities[registration_number] = {
                name = "constructron",
                surface = entity.surface.index
            }
            global.constructrons_count[entity.surface.index] = global.constructrons_count[entity.surface.index] + 1
        elseif entity.name == "service_station" then
            local registration_number = script.register_on_entity_destroyed(entity)

            global.service_stations[entity.unit_number] = entity
            global.registered_entities[registration_number] = {
                name = "service_station",
                surface = entity.surface.index
            }
            global.stations_count[entity.surface.index] = global.stations_count[entity.surface.index] + 1
        end
    end
end

me.on_post_entity_died = function(event) -- for entities that die and need rebuilding
    if not global.rebuild_job_toggle then return end
    local entity = event.ghost

    if entity and entity.valid and (entity.type == 'entity-ghost') and (entity.force.name == "player") then
        local key = entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y

        global.ghost_entities[key] = entity
        global.ghost_tick = event.tick
    end
end

me.on_entity_marked_for_deconstruction = function(event) -- for entity deconstruction
    if not global.deconstruction_job_toggle then return end
    if not (event.entity.name == "item-on-ground") then
        local entity = event.entity
        local force_name = entity.force.name
        local key = entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y
        if force_name == "player" or force_name == "neutral" then
            global.deconstruct_marked_tick = event.tick
            global.deconstruction_entities[key] = entity
        end
    elseif global.ground_decon_job_toggle then
        local entity = event.entity
        local force_name = entity.force.name
        local key = entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y
        if force_name == "player" or force_name == "neutral" then
            global.deconstruct_marked_tick = event.tick
            global.deconstruction_entities[key] = entity
        end
    end
end

me.on_marked_for_upgrade = function(event) -- for entity upgrade
    if not global.upgrade_job_toggle then return end
    local entity = event.entity
    local key = entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y

    if entity.force.name == "player" then
        global.upgrade_marked_tick = event.tick
        global.upgrade_entities[key] = {
            entity = entity,
            target = event.target
        }
    end
end

me.on_entity_damaged = function(event)
    if not global.repair_job_toggle then return end
    local entity = event.entity
    local force = entity.force.name
    local key = entity.surface.index .. ',' .. entity.position.x .. ',' .. entity.position.y

    if (force == "player") and (((event.final_health / entity.prototype.max_health) * 100) <= settings.global["repair_percent"].value) then
        if not global.repair_entities[key] then
            global.repair_marked_tick = event.tick
            global.repair_entities[key] = entity
        end
    elseif force == "player" and global.repair_entities[key] and event.final_health == 0 then
        global.repair_entities[key] = nil
    end
end

me.on_surface_created = function(event)
    local index = event.surface_index

    global.construct_queue[index] = {}
    global.deconstruct_queue[index] = {}
    global.upgrade_queue[index] = {}
    global.repair_queue[index] = {}

    global.constructrons_count[index] = 0
    global.stations_count[index] = 0
end

me.on_surface_deleted = function(event)
    local index = event.surface_index

    global.construct_queue[index] = nil
    global.deconstruct_queue[index] = nil
    global.upgrade_queue[index] = nil
    global.repair_queue[index] = nil

    global.constructrons_count[index] = nil
    global.stations_count[index] = nil
end

me.on_entity_cloned = function(event)
    local entity = event.destination
    if entity.name == 'constructron' or entity.name == "constructron-rocket-powered" then
        local registration_number = script.register_on_entity_destroyed(entity)
        debug_lib.DebugLog('constructron ' .. event.destination.unit_number .. ' Cloned!')
        me.paint_constructron(entity, 'idle')

        global.constructrons[entity.unit_number] = entity
        global.registered_entities[registration_number] = {
            name = "constructron",
            surface = entity.surface.index
        }
        global.constructrons_count[entity.surface.index] = global.constructrons_count[entity.surface.index] + 1
    elseif entity.name == "service_station" then
        local registration_number = script.register_on_entity_destroyed(entity)
        debug_lib.DebugLog('service_station ' .. event.destination.unit_number .. ' Cloned!')

        global.service_stations[entity.unit_number] = entity
        global.registered_entities[registration_number] = {
            name = "service_station",
            surface = entity.surface.index
        }
        global.stations_count[entity.surface.index] = global.stations_count[entity.surface.index] + 1
    end
end

me.on_entity_destroyed = function(event)
    if global.registered_entities[event.registration_number] then
        local removed_entity = global.registered_entities[event.registration_number]
        if removed_entity.name == "constructron" or removed_entity.name == "constructron-rocket-powered" then
            local surface = removed_entity.surface
            global.constructrons_count[surface] = math.max(0, (global.constructrons_count[surface] or 0) - 1)
            global.constructrons[event.unit_number] = nil
            global.constructron_statuses[event.unit_number] = nil
            debug_lib.DebugLog('constructron ' .. event.unit_number .. ' Destroyed!')
        elseif removed_entity.name == "service_station" then
            local surface = removed_entity.surface
            global.stations_count[surface] = math.max(0, (global.stations_count[surface] or 0) - 1)
            global.service_stations[event.unit_number] = nil
            debug_lib.DebugLog('service_station ' .. event.unit_number .. ' Destroyed!')
        end
        global.registered_entities[event.registration_number] = nil
    end
end

me.set_constructron_status = function(constructron, state, value)
    if constructron and constructron.valid then
        if global.constructron_statuses[constructron.unit_number] then
            global.constructron_statuses[constructron.unit_number][state] = value
        else
            global.constructron_statuses[constructron.unit_number] = {}
            global.constructron_statuses[constructron.unit_number][state] = value
        end
    else
        return true
    end
end

me.get_constructron_status = function(constructron, state)
    if constructron and constructron.valid then
        if global.constructron_statuses[constructron.unit_number] then
            return global.constructron_statuses[constructron.unit_number][state]
        end
        return nil
    else
        return true
    end
end

me.get_closest_service_station = function(constructron)
    local service_stations = me.get_service_stations(constructron.surface.index)
    if service_stations then
        for unit_number, station in pairs(service_stations) do
            if not station.valid then
                global.service_stations[unit_number] = nil -- could be redundant as entities are now registered
            end
        end
        local service_station_index = chunk_util.get_closest_object(service_stations, constructron.position)
        return service_stations[service_station_index]
    end
end

me.get_closest_unused_service_station = function(constructron, unused_stations)
    if unused_stations then
        local unused_stations_index = chunk_util.get_closest_object(unused_stations, constructron.position)
        return unused_stations[unused_stations_index]
    end
end

me.paint_constructron = function(constructron, color_state)
    if color_state == 'idle' then
        constructron.color = color_lib.color_alpha(color_lib.colors.white, 0.25)
    elseif color_state == 'construct' then
        constructron.color = color_lib.color_alpha(color_lib.colors.blue, 0.4)
    elseif color_state == 'deconstruct' then
        constructron.color = color_lib.color_alpha(color_lib.colors.red, 0.4)
    elseif color_state == 'upgrade' then
        constructron.color = color_lib.color_alpha(color_lib.colors.green, 0.4)
    elseif color_state == 'repair' then
        constructron.color = color_lib.color_alpha(color_lib.colors.charcoal, 0.4)
    end
end

return me
