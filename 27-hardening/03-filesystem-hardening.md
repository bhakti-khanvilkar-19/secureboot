# Filesystem and Runtime Hardening

## Filesystem Layout for Security

```
Partition   Mount Point   Type    Flags           Contents
──────────────────────────────────────────────────────────────────────
mmcblk2p1   (boot-a)      raw     -               FIT image (signed)
mmcblk2p2   (boot-b)      raw     -               FIT image backup
mmcblk2p3   /             ext4    ro,noexec*      dm-verity rootfs
mmcblk2p4   (rootfs-b)    ext4    ro,noexec*      OTA update slot B
mmcblk2p5   /data         ext4    rw,nodev,nosuid LUKS2 encrypted data
tmpfs       /tmp          tmpfs   rw,noexec,nosuid,nodev Temporary files
tmpfs       /run          tmpfs   rw,nodev,nosuid Runtime data

* noexec is enforced by dm-verity (read-only device) not mount flags
```

---

## Mount Hardening

```bash
# /etc/fstab (baked into dm-verity rootfs)

# Root (via dm-verity — automatically mounted by initramfs):
/dev/mapper/vroot  /         ext4  ro,relatime,errors=remount-ro 0 1

# Data partition (LUKS2, mounted after TPM unseal):
/dev/mapper/data   /data     ext4  rw,nodev,nosuid,relatime 0 2

# Temporary filesystems:
tmpfs              /tmp      tmpfs  rw,nodev,nosuid,noexec,size=64m 0 0
tmpfs              /run      tmpfs  rw,nodev,nosuid,mode=755         0 0
tmpfs              /var/log  tmpfs  rw,nodev,nosuid,noexec,size=32m  0 0

# /proc hardening:
proc               /proc     proc   rw,nosuid,nodev,noexec,relatime,hidepid=2 0 0
# hidepid=2: processes of other users not visible

# /sys:
sysfs              /sys      sysfs  ro,nosuid,nodev,noexec,relatime 0 0
# Note: tmpfs over /sys/fs/cgroup as needed by systemd
```

---

## Systemd Hardening

### System-Wide Security Settings

```ini
# /etc/systemd/system.conf (baked into rootfs)

[Manager]
DefaultLimitNOFILE=1024
DefaultLimitMEMLOCK=0
DefaultTasksMax=512
CtrlAltDelBurstAction=none  # Disable Ctrl+Alt+Del reboot
```

### Service Hardening Template

```ini
# /etc/systemd/system/your-service.service
[Unit]
Description=Your Application
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/your-application
User=appuser
Group=appgroup

# Filesystem isolation:
PrivateTmp=yes                  # Private /tmp
ReadOnlyPaths=/                 # Entire FS read-only
ReadWritePaths=/data/app        # Only this path is writable
ProtectSystem=strict            # /usr, /boot, /etc read-only
ProtectHome=yes                 # No access to /home /root

# Namespace isolation:
PrivateDevices=yes              # No /dev access (except required)
DeviceAllow=/dev/null rw
ProtectKernelTunables=yes       # No /proc/sys write
ProtectKernelModules=yes        # No module loading
ProtectControlGroups=yes        # No cgroup manipulation
RestrictNamespaces=yes          # No namespace creation

# Network:
PrivateNetwork=no               # Needs network
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

# Capabilities:
CapabilityBoundingSet=          # No capabilities (empty = none)
AmbientCapabilities=            # No ambient capabilities
NoNewPrivileges=yes             # Cannot gain new privileges

# Seccomp:
SystemCallFilter=@system-service  # Only common service syscalls
SystemCallErrorNumber=EPERM       # Return EPERM instead of SIGSYS

# Memory:
MemoryDenyWriteExecute=yes      # No mmap(RWX)
LockPersonality=yes             # No personality() calls
RestrictRealtime=yes            # No real-time scheduling

[Install]
WantedBy=multi-user.target
```

---

## Minimal Root Filesystem

```bash
# Remove unnecessary binaries from rootfs:
# In Yocto, use IMAGE_FEATURES:remove and minimal package sets

IMAGE_FEATURES:remove = " \
    debug-tweaks \
    allow-empty-password \
    allow-root-login \
    post-install-logging \
"

# Remove shells (if not needed by application):
# RDEPENDS:${PN}:remove = "bash"
# BAD_RECOMMENDATIONS += "bash"

# Remove package manager (no runtime installs in production):
PACKAGE_EXCLUDE += "opkg"
IMAGE_FEATURES:remove = "package-management"

# Remove development tools:
BAD_RECOMMENDATIONS += "strace gdb binutils"

# Remove unnecessary setuid binaries:
# In your image recipe or local.conf:
ROOTFS_POSTPROCESS_COMMAND += "remove_setuid_bits;"

remove_setuid_bits() {
    find "${IMAGE_ROOTFS}" -perm /6000 -type f \
        -not -path "*/bin/su" \
        -not -path "*/bin/ping" \
        -exec chmod a-s {} \;
}
```

