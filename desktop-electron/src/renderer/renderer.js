// Desktop renderer = WebRTC HOST.
// Creates a room on the signaling server, shows a pairing QR, then establishes a
// P2P DataChannel with the phone. Received text is injected via the main process.

// --- Config (renderer-safe; cannot read process.env here) -------------------
const SIGNALING_URL = 'ws://10.2.101.210:8080';
const ICE_SERVERS = [{ urls: 'stun:stun.l.google.com:19302' }];

// --- DOM helpers ------------------------------------------------------------
const $status = document.getElementById('status');
const $qr = document.getElementById('qr');
const $code = document.getElementById('code');
const $log = document.getElementById('log');

function log(...args) {
  const line = args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ');
  $log.textContent += line + '\n';
  $log.scrollTop = $log.scrollHeight;
  console.log('[renderer]', ...args);
}

function setStatus(text, connected = false) {
  $status.textContent = text;
  $status.classList.toggle('connected', connected);
}

// --- WebRTC + signaling state ----------------------------------------------
let ws = null;
let pc = null;
let channel = null;

function sendSignal(data) {
  ws?.send(JSON.stringify({ type: 'signal', data }));
}

function createPeerConnection() {
  pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });

  pc.onicecandidate = (e) => {
    if (e.candidate) sendSignal({ candidate: e.candidate });
  };

  pc.onconnectionstatechange = () => {
    log('pc state:', pc.connectionState);
    if (pc.connectionState === 'connected') setStatus('P2P 已连接 ✅', true);
    if (['disconnected', 'failed', 'closed'].includes(pc.connectionState)) {
      setStatus('P2P 已断开');
    }
  };

  // Host creates the DataChannel.
  channel = pc.createDataChannel('input');
  wireChannel(channel);
}

function wireChannel(ch) {
  ch.onopen = () => {
    log('datachannel open');
    setStatus('P2P 已连接 ✅', true);
  };
  ch.onclose = () => log('datachannel closed');
  ch.onmessage = (e) => {
    let msg;
    try { msg = JSON.parse(e.data); } catch { return; }
    if (msg.type === 'text' && msg.text) {
      log('recv text:', msg.text);
      window.desktop.injectText(msg.text);
    }
  };
}

async function makeOffer() {
  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  sendSignal({ sdp: pc.localDescription });
}

async function handleSignal(data) {
  if (data.sdp) {
    await pc.setRemoteDescription(data.sdp);
    log('remote sdp set:', data.sdp.type);
  } else if (data.candidate) {
    try { await pc.addIceCandidate(data.candidate); } catch (err) { log('ice err', err.message); }
  }
}

// --- Signaling connection ---------------------------------------------------
function connectSignaling() {
  ws = new WebSocket(SIGNALING_URL);

  ws.onopen = () => {
    setStatus('信令已连接，创建房间…');
    ws.send(JSON.stringify({ type: 'create-room' }));
  };

  ws.onmessage = async (e) => {
    const msg = JSON.parse(e.data);
    switch (msg.type) {
      case 'room-created': {
        const payload = JSON.stringify({ url: SIGNALING_URL, roomId: msg.roomId, token: msg.token });
        const qr = await window.desktop.makeQr(payload);
        $qr.innerHTML = `<img src="${qr}" alt="pairing qr" />`;
        $code.textContent = `房间 ${msg.roomId}`;
        setStatus('等待手机扫码配对…');
        log('room created:', msg.roomId);
        break;
      }
      case 'peer-joined': {
        // Host side: a guest joined -> start the WebRTC handshake.
        if (msg.role === 'host') {
          log('guest joined, creating offer');
          createPeerConnection();
          await makeOffer();
        }
        break;
      }
      case 'signal':
        await handleSignal(msg.data);
        break;
      case 'peer-left':
        log('peer left');
        setStatus('手机已断开，等待重连…');
        break;
      case 'error':
        log('signaling error:', msg.reason);
        break;
    }
  };

  ws.onclose = () => {
    setStatus('信令断开，3 秒后重连…');
    setTimeout(connectSignaling, 3000);
  };
  ws.onerror = () => log('ws error');
}

// --- Focus changes -> notify phone to create/switch a session ---------------
window.desktop.onFocusChanged((session) => {
  log('focus:', session.app, '-', session.title);
  if (channel && channel.readyState === 'open') {
    channel.send(JSON.stringify({ type: 'session', ...session }));
  }
});

window.desktop.onFocusError(() => {
  log('⚠️ 焦点监控未授权：系统设置 → 隐私与安全性 → 屏幕录制 → 勾选 Electron，然后重启应用。');
});

connectSignaling();
