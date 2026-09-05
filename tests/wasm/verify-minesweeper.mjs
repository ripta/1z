// Verifies minesweeper (examples/wasm-minesweeper/) against the real wasm32-freestanding
// artifact, headless via Node's WebAssembly API, mirroring verify-snake.mjs's structure.
//
// The game's state words are private to minesweeper.1z's own file scope, so later eval calls
// cannot inspect them; every assertion here reads the framebuffer instead, which is also the
// contract a player actually sees. Clicks are appended to the mouse ring the way host.js does.
//
// Run via `make wasm-minesweeper-verify` (builds the wasm artifact first). Not part of `make test`.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const wasmPath = path.join(repoRoot, 'examples', 'wasm-minesweeper', '1z.wasm')
const gameSourcePath = path.join(repoRoot, 'examples', 'wasm-minesweeper', 'minesweeper.1z')

const ONEZ_EVAL_COMPLETE = 0

// The palette minesweeper.1z draws with, as [r, g, b] triples.
const PAGE_COLOR = [8, 8, 24]
const COVERED_COLOR = [192, 192, 192]
const BEVEL_LIGHT = [255, 255, 255]
const BEVEL_DARK = [112, 112, 112]
const REVEALED_COLOR = [168, 168, 168]
const FLAG_COLOR = [255, 0, 0]
const HUD_PANEL_COLOR = [0, 0, 0]
const HUD_DIGIT_COLOR = [255, 0, 0]
const FACE_COLOR = [255, 216, 0]

// Board geometry, matching minesweeper.1z's constants at the Beginner preset it loads on: 9x9
// cells of 8px, the block of HUD strip plus board centered on the canvas, so the board's
// origin is (92, 88). A cell fills 7x7 of its pitch; its center is 3 pixels in.
const CELL_PX = 8
const BOARD_COLS = 9
const BOARD_PX_X = 92
const BOARD_PX_Y = 88
const CANVAS_WIDTH = 256

// The HUD strip is the 24 rows above the board: a 24x8 mine-counter panel at the board's left
// edge, a 24x8 timer panel at its right, and the 13x13 face button centered between them.
const HUD_HEIGHT = 24
const HUD_PANEL_WIDTH = 24
const HUD_PANEL_HEIGHT = 8
const FACE_PX = 13
const HUD_STRIP_PX_Y = BOARD_PX_Y - HUD_HEIGHT
const HUD_PANEL_PX_Y = HUD_STRIP_PX_Y + (HUD_HEIGHT - HUD_PANEL_HEIGHT) / 2
const HUD_MINES_PX_X = BOARD_PX_X
const FACE_PX_X = BOARD_PX_X + Math.floor((BOARD_COLS * CELL_PX - FACE_PX) / 2)
const FACE_PX_Y = HUD_STRIP_PX_Y + Math.floor((HUD_HEIGHT - FACE_PX) / 2)

// The mouse buffer's byte layout, the same private contract host.js mirrors.
const MOUSE = { WRITE: 6, READ: 7, RING: 16, CAPACITY: 32, SLOT: 8 }

function readCString(memory, ptr) {
  const bytes = new Uint8Array(memory.buffer)
  let end = ptr
  while (bytes[end] !== 0) end++
  return new TextDecoder().decode(bytes.subarray(ptr, end))
}

