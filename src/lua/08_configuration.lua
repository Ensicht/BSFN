-- =============================================================================
-- 配置加载与双字典
-- =============================================================================
-- 扫描只在启动或重读时发生；成功覆盖索引，失败保留并回退上次快照。

local function normalize_target_path(path)
    local text = tostring(path or "")
    text = string.gsub(text, "\\", "/")
    text = string.gsub(text, "^%./", "")
    return text
end

local function canonical_data_path(path)
    local normalized = normalize_target_path(path)
    local lower = string.lower(normalized)
    local prefix = "reframework/data/"
    if string.sub(lower, 1, string.len(prefix)) == prefix then
        return string.sub(normalized, string.len(prefix) + 1)
    end
    return normalized
end

local function file_name_from_path(path)
    local normalized = normalize_target_path(path)
    return string.match(normalized, "([^/]+)$") or normalized
end

local function file_stem_from_path(path)
    return string.gsub(file_name_from_path(path), "%.json$", "")
end

local function is_npc_target_id(value)
    return type(value) == "string" and string.match(value, "^NPC%d+_%d+_%d+$") ~= nil
end

local function npc_id_from_target_path(path)
    local stem = file_stem_from_path(path)
    if is_npc_target_id(stem) then
        return stem
    end
    return nil
end

local function body_id_from_bone_config_path(path)
    return string.match(file_name_from_path(path), "^(ch%d%d_%d%d%d_%d%d%d%d)%.json$")
end

local function body_id_from_index_entry(entry)
    if type(entry) == "string" then
        return string.match(entry, "(ch%d%d_%d%d%d_%d%d%d%d)")
    end
    if type(entry) == "table" then
        return body_id_from_index_entry(entry.body_id or entry.id or entry.name or entry.path or entry.file)
    end
    return nil
end

local function path_preference(path, expected)
    if string.lower(canonical_data_path(path)) == string.lower(expected) then
        return 2
    end
    return 1
end

local function load_json_file(path)
    if not json or type(json.load_file) ~= "function" then
        return nil, "json.load_file unavailable"
    end
    local ok, data = pcall(function()
        return json.load_file(path)
    end)
    if ok and type(data) == "table" then
        return data, path
    end
    local canonical = canonical_data_path(path)
    if canonical ~= normalize_target_path(path) then
        local ok_canonical, canonical_data = pcall(function()
            return json.load_file(canonical)
        end)
        if ok_canonical and type(canonical_data) == "table" then
            return canonical_data, canonical
        end
        return nil, tostring(canonical_data)
    end
    return nil, tostring(data)
end

local function append_target(result, target, source_path)
    if type(target) ~= "table" or target.enabled == false then
        return 0
    end
    if target.enabled == nil then
        target.enabled = true
    end
    local file_npc_id = npc_id_from_target_path(source_path)
    local configured_npc_id = target.npc_id and tostring(target.npc_id) or nil
    if configured_npc_id == "" then
        configured_npc_id = nil
    end
    local npc_id = configured_npc_id or file_npc_id
    if not is_npc_target_id(npc_id) then
        record_event("target_skipped_invalid_npc_id", tostring(source_path or ""))
        return 0
    end
    if file_npc_id and configured_npc_id and configured_npc_id ~= file_npc_id then
        record_event("target_skipped_npc_id_mismatch", tostring(source_path or "") .. "; npc_id=" .. configured_npc_id)
        return 0
    end
    target.npc_id = npc_id
    target.source_file = canonical_data_path(source_path)
    table.insert(result, target)
    return 1
end

local function append_targets_from_data(result, data, source_path)
    if type(data) ~= "table" then
        return 0
    end
    local before = #result
    if type(data.targets) == "table" then
        for _, target in ipairs(data.targets) do
            append_target(result, target, source_path)
        end
    elseif type(data[1]) == "table" then
        for _, target in ipairs(data) do
            append_target(result, target, source_path)
        end
    else
        append_target(result, data, source_path)
    end
    return #result - before
end

local function load_target_file(path, result)
    local canonical = string.lower(canonical_data_path(path))
    if loaded_target_paths[canonical] then
        return 0
    end
    loaded_target_paths[canonical] = true
    local data, loaded_path_or_error = load_json_file(path)
    if type(data) ~= "table" then
        record_event("target_load_failed", tostring(path) .. ": " .. trim_text(loaded_path_or_error, 300))
        return 0
    end
    local count = append_targets_from_data(result, data, loaded_path_or_error)
    table.insert(diagnostics.target_files, { path = loaded_path_or_error, targets = count })
    return count
end

