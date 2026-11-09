import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { withCamelAliases } from '../src/lib/ipcArgs.ts';

function urlToPath(url) {
  let p = new URL(url).pathname;
  if (process.platform === 'win32' && /^\/[a-zA-Z]:/.test(p)) {
    p = p.slice(1);
  }
  return decodeURIComponent(p);
}

const testDir = urlToPath(new URL('.', import.meta.url));
const frontendDir = path.resolve(testDir, '..');
const repoRoot = path.resolve(frontendDir, '..');
const srcTauriSrc = path.resolve(repoRoot, 'src-tauri', 'src');
const frontendSrc = path.resolve(frontendDir, 'src');

function findFiles(dir, extensions) {
  const files = [];
  if (!fs.existsSync(dir)) return files;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...findFiles(fullPath, extensions));
    } else if (entry.isFile()) {
      if (extensions.some((ext) => entry.name.endsWith(ext))) {
        files.push(fullPath);
      }
    }
  }
  return files;
}

function parseRustCommands(rustFiles) {
  const rustCommands = new Map();
  const attrRegex = /#\s*\[\s*tauri\s*::\s*command(?:\s*\([\s\S]*?\))?\s*\]/g;

  for (const filePath of rustFiles) {
    const content = fs.readFileSync(filePath, 'utf8');
    attrRegex.lastIndex = 0;
    let match;

    while ((match = attrRegex.exec(content)) !== null) {
      let pos = match.index + match[0].length;

      while (pos < content.length) {
        const wsMatch = /^\s+/.exec(content.slice(pos));
        if (wsMatch) {
          pos += wsMatch[0].length;
          continue;
        }
        if (content.startsWith('//', pos)) {
          const nlIdx = content.indexOf('\n', pos);
          pos = nlIdx === -1 ? content.length : nlIdx + 1;
          continue;
        }
        if (content.startsWith('/*', pos)) {
          const endComment = content.indexOf('*/', pos);
          pos = endComment === -1 ? content.length : endComment + 2;
          continue;
        }
        if (content.startsWith('#[', pos)) {
          const closeBracket = content.indexOf(']', pos);
          pos = closeBracket === -1 ? content.length : closeBracket + 1;
          continue;
        }
        break;
      }

      const fnMatch = /^(?:pub(?:\s*\([^)]*\))?\s+)?(?:async\s+)?fn\s+([a-zA-Z0-9_]+)\s*\(/.exec(
        content.slice(pos)
      );
      if (!fnMatch) continue;

      const cmdName = fnMatch[1];
      let paramPos = pos + fnMatch[0].length;
      let round = 1;
      let angle = 0;
      let square = 0;
      let paramStart = paramPos;
      const rawParams = [];

      while (paramPos < content.length && round > 0) {
        const ch = content[paramPos];
        if (ch === '<') {
          angle++;
        } else if (ch === '>') {
          if (angle > 0) angle--;
        } else if (ch === '[') {
          square++;
        } else if (ch === ']') {
          if (square > 0) square--;
        } else if (ch === '(') {
          round++;
        } else if (ch === ')') {
          round--;
          if (round === 0) {
            const param = content.slice(paramStart, paramPos).trim();
            if (param) rawParams.push(param);
            break;
          }
        } else if (ch === ',' && round === 1 && angle === 0 && square === 0) {
          const param = content.slice(paramStart, paramPos).trim();
          if (param) rawParams.push(param);
          paramStart = paramPos + 1;
        }
        paramPos++;
      }

      attrRegex.lastIndex = paramPos;

      const cmdParams = [];
      for (const rawParam of rawParams) {
        const clean = rawParam
          .replace(/\/\*[\s\S]*?\*\//g, '')
          .replace(/\/\/[^\n]*/g, '')
          .trim();
        const colonIdx = clean.indexOf(':');
        if (colonIdx === -1) continue;

        const rustName = clean.slice(0, colonIdx).trim().replace(/^mut\s+/, '');
        const typeText = clean.slice(colonIdx + 1).trim();

        if (
          typeText.includes('State<') ||
          typeText.includes('AppHandle') ||
          typeText.includes('Window') ||
          typeText.includes('Webview') ||
          typeText.includes('tauri::')
        ) {
          continue;
        }

        const required = !typeText.startsWith('Option<');
        const jsKey = rustName.includes('_')
          ? rustName.replace(/_([a-z0-9])/g, (_, c) => c.toUpperCase())
          : rustName;

        cmdParams.push({ rustName, jsKey, required });
      }

      rustCommands.set(cmdName, cmdParams);
    }
  }

  return rustCommands;
}

function extractObjectLiteral(content, braceStart) {
  let depth = 1;
  let inSingle = false;
  let inDouble = false;
  let inTemplate = false;
  let templateDepths = [];
  let inLineComment = false;
  let inBlockComment = false;

  let i = braceStart + 1;
  let endBrace = -1;

  while (i < content.length) {
    const ch = content[i];
    const next = content[i + 1];

    if (inLineComment) {
      if (ch === '\n') inLineComment = false;
    } else if (inBlockComment) {
      if (ch === '*' && next === '/') {
        inBlockComment = false;
        i++;
      }
    } else if (inSingle) {
      if (ch === '\\') i++;
      else if (ch === "'") inSingle = false;
    } else if (inDouble) {
      if (ch === '\\') i++;
      else if (ch === '"') inDouble = false;
    } else if (inTemplate) {
      if (ch === '\\') i++;
      else if (ch === '`') inTemplate = false;
      else if (ch === '$' && next === '{') {
        templateDepths.push(depth);
        depth++;
        inTemplate = false;
        i++;
      }
    } else {
      if (ch === '/' && next === '/') {
        inLineComment = true;
        i++;
      } else if (ch === '/' && next === '*') {
        inBlockComment = true;
        i++;
      } else if (ch === "'") {
        inSingle = true;
      } else if (ch === '"') {
        inDouble = true;
      } else if (ch === '`') {
        inTemplate = true;
      } else if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
        if (depth === 0) {
          endBrace = i;
          break;
        }
        if (templateDepths.length > 0 && depth === templateDepths[templateDepths.length - 1]) {
          templateDepths.pop();
          inTemplate = true;
        }
      }
    }
    i++;
  }

  if (endBrace === -1) return null;
  return content.slice(braceStart + 1, endBrace);
}

