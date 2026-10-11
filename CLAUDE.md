# DSVideo
Video streaming server packaged as a Synology DSM NAS package: personal library, transcoding, remote playback.
Stack: Go, Node.js, Synology SPK packaging
Rules:
- Build must produce a valid DSM-installable SPK.
- Runs on NAS hardware: watch memory and CPU.
- No external runtime deps; bundle everything.
Docs: docs/design-spec.md, docs/api/.
