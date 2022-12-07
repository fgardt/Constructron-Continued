---@module "gui"

local gui_event_type = {
    [defines.events.on_gui_click] = "on_gui_click",
    [defines.events.on_gui_selection_state_changed] = "on_gui_selection_state_changed"
}

---@type GUI
local gui = {}
local gui_handler = {}
local handlers = {}

---@param player LuaPlayer
---@param _ LuaGuiElement
function handlers.toggle_main(player, _)
    gui.toggleMain(player)
end

---@param player LuaPlayer
---@param _ LuaGuiElement
function handlers.toggle_preferences(player, _)
    gui.togglePreferences(player)
end

---@param player LuaPlayer
---@param dropdown LuaGuiElement
function handlers.selected_new_surface(player, dropdown)
    gui.selectedNewSurface(player, dropdown)
end

function gui_handler.init(guiInstance)
    gui = guiInstance
end

function gui_handler.register()
    for ev, _ in pairs(gui_event_type) do
        script.on_event(ev, gui_handler.gui_event)
    end
end

---@param event 
---| EventData.on_gui_click 
---| EventData.on_gui_selection_state_changed
function gui_handler.gui_event(event)
    if not event.element then return end

    local tags = event.element.tags
    if tags.mod ~= "constructron" then return end

    -- GUI events always have an associated player
    local player = game.get_player(event.player_index)
    if not player then return end

    local event_name = gui_event_type[event.name]
    local action_name = tags[event_name]

    if not action_name then return end

    local event_handler = handlers[action_name]

    if not event_handler then return end

    event_handler(player, event.element)
end

---@param event EventData.on_surface_created
function gui_handler.surface_created(event)
    local name = game.surfaces[event.surface_index].name

    for _, player in pairs(game.players) do
        local frame = player.gui.screen[gui.builder.mainFrameName] --[[@as LuaGuiElement?]]

        if not frame or not frame.valid then
            goto continue
        end

        local surface_selection = frame["title_bar"]["surface_select"] --[[@as LuaGuiElement]]

        surface_selection.add_item(name)
        surface_selection.visible = true

        ::continue::
    end
end

---@param event EventData.on_surface_deleted
function gui_handler.surface_deleted(event)
    local removed_name = game.surfaces[event.surface_index].name

    for _, player in pairs(game.players) do
        local frame = player.gui.screen[gui.builder.mainFrameName] --[[@as LuaGuiElement?]]

        if not frame or not frame.valid then
            goto continue
        end

        local surface_selection = frame["title_bar"]["surface_select"] --[[@as LuaGuiElement]]
        local current_items = surface_selection.items

        for i, name in ipairs(current_items) do --[[@cast i uint]]
            if name == removed_name then
                if i == surface_selection.selected_index then
                    -- current selection gets removed -> fallback to nauvis
                    surface_selection.selected_index = 1

                    handlers.selected_new_surface(player, surface_selection)
                end

                surface_selection.remove_item(i)
                break
            end
        end

        if #surface_selection.items == 1 then
            -- hide selection if only 1 surface is left
            surface_selection.visible = false
        end

        ::continue::
    end
end

---@param event EventData.on_surface_renamed
function gui_handler.surface_renamed(event)
    for _, player in pairs(game.players) do
        local frame = player.gui.screen[gui.builder.mainFrameName] --[[@as LuaGuiElement?]]

        if not frame or not frame.valid then
            goto continue
        end

        local surface_selection = frame["title_bar"]["surface_select"] --[[@as LuaGuiElement]]

        for i, old_name in ipairs(surface_selection.items) do --[[@cast i uint]]
            if old_name == event.old_name then
                surface_selection.set_item(i, event.new_name)
                break
            end
        end

        ::continue::
    end
end

---@param event EventData.on_player_changed_surface
function gui_handler.player_changed_surfaces(event)
    local player = game.players[event.player_index]
    local frame = player.gui.screen[gui.builder.mainFrameName] --[[@as LuaGuiElement?]]

    if not frame or not frame.valid then
        return
    end

    local surface_selection = frame["title_bar"]["surface_select"] --[[@as LuaGuiElement]]
    local surface_name = player.surface.name

    for i, name in ipairs(surface_selection.items) do --[[@cast i uint]]
        if name == surface_name then
            surface_selection.selected_index = i
            break
        end
    end

    handlers.selected_new_surface(player, surface_selection)
end

return gui_handler