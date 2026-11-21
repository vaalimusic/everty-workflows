#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
apply_branding_links.py — Apply custom URLs and notification suppression.

Replaces upstream RustDesk URLs (homepage, download link) with branded ones,
and disables upstream update checks / notification banners across platforms.

Usage:
    python3 apply_branding_links.py \
        [--url-link "https://desk.everty.ru"] \
        [--download-link "https://desk.everty.ru/download"] \
        [--remove-notif]
"""

import argparse
import os
import re
import sys

# Force UTF-8 stdout/stderr
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')


def safe_replace(file_path: str, old_str: str, new_str: str, description: str = ""):
    if not os.path.isfile(file_path):
        return False
    try:
        with open(file_path, "r", encoding="utf-8", errors="ignore") as f:
            content = f.read()
        if old_str in content:
            updated = content.replace(old_str, new_str)
            with open(file_path, "w", encoding="utf-8") as f:
                f.write(updated)
            label = description or f"{file_path}: {old_str} -> {new_str}"
            print(f"  ✓ {label}")
            return True
    except Exception as e:
        print(f"  ⚠ Failed patching {file_path}: {e}", file=sys.stderr)
    return False


def apply_url_link(url_link: str):
    if not url_link or url_link.strip() == "https://rustdesk.com":
        return
    url = url_link.strip().rstrip('/')
    print(f"Applying custom homepage URL: {url}")
    safe_replace("build.py", "Homepage: https://rustdesk.com", f"Homepage: {url}", "build.py homepage")
    safe_replace("flutter/lib/common.dart", "launchUrl(Uri.parse('https://rustdesk.com'));", f"launchUrl(Uri.parse('{url}'));", "common.dart launchUrl")
    safe_replace("flutter/lib/desktop/pages/desktop_setting_page.dart", "launchUrlString('https://rustdesk.com');", f"launchUrlString('{url}');", "desktop_setting_page.dart")
    safe_replace("flutter/lib/mobile/pages/settings_page.dart", "const url = 'https://rustdesk.com/';", f"const url = '{url}/';", "mobile settings_page.dart")
    safe_replace("flutter/lib/desktop/pages/install_page.dart", "https://rustdesk.com/privacy.html", f"{url}/privacy.html", "install_page.dart privacy")
    safe_replace("res/msi/Package/License.rtf", "rustdesk.com", url, "msi license")


def apply_download_link(download_link: str):
    if not download_link or download_link.strip() == "https://rustdesk.com/download":
        return
    dl = download_link.strip()
    print(f"Applying custom download URL: {dl}")
    safe_replace("flutter/lib/desktop/pages/desktop_home_page.dart", "https://rustdesk.com/download", dl, "desktop_home_page.dart download url")
    safe_replace("flutter/lib/mobile/pages/connection_page.dart", "https://rustdesk.com/download", dl, "mobile connection_page.dart download url")


def apply_remove_notif():
    print("Suppressing upstream new version notifications...")
    # 1. Flutter desktop_home_page.dart
    safe_replace(
        "flutter/lib/desktop/pages/desktop_home_page.dart",
        "updateUrl.isNotEmpty",
        "false",
        "desktop_home_page.dart updateUrl.isNotEmpty -> false"
    )

    # 2. Rust src/common.rs
    common_rs = "src/common.rs"
    if os.path.isfile(common_rs):
        try:
            with open(common_rs, "r", encoding="utf-8") as f:
                content = f.read()
            pattern = re.compile(r'(pub async fn do_check_software_update\(\) -> hbb_common::ResultType<\(\)> \{)(\r?\n)')
            if pattern.search(content) and 'EVERTY_DISABLE_UPSTREAM_UPDATE_CHECK' not in content:
                replacement = r'\1\2    if option_env!("EVERTY_DISABLE_UPSTREAM_UPDATE_CHECK").is_some() || true {\2        return Ok(());\2    }\2'
                content = pattern.sub(replacement, content, count=1)
                with open(common_rs, "w", encoding="utf-8") as f:
                    f.write(content)
                print("  ✓ src/common.rs do_check_software_update bypassed")
        except Exception as e:
            print(f"  ⚠ Failed patching src/common.rs: {e}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url-link", default=os.environ.get("URL_LINK", ""), help="Homepage URL")
    parser.add_argument("--download-link", default=os.environ.get("DOWNLOAD_LINK", ""), help="Download URL")
    parser.add_argument("--remove-notif", action="store_true", default=os.environ.get("REMOVE_NOTIF", "").lower() in ("true", "1", "yes"), help="Suppress update notifications")
    args = parser.parse_args()

    if args.url_link:
        apply_url_link(args.url_link)
    if args.download_link:
        apply_download_link(args.download_link)
    if args.remove_notif:
        apply_remove_notif()


if __name__ == "__main__":
    main()
