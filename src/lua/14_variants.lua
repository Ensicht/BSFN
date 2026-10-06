 
 
 
 

local function merge_armor_variant_part_data(target_preset, source_preset)
    if type(source_preset) ~= "table" then
        return
    end
    for part_key, part_data in pairs(source_preset) do
        if type(part_data) == "table" then
            local target_part = target_preset[tostring(part_key)]
            if type(target_part) ~= "table" then
                target_part = {}
                target_preset[tostring(part_key)] = target_part
            end
            if part_data.mesh_enabled ~= nil then
                target_part.mesh_enabled = part_data.mesh_enabled == true
            end
            if type(part_data.materials) == "table" then
                if type(target_part.materials) ~= "table" then
                    target_part.materials = {}
                end
                for material_name, enabled in pairs(part_data.materials) do
                    target_part.materials[tostring(material_name)] = enabled == true
                end
            end
        end
    end
end

local function merge_armor_variant_global_hidden(target_preset, source_preset)
    if type(source_preset) ~= "table" then
        return
    end
    for part_key, part_data in pairs(source_preset) do
        if type(part_data) == "table" and type(part_data.materials) == "table" then
            local target_part = target_preset[tostring(part_key)]
            if type(target_part) ~= "table" then
                target_part = {}
                target_preset[tostring(part_key)] = target_part
            end
            if type(target_part.materials) ~= "table" then
                target_part.materials = {}
            end
            for material_name, enabled in pairs(part_data.materials) do
                if enabled == false then
                    target_part.materials[tostring(material_name)] = false
                end
            end
        end
    end
end

 
local function build_static_armor_variant_preset(avm_data)
    local preset = {}
    local used = { source = "static", default_preset = "", group_presets = {} }
    if type(avm_data) ~= "table" then
        return preset, used
    end
    if type(avm_data.presets) == "table" and avm_data.default_preset and type(avm_data.presets[avm_data.default_preset]) == "table" then
        merge_armor_variant_part_data(preset, avm_data.presets[avm_data.default_preset])
        used.default_preset = tostring(avm_data.default_preset)
    end
    if type(avm_data.groups) == "table" then
        for group_name, group_data in pairs(avm_data.groups) do
            if type(group_data) == "table"
                and group_data.is_global ~= true
                and group_data.default_preset
                and type(group_data.presets) == "table" then
                local group_preset = group_data.presets[group_data.default_preset]
                if type(group_preset) == "table" then
                    merge_armor_variant_part_data(preset, group_preset)
                    table.insert(used.group_presets, tostring(group_name) .. ":" .. tostring(group_data.default_preset))
                end
            end
        end
        for group_name, group_data in pairs(avm_data.groups) do
            if type(group_data) == "table"
                and group_data.is_global == true
                and group_data.default_preset
                and type(group_data.presets) == "table" then
                local group_preset = group_data.presets[group_data.default_preset]
                if type(group_preset) == "table" then
                    merge_armor_variant_global_hidden(preset, group_preset)
                    table.insert(used.group_presets, tostring(group_name) .. ":" .. tostring(group_data.default_preset))
                end
            end
        end
    end
    return preset, used
