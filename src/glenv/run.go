package main

import (
	"debug/elf"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func dirExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

// ensureMountPoints creates mount points for glibc overlays (needs root once).
var mountPointsEnsured bool

func ensureMountPoints() {
	if mountPointsEnsured {
		return
	}
	mountPointsEnsured = true
	for _, d := range []string{tripletDir, "/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib/ssl"} {
		if dirExists(d) {
			continue
		}
		// try directly, then via sudo
		if err := os.MkdirAll(d, 0o755); err == nil {
			continue
		}
		ensureAskpass()
		_ = exec.Command("sudo", "-A", "mkdir", "-p", d).Run()
	}
}

// Sandbox presets.
const (
	SandboxFull      = "full"       // everything visible rw + glibc path overlay - "like on a glibc distro"
	SandboxHome      = "home"       // exactly / (ro) + home (rw), net on
	SandboxHomeNoNet = "home-nonet" // same, no net
	SandboxCustom    = "custom"     // exactly / (ro) + given dirs (rw)
	SandboxNone      = "none"       // no sandbox, loader only
)

// classify decides how to run a program.
// Returns kind: "glibc" | "native" | "script" | "unknown".
func classify(path string) (kind, interp string, err error) {
	f, err := os.Open(path)
	if err != nil {
		return "", "", err
	}
	defer f.Close()
	hdr := make([]byte, 4)
	if _, err := f.ReadAt(hdr, 0); err != nil {
		return "unknown", "", nil
	}
	if hdr[0] == '#' && hdr[1] == '!' {
		return "script", "", nil
	}
	if string(hdr[0:4]) != "\x7fELF" {
		return "unknown", "", nil
	}
	ef, err := elf.Open(path)
	if err != nil {
		return "unknown", "", err
	}
	defer ef.Close()
	for _, p := range ef.Progs {
		if p.Type == elf.PT_INTERP {
			r := p.Open()
			buf := make([]byte, 256)
			n, _ := r.Read(buf)
			interp = strings.TrimRight(string(buf[:n]), "\x00")
			break
		}
	}
	switch {
	case interp == "":
		return "native", interp, nil // static link
	case strings.Contains(interp, "musl"):
		return "native", interp, nil
	default:
		return "glibc", interp, nil
	}
}

// resolveProg finds the program path (absolute or via PATH).
func resolveProg(prog string) (string, error) {
	if strings.Contains(prog, "/") {
		if !strings.HasPrefix(prog, "/") {
			abs, err := absPath(prog)
			if err == nil {
				return abs, nil
			}
		}
		if st, err := os.Stat(prog); err == nil && !st.IsDir() {
			return prog, nil
		}
		return "", fmt.Errorf("no such program: %s", prog)
	}
	return exec.LookPath(prog)
}

func absPath(p string) (string, error) {
	if strings.HasPrefix(p, "/") {
		return p, nil
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	return wd + "/" + p, nil
}

// Options - launch options.
type Options struct {
	Sandbox string   // full | home | home-nonet | custom:A,B | none
	RunAs   string   // "" | root | USER
	Custom  []string // for custom
}

// applyPolicy merges saved policy unless flags are set explicitly.
func (o *Options) applyPolicy(prog string) {
	p := loadPolicy()
	if e, ok := p.Apps[prog]; ok {
		if o.Sandbox == "" && e.Sandbox != "" {
			o.Sandbox = e.Sandbox
		}
		if o.RunAs == "" && e.RunAs != "" {
			o.RunAs = e.RunAs
		}
	}
	if o.Sandbox == "" {
		o.Sandbox = SandboxFull
	}
}

// buildCmd builds the launch command: [sudo -A] [bwrap ...] [ld.so ...] prog args
func buildCmd(prog string, args []string, opt Options) (*exec.Cmd, error) {
	prog, err := resolveProg(prog)
	if err != nil {
		return nil, err
	}
	opt.applyPolicy(prog)

	kind, _, err := classify(prog)
	if err != nil {
		return nil, err
	}

	var argv []string
	var env []string
	switch kind {
	case "glibc":
		if _, e := os.Stat(loaderPath); e != nil {
			return nil, fmt.Errorf("glibc loader not found: %s (run 'glenv doctor')", loaderPath)
		}
		argv = append(argv, loaderPath, "--library-path", libPath, prog)
		argv = append(argv, args...)
		env = append(env, "GCONV_PATH="+gconvDir)
	case "script":
		// shebang: interpreter may be glibc - then run it via the loader
		interpPath, _, e := readShebang(prog)
		if e == nil {
			if k2, _, e2 := classify(interpPath); e2 == nil && k2 == "glibc" {
				argv = append(argv, loaderPath, "--library-path", libPath, interpPath, prog)
				argv = append(argv, args...)
				env = append(env, "GCONV_PATH="+gconvDir)
			} else {
				argv = append(argv, prog)
				argv = append(argv, args...)
			}
		} else {
			argv = append(argv, prog)
			argv = append(argv, args...)
		}
	default: // native / static
		argv = append(argv, prog)
		argv = append(argv, args...)
	}

	// sandbox
	if opt.Sandbox != SandboxNone && opt.Sandbox != "" {
		bw, e := bwrapArgs(opt, argv)
		if e != nil {
			return nil, e
		}
		argv = bw
	}

	// run as another user/root
	if opt.RunAs != "" && opt.RunAs != "me" {
		ensureAskpass()
		sudo := []string{"sudo", "-A"}
		if opt.RunAs != "root" {
			sudo = append(sudo, "-u", opt.RunAs)
		}
		// env inside sudo: SUDO_ASKPASS + GUI env + /usr/bin/env VAR=... command
		inner := append([]string{"/usr/bin/env", "SUDO_ASKPASS=" + askpassFile}, env...)
		inner = append(inner, guiEnv()...)
		inner = append(inner, argv...)
		cmd := exec.Command(sudo[0], append(sudo[1:], inner...)...)
		cmd.Env = append(os.Environ(), "SUDO_ASKPASS="+askpassFile)
		cmd.Stdin = os.Stdin
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		return cmd, nil
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd, nil
}

// bwrapArgs wraps argv in bubblewrap per preset.
func bwrapArgs(opt Options, argv []string) ([]string, error) {
	if _, err := exec.LookPath("bwrap"); err != nil {
		return nil, errors.New("bwrap not installed (apk add bubblewrap)")
	}
	bw := []string{"bwrap", "--die-with-parent"}

	// root first, then /dev and /proc (else ro-bind hides the fresh /dev)
	switch {
	case opt.Sandbox == SandboxFull:
		// Everything visible rw (like a regular distro) + glibc path overlay,
		// so hardcoded /usr/lib/x86_64-linux-gnu and /lib64 resolve as on glibc.
		ensureMountPoints()
		bw = append(bw, "--bind", "/", "/")
		// /dev NOT recreated - host one stays (need /dev/dri for GPU)
	case opt.Sandbox == SandboxHome:
		bw = append(bw, "--ro-bind", "/", "/", "--bind", homeDir, homeDir, "--tmpfs", "/tmp")
	case opt.Sandbox == SandboxHomeNoNet:
		bw = append(bw, "--unshare-net", "--ro-bind", "/", "/", "--bind", homeDir, homeDir, "--tmpfs", "/tmp")
	case opt.Sandbox == SandboxCustom:
		bw = append(bw, "--ro-bind", "/", "/", "--bind", homeDir, homeDir, "--tmpfs", "/tmp")
		for _, d := range opt.Custom {
			bw = append(bw, "--bind", d, d)
		}
	default:
		return nil, fmt.Errorf("unknown sandbox preset: %s", opt.Sandbox)
	}

	// --- GUI access: X11, Wayland, D-Bus session (rw, since connect() needs write) ---
	for _, s := range guiSockets() {
		bw = append(bw, "--bind", s, s)
	}

	// --- glibc overlays (all presets, incl. re-exec of child processes) ---
	bw = append(bw, glibcOverlays()...)

	// /dev: for ro presets - fresh devtmpfs + host GPU nodes;
	// for full, host /dev is already visible, don't mount twice.
	if opt.Sandbox != SandboxFull {
		bw = append(bw, "--proc", "/proc", "--dev", "/dev")
		if dirExists("/dev/dri") {
			bw = append(bw, "--dev-bind", "/dev/dri", "/dev/dri")
		}
	}
	bw = append(bw, "--")
	bw = append(bw, argv...)
	return bw, nil
}

// guiEnv - GUI session env vars to pass into sudo
// (sudo scrubs the environment by default).
func guiEnv() []string {
	var out []string
	for _, k := range []string{
		"DISPLAY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "XAUTHORITY",
		"DBUS_SESSION_BUS_ADDRESS", "XDG_SESSION_TYPE", "XDG_CURRENT_DESKTOP",
		"QT_QPA_PLATFORM", "GDK_BACKEND", "PULSE_SERVER",
	} {
		if v := os.Getenv(k); v != "" {
			out = append(out, k+"="+v)
		}
	}
	return out
}

// guiSockets - GUI session sockets needed inside the sandbox.
func guiSockets() []string {
	var out []string
	add := func(p string) {
		if p == "" {
			return
		}
		if _, err := os.Stat(p); err != nil {
			return
		}
		for _, e := range out {
			if e == p {
				return
			}
		}
		out = append(out, p)
	}
	// X11
	add("/tmp/.X11-unix")
	add(os.Getenv("XAUTHORITY"))
	// Wayland + session pipes (pulse, dconf, ...)
	add(os.Getenv("XDG_RUNTIME_DIR"))
	// D-Bus session: unix:path=... or unix:abstract=...
	if addr := os.Getenv("DBUS_SESSION_BUS_ADDRESS"); addr != "" {
		for _, part := range strings.Split(addr, ",") {
			if strings.HasPrefix(part, "unix:path=") {
				add(strings.TrimPrefix(part, "unix:path="))
			}
		}
	}
	return out
}

// glibcOverlays - glibc sysroot mounts over host musl paths.
// Needed so child processes (exec) find the loader and libraries.
func glibcOverlays() []string {
	ensureMountPoints()
	var bw []string
	sysLib64 := filepath.Join(sysrootDir, "usr/lib64")
	if dirExists(libPath) {
		bw = append(bw, "--ro-bind", libPath, tripletDir)
		if dirExists("/lib/x86_64-linux-gnu") {
			bw = append(bw, "--ro-bind", libPath, "/lib/x86_64-linux-gnu")
		}
	}
	if dirExists(sysLib64) {
		if dirExists("/usr/lib64") {
			bw = append(bw, "--ro-bind", sysLib64, "/usr/lib64")
		}
		if dirExists("/lib64") {
			bw = append(bw, "--ro-bind", sysLib64, "/lib64")
		}
	}
	// fonts/data from sysroot (Debian fontconfig, mime, glib schemas, SSL path)
	for _, d := range []string{"usr/share/fonts", "usr/share/icons", "usr/share/themes",
		"usr/share/mime", "usr/share/glib-2.0", "usr/share/X11", "etc/fonts",
		"usr/lib/ssl"} {
		src := filepath.Join(sysrootDir, d)
		if dirExists(src) {
			bw = append(bw, "--ro-bind", src, "/"+d)
		}
	}
	return bw
}

// runCmd - terminal command: glenv [run] [flags] prog args
func runCmd(args []string) {
	opt := Options{}
	var prog string
	var progArgs []string

	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--" && prog == "":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "glenv: no program specified")
				os.Exit(2)
			}
			prog = args[i+1]
			progArgs = args[i+2:]
			i = len(args)
		case strings.HasPrefix(a, "--sandbox="):
			opt.Sandbox = strings.TrimPrefix(a, "--sandbox=")
		case a == "--sandbox":
			i++
			if i < len(args) {
				opt.Sandbox = args[i]
			}
		case strings.HasPrefix(a, "--as="):
			opt.RunAs = strings.TrimPrefix(a, "--as=")
		case a == "--as":
			i++
			if i < len(args) {
				opt.RunAs = args[i]
			}
		case strings.HasPrefix(a, "-") && prog == "":
			fmt.Fprintf(os.Stderr, "glenv: unknown flag %s\n", a)
			os.Exit(2)
		default:
			if prog == "" {
				prog = a
			} else {
				progArgs = append(progArgs, a)
			}
		}
	}
	if prog == "" {
		fmt.Fprintln(os.Stderr, "glenv: no program specified")
		os.Exit(2)
	}

	// custom:A,B -> Custom
	if strings.HasPrefix(opt.Sandbox, "custom:") {
		opt.Custom = splitTrim(strings.TrimPrefix(opt.Sandbox, "custom:"))
		opt.Sandbox = SandboxCustom
	}

	cmd, err := buildCmd(prog, progArgs, opt)
	if err != nil {
		fmt.Fprintln(os.Stderr, "glenv:", err)
		os.Exit(1)
	}
	err = cmd.Run()
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			os.Exit(ee.ExitCode())
		}
		fmt.Fprintln(os.Stderr, "glenv:", err)
		os.Exit(1)
	}
}

func splitTrim(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

// readShebang parses the #! line
func readShebang(path string) (interp string, rest []string, err error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", nil, err
	}
	line := string(b)
	if i := strings.IndexByte(line, '\n'); i >= 0 {
		line = line[:i]
	}
	line = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "#!"))
	if line == "" {
		return "", nil, errors.New("empty shebang")
	}
	fields := strings.Fields(line)
	ip, err := resolveProg(fields[0])
	if err != nil {
		return fields[0], fields[1:], nil
	}
	return ip, fields[1:], nil
}
