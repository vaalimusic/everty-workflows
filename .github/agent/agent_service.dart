// EvertyDesk Smart Agent — injected at build time.
// Provides heartbeat, push notifications, and support requests.
// Compatible with RustDesk 1.3.5+

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/models/platform_model.dart' show bind;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class AgentService {
  AgentService._();
  static final AgentService instance = AgentService._();

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  String? _apiServer;
  String? _serviceKey;
  String? _machineId;
  String? _rustdeskId;       // RustDesk numeric ID, read lazily from config
  String _appName = '';      // branded app name (e.g. "Everty Desk") — controls config dir name, matches APP_NAME in hbb_common
  bool _showPeerList = true; // show operator list in help dialog
  Timer? _heartbeatTimer;
  Timer? _inboxTimer;
  // Tracks notification IDs that currently have a dialog open.
  // Prevents duplicate dialogs when inbox is polled while dialog is still showing.
  final Set<String> _activePingDialogIds = {};

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
  Future<void> initialize({
    required String apiServer,
    String serviceKey = '',
    bool isGenericClient = false,
    bool showPeerList = true,
    bool allowSupportRequest = true, // informational; button injection is build-time
    String appName = '',             // APP_NAME used at build time — controls the config folder name
  }) async {
    if (apiServer.isEmpty) return;
    _apiServer = apiServer.endsWith('/') ? apiServer.substring(0, apiServer.length - 1) : apiServer;
    _serviceKey = serviceKey;
    _isGenericClient = isGenericClient;
    _showPeerList = showPeerList;
    // Normalise: empty / literal "null" / lowercase "rustdesk" all mean the
    // default RustDesk build whose config lives in a folder named "RustDesk".
    final raw = appName.trim();
    _appName = (raw.isEmpty || raw == 'null' || raw.toLowerCase() == 'rustdesk')
        ? 'RustDesk'
        : raw;
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

    if (_isGenericClient) {
      Future.delayed(kLoginNudgeDelay, _maybeShowLoginNudge);
    }
  }

  // ── Soft login nudge ──────────────────────────────────────────────────────
  // Generic (unbranded) clients have no company account tied in at build
  // time — encourages personal users to sign in via Yandex to unlock the
  // cabinet (address book, session history, Smart Agent), without blocking
  // ad-hoc use. Shown once ever per install; dismissing it (either button)
  // marks it seen — this never nags again and never blocks the app.
  static const Duration kLoginNudgeDelay = Duration(seconds: 6);

  Future<File> _loginNudgeMarkerFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}login_nudge_shown');
  }

  Future<void> _maybeShowLoginNudge() async {
    try {
      final marker = await _loginNudgeMarkerFile();
      if (await marker.exists()) return;
    } catch (_) {
      return;
    }
    _withContext((ctx) => _showLoginNudgeWithCtx(ctx));
  }

  void _showLoginNudgeWithCtx(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Сохраняйте устройства и историю'),
        content: const Text(
          'Войдите через Яндекс (кнопка входа в главном меню приложения), '
          'чтобы сохранять устройства в адресной книге, видеть историю '
          'сеансов и получать уведомления. Это не обязательно — разовое '
          'подключение по ID работает и без входа.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _markLoginNudgeShown();
            },
            child: const Text('Позже'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _markLoginNudgeShown();
            },
            child: const Text('Понятно, где войти'),
          ),
        ],
      ),
    );
  }

  Future<void> _markLoginNudgeShown() async {
    try {
      final marker = await _loginNudgeMarkerFile();
      await marker.writeAsString(DateTime.now().toIso8601String());
    } catch (_) {}
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

  /// Attempts to read the RustDesk numeric ID from the app config TOML file.
  ///
  /// Key insight: the config folder name is APP_NAME (patched into hbb_common
  /// at build time), NOT the executable file name (FILE_NAME).
  ///
  ///   Windows:  %APPDATA%\{APP_NAME}\           e.g. %APPDATA%\Everty Desk\
  ///   Linux:    ~/.config/{APP_NAME}/            e.g. ~/.config/Everty Desk/
  ///   macOS:    ~/Library/Preferences/{APP_NAME}/
  ///
  /// Flutter's getApplicationSupportDirectory() points elsewhere — we keep it
  /// only as a last-resort fallback.
  Future<String> _readRustdeskIdFromConfig() async {
    // ── 1. Ask RustDesk directly via native binding (most reliable) ───────────
    // bind.mainGetMyId() is available because this agent is injected into the
    // flutter_hbb process at build time. This works regardless of config format
    // (plain id= or enc_id= encryption introduced in newer RustDesk versions).
    try {
      final id = await bind.mainGetMyId().timeout(const Duration(seconds: 3));
      if (id.isNotEmpty && int.tryParse(id) != null) return id;
    } catch (_) {}

    // ── 2. File fallback: parse .toml config ──────────────────────────────────
    // Handles both plain `id = "123"` and the older unencrypted format.
    // enc_id (encrypted) cannot be decoded here — binding above covers that.
    final idRegex = RegExp(r"""\bid\s*=\s*['"]?(\d{6,12})['"]?""", multiLine: true);

    final candidates = <Directory>[];

    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'] ?? '';
      if (appData.isNotEmpty) {
        candidates.add(Directory('$appData\\$_appName'));
        candidates.add(Directory('$appData\\$_appName\\config'));
      }
    } else if (Platform.isMacOS) {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) {
        candidates.add(Directory('$home/Library/Preferences/$_appName'));
        candidates.add(Directory('$home/Library/Application Support/$_appName'));
      }
    } else if (Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) {
        candidates.add(Directory('$home/.config/$_appName'));
        candidates.add(Directory('$home/.config/$_appName/config'));
      }
    }

    try {
      final dir = await getApplicationSupportDirectory();
      candidates.addAll([
        Directory(dir.path),
        Directory('${dir.path}${Platform.pathSeparator}config'),
        Directory('${dir.parent.path}${Platform.pathSeparator}config'),
        dir.parent,
      ]);
    } catch (_) {}

    for (final d in candidates) {
      try {
        if (!await d.exists()) continue;
        await for (final entity in d.list()) {
          if (entity is! File) continue;
          if (!entity.path.endsWith('.toml')) continue;
          try {
            final content = await entity.readAsString();
            final match = idRegex.firstMatch(content);
            if (match != null) {
              final id = match.group(1) ?? '';
              if (id.isNotEmpty && int.tryParse(id) != null) return id;
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
    return '';
  }

  /// Tries to load the RustDesk numeric ID from the config file.
  /// First attempt fires after 2 s (before the first heartbeat at 3 s),
  /// then backs off to 15 s, 30 s, 45 s. Stops as soon as the ID is found.
  void _tryLoadRustdeskId({int attempt = 0}) {
    if (_rustdeskId != null && _rustdeskId!.isNotEmpty) return;
    // Attempt 0: 2 s — catch the common case where the relay assigns the ID
    //            before the first heartbeat (3 s). Subsequent retries use
    //            longer delays for machines that get assigned IDs later.
    final delaySec = attempt == 0 ? 2 : 15 * attempt;
    Future.delayed(Duration(seconds: delaySec), () async {
      try {
        final id = await _readRustdeskIdFromConfig();
        if (id.isNotEmpty) {
          _rustdeskId = id;
          return; // success — stop retrying
        }
      } catch (_) {}
      if (attempt < 4) _tryLoadRustdeskId(attempt: attempt + 1);
    });
  }

  Future<void> _sendHeartbeat() async {
    if (_apiServer == null || _machineId == null) return;
    // If ID still unknown, try once more before sending — covers the case
    // where all startup retries ran before RustDesk got its ID from relay.
    if (_rustdeskId == null || _rustdeskId!.isEmpty) {
      try {
        final id = await _readRustdeskIdFromConfig();
        if (id.isNotEmpty) _rustdeskId = id;
      } catch (_) {}
    }
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
          final pingId = item['id']?.toString() ?? '';
          if (!_activePingDialogIds.contains(pingId)) {
            _withContext((ctx) {
              showSupportPingDialog(ctx, item as Map<String, dynamic>);
            });
          }
        } else if (item['type'] == 'connection_alert') {
          _withContext((ctx) async {
            await _ackNotification(item['id'].toString());
            _showConnectionAlert(ctx, item as Map<String, dynamic>);
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
      final permanentPassword = (body['permanent_password'] as String?) ?? '';

      if (permanentPassword.isNotEmpty) {
        try {
          await bind.mainSetOption('permanent-password', permanentPassword);
          _withContext((ctx) {
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(
                  content: Text('Постоянный пароль обновлён администратором'),
                  duration: Duration(seconds: 4),
                ),
              );
            }
          });
        } catch (_) {}
      }

      if (server.isNotEmpty || key.isNotEmpty || apiServer.isNotEmpty) {
        _showConfigUpdateDialog(server: server, key: key, apiServer: apiServer);
      }
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

  /// Sends a support request. Returns null on success, or a human-readable
  /// error string (e.g. rate-limit message) that the caller should display.
  Future<String?> sendSupportRequest({String message = '', String targetMachineId = '', String targetRustdeskId = ''}) async {
    if (_apiServer == null || _machineId == null) return 'Агент не инициализирован';
    try {
      final resp = await http.post(
        Uri.parse('$_apiServer/admin/agent/support-request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'machine_id': _machineId,
          'service_key': _serviceKey ?? '',
          'hostname': Platform.localHostname,
          'message': message,
          'target_machine_id': targetMachineId,
          'target_rustdesk_id': targetRustdeskId,
          'from_rustdesk_id': _rustdeskId ?? '', // own numeric ID for operator auto-connect
        }),
      ).timeout(kHttpTimeout);

      if (resp.statusCode == 429) {
        // Rate-limit or open-request cap hit. Try to extract the server's message.
        try {
          final body = jsonDecode(resp.body) as Map<String, dynamic>;
          final msg = body['message'] as String?;
          if (msg != null && msg.isNotEmpty) return msg;
        } catch (_) {}
        return 'Слишком много запросов. Подождите немного и попробуйте снова.';
      }
      if (resp.statusCode >= 400) {
        return 'Ошибка сервера (${resp.statusCode}). Попробуйте позже.';
      }

      // After sending a help request, the user is waiting for an answer.
      // Burst-poll inbox for 60 seconds (every 5 sec) so the reply
      // notification (✓ Принят / ⏰ Через 10 мин / Отклонён) lands quickly.
      _startBurstPolling();
      return null; // success
    } catch (_) {
      return 'Нет связи с сервером. Проверьте интернет-соединение.';
    }
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

  /// Responds to a support request. Returns null on success, or an error string.
  Future<String?> respondToSupportRequest(int requestId, String action) async {
    if (_apiServer == null || _machineId == null) return 'Агент не инициализирован';
    try {
      final resp = await http.post(
        Uri.parse('$_apiServer/admin/agent/support-request/respond'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'machine_id': _machineId,
          'service_key': _serviceKey ?? '',
          'request_id': requestId,
          'action': action,
        }),
      ).timeout(kHttpTimeout);
      if (resp.statusCode == 403) return 'Этот запрос адресован другому специалисту';
      if (resp.statusCode == 409) return 'Запрос уже был обработан ранее';
      if (resp.statusCode >= 400) return 'Ошибка сервера (${resp.statusCode})';
      // Burst-poll briefly — the server may also send follow-up notifications
      // (e.g. confirmation snackbar) that the operator should see right away.
      _startBurstPolling();
      return null; // success
    } catch (_) {
      return 'Нет связи с сервером';
    }
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
  /// If the ping includes a meta:from_rdid=<id> option, pressing «Принять» will
  /// automatically open a RustDesk connection to the requester's machine.
  void showSupportPingDialog(BuildContext ctx, Map<String, dynamic> item) {
    final options = (item['options'] as List<dynamic>?)?.cast<String>() ?? [];
    int? requestId;
    String? fromRdId; // client's RustDesk numeric ID for auto-connect
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
      if (o.startsWith('meta:from_rdid=')) {
        final id = o.substring('meta:from_rdid='.length).trim();
        if (id.isNotEmpty) fromRdId = id;
        continue; // not a button
      }
      final id = _parseRequestRef(o);
      if (id != null && requestId == null) {
        requestId = id;
      }
    }

    final dialogId = item['id']?.toString() ?? '';
    _activePingDialogIds.add(dialogId);
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
              if (fromRdId != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.link, size: 14, color: Color(0xFF6B7280)),
                    const SizedBox(width: 4),
                    Text('ID: $fromRdId', style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  ],
                ),
              ],
            ],
          ),
        ),
        actions: actionLabels.entries.map((entry) {
          return TextButton(
            onPressed: () async {
              String? respondError;
              if (requestId != null) {
                respondError = await respondToSupportRequest(requestId, entry.key);
              }
              // If server rejected the action (403 / 409), show error and keep dialog open.
              if (respondError != null) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text(respondError), backgroundColor: const Color(0xFFDC2626)),
                  );
                }
                return;
              }
              await _ackNotification(item['id'].toString());
              _activePingDialogIds.remove(dialogId);
              if (ctx.mounted) Navigator.of(ctx).pop();
              if (entry.key == 'accept') {
                // Auto-connect: open RustDesk URL scheme so the desktop client
                // immediately initiates a connection to the requester.
                if (fromRdId != null && fromRdId!.isNotEmpty) {
                  await _openRustdeskConnection(fromRdId!);
                } else if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    const SnackBar(content: Text('Запрос принят. Свяжитесь с пользователем.')),
                  );
                }
              }
            },
            style: TextButton.styleFrom(foregroundColor: actionTypes[entry.key]),
            child: Text(entry.value),
          );
        }).toList(),
      ),
    ).then((_) {
      // Fallback cleanup: remove from active set when dialog is dismissed
      // by any means (back button, system, app restart, etc.)
      _activePingDialogIds.remove(dialogId);
    });
  }

  /// Opens a direct RustDesk connection to [peerId] using the RustDesk URL scheme.
  /// rustdesk://peerId causes RustDesk to bring itself to foreground and connect.
  Future<void> _openRustdeskConnection(String peerId) async {
    final url = 'rustdesk://$peerId';
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url], runInShell: true);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [url]);
      }
    } catch (_) {
      // Fallback: copy ID to clipboard so the operator can connect manually.
      await Clipboard.setData(ClipboardData(text: peerId));
    }
  }

  /// Shows a connection alert when an Android client connects to this host.
  /// On Windows: system toast notification (visible even when app is minimized to tray).
  /// On other platforms: in-app overlay in top-right corner.
  void _showConnectionAlert(BuildContext ctx, Map<String, dynamic> item) {
    final title = item['title'] as String? ?? 'EvertyDesk — входящее подключение';
    final body = item['body'] as String? ?? 'К вам подключились с мобильного устройства.';

    if (Platform.isWindows) {
      _showWindowsToast(title, body);
      return;
    }

    // Non-Windows: in-app overlay
    final overlay = Overlay.of(ctx);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => Positioned(
        top: 24,
        right: 24,
        child: Material(
          color: Colors.transparent,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(
              color: const Color(0xFF1F2937),
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(color: Colors.black26, blurRadius: 14, offset: Offset(0, 4)),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.phone_android_rounded, color: Color(0xFF60A5FA), size: 28),
                const SizedBox(width: 12),
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                      const SizedBox(height: 3),
                      Text(body,
                          style: const TextStyle(
                              color: Color(0xFF9CA3AF), fontSize: 12, height: 1.4)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 5), () {
      try { entry.remove(); } catch (_) {}
    });
  }

  /// Fires a Windows system toast notification via PowerShell.
  /// Works even when the app is minimized to the system tray.
  void _showWindowsToast(String title, String body) {
    // Escape single quotes for PowerShell string
    final safeTitle = title.replaceAll("'", "\\'");
    final safeBody = body.replaceAll("'", "\\'");
    final script = r"""
[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom,ContentType=WindowsRuntime] | Out-Null
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$xml.SelectSingleNode('//text[@id=1]').InnerText = '""" + safeTitle + r"""'
$xml.SelectSingleNode('//text[@id=2]').InnerText = '""" + safeBody + r"""'
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('EvertyDesk').Show($toast)
""";
    try {
      Process.start(
        'powershell',
        ['-NonInteractive', '-NoProfile', '-Command', script],
        runInShell: false,
      );
    } catch (_) {}
  }

  void showSupportRequestDialog(BuildContext ctx) {
    final messageCtl = TextEditingController();
    final manualIdCtl = TextEditingController();

    final ValueNotifier<Map<String, dynamic>?> selectedOperator = ValueNotifier(null);
    final ValueNotifier<List<Map<String, dynamic>>> operators = ValueNotifier([]);
    final ValueNotifier<bool> loadingOperators = ValueNotifier(true);
    final ValueNotifier<List<Map<String, String>>> history = ValueNotifier([]);
    // Generic clients (is_generic=true baked in at build time) have no
    // operator list. Also respect the build-time show_peer_list flag.
    final isGenericClient = _isGenericClient;
    final hidePeerList = !_showPeerList; // build-time: admin disabled list
    final ValueNotifier<bool> useManualMode = ValueNotifier(isGenericClient || hidePeerList);

    // Load operator list + history in background.
    // Skip fetching if the peer list is hidden (no point in calling the API).
    // For generic clients we still call fetchOperators (it returns [] anyway)
    // — but skip the auto-switch since we're already in manual mode.
    if (hidePeerList) {
      loadingOperators.value = false;
    } else {
      fetchOperators().then((list) {
        operators.value = list;
        loadingOperators.value = false;
        if (list.isEmpty && !isGenericClient) {
          // Tenant client whose operator list is empty (e.g. nobody online yet)
          // — also switch to manual to give user a way to act
          useManualMode.value = true;
        }
      });
    }
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
                // Mode toggle row — only shown if operator list is non-empty,
                // this isn't a generic (unbranded) client, and the build
                // allows showing the peer list (show_peer_list setting).
                if (!isGenericClient && !hidePeerList)
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

              final sendError = await sendSupportRequest(
                message: messageCtl.text.trim(),
                targetMachineId: isManualEnabled ? '' : (op?['machine_id']?.toString() ?? ''),
                targetRustdeskId: isManualEnabled ? manualId : '',
              );

              if (sendError != null) {
                // Show error without closing the dialog so user can retry.
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(
                      content: Text(sendError),
                      backgroundColor: const Color(0xFFDC2626),
                      duration: const Duration(seconds: 5),
                    ),
                  );
                }
                return;
              }

              // Save to local history on success
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
                          : 'Запрос отправлен. Любой свободный сотрудник подключится в ближайшее время.')
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