// One fresh wasm instance per call, as in verify-snake.mjs: onez_init has no
// teardown-and-reinit story on the freestanding allocator.
async function instantiate() {
  const bytes = readFileSync(wasmPath)
  let memory = null
  let presentCount = 0

  const imports = {
    env: {
      onez_host_monotonic_now_ns: () => BigInt(Math.round(performance.now() * 1e6)),
      onez_host_realtime_now_ms: () => BigInt(Date.now()),
      onez_host_write_output: () => {},
      onez_host_present: () => {
        presentCount++
      },
      onez_host_load_sample: () => 0,
      onez_host_play_sample: () => {},
    },
  }

  const { instance } = await WebAssembly.instantiate(bytes, imports)
  const exports = instance.exports
  memory = exports.memory

  const handle = exports.onez_init()
  assert.ok(handle, 'onez_init returned a null handle')
  exports.onez_wasm_use_host_output(handle)

  function evalSource(source) {
    const inputPtr = exports.onez_wasm_input_ptr()
    const inputCapacity = exports.onez_wasm_input_capacity()
    const encoded = new TextEncoder().encode(source)
    assert.ok(encoded.length <= inputCapacity, 'source exceeds the wasm input buffer capacity')
    new Uint8Array(memory.buffer, inputPtr, inputCapacity).set(encoded)
    return exports.onez_wasm_eval(handle, inputPtr, encoded.length)
  }

  function lastError() {
    const errPtr = exports.onez_last_error(handle)
    return errPtr ? readCString(memory, errPtr) : 'unknown error'
  }

  // One pixel as an [r, g, b] triple, read fresh from memory.buffer on every call since
  // interpreted frames can grow wasm memory.
  function pixelAt(x, y) {
    const ptr = exports.onez_wasm_framebuffer_ptr()
    const offset = (y * CANVAS_WIDTH + x) * 4
    const pixels = new Uint8Array(memory.buffer, ptr, exports.onez_wasm_framebuffer_len())
    return [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
  }

  // The mouse buffer, viewed fresh for the same reason.
  function mouseView() {
    return new DataView(memory.buffer, exports.onez_wasm_mouse_ptr(), exports.onez_wasm_mouse_len())
  }

  // Appends one press slot at the write index, the way host.js does, with inside set.
  function pushPress(button, x, y) {
    const view = mouseView()
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

  return {
    exports,
    get memory() {
      return memory
    },
    get presentCount() {
      return presentCount
    },
    evalSource,
    lastError,
    pixelAt,
    mouseView,
    pushPress,
  }
}

const cellOrigin = (col, row) => ({ x: BOARD_PX_X + col * CELL_PX, y: BOARD_PX_Y + row * CELL_PX })
const cellCenter = (col, row) => ({ x: BOARD_PX_X + col * CELL_PX + 3, y: BOARD_PX_Y + row * CELL_PX + 3 })

// Count pixels matching `color` within a w-by-h box at (x, y).
function boxColorCount(onez, x, y, w, h, color) {
  let count = 0
  for (let dy = 0; dy < h; dy++) {
    for (let dx = 0; dx < w; dx++) {
      const [r, g, b] = onez.pixelAt(x + dx, y + dy)
      if (r === color[0] && g === color[1] && b === color[2]) count++
    }
  }
  return count
}

// Count pixels matching `color` within a cell's 7x7 area.
function cellColorCount(onez, col, row, color) {
  const origin = cellOrigin(col, row)
  return boxColorCount(onez, origin.x, origin.y, 7, 7, color)
}

// Count pixels matching `color` within the mine-counter panel.
function minePanelColorCount(onez, color) {
  return boxColorCount(onez, HUD_MINES_PX_X, HUD_PANEL_PX_Y, HUD_PANEL_WIDTH, HUD_PANEL_HEIGHT, color)
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function bootMinesweeper(onez) {
  const gameSource = readFileSync(gameSourcePath, 'utf8')
  const status = onez.evalSource(gameSource)
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'minesweeper.1z failed to evaluate: ' + onez.lastError())
}

// run-frame only runs update ticks as real time accrues on the fixed 60 Hz timestep, so
// each frame that must tick waits out at least one full interval first.
async function tickFrame(onez) {
  await sleep(20)
  const status = onez.evalSource('run-frame')
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'run-frame failed: ' + onez.lastError())
}

test('minesweeper.1z evaluates and registers its callbacks via start-game', async () => {
  const onez = await instantiate()
  await bootMinesweeper(onez)
})

test('the first frame paints the covered board on the page background', async () => {
  const onez = await instantiate()
  await bootMinesweeper(onez)

  await tickFrame(onez)
  assert.ok(onez.presentCount >= 1, 'present-frame should fire once per run-frame call')

  const center = cellCenter(4, 4)
  assert.deepEqual(onez.pixelAt(center.x, center.y), COVERED_COLOR, 'a cell center carries the covered fill')
  assert.deepEqual(onez.pixelAt(BOARD_PX_X, BOARD_PX_Y), BEVEL_LIGHT, 'the board origin is the first cell\'s light bevel')
  assert.deepEqual(onez.pixelAt(BOARD_PX_X + 6, BOARD_PX_Y + 6), BEVEL_DARK, 'the first cell ends in its dark bevel')
  assert.deepEqual(onez.pixelAt(BOARD_PX_X + 7, BOARD_PX_Y), PAGE_COLOR, 'the gutter keeps the page background')
  assert.deepEqual(onez.pixelAt(10, 10), PAGE_COLOR, 'the canvas outside the board is the page background')

  const lastOrigin = cellOrigin(BOARD_COLS - 1, BOARD_COLS - 1)
  assert.deepEqual(onez.pixelAt(lastOrigin.x + 3, lastOrigin.y + 3), COVERED_COLOR, 'the last cell is painted too')
})

test('the first frame paints the HUD above the board', async () => {
  const onez = await instantiate()
  await bootMinesweeper(onez)
  await tickFrame(onez)

  assert.ok(minePanelColorCount(onez, HUD_PANEL_COLOR) > 0, 'the mine counter sits on a black panel')
  assert.ok(minePanelColorCount(onez, HUD_DIGIT_COLOR) > 0, 'the mine counter draws red digits')
  assert.deepEqual(
    onez.pixelAt(FACE_PX_X + 6, FACE_PX_Y + 6),
    FACE_COLOR,
    'the face button paints its yellow disc',
  )
  assert.deepEqual(onez.pixelAt(FACE_PX_X - 1, FACE_PX_Y), PAGE_COLOR, 'the strip beside the face stays clear')
})

test('clicking the face starts a new game', async () => {
  const onez = await instantiate()
  await bootMinesweeper(onez)
  await tickFrame(onez)

  // Open a region, so a restart has something visible to undo.
  const clickAt = cellCenter(4, 4)
  onez.pushPress(0, clickAt.x, clickAt.y)
  await tickFrame(onez)
  assert.deepEqual(onez.pixelAt(clickAt.x, clickAt.y), REVEALED_COLOR, 'the clicked cell is revealed')

  onez.pushPress(0, FACE_PX_X + 6, FACE_PX_Y + 6)
  await tickFrame(onez)
  assert.deepEqual(onez.pixelAt(clickAt.x, clickAt.y), COVERED_COLOR, 'the restart covers the board again')
  assert.equal(cellColorCount(onez, 4, 4, COVERED_COLOR), 25, 'the cell is a full covered cell again')
})

test('a right press flags a cell and a left press opens a region, observable in the framebuffer', async () => {
  const onez = await instantiate()
  await bootMinesweeper(onez)
  await tickFrame(onez)

  // The flag goes down first, while every cell is still covered: after the opening cascade a
  // time-seeded board may already have revealed the flag's target cell.
  const flagAt = cellCenter(0, 8)
  onez.pushPress(2, flagAt.x, flagAt.y)
  await tickFrame(onez)
  assert.equal(onez.mouseView().getUint8(MOUSE.READ), 1, 'the read index should have caught up to the write index')
  assert.equal(cellColorCount(onez, 0, 8, FLAG_COLOR), 5, 'the flag sprite paints its red cloth in the flagged cell')
  assert.equal(cellColorCount(onez, 4, 4, FLAG_COLOR), 0, 'no other cell carries a flag')

  // The first click is always a zero, so its own cell and all eight neighbors end up revealed
  // whatever the seed; the cascade spreads four cells per tick, so the ring takes a frame or
  // two of catch-up ticks to finish.
  const clickAt = cellCenter(4, 4)
  onez.pushPress(0, clickAt.x, clickAt.y)
  await tickFrame(onez)
  assert.equal(onez.mouseView().getUint8(MOUSE.READ), 2, 'the second slot was drained')
  assert.deepEqual(onez.pixelAt(clickAt.x, clickAt.y), REVEALED_COLOR, 'the clicked cell is revealed on its own frame')

  await tickFrame(onez)
  await tickFrame(onez)
  for (let row = 3; row <= 5; row++) {
    for (let col = 3; col <= 5; col++) {
      // A numbered neighbor can paint its digit over the center pixel.
      assert.ok(cellColorCount(onez, col, row, REVEALED_COLOR) > 0, 'neighbor (' + col + ', ' + row + ') has revealed fill')
      assert.equal(cellColorCount(onez, col, row, COVERED_COLOR), 0, 'neighbor (' + col + ', ' + row + ') is uncovered')
    }
  }
  assert.equal(cellColorCount(onez, 0, 8, FLAG_COLOR), 5, 'the flag survives the opening cascade')
})

test('run-frame executes repeatedly without exhausting the wasm heap', async () => {
  const onez = await instantiate()
  await bootMinesweeper(onez)

  const frameCount = 10
  for (let frame = 0; frame < frameCount; frame++) {
    await tickFrame(onez)
  }
  assert.ok(onez.presentCount >= frameCount, 'present-frame fired ' + onez.presentCount + ' times for ' + frameCount + ' frames')
})
