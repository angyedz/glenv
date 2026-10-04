package main

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

// permsCmd: glenv perms <path> [-mode 755] [-owner user:group]
func permsCmd(args []string) {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: glenv perms <path> [-mode 755] [-owner user:group]")
		os.Exit(2)
	}
	path := args[0]
	mode := ""
	owner := ""
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "-mode", "--mode":
			i++
			if i < len(args) {
				mode = args[i]
			}
		case "-owner", "--owner":
			i++
			if i < len(args) {
				owner = args[i]
			}
		}
	}
	permApply(path, mode, owner)
}

// permApply applies chmod/chown (via sudo if needed).
func permApply(path, mode, owner string) error {
	if mode != "" {
		m, err := strconv.ParseUint(mode, 8, 32)
		if err != nil {
			return fmt.Errorf("invalid mode %q (want octal, e.g. 755)", mode)
		}
		if err := os.Chmod(path, os.FileMode(m)); err != nil {
			// try via sudo
			if e := sudoChmod(path, mode); e != nil {
				return fmt.Errorf("chmod: %v (and via sudo: %v)", err, e)
			}
		}
	}
	if owner != "" {
		if err := chown(path, owner); err != nil {
			return err
		}
	}
	return nil
}

func sudoChmod(path, mode string) error {
	ensureAskpass()
	cmd := exec.Command("sudo", "-A", "chmod", mode, path)
	cmd.Env = append(os.Environ(), "SUDO_ASKPASS="+askpassFile)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd.Run()
}

func chown(path, owner string) error {
	parts := strings.SplitN(owner, ":", 2)
	uid, gid := -1, -1
	if u, err := strconv.Atoi(parts[0]); err == nil {
		uid = u
	} else {
		out, err := exec.Command("id", "-u", parts[0]).Output()
		if err != nil {
			return fmt.Errorf("no such user: %s", parts[0])
		}
		uid, _ = strconv.Atoi(strings.TrimSpace(string(out)))
	}
	if len(parts) == 2 && parts[1] != "" {
		if g, err := strconv.Atoi(parts[1]); err == nil {
			gid = g
		} else {
			out, err := exec.Command("id", "-g", parts[1]).Output()
			if err != nil {
				return fmt.Errorf("no such group: %s", parts[1])
			}
			gid, _ = strconv.Atoi(strings.TrimSpace(string(out)))
		}
	}
	err := os.Chown(path, uid, gid)
	if err == nil {
		return nil
	}
	// via sudo
	ensureAskpass()
	own := owner
	if len(parts) == 2 {
		own = fmt.Sprintf("%d:%d", uid, gid)
	} else {
		own = fmt.Sprintf("%d", uid)
	}
	c := exec.Command("sudo", "-A", "chown", own, path)
	c.Env = append(os.Environ(), "SUDO_ASKPASS="+askpassFile)
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	if e := c.Run(); e != nil {
		return fmt.Errorf("chown: %v (and via sudo: %v)", err, e)
	}
	return nil
}

// permInfo - file mode and owner for display.
func permInfo(path string) (mode string, owner string, err error) {
	st, err := os.Stat(path)
	if err != nil {
		return "", "", err
	}
	mode = fmt.Sprintf("%04o", st.Mode().Perm())
	uid := -1
	gid := -1
	if sys, ok := st.Sys().(*syscall.Stat_t); ok {
		uid = int(sys.Uid)
		gid = int(sys.Gid)
	}
	owner = fmt.Sprintf("%d:%d", uid, gid)
	if name := userName(uid); name != "" {
		owner = fmt.Sprintf("%s:%s", name, groupName(gid))
	}
	return mode, owner, nil
}

func userName(uid int) string {
	out, err := exec.Command("id", "-nu", strconv.Itoa(uid)).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func groupName(gid int) string {
	out, err := exec.Command("id", "-ng", strconv.Itoa(gid)).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}
