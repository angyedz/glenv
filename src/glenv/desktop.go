package main

import (
	"bufio"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// desktopCmd - manage .desktop files.
func desktopCmd(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: glenv desktop <install|remove|scan> ...")
		os.Exit(2)
	}
	switch args[0] {
	case "install":
		desktopInstall(args[1:])
	case "remove":
		desktopRemove(args[1:])
	case "scan":
		desktopScan()
	default:
		fmt.Fprintln(os.Stderr, "unknown subcommand:", args[0])
		os.Exit(2)
	}
}

// parseDesktop reads .desktop, returns Exec tokens and "other" lines.
func parseDesktop(path string) (execTokens []string, other []string, err error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	inEntry := false
	for sc.Scan() {
		line := sc.Text()
		t := strings.TrimSpace(line)
		switch {
		case t == "[Desktop Entry]":
			inEntry = true
			other = append(other, line)
		case strings.HasPrefix(t, "["):
			inEntry = false
			other = append(other, line)
		case inEntry && strings.HasPrefix(t, "Exec="):
			execTokens = splitExec(strings.TrimPrefix(t, "Exec="))
		default:
			other = append(other, line)
		}
	}
	if execTokens == nil {
		return nil, other, fmt.Errorf("no Exec= line")
	}
	return execTokens, other, nil
}

// splitExec - simple shell-split for Exec (quotes, no escapes).
func splitExec(s string) []string {
	var out []string
	var cur strings.Builder
	inQ := false
	for _, r := range s {
		switch {
		case r == '"':
			inQ = !inQ
		case r == ' ' && !inQ:
			if cur.Len() > 0 {
				out = append(out, cur.String())
				cur.Reset()
			}
		default:
			cur.WriteRune(r)
		}
	}
	if cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out
}

// stripFieldCodes drops %f/%F/%u/%U/%i/... from EXEC args, returning program and its args.
func stripFieldCodes(tokens []string) (prog string, rest []string) {
	for i, t := range tokens {
		if strings.HasPrefix(t, "%") && len(t) <= 2 {
			continue
		}
		if prog == "" {
			// skip leading env vars like K=v
			if strings.Contains(t, "=") && !strings.Contains(t, "/") && i < len(tokens)-1 {
				continue
			}
			prog = t
			continue
		}
		rest = append(rest, t)
	}
	return prog, rest
}

// desktopInstall installs a .desktop launched via glenv.
// Forms:
//
//	glenv desktop install <file.desktop> [program settings...]  - rewrite Exec=
//	glenv desktop install <program> --name=... [program settings...] - create new
//
// Program settings: --sandbox=... --as=... --name=... --icon=... --comment=...
//
//	--categories=... --terminal --dest=<dir|file.desktop>
func desktopInstall(args []string) {
	var src string
	opt := Options{}
	name, icon, comment, categories, dest := "", "", "", "", ""
	terminal := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case strings.HasPrefix(a, "--sandbox="):
			opt.Sandbox = strings.TrimPrefix(a, "--sandbox=")
		case strings.HasPrefix(a, "--as="):
			opt.RunAs = strings.TrimPrefix(a, "--as=")
		case strings.HasPrefix(a, "--name="):
			name = strings.TrimPrefix(a, "--name=")
		case strings.HasPrefix(a, "--icon="):
			icon = strings.TrimPrefix(a, "--icon=")
		case strings.HasPrefix(a, "--comment="):
			comment = strings.TrimPrefix(a, "--comment=")
		case strings.HasPrefix(a, "--categories="):
			categories = strings.TrimPrefix(a, "--categories=")
		case a == "--terminal":
			terminal = true
		case strings.HasPrefix(a, "--dest="):
			dest = strings.TrimPrefix(a, "--dest=")
		case !strings.HasPrefix(a, "-"):
			if src == "" {
				src = a
			}
		}
	}
	if src == "" {
		fmt.Fprintln(os.Stderr, "usage: glenv desktop install <file.desktop|program> [--sandbox=...] [--as=...] [--name=...] [--icon=...] [--comment=...] [--categories=...] [--terminal] [--dest=<dir|file.desktop>]")
		os.Exit(2)
	}
	if opt.Sandbox == "" {
		opt.Sandbox = SandboxFull
	}
	if strings.HasPrefix(opt.Sandbox, "custom:") {
		opt.Custom = splitTrim(strings.TrimPrefix(opt.Sandbox, "custom:"))
		opt.Sandbox = SandboxCustom
	}
	runAs := runAsOrDefault(opt.RunAs)
	sandbox := sandboxFlag(opt)

	if isDesktopFile(src) {
		installFromDesktop(src, name, icon, comment, categories, terminal, dest, sandbox, runAs, opt)
		return
	}
	installFromProgram(src, name, icon, comment, categories, terminal, dest, sandbox, runAs, opt)
}

