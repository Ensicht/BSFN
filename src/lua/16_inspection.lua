 
 
 
 

 
local function inspect_character(character, source, resolution, cache_entry, options)
    if not config.enabled or not character then
        return false, "disabled or nil character"
    end
    options = options or {}
    local root_obj = options.root_obj or get_game_object(character)
    if not root_obj then
        return false, "no root game object"
    end
    local resolution_npc_id = resolution and resolution.npc_id or nil
    local is_player, player_reason = is_any_player_character(character, root_obj, resolution_npc_id == nil)
    if is_player then
        reject_normal_player_character(character, root_obj, cache_entry, player_reason)
        return false, "player_character_rejected"
    end
    local match_status = nil
    if not resolution then
        cache_entry = cache_entry or {}
        resolution, match_status = resolve_target(character, root_obj, cache_entry, options.resolve_options)
    end
    if not resolution or not resolution.target then
        return false, tostring(match_status or "unmatched")
    end
    local target = resolution.target
    local body_id = resolution.body_id
    local match_source = resolution.match_source
    local identity = "npc_id=" .. tostring(resolution.npc_id or "") .. ";chest=" .. tostring(resolution.chest_state and resolution.chest_state.chest_name or "")
    stats.matched = stats.matched + 1
    stats.inspected = stats.inspected + 1
    stats.candidates_ready = 0

    local bone_body_id = target.bone_system_body_id or body_id or target.body_id
    local bone_data, bone_source = load_bone_config(bone_body_id)
    local candidates = build_candidates(root_obj, body_id or target.body_id, options.extra_roots)
    local edit_region_trace = build_edit_region_trace(character, root_obj, candidates, bone_data, target)
    local candidate_reports = {}
    local final_ok = false
    local final_status = "no ready candidate"
    local expected_readiness_signature = options.expected_readiness_signature

    for _, candidate in ipairs(candidates) do
        local normal_bone_state
        local report, motion, custom_skeleton = inspect_candidate(candidate.obj, candidate.label)
        if expected_readiness_signature then
            local current_state, readiness_error = probe_candidate_bone_state(candidate.obj, candidate.label)
            report.joints_constructed = current_state and current_state.joints_constructed == true or false
            report.readiness_status = current_state and "ready" or tostring(readiness_error or "not ready")
            report.readiness_signature_match = current_state and current_state.signature == expected_readiness_signature or false
            if current_state and current_state.signature == expected_readiness_signature then
                motion = current_state.motion
                custom_skeleton = current_state.custom_skeleton
                normal_bone_state = current_state
            else
                motion = nil
                custom_skeleton = nil
                if current_state then
                    final_status = "bone readiness changed before apply"
                end
            end
        end
        table.insert(candidate_reports, report)
        if not final_ok and motion and custom_skeleton and bone_data then
            if config.auto_apply_bone == false then
                final_ok = true
                final_status = "bone disabled by config"
            else
                stats.stage_attempts = stats.stage_attempts + 1
                local nonhuman_plan = cache_entry and registered[tostring(character)] == cache_entry
                    and expected_readiness_signature and nonhuman_ik.prepare(candidate, normal_bone_state, cache_entry, bone_data)
                local fingers_plan = cache_entry and registered[tostring(character)] == cache_entry
                    and expected_readiness_signature and nonhuman_fingers.prepare(candidate, normal_bone_state, cache_entry, bone_data)
                local forefoot_plan = cache_entry and registered[tostring(character)] == cache_entry
                    and expected_readiness_signature and nonhuman_forefoot.prepare(candidate, normal_bone_state, cache_entry, bone_data, body_id or target.body_id)
                final_ok, final_status = perform_stage(candidate, motion, custom_skeleton, target, bone_body_id, bone_data)
                if nonhuman_plan then nonhuman_ik.finish(nonhuman_plan, final_ok, cache_entry) end
                if fingers_plan then nonhuman_fingers.finish(fingers_plan, final_ok, cache_entry) end
                if forefoot_plan then nonhuman_forefoot.finish(forefoot_plan, final_ok, cache_entry) end
                if final_ok then
                    stats.stage_ok = stats.stage_ok + 1
                end
            end
        end
    end

    if not bone_data then
        final_status = tostring(bone_source)
    end

    local armor_variant_ok = false
    local armor_variant_status = "not attempted"
    if final_ok then
        armor_variant_ok, armor_variant_status = apply_armor_variant_with_api(character, target, bone_body_id or body_id or target.body_id, options)
    end

    local inspection = {
        time = os.clock(),
        source = source,
        target = target.display_name or target.npc_id,
        body_id = body_id or target.body_id,
        bone_body_id = bone_body_id,
        bone_source = tostring(bone_source),
        root = tostring(root_obj),
        root_name = get_game_object_name(root_obj),
        identity = trim_text(identity, 1200),
        candidate_count = #candidates,
        candidates = candidate_reports,
        edit_region_trace = edit_region_trace,
        status = tostring(final_status),
        armor_variant_status = tostring(armor_variant_status),
        armor_variant_ok = armor_variant_ok,
        private_face_mode = use_private_face_mode(target),
        ok = final_ok
    }
    table.insert(diagnostics.inspections, inspection)
    while #diagnostics.inspections > 8 do
        table.remove(diagnostics.inspections, 1)
    end

    local label = tostring(target.display_name or target.npc_id or "target")
    stats.last_status = label .. " via " .. tostring(match_source or source) .. ": " .. tostring(final_status)
    if not final_ok then
        stats.last_error = tostring(final_status)
    end
    record_event(final_ok and "stage_ok" or "stage_failed", stats.last_status)
    if options.defer_report ~= true then
        write_report(true)
    end
    bs_log(stats.last_status)
    return final_ok, stats.last_status, target, body_id or target.body_id, bone_body_id, armor_variant_status, armor_variant_ok
end
