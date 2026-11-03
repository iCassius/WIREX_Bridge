// WIREX Bridge 原生 GUI 外壳（R128）：Win32 + DirectX 11 + Dear ImGui。
//
// 命令行：
//   --fake                 模拟引擎 + 真实服务（config.json、设备枚举、CAT、BM API、RadioID 均为真实实现）
//   --fake-services        与 --fake 合用：服务也用内存模拟（离线截图，不读写 config.json、不访问串口/网络）
//   --config <json>        config.json 路径（默认 exe 同目录；不存在时生成默认配置）
//   --screenshot <png>     渲染若干帧后把后台缓冲区保存为 PNG 并退出（离线验收）
//   --open-settings        启动时打开设置弹窗（配合 --screenshot 检查弹窗布局）
//   --check-config         只做 config.json 生成/读取检查并退出（退出码 0 = 成功；不打开窗口）
// 不带 --fake 时使用真实引擎（需以 WIREX_GUI_REAL_ENGINE=1 编译；否则提示“真实引擎尚未接入”）。
//
// 重绘策略：只在窗口消息、引擎唤醒事件或动画需要时绘制。
// - 鼠标按下/拖动：按垂直同步连续绘制；
// - 悬停（延迟提示）、文本输入光标、等待动画：10 fps；
// - 引擎事件驱动的重绘限速到 10 fps；
// - 其余情况 MsgWaitForMultipleObjectsEx 无限等待，空闲时不占 CPU。

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <d3d11.h>
#include <imm.h>
#include <shellapi.h>
#include <wincodec.h>

#include "imgui.h"
#include "backends/imgui_impl_dx11.h"
#include "backends/imgui_impl_win32.h"

#include "app_view.hpp"
#include "fake_engine.hpp"
#include "real_services.hpp"
#include "resource.h"
#include "strings.hpp"
#include "view_model.hpp"

#ifndef WIREX_GUI_REAL_ENGINE
#define WIREX_GUI_REAL_ENGINE 0
#endif
#if WIREX_GUI_REAL_ENGINE
#include "wirex/engine.hpp"
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <vector>

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);

namespace {

using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

constexpr int kLogicalWidth = 1360;
constexpr int kLogicalHeight = 900;
constexpr int kMinLogicalWidth = 1180;
constexpr int kMinLogicalHeight = 780;
constexpr DWORD kTickMs = 100U; // 10 fps
constexpr int kScreenshotFrames = 8;
constexpr wchar_t kWindowClass[] = L"WirexBridgeGui";

template <class T>
void release(T*& p) {
    if (p != nullptr) {
        p->Release();
        p = nullptr;
    }
}

struct D3D {
    ID3D11Device* device{};
    ID3D11DeviceContext* context{};
    IDXGISwapChain* swap_chain{};
    ID3D11RenderTargetView* rtv{};
    bool occluded{};
    UINT resize_w{};
    UINT resize_h{};
};

struct Shell {
    D3D d3d{};
    float dpi_scale{1.0F};
    bool dpi_changed{};
    bool quit_requested{};
};

Shell g_shell;

bool create_render_target() {
    ID3D11Texture2D* back = nullptr;
    if (FAILED(g_shell.d3d.swap_chain->GetBuffer(0, IID_PPV_ARGS(&back))) || back == nullptr) return false;
    const HRESULT hr = g_shell.d3d.device->CreateRenderTargetView(back, nullptr, &g_shell.d3d.rtv);
    back->Release();
    return SUCCEEDED(hr);
}

bool create_device(HWND hwnd) {
    DXGI_SWAP_CHAIN_DESC sd{};
    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferDesc.RefreshRate.Numerator = 60;
    sd.BufferDesc.RefreshRate.Denominator = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    constexpr D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0};
    D3D_FEATURE_LEVEL got{};
    auto& d = g_shell.d3d;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, levels, 2,
                                               D3D11_SDK_VERSION, &sd, &d.swap_chain, &d.device, &got, &d.context);
    if (hr == DXGI_ERROR_UNSUPPORTED) {
        hr = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, levels, 2, D3D11_SDK_VERSION, &sd,
                                           &d.swap_chain, &d.device, &got, &d.context);
    }
    if (FAILED(hr)) return false;
    // 禁用 DXGI 的 Alt+Enter 全屏切换。
    IDXGIFactory* factory = nullptr;
    if (SUCCEEDED(d.swap_chain->GetParent(IID_PPV_ARGS(&factory))) && factory != nullptr) {
        factory->MakeWindowAssociation(hwnd, DXGI_MWA_NO_ALT_ENTER);
        factory->Release();
    }
    return create_render_target();
}

