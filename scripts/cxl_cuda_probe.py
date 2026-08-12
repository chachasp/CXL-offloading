#!/usr/bin/env python3
"""Read/write, placement and CUDA registration probe for a CXL NUMA node."""

from __future__ import annotations

import argparse
import ctypes
import mmap
import os
import platform
import resource
import sys
from pathlib import Path


MPOL_BIND = 2
CUDA_MEMHOSTREGISTER_PORTABLE = 1
CUDA_MEMHOSTREGISTER_DEVICEMAP = 2


def syscall_numbers() -> tuple[int, int]:
    machine = platform.machine().lower()
    if machine in {"x86_64", "amd64"}:
        return 237, 279
    if machine in {"aarch64", "arm64"}:
        return 235, 239
    raise RuntimeError(f"unsupported architecture for syscall numbers: {machine}")


def check_node(node: int) -> None:
    node_dir = Path(f"/sys/devices/system/node/node{node}")
    if not node_dir.is_dir():
        raise RuntimeError(f"NUMA node {node} does not exist")
    cpulist = (node_dir / "cpulist").read_text(encoding="ascii").strip()
    if cpulist:
        raise RuntimeError(
            f"node {node} owns CPUs ({cpulist}); strict CXL-only mode requires an empty cpulist"
        )
    print(f"node={node} cpulist=<empty>")
    print((node_dir / "meminfo").read_text(encoding="ascii").strip())


def cuda_error(libcuda: ctypes.CDLL, code: int) -> str:
    text = ctypes.c_char_p()
    if hasattr(libcuda, "cuGetErrorString") and libcuda.cuGetErrorString(code, ctypes.byref(text)) == 0:
        return text.value.decode("utf-8", errors="replace") if text.value else str(code)
    return str(code)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", required=True, type=int)
    parser.add_argument("--size-mib", type=int, default=64)
    args = parser.parse_args()
    if args.size_mib < 1:
        parser.error("--size-mib must be positive")

    check_node(args.node)
    soft, hard = resource.getrlimit(resource.RLIMIT_MEMLOCK)
    print(f"RLIMIT_MEMLOCK soft={soft} hard={hard}")

    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    sys_mbind, sys_move_pages = syscall_numbers()
    page_size = os.sysconf("SC_PAGE_SIZE")
    length = args.size_mib * 1024 * 1024
    region = mmap.mmap(
        -1,
        length,
        flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS,
        prot=mmap.PROT_READ | mmap.PROT_WRITE,
    )
    address = ctypes.addressof(ctypes.c_char.from_buffer(region))
    bits = ctypes.sizeof(ctypes.c_ulong) * 8
    words = args.node // bits + 1
    mask = (ctypes.c_ulong * words)()
    mask[args.node // bits] |= 1 << (args.node % bits)
    maxnode = words * bits

    rc = libc.syscall(
        sys_mbind,
        ctypes.c_void_p(address),
        ctypes.c_size_t(length),
        ctypes.c_int(MPOL_BIND),
        ctypes.byref(mask),
        ctypes.c_ulong(maxnode),
        ctypes.c_uint(0),
    )
    if rc != 0:
        error = ctypes.get_errno()
        raise OSError(error, f"mbind node {args.node} failed: {os.strerror(error)}")
    print(f"mbind=PASS address=0x{address:x} bytes={length}")

    for offset in range(0, length, page_size):
        region[offset] = 0
    if length % page_size:
        region[length - 1] = 0
    print("page_fault=PASS")

    page_count = (length + page_size - 1) // page_size
    batch = 4096
    checked = 0
    while checked < page_count:
        count = min(batch, page_count - checked)
        pages = (ctypes.c_void_p * count)(
            *(address + (checked + index) * page_size for index in range(count))
        )
        status = (ctypes.c_int * count)(*([-1] * count))
        rc = libc.syscall(
            sys_move_pages,
            ctypes.c_int(0),
            ctypes.c_ulong(count),
            ctypes.byref(pages),
            ctypes.c_void_p(),
            ctypes.byref(status),
            ctypes.c_int(0),
        )
        if rc < 0:
            error = ctypes.get_errno()
            raise OSError(error, f"move_pages query failed: {os.strerror(error)}")
        for index, actual in enumerate(status):
            if actual != args.node:
                raise RuntimeError(
                    f"placement mismatch at page {checked + index}: actual/status={actual}, expected={args.node}"
                )
        checked += count
    print(f"placement=PASS pages={page_count} node={args.node}")

    libcuda = ctypes.CDLL("libcuda.so.1")
    libcuda.cuInit.argtypes = [ctypes.c_uint]
    libcuda.cuInit.restype = ctypes.c_int
    code = libcuda.cuInit(0)
    if code:
        raise RuntimeError(f"cuInit failed: {cuda_error(libcuda, code)}")

    register = getattr(libcuda, "cuMemHostRegister_v2", None) or getattr(
        libcuda, "cuMemHostRegister", None
    )
    if register is None:
        raise RuntimeError("libcuda has no cuMemHostRegister symbol")
    register.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint]
    register.restype = ctypes.c_int
    libcuda.cuMemHostUnregister.argtypes = [ctypes.c_void_p]
    libcuda.cuMemHostUnregister.restype = ctypes.c_int
    flags = CUDA_MEMHOSTREGISTER_PORTABLE | CUDA_MEMHOSTREGISTER_DEVICEMAP
    code = register(ctypes.c_void_p(address), ctypes.c_size_t(length), flags)
    if code:
        raise RuntimeError(
            "cuMemHostRegister failed: "
            f"{cuda_error(libcuda, code)}; check IPC_LOCK/memlock and CXL zone type"
        )
    print("cuda_host_register=PASS")
    code = libcuda.cuMemHostUnregister(ctypes.c_void_p(address))
    if code:
        raise RuntimeError(f"cuMemHostUnregister failed: {cuda_error(libcuda, code)}")
    region.close()
    print("RESULT: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:  # fail-fast CLI with one actionable line
        print(f"RESULT: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
