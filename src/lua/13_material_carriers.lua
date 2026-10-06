 
 
 
 

local function load_armor_variant_config(body_id)
    if not body_id or body_id == "" then
        return nil, "empty body id"
    end
    local path = "ArmorVariantManager/" .. tostring(body_id) .. ".json"
    local ok, data = pcall(function()
        return json.load_file(path)
    end)
    if ok and type(data) == "table" then
        return data, path
    end
    return nil, "failed to load " .. path .. ": " .. tostring(data)
end

local function get_armor_variant_manager_api()
    local ok_global, api = pcall(function()
        return _G and _G.NPCModelBridge_ArmorVariantManager
    end)
    if ok_global and type(api) == "table" then
        return api
    end
    return nil
end


local function collection_count(collection)
    if not collection then
        return nil
    end
    if type(collection) == "table" then
        return #collection
    end
    local ok_count, count = safe_call(collection, "get_Count")
    if ok_count and tonumber(count) then
        return tonumber(count)
    end
    local ok_len, len = safe_call(collection, "get_Length")
    if ok_len and tonumber(len) then
        return tonumber(len)
    end
    return nil
end

local function collection_item(collection, index)
    if not collection then
        return nil
    end
    if type(collection) == "table" then
        return collection[index + 1]
    end
    local ok_item, item = safe_call(collection, "get_Item", index)
    if ok_item then
        return item
    end
    return nil
end

local function is_mesh_component(component)
    if not component then
        return false
    end
    local ok_type, type_def = pcall(function()
        return component:get_type_definition()
    end)
    if ok_type and type_def then
        local ok_name, full_name = pcall(function()
            return type_def:get_full_name()
        end)
        return ok_name and full_name == "via.render.Mesh"
    end
    return false
end

local function collect_mesh_components_recursive(game_obj, limit)
    local meshes = {}
    local seen_meshes = {}
    local visited = {}
    local count = 0
    limit = tonumber(limit) or 128
    local mesh_type = get_runtime_type("via.render.Mesh")
    local function remember(mesh)
        if not mesh then
            return
        end
        local key = tostring(mesh)
        if seen_meshes[key] then
            return
        end
        seen_meshes[key] = true
        table.insert(meshes, mesh)
    end
    local function remember_all_mesh_components(actual)
        local ok_components, components = safe_call(actual, "get_Components")
        if ok_components and components then
            local total = collection_count(components)
            if total and total > 0 then
                for i = 0, total - 1 do
                    local component = collection_item(components, i)
                    if is_mesh_component(component) then
                        remember(component)
                    end
                end
            end
        end
        if mesh_type then
            local ok_mesh, mesh = safe_call(actual, "getComponent(System.Type)", mesh_type)
            if ok_mesh and mesh then
                remember(mesh)
            end
        end
    end
    local function visit(obj, depth)
        if not is_valid_managed_object(obj) or depth > 6 or count >= limit then
            return
        end
        local key = tostring(obj)
        if visited[key] then
            return
        end
        visited[key] = true
        count = count + 1
        local actual = get_game_object(obj) or obj
        remember_all_mesh_components(actual)
        local transform = get_transform(actual)
        if not transform then
            return
        end
        local ok_child, child = safe_call(transform, "get_Child")
        while ok_child and child and count < limit do
            local ok_obj, child_obj = safe_call(child, "get_GameObject")
            if ok_obj and child_obj then
                visit(child_obj, depth + 1)
            end
            ok_child, child = safe_call(child, "get_Next")
        end
    end
    visit(game_obj, 0)
    return meshes
end

local ARMOR_VARIANT_PART_SUFFIX_BY_INDEX = {
    [0] = "3",
    [1] = "2",
    [2] = "1",
    [3] = "5",
    [4] = "4",
    [5] = "6"
}

local function build_armor_variant_part_name(body_id, part_index)
    local suffix = ARMOR_VARIANT_PART_SUFFIX_BY_INDEX[tonumber(part_index)]
    if not suffix then
        return nil
    end
    local prefix = string.match(tostring(body_id or ""), "^(ch%d%d_%d%d%d_%d%d%d)")
    if not prefix then
        return nil
    end
    return prefix .. suffix
end

local function is_private_face_or_native_chain_name(name)
    local text = tostring(name or "")
    local prefix = string.sub(text, 1, 4)
    return prefix == "ch00" or prefix == "ch01" or prefix == "ch04"
end

local function count_material_matches_for_part(part_obj, part_data)
    local result = {
        mesh_count = 0,
        materials_checked = 0,
        material_matches = 0
    }
    if not part_obj or type(part_data) ~= "table" then
        return result
    end
    local meshes = collect_mesh_components_recursive(part_obj)
    result.mesh_count = #meshes
    if type(part_data.materials) ~= "table" then
        return result
    end
    for _, mesh in ipairs(meshes) do
        local ok_count, material_count = safe_call(mesh, "get_MaterialNum")
        local count = tonumber(material_count) or 0
        if ok_count and count > 0 then
            for material_index = 0, count - 1 do
                result.materials_checked = result.materials_checked + 1
                local ok_name, material_name = safe_call(mesh, "getMaterialName", material_index)
                if ok_name and material_name ~= nil and part_data.materials[tostring(material_name)] ~= nil then
                    result.material_matches = result.material_matches + 1
                end
            end
        end
    end
    return result
