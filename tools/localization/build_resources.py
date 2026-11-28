#!/usr/bin/env python3
"""Validate the reviewed interface catalog and emit small, offline iOS tables."""
from pathlib import Path
from collections import Counter
import argparse
import json
import re

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ['en', 'zh-Hant', 'ja', 'ko']
PRINTF = re.compile(r'%(?:(\d+)\$)?([-+ #0]*\d*(?:\.\d+)?)?(ll|l|hh|h|z|t|j)?([diuoxXfFeEgGaAcCsSp@])')
TOKENS = re.compile(r'\{#\d+\}')


def placeholders(value):
    # A positional specifier may reorder values, but not change their types.
    output = []
    ordinal = 0
    for match in PRINTF.finditer(value.replace('%%', '')):
        ordinal += 1
        output.append((int(match[1]) if match[1] else ordinal, match[3] or '', match[4]))
    return Counter(output), Counter(TOKENS.findall(value))


def validate(catalog):
    for key, entry in catalog.items():
        expected = placeholders(key)
        for language in LANGUAGES:
            value = entry[language]
            if not value or placeholders(value) != expected:
                raise ValueError(f'Empty translation or changed placeholders: {language} {key!r}')
            if value.count('\n') != key.count('\n'):
                raise ValueError(f'Changed line breaks: {language} {key!r}')


def write_strings(path, entries):
    def quote(value): return json.dumps(value, ensure_ascii=False)
    body = '// Interface text only. Generated from tools/localization/translations.json.\n'
    body += '\n'.join(f'{quote(key)} = {quote(value)};' for key, value in sorted(entries.items())) + '\n'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--catalog', type=Path, default=Path(__file__).with_name('translations.json'))
    parser.add_argument('--output', type=Path, default=ROOT/'SituationVoicePlayer/Sources/Resources')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    catalog = json.loads(args.catalog.read_text())
    validate(catalog)
    if not args.check:
        privacy = {
            'NSLocalNetworkUsageDescription': '连接你添加的电脑或 NAS，共享目录只在你选择导入或播放时访问。',
            'NSMotionUsageDescription': '根据手机轻微倾斜移动通话背景图片，呈现空间感；动作数据只在本机即时使用。',
            'NSPhotoLibraryAddUsageDescription': '将你选择的收听报告图片保存到相册。',
        }
        for language in ['zh-Hans'] + LANGUAGES:
            entries = {key: key if language == 'zh-Hans' else entry[language] for key, entry in catalog.items()}
            write_strings(args.output/f'{language}.lproj/Localizable.strings', entries)
            write_strings(args.output/f'{language}.lproj/InfoPlist.strings', {name: entries[key] for name, key in privacy.items()})
    print(f'Validated {len(catalog)} interface keys × 5 languages.')


if __name__ == '__main__': main()
