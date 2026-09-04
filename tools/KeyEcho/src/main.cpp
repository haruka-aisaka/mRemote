#include <windows.h>
#include <commdlg.h>
#include <winternl.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <cwchar>
#include <iomanip>
#include <limits>
#include <memory>
#include <sstream>
#include <string>
#include <string_view>

namespace {

constexpr wchar_t kWindowClass[] = L"mRemote.KeyEcho.Window";
constexpr UINT kKeyboardEventMessage = WM_APP + 1;
constexpr int kClearButtonId = 1001;
constexpr int kCopyButtonId = 1002;
constexpr int kSaveButtonId = 1003;
constexpr int kResetButtonId = 1004;

constexpr DWORD kEisuScanCode = 0x7B;
constexpr DWORD kKanaScanCode = 0x79;

struct KeyboardEvent {
    std::uint64_t sequence;
    std::uint64_t monotonicNanoseconds;
    DWORD scanCode;
    DWORD virtualKey;
    DWORD flags;
};

struct TargetCounts {
    std::uint64_t down = 0;
    std::uint64_t up = 0;
    std::uint64_t repeats = 0;
    std::uint64_t mappingMismatches = 0;
    bool pressed = false;
};

struct AppState {
    HWND window = nullptr;
    HWND status = nullptr;
    HWND log = nullptr;
    HHOOK keyboardHook = nullptr;
    LARGE_INTEGER performanceFrequency{};
    std::wstring jsonLines;
    TargetCounts eisu;
    TargetCounts kana;
};

AppState* gState = nullptr;
std::atomic<std::uint64_t> gSequence{0};

std::wstring WindowsVersion() {
    using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
    const auto ntdll = GetModuleHandleW(L"ntdll.dll");
    if (!ntdll) {
        return L"unknown";
    }
    const auto rtlGetVersion = reinterpret_cast<RtlGetVersionFn>(
        GetProcAddress(ntdll, "RtlGetVersion"));
    if (!rtlGetVersion) {
        return L"unknown";
    }

    RTL_OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    if (rtlGetVersion(&version) != 0) {
        return L"unknown";
    }

    std::wostringstream output;
    output << version.dwMajorVersion << L'.' << version.dwMinorVersion
           << L" build " << version.dwBuildNumber;
    return output.str();
}

std::wstring ComputerName() {
    std::array<wchar_t, MAX_COMPUTERNAME_LENGTH + 1> buffer{};
    DWORD size = static_cast<DWORD>(buffer.size());
    if (!GetComputerNameW(buffer.data(), &size)) {
        return L"unknown";
    }
    return std::wstring(buffer.data(), size);
}

std::wstring JsonEscape(std::wstring_view value) {
    std::wostringstream escaped;
    escaped << L'\"';
    for (const auto character : value) {
        switch (character) {
        case L'\"':
            escaped << L"\\\"";
            break;
        case L'\\':
            escaped << L"\\\\";
            break;
        case L'\b':
            escaped << L"\\b";
            break;
        case L'\f':
            escaped << L"\\f";
            break;
        case L'\n':
            escaped << L"\\n";
            break;
        case L'\r':
            escaped << L"\\r";
            break;
        case L'\t':
            escaped << L"\\t";
            break;
        default:
            if (character < L' ') {
                escaped << L"\\u" << std::uppercase << std::hex << std::setw(4)
                        << std::setfill(L'0') << static_cast<unsigned int>(character)
                        << std::dec;
            } else {
                escaped << character;
            }
            break;
        }
    }
    escaped << L'\"';
    return escaped.str();
}

std::wstring VirtualKeyName(const KeyboardEvent& event) {
    LONG keyNameParameter = static_cast<LONG>((event.scanCode & 0xFFU) << 16U);
    if ((event.flags & LLKHF_EXTENDED) != 0) {
        keyNameParameter |= 1L << 24;
    }

    std::array<wchar_t, 128> name{};
    if (GetKeyNameTextW(keyNameParameter, name.data(), static_cast<int>(name.size())) > 0) {
        return name.data();
    }
    return L"Unknown";
}

std::wstring Hex(DWORD value, int width) {
    std::wostringstream output;
    output << L"0x" << std::uppercase << std::hex << std::setw(width)
           << std::setfill(L'0') << value;
    return output.str();
}

void AppendText(HWND edit, const std::wstring& text) {
    const auto end = GetWindowTextLengthW(edit);
    SendMessageW(edit, EM_SETSEL, end, end);
    SendMessageW(edit, EM_REPLACESEL, FALSE, reinterpret_cast<LPARAM>(text.c_str()));
    SendMessageW(edit, EM_SCROLLCARET, 0, 0);
}

void ResetCounts(AppState& state) {
    state.eisu = {};
    state.kana = {};
}

void UpdateStatus(AppState& state) {
    std::wostringstream status;
    status << L"英数→無変換 (scan 0x7B): down " << state.eisu.down
           << L" / up " << state.eisu.up
           << L" / repeat " << state.eisu.repeats
           << L" / mismatch " << state.eisu.mappingMismatches
           << L" / held " << (state.eisu.pressed ? L"YES" : L"NO")
           << L"    |    かな→変換 (scan 0x79): down " << state.kana.down
           << L" / up " << state.kana.up
           << L" / repeat " << state.kana.repeats
           << L" / mismatch " << state.kana.mappingMismatches
           << L" / held " << (state.kana.pressed ? L"YES" : L"NO");
    SetWindowTextW(state.status, status.str().c_str());
}

void CountTarget(TargetCounts& counts, const KeyboardEvent& event, DWORD expectedVirtualKey) {
    const bool isUp = (event.flags & LLKHF_UP) != 0;
    if (event.virtualKey != expectedVirtualKey) {
        ++counts.mappingMismatches;
    }

    if (isUp) {
        ++counts.up;
        counts.pressed = false;
    } else if (counts.pressed) {
        ++counts.repeats;
    } else {
        ++counts.down;
        counts.pressed = true;
    }
}

void HandleKeyboardEvent(AppState& state, const KeyboardEvent& event) {
    const bool isUp = (event.flags & LLKHF_UP) != 0;
    const bool isExtended = (event.flags & LLKHF_EXTENDED) != 0;
    const bool isInjected = (event.flags & LLKHF_INJECTED) != 0;
    const bool isAltDown = (event.flags & LLKHF_ALTDOWN) != 0;
    const auto name = VirtualKeyName(event);

    if (event.scanCode == kEisuScanCode) {
        CountTarget(state.eisu, event, VK_NONCONVERT);
    } else if (event.scanCode == kKanaScanCode) {
        CountTarget(state.kana, event, VK_CONVERT);
    }

    std::wostringstream display;
    display << event.sequence << L"  " << (isUp ? L"UP  " : L"DOWN")
            << L" scan=" << Hex(event.scanCode, 2)
            << L" vk=" << Hex(event.virtualKey, 2)
            << L" ext=" << (isExtended ? 1 : 0)
            << L" injected=" << (isInjected ? 1 : 0)
            << L" alt=" << (isAltDown ? 1 : 0)
            << L" name=" << name << L"\r\n";
    AppendText(state.log, display.str());

    std::wostringstream jsonRow;
    jsonRow << L"{\"type\":\"event\",\"sequence\":" << event.sequence
            << L",\"monotonic_ns\":" << event.monotonicNanoseconds
            << L",\"action\":\"" << (isUp ? L"up" : L"down")
            << L"\",\"scan_code\":\"" << Hex(event.scanCode, 2)
            << L"\",\"extended\":" << (isExtended ? L"true" : L"false")
            << L",\"vk_code\":\"" << Hex(event.virtualKey, 2)
            << L"\",\"vk_name\":" << JsonEscape(name)
            << L",\"injected\":" << (isInjected ? L"true" : L"false")
            << L",\"alt_down\":" << (isAltDown ? L"true" : L"false")
            << L"}\r\n";
    state.jsonLines += jsonRow.str();
    UpdateStatus(state);
}

void CopyLog(const AppState& state) {
    if (!OpenClipboard(state.window)) {
        return;
    }
    EmptyClipboard();
    const auto bytes = (state.jsonLines.size() + 1) * sizeof(wchar_t);
    const auto memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (memory) {
        if (const auto destination = GlobalLock(memory)) {
            CopyMemory(destination, state.jsonLines.c_str(), bytes);
            GlobalUnlock(memory);
            if (!SetClipboardData(CF_UNICODETEXT, memory)) {
                GlobalFree(memory);
            }
        } else {
            GlobalFree(memory);
        }
    }
    CloseClipboard();
}

bool WriteUtf8File(const wchar_t* path, std::wstring_view value) {
    if (value.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
        return false;
    }
    const int required = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
                                              static_cast<int>(value.size()),
                                              nullptr, 0, nullptr, nullptr);
    if (required <= 0) {
        return false;
    }
    std::string utf8(static_cast<std::size_t>(required), '\0');
    const int converted = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
        utf8.data(), required, nullptr, nullptr);
    if (converted != required) {
        return false;
    }

    const auto file = CreateFileW(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    DWORD written = 0;
    if (utf8.size() > static_cast<std::size_t>(MAXDWORD)) {
        CloseHandle(file);
        return false;
    }
    const auto byteCount = static_cast<DWORD>(utf8.size());
    const bool ok = WriteFile(file, utf8.data(), byteCount,
                              &written, nullptr) != FALSE
                    && written == byteCount;
    CloseHandle(file);
    return ok;
}

