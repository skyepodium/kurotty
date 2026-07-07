#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import { appendFileSync, existsSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const DEFAULT_KUROTTY_BINARY = '/Applications/kurotty.app/Contents/MacOS/kurotty';
const DEFAULT_OMX_NOTIFY_HOOK = '/opt/homebrew/lib/node_modules/oh-my-codex/dist/scripts/notify-hook.js';
const MAX_BODY_CHARACTERS = 240;
const SCRIPT_PATH = fileURLToPath(import.meta.url);
const LOG_PATH = process.env.KUROTTY_CODEX_NOTIFY_LOG_PATH
  || join(homedir(), 'Library', 'Logs', 'Kurotty', 'codex-notify.jsonl');

function safeString(value) {
  return typeof value === 'string' ? value : '';
}

function normalizeText(value) {
  return safeString(value)
    .replace(/\x1b(?:[@-Z\\-_]|\[[0-9;?]*[ -/]*[@-~])/g, '')
    .replace(/\r/g, '\n')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .join(' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function firstText(...values) {
  for (const value of values) {
    const text = normalizeText(value);
    if (text) return text;
  }
  return '';
}

function truncate(text) {
  if (text.length <= MAX_BODY_CHARACTERS) return text;
  return `${text.slice(0, MAX_BODY_CHARACTERS - 1)}…`;
}

function parsePayload(rawPayload) {
  if (!rawPayload || rawPayload.startsWith('-')) return null;
  try {
    const parsed = JSON.parse(rawPayload);
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

function parseArguments(argv) {
  const previousNotifyCommands = [];
  let rawPayload = '';

  for (let index = 0; index < argv.length; index += 1) {
    const value = safeString(argv[index]);
    if (value === '--previous-notify') {
      const command = safeString(argv[index + 1]);
      if (command) previousNotifyCommands.push(command);
      index += 1;
      continue;
    }
    rawPayload = value;
  }

  return { rawPayload, previousNotifyCommands };
}

function parsePreviousNotifyCommand(value) {
  try {
    const parsed = JSON.parse(value);
    if (
      Array.isArray(parsed)
      && parsed.length > 0
      && parsed.every((item) => typeof item === 'string')
    ) {
      return parsed;
    }
  } catch {
    // Fall through to the shared failure log below.
  }
  logEvent({ type: 'previous_notify_invalid', command: value });
  return null;
}

function shouldNotify(payload) {
  const type = safeString(payload.type || '').trim().toLowerCase();
  return type === '' || type === 'agent-turn-complete' || type === 'turn-complete';
}

function notificationBody(payload) {
  return firstText(
    payload['last-assistant-message'],
    payload.last_assistant_message,
    payload.lastAssistantMessage,
    payload.output_preview,
    payload.outputPreview,
    payload.body,
    payload.message,
    payload.summary,
    payload.text
  );
}

function projectName(payload) {
  const explicit = firstText(payload.session_name, payload.project_name, payload.projectName);
  if (explicit) return explicit;
  const cwd = firstText(payload.cwd, payload.project_path, payload.projectPath);
  if (!cwd) return 'codex';
  return cwd.split(/[\\/]+/).filter(Boolean).at(-1) || 'codex';
}

function buildKurottyPayload(payload) {
  const body = notificationBody(payload);
  if (!body) return null;
  return {
    title: 'Alert',
    body: `Session ${projectName(payload)} #1: ${truncate(body)}`,
  };
}

function logEvent(event) {
  try {
    mkdirSync(dirname(LOG_PATH), { recursive: true });
    appendFileSync(LOG_PATH, `${JSON.stringify({ timestamp: new Date().toISOString(), ...event })}\n`);
  } catch {
    // Notification logging must never break Codex completion.
  }
}

function kurottyCommand() {
  const configured = safeString(process.env.KUROTTY_NOTIFY_COMMAND).trim();
  if (configured) return configured;
  const bundled = bundledKurottyCommand();
  if (bundled) return bundled;
  return DEFAULT_KUROTTY_BINARY;
}

function bundledKurottyCommand() {
  const resourcesDirectory = dirname(SCRIPT_PATH);
  if (!resourcesDirectory.endsWith('/Contents/Resources')) return '';
  const contentsDirectory = dirname(resourcesDirectory);
  const bundledCommand = join(contentsDirectory, 'MacOS', 'kurotty');
  return existsSync(bundledCommand) ? bundledCommand : '';
}

function deliverToKurotty(payload) {
  if (process.env.KUROTTY_NOTIFY_DRY_RUN === '1') {
    logEvent({ type: 'kurotty_notify_dry_run', payload });
    return true;
  }

  const command = kurottyCommand();
  const result = spawnSync(command, ['--notify-json', JSON.stringify(payload)], {
    stdio: 'ignore',
    env: process.env,
  });
  if (result.status === 0) {
    logEvent({ type: 'kurotty_notify_sent', command, body_chars: payload.body.length });
    return true;
  }

  logEvent({
    type: 'kurotty_notify_failed',
    command,
    status: result.status,
    signal: result.signal || null,
    error: result.error ? result.error.message : null,
  });
  return false;
}

function chainOmxNotify(rawPayload) {
  if (process.env.KUROTTY_NOTIFY_CHAIN_OMX === '0') return;
  const hook = safeString(process.env.KUROTTY_OMX_NOTIFY_HOOK).trim() || DEFAULT_OMX_NOTIFY_HOOK;
  if (!existsSync(hook)) {
    logEvent({ type: 'omx_notify_hook_missing', hook });
    return;
  }

  const result = spawnSync(process.execPath, [hook, rawPayload], {
    stdio: 'ignore',
    env: {
      ...process.env,
      KUROTTY_NOTIFY_WRAPPER_SENT: '1',
    },
  });
  if (result.status !== 0) {
    logEvent({
      type: 'omx_notify_hook_failed',
      hook,
      status: result.status,
      signal: result.signal || null,
      error: result.error ? result.error.message : null,
    });
  }
}

function chainPreviousNotify(rawPayload, encodedCommand) {
  if (process.env.KUROTTY_NOTIFY_CHAIN_PREVIOUS === '0') return;
  const command = parsePreviousNotifyCommand(encodedCommand);
  if (!command) return;

  const [executable, ...args] = command;
  const result = spawnSync(executable, [...args, rawPayload], {
    stdio: 'ignore',
    env: process.env,
  });
  if (result.status === 0) {
    logEvent({ type: 'previous_notify_sent', command: executable });
    return;
  }

  logEvent({
    type: 'previous_notify_failed',
    command: executable,
    status: result.status,
    signal: result.signal || null,
    error: result.error ? result.error.message : null,
  });
}

function main() {
  const { rawPayload, previousNotifyCommands } = parseArguments(process.argv.slice(2));
  const payload = parsePayload(rawPayload);
  if (payload && shouldNotify(payload)) {
    const notification = buildKurottyPayload(payload);
    if (notification) {
      deliverToKurotty(notification);
    } else {
      logEvent({ type: 'kurotty_notify_skipped', reason: 'empty_explicit_payload' });
    }
  }

  chainOmxNotify(rawPayload);
  for (const previousNotifyCommand of previousNotifyCommands) {
    chainPreviousNotify(rawPayload, previousNotifyCommand);
  }
}

main();
