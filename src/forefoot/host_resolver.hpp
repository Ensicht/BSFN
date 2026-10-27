#pragma once
#include <array>
#include <cstring>
#include "host_patterns.hpp"

namespace host_resolver {
constexpr uintptr_t scene_lock = 0x328;
struct Resolution {
    std::array<uintptr_t, host_patterns::values.size()> sites{};
    uintptr_t scene_slot = 0, enter_iat = 0, leave_iat = 0;
};
struct Matches {
    std::array<uintptr_t, 64> items{};
    unsigned count = 0;
    bool add(uintptr_t value) {
        if (count == items.size()) return false;
        items[count++] = value;
        return true;
    }
};

template<class Image, class Memory> class Resolver {
    uintptr_t base;
    const Image& image;
    const Memory& memory;
    std::array<Matches, host_patterns::values.size()> found{};
    bool scan_error = false;
    bool matches(unsigned id, uintptr_t at) const {
        const auto& pattern = host_patterns::values[id];
        if (!image.range(memory, at, pattern.bytes.size(), true)) return false;
        const auto* p = reinterpret_cast<const unsigned char*>(base + at);
        for (size_t i = 0; i < pattern.bytes.size(); ++i)
            if (pattern.mask[i] && p[i] != static_cast<unsigned char>(pattern.bytes[i])) return false;
        return true;
    }
    bool scan(unsigned id, uintptr_t scope_begin = 0, uintptr_t scope_end = 0) {
        const auto& pattern = host_patterns::values[id];
        size_t seed = 0, length = 0;
        for (size_t i = 0; i < pattern.mask.size();) {
            if (!pattern.mask[i]) { ++i; continue; }
            const auto start = i;
            while (i < pattern.mask.size() && pattern.mask[i]) ++i;
            if (i - start > length) { seed = start; length = i - start; }
        }
        if (length < 7) return false;
        std::array<size_t, 256> skip{};
        skip.fill(length);
        for (size_t i = 0; i + 1 < length; ++i)
            skip[static_cast<unsigned char>(pattern.bytes[seed + i])] = length - i - 1;
        for (unsigned i = 0; i < image.nt->FileHeader.NumberOfSections; ++i) {
            const auto& section = image.sections[i];
            if (!(section.Characteristics & IMAGE_SCN_MEM_EXECUTE) ||
                !(section.Characteristics & IMAGE_SCN_MEM_READ)) continue;
            const auto size = static_cast<size_t>(section.Misc.VirtualSize);
            if (size < pattern.bytes.size()) continue;
             
            uintptr_t cursor = section.VirtualAddress;
            uintptr_t end = cursor + size;
            if (scope_end) {
                if (cursor < scope_begin) cursor = scope_begin;
                if (end > scope_end) end = scope_end;
            }
            while (cursor < end) {
                MEMORY_BASIC_INFORMATION page{};
                if (!VirtualQuery(reinterpret_cast<void*>(base + cursor), &page, sizeof(page))) { scan_error = true; return false; }
                const auto region_end = reinterpret_cast<uintptr_t>(page.BaseAddress) + page.RegionSize;
                const auto stop = region_end < base + end ? region_end - base : end;
                if (stop <= cursor) { scan_error = true; return false; }
                const auto mode = page.Protect & 0xff;
                const bool readable = page.State == MEM_COMMIT && !(page.Protect & (PAGE_GUARD | PAGE_NOACCESS)) &&
                    (mode == PAGE_EXECUTE_READ || mode == PAGE_EXECUTE_READWRITE || mode == PAGE_EXECUTE_WRITECOPY) &&
                    reinterpret_cast<uintptr_t>(page.AllocationBase) == base;
                if (readable && stop - cursor >= pattern.bytes.size()) {
                    const auto* p = reinterpret_cast<const unsigned char*>(base + cursor + seed);
                    const auto* limit = reinterpret_cast<const unsigned char*>(base + stop - pattern.bytes.size() + seed);
                    while (p <= limit) {
                        const auto tail = p[length - 1];
                        const auto at = reinterpret_cast<uintptr_t>(p) - base - seed;
                        if (tail == static_cast<unsigned char>(pattern.bytes[seed + length - 1]) &&
                            !std::memcmp(p, pattern.bytes.data() + seed, length) && matches(id, at) && !found[id].add(at)) {
                            scan_error = true;
                            return false;
                        }
                        p += skip[tail];
                    }
                }
                cursor = stop;
            }
        }
        return found[id].count != 0;
    }
    uintptr_t function(uintptr_t at) const {
        const auto& directory = image.nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
        if (!directory.VirtualAddress || directory.Size % sizeof(RUNTIME_FUNCTION) ||
            !image.range(memory, directory.VirtualAddress, directory.Size, false)) return 0;
        const auto* table = reinterpret_cast<const RUNTIME_FUNCTION*>(base + directory.VirtualAddress);
        size_t begin = 0, end = directory.Size / sizeof(RUNTIME_FUNCTION);
        while (begin < end) {
            const auto mid = begin + (end - begin) / 2;
            if (table[mid].BeginAddress <= at) begin = mid + 1; else end = mid;
        }
        if (!begin || at >= table[begin - 1].EndAddress) return 0;
        return table[begin - 1].BeginAddress;
    }
    uintptr_t function_end(uintptr_t start) const {
        const auto& directory = image.nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXCEPTION];
        if (!start || !image.range(memory, directory.VirtualAddress, directory.Size, false)) return 0;
        const auto* table = reinterpret_cast<const RUNTIME_FUNCTION*>(base + directory.VirtualAddress);
        size_t begin = 0, end = directory.Size / sizeof(RUNTIME_FUNCTION);
        while (begin < end) {
            const auto mid = begin + (end - begin) / 2;
            if (table[mid].BeginAddress < start) begin = mid + 1; else end = mid;
        }
        return begin < directory.Size / sizeof(RUNTIME_FUNCTION) && table[begin].BeginAddress == start ? table[begin].EndAddress : 0;
    }
    uintptr_t relative(uintptr_t at, unsigned displacement, unsigned next) const {
        if (!image.range(memory, at, next, true)) return 0;
        int32_t value{};
        std::memcpy(&value, reinterpret_cast<const void*>(base + at + displacement), sizeof(value));
        const auto target = static_cast<int64_t>(at + next) + value;
        return target > 0 && static_cast<uint64_t>(target) < image.nt->OptionalHeader.SizeOfImage
            ? static_cast<uintptr_t>(target) : 0;
    }
public:
    unsigned stage = 0;
    Resolver(uintptr_t b, const Image& i, const Memory& m) : base(b), image(i), memory(m) {}
    bool run(const std::array<uintptr_t, 6>& typed, Resolution& output) {
        output = {};
        stage = 1;
        if (!scan(0) || found[0].count != 1) return false;
        const auto mapping_start = function(found[0].items[0]);
        const auto mapping_end = function_end(mapping_start);
        if (!mapping_start || !mapping_end) return false;
        for (unsigned i : {1u, 2u, 3u, 4u, 14u, 15u})
            if (!scan(i, mapping_start, mapping_end)) return false;
        stage = 2;
        for (unsigned i : {7u, 8u, 9u, 18u, 20u}) {
             
            int slot = i >= 7 && i <= 9 ? static_cast<int>(i - 7) : i == 18 ? 3 : i == 20 ? 4 : -1;
            if (slot >= 0) {
                if (!typed[slot] || !matches(i, typed[slot]) || !found[i].add(typed[slot])) return false;
            } else return false;
        }
         
        const auto dirty = relative(found[7].items[0], 47, 51);
        if (!dirty || !matches(10, dirty) || !found[10].add(dirty)) return false;
        const auto update = relative(dirty, 76, 80);
        if (!update || !matches(11, update) || !found[11].add(update)) return false;
        const auto outputs = relative(found[20].items[0], 4, 8);
        if (!outputs || !matches(21, outputs) || !found[21].add(outputs)) return false;
        stage = 3;
        if (!scan(5)) return false;
        std::array<uintptr_t, 64> scanned{};
        unsigned scanned_count = 0;
        for (unsigned i = 0; i < found[5].count; ++i) {
            const auto begin = function(found[5].items[i]);
            bool seen = false;
            for (unsigned j = 0; j < scanned_count; ++j) seen = seen || scanned[j] == begin;
            if (!begin || seen) continue;
            scanned[scanned_count++] = begin;
             
            scan(6, begin, function_end(begin));
            if (scan_error) return false;
        }
        if (!found[6].count) return false;
        for (unsigned i : {12u, 13u, 16u, 17u, 19u, 22u, 23u}) {
            stage = 100 + i;
            if (!scan(i)) return false;
        }
        stage = 4;
        auto& s = output.sites;
        for (unsigned i = 0; i < found.size(); ++i) {
            if (i == 4 || i == 5 || i == 6) continue;
            if (found[i].count != 1) return false;
            s[i] = found[i].items[0];
        }
        const auto mapping = function(s[0]);
        if (!mapping) return false;
        for (unsigned i : {1u, 2u, 3u, 14u, 15u})
            if (function(s[i]) != mapping) return false;
        for (unsigned i = 0; i < found[4].count; ++i)
            if (function(found[4].items[i]) == mapping) {
                if (s[4]) return false;
                s[4] = found[4].items[i];
            }
        unsigned pairs = 0;
        for (unsigned i = 0; i < found[5].count; ++i) for (unsigned j = 0; j < found[6].count; ++j) {
            const auto a = found[5].items[i], b = found[6].items[j];
            if (function(a) && function(a) == function(b)) { s[5] = a; s[6] = b; ++pairs; }
        }
        if (!s[4] || pairs != 1) return false;
        stage = 5;
        output.scene_slot = relative(s[0], 8, 12);
        output.enter_iat = relative(s[0], 17, 21);
        output.leave_iat = relative(s[4], 22, 26);
        if (!output.scene_slot || !output.enter_iat || !output.leave_iat ||
            output.scene_slot != relative(s[5], 8, 12) || output.scene_slot != relative(s[11], 28, 32) ||
            output.enter_iat != relative(s[5], 17, 21) || output.enter_iat != relative(s[11], 37, 41) ||
            output.leave_iat != relative(s[6], 8, 12) || output.leave_iat != relative(s[11], 129, 133)) return false;
        if (!image.range(memory, typed[5], 15, true)) return false;
        const auto* getter = reinterpret_cast<const unsigned char*>(base + typed[5]);
        if (std::memcmp(getter, "\x48\x8b\x05", 3) ||
            std::memcmp(getter + 7, "\x48\x8b\x80\x90\x00\x00\x00\xc3", 8) ||
            relative(typed[5], 3, 7) != output.scene_slot) return false;
        for (auto rva : {output.scene_slot, output.enter_iat, output.leave_iat})
            if (!image.range(memory, rva, sizeof(uintptr_t), false)) return false;
        if (relative(s[7], 47, 51) != s[10] || relative(s[8], 35, 39) != s[10] ||
            relative(s[9], 47, 51) != s[10] || relative(s[10], 76, 80) != s[11] ||
            relative(s[20], 4, 8) != s[21]) return false;
        stage = 0;
        return true;
    }
};
}
