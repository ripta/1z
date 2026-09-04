// Verifies the browser game platform's demo (examples/wasm-game/) against the real
// wasm32-freestanding artifact, headless via Node's WebAssembly API. Not a browser test: it
// exercises the same onez_wasm_eval/present-frame/framebuffer plumbing repl.js and demo.js use,
// without a DOM or a canvas.
//
// Run via `make wasm-game-verify` (builds the wasm artifact first). Not part of `make test`,
// since it needs the wasm build step rather than any remaining known failure.

import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')
const wasmPath = path.join(repoRoot, 'examples', 'wasm-game', '1z.wasm')
const gameSourcePath = path.join(repoRoot, 'examples', 'wasm-game', 'demo-game.1z')

const ONEZ_EVAL_COMPLETE = 0
const ONEZ_EVAL_ERROR = 2

function readCString(memory, ptr) {
  const bytes = new Uint8Array(memory.buffer)
  let end = ptr
  while (bytes[end] !== 0) end++
  return new TextDecoder().decode(bytes.subarray(ptr, end))
}

// One fresh wasm instance per call: onez_init has no reset/teardown-and-reinit story on the
// static-heap freestanding allocator, so each test case gets its own instance rather than
// sharing state across test cases.
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
      // Node has no Web Audio, so these record what crossed the boundary instead of playing
      // anything. The PCM bytes are snapshotted here rather than at the assertion, since the 1z
      // byte array they came from may already be freed by then.
      onez_host_load_sample: (ptr, len, channels, rate) => {
        loadedSamples.push({
          channels,
          rate,
          bytes: Array.from(new Uint8Array(memory.buffer, ptr, len)),
        })
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

  return {
    exports,
    get memory() {
      return memory
    },
    get presentCount() {
      return presentCount
    },
    get loadedSamples() {
      return loadedSamples
    },
    get playedSamples() {
      return playedSamples
    },
    evalSource,
    lastError,
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

// run-frame only runs update ticks as real time accrues on its fixed 60 Hz timestep, so each
// frame that must tick waits out at least one full interval first.
async function tickFrame(onez) {
  await sleep(20)
  const status = onez.evalSource('run-frame')
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'run-frame failed: ' + onez.lastError())
}

// Asserts via throw/if on core prelude words rather than the testing module's assert=, since
// the game source's own use "game" already imported the words under test into the shared
// top-level scope this eval call resumes, so no use is needed here at all.
function expectTrue(onez, source) {
  const status = onez.evalSource(source + ' not [ f "expected true" EInvalidArgument make-error throw ] when')
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'expected true: ' + source + ': ' + onez.lastError())
}

function expectFalse(onez, source) {
  const status = onez.evalSource(source + ' [ f "expected false" EInvalidArgument make-error throw ] when')
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'expected false: ' + source + ': ' + onez.lastError())
}

test('wasm module loads and initializes', async () => {
  const onez = await instantiate()
  const ptr = onez.exports.onez_wasm_framebuffer_ptr()
  const len = onez.exports.onez_wasm_framebuffer_len()
  assert.equal(len, 256 * 224 * 4, 'framebuffer length does not match the settled 256x224 RGBA8888 resolution')
  assert.ok(ptr > 0, 'framebuffer pointer should be non-null')
})

test('use "testing" loads as the first statement of a fresh session', async () => {
  // The testing module's reporter selection reads `environ`, which does not exist on
  // freestanding builds; its parse-time target gate must keep the module loadable here.
  const onez = await instantiate()
  const status = onez.evalSource('use "testing" ;')
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'use "testing" failed: ' + onez.lastError())

  const assertStatus = onez.evalSource('4 2 2 + "two plus two" assert=')
  assert.equal(assertStatus, ONEZ_EVAL_COMPLETE, 'assert= failed: ' + onez.lastError())
})

test('demo-game.1z evaluates and registers init/update/draw via start-game', async () => {
  const onez = await instantiate()
  const gameSource = readFileSync(gameSourcePath, 'utf8')
  const status = onez.evalSource(gameSource)
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'demo-game.1z failed to evaluate: ' + onez.lastError())
})

