import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/utils/cloud_sync_service.dart';
import 'package:flutter_hbb/utils/crm_service.dart';
import 'package:flutter_hbb/utils/freemium_guard.dart';

String crmFormatDateTime(DateTime? value) {
  if (value == null) return '-';
  final v = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(v.day)}/${two(v.month)}/${v.year} ${two(v.hour)}:${two(v.minute)}';
}

String crmFormatDuration(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final minutes = s ~/ 60;
  final rest = s % 60;
  if (minutes <= 0) return '${rest}s';
  return '${minutes}m ${rest}s';
}

class _CrmNoteTriple {
  const _CrmNoteTriple({
    required this.complaint,
    required this.actionTaken,
    required this.furtherNotes,
  });

  final String complaint;
  final String actionTaken;
  final String furtherNotes;

  bool get isAllEmpty =>
      complaint.trim().isEmpty &&
      actionTaken.trim().isEmpty &&
      furtherNotes.trim().isEmpty;
}

Widget _crmNoteTripleFields({
  required TextEditingController complaintController,
  required TextEditingController actionTakenController,
  required TextEditingController furtherNotesController,
  required bool enabled,
}) {
  const fieldStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
  InputDecoration deco(String hint) => InputDecoration(
        border: const OutlineInputBorder(),
        hintText: hint,
      );
  Widget block(String label, TextEditingController c, String hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: fieldStyle),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          enabled: enabled,
          minLines: 2,
          maxLines: 6,
          decoration: deco(hint),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      block('🔴 תלונה:', complaintController, 'תלונה / תיאור הבעיה'),
      block('🟢 מה עשיתי:', actionTakenController, 'פעולות שבוצעו'),
      block('📝 המשך טיפול / הערות:', furtherNotesController,
          'המשך טיפול או הערות נוספות'),
    ],
  );
}

/// Post-session note UI after the remote connection is already closed.
Future<void> showCrmDisconnectedNoteFlowPostClose({
  required BuildContext context,
  required String peerId,
  required DateTime endTime,
  FutureOr<void> Function()? onCloseSession,
  bool useRootNavigator = false,
}) async {
  if (!await hasProLicenseLocal()) {
    if (onCloseSession != null) {
      await onCloseSession();
    }
    return;
  }
  if (!context.mounted) {
    if (onCloseSession != null) {
      await onCloseSession();
    }
    return;
  }
  final email = CloudSyncService.savedEmail.trim();
  if (email.isEmpty) {
    if (onCloseSession != null) {
      await onCloseSession();
    }
    return;
  }
  if (!context.mounted) {
    if (onCloseSession != null) {
      await onCloseSession();
    }
    return;
  }
  await showCrmNoteDialog(
    context: context,
    peerId: peerId,
    endTime: endTime,
    onCloseSession: onCloseSession,
    useRootNavigator: useRootNavigator,
  );
}

Future<void> showCrmNoteDialog({
  required BuildContext context,
  required String peerId,
  required DateTime endTime,
  FutureOr<void> Function()? onCloseSession,
  bool useRootNavigator = false,
}) async {
  final complaintController = TextEditingController();
  final actionTakenController = TextEditingController();
  final furtherNotesController = TextEditingController();
  var saving = false;
  var closing = false;
  Future<void> dismissDialog(BuildContext dialogContext) async {
    if (closing) return;
    closing = true;
    Navigator.of(dialogContext, rootNavigator: useRootNavigator).pop();
    if (onCloseSession != null) {
      await onCloseSession();
    }
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: useRootNavigator,
    builder: (dialogContext) => StatefulBuilder(
      builder: (ctx, setState) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop || saving) return;
          await dismissDialog(dialogContext);
        },
        child: AlertDialog(
          title: const Text('תיעוד סיום טיפול'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('שעת סיום: ${crmFormatDateTime(endTime)}'),
                  const SizedBox(height: 12),
                  _crmNoteTripleFields(
                    complaintController: complaintController,
                    actionTakenController: actionTakenController,
                    furtherNotesController: furtherNotesController,
                    enabled: !saving,
                  ),
                  if (saving) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed:
                  saving ? null : () async => dismissDialog(dialogContext),
              child: const Text('צא ללא תיעוד'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      final triple = _CrmNoteTriple(
                        complaint: complaintController.text,
                        actionTaken: actionTakenController.text,
                        furtherNotes: furtherNotesController.text,
                      );
                      if (triple.isAllEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('יש למלא לפחות אחד מהשדות'),
                          ),
                        );
                        return;
                      }
                      setState(() => saving = true);
                      try {
                        await CrmService.addNote(
                          peerId: peerId,
                          complaint: triple.complaint,
                          actionTaken: triple.actionTaken,
                          furtherNotes: triple.furtherNotes,
                        );
                        if (dialogContext.mounted) {
                          dismissDialog(dialogContext);
                        }
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(e.toString()),
                              backgroundColor: Colors.red.shade700,
                            ),
                          );
                        }
                      } finally {
                        if (dialogContext.mounted && !closing) {
                          setState(() => saving = false);
                        }
                      }
                    },
              child: const Text('שמור'),
            ),
          ],
        ),
      ),
    ),
  );
  complaintController.dispose();
  actionTakenController.dispose();
  furtherNotesController.dispose();
}

