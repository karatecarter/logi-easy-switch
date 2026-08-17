#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { findAgentSocket, OptionsClient, responsePayload } from "./protocol.mjs";

const CONFIG_PATH = join(homedir(), ".config", "logi-easy-switch", "config.json");

function usage() {
  console.log(`Usage:
  logi-switch list
  logi-switch list --connected
  logi-switch inspect <device-id>
  logi-switch targets [--device <device-id> ...]
  logi-switch defaults
  logi-switch set-defaults --mouse <device-id> --keyboard <device-id>
  logi-switch switch-to <computer-name> [--device <device-id> ...] [--yes]
  logi-switch switch <1|2|3> [--device <device-id> ...] [--yes]

Channel numbers match the labels printed on the devices.`);
}

function optionValues(args, option) {
  const values = [];
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === option) {
      const value = args[index + 1];
      if (!value || value.startsWith("--")) throw new Error(`${option} requires a value`);
      values.push(value);
      index += 1;
    }
  }
  return values;
}

function collectDevices(value, output = []) {
  if (Array.isArray(value)) {
    for (const item of value) collectDevices(item, output);
  } else if (value && typeof value === "object") {
    const name = value.name ?? value.deviceName ?? value.displayName;
    const id = value.id ?? value.deviceId ?? value.device_id;
    if (name && id) output.push({ id, name, raw: value });
    for (const child of Object.values(value)) collectDevices(child, output);
  }
  return [...new Map(output.map((device) => [device.id, device])).values()];
}

function isInputDevice(device) {
  return device.id.startsWith("dev") && ["KEYBOARD", "MOUSE"].includes(device.raw.deviceType);
}

function isAvailable(device) {
  return device.raw.connected === true || ["ACTIVE", "PRESENT"].includes(device.raw.state);
}

function fallbackDefaults(devices) {
  const keyboard = devices.find((device) => /ERGO K860/i.test(device.name));
  const mouse = devices.find((device) => /MX Master 3S/i.test(device.name));
  return [mouse, keyboard].filter(Boolean).map((device) => device.id);
}