end

 
local function apply_builtin_armor_variant(character, target, body_id, avm_data, avm_source, options)
    local operation = {
        time = os.clock(),
        mode = "armor_variant_builtin",
        body_id = tostring(body_id or ""),
        target = tostring(target and (target.display_name or target.npc_id or target.body_id) or "target"),
        config_source = tostring(avm_source or ""),
        armor_variant_mode = tostring(config.armor_variant_mode or "static_defaults"),
        parts_checked = 0,
        parts_found = 0,
        parts_with_mesh = 0,
        mesh_components_checked = 0,
        mesh_requests = 0,
        mesh_changed = 0,
        mesh_set_failed = 0,
        materials_checked = 0,
        materials_matched = 0,
        materials_changed = 0,
        material_set_failed = 0,
        material_trace = {},
        part_object_names = {},
        part_match_counts = {},
        part_selection_sources = {},
        part_candidate_trace = {},
        armor_variant_carrier_strategy = "",
        status = "not attempted"
    }
    local trace_lookup = {}
    local trace_list = config.armor_variant_trace_materials
    if type(trace_list) ~= "table" then
        trace_list = default_config.armor_variant_trace_materials
    end
    if type(trace_list) == "table" then
        for _, material_name in pairs(trace_list) do
            trace_lookup[tostring(material_name)] = true
        end
    end
    local trace_limit = tonumber(config.armor_variant_trace_limit) or 64
    local function trace_material(part_index, part_obj, material_index, material_name, desired_material, ok_current, current_material, set_attempted, ok_set)
        if not material_name or not trace_lookup[tostring(material_name)] then
            return
        end
        if #operation.material_trace >= trace_limit then
            return
        end
        table.insert(operation.material_trace, {
            part_index = part_index,
            part_object = get_game_object_name(part_obj),
            material_index = material_index,
            material_name = tostring(material_name),
            desired = desired_material,
            current_ok = ok_current == true,
            current = current_material,
            set_attempted = set_attempted == true,
            set_ok = ok_set == true
        })
    end
    if operation.armor_variant_mode ~= "static_defaults" then
        operation.status = "builtin ArmorVariant mode unsupported: " .. operation.armor_variant_mode
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    stats.armor_variant_attempts = stats.armor_variant_attempts + 1
    options = options or {}
    local root_obj = options.root_obj or get_game_object(character) or character
    if not root_obj then
        operation.status = "no character game object"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    local preset, used = build_static_armor_variant_preset(avm_data)
    operation.default_preset = tostring(used.default_preset or "")
    operation.group_presets = used.group_presets
    if not next(preset) then
        operation.status = "no ArmorVariant preset data"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    for part_index = 0, 5 do
        local part_data = preset[tostring(part_index)]
        if type(part_data) == "table" then
            operation.parts_checked = operation.parts_checked + 1
            local part_obj = choose_armor_variant_part_for_index(character, root_obj, body_id, part_index, part_data, operation, options.extra_roots)
            if part_obj then
                operation.parts_found = operation.parts_found + 1
                local meshes = collect_mesh_components_recursive(part_obj)
                if #meshes > 0 then
                    operation.parts_with_mesh = operation.parts_with_mesh + 1
                    operation.mesh_components_checked = operation.mesh_components_checked + #meshes
                    if part_data.mesh_enabled ~= nil then
                        operation.mesh_requests = operation.mesh_requests + 1
                        local desired_mesh = part_data.mesh_enabled == true
                        local target_obj = get_game_object(part_obj) or part_obj
                        local ok_enabled, current_enabled = safe_call(target_obj, "get_Enabled")
                        if not ok_enabled or current_enabled ~= desired_mesh then
                            local ok_set = safe_call(target_obj, "set_Enabled", desired_mesh)
                            if ok_set then
                                operation.mesh_changed = operation.mesh_changed + 1
                            else
                                operation.mesh_set_failed = operation.mesh_set_failed + 1
                            end
                        end
                    end
                    if type(part_data.materials) == "table" then
                        for _, mesh in ipairs(meshes) do
                            local ok_count, material_count = safe_call(mesh, "get_MaterialNum")
                            local count = tonumber(material_count) or 0
                            if ok_count and count > 0 then
                                for material_index = 0, count - 1 do
                                    operation.materials_checked = operation.materials_checked + 1
                                    local ok_name, material_name = safe_call(mesh, "getMaterialName", material_index)
                                    local material_text = nil
                                    local desired_material = nil
                                    if ok_name and material_name ~= nil then
                                        material_text = tostring(material_name)
                                        desired_material = part_data.materials[material_text]
                                    end
                                    if desired_material ~= nil then
                                        desired_material = desired_material == true
                                        operation.materials_matched = operation.materials_matched + 1
                                        local ok_current, current_material = safe_call(mesh, "getMaterialsEnable", material_index)
                                        local set_attempted = false
                                        local ok_set = nil
                                        if not ok_current or current_material ~= desired_material then
                                            set_attempted = true
                                            ok_set = safe_call(mesh, "setMaterialsEnable", material_index, desired_material)
                                            if ok_set then
                                                operation.materials_changed = operation.materials_changed + 1
                                            else
                                                operation.material_set_failed = operation.material_set_failed + 1
                                            end
                                        end
                                        trace_material(part_index, part_obj, material_index, material_text, desired_material, ok_current, current_material, set_attempted, ok_set)
                                    elseif material_text and trace_lookup[material_text] then
                                        local ok_current, current_material = safe_call(mesh, "getMaterialsEnable", material_index)
                                        trace_material(part_index, part_obj, material_index, material_text, nil, ok_current, current_material, false, nil)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if operation.materials_matched > 0 then
        operation.status = "builtin static ArmorVariant applied parts=" .. tostring(operation.parts_with_mesh) .. " material_matches=" .. tostring(operation.materials_matched) .. " material_changes=" .. tostring(operation.materials_changed) .. " carrier=" .. tostring(operation.armor_variant_carrier_strategy or "")
        stats.armor_variant_ok = stats.armor_variant_ok + 1
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return true, operation.status
    end
    if operation.parts_with_mesh > 0 then
        operation.status = "builtin static ArmorVariant found parts but no matching material; possible wrong carrier"
    else
        operation.status = "builtin static ArmorVariant found no matching part/material"
    end
    diagnostics.armor_variant = operation
    remember_operation(operation)
    return false, operation.status
