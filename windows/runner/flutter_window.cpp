#include "flutter_window.h"

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Services.Store.h>
#include <winrt/base.h>

namespace {
constexpr char kUpdateChannelName[] = "icarus/update_checker";
constexpr char kCheckWindowsStoreUpdateMethod[] = "checkWindowsStoreUpdate";
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  update_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kUpdateChannelName,
          &flutter::StandardMethodCodec::GetInstance());

  update_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == kCheckWindowsStoreUpdateMethod) {
          result->Success(flutter::EncodableValue(CheckWindowsStoreUpdate()));
          return;
        }

        result->NotImplemented();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  update_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

flutter::EncodableMap FlutterWindow::CheckWindowsStoreUpdate() const {
  flutter::EncodableMap payload;
  payload[flutter::EncodableValue("source")] =
      flutter::EncodableValue("windows_store");
  payload[flutter::EncodableValue("isSupported")] =
      flutter::EncodableValue(false);
  payload[flutter::EncodableValue("isUpdateAvailable")] =
      flutter::EncodableValue(false);

  try {
    // Throws on unpackaged desktop runs where Package identity is unavailable.
    auto package = winrt::Windows::ApplicationModel::Package::Current();
    (void)package;

    const auto context =
        winrt::Windows::Services::Store::StoreContext::GetDefault();
    const auto updates = context.GetAppAndOptionalStorePackageUpdatesAsync().get();

    payload[flutter::EncodableValue("isSupported")] =
        flutter::EncodableValue(true);
    payload[flutter::EncodableValue("isUpdateAvailable")] =
        flutter::EncodableValue(updates.Size() > 0);
    payload[flutter::EncodableValue("updateCount")] =
        flutter::EncodableValue(static_cast<int32_t>(updates.Size()));
  } catch (const winrt::hresult_error& error) {
    payload[flutter::EncodableValue("errorCode")] =
        flutter::EncodableValue(static_cast<int32_t>(error.code().value));
    payload[flutter::EncodableValue("message")] =
        flutter::EncodableValue(winrt::to_string(error.message()));
  } catch (const std::exception& error) {
    payload[flutter::EncodableValue("message")] =
        flutter::EncodableValue(std::string(error.what()));
  } catch (...) {
    payload[flutter::EncodableValue("message")] =
        flutter::EncodableValue("Unknown Windows Store update check failure.");
  }

  return payload;
}
