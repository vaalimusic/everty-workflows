// EvertyDesk Smart Agent — injected at build time.
// Provides heartbeat, push notifications, and support requests.
// Compatible with RustDesk 1.3.5+

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class AgentService {
  AgentService._();
  static final AgentService instance = AgentService._();

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  String? _apiServer;
  String? _serviceKey;
  String? _machineId;
  String? _rustdeskId; // RustDesk numeric ID, read lazily from config
  Timer? _heartbeatTimer;
  Timer? _inboxTimer;

  // Tunables — exposed at top for easy adjustment.
  // Lower values = more responsive support flow but more server load.
  static const Duration kHeartbeatInterval = Duration(minutes: 1);
  static const Duration kInboxInterval = Duration(seconds: 30);
  static const Duration kInitialHeartbeatDelay = Duration(seconds: 3);
  static const Duration kInitialInboxDelay = Duration(seconds: 8);
  static const Duration kHttpTimeout = Duration(seconds: 12);

  /// Tracks consecutive failures for backoff. Reset on success.
  int _heartbeatFailures = 0;
  int _inboxFailures = 0;
  bool _isGenericClient = false;

  // Called from main() after app boots.
  Future<void> initialize({required String apiServer, String serviceKey = '', bool isGenericClient = false}) async {
    if (apiServer.isEmpty) return;
    _apiServer = apiServer.endsWith('/') ? apiServer.substring(0, apiServer.length - 1) : apiServer;
    _serviceKey = serviceKey;
    _isGenericClient = isGenericClient;
    _machineId = await _getOrCreateMachineId();
    // Lazily read the RustDesk numeric ID from the config file.
    // The ID may not be assigned by the relay server yet at startup, so we
    // retry a few times with a delay. Once known, it is included in every
    // subsequent heartbeat so the server can resolve support-request targets.
    _tryLoadRustdeskId();

    Future.delayed(kInitialHeartbeatDelay, _sendHeartbeat);
    _heartbeatTimer = Timer.periodic(kHeartbeatInterval, (_) => _sendHeartbeat());

    Future.delayed(kInitialInboxDelay, _checkInbox);
    _inboxTimer = Timer.periodic(kInboxInterval, (_) => _checkInbox());
  }

  Future<String> _getOrCreateMachineId() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}agent_id');
      if (await file.exists()) {
        final id = (await file.readAsString()).trim();
        if (id.isNotEmpty) return id;
      }
      final id = _randomId();
      await file.writeAsString(id);
      return id;
    } catch (_) {
      return _randomId();
    }
  }

  String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// Attempts to read the RustDesk numeric ID from the app config file.
  /// RustDesk stores `id = "123456789"` in a TOML file in the config directory
  /// (a sibling to the Flutter app-support directory).
  /// We search a few candidate paths to stay robust across platforms and
  /// custom build names.
  Future<String> _readRustdeskIdFromConfig() async {
    try {
      final dir = await getApplicationSupportDirectory();
      // Candidate directories (platform-dependent):
      //   Windows: %APPDATA%\{AppName}\  and  %APPDATA%\{AppName}\config
      //   macOS:   ~/Library/Application Support/{AppName}/
      //   Linux:   ~/.local/share/{AppName}/
      final candidates = [
        Directory(dir.path),
        Directory('${dir.path}${Platform.pathSeparator}config'),
        Directory('${dir.parent.path}${Platform.pathSeparator}config'),
        dir.parent,
      ];
      for (final d in candidates) {
        if (!await d.exists()) continue;
        await for (final entity in d.list()) {
          if (entity is File && entity.path.endsWith('.toml')) {
            final content = await entity.readAsString();
            final match = RegExp(r'^id\s*=\s*"([^"]+)"', multiLine: true).firstMatch(content);
            if (match != null) {
              final id = match.group(1) ?? '';
              if (id.isNotEmpty) return id;
            }
          }
        }
      }
    } catch (_) {}
    return '';
  }

  /// Tries to load the RustDesk ID with retries (max 4 attempts, 15s apart).
  /// Called once at startup; stops as soon as the ID is found.
  void _tryLoadRustdeskId({int attempt = 0}) {
    if (_rustdeskId != null && _rustdeskId!.isNotEmpty) return;
    Future.delayed(Duration(seconds: 15 + attempt * 15), () async {
      try {
        final id = await _readRustdeskIdFromConfig();
        if (id.isNotEmpty) {
          _rustdeskId = id;
          return; // success — stop retrying
        }
      } catch (_) {}
      if (attempt < 3) _tryLoadRustdeskId(attempt: attempt + 1);
    });
  }

  Future<void> _sendHeartbeat() async {
    if (_apiServer == null || _machineId == null) return;
    try {
      final resp = await http.post(
        Uri.parse('$_apiServer/admin/agent/heartbeat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'machine_id': _machineId,
          'service_key': _serviceKey ?? '',
          'hostname': Platform.localHostname,
          'os': Platform.operatingSystem,
          'os_version': Platform.operatingSystemVersion,
          'rustdesk_id': _rustdeskId ?? '', // numeric ID assigned by relay server
        }),
      ).timeout(kHttpTimeout);
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        _heartbeatFailures = 0;
      } else {
        _heartbeatFailures++;
      }
    } catch (_) {
      _heartbeatFailures++;
      // Retry-with-backoff: schedule a single faster retry after small delay
      // if this was a transient network blip (max 3 quick retries).
      if (_heartbeatFailures <= 3) {
        Future.delayed(Duration(seconds: 5 * _heartbeatFailures), _sendHeartbeat);
      }
    }
  }

  Future<void> _checkInbox() async {
    if (_apiServer == null || _machineId == null) return;
    try {
      final uri = Uri.parse('$_apiServer/admin/agent/inbox').replace(queryParameters: {
        'machine_id': _machineId!,
        'service_key': _serviceKey ?? '',
      });
      final resp = await http.get(uri).timeout(kHttpTimeout);
      if (resp.statusCode != 200) {
        _inboxFailures++;
        return;
      }
      _inboxFailures = 0;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>?) ?? [];
      for (final item in items) {
        if (item['type'] == 'config_update') {
          _withContext((ctx) async {
            await _ackNotification(item['id'].toString());
            _applyConfigUpdate(item as Map<String, dynamic>);
          });
        } else if (item['type'] == 'support_ping') {
          // Peer-to-peer support request — operator sees this on their own client.
          // Don't auto-ack here; ack happens after operator picks a response action.
          _withContext((ctx) {
            showSupportPingDialog(ctx, item as Map<String, dynamic>);
          });
        } else {
          _withContext((ctx) async {
            await _ackNotification(item['id'].toString());
            _showItemWithCtx(ctx, item as Map<String, dynamic>);
          });
        }
      }
    } catch (_) {
      _inboxFailures++;
    }
  }

  Future<void> _ackNotification(String id) async {
    try {
      await http.post(
        Uri.parse('$_apiServer/admin/agent/notification/$id/ack?machine_id=$_machineId'),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> _applyConfigUpdate(Map<String, dynamic> item) async {
    try {
      final body = jsonDecode(item['body'] as String? ?? '{}') as Map<String, dynamic>;
      final server = (body['server'] as String?) ?? '';
      final key = (body['key'] as String?) ?? '';
      final apiServer = (body['api_server'] as String?) ?? '';
      _showConfigUpdateDialog(server: server, key: key, apiServer: apiServer);
    } catch (_) {}
  }

  void _showConfigUpdateDialog({required String server, required String key, required String apiServer}) {
    _withContext((ctx) => _showConfigUpdateDialogWithCtx(ctx, server: server, key: key, apiServer: apiServer));
  }

  void _showConfigUpdateDialogWithCtx(BuildContext ctx, {required String server, required String key, required String apiServer}) {
    final lines = <Widget>[];
    if (server.isNotEmpty) lines.add(_configRow('ID/Relay сервер', server));
    if (key.isNotEmpty) lines.add(_configRow('Публичный ключ', key));
    if (apiServer.isNotEmpty) lines.add(_configRow('API сервер', apiServer));
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Обновление настроек подключения'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Администратор обновил настройки сервера. Скопируйте значения и вставьте их в Настройки → Сеть.'),
              const SizedBox(height: 12),
              ...lines,
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _configRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 13))),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Копировать',
                onPressed: () => Clipboard.setData(ClipboardData(text: value)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _voteNotification(String id, String vote) async {
    try {
      await http.post(
        Uri.parse('$_apiServer/admin/agent/notification/$id/vote?machine_id=$_machineId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'vote': vote}),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  BuildContext? _findContext() {
    final ctx = navigatorKey.currentContext;
    if (ctx != null) return ctx;
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    BuildContext? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget is Navigator) {
        found = e;
        return;
      }
      e.visitChildren(visit);
    }
    visit(root);
    return found;
  }

  void _withContext(void Function(BuildContext ctx) action, {int retries = 30}) {
    final ctx = _findContext();
    if (ctx != null) {
      action(ctx);
      return;
    }
    if (retries <= 0) return;
    Future.delayed(const Duration(seconds: 2), () => _withContext(action, retries: retries - 1));
  }

  void _showItem(Map<String, dynamic> item) {
    _withContext((ctx) => _showItemWithCtx(ctx, item));
  }

  String _absoluteUrl(String url) {
    if (url.isEmpty) return url;
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
    final base = _apiServer ?? '';
    if (url.startsWith('/')) return base + url;
    return '$base/$url';
  }

  void _showItemWithCtx(BuildContext ctx, Map<String, dynamic> item) {
    final id = item['id'].toString();
    final title = item['title'] as String? ?? '';
    final body = item['body'] as String? ?? '';
    final type = item['type'] as String? ?? 'banner';
    final options = (item['options'] as List<dynamic>?)?.cast<String>() ?? [];
    final link = (item['link'] as String?) ?? '';
    final linkLabel = (item['link_label'] as String?) ?? '';
    final imageUrl = _absoluteUrl((item['image_url'] as String?) ?? '');
    final severity = (item['severity'] as String?) ?? 'info';

    final accent = _severityColor(severity);
    final accentIcon = _severityIcon(severity);

    showDialog(
      context: ctx,
      barrierDismissible: type != 'poll',
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
        titlePadding: EdgeInsets.zero,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imageUrl.isNotEmpty)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                child: Image.network(
                  imageUrl,
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Row(
                children: [
                  if (type == 'banner') Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Icon(accentIcon, color: accent, size: 24),
                  ),
                  Expanded(
                    child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(body, style: const TextStyle(fontSize: 14, height: 1.45)),
                ),
              if (type == 'poll' && options.isNotEmpty) ...[
                const SizedBox(height: 12),
                ...options.map((opt) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        _voteNotification(id, opt);
                        Navigator.of(ctx).pop();
                      },
                      child: Text(opt),
                    ),
                  ),
                )),
              ],
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 8),
        actions: type == 'poll'
            ? []
            : [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Закрыть'),
                ),
                if (link.isNotEmpty)
                  FilledButton.icon(
                    onPressed: () {
                      _openExternalLink(link);
                      Navigator.of(ctx).pop();
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(linkLabel.isNotEmpty ? linkLabel : 'Открыть'),
                  ),
              ],
      ),
    );
  }

  Color _severityColor(String severity) {
    switch (severity) {
      case 'success': return const Color(0xFF16A34A);
      case 'warning': return const Color(0xFFEA580C);
      case 'error':   return const Color(0xFFDC2626);
      default:        return const Color(0xFF2563EB);
    }
  }

  IconData _severityIcon(String severity) {
    switch (severity) {
      case 'success': return Icons.check_circle_rounded;
      case 'warning': return Icons.warning_amber_rounded;
      case 'error':   return Icons.error_rounded;
      default:        return Icons.info_rounded;
    }
  }

  Future<void> _openExternalLink(String url) async {
    try {
      // Copy to clipboard as a robust fallback (Windows: opens via shell, anywhere: user can paste)
      await Clipboard.setData(ClipboardData(text: url));
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url], runInShell: true);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [url]);
      }
    } catch (_) {}
  }

  Future<void> sendSupportRequest({String message = '', String targetMachineId = '', String targetRustdeskId = ''}) async {
    if (_apiServer == null || _machineId == null) return;
    try {
      await http.post(
        Uri.parse('$_apiServer/admin/agent/support-request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'machine_id': _machineId,
          'service_key': _serviceKey ?? '',
          'hostname': Platform.localHostname,
          'message': message,
          'target_machine_id': targetMachineId,
          'target_rustdesk_id': targetRustdeskId,
        }),
      ).timeout(kHttpTimeout);
      // After sending a help request, the user is waiting for an answer.
      // Burst-poll inbox for 60 seconds (every 5 sec) so the reply
      // notification (✓ Принят / ⏰ Через 10 мин / Отклонён) lands quickly.
      _startBurstPolling();
    } catch (_) {}
  }

  Timer? _burstTimer;
  /// Aggressive polling window — used after the user sends a support request
  /// or right after they pressed any action on a support_ping. Polls inbox
  /// every 5 seconds for 60 seconds, then drops back to normal interval.
  void _startBurstPolling() {
    _burstTimer?.cancel();
    int ticks = 0;
    _burstTimer = Timer.periodic(const Duration(seconds: 5), (t) {
      _checkInbox();
      ticks++;
      if (ticks >= 12) {
        // 12 * 5 sec = 60 sec
        t.cancel();
        _burstTimer = null;
      }
    });
  }

  Future<List<Map<String, dynamic>>> fetchOperators() async {
    if (_apiServer == null) return [];
    try {
      final uri = Uri.parse('$_apiServer/admin/agent/operators').replace(queryParameters: {
        'service_key': _serviceKey ?? '',
      });
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return [];
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>?) ?? [];
      return items.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  // ─── Local help-request history ───────────────────────────────────────
  // Stored in the same app support directory as agent_id. Last 10 entries.
  //
  // For generic (unbranded) EvertyDesk clients with no operator list,
  // history is the only way to remember whom the user contacted before.

  Future<File?> _historyFile() async {
    try {
      final dir = await getApplicationSupportDirectory();
      return File('${dir.path}${Platform.pathSeparator}support_history.json');
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, String>>> loadSupportHistory() async {
    try {
      final f = await _historyFile();
      if (f == null || !await f.exists()) return [];
      final raw = await f.readAsString();
      final list = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      return list.map((e) => e.map((k, v) => MapEntry(k, v?.toString() ?? ''))).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSupportHistoryEntry({
    required String targetId,
    required String label,
  }) async {
    if (targetId.isEmpty) return;
    try {
      final existing = await loadSupportHistory();
      // De-duplicate by targetId — move existing to the top.
      existing.removeWhere((e) => e['target_id'] == targetId);
      existing.insert(0, {
        'target_id': targetId,
        'label': label,
        'at': DateTime.now().toIso8601String(),
      });
      // Keep at most 10
      while (existing.length > 10) existing.removeLast();
      final f = await _historyFile();
      if (f != null) {
        await f.writeAsString(jsonEncode(existing));
      }
    } catch (_) {}
  }

  Future<void> respondToSupportRequest(int requestId, String action) async {
    if (_apiServer == null || _machineId == null) return;
    try {
      await http.post(
        Uri.parse('$_apiServer/admin/agent/support-request/respond'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'machine_id': _machineId,
          'service_key': _serviceKey ?? '',
          'request_id': requestId,
          'action': action,
        }),
      ).timeout(kHttpTimeout);
      // Burst-poll briefly — the server may also send follow-up notifications
      // (e.g. confirmation snackbar) that the operator should see right away.
      _startBurstPolling();
    } catch (_) {}
  }

  /// Parses "req-123" → 123, used when reading support_ping options.
  int? _parseRequestRef(String ref) {
    final parts = ref.split(':');
    if (parts.length < 2) return null;
    final idStr = parts[1].replaceFirst('req-', '');
    return int.tryParse(idStr);
  }

  /// Shows a special dialog when the operator's agent receives a support_ping.
  /// Buttons: Принять / Через 10 мин / Через час / Отклонить.
  /// Each maps to an option in the AgentNotification payload (accept/defer10/defer60/decline).
  void showSupportPingDialog(BuildContext ctx, Map<String, dynamic> item) {
    final options = (item['options'] as List<dynamic>?)?.cast<String>() ?? [];
    int? requestId;
    final actionLabels = <String, String>{
      'accept': '✓ Принять',
      'defer10': 'Через 10 мин',
      'defer60': 'Через час',
      'decline': '✕ Отклонить',
    };
    final actionTypes = <String, Color>{
      'accept': const Color(0xFF16A34A),
      'defer10': const Color(0xFF2563EB),
      'defer60': const Color(0xFF2563EB),
      'decline': const Color(0xFFDC2626),
    };
    for (final o in options) {
      final id = _parseRequestRef(o);
      if (id != null) {
        requestId = id;
        break;
      }
    }

    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Row(
          children: [
            const Icon(Icons.support_agent, color: Color(0xFFEA580C)),
            const SizedBox(width: 8),
            Expanded(child: Text(item['title']?.toString() ?? 'Запрос помощи', style: const TextStyle(fontWeight: FontWeight.w700))),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item['body']?.toString() ?? '', style: const TextStyle(fontSize: 14, height: 1.5)),
            ],
          ),
        ),
        actions: actionLabels.entries.map((entry) {
          return TextButton(
            onPressed: () async {
              if (requestId != null) {
                await respondToSupportRequest(requestId, entry.key);
              }
              await _ackNotification(item['id'].toString());
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (entry.key == 'accept' && ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Запрос принят. Свяжитесь с пользователем.')),
                );
              }
            },
            style: TextButton.styleFrom(foregroundColor: actionTypes[entry.key]),
            child: Text(entry.value),
          );
        }).toList(),
      ),
    );
  }

  void showSupportRequestDialog(BuildContext ctx) {
    final messageCtl = TextEditingController();
    final manualIdCtl = TextEditingController();

    final ValueNotifier<Map<String, dynamic>?> selectedOperator = ValueNotifier(null);
    final ValueNotifier<List<Map<String, dynamic>>> operators = ValueNotifier([]);
    final ValueNotifier<bool> loadingOperators = ValueNotifier(true);
    final ValueNotifier<List<Map<String, String>>> history = ValueNotifier([]);
    // Generic clients (is_generic=true baked in at build time) have no
    // operator list — start in manual mode immediately.
    final isGenericClient = _isGenericClient;
    final ValueNotifier<bool> useManualMode = ValueNotifier(isGenericClient);

    // Load operator list + history in background.
    // For generic clients we still call fetchOperators (it returns [] anyway)
    // — but skip the auto-switch since we're already in manual mode.
    fetchOperators().then((list) {
      operators.value = list;
      loadingOperators.value = false;
      if (list.isEmpty && !isGenericClient) {
        // Tenant client whose operator list is empty (e.g. nobody online yet)
        // — also switch to manual to give user a way to act
        useManualMode.value = true;
      }
    });
    loadSupportHistory().then((h) => history.value = h);

    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Запросить помощь'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Mode toggle row — only shown if operator list is non-empty
                // AND this isn't a generic (unbranded) client. Generic clients
                // never have an operator list, so the toggle is just clutter.
                if (!isGenericClient)
                  ValueListenableBuilder<List<Map<String, dynamic>>>(
                    valueListenable: operators,
                    builder: (_, list, __) {
                      if (list.isEmpty) return const SizedBox.shrink();
                    return ValueListenableBuilder<bool>(
                      valueListenable: useManualMode,
                      builder: (_, manual, __) => Row(
                        children: [
                          Expanded(
                            child: SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(value: false, label: Text('Из списка', style: TextStyle(fontSize: 12))),
                                ButtonSegment(value: true, label: Text('По ID', style: TextStyle(fontSize: 12))),
                              ],
                              selected: {manual},
                              showSelectedIcon: false,
                              onSelectionChanged: (s) => useManualMode.value = s.first,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),

                // ── Mode 1: pick from operator list ──
                ValueListenableBuilder<bool>(
                  valueListenable: useManualMode,
                  builder: (_, manual, __) {
                    if (manual) return const SizedBox.shrink();
                    return ValueListenableBuilder<bool>(
                      valueListenable: loadingOperators,
                      builder: (_, isLoading, __) {
                        if (isLoading) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text('Загружается список...', style: TextStyle(color: Colors.grey, fontSize: 12)),
                          );
                        }
                        return ValueListenableBuilder<List<Map<String, dynamic>>>(
                          valueListenable: operators,
                          builder: (_, list, __) {
                            if (list.isEmpty) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 8),
                                child: Text(
                                  'Список сотрудников недоступен. Введите ID получателя помощи вручную.',
                                  style: TextStyle(color: Colors.orange, fontSize: 12),
                                ),
                              );
                            }
                            return ValueListenableBuilder<Map<String, dynamic>?>(
                              valueListenable: selectedOperator,
                              builder: (_, sel, __) {
                                return Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: Colors.grey.shade300),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  constraints: const BoxConstraints(maxHeight: 180),
                                  child: ListView.builder(
                                    shrinkWrap: true,
                                    itemCount: list.length + 1,
                                    itemBuilder: (_, i) {
                                      if (i == 0) {
                                        return RadioListTile<Map<String, dynamic>?>(
                                          title: const Text('Любой свободный', style: TextStyle(fontSize: 13)),
                                          value: null,
                                          groupValue: sel,
                                          dense: true,
                                          onChanged: (v) => selectedOperator.value = v,
                                        );
                                      }
                                      final op = list[i - 1];
                                      final online = op['online'] == true;
                                      return RadioListTile<Map<String, dynamic>?>(
                                        title: Row(
                                          children: [
                                            Container(
                                              width: 8, height: 8,
                                              margin: const EdgeInsets.only(right: 6),
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: online ? Colors.green : Colors.grey,
                                              ),
                                            ),
                                            Expanded(child: Text(op['hostname']?.toString() ?? op['machine_id']?.toString() ?? '?',
                                                style: const TextStyle(fontSize: 13))),
                                          ],
                                        ),
                                        value: op,
                                        groupValue: sel,
                                        dense: true,
                                        onChanged: (v) => selectedOperator.value = v,
                                      );
                                    },
                                  ),
                                );
                              },
                            );
                          },
                        );
                      },
                    );
                  },
                ),

                // ── Mode 2: manual ID entry ──
                ValueListenableBuilder<bool>(
                  valueListenable: useManualMode,
                  builder: (_, manual, __) {
                    if (!manual) return const SizedBox.shrink();
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Введите ID специалиста, у кого попросить помощь:',
                          style: TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: manualIdCtl,
                          decoration: const InputDecoration(
                            hintText: '123 456 789  или  abc123def456',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                        const SizedBox(height: 8),

                        // History of last contacted IDs
                        ValueListenableBuilder<List<Map<String, String>>>(
                          valueListenable: history,
                          builder: (_, h, __) {
                            if (h.isEmpty) return const SizedBox.shrink();
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                const Text('Недавние:',
                                  style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: h.take(6).map((e) {
                                    final lbl = e['label']?.isNotEmpty == true ? e['label']! : (e['target_id'] ?? '');
                                    return InkWell(
                                      onTap: () => manualIdCtl.text = e['target_id'] ?? '',
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                        decoration: BoxDecoration(
                                          border: Border.all(color: Colors.grey.shade300),
                                          borderRadius: BorderRadius.circular(99),
                                        ),
                                        child: Text(lbl, style: const TextStyle(fontSize: 11)),
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    );
                  },
                ),

                const SizedBox(height: 14),
                const Text('Опишите проблему (необязательно):', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 6),
                TextField(
                  controller: messageCtl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'Например: не работает принтер...',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () async {
              final op = selectedOperator.value;
              final manualId = manualIdCtl.text.trim().replaceAll(' ', '');
              final isManualEnabled = useManualMode.value;

              if (isManualEnabled && manualId.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Введите ID получателя помощи')),
                );
                return;
              }

              await sendSupportRequest(
                message: messageCtl.text.trim(),
                targetMachineId: isManualEnabled ? '' : (op?['machine_id']?.toString() ?? ''),
                targetRustdeskId: isManualEnabled ? manualId : '',
              );

              // Save to local history
              final saveId = isManualEnabled ? manualId : (op?['machine_id']?.toString() ?? '');
              final saveLabel = isManualEnabled
                  ? manualId
                  : (op?['hostname']?.toString() ?? op?['machine_id']?.toString() ?? '');
              if (saveId.isNotEmpty) {
                await saveSupportHistoryEntry(targetId: saveId, label: saveLabel);
              }

              if (ctx.mounted) {
                Navigator.of(ctx).pop();
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(
                    isManualEnabled
                      ? 'Запрос отправлен на ID $manualId. Ожидайте подключения.'
                      : (op != null
                          ? 'Запрос отправлен ${op['hostname'] ?? "сотруднику"}. Ожидайте уведомления.'
                          : 'Запрос отправлен. Свободный сотрудник подключится в ближайшее время.')
                  )),
                );
              }
            },
            child: const Text('Отправить'),
          ),
        ],
      ),
    );
  }

}
