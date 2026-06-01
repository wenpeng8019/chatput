// WebRTC signaling + pairing server.
// Pure relay for SDP/ICE; the actual text payload travels P2P over the DataChannel.
//
// Message protocol (JSON over WebSocket):
//   C->S {type:'create-room'}                       -> S->C {type:'room-created', roomId, token}
//   C->S {type:'join-room', roomId, token}          -> both: {type:'peer-joined', role}
//                                                      joiner err: {type:'error', reason}
//   C->S {type:'signal', data}                      -> forwarded to the other peer as-is
//   S->C {type:'peer-left'}                          when a peer disconnects
//
// Roles: the room creator is 'host' (desktop), the joiner is 'guest' (phone).

import { WebSocketServer } from 'ws';
import { randomBytes } from 'node:crypto';

const PORT = process.env.PORT ? Number(process.env.PORT) : 8080;

/** @type {Map<string, {token:string, host:any|null, guest:any|null}>} */
const rooms = new Map();

function genId(bytes = 4) {
  return randomBytes(bytes).toString('hex');
}

function send(ws, obj) {
  if (ws && ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

function otherPeer(room, ws) {
  if (room.host === ws) return room.guest;
  if (room.guest === ws) return room.host;
  return null;
}

function cleanupSocket(ws) {
  const roomId = ws._roomId;
  if (!roomId) return;
  const room = rooms.get(roomId);
  if (!room) return;

  const peer = otherPeer(room, ws);
  if (room.host === ws) room.host = null;
  if (room.guest === ws) room.guest = null;

  if (peer) send(peer, { type: 'peer-left' });

  if (!room.host && !room.guest) {
    rooms.delete(roomId);
  }
}

const wss = new WebSocketServer({ port: PORT });

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch {
      send(ws, { type: 'error', reason: 'invalid-json' });
      return;
    }

    switch (msg.type) {
      case 'create-room': {
        const roomId = genId(3);   // short, QR-friendly
        const token = genId(8);
        rooms.set(roomId, { token, host: ws, guest: null });
        ws._roomId = roomId;
        send(ws, { type: 'room-created', roomId, token });
        break;
      }

      case 'join-room': {
        const room = rooms.get(msg.roomId);
        if (!room) {
          send(ws, { type: 'error', reason: 'room-not-found' });
          return;
        }
        if (room.token !== msg.token) {
          send(ws, { type: 'error', reason: 'bad-token' });
          return;
        }
        if (room.guest) {
          send(ws, { type: 'error', reason: 'room-full' });
          return;
        }
        room.guest = ws;
        ws._roomId = msg.roomId;
        send(ws, { type: 'peer-joined', role: 'guest' });
        send(room.host, { type: 'peer-joined', role: 'host' });
        break;
      }

      case 'signal': {
        const room = rooms.get(ws._roomId);
        if (!room) {
          send(ws, { type: 'error', reason: 'not-in-room' });
          return;
        }
        const peer = otherPeer(room, ws);
        if (peer) send(peer, { type: 'signal', data: msg.data });
        break;
      }

      default:
        send(ws, { type: 'error', reason: 'unknown-type' });
    }
  });

  ws.on('close', () => cleanupSocket(ws));
  ws.on('error', () => cleanupSocket(ws));
});

// Heartbeat: drop dead connections.
const interval = setInterval(() => {
  for (const ws of wss.clients) {
    if (ws.isAlive === false) { ws.terminate(); continue; }
    ws.isAlive = false;
    ws.ping();
  }
}, 30000);

wss.on('close', () => clearInterval(interval));

console.log(`[signaling] listening on ws://0.0.0.0:${PORT}`);