Future<void> showCrmPeerHistoryDialog({
  required BuildContext context,
  required String peerId,
}) async {
  await showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (ctx) => _CrmPeerHistoryDialog(peerId: peerId),
  );
}

class _CrmPeerHistoryDialog extends StatefulWidget {
  final String peerId;

  const _CrmPeerHistoryDialog({required this.peerId});

  @override
  State<_CrmPeerHistoryDialog> createState() => _CrmPeerHistoryDialogState();
}

class _CrmPeerHistoryDialogState extends State<_CrmPeerHistoryDialog> {
  late Future<List<CrmNote>> _notesFuture;
  int? _busyNoteId;

  @override
  void initState() {
    super.initState();
    _notesFuture = CrmService.getNotes(peerId: widget.peerId);
  }

  void _reload() {
    setState(() {
      _notesFuture = CrmService.getNotes(peerId: widget.peerId);
    });
  }

  Future<void> _addManualNote() async {
    final triple = await _showThreeFieldNoteDialog(title: 'תיעוד חדש');
    if (triple == null || triple.isAllEmpty) return;
    setState(() => _busyNoteId = 0);
    try {
      await CrmService.addNote(
        peerId: widget.peerId,
        complaint: triple.complaint,
        actionTaken: triple.actionTaken,
        furtherNotes: triple.furtherNotes,
        isManual: true,
      );
      _reload();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busyNoteId = null);
    }
  }

  Future<_CrmNoteTriple?> _showThreeFieldNoteDialog({
    required String title,
    String initialComplaint = '',
    String initialActionTaken = '',
    String initialFurtherNotes = '',
  }) async {
    final complaintController = TextEditingController(text: initialComplaint);
    final actionTakenController =
        TextEditingController(text: initialActionTaken);
    final furtherNotesController =
        TextEditingController(text: initialFurtherNotes);
    try {
      return await showDialog<_CrmNoteTriple>(
        context: context,
        useRootNavigator: true,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: _crmNoteTripleFields(
                complaintController: complaintController,
                actionTakenController: actionTakenController,
                furtherNotesController: furtherNotesController,
                enabled: true,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(),
              child: const Text('ביטול'),
            ),
            FilledButton(
              onPressed: () {
                final triple = _CrmNoteTriple(
                  complaint: complaintController.text,
                  actionTaken: actionTakenController.text,
                  furtherNotes: furtherNotesController.text,
                );
                if (triple.isAllEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('יש למלא לפחות אחד מהשדות'),
                    ),
                  );
                  return;
                }
                Navigator.of(ctx, rootNavigator: true).pop(triple);
              },
              child: const Text('שמור'),
            ),
          ],
        ),
      );
    } finally {
      complaintController.dispose();
      actionTakenController.dispose();
      furtherNotesController.dispose();
    }
  }

  void _showError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error.toString()), backgroundColor: Colors.red),
    );
  }

  Future<void> _editNote(CrmNote note) async {
    if (note.id <= 0) return;
    final triple = await _showThreeFieldNoteDialog(
      title: 'עריכת תיעוד',
      initialComplaint: note.complaint,
      initialActionTaken: note.actionTaken,
      initialFurtherNotes: note.furtherNotes,
    );
    if (triple == null || triple.isAllEmpty) return;
    if (triple.complaint.trim() == note.complaint.trim() &&
        triple.actionTaken.trim() == note.actionTaken.trim() &&
        triple.furtherNotes.trim() == note.furtherNotes.trim()) {
      return;
    }
    setState(() => _busyNoteId = note.id);
    try {
      await CrmService.editNote(
        noteId: note.id,
        complaint: triple.complaint,
        actionTaken: triple.actionTaken,
        furtherNotes: triple.furtherNotes,
      );
      _reload();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busyNoteId = null);
    }
  }

  Future<void> _deleteNote(CrmNote note) async {
    if (note.id <= 0) return;
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (ctx) => AlertDialog(
        title: const Text('מחיקת תיעוד'),
        content: const Text('למחוק את התיעוד הזה?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(false),
            child: const Text('ביטול'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx, rootNavigator: true).pop(true),
            child: const Text('מחק'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busyNoteId = note.id);
    try {
      await CrmService.deleteNote(noteId: note.id);
      _reload();
    } catch (e) {
      _showError(e);
    } finally {
      if (mounted) setState(() => _busyNoteId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 36, vertical: 30),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        width: 760,
        height: 560,
        decoration: BoxDecoration(
          color: const Color(0xFFF1F2F4),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFCDD1D6), width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'היסטוריית טיפולים',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _busyNoteId == null ? _addManualNote : null,
                    icon: const Icon(Icons.add),
                    label: const Text('חדש'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 18),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFE6E8EB),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFD1D5DA)),
                ),
                child: FutureBuilder<List<CrmNote>>(
                  future: _notesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(child: Text(snapshot.error.toString()));
                    }
                    final notes = snapshot.data ?? const <CrmNote>[];
                    if (notes.isEmpty) {
                      return const Center(child: Text('אין פתקים להצגה'));
                    }
                    return ListView.separated(
                      itemCount: notes.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final note = notes[index];
                        final hasAny = note.complaint.trim().isNotEmpty ||
                            note.actionTaken.trim().isNotEmpty ||
                            note.furtherNotes.trim().isNotEmpty;
                        final canModify = note.id > 0;
                        final busy = _busyNoteId == note.id;
                        final cardColor = note.isManual
                            ? Colors.amber.shade100
                            : Colors.teal.shade200;
                        final borderColor = note.isManual
                            ? Colors.amber.shade300
                            : Colors.teal.shade400;
                        return Align(
                          alignment: Alignment.centerRight,
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: cardColor,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: borderColor),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          if (!hasAny)
                                            const Text(
                                              '—',
                                              style: TextStyle(
                                                color: Colors.black87,
                                                fontSize: 15,
                                              ),
                                            )
                                          else ...[
                                            if (note.complaint
                                                .trim()
                                                .isNotEmpty) ...[
                                              const Text(
                                                '🔴 תלונה:',
                                                style: TextStyle(
                                                  color: Colors.black87,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                note.complaint,
                                                style: const TextStyle(
                                                  color: Colors.black87,
                                                  fontSize: 15,
                                                ),
                                              ),
                                              const SizedBox(height: 10),
                                            ],
                                            if (note.actionTaken
                                                .trim()
                                                .isNotEmpty) ...[
                                              const Text(
                                                '🟢 מה עשיתי:',
                                                style: TextStyle(
                                                  color: Colors.black87,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                note.actionTaken,
                                                style: const TextStyle(
                                                  color: Colors.black87,
                                                  fontSize: 15,
                                                ),
                                              ),
                                              const SizedBox(height: 10),
                                            ],
                                            if (note.furtherNotes
                                                .trim()
                                                .isNotEmpty) ...[
                                              const Text(
                                                '📝 המשך טיפול / הערות:',
                                                style: TextStyle(
                                                  color: Colors.black87,
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                note.furtherNotes,
                                                style: const TextStyle(
                                                  color: Colors.black87,
                                                  fontSize: 15,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ],
                                      ),
                                    ),
                                    if (busy)
                                      const SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    else ...[
                                      IconButton(
                                        tooltip: 'ערוך',
                                        onPressed: canModify
                                            ? () => _editNote(note)
                                            : null,
                                        icon: const Icon(Icons.edit_outlined),
                                      ),
                                      IconButton(
                                        tooltip: 'מחק',
                                        onPressed: canModify
                                            ? () => _deleteNote(note)
                                            : null,
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '${crmFormatDateTime(note.createdAt)} · ${note.userEmail}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: Colors.black87),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 14, bottom: 10, top: 6),
                child: TextButton(
                  onPressed: () =>
                      Navigator.of(context, rootNavigator: true).pop(),
                  child: const Text('סגור'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
