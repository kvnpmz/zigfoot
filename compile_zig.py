import sys
import subprocess

input_file = sys.argv[1]
output_file = sys.argv[2]

# Optional: "true"/"false" for grapheme clustering. When given, a
# build_options module is generated next to the output and handed to the
# root module as @import("build_options"), mirroring the C build's
# FOOT_GRAPHEME_CLUSTERING define.
grapheme_clustering = sys.argv[3] if len(sys.argv) > 3 else None

# Flags must precede the module/root arguments.
cmd = ["zig", "build-obj", "-O", "ReleaseSafe", "-fno-stack-check", "-lc"]

if grapheme_clustering is not None:
    opts_file = output_file + ".build_options.zig"
    with open(opts_file, "w") as f:
        f.write("pub const grapheme_clustering = %s;\n"
                % ("true" if grapheme_clustering == "true" else "false"))
    cmd += ["--dep", "build_options",
            "-Mroot=" + input_file,
            "-Mbuild_options=" + opts_file]
else:
    cmd += [input_file]

cmd += ["-femit-bin=" + output_file]

subprocess.run(cmd, check=True)
