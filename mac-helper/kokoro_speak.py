#!/usr/bin/env python3
"""
Co/Pad Kokoro bridge
--------------------
Reads text on stdin, synthesizes speech with Kokoro-82M, and plays it through
the Mac speakers (afplay). Used by the Node helper for the "Claude speaks back"
side of Co/Pad's voice conversation.

Setup (once):
    python3 -m pip install kokoro soundfile numpy
    brew install espeak-ng          # phonemizer backend Kokoro needs

Config via env:
    KOKORO_LANG   language code — 'a' US English (default), 'b' UK, 'f' French,
                  'e' Spanish, 'i' Italian, 'p' Portuguese, 'j' Japanese, 'z' Chinese
    KOKORO_VOICE  voice name (default 'af_heart')

Exit codes: 0 ok/nothing to say · 3 Kokoro not installed · other = error.
"""
import os
import sys
import subprocess
import tempfile


def to_numpy(a):
    try:
        import torch
        if isinstance(a, torch.Tensor):
            return a.detach().cpu().numpy()
    except Exception:
        pass
    return a


def main() -> int:
    text = sys.stdin.read().strip()
    if not text:
        return 0

    lang = os.environ.get("KOKORO_LANG", "a")
    voice = os.environ.get("KOKORO_VOICE", "af_heart")

    try:
        from kokoro import KPipeline
        import soundfile as sf
        import numpy as np
    except Exception as e:  # not installed
        sys.stderr.write(f"kokoro not available: {e}\n")
        return 3

    try:
        pipeline = KPipeline(lang_code=lang)
        chunks = [to_numpy(audio) for _, _, audio in pipeline(text, voice=voice)]
        chunks = [c for c in chunks if c is not None and len(c) > 0]
        if not chunks:
            return 0
        audio = np.concatenate(chunks) if len(chunks) > 1 else chunks[0]
        if audio is None or len(audio) == 0:
            return 0

        path = tempfile.NamedTemporaryFile(suffix=".wav", delete=False).name
        try:
            sf.write(path, audio, 24000)
            subprocess.run(["afplay", path], check=False)
        finally:
            try:
                os.unlink(path)
            except OSError:
                pass
        return 0
    except Exception as e:
        sys.stderr.write(f"synthesis failed: {e}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