// isDesktopFile - existing *.desktop file.
func isDesktopFile(src string) bool {
	if !strings.HasSuffix(strings.ToLower(src), ".desktop") {
		return false
	}
	st, err := os.Stat(src)
	return err == nil && !st.IsDir()
}

// resolveDest - target dir and file name for the installed .desktop.
func resolveDest(dest, base string) (dir, file string) {
	if !strings.HasPrefix(base, "glenv-") {
		base = "glenv-" + base
	}
	if !strings.HasSuffix(base, ".desktop") {
		base += ".desktop"
	}
	if dest == "" {
		return desktopDir, base
	}
	if strings.HasSuffix(dest, ".desktop") {
		return filepath.Dir(dest), filepath.Base(dest)
	}
	return dest, base
}

// execLineFor builds "glenv run ..." for a program + args.
func execLineFor(absProg string, progArgs []string, sandbox, runAs string) string {
	execLine := fmt.Sprintf("%s run --sandbox=%s --as=%s -- %s", self, sandbox, runAs, absProg)
	if len(progArgs) > 0 {
		execLine += " " + strings.Join(progArgs, " ")
	}
	return execLine
}

// savePolicyFor records the installed .desktop in policy.
func savePolicyFor(absProg, dst, sandbox, runAs string) {
	e := getPolicy(absProg)
	e.Desktop = filepath.Base(dst)
	e.Sandbox = sandbox
	e.RunAs = runAs
	if err := savePolicy(absProg, e); err != nil {
		fmt.Fprintln(os.Stderr, "glenv:", err)
		os.Exit(1)
	}
}

// installFromDesktop rewrites Exec= of an existing .desktop and installs it.
func installFromDesktop(src, name, icon, comment, categories string, terminal bool, dest, sandbox, runAs string, opt Options) {
	tokens, _, err := parseDesktop(src)
	if err != nil {
		fmt.Fprintln(os.Stderr, "glenv:", err)
		os.Exit(1)
	}
	prog, progArgs := stripFieldCodes(tokens)
	absProg, err := resolveProg(prog)
	if err != nil {
		fmt.Fprintln(os.Stderr, "glenv: program from Exec not found:", prog, err)
		os.Exit(1)
	}
	warnIfNotGlibc(prog, absProg)
	execLine := execLineFor(absProg, progArgs, sandbox, runAs)

	base := strings.TrimSuffix(filepath.Base(src), ".desktop")
	if name != "" {
		base = name
	}
	dir, file := resolveDest(dest, base)
	out, err := writeDesktopWithExec(src, execLine)
	if err != nil {
		fmt.Fprintln(os.Stderr, "glenv:", err)
		os.Exit(1)
	}
	out = overrideDesktopFields(out, name, icon, comment, categories, terminal)
	dst := writeDesktopFile(dir, file, out)
	savePolicyFor(absProg, dst, sandbox, opt.RunAs)
	refreshMenus(dir)
	fmt.Println("Installed:", dst)
	fmt.Println("Exec:", execLine)
}