test('key-down? reflects keyboard bytes written the way JS would write them', async () => {
  const onez = await instantiate()
  const gameSource = readFileSync(gameSourcePath, 'utf8')
  assert.equal(onez.evalSource(gameSource), ONEZ_EVAL_COMPLETE, 'setup failed: ' + onez.lastError())

  const keyboardPtr = onez.exports.onez_wasm_keyboard_ptr()
  const keyboardLen = onez.exports.onez_wasm_keyboard_len()
  assert.equal(keyboardLen, 48, 'keyboard buffer length does not match the settled 48-key vocabulary')

  // Index 0 is arrow-up in lib/game/input.1z's key-index table (see examples/wasm-game/host.js's
  // KEY_INDEX for the JS side of this same private contract).
  const ARROW_UP_INDEX = 0
  const keyboard = new Uint8Array(onez.memory.buffer, keyboardPtr, keyboardLen)

  expectFalse(onez, 'arrow-up: key-down?')

  keyboard[ARROW_UP_INDEX] = 1
  expectTrue(onez, 'arrow-up: key-down?')

  keyboard[ARROW_UP_INDEX] = 0
  expectFalse(onez, 'arrow-up: key-down?')
})

test('mouse pointer state written the way JS would write it reads back through game/input', async () => {
  const onez = await instantiate()
  const gameSource = readFileSync(gameSourcePath, 'utf8')
  assert.equal(onez.evalSource(gameSource), ONEZ_EVAL_COMPLETE, 'setup failed: ' + onez.lastError())

  const mousePtr = onez.exports.onez_wasm_mouse_ptr()
  const mouseLen = onez.exports.onez_wasm_mouse_len()
  assert.equal(mouseLen, 272, 'mouse buffer length does not match the 16-byte header plus 32 8-byte slots')

  // Header offsets follow lib/game/input.1z's private layout table (see examples/wasm-game/
  // host.js's MOUSE for the JS side of this same private contract): x at 0, y at 2, inside at
  // 4, the held bitmap at 5 with bit 0 left, bit 1 middle, bit 2 right.
  const view = new DataView(onez.memory.buffer, mousePtr, mouseLen)
  view.setUint16(0, 300, true)
  view.setUint16(2, 40, true)
  view.setUint8(4, 1)
  view.setUint8(5, 0b101)

  expectTrue(onez, 'mouse-position 40 = swap 300 = and')
  expectTrue(onez, 'mouse-inside?')
  expectTrue(onez, 'left: mouse-down?')
  expectFalse(onez, 'middle: mouse-down?')
  expectTrue(onez, 'right: mouse-down?')
  expectTrue(onez, 'mouse-dropped-events 0 =')
})

test('a left press in the ring reaches update once and moves the demo player square', async () => {
  const onez = await instantiate()
  const gameSource = readFileSync(gameSourcePath, 'utf8')
  assert.equal(onez.evalSource(gameSource), ONEZ_EVAL_COMPLETE, 'setup failed: ' + onez.lastError())

  const mousePtr = onez.exports.onez_wasm_mouse_ptr()
  const mouseLen = onez.exports.onez_wasm_mouse_len()
  const framebufferPtr = onez.exports.onez_wasm_framebuffer_ptr()
  const framebufferLen = onez.exports.onez_wasm_framebuffer_len()

  // One left press at (200, 40) appended the way host.js does: slot 0 at offset 16 holds the
  // button id, kind (1 press), inside, a reserved byte, then x and y; the write index at
  // offset 6 advances to 1. The view is rebuilt after the frame for the same reason the
  // keyboard test rebuilds its view.
  const mouse = () => new DataView(onez.memory.buffer, mousePtr, mouseLen)
  const slot = mouse()
  slot.setUint8(16, 0)
  slot.setUint8(17, 1)
  slot.setUint8(18, 1)
  slot.setUint16(20, 200, true)
  slot.setUint16(22, 40, true)
  slot.setUint8(6, 1)

  await tickFrame(onez)
  assert.equal(mouse().getUint8(7), 1, 'the read index should have caught up to the write index')

  // demo-update moves the player square's top-left corner to the click point, so after the
  // frame's draw the framebuffer pixel there carries the player color.
  const pixelAt = (x, y) => {
    const offset = (y * 256 + x) * 4
    return Array.from(new Uint8Array(onez.memory.buffer, framebufferPtr, framebufferLen).subarray(offset, offset + 4))
  }
  assert.deepEqual(pixelAt(200, 40), [220, 90, 90, 255], 'the player square should sit at the click point')

  // A second frame drains an empty ring and leaves the square where the click put it.
  await tickFrame(onez)
  assert.deepEqual(pixelAt(200, 40), [220, 90, 90, 255], 'an already-drained click must not be replayed or undone')
  expectTrue(onez, 'mouse-events #len 0 =')
})