end

 
local function collect_armor_variant_part_candidates(character, root_obj, body_id, part_index, part_data, extra_roots)
    local candidates = {}
    local seen = {}
    local expected_name = build_armor_variant_part_name(body_id, part_index)
    local function add(obj, source)
        if not obj then
            return
        end
        local actual = get_game_object(obj) or obj
        if not actual then
            return
        end
        local key = tostring(actual)
        if seen[key] then
            return
        end
        seen[key] = true
        local name = get_game_object_name(actual)
        local match_counts = count_material_matches_for_part(actual, part_data)
        local exact_part_name = expected_name and lower_contains(name, expected_name) or false
        local prefix = string.sub(tostring(name or ""), 1, 4)
        local is_hunter_armor = prefix == "ch02" or prefix == "ch03"
        local blocked_private_chain = is_private_face_or_native_chain_name(name)
        local score = 0
        if exact_part_name then
            score = score + 1000
        elseif is_hunter_armor then
            score = score + 250
        elseif blocked_private_chain then
            score = score - 500
        end
        score = score + (match_counts.material_matches * 20) + match_counts.mesh_count
        if blocked_private_chain and match_counts.material_matches == 0 then
            score = score - 500
        end
        table.insert(candidates, {
            obj = actual,
            name = name,
            source = source,
            expected_name = expected_name or "",
            exact_part_name = exact_part_name,
            is_hunter_armor = is_hunter_armor,
            blocked_private_chain = blocked_private_chain,
            mesh_count = match_counts.mesh_count,
            materials_checked = match_counts.materials_checked,
            material_matches = match_counts.material_matches,
            score = score
        })
    end
    local ok_part, part = safe_call(character, "getParts", part_index)
    if ok_part and part then
        add(part, "character.getParts")
    end
    if root_obj then
        for _, obj in ipairs(collect_child_game_objects(root_obj)) do
            local actual = get_game_object(obj) or obj
            local name = get_game_object_name(actual)
            local prefix = string.sub(tostring(name or ""), 1, 4)
            if (expected_name and lower_contains(name, expected_name)) or prefix == "ch02" or prefix == "ch03" then
                add(actual, "root.armor")
            end
        end
    end
    if type(extra_roots) == "table" then
        for _, obj in ipairs(extra_roots) do
            add(obj, "event.pl_equip")
        end
    end
    return candidates
end

local function is_usable_armor_variant_candidate(candidate, part_data)
    if not candidate or candidate.mesh_count <= 0 then
        return false
    end
    if candidate.material_matches > 0 then
        return true
    end
    if type(part_data) == "table" and type(part_data.materials) == "table" and next(part_data.materials) ~= nil then
        return candidate.exact_part_name and not candidate.blocked_private_chain
    end
    return (candidate.exact_part_name or candidate.is_hunter_armor) and not candidate.blocked_private_chain
end

 
local function choose_armor_variant_part_for_index(character, root_obj, body_id, part_index, part_data, operation, extra_roots)
    local candidates = collect_armor_variant_part_candidates(character, root_obj, body_id, part_index, part_data, extra_roots)
    local best = nil
    for _, candidate in ipairs(candidates) do
        if is_usable_armor_variant_candidate(candidate, part_data) then
            if not best or candidate.score > best.score then
                best = candidate
            end
        end
    end
    if operation then
        if type(operation.part_candidate_trace) ~= "table" then
            operation.part_candidate_trace = {}
        end
        local trace = {}
        for _, candidate in ipairs(candidates) do
            table.insert(trace, {
                name = tostring(candidate.name or ""),
                source = tostring(candidate.source or ""),
                expected_name = tostring(candidate.expected_name or ""),
                exact_part_name = candidate.exact_part_name == true,
                is_hunter_armor = candidate.is_hunter_armor == true,
                blocked_private_chain = candidate.blocked_private_chain == true,
                mesh_count = candidate.mesh_count,
                materials_checked = candidate.materials_checked,
                material_matches = candidate.material_matches,
                score = candidate.score
            })
        end
        operation.part_candidate_trace[tostring(part_index)] = trace
        if best then
            operation.part_object_names[tostring(part_index)] = get_game_object_name(best.obj)
            operation.part_match_counts[tostring(part_index)] = best.material_matches
            operation.part_selection_sources[tostring(part_index)] = tostring(best.source or "")
            if best.material_matches > 0 then
                operation.armor_variant_carrier_strategy = "material_match"
            elseif operation.armor_variant_carrier_strategy == "" then
                operation.armor_variant_carrier_strategy = "exact_armor_part"
            end
        end
    end
    return best and best.obj or nil
end
