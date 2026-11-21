#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_custom_client.py — Allow custom client configuration in RustDesk src/common.rs.

1. Removes upstream ED25519 signature check in read_custom_client so clients
   can be configured by Everty / self-hosted servers.
2. Accepts both base64-encoded and raw JSON configs seamlessly.
3. Checks for both 'custom.txt' and 'custom_.txt' across Windows, Linux, and macOS.
"""

import os
import re
import sys

# Force UTF-8 stdout/stderr
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')

FILE_PATH = 'src/common.rs'


def patch_file(path):
    if not os.path.isfile(path):
        print(f"Error: {path} not found.", file=sys.stderr)
        return False

    with open(path, 'r', encoding='utf-8') as f:
        content = f.read()

    modified = False

    # ── 1. Patch read_custom_client signature verification ────────────────────
    # Look for signature verification block:
    #   let Ok(data) = decode64(config) else ...
    #   const KEY: &str = ...;
    #   let Some(pk) = get_rs_pk(KEY) ...
    #   let Ok(data) = sign::verify(&data, &pk) ...
    sig_pattern = re.compile(
        r'(pub fn read_custom_client\(config: &str\) \{)'
        r'(\s*let Ok\(data\) = decode64\(config\) else \{[^\}]+\};)'
        r'(\s*const KEY: &str = [^;]+;)'
        r'(\s*let Some\(pk\) = get_rs_pk\(KEY\) else \{[^\}]+\};)'
        r'(\s*let Ok\(data\) = sign::verify\(&data, &pk\) else \{[^\}]+\};)',
        re.MULTILINE
    )

    if sig_pattern.search(content):
        replacement = r'''\1
    let data = decode64(config).unwrap_or_else(|_| config.as_bytes().to_vec());'''
        content = sig_pattern.sub(replacement, content, count=1)
        modified = True
        print("✓ Removed signature verification check and added fallback in read_custom_client")
    elif "unwrap_or_else(|_| config.as_bytes().to_vec())" in content:
        print("ℹ️ read_custom_client already patched")
    else:
        # Fallback simpler replacement: just remove const KEY ... sign::verify if decode64 was already adjusted
        alt_pattern = re.compile(
            r'(\s*const KEY: &str = [^;]+;\s*let Some\(pk\) = get_rs_pk\(KEY\) else \{[^\}]+\};\s*let Ok\(data\) = sign::verify\(&data, &pk\) else \{[^\}]+\};)',
            re.MULTILINE
        )
        if alt_pattern.search(content):
            content = alt_pattern.sub('', content, count=1)
            modified = True
            print("✓ Removed KEY/sign::verify block via fallback pattern")

    # ── 2. Allow both custom.txt and custom_.txt in load_custom_client ─────────
    # In load_custom_client:
    #   let path = path.join("custom.txt");
    old_join = 'let path = path.join("custom.txt");'
    new_join = 'let path = if path.join("custom_.txt").is_file() { path.join("custom_.txt") } else { path.join("custom.txt") };'

    if old_join in content:
        content = content.replace(old_join, new_join, 1)
        modified = True
        print("✓ Enabled loading from both custom.txt and custom_.txt in load_custom_client")
    elif new_join in content:
        print("ℹ️ load_custom_client path resolution already patched")

    # Also handle debug assertions check: if let Ok(data) = std::fs::read_to_string("./custom.txt")
    if 'read_to_string("./custom_.txt")' not in content and 'read_to_string("./custom.txt")' in content:
        content = content.replace(
            'read_to_string("./custom.txt")',
            'read_to_string("./custom_.txt").or_else(|_| std::fs::read_to_string("./custom.txt"))',
            1
        )
        modified = True
        print("✓ Enabled debug assertion fallback for custom_.txt")

    # ── 3. Neutralize upstream update check in do_check_software_update ───────
    update_pattern = re.compile(
        r'(pub async fn do_check_software_update\(\) -> hbb_common::ResultType<\(\)> \{)(\r?\n)'
    )
    if update_pattern.search(content) and 'EVERTY_DISABLE_UPSTREAM_UPDATE_CHECK' not in content:
        content = update_pattern.sub(
            r'\1\2    if option_env!("EVERTY_DISABLE_UPSTREAM_UPDATE_CHECK").is_some() || true {\2        return Ok(());\2    }\2',
            content,
            count=1
        )
        modified = True
        print("✓ Disabled upstream update checks in do_check_software_update")

    if modified:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        print(f"✅ Successfully patched {path}")
    else:
        print(f"ℹ️ {path} already up-to-date")

    return True


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else FILE_PATH
    if not patch_file(path):
        sys.exit(1)


if __name__ == '__main__':
    main()
