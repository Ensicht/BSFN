 
 
 
 

local function diagnostic_status(tag, message)
    record_event(tag, message)
    bs_log("[" .. tostring(tag) .. "] " .. tostring(message))
end

local function remember_collision(kind, key, kept, ignored)
    local collision = {
        time = os.clock(),
        kind = tostring(kind),
        key = tostring(key),
        kept = tostring(kept or ""),
        ignored = tostring(ignored or "")
    }
    table.insert(diagnostics.collisions, collision)
    while #diagnostics.collisions > 24 do
        table.remove(diagnostics.collisions, 1)
    end
    bs_log("[Collision] kind=" .. collision.kind .. " key=" .. collision.key .. " kept=" .. collision.kept .. " ignored=" .. collision.ignored)
end

local function remember_operation(operation)
    table.insert(diagnostics.operations, operation)
    while #diagnostics.operations > 16 do
        table.remove(diagnostics.operations, 1)
    end
end

local function get_targets()
    if target_cache then
        return target_cache
    end
    local result = {}
    if type(config.targets) == "table" then
        for _, target in ipairs(config.targets) do
            if target.enabled ~= false then
                table.insert(result, target)
            end
        end
    end
    target_cache = result
    return result
end

local function write_report(force)
    if config.write_report == false or not json or not json.dump_file then
        return
    end
    local now = os.clock()
    local interval = tonumber(config.report_interval) or 1.0
    if not force and now - diagnostics.last_report_time < interval then
        return
    end
    diagnostics.last_report_time = now
    pcall(function()
        local report = {
            mod = MOD_NAME,
            version = VERSION,
            api_present = type(API) == "table",
            api_fix_bone_type = type(API.fix_bone),
            api_load_data_type = type(API.load_data),
            enabled = config.enabled,
            mode = config.mode,
            enable_native_fix = config.enable_native_fix == true,
            dictionary_generation = dictionary_generation,
            bone_scan_status = diagnostics.bone_scan_status,
            bone_index_status = diagnostics.bone_index_status,
            auto_dictionary_count = stats.auto_targets,
            target_scan_status = diagnostics.target_scan_status,
            target_index_status = diagnostics.target_index_status,
            manual_dictionary_count = stats.manual_targets,
            auto_dictionary_source = diagnostics.auto_dictionary_source,
            manual_dictionary_source = diagnostics.manual_dictionary_source,
            performance = performance,
            recent_unmatched = diagnostics.recent_unmatched,
            collisions = diagnostics.collisions,
            hook_state = hook_state,
            stats = stats,
            targets = get_targets(),
            inspections = diagnostics.inspections,
            operations = diagnostics.operations,
            target_files = diagnostics.target_files,
            bone_system_scan = diagnostics.bone_system_scan,
            manual_targets = diagnostics.manual_targets,
            auto_targets = diagnostics.auto_targets,
            target_manual_overrides = diagnostics.target_manual_overrides,
            armor_variant = diagnostics.armor_variant,
            scene_transition = diagnostics.scene_transition,
            event_model_setups = diagnostics.event_model_setups,
            events = diagnostics.events
        }
        json.dump_file(REPORT_PATH, sanitize_report_value(report, 0))
    end)
end
