package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// doctorCmd - environment check.
func doctorCmd() {
	ok := func(b bool) string {
		if b {
			return "OK "
		}
		return "NO "
	}
	st, err := os.Stat(loaderPath)
	fmt.Printf("[%s] sysroot: %s\n", ok(err == nil), sysrootDir)
	fmt.Printf("[%s] loader:  %s\n", ok(err == nil), loaderPath)
	if err == nil {
		fmt.Printf("        libc:    %s\n", filepath.Join(libPath, "libc.so.6"))
	}
	_, gerr := os.Stat(gconvDir)
	fmt.Printf("[%s] gconv:   %s\n", ok(gerr == nil), gconvDir)
	_, berr := exec.LookPath("bwrap")
	fmt.Printf("[%s] bwrap:   sandbox (userns)\n", ok(berr == nil))
	_, serr := exec.LookPath("sudo")
	fmt.Printf("[%s] sudo:    run as root/other user\n", ok(serr == nil))
	if _, perr := os.Stat(passFile); perr == nil {
		fmt.Printf("[OK ] passwd:  saved (%s)\n", passFile)
	} else {
		fmt.Printf("[-- ] passwd:  not saved (glenv auth save) - will prompt at launch\n")
	}
	if st != nil && err == nil {
		fmt.Printf("        size:    %d bytes\n", st.Size())
	}
	// Wayland explicit-sync filter. glibc reads /etc/ld.so.preload, musl never
	// does, so this file is what carries the fix to directly executed binaries.
	preload, perr := os.ReadFile("/etc/ld.so.preload")
	shimName := filepath.Join(envDir, "lib", "glenv-wayland-filter.so")
	shimOK := perr == nil && strings.Contains(string(preload), shimName)
	fmt.Printf("[%s] filter:  wayland explicit-sync shim in /etc/ld.so.preload\n", ok(shimOK))
	if !shimOK {
		fmt.Printf("        fix: run tools/integrate-system.sh\n")
	}
	// PipeWire client modules. Without them every glibc screen-share client dies
	// inside pw_context_new(), immediately after the portal picker.
	proto := filepath.Join(tripletDir, "pipewire-0.3", "libpipewire-module-protocol-native.so")
	_, werr := os.Stat(proto)
	fmt.Printf("[%s] pipewire: client modules (screen share path)\n", ok(werr == nil))
	if werr != nil {
		fmt.Printf("        fix: tools/fetch-deps.py libpipewire-0.3-modules pipewire-bin\n")
	}
	_ = strings.TrimSpace("")
}
