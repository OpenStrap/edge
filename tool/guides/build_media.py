#!/usr/bin/env python3
"""Build review GIFs/contact sheets from capture_activity.dart manifests.

Run with ImageMagick on PATH, e.g. nix shell nixpkgs#imagemagick -c python3
 tool/guides/build_media.py /home/user/pr716-media
No images are checked into the repository.
"""
import argparse
import json
from pathlib import Path
import struct
import subprocess


def png_size(path):
    with path.open('rb') as stream:
        header = stream.read(24)
    if header[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Invalid PNG: {path}')
    return struct.unpack('>II', header[16:24])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    root = args.directory.resolve()
    manifests = sorted(root.glob('*/manifest.json'))
    if len(manifests) != 8:
        raise ValueError(f'Expected eight guides, found {len(manifests)}')
    (root / 'gifs').mkdir(exist_ok=True)
    for manifest in manifests:
        data = json.loads(manifest.read_text())
        directory = manifest.parent
        for step in data['steps']:
            for name in step['pngPaths'].values():
                if png_size(directory / name) != (1082, 2402):
                    raise ValueError(f'Wrong capture dimensions: {name}')
        if png_size(directory / data['offPath']['file']) != (1082, 2402):
            raise ValueError(f'Wrong off-path dimensions: {directory}')
        sequence = data['sequence']
        frames = sequence['frames']
        if frames[-1]['phase'] != 'Done card':
            raise ValueError(f'Path does not end with Done: {directory}')
        for i, frame in enumerate(frames):
            if frame['timeMs'] != (i + 1) * 100:
                raise ValueError(f'Missing 100ms sample: {frame}')
            if png_size(directory / frame['path']) != (412, 915):
                raise ValueError(f'Wrong sequence dimensions: {frame}')
        gif = root / 'gifs' / f"{data['guideId']}.gif"
        subprocess.run([
            'magick', '-delay', '10', '-loop', '0',
            *[str(directory / frame['path']) for frame in frames],
            '-resize', '360x', '-colors', '128', '-layers', 'Optimize', str(gif),
        ], check=True)
        if gif.stat().st_size >= 4_000_000:
            raise ValueError(f'GIF exceeds 4 MB: {gif}')
        # All steps side by side, independent of the guide's step count.
        width = 1600 // len(data['steps'])
        subprocess.run([
            'magick',
            *[str(directory / step['pngPaths']['guided']) for step in data['steps']],
            '-resize', f'{width}x', '+append', str(directory / 'sheet.png'),
        ], check=True)
        data['contactSheet'] = 'sheet.png'
        sequence['gifSize'] = [360, 800]
        sequence['gifBytes'] = gif.stat().st_size
        manifest.write_text(json.dumps(data, indent=2) + '\n')
        print(f"{data['guideId']}: {len(data['steps'])} steps, "
              f"{len(frames)} samples, GIF {gif.stat().st_size:,} bytes", flush=True)


if __name__ == '__main__':
    main()
