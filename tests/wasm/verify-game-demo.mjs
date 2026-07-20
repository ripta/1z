// Verifies the browser game platform's demo (examples/wasm-game/) against the real
// wasm32-freestanding artifact, headless via Node's WebAssembly API. Not a browser test: it
// exercises the same onez_wasm_eval/present-frame/framebuffer plumbing repl.js and demo.js use,
// without a DOM or a canvas.
//
// Run via `make wasm-game-verify` (builds the wasm artifact first). Not part of `make test`:
// the "run-frame executes repeatedly without exhausting memory" case currently fails against
// the real wasm build -- see
// spec/bugs/20260720-wasm-fixedbufferallocator-repeated-call-exhaustion.md. The other cases
// pass and guard against regressions in the parts that already work.

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
  assert.equal(status, ONEZ_EVAL_COMPLETE, () => 'demo-game.1z failed to evaluate: ' + onez.lastError())
})

test('run-frame executes repeatedly without exhausting the wasm heap', async (t) => {
  const onez = await instantiate()
  const gameSource = readFileSync(gameSourcePath, 'utf8')
  assert.equal(onez.evalSource(gameSource), ONEZ_EVAL_COMPLETE, () => 'setup failed: ' + onez.lastError())

  const frameCount = 5
  for (let frame = 0; frame < frameCount; frame++) {
    const status = onez.evalSource('run-frame')
    if (status === ONEZ_EVAL_ERROR) {
      t.diagnostic(
        'run-frame failed on frame ' + frame + ': ' + onez.lastError() +
        ' -- see spec/bugs/20260720-wasm-fixedbufferallocator-repeated-call-exhaustion.md'
      )
    }
    assert.equal(status, ONEZ_EVAL_COMPLETE, () => 'run-frame failed on frame ' + frame + ': ' + onez.lastError())
  }

  assert.ok(
    onez.presentCount >= frameCount,
    'present-frame should fire at least once per run-frame call, fired ' + onez.presentCount + ' times for ' + frameCount + ' frames'
  )
})
