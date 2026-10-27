#pragma once
#include "forefoot_core.hpp"

namespace constraint_reader {
enum Status { Compatible = 0, Pending = 2, FootWriter = 30, UnknownSections = 31,
              Invalid = 32, UncheckedSkin = 33, EmptyLayer = 34 };

// JCNS102 General+152 counts 16-byte material bindings at General+80.
// Native a629530 reads a source joint; a77b7d0 writes a mesh material property.
// This candidate covers translation sources only, not new joint-write families.
template<class Memory> int materials(const Memory& memory, uintptr_t data) {
    const auto count = forefoot::value<uint16_t>(data, 152);
    if (!count) return Compatible;
    // Validate the dispatch metadata on this newly supported path only.
    // ce0e600 selects uint32 IDs: 0 ordinary, 2 SC, 4 material, 5 export graph.
    if (forefoot::value<uintptr_t>(data, 88) || forefoot::value<uint16_t>(data, 156))
        return UnknownSections;
    const auto section_count = forefoot::value<uint16_t>(data, 154);
    const auto sections = forefoot::value<uintptr_t>(data, 96);
    if (!section_count || section_count > 64
        || !memory.range(sections, section_count * 4ULL, false)) return Invalid;
    bool scheduled = false;
    for (unsigned i = 0; i < section_count; ++i) {
        const auto kind = forefoot::value<uint32_t>(sections + i * 4ULL);
        if (kind == 4) scheduled = true;
        else if (kind != 0 && kind != 2) return UnknownSections;
    }
    if (!scheduled) return Invalid;
    const auto records = forefoot::value<uintptr_t>(data, 80);
    const auto hashes = forefoot::value<uintptr_t>(data, 112);
    const auto hash_count = forefoot::value<uint32_t>(data, 128);
    if (count > 2048 || !memory.range(records, count * 16ULL, false)
        || !hash_count || hash_count > 2048
        || !memory.range(hashes, hash_count * 4ULL, false)) return Invalid;
    for (unsigned i = 0; i < count; ++i) {
        const auto record = records + i * 16ULL;
        const auto source = forefoot::value<int32_t>(record);
        if (source < 0 || static_cast<uint32_t>(source) >= hash_count) return Invalid;
        // +4/+8 are material/property hashes, not joint output hashes.
        // Keep unreviewed source modes, rotation order and reserved bytes closed.
        if (forefoot::value<uint8_t>(record, 12) != 0
            || forefoot::value<uint8_t>(record, 13) != 0
            || forefoot::value<uint8_t>(record, 14) > 1
            || forefoot::value<uint8_t>(record, 15) != 0) return UnknownSections;
    }
    return Compatible;
}

// SC is permitted by policy, not proven harmless. Inspect ordinary outputs even
// when SC is present; never treat an unknown resource layout as an SC allowance.
template<class Memory> int general(const Memory& memory, uintptr_t data) {
    if (!memory.range(data, 160, false)) return Invalid;
    bool unknown = forefoot::value<uint16_t>(data, 132) != 0;
    for (unsigned offset : {138U, 140U, 142U, 150U})
        unknown = unknown || forefoot::value<uint16_t>(data, offset) != 0;
    const bool skin = forefoot::value<uint16_t>(data, 144)
        || forefoot::value<uint16_t>(data, 146) || forefoot::value<uint16_t>(data, 148);
    const auto count = forefoot::value<uint16_t>(data, 134);
    const auto records = forefoot::value<uintptr_t>(data, 8);
    if (count > 2048 || (count && !memory.range(records, count * 80ULL, false))) return Invalid;
    constexpr uint32_t feet[]{0x4d0e10c5, 0x6ded958a, 0x87f13496, 0x20bd0d5c, 0x17b78c57, 0x31754433};
    for (unsigned i = 0; i < count; ++i) {
        const auto target = forefoot::value<uint32_t>(records + i * 80ULL, 36);
        for (auto hash : feet) if (target == hash) return FootWriter;
    }
    const auto material_status = materials(memory, data);
    if (material_status != Compatible) return material_status;
    if (unknown) return UnknownSections;
    return skin ? UncheckedSkin : Compatible;
}

template<class Memory> int layer(const Memory& memory, uintptr_t pointer) {
    if (!memory.range(pointer, 0x28, false)) return Invalid;
    // Detached layers may still retain an asset; wait until they have an owner.
    if (!forefoot::value<uintptr_t>(pointer, 0x10)) return Pending;
    const auto resource = forefoot::value<uintptr_t>(pointer, 0x20);
    // The native updater skips an attached layer without an assigned asset.
    // An assigned resource has its own readiness flag; never collapse it into empty.
    if (!resource) return EmptyLayer;
    if (!memory.range(resource, 0x68, false)) return Invalid;
    if (!forefoot::value<uint8_t>(resource, 0x39)) return Pending;
    const auto data = forefoot::value<uintptr_t>(resource, 0x60);
    if (!memory.range(data, 48, false)) return Pending;
    if (forefoot::value<uint32_t>(data) != 102 || forefoot::value<uint32_t>(data, 4) != 0x736e636a)
        return UnknownSections;
    const auto count = forefoot::value<uint32_t>(data, 40);
    const auto kinds = forefoot::value<uintptr_t>(data, 16);
    const auto sections = forefoot::value<uintptr_t>(data, 32);
    if (count != 1) return UnknownSections;
    if (!memory.range(kinds, 1, false) || !memory.range(sections, 8, false)) return Invalid;
    if (forefoot::value<uint8_t>(kinds) != 15) return UnknownSections;
    return general(memory, forefoot::value<uintptr_t>(sections));
}
}
