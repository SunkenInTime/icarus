import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:icarus/share/share_link_format.dart';

/// The origin share links made on this device point at, and the one incoming
/// links may use besides production.
///
/// On web this is the page's own origin, so the beta hands out beta links
/// (`https://beta.icarusstrats.com/share/…`) that open in the beta. Native
/// builds always use production.
Uri currentShareOrigin() {
  return kIsWeb ? Uri.parse(Uri.base.origin) : icarusProductionShareOrigin;
}