local function load_main_config()
    local data, loaded_path_or_error = load_json_file(CONFIG_PATH)
    local next_config = type(data) == "table" and data or {}
    merge_defaults(next_config, default_config)
    -- 两条接管路径固定启用；忽略旧开关，避免升级后沿用 false 而无处重新开启。
    next_config.manual_targets_enabled = nil
    next_config.auto_discover_bonesystem_outfits = nil
    if type(data) == "table" then
        record_event("config_loaded", loaded_path_or_error)
    else
        record_event("config_default", trim_text(loaded_path_or_error, 300))
    end
    return next_config
end

-- 索引是本机扫描快照，不是 NPC 包的配置；写入失败不能伪装成扫描失败。
local function replace_index_snapshot(path, payload)
    if not json or type(json.dump_file) ~= "function" then
        return false, "json.dump_file unavailable"
    end
    local ok, err = pcall(function()
        json.dump_file(path, payload)
    end)
    if not ok then
        return false, trim_text(err, 300)
    end
    return true, "updated"
end

local function load_bone_system_index_snapshot()
    local result = {}
    local seen = {}
    if config.use_bone_system_index == false then
        return result, false, "disabled"
    end
    local path = config.bone_system_index_path or BONE_SYSTEM_INDEX_PATH
    local data, loaded_path_or_error = load_json_file(path)
    if type(data) ~= "table" then
        return result, false, trim_text(loaded_path_or_error, 300)
    end
    local raw = data.body_ids or data.files or data
    if type(raw) ~= "table" then
        return result, false, "index has no body_ids"
    end
    for _, entry in ipairs(raw) do
        local body_id = body_id_from_index_entry(entry)
        if body_id and not seen[body_id] then
            seen[body_id] = true
            table.insert(result, body_id)
        end
    end
    table.sort(result)
    return result, #result > 0, loaded_path_or_error
end