test('audio host words carry PCM bytes out and a sample handle back', async () => {
  const onez = await instantiate()

  // Two mono frames of 32-bit float PCM, 1.0 then -1.0, little-endian. The host words are
  // registered by onez_init in the global dictionary, so no game source has to load first.
  const pcm = [0x00, 0x00, 0x80, 0x3f, 0x00, 0x00, 0x80, 0xbf]
  const literal = 'B{ ' + pcm.map((byte) => '0x' + byte.toString(16).padStart(2, '0')).join(' ') + ' }'
  const status = onez.evalSource(literal + ' 1 8000 (wasm-load-sample) (wasm-play-sample)')
  assert.equal(status, ONEZ_EVAL_COMPLETE, 'load and play failed: ' + onez.lastError())

  assert.equal(onez.loadedSamples.length, 1, 'expected exactly one load call')
  assert.deepEqual(onez.loadedSamples[0].bytes, pcm, 'the host saw different PCM bytes than 1z pushed')
  assert.equal(onez.loadedSamples[0].channels, 1)
  assert.equal(onez.loadedSamples[0].rate, 8000)

  assert.deepEqual(onez.playedSamples, [0], 'the play call should carry back the handle the load call returned')
})

test('the demo game synthesizes a beep at init and plays it once per space press', async () => {
  const onez = await instantiate()
  const gameSource = readFileSync(gameSourcePath, 'utf8')
  assert.equal(onez.evalSource(gameSource), ONEZ_EVAL_COMPLETE, 'setup failed: ' + onez.lastError())

  assert.equal(onez.loadedSamples.length, 1, 'demo-init should load exactly one sample')
  assert.equal(onez.loadedSamples[0].channels, 1, 'the beep is mono')
  assert.equal(onez.loadedSamples[0].rate, 8000, 'the beep is 8000 Hz')
  assert.equal(onez.loadedSamples[0].bytes.length, 1200 * 4, 'the beep is 1200 frames of 32-bit float PCM')

  const pcm = new Float32Array(new Uint8Array(onez.loadedSamples[0].bytes).buffer)
  assert.equal(pcm[0], 0, 'the sine starts at zero phase')
  assert.notEqual(pcm[3], 0, 'the beep is not silence')

  const keyboardPtr = onez.exports.onez_wasm_keyboard_ptr()
  const keyboardLen = onez.exports.onez_wasm_keyboard_len()

  // Index 40 is space in lib/game/input.1z's key-index table, the same private contract the
  // key-down? test documents above.
  //
  // The view is rebuilt on every write, as host.js does: a memory.grow during the interpreted
  // draw frames detaches any cached view, so a poke through a stale one silently goes nowhere.
  const SPACE_INDEX = 40
  const setSpace = (down) => {
    new Uint8Array(onez.memory.buffer, keyboardPtr, keyboardLen)[SPACE_INDEX] = down ? 1 : 0
  }

  setSpace(true)
  await tickFrame(onez)
  assert.deepEqual(onez.playedSamples, [0], 'a space press plays the beep once, with the loaded handle')

  await tickFrame(onez)
  assert.deepEqual(onez.playedSamples, [0], 'a held space key does not re-trigger')

  setSpace(false)
  await tickFrame(onez)
  setSpace(true)
  await tickFrame(onez)
  assert.deepEqual(onez.playedSamples, [0, 0], 'a second press replays the sample')
})

test('run-frame executes repeatedly without exhausting the wasm heap', async () => {
  const onez = await instantiate()
  const gameSource = readFileSync(gameSourcePath, 'utf8')
  assert.equal(onez.evalSource(gameSource), ONEZ_EVAL_COMPLETE, 'setup failed: ' + onez.lastError())

  const frameCount = 5
  for (let frame = 0; frame < frameCount; frame++) {
    const status = onez.evalSource('run-frame')
    assert.equal(status, ONEZ_EVAL_COMPLETE, 'run-frame failed on frame ' + frame + ': ' + onez.lastError())
  }

  assert.ok(
    onez.presentCount >= frameCount,
    'present-frame should fire at least once per run-frame call, fired ' + onez.presentCount + ' times for ' + frameCount + ' frames'
  )
})