void SaveLog(const AppState& state) {
    std::array<wchar_t, MAX_PATH> path{};
    wcscpy_s(path.data(), path.size(), L"KeyEcho.jsonl");
    OPENFILENAMEW dialog{};
    dialog.lStructSize = sizeof(dialog);
    dialog.hwndOwner = state.window;
    dialog.lpstrFilter = L"JSON Lines (*.jsonl)\0*.jsonl\0All files (*.*)\0*.*\0";
    dialog.lpstrFile = path.data();
    dialog.nMaxFile = static_cast<DWORD>(path.size());
    dialog.lpstrDefExt = L"jsonl";
    dialog.Flags = OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST;
    if (GetSaveFileNameW(&dialog)) {
        if (!WriteUtf8File(path.data(), state.jsonLines)) {
            MessageBoxW(state.window, L"JSON Lines ファイルを書き込めませんでした。", L"KeyEcho",
                        MB_OK | MB_ICONERROR);
        }
    }
}

std::wstring JsonMetadata() {
    std::wostringstream header;
    header << L"{\"type\":\"metadata\",\"keyecho_version\":\"0.1.0\""
           << L",\"computer\":" << JsonEscape(ComputerName())
           << L",\"windows\":" << JsonEscape(WindowsVersion())
           << L",\"clock\":\"QueryPerformanceCounter converted to nanoseconds\"}\r\n";
    return header.str();
}

