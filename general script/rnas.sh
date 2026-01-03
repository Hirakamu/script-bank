#!/bin/bash

#=============================================================================
# RNAS Management Script
# Purpose: Manage remote NAS disk initialization, backup, deletion, and maintenance
# Uses: Private uses
#=============================================================================

set -euo pipefail

VERSION="2.1"
CONFIG_DIR="/etc/rnas"
CONFIG_FILE="${CONFIG_DIR}/rnas.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Additional

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

# Config

set_default_config() {
    RNAS_DIR="/var/rnas"
    IMAGE_SIZE="10G"
    REMOTE_SERVER="ip.hirakamu.my.id"
    REMOTE_PORT="9901"
    REMOTE_PATH="/receive"
    CRON_SCHEDULE="0 2 * * *"
}

set_derived_variables() {
    DISK_EXIST_FILE="${RNAS_DIR}/DISK_EXIST"
    BACKUP_DISABLED_FILE="${RNAS_DIR}/BACKUP_DISABLED"
    MOUNT_POINT="/mnt/rnas/$(hostname)"
    IMAGE_PATH="${RNAS_DIR}/$(hostname).img"
    COPY_IMAGE_PATH="${RNAS_DIR}/$(hostname)-copy.img"
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Loading configuration from $CONFIG_FILE"
        source "$CONFIG_FILE" || {
            log_error "Failed to load configuration file"
            return 1
        }
    else
        log_warn "No configuration file found, using defaults"
    fi
    set_derived_variables
}

validate_config() {
    local errors=0
    
    if ! [[ "$IMAGE_SIZE" =~ ^[0-9]+[GMK]$ ]]; then
        log_error "Invalid IMAGE_SIZE: '$IMAGE_SIZE' (must match format: number+G/M/K, e.g., 10G, 500M)"
        ((errors++))
    fi
    local cron_fields=$(echo "$CRON_SCHEDULE" | wc -w)
    if [[ $cron_fields -ne 5 ]]; then
        log_error "Invalid CRON_SCHEDULE: '$CRON_SCHEDULE' (must have 5 fields: minute hour day month weekday)"
        ((errors++))
    fi
    if ! [[ "$REMOTE_PORT" =~ ^[0-9]+$ ]] || [[ $REMOTE_PORT -lt 1 ]] || [[ $REMOTE_PORT -gt 65535 ]]; then
        log_error "Invalid REMOTE_PORT: '$REMOTE_PORT' (must be numeric, 1-65535)"
        ((errors++))
    fi
    if ! [[ "$RNAS_DIR" =~ ^/ ]]; then
        log_error "Invalid RNAS_DIR: '$RNAS_DIR' (must be absolute path starting with /)"
        ((errors++))
    fi
    if ! [[ "$REMOTE_PATH" =~ ^/ ]]; then
        log_error "Invalid REMOTE_PATH: '$REMOTE_PATH' (must be absolute path starting with /)"
        ((errors++))
    fi
    if [[ -z "$REMOTE_SERVER" ]]; then
        log_error "REMOTE_SERVER cannot be empty"
        ((errors++))
    fi
    if [[ $errors -gt 0 ]]; then
        log_error "Configuration validation failed with $errors error(s)"
        return 1
    fi
    return 0
}

generate_default_config() {
    local config_path="$1"
    
    cat > "$config_path" << 'EOF'
#!/bin/bash
#=============================================================================
# RNAS Configuration File
# Location: /etc/rnas/rnas.conf
# Edit with: sudo rnas config-edit
# Validate with: sudo rnas config-validate
#=============================================================================

# Base directory for RNAS files (disk images, markers, etc.)
# Default: /var/rnas
RNAS_DIR="/var/rnas"

# Initial disk image size (number + suffix: G=GB, M=MB, K=KB)
# Examples: 10G, 500M, 2T
# Default: 10G
IMAGE_SIZE="10G"

# Remote backup server configuration
# Hostname or IP address of the remote server
REMOTE_SERVER="ip.hirakamu.my.id"

# SSH port for remote connection
# Default: 9901
REMOTE_PORT="9901"

# Destination path on remote server (must be absolute)
# Default: /receive
REMOTE_PATH="/receive"

# Backup schedule in cron format
# Format: minute hour day month weekday
# Examples:
#   0 2 * * *    - Daily at 2:00 AM (default)
#   0 */6 * * *  - Every 6 hours
#   0 0 * * 0    - Weekly on Sunday at midnight
#   0 3 * * 1-5  - Weekdays at 3:00 AM
CRON_SCHEDULE="0 2 * * *"

#=============================================================================
# Derived variables (automatically set, do not modify):
#   MOUNT_POINT = /mnt/rnas/$(hostname)
#   IMAGE_PATH = ${RNAS_DIR}/$(hostname).img
#=============================================================================
EOF
    
    chmod 644 "$config_path"
    log_info "Generated configuration file: $config_path"
}

# SSH Check

check_ssh_key() {
    # Check for existing SSH keys
    if [[ -f ~/.ssh/id_ed25519 ]]; then
        echo ~/.ssh/id_ed25519
        return 0
    elif [[ -f ~/.ssh/id_rsa ]]; then
        echo ~/.ssh/id_rsa
        return 0
    fi
    return 1
}

