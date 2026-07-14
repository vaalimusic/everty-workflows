#!/usr/bin/env python3
"""
apply_evrtck.py — Inject EVRTCK v2 lossless tile codec into RustDesk build.

Changes:
  1. Copies evrtck_server.rs  → src/evrtck_codec.rs
  2. Copies evrtck_client.rs  → libs/scrap/src/evrtck_codec.rs
  3. Declares modules in src/lib.rs and libs/scrap/src/lib.rs
  4. Patches src/server/video_service.rs — EVRTCK replaces VP8 encode path
  5. Patches libs/scrap/src/common/codec.rs — intercepts av1s for EVRTCK decode
"""

import sys
import shutil
import os

PATCH_DIR = "/tmp/everty-patches"

# ── 1. Copy codec source files ────────────────────────────────────────────────

shutil.copy(f"{PATCH_DIR}/evrtck_server.rs", "src/evrtck_codec.rs")
print("✓ copied evrtck_server.rs → src/evrtck_codec.rs")

shutil.copy(f"{PATCH_DIR}/evrtck_client.rs", "libs/scrap/src/evrtck_codec.rs")
print("✓ copied evrtck_client.rs → libs/scrap/src/evrtck_codec.rs")


# ── 2. Declare module in src/lib.rs ──────────────────────────────────────────

with open("src/lib.rs", "r", encoding="utf-8") as f:
    src = f.read()

MOD_ANCHOR = "mod server;"
MOD_INSERT = "mod server;\npub mod evrtck_codec;"

if "evrtck_codec" in src:
    print("✓ src/lib.rs already has evrtck_codec")
else:
    if MOD_ANCHOR not in src:
        print("ERROR: could not find 'mod server;' in src/lib.rs")
        sys.exit(1)
    src = src.replace(MOD_ANCHOR, MOD_INSERT, 1)
    with open("src/lib.rs", "w", encoding="utf-8") as f:
        f.write(src)
    print("✓ added evrtck_codec module to src/lib.rs")


# ── 3. Declare module in libs/scrap/src/lib.rs ───────────────────────────────

with open("libs/scrap/src/lib.rs", "r", encoding="utf-8") as f:
    scrap_lib = f.read()

SCRAP_ANCHOR = "mod common;"
SCRAP_INSERT = "mod common;\npub mod evrtck_codec;"

if "evrtck_codec" in scrap_lib:
    print("✓ libs/scrap/src/lib.rs already has evrtck_codec")
else:
    if SCRAP_ANCHOR not in scrap_lib:
        print("ERROR: could not find 'mod common;' in libs/scrap/src/lib.rs")
        sys.exit(1)
    scrap_lib = scrap_lib.replace(SCRAP_ANCHOR, SCRAP_INSERT, 1)
    with open("libs/scrap/src/lib.rs", "w", encoding="utf-8") as f:
        f.write(scrap_lib)
    print("✓ added evrtck_codec module to libs/scrap/src/lib.rs")


# ── 4. Patch src/server/video_service.rs ─────────────────────────────────────

with open("src/server/video_service.rs", "r", encoding="utf-8") as f:
    vs = f.read()

if "evrtck_codec" in vs:
    print("✓ video_service.rs already patched")
