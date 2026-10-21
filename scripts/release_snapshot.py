"""Normalize release identity and asset digests for promotion verification."""

import json
import sys

release = json.load(sys.stdin)
if release.get('draft') is not True:
    raise ValueError('Release must still be a draft')
expected = {
    'paradoxcli-linux-arm64.tar.gz',
    'paradoxcli-linux-x64.tar.gz',
    'paradoxcli-win-x64.zip',
    'SHA256SUMS',
}
assets = release['assets']
if len(assets) != len(expected) or {a['name'] for a in assets} != expected:
    raise ValueError('Unexpected draft release assets')
snapshot = {
    'id': release['id'],
    'tag': release['tag_name'],
    'assets': sorted([
        {k: asset[k] for k in ('id', 'name', 'size', 'digest', 'updated_at')}
        for asset in assets
    ], key=lambda asset: asset['name']),
}
for asset in snapshot['assets']:
    if not isinstance(asset['digest'], str) or not asset['digest'].startswith('sha256:'):
        raise ValueError('Missing server-side asset digest')
print(json.dumps(snapshot, sort_keys=True))
