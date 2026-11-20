#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <wchar.h>
#include <windows.h>
#include "app_links/app_links_plugin_c_api.h"
#include "flutter_window.h"
#include "utils.h"

namespace {
void DebugLog(const std::wstring& message) {
  ::OutputDebugStringW((L"[icarus] " + message + L"\n").c_str());
}

bool WindowTitleContains(HWND hwnd, const std::wstring& needle) {
  const int titleLength = ::GetWindowTextLengthW(hwnd);
  if (titleLength <= 0) {
    return false;
  }

  std::wstring title(titleLength, L'\0');
  ::GetWindowTextW(hwnd, title.data(), titleLength + 1);
  return title.find(needle) != std::wstring::npos;
}

// True when the only argument is an icarus:// link, the way Windows launches
// us for OAuth callbacks and share links.
bool LaunchedWithAppLink() {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  const bool is_app_link =
      argv != nullptr && argc == 2 && ::_wcsnicmp(argv[1], L"icarus:", 7) == 0;
  ::LocalFree(argv);
  return is_app_link;
}
}

bool SendAppLinkToInstance(const std::wstring& title) {
  HWND hwnd = ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", title.c_str());

  // The app title is changed later by Dart code, so fallback to scanning
  // Flutter runner windows and matching the runtime title variant.
  if (!hwnd) {
    HWND next = nullptr;
    while ((next = ::FindWindowEx(nullptr, next, L"FLUTTER_RUNNER_WIN32_WINDOW",
                                  nullptr)) != nullptr) {
      if (WindowTitleContains(next, L"Icarus")) {
        hwnd = next;
        break;
      }
    }
  }

  if (hwnd) {
    DebugLog(L"Existing window found. Forwarding app link to running instance.");

    SendAppLink(hwnd);

    WINDOWPLACEMENT place = { sizeof(WINDOWPLACEMENT) };
    GetWindowPlacement(hwnd, &place);

    switch(place.showCmd) {
      case SW_SHOWMAXIMIZED:
          ShowWindow(hwnd, SW_SHOWMAXIMIZED);
          break;
      case SW_SHOWMINIMIZED:
          ShowWindow(hwnd, SW_RESTORE);
          break;
      default:
          ShowWindow(hwnd, SW_NORMAL);
          break;
    }

    SetWindowPos(hwnd, HWND_TOP, 0, 0, 0, 0,
                 SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
    SetForegroundWindow(hwnd);

    return true;
  }

  DebugLog(L"No existing window found. Continuing cold start.");
  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  DebugLog(L"wWinMain entered.");
  DebugLog(std::wstring(L"Raw command line: ") +
           (command_line ? command_line : L"<null>"));

  // Only an icarus:// link (OAuth callbacks, share links) is handed to a
  // running window here, because app_links forwards nothing else: exiting on
  // any other launch would drop it. Everything else (an .ica path,
  // --hive-store-dir, no arguments) goes on to Dart, whose per-store
  // single-instance check hands file opens to the window using that store.
  if (LaunchedWithAppLink() && SendAppLinkToInstance(L"icarus")) {
    DebugLog(L"App link forwarded to existing instance. Exiting.");
    return EXIT_SUCCESS;
  }
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  for (const auto& arg : command_line_arguments) {
    DebugLog(std::wstring(L"CLI arg: ") + std::wstring(arg.begin(), arg.end()));
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"icarus", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
