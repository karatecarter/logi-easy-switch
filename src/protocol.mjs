import net from "node:net";
import { lstat, readdir } from "node:fs/promises";

const SOCKET_PREFIX = "logitech_kiros_agent-";
const MAX_FRAME_BYTES = 1024 * 1024;

export async function validateAgentSocket(socketPath) {
  const info = await lstat(socketPath);
  // Trust only root and our own login user. lstat deliberately rejects symlinks.
  if (!info.isSocket() || ![0, process.getuid()].includes(info.uid)) {
    throw new Error("Untrusted Options+ socket: expected a socket owned by root or the current user");
  }
  return socketPath;
}

export function encodeFrame(message) {
  const protocol = Buffer.from("json", "utf8");
  const payload = Buffer.from(JSON.stringify(message), "utf8");
  const innerLength = 4 + protocol.length + 4 + payload.length;
  const frame = Buffer.alloc(4 + innerLength);

  frame.writeUInt32LE(innerLength, 0);
  frame.writeUInt32BE(protocol.length, 4);
  protocol.copy(frame, 8);
  frame.writeUInt32BE(payload.length, 8 + protocol.length);
  payload.copy(frame, 12 + protocol.length);
  return frame;
}

export function decodeFrames(buffer) {
  const messages = [];
  let offset = 0;

  while (buffer.length - offset >= 4) {
    const innerLength = buffer.readUInt32LE(offset);
    if (innerLength < 8 || innerLength > MAX_FRAME_BYTES) {
      throw new Error("Invalid or oversized Options+ IPC frame");
    }
    if (buffer.length - offset < innerLength + 4) break;

    const start = offset + 4;
    const protocolLength = buffer.readUInt32BE(start);
    const protocolStart = start + 4;
    const protocolEnd = protocolStart + protocolLength;
    if (protocolEnd + 4 > offset + innerLength + 4) {
      throw new Error("Malformed Options+ IPC frame");
    }
    const messageLength = buffer.readUInt32BE(protocolEnd);
    const messageStart = protocolEnd + 4;
    const messageEnd = messageStart + messageLength;

    if (messageEnd > offset + innerLength + 4) {
      throw new Error("Malformed Options+ IPC frame");
    }

    const protocol = buffer.toString("utf8", protocolStart, protocolEnd);
    // Current agents send a protobuf greeting before the JSON response. The
    // greeting is transport metadata and has no request ID, so it is safe to
    // consume and ignore here.
    if (protocol === "json") {
      messages.push(JSON.parse(buffer.toString("utf8", messageStart, messageEnd)));
    }
    offset += innerLength + 4;
  }

  return { messages, remaining: buffer.subarray(offset) };
}

export async function findAgentSocket(tmpDirectory = "/tmp") {
  const names = await readdir(tmpDirectory);
  const matches = names.filter((name) => name.startsWith(SOCKET_PREFIX)).sort();
  if (matches.length === 0) {
    throw new Error("Logi Options+ agent socket was not found; is Options+ running?");
  }
  for (const name of matches.reverse()) {
    const candidate = `${tmpDirectory}/${name}`;
    try { return await validateAgentSocket(candidate); }
    catch { /* Ignore vanished paths, symlinks, and sockets belonging to other users. */ }
  }
  throw new Error("No trusted Logi Options+ socket was found");
}

export class OptionsClient {
  constructor(socketPath) {
    this.socketPath = socketPath;
    this.nextMessageId = 1;
  }

  async request(verb, path, payload) {
    await validateAgentSocket(this.socketPath);
    const msgId = String(this.nextMessageId++);
    const message = { msg_id: msgId, verb, path };
    if (payload !== undefined) message.payload = payload;

    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ path: this.socketPath });
      let received = Buffer.alloc(0);
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error(`Options+ request timed out: ${verb} ${path}`));
      }, 3000);

      const finish = (callback, value) => {
        clearTimeout(timer);
        socket.destroy();
        callback(value);
      };

      socket.on("connect", () => socket.write(encodeFrame(message)));
      socket.on("data", (chunk) => {
        try {
          if (received.length + chunk.length > MAX_FRAME_BYTES + 4) {
            throw new Error("Options+ receive buffer exceeds the limit");
          }
          received = Buffer.concat([received, chunk]);
          const decoded = decodeFrames(received);
          received = decoded.remaining;
          const response = decoded.messages.find(
            (candidate) => String(candidate.msgId ?? candidate.msg_id) === msgId,
          );
          if (response) finish(resolve, response);
        } catch (error) {
          finish(reject, error);
        }
      });
      socket.on("error", (error) => finish(reject, error));
    });
  }

  get(path) {
    return this.request("GET", path);
  }

  set(path, payload) {
    return this.request("SET", path, payload);
  }
}

export function responsePayload(response) {
  const code = response?.result?.code;
  if (code && code !== "SUCCESS") {
    throw new Error(`${code}: ${response.result.what || response.path || "request failed"}`);
  }
  return response.payload ?? response;
}
