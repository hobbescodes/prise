local prise = require("prise")

local state = {
    root = nil,
    focused_id = nil,
    status_bg = "white",
    pending_command = false,
    timer = nil,
    pending_split = nil,
}

local M = {}

local DEFAULT_FLEX = 10000
local RESIZE_STEP = 5

-- --- Helpers ---

local function is_pane(node)
    return node and node.type == "pane"
end
local function is_split(node)
    return node and node.type == "split"
end

-- Returns a list of nodes from root to the target node [root, ..., target]
local function find_node_path(current, target_id, path)
    path = path or {}
    if not current then
        return nil
    end

    table.insert(path, current)

    if is_pane(current) then
        if current.id == target_id then
            return path
        end
    elseif is_split(current) then
        for _, child in ipairs(current.children) do
            if find_node_path(child, target_id, path) then
                return path
            end
        end
    end

    -- Not found in this branch
    table.remove(path)
    return nil
end

local function get_first_leaf(node)
    if not node then
        return nil
    end
    if is_pane(node) then
        return node
    end
    if is_split(node) then
        return get_first_leaf(node.children[1])
    end
    return nil
end

local function get_last_leaf(node)
    if not node then
        return nil
    end
    if is_pane(node) then
        return node
    end
    if is_split(node) then
        return get_last_leaf(node.children[#node.children])
    end
    return nil
end

-- Recursively insert a new pane relative to target_id
local function insert_split_recursive(node, target_id, new_pane, direction)
    if is_pane(node) then
        if node.id == target_id then
            -- Found the target pane. Replace it with a split containing [node, new_pane]
            local split_flex = node.flex or DEFAULT_FLEX
            node.flex = DEFAULT_FLEX
            new_pane.flex = DEFAULT_FLEX
            return {
                type = "split",
                direction = direction,
                flex = split_flex, -- Inherit flex from the pane being replaced
                children = { node, new_pane },
            }
        else
            return node
        end
    elseif is_split(node) then
        for i, child in ipairs(node.children) do
            node.children[i] = insert_split_recursive(child, target_id, new_pane, direction)
        end
        return node
    end
    return node
end

-- Recursively remove a pane and return: new_node, closest_sibling_id
local function remove_pane_recursive(node, id)
    if is_pane(node) then
        if node.id == id then
            return nil, nil
        end -- Remove this pane
        return node, nil
    elseif is_split(node) then
        local new_children = {}
        local removed_index = nil
        local closest_id = nil

        for i, child in ipairs(node.children) do
            local res, sibling_from_below = remove_pane_recursive(child, id)

            if res then
                table.insert(new_children, res)
                if sibling_from_below then
                    closest_id = sibling_from_below
                end
            else
                -- This child was removed
                removed_index = i
                if sibling_from_below then
                    closest_id = sibling_from_below
                end
            end
        end

        -- If we found the removed node at this level, pick a sibling
        if removed_index and not closest_id then
            -- Try right sibling first (if exists), then left
            if removed_index < #node.children then
                local neighbor = node.children[removed_index + 1]
                local leaf = get_first_leaf(neighbor)
                if leaf then
                    closest_id = leaf.id
                end
            elseif removed_index > 1 then
                local neighbor = node.children[removed_index - 1]
                local leaf = get_last_leaf(neighbor)
                if leaf then
                    closest_id = leaf.id
                end
            end
        end

        if #new_children == 0 then
            return nil, closest_id
        end

        -- If only one child remains, promote it
        if #new_children == 1 then
            local survivor = new_children[1]
            survivor.flex = node.flex or DEFAULT_FLEX
            return survivor, closest_id
        end

        node.children = new_children
        return node, closest_id
    end
    return nil, nil
end

local function get_focused_pty()
    if not state.focused_id or not state.root then
        return nil
    end
    local path = find_node_path(state.root, state.focused_id)
    if path then
        return path[#path].pty
    end
    return nil
end

local function resize_pane(dimension, delta_chars)
    if not state.focused_id or not state.root then
        return
    end

    local path = find_node_path(state.root, state.focused_id)
    if not path then
        return
    end

    local target_split_dir = (dimension == "width") and "row" or "col"

    -- Traverse up to find a split of the correct direction
    local parent_split = nil
    local child_idx = nil
    local node = nil

    for i = #path - 1, 1, -1 do
        if path[i].type == "split" and path[i].direction == target_split_dir then
            parent_split = path[i]
            node = path[i + 1]

            -- Find index
            for k, c in ipairs(parent_split.children) do
                if c == node then
                    child_idx = k
                    break
                end
            end
            break
        end
    end

    if not parent_split or not child_idx then
        return
    end

    -- Calculate flex delta
    local pty = get_focused_pty()
    if not pty then
        return
    end

    local size = pty:size()
    local current_dim_size = (dimension == "width") and size.cols or size.rows
    local current_flex = node.flex or DEFAULT_FLEX

    if current_dim_size == 0 then
        return
    end

    local flex_per_char = current_flex / current_dim_size
    local flex_delta = math.floor(delta_chars * flex_per_char)

    if flex_delta == 0 then
        -- Ensure at least some movement if delta_chars is small
        flex_delta = (delta_chars > 0) and 100 or -100
    end

    -- Resize logic:
    -- To grow (positive delta): try to shrink next sibling, else shrink prev sibling.
    -- To shrink (negative delta): try to grow next sibling, else grow prev sibling.

    local neighbor = nil
    local neighbor_idx = nil

    if delta_chars > 0 then
        -- Grow
        if child_idx < #parent_split.children then
            neighbor_idx = child_idx + 1
        elseif child_idx > 1 then
            neighbor_idx = child_idx - 1
        end
    else
        -- Shrink
        if child_idx < #parent_split.children then
            neighbor_idx = child_idx + 1
        elseif child_idx > 1 then
            neighbor_idx = child_idx - 1
        end
    end

    if not neighbor_idx then
        return
    end
    neighbor = parent_split.children[neighbor_idx]

    -- Apply flex change
    -- If we grow, neighbor shrinks. If we shrink, neighbor grows.
    -- Wait, if we take from neighbor (grow), neighbor flex decreases.
    -- But if neighbor is to the left or right, does it matter?
    -- Flex is just ratio. Increasing my flex vs neighbor flex increases my size.

    -- So:
    -- My flex += flex_delta (can be negative)
    -- Neighbor flex -= flex_delta

    local my_new_flex = (node.flex or DEFAULT_FLEX) + flex_delta
    local neighbor_new_flex = (neighbor.flex or DEFAULT_FLEX) - flex_delta

    -- Clamp values (don't let them disappear completely, keep at least small flex)
    local min_flex = 100
    if my_new_flex < min_flex then
        local diff = min_flex - my_new_flex
        my_new_flex = min_flex
        neighbor_new_flex = neighbor_new_flex - diff
    end
    if neighbor_new_flex < min_flex then
        local diff = min_flex - neighbor_new_flex
        neighbor_new_flex = min_flex
        my_new_flex = my_new_flex - diff
    end

    node.flex = math.floor(my_new_flex)
    neighbor.flex = math.floor(neighbor_new_flex)

    prise.request_frame()
end

local function move_focus(direction)
    if not state.focused_id or not state.root then
        return
    end

    local path = find_node_path(state.root, state.focused_id)
    if not path then
        return
    end

    -- "left"/"right" implies moving along "row"
    -- "up"/"down" implies moving along "col"
    local target_split_type = (direction == "left" or direction == "right") and "row" or "col"
    local forward = (direction == "right" or direction == "down")

    local sibling_node = nil

    -- Traverse up the path to find a split of the correct type where we can move
    -- path is [root, ..., parent, leaf]
    for i = #path - 1, 1, -1 do
        local node = path[i]
        local child = path[i + 1]

        if node.type == "split" and node.direction == target_split_type then
            -- Find index of child
            local idx = 0
            for k, c in ipairs(node.children) do
                if c == child then
                    idx = k
                    break
                end
            end

            if forward then
                if idx < #node.children then
                    sibling_node = node.children[idx + 1]
                    break
                end
            else
                if idx > 1 then
                    sibling_node = node.children[idx - 1]
                    break
                end
            end
        end
    end

    if sibling_node then
        -- Found a sibling tree/pane. Find the closest leaf.
        local target_leaf
        if forward then
            target_leaf = get_first_leaf(sibling_node)
        else
            target_leaf = get_last_leaf(sibling_node)
        end

        if target_leaf then
            state.focused_id = target_leaf.id
            prise.request_frame()
        end
    end
end

-- --- Main Functions ---

function M.update(event)
    if event.type == "pty_attach" then
        prise.log.info("Lua: pty_attach received")
        local pty = event.data.pty
        local new_pane = { type = "pane", pty = pty, id = pty:id(), flex = DEFAULT_FLEX }

        if not state.root then
            -- First terminal
            state.root = new_pane
            state.focused_id = new_pane.id

            -- Auto-spawn second terminal for convenience
            prise.log.info("Lua: spawning second terminal")
            prise.spawn({})
            state.pending_split = { direction = "row" }
        else
            -- Insert into tree
            local direction = (state.pending_split and state.pending_split.direction) or "row"

            if state.focused_id then
                state.root = insert_split_recursive(state.root, state.focused_id, new_pane, direction)
            else
                -- Fallback
                if is_split(state.root) then
                    table.insert(state.root.children, new_pane)
                else
                    state.root = {
                        type = "split",
                        direction = direction,
                        flex = DEFAULT_FLEX,
                        children = { state.root, new_pane },
                    }
                end
            end

            state.focused_id = new_pane.id
            state.pending_split = nil
        end
        prise.request_frame()
    elseif event.type == "key_press" then
        -- Handle pending command mode (after Ctrl+b)
        if state.pending_command then
            local handled = false
            local k = event.data.key

            if k == "h" then
                move_focus("left")
                handled = true
            elseif k == "l" then
                move_focus("right")
                handled = true
            elseif k == "j" then
                move_focus("down")
                handled = true
            elseif k == "k" then
                move_focus("up")
                handled = true
            elseif k == "H" then
                resize_pane("width", -RESIZE_STEP)
                handled = true
            elseif k == "L" then
                resize_pane("width", RESIZE_STEP)
                handled = true
            elseif k == "J" then
                resize_pane("height", RESIZE_STEP)
                handled = true
            elseif k == "K" then
                resize_pane("height", -RESIZE_STEP)
                handled = true
            elseif k == "%" or k == "v" then
                -- Split horizontal (side-by-side)
                prise.spawn({})
                state.pending_split = { direction = "row" }
                handled = true
            elseif k == '"' or k == "'" or k == "s" then
                -- Split vertical (top-bottom)
                prise.spawn({})
                state.pending_split = { direction = "col" }
                handled = true
            end

            if handled then
                if state.timer then
                    state.timer:cancel()
                    state.timer = nil
                end
                state.pending_command = false
                state.status_bg = "white"
                prise.request_frame()
                return
            end

            -- Reset timeout
            if state.timer then
                state.timer:cancel()
            end
            state.timer = prise.set_timeout(1000, function()
                if state.pending_command then
                    state.pending_command = false
                    state.status_bg = "white"
                    state.timer = nil
                    prise.request_frame()
                end
            end)
            return
        end

        -- Ctrl+b to enter command mode
        if event.data.key == "b" and event.data.ctrl then
            state.pending_command = true
            state.status_bg = "magenta"
            prise.request_frame()
            state.timer = prise.set_timeout(1000, function()
                if state.pending_command then
                    state.pending_command = false
                    state.status_bg = "white"
                    state.timer = nil
                    prise.request_frame()
                end
            end)
            return
        end

        -- Pass key to focused PTY
        if state.root and state.focused_id then
            local path = find_node_path(state.root, state.focused_id)
            if path then
                local pane = path[#path]
                pane.pty:send_key(event.data)
            end
        end
    elseif event.type == "pty_exited" then
        local id = event.data.id
        prise.log.info("Lua: pty_exited " .. id)

        local new_root, next_focus = remove_pane_recursive(state.root, id)
        state.root = new_root

        if not state.root then
            prise.quit()
        else
            -- If focused pane is gone, focus another one
            if state.focused_id == id then
                if next_focus then
                    state.focused_id = next_focus
                else
                    local first = get_first_leaf(state.root)
                    if first then
                        state.focused_id = first.id
                    end
                end
            end
        end
        prise.request_frame()
    elseif event.type == "mouse" then
        local d = event.data
        if d.action == "press" and d.button == "left" then
            -- Focus the clicked pane
            if d.target then
                state.focused_id = d.target
                prise.request_frame()
            end
        end
        -- Forward mouse events to the target PTY if there is one
        if d.target and state.root then
            local path = find_node_path(state.root, d.target)
            if path then
                local pane = path[#path]
                pane.pty:send_mouse({
                    x = d.target_x or 0,
                    y = d.target_y or 0,
                    button = d.button,
                    event_type = d.action,
                    mods = d.mods,
                })
            end
        end
    elseif event.type == "winsize" then
        prise.request_frame()
    end
end

-- Recursive rendering function
local function render_node(node)
    if is_pane(node) then
        local is_focused = (node.id == state.focused_id)
        return prise.Terminal({
            pty = node.pty,
            flex = node.flex or DEFAULT_FLEX,
            show_cursor = is_focused,
        })
    elseif is_split(node) then
        local children_widgets = {}
        for _, child in ipairs(node.children) do
            table.insert(children_widgets, render_node(child))
        end

        local props = {
            children = children_widgets,
            flex = node.flex or DEFAULT_FLEX,
            cross_axis_align = "stretch",
        }

        if node.direction == "row" then
            return prise.Row(props)
        else
            return prise.Column(props)
        end
    end
end

function M.view()
    if not state.root then
        return prise.Column({
            cross_axis_align = "stretch",
            children = { prise.Text("Waiting for terminal...") },
        })
    end

    local content = render_node(state.root)

    -- Status bar logic
    local title = " Prise Terminal "
    if state.focused_id then
        local path = find_node_path(state.root, state.focused_id)
        if path then
            local pane = path[#path]
            local t = pane.pty:title()
            if t and #t > 0 then
                title = " " .. t .. " "
            end
        end
    end

    return prise.Column({
        cross_axis_align = "stretch",
        children = {
            content,
            prise.Text({
                text = title,
                style = { bg = state.status_bg, fg = "black" },
            }),
        },
    })
end

return M