generate_ssh_key() {
    local key_path=~/.ssh/id_ed25519
    
    log_info "Generating SSH key pair..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "rnas@$(hostname)" -q
    
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"
    
    log_info "SSH key generated: $key_path"
    echo "$key_path"
}

get_public_key() {
    local key_path
    if key_path=$(check_ssh_key); then
        cat "${key_path}.pub"
    else
        return 1
    fi
}

test_ssh_connection() {
    log_info "Testing connection to ${REMOTE_SERVER}:${REMOTE_PORT}..."
    
    if timeout 10 ssh -p "$REMOTE_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        "root@${REMOTE_SERVER}" \
        "echo 'SSH_OK'" &>/dev/null; then
        log_info "SSH connection successful ✓"
        return 0
    else
        log_error "SSH connection failed"
        return 1
    fi
}

verify_backup_connectivity() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}     RNAS Connection Verification${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    
    local checks_passed=0
    local checks_total=5
    
    # Check 1: SSH Key
    echo -e "${YELLOW}[1/5]${NC} Checking local SSH key..."
    if check_ssh_key &>/dev/null; then
        local key_path=$(check_ssh_key)
        echo -e "  ${GREEN}✓${NC} Private key found: $key_path"
        echo -e "  ${GREEN}✓${NC} Public key found: ${key_path}.pub"
        ((checks_passed++))
    else
        echo -e "  ${RED}✗${NC} No SSH key found"
    fi
    
    # Check 2: DNS Resolution
    echo -e "${YELLOW}[2/5]${NC} Testing DNS resolution..."
    if host "$REMOTE_SERVER" &>/dev/null; then
        local ip=$(host "$REMOTE_SERVER" | grep "has address" | head -1 | awk '{print $NF}')
        echo -e "  ${GREEN}✓${NC} $REMOTE_SERVER resolves to $ip"
        ((checks_passed++))
    else
        echo -e "  ${RED}✗${NC} Failed to resolve $REMOTE_SERVER"
    fi
    
    # Check 3: Network Connectivity
    echo -e "${YELLOW}[3/5]${NC} Testing network connectivity..."
    if timeout 5 ping -c 1 "$REMOTE_SERVER" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Host is reachable (ping successful)"
        ((checks_passed++))
    else
        echo -e "  ${YELLOW}⚠${NC} Ping failed (may be blocked by firewall)"
    fi
    
    # Check 4: SSH Connection
    echo -e "${YELLOW}[4/5]${NC} Testing SSH connection..."
    if timeout 10 ssh -p "$REMOTE_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        "root@${REMOTE_SERVER}" \
        "echo 'OK'" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} SSH authentication successful"
        echo -e "  ${GREEN}✓${NC} Connected to ${REMOTE_SERVER}:${REMOTE_PORT}"
        ((checks_passed++))
    else
        echo -e "  ${RED}✗${NC} SSH connection failed"
    fi
    
    # Check 5: Remote Path Access
    echo -e "${YELLOW}[5/5]${NC} Testing remote path access..."
    if timeout 10 ssh -p "$REMOTE_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "root@${REMOTE_SERVER}" \
        "test -d ${REMOTE_PATH} && test -w ${REMOTE_PATH} && echo 'OK'" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Path $REMOTE_PATH exists"
        echo -e "  ${GREEN}✓${NC} Path is writable"
        
        local space=$(timeout 10 ssh -p "$REMOTE_PORT" \
            -o BatchMode=yes \
            "root@${REMOTE_SERVER}" \
            "df -BG ${REMOTE_PATH} 2>/dev/null | tail -1 | awk '{print \$4}'" 2>/dev/null || echo "unknown")
        if [[ "$space" != "unknown" ]]; then
            echo -e "  ${GREEN}✓${NC} Available space: $space"
        fi
        ((checks_passed++))
    else
        echo -e "  ${RED}✗${NC} Failed to access $REMOTE_PATH"
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    if [[ $checks_passed -eq $checks_total ]]; then
        echo -e "${GREEN}Result: All checks passed ✓${NC}"
        echo -e "${GREEN}════════════════════════════════════════════${NC}"
        echo ""
        echo "Your RNAS backup is properly configured and ready to use."
        return 0
    else
        echo -e "${YELLOW}Result: $checks_passed/$checks_total checks passed${NC}"
        echo -e "${GREEN}════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${YELLOW}Some checks failed. Run 'sudo rnas setup-ssh' to fix SSH issues.${NC}"
        return 1
    fi
}

