#!/usr/bin/env node

import { open } from "node:fs/promises";

const defaultArchive =
  "/Applications/logioptionsplus.app/Contents/Resources/app.asar";
const archivePath = process.argv[2] ?? defaultArchive;
const pattern = new RegExp(process.argv[3] ?? "easy.?switch", "i");

function walk(files, prefix = "") {
  const entries = [];
  for (const [name, metadata] of Object.entries(files)) {
    const path = prefix ? `${prefix}/${name}` : name;
    if (metadata.files) entries.push(...walk(metadata.files, path));
    else entries.push({ path, ...metadata });
  }
  return entries;
}

const archive = await open(archivePath, "r");
try {
  const prefix = Buffer.alloc(16);
  await archive.read(prefix, 0, prefix.length, 0);
  const headerLength = prefix.readUInt32LE(12);
  const headerBuffer = Buffer.alloc(headerLength);
  await archive.read(headerBuffer, 0, headerLength, 16);
  const header = JSON.parse(headerBuffer.toString("utf8"));
  const contentOffset = 16 + headerLength;

  for (const entry of walk(header.files)) {
    if (entry.unpacked || entry.offset === undefined || entry.size === undefined) {
      continue;
    }

    const contents = Buffer.alloc(entry.size);
    await archive.read(
      contents,
      0,
      entry.size,
      contentOffset + Number(entry.offset),
    );
    const text = contents.toString("utf8");
    if (!pattern.test(entry.path) && !pattern.test(text)) continue;

    console.log(`FILE ${entry.path} (${entry.size} bytes)`);
    const lines = text.split("\n");
    const matching = [];
    for (let index = 0; index < lines.length; index += 1) {
      if (pattern.test(lines[index])) matching.push(index);
    }
    for (const index of matching.slice(0, 20)) {
      const start = Math.max(0, index - 2);
      const end = Math.min(lines.length, index + 3);
      console.log(lines.slice(start, end).join("\n"));
    }
  }
} finally {
  await archive.close();
}
