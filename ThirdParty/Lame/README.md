# LAME encoder integration

Upstream: https://lame.sourceforge.io/download.php
Source archive: https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz
Version: 4.0, official SourceForge release dated 2026-07-11; retrieved 2026-11-17.

`lame-4.0/` is the complete unmodified upstream source distribution, including its COPYING, AUTHORS, ChangeLog, headers and build files. `Package.swift`, `config/config.h` and `include/CLame.h` are the local Apple build adapter. The target builds the portable encoder C files listed by upstream libmp3lame/Makefile.am. It does not build the command-line frontend, link an MPEG decoder, use assembler, or download a binary package. The local config undefines Xcode’s generic `DEBUG` macro inside this encoder target to avoid upstream per-frame diagnostic logging; error reporting remains enabled. Header types and platform sizes are explicit for Apple clang; the implementation's portable fallbacks remain enabled. The App uses this checked-in configuration rather than running autoconf during its build.

The encoder is LGPL version 2 or, at the recipient's option, later. Read upstream `COPYING` and the license headers; this is not the application's license. The App includes the unmodified license as LAME-COPYING.txt and credits LAME under Settings → open-source licenses. No upstream encoder source was modified.

The local Swift package is deliberately replaceable and built from source. The Xcode project's local package reference points to this directory, and the app imports CLame. The full application sources and this adapter are retained alongside it. Follow `docs/BUILD.md` to build all dependencies and relink the App. Review release packaging and the chosen app license before public distribution, including the corresponding source, license notices and replacement/relink material required by LGPL section 6.

Configuration: LAME VBR quality 2, encoder quality 2, no ReplayGain normalization, original mono/stereo order. MP3 sampling rates are chosen from MPEG-supported rates; WAV retains source PCM rate/precision. The final LAME duration/delay/padding header replaces its reserved first frame. Audio is read from a saved CAF, never from playback effects or a newly truncated original track.

Archive and extracted-source SHA-256 records: `provenance.json`. This repository includes all extracted upstream files; it does not include the original archive. Run `python3 scripts/verify-resources.py` from the repository root to verify them. See `docs/BUILD.md` for the complete App rebuild and relink steps.
