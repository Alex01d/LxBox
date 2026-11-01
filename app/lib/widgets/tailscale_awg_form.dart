import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/file_export.dart';
import '../services/file_import.dart';
import '../services/l10n/locale_controller.dart';
import '../services/tailscale_awg_profile.dart';
import 'lx_code_editor.dart';

/// One editor for Add and Source. It changes only body.awg; saving the existing
/// source retains the local record/state identity. No live VPN is required.
class TailscaleAwgForm extends StatefulWidget {
  const TailscaleAwgForm({
    super.key,
    required this.body,
    required this.onChanged,
    this.onDraftChanged,
    this.enabled = true,
  });

  final Map<String, dynamic> body;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final VoidCallback? onDraftChanged;
  final bool enabled;

  @override
  State<TailscaleAwgForm> createState() => TailscaleAwgFormState();
}

class TailscaleAwgFormState extends State<TailscaleAwgForm> {
  static const _eq = DeepCollectionEquality();
  static const _json = JsonEncoder.withIndent('  ');
  final _label = TextEditingController();
  final _parameters = TextEditingController();
  final _editor = GlobalKey<LxCodeEditorState>();
  final _schema = loadTailscaleAwgSchema();
  Map<String, dynamic>? _loadedSchema;
  Object? _lastProfile;
  Map<String, dynamic> _profileBase = {};
  bool _profileEdited = false;
  Map<String, dynamic>? _emitted;
  int _mode = 0;
  bool _syncing = false;
  bool _tried = false;
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _load(widget.body['awg']);
    _label.addListener(_changed);
    _parameters.addListener(_changed);
    unawaited(
      _schema
          .then((value) {
            if (!mounted) return;
            _loadedSchema = value;
          })
          .catchError((Object _) {
            // A failed schema load keeps AWG editing fail-closed. validate() presents
            // the safe message without leaking profile contents to a log.
          }),
    );
  }

  @override
  void didUpdateWidget(covariant TailscaleAwgForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_eq.equals(widget.body, _emitted) ||
        _eq.equals(widget.body['awg'], _lastProfile)) {
      return;
    }
    _load(widget.body['awg']);
  }

  void _load(Object? value) {
    _syncing = true;
    _lastProfile = value == null ? null : jsonDecode(jsonEncode(value));
    _profileBase = value is Map<String, dynamic>
        ? jsonDecode(jsonEncode(value)) as Map<String, dynamic>
        : {};
    _profileEdited = false;
    if (value == null) {
      _mode = 0;
      _label.text = '';
      _parameters.text = '{}';
    } else {
      final profile = value is Map ? value : const {};
      final version = profile['version'];
      _mode = version == 2 || version == 3 ? version as int : -1;
      _label.text = profile['profile_id'] is String
          ? profile['profile_id'] as String
          : '';
      _parameters.text = _json.convert(profile['parameters']);
    }
    _tried = false;
    _invalid = false;
    _syncing = false;
  }

  Map<String, dynamic>? _profile(Map<String, dynamic> schema) {
    if (_mode == 0) return null;
    if (!_profileEdited && _lastProfile != null) {
      return parseTailscaleAwgProfile(jsonEncode(_lastProfile), schema);
    }
    if (_parameters.text.length > tailscaleAwgProfileMaxBytes) {
      throw const FormatException('AWG profile is too large');
    }
    final Object? parameters;
    try {
      parameters = jsonDecode(_parameters.text);
    } on FormatException {
      throw const FormatException('Invalid AWG profile JSON');
    }
    final draft = <String, dynamic>{
      ..._profileBase,
      'version': _mode,
      'parameters': parameters,
    };
    if (_label.text.trim().isEmpty) {
      draft.remove('profile_id');
    } else {
      draft['profile_id'] = _label.text.trim();
    }
    return parseTailscaleAwgProfile(jsonEncode(draft), schema);
  }

  void _emit(Map<String, dynamic>? profile) {
    final next = withTailscaleAwgProfile(widget.body, profile);
    _emitted = next;
    _lastProfile = next['awg'];
    widget.onChanged(next);
  }

  void _changed() {
    if (_syncing || !widget.enabled) return;
    _profileEdited = true;
    widget.onDraftChanged?.call();
    try {
      if (_mode == 0) {
        _emit(null);
      } else if (_loadedSchema != null) {
        _emit(_profile(_loadedSchema!));
      } else {
        return;
      }
      if (_invalid) setState(() => _invalid = false);
    } on FormatException {
      if (_tried) setState(() => _invalid = true);
    }
  }

  /// Called by the owner's Save/Add before persisting. Invalid drafts cannot
  /// quietly save the last valid profile or downgrade to ordinary WireGuard.
  Future<bool> validate() async {
    if (!widget.enabled) return true;
    await _editor.currentState?.flush();
    try {
      final schema = _mode == 0 ? const <String, dynamic>{} : await _schema;
      if (!mounted) return false;
      _loadedSchema = schema.isEmpty ? _loadedSchema : schema;
      final value = _profile(schema);
      _emit(value);
      setState(() {
        _tried = true;
        _invalid = false;
      });
      return true;
    } catch (_) {
      if (mounted) {
        setState(() {
          _tried = true;
          _invalid = true;
        });
      }
      return false;
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _importText(String text) async {
    try {
      final schema = await _schema;
      final profile = parseTailscaleAwgProfile(text, schema);
      if (!mounted) return;
      _loadedSchema = schema;
      setState(() => _load(profile));
      _changed();
    } catch (_) {
      _message(
        getLocalText.s(
          "Invalid AWG profile. Check its version, label and typed parameters.",
        ),
      );
    }
  }

  Future<void> _importFile() async {
    final outcome = await pickFileSafely(allowedExtensions: const ['json']);
    if (!mounted) return;
    if (outcome is PickedFiles) {
      await _importText(outcome.single.text);
    } else {
      final problem = pickProblemText(outcome);
      if (problem != null) _message(problem);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    await _importText(data?.text ?? '');
  }

  Future<void> _export({bool copy = false}) async {
    if (_mode == 0) {
      _message(
        getLocalText.s("Select an AWG mode before exporting a profile."),
      );
      return;
    }
    if (!await validate() || !mounted) return;
    final text = '${_json.convert(_profile(_loadedSchema!))}\n';
    if (copy) {
      await Clipboard.setData(ClipboardData(text: text));
      _message(getLocalText.s("Copied"));
      return;
    }
    final outcome = await saveFileSafely(
      fileName: 'awg-profile.json',
      content: text,
    );
    final problem = saveProblemText(outcome);
    if (problem != null) {
      _message(problem);
    } else if (outcome is SavedToFile || outcome is SavedToDownloads) {
      _message(getLocalText.s("Profile exported"));
    }
  }

  @override
  void dispose() {
    _label.dispose();
    _parameters.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<int>(
          key: ValueKey('tailscale-awg-mode-$_mode'),
          initialValue: _mode,
          decoration: InputDecoration(
            labelText: getLocalText.s("Tailscale peer transport"),
          ),
          items: [
            DropdownMenuItem(
              value: 0,
              child: Text(getLocalText.s("Ordinary Tailscale (WireGuard)")),
            ),
            // l10n-exempt: protocol version names
            const DropdownMenuItem(value: 2, child: Text('AWG2')),
            // l10n-exempt: protocol version names
            const DropdownMenuItem(value: 3, child: Text('AWG3')),
            if (_mode == -1)
              DropdownMenuItem(
                value: -1,
                child: Text(getLocalText.s("Unsupported profile")),
              ),
          ],
          onChanged: !widget.enabled
              ? null
              : (value) {
                  if (value == null) return;
                  setState(() => _mode = value);
                  _changed();
                },
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: widget.enabled ? _importFile : null,
              icon: const Icon(Icons.file_open_outlined),
              label: Text(getLocalText.s("Import profile")),
            ),
            TextButton.icon(
              onPressed: widget.enabled ? _paste : null,
              icon: const Icon(Icons.content_paste),
              label: Text(getLocalText.s("Paste profile")),
            ),
            TextButton.icon(
              onPressed: widget.enabled ? () => _export() : null,
              icon: const Icon(Icons.save_alt),
              label: Text(getLocalText.s("Export profile")),
            ),
            TextButton.icon(
              onPressed: widget.enabled ? () => _export(copy: true) : null,
              icon: const Icon(Icons.copy),
              label: Text(getLocalText.s("Copy profile")),
            ),
          ],
        ),
        if (_mode != 0) ...[
          TextField(
            controller: _label,
            enabled: widget.enabled,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: getLocalText.s("Profile label (optional)"),
            ),
          ),
          const SizedBox(height: 8),
          Text(getLocalText.s("AWG parameters (JSON)"), style: hint),
          SizedBox(
            height: 240,
            child: LxCodeEditor(
              key: _editor,
              controller: _parameters,
              readOnly: !widget.enabled,
              language: LxCodeLanguage.json,
              showLineNumbers: true,
              format: true,
            ),
          ),
          Text(
            getLocalText.s(
              "Both peers must use a compatible profile. Export may contain a shared key; it never includes this device's identity.",
            ),
            style: hint,
          ),
        ],
        if (_invalid)
          Text(
            getLocalText.s(
              "Invalid AWG profile. Check its version, label and typed parameters.",
            ),
            style: hint?.copyWith(color: Theme.of(context).colorScheme.error),
          ),
      ],
    );
  }
}