void ClearLog(AppState& state) {
    state.jsonLines = JsonMetadata();
    SetWindowTextW(state.log,
                   L"KeyEcho: リモート画面をフォーカスしたままキーを押してください。\r\n"
                   L"英数は scan=0x7B / vk=0x1D、かなは scan=0x79 / vk=0x1C が期待値です。\r\n\r\n");
    ResetCounts(state);
    UpdateStatus(state);
}

void ResizeChildren(AppState& state, int width, int height) {
    constexpr int margin = 12;
    constexpr int buttonWidth = 92;
    constexpr int buttonHeight = 30;
    constexpr int gap = 8;
    constexpr int statusHeight = 30;
    const int top = margin;
    MoveWindow(GetDlgItem(state.window, kClearButtonId), margin, top,
               buttonWidth, buttonHeight, TRUE);
    MoveWindow(GetDlgItem(state.window, kCopyButtonId), margin + buttonWidth + gap,
               top, buttonWidth, buttonHeight, TRUE);
    MoveWindow(GetDlgItem(state.window, kSaveButtonId),
               margin + (buttonWidth + gap) * 2, top, buttonWidth, buttonHeight, TRUE);
    MoveWindow(GetDlgItem(state.window, kResetButtonId),
               margin + (buttonWidth + gap) * 3, top, buttonWidth, buttonHeight, TRUE);

    const int statusTop = top + buttonHeight + gap;
    MoveWindow(state.status, margin, statusTop, width - margin * 2, statusHeight, TRUE);
    const int logTop = statusTop + statusHeight + gap;
    MoveWindow(state.log, margin, logTop, width - margin * 2,
               height - logTop - margin, TRUE);
}

void StopCaptureAndDiscardPendingEvents(AppState& state) {
    if (state.keyboardHook) {
        UnhookWindowsHookEx(state.keyboardHook);
        state.keyboardHook = nullptr;
    }
    if (gState == &state) {
        gState = nullptr;
    }

    MSG pending{};
    while (PeekMessageW(&pending, state.window, kKeyboardEventMessage,
                        kKeyboardEventMessage, PM_REMOVE)) {
        delete reinterpret_cast<KeyboardEvent*>(pending.lParam);
    }
}

