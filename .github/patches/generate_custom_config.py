#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
generate_custom_config.py — Generate RustDesk custom.txt / custom_.txt configuration.

Parses custom_config JSON from Everty API server and writes standard RustDesk
custom configuration files. Supports base64 encoding and raw JSON format.
"""

import argparse
import base64
import json
import os
import sys

# Force UTF-8 stdout/stderr
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')


def yn(v):
    if isinstance(v, bool):
        return 'Y' if v else 'N'
    return 'Y' if str(v).strip().lower() in ('true', 'yes', 'y', '1') else 'N'


def build_config(custom, server='', key='', api_server=''):
    if isinstance(custom, str):
        try:
            custom = json.loads(custom)
        except Exception:
            custom = {}

    if not isinstance(custom, dict):
        custom = {}

    cfg = {}

    conn_type = custom.get('conn_type', 'both')
    if conn_type and conn_type != 'both':
        cfg['conn-type'] = conn_type

    if yn(custom.get('disable_installation', False)) == 'Y':
        cfg['disable-installation'] = 'Y'
    if yn(custom.get('disable_settings', False)) == 'Y':
        cfg['disable-settings'] = 'Y'

    perm_pass = str(custom.get('permanent_password', '') or '').strip()
    if perm_pass:
        cfg['password'] = perm_pass

    cfg['enable-lan-discovery'] = yn(custom.get('enable_lan_discovery', custom.get('enable_lan', True)))
    cfg['allow-auto-disconnect'] = yn(custom.get('allow_auto_disconnect', custom.get('auto_disconnect', False)))
    cfg['allow-change-id'] = yn(custom.get('allow_change_id', True))

    settings_mode = custom.get('settings_mode', 'default')
    mode_key = 'override-settings' if settings_mode == 'override' else 'default-settings'

    theme_mode = custom.get('theme_mode', 'default')
    theme_key = 'override-settings' if theme_mode == 'override' else 'default-settings'

    cfg['override-settings'] = {}
    cfg['default-settings'] = {}

    # If rendezvous server / key / api-server provided, set in default-settings
    if server:
        cfg['default-settings']['custom-rendezvous-server'] = server
    if key:
        cfg['default-settings']['key'] = key
    if api_server:
        cfg['default-settings']['api-server'] = api_server

    theme = custom.get('theme', 'system')
    if theme and theme != 'system':
        cfg[theme_key]['theme'] = theme

    access_mode = custom.get('access_mode', 'custom')
    cfg[mode_key]['access-mode'] = access_mode

    cfg[mode_key]['enable-keyboard'] = yn(custom.get('enable_keyboard', custom.get('enable_kb', True)))
    cfg[mode_key]['enable-clipboard'] = yn(custom.get('enable_clipboard', custom.get('enable_cb', True)))
    cfg[mode_key]['enable-file-transfer'] = yn(custom.get('enable_file_transfer', custom.get('enable_ft', True)))
    cfg[mode_key]['enable-audio'] = yn(custom.get('enable_audio', True))
    cfg[mode_key]['enable-tunnel'] = yn(custom.get('enable_tunnel', custom.get('enable_tcp', True)))
    cfg[mode_key]['enable-remote-restart'] = yn(custom.get('enable_remote_restart', custom.get('enable_restart', True)))
    cfg[mode_key]['enable-record-session'] = yn(custom.get('enable_record_session', custom.get('enable_record', True)))
    cfg[mode_key]['enable-block-input'] = yn(custom.get('enable_block_input', custom.get('enable_block', True)))
    cfg[mode_key]['allow-remote-config-modification'] = yn(custom.get('allow_remote_config_modification', custom.get('enable_remmod', False)))
    cfg[mode_key]['direct-server'] = yn(custom.get('direct_server', custom.get('enable_direct', False)))
    cfg[mode_key]['verification-method'] = custom.get('verification_method', custom.get('verif_method', 'use-both-passwords'))
    cfg[mode_key]['approve-mode'] = custom.get('approve_mode', 'password-click')
    cfg[mode_key]['allow-hide-cm'] = yn(custom.get('allow_hide_cm', custom.get('hide_cm', False)))
    cfg[mode_key]['allow-remove-wallpaper'] = yn(custom.get('allow_remove_wallpaper', custom.get('remove_wallpaper', True)))
    cfg[mode_key]['enable-remote-printer'] = yn(custom.get('enable_remote_printer', custom.get('enable_printer', True)))
    cfg[mode_key]['enable-camera'] = yn(custom.get('enable_camera', True))
    cfg[mode_key]['enable-terminal'] = yn(custom.get('enable_terminal', True))

    # Manual key=value settings
    for line in (custom.get('default_manual') or '').splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            cfg['default-settings'][k.strip()] = v.strip()

    for line in (custom.get('override_manual') or '').splitlines():
        if '=' in line:
            k, v = line.split('=', 1)
            cfg['override-settings'][k.strip()] = v.strip()

    if not cfg['default-settings']:
        del cfg['default-settings']
    if not cfg['override-settings']:
        del cfg['override-settings']

    return cfg


def main():
    parser = argparse.ArgumentParser(description='Generate custom config file for RustDesk.')
    parser.add_argument('--custom-json', default=os.environ.get('CUSTOM_JSON', '{}'), help='Raw JSON string of custom config')
    parser.add_argument('--custom-file', default='', help='Path to file containing custom config JSON')
    parser.add_argument('--server', default=os.environ.get('RDSERVER', ''), help='ID/Relay Server')
    parser.add_argument('--key', default=os.environ.get('RDKEY', ''), help='Public Key')
    parser.add_argument('--api-server', default=os.environ.get('API_SERVER', ''), help='API Server')
    parser.add_argument('--output', action='append', default=[], help='Target output file path(s)')
    parser.add_argument('--output-dir', default='', help='Target directory where custom.txt and custom_.txt will be written')
    parser.add_argument('--format', choices=['base64', 'json'], default='base64', help='Output format (base64 or json, defaults to base64)')

    args = parser.parse_args()

    custom_data = {}
    if args.custom_file and os.path.isfile(args.custom_file):
        try:
            with open(args.custom_file, 'r', encoding='utf-8') as f:
                custom_data = json.load(f)
        except Exception as e:
            print(f'Warning: failed to read custom-file {args.custom_file}: {e}', file=sys.stderr)
    else:
        raw_json = args.custom_json.strip()
        if raw_json and raw_json != 'null':
            try:
                custom_data = json.loads(raw_json)
            except Exception as e:
                print(f'Warning: failed to parse custom-json: {e}', file=sys.stderr)

    cfg = build_config(custom_data, server=args.server, key=args.key, api_server=args.api_server)
    json_bytes = json.dumps(cfg).encode('utf-8')

    if args.format == 'base64':
        output_content = base64.b64encode(json_bytes).decode('utf-8')
    else:
        output_content = json_bytes.decode('utf-8')

    targets = list(args.output)
    if args.output_dir:
        targets.append(os.path.join(args.output_dir, 'custom.txt'))
        targets.append(os.path.join(args.output_dir, 'custom_.txt'))

    if not targets:
        # Default fallback to stdout
        sys.stdout.write(output_content)
        return

    for t in targets:
        os.makedirs(os.path.dirname(os.path.abspath(t)), exist_ok=True)
        with open(t, 'w', encoding='utf-8') as f:
            f.write(output_content)
        print(f'✓ Wrote custom config to {t} ({len(output_content)} bytes, format={args.format})')


if __name__ == '__main__':
    main()
