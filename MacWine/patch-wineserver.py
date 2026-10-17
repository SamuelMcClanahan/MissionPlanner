#!/usr/bin/env python3
"""Fix a crash of the Wine 11.0 wineserver on macOS (Gcenx build 11.0_1).

server/fd.c get_device() computes

    unsigned int hash = dev % DEVICE_HASH_SIZE;    /* DEVICE_HASH_SIZE is 7 */

dev_t is a signed 32-bit integer on macOS. For a file system whose device
number has the top bit set, dev % 7 is negative, the unsigned hash is huge,
and device_hash[hash] reads far outside the table: the server stops with
EXC_BAD_ACCESS (SIGBUS) the first time a Windows program opens a file there.
Every Wine program of the session then waits forever. Some GitHub macOS
runners have such a file system; Mission Planner then stops after
"TTS: init".

This script replaces the signed "% 7" with an unsigned one ("div") at the two
places where the compiler put that hash: get_device() and its inlined copy in
unmount_device(). Device numbers below 0x80000000 keep their hash bucket.

Usage: patch-wineserver.py <path to wineserver>
"""
import hashlib
import sys

# sha256 of bin/wineserver in wine-stable-11.0_1-osx64.tar.xz
ORIGINAL_SHA256 = "6da7d389c5a35687e580c4988e03f830a73786cf13aba6761e4791ab74aeea2e"

NOP = bytes([0x90])

PATCHES = [
    # get_device( dev = %edi, unix_fd = %esi ): bucket offset (hash * 16) in %rax.
    (0x15E69,
     bytes.fromhex("4863c7"            # movslq %edi,%rax
                   "4869c093244992"    # imulq  $-0x6db6db6d,%rax,%rax
                   "48c1e820"          # shrq   $0x20,%rax
                   "01f8"              # addl   %edi,%eax
                   "89c1"              # movl   %eax,%ecx
                   "c1e91f"            # shrl   $0x1f,%ecx
                   "c1f802"            # sarl   $0x2,%eax
                   "01c8"              # addl   %ecx,%eax
                   "8d0cc500000000"    # leal   (,%rax,8),%ecx
                   "29c8"              # subl   %ecx,%eax
                   "01f8"              # addl   %edi,%eax
                   "48c1e004"),        # shlq   $0x4,%rax
     bytes.fromhex("89f8"              # movl   %edi,%eax
                   "31d2"              # xorl   %edx,%edx
                   "b907000000"        # movl   $7,%ecx
                   "f7f1"              # divl   %ecx          (edx = dev % 7, unsigned)
                   "89d0"              # movl   %edx,%eax
                   "48c1e004")),       # shlq   $0x4,%rax
    # unmount_device(): get_device( st.st_rdev, -1 ) inlined, dev at -0x4038(%rbp).
    # Bucket offset in %rdx, dev in %eax for the compare that follows.
    (0x139D3,
     bytes.fromhex("486385c8bfffff"    # movslq -0x4038(%rbp),%rax
                   "4869d093244992"    # imulq  $-0x6db6db6d,%rax,%rdx
                   "48c1ea20"          # shrq   $0x20,%rdx
                   "01c2"              # addl   %eax,%edx
                   "89d1"              # movl   %edx,%ecx
                   "c1e91f"            # shrl   $0x1f,%ecx
                   "c1fa02"            # sarl   $0x2,%edx
                   "01ca"              # addl   %ecx,%edx
                   "8d0cd500000000"    # leal   (,%rdx,8),%ecx
                   "29ca"              # subl   %ecx,%edx
                   "01c2"              # addl   %eax,%edx
                   "48c1e204"),        # shlq   $0x4,%rdx
     bytes.fromhex("8b85c8bfffff"      # movl   -0x4038(%rbp),%eax
                   "31d2"              # xorl   %edx,%edx
                   "b907000000"        # movl   $7,%ecx
                   "f7f1"              # divl   %ecx          (edx = dev % 7, unsigned)
                   "8b85c8bfffff"      # movl   -0x4038(%rbp),%eax
                   "48c1e204")),       # shlq   $0x4,%rdx
]


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    data = bytearray(open(path, "rb").read())
    digest = hashlib.sha256(data).hexdigest()
    if digest != ORIGINAL_SHA256:
        sys.exit("wineserver is not the expected Wine 11.0_1 build (sha256 %s); "
                 "check whether the get_device() hash bug is still there before shipping" % digest)
    for offset, old, new in PATCHES:
        assert len(new) <= len(old)
        if data[offset:offset + len(old)] != old:
            sys.exit("unexpected bytes at 0x%x" % offset)
        data[offset:offset + len(old)] = new + NOP * (len(old) - len(new))
    open(path, "wb").write(data)
    print("wineserver patched (get_device hash), sha256 %s" % hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    main()
