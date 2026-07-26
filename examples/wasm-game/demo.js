// Thin boot wrapper: the host plumbing lives in host.js, shared by every game page.
import { bootGame } from './host.js'

bootGame({ gameUrl: 'demo-game.1z' }).catch((error) => {
  const statusEl = document.getElementById('status')
  statusEl.textContent = 'failed to load the wasm module: ' + error
  statusEl.className = 'error'
})
