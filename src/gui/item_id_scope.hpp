#pragma once

#include "imgui.h"

namespace wirex::gui::detail {

// Give repeated visible labels distinct ImGui IDs by pushing stable item identity.
// Use an index only when the source item has no stable identifier.
class ItemIdScope final {
public:
    ItemIdScope(const char* stable_id, int fallback_index) {
        if (stable_id != nullptr && stable_id[0] != '\0') ImGui::PushID(stable_id);
        else ImGui::PushID(fallback_index);
    }

    ~ItemIdScope() { ImGui::PopID(); }

    ItemIdScope(const ItemIdScope&) = delete;
    ItemIdScope& operator=(const ItemIdScope&) = delete;
};

} // namespace wirex::gui::detail