LRESULT CALLBACK LowLevelKeyboardProc(int code, WPARAM message, LPARAM parameter) {
    if (code == HC_ACTION && gState && gState->window
        && (message == WM_KEYDOWN || message == WM_KEYUP
            || message == WM_SYSKEYDOWN || message == WM_SYSKEYUP)) {
        const auto* source = reinterpret_cast<const KBDLLHOOKSTRUCT*>(parameter);
        LARGE_INTEGER now{};
        QueryPerformanceCounter(&now);
        const auto nanoseconds = static_cast<std::uint64_t>(
            (static_cast<long double>(now.QuadPart) * 1'000'000'000.0L)
            / static_cast<long double>(gState->performanceFrequency.QuadPart));

        auto event = std::make_unique<KeyboardEvent>();
        event->sequence = gSequence.fetch_add(1, std::memory_order_relaxed) + 1;
        event->monotonicNanoseconds = nanoseconds;
        event->scanCode = source->scanCode;
        event->virtualKey = source->vkCode;
        event->flags = source->flags;
        if (PostMessageW(gState->window, kKeyboardEventMessage, 0,
                         reinterpret_cast<LPARAM>(event.get()))) {
            event.release();
        }
    }
    return CallNextHookEx(nullptr, code, message, parameter);
}

LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    auto* state = reinterpret_cast<AppState*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    switch (message) {
    case WM_CREATE: {
        state = reinterpret_cast<AppState*>(
            reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
        state->window = window;
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));

        const auto font = reinterpret_cast<HFONT>(GetStockObject(DEFAULT_GUI_FONT));
        const auto makeButton = [&](int id, const wchar_t* title) {
            const auto button = CreateWindowExW(0, L"BUTTON", title,
                WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                window, reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
                nullptr, nullptr);
            SendMessageW(button, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
        };
        makeButton(kClearButtonId, L"ログ消去");
        makeButton(kCopyButtonId, L"JSONL コピー");
        makeButton(kSaveButtonId, L"JSONL 保存");
        makeButton(kResetButtonId, L"集計リセット");

        state->status = CreateWindowExW(0, L"STATIC", L"", WS_CHILD | WS_VISIBLE,
            0, 0, 0, 0, window, nullptr, nullptr, nullptr);
        SendMessageW(state->status, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
        state->log = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
            WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_HSCROLL | ES_MULTILINE
                | ES_AUTOVSCROLL | ES_AUTOHSCROLL | ES_READONLY,
            0, 0, 0, 0, window, nullptr, nullptr, nullptr);
        SendMessageW(state->log, WM_SETFONT,
                     reinterpret_cast<WPARAM>(GetStockObject(ANSI_FIXED_FONT)), TRUE);
        SendMessageW(state->log, EM_SETLIMITTEXT, 16 * 1024 * 1024, 0);
        ClearLog(*state);
        return 0;
    }
    case WM_SIZE:
        if (state) {
            ResizeChildren(*state, LOWORD(lParam), HIWORD(lParam));
        }
        return 0;
    case WM_COMMAND:
        if (state && HIWORD(wParam) == BN_CLICKED) {
            switch (LOWORD(wParam)) {
            case kClearButtonId:
                ClearLog(*state);
                return 0;
            case kCopyButtonId:
                CopyLog(*state);
                return 0;
            case kSaveButtonId:
                SaveLog(*state);
                return 0;
            case kResetButtonId:
                ResetCounts(*state);
                UpdateStatus(*state);
                return 0;
            default:
                break;
            }
        }
        break;
    case kKeyboardEventMessage:
        if (state) {
            std::unique_ptr<KeyboardEvent> event(reinterpret_cast<KeyboardEvent*>(lParam));
            HandleKeyboardEvent(*state, *event);
        }
        return 0;
    case WM_DESTROY:
        if (state) {
            StopCaptureAndDiscardPendingEvents(*state);
        }
        PostQuitMessage(0);
        return 0;
    default:
        break;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int showCommand) {
    AppState state;
    if (!QueryPerformanceFrequency(&state.performanceFrequency)
        || state.performanceFrequency.QuadPart <= 0) {
        return 1;
    }
    gState = &state;

    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.style = CS_HREDRAW | CS_VREDRAW;
    windowClass.lpfnWndProc = WindowProc;
    windowClass.hInstance = instance;
    windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    windowClass.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    windowClass.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
    windowClass.lpszClassName = kWindowClass;
    if (!RegisterClassExW(&windowClass)) {
        gState = nullptr;
        return 1;
    }

    const auto window = CreateWindowExW(0, kWindowClass,
        L"KeyEcho — mRemote Phase 0 scan-code observer",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1120, 720,
        nullptr, nullptr, instance, &state);
    if (!window) {
        gState = nullptr;
        return 1;
    }

    state.keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, LowLevelKeyboardProc,
                                            instance, 0);
    if (!state.keyboardHook) {
        MessageBoxW(window, L"キーボード hook を開始できませんでした。", L"KeyEcho",
                    MB_OK | MB_ICONERROR);
        DestroyWindow(window);
        return 1;
    }

    ShowWindow(window, showCommand);
    UpdateWindow(window);

    MSG message{};
    int exitCode = 0;
    for (;;) {
        const BOOL getMessageResult = GetMessageW(&message, nullptr, 0, 0);
        if (getMessageResult == -1) {
            exitCode = 1;
            if (IsWindow(window)) {
                DestroyWindow(window);
            }
            break;
        }
        if (getMessageResult == 0) {
            exitCode = static_cast<int>(message.wParam);
            break;
        }
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    if (state.keyboardHook) {
        UnhookWindowsHookEx(state.keyboardHook);
        state.keyboardHook = nullptr;
    }
    gState = nullptr;
    return exitCode;
}
