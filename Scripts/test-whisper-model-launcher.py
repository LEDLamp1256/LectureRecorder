#!/usr/bin/python3
"""Direct-interpreter launcher regressions; stdlib only, no production test hooks.

Hostile-environment tests execute byte-identical production scripts with a tiny
observable C source in an isolated repository fixture. Fault tests instrument
only trusted utility/compile dispatch in disposable copies, never production
environment overrides. Real helper/model controls are run separately.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
if len(sys.argv) > 2 and sys.argv[1] == "--source-directory":
    SCRIPTS = Path(sys.argv[2]).resolve()
    del sys.argv[1:3]
CLANG = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
SDK = "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
CLEAN = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"}
NAMES = ["run-whisper-model-preparation.sh", "install-whisper-large-v3-turbo-model.sh",
         "stage-whisper-large-v3-turbo-harness-model.sh"]


class LauncherEnvironmentTests(unittest.TestCase):
    assertion_calls = 0

    def assertEqual(self, *args, **kwargs):
        type(self).assertion_calls += 1
        return super().assertEqual(*args, **kwargs)

    def assertTrue(self, *args, **kwargs):
        type(self).assertion_calls += 1
        return super().assertTrue(*args, **kwargs)

    def assertFalse(self, *args, **kwargs):
        type(self).assertion_calls += 1
        return super().assertFalse(*args, **kwargs)

    def assertIn(self, *args, **kwargs):
        type(self).assertion_calls += 1
        return super().assertIn(*args, **kwargs)

    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix="LectureRecorder-launcher-tests.", dir="/private/tmp"))
        print("launcher test evidence:", cls.root, flush=True)

    def setUp(self):
        self.runs = 0
        self.case = self.root / self._testMethodName
        self.scripts = self.case / "source ; $(literal)" / "Scripts"
        self.scripts.mkdir(parents=True)
        self.cwd = self.case / "unrelated cwd ; $(not-code)"
        self.cwd.mkdir()
        self.marker = self.case / "UNEXPECTED"
        self.executed = self.case / "helper-executed"
        self.sentinel = self.case / "pre-existing"
        self.sentinel.write_text("preserve me")
        for name in NAMES:
            shutil.copyfile(SCRIPTS / name, self.scripts / name)
            (self.scripts / name).chmod(0o755)
        self.launcher = self.scripts / NAMES[0]
        source = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    FILE *mark = fopen(EXECUTED, "w"); if (!mark) return 71; fclose(mark);
    for (char **p = environ; *p; p++) printf("HELPER_ENV=%s\n", *p);
    for (int i = 0; i < argc; i++) printf("HELPER_ARG=%s\n", argv[i]);
    char cwd[4096]; if (!getcwd(cwd, sizeof(cwd))) return 72;
    printf("HELPER_CWD=%s\n", cwd);
    return argc == 2 && !strcmp(argv[1], "stage") ? 23 : 0;
}
'''
        (self.scripts / "WhisperModelInstall.c").write_text(
            "#define EXECUTED " + json.dumps(str(self.executed)) + "\n" + source)
        # A competing current-directory source/configuration must never be used.
        (self.cwd / "WhisperModelInstall.c").write_text("#error WRONG SOURCE\n")
        (self.cwd / "clang.cfg").write_text("--this-is-not-a-clang-option\n")

    def run_launcher(self, extra_env=None, arguments=("install",), entry=None):
        env = dict(CLEAN)
        env.update(extra_env or {})
        result = subprocess.run([str(entry or self.launcher), *arguments], env=env,
                                cwd=self.cwd, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=90)
        self.runs += 1
        (self.case / ("run-%02d.json" % self.runs)).write_text(json.dumps({
            "command": [str(entry or self.launcher), *arguments], "cwd": str(self.cwd),
            "environment": env, "exit": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr}, indent=2))
        self.assertFalse(self.marker.exists(), result.stderr)
        self.assertEqual(self.sentinel.read_text(), "preserve me")
        return result

    def assert_normal(self, result, status=0, mode="install"):
        self.assertEqual(result.returncode, status, result.stderr)
        self.assertTrue(self.executed.exists())
        values = [line.removeprefix("HELPER_ENV=") for line in result.stdout.splitlines()
                  if line.startswith("HELPER_ENV=")]
        self.assertEqual(set(values), {key + "=" + value for key, value in CLEAN.items()})
        args = [line.removeprefix("HELPER_ARG=") for line in result.stdout.splitlines()
                if line.startswith("HELPER_ARG=")]
        self.assertEqual(len(args), 2)
        self.assertEqual(args[1], mode)
        output = Path(args[0])
        self.assertEqual(output.name, "WhisperModelInstall")
        self.assertTrue(str(output.parent).startswith("/private/tmp/LectureRecorder-model-helper."))
        self.assertIn("HELPER_CWD=" + str(output.parent), result.stdout)
        self.assertFalse(output.parent.exists(), "private compilation output was not cleaned")

    def test_exported_functions_cannot_intercept(self):
        utilities = ["xcrun", "dirname", "mktemp", "rm", "rmdir", "env", "stat", "file", "pwd", "cd"]
        definitions = "\n".join(name + "() { /usr/bin/touch " +
                                 json.dumps(str(self.marker)) + "; return 81; }; export -f " + name
                                 for name in utilities)
        # Use the installed Bash itself to encode exported functions correctly.
        definitions += "\nexec /usr/bin/python3 -c 'import os,json; print(json.dumps({k:v for k,v in os.environ.items() if v.startswith(\"() {\")}))'"
        exported = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", definitions],
                                  env=CLEAN, check=True, capture_output=True, text=True)
        functions = json.loads(exported.stdout)
        self.assertEqual(len(functions), len(utilities))
        self.assert_normal(self.run_launcher(functions))

    def test_exported_xcrun_alone_cannot_replace_compiler(self):
        definition = "xcrun() { /usr/bin/touch " + json.dumps(str(self.marker)) + "; return 81; }; export -f xcrun\n"
        definition += "exec /usr/bin/python3 -c 'import os,json; print(json.dumps({k:v for k,v in os.environ.items() if v.startswith(\"() {\")}))'"
        exported = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", definition],
                                  env=CLEAN, check=True, capture_output=True, text=True)
        functions = json.loads(exported.stdout)
        self.assertEqual(len(functions), 1)
        self.assert_normal(self.run_launcher(functions))

    def test_path_xcrun_alone_cannot_replace_compiler(self):
        malicious = self.case / "compiler bin"
        malicious.mkdir()
        tool = malicious / "xcrun"
        tool.write_text("#!/bin/bash -p\n/usr/bin/touch " + json.dumps(str(self.marker)) + "\nexit 82\n")
        tool.chmod(0o755)
        self.assert_normal(self.run_launcher({"PATH": str(malicious) + ":" + CLEAN["PATH"]}))

    def test_path_replacement_utilities_cannot_intercept(self):
        malicious = self.case / "malicious bin"
        malicious.mkdir()
        for name in ["xcrun", "dirname", "mktemp", "rm", "rmdir", "env", "stat", "file", "clang", "pwd"]:
            tool = malicious / name
            tool.write_text("#!/bin/bash -p\n/usr/bin/touch " + json.dumps(str(self.marker)) + "\nexit 82\n")
            tool.chmod(0o755)
        self.assert_normal(self.run_launcher({"PATH": str(malicious) + ":" + CLEAN["PATH"]}))

    def test_compiler_sdk_and_flag_overrides_are_discarded(self):
        keys = ["CC", "CXX", "CPPFLAGS", "CFLAGS", "CXXFLAGS", "LDFLAGS", "SDKROOT", "DEVELOPER_DIR",
                "TOOLCHAINS", "XCRUN_TOOLCHAIN_NAME", "CPATH", "LIBRARY_PATH", "COMPILER_PATH",
                "CLANG_CONFIG_FILE_USER_DIR", "CLANG_CONFIG_FILE_SYSTEM_DIR"]
        self.assert_normal(self.run_launcher({key: str(self.cwd / "not approved ; $(false)") for key in keys}))

    def test_tmpdir_cdpath_pwd_and_adversarial_cwd_are_ignored(self):
        self.assert_normal(self.run_launcher({"TMPDIR": str(self.cwd), "CDPATH": str(self.cwd),
                                             "PWD": "/not/the/working/directory", "HOME": str(self.cwd)}))
        self.assertEqual(sorted(p.name for p in self.cwd.iterdir()), ["WhisperModelInstall.c", "clang.cfg"])

    def test_startup_hooks_and_shell_options_do_not_run(self):
        hook = self.case / "startup hook"
        hook.write_text("/usr/bin/touch " + json.dumps(str(self.marker)) + "\nexit 83\n")
        self.assert_normal(self.run_launcher({"BASH_ENV": str(hook), "ENV": str(hook),
                                             "SHELLOPTS": "xtrace:nounset", "BASHOPTS": "expand_aliases"}))

    def test_dynamic_loader_variables_absent_from_helper(self):
        variables = {key: str(self.cwd / "injection") for key in [
            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
            "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH", "DYLD_IMAGE_SUFFIX",
            "DYLD_PRINT_TO_FILE", "DYLD_PRINT_LIBRARIES", "LD_PRELOAD"]}
        self.assert_normal(self.run_launcher(variables))

    def test_public_wrappers_preserve_modes_and_startup_protection(self):
        hook = self.case / "wrapper startup hook"
        hook.write_text("/usr/bin/touch " + json.dumps(str(self.marker)) + "\n")
        for name, mode, status in [(NAMES[1], "install", 0), (NAMES[2], "stage", 23)]:
            self.assert_normal(self.run_launcher({"BASH_ENV": str(hook), "ENV": str(hook)},
                arguments=(), entry=self.scripts / name), status=status, mode=mode)

    def test_literal_invalid_arguments_do_not_execute(self):
        literal = "install ; /usr/bin/touch " + str(self.marker)
        result = self.run_launcher(arguments=(literal,))
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.executed.exists())
        for name in NAMES[1:]:
            result = self.run_launcher(arguments=(literal,), entry=self.scripts / name)
            self.assertEqual(result.returncode, 1)

    def compiler_observer(self, mode):
        """Only disposable copies substitute a compiler dispatch for faults."""
        log = self.case / "compiler-environment"
        output_log = self.case / "compiler-output"
        source = self.case / "observer.c"
        source.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
extern char **environ;
int main(int argc, char **argv) {
    FILE *log = fopen(LOG, "w"); if (!log) return 90;
    for (char **p = environ; *p; p++) fprintf(log, "%s\n", *p);
    fclose(log);
    const char *output = NULL;
    for (int i = 1; i + 1 < argc; i++) if (!strcmp(argv[i], "-o")) output = argv[i+1];
    if (!output) return 91;
    log = fopen(OUTPUT_LOG, "w"); if (!log) return 92;
    fprintf(log, "%s", output); fclose(log);
    if (!strcmp(MODE, "real")) { argv[0] = CLANG; execv(CLANG, argv); return 93; }
    if (!strcmp(MODE, "signal")) {
        pid_t child = fork(); if (child < 0) return 100;
        if (!child) { argv[0] = CLANG; execv(CLANG, argv); _exit(101); }
        int status; if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) return 102;
        kill(getppid(), SIGTERM); return 0;
    }
    if (!strcmp(MODE, "missing")) return 0;
    if (!strcmp(MODE, "symlink")) return symlink(SENTINEL, output) ? 94 : 0;
    if (!strcmp(MODE, "directory")) return mkdir(output, 0700) ? 95 : 0;
    if (!strcmp(MODE, "fifo")) return mkfifo(output, 0700) ? 96 : 0;
    if (!strcmp(MODE, "hardlink")) return link(SENTINEL, output) ? 97 : 0;
    int fd = open(output, O_CREAT|O_EXCL|O_WRONLY, 0700); if (fd < 0) return 98;
    const char *payload = "#!/bin/bash\n/usr/bin/touch " MARKER "\n";
    if (strcmp(MODE, "empty")) { size_t size = strlen(payload); if (write(fd, payload, size) != (ssize_t)size) return 99; }
    close(fd);
    return !strcmp(MODE, "failure") ? 37 : 0;
}
'''.replace("#include <stdio.h>", "\n".join("#define " + key + " " + json.dumps(str(value)) for key, value in {
            "LOG": log, "OUTPUT_LOG": output_log, "MODE": mode, "CLANG": CLANG,
            "SENTINEL": self.sentinel, "MARKER": self.marker}.items()) + "\n#include <stdio.h>"))
        observer = self.case / "compiler-observer"
        compilation = subprocess.run([CLANG, "--no-default-config", "-std=c11", "-Wall", "-Wextra", "-Werror",
                        "-isysroot", SDK, str(source), "-o", str(observer)],
                       env={**CLEAN, "TMPDIR": str(self.case)}, capture_output=True, text=True)
        (self.case / "observer-compile.json").write_text(json.dumps({"command": compilation.args,
            "exit": compilation.returncode, "stdout": compilation.stdout, "stderr": compilation.stderr}))
        self.assertEqual(compilation.returncode, 0, compilation.stderr)
        text = self.launcher.read_text()
        needle = '"${COMPILER}" --no-default-config'
        self.assertEqual(text.count(needle), 1)
        self.launcher.write_text(text.replace(needle, json.dumps(str(observer)) + " --no-default-config"))
        return log, output_log

    def test_compiler_child_environment_is_minimal(self):
        log, _ = self.compiler_observer("real")
        hostile = {key: "hostile" for key in ["DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "CC", "CFLAGS", "SDKROOT", "BASH_ENV"]}
        self.assert_normal(self.run_launcher(hostile))
        values = dict(line.split("=", 1) for line in log.read_text().splitlines())
        self.assertEqual(set(values), {"PATH", "LC_ALL", "DEVELOPER_DIR", "TMPDIR"})
        self.assertEqual(values["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
        self.assertTrue(values["TMPDIR"].startswith("/private/tmp/LectureRecorder-model-helper."))

    def check_compiler_fault(self, mode, expected=1):
        _, output_log = self.compiler_observer(mode)
        original_inode = self.sentinel.stat().st_ino
        result = self.run_launcher()
        self.assertEqual(result.returncode, expected, result.stderr)
        self.assertFalse(self.executed.exists())
        self.assertEqual(self.sentinel.stat().st_ino, original_inode)
        output = Path(output_log.read_text())
        if mode != "directory": self.assertFalse(output.parent.exists())
        else:
            self.assertTrue(output.is_dir())
            self.assertIn("private build directory retained", result.stderr)

    def test_compiler_failure_never_executes_its_output_and_preserves_status(self): self.check_compiler_fault("failure", 37)
    def test_missing_compiler_output_rejected(self): self.check_compiler_fault("missing")
    def test_executable_text_output_rejected(self): self.check_compiler_fault("text")
    def test_symlink_output_rejected_without_deleting_target(self): self.check_compiler_fault("symlink")
    def test_directory_output_rejected_without_recursive_cleanup(self): self.check_compiler_fault("directory")
    def test_fifo_output_rejected(self): self.check_compiler_fault("fifo")
    def test_empty_output_rejected(self): self.check_compiler_fault("empty")
    def test_hardlink_output_rejected_without_deleting_original(self): self.check_compiler_fault("hardlink")
    def test_signal_during_compile_cannot_execute_output(self): self.check_compiler_fault("signal", 143)

    def replace_utility(self, utility, body):
        seam = self.case / "trusted-utility-seam"
        seam.write_text("#!/bin/bash -p\n" + body)
        seam.chmod(0o755)
        text = self.launcher.read_text()
        self.assertEqual(text.count(utility), 1)
        self.launcher.write_text(text.replace(utility, json.dumps(str(seam))))

    def test_temporary_creation_failure_cannot_execute_or_cleanup_external_path(self):
        self.replace_utility("/usr/bin/mktemp", "exit 63\n")
        result = self.run_launcher({"TMPDIR": str(self.case)})
        self.assertEqual(result.returncode, 1)
        self.assertIn("exclusive helper build directory creation failed", result.stderr)
        self.assertFalse(self.executed.exists())

    def test_unexpected_preexisting_output_is_preserved(self):
        record = self.case / "created-directory"
        self.replace_utility("/usr/bin/mktemp", 'root=$(/usr/bin/mktemp "$@") || exit $?\n'
            'printf "%s" "$root" > ' + json.dumps(str(record)) + '\n'
            'printf "pre-existing" > "$root/WhisperModelInstall"\nprintf "%s\\n" "$root"\n')
        result = self.run_launcher()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.executed.exists())
        self.assertEqual((Path(record.read_text()) / "WhisperModelInstall").read_text(), "pre-existing")

    def test_cleanup_failure_is_reported_not_success(self):
        self.replace_utility("/bin/rmdir", "exit 44\n")
        result = self.run_launcher()
        self.assertEqual(result.returncode, 1)
        self.assertTrue(self.executed.exists())
        self.assertIn("private build directory retained", result.stderr)

    def test_unavailable_toolchain_fails_before_compilation(self):
        text = self.launcher.read_text()
        # xcrun can fall back for unknown selector names. Make the approved
        # installation actually unavailable instead; never mutate host Xcode.
        self.launcher.write_text(text.replace("readonly DEVELOPER_ROOT=/Applications/Xcode.app/Contents/Developer",
                                             "readonly DEVELOPER_ROOT=/unavailable-test-Xcode/Contents/Developer"))
        result = self.run_launcher()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.executed.exists())

    def test_unavailable_sdk_fails_before_compilation(self):
        text = self.launcher.read_text()
        self.launcher.write_text(text.replace("--sdk macosx26.5", "--sdk unavailable-test-sdk"))
        result = self.run_launcher()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.executed.exists())


if __name__ == "__main__":
    program = unittest.main(verbosity=2, exit=False)
    print("assertion-method calls:", LauncherEnvironmentTests.assertion_calls, flush=True)
    sys.exit(0 if program.result.wasSuccessful() else 1)