function splitTopLevelEntries(text) {
  const entries = [];
  let start = 0;
  let depthBrace = 0;
  let depthParen = 0;
  let depthBracket = 0;
  let inSingle = false;
  let inDouble = false;
  let inTemplate = false;
  let templateDepths = [];
  let inLineComment = false;
  let inBlockComment = false;

  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    const next = text[i + 1];

    if (inLineComment) {
      if (ch === '\n') inLineComment = false;
    } else if (inBlockComment) {
      if (ch === '*' && next === '/') {
        inBlockComment = false;
        i++;
      }
    } else if (inSingle) {
      if (ch === '\\') i++;
      else if (ch === "'") inSingle = false;
    } else if (inDouble) {
      if (ch === '\\') i++;
      else if (ch === '"') inDouble = false;
    } else if (inTemplate) {
      if (ch === '\\') i++;
      else if (ch === '`') inTemplate = false;
      else if (ch === '$' && next === '{') {
        templateDepths.push(depthBrace);
        depthBrace++;
        inTemplate = false;
        i++;
      }
    } else {
      if (ch === '/' && next === '/') {
        inLineComment = true;
        i++;
      } else if (ch === '/' && next === '*') {
        inBlockComment = true;
        i++;
      } else if (ch === "'") {
        inSingle = true;
      } else if (ch === '"') {
        inDouble = true;
      } else if (ch === '`') {
        inTemplate = true;
      } else if (ch === '{') {
        depthBrace++;
      } else if (ch === '}') {
        depthBrace--;
        if (templateDepths.length > 0 && depthBrace === templateDepths[templateDepths.length - 1]) {
          templateDepths.pop();
          inTemplate = true;
        }
      } else if (ch === '(') {
        depthParen++;
      } else if (ch === ')') {
        depthParen--;
      } else if (ch === '[') {
        depthBracket++;
      } else if (ch === ']') {
        depthBracket--;
      } else if (ch === ',' && depthBrace === 0 && depthParen === 0 && depthBracket === 0) {
        entries.push(text.slice(start, i));
        start = i + 1;
      }
    }
    i++;
  }
  const last = text.slice(start);
  if (last.trim()) entries.push(last);
  return entries;
}

function parseObjectLiteralKeys(objText) {
  const entries = splitTopLevelEntries(objText);
  const keys = [];
  let hasSpread = false;

  for (const rawEntry of entries) {
    const entry = rawEntry.trim();
    if (!entry) continue;

    if (entry.startsWith('...')) {
      hasSpread = true;
      break;
    }

    let colonIdx = -1;
    let depthBrace = 0;
    let depthParen = 0;
    let depthBracket = 0;
    let inSingle = false;
    let inDouble = false;
    let inTemplate = false;
    let templateDepths = [];

    for (let i = 0; i < entry.length; i++) {
      const ch = entry[i];
      if (inSingle) {
        if (ch === '\\') i++;
        else if (ch === "'") inSingle = false;
      } else if (inDouble) {
        if (ch === '\\') i++;
        else if (ch === '"') inDouble = false;
      } else if (inTemplate) {
        if (ch === '\\') i++;
        else if (ch === '`') inTemplate = false;
        else if (ch === '$' && entry[i + 1] === '{') {
          templateDepths.push(depthBrace);
          depthBrace++;
          inTemplate = false;
          i++;
        }
      } else {
        if (ch === "'") inSingle = true;
        else if (ch === '"') inDouble = true;
        else if (ch === '`') inTemplate = true;
        else if (ch === '{') depthBrace++;
        else if (ch === '}') {
          depthBrace--;
          if (templateDepths.length > 0 && depthBrace === templateDepths[templateDepths.length - 1]) {
            templateDepths.pop();
            inTemplate = true;
          }
        } else if (ch === '(') depthParen++;
        else if (ch === ')') depthParen--;
        else if (ch === '[') depthBracket++;
        else if (ch === ']') depthBracket--;
        else if (ch === ':' && depthBrace === 0 && depthParen === 0 && depthBracket === 0) {
          colonIdx = i;
          break;
        }
      }
    }

    let rawKey = colonIdx !== -1 ? entry.slice(0, colonIdx) : entry;
    rawKey = rawKey.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '').trim();

    if (rawKey.startsWith('...')) {
      hasSpread = true;
      break;
    }

    let key = rawKey;
    if ((key.startsWith("'") && key.endsWith("'")) || (key.startsWith('"') && key.endsWith('"'))) {
      key = key.slice(1, -1);
    }

    if (key) {
      keys.push(key);
    }
  }

  return { keys, hasSpread };
}

