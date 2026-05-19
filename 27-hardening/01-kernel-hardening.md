# Kernel Hardening

## Kconfig Hardening Options

### Memory Protection

```bash
# Stack protection:
CONFIG_STACKPROTECTOR_STRONG=y    # Stack canary
CONFIG_VMAP_STACK=y               # Guard pages on kernel stack
CONFIG_THREAD_INFO_IN_TASK=y      # thread_info in task_struct (no stack leak)

# ASLR and randomization:
CONFIG_RANDOMIZE_BASE=y           # KASLR (Kernel ASLR)
CONFIG_RANDOMIZE_MODULE_REGION_FULL=y

# Memory permissions:
CONFIG_STRICT_KERNEL_RWX=y        # Kernel text: RO, data: NX
CONFIG_STRICT_MODULE_RWX=y        # Module text: RO, data: NX
CONFIG_DEBUG_RODATA=y             # Verify rodata is actually read-only
CONFIG_ARM64_SW_TTBR0_PAN=y       # Privileged Access Never (user page access from kernel)
CONFIG_ARM64_PAN=y                # Hardware PAN (if CPU supports)

# Heap:
CONFIG_SLAB_FREELIST_RANDOM=y     # Randomize slab freelist
CONFIG_SLAB_FREELIST_HARDENED=y   # Harden slab freelist metadata
CONFIG_SHUFFLE_PAGE_ALLOCATOR=y   # Randomize page allocator
```

### Information Leaks

```bash
# Restrict /proc and /sys:
CONFIG_SECURITY_DMESG_RESTRICT=y  # Non-root cannot read dmesg
CONFIG_PROC_FS=y
CONFIG_STRICT_DEVMEM=y            # /dev/mem: only first 1MB accessible
CONFIG_IO_STRICT_DEVMEM=y         # /dev/mem: no I/O port access

# Kernel pointer leaks:
CONFIG_KALLSYMS=n                 # No kernel symbol table in production
CONFIG_KALLSYMS_ALL=n
# kptr_restrict=2 at runtime:
# echo 2 > /proc/sys/kernel/kptr_restrict

# Restrict ptrace:
CONFIG_SECURITY_YAMA=y
# kernel.yama.ptrace_scope = 1 (only parents can ptrace children)
# or = 3 (no ptrace at all, for locked-down devices)
```

### Exploit Mitigations

```bash
# Integer overflow:
CONFIG_UBSAN=n                    # Disable in production (overhead)
CONFIG_UBSAN_TRAP=n

# Control flow:
CONFIG_CFI_CLANG=y                # Control Flow Integrity (requires clang)
CONFIG_SHADOW_CALL_STACK=y        # Shadow call stack (ARM64, requires clang)

# Spectre/Meltdown mitigations:
CONFIG_UNMAP_KERNEL_AT_EL0=y      # KPTI (Kernel Page Table Isolation)
CONFIG_HARDEN_EL2_VECTORS=y       # Spectre v2 EL2 mitigation
CONFIG_ARM64_SSBD=y               # Speculative Store Bypass Disable

# BPF hardening:
CONFIG_BPF_JIT_ALWAYS_ON=n        # Disable JIT (or enable with hardening)
CONFIG_BPF_UNPRIV_DEFAULT_OFF=y   # Unprivileged BPF disabled by default
```

### Debug Feature Removal (Production)

```bash
# Remove all debug facilities:
CONFIG_DEBUG_FS=n                 # No /sys/kernel/debug
CONFIG_KGDB=n                     # No kernel debugger
CONFIG_MAGIC_SYSRQ=n              # No SysRq key
CONFIG_PROC_KCORE=n               # No /proc/kcore
CONFIG_COREDUMP=n                 # No core dumps

CONFIG_MODULES=n                  # No loadable kernel modules (highest security)
# Or if modules needed:
CONFIG_MODULE_SIG=y               # Signed modules required
CONFIG_MODULE_SIG_ALL=y           # Sign all modules at build time
CONFIG_MODULE_SIG_FORCE=y         # Reject unsigned modules
CONFIG_MODULE_SIG_SHA256=y        # SHA-256 for module signing
```

---

## Kernel Lockdown Mode

Kernel lockdown restricts the kernel's ability to modify itself or leak kernel data, even to root:

