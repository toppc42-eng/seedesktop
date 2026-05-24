import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/pages/terminal_appearance_prefs.dart';
import 'package:xterm/xterm.dart';

/// Preset pairs: (background, foreground).
const _kTerminalPresets = <String, (Color, Color)>{
  'שחור / לבן': (Color(0xFF000000), Color(0xFFFFFFFF)),
  'אפור כהה (xterm)': (Color(0xFF1E1E1E), Color(0xFFCCCCCC)),
  'מטריקס': (Color(0xFF0D0208), Color(0xFF00FF41)),
  'Solarized Dark': (Color(0xFF002B36), Color(0xFF839496)),
};

Future<void> showTerminalAppearanceDialog(
  BuildContext context, {
  required Color initialBackground,
  required Color initialForeground,
  required void Function(TerminalTheme theme, Color bg, Color fg) onApply,
}) async {
  Color bg = initialBackground;
  Color fg = initialForeground;

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (context, setLocal) {
          return AlertDialog(
            title: const Text('מראה טרמינל'),
            content: SizedBox(
              width: 320,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('ערכות מוכנות',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _kTerminalPresets.entries.map((e) {
                        return ActionChip(
                          label: Text(e.key, style: const TextStyle(fontSize: 12)),
                          onPressed: () {
                            setLocal(() {
                              bg = e.value.$1;
                              fg = e.value.$2;
                            });
                          },
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('צבע רקע'),
                      trailing: Container(
                        width: 40,
                        height: 28,
                        decoration: BoxDecoration(
                          color: bg,
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onTap: () async {
                        final picked = await showColorPickerDialog(
                          ctx,
                          bg,
                          pickersEnabled: const {
                            ColorPickerType.accent: false,
                            ColorPickerType.wheel: true,
                          },
                          actionButtons: const ColorPickerActionButtons(
                            dialogOkButtonLabel: 'אישור',
                            dialogCancelButtonLabel: 'ביטול',
                          ),
                          showColorCode: true,
                        );
                        setLocal(() => bg = picked);
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('צבע טקסט'),
                      trailing: Container(
                        width: 40,
                        height: 28,
                        decoration: BoxDecoration(
                          color: fg,
                          border: Border.all(color: Colors.grey),
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      onTap: () async {
                        final picked = await showColorPickerDialog(
                          ctx,
                          fg,
                          pickersEnabled: const {
                            ColorPickerType.accent: false,
                            ColorPickerType.wheel: true,
                          },
                          actionButtons: const ColorPickerActionButtons(
                            dialogOkButtonLabel: 'אישור',
                            dialogCancelButtonLabel: 'ביטול',
                          ),
                          showColorCode: true,
                        );
                        setLocal(() => fg = picked);
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('ביטול'),
              ),
              FilledButton(
                onPressed: () async {
                  await saveTerminalWindowTheme(bg, fg);
                  final theme = terminalThemeFromBaseColors(bg, fg);
                  onApply(theme, bg, fg);
                  if (ctx.mounted) Navigator.of(ctx).pop();
                },
                child: const Text('החל'),
              ),
            ],
          );
        },
      );
    },
  );
}
