// Verifies snake (examples/wasm-snake/) against the real wasm32-freestanding artifact,
// headless via Node's WebAssembly API, mirroring verify-game-demo.mjs's structure.
//
// The game's state words are private to snake.1z's own file scope, so later eval calls
// cannot inspect them; every assertion here reads the framebuffer instead, which is also
// the contract a player actually sees.
//
// Run via `make wasm-snake-verify` (builds the wasm artifact first). Not part of `make test`.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const wasmPath = path.join(repoRoot, 'examples', 'wasm-snake', '1z.wasm')
const gameSourcePath = path.join(repoRoot, 'examples', 'wasm-snake', 'snake.1z')

const ONEZ_EVAL_COMPLETE = 0

// The palette snake.1z draws with, as [r, g, b] triples.
const PAGE_COLOR = [8, 8, 24]
const BOARD_COLOR = [16, 16, 40]
const HEAD_COLOR = [96, 224, 96]
const FOOD_COLOR = [224, 64, 48]
const HUD_COLOR = [255, 255, 255]

// Board geometry, matching snake.1z's constants: 20x20 cells of 8px at x 0..160,
// vertically centered at y 32.
const CELL_PX = 8
const BOARD_PX_X = 0
const BOARD_PX_Y = 32
const CANVAS_WIDTH = 256

function readCString(memory, ptr) {
  const bytes = new Uint8Array(memory.buffer)
  let end = ptr
  while (bytes[end] !== 0) end++
  return new TextDecoder().decode(bytes.subarray(ptr, end))
}

