#!/bin/bash

#=============================================================================
# RNAS Management Script
# Purpose: Manage remote NAS disk initialization, backup, deletion, and maintenance
# Version: 1.3
#=============================================================================

set -euo pipefail

# Version
VERSION="1.3"

# Configuration
RNAS_DIR="/var/rnas"
DISK_EXIST_FILE="${RNAS_DIR}/DISK_EXIST"
BACKUP_DISABLED_FILE="${RNAS_DIR}/BACKUP_DISABLED"
MOUNT_POINT="/mnt/rnas/$(hostname)"
IMAGE_PATH="${RNAS_DIR}/$(hostname).img"
COPY_IMAGE_PATH="${RNAS_DIR}/$(hostname)-copy.img"
IMAGE_SIZE="10G"
REMOTE_SERVER="ip.hirakamu.my.id"
REMOTE_PORT="9901"
REMOTE_PATH="/receive"
CRON_SCHEDULE="0 2 * * *"  # Daily at 2 AM

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#=============================================================================
# Helper Functions
#=============================================================================

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

confirm() {
    local prompt="$1"
    local response
    read -p "$(echo -e ${YELLOW}${prompt}${NC})" response
    [[ "$response" =~ ^[Yy]$ ]]
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_debian() {
    if [[ ! -f /etc/debian_version ]]; then
        log_error "This script can only be run on Debian-based systems"
        exit 1
    fi
}

create_rnas_dirs() {
    if [[ ! -d "$RNAS_DIR" ]]; then
        mkdir -p "$RNAS_DIR"
        chmod 755 "$RNAS_DIR"
        log_info "Created $RNAS_DIR"
    fi
    
    if [[ ! -d "$MOUNT_POINT" ]]; then
        mkdir -p "$MOUNT_POINT"
        chmod 755 "$MOUNT_POINT"
        log_info "Created $MOUNT_POINT"
    fi
}

freeze_filesystem() {
    log_info "Freezing filesystem at $MOUNT_POINT..."
    fsfreeze --freeze "$MOUNT_POINT" 2>/dev/null || {
        log_warn "Failed to freeze filesystem (may not be necessary)"
    }
}

unfreeze_filesystem() {
    log_info "Unfreezing filesystem at $MOUNT_POINT..."
    fsfreeze --unfreeze "$MOUNT_POINT" 2>/dev/null || {
        log_warn "Failed to unfreeze filesystem"
    }
}

get_disk_size() {
    if [[ -f "$1" ]]; then
        du -h "$1" | cut -f1
    fi
}

#=============================================================================
# Main Functions
#=============================================================================

cmd_init() {
    log_info "Initializing RNAS system..."
    
    # Check if already initialized
    if [[ -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS is already initialized!"
        log_error "DISK_EXIST file found at $DISK_EXIST_FILE"
        exit 1
    fi
    
    # Confirmation
    if ! confirm "Initialize RNAS with the following configuration?\n - Image: $IMAGE_PATH\n - Mount: $MOUNT_POINT\n - Size: $IMAGE_SIZE\n Continue? (Y/n): "; then
        log_info "Initialization cancelled"
        exit 0
    fi
    
    # Install required packages
    log_info "Installing required packages..."
    apt-get update -qq
    apt-get install -y -qq rsync util-linux coreutils e2fsprogs openssh-client cron curl || {
        log_warn "Some packages failed to install, continuing anyway..."
    }
    
    # Create directories
    create_rnas_dirs
    
    # Copy script to /var/rnas
    log_info "Copying rnas.sh to $RNAS_DIR..."
    cp "$(readlink -f "$0")" "$RNAS_DIR/rnas.sh"
    chmod +x "$RNAS_DIR/rnas.sh"
    
    # Add to PATH via symlink
    log_info "Adding rnas to PATH..."
    ln -sf "$RNAS_DIR/rnas.sh" /usr/local/bin/rnas
    
    # Create DISK_EXIST marker
    log_info "Creating DISK_EXIST marker..."
    touch "$DISK_EXIST_FILE"
    
    # Create image disk
    log_info "Creating image disk ($IMAGE_SIZE)..."
    fallocate -l "$IMAGE_SIZE" "$IMAGE_PATH" || dd if=/dev/zero of="$IMAGE_PATH" bs=1M count=$(($(echo $IMAGE_SIZE | sed 's/G//') * 1024))
    chmod 600 "$IMAGE_PATH"
    
    # Format the image
    log_info "Formatting image as ext4..."
    mkfs.ext4 -F "$IMAGE_PATH"
    
    # Update fstab
    log_info "Updating /etc/fstab..."
    if ! grep -q "$IMAGE_PATH" /etc/fstab; then
        echo "$IMAGE_PATH $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    
    # Mount the filesystem
    log_info "Mounting filesystem..."
    mount "$IMAGE_PATH" "$MOUNT_POINT"
    chmod 755 "$MOUNT_POINT"
    
    # Initialize cronjob
    log_info "Setting up backup cronjob..."
    local cron_cmd="$RNAS_DIR/rnas.sh backup"
    (crontab -l 2>/dev/null | grep -v "rnas.sh backup" || true; echo "$CRON_SCHEDULE $cron_cmd") | crontab -
    
    # Reload systemd daemon
    log_info "Reloading systemd daemon..."
    systemctl daemon-reload || log_warn "Failed to reload systemd daemon"
    
    log_info ""
    log_info "════════════════════════════════════════════"
    log_info "RNAS Initialization Completed Successfully!"
    log_info "════════════════════════════════════════════"
    log_info "Image Path: $IMAGE_PATH"
    log_info "Mount Point: $MOUNT_POINT"
    log_info "Backup Schedule: $CRON_SCHEDULE"
    log_info "════════════════════════════════════════════"
}

cmd_status() {
    echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}                    RNAS Status Report${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
    
    echo -e "${YELLOW}Version:${NC} $VERSION"
    echo -e "${YELLOW}Hostname:${NC} $(hostname)"
    echo ""
    
    # Installation status
    if [[ -f "$DISK_EXIST_FILE" ]]; then
        echo -e "${YELLOW}Installation Status:${NC} ${GREEN}✓ Installed${NC}"
    else
        echo -e "${YELLOW}Installation Status:${NC} ${RED}✗ Not Installed${NC}"
        echo -e "\n${YELLOW}Run 'rnas init' to initialize RNAS${NC}\n"
        return 0
    fi
    
    # Image disk status
    if [[ -f "$IMAGE_PATH" ]]; then
        local image_size=$(get_disk_size "$IMAGE_PATH")
        echo -e "${YELLOW}Image Disk:${NC} ${GREEN}✓ Exists${NC} ($image_size)"
        echo -e "${YELLOW}Image Path:${NC} $IMAGE_PATH"
    else
        echo -e "${YELLOW}Image Disk:${NC} ${RED}✗ Missing${NC}"
    fi
    
    # Mount status
    if grep -q "$IMAGE_PATH" /proc/mounts 2>/dev/null; then
        echo -e "${YELLOW}Mount Status:${NC} ${GREEN}✓ Mounted${NC}"
        echo -e "${YELLOW}Mount Point:${NC} $MOUNT_POINT"
        
        # Disk usage
        if [[ -d "$MOUNT_POINT" ]]; then
            local usage=$(df -h "$MOUNT_POINT" 2>/dev/null | tail -1 | awk '{print $3 " / " $2 " (" $5 " used)"}')
            echo -e "${YELLOW}Disk Usage:${NC} $usage"
        fi
    else
        echo -e "${YELLOW}Mount Status:${NC} ${RED}✗ Not Mounted${NC}"
    fi
    
    # Backup status
    if crontab -l 2>/dev/null | grep -q "rnas.sh backup"; then
        if [[ -f "$BACKUP_DISABLED_FILE" ]]; then
            echo -e "${YELLOW}Auto Backup:${NC} ${YELLOW}⚠ Disabled${NC}"
        else
            echo -e "${YELLOW}Auto Backup:${NC} ${GREEN}✓ Enabled${NC}"
        fi
        echo -e "${YELLOW}Backup Schedule:${NC} $CRON_SCHEDULE"
    else
        echo -e "${YELLOW}Auto Backup:${NC} ${RED}✗ Not Configured${NC}"
    fi
    
    # Last backup time
    if [[ -f "$IMAGE_PATH" ]]; then
        local last_modified=$(stat -c %y "$IMAGE_PATH" 2>/dev/null | cut -d'.' -f1)
        echo -e "${YELLOW}Image Last Modified:${NC} $last_modified"
    fi
    
    # Check for backup copy
    if [[ -f "$COPY_IMAGE_PATH" ]]; then
        local copy_size=$(get_disk_size "$COPY_IMAGE_PATH")
        echo -e "${YELLOW}Backup Copy:${NC} ${GREEN}✓ Exists${NC} ($copy_size)"
    fi
    
    # Remote server info
    echo ""
    echo -e "${YELLOW}Remote Server:${NC} $REMOTE_SERVER:$REMOTE_PORT"
    echo -e "${YELLOW}Remote Path:${NC} $REMOTE_PATH"
    
    # fstab check
    echo ""
    if grep -q "$IMAGE_PATH" /etc/fstab 2>/dev/null; then
        echo -e "${YELLOW}fstab Entry:${NC} ${GREEN}✓ Configured${NC}"
    else
        echo -e "${YELLOW}fstab Entry:${NC} ${RED}✗ Missing${NC}"
    fi
    
    # Symlink check
    if [[ -L "/usr/local/bin/rnas" ]]; then
        echo -e "${YELLOW}PATH Symlink:${NC} ${GREEN}✓ Configured${NC}"
    else
        echo -e "${YELLOW}PATH Symlink:${NC} ${YELLOW}⚠ Missing${NC}"
    fi
    
    echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
}

cmd_backup() {
    log_info "Starting backup procedure..."
    
    # Check if initialized
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not initialized. Run 'rnas init' first"
        exit 1
    fi
    
    # Check if backup is disabled
    if [[ -f "$BACKUP_DISABLED_FILE" ]]; then
        log_warn "Automatic backups are disabled. Skipping backup."
        exit 0
    fi
    
    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image disk not found at $IMAGE_PATH"
        exit 1
    fi
    
    # Freeze
    freeze_filesystem
    sleep 1
    
    # Copy image
    log_info "Creating backup copy..."
    cp "$IMAGE_PATH" "$COPY_IMAGE_PATH"
    
    # Unfreeze
    unfreeze_filesystem
    sleep 1
    
    # Rsync to remote server
    log_info "Syncing to remote server ($REMOTE_SERVER)..."
    rsync -vS --compress-level=1 --inplace --partial --progress --timeout=300 \
        --stats --human-readable \
        -e "ssh -p $REMOTE_PORT -o Compression=no -o ServerAliveInterval=30" \
        "$COPY_IMAGE_PATH" \
        "root@${REMOTE_SERVER}:${REMOTE_PATH}/" || {
        log_error "Rsync failed, keeping backup for retry"
        exit 1
    }
    
    # Cleanup copy
    log_info "Cleaning up backup copy..."
    rm -f "$COPY_IMAGE_PATH"
    
    log_info ""
    log_info "✓ Backup completed successfully!"
    log_info "  Image: $(basename $IMAGE_PATH) - Size: $(get_disk_size $IMAGE_PATH)"
    log_info "  Remote: ${REMOTE_SERVER}:${REMOTE_PATH}"
}

cmd_delete() {
    log_info "Starting deletion with backup..."
    
    # Check if initialized
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not initialized"
        exit 1
    fi
    
    # Confirmation
    if ! confirm "Delete RNAS with backup? This will backup before deletion. Continue? (Y/n): "; then
        log_info "Deletion cancelled"
        exit 0
    fi
    
    # Perform backup first
    log_info "Performing backup before deletion..."
    cmd_backup || {
        log_error "Backup failed. Aborting deletion"
        exit 1
    }
    
    # Unmount
    log_info "Unmounting filesystem..."
    if grep -q "$IMAGE_PATH" /proc/mounts; then
        umount "$MOUNT_POINT" || {
            log_error "Failed to unmount. Using force unmount..."
            umount -l "$MOUNT_POINT"
        }
    fi
    
    # Remove fstab entry
    log_info "Removing fstab entry..."
    sed -i "\|$IMAGE_PATH|d" /etc/fstab
    
    # Remove DISK_EXIST marker
    log_info "Removing DISK_EXIST marker..."
    rm -f "$DISK_EXIST_FILE"
    rm -f "$BACKUP_DISABLED_FILE"
    
    # Remove image and directories
    log_info "Removing disk image and directories..."
    rm -f "$IMAGE_PATH"
    rm -f "$COPY_IMAGE_PATH"
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    
    # Remove cronjob
    log_info "Removing backup cronjob..."
    crontab -l 2>/dev/null | grep -v "rnas.sh backup" | crontab - || true
    
    # Remove symlink
    rm -f /usr/local/bin/rnas
    
    log_info ""
    log_info "════════════════════════════════════════════"
    log_info "RNAS Deletion Completed!"
    log_info "════════════════════════════════════════════"
    log_info "Backup was sent to ${REMOTE_SERVER}:${REMOTE_PATH}"
    log_info "════════════════════════════════════════════"
}

cmd_purge() {
    log_info "Starting purge procedure (no backup)..."
    
    # Check if initialized
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not initialized"
        exit 1
    fi
    
    # Confirmation
    if ! confirm "Purge RNAS WITHOUT backup? This cannot be undone! Continue? (y/N): "; then
        log_info "Purge cancelled"
        exit 0
    fi
    
    if ! confirm "Are you absolutely sure? Type 'yes' to confirm: "; then
        log_info "Purge cancelled"
        exit 0
    fi
    
    # Unmount
    log_info "Unmounting filesystem..."
    if grep -q "$IMAGE_PATH" /proc/mounts; then
        umount "$MOUNT_POINT" || {
            log_error "Failed to unmount. Using force unmount..."
            umount -l "$MOUNT_POINT"
        }
    fi
    
    # Remove fstab entry
    log_info "Removing fstab entry..."
    sed -i "\|$IMAGE_PATH|d" /etc/fstab
    
    # Remove DISK_EXIST marker
    log_info "Removing DISK_EXIST marker..."
    rm -f "$DISK_EXIST_FILE"
    rm -f "$BACKUP_DISABLED_FILE"
    
    # Remove image and directories
    log_info "Removing disk image and directories..."
    rm -f "$IMAGE_PATH"
    rm -f "$COPY_IMAGE_PATH"
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    
    # Remove cronjob
    log_info "Removing backup cronjob..."
    crontab -l 2>/dev/null | grep -v "rnas.sh backup" | crontab - || true
    
    # Remove symlink
    rm -f /usr/local/bin/rnas
    
    log_info ""
    log_info "════════════════════════════════════════════"
    log_info "RNAS Purge Completed!"
    log_info "════════════════════════════════════════════"
    log_info "All data has been destroyed (no backup sent)"
    log_info "════════════════════════════════════════════"
}

cmd_copy_only() {
    log_info "Creating backup copy..."
    
    # Check if initialized
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not initialized"
        exit 1
    fi
    
    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image disk not found at $IMAGE_PATH"
        exit 1
    fi
    
    # Freeze
    freeze_filesystem
    sleep 1
    
    # Copy image
    log_info "Creating copy..."
    cp "$IMAGE_PATH" "$COPY_IMAGE_PATH"
    
    # Unfreeze
    unfreeze_filesystem
    
    local size=$(get_disk_size "$COPY_IMAGE_PATH")
    log_info ""
    log_info "════════════════════════════════════════════"
    log_info "Backup Copy Created"
    log_info "════════════════════════════════════════════"
    log_info "Path: $COPY_IMAGE_PATH"
    log_info "Size: $size"
    log_info "════════════════════════════════════════════"
}

cmd_update() {
    log_info "Updating RNAS script..."
    
    local script_url="https://raw.githubusercontent.com/Hirakamu/script-bank/refs/heads/main/general%20script/rnas.sh?token=GHSAT0AAAAAADRLJO5ZLC7CNZGK5JYSOVTI2KYRQKQ"
    local current_script="$(readlink -f "$0")"
    local temp_script="/tmp/rnas-update-$$.sh"
    local backup_script="${current_script}.bak"
    
    # Download new version
    log_info "Downloading latest version..."
    if ! curl -fsSL "$script_url" -o "$temp_script"; then
        log_error "Failed to download script from GitHub"
        rm -f "$temp_script"
        exit 1
    fi
    
    # Verify downloaded file is a valid bash script
    if ! head -n 1 "$temp_script" | grep -q "^#!/bin/bash"; then
        log_error "Downloaded file doesn't appear to be a valid bash script"
        rm -f "$temp_script"
        exit 1
    fi
    
    # Backup current script
    log_info "Backing up current script..."
    cp "$current_script" "$backup_script"
    
    # Replace with new version
    log_info "Installing new version..."
    mv "$temp_script" "$current_script"
    chmod +x "$current_script"
    
    # Update copies in /var/rnas if exists and not already the same file
    if [[ -f "$RNAS_DIR/rnas.sh" ]] && [[ "$current_script" != "$RNAS_DIR/rnas.sh" ]]; then
        log_info "Updating RNAS directory copy..."
        cp "$current_script" "$RNAS_DIR/rnas.sh"
        chmod +x "$RNAS_DIR/rnas.sh"
    fi
    
    # Refresh symlink if needed
    if [[ -L "/usr/local/bin/rnas" ]]; then
        log_info "Refreshing PATH symlink..."
        ln -sf "$RNAS_DIR/rnas.sh" /usr/local/bin/rnas
    fi
    
    log_info ""
    log_info "═══════════════════════════════════════════="
    log_info "RNAS Script Updated Successfully!"
    log_info "═══════════════════════════════════════════="
    log_info "New Version: $current_script"
    log_info "Backup: $backup_script"
    log_info "═══════════════════════════════════════════="
}

cmd_repair() {
    log_info "Starting repair procedure..."
    
    # Check if initialized
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not initialized. Run 'rnas init' first"
        exit 1
    fi
    
    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image disk not found at $IMAGE_PATH. Cannot repair."
        exit 1
    fi
    
    log_info "Repairing RNAS configuration..."
    
    # Ensure directories exist
    create_rnas_dirs
    
    # Copy script to /var/rnas if missing
    if [[ ! -f "$RNAS_DIR/rnas.sh" ]]; then
        log_info "Copying rnas.sh to $RNAS_DIR..."
        cp "$(readlink -f "$0")" "$RNAS_DIR/rnas.sh"
        chmod +x "$RNAS_DIR/rnas.sh"
    fi
    
    # Re-add symlink
    log_info "Re-creating symlink in PATH..."
    ln -sf "$RNAS_DIR/rnas.sh" /usr/local/bin/rnas
    
    # Re-add fstab entry if missing
    log_info "Checking fstab entry..."
    if ! grep -q "$IMAGE_PATH" /etc/fstab; then
        log_info "Adding fstab entry..."
        echo "$IMAGE_PATH $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
    else
        log_info "fstab entry already exists"
    fi
    
    # Remount if not mounted
    log_info "Checking mount status..."
    if ! grep -q "$IMAGE_PATH" /proc/mounts; then
        log_info "Mounting filesystem..."
        mount "$IMAGE_PATH" "$MOUNT_POINT" || {
            log_error "Failed to mount filesystem"
            log_info "You may need to check the image with: fsck.ext4 $IMAGE_PATH"
            exit 1
        }
        chmod 755 "$MOUNT_POINT"
    else
        log_info "Filesystem already mounted"
    fi
    
    # Re-add cronjob if missing
    log_info "Checking backup cronjob..."
    if ! crontab -l 2>/dev/null | grep -q "rnas.sh backup"; then
        log_info "Adding backup cronjob..."
        local cron_cmd="$RNAS_DIR/rnas.sh backup"
        (crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $cron_cmd") | crontab -
    else
        log_info "Cronjob already exists"
    fi
    
    # Reload systemd daemon
    log_info "Reloading systemd daemon..."
    systemctl daemon-reload || log_warn "Failed to reload systemd daemon"
    
    log_info ""
    log_info "═══════════════════════════════════════════="
    log_info "RNAS Repair Completed!"
    log_info "═══════════════════════════════════════════="
    log_info "Image Path: $IMAGE_PATH"
    log_info "Mount Point: $MOUNT_POINT"
    log_info "Mount Status: $(grep -q "$IMAGE_PATH" /proc/mounts && echo 'Mounted' || echo 'Not Mounted')"
    log_info "═══════════════════════════════════════════="
}

cmd_enable_backup() {
    log_info "Enabling automatic backups..."
    
    # Check if initialized
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not initialized. Run 'rnas init' first"
        exit 1
    fi
    
    # Remove disabled flag
    if [[ -f "$BACKUP_DISABLED_FILE" ]]; then
        rm -f "$BACKUP_DISABLED_FILE"
        log_info "Automatic backups have been enabled"
    else
        log_info "Automatic backups are already enabled"
    fi
    
    # Ensure cronjob exists
    if ! crontab -l 2>/dev/null | grep -q "rnas.sh backup"; then
        log_info "Re-adding backup cronjob..."
        local cron_cmd="$RNAS_DIR/rnas.sh backup"
        (crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $cron_cmd") | crontab -
    fi
    
    log_info ""
    log_info "═══════════════════════════════════════════"
    log_info "Automatic Backups Enabled"
    log_info "═══════════════════════════════════════════"
    log_info "Schedule: $CRON_SCHEDULE"
    log_info "═══════════════════════════════════════════"
}

cmd_disable_backup() {
    log_info "Disabling automatic backups..."
    
    # Check if initialized
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not initialized. Run 'rnas init' first"
        exit 1
    fi
    
    # Confirmation
    if ! confirm "Disable automatic backups? You can still run manual backups. Continue? (Y/n): "; then
        log_info "Operation cancelled"
        exit 0
    fi
    
    # Create disabled flag
    touch "$BACKUP_DISABLED_FILE"
    
    log_info ""
    log_info "═══════════════════════════════════════════"
    log_info "Automatic Backups Disabled"
    log_info "═══════════════════════════════════════════"
    log_info "Cronjob will skip backups until re-enabled"
    log_info "Manual backups can still be run with: rnas backup --force"
    log_info "To re-enable: rnas enable-backup"
    log_info "═══════════════════════════════════════════"
}

cmd_expand() {
    if [[ $# -lt 1 ]]; then
        log_error "expand requires an increment size (e.g., expand 5 for 5GB)"
        exit 1
    fi
    
    local increment="$1"
    log_info "Expanding disk by ${increment}G..."
    
    # Check if initialized
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not initialized"
        exit 1
    fi
    
    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image disk not found at $IMAGE_PATH"
        exit 1
    fi
    
    # Confirmation
    if ! confirm "Expand disk by ${increment}G? Continue? (Y/n): "; then
        log_info "Expansion cancelled"
        exit 0
    fi
    
    # Freeze
    freeze_filesystem
    sleep 1
    
    # Expand image
    log_info "Expanding image file..."
    fallocate -l +"${increment}G" "$IMAGE_PATH" || dd if=/dev/zero bs=1M count=$((increment * 1024)) >> "$IMAGE_PATH"
    
    # Unfreeze
    unfreeze_filesystem
    sleep 1
    
    # Resize filesystem
    log_info "Resizing ext4 filesystem..."
    resize2fs "$IMAGE_PATH" || {
        log_error "Failed to resize filesystem"
        log_info "You may need to manually resize using: resize2fs $IMAGE_PATH"
        exit 1
    }
    
    # Also resize mounted filesystem if possible
    if grep -q "$IMAGE_PATH" /proc/mounts; then
        log_info "Resizing mounted filesystem..."
        resize2fs "$MOUNT_POINT"
    fi
    
    local new_size=$(get_disk_size "$IMAGE_PATH")
    log_info ""
    log_info "════════════════════════════════════════════"
    log_info "Disk Expansion Completed!"
    log_info "════════════════════════════════════════════"
    log_info "Image: $(basename $IMAGE_PATH)"
    log_info "New Size: $new_size"
    log_info "Mount Point: $MOUNT_POINT"
    log_info "════════════════════════════════════════════"
}

cmd_help() {
    cat << EOF
RNAS Management Script v${VERSION}

Usage: rnas.sh COMMAND [OPTIONS]

Commands:
  init              Initialize RNAS system (creates disk, mounts, sets up backup)
  status            Show detailed RNAS status and configuration
  backup            Backup disk image to remote server
  backup --force    Force backup even if disabled
  enable-backup     Enable automatic daily backups
  disable-backup    Disable automatic daily backups
  delete            Delete RNAS with backup before deletion
  purge             Delete RNAS without backup (permanent)
  copy-only         Create a backup copy without sending to server
  expand SIZE       Expand disk by SIZE GB (e.g., expand 5)
  repair            Repair RNAS configuration (fstab, cronjob, mount, symlink)
  update            Update RNAS script to latest version from GitHub
  help              Show this help message

Examples:
  sudo rnas.sh init
  sudo rnas.sh status
  sudo rnas.sh backup
  sudo rnas.sh backup --force
  sudo rnas.sh enable-backup
  sudo rnas.sh disable-backup
  sudo rnas.sh delete
  sudo rnas.sh purge
  sudo rnas.sh copy-only
  sudo rnas.sh expand 10
  sudo rnas.sh repair
  sudo rnas.sh update

Configuration:
  RNAS Directory:   $RNAS_DIR
  Mount Point:      $MOUNT_POINT
  Image Path:       $IMAGE_PATH
  Remote Server:    $REMOTE_SERVER:$REMOTE_PATH
  Backup Schedule:  $CRON_SCHEDULE

EOF
}

#=============================================================================
# Main Entry Point
#=============================================================================

main() {
    if [[ $# -eq 0 ]]; then
        cmd_help
        exit 1
    fi
    
    local command="$1"
    shift
    
    check_root
    check_debian
    
    case "$command" in
        init)
            cmd_init
            ;;
        status)
            cmd_status
            ;;
        backup)
            # Check for --force flag
            if [[ "$1" == "--force" ]] && [[ -f "$BACKUP_DISABLED_FILE" ]]; then
                log_warn "Forcing backup despite disabled flag..."
                rm -f "$BACKUP_DISABLED_FILE"
                cmd_backup
                touch "$BACKUP_DISABLED_FILE"
            else
                cmd_backup
            fi
            ;;
        delete)
            cmd_delete
            ;;
        purge)
            cmd_purge
            ;;
        copy-only)
            cmd_copy_only
            ;;
        expand)
            cmd_expand "$@"
            ;;
        enable-backup)
            cmd_enable_backup
            ;;
        disable-backup)
            cmd_disable_backup
            ;;
        repair)
            cmd_repair
            ;;
        update)
            cmd_update
            ;;
        help|--help|-h)
            cmd_help
            ;;
        *)
            log_error "Unknown command: $command"
            echo ""
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