function parseJsCallSites(jsFiles) {
  const callSites = [];
  const invokeRegex = /\binvoke\s*(?:<[^()]*?>)?\s*\(\s*['"]([a-z_0-9]+)['"]\s*(?:,\s*\{|\))/g;

  for (const filePath of jsFiles) {
    const content = fs.readFileSync(filePath, 'utf8');
    const relPath = path.relative(frontendDir, filePath).replace(/\\/g, '/');
    invokeRegex.lastIndex = 0;
    let match;

    while ((match = invokeRegex.exec(content)) !== null) {
      const cmdName = match[1];
      const line = content.slice(0, match.index).split('\n').length;
      const hasObjectLiteral = match[0].endsWith('{');

      if (!hasObjectLiteral) {
        callSites.push({
          cmdName,
          line,
          relPath,
          hasObjectLiteral: false,
          keys: [],
          hasSpread: false,
        });
        continue;
      }

      const braceStart = match.index + match[0].length - 1;
      const objText = extractObjectLiteral(content, braceStart);
      if (objText === null) continue;

      const { keys, hasSpread } = parseObjectLiteralKeys(objText);
      callSites.push({
        cmdName,
        line,
        relPath,
        hasObjectLiteral: true,
        keys,
        hasSpread,
      });
    }
  }

  return callSites;
}

const rustFiles = findFiles(srcTauriSrc, ['.rs']);
const jsFiles = findFiles(frontendSrc, ['.svelte', '.ts']);
const rustCommands = parseRustCommands(rustFiles);
const callSites = parseJsCallSites(jsFiles);

const violations = [];
let callSiteCount = 0;

for (const call of callSites) {
  callSiteCount++;
  const { cmdName, line, relPath, hasObjectLiteral, keys, hasSpread } = call;

  if (!rustCommands.has(cmdName)) {
    continue;
  }

  if (hasSpread) {
    continue;
  }

  const expectedParams = rustCommands.get(cmdName);
  const requiredParams = expectedParams.filter((p) => p.required);

  if (!hasObjectLiteral) {
    for (const param of requiredParams) {
      violations.push(
        `${relPath}:${line} invoke('${cmdName}') is missing required argument ${param.jsKey} (Rust parameter ${param.rustName}); keys passed: `
      );
    }
    continue;
  }

  const effectiveKeys = Object.keys(
    withCamelAliases(Object.fromEntries(keys.map((k) => [k, true])))
  );

  for (const param of requiredParams) {
    if (!effectiveKeys.includes(param.jsKey)) {
      const keysPassed = keys.join(', ');
      violations.push(
        `${relPath}:${line} invoke('${cmdName}') is missing required argument ${param.jsKey} (Rust parameter ${param.rustName}); keys passed: ${keysPassed}`
      );
    }
  }
}

test('withCamelAliases unit cases', () => {
  const snake = withCamelAliases({ addon_id: '123' });
  assert.equal(snake.addon_id, '123');
  assert.equal(snake.addonId, '123');

  const single = withCamelAliases({ flavour: 'retail' });
  assert.deepEqual(single, { flavour: 'retail' });

  const existing = withCamelAliases({ addon_id: 'snake_val', addonId: 'camel_val' });
  assert.equal(existing.addonId, 'camel_val');
  assert.equal(existing.addon_id, 'snake_val');

  const nested = { override_hold: true };
  const res = withCamelAliases({ params: nested });
  assert.equal(res.params.override_hold, true);
  assert.equal(res.params.overrideHold, undefined);
  assert.equal(res.params, nested);
});

test('Test A: violation list is empty', () => {
  assert.equal(
    violations.length,
    0,
    `Found ${violations.length} IPC contract violation(s):\n${violations.join('\n')}`
  );
});

test('Test B: found at least 20 Rust commands and at least 20 call sites', () => {
  assert.ok(
    rustCommands.size >= 20,
    `Expected at least 20 Rust commands, found ${rustCommands.size}`
  );
  assert.ok(
    callSiteCount >= 20,
    `Expected at least 20 call sites, found ${callSiteCount}`
  );
});
