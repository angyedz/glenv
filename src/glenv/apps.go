package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// appsCmd: glenv apps scan [dirs...] - find glibc programs.
func appsCmd(args []string) {
	if len(args) == 0 || args[0] != "scan" {
		fmt.Fprintln(os.Stderr, "usage: glenv apps scan [dirs...]")
		os.Exit(2)
	}
	dirs := args[1:]
	if len(dirs) == 0 {
		for _, d := range []string{
			filepath.Join(homeDir, "Applications"),
			filepath.Join(homeDir, ".local/bin"),
			filepath.Join(homeDir, "bin"),
			filepath.Join(homeDir, "Desktop"),
			filepath.Join(homeDir, "Downloads"),
		} {
			if dirExists(d) {
				dirs = append(dirs, d)
			}
		}
	}
	if len(dirs) == 0 {
		fmt.Fprintln(os.Stderr, "no directories to scan")
		os.Exit(1)
	}
	for _, d := range dirs {
		scanDir(d, 0)
	}
}

func scanDir(root string, depth int) {
	if depth > 4 {
		return
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, e := range entries {
		p := filepath.Join(root, e.Name())
		if e.IsDir() {
			if strings.HasPrefix(e.Name(), ".") {
				continue
			}
			scanDir(p, depth+1)
			continue
		}
		if e.Type()&0o111 == 0 {
			// regular files have Type()==0 - check perms via Info()
			if fi, err := e.Info(); err == nil && fi.Mode().Perm()&0o111 == 0 {
				continue
			}
		}
		kind, interp, err := classify(p)
		if err != nil || kind != "glibc" {
			continue
		}
		pol := getPolicy(p)
		fmt.Printf("%s\n    interp: %s\n    sandbox: %s  run-as: %s  desktop: %v\n",
			p, interp, pol.Sandbox, runAsLabel(pol.RunAs), desktopStatus(p))
	}
}

func runAsLabel(s string) string {
	switch s {
	case "", "me":
		return "me"
	case "root":
		return "root"
	default:
		return s
	}
}
