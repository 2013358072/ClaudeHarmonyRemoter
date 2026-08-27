/** 用真实 transcript 里的 skill 注入样本验证 normalize 的折叠逻辑 */
import { normalize } from '../src/protocol/normalize.js';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const base = join(homedir(), '.claude', 'projects');
let sample: string | null = null;

outer: for (const d of readdirSync(base)) {
    let files: string[];
    try { files = readdirSync(join(base, d)); } catch { continue; }
    for (const f of files) {
        if (!f.endsWith('.jsonl')) continue;
        let text: string;
        try { text = readFileSync(join(base, d, f), 'utf8'); } catch { continue; }
        if (!text.includes('Base directory for this skill')) continue;
        for (const line of text.split('\n')) {
            if (!line.includes('Base directory for this skill')) continue;
            try {
                const r = JSON.parse(line) as Record<string, unknown>;
                if (r['type'] !== 'user') continue;
                sample = line;
                break outer;
            } catch { /* skip */ }
        }
    }
}

if (!sample) {
    console.log('未找到 skill 注入样本');
    process.exit(0);
}

const rec = JSON.parse(sample) as Record<string, unknown>;
const inner = rec['message'] as Record<string, unknown>;
const content = inner['content'];
const raw = typeof content === 'string'
    ? content
    : (content as Array<Record<string, unknown>>).find(b => b['type'] === 'text')?.['text'] as string;

console.log('原始文本长度:', raw.length);
console.log('首行:', raw.split('\n')[0].slice(0, 90));
console.log();

const { events } = normalize(rec);
console.log('归一化后事件数:', events.length);
for (const e of events) {
    if (e.kind === 'skill') {
        console.log(`  [skill] skillName = ${e.skillName}`);
    } else if (e.kind === 'text') {
        console.log(`  [text] 长度 ${(e.text ?? '').length}`);
    } else {
        console.log(`  [${e.kind}]`);
    }
}
