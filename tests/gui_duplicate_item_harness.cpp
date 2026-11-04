#include "imgui.h"
#include "imgui_internal.h"
#include "item_id_scope.hpp"

#include <array>
#include <cfloat>
#include <cstdio>
#include <cstdlib>

namespace {

struct Fixture {
    std::array<ImGuiID, 2> radio_ids{};
    std::array<ImGuiID, 2> same_label_ids{};
    std::array<ImGuiID, 2> audio_ids{};
    std::array<ImVec2, 2> radio_centers{};
    std::array<ImVec2, 2> same_label_centers{};
    std::array<ImVec2, 2> audio_centers{};
    int radio_selected{-1};
    int same_label_selected{-1};
    int audio_selected{-1};
};

void require(bool condition, const char* message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        std::exit(1);
    }
}

ImVec2 item_center() {
    const ImVec2 min = ImGui::GetItemRectMin();
    const ImVec2 max = ImGui::GetItemRectMax();
    return ImVec2(min.x + (max.x - min.x) * 0.5F, min.y + (max.y - min.y) * 0.5F);
}

void draw_choice(const char* stable_id, int fallback_index, const char* label,
                 int index, int& selected, ImGuiID& captured_id, ImVec2& center) {
    wirex::gui::detail::ItemIdScope item_id(stable_id, fallback_index);
    captured_id = ImGui::GetID(label);
    if (ImGui::Selectable(label, selected == index)) selected = index;
    center = item_center();
}

void render_frame(Fixture& fixture, ImVec2 mouse_pos, bool mouse_down) {
    ImGuiIO& io = ImGui::GetIO();
    io.MousePos = mouse_pos;
    io.MouseDown[0] = mouse_down;
    io.DeltaTime = 1.0F / 60.0F;

    ImGui::NewFrame();
    ImGui::SetNextWindowPos(ImVec2(10.0F, 10.0F), ImGuiCond_Always);
    ImGui::SetNextWindowSize(ImVec2(700.0F, 540.0F), ImGuiCond_Always);
    ImGui::Begin("Repeated ImGui choices", nullptr, ImGuiWindowFlags_NoSavedSettings);

    ImGui::TextUnformatted("HRI: Auto resolves to COM5; manual COM5 remains a separate choice.");
    draw_choice("auto-resolved:COM5", 0, "Auto · COM5", 0, fixture.radio_selected,
                fixture.radio_ids[0], fixture.radio_centers[0]);
    draw_choice("COM5", 1, "COM5 · Silicon Labs CP210x (Wires-X)", 1, fixture.radio_selected,
                fixture.radio_ids[1], fixture.radio_centers[1]);

    ImGui::Separator();
    ImGui::TextUnformatted("Stress: two visible COM5 labels with different stable keys.");
    draw_choice("auto-resolved:COM5-stress", 0, "COM5", 0, fixture.same_label_selected,
                fixture.same_label_ids[0], fixture.same_label_centers[0]);
    draw_choice("manual:COM5-stress", 1, "COM5", 1, fixture.same_label_selected,
                fixture.same_label_ids[1], fixture.same_label_centers[1]);

    ImGui::Separator();
    ImGui::TextUnformatted("Two audio endpoints share one visible name.");
    draw_choice("{endpoint-a}", 0, "USB headset", 0, fixture.audio_selected,
                fixture.audio_ids[0], fixture.audio_centers[0]);
    draw_choice("{endpoint-b}", 1, "USB headset", 1, fixture.audio_selected,
                fixture.audio_ids[1], fixture.audio_centers[1]);

    ImGui::End();
    ImGui::Render();
    require(ImGui::GetDrawData()->TotalVtxCount > 0, "frame rendered visible choice rows");
    require(GImGui->DebugDrawIdConflictsId == 0, "Dear ImGui reported no visible ID conflict");
}

void click_choice(Fixture& fixture, ImVec2 center) {
    render_frame(fixture, center, true);
    render_frame(fixture, center, false);
}

} // namespace

int main() {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
    io.DisplaySize = ImVec2(720.0F, 560.0F);
    io.DisplayFramebufferScale = ImVec2(1.0F, 1.0F);
    io.ConfigDebugHighlightIdConflicts = true;
    io.ConfigDebugHighlightIdConflictsShowItemPicker = false;
    ImGui::StyleColorsDark();
    require(io.Fonts->Build(), "default font atlas built");

    Fixture fixture;
    render_frame(fixture, ImVec2(-FLT_MAX, -FLT_MAX), false);
    require(fixture.radio_ids[0] != fixture.radio_ids[1], "Auto COM5 and manual COM5 have distinct IDs");
    require(fixture.same_label_ids[0] != fixture.same_label_ids[1], "same visible COM5 labels have distinct IDs");
    require(fixture.audio_ids[0] != fixture.audio_ids[1], "same audio names with different endpoint IDs remain distinct");

    click_choice(fixture, fixture.radio_centers[1]);
    require(fixture.radio_selected == 1, "click selected manual COM5");
    click_choice(fixture, fixture.radio_centers[0]);
    require(fixture.radio_selected == 0, "click selected Auto-resolved COM5");
    click_choice(fixture, fixture.same_label_centers[1]);
    require(fixture.same_label_selected == 1, "click selected second same-label COM5 item");
    click_choice(fixture, fixture.audio_centers[1]);
    require(fixture.audio_selected == 1, "click selected second same-name audio endpoint");
    click_choice(fixture, fixture.audio_centers[0]);
    require(fixture.audio_selected == 0, "click selected first same-name audio endpoint");

    ImGui::DestroyContext();
    std::puts("PASS: repeated candidate render, unique IDs, and click selection checks");
    return 0;
}
