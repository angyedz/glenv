package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// AppPolicy - saved launch policy for one app.
type AppPolicy struct {
	Sandbox string `json:"sandbox,omitempty"`
	RunAs   string `json:"run_as,omitempty"`
	Desktop string `json:"desktop,omitempty"` // installed .desktop (file name)
}

// Policies - ~/.glenv/policies.json
type Policies struct {
	Apps map[string]*AppPolicy `json:"apps"`
}

func loadPolicy() *Policies {
	p := &Policies{Apps: map[string]*AppPolicy{}}
	b, err := os.ReadFile(policyFile)
	if err == nil {
		_ = json.Unmarshal(b, p)
	}
	if p.Apps == nil {
		p.Apps = map[string]*AppPolicy{}
	}
	return p
}

func (p *Policies) save() error {
	if err := os.MkdirAll(glenvDir, 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(policyFile, b, 0o600)
}

// getPolicy returns the app policy (creating if needed).
func getPolicy(prog string) *AppPolicy {
	p := loadPolicy()
	e, ok := p.Apps[prog]
	if !ok {
		e = &AppPolicy{}
		p.Apps[prog] = e
	}
	if e.Sandbox == "" {
		e.Sandbox = SandboxFull
	}
	return e
}

// savePolicy stores the policy and refreshes .desktop if installed.
func savePolicy(prog string, e *AppPolicy) error {
	p := loadPolicy()
	p.Apps[prog] = e
	if err := p.save(); err != nil {
		return err
	}
	if e.Desktop != "" {
		updateDesktopExec(prog, e)
	}
	return nil
}

// ensureAskpass writes ~/.glenv/askpass.sh (reads the saved sudo password).
func ensureAskpass() {
	if _, err := os.Stat(askpassFile); err == nil {
		return
	}
	_ = os.MkdirAll(glenvDir, 0o700)
	script := "#!/bin/sh\n" +
		"P=\"$HOME/.glenv/.pass\"\n" +
		"if [ -r \"$P\" ]; then cat \"$P\"; exit 0; fi\n" +
		"printf 'Password: ' >/dev/tty\n" +
		"read -r X </dev/tty\n" +
		"printf '%s' \"$X\"\n"
	_ = os.WriteFile(askpassFile, []byte(script), 0o700)
}

// authCmd: glenv auth save
func authCmd(args []string) {
	if len(args) == 0 || args[0] != "save" {
		fmt.Fprintln(os.Stderr, "usage: glenv auth save")
		os.Exit(2)
	}
	fmt.Fprint(os.Stderr, "sudo password (stored in ~/.glenv/.pass, 0600): ")
	var pass string
	if _, err := fmt.Fscanln(os.Stdin, &pass); err != nil {
		fmt.Fprintln(os.Stderr, "read error:", err)
		os.Exit(1)
	}
	_ = os.MkdirAll(glenvDir, 0o700)
	if err := os.WriteFile(passFile, []byte(pass+"\n"), 0o600); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	ensureAskpass()
	fmt.Println("Saved to", passFile)
}

// sudoPasswdOk - quick check for a saved password.
func sudoPasswdOk() bool {
	if _, err := os.Stat(passFile); err != nil {
		return false
	}
	return true
}

// installDesktopFor installs .desktop for a binary and records the name in policy.
func installDesktopFor(prog, sandbox, runAs string) (string, error) {
	name := filepath.Base(prog)
	desktop := fmt.Sprintf(`[Desktop Entry]
Type=Application
Name=%s
Comment=Launched via glenv (glibc)
Exec=%s run --sandbox=%s --as=%s -- %s
Terminal=false
Categories=Utility;
`, name, self, sandbox, runAsOrDefault(runAs), prog)
	if err := os.MkdirAll(desktopDir, 0o755); err != nil {
		return "", err
	}
	fn := filepath.Join(desktopDir, "glenv-"+name+".desktop")
	if err := os.WriteFile(fn, []byte(desktop), 0o644); err != nil {
		return "", err
	}
	e := getPolicy(prog)
	e.Desktop = filepath.Base(fn)
	e.Sandbox = sandbox
	e.RunAs = runAs
	if err := savePolicy(prog, e); err != nil {
		return "", err
	}
	return fn, nil
}

func runAsOrDefault(s string) string {
	if s == "" {
		return "me"
	}
	return s
}
