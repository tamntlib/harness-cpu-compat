"""Run a test command with a controlling terminal and one package answer."""
import errno
import os
import select
import signal
import sys
import time

answer, *command = sys.argv[1:]
pid, master = os.forkpty()
if pid == 0:
    os.execvp(command[0], command)

output = bytearray()
sent = False
deadline = time.monotonic() + 30
try:
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            output.extend(chunk)
            if not sent and b"[y/N]: " in output:
                os.write(master, b"\x04" if answer == "EOF" else (answer + "\n").encode())
                sent = True
    else:
        os.kill(pid, signal.SIGKILL)
        raise TimeoutError("interactive fixture exceeded deadline")
finally:
    os.close(master)
    _, status = os.waitpid(pid, 0)
    sys.stdout.buffer.write(output)

sys.exit(os.waitstatus_to_exitcode(status))
