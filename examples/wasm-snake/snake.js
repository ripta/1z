// Thin boot wrapper: the host plumbing lives in the platform demo's host.js.
import { bootGame } from '../wasm-game/host.js'

bootGame({ gameUrl: 'snake.1z' }).catch((error) => {
  const statusEl = document.getElementById('status')
  statusEl.textContent = 'failed to load the wasm module: ' + error
  statusEl.className = 'error'
})