---

## User and Privilege Hardening

```bash
# /etc/passwd (no shell for system users):
root:x:0:0:root:/root:/bin/false   # Root login disabled
daemon:x:1:1::/:/bin/false
appuser:x:1000:1000::/home/app:/bin/false  # App user, no shell

# /etc/shadow (root password locked):
root:!:19000:0:99999:7:::    # ! = locked

# Disable su (if not needed):
# Remove from rootfs or restrict with PAM

# /etc/sudoers: no sudo in production
# (If needed, restrict to specific commands with NOPASSWD)

# SSH: key-only, no root login, no password auth
# /etc/ssh/sshd_config:
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
# Consider disabling SSH entirely in production:
# systemctl disable sshd
```

---

## /proc Hardening

```bash
# /proc/sys write protection via read-only /proc:
# (Applied after sysctl at boot)

# Or via kernel cmdline:
# proc-hide-threads

# hidepid=2: users cannot see other users' processes
# /etc/fstab:
proc /proc proc nosuid,nodev,noexec,relatime,hidepid=2,gid=procadmin 0 0

# Create procadmin group for users who need full /proc access:
groupadd -r procadmin
```

---

## ASLR and Executable Hardening

```bash
# Compile all applications with hardening flags:
# In Yocto local.conf:
SECURITY_CFLAGS = "-fstack-protector-strong -fPIE -D_FORTIFY_SOURCE=2"
SECURITY_LDFLAGS = "-Wl,-z,relro -Wl,-z,now -pie"

TARGET_CFLAGS:append = " ${SECURITY_CFLAGS}"
TARGET_LDFLAGS:append = " ${SECURITY_LDFLAGS}"

# Verify binary hardening:
checksec --file=/usr/bin/your-application
# Relro:    Full
# Stack:    Canary found
# NX:       Enabled
# PIE:      Enabled
# FORTIFY:  Enabled
```

---

## Audit and Monitoring

```bash
# Install auditd for security event logging:
IMAGE_INSTALL:append = " audit"

# Audit rules (/etc/audit/rules.d/production.rules):
-D  # Delete all existing rules first
-b 320  # Buffer size

# Log authentication events:
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity

# Log privilege escalation:
-a always,exit -F arch=b64 -S setuid -S setgid -k privilege_esc

# Log sudo usage:
-w /etc/sudoers -p wa -k sudoers

# Log SSH keys:
-w /root/.ssh -p wa -k sshkeys

# Log module loading (if modules enabled):
-w /sbin/insmod -p x -k module_ins
-a always,exit -F arch=b64 -S init_module -S finit_module -k module_load
```

---

## Security Verification Script

```bash
#!/bin/bash
# security-verify.sh — Run on target device to verify hardening

PASS=0; FAIL=0
check() {
    local desc="$1"; shift
    if eval "$@" 2>/dev/null; then
        echo "  PASS: $desc"
        ((PASS++))
    else
        echo "  FAIL: $desc"
        ((FAIL++))
    fi
}

echo "=== Filesystem Hardening ==="
check "Root is read-only"         "mount | grep 'on / ' | grep -q 'ro'"
check "/tmp is tmpfs"             "mount | grep '/tmp' | grep -q 'tmpfs'"
check "hidepid on /proc"          "mount | grep '/proc' | grep -q 'hidepid'"

echo "=== SUID Binaries ==="
SUID_COUNT=$(find / -perm /4000 -not -path '/proc/*' 2>/dev/null | wc -l)
check "Minimal setuid binaries (<5)" "[ $SUID_COUNT -lt 5 ]"

echo "=== User Security ==="
check "Root login disabled"       "grep -q 'root:!' /etc/shadow"
check "No shell users"            "! grep -qv 'false\|nologin' /etc/passwd | grep -v '^root'"

echo "=== Kernel ==="
check "ASLR enabled"              "[ $(cat /proc/sys/kernel/randomize_va_space) -eq 2 ]"
check "kptr_restrict=2"           "[ $(cat /proc/sys/kernel/kptr_restrict) -eq 2 ]"
check "dmesg restricted"          "[ $(cat /proc/sys/kernel/dmesg_restrict) -eq 1 ]"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
```

---

## Cross-References

- [01-kernel-hardening.md](01-kernel-hardening.md) — Kernel configuration
- [02-uboot-hardening.md](02-uboot-hardening.md) — Bootloader hardening
- [../21-verified-boot-and-dmverity/01-dmverity-setup.md](../21-verified-boot-and-dmverity/01-dmverity-setup.md) — dm-verity rootfs
- [../28-production-checklists/02-security-review-checklist.md](../28-production-checklists/02-security-review-checklist.md) — Security review
