import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const String kSecureTransferContactsPrefsKey = 'sd_secure_transfer_contacts_v1';

/// Local secure-transfer contacts (sync to backend can replace this later).
class SecureTransferContact {
  SecureTransferContact({
    required this.id,
    required this.fullName,
    required this.email,
    this.phone = '',
    this.notes = '',
  });

  final String id;
  final String fullName;
  final String email;
  final String phone;
  final String notes;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'full_name': fullName,
        'email': email,
        'phone': phone,
        'notes': notes,
      };

  static SecureTransferContact fromJson(Map<String, dynamic> m) {
    return SecureTransferContact(
      id: m['id']?.toString() ?? '',
      fullName: m['full_name']?.toString() ?? '',
      email: m['email']?.toString() ?? '',
      phone: m['phone']?.toString() ?? '',
      notes: m['notes']?.toString() ?? '',
    );
  }
}

Future<List<SecureTransferContact>> loadSecureTransferContacts() async {
  try {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(kSecureTransferContactsPrefsKey);
    if (raw == null || raw.isEmpty) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => SecureTransferContact.fromJson(
              Map<String, dynamic>.from(e as Map),
            ))
        .where((c) => c.email.trim().isNotEmpty)
        .toList();
  } catch (_) {
    return [];
  }
}

Future<void> saveSecureTransferContacts(List<SecureTransferContact> items) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(
    kSecureTransferContactsPrefsKey,
    jsonEncode(items.map((e) => e.toJson()).toList()),
  );
}

/// Merge cloud list with local: same email → prefer non-empty fields from [local].
List<SecureTransferContact> mergeSecureTransferContacts(
  List<SecureTransferContact> local,
  List<SecureTransferContact> remote,
) {
  final map = <String, SecureTransferContact>{};
  for (final r in remote) {
    final k = r.email.trim().toLowerCase();
    if (k.isEmpty) continue;
    map[k] = r;
  }
  for (final l in local) {
    final k = l.email.trim().toLowerCase();
    if (k.isEmpty) continue;
    final ex = map[k];
    if (ex == null) {
      map[k] = l;
    } else {
      map[k] = SecureTransferContact(
        id: l.id.isNotEmpty ? l.id : ex.id,
        fullName: l.fullName.trim().isNotEmpty ? l.fullName : ex.fullName,
        email: l.email.trim(),
        phone: l.phone.trim().isNotEmpty ? l.phone : ex.phone,
        notes: l.notes.trim().isNotEmpty ? l.notes : ex.notes,
      );
    }
  }
  final out = map.values.toList();
  out.sort((a, b) {
    final c = a.fullName.toLowerCase().compareTo(b.fullName.toLowerCase());
    if (c != 0) return c;
    return a.email.toLowerCase().compareTo(b.email.toLowerCase());
  });
  return out;
}