setup_ssh_keys() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}         SSH Key Setup Required${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    
    local key_path
    if key_path=$(check_ssh_key); then
        log_info "Using existing SSH key: $key_path"
    else
        key_path=$(generate_ssh_key)
    fi
    
    local pub_key=$(cat "${key_path}.pub")
    
    log_info "Testing connection to ${REMOTE_SERVER}:${REMOTE_PORT}..."
    if test_ssh_connection; then
        echo ""
        echo -e "${GREEN}SSH connection already working! ✓${NC}"
        return 0
    fi
    
    echo ""
    echo -e "${YELLOW}SSH connection failed. Your public key needs to be added to the remote server.${NC}"
    echo ""
    echo "Public Key:"
    echo "────────────────────────────────────────────"
    echo "$pub_key"
    echo "────────────────────────────────────────────"
    echo ""
    echo "Setup Options:"
    echo "  1. Automatic setup (requires password, recommended)"
    echo "  2. Manual setup (copy/paste instructions)"
    echo "  3. Skip for now (backups will fail!)"
    echo ""
    
    local choice
    read -p "$(echo -e ${YELLOW}Choose option [1]: ${NC})" choice
    choice=${choice:-1}
    
    case "$choice" in
        1)
            echo ""
            log_info "Attempting automatic key installation..."
            if ssh-copy-id -p "$REMOTE_PORT" "root@${REMOTE_SERVER}" 2>/dev/null; then
                log_info "Key successfully added to remote server ✓"
                echo ""
                if test_ssh_connection; then
                    echo ""
                    echo -e "${GREEN}✓ SSH setup completed successfully!${NC}"
                    return 0
                fi
            else
                log_error "Automatic setup failed"
                echo ""
                echo "Falling back to manual setup..."
                setup_ssh_keys_manual "$pub_key"
            fi
            ;;
        2)
            setup_ssh_keys_manual "$pub_key"
            ;;
        3)
            log_warn "Skipping SSH setup"
            echo ""
            echo -e "${RED}⚠ WARNING: Backups will fail until SSH is properly configured!${NC}"
            echo ""
            echo "You can run 'sudo rnas setup-ssh' later to complete the setup."
            return 1
            ;;
        *)
            log_error "Invalid choice"
            return 1
            ;;
    esac
}

setup_ssh_keys_manual() {
    local pub_key="$1"
    
    echo ""
    echo "Manual Setup Instructions:"
    echo "════════════════════════════════════════════"
    echo ""
    echo "1. Copy your public key (shown above)"
    echo ""
    echo "2. On the remote server (${REMOTE_SERVER}), run:"
    echo ""
    echo "   mkdir -p ~/.ssh"
    echo "   echo \"$pub_key\" >> ~/.ssh/authorized_keys"
    echo "   chmod 700 ~/.ssh"
    echo "   chmod 600 ~/.ssh/authorized_keys"
    echo ""
    echo "3. OR use this one-liner on your local machine:"
    echo ""
    echo "   ssh-copy-id -p $REMOTE_PORT root@${REMOTE_SERVER}"
    echo ""
    echo "════════════════════════════════════════════"
    echo ""
    
    read -p "Press Enter when ready to test connection... "
    
    echo ""
    if test_ssh_connection; then
        echo ""
        echo -e "${GREEN}✓ SSH setup completed successfully!${NC}"
        return 0
    else
        echo ""
        echo -e "${RED}Connection still failing.${NC}"
        echo ""
        if confirm "Try testing again? (Y/n): "; then
            setup_ssh_keys_manual "$pub_key"
        else
            log_warn "SSH setup incomplete"
            return 1
        fi
    fi
}

# Config Commands

cmd_config_show() {
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}    Current RNAS Configuration${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}Config File:${NC} $CONFIG_FILE ${GREEN}✓${NC}"
        local last_mod=$(stat -c %y "$CONFIG_FILE" 2>/dev/null | cut -d'.' -f1 || echo "unknown")
        echo -e "${YELLOW}Last Modified:${NC} $last_mod"
    else
        echo -e "${YELLOW}Config File:${NC} $CONFIG_FILE ${RED}✗ Not found${NC}"
        echo -e "${YELLOW}Status:${NC} Using built-in defaults"
    fi
    
    echo ""
    echo -e "${YELLOW}RNAS_DIR${NC}         = $RNAS_DIR"
    echo -e "${YELLOW}IMAGE_SIZE${NC}       = $IMAGE_SIZE"
    echo -e "${YELLOW}REMOTE_SERVER${NC}    = $REMOTE_SERVER"
    echo -e "${YELLOW}REMOTE_PORT${NC}      = $REMOTE_PORT"
    echo -e "${YELLOW}REMOTE_PATH${NC}      = $REMOTE_PATH"
    echo -e "${YELLOW}CRON_SCHEDULE${NC}    = $CRON_SCHEDULE"
    
    echo ""
    echo -e "${YELLOW}Derived Values:${NC}"
    echo -e "  MOUNT_POINT    = $MOUNT_POINT"
    echo -e "  IMAGE_PATH     = $IMAGE_PATH"
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
}

cmd_config_edit() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "Configuration file not found"
        if confirm "Create new configuration file? (Y/n): "; then
            mkdir -p "$CONFIG_DIR"
            generate_default_config "$CONFIG_FILE"
        else
            log_info "Operation cancelled"
            return 0
        fi
    fi
    
    local old_server="$REMOTE_SERVER"
    local old_port="$REMOTE_PORT"
    local old_path="$REMOTE_PATH"
    
    local temp_config=$(mktemp /tmp/rnas-config.XXXXXX)
    cp "$CONFIG_FILE" "$temp_config"
    
    while true; do
        log_info "Opening configuration editor..."
        ${EDITOR:-nano} "$temp_config"
        
        echo ""
        log_info "Validating configuration..."
        
        if (source "$temp_config" && \
            [[ -n "$RNAS_DIR" ]] && \
            [[ -n "$IMAGE_SIZE" ]] && \
            [[ -n "$REMOTE_SERVER" ]] && \
            [[ -n "$REMOTE_PORT" ]] && \
            [[ -n "$REMOTE_PATH" ]] && \
            [[ -n "$CRON_SCHEDULE" ]]) 2>/dev/null; then
            
            source "$temp_config"
            set_derived_variables
            
            if validate_config 2>/dev/null; then
                log_info "Configuration is valid ✓"
                
                cp "$temp_config" "$CONFIG_FILE"
                rm -f "$temp_config"
                
                if [[ "$REMOTE_SERVER" != "$old_server" ]] || \
                   [[ "$REMOTE_PORT" != "$old_port" ]] || \
                   [[ "$REMOTE_PATH" != "$old_path" ]]; then
                    echo ""
                    log_warn "Remote server configuration changed"
                    echo ""
                    if confirm "Test connection to new remote server? (Y/n): "; then
                        if ! test_ssh_connection; then
                            echo ""
                            if confirm "Connection failed. Run SSH setup wizard? (Y/n): "; then
                                setup_ssh_keys
                            fi
                        fi
                    fi
                fi
                
                log_info "Configuration saved successfully"
                return 0
            else
                echo ""
                log_error "Configuration validation failed"
            fi
        else
            echo ""
            log_error "Configuration file has syntax errors or missing required values"
        fi
        
        echo ""
        if confirm "Re-edit configuration? (Y/n): "; then
            continue
        else
            log_info "Discarding changes"
            rm -f "$temp_config"
            return 1
        fi
    done
}

