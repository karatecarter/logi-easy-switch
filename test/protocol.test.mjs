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