// installFromProgram creates a .desktop from scratch for a program binary.
func installFromProgram(src, name, icon, comment, categories string, terminal bool, dest, sandbox, runAs string, opt Options) {
	absProg, err := resolveProg(src)
	if err != nil {
		fmt.Fprintln(os.Stderr, "glenv: program not found:", src, err)
		os.Exit(1)
	}
	warnIfNotGlibc(src, absProg)
	if name == "" {
		name = filepath.Base(absProg)
	}
	if comment == "" {
		comment = "Launched via glenv (glibc)"
	}
	if categories == "" {
		categories = "Utility;"
	}
	termStr := "false"
	if terminal {
		termStr = "true"
	}
	out := "[Desktop Entry]\nType=Application\nVersion=1.0\n"
	out += "Name=" + name + "\n"
	out += "Comment=" + comment + "\n"
	out += "Exec=" + execLineFor(absProg, nil, sandbox, runAs) + "\n"
	if icon != "" {
		out += "Icon=" + icon + "\n"
	}
	out += "Terminal=" + termStr + "\n"
	out += "Categories=" + categories + "\n"
	out += "StartupNotify=true\n"
	dir, file := resolveDest(dest, name)
	dst := writeDesktopFile(dir, file, out)
	savePolicyFor(absProg, dst, sandbox, opt.RunAs)
	refreshMenus(dir)
	fmt.Println("Installed:", dst)
	fmt.Println("Exec:", execLineFor(absProg, nil, sandbox, runAs))
}

// warnIfNotGlibc warns when the program is not glibc.
func warnIfNotGlibc(prog, absProg string) {
	kind, _, _ := classify(absProg)
	if kind != "glibc" {
		fmt.Printf("Warning: %s is not a glibc program (%s) - installing anyway.\n", prog, kind)
	}
}

// overrideDesktopFields applies --name/--icon/--comment/--categories/--terminal
// to [Desktop Entry] of an existing .desktop content.
func overrideDesktopFields(content, name, icon, comment, categories string, terminal bool) string {
	if name == "" && icon == "" && comment == "" && categories == "" && !terminal {
		return content
	}
	lines := strings.Split(content, "\n")
	inEntry := false
	set := map[string]bool{}
	for i, line := range lines {
		t := strings.TrimSpace(line)
		switch {
		case t == "[Desktop Entry]":
			inEntry = true
		case strings.HasPrefix(t, "["):
			inEntry = false
		case inEntry && strings.HasPrefix(t, "Name=") && name != "":
			lines[i] = "Name=" + name
			set["Name"] = true
		case inEntry && strings.HasPrefix(t, "Icon=") && icon != "":
			lines[i] = "Icon=" + icon
			set["Icon"] = true
		case inEntry && strings.HasPrefix(t, "Comment=") && comment != "":
			lines[i] = "Comment=" + comment
			set["Comment"] = true
		case inEntry && strings.HasPrefix(t, "Categories=") && categories != "":
			lines[i] = "Categories=" + categories
			set["Categories"] = true
		case inEntry && strings.HasPrefix(t, "Terminal=") && terminal:
			lines[i] = "Terminal=true"
			set["Terminal"] = true
		}
	}
	var extra []string
	if name != "" && !set["Name"] {
		extra = append(extra, "Name="+name)
	}
	if icon != "" && !set["Icon"] {
		extra = append(extra, "Icon="+icon)
	}
	if comment != "" && !set["Comment"] {
		extra = append(extra, "Comment="+comment)
	}
	if categories != "" && !set["Categories"] {
		extra = append(extra, "Categories="+categories)
	}
	if terminal && !set["Terminal"] {
		extra = append(extra, "Terminal=true")
	}
	if len(extra) > 0 {
		// insert after [Desktop Entry] line
		for i, line := range lines {
			if strings.TrimSpace(line) == "[Desktop Entry]" {
				lines = append(lines[:i+1], append(extra, lines[i+1:]...)...)
				break
			}
		}
	}
	return strings.Join(lines, "\n")
}

// writeDesktopFile writes content to dir/file (creates dir).
func writeDesktopFile(dir, file, content string) string {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		fmt.Fprintln(os.Stderr, "glenv:", err)
		os.Exit(1)
	}
	dst := filepath.Join(dir, file)
	if err := os.WriteFile(dst, []byte(content), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "glenv:", err)
		os.Exit(1)
	}
	if out, err := exec.Command("desktop-file-validate", dst).CombinedOutput(); err != nil {
		fmt.Printf("Warning: desktop-file-validate: %s\n", strings.TrimSpace(string(out)))
	}
	return dst
}