void destroy_device() {
    auto& d = g_shell.d3d;
    release(d.rtv);
    release(d.swap_chain);
    release(d.context);
    release(d.device);
}

LRESULT WINAPI wnd_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam)) return 1;
    switch (msg) {
    case WM_SIZE:
        if (wparam != SIZE_MINIMIZED) {
            g_shell.d3d.resize_w = LOWORD(lparam);
            g_shell.d3d.resize_h = HIWORD(lparam);
        }
        return 0;
    case WM_GETMINMAXINFO: {
        auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
        const UINT dpi = GetDpiForWindow(hwnd);
        RECT r{0, 0, MulDiv(kMinLogicalWidth, static_cast<int>(dpi), 96), MulDiv(kMinLogicalHeight, static_cast<int>(dpi), 96)};
        AdjustWindowRectExForDpi(&r, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
        info->ptMinTrackSize.x = r.right - r.left;
        info->ptMinTrackSize.y = r.bottom - r.top;
        return 0;
    }
    case WM_DPICHANGED: {
        const auto* suggested = reinterpret_cast<const RECT*>(lparam);
        SetWindowPos(hwnd, nullptr, suggested->left, suggested->top, suggested->right - suggested->left,
                     suggested->bottom - suggested->top, SWP_NOZORDER | SWP_NOACTIVATE);
        g_shell.dpi_scale = static_cast<float>(HIWORD(wparam)) / 96.0F;
        g_shell.dpi_changed = true;
        return 0;
    }
    case WM_SYSCOMMAND:
        if ((wparam & 0xFFF0U) == SC_KEYMENU) return 0; // 禁用 Alt 菜单
        break;
    case WM_CLOSE:
        g_shell.quit_requested = true;
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    default:
        break;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

// ---------------------------------------------------------------- IME

// 替换 ImGui 默认实现：默认实现把候选窗左上角放在光标处（CFS_CANDIDATEPOS），会挡住正在输入的行。
// 这里组合窗跟随光标，候选窗以 CFS_EXCLUDE 排除当前输入行，系统把候选列表放在行下方（空间不足时放上方）。
// 坐标为客户区坐标；主视口 Pos 恒为 (0,0)，因此 ImGui 屏幕坐标即客户区坐标。
void set_ime_data(ImGuiContext*, ImGuiViewport* viewport, ImGuiPlatformImeData* data) {
    const auto hwnd = static_cast<HWND>(viewport->PlatformHandleRaw);
    if (hwnd == nullptr) return;
    const HIMC himc = ImmGetContext(hwnd);
    if (himc == nullptr) return;
    const LONG x = static_cast<LONG>(data->InputPos.x - viewport->Pos.x);
    const LONG y = static_cast<LONG>(data->InputPos.y - viewport->Pos.y);
    const LONG h = static_cast<LONG>(data->InputLineHeight);
    COMPOSITIONFORM composition{};
    composition.dwStyle = CFS_FORCE_POSITION;
    composition.ptCurrentPos = POINT{x, y};
    ImmSetCompositionWindow(himc, &composition);
    CANDIDATEFORM candidate{};
    candidate.dwIndex = 0;
    candidate.dwStyle = CFS_EXCLUDE;
    candidate.ptCurrentPos = POINT{x, y + h};
    candidate.rcArea = RECT{x, y, x + 1, y + h};
    ImmSetCandidateWindow(himc, &candidate);
    ImmReleaseContext(hwnd, himc);
}

// ---------------------------------------------------------------- 字体

std::filesystem::path fonts_dir() {
    wchar_t windir[MAX_PATH] = {};
    const UINT n = GetWindowsDirectoryW(windir, MAX_PATH);
    if (n == 0U || n >= MAX_PATH) return std::filesystem::path(L"C:\\Windows\\Fonts");
    return std::filesystem::path(windir) / L"Fonts";
}

ImFont* add_font(const std::filesystem::path& file, int index) {
    std::error_code ec;
    if (!std::filesystem::is_regular_file(file, ec)) return nullptr;
    ImFontConfig cfg;
    cfg.FontNo = static_cast<ImU32>(index);
    cfg.Flags |= ImFontFlags_NoLoadError;
    cfg.OversampleH = 1; // 1.92 动态字形：CJK 无需水平过采样，降低图集内存
    const std::string utf8 = file.u8string();
    return ImGui::GetIO().Fonts->AddFontFromFileTTF(utf8.c_str(), 14.0F, &cfg);
}

// 1.92 起 DX11 backend 支持动态字体图集（RendererHasTextures），中文字形按需光栅化，无需 glyph range。
wirex::gui::Fonts load_fonts(wirex::gui::FontStatus& status) {
    const auto dir = fonts_dir();
    wirex::gui::Fonts fonts;
    // msyh.ttc：0 = Microsoft YaHei，1 = Microsoft YaHei UI（与 WPF FontFamily 一致）。
    fonts.regular = add_font(dir / L"msyh.ttc", 1);
    if (fonts.regular == nullptr) fonts.regular = add_font(dir / L"msyh.ttc", 0);
    if (fonts.regular != nullptr) {
        status = wirex::gui::FontStatus::yahei;
        fonts.bold = add_font(dir / L"msyhbd.ttc", 1);
        if (fonts.bold == nullptr) fonts.bold = add_font(dir / L"msyhbd.ttc", 0);
    } else if ((fonts.regular = add_font(dir / L"simhei.ttf", 0)) != nullptr) {
        status = wirex::gui::FontStatus::simhei;
    } else {
        status = wirex::gui::FontStatus::fallback_default;
        fonts.regular = ImGui::GetIO().Fonts->AddFontDefault();
    }
    if (fonts.bold == nullptr) fonts.bold = fonts.regular;
    return fonts;
}

// ---------------------------------------------------------------- 截图

bool save_back_buffer_png(const std::wstring& path, std::string& error) {
    auto& d = g_shell.d3d;
    ID3D11Texture2D* back = nullptr;
    if (FAILED(d.swap_chain->GetBuffer(0, IID_PPV_ARGS(&back))) || back == nullptr) {
        error = "GetBuffer failed";
        return false;
    }
    D3D11_TEXTURE2D_DESC desc{};
    back->GetDesc(&desc);
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    desc.MiscFlags = 0;
    ID3D11Texture2D* staging = nullptr;
    if (FAILED(d.device->CreateTexture2D(&desc, nullptr, &staging)) || staging == nullptr) {
        back->Release();
        error = "CreateTexture2D(staging) failed";
        return false;
    }
    d.context->CopyResource(staging, back);
    back->Release();

    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(d.context->Map(staging, 0, D3D11_MAP_READ, 0, &mapped))) {
        staging->Release();
        error = "Map failed";
        return false;
    }
    // RGBA → BGRA，alpha 置 255（WIC PNG 编码器原生支持 32bppBGRA）。
    const UINT stride = desc.Width * 4U;
    std::vector<BYTE> pixels(static_cast<std::size_t>(stride) * desc.Height);
    for (UINT y = 0; y < desc.Height; ++y) {
        const auto* src = static_cast<const BYTE*>(mapped.pData) + static_cast<std::size_t>(y) * mapped.RowPitch;
        BYTE* dst = pixels.data() + static_cast<std::size_t>(y) * stride;
        for (UINT x = 0; x < desc.Width; ++x) {
            dst[x * 4U + 0U] = src[x * 4U + 2U];
            dst[x * 4U + 1U] = src[x * 4U + 1U];
            dst[x * 4U + 2U] = src[x * 4U + 0U];
            dst[x * 4U + 3U] = 0xFFU;
        }
    }
    d.context->Unmap(staging, 0);
    staging->Release();

    IWICImagingFactory* factory = nullptr;
    IWICStream* stream = nullptr;
    IWICBitmapEncoder* encoder = nullptr;
    IWICBitmapFrameEncode* frame = nullptr;
    HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
    if (SUCCEEDED(hr)) hr = factory->CreateStream(&stream);
    if (SUCCEEDED(hr)) hr = stream->InitializeFromFilename(path.c_str(), GENERIC_WRITE);
    if (SUCCEEDED(hr)) hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
    if (SUCCEEDED(hr)) hr = encoder->Initialize(stream, WICBitmapEncoderNoCache);
    if (SUCCEEDED(hr)) hr = encoder->CreateNewFrame(&frame, nullptr);
    if (SUCCEEDED(hr)) hr = frame->Initialize(nullptr);
    if (SUCCEEDED(hr)) hr = frame->SetSize(desc.Width, desc.Height);
    WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
    if (SUCCEEDED(hr)) hr = frame->SetPixelFormat(&format);
    if (SUCCEEDED(hr) && format != GUID_WICPixelFormat32bppBGRA) hr = E_FAIL;
    if (SUCCEEDED(hr)) hr = frame->WritePixels(desc.Height, stride, static_cast<UINT>(pixels.size()), pixels.data());
    if (SUCCEEDED(hr)) hr = frame->Commit();
    if (SUCCEEDED(hr)) hr = encoder->Commit();
    release(frame);
    release(encoder);
    release(stream);
    release(factory);
    if (FAILED(hr)) {
        char buffer[64];
        wsprintfA(buffer, "WIC PNG encode failed (0x%08lX)", static_cast<unsigned long>(hr));
        error = buffer;
        return false;
    }
    return true;
}

// ---------------------------------------------------------------- 命令行

struct Options {
    bool fake{};
    bool fake_services{};
    bool open_settings{};
    bool check_config{};
    std::optional<std::wstring> screenshot{};
    std::optional<std::filesystem::path> config{};
    std::wstring error{};
};

Options parse_args() {
    Options o;
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv == nullptr) {
        o.error = L"无法解析命令行。";
        return o;
    }
    for (int i = 1; i < argc; ++i) {
        const std::wstring a = argv[i];
        if (a == L"--fake") {
            o.fake = true;
        } else if (a == L"--fake-services") {
            o.fake_services = true;
        } else if (a == L"--open-settings") {
            o.open_settings = true;
        } else if (a == L"--check-config") {
            o.check_config = true;
        } else if (a == L"--config") {
            if (i + 1 >= argc) {
                o.error = L"--config 需要 config.json 路径。";
                break;
            }
            std::error_code ec;
            auto full = std::filesystem::absolute(argv[++i], ec);
            if (ec) {
                o.error = L"config.json 路径无效。";
                break;
            }
            o.config = std::move(full);
        } else if (a == L"--screenshot") {
            if (i + 1 >= argc) {
                o.error = L"--screenshot 需要 PNG 路径。";
                break;
            }
            std::error_code ec;
            const auto full = std::filesystem::absolute(argv[++i], ec);
            if (ec) {
                o.error = L"截图路径无效。";
                break;
            }
            o.screenshot = full.wstring();
        } else {
            o.error = L"未知参数：" + a +
                      L"\n用法：WirexBridge.exe [--fake [--fake-services]] [--config <json>] [--screenshot <png>] "
                      L"[--open-settings] [--check-config]";
            break;
        }
    }
    LocalFree(argv);
    if (o.error.empty() && o.fake_services && !o.fake) o.error = L"--fake-services 只能与 --fake 一起使用。";
    return o;
}

