-- =============================================================================
-- 配置保存与界面
-- =============================================================================
-- 仅保存用户选项；接管路径固定启用，不保存生成目标列表或已废弃的模式开关。

local function make_persisted_config()
    local persisted = copy_table(config or {})
    persisted.targets = nil
    persisted.manual_targets_enabled = nil
    persisted.auto_discover_bonesystem_outfits = nil
    return persisted
end

local function save_config()
    if not json or type(json.dump_file) ~= "function" then
        return
    end
    local ok, err = pcall(function()
        json.dump_file(CONFIG_PATH, make_persisted_config())
    end)
    if not ok then
        stats.last_error = "save_config: " .. tostring(err)
        record_event("save_config_failed", stats.last_error)
    end
end

local function checkbox(label, value)
    if not imgui or type(imgui.checkbox) ~= "function" then
        return false, value
    end
    local ok, a, b = pcall(imgui.checkbox, label, value)
    if ok and type(a) == "boolean" and type(b) == "boolean" then
        return a, b
    end
    if ok and type(a) == "boolean" then
        return a ~= value, a
    end
    return false, value
end

local function draw_bool(label, key)
    local changed, value = checkbox(label, config[key] == true)
    if changed then
        config[key] = value
        save_config()
        write_report(true)
    end
end

local function draw_ui()
    if not config.ui_enabled or not imgui or type(imgui.tree_node) ~= "function" then
        return
    end
    if not imgui.tree_node(MOD_NAME .. " v" .. VERSION) then
        return
    end

    draw_bool(T("enabled"), "enabled")

    if imgui.tree_node(T("language")) then
        local changed_zh, new_zh = checkbox(T("language_zh"), config.language == "zh")
        if changed_zh and new_zh then
            config.language = "zh"
            save_config()
        end
        local changed_en, new_en = checkbox(T("language_en"), config.language == "en")
        if changed_en and new_en then
            config.language = "en"
            save_config()
        end
        imgui.tree_pop()
    end

    if imgui.tree_node(T("advanced")) then
        draw_bool(T("auto_apply_face_mapping"), "auto_apply_face_mapping")
        draw_bool(T("auto_sync_armor_variant"), "auto_sync_armor_variant")
        imgui.tree_pop()
    end

    if imgui.tree_node(T("debug")) then
        draw_bool(T("write_report"), "write_report")
        draw_bool(T("debug_log"), "debug_log")
        if imgui.button(T("reload_config")) then
            load_config()
            write_report(true)
        end
        if imgui.button(T("write_report_now")) then
            local old_write_report = config.write_report
            config.write_report = true
            write_report(true)
            config.write_report = old_write_report
        end
        imgui.text(T("status") .. ": " .. tostring(stats.last_status))
        imgui.text(T("targets") .. ": manual=" .. tostring(stats.manual_targets) .. ", auto=" .. tostring(stats.auto_targets))
        imgui.text(T("scan") .. ": " .. tostring(stats.bone_system_configs))
        imgui.text(T("avm") .. ": " .. tostring(diagnostics.armor_variant and diagnostics.armor_variant.status or ""))
        imgui.tree_pop()
    end

    imgui.tree_pop()
end
