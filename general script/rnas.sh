#!/bin/bash
# rnas.sh - Remote NAS Automation Script

set -euo pipefail
HOSTNAME=$(hostname)
BASE_DIR="/var/rnas"
MOUNT_DIR="/mnt/rnas/$HOSTNAME"
IMG="$BASE_DIR/$HOSTNAME.img"
COPY_IMG="$BASE_DIR/$HOSTNAME-copy.img"
DISK_FLAG="$BASE_DIR/DISK_EXIST"
RSYNC_DEST="ip.hirakamu.my.id:/receive"
RSYNC_PORT=9901

usage() {
    echo "Usage: $0 {init|backup|delete|purge|copy-only|expand [int increment]}"
    exit 1
}

# Ensure BASE_DIR exists
mkdir -p "$BASE_DIR"

init() {
    if [ -f "$DISK_FLAG" ]; then
        echo "ERROR: RNAS already initialized! ($DISK_FLAG exists)"
        exit 1
    fi

    read -p "RNAS will initialize on this system. Continue? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

    # Copy this script to /var/rnas
    cp "$0" "$BASE_DIR/"

    # Optionally, add to PATH via symlink
    ln -sf "$BASE_DIR/$(basename $0)" /usr/local/bin/rnas

    # Create disk image
    fallocate -l 10G "$IMG" || dd if=/dev/zero of="$IMG" bs=1M count=0 seek=10240

    # Make filesystem
    mkfs.ext4 -F "$IMG"

    # Create mount point
    mkdir -p "$MOUNT_DIR"
    # Add to fstab if not present
    if ! grep -q "$IMG" /etc/fstab; then
        echo "$IMG $MOUNT_DIR ext4 loop 0 0" >> /etc/fstab
    fi

    mount "$MOUNT_DIR"
    touch "$DISK_FLAG"

    # Initialize cronjob: backup every day at 2AM
    (crontab -l 2>/dev/null; echo "0 2 * * * /usr/local/bin/rnas backup") | crontab -

    echo "Initialization complete. Disk mounted at $MOUNT_DIR"
}

backup() {
    [ -f "$DISK_FLAG" ] || { echo "ERROR: RNAS not initialized."; exit 1; }

    echo "Freezing filesystem..."
    if command -v fsfreeze >/dev/null 2>&1; then
        fsfreeze -f "$MOUNT_DIR"
    fi

    echo "Copying disk..."
    cp --sparse=always "$IMG" "$COPY_IMG"

    echo "Unfreezing filesystem..."
    if command -v fsfreeze >/dev/null 2>&1; then
        fsfreeze -u "$MOUNT_DIR"
    fi

    echo "Syncing to remote (incremental, block-level)..."
    rsync -avS --inplace --partial --progress \
          --block-size=4096 \
          --no-whole-file \
          -e "ssh -p $RSYNC_PORT" \
          "$COPY_IMG" "$RSYNC_DEST"

    echo "Removing temporary copy..."
    rm -f "$COPY_IMG"

    echo "Backup completed."
}

copy_only() {
    [ -f "$DISK_FLAG" ] || { echo "ERROR: RNAS not initialized."; exit 1; }

    echo "Copying disk only..."
    cp --sparse=always "$IMG" "$COPY_IMG"
    echo "Copy created at $COPY_IMG"
}

delete() {
    [ -f "$DISK_FLAG" ] || { echo "ERROR: RNAS not initialized."; exit 1; }

    read -p "Are you sure you want to delete the RNAS disk? This action cannot be undone. Continue? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

    backup

    echo "Deleting RNAS disk..."
    umount "$MOUNT_DIR" || true
    rm -f "$IMG" "$DISK_FLAG"

    # Remove fstab entry
    sed -i "\|$IMG|d" /etc/fstab
    rmdir "$MOUNT_DIR" || true

    echo "Delete procedure completed."
}

purge() {
    [ -f "$DISK_FLAG" ] || { echo "ERROR: RNAS not initialized."; exit 1; }

    read -p "RNAS will be purged without backup. Continue? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

    read -p "This is your last chance to abort. Continue? (y/N): " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

    echo "Purging RNAS disk..."
    umount "$MOUNT_DIR" || true
    rm -f "$IMG" "$DISK_FLAG"
    sed -i "\|$IMG|d" /etc/fstab
    rmdir "$MOUNT_DIR" || true

    echo "Purge procedure completed."
}

expand() {
    [ -f "$DISK_FLAG" ] || { echo "ERROR: RNAS not initialized."; exit 1; }
    local increment=${1:-10} # default 10G
    echo "Expanding RNAS image by $increment GB..."
    truncate -s +${increment}G "$IMG"
    echo "Resizing filesystem..."
    resize2fs "$IMG"
    echo "Expansion complete."
}

case ${1:-} in
    init) init ;;
    backup) backup ;;
    delete) delete ;;
    purge) purge ;;
    copy-only) copy_only ;;
    expand) expand "$2" ;;
    *) usage ;;
esac
