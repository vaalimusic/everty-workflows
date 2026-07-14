// EVRTCK v2 — Server-side codec integration for EvertyDesk
//
// This file is injected into src/evrtck_codec.rs during the build workflow.
// It provides the EVRTCK tile-based lossless delta encoder for the server's
// video capture pipeline, replacing VP8/VP9 for desktop/UI content.
//
// Wire format: [EVCK magic][version][flags][frame_id][width][height][map_bytes][tile_map][tile data...]

#![allow(dead_code)]

use std::cell::RefCell;
use hbb_common::message_proto::{EncodedVideoFrame, EncodedVideoFrames, Message, VideoFrame};

// GenericService is re-exported from the server module in lib.rs (pub use self::server::*)
// Defined as: pub type GenericService = ServiceTmpl<ConnInner>
use crate::GenericService;

// ── Constants ────────────────────────────────────────────────────────────────

pub const MAGIC: &[u8; 4] = b"EVCK";
const VERSION: u8 = 1;
pub const TILE_SIZE: usize = 32;
const MODE_SOLID: u8 = 1;
const MODE_DELTA: u8 = 2;

// ── EVRTCK Encoder ───────────────────────────────────────────────────────────

pub struct EvrtckEncoder {
    prev: Vec<u8>,
    width: usize,
    height: usize,
}

impl EvrtckEncoder {
    pub fn new(width: usize, height: usize) -> Self {
        Self { prev: vec![0u8; width * height * 4], width, height }
    }

    pub fn encode(&mut self, rgba: &[u8], frame_id: u32) -> Vec<u8> {
        debug_assert_eq!(rgba.len(), self.width * self.height * 4);
        let data = encode_frame(rgba, &self.prev, self.width, self.height, frame_id);
        self.prev.copy_from_slice(rgba);
        data
    }

    pub fn reset(&mut self) { self.prev.fill(0); }
    pub fn width(&self) -> usize { self.width }
    pub fn height(&self) -> usize { self.height }
}

// ── Thread-local encoder state ───────────────────────────────────────────────

struct EvrtckState {
    encoder: Option<EvrtckEncoder>,
    frame_id: u32,
}

impl EvrtckState {
    fn empty() -> Self { Self { encoder: None, frame_id: 0 } }
}

thread_local! {
    static EVRTCK: RefCell<EvrtckState> = RefCell::new(EvrtckState::empty());
}

// ── Public server API ────────────────────────────────────────────────────────

/// Try to encode a raw BGRA frame with EVRTCK and broadcast it to all
/// connected clients via the service pointer. Returns true if sent.
/// Replaces the normal VP8/VP9 encode path for this frame.
pub fn try_encode_and_send(
    raw: &[u8],
    width: usize,
    height: usize,
    display: i32,
    ms: i64,
    sp: &GenericService,
) -> bool {
    if raw.len() != width * height * 4 { return false; }

    EVRTCK.with(|state| {
        let mut s = state.borrow_mut();

        // (Re-)initialize encoder when dimensions change.
        let needs_init = s.encoder.as_ref()
            .map(|e| e.width() != width || e.height() != height)
            .unwrap_or(true);
        if needs_init {
            s.encoder = Some(EvrtckEncoder::new(width, height));
            s.frame_id = 0;
        }

        let enc = s.encoder.as_mut().unwrap();
        let frame_id = s.frame_id;
        s.frame_id = s.frame_id.wrapping_add(1);

        let payload = enc.encode(raw, frame_id);

        // Skip frames that would be larger than 500 KB (very high motion / full-screen video).
        // Those are better handled by VP8; EVRTCK resumes next frame.
        if payload.len() > 500 * 1024 {
            return false;
        }

        let mut evf = EncodedVideoFrame::new();
        evf.data = payload.into();
        evf.key = true;
        let mut evfs = EncodedVideoFrames::new();
        evfs.frames = vec![evf].into();
        let mut vf = VideoFrame::new();
        vf.set_av1s(evfs);
        vf.display = display;
        vf.timestamp = ms;
        let mut msg = Message::new();
        msg.set_video_frame(vf);

        let _ = sp.send_video_frame(msg);
        true
    })
}

// ── Core encoder ─────────────────────────────────────────────────────────────

