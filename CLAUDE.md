# DSVideo — Friday Context

## What This Is
Video streaming server packaged as a Synology DSM NAS package. Serves personal video library with transcoding and remote playback.

## Stack
Go · Node.js · Synology DSM packaging

## Critical Rules
- Must package as a valid Synology SPK — build produces a DSM-installable package
- Runs on NAS hardware — performance and memory constraints
- No external runtime dependencies; everything must be bundled

## Ticketmaster ID
`dsvideo`
