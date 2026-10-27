# NFS Storage Sandbox

This document explains how the storage sandbox is built from the ground up.

## Overview

The lab creates a virtual storage stack:

- loopback disk images
- LVM physical volumes and volume groups
- logical volume
- XFS filesystem
- NFS export

The main scripts are:

- `scripts/sandbox-setup.sh`
- `scripts/sandbox-teardown.sh`

## Setup flow

The setup script does the following:

1. Creates sparse loop devices
2. Initializes LVM on them
3. Creates a logical volume
4. Formats it with XFS
5. Mounts it at `/srv/nfs/share`
6. Exports it via NFS

## Cleanup flow

The teardown script reverses the build process:

- unmount the share
- disable the export
- remove the LVM volume
- detach loop devices
- delete the images

## Related files

- `scripts/sandbox-setup.sh`
- `scripts/sandbox-teardown.sh`
- `scripts/generate-messy-data.sh`
