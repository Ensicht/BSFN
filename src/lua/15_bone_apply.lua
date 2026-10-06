-- =============================================================================
-- 骨骼应用与保留的底层诊断
-- =============================================================================
-- 默认只调用原版 fix_bone，不预创建第二份骨骼资源。非默认诊断分支保留但不推荐启用。

-- 正常路径在原版 API 调用后立即返回，避免落入后面的历史资源诊断分支。
local function perform_stage(candidate, motion, custom_skeleton, target, bone_body_id, bone_data)
    local mode = tostring(config.mode or "probe")
    local operation = {
        time = os.clock(),
        mode = mode,
        target = tostring(target.display_name or target.npc_id or "target"),
        candidate_label = tostring(candidate.label),
        candidate_name = tostring(candidate.name),
        candidate_object = tostring(candidate.obj),
        bone_body_id = tostring(bone_body_id or ""),
        resource_created = false,
        resource_owner = mode == "api_fix_bone" and "BoneSystemNPCAPI.fix_bone" or "BSFN.lua",
        resource_precreate_skipped = mode == "api_fix_bone",
        holder_ready = false,
        write_holder_ok = false,
        set_holder_ok = false,
        apply_custom_joint_ok = false,
        status = "started"
    }

    local resource_path = resource_path_from_bone_data(bone_data)
    operation.desired_resource_path = tostring(resource_path or "")
    if not resource_path then
        operation.status = "missing FbxPath"
        remember_operation(operation)
        return false, operation.status
    end

    if mode == "api_fix_bone" then
        local api_bone_data, private_mode, face_route = make_target_bone_data(bone_data, target)
        operation.private_face_mode = private_mode
        operation.face_route = tostring(face_route)
        if type(api_bone_data) == "table" then
            operation.api_hide_face = tostring(api_bone_data.HideFace)
            operation.api_bind_face = tostring(api_bone_data.BindFace)
        end
        operation.api_fix_bone_type = type(API.fix_bone)
        if operation.api_fix_bone_type ~= "function" then
            operation.status = "API.fix_bone missing"
            remember_operation(operation)
            return false, operation.status
        end
        local ok_api, api_result = pcall(function()
            return API.fix_bone(candidate.obj, api_bone_data, nil)
        end)
        operation.api_fix_bone_ok = ok_api
        operation.api_fix_bone_result = trim_text(api_result, 500)
        if ok_api then
            local ok_post_holder, post_holder = call_any(custom_skeleton, "get_SkeletonResourceHandle")
            operation.post_holder_ready = ok_post_holder and post_holder ~= nil
            if operation.post_holder_ready then
                operation.post_holder_object = tostring(post_holder)
                operation.post_holder_address, operation.post_holder_address_raw = get_address_text(post_holder)
                local ok_post_path, post_path = call_any(post_holder, "get_ResourcePath")
                operation.post_resource_path = ok_post_path and tostring(post_path or "") or ""
            else
                operation.post_resource_path = ""
            end
        end
        if not ok_api then
            operation.status = "api_fix_bone failed"
            remember_operation(operation)
            return false, operation.status
        end
        operation.status = "api_fix_bone ok"
        remember_operation(operation)
        return true, operation.status
    end

    local ok_holder, holder = call_any(custom_skeleton, "get_SkeletonResourceHandle")
    if not ok_holder or not holder then
        operation.status = "no current SkeletonResourceHandle"
        operation.error = trim_text(holder, 500)
        remember_operation(operation)
        return false, operation.status
    end
    operation.holder_ready = true
    operation.holder_object = tostring(holder)
    operation.holder_address, operation.holder_address_raw = get_address_text(holder)

    local ok_add_ref, add_ref_result = call_any(holder, "add_ref")
    operation.holder_add_ref_ok = ok_add_ref
    operation.holder_add_ref_result = trim_text(add_ref_result, 200)

    local ok_current, current_path = call_any(holder, "get_ResourcePath")
    operation.current_resource_path = ok_current and tostring(current_path or "") or ""

    local ok_resource, resource = pcall(function()
        return sdk.create_resource("via.motion.SkeletonResource", resource_path)
    end)
    if not ok_resource or not resource then
        operation.status = "resource create failed"
        operation.error = trim_text(resource, 500)
        remember_operation(operation)
        return false, operation.status
    end
    retained_resources[resource_path] = resource
    operation.resource_created = true
    operation.resource_object = tostring(resource)
    operation.resource_address, operation.resource_address_raw = get_address_text(resource)

    if mode == "probe" then
        operation.status = "probe ok"
        remember_operation(operation)
        return true, operation.status
    end

    if mode == "write_holder" or mode == "set_holder" or mode == "native_direct" then
        if not operation.resource_address_raw then
            operation.status = "resource address missing"
            remember_operation(operation)
            return false, operation.status
        end
        local ok_write, write_result = call_any(holder, "write_qword", 7, operation.resource_address_raw)
        operation.write_holder_ok = ok_write
        operation.write_holder_result = trim_text(write_result, 500)
        if not ok_write then
            operation.status = "write_holder failed"
            remember_operation(operation)
            return false, operation.status
        end
    end

    if mode == "native_direct" then
        operation.motion_address, operation.motion_address_raw = get_address_text(motion)
        operation.custom_skeleton_address, operation.custom_skeleton_address_raw = get_address_text(custom_skeleton)
        operation.holder_address, operation.holder_address_raw = get_address_text(holder)
        operation.sdk_fix_bone_type = type(sdk.fix_bone)
        operation.default_value = bone_data.Default == true
        if operation.sdk_fix_bone_type ~= "function" then
            operation.status = "sdk.fix_bone missing"
            remember_operation(operation)
            return false, operation.status
        end
        if not operation.motion_address_raw or not operation.custom_skeleton_address_raw or not operation.holder_address_raw then
            operation.status = "native address missing"
            remember_operation(operation)
            return false, operation.status
        end
        local ok_native, native_result = pcall(function()
            return sdk.fix_bone(operation.motion_address_raw, operation.custom_skeleton_address_raw, operation.holder_address_raw, operation.default_value, 0)
        end)
        operation.native_direct_ok = ok_native
        operation.native_direct_result = trim_text(native_result, 500)
        if ok_native then
            local ok_apply, apply_result = call_any(custom_skeleton, "applyCustomJoint")
            operation.apply_custom_joint_ok = ok_apply
            operation.apply_custom_joint_result = trim_text(apply_result, 500)
            local ok_post_holder, post_holder = call_any(custom_skeleton, "get_SkeletonResourceHandle")
            if ok_post_holder and post_holder then
                local ok_post_path, post_path = call_any(post_holder, "get_ResourcePath")
                operation.post_resource_path = ok_post_path and tostring(post_path or "") or ""
            else
                operation.post_resource_path = ""
            end
        end
        if not ok_native then
            operation.status = "native_direct failed"
            remember_operation(operation)
            return false, operation.status
        end
    end

    if mode == "set_holder" then
        local ok_set, set_result = call_any(custom_skeleton, "set_SkeletonResourceHandle", holder)
        operation.set_holder_ok = ok_set
        operation.set_holder_result = trim_text(set_result, 500)
        if ok_set then
            local ok_apply, apply_result = call_any(custom_skeleton, "applyCustomJoint")
            operation.apply_custom_joint_ok = ok_apply
            operation.apply_custom_joint_result = trim_text(apply_result, 500)
            local ok_post_holder, post_holder = call_any(custom_skeleton, "get_SkeletonResourceHandle")
            if ok_post_holder and post_holder then
                local ok_post_path, post_path = call_any(post_holder, "get_ResourcePath")
                operation.post_resource_path = ok_post_path and tostring(post_path or "") or ""
            else
                operation.post_resource_path = ""
            end
        end
        if not ok_set then
            operation.status = "set_holder failed"
            remember_operation(operation)
            return false, operation.status
        end
    end

    operation.status = mode .. " ok"
    remember_operation(operation)
    return true, operation.status
end
