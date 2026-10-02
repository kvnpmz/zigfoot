import sys
import subprocess

input_file = sys.argv[1]
output_file = sys.argv[2]

cmd = ["zig", "build-obj", "-O", "ReleaseSafe", input_file, "-fno-stack-check", "-lc", "-femit-bin=" + output_file]
subprocess.run(cmd, check=True)
