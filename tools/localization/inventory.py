#!/usr/bin/env python3
"""Inventory Swift interface literals; never rewrite code without a reviewed list."""
from pathlib import Path
import json
import re

ROOT = Path(__file__).resolve().parents[2]
HAN = re.compile(r'[\u3400-\u9fff]')


def strings(source):
    records = []

    def block_comment(i):
        depth = 1
        i += 2
        while i < len(source) and depth:
            if source.startswith('/*', i): depth += 1; i += 2
            elif source.startswith('*/', i): depth -= 1; i += 2
            else: i += 1
        return i

    def expression(i):
        depth = 1
        begin = i
        while i < len(source):
            if source.startswith('//', i):
                end = source.find('\n', i); i = len(source) if end < 0 else end
            elif source.startswith('/*', i): i = block_comment(i)
            elif source[i] == '"': i, _, _ = literal(i)
            elif source[i] == '(':
                depth += 1; i += 1
            elif source[i] == ')':
                depth -= 1
                if not depth: return i + 1, source[begin:i]
                i += 1
            else: i += 1
        raise ValueError('unclosed interpolation')

    def literal(start):
        triple = source.startswith('"""', start)
        quote = '"""' if triple else '"'
        i = start + len(quote)
        parts = []; expressions = []
        raw = start > 0 and source[start - 1] == '#'
        while i < len(source):
            if source.startswith(quote, i):
                end = i + len(quote)
                key = ''.join(parts)
                if HAN.search(key) and not raw:
                    line = source.count('\n', 0, start) + 1
                    line_start = source.rfind('\n', 0, start) + 1
                    line_end = source.find('\n', end)
                    records.append(dict(start=start, end=end, line=line, literal=source[start:end],
                                        key=key, expressions=expressions, triple=triple,
                                        context=source[line_start:line_end if line_end >= 0 else len(source)].strip()))
                return end, key, expressions
            if source.startswith('\\(', i) and not raw:
                i, expr = expression(i + 2)
                parts.append('{#%d}' % len(expressions)); expressions.append(expr)
            elif source[i] == '\\' and not raw and i + 1 < len(source):
                escaped = source[i + 1]
                parts.append({'n': '\n', 'r': '\r', 't': '\t', '0': '\0'}.get(escaped, escaped))
                i += 2
            else:
                parts.append(source[i]); i += 1
        raise ValueError('unclosed literal')

    i = 0
    while i < len(source):
        if source.startswith('//', i):
            end = source.find('\n', i); i = len(source) if end < 0 else end
        elif source.startswith('/*', i): i = block_comment(i)
        elif source[i] == '"': i, _, _ = literal(i)
        else: i += 1
    return sorted(records, key=lambda record: record['start'])


def collect():
    result = []
    for folder in ['SituationVoicePlayer/Sources', 'hibiki/Sources/HibikiCore']:
        for path in (ROOT / folder).rglob('*.swift'):
            for record in strings(path.read_text()):
                result.append(dict(path=str(path.relative_to(ROOT)), **record))
    return result


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    values = collect()
    args.output.write_text(json.dumps(values, ensure_ascii=False, indent=2))
    print(f'{len(values)} literals in {len(set(v["path"] for v in values))} source files')
