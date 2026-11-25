import 'dart:js_interop';
import 'dart:js_interop_unsafe';

void holdPageLoaderForSplash() {
  globalContext['icarusSplashPending'] = true.toJS;
}

void releasePageLoader() {
  if (globalContext.has('icarusSplashReady')) {
    globalContext.callMethod('icarusSplashReady'.toJS);
  }
}