-- REFramework 的 fs.glob 使用正则路径，不是 shell 的通配符；两种分隔符均需兼容。
local function scan_bone_system_configs()
    local scan = {
        patterns = {},
        paths = {},
        body_ids = {},
        files_by_body_id = {},
        errors = {},
        invalid = 0,
        successful_patterns = 0
    }
    local seen_paths = {}
    local patterns = config.bone_system_scan_patterns or DEFAULT_BONE_SYSTEM_SCAN_PATTERNS
    if not fs or type(fs.glob) ~= "function" then
        table.insert(scan.errors, "fs.glob unavailable")
    else
        for _, pattern in ipairs(patterns) do
            local pattern_report = { pattern = tostring(pattern), count = 0 }
            local ok, globbed = pcall(function()
                return fs.glob(pattern)
            end)
            if ok and type(globbed) == "table" then
                scan.successful_patterns = scan.successful_patterns + 1
                pattern_report.count = #globbed
                for _, path in ipairs(globbed) do
                    local normalized = canonical_data_path(path)
                    local path_key = string.lower(normalized)
                    if normalized ~= "" and not seen_paths[path_key] then
                        seen_paths[path_key] = true
                        table.insert(scan.paths, normalized)
                        local body_id = body_id_from_bone_config_path(normalized)
                        if body_id then
                            local expected = "BoneSystem/" .. body_id .. ".json"
                            local current = scan.files_by_body_id[body_id]
                            if not current then
                                scan.files_by_body_id[body_id] = normalized
                            else
                                local current_score = path_preference(current, expected)
                                local new_score = path_preference(normalized, expected)
                                if new_score > current_score then
                                    scan.files_by_body_id[body_id] = normalized
                                    remember_collision("bone_system", body_id, normalized, current)
                                else
                                    remember_collision("bone_system", body_id, current, normalized)
                                end
                            end
                        else
                            scan.invalid = scan.invalid + 1
                        end
                    end
                end
            else
                pattern_report.error = trim_text(globbed, 240)
                table.insert(scan.errors, tostring(pattern) .. ": " .. pattern_report.error)
            end
            table.insert(scan.patterns, pattern_report)
        end
    end
    for body_id in pairs(scan.files_by_body_id) do
        table.insert(scan.body_ids, body_id)
    end
    table.sort(scan.body_ids)
    scan.live_success = scan.successful_patterns > 0 and #scan.body_ids > 0
    diagnostics.bone_system_scan = scan
    diagnostics.bone_scan_status = scan.live_success and "live_success" or "live_failed"
    diagnostic_status("BoneScan", "status=" .. diagnostics.bone_scan_status .. " valid=" .. tostring(#scan.body_ids) .. " invalid=" .. tostring(scan.invalid))
    return scan
end

-- 保持稳定版语义：有效非空扫描才更新；扫描为空或报错时回退旧索引。
local function rebuild_auto_dictionary()
    auto_by_body_id = {}
    local old_ids, old_loaded = load_bone_system_index_snapshot()
    local scan = scan_bone_system_configs()
    local source_ids = nil
    local source_files = {}
    if scan.live_success then
        source_ids = scan.body_ids
        source_files = scan.files_by_body_id
        local ok_write, write_status = replace_index_snapshot(
            config.bone_system_index_path or BONE_SYSTEM_INDEX_PATH,
            {
                version = 1,
                source = "generated_from_live_bone_system_scan",
                generated_on = os.date("%Y-%m-%d"),
                body_ids = scan.body_ids
            }
        )
        diagnostics.bone_index_status = ok_write and "updated" or "write_failed"
        diagnostic_status("BoneIndex", "status=" .. diagnostics.bone_index_status .. " old=" .. tostring(#old_ids) .. " new=" .. tostring(#scan.body_ids) .. (ok_write and "" or " reason=" .. tostring(write_status)))
        diagnostics.auto_dictionary_source = "live"
    elseif old_loaded then
        source_ids = old_ids
        for _, body_id in ipairs(old_ids) do
            source_files[body_id] = "BoneSystem/" .. body_id .. ".json"
        end
        diagnostics.bone_index_status = "preserved"
        diagnostics.auto_dictionary_source = "index"
        diagnostic_status("BoneIndex", "status=preserved count=" .. tostring(#old_ids))
    else
        source_ids = {}
        diagnostics.bone_index_status = "unavailable"
        diagnostics.auto_dictionary_source = "none"
        diagnostic_status("BoneIndex", "status=unavailable")
    end

    for _, body_id in ipairs(source_ids) do
        auto_by_body_id[body_id] = {
            enabled = true,
            body_id = body_id,
            bone_system_body_id = body_id,
            private_face_mode = config.default_private_face_mode == true,
            auto_target = true,
            source_file = source_files[body_id] or ("BoneSystem/" .. body_id .. ".json")
        }
    end
    local targets = {}
    for _, body_id in ipairs(source_ids) do
        local target = auto_by_body_id[body_id]
        if target then
            table.insert(targets, target)
        end
    end
    diagnostics.auto_targets = targets
    stats.auto_targets = #targets
    stats.bone_system_configs = #source_ids
    local dictionary_status = diagnostics.auto_dictionary_source == "live" and "ready"
        or (diagnostics.auto_dictionary_source == "index" and "degraded_ready" or "unavailable")
    diagnostic_status("AutoDict", "status=" .. dictionary_status .. " count=" .. tostring(#targets) .. " source=" .. diagnostics.auto_dictionary_source .. " generation=" .. tostring(dictionary_generation))
end

local function scan_target_paths()
    local scan = {
        patterns = {},
        paths = {},
        errors = {},
        successful_patterns = 0,
        raw_count = 0
    }
    local seen = {}
    if not fs or type(fs.glob) ~= "function" then
        table.insert(scan.errors, "fs.glob unavailable")
    else
        for _, pattern in ipairs(TARGETS_GLOB_PATTERNS) do
            local pattern_report = { pattern = tostring(pattern), count = 0 }
            local ok, globbed = pcall(function()
                return fs.glob(pattern)
            end)
            if ok and type(globbed) == "table" then
                scan.successful_patterns = scan.successful_patterns + 1
                pattern_report.count = #globbed
                scan.raw_count = scan.raw_count + #globbed
                for _, path in ipairs(globbed) do
                    local normalized = canonical_data_path(path)
                    local key = string.lower(normalized)
                    if normalized ~= "" and not seen[key] then
                        seen[key] = true
                        table.insert(scan.paths, normalized)
                    end
                end
            else
                pattern_report.error = trim_text(globbed, 240)
                table.insert(scan.errors, tostring(pattern) .. ": " .. pattern_report.error)
            end
            table.insert(scan.patterns, pattern_report)
        end
    end
    table.sort(scan.paths)
    scan.live_success = scan.successful_patterns > 0 and scan.raw_count > 0
    diagnostics.target_scan_status = scan.live_success and "live_success" or "live_failed"
    diagnostic_status("TargetScan", "status=" .. diagnostics.target_scan_status .. " raw=" .. tostring(scan.raw_count))
    return scan
end

local function load_target_index_paths()
    local paths = {}
    local data, loaded_path_or_error = load_json_file(TARGET_INDEX_PATH)
    if type(data) ~= "table" then
        return paths, false, trim_text(loaded_path_or_error, 300)
    end
    local raw = data.files or data
    if type(raw) ~= "table" then
        return paths, false, "index has no files"
    end
    local seen = {}
    for _, entry in ipairs(raw) do
        local value = type(entry) == "table" and (entry.path or entry.file or entry.name) or entry
        if type(value) == "string" and value ~= "" then
            local path = string.find(value, "[/\\]") and canonical_data_path(value) or (TARGETS_DIR .. "/" .. value)
            local key = string.lower(path)
            if not seen[key] then
                seen[key] = true
                table.insert(paths, path)
            end
        end
    end
    table.sort(paths)
    return paths, true, loaded_path_or_error
end

local function build_manual_dictionary_from_paths(paths)
    local candidates = {}
    loaded_target_paths = {}
    for _, path in ipairs(paths or {}) do
        local file_name = string.lower(file_name_from_path(path))
        if file_name ~= "example.json" and file_name ~= "_index.json" and file_name ~= "targetindex.json" then
            load_target_file(path, candidates)
        end
    end
    local selected = {}
    for _, target in ipairs(candidates) do
        local npc_id = target.npc_id
        local current = selected[npc_id]
        if not current then
            selected[npc_id] = target
        else
            local expected = TARGETS_DIR .. "/" .. npc_id .. ".json"
            local current_score = path_preference(current.source_file, expected)
            local new_score = path_preference(target.source_file, expected)
            if new_score > current_score then
                selected[npc_id] = target
                remember_collision("manual_target", npc_id, target.source_file, current.source_file)
            else
                remember_collision("manual_target", npc_id, current.source_file, target.source_file)
            end
        end
    end
    return selected
end

local function sorted_manual_targets(dictionary)
    local ids = {}
    for npc_id in pairs(dictionary or {}) do
        table.insert(ids, npc_id)
    end
    table.sort(ids)
    local targets = {}
    local files = {}
    for _, npc_id in ipairs(ids) do
        table.insert(targets, dictionary[npc_id])
        table.insert(files, npc_id .. ".json")
    end
    return targets, files
end

-- 保留旧专属包的优先规则，但不以这些规则限制自动接管的 NPC 类别。
local function rebuild_manual_dictionary()
    manual_by_npc_id = {}
    local scan = scan_target_paths()
    local paths = nil
    if scan.live_success then
        paths = scan.paths
        diagnostics.manual_dictionary_source = "live"
        local live_dictionary = build_manual_dictionary_from_paths(paths)
        local _, files = sorted_manual_targets(live_dictionary)
        local ok_write, write_status = replace_index_snapshot(
            TARGET_INDEX_PATH,
            {
                version = 1,
                source = "generated_from_live_target_scan",
                generated_on = os.date("%Y-%m-%d"),
                files = files
            }
        )
        diagnostics.target_index_status = ok_write and "updated" or "write_failed"
        diagnostic_status("TargetIndex", "status=" .. diagnostics.target_index_status .. " files=" .. tostring(#files) .. (ok_write and "" or " reason=" .. tostring(write_status)))
        manual_by_npc_id = live_dictionary
    else
        local index_paths, index_loaded = load_target_index_paths()
        if index_loaded then
            paths = index_paths
            diagnostics.target_index_status = "preserved"
            diagnostics.manual_dictionary_source = "index"
            diagnostic_status("TargetIndex", "status=preserved files=" .. tostring(#index_paths))
            manual_by_npc_id = build_manual_dictionary_from_paths(index_paths)
        else
            diagnostics.target_index_status = "unavailable"
            diagnostics.manual_dictionary_source = "none"
            diagnostic_status("TargetIndex", "status=unavailable")
        end
        diagnostics.manual_targets = sorted_manual_targets(manual_by_npc_id)
    end
    local manual_targets = sorted_manual_targets(manual_by_npc_id)
    diagnostics.manual_targets = manual_targets
    stats.manual_targets = #manual_targets
    local dictionary_status = diagnostics.manual_dictionary_source == "live" and "ready"
        or (diagnostics.manual_dictionary_source == "index" and "degraded_ready" or "unavailable")
    diagnostic_status("ManualDict", "status=" .. dictionary_status .. " count=" .. tostring(#manual_targets) .. " source=" .. diagnostics.manual_dictionary_source .. " generation=" .. tostring(dictionary_generation))
end

-- 一次重读对应一个字典代际，旧目标缓存会在原更新路径中自然失效。
local function load_config()
    config = load_main_config()
    dictionary_generation = dictionary_generation + 1
    stats.dictionary_generation = dictionary_generation
    diagnostics.target_files = {}
    diagnostics.manual_targets = {}
    diagnostics.auto_targets = {}
    diagnostics.collisions = {}
    diagnostics.bone_system_scan = {}
    rebuild_manual_dictionary()
    rebuild_auto_dictionary()

    local combined = {}
    for _, target in ipairs(diagnostics.manual_targets) do
        table.insert(combined, target)
    end
    for _, target in ipairs(diagnostics.auto_targets) do
        table.insert(combined, target)
    end
    config.targets = combined
    target_cache = nil
end
