# FIT Image Verification in U-Boot

## Verification Code Path

```
bootm ${fit_addr}
  └─ do_bootm()                          # cmd/bootm.c
       └─ boot_get_kernel()
            └─ fit_check_format()         # common/image-fit.c
            └─ fit_image_select()
            └─ bootm_find_images()
                 └─ boot_get_fdt()
                 └─ boot_get_ramdisk()
       └─ boot_selected_os()
            └─ fit_image_verify_required_sigs()   # common/image-fit-sig.c
                 └─ fit_image_sig_verify()
                      └─ fit_image_verify_sig()
                           └─ rsa_verify()         # lib/rsa/rsa-verify.c
```

## Key Function: fit_image_verify_required_sigs()

```c
/* common/image-fit-sig.c */
int fit_image_verify_required_sigs(const void *fit, int image_noffset,
                                    const char *fit_uname,
                                    const void *sig_blob,
                                    int *no_sigsp)
{
    int verify_count = 0;
    int ret;
    int fdt_err;

    /* Iterate over signature nodes in image */
    fdt_for_each_subnode(noffset, fit, image_noffset) {
        const char *name = fit_get_name(fit, noffset, NULL);
        if (strncmp(name, FIT_SIG_NODENAME,
                    strlen(FIT_SIG_NODENAME)))
            continue;

        /* Try to verify this signature */
        ret = fit_image_sig_verify(fit, image_noffset, noffset,
                                    sig_blob);
        if (ret) {
            printf("! ");
        } else {
            printf("+ ");
            verify_count++;
        }
    }

    /* Check if required signatures verified */
    if (verify_count == 0 && !*no_sigsp) {
        printf("ERROR: No signatures found\n");
        return -EPERM;
    }

    return 0;
}
```

## Expected Verification Output

### Success
```
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ... sha256+ OK
   Verified OK, SIGNATURE sha256,rsa2048:fit-signing-key (1)
## Loading fdt from FIT Image at 40400000 ...
   Verifying Hash Integrity ... sha256+ OK
## Loading ramdisk from FIT Image at 40400000 ...
   Verifying Hash Integrity ... sha256+ OK
```

### Failure: Wrong Signing Key
```
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
   Verifying Hash Integrity ... ! ERROR: signature check failed
ERROR: Failed to validate required signature 'fit-signing-key'
## FAIL: signature check failed for config 'conf@1'
SCRIPT FAILED: continuing...
```

### Failure: No Signature Node
```
## Loading kernel from FIT Image at 40400000 ...
   Using 'conf@1' configuration
ERROR: No signatures found for required image
## FAIL: signature check failed
```

## Public Key Embedding in U-Boot DTB

During build, `mkimage -K u-boot.dtb` embeds the signing public key:

```
# U-Boot DTB node added by mkimage:
/signature {
    key-fit-signing-key {
        required = "conf";
        algo = "sha256,rsa2048";
        rsa,num-bits = <2048>;
        rsa,modulus = <
            00 aa bb cc dd ... (256 bytes, big-endian)
        >;
        rsa,exponent = <0x00010001>;  /* 65537 */
        rsa,r-squared = <
            ...  (Montgomery R^2 mod N, precomputed)
        >;
        rsa,n0-inverse = <0x12345678>;  /* Montgomery -N^-1 mod 2^32 */
        key-name-hint = "fit-signing-key";
    };
};
```

### Why precomputed Montgomery values?

RSA modular exponentiation uses Montgomery multiplication for performance. U-Boot precomputes `R^2 mod N` and `-N^{-1} mod 2^32` at build time (via mkimage) to avoid expensive computation at boot time on constrained hardware.

## Inspecting Embedded Key

```bash
# Check U-Boot DTB for embedded key
fdtdump u-boot.dtb | grep -A 20 "signature"

# Or with dtc:
dtc -I dtb -O dts u-boot.dtb | grep -A 15 "signature"

# Output shows:
# signature {
#   key-fit-signing-key {
#     required = "conf";
#     algo = "sha256,rsa2048";
#     rsa,num-bits = <0x00000800>;
#     ...
```

## required = "conf" vs required = "image"

```
required = "conf"   → Verification of conf signature is MANDATORY
                      (if no valid conf sig → boot fails)

required = "image"  → Verification of individual image signature is MANDATORY

No "required"       → Verification optional (insecure for production!)
```

**Production setting must use `required = "conf"`** — otherwise U-Boot will boot unsigned FIT images.

## Debugging with iminfo

```
=> iminfo ${fit_addr}

## Checking Image at 40400000 ...
   FIT image found
   FIT description: phyCORE-i.MX8MP Secure Boot
   Created:         Thu Jan 16 10:23:45 2024
   Image 0 (kernel@1)
    Description:  Linux Kernel 6.6
    Type:         Kernel Image (no loading done)
    Compression:  uncompressed
    Data Start:   0x40400100
    Data Size:    21757952 Bytes = 20.7 MiB
    Hash algo:    sha256
    Hash value:   abc123...
    Sign algo:    sha256,rsa2048:fit-signing-key
    Sign value:   deadbeef...
   Default Configuration: 'conf@1'
   Configuration 0 (conf@1)
    Description:  phyCORE-i.MX8MP Secure Boot Config
    Kernel:       kernel@1
    Init Ramdisk: ramdisk@1
    FDT:          fdt@1
```
