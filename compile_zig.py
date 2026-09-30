import sys
import subprocess

input_file = sys.argv[1]
output_file = sys.argv[2]

cmd = ["zig", "build-obj", "-O", "ReleaseSafe", input_file, "-fno-stack-check", "-lc"]
subprocess.run(cmd, check=True)