else:
    # Old: VP8 encode path (the section we replace with EVRTCK)
    OLD_ENCODE = (
        "            let frame = frame.to(encoder.yuvfmt(), &mut yuv, &mut mid_data)?;\n"
        "            let send_conn_ids = handle_one_frame(\n"
        "                display_idx,\n"
        "                &sp,\n"
        "                frame,\n"
        "                ms,\n"
        "                &mut encoder,\n"
        "                recorder.clone(),\n"
        "                &mut encode_fail_counter,\n"
        "                &mut first_frame,\n"
        "                capture_width,\n"
        "                capture_height,\n"
        "            )?;\n"
        "            frame_controller.set_send(now, send_conn_ids);\n"
        "            send_counter += 1;"
    )

    NEW_ENCODE = (
        "            // Everty: try EVRTCK v2 tile codec on raw pixels before YUV conversion\n"
        "            let evrtck_sent = if let scrap::Frame::PixelBuffer(ref pb) = frame {\n"
        "                crate::evrtck_codec::try_encode_and_send(\n"
        "                    pb.data(),\n"
        "                    pb.width(),\n"
        "                    pb.height(),\n"
        "                    display_idx as _,\n"
        "                    ms,\n"
        "                    &sp,\n"
        "                )\n"
        "            } else {\n"
        "                false // GPU texture frames fall through to VP8\n"
        "            };\n"
        "            if evrtck_sent {\n"
        "                frame_controller.set_send(now, Default::default());\n"
        "                send_counter += 1;\n"
        "            } else {\n"
        "                // Fall back to VP8/VP9 for high-motion content or GPU frames\n"
        "                let frame = frame.to(encoder.yuvfmt(), &mut yuv, &mut mid_data)?;\n"
        "                let send_conn_ids = handle_one_frame(\n"
        "                    display_idx,\n"
        "                    &sp,\n"
        "                    frame,\n"
        "                    ms,\n"
        "                    &mut encoder,\n"
        "                    recorder.clone(),\n"
        "                    &mut encode_fail_counter,\n"
        "                    &mut first_frame,\n"
        "                    capture_width,\n"
        "                    capture_height,\n"
        "                )?;\n"
        "                frame_controller.set_send(now, send_conn_ids);\n"
        "                send_counter += 1;\n"
        "            }"
    )

    if OLD_ENCODE not in vs:
        print("ERROR: could not find VP8 encode anchor in video_service.rs")
        print("Expected anchor (first 80 chars):")
        print(repr(OLD_ENCODE[:80]))
        sys.exit(1)

    vs = vs.replace(OLD_ENCODE, NEW_ENCODE, 1)

    # Also need frame.data() — verify the raw frame type exposes .data()
    # (scrap::Frame does: returns &[u8] of raw pixel bytes)

    with open("src/server/video_service.rs", "w", encoding="utf-8") as f:
        f.write(vs)
    print("✓ patched video_service.rs with EVRTCK encode path")


# ── 5. Patch libs/scrap/src/common/codec.rs ──────────────────────────────────

with open("libs/scrap/src/common/codec.rs", "r", encoding="utf-8") as f:
    codec = f.read()

if "evrtck_codec" in codec:
    print("✓ codec.rs already patched")
else:
    # Old: normal av1s decode arm
    OLD_AV1 = (
        "        video_frame::Union::Av1s(av1s) => {\n"
        "            if let Some(av1) = &mut self.av1 {\n"
        "                Decoder::handle_av1s_video_frame(av1, av1s, rgb, chroma)\n"
        "            } else {\n"
        "                bail!(\"av1 decoder not available\");\n"
        "            }\n"
        "        }"
    )

    NEW_AV1 = (
        "        video_frame::Union::Av1s(av1s) => {\n"
        "            // Everty: EVRTCK v2 transport piggybacks on av1s (magic = b\"EVCK\")\n"
        "            if av1s.frames.len() == 1 && av1s.frames[0].data.starts_with(b\"EVCK\") {\n"
        "                let ok = crate::evrtck_codec::decode_to_rgb(&av1s.frames[0].data, rgb);\n"
        "                return Ok(ok);\n"
        "            }\n"
        "            if let Some(av1) = &mut self.av1 {\n"
        "                Decoder::handle_av1s_video_frame(av1, av1s, rgb, chroma)\n"
        "            } else {\n"
        "                bail!(\"av1 decoder not available\");\n"
        "            }\n"
        "        }"
    )

    if OLD_AV1 not in codec:
        print("ERROR: could not find av1s arm in codec.rs")
        print("Expected anchor (first 80 chars):")
        print(repr(OLD_AV1[:80]))
        sys.exit(1)

    codec = codec.replace(OLD_AV1, NEW_AV1, 1)
    with open("libs/scrap/src/common/codec.rs", "w", encoding="utf-8") as f:
        f.write(codec)
    print("✓ patched codec.rs with EVRTCK decode path")


print("\n✅ EVRTCK v2 integration complete")
print("   Server: EVRTCK replaces VP8 for desktop content (fallback for >500KB frames)")
print("   Client: av1s frames with EVCK magic are decoded by EVRTCK, not AV1")
