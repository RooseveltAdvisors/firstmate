# Live probe: source a firstmate bin/fm-timeout-lib.sh inside a job-control bash
# attached to a real pty (80x24), background a bounded `cat`, and observe whether
# it completes or freezes in T state on SIGTTIN.
import fcntl, os, pty, select, signal, struct, subprocess, sys, termios, time
binroot, mode = sys.argv[1], sys.argv[2]
rcf = f"/tmp/sigttin-rc-{os.getpid()}"
cmd = {
 "run":  f'fm_run_timed 6 cat',
 "bash": f'FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed 6 cat',
 "exec": f'( fm_exec_timed 6 2 cat )',
}[mode]
script = f'set -m; . "{binroot}/bin/fm-timeout-lib.sh"; {cmd}; echo "rc=$?" > {rcf}'
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c", script])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
t0 = time.time(); frozen = 0; done = False
while time.time() - t0 < 4:
    r,_,_ = select.select([fd],[],[],0.25)
    if r:
        try: os.read(fd, 4096)
        except OSError: pass
    if os.path.exists(rcf): done = True; break
    ps = subprocess.run(["ps","-eo","pid,stat,args"],capture_output=True,text=True).stdout
    ps = subprocess.run(["ps","-s",str(pid),"-o","pid=,stat=,args="],capture_output=True,text=True).stdout
    frozen += sum(1 for l in ps.splitlines() if l.split()[1].startswith("T") and l.rstrip().endswith(" cat"))
rc = open(rcf).read().strip() if done else "none"
print(f"mode={mode} completed={'yes' if done else 'no'} elapsed={time.time()-t0:.1f}s frozen_cat_observations={frozen} {rc}")
# cleanup any stopped cats we caused
subprocess.run(["pkill","-KILL","-s",str(pid)],capture_output=True)
try: os.kill(pid, signal.SIGKILL); os.waitpid(pid,0)
except Exception: pass
if os.path.exists(rcf): os.unlink(rcf)
