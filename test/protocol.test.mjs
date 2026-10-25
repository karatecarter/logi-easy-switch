import assert from "node:assert/strict";
import test from "node:test";
import { decodeFrames, encodeFrame } from "../src/protocol.mjs";

test("encodes and decodes an Options+ JSON frame", () => {
  const input = { msg_id: "7", verb: "GET", path: "/devices/list" };
  const frame = encodeFrame(input);
  const decoded = decodeFrames(frame);
  assert.deepEqual(decoded.messages, [input]);
  assert.equal(decoded.remaining.length, 0);
});

test("retains a partial frame", () => {
  const frame = encodeFrame({ msg_id: "8", verb: "GET", path: "/permissions" });
  const first = decodeFrames(frame.subarray(0, 9));
  assert.deepEqual(first.messages, []);
  assert.equal(first.remaining.length, 9);
});

test("rejects malformed and oversized IPC frame lengths", () => {
  for (const size of [0, 7, 1024 * 1024 + 1]) {
    const frame = Buffer.alloc(4);
    frame.writeUInt32LE(size);
    assert.throws(() => decodeFrames(frame), /Invalid or oversized/);
  }
  const frame = Buffer.alloc(12);
  frame.writeUInt32LE(8, 0);
  frame.writeUInt32BE(100, 4);
  assert.throws(() => decodeFrames(frame), /Malformed/);
});

test("socket discovery rejects files and symlinks and accepts an owned socket", async (t) => {
  const { mkdtemp, rm, writeFile, symlink } = await import("node:fs/promises");
  const { tmpdir } = await import("node:os");
  const { join } = await import("node:path");
  const { createServer } = await import("node:net");
  const { findAgentSocket, validateAgentSocket, OptionsClient } = await import("../src/protocol.mjs");
  const directory = await mkdtemp(join(tmpdir(), "logi-socket-test-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const fake = join(directory, "logitech_kiros_agent-zzz");
  await writeFile(fake, "not a socket");
  await assert.rejects(findAgentSocket(directory), /No trusted/);
  const real = join(directory, "logitech_kiros_agent-aaa");
  const server = createServer();
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(real, resolve); });
  t.after(() => new Promise((resolve) => server.close(resolve)));
  const link = join(directory, "logitech_kiros_agent-yyy");
  await symlink(real, link);
  await assert.rejects(validateAgentSocket(link), /Untrusted/);
  assert.equal(await findAgentSocket(directory), real);
  // A path supplied directly to the client is also validated before connection.
  await assert.rejects(new OptionsClient(fake).get("/devices/list"), /Untrusted/);
});
