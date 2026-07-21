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

  const imports = {
    env: {
      onez_host_monotonic_now_ns: () => BigInt(Math.round(performance.now() * 1e6)),
      onez_host_realtime_now_ms: () => BigInt(Date.now()),
      onez_host_write_output: () => {},
      onez_host_present: () => {
        presentCount++
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
    evalSource,
    lastError,
  }
}

test('wasm module loads and initializes', async () => {
  const onez = await instantiate()
  const ptr = onez.exports.onez_wasm_framebuffer_ptr()
  const len = onez.exports.onez_wasm_framebuffer_len()
  assert.equal(len, 256 * 224 * 4, 'framebuffer length does not match the settled 256x224 RGBA8888 resolution')
  assert.ok(ptr > 0, 'framebuffer pointer should be non-null')
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

  // Index 0 is arrow-up in lib/game/input.1z's key-index table (see examples/wasm-game/demo.js's
  // KEY_INDEX for the JS side of this same private contract).
  const ARROW_UP_INDEX = 0
  const keyboard = new Uint8Array(onez.memory.buffer, keyboardPtr, keyboardLen)

  // Asserts via throw/if on core prelude words rather than the testing module's assert=: `use
  // "testing"` does not currently load on this target, and demo-game.1z's own use "game" already
  // imported these words into the shared top-level scope this eval call resumes, so no use is
  // needed here at all.
  const expectDown = (source) => {
    const status = onez.evalSource(source + ' not [ f "expected key-down? true" EInvalidArgument make-error throw ] when')
    assert.equal(status, ONEZ_EVAL_COMPLETE, 'expected true: ' + source + ': ' + onez.lastError())
  }
  const expectUp = (source) => {
    const status = onez.evalSource(source + ' [ f "expected key-down? false" EInvalidArgument make-error throw ] when')
    assert.equal(status, ONEZ_EVAL_COMPLETE, 'expected false: ' + source + ': ' + onez.lastError())
  }

  expectUp('arrow-up: key-down?')

  keyboard[ARROW_UP_INDEX] = 1
  expectDown('arrow-up: key-down?')

  keyboard[ARROW_UP_INDEX] = 0
  expectUp('arrow-up: key-down?')
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
