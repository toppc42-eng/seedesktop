// =============================================================================
// End-user IT troubleshooting chat (incoming-only home screen only).
// POST → …/api/ai_rmm_it_troubleshooting (via kLicenseServerBaseUrl).
// =============================================================================

import 'dart:convert';

import 'package:flutter_hbb/utils/agent_heartbeat_manager.dart'
    show kVpsAdminBearerKey;
import 'package:flutter_hbb/utils/freemium_guard.dart'
    show canUseRmmItTroubleshootingChatLocal;
import 'package:flutter_hbb/utils/license_manager.dart'
    show getSavedLicenseKey, kLicenseServerBaseUrl;
import 'package:flutter_hbb/utils/license_api_router.dart';

const String kAiItTroubleshootingEndpoint =
    '$kLicenseServerBaseUrl/ai_rmm_it_troubleshooting';

/// System instruction for the end-user IT help assistant (plain language).
const String kItTroubleshootingSystemPreamble = '''
You are a patient IT and computer troubleshooting assistant for SeeDesktop users who receive remote support. Give clear, step-by-step guidance in plain language. Prefer safe, reversible steps. Do not output PowerShell, CMD, or shell scripts unless the user explicitly asks for commands; default to descriptive guidance.''';

String? _lastUserFromTurns(List<ItTroubleshootingChatTurn> turns) {
  for (var i = turns.length - 1; i >= 0; i--) {
    if (turns[i].isUser) return turns[i].text.trim();
  }
  return null;
}

String? _textFromJson(Map<String, dynamic>? j) {
  if (j == null) return null;
  for (final k in <String>[
    'reply',
    'message',
    'text',
    'content',
    'response',
    'answer',
  ]) {
    final v = j[k];
    if (v != null) {
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
  }
  return null;
}

class ItTroubleshootingChatTurn {
  const ItTroubleshootingChatTurn({required this.isUser, required this.text});
  final bool isUser;
  final String text;
}

/// Sends the conversation to the IT troubleshooting endpoint (includes `messages`,
/// `chat_history`, and `license_key` for VPS validation).
Future<String> sendItTroubleshootingChatMessage({
  required String systemPrompt,
  required List<ItTroubleshootingChatTurn> conversationTurns,
}) async {
  if (!await canUseRmmItTroubleshootingChatLocal()) {
    return 'Error: Pro-RMM license or active SD-FREE trial required for IT Support chat.';
  }
  final licenseKey = (await getSavedLicenseKey())?.trim() ?? '';
  if (licenseKey.isEmpty) {
    return 'Error: No license key — IT Support chat requires a Pro-RMM license.';
  }
  if (conversationTurns.isEmpty) {
    return 'Error: empty message';
  }
  final lastUser = _lastUserFromTurns(conversationTurns);
  if (lastUser == null || lastUser.isEmpty) {
    return 'Error: empty message';
  }

  final chatOnly = <Map<String, String>>[];
  for (final t in conversationTurns) {
    final c = t.text.trim();
    if (c.isEmpty) continue;
    chatOnly.add({
      'role': t.isUser ? 'user' : 'assistant',
      'content': c,
    });
  }
  if (chatOnly.isEmpty) {
    return 'Error: empty message';
  }

  final system = systemPrompt.trim();
  final messages = <Map<String, dynamic>>[
    if (system.isNotEmpty) {'role': 'system', 'content': system},
    ...chatOnly.map((m) => Map<String, dynamic>.from(m)),
  ];

  final headers = <String, String>{
    'Authorization': 'Bearer $kVpsAdminBearerKey',
    'Content-Type': 'application/json; charset=utf-8',
  };
  final body = jsonEncode(<String, dynamic>{
    'license_key': licenseKey,
    'message': lastUser,
    'prompt': lastUser,
    'system_prompt': system,
    'module': 'rmm_it_troubleshooting',
    'messages': messages,
    'chat_history': chatOnly,
  });

  try {
    final resp = await LicenseApiRouter.post(
      Uri.parse(kAiItTroubleshootingEndpoint),
      headers: headers,
      body: body,
      requestTimeout: const Duration(seconds: 120),
    );
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(resp.body) as Map<String, dynamic>?;
    } catch (_) {
      j = null;
    }
    if (resp.statusCode == 403) {
      final detail =
          j?['error']?.toString() ?? j?['message']?.toString() ?? '';
      if (detail.isNotEmpty) {
        return 'Error: $detail';
      }
      return 'Error: Access denied (403). Your license may not include IT Support '
          'chat, or the key is invalid. Pro-RMM is required.';
    }
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      final err = j?['error']?.toString() ?? j?['message']?.toString() ?? '';
      return 'Error: ${err.isNotEmpty ? err : 'HTTP ${resp.statusCode}'}';
    }
    final t = _textFromJson(j);
    if (t != null && t.isNotEmpty) return t;
    return 'Error: empty response';
  } catch (e) {
    return 'Error: $e';
  }
}
