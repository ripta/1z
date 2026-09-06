// Times a minesweeper reset against the real wasm32-freestanding artifact, headless via Node's
// WebAssembly API. The sibling bench_minesweeper.1z answers the same question under the native
// interpreter; this one answers it in the tier the player actually runs.
//
// A reset is one frame: the update tick that handles the face press calls (new-game), and the
// draw that follows repaints the whole canvas. So the frame containing the press carries the
// entire cost, and timing that one onez_wasm_eval('run-frame') call is the number a player
// waits out.
//
// Run with `node tests/wasm/bench-minesweeper.mjs` after `make wasm`. Not part of `make test`.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const wasmPath = path.join(repoRoot, 'examples', 'wasm-minesweeper', '1z.wasm')
const gameSourcePath = path.join(repoRoot, 'examples', 'wasm-minesweeper', 'minesweeper.1z')

const ONEZ_EVAL_COMPLETE = 0

// Board geometry at the Beginner preset minesweeper.1z loads on, mirroring verify-minesweeper.mjs.
const CELL_PX = 8
const BOARD_COLS = 9
const BOARD_PX_X = 92
const BOARD_PX_Y = 88
const HUD_HEIGHT = 24
const FACE_PX = 13
const HUD_STRIP_PX_Y = BOARD_PX_Y - HUD_HEIGHT
const FACE_PX_X = BOARD_PX_X + Math.floor((BOARD_COLS * CELL_PX - FACE_PX) / 2)
const FACE_PX_Y = HUD_STRIP_PX_Y + Math.floor((HUD_HEIGHT - FACE_PX) / 2)

// The mouse buffer's byte layout, the same private contract host.js mirrors.
const MOUSE = { WRITE: 6, RING: 16, CAPACITY: 32, SLOT: 8 }

function readCString(memory, ptr) {
  const bytes = new Uint8Array(memory.buffer)
  let end = ptr
  while (bytes[end] !== 0) end++
  return new TextDecoder().decode(bytes.subarray(ptr, end))
}

async function instantiate() {
  const bytes = readFileSync(wasmPath)
  let memory = null

  const imports = {
    env: {
      onez_host_monotonic_now_ns: () => BigInt(Math.round(performance.now() * 1e6)),
      onez_host_realtime_now_ms: () => BigInt(Date.now()),
      onez_host_write_output: () => {},
      onez_host_present: () => {},
      onez_host_load_sample: () => 0,
      onez_host_play_sample: () => {},
    },
  }

  const { instance } = await WebAssembly.instantiate(bytes, imports)
  const exports = instance.exports
  memory = exports.memory

  const handle = exports.onez_init()
  if (!handle) throw new Error('onez_init returned a null handle')
  exports.onez_wasm_use_host_output(handle)

  function evalSource(source) {
    const inputPtr = exports.onez_wasm_input_ptr()
    const inputCapacity = exports.onez_wasm_input_capacity()
    const encoded = new TextEncoder().encode(source)
    if (encoded.length > inputCapacity) throw new Error('source exceeds the wasm input buffer capacity')
    new Uint8Array(memory.buffer, inputPtr, inputCapacity).set(encoded)
    const status = exports.onez_wasm_eval(handle, inputPtr, encoded.length)
    if (status !== ONEZ_EVAL_COMPLETE) {
      const errPtr = exports.onez_last_error(handle)
      throw new Error('eval failed: ' + (errPtr ? readCString(memory, errPtr) : 'unknown error'))
    }
    return status
  }

  // Appends one press slot at the write index, the way host.js does, with inside set.
  function pushPress(button, x, y) {
    const view = new DataView(memory.buffer, exports.onez_wasm_mouse_ptr(), exports.onez_wasm_mouse_len())
    const write = view.getUint8(MOUSE.WRITE)
    const base = MOUSE.RING + (write % MOUSE.CAPACITY) * MOUSE.SLOT
    view.setUint8(base, button)
    view.setUint8(base + 1, 1)
    view.setUint8(base + 2, 1)
    view.setUint8(base + 3, 0)
    view.setUint16(base + 4, x, true)
    view.setUint16(base + 6, y, true)
    view.setUint8(MOUSE.WRITE, (write + 1) & 0xff)
  }

  return { evalSource, pushPress }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function time(label, fn) {
  const started = performance.now()
  fn()
  const ms = performance.now() - started
  console.log(label.padEnd(34) + ms.toFixed(1).padStart(9) + ' ms')
  return ms
}

// run-frame only runs update ticks as real time accrues on the fixed 60 Hz timestep, so a frame
// that must tick waits out at least one full interval first.
async function frame(onez, label) {
  await sleep(20)
  return time(label, () => onez.evalSource('run-frame'))
}

const onez = await instantiate()

time('boot (parse + init)', () => onez.evalSource(readFileSync(gameSourcePath, 'utf8')))
await frame(onez, 'first frame (full repaint)')
await frame(onez, 'steady frame (no repaint)')
await frame(onez, 'steady frame (no repaint)')

// The press lands in the same frame that repaints from it, so this one call is the whole reset.
onez.pushPress(0, FACE_PX_X + Math.floor(FACE_PX / 2), FACE_PX_Y + Math.floor(FACE_PX / 2))
await frame(onez, 'reset frame (face press)')

await frame(onez, 'steady frame (no repaint)')

// The first board press builds all four sound samples before it reveals anything.
onez.pushPress(0, BOARD_PX_X + 3, BOARD_PX_Y + 3)
await frame(onez, 'first board press (+ sounds)')

onez.pushPress(0, BOARD_PX_X + CELL_PX * 8 + 3, BOARD_PX_Y + CELL_PX * 8 + 3)
await frame(onez, 'later board press (no sounds)')

// Decompose the repaint in this tier rather than extrapolating the native ratios. A later eval
// cannot reach minesweeper's private words, so it imports the drawing library itself and drives
// the same public words the repaint runs.
console.log('')
onez.evalSource('use "game" ; use "bytes" ; use "ranges" ; use "sequences" ;')

time('clear-background (57344 px)', () => onez.evalSource('8 8 24 255 <color> clear-background'))
time('full-canvas rectangle', () => onez.evalSource('0 0 256 224 8 8 24 255 <color> draw-rectangle'))
time('board-sized rectangle (72x72)', () => onez.evalSource('92 88 72 72 8 8 24 255 <color> draw-rectangle'))
time('iterate 57344, no write', () => onez.evalSource('57344 iota >iterator [ drop ] #each'))

// What the 81 cell blits cost on their own, against a sprite built once. The reset's remainder
// past clear-background and the HUD is this plus the per-cell sprite rebuild (draw-cell) calls
// covered-sprite, and a const word is re-evaluated on every call.
onez.evalSource('bench-sprite: 7 7 7 7 * 4 * bytes-alloc <sprite> ;')
time('blit 7x7 x81 (sprite hoisted)', () => onez.evalSource('81 [ 0 0 bench-sprite blit-sprite ] times'))
