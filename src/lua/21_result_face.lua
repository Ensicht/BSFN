-- 结算身份使用原生地址；Lua 弱缓存重建包装后，tostring 不能用于跨回调比较。
-- 地址只作标量身份，不据此还原或保活对象；每次仍从当前原生动作取得对象。
local function quest_object_address(object)
    if not object then return end
    local ok, address = pcall(function() return object:get_address() end)
    if not ok or type(address) ~= "number" then return end
    address = math.tointeger(address)
    if address and address > 0 then return address end
end

-- 结算专用表情传递：只保留骨名、基准差和身份标量，不持有场景对象。
-- LockScene 前重新取得本机当前动作，避开胸部 ChildSecondary 回调的调度差异。
local function make_quest_face_relay(field, call, edit_root_for, quest)
    local ticket
    local relay = {}
    local properties = { "LocalPosition", "LocalRotation", "LocalScale" }
    local axes = { "x", "y", "z", "w" }

    local function finite(value)
        return type(value) == "number" and value == value and math.abs(value) < math.huge
    end

    -- 仅接收原生脸中的表情骨；不能沿用原 DLL 的“所有同名骨”到人物根。
    local function facial_name(name)
        if type(name) ~= "string" or #name > 96 then return false end
        if name == "L_Eye" or name == "R_Eye" then return true end
        if name == "L_Eye_Master" or name == "R_Eye_Master" or name == "C_Mouth_Master" then return true end
        local stem = name:match("^[LRC]_(.-)_LOD%d%d$")
        if not stem then return false end
        stem = stem:lower()
        for _, token in ipairs({ "eye", "brow", "lip", "jaw", "cheek", "nose",
            "nostril", "chin", "mouth", "tongue", "teeth", "forehead" }) do
            if stem:find(token, 1, true) then return true end
        end
        return false
    end

    local function stop(state, reason)
        if ticket == state then ticket = nil end
        state.relay_enabled = nil
        state.relay_map = nil
        if state.face_relay then state.face_relay.status = reason end
    end

    -- 只在首次有效渲染帧建立映射；不缓存 Joint、Transform 或 Motion。
    local function build_map(source, target)
        local joints = call(source, "get_Joints")
        local count = tonumber(joints and call(joints, "get_Length"))
        assert(count and count > 0 and count <= 768 and count % 1 == 0, "invalid source joint count")
        local result, seen = {}, {}
        for index = 0, count - 1 do
            local joint = call(joints, "get_Item", index)
            local name = joint and call(joint, "get_Name")
            if facial_name(name) and not seen[name] then
                seen[name] = true
                local other = call(target, "getJointByName", name)
                if other and call(joint, "get_Valid") == true and call(other, "get_Valid") == true then
                    local item = { name = name, deltas = {} }
                    for _, property in ipairs(properties) do
                        local a = assert(call(joint, "get_Base" .. property), "missing source base")
                        local b = assert(call(other, "get_Base" .. property), "missing target base")
                        local delta = {}
                        for axis = 1, property == "LocalRotation" and 4 or 3 do
                            local key = axes[axis]
                            assert(finite(a[key]) and finite(b[key]), "nonfinite base pose")
                            delta[key] = b[key] - a[key]
                        end
                        item.deltas[property] = delta
                    end
                    result[#result + 1] = item
                    assert(#result <= 192, "facial map budget exceeded")
                end
            end
        end
        assert(#result > 0, "no matching facial joints")
        return result
    end

    local function current_action()
        local manager = sdk.get_managed_singleton("app.PlayerManager")
        local player = manager and call(manager, "getMasterPlayer")
        local character = player and call(player, "get_Character")
        local controller = character and call(character, "get_BaseActionController")
        return controller and call(controller, "get_CurrentAction")
    end

    local function transfer(state)
        local action = current_action()
        if not action or quest_object_address(action) ~= state.key then return stop(state, "current action changed") end
        local phase = tonumber(field(action, "_Phase"))
        if phase ~= 1 and phase ~= 2 and phase ~= 3 then return stop(state, "result phase ended") end
        local motion = field(action, "_NpcMotionComponent")
        local owner = motion and get_game_object_quiet(motion)
        local creator = field(action, "_NpcVisualCreator")
        local player = field(action, "_Chara")
        if not owner or quest_object_address(owner) ~= state.owner_address
            or quest_object_address(motion) ~= state.motion_address
            or not same_runtime_object(owner, get_game_object_quiet(creator))
            or get_component(owner, "app.HunterCharacter")
            or (player and same_runtime_object(owner, get_game_object_quiet(player))) then
            return stop(state, "NPC owner changed")
        end
        local root = edit_root_for(owner)
        local face = root and call(root, "getPartsObject", 935285574)
        local part = root and call(root, "getPartsObject", state.relay_bind_hash)
        if not face or not part or same_runtime_object(face, part) or same_runtime_object(owner, part)
            or quest_object_address(face) ~= state.relay_face or quest_object_address(part) ~= state.relay_part then
            return stop(state, "face or outfit part changed")
        end
        local part_motion = get_component(part, "via.motion.Motion")
        local driver = part_motion or get_component(part, "via.motion.ChildSecondary")
        if not driver or quest_object_address(driver) ~= state.face_bind_driver_address then
            return stop(state, "binding driver changed")
        end
        local part_construction = part_motion and tonumber(call(part_motion, "get_SkeletonConstructCount")) or -1
        if part_motion and (part_construction == -1 or call(part_motion, "get_JointsConstructed") ~= true) then
            return stop(state, "outfit joints not ready")
        end
        local face_motion = get_component(face, "via.motion.Motion")
        local source_motion_address = quest_object_address(face_motion)
        if not source_motion_address then return stop(state, "source motion identity unavailable") end
        local constructed = call(motion, "get_JointsConstructed")
        local source_ready = face_motion and call(face_motion, "get_JointsConstructed")
        if constructed ~= true or source_ready ~= true then return stop(state, "joints no longer constructed") end
        local construction = tonumber(call(motion, "get_SkeletonConstructCount"))
        local source_construction = tonumber(call(face_motion, "get_SkeletonConstructCount"))
        if not construction or not source_construction then return stop(state, "missing construction identity") end
        local source, target = get_transform(face), get_transform(part)
        if not source or not target then return stop(state, "missing current transform") end
        if not state.relay_map then
            state.relay_map = build_map(source, target)
            state.relay_construction, state.relay_source_construction = construction, source_construction
            state.relay_part_construction = part_construction
            state.relay_source_motion = source_motion_address
            state.face_relay.joint_count = #state.relay_map
            state.face_relay.joints = {}
            for _, item in ipairs(state.relay_map) do state.face_relay.joints[#state.face_relay.joints + 1] = item.name end
        elseif state.relay_construction ~= construction or state.relay_source_construction ~= source_construction
            or state.relay_source_motion ~= source_motion_address or state.relay_part_construction ~= part_construction then
            return stop(state, "skeleton reconstructed; old map discarded")
        end

        -- 值类型是 getter 返回的副本。采用原 BoneSystem 的逐分量基准差算法，
        -- 不归一化/重定向，不触碰 Head、Neck、root 或动作播放参数。
        local writes = 0
        for _, item in ipairs(state.relay_map) do
            local a = call(source, "getJointByName", item.name)
            local b = call(target, "getJointByName", item.name)
            assert(a and b and call(a, "get_Valid") == true and call(b, "get_Valid") == true,
                "mapped joint became invalid")
            for _, property in ipairs(properties) do
                local value = assert(call(a, "get_" .. property), "missing animated pose")
                for axis = 1, property == "LocalRotation" and 4 or 3 do
                    local key = axes[axis]
                    assert(finite(value[key]), "nonfinite animated pose")
                    value[key] = value[key] + item.deltas[property][key]
                    assert(finite(value[key]), "nonfinite transferred pose")
                end
                local ok, err = call_any(b, "set_" .. property, value)
                assert(ok, tostring(err))
                writes = writes + 1
            end
        end
        local info = state.face_relay
        info.frames, info.writes, info.status = info.frames + 1, info.writes + writes, "copying facial joints"
        -- 三次少量回读留在同一份 BSFN 报告，避免只凭 API 成功宣称面部已动。
        if state.diagnostics and (info.frames == 1 or info.frames == 30 or info.frames == 120) then
            local sample = { frame = info.frames, time = os.clock(), joints = {} }
            for _, name in ipairs({ "L_UpEyeLidJ_LOD02", "C_upLip_LOD02", "C_Jaw_LOD02" }) do
                local joint = call(target, "getJointByName", name)
                local rotation = joint and call(joint, "get_LocalRotation")
                if rotation then
                    sample.joints[name] = { x = rotation.x, y = rotation.y, z = rotation.z, w = rotation.w }
                end
            end
            info.samples[#info.samples + 1] = sample
        end
    end

    function relay.arm(state, face, part, bind_hash)
        state.relay_bind_hash = bind_hash
        state.relay_face, state.relay_part = quest_object_address(face), quest_object_address(part)
        state.face_relay = { action = state.key, owner = state.owner, body_id = state.body_id,
            owner_address = state.owner_address, motion_address = state.motion_address,
            face_address = state.relay_face, part_address = state.relay_part,
            driver_address = state.face_bind_driver_address,
            status = "waiting for late animation phase", frames = 0, writes = 0, samples = {},
            started = os.clock(), timing_enabled = state.diagnostics == true,
            total_ms = state.diagnostics and 0 or nil, peak_ms = state.diagnostics and 0 or nil }
        quest.face_relays[#quest.face_relays + 1] = state.face_relay
        if #quest.face_relays > 4 then table.remove(quest.face_relays, 1) end
        if not state.relay_face or not state.relay_part or not state.face_bind_driver_address then
            return stop(state, "face or binding identity unavailable")
        end
        state.relay_enabled = true
    end

    function relay.queue(state)
        if state.relay_enabled then ticket = state end
    end

    relay.stop = stop
    if re and re.on_pre_application_entry then
        re.on_pre_application_entry("LockScene", function()
            -- 一张票只消费一次。没有本帧结算 doUpdate 就不会查找角色或重放旧姿态。
            local state = ticket
            if not state then return end
            ticket = nil
            if not state.relay_enabled or not config.enabled or config.auto_apply_face_mapping == false or scene_transition.active
                or state.generation ~= scene_generation then
                stop(state, "result relay suspended")
                return
            end
            if os.clock() - state.face_relay.started > 60 or state.face_relay.frames >= 20000 then
                stop(state, "result relay budget ended")
                return
            end
            local started = os.clock()
            local ok, err = pcall(transfer, state)
            local info = state.face_relay
            if state.diagnostics then
                local elapsed = (os.clock() - started) * 1000
                info.total_ms, info.peak_ms = info.total_ms + elapsed, math.max(info.peak_ms, elapsed)
            end
            if not ok then
                info.error = tostring(err)
                quest.relay_errors = quest.relay_errors + 1
                stop(state, "relay failed; no retry for this action")
            end
        end)
        relay.available = true
    end
    return relay
end
