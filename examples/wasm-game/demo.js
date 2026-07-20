// Browser harness for the 1z game platform, compiled to wasm32-freestanding
// (src/capi_wasm.zig). No build step: loaded directly as an ES module by index.html.
//
// The frame-loop contract itself (the fixed timestep, the tick counter, the capped
// catch-up accumulator) lives entirely in lib/game/loop.1z's run-frame word. This
// harness is intentionally dumb: it calls run-frame once per requestAnimationFrame
// tick and otherwise only handles what only a browser can do -- loading the module,
// presenting the framebuffer, and sizing the canvas.

const ONEZ_EVAL_ERROR = 2

const canvasWidth = 256
const canvasHeight = 224

let memory = null
const canvas = document.getElementById('canvas')
const ctx2d = canvas.getContext('2d')
const statusEl = document.getElementById('status')

function setStatus(text, isError) {
  statusEl.textContent = text
  statusEl.className = isError ? 'error' : ''
}

// Snap the canvas's on-screen CSS size to the largest integer multiple of the base
// resolution that fits the viewport, so every source pixel maps to a whole number of
// screen pixels (no shimmer from a fractional scale). Recomputed on resize.
function resizeCanvas() {
  const availableWidth = Math.max(window.innerWidth - 32, canvasWidth)
  const availableHeight = Math.max(window.innerHeight - 200, canvasHeight)
  const scale = Math.max(1, Math.floor(Math.min(availableWidth / canvasWidth, availableHeight / canvasHeight)))
  canvas.style.width = (canvasWidth * scale) + 'px'
  canvas.style.height = (canvasHeight * scale) + 'px'
}

window.addEventListener('resize', resizeCanvas)

let framebufferPtr = 0
const framebufferLen = canvasWidth * canvasHeight * 4

const imports = {
  env: {
    onez_host_monotonic_now_ns: () => BigInt(Math.round(performance.now() * 1e6)),
    onez_host_realtime_now_ms: () => BigInt(Date.now()),
    onez_host_write_output: (ptr, len) => {
      const text = new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len))
      console.log(text)
    },
    onez_host_present: () => {
      const pixels = new Uint8ClampedArray(memory.buffer, framebufferPtr, framebufferLen)
      ctx2d.putImageData(new ImageData(pixels, canvasWidth, canvasHeight), 0, 0)
    },
  },
}

async function main() {
  resizeCanvas()

  const response = await fetch('1z.wasm')
  const bytes = await response.arrayBuffer()
  const { instance } = await WebAssembly.instantiate(bytes, imports)
  const exports = instance.exports
  memory = exports.memory

  const handle = exports.onez_init()
  if (!handle) {
    setStatus('failed to initialize the 1z interpreter', true)
    return
  }
  exports.onez_wasm_use_host_output(handle)

  framebufferPtr = exports.onez_wasm_framebuffer_ptr()

  const inputPtr = exports.onez_wasm_input_ptr()
  const inputCapacity = exports.onez_wasm_input_capacity()
  const encoder = new TextEncoder()

  function evalSource(source) {
    const encoded = encoder.encode(source)
    if (encoded.length > inputCapacity) {
      throw new Error('source too long for the demo input buffer (' + inputCapacity + ' bytes)')
    }
    new Uint8Array(memory.buffer, inputPtr, inputCapacity).set(encoded)
    return exports.onez_wasm_eval(handle, inputPtr, encoded.length)
  }

  function reportEvalError(context) {
    const errPtr = exports.onez_last_error(handle)
    const message = errPtr ? readCString(errPtr) : 'unknown error'
    setStatus(context + ': ' + message, true)
  }

  function readCString(ptr) {
    const bytes = new Uint8Array(memory.buffer)
    let end = ptr
    while (bytes[end] !== 0) end++
    return new TextDecoder().decode(bytes.subarray(ptr, end))
  }

  const gameSource = await (await fetch('demo-game.1z')).text()
  if (evalSource(gameSource) === ONEZ_EVAL_ERROR) {
    reportEvalError('failed to start the demo game')
    return
  }

  setStatus('running')

  function frame() {
    if (evalSource('run-frame') === ONEZ_EVAL_ERROR) {
      reportEvalError('run-frame failed')
      return
    }
    requestAnimationFrame(frame)
  }
  requestAnimationFrame(frame)
}

main().catch((error) => {
  setStatus('failed to load the wasm module: ' + error, true)
})