end
 
 
local function apply_armor_variant_with_api(character, target, body_id, options)
    local operation = {
        time = os.clock(),
        mode = "armor_variant",
        body_id = tostring(body_id or ""),
        target = tostring(target and (target.display_name or target.npc_id or target.body_id) or "target"),
        status = "not attempted"
    }
    if config.auto_sync_armor_variant == false then
        operation.status = "disabled by config"
        diagnostics.armor_variant = operation
        return false, operation.status
    end
    local configured_avm_body_id = target and target.armor_variant_body_id or nil
    local avm_body_id = nil
    local configured_avm_id_empty = configured_avm_body_id == nil
    if type(configured_avm_body_id) == "string" then
        configured_avm_body_id = string.match(configured_avm_body_id, "^%s*(.-)%s*$") or ""
        configured_avm_id_empty = configured_avm_body_id == ""
        if string.lower(configured_avm_body_id) == "static" then
            operation.mode = "armor_variant_static_package"
            operation.status = "static package materials; AVM sync skipped"
            diagnostics.armor_variant = operation
            remember_operation(operation)
            return true, operation.status
        elseif configured_avm_body_id ~= "" then
            avm_body_id = configured_avm_body_id
        end
    elseif configured_avm_body_id ~= nil then
        avm_body_id = tostring(configured_avm_body_id)
        configured_avm_id_empty = avm_body_id == ""
    end

    if not avm_body_id or avm_body_id == "" then
        if target then
            avm_body_id = target.body_id or body_id or target.bone_system_body_id
        else
            avm_body_id = body_id
        end
        if configured_avm_id_empty and avm_body_id and avm_body_id ~= "" then
            operation.config_id_resolution = "empty ArmorVariant config id; using body_id: " .. tostring(avm_body_id)
        end
    end
    if not avm_body_id or avm_body_id == "" then
        operation.mode = "armor_variant_default_state"
        operation.status = "ArmorVariant config id unavailable; using default material state"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return true, operation.status
    end

    operation.body_id = tostring(avm_body_id)
    local avm_data, avm_source = load_armor_variant_config(operation.body_id)
    operation.config_source = tostring(avm_source or "")
    operation.config_loaded = type(avm_data) == "table"
    if not avm_data then
        operation.mode = "armor_variant_default_state"
        operation.status = "ArmorVariant config not found; using default material state: " .. tostring(avm_source)
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return true, operation.status
    end
    if config.use_builtin_armor_variant_sync ~= false then
        return apply_builtin_armor_variant(character, target, operation.body_id, avm_data, avm_source, options)
    end
    if config.use_armor_variant_manager_api == false then
        operation.status = "ArmorVariantManager API disabled"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    local api = get_armor_variant_manager_api()
    operation.api_present = type(api) == "table"
    operation.api_apply_body_to_character_type = api and type(api.apply_body_to_character) or "nil"
    if not api or type(api.apply_body_to_character) ~= "function" then
        operation.status = "ArmorVariantManager API unavailable"
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    stats.armor_variant_attempts = stats.armor_variant_attempts + 1
    local ok, applied, status = pcall(api.apply_body_to_character, operation.body_id, character, true)
    operation.api_call_ok = ok
    operation.api_applied = applied == true
    operation.api_status = trim_text(status, 300)
    if not ok then
        operation.status = "ArmorVariantManager API error: " .. trim_text(applied, 300)
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return false, operation.status
    end
    if applied then
        operation.status = "ArmorVariantManager API " .. tostring(status or "applied")
        stats.armor_variant_ok = stats.armor_variant_ok + 1
        diagnostics.armor_variant = operation
        remember_operation(operation)
        return true, operation.status
    end
    operation.status = "ArmorVariantManager API " .. tostring(status or "not applied")
    diagnostics.armor_variant = operation
    remember_operation(operation)
    return false, operation.status
end