// refreshMenus updates menu caches so the entry appears in KDE and other DE/WM.
func refreshMenus(dir string) {
	if _, err := exec.LookPath("update-desktop-database"); err == nil {
		_ = exec.Command("update-desktop-database", dir).Run()
	}
	// KDE Plasma 6: rebuild sycoca so the menu picks the entry up immediately.
	if _, err := exec.LookPath("kbuildsycoca6"); err == nil {
		_ = exec.Command("kbuildsycoca6", "--noincremental").Run()
	} else if _, err := exec.LookPath("kbuildsycoca5"); err == nil {
		_ = exec.Command("kbuildsycoca5", "--noincremental").Run()
	}
}

func sandboxFlag(opt Options) string {
	if opt.Sandbox == SandboxCustom {
		return "custom:" + strings.Join(opt.Custom, ",")
	}
	return opt.Sandbox
}

// writeDesktopWithExec rewrites Exec= in .desktop content.
func writeDesktopWithExec(src, newExec string) (string, error) {
	b, err := os.ReadFile(src)
	if err != nil {
		return "", err
	}
	lines := strings.Split(string(b), "\n")
	inEntry := false
	found := false
	for i, line := range lines {
		t := strings.TrimSpace(line)
		switch {
		case t == "[Desktop Entry]":
			inEntry = true
		case strings.HasPrefix(t, "["):
			inEntry = false
		case inEntry && strings.HasPrefix(t, "Exec="):
			lines[i] = "Exec=" + newExec
			found = true
		}
	}
	if !found {
		return "", fmt.Errorf("no Exec= line in %s", src)
	}
	return strings.Join(lines, "\n"), nil
}

// updateDesktopExec refreshes Exec= in the installed .desktop on policy change.
func updateDesktopExec(prog string, e *AppPolicy) {
	if e.Desktop == "" {
		return
	}
	dst := filepath.Join(desktopDir, e.Desktop)
	if _, err := os.Stat(dst); err != nil {
		return
	}
	runAs := runAsOrDefault(e.RunAs)
	execLine := fmt.Sprintf("%s run --sandbox=%s --as=%s -- %s", self, e.Sandbox, runAs, prog)
	out, err := writeDesktopWithExec(dst, execLine)
	if err != nil {
		return
	}
	_ = os.WriteFile(dst, []byte(out), 0o644)
}

// desktopRemove removes an installed glenv-.desktop.
func desktopRemove(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: glenv desktop remove <name.desktop>")
		os.Exit(2)
	}
	name := args[0]
	if !strings.HasSuffix(name, ".desktop") {
		name += ".desktop"
	}
	if !strings.HasPrefix(name, "glenv-") {
		name = "glenv-" + name
	}
	fn := filepath.Join(desktopDir, name)
	if err := os.Remove(fn); err != nil {
		fmt.Fprintln(os.Stderr, "glenv:", err)
		os.Exit(1)
	}
	// Clean the policy entry that pointed at this .desktop.
	p := loadPolicy()
	for k, v := range p.Apps {
		if v.Desktop == name {
			v.Desktop = ""
			p.Apps[k] = v
		}
	}
	_ = p.save()
	refreshMenus(desktopDir)
	fmt.Println("Removed:", fn)
}

// desktopScan - list .desktop files launched via glenv.
func desktopScan() {
	entries, _ := os.ReadDir(desktopDir)
	n := 0
	for _, de := range entries {
		if de.IsDir() || !strings.HasSuffix(de.Name(), ".desktop") {
			continue
		}
		if !strings.HasPrefix(de.Name(), "glenv-") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(desktopDir, de.Name()))
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(line, "Exec=") {
				fmt.Printf("%-40s %s\n", de.Name(), line)
				n++
				break
			}
		}
	}
	if n == 0 {
		fmt.Println("no glenv-.desktop found in", desktopDir)
	}
}

// desktopStatus - for TUI: whether the program has a .desktop.
func desktopStatus(prog string) bool {
	e := getPolicy(prog)
	if e.Desktop == "" {
		return false
	}
	_, err := os.Stat(filepath.Join(desktopDir, e.Desktop))
	return err == nil
}

// installOrUpdateDesktop installs/updates .desktop for a binary (TUI).
func installOrUpdateDesktop(prog string, e *AppPolicy) error {
	fn, err := installDesktopFor(prog, e.Sandbox, e.RunAs)
	if err != nil {
		return err
	}
	refreshMenus(filepath.Dir(fn))
	_ = fn
	return nil
}
