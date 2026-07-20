// Browser harness for the 1z interpreter compiled to wasm32-freestanding (src/capi_wasm.zig).
// No build step: this is loaded directly as an ES module by index.html.

const ONEZ_EVAL_COMPLETE = 0
const ONEZ_EVAL_NEEDS_MORE_INPUT = 1
const ONEZ_EVAL_ERROR = 2

let memory = null

function readCString(ptr) {
  const bytes = new Uint8Array(memory.buffer)
  let end = ptr
  while (bytes[end] !== 0) end++
  return new TextDecoder().decode(bytes.subarray(ptr, end))
}

function appendOutput(text, className) {
  const output = document.getElementById('output')
  const span = document.createElement('span')
  if (className) span.className = className
  span.textContent = text
  output.appendChild(span)
  output.scrollTop = output.scrollHeight
}

// Each import is its own individually-named, individually-typed function, resolved against 
// the scheduler's and C API's matching `extern` declrations.
const imports = {
  env: {
    onez_host_monotonic_now_ns: () => BigInt(Math.round(performance.now() * 1e6)),
    onez_host_realtime_now_ms: () => BigInt(Date.now()),
    onez_host_write_output: (ptr, len) => {
      appendOutput(new TextDecoder().decode(new Uint8Array(memory.buffer, ptr, len)))
    },
  },
}

async function main() {
  const response = await fetch('1z.wasm')
  const bytes = await response.arrayBuffer()
  const { instance } = await WebAssembly.instantiate(bytes, imports)
  const exports = instance.exports
  memory = exports.memory

  const handle = exports.onez_init()
  if (!handle) {
    appendOutput('failed to initialize the 1z interpreter\n', 'error')
    return
  }
  exports.onez_wasm_use_host_output(handle)

  const inputPtr = exports.onez_wasm_input_ptr()
  const inputCapacity = exports.onez_wasm_input_capacity()

  const inputEl = document.getElementById('input')
  const promptEl = document.getElementById('prompt')
  const encoder = new TextEncoder()

  // Host-accumulated buffer: onez_wasm_eval carries no state between calls, so on
  // ONEZ_EVAL_NEEDS_MORE_INPUT the whole growing statement is re-sent on the next line.
  let pendingLines = []

  inputEl.addEventListener('keydown', (event) => {
    if (event.key !== 'Enter') return
    event.preventDefault()

    const line = inputEl.value
    inputEl.value = ''
    pendingLines.push(line)
    appendOutput((pendingLines.length === 1 ? '> ' : '+ ') + line + '\n')

    const source = pendingLines.join('\n')
    const encoded = encoder.encode(source)
    if (encoded.length > inputCapacity) {
      appendOutput('input too long for the demo buffer (' + inputCapacity + ' bytes)\n', 'error')
      pendingLines = []
      promptEl.textContent = '>'
      return
    }
    new Uint8Array(memory.buffer, inputPtr, inputCapacity).set(encoded)

    const status = exports.onez_wasm_eval(handle, inputPtr, encoded.length)
    if (status === ONEZ_EVAL_NEEDS_MORE_INPUT) {
      promptEl.textContent = '+'
      return
    }

    if (status === ONEZ_EVAL_ERROR) {
      const errPtr = exports.onez_last_error(handle)
      appendOutput((errPtr ? readCString(errPtr) : 'unknown error') + '\n', 'error')
    } else {
      appendOutput('(' + exports.onez_stack_depth(handle) + ' value(s) on stack)\n', 'stack')
    }

    pendingLines = []
    promptEl.textContent = '>'
  })
}

main().catch((error) => {
  appendOutput('failed to load the wasm module: ' + error + '\n', 'error')
})
