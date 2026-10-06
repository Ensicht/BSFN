-- =============================================================================
-- 结算动画接管：独立于普通 NPC 和艺术馆，不增加普通帧扫描。
-- =============================================================================
-- 在 WAIT-pre 应用骨架；结算动作内等待最终槽表后仅补全隐藏/表情。
-- 不写动作阶段、计时器、播放速度、根位移，也不保留任何 managed 对象。
local function install_quest_result_hooks()
    local states, state_order = {}, {}
    local paused = false
    local report_key = "quest_result"
    local quest = { calls = 0, attempts = 0, succeeded = 0, errors = 0, face_attempts = 0, hide_attempts = 0,
        recent_results = {},
        face_traces = {}, trace_samples = 0, trace_errors = 0, face_relays = {}, relay_errors = 0 }
    performance[report_key] = quest

    local function field(object, name)
        local ok, value = probe_field_quiet(object, name)
        if ok then return value end
    end

    local function call(object, name, ...)
        local ok, value = call_any(object, name, ...)
        if ok then return value end
    end

    -- 仅结算动作内采样；不枚举关节、不写姿态、不保存 managed 包装对象。
    local trace_offsets = { 0, 0, 0.15, 0.4, 0.8, 1.5, 3, 5 }
    local trace_joints = { "L_UpEyeLidJ_LOD02", "R_UpEyeLidJ_LOD02",
        "C_upLip_LOD02", "C_loLip_LOD02", "C_Jaw_LOD02" }

    local function vector_snapshot(value)
        if not value then return end
        local ok, result = pcall(function()
            local item = { x = tonumber(value.x), y = tonumber(value.y), z = tonumber(value.z) }
            -- Vector3 没有 w；不能因此丢弃整个位置/缩放快照。
            local has_w, w = pcall(function() return value.w end)
            if has_w then item.w = tonumber(w) end
            return item
        end)
        if ok then return result end
    end

    local function joint_snapshot(transform, name)
        local joint = transform and call(transform, "getJointByName", name)
        local item = { present = joint ~= nil }
        if not joint then return item end
        item.valid = tostring(call(joint, "get_Valid"))
        for _, property in ipairs({ "LocalPosition", "LocalRotation", "LocalScale",
            "BaseLocalPosition", "BaseLocalRotation", "BaseLocalScale" }) do
            item[property] = vector_snapshot(call(joint, "get_" .. property))
        end
        return item
    end

    local function motion_snapshot(motion, with_layers)
        local item = { object = tostring(motion) }
        if not motion then return item end
        for _, property in ipairs({ "Enabled", "EnabledConstraints", "EnabledJointExpression" }) do
            item[property] = tostring(call(motion, "get_" .. property))
        end
        if not with_layers then return item end
        item.joint_map = tostring(call(motion, "get_JointMap"))
        item.joints_constructed = tostring(call(motion, "get_JointsConstructed"))
        item.joint_count = tonumber(call(motion, "get_JointCount"))
        local layers = call(motion, "get_Layer")
        local count = tonumber(layers and call(layers, "get_Count")) or 0
        item.layer_count, item.layers = count, {}
        for index = 0, math.min(count, 12) - 1 do
            local layer = call(layers, "get_Item", index)
            local entry = { index = index }
            for _, property in ipairs({ "Frame", "MotionBankID", "MotionID", "BlendRate", "Speed",
                "Enabled", "Running", "StopUpdate", "UpdateRootOnly", "AnimatedJointCount" }) do
                entry[property] = tostring(layer and call(layer, "get_" .. property))
            end
            item.layers[#item.layers + 1] = entry
        end
        return item
    end

    local function edit_root_for(object)
        local root = object and get_component(object, "app.CharacterEditRegionRoot")
        if root then return root, "root" end
        local region = object and get_component(object, "app.CharacterEditRegion")
        return region and call(region, "getRoot"), region and "region.getRoot" or "missing"
    end

    local face_relay = make_quest_face_relay(field, call, edit_root_for, quest)

    -- 精确复现 DLL 回调的查找方向：驱动所属对象 -> RegionRoot -> Face。
    -- owner 槽只能作为对照，不能替代 DLL 实际读取的源脸。
    local function face_trace_snapshot(action, state, stage)
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        local root = edit_root_for(owner)
        local expected_face = root and call(root, "getPartsObject", 935285574)
        local bind_part = root and call(root, "getPartsObject", state.trace_bind_hash)
        local driver = bind_part and get_component(bind_part, "via.motion.Motion")
        local driver_kind = driver and "via.motion.Motion" or "via.motion.ChildSecondary"
        driver = driver or (bind_part and get_component(bind_part, driver_kind))
        local driver_owner = driver and get_game_object_quiet(driver)
        local bind_root, route = edit_root_for(driver_owner)
        local source_face = bind_root and call(bind_root, "getPartsObject", 935285574)
        local source_transform = source_face and get_transform(source_face)
        local target_transform = driver_owner and get_transform(driver_owner)
        local item = {
            stage = stage, time = os.clock(), offset = os.clock() - state.face_trace.started,
            phase = tonumber(field(action, "_Phase")), mot_phase = tonumber(field(action, "_MotPhase")),
            elapsed = tonumber(field(action, "_RawTotalElapsedSecond")),
            owner = tostring(owner), owner_root = tostring(root), expected_face = tostring(expected_face),
            bind_part = tostring(bind_part), driver = tostring(driver), driver_kind = driver_kind,
            driver_owner = tostring(driver_owner), bind_route = route, bind_root = tostring(bind_root),
            source_face = tostring(source_face), source_name = get_game_object_name_quiet(source_face),
            roots_agree = root ~= nil and bind_root ~= nil and same_runtime_object(root, bind_root),
            faces_agree = expected_face ~= nil and source_face ~= nil and same_runtime_object(expected_face, source_face),
            driver_unchanged = driver ~= nil and state.face_bind_driver_address ~= nil
                and quest_object_address(driver) == state.face_bind_driver_address,
            joints = {}, binding_motion = motion_snapshot(driver, driver_kind == "via.motion.Motion")
        }
        local face_motion = source_face and get_component(source_face, "via.motion.Motion")
        item.face_motion = motion_snapshot(face_motion, true)
        local controller = source_face and get_component(source_face, "app.FacialController")
        item.facial_controller = { object = tostring(controller) }
        if controller then
            for _, property in ipairs({ "_IsSetupDone", "_FaceObj", "_Motion", "_ParentObj",
                "_FacialMode", "_CurrentMotionSeqLayerNo", "_SeqMotionID", "_SeqMotionBankID",
                "_CurrentLodLevel", "_IsEventObj", "_SusependReduceFacial" }) do
                item.facial_controller[property] = tostring(field(controller, property))
            end
        end
        for _, name in ipairs(trace_joints) do
            item.joints[name] = { source = joint_snapshot(source_transform, name),
                target = joint_snapshot(target_transform, name) }
        end
        -- 查找链不一致时，仍保留 owner 原生脸的同名骨骼，避免把“查错脸”误判为不播放表情。
        if expected_face and not item.faces_agree then
            item.expected_face_joints = {}
            local transform = get_transform(expected_face)
            for _, name in ipairs(trace_joints) do item.expected_face_joints[name] = joint_snapshot(transform, name) end
        end
        return item
    end

    local function stop_face_trace(state, reason)
        state.trace_pending = nil
        if state.face_trace and state.face_trace.status == "sampling" then state.face_trace.status = reason end
    end

    local function sample_face_trace(action, state, stage)
        if not state.trace_pending then return end
        local trace = state.face_trace
        state.trace_checks = state.trace_checks + 1
        if not config.enabled or scene_transition.active or state.generation ~= scene_generation then
            stop_face_trace(state, "cancelled by lifecycle")
            return
        end
        if os.clock() - trace.started > 6 or state.trace_checks > 3000 then
            stop_face_trace(state, "sample budget ended")
            return
        end
        if os.clock() - trace.started < trace_offsets[#trace.samples + 1] then return end
        local phase = tonumber(field(action, "_Phase"))
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        local creator = field(action, "_NpcVisualCreator")
        local player = field(action, "_Chara")
        if (phase ~= 1 and phase ~= 2 and phase ~= 3) or quest_object_address(owner) ~= state.owner_address
            or quest_object_address(motion) ~= state.motion_address
            or not same_runtime_object(owner, get_game_object_quiet(creator))
            or get_component(owner, "app.HunterCharacter")
            or (player and same_runtime_object(owner, get_game_object_quiet(player))) then
            stop_face_trace(state, "action or owner changed")
            return
        end
        local ok, sample = pcall(face_trace_snapshot, action, state, stage)
        if not ok then
            trace.error = tostring(sample)
            quest.trace_errors = quest.trace_errors + 1
            stop_face_trace(state, "read failed")
            return
        end
        trace.samples[#trace.samples + 1] = sample
        quest.trace_samples = quest.trace_samples + 1
        if #trace.samples == #trace_offsets then stop_face_trace(state, "sampled") end
    end

    local function begin_face_trace(action, state, bind_hash)
        state.trace_bind_hash, state.trace_pending, state.trace_checks = bind_hash, true, 0
        state.face_trace = { action = state.key, owner = state.owner, body_id = state.body_id,
            generation = state.generation, started = os.clock(), status = "sampling", samples = {} }
        quest.face_traces[#quest.face_traces + 1] = state.face_trace
        if #quest.face_traces > 4 then table.remove(quest.face_traces, 1) end
        sample_face_trace(action, state, "before_face_api")
    end

    -- 只读最终部件，不保留 Mesh；最多三个部件、每部件128个材质。
    local function part_snapshot(part)
        local item = { object = tostring(part), name = get_game_object_name_quiet(part) }
        if not part then return item end
        local mesh = get_component(part, "via.render.Mesh")
        if not mesh then return item end
        item.mesh = tostring(mesh)
        item.enabled = tostring(call(mesh, "get_Enabled"))
        item.materials = {}
        local count = tonumber(call(mesh, "get_MaterialNum")) or 0
        item.material_count = count
        for index = 0, math.min(count, 128) - 1 do
            item.materials[#item.materials + 1] = {
                name = tostring(call(mesh, "getMaterialName", index)),
                enabled = tostring(call(mesh, "getMaterialsEnable", index))
            }
        end
        return item
    end

    -- 快照只含标量；报告按钮可在动画结束后使用，不会因此留住旧场景对象。
    local function snapshot(action, motion)
        local result = {
            phase = tonumber(field(action, "_Phase")),
            mot_phase = tonumber(field(action, "_MotPhase")),
            first_update = tostring(field(action, "_IsFirstUpdate")),
            elapsed = tonumber(field(action, "_RawTotalElapsedSecond"))
        }
        if motion then
            result.motion = tostring(motion)
            local owner = get_game_object_quiet(motion)
            local transform = owner and get_transform(owner)
            result.owner = tostring(owner)
            for _, name in ipairs({ "Position", "LocalPosition" }) do
                local value = transform and call(transform, "get_" .. name)
                if value then
                    local ok, xyz = pcall(function() return { x = value.x, y = value.y, z = value.z } end)
                    if ok then result[name] = xyz end
                end
            end
            local skeleton = owner and get_component(owner, "via.motion.CustomSkeleton")
            local holder = skeleton and call(skeleton, "get_SkeletonResourceHandle")
            -- getter 每次创建包装对象，包装地址不能用于证明资源被覆盖。
            result.resource_path = tostring(call(holder, "get_ResourcePath"))
            result.custom_skeleton = tostring(skeleton)
            result.auto_apply = tostring(call(skeleton, "get_AutoApply"))
            local edit_root = get_component(owner, "app.CharacterEditRegionRoot")
            local edit_region = get_component(owner, "app.CharacterEditRegion")
            result.edit_root_present = edit_root ~= nil
            result.edit_region_present = edit_region ~= nil
            edit_root = edit_root or (edit_region and call(edit_region, "getRoot"))
            result.bone_api_root = tostring(edit_root)
            result.bone_api_slots = {}
            for label, hash in pairs({ main = 4175418299, face = 935285574, chest = 3471977595 }) do
                local part = edit_root and call(edit_root, "getPartsObject", hash)
                result.bone_api_slots[label] = {
                    object = tostring(part), name = get_game_object_name_quiet(part),
                    mesh = tostring(part and get_component(part, "via.render.Mesh"))
                }
            end
            for _, name in ipairs({ "RootMotion", "RootScaleDisabled", "JointsConstructed", "SkeletonConstructCount", "JointCount" }) do
                result[name] = tostring(call(motion, "get_" .. name))
            end
            for _, name in ipairs({ "RootMotionTranslation", "OriginalRootMotionTranslation" }) do
                local value = call(motion, "get_" .. name)
                if value then
                    local ok, xyz = pcall(function() return { x = value.x, y = value.y, z = value.z } end)
                    if ok then result[name] = xyz end
                end
            end
        end
        local creator = field(action, "_NpcVisualCreator")
        local controller = creator and call(creator, "get_CharaMakeController")
        if controller then
            result.parts = {}
            for label, hash in pairs({ main = 4175418299, face = 935285574, chest = 3471977595 }) do
                result.parts[label] = part_snapshot(call(controller, "getPartsObject(System.UInt32)", hash))
            end
        end
        return result
    end

    local function remember(state, status)
        state.status = status
        quest.last_status = status
        -- 每个动作仅留一条有限标量摘要，后一次成功不能覆盖前一次取消原因。
        if not state.summary then
            state.summary = { action = state.key, scene_generation = state.generation, started = state.started }
            quest.recent_results[#quest.recent_results + 1] = state.summary
            if #quest.recent_results > 8 then table.remove(quest.recent_results, 1) end
        end
        local summary = state.summary
        summary.time, summary.status = os.clock(), status
        summary.owner, summary.npc_name, summary.body_id = state.owner, state.npc_name, state.body_id
        summary.owner_address, summary.motion_address = state.owner_address, state.motion_address
        summary.bone_ok, summary.face_status = state.bone_ok, state.face_status
        summary.face_checks, summary.face_attempts = state.face_checks or 0, state.face_attempts or 0
        summary.hide_attempts, summary.hide_status = state.hide_attempts or 0, state.hide_status
        summary.phase, summary.mot_phase = state.face_phase, state.face_mot_phase
        summary.native_update_result = state.native_update_result
        summary.variant_ok = state.variant and state.variant.ok
        local item = {
            time = os.clock(), mode = report_key, status = status,
            action = state.key, scene_generation = state.generation,
            attempts = state.attempts, owner = state.owner,
            owner_address = state.owner_address, motion_address = state.motion_address,
            native_after = state.native_after, before = state.before, after = state.after,
            next_callback = state.next_callback, settled = state.settled, variant = state.variant,
            body_id = state.body_id, actual_resource = state.actual_resource,
            face_status = state.face_status, face_after = state.face_after,
            face_checks = state.face_checks, face_ready = state.face_ready,
            face_bind_driver = state.face_bind_driver,
            face_bind_driver_address = state.face_bind_driver_address,
            hide_attempts = state.hide_attempts, hide_status = state.hide_status,
            face_trace_started = state.face_trace and state.face_trace.started
        }
        quest.last_result = item
        remember_operation(item)
        record_event(report_key, status)
    end

    local function new_state(key)
        local state = { key = key, generation = scene_generation, attempts = 0, checks = 0,
            finished = false, started = os.clock(), diagnostics = config.debug_log == true }
        if not states[key] then
            state_order[#state_order + 1] = key
            if #state_order > 16 then
                local oldest = table.remove(state_order, 1)
                if states[oldest] then
                    stop_face_trace(states[oldest], "state budget evicted")
                    face_relay.stop(states[oldest], "state budget evicted")
                    states[oldest].face_data = nil
                    states[oldest].face_status = "state budget evicted"
                    remember(states[oldest], "state budget evicted")
                end
                states[oldest] = nil
            end
        end
        states[key] = state
        return state
    end

    local function process(action, state)
        if not config.enabled or scene_transition.active then return end
        if state.finished or state.generation ~= scene_generation then return end
        local phase = tonumber(field(action, "_Phase"))
        if phase ~= 0 then return end
        local creator = field(action, "_NpcVisualCreator")
        if not creator or call(creator, "get_IsCreated") ~= true then return end

        -- 必须使用动作明确持有的 NPC Motion，禁止回退到玩家或全场景搜索。
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        if not owner or not same_runtime_object(owner, get_game_object_quiet(creator)) then
            state.finished = true
            remember(state, "creator and NPC Motion owner do not agree")
            return
        end
        state.owner_address, state.motion_address = quest_object_address(owner), quest_object_address(motion)
        if not state.owner_address or not state.motion_address then
            state.finished = true
            remember(state, "NPC identity unavailable; no skeleton write")
            return
        end
        local player = field(action, "_Chara")
        if get_component(owner, "app.HunterCharacter")
            or (player and same_runtime_object(owner, get_game_object_quiet(player))) then
            state.finished = true
            remember(state, "player owner rejected before any skeleton write")
            return
        end
        local ready, reason = probe_candidate_bone_state(owner, "quest_result_owner")
        if not ready or not same_runtime_object(ready.motion, motion) then
            state.finished = true
            remember(state, "native creator completed but skeleton not ready: " .. tostring(reason))
            return
        end
        local controller = call(creator, "get_CharaMakeController")
        if not controller or call(controller, "isFinishPartsSetup") ~= true then
            state.finished = true
            remember(state, "native creator completed but parts not ready; no late retry")
            return
        end
        local parts, chest = {}, nil
        for index = 0, 5 do
            local part = call(controller, "getPartsObject(app.ArmorDef.ARMOR_PARTS)", index)
            if part then parts[#parts + 1] = part end
            if index == 1 then chest = part end
        end
        local name = get_game_object_name_quiet(chest)
        local cache = new_event_cache_entry()
        local resolution, match_status = resolve_target(creator, owner, cache, {
            chest_state = {
                chest_object = chest, chest_name = name, chest_body_id = body_id_from_object_name(name),
                source = report_key, cache_route = report_key
            }, extra_roots = parts, disable_session_cache = true
        })
        state.finished = true
        if not resolution then
            remember(state, "no configured outfit: " .. tostring(match_status))
            return
        end
        state.owner = tostring(owner)
        state.npc_name = get_game_object_name_quiet(owner)
        state.body_id = resolution.body_id
        state.before = state.diagnostics and snapshot(action, motion) or { motion = tostring(motion) }
        state.attempts = 1
        quest.attempts = quest.attempts + 1
        local ok, status, _, _, _, variant, variant_ok = inspect_character(
            creator, report_key, resolution, cache, {
                root_obj = owner, extra_roots = parts, defer_report = true,
                expected_readiness_signature = ready.signature
            }
        )
        if state.diagnostics then
            state.after = snapshot(action, motion)
            state.sample_next = true
            state.sample_settled_at = os.clock() + 0.25
        end
        state.variant = { ok = variant_ok == true, status = tostring(variant) }
        state.bone_ok = ok == true
        local holder = call(ready.custom_skeleton, "get_SkeletonResourceHandle")
        state.actual_resource = tostring(call(holder, "get_ResourcePath"))
        if ok then
            quest.succeeded = quest.succeeded + 1
            local data = load_bone_config(resolution.target.bone_system_body_id or resolution.body_id)
            local face_data = make_target_bone_data(data, resolution.target)
            if type(face_data) == "table" then
                -- make_target_bone_data 可能返回共享原表；必须复制，不能关掉全局骨骼功能。
                state.face_data = { FixBone = false }
                -- 动作退出和场景代际负责正常取消；总上限仅防异常动作永久等待。
                state.face_deadline = os.clock() + 60
                state.face_checks = 0
                for _, name in ipairs({ "Enable", "HideFace", "HideHair", "HideSlinger", "BindFace", "BindPart", "DispOffOutDoorCookingHelm" }) do
                    state.face_data[name] = face_data[name]
                end
            end
        end
        remember(state, tostring(status))
        return state
    end

    -- 骨架和差分时机不变；仅未完成的面部项可继续进入同一结算动作的 post。
    local function prepare(action)
        quest.calls = quest.calls + 1
        local key = quest_object_address(action)
        if not key then return end
        local state = states[key]
        if state and state.generation ~= scene_generation then
            stop_face_trace(state, "scene generation changed")
            face_relay.stop(state, "scene generation changed")
            state.face_data = nil
            state.face_status = "scene generation changed; face wait cancelled"
            remember(state, state.status)
            state = nil
        end
        if state and state.finished then
            if state.sample_next then
                state.sample_next = false
                state.next_callback = snapshot(action, field(action, "_NpcMotionComponent"))
                remember(state, "next callback readback; " .. state.status)
            elseif state.sample_settled_at and os.clock() >= state.sample_settled_at then
                state.sample_settled_at = nil
                state.settled = snapshot(action, field(action, "_NpcMotionComponent"))
                remember(state, "settled readback; " .. state.status)
            end
            if state.face_data or state.trace_pending or state.relay_enabled then return state end
            return
        end
        state = state or new_state(key)
        if tonumber(field(action, "_Phase")) ~= 0 then
            state.finished = true
            remember(state, "WAIT exit not observed; no late skeleton write")
            return
        end
        state.checks = state.checks + 1
        if state.checks > 2400 or os.clock() - state.started > 15 then
            state.finished = true
            remember(state, "bounded WAIT budget exceeded; no late skeleton write")
            return
        end
        return process(action, state)
    end

    local function face_status(state, message, stop)
        if stop then state.face_data = nil end
        if state.face_status ~= message then
            state.face_status = message
            remember(state, state.status)
        end
    end

    -- Face 已就绪而绑定部件尚未注册时，先复用原 API 隐藏一次，不重复绑定。
    local function hide_ready_face(owner, state)
        local data = state.face_data
        if state.hide_attempts or data.Enable == false or data.HideFace ~= true then return end
        local hide_data = {}
        for name, value in pairs(data) do hide_data[name] = value end
        hide_data.BindFace = false
        state.hide_attempts = 1
        quest.hide_attempts = quest.hide_attempts + 1
        local ok, message = pcall(API.fix_bone, owner, hide_data, nil)
        state.hide_status = ok and "hide-only API returned; binding still pending" or tostring(message)
        if not ok then quest.errors = quest.errors + 1 end
        remember(state, state.status)
    end

    -- 原版 fix_bone 在 FixBone=false 时只执行 fix_hide，不创建/写骨架。
    -- creator 完成不等于 hash 槽已注册；只等槽表，不重复调用绑定 API。
    local function finish_face(action, state)
        local face_data = state.face_data
        if not face_data then return end
        if state.generation ~= scene_generation then
            face_status(state, "scene generation changed; face wait cancelled", true)
            return
        end
        local now = os.clock()
        if state.face_checks >= 1200 or now > state.face_deadline then
            face_status(state, "face slot wait budget exceeded; no late retry", true)
            return
        end
        local phase = tonumber(field(action, "_Phase"))
        local mot_phase = tonumber(field(action, "_MotPhase"))
        if state.face_phase ~= phase or state.face_mot_phase ~= mot_phase then state.next_face_probe = nil end
        state.face_phase, state.face_mot_phase = phase, mot_phase
        if phase == 0 and not state.face_wait_confirmed then
            face_status(state, "waiting for native WAIT exit", false)
            return
        end
        if phase ~= 1 and phase ~= 2 and phase ~= 3 then
            face_status(state, "native result phase ended; face wait cancelled", true)
            return
        end
        state.face_wait_confirmed = true
        -- 原生 MotPhase.NONE 是准备态，不是结束态；实际 doExit 仍立即撤销待办。
        if mot_phase == 0 then
            face_status(state, "waiting for native motion setup", false)
            return
        end
        if mot_phase ~= 1 and mot_phase ~= 2 then
            face_status(state, "unsupported native motion phase; face wait cancelled", true)
            return
        end
        if state.next_face_probe and now < state.next_face_probe then return end
        state.face_checks = state.face_checks + 1
        -- 同一等待原因可能持续多帧；更新现有标量摘要，不追加事件或写报告。
        if state.summary then
            state.summary.face_checks, state.summary.face_last_check = state.face_checks, now
        end
        -- 常见的下一回调就绪仍立即完成；慢路径每秒最多约20次，不在普通帧扫描。
        state.next_face_probe = state.face_checks >= 4 and now + 0.05 or nil
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        local creator = field(action, "_NpcVisualCreator")
        if quest_object_address(owner) ~= state.owner_address or quest_object_address(motion) ~= state.motion_address
            or not same_runtime_object(owner, get_game_object_quiet(creator)) then
            face_status(state, "native owner changed; no cross-object face write", true)
            return
        end
        local player = field(action, "_Chara")
        if get_component(owner, "app.HunterCharacter")
            or (player and same_runtime_object(owner, get_game_object_quiet(player))) then
            face_status(state, "player owner rejected", true)
            return
        end
        if state.diagnostics and not state.native_after then state.native_after = snapshot(action, motion) end
        if call(motion, "get_JointsConstructed") ~= true then
            face_status(state, "waiting for constructed NPC joints", false)
            return
        end
        local edit_root = get_component(owner, "app.CharacterEditRegionRoot")
        local edit_region = not edit_root and get_component(owner, "app.CharacterEditRegion")
        edit_root = edit_root or (edit_region and call(edit_region, "getRoot"))
        local face = edit_root and call(edit_root, "getPartsObject", 935285574)
        local mesh = face and get_component(face, "via.render.Mesh")
        if not mesh or (tonumber(call(mesh, "get_MaterialNum")) or 0) <= 0 then
            face_status(state, "waiting for stock BoneSystem Face slot and materials", false)
            return
        end
        local chest = call(edit_root, "getPartsObject", 3471977595)
        local bind_hashes = { 3471977595, 2156620752, 639293466, 1274174449 }
        local bind_hash = bind_hashes[tonumber(face_data.BindPart) or 1]
        local bind_part = bind_hash and call(edit_root, "getPartsObject", bind_hash)
        if not chest or (face_data.BindFace == true and not bind_part) then
            hide_ready_face(owner, state)
            face_status(state, "waiting for stock BoneSystem Chest/bind slot", false)
            return
        end
        if face_data.BindFace == true then
            local bind_motion = get_component(bind_part, "via.motion.Motion")
                or get_component(bind_part, "via.motion.ChildSecondary")
            if not bind_motion then
                hide_ready_face(owner, state)
                face_status(state, "waiting for stock BoneSystem binding Motion/ChildSecondary", false)
                return
            end
            state.face_bind_driver_address = quest_object_address(bind_motion)
            if not state.face_bind_driver_address then
                face_status(state, "binding identity unavailable; face wait cancelled", true)
                return
            end
            state.face_bind_driver = tostring(bind_motion)
        end
        if state.diagnostics then state.face_ready = snapshot(action, motion) end
        if state.diagnostics and face_data.BindFace == true then
            -- 诊断失败不能取消已经就绪的原版显隐/绑定调用。
            local traced, trace_error = pcall(begin_face_trace, action, state, bind_hash)
            if not traced then
                quest.trace_errors = quest.trace_errors + 1
                if state.face_trace then state.face_trace.error = tostring(trace_error) end
                stop_face_trace(state, "trace initialization failed")
            end
        end
        -- 先关闭待办；异常也不能引发下一帧重复绑定。
        state.face_data = nil
        state.face_attempts = (state.face_attempts or 0) + 1
        quest.face_attempts = quest.face_attempts + 1
        local ok, message = pcall(API.fix_bone, owner, face_data, nil)
        state.face_status = ok and "face-only API returned; check material readback" or tostring(message)
        if not ok then quest.errors = quest.errors + 1 end
        if ok and face_data.Enable ~= false and face_data.BindFace == true and face_relay.available then
            face_relay.arm(state, face, bind_part, bind_hash)
        end
        if state.diagnostics then state.face_after = snapshot(action, motion) end
        if not ok then stop_face_trace(state, "face API failed") end
        if state.diagnostics then state.sample_settled_at = os.clock() + 0.25 end
        remember(state, state.status)
    end

    local function record_error(action, message)
        quest.errors = quest.errors + 1
        local key = quest_object_address(action)
        if not key then
            quest.last_status = "caught error without action identity: " .. tostring(message)
            return
        end
        local state = states[key] or new_state(key)
        state.finished = true
        state.face_data = nil
        face_relay.stop(state, "result callback failed")
        stop_face_trace(state, "result callback failed")
        state.sample_next, state.sample_settled_at = nil, nil
        remember(state, "caught error: " .. tostring(message))
    end

    local function storage_or_nil()
        local ok, storage = pcall(thread.get_hook_storage)
        if ok then return storage end
    end

    -- 原生 UPDATE_RESULT.END=1；结束时阶段字段未必改变，不能据旧阶段继续补脸。
    local function native_update_result(retval)
        local value = type(retval) == "number" and retval or nil
        if not value and sdk.to_int64 then
            local ok, raw = pcall(sdk.to_int64, retval)
            if ok then value = math.tointeger(raw) end
        end
        return value and (value & 0xffffffff) or nil
    end

    local type_def = safe_sdk_type("app.PlayerCommonAction.cQuestClearBase")
    local update, exit_method
    local methods_ok = pcall(function()
        update = type_def and type_def:get_method("doUpdate")
        exit_method = type_def and type_def:get_method("doExit")
    end)
    if methods_ok and update and exit_method and thread and thread.get_hook_storage then
        local ok, err = pcall(function()
            sdk.hook(update, function(args)
                local storage = storage_or_nil()
                if not storage then return end
                storage.bsfn_quest_action = nil
                storage.bsfn_quest_state = nil
                if not config.enabled or scene_transition.active then
                    -- 不清除已执行标记；重新开启时不能重做骨架或恢复旧面部待办。
                    if not paused then
                        paused = true
                        for _, state in pairs(states) do
                            stop_face_trace(state, "result suspended")
                            face_relay.stop(state, "result suspended")
                            if state.face_data then
                                face_status(state, "result suspended; face wait cancelled", true)
                            end
                        end
                    end
                    return
                end
                paused = false
                local converted, action = pcall(sdk.to_managed_object, args[2])
                if not converted or not action then return end
                local success, state = pcall(prepare, action)
                if not success then
                    record_error(action, state)
                elseif state then
                    storage.bsfn_quest_action = action
                    storage.bsfn_quest_state = state
                end
            end, function(retval)
                local storage = storage_or_nil()
                if not storage then return retval end
                local action, state = storage.bsfn_quest_action, storage.bsfn_quest_state
                storage.bsfn_quest_action, storage.bsfn_quest_state = nil, nil
                if action and state then
                    state.native_update_result = native_update_result(retval)
                    if state.native_update_result == 1 then
                        if state.face_data then state.face_status = "native update ended before face completion" end
                        state.face_data = nil
                        state.sample_next, state.sample_settled_at = nil, nil
                        face_relay.stop(state, "native update ended")
                        stop_face_trace(state, "native update ended")
                        remember(state, "native update returned END; " .. tostring(state.status))
                        return retval
                    end
                    if config.enabled and not scene_transition.active then
                        local ok, message = pcall(finish_face, action, state)
                        if not ok then record_error(action, message) end
                        if ok then
                            face_relay.queue(state)
                            local sampled, sample_error = pcall(sample_face_trace, action, state, "after_native_update")
                            if not sampled then
                                quest.trace_errors = quest.trace_errors + 1
                                if state.face_trace then state.face_trace.error = tostring(sample_error) end
                                stop_face_trace(state, "read failed")
                            end
                        end
                    else
                        face_status(state, "result suspended in original callback", true)
                        face_relay.stop(state, "result suspended in original callback")
                        stop_face_trace(state, "result suspended in original callback")
                    end
                end
                return retval
            end)
            sdk.hook(exit_method, function(args)
                local converted, action = pcall(sdk.to_managed_object, args[2])
                if not converted or not action then return end
                local key = quest_object_address(action)
                if not key then return end
                local state = states[key]
                if state then
                    if state.face_data then state.face_status = "action exited before face completion" end
                    state.face_data = nil
                    face_relay.stop(state, "action exited")
                    stop_face_trace(state, "action exited")
                    remember(state, "action exited; " .. tostring(state.status))
                    states[key] = nil
                    for i = #state_order, 1, -1 do
                        if state_order[i] == key then table.remove(state_order, i) end
                    end
                end
            end, function(retval) return retval end)
        end)
        hook_state.quest_result = ok and "installed: bounded face-slot readiness; result-only facial relay before LockScene; no normal-scene scan" or tostring(err)
    else
        hook_state.quest_result = "unavailable: native action methods or hook storage missing"
    end
end
install_quest_result_hooks()