```bash
# Enable lockdown:
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_SECURITY_LOCKDOWN_LSM_EARLY=y

# Set lockdown level in cmdline:
# lockdown=confidentiality  (strictest: no kernel image access)
# lockdown=integrity        (moderate: no live patching, limited /dev/mem)
# lockdown=none             (disabled)

# In production FIT image bootargs:
# lockdown=confidentiality
```

Lockdown `confidentiality` blocks:
- `/dev/mem` and `/dev/kmem` access
- Hibernation (could leak kernel state to disk)
- kexec (could replace kernel without secure boot)
- BPF reading of kernel memory
- Loading unsigned modules

---

## IMA (Integrity Measurement Architecture)

IMA measures and optionally enforces file integrity at runtime:

```bash
# Kconfig:
CONFIG_IMA=y
CONFIG_IMA_MEASURE_PCR_IDX=10    # PCR 10 for IMA measurements
CONFIG_IMA_NG_TEMPLATE=y
CONFIG_IMA_APPRAISE=y             # Enable appraisal (enforcement)
CONFIG_IMA_APPRAISE_BOOTPARAM=y   # Control via kernel cmdline
CONFIG_EVM=y                      # Extended Verification Module

# IMA policy (in initramfs /etc/ima/ima-policy):
# Measure all executed files:
measure func=BPRM_CHECK
# Appraise (enforce hash) for all files:
appraise func=FILE_CHECK appraise_type=imasig
# Don't appraise tmpfs:
dont_appraise fstype=tmpfs
dont_appraise fstype=ramfs
```

### IMA + EVM with dm-verity

On dm-verity protected rootfs, IMA/EVM provides defense-in-depth:
- dm-verity: per-block integrity on read
- IMA: per-file measurement at execution time
- EVM: HMAC protection of file metadata

```bash
# In kernel cmdline (signed FIT bootargs):
ima_policy=appraise_tcb ima_appraise=enforce evm=fix
```

---

## AppArmor / SELinux

```bash
# AppArmor for application confinement:
CONFIG_SECURITY_APPARMOR=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y

# Or SELinux:
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y

# Yocto: add AppArmor profile support
IMAGE_INSTALL:append = " apparmor apparmor-utils"
DISTRO_FEATURES:append = " apparmor"
```

---

## Kernel Cmdline Hardening

```bash
# Complete hardened kernel cmdline for production:
BOOTARGS="
console=ttymxc1,115200n8
root=/dev/mapper/vroot
rootfstype=ext4
rootwait
ro
quiet
panic=5
oops=panic
init_on_alloc=1
init_on_free=1
page_alloc.shuffle=1
slab_nomerge
randomize_kstack_offset=on
vsyscall=none
debugfs=off
lockdown=confidentiality
kptr_restrict=2
kernel.yama.ptrace_scope=3
ima_policy=appraise_tcb
ima_appraise=enforce
apparmor=1
security=apparmor
systemd.verity=yes
systemd.verity_root_hash=ROOTHASH_HERE
"
```

---

## sysctl Hardening

```bash
# /etc/sysctl.d/90-security.conf

# Network:
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.tcp_syncookies = 1

# Kernel:
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.perf_event_paranoid = 3
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
kernel.unprivileged_bpf_disabled = 1

# File system:
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
```

---

## Yocto Integration

```bash
# meta-security provides hardening recipes:
IMAGE_INSTALL:append = " \
    kernel-hardening \
    apparmor \
    libseccomp \
    audit \
    aide \
"

# In local.conf:
DISTRO_FEATURES:append = " apparmor seccomp"

# Kernel config fragment (meta-your-layer/recipes-kernel/linux/):
# imx8mp-hardening.cfg
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_STRICT_KERNEL_RWX=y
CONFIG_SECURITY_DMESG_RESTRICT=y
CONFIG_STRICT_DEVMEM=y
CONFIG_SECURITY_LOCKDOWN_LSM=y
CONFIG_IMA=y
CONFIG_IMA_APPRAISE=y
CONFIG_EVM=y
CONFIG_SECURITY_APPARMOR=y
CONFIG_DEFAULT_SECURITY_APPARMOR=y
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_FORCE=y
CONFIG_MODULE_SIG_SHA256=y
```

---

## Cross-References

- [02-uboot-hardening.md](02-uboot-hardening.md) — U-Boot hardening
- [03-filesystem-hardening.md](03-filesystem-hardening.md) — Runtime filesystem protection
- [../26-threat-modeling/01-attack-scenarios.md](../26-threat-modeling/01-attack-scenarios.md) — Threats mitigated