fn encode_frame(rgba: &[u8], prev: &[u8], width: usize, height: usize, frame_id: u32) -> Vec<u8> {
    let tiles_x = tiles_in_dim(width);
    let tiles_y = tiles_in_dim(height);
    let tile_count = tiles_x * tiles_y;

    let mut dirty = vec![false; tile_count];
    let mut dirty_count = 0u32;
    for ty in 0..tiles_y {
        for tx in 0..tiles_x {
            if tile_is_dirty(rgba, prev, width, height, tx, ty) {
                dirty[ty * tiles_x + tx] = true;
                dirty_count += 1;
            }
        }
    }

    let map_bytes = (tile_count + 7) / 8;
    let mut tile_map = vec![0u8; map_bytes];
    for (i, &d) in dirty.iter().enumerate() {
        if d { tile_map[i / 8] |= 1 << (i % 8); }
    }

    let mut out = Vec::with_capacity(20 + map_bytes + (dirty_count as usize) * 64);
    out.extend_from_slice(MAGIC);
    out.push(VERSION);
    out.push(0u8);
    out.extend_from_slice(&frame_id.to_le_bytes());
    out.extend_from_slice(&(width as u32).to_le_bytes());
    out.extend_from_slice(&(height as u32).to_le_bytes());
    out.extend_from_slice(&(map_bytes as u16).to_le_bytes());
    out.extend_from_slice(&tile_map);

    for ty in 0..tiles_y {
        for tx in 0..tiles_x {
            if dirty[ty * tiles_x + tx] {
                encode_tile(&mut out, rgba, prev, width, height, tx, ty);
            }
        }
    }
    out
}

#[inline]
fn tiles_in_dim(px: usize) -> usize { (px + TILE_SIZE - 1) / TILE_SIZE }

fn tile_is_dirty(rgba: &[u8], prev: &[u8], width: usize, height: usize, tx: usize, ty: usize) -> bool {
    let x0 = tx * TILE_SIZE;
    let y0 = ty * TILE_SIZE;
    let x1 = (x0 + TILE_SIZE).min(width);
    let y1 = (y0 + TILE_SIZE).min(height);
    for y in y0..y1 {
        let base = (y * width + x0) * 4;
        let end = base + (x1 - x0) * 4;
        if rgba[base..end] != prev[base..end] { return true; }
    }
    false
}

fn encode_tile(out: &mut Vec<u8>, rgba: &[u8], prev: &[u8], width: usize, height: usize, tx: usize, ty: usize) {
    let x0 = tx * TILE_SIZE;
    let y0 = ty * TILE_SIZE;
    let x1 = (x0 + TILE_SIZE).min(width);
    let y1 = (y0 + TILE_SIZE).min(height);
    let tw = x1 - x0;
    let th = y1 - y0;
    let pixel_bytes = tw * th * 4;

    let mut tile = Vec::with_capacity(pixel_bytes);
    let mut tile_prev = Vec::with_capacity(pixel_bytes);
    for y in y0..y1 {
        let base = (y * width + x0) * 4;
        tile.extend_from_slice(&rgba[base..base + tw * 4]);
        tile_prev.extend_from_slice(&prev[base..base + tw * 4]);
    }

    if let Some(color) = try_solid(&tile) {
        out.push(MODE_SOLID);
        out.extend_from_slice(&color);
        return;
    }

    let mut delta = vec![0u8; pixel_bytes];
    for i in 0..pixel_bytes { delta[i] = tile[i] ^ tile_prev[i]; }
    let compressed = zrle_encode(&delta);
    out.push(MODE_DELTA);
    out.extend_from_slice(&(compressed.len() as u32).to_le_bytes());
    out.extend_from_slice(&compressed);
}

fn try_solid(tile: &[u8]) -> Option<[u8; 4]> {
    let mut chunks = tile.chunks_exact(4);
    let first = chunks.next()?;
    let color = [first[0], first[1], first[2], first[3]];
    if chunks.all(|c| c == color) { Some(color) } else { None }
}

// ── ZRLE ─────────────────────────────────────────────────────────────────────

fn zrle_encode(src: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(src.len() / 8 + 16);
    let mut i = 0;
    while i < src.len() {
        let z_start = i;
        while i < src.len() && src[i] == 0 { i += 1; }
        let zeros = i - z_start;
        if zeros >= 4 || (zeros > 0 && i == src.len()) {
            let mut rem = zeros;
            while rem > 0 {
                let n = rem.min(65535) as u16;
                out.push(0x00);
                out.extend_from_slice(&n.to_le_bytes());
                rem -= n as usize;
            }
            continue;
        }
        i = z_start;
        let lit_start = i;
        loop {
            if i >= src.len() { break; }
            if src[i] == 0 {
                let mut z = 0;
                while i + z < src.len() && src[i + z] == 0 { z += 1; }
                if z >= 4 { break; }
            }
            i += 1;
        }
        let lit_len = i - lit_start;
        if lit_len > 0 {
            let mut j = 0;
            while j < lit_len {
                let n = (lit_len - j).min(65535) as u16;
                out.push(0x01);
                out.extend_from_slice(&n.to_le_bytes());
                out.extend_from_slice(&src[lit_start + j..lit_start + j + n as usize]);
                j += n as usize;
            }
        }
    }
    out
}
