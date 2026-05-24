import 'package:flutter_hbb/models/platform_model.dart';

Future<String> getUnifiedAppVersion() async {
  final version = await bind.mainGetVersion();
  return version.trim();
}