async function loadConfig() {
  try {
    return JSON.parse(await readFile(CONFIG_PATH, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return { defaults: {} };
    throw error;
  }
}

async function saveConfig(config) {
  await mkdir(dirname(CONFIG_PATH), { recursive: true });
  await writeFile(CONFIG_PATH, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
}

async function selectedDevices(client, args) {
  const devices = collectDevices(responsePayload(await client.get("/devices/list"))).filter(isInputDevice);
  const requestedIds = optionValues(args, "--device");
  const config = await loadConfig();
  const ids = requestedIds.length > 0 ? requestedIds : config.defaults?.deviceIds ?? fallbackDefaults(devices);
  const selected = ids.map((id) => devices.find((device) => device.id === id));
  const missing = selected
    .map((device, index) => (device ? undefined : ids[index]))
    .filter(Boolean);
  if (missing.length > 0) {
    throw new Error(`Configured device not found: ${missing.join(", ")}. Run list, then set-defaults.`);
  }
  if (selected.length === 0) throw new Error("No default input devices found. Run set-defaults.");
  return selected;
}

async function hostMap(client, device) {
  const response = await client.get(`/devices/${device.id}/easy_switch`);
  const payload = responsePayload(response);
  return {
    device,
    hosts: (payload.hosts ?? []).filter((host) => host.paired),
  };
}

const [command = "help", ...args] = process.argv.slice(2);
if (["help", "--help", "-h"].includes(command)) {
  usage();
  process.exit(0);
}

const socketPath = await findAgentSocket();
const client = new OptionsClient(socketPath);

if (command === "list") {
  const response = await client.get("/devices/list");
  const payload = responsePayload(response);
  let devices = collectDevices(payload);
  if (args.includes("--connected")) devices = devices.filter(isAvailable);
  if (args.includes("--json")) {
    console.log(JSON.stringify({ socketPath, devices, response }, null, 2));
  } else {
    console.log(`Agent: ${socketPath}`);
    for (const device of devices) {
      const { state, connectionType, deviceType, connected } = device.raw;
      console.log(
        [device.id, device.name, deviceType, connectionType, state, connected ? "connected" : ""].
          filter(Boolean).
          join("\t"),
      );
    }
  }
  process.exit(0);
}

if (command === "inspect") {
  const deviceId = args[0];
  if (!deviceId) throw new Error("inspect requires a device ID");
  const [easySwitch, currentHost] = await Promise.all([
    client.get(`/devices/${deviceId}/easy_switch`),
    client.get(`/change_host/${deviceId}/host`),
  ]);
  console.log(JSON.stringify({ easySwitch, currentHost }, null, 2));
  process.exit(0);
}

if (command === "defaults") {
  const devices = collectDevices(responsePayload(await client.get("/devices/list"))).filter(isInputDevice);
  const config = await loadConfig();
  const ids = config.defaults?.deviceIds ?? fallbackDefaults(devices);
  console.log(`Config: ${CONFIG_PATH}`);
  for (const id of ids) {
    const device = devices.find((candidate) => candidate.id === id);
    console.log(`${id}\t${device?.name ?? "not currently available"}`);
  }
  process.exit(0);
}

if (command === "set-defaults") {
  const mouseId = optionValues(args, "--mouse").at(-1);
  const keyboardId = optionValues(args, "--keyboard").at(-1);
  if (!mouseId || !keyboardId) {
    throw new Error("set-defaults requires --mouse <id> and --keyboard <id>");
  }
  const devices = collectDevices(responsePayload(await client.get("/devices/list"))).filter(isInputDevice);
  const mouse = devices.find((device) => device.id === mouseId);
  const keyboard = devices.find((device) => device.id === keyboardId);
  if (!mouse || mouse.raw.deviceType !== "MOUSE") throw new Error(`Not a mouse: ${mouseId}`);
  if (!keyboard || keyboard.raw.deviceType !== "KEYBOARD") throw new Error(`Not a keyboard: ${keyboardId}`);
  await saveConfig({ defaults: { deviceIds: [mouseId, keyboardId] } });
  console.log(`Saved defaults: ${mouse.name} + ${keyboard.name}`);
  process.exit(0);
}

if (command === "targets") {
  const mappings = await Promise.all(
    (await selectedDevices(client, args)).map((device) => hostMap(client, device)),
  );
  for (const { device, hosts } of mappings) {
    console.log(device.name);
    if (hosts.length === 0) {
      console.log("  No paired Easy-Switch hosts detected");
      continue;
    }
    for (const host of hosts) {
      const marker = host.connected ? " (current)" : "";
      console.log(`  channel ${host.index + 1}: ${host.name}${marker}`);
    }
  }
  process.exit(0);
}

if (command === "switch-to") {
  const targetName = args.find((arg) => !arg.startsWith("--"));
  if (!targetName) throw new Error("switch-to requires a computer name");
  if (!args.includes("--yes")) {
    throw new Error(
      `Refusing to switch to ${targetName} without --yes. Ensure it is awake.`,
    );
  }

  const mappings = await Promise.all((await selectedDevices(client, args)).map((device) => hostMap(client, device)));
  const destinations = mappings.map(({ device, hosts }) => ({
    device,
    host: hosts.find(
      (candidate) => candidate.name.toLowerCase() === targetName.toLowerCase(),
    ),
  }));
  const missing = destinations.filter(({ host }) => !host);
  if (missing.length > 0) {
    throw new Error(
      `${targetName} is not paired on: ${missing.map(({ device }) => device.name).join(", ")}`,
    );
  }

  // Switch pointing devices first so the keyboard remains available if the
  // second command cannot be delivered for any reason.
  destinations.sort(({ device: left }, { device: right }) =>
    left.raw.deviceType === "KEYBOARD" ? 1 : right.raw.deviceType === "KEYBOARD" ? -1 : 0,
  );
  for (const { device, host } of destinations) {
    if (host.connected) {
      console.log(`${device.name}: already connected to ${targetName}`);
      continue;
    }
    const payload = {
      "@type": "type.googleapis.com/logi.protocol.devices.ChangeHost",
      host: host.index,
    };
    responsePayload(await client.set(`/change_host/${device.id}/host`, payload));
    console.log(`${device.name}: switched to ${targetName} (channel ${host.index + 1})`);
  }
  process.exit(0);
}

if (command === "switch") {
  const channel = Number(args[0]);
  if (![1, 2, 3].includes(channel)) {
    throw new Error("switch requires channel 1, 2, or 3");
  }

  const yes = args.includes("--yes");
  if (!yes) {
    throw new Error(
      "Refusing to switch without --yes. Ensure the target computer is awake.",
    );
  }
  const devices = await selectedDevices(client, args);
  const mappings = await Promise.all(devices.map((device) => hostMap(client, device)));
  const targetHosts = mappings.map(({ device, hosts }) => ({
    device,
    host: hosts.find((host) => host.index === channel - 1),
  }));
  const missing = targetHosts.filter(({ host }) => !host);
  if (missing.length > 0) {
    throw new Error(
      `Channel ${channel} is not paired on: ${missing.map(({ device }) => device.name).join(", ")}`,
    );
  }
  const names = new Set(targetHosts.map(({ host }) => host.name));
  if (names.size > 1) {
    throw new Error(
      `Channel ${channel} points to different computers (${[...names].join(", ")}). Use switch-to or --device.`,
    );
  }
  const deviceIds = devices.map((device) => device.id);

  const payload = {
    "@type": "type.googleapis.com/logi.protocol.devices.ChangeHost",
    host: channel - 1,
  };
  for (const deviceId of deviceIds) {
    const response = await client.set(`/change_host/${deviceId}/host`, payload);
    responsePayload(response);
    console.log(`Switched ${deviceId} to channel ${channel}`);
  }
  process.exit(0);
}

usage();
process.exitCode = 1;
