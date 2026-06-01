// Preload (CommonJS). Bridges a minimal, safe API to the renderer.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('desktop', {
  // Renderer -> main: inject recognized text into the focused input.
  injectText: (text) => ipcRenderer.send('inject-text', text),
  // Main -> renderer: the focused window changed (new session).
  onFocusChanged: (cb) => ipcRenderer.on('focus-changed', (_e, data) => cb(data)),
  // Main -> renderer: focus monitoring disabled (needs Screen Recording permission).
  onFocusError: (cb) => ipcRenderer.on('focus-error', () => cb()),
  // Renderer -> main: build a QR data URL from a pairing payload.
  makeQr: (payload) => ipcRenderer.invoke('make-qr', payload)
});
