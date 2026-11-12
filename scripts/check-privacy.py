#!/usr/bin/env python3
"""SDK-owned declarations only; no claim about the host application's full privacy practices."""
import argparse
import json
import plistlib
from pathlib import Path

ANALYTICS = 'NSPrivacyCollectedDataTypePurposeAnalytics'
FUNCTIONALITY = 'NSPrivacyCollectedDataTypePurposeAppFunctionality'
KINDS = {'UserID', 'DeviceID', 'ProductInteraction', 'CrashData'}


def load(path):
    data = Path(path).read_bytes()
    return json.loads(data) if str(path).endswith('.json') else plistlib.loads(data)


def common(document):
    entries = document['NSPrivacyCollectedDataTypes']
    assert len(entries) == 4
    rows = {row['NSPrivacyCollectedDataType']: row for row in entries}
    assert set(rows) == {'NSPrivacyCollectedDataType' + kind for kind in KINDS}
    for kind in KINDS:
        row = rows['NSPrivacyCollectedDataType' + kind]
        assert row['NSPrivacyCollectedDataTypeLinked'] is True, kind
        assert row['NSPrivacyCollectedDataTypeTracking'] is False, kind
        purposes = {ANALYTICS, FUNCTIONALITY} if kind == 'CrashData' else {ANALYTICS}
        assert set(row['NSPrivacyCollectedDataTypePurposes']) == purposes, kind
    return rows


def check_manifest(path, platform, canonical=None):
    document = load(path)
    assert document.get('NSPrivacyTracking', False) is False
    assert document.get('NSPrivacyTrackingDomains', []) == []
    rows = common(document)
    reasons = document.get('NSPrivacyAccessedAPITypes', [])
    expected = [{'NSPrivacyAccessedAPIType': 'NSPrivacyAccessedAPICategoryFileTimestamp',
                 'NSPrivacyAccessedAPITypeReasons': ['C617.1']}] if platform in {'ios', 'flutter'} else []
    assert reasons == expected, 'Required-reason declarations must match the actual platform APIs'
    if canonical is not None:
        assert rows == common(load(canonical)), 'Shared collection declarations differ'
    return rows


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--platform', choices=['ios', 'flutter', 'rn'], required=True)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--canonical')
    args = parser.parse_args()
    check_manifest(args.manifest, args.platform, args.canonical)
    print('SDK linked-data declarations and platform-specific required reasons passed')
