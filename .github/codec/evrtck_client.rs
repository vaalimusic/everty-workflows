// EVRTCK v2 — Client-side codec integration for EvertyDesk
//
// This file is injected into libs/scrap/src/evrtck_codec.rs during the build workflow.
// It provides the EVRTCK tile-based lossless delta decoder for the client's
// video rendering pipeline. Activated when av1s frames carry an EVCK magic header.

#![allow(dead_code)]

use std::cell::RefCell;
use crate::{ImageFormat, ImageRgb};

// ── Constants ────────────────────────────────────────────────────────────────

pub const MAGIC: &[u8; 4] = b"EVCK";
const VERSION: u8 = 1;
const TILE_SIZE: usize = 32;
const MODE_SOLID: u8 = 1;
const MODE_DELTA: u8 = 2;

// ── EVRTCK Decoder ───────────────────────────────────────────────────────────

struct EvrtckDecoder {
    frame: Vec<u8>,
    width: usize,
    height: usize,
}

impl EvrtckDecoder {
    fn new() -> Self { Self { frame: Vec::new(), width: 0, height: 0 } }

    /// Decode raw EVRTCK packet bytes (starting with EVCK magic) into the
    /// internal BGRA frame buffer. Returns (width, height) on success.
    fn decode(&mut self, data: &[u8]) -> Option<(usize, usize)> {
        if data.len() < 20 { return None; }
        if &data[..4] != b"EVCK" { return None; }
        // version @ offset 4, flags @ 5
        // frame_id @ 6..10 (skip)
        let w = u32::from_le_bytes([data[10], data[11], data[12], data[13]]) as usize;
        let h = u32::from_le_bytes([data[14], data[15], data[16], data[17]]) as usize;
        if w == 0 || h == 0 || w > 16384 || h > 16384 { return None; }

        if self.width != w || self.height != h || self.frame.len() != w * h * 4 {
            self.frame = vec![0u8; w * h * 4];
            self.width = w;
            self.height = h;
        }

        decode_frame(data, &mut self.frame, w, h).ok()?;
        Some((w, h))
    }
}

// ── Thread-local decoder state ───────────────────────────────────────────────

thread_local! {
    static EVRTCK: RefCell<EvrtckDecoder> = RefCell::new(EvrtckDecoder::new());
}

// ── Public client API ────────────────────────────────────────────────────────

/// Decode an EVRTCK packet into an ImageRgb.
/// Returns true on success. On failure the caller should fall back to VP8.
pub fn decode_to_rgb(data: &[u8], rgb: &mut ImageRgb) -> bool {
    EVRTCK.with(|dec| {
        let mut d = dec.borrow_mut();
        let (w, h) = match d.decode(data) {
            Some(dims) => dims,
            None => return false,
        };
        // Frame buffer is BGRA (matching Windows DXGI capture format).
        // scrap ImageFormat::ARGB corresponds to in-memory BGRA (libyuv convention).
        let expected = w * h * 4;
        if d.frame.len() < expected { return false; }

        rgb.raw.resize(expected, 0);
        rgb.raw.copy_from_slice(&d.frame[..expected]);
        rgb.w = w;
        rgb.h = h;
        rgb.fmt = ImageFormat::ARGB;
        rgb.align = 1;
        true
    })
}

// ── Core decoder ─────────────────────────────────────────────────────────────

fn decode_frame(data: &[u8], frame: &mut Vec<u8>, width: usize, height: usize) -> Result<(), ()> {
    let mut pos = 0usize;

    macro_rules! need { ($n:expr) => { if pos + $n > data.len() { return Err(()); } }; }
    macro_rules! read_bytes {
        ($n:expr) => {{ need!($n); let s = &data[pos..pos+$n]; pos += $n; s }};
    }
    macro_rules! read_u16 {
        () => { u16::from_le_bytes(read_bytes!(2).try_into().unwrap()) };
    }
    macro_rules! read_u32 {
        () => { u32::from_le_bytes(read_bytes!(4).try_into().unwrap()) };
    }

    if read_bytes!(4) != b"EVCK" { return Err(()); }
    let _ver = read_bytes!(1)[0];
    let _flags = read_bytes!(1)[0];
    let _frame_id = read_u32!();
    let w = read_u32!() as usize;
    let h = read_u32!() as usize;
    if w != width || h != height { return Err(()); }

    let map_bytes = read_u16!() as usize;
    let tile_map = read_bytes!(map_bytes).to_vec();

    let tiles_x = (width + TILE_SIZE - 1) / TILE_SIZE;
    let tiles_y = (height + TILE_SIZE - 1) / TILE_SIZE;

    for ty in 0..tiles_y {
        for tx in 0..tiles_x {
            let idx = ty * tiles_x + tx;
            let dirty = (tile_map.get(idx / 8).copied().unwrap_or(0) >> (idx % 8)) & 1 == 1;
            if !dirty { continue; }

            need!(1);
            let mode = data[pos]; pos += 1;

            let x0 = tx * TILE_SIZE;
            let y0 = ty * TILE_SIZE;
            let x1 = (x0 + TILE_SIZE).min(width);
            let y1 = (y0 + TILE_SIZE).min(height);

            match mode {
                MODE_SOLID => {
                    let color = read_bytes!(4);
                    for y in y0..y1 {
                        for x in x0..x1 {
                            let off = (y * width + x) * 4;
                            frame[off..off+4].copy_from_slice(color);
                        }
                    }
                }
                MODE_DELTA => {
                    let enc_len = read_u32!() as usize;
                    let enc = read_bytes!(enc_len);
                    let delta = zrle_decode(enc).ok_or(())?;
                    let expected = (x1 - x0) * (y1 - y0) * 4;
                    if delta.len() < expected { return Err(()); }
                    let mut di = 0;
                    for y in y0..y1 {
                        for x in x0..x1 {
                            let off = (y * width + x) * 4;
                            frame[off]   ^= delta[di];
                            frame[off+1] ^= delta[di+1];
                            frame[off+2] ^= delta[di+2];
                            frame[off+3] ^= delta[di+3];
                            di += 4;
                        }
                    }
                }
                _ => return Err(()),
            }
        }
    }
    Ok(())
}

fn zrle_decode(src: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < src.len() {
        let tag = *src.get(i)?;
        i += 1;
        match tag {
            0x00 => {
                if i + 2 > src.len() { return None; }
                let count = u16::from_le_bytes([src[i], src[i+1]]) as usize;
                i += 2;
                out.resize(out.len() + count, 0);
            }
            0x01 => {
                if i + 2 > src.len() { return None; }
                let len = u16::from_le_bytes([src[i], src[i+1]]) as usize;
                i += 2;
                if i + len > src.len() { return None; }
                out.extend_from_slice(&src[i..i+len]);
                i += len;
            }
            _ => return None,
        }
    }
    Some(out)
}