// One fresh wasm instance per call, as in verify-game-demo.mjs: onez_init has no
// teardown-and-reinit story on the freestanding allocator.
async function instantiate() {
  const bytes = readFileSync(wasmPath)
  let memory = null
  let presentCount = 0
  const loadedSamples = []
  const playedSamples = []

  const imports = {
    env: {
      onez_host_monotonic_now_ns: () => BigInt(Math.round(performance.now() * 1e6)),
      onez_host_realtime_now_ms: () => BigInt(Date.now()),
      onez_host_write_output: () => {},
      onez_host_present: () => {
        presentCount++
      },
      onez_host_load_sample: (ptr, len, channels, rate) => {
        const bytesCopy = new Uint8Array(memory.buffer.slice(ptr, ptr + len))
        loadedSamples.push({ channels, rate, byteLength: bytesCopy.length })
        return loadedSamples.length - 1
      },
      onez_host_play_sample: (handle) => {
        playedSamples.push(handle)
      },
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

  // The center pixel of a board cell as an [r, g, b] triple, read fresh from
  // memory.buffer on every call since interpreted frames can grow wasm memory.
  function cellColor(col, row) {
    const ptr = exports.onez_wasm_framebuffer_ptr()
    const x = BOARD_PX_X + col * CELL_PX + CELL_PX / 2
    const y = BOARD_PX_Y + row * CELL_PX + CELL_PX / 2
    const offset = (y * CANVAS_WIDTH + x) * 4
    const pixels = new Uint8Array(memory.buffer, ptr, exports.onez_wasm_framebuffer_len())
    return [pixels[offset], pixels[offset + 1], pixels[offset + 2]]
  }

  return {
    exports,
    get memory() {
      return memory
    },
    get presentCount() {
      return presentCount
    },
    loadedSamples,
    playedSamples,
    evalSource,
    lastError,
    cellColor,
  }
}

// Count pixels matching `color` within the rectangle [x, x+w) x [y, y+h).
function countPixels(onez, color, x, y, w, h) {
  const ptr = onez.exports.onez_wasm_framebuffer_ptr()
  const pixels = new Uint8Array(onez.memory.buffer, ptr, onez.exports.onez_wasm_framebuffer_len())
  let count = 0
  for (let row = y; row < y + h; row++) {
    for (let col = x; col < x + w; col++) {
      const offset = (row * CANVAS_WIDTH + col) * 4
      if (pixels[offset] === color[0] && pixels[offset + 1] === color[1] && pixels[offset + 2] === color[2]) count++
    }
  }
  return count
}

// White pixels over the board region: zero during play, nonzero once the GAME OVER
// overlay is drawn.
function boardOverlayWhite(onez) {
  return countPixels(onez, HUD_COLOR, BOARD_PX_X, BOARD_PX_Y, 20 * CELL_PX, 20 * CELL_PX)
}

// White pixels in the sidebar text region the SCORE label and value land in.
function sidebarWhite(onez) {
  return countPixels(onez, HUD_COLOR, 168, BOARD_PX_Y, 80, 20)
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function bootSnake(onez) {
  const gameSource = readFileSync(gameSourcePath, 'utf8')
  const status = onez.evalSource(gameSource)
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'snake.1z failed to evaluate: ' + onez.lastError())
}

// run-frame only runs update ticks as real time accrues on the fixed 60 Hz timestep, so
// each frame that must tick waits out at least one full interval first.
async function tickFrame(onez) {
  await sleep(20)
  const status = onez.evalSource('run-frame')
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'run-frame failed: ' + onez.lastError())
}

// Every cell whose center matches `color`, as packed col,row pairs.
function findCells(onez, color) {
  const found = []
  for (let row = 0; row < 20; row++) {
    for (let col = 0; col < 20; col++) {
      const [r, g, b] = onez.cellColor(col, row)
      if (r === color[0] && g === color[1] && b === color[2]) found.push({ col, row })
    }
  }
  return found
}

test('snake.1z evaluates and registers its callbacks via start-game', async () => {
  const onez = await instantiate()
  await bootSnake(onez)
})

test('run-frame draws the board, snake, and food', async () => {
  const onez = await instantiate()
  await bootSnake(onez)

  await tickFrame(onez)
  assert.ok(onez.presentCount >= 1, 'present-frame should fire once per run-frame call')

  // The head starts at the board center, col 10 row 10, before the first move interval
  // elapses.
  assert.deepEqual(onez.cellColor(10, 10), HEAD_COLOR, 'the head cell is drawn in the head color')

  const food = findCells(onez, FOOD_COLOR)
  assert.equal(food.length, 1, 'exactly one food cell is drawn')

  // A sidebar pixel carries the page background; the board corner carries the board
  // background unless the random food happens to sit there.
  const ptr = onez.exports.onez_wasm_framebuffer_ptr()
  const pixels = new Uint8Array(onez.memory.buffer, ptr, onez.exports.onez_wasm_framebuffer_len())
  const sidebarOffset = (10 * CANVAS_WIDTH + 200) * 4
  assert.deepEqual(
    [pixels[sidebarOffset], pixels[sidebarOffset + 1], pixels[sidebarOffset + 2]],
    PAGE_COLOR,
    'the sidebar strip above the HUD text keeps the page background'
  )
  const corner = onez.cellColor(0, 0)
  assert.ok(
    JSON.stringify(corner) === JSON.stringify(BOARD_COLOR) || JSON.stringify(corner) === JSON.stringify(FOOD_COLOR),
    'an empty board cell carries the board background'
  )

  assert.ok(sidebarWhite(onez) > 0, 'the sidebar shows the score text in the HUD color')
  assert.equal(boardOverlayWhite(onez), 0, 'no overlay is drawn over the board during play')
})

test('death on the top wall shows GAME OVER and a keypress restarts', async () => {
  const onez = await instantiate()
  await bootSnake(onez)

  const keyboardPtr = onez.exports.onez_wasm_keyboard_ptr()
  const keyboardLen = onez.exports.onez_wasm_keyboard_len()
  const keyboard = () => new Uint8Array(onez.memory.buffer, keyboardPtr, keyboardLen)

  // Hold arrow-up (index 0): ten moves reach the top wall and the eleventh dies there.
  // Each interpreted frame takes seconds of real time, and run-frame banks that elapsed
  // time (capped per frame), so death arrives within a few dozen frames; the cap is a
  // hang guard, not an expected count.
  keyboard()[0] = 1
  let died = false
  for (let frame = 0; frame < 200; frame++) {
    await tickFrame(onez)
    if (boardOverlayWhite(onez) > 0) {
      died = true
      break
    }
  }
  assert.ok(died, 'steering into the top wall shows the GAME OVER overlay')
  assert.ok(sidebarWhite(onez) > 0, 'the sidebar still shows the final score')

  // Release the arrow, then press space to restart; the fresh snake redraws at the
  // board center before its first move interval elapses.
  keyboard()[0] = 0
  keyboard()[40] = 1
  await tickFrame(onez)
  await tickFrame(onez)
  assert.equal(boardOverlayWhite(onez), 0, 'the restart clears the GAME OVER overlay')
  assert.deepEqual(onez.cellColor(10, 10), HEAD_COLOR, 'the restart recenters the head')
})

test('an arrow-key poke steers the snake, observable in the framebuffer', async () => {
  const onez = await instantiate()
  await bootSnake(onez)

  const keyboardPtr = onez.exports.onez_wasm_keyboard_ptr()
  const keyboardLen = onez.exports.onez_wasm_keyboard_len()

  // Index 0 is arrow-up in lib/game/input.1z's key-index table. The view is rebuilt on
  // every write, since a memory.grow during interpreted frames detaches cached views.
  new Uint8Array(onez.memory.buffer, keyboardPtr, keyboardLen)[0] = 1

  // The starting pace is one move per 150ms; 16 ticked frames at >=20ms each cover at
  // least two moves.
  for (let frame = 0; frame < 16; frame++) {
    await tickFrame(onez)
  }

  const heads = findCells(onez, HEAD_COLOR)
  assert.equal(heads.length, 1, 'exactly one head cell is drawn')
  assert.equal(heads[0].col, 10, 'steering up keeps the head in its column')
  assert.ok(heads[0].row < 10, 'the head moved up from the starting row')
})

test('run-frame executes repeatedly without exhausting the wasm heap', async () => {
  const onez = await instantiate()
  await bootSnake(onez)

  const frameCount = 10
  for (let frame = 0; frame < frameCount; frame++) {
    await tickFrame(onez)
  }
  assert.ok(onez.presentCount >= frameCount, 'present-frame fired ' + onez.presentCount + ' times for ' + frameCount + ' frames')
})
