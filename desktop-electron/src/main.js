// Electron main process.
// Responsibilities:
//   1. Create the window (the renderer runs WebRTC + shows the pairing QR).
//   2. Monitor the active/focused window (focus change => a new "session").
//   3. Inject received text into the currently focused input (clipboard + Cmd/Ctrl+V).

import { app, BrowserWindow, ipcMain, clipboard, systemPreferences } from 'electron';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import QRCode from 'qrcode';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

let mainWindow = null;
let focusPoller = null;
let lastFocusKey = '';
let focusErrorLogged = false;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 420,
    height: 600,
    title: 'Chatput',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });
  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

// --- Focus monitoring -------------------------------------------------------
// active-win is ESM-only and dynamically imported to play nice with packaging.
async function pollActiveWindow() {
  try {
    const { default: activeWindow } = await import('active-win');
    const win = await activeWindow();
    if (!win) return;

    // Ignore our own window so it doesn't create a self-session.
    if (win.owner && win.owner.name && win.owner.name.includes('Electron')) return;

    const key = `${win.owner?.name || ''}|${win.title || ''}`;
    if (key === lastFocusKey) return;
    lastFocusKey = key;

    // A focus change == a session in the phone UI.
    mainWindow?.webContents.send('focus-changed', {
      sessionId: key,
      app: win.owner?.name || 'Unknown',
      title: win.title || '',
      ts: Date.now()
    });
  } catch (err) {
    // active-win needs Screen Recording permission on macOS to read window titles.
    // Log once instead of spamming, and tell the renderer to show guidance.
    if (!focusErrorLogged) {
      focusErrorLogged = true;
      console.error('[focus] disabled:', err.message);
      console.error('[focus] macOS 需在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 Electron，然后重启应用。');
      mainWindow?.webContents.send('focus-error');
    }
  }
}

function startFocusPolling() {
  if (focusPoller) return;
  focusPoller = setInterval(pollActiveWindow, 800);
}

function stopFocusPolling() {
  if (focusPoller) { clearInterval(focusPoller); focusPoller = null; }
}

// --- Text injection ---------------------------------------------------------
function injectText(text) {
  if (!text) return;
  const previous = clipboard.readText();
  clipboard.writeText(text);

  if (process.platform === 'darwin') {
    // Requires Accessibility permission for the running app.
    execFile('osascript', [
      '-e', 'tell application "System Events" to keystroke "v" using command down'
    ], (err) => {
      if (err) console.error('[inject] osascript error:', err.message);
      // Restore clipboard shortly after paste.
      setTimeout(() => clipboard.writeText(previous), 300);
    });
  } else {
    // Windows/Linux injection comes in Phase 2.
    console.warn('[inject] platform not implemented yet:', process.platform);
  }
}

// --- IPC from renderer ------------------------------------------------------
ipcMain.on('inject-text', (_evt, text) => injectText(text));

// Build a QR code data URL from the pairing payload (rendered as <img> by renderer).
ipcMain.handle('make-qr', async (_evt, payload) => {
  return QRCode.toDataURL(payload, { margin: 1, width: 240 });
});

app.whenReady().then(() => {
  createWindow();
  startFocusPolling();

  // On macOS, ensure Electron is a trusted accessibility client (needed for
  // keystroke injection). Shows the system prompt once if not yet granted.
  if (process.platform === 'darwin') {
    const trusted = systemPreferences.isTrustedAccessibilityClient(true);
    if (!trusted) {
      console.warn('[perm] 需在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 Electron。');
    }
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  stopFocusPolling();
  if (process.platform !== 'darwin') app.quit();
});