std::wstring widen(const std::string& s);

// 引擎 + 服务的组合。FakeEngine 或真实 Engine（经 EngineAdapter 包装）二选一。
struct Backend {
    std::unique_ptr<wirex::gui::FakeEngine> fake{};
#if WIREX_GUI_REAL_ENGINE
    std::unique_ptr<wirex::engine::Engine> real{};
    std::unique_ptr<wirex::gui::EngineAdapter<wirex::engine::Engine>> adapter{};
#endif
    wirex::gui::EngineApi* api{};
    wirex::gui::services::Services services{};
};

std::optional<Backend> make_backend(const Options& opts, std::wstring& error) {
    Backend b;
    wirex::gui::RealServiceOptions so;
    if (opts.config) so.config_path = *opts.config;
    if (opts.fake) {
        wirex::gui::FakeEngineOptions fake_opts;
        fake_opts.seed_demo = true;
        b.fake = std::make_unique<wirex::gui::FakeEngine>(fake_opts);
        b.api = b.fake.get();
        if (opts.fake_services) {
            b.services = wirex::gui::make_fake_services(*b.fake);
        } else {
            so.lenient_start = true; // 真实检查未通过时仍允许模拟引擎“连接串口”
            b.services = wirex::gui::make_real_services(*b.api, so);
        }
        return b;
    }
#if WIREX_GUI_REAL_ENGINE
    try {
        b.real = std::make_unique<wirex::engine::Engine>();
    } catch (const std::exception& e) {
        error = L"无法创建桥接引擎：" + widen(e.what());
        return std::nullopt;
    }
    b.adapter = std::make_unique<wirex::gui::EngineAdapter<wirex::engine::Engine>>(*b.real);
    b.api = b.adapter.get();
    b.services = wirex::gui::make_real_services(*b.api, so);
    return b;
#else
    // 真实引擎（wirex::engine::Engine）尚未合入；以 /DWIREX_GUI_REAL_ENGINE=1 编译并链接引擎源文件后启用。
    error = widen(wirex::gui::tr(wirex::gui::Str::engine_unavailable));
    return std::nullopt;
#endif
}

