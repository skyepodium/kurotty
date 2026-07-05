import { spawn } from 'node:child_process';
import { basename } from 'node:path';

const KUROTTY_BINARY = '/Applications/kurotty.app/Contents/MacOS/kurotty';
const MAX_BODY_CHARACTERS = 240;

function normalizedText(value) {
  if (typeof value !== 'string') return '';
  return value
    .replace(/\x1b(?:[@-Z\\-_]|\[[0-9;]*[A-Za-z])/g, '')
    .replace(/\r/g, '\n')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .join(' ')
    .trim();
}

function firstText(...values) {
  for (const value of values) {
    const text = normalizedText(value);
    if (text) return text;
  }
  return '';
}

function truncatedBody(text) {
  if (text.length <= MAX_BODY_CHARACTERS) return text;
  return `${text.slice(0, MAX_BODY_CHARACTERS - 1)}…`;
}

function sessionName(event) {
  const context = event.context || {};
  const fromContext = firstText(
    context.session_name,
    context.project_name,
    context.projectName,
    context.tmuxSession
  );
  if (fromContext) return fromContext;

  const projectPath = firstText(context.project_path, context.projectPath);
  if (projectPath) return basename(projectPath);
  return 'kurotty';
}

function notificationBody(event) {
  const context = event.context || {};
  switch (event.event) {
    case 'turn-complete':
      return firstText(
        context.output_preview,
        context.last_assistant_message,
        context['last-assistant-message'],
        context.message,
        context.text
      );
    case 'needs-input':
      return firstText(context.text, context.output_preview, context.question, context.message);
    case 'ask-user-question':
      return firstText(context.question, context.prompt, context.message);
    default:
      return '';
  }
}

function commandPath() {
  return process.env.KUROTTY_NOTIFY_COMMAND || KUROTTY_BINARY;
}

async function sendToKurotty(payload) {
  const child = spawn(commandPath(), ['--notify-json', JSON.stringify(payload)], {
    stdio: 'ignore',
    detached: false,
  });
  const status = await new Promise((resolve) => {
    child.on('error', (error) => resolve({ code: -1, error }));
    child.on('close', (code) => resolve({ code: code ?? -1 }));
  });
  if (status.code !== 0) {
    throw status.error || new Error(`kurotty notify exited with ${status.code}`);
  }
}

export async function onHookEvent(event, sdk) {
  const body = notificationBody(event);
  if (!body) return;

  const payload = {
    title: 'Alert',
    body: `Session ${sessionName(event)} #1: ${truncatedBody(body)}`,
  };

  await sendToKurotty(payload);
  await sdk.log.info('sent kurotty notification', {
    event: event.event,
    turn_id: event.turn_id || null,
    body_chars: body.length,
  });
}