cmd_config_validate() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        echo "Run 'rnas install' to create one, or 'rnas config-edit' to create manually."
        return 1
    fi
    
    log_info "Validating configuration file: $CONFIG_FILE"
    echo ""
    
    if source "$CONFIG_FILE" 2>/dev/null; then
        set_derived_variables
        if validate_config; then
            echo ""
            echo -e "${GREEN}✓ Configuration is valid${NC}"
            return 0
        else
            echo ""
            echo -e "${RED}✗ Configuration validation failed${NC}"
            return 1
        fi
    else
        log_error "Failed to load configuration file (syntax error)"
        return 1
    fi
}

cmd_config_reset() {
    log_warn "Resetting configuration to defaults..."
    
    if [[ -f "$CONFIG_FILE" ]]; then
        if ! confirm "This will overwrite your current configuration. Continue? (y/N): "; then
            log_info "Operation cancelled"
            return 0
        fi
        
        local backup="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_FILE" "$backup"
        log_info "Backed up current config to: $backup"
    fi
    
    mkdir -p "$CONFIG_DIR"
    generate_default_config "$CONFIG_FILE"
    
    log_info ""
    log_info "════════════════════════════════════════════"
    log_info "Configuration Reset Complete"
    log_info "════════════════════════════════════════════"
    log_info "Config file: $CONFIG_FILE"
    log_info "Edit with: sudo rnas config-edit"
    log_info "════════════════════════════════════════════"
}

cmd_verify_connection() {
    verify_backup_connectivity
}

cmd_setup_ssh() {
    setup_ssh_keys
}

# Main

