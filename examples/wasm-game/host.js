// Browser harness for the 1z game platform, compiled to wasm32-freestanding
// (src/capi_wasm.zig). No build step: imported directly as an ES module by each game's
// thin boot script (demo.js, ../wasm-snake/snake.js).
//
// The frame-loop contract itself (the fixed timestep, the tick counter, the capped
// catch-up accumulator) lives entirely in lib/game/loop.1z's run-frame word. This
// harness is intentionally dumb: it calls run-frame once per requestAnimationFrame
// tick and otherwise only handles what only a browser can do -- loading the module,
// presenting the framebuffer, sizing the canvas, and relaying input and audio.
//
// All fetches are page-relative: each game's directory carries its own copy of
// 1z.wasm (placed by `make wasm`) next to the game source file `bootGame` fetches.

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

// Maps KeyboardEvent.code to the same 0-47 byte offsets lib/game/input.1z's private key-index
// hash uses. The two tables are a private contract kept in sync by inspection; there is no
// shared source of truth, since capi_wasm.zig's keyboard buffer carries no key semantics of
// its own (see lib/game/input.1z's header comment).
const KEY_INDEX = {
  ArrowUp: 0, ArrowDown: 1, ArrowLeft: 2, ArrowRight: 3,
  KeyA: 4, KeyB: 5, KeyC: 6, KeyD: 7, KeyE: 8, KeyF: 9, KeyG: 10, KeyH: 11, KeyI: 12,
  KeyJ: 13, KeyK: 14, KeyL: 15, KeyM: 16, KeyN: 17, KeyO: 18, KeyP: 19, KeyQ: 20, KeyR: 21,
  KeyS: 22, KeyT: 23, KeyU: 24, KeyV: 25, KeyW: 26, KeyX: 27, KeyY: 28, KeyZ: 29,
  Digit0: 30, Digit1: 31, Digit2: 32, Digit3: 33, Digit4: 34, Digit5: 35, Digit6: 36,
  Digit7: 37, Digit8: 38, Digit9: 39,
  Space: 40, Enter: 41, Escape: 42, Tab: 43,
  ShiftLeft: 44, ShiftRight: 45, ControlLeft: 46, ControlRight: 47,
}

let keyboardPtr = 0
let keyboardLen = 0

function setKeyState(code, down) {
  if (memory === null) return false
  const index = KEY_INDEX[code]
  if (index === undefined) return false
  new Uint8Array(memory.buffer, keyboardPtr, keyboardLen)[index] = down ? 1 : 0
  return true
}

window.addEventListener('keydown', (event) => {
  if (setKeyState(event.code, true)) event.preventDefault()
})
window.addEventListener('keyup', (event) => {
  if (setKeyState(event.code, false)) event.preventDefault()
})

// Loaded samples, indexed by the handle the load call hands back to 1z.
const audioBuffers = []

// Browsers gate audio output behind a user gesture, but not context creation or sample loading,
// so the context is built up front and resumed on the first gesture.
//
// 1z never sees any of this. A play issued before the gesture is silent rather than an error,
// and every game's first sound follows the same input that starts real gameplay.
const audioContext = new AudioContext()

function armAudio() {
  if (audioContext.state === 'suspended') audioContext.resume()
}

window.addEventListener('keydown', armAudio)
window.addEventListener('click', armAudio)
window.addEventListener('touchstart', armAudio)

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
    onez_host_load_sample: (ptr, len, channels, rate) => {
      try {
        // Copy the bytes out rather than viewing them in place: a 1z byte array carries no
        // alignment guarantee, and a Float32Array view needs a 4-byte-aligned offset.
        const frames = new Float32Array(memory.buffer.slice(ptr, ptr + len))
        const frameCount = frames.length / channels
        const buffer = audioContext.createBuffer(channels, frameCount, rate)
        for (let channel = 0; channel < channels; channel++) {
          const channelData = new Float32Array(frameCount)
          for (let frame = 0; frame < frameCount; frame++) {
            channelData[frame] = frames[frame * channels + channel]
          }
          buffer.copyToChannel(channelData, channel)
        }
        audioBuffers.push(buffer)
        return audioBuffers.length - 1
      } catch (error) {
        // A byte length that does not divide evenly into frames, or a rate the browser refuses,
        // throws here. The negative handle turns that into an ordinary 1z error, rather than an
        // exception unwinding the wasm frame that called this import.
        console.error('onez_host_load_sample rejected the sample', error)
        return -1
      }
    },
    onez_host_play_sample: (handle) => {
      const buffer = audioBuffers[handle]
      if (buffer === undefined) return
      try {
        const source = audioContext.createBufferSource()
        source.buffer = buffer
        source.connect(audioContext.destination)
        source.start()
      } catch (error) {
        // Throwing out of an import unwinds the wasm frame that called it, so the interpreter's
        // own stack and call frames never get unwound with it. A dropped sound is the cheaper loss.
        console.error('onez_host_play_sample could not start the sample', error)
      }
    },
  },
}

// Load the wasm module, evaluate the game source fetched from `gameUrl`, and drive
// run-frame once per requestAnimationFrame tick.
export async function bootGame({ gameUrl }) {
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
  keyboardPtr = exports.onez_wasm_keyboard_ptr()
  keyboardLen = exports.onez_wasm_keyboard_len()

  const inputPtr = exports.onez_wasm_input_ptr()
  const inputCapacity = exports.onez_wasm_input_capacity()
  const encoder = new TextEncoder()

  function evalSource(source) {
    const encoded = encoder.encode(source)
    if (encoded.length > inputCapacity) {
      throw new Error('source too long for the eval input buffer (' + inputCapacity + ' bytes)')
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

  const gameSource = await (await fetch(gameUrl)).text()
  if (evalSource(gameSource) === ONEZ_EVAL_ERROR) {
    reportEvalError('failed to start ' + gameUrl)
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
