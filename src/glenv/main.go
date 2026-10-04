// glenv - run glibc programs on musl (Alpine) in userspace.
//
//	glenv run [--sandbox=...] [--as=...] prog [args...]   - terminal command
//	glenv desktop install <file.desktop|program>              - .desktop with glibc launch
//	glenv tui                                             - simple TUI
//	glenv perms <path> [-mode 755] [-owner u:g]           - chmod/chown
//	glenv auth save                                        - save sudo password
//	glenv doctor                                           - environment check
package main

import (
	"fmt"
	"os"
	"path/filepath"
)

// Env paths: GLENV_HOME > prefix next to this executable > /opt/glibc-env > ~/glibc-env.
func defaultEnvDir() string {
	if v := os.Getenv("GLENV_HOME"); v != "" {
		return v
	}
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Dir(filepath.Dir(exe))
		if st, err := os.Stat(filepath.Join(candidate, "sysroot")); err == nil && st.IsDir() {
			return candidate
		}
	}
	if st, err := os.Stat("/opt/glibc-env/sysroot"); err == nil && st.IsDir() {
		return "/opt/glibc-env"
	}
	return filepath.Join(homeDir, "glibc-env")
}

// Env paths (overridden by GLENV_HOME).
var (
	homeDir, _  = os.UserHomeDir()
	envDir      = defaultEnvDir()
	sysrootDir  = filepath.Join(envDir, "sysroot")
	gconvDir    = filepath.Join(sysrootDir, "usr/lib/x86_64-linux-gnu/gconv")
	loaderPath  = filepath.Join(sysrootDir, "usr/lib64/ld-linux-x86-64.so.2")
	libPath     = filepath.Join(sysrootDir, "usr/lib/x86_64-linux-gnu")
	tripletDir  = "/usr/lib/x86_64-linux-gnu"
	glenvDir    = filepath.Join(homeDir, ".glenv")
	policyFile  = filepath.Join(glenvDir, "policies.json")
	passFile    = filepath.Join(glenvDir, ".pass")
	askpassFile = filepath.Join(glenvDir, "askpass.sh")
	desktopDir  = filepath.Join(homeDir, ".local/share/applications")
)

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func main() {
	self, _ = os.Executable()
	self = filepath.Clean(self)

	args := os.Args[1:]
	if len(args) == 0 {
		usage()
		os.Exit(2)
	}

	switch args[0] {
	case "run", "--run":
		runCmd(args[1:])
	case "desktop", "--desktop":
		desktopCmd(args[1:])
	case "tui", "--tui":
		tuiCmd()
	case "perms", "--perms":
		permsCmd(args[1:])
	case "auth", "--auth":
		authCmd(args[1:])
	case "doctor", "--doctor":
		doctorCmd()
	case "apps", "--apps":
		appsCmd(args[1:])
	case "-h", "--help", "help":
		usage()
	default:
		// glenv <prog> [args...] - terminal launch shortcut
		runCmd(args)
	}
}

var self string

func usage() {
	fmt.Print(`glenv - run glibc programs on musl in userspace

Terminal launch (shortcut):
  glenv <program> [args...]
  glenv run [--sandbox=full|home|home-nonet|custom:A,B|none] [--as=root|USER] <program> [args...]

.desktop:
  glenv desktop install <file.desktop|program> [--sandbox=...] [--as=...]
      [--name=...] [--icon=...] [--comment=...] [--categories=...] [--terminal]
      [--dest=<dir|file.desktop>]
  glenv desktop remove  <name.desktop>
  glenv desktop scan

Other:
  glenv tui                - simple UI (launch, sandbox, perms, run as root)
  glenv perms <path> [-mode 755] [-owner user:group]
  glenv auth save          - save sudo password for run-as-root/other-user launches
  glenv doctor             - environment check
  glenv apps scan          - find glibc programs
`)
}