cmd_install() {
    log_info "Installing RNAS system..."
    
    if [[ -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS is already initialized!"
        log_error "DISK_EXIST file found at $DISK_EXIST_FILE"
        exit 1
    fi
    
    log_info "Creating configuration directory..."
    mkdir -p "$CONFIG_DIR"
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        generate_default_config "$CONFIG_FILE"
        echo ""
    fi
    
    if confirm "Edit configuration before installing? (Y/n): "; then
        cmd_config_edit
        source "$CONFIG_FILE"
        set_derived_variables
    fi
    
    echo ""
    if ! validate_config; then
        log_error "Configuration validation failed. Please fix the issues and try again."
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}     Configuration Summary${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}RNAS Directory:${NC}    $RNAS_DIR"
    echo -e "${YELLOW}Image Size:${NC}        $IMAGE_SIZE"
    echo -e "${YELLOW}Mount Point:${NC}       $MOUNT_POINT"
    echo -e "${YELLOW}Remote Server:${NC}     ${REMOTE_SERVER}:${REMOTE_PORT}"
    echo -e "${YELLOW}Remote Path:${NC}       $REMOTE_PATH"
    echo -e "${YELLOW}Backup Schedule:${NC}   $CRON_SCHEDULE"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    
    if ! confirm "Proceed with installation? (Y/n): "; then
        log_info "Installation cancelled"
        exit 0
    fi
    
    echo ""
    log_info "Setting up SSH keys for backup..."
    if ! setup_ssh_keys; then
        log_warn "SSH setup was skipped or failed"
        echo ""
        if ! confirm "Continue without SSH verification? (backups may fail) (y/N): "; then
            log_info "Installation cancelled"
            log_info "You can complete SSH setup later with: sudo rnas setup-ssh"
            exit 0
        fi
    fi
    
    echo ""
    log_info "Proceeding with RNAS installation..."
    
    log_info "Installing required packages..."
    apt-get update -qq
    apt-get install -y -qq rsync util-linux coreutils e2fsprogs openssh-client cron curl || {
        log_warn "Some packages failed to install, continuing anyway..."
    }
    
    create_rnas_dirs
    
    log_info "Copying rnas.sh to $RNAS_DIR..."
    cp "$(readlink -f "$0")" "$RNAS_DIR/rnas.sh"
    chmod +x "$RNAS_DIR/rnas.sh"
    
    log_info "Adding rnas to PATH..."
    ln -sf "$RNAS_DIR/rnas.sh" /usr/local/bin/rnas
    
    log_info "Creating DISK_EXIST marker..."
    touch "$DISK_EXIST_FILE"
    
    log_info "Creating image disk ($IMAGE_SIZE)..."
    fallocate -l "$IMAGE_SIZE" "$IMAGE_PATH" || dd if=/dev/zero of="$IMAGE_PATH" bs=1M count=$(($(echo $IMAGE_SIZE | sed 's/G//') * 1024))
    chmod 600 "$IMAGE_PATH"
    
    log_info "Formatting image as ext4..."
    mkfs.ext4 -F "$IMAGE_PATH"
    
    log_info "Updating /etc/fstab..."
    if ! grep -q "$IMAGE_PATH" /etc/fstab; then
        echo "$IMAGE_PATH $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
    
    log_info "Mounting filesystem..."
    mount "$IMAGE_PATH" "$MOUNT_POINT"
    chmod 755 "$MOUNT_POINT"
    
    log_info "Setting up backup cronjob..."
    local cron_cmd="$RNAS_DIR/rnas.sh backup"
    (crontab -l 2>/dev/null | grep -v "rnas.sh backup" || true; echo "$CRON_SCHEDULE $cron_cmd") | crontab -
    
    log_info "Reloading systemd daemon..."
    systemctl daemon-reload || log_warn "Failed to reload systemd daemon"
    
    log_info ""
    log_info "════════════════════════════════════════════"
    log_info "RNAS Installation Completed Successfully!"
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
    
    if [[ -f "$DISK_EXIST_FILE" ]]; then
        echo -e "${YELLOW}Installation Status:${NC} ${GREEN}✓ Installed${NC}"
    else
        echo -e "${YELLOW}Installation Status:${NC} ${RED}✗ Not Installed${NC}"
        echo -e "\n${YELLOW}Run 'rnas install' to install RNAS${NC}\n"
        return 0
    fi
    
    if [[ -f "$IMAGE_PATH" ]]; then
        local image_size=$(get_disk_size "$IMAGE_PATH")
        echo -e "${YELLOW}Image Disk:${NC} ${GREEN}✓ Exists${NC} ($image_size)"
        echo -e "${YELLOW}Image Path:${NC} $IMAGE_PATH"
    else
        echo -e "${YELLOW}Image Disk:${NC} ${RED}✗ Missing${NC}"
    fi
    
    if grep -q "$IMAGE_PATH" /proc/mounts 2>/dev/null; then
        echo -e "${YELLOW}Mount Status:${NC} ${GREEN}✓ Mounted${NC}"
        echo -e "${YELLOW}Mount Point:${NC} $MOUNT_POINT"
        
        if [[ -d "$MOUNT_POINT" ]]; then
            local usage=$(df -h "$MOUNT_POINT" 2>/dev/null | tail -1 | awk '{print $3 " / " $2 " (" $5 " used)"}')
            echo -e "${YELLOW}Disk Usage:${NC} $usage"
        fi
    else
        echo -e "${YELLOW}Mount Status:${NC} ${RED}✗ Not Mounted${NC}"
    fi
    
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
    
    if [[ -f "$IMAGE_PATH" ]]; then
        local last_modified=$(stat -c %y "$IMAGE_PATH" 2>/dev/null | cut -d'.' -f1)
        echo -e "${YELLOW}Image Last Modified:${NC} $last_modified"
    fi
    
    if [[ -f "$COPY_IMAGE_PATH" ]]; then
        local copy_size=$(get_disk_size "$COPY_IMAGE_PATH")
        echo -e "${YELLOW}Backup Copy:${NC} ${GREEN}✓ Exists${NC} ($copy_size)"
    fi
    
    echo ""
    echo -e "${YELLOW}Remote Server:${NC} $REMOTE_SERVER:$REMOTE_PORT"
    echo -e "${YELLOW}Remote Path:${NC} $REMOTE_PATH"
    
    echo ""
    if [[ -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}Config File:${NC} ${GREEN}✓ ${NC}$CONFIG_FILE"
    else
        echo -e "${YELLOW}Config File:${NC} ${YELLOW}⚠ Using defaults${NC}"
    fi
    
    if check_ssh_key &>/dev/null; then
        local key_path=$(check_ssh_key)
        echo -e "${YELLOW}SSH Key:${NC} ${GREEN}✓${NC} $key_path"
    else
        echo -e "${YELLOW}SSH Key:${NC} ${RED}✗ Not found${NC}"
    fi
    
    if timeout 5 ssh -p "$REMOTE_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=accept-new \
        "root@${REMOTE_SERVER}" \
        "echo 'OK'" &>/dev/null; then
        echo -e "${YELLOW}SSH Connection:${NC} ${GREEN}✓ Working${NC}"
    else
        echo -e "${YELLOW}SSH Connection:${NC} ${RED}✗ Failed${NC} (run 'rnas verify-connection')"
    fi
    
    echo ""
    if grep -q "$IMAGE_PATH" /etc/fstab 2>/dev/null; then
        echo -e "${YELLOW}fstab Entry:${NC} ${GREEN}✓ Configured${NC}"
    else
        echo -e "${YELLOW}fstab Entry:${NC} ${RED}✗ Missing${NC}"
    fi
    
    if [[ -L "/usr/local/bin/rnas" ]]; then
        echo -e "${YELLOW}PATH Symlink:${NC} ${GREEN}✓ Configured${NC}"
    else
        echo -e "${YELLOW}PATH Symlink:${NC} ${YELLOW}⚠ Missing${NC}"
    fi
    
    echo -e "\n${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
}

cmd_backup() {
    log_info "Starting backup procedure..."
    
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not installed. Run 'rnas install' first"
        exit 1
    fi
    if [[ -f "$BACKUP_DISABLED_FILE" ]]; then
        log_warn "Automatic backups are disabled. Skipping backup."
        exit 0
    fi
    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image disk not found at $IMAGE_PATH"
        exit 1
    fi
    
    log_info "Verifying remote server connectivity..."
    if ! timeout 10 ssh -p "$REMOTE_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        "root@${REMOTE_SERVER}" \
        "echo 'OK'" &>/dev/null; then
        log_error "SSH connection to ${REMOTE_SERVER}:${REMOTE_PORT} failed"
        echo ""
        echo "The remote server is unreachable or SSH authentication failed."
        echo ""
        echo "Troubleshooting:"
        echo "  1. Verify remote server is online: ping ${REMOTE_SERVER}"
        echo "  2. Test SSH manually: ssh -p ${REMOTE_PORT} root@${REMOTE_SERVER}"
        echo "  3. Verify SSH keys: sudo rnas verify-connection"
        echo "  4. Re-run key setup: sudo rnas setup-ssh"
        echo ""
        echo "Run 'sudo rnas verify-connection' for detailed diagnostics."
        exit 1
    fi
    log_info "Remote server connectivity verified ✓"
    
    freeze_filesystem
    sleep 1
    
    log_info "Creating backup copy..."
    cp "$IMAGE_PATH" "$COPY_IMAGE_PATH"
    
    unfreeze_filesystem
    sleep 1
    
    log_info "Syncing to remote server ($REMOTE_SERVER)..."
    rsync -vS --compress-level=1 --inplace --partial --progress --timeout=300 \
        --stats --human-readable \
        -e "ssh -p $REMOTE_PORT -o Compression=no -o ServerAliveInterval=30" \
        "$COPY_IMAGE_PATH" \
        "root@${REMOTE_SERVER}:${REMOTE_PATH}/" || {
        log_error "Rsync failed, keeping backup for retry"
        exit 1
    }
    
    log_info "Cleaning up backup copy..."
    rm -f "$COPY_IMAGE_PATH"
    
    log_info ""
    log_info "✓ Backup completed successfully!"
    log_info "  Image: $(basename $IMAGE_PATH) - Size: $(get_disk_size $IMAGE_PATH)"
    log_info "  Remote: ${REMOTE_SERVER}:${REMOTE_PATH}"
}

cmd_uninstall() {
    log_info "Starting RNAS uninstallation..."
    
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not installed"
        exit 1
    fi
    
    echo ""
    echo -e "${YELLOW}Uninstallation Options:${NC}"
    echo ""
    
    # Ask about backup
    local do_backup=false
    if confirm "Do you want to perform a last backup before uninstalling? (Y/n): "; then
        do_backup=true
    fi
    
    # Ask about userdata removal
    local remove_userdata=false
    if confirm "Do you want to remove all user data? (disk image will be deleted) (Y/n): "; then
        remove_userdata=true
    fi
    
    echo ""
    echo -e "${YELLOW}Uninstallation Summary:${NC}"
    echo -e "  Backup before uninstall: $([ "$do_backup" = true ] && echo "${GREEN}Yes${NC}" || echo "${RED}No${NC}")"
    echo -e "  Remove user data: $([ "$remove_userdata" = true ] && echo "${RED}Yes${NC}" || echo "${GREEN}No${NC}")"
    echo ""
    
    if ! confirm "Proceed with uninstallation? (Y/n): "; then
        log_info "Uninstallation cancelled"
        exit 0
    fi
    
    # Perform backup if requested
    if [ "$do_backup" = true ]; then
        echo ""
        log_info "Performing final backup..."
        cmd_backup || {
            log_error "Backup failed"
            if ! confirm "Continue with uninstallation despite backup failure? (y/N): "; then
                log_info "Uninstallation cancelled"
                exit 1
            fi
        }
    fi
    
    echo ""
    log_info "Unmounting filesystem..."
    if grep -q "$IMAGE_PATH" /proc/mounts; then
        umount "$MOUNT_POINT" || {
            log_error "Failed to unmount. Using force unmount..."
            umount -l "$MOUNT_POINT"
        }
    fi
    
    log_info "Removing fstab entry..."
    sed -i "\|$IMAGE_PATH|d" /etc/fstab
    
    log_info "Removing DISK_EXIST marker..."
    rm -f "$DISK_EXIST_FILE"
    rm -f "$BACKUP_DISABLED_FILE"
    
    # Remove user data if requested
    if [ "$remove_userdata" = true ]; then
        log_info "Removing disk image and user data..."
        rm -f "$IMAGE_PATH"
        rm -f "$COPY_IMAGE_PATH"
        rmdir "$MOUNT_POINT" 2>/dev/null || true
    else
        log_info "Keeping disk image at: $IMAGE_PATH"
        log_info "Keeping mount point at: $MOUNT_POINT"
    fi
    
    log_info "Removing backup cronjob..."
    crontab -l 2>/dev/null | grep -v "rnas.sh backup" | crontab - || true
    
    log_info "Removing symlink..."
    rm -f /usr/local/bin/rnas
    
    log_info ""
    log_info "════════════════════════════════════════════"
    log_info "RNAS Uninstallation Completed!"
    log_info "════════════════════════════════════════════"
    if [ "$do_backup" = true ]; then
        log_info "Final backup: Sent to ${REMOTE_SERVER}:${REMOTE_PATH}"
    else
        log_info "Final backup: Skipped"
    fi
    if [ "$remove_userdata" = true ]; then
        log_info "User data: Removed"
    else
        log_info "User data: Preserved at $IMAGE_PATH"
    fi
    log_info "════════════════════════════════════════════"
}

cmd_copy_only() {
    log_info "Creating backup copy..."
    
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not installed"
        exit 1
    fi
    
    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image disk not found at $IMAGE_PATH"
        exit 1
    fi
    
    freeze_filesystem
    sleep 1
    
    log_info "Creating copy..."
    cp "$IMAGE_PATH" "$COPY_IMAGE_PATH"
    
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
    
    local script_url="https://raw.githubusercontent.com/Hirakamu/script-bank/refs/heads/main/general%20script/rnas.sh"
    local current_script="$(readlink -f "$0")"
    local temp_script="/tmp/rnas-update-$$.sh"
    local backup_script="${current_script}.bak"
    local current_version="$VERSION"
    
    log_info "Downloading latest version..."
    if ! curl -fsSL "$script_url" -o "$temp_script"; then
        log_error "Failed to download script from GitHub"
        rm -f "$temp_script"
        exit 1
    fi
    if ! head -n 1 "$temp_script" | grep -q "^#!/bin/bash"; then
        log_error "Downloaded file doesn't appear to be a valid bash script"
        rm -f "$temp_script"
        exit 1
    fi

    local new_version=$(grep -m 1 '^VERSION=' "$temp_script" | cut -d'"' -f2)
    if [[ -z "$new_version" ]]; then
        new_version="unknown"
    fi
    if [[ "$current_version" == "$new_version" ]]; then
        log_info "Already running the latest version ($current_version)"
        rm -f "$temp_script"
        return 0
    fi
    
    log_info "Backing up current script..."
    cp "$current_script" "$backup_script"
    
    log_info "Installing new version..."
    mv "$temp_script" "$current_script"
    chmod +x "$current_script"
    
    if [[ -f "$RNAS_DIR/rnas.sh" ]] && [[ "$current_script" != "$RNAS_DIR/rnas.sh" ]]; then
        log_info "Updating RNAS directory copy..."
        cp "$current_script" "$RNAS_DIR/rnas.sh"
        chmod +x "$RNAS_DIR/rnas.sh"
    fi
    if [[ -L "/usr/local/bin/rnas" ]]; then
        log_info "Refreshing PATH symlink..."
        ln -sf "$RNAS_DIR/rnas.sh" /usr/local/bin/rnas
    fi
    
    log_info ""
    log_info "═══════════════════════════════════════════="
    log_info "RNAS Script Updated Successfully!"
    log_info "═══════════════════════════════════════════="
    log_info "Version: $current_version → $new_version"
    log_info "Script: $current_script"
    log_info "Backup: $backup_script"
    log_info "═══════════════════════════════════════════="
}

cmd_repair() {
    log_info "Starting repair procedure..."
    
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not installed. Run 'rnas install' first"
        exit 1
    fi
    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image disk not found at $IMAGE_PATH. Cannot repair."
        exit 1
    fi
    
    log_info "Repairing RNAS configuration..."
    
    create_rnas_dirs
    
    if [[ ! -f "$RNAS_DIR/rnas.sh" ]]; then
        log_info "Copying rnas.sh to $RNAS_DIR..."
        cp "$(readlink -f "$0")" "$RNAS_DIR/rnas.sh"
        chmod +x "$RNAS_DIR/rnas.sh"
    fi
    
    log_info "Re-creating symlink in PATH..."
    ln -sf "$RNAS_DIR/rnas.sh" /usr/local/bin/rnas
    
    log_info "Checking fstab entry..."
    if ! grep -q "$IMAGE_PATH" /etc/fstab; then
        log_info "Adding fstab entry..."
        echo "$IMAGE_PATH $MOUNT_POINT ext4 defaults,nofail 0 2" >> /etc/fstab
    else
        log_info "fstab entry already exists"
    fi

    log_info "Checking mount status..."
    if grep -q "$IMAGE_PATH" /proc/mounts; then
        log_info "Unmounting filesystem for repair..."
        umount "$MOUNT_POINT" || {
            log_warn "Standard unmount failed, trying force unmount..."
            umount -l "$MOUNT_POINT" || {
                log_error "Failed to unmount filesystem"
                exit 1
            }
        }
    fi
    
    log_info "Mounting filesystem..."
    mount "$IMAGE_PATH" "$MOUNT_POINT" || {
        log_error "Failed to mount filesystem"
        log_info "You may need to check the image with: fsck.ext4 $IMAGE_PATH"
        exit 1
    }
    chmod 755 "$MOUNT_POINT"
    log_info "Filesystem mounted successfully"
    
    log_info "Checking backup cronjob..."
    if ! crontab -l 2>/dev/null | grep -q "rnas.sh backup"; then
        log_info "Adding backup cronjob..."
        local cron_cmd="$RNAS_DIR/rnas.sh backup"
        (crontab -l 2>/dev/null; echo "$CRON_SCHEDULE $cron_cmd") | crontab -
    else
        log_info "Cronjob already exists"
    fi
    
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
    
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not installed. Run 'rnas install' first"
        exit 1
    fi
    if [[ -f "$BACKUP_DISABLED_FILE" ]]; then
        rm -f "$BACKUP_DISABLED_FILE"
        log_info "Automatic backups have been enabled"
    else
        log_info "Automatic backups are already enabled"
    fi
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
    
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not installed. Run 'rnas install' first"
        exit 1
    fi
    if ! confirm "Disable automatic backups? You can still run manual backups. Continue? (Y/n): "; then
        log_info "Operation cancelled"
        exit 0
    fi
    
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
    
    if [[ ! -f "$DISK_EXIST_FILE" ]]; then
        log_error "RNAS not installed"
        exit 1
    fi
    if [[ ! -f "$IMAGE_PATH" ]]; then
        log_error "Image disk not found at $IMAGE_PATH"
        exit 1
    fi
    if ! confirm "Expand disk by ${increment}G? Continue? (Y/n): "; then
        log_info "Expansion cancelled"
        exit 0
    fi
    
    freeze_filesystem
    sleep 1
    
    log_info "Expanding image file..."
    fallocate -l +"${increment}G" "$IMAGE_PATH" || dd if=/dev/zero bs=1M count=$((increment * 1024)) >> "$IMAGE_PATH"
    
    unfreeze_filesystem
    sleep 1
    
    log_info "Resizing ext4 filesystem..."
    resize2fs "$IMAGE_PATH" || {
        log_error "Failed to resize filesystem"
        log_info "You may need to manually resize using: resize2fs $IMAGE_PATH"
        exit 1
    }
    
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
  install              Install RNAS system (creates disk, mounts, sets up backup)
  uninstall            Uninstall RNAS (with options for backup and data removal)
  status               Show detailed RNAS status and configuration
  
  Configuration Management:
  config-show          Display current configuration values
  config-edit          Edit configuration file (creates if missing)
  config-validate      Validate configuration file syntax
  config-reset         Reset configuration to defaults
  
  SSH & Connectivity:
  verify-connection    Test SSH and remote server connectivity
  setup-ssh            Run SSH key setup wizard
  
  Backup Operations:
  backup               Backup disk image to remote server
  backup --force       Force backup even if disabled
  enable-backup        Enable automatic daily backups
  disable-backup       Disable automatic daily backups
  
  Maintenance:
  copy-only            Create a backup copy without sending to server
  expand SIZE          Expand disk by SIZE GB (e.g., expand 5)
  repair               Repair RNAS configuration (fstab, cronjob, mount, symlink)
  update               Update RNAS script to latest version from GitHub
  
  help                 Show this help message

Examples:
  # Initial setup
  sudo rnas install
  
  # Configuration management
  sudo rnas config-show
  sudo rnas config-edit
  sudo rnas verify-connection
  
  # Backup operations
  sudo rnas status
  sudo rnas backup
  sudo rnas backup --force
  sudo rnas enable-backup
  sudo rnas disable-backup
  
  # Maintenance
  sudo rnas expand 10
  sudo rnas repair
  sudo rnas update
  
  # Removal
  sudo rnas uninstall

Configuration:
  Config File:      $CONFIG_FILE
  RNAS Directory:   $RNAS_DIR
  Mount Point:      $MOUNT_POINT
  Image Path:       $IMAGE_PATH
  Remote Server:    $REMOTE_SERVER:$REMOTE_PORT
  Remote Path:      $REMOTE_PATH
  Backup Schedule:  $CRON_SCHEDULE

For more information, visit: https://github.com/Hirakamu/script-bank

EOF
}

# "Main"

main() {
    check_root
    check_debian
    set_default_config
    
    if [[ $# -eq 0 ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            source "$CONFIG_FILE" 2>/dev/null || true
        fi
        set_derived_variables
        cmd_help
        exit 1
    fi
    
    local command="$1"
    shift
    
    if [[ "$command" != "install" ]]; then
        if [[ -f "$CONFIG_FILE" ]]; then
            load_config
            if ! validate_config; then
                log_error "Invalid configuration. Run 'rnas config-validate' for details"
                exit 1
            fi
        else
            log_warn "No configuration file found at $CONFIG_FILE"
            log_warn "Using built-in defaults. Run 'rnas config-edit' to create configuration."
            set_derived_variables
        fi
    else
        set_derived_variables
    fi
    
    case "$command" in
        install)
            cmd_install
            ;;
        uninstall)
            cmd_uninstall
            ;;
        status)
            cmd_status
            ;;
        config-show)
            cmd_config_show
            ;;
        config-edit)
            cmd_config_edit
            ;;
        config-validate)
            cmd_config_validate
            ;;
        config-reset)
            cmd_config_reset
            ;;
        verify-connection)
            cmd_verify_connection
            ;;
        setup-ssh)
            cmd_setup_ssh
            ;;
        backup)
            if [[ "${1:-}" == "--force" ]] && [[ -f "$BACKUP_DISABLED_FILE" ]]; then
                log_warn "Forcing backup despite disabled flag..."
                rm -f "$BACKUP_DISABLED_FILE"
                cmd_backup
                touch "$BACKUP_DISABLED_FILE"
            else
                cmd_backup
            fi
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

# Execute REAL Main :)

main "$@"
