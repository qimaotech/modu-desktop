#!/usr/bin/env python3
import argparse
import ctypes
import errno
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description="Find a running mock App without terminating it.")
    parser.add_argument("--executable", required=True)
    parser.add_argument("--workspace", required=True)
    arguments = parser.parse_args()
    try:
        pids = find_processes(Path(arguments.executable).resolve(), Path(arguments.workspace).resolve())
        for pid in pids:
            print(f"App instance PID: {pid}")
        return 0 if pids else 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Could not inspect mock App processes: {error}", file=sys.stderr)
        return 2


def find_processes(executable, workspace):
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    kernel = ctypes.CDLL(None, use_errno=True)
    kernel.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                             ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    kernel.sysctl.restype = ctypes.c_int
    pids = subprocess.check_output(["/bin/ps", "-U", str(os.getuid()), "-o", "pid="], text=True).split()
    matches = []
    for value in pids:
        pid = int(value)
        path = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, path, len(path)) <= 0:
            error = ctypes.get_errno()
            if error in (errno.EPERM, errno.EACCES):
                raise OSError(error, os.strerror(error))
            continue
        if Path(os.fsdecode(path.value)).resolve() != executable:
            continue
        try:
            arguments = process_arguments(kernel, pid)
        except ProcessLookupError:
            continue
        for index, argument in enumerate(arguments[:-1]):
            if argument == "--mock-workspace" and Path(arguments[index + 1]).resolve() == workspace:
                matches.append(pid)
                break
    return matches


def process_arguments(kernel, pid):
    # KERN_PROCARGS2 preserves argv boundaries, unlike ps command text with paths containing spaces.
    query = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t()
    if kernel.sysctl(query, 3, None, ctypes.byref(size), None, 0) != 0:
        raise OSError(ctypes.get_errno(), os.strerror(ctypes.get_errno()))
    buffer = ctypes.create_string_buffer(size.value)
    if kernel.sysctl(query, 3, buffer, ctypes.byref(size), None, 0) != 0:
        error = ctypes.get_errno()
        if error in (errno.ESRCH, errno.ENOENT):
            raise ProcessLookupError(error, os.strerror(error))
        raise OSError(error, os.strerror(error))
    raw = buffer.raw[:size.value]
    count = int.from_bytes(raw[:4], sys.byteorder)
    start = raw.index(b"\0", 4) + 1
    while start < len(raw) and raw[start] == 0:
        start += 1
    arguments = raw[start:].split(b"\0")[:count]
    if len(arguments) != count:
        raise ValueError(f"Incomplete arguments for PID {pid}.")
    return [os.fsdecode(value) for value in arguments]


if __name__ == "__main__":
    sys.exit(main())