// --check-config：生成（若不存在）并读回 config.json；只输出结构信息，不输出任何字段值。
int check_config(const Options& opts) {
    wirex::gui::FakeEngine engine;
    wirex::gui::RealServiceOptions so;
    if (opts.config) so.config_path = *opts.config;
    auto services = wirex::gui::make_real_services(engine, so);
    std::string error;
    auto first = services.config.load(error);
    int code = 0;
    if (!first) {
        code = 3;
    } else if (!services.config.save(*first, error)) {
        code = 4; // 写回（保留未知字段）失败
    } else if (auto second = services.config.load(error); !second || second->channels.size() != first->channels.size()) {
        code = 5;
    }
    services.shutdown();
    return code;
}

void fail_box(const std::wstring& text) { MessageBoxW(nullptr, text.c_str(), L"WIREX Bridge", MB_ICONERROR | MB_OK); }

std::wstring widen(const std::string& s) {
    if (s.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring w(static_cast<std::size_t>(std::max(n, 0)), L'\0');
    if (n > 0) MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
    return w;
}

void render(const ImVec4& clear) {
    auto& d = g_shell.d3d;
    ImGui::Render();
    const float c[4] = {clear.x, clear.y, clear.z, 1.0F};
    d.context->OMSetRenderTargets(1, &d.rtv, nullptr);
    d.context->ClearRenderTargetView(d.rtv, c);
    ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
}

int run(HINSTANCE instance) {
    const Options opts = parse_args();
    if (!opts.error.empty()) {
        fail_box(opts.error);
        return 2;
    }
    if (opts.check_config) return check_config(opts);
#if !WIREX_GUI_REAL_ENGINE
    if (!opts.fake) {
        fail_box(widen(wirex::gui::tr(wirex::gui::Str::engine_unavailable)));
        return 2;
    }
#endif

    ImGui_ImplWin32_EnableDpiAwareness(); // Per-Monitor V2（manifest 中也已声明）

    const HRESULT co = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool co_ok = SUCCEEDED(co);

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.style = CS_CLASSDC;
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = instance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kWindowClass;
    wc.hIcon = static_cast<HICON>(LoadImageW(instance, MAKEINTRESOURCEW(IDI_WIREX_APP), IMAGE_ICON,
                                             GetSystemMetrics(SM_CXICON), GetSystemMetrics(SM_CYICON), LR_DEFAULTCOLOR));
    wc.hIconSm = static_cast<HICON>(LoadImageW(instance, MAKEINTRESOURCEW(IDI_WIREX_APP), IMAGE_ICON,
                                               GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
    if (RegisterClassExW(&wc) == 0) {
        fail_box(L"RegisterClassExW 失败。");
        if (co_ok) CoUninitialize();
        return 1;
    }

    // 以主显示器 DPI 计算 1360×900 逻辑客户区，并居中。
    const HMONITOR monitor = MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY);
    g_shell.dpi_scale = ImGui_ImplWin32_GetDpiScaleForMonitor(monitor);
    const UINT dpi = static_cast<UINT>(std::lround(g_shell.dpi_scale * 96.0F));
    RECT rect{0, 0, static_cast<LONG>(std::lround(kLogicalWidth * g_shell.dpi_scale)),
              static_cast<LONG>(std::lround(kLogicalHeight * g_shell.dpi_scale))};
    AdjustWindowRectExForDpi(&rect, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
    MONITORINFO mi{};
    mi.cbSize = sizeof(mi);
    GetMonitorInfoW(monitor, &mi);
    const int win_w = rect.right - rect.left;
    const int win_h = rect.bottom - rect.top;
    const int x = mi.rcWork.left + std::max(0, static_cast<int>((mi.rcWork.right - mi.rcWork.left - win_w) / 2));
    const int y = mi.rcWork.top + std::max(0, static_cast<int>((mi.rcWork.bottom - mi.rcWork.top - win_h) / 2));
    const std::wstring title = widen(wirex::gui::tr(wirex::gui::Str::window_title));
    HWND hwnd = CreateWindowExW(0, kWindowClass, title.c_str(), WS_OVERLAPPEDWINDOW, x, y, win_w, win_h, nullptr, nullptr,
                                instance, nullptr);
    if (hwnd == nullptr) {
        fail_box(L"CreateWindowExW 失败。");
        UnregisterClassW(kWindowClass, instance);
        if (co_ok) CoUninitialize();
        return 1;
    }
    g_shell.dpi_scale = ImGui_ImplWin32_GetDpiScaleForHwnd(hwnd);
    if (!create_device(hwnd)) {
        fail_box(L"无法创建 Direct3D 11 设备。");
        destroy_device();
        DestroyWindow(hwnd);
        UnregisterClassW(kWindowClass, instance);
        if (co_ok) CoUninitialize();
        return 1;
    }
    ShowWindow(hwnd, opts.screenshot ? SW_SHOWNOACTIVATE : SW_SHOWDEFAULT);
    UpdateWindow(hwnd);

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO& io = ImGui::GetIO();
    io.IniFilename = nullptr; // 不写 imgui.ini
    io.LogFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    wirex::gui::apply_theme(g_shell.dpi_scale);
    const bool win32_ok = ImGui_ImplWin32_Init(hwnd);
    const bool dx11_ok = win32_ok && ImGui_ImplDX11_Init(g_shell.d3d.device, g_shell.d3d.context);
    if (!dx11_ok) {
        fail_box(L"Dear ImGui backend 初始化失败。");
        if (win32_ok) ImGui_ImplWin32_Shutdown();
        ImGui::DestroyContext();
        destroy_device();
        DestroyWindow(hwnd);
        UnregisterClassW(kWindowClass, instance);
        if (co_ok) CoUninitialize();
        return 1;
    }
    ImGui::GetPlatformIO().Platform_SetImeDataFn = set_ime_data;
    wirex::gui::FontStatus font_status{};
    const wirex::gui::Fonts fonts = load_fonts(font_status);

    int exit_code = 0;
    {
        HANDLE wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        std::wstring backend_error;
        std::optional<Backend> backend;
        if (wake != nullptr) backend = make_backend(opts, backend_error);
        if (wake == nullptr) {
            fail_box(L"CreateEventW 失败。");
            exit_code = 1;
        } else if (!backend) {
            fail_box(backend_error);
            exit_code = 2;
        } else {
            // 成员析构顺序：vm（停止服务线程）→ backend（引擎）。
            wirex::gui::ViewModel vm(*backend->api, std::move(backend->services), opts.fake);
            vm.set_font_status(font_status);
            vm.set_wakeup([wake]() { SetEvent(wake); });
            wirex::gui::AppView view(vm, fonts);
            if (opts.open_settings) view.open_settings();

            const ImVec4 clear = ImGui::GetStyle().Colors[ImGuiCol_WindowBg];
            bool dirty = true;
            bool input = false;
            bool continuous = false;
            int settle_frames = 0;
            int hover_frames = 0;
            int frames = 0;
            const auto shot_after = Clock::now() + 1500ms; // 等后台服务（静态组、CAT、身份查询）的首个结果
            DWORD wait_ms = 0;
            auto last_frame = Clock::now() - 1s;
            bool running = true;
            while (running) {
                const DWORD r = MsgWaitForMultipleObjectsEx(1, &wake, wait_ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
                if (r == WAIT_TIMEOUT) dirty = true;
                if (r == WAIT_FAILED) {
                    exit_code = 1;
                    break;
                }
                MSG msg;
                while (PeekMessageW(&msg, nullptr, 0U, 0U, PM_REMOVE)) {
                    if (msg.message == WM_QUIT) running = false;
                    TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                    input = true;
                }
                if (!running) break;
                if (vm.pump()) dirty = true;
                if (g_shell.quit_requested || vm.exit_requested()) {
                    if (vm.snapshot().phase != wirex::engine::Phase::stopped && !vm.pending(wirex::gui::Str::op_stop)) vm.stop();
                    DestroyWindow(hwnd);
                    g_shell.quit_requested = false;
                    wait_ms = INFINITE;
                    continue; // 等 WM_QUIT
                }
                if (input) {
                    dirty = true;
                    settle_frames = 2; // ImGui 的悬停/点击状态需要多一两帧稳定
                }

                const auto now = Clock::now();
                const bool fast = input || continuous || settle_frames > 0 || opts.screenshot.has_value();
                if (!dirty && !fast) {
                    // 无事可做：等待下一次消息/唤醒，或 ViewModel 指定的刷新时间（例如通话计时）。
                    const auto t = vm.idle_timeout_ms();
                    wait_ms = t ? std::max<DWORD>(*t, kTickMs) : INFINITE;
                    continue;
                }
                if (!fast) {
                    const auto since = std::chrono::duration_cast<std::chrono::milliseconds>(now - last_frame).count();
                    if (since < static_cast<long long>(kTickMs)) { // 引擎事件驱动的重绘限速 10 fps
                        wait_ms = kTickMs - static_cast<DWORD>(since);
                        continue;
                    }
                }

                // 最小化/被遮挡时不绘制
                auto& d = g_shell.d3d;
                if (d.occluded && d.swap_chain->Present(0, DXGI_PRESENT_TEST) == DXGI_STATUS_OCCLUDED) {
                    wait_ms = 250U;
                    continue;
                }
                d.occluded = false;
                if (d.resize_w != 0U && d.resize_h != 0U) {
                    release(d.rtv);
                    if (FAILED(d.swap_chain->ResizeBuffers(0, d.resize_w, d.resize_h, DXGI_FORMAT_UNKNOWN, 0)) ||
                        !create_render_target()) {
                        fail_box(L"调整交换链大小失败。");
                        exit_code = 1;
                        break;
                    }
                    d.resize_w = d.resize_h = 0U;
                }
                if (g_shell.dpi_changed) {
                    g_shell.dpi_changed = false;
                    wirex::gui::apply_theme(g_shell.dpi_scale);
                }

                ImGui_ImplDX11_NewFrame();
                ImGui_ImplWin32_NewFrame();
                ImGui::NewFrame();
                view.draw(g_shell.dpi_scale);
                const bool mouse_down = ImGui::IsAnyMouseDown();
                // 悬停只在提示延迟（≈0.5 s）出现前后刷新 1.5 s；文本输入保持 10 fps 以显示光标闪烁。
                const bool mouse_still = io.MouseDelta.x == 0.0F && io.MouseDelta.y == 0.0F;
                hover_frames = ImGui::IsAnyItemHovered() ? (mouse_still ? hover_frames + 1 : 0) : 99;
                const bool hover_tick = hover_frames < 15;
                const bool ticking = view.wants_continuous() || io.WantTextInput || hover_tick;
                render(clear);
                ++frames;

                if (opts.screenshot && frames >= kScreenshotFrames && Clock::now() >= shot_after) {
                    std::string error;
                    if (!save_back_buffer_png(*opts.screenshot, error)) {
                        fail_box(L"截图失败：" + widen(error));
                        exit_code = 1;
                    }
                    g_shell.quit_requested = true;
                }
                const HRESULT hr = d.swap_chain->Present(1, 0);
                d.occluded = hr == DXGI_STATUS_OCCLUDED;
                if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) {
                    fail_box(L"Direct3D 设备已丢失。");
                    exit_code = 1;
                    break;
                }

                last_frame = now;
                dirty = false;
                input = false;
                if (settle_frames > 0) --settle_frames;
                continuous = mouse_down;
                if (opts.screenshot || mouse_down || settle_frames > 0) {
                    wait_ms = 0U; // Present(1) 按垂直同步节流
                } else if (ticking) {
                    wait_ms = kTickMs;
                    dirty = true; // 悬停提示、光标闪烁、等待动画按 10 fps 刷新
                } else {
                    const auto t = vm.idle_timeout_ms();
                    wait_ms = t ? std::max<DWORD>(*t, kTickMs) : INFINITE;
                }
            }
            vm.set_wakeup({});
        }
        if (wake != nullptr) CloseHandle(wake);
    }

    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    destroy_device();
    if (IsWindow(hwnd)) DestroyWindow(hwnd);
    UnregisterClassW(kWindowClass, instance);
    if (co_ok) CoUninitialize();
    return exit_code;
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    try {
        return run(instance);
    } catch (const std::exception& e) {
        fail_box(L"未处理的异常：" + widen(e.what()));
    } catch (...) {
        fail_box(L"未处理的异常。");
    }
    return 1;
}
