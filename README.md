# Linux-Storage-Santbox

A small lab project for building and managing a Linux storage sandbox with loop devices, LVM, XFS, and NFS.

## What this repo contains

- `scripts/` — setup, teardown, checks, and data generation
- `docs/` — explanations, notes, and troubleshooting
- `powershell/` — Windows automation for VM snapshots
- `assets/` — diagrams and screenshots

## Quick start

1. Review the setup guide:
   - `docs/sandbox-setup.md`
2. Build the sandbox:
   - `scripts/sandbox-setup.sh`
3. Generate messy data:
   - `scripts/generate-messy-data.sh`
4. Tear down when done:
   - `scripts/sandbox-teardown.sh`

## Project flow

- Create loop-backed disks
- Build LVM PV/VG/LV
- Create XFS filesystem
- Export via NFS
- Practice auditing and cleanup

## Notes

This repo was reorganized for clarity while preserving the original lab materials and scripts.
