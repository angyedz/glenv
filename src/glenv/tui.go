package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// item - app in the TUI list.
type item struct {
	title, desc string
	prog        string
}

func (i item) Title() string       { return i.title }
func (i item) Description() string { return i.desc }
func (i item) FilterValue() string { return i.title + " " + i.desc }

type mode int

const (
	modeList mode = iota
	modeInput // path/mode input
)

type model struct {
	list     list.Model
	items    []item
	progOf   map[string]string // title -> prog path
	mode     mode
	input    textinput.Model
	inputKind string // "add" | "mode" | "owner"
	target    string // for mode/owner
	status    string
	width, height int
}

func tuiCmd() {
	m := newModel()
	p := tea.NewProgram(&m, tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "glenv:", err)
		os.Exit(1)
	}
}

func newModel() model {
	ti := textinput.New()
	ti.Placeholder = "program path"
	ti.CharLimit = 4096

	m := model{
		progOf:  map[string]string{},
		mode:    modeList,
		input:   ti,
	}
	m.reload()
	return m
}

// reload lists apps: policy + scan.
func (m *model) reload() {
	m.items = nil
	m.progOf = map[string]string{}

	seen := map[string]bool{}
	add := func(prog string) {
		if seen[prog] {
			return
		}
		if !dirExists(filepath.Dir(prog)) {
			return
		}
		if st, err := os.Stat(prog); err != nil || st.IsDir() {
			return
		}
		kind, interp, err := classify(prog)
		if err != nil || kind != "glibc" {
			return
		}
		seen[prog] = true
		pol := getPolicy(prog)
		title := filepath.Base(prog)
		desc := fmt.Sprintf("%s │ sandbox: %s │ as: %s │ .desktop: %v",
			prog, pol.Sandbox, runAsLabel(pol.RunAs), desktopStatus(prog))
		if interp != "" {
			desc += " │ " + filepath.Base(interp)
		}
		m.progOf[title] = prog
		m.items = append(m.items, item{title: title, desc: desc, prog: prog})
	}

	// from policy
	p := loadPolicy()
	for prog := range p.Apps {
		add(prog)
	}
	// scan standard dirs
	for _, d := range []string{
		filepath.Join(homeDir, "Applications"),
		filepath.Join(homeDir, ".local/bin"),
		filepath.Join(homeDir, "bin"),
		filepath.Join(homeDir, "Desktop"),
	} {
		collectGlibc(d, 0, add)
	}

	li := make([]list.Item, len(m.items))
	for i, it := range m.items {
		li[i] = it
	}
	l := list.New(li, list.NewDefaultDelegate(), 0, 0)
	l.Title = "glenv - glibc apps"
	l.SetShowStatusBar(true)
	l.SetFilteringEnabled(true)
	l.SetShowHelp(true)
	if m.width > 0 {
		l.SetSize(m.width-2, m.height-4)
	}
	// keep selection
	if prev, ok := m.list.SelectedItem().(item); ok {
		for i, it := range m.items {
			if it.title == prev.title {
				l.Select(i)
				break
			}
		}
	}
	m.list = l
}

func collectGlibc(root string, depth int, add func(string)) {
	if depth > 3 {
		return
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return
	}
	for _, e := range entries {
		p := filepath.Join(root, e.Name())
		if e.IsDir() {
			if !strings.HasPrefix(e.Name(), ".") {
				collectGlibc(p, depth+1, add)
			}
			continue
		}
		if e.Type()&0o111 == 0 {
			if fi, err := e.Info(); err == nil && fi.Mode().Perm()&0o111 == 0 {
				continue
			}
		}
		if kind, _, err := classify(p); err == nil && kind == "glibc" {
			add(p)
		}
	}
}

func (m *model) Init() tea.Cmd { return textinput.Blink }

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case statusMsg:
		m.status = string(msg)
		return m, nil
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		m.list.SetSize(msg.Width-2, msg.Height-4)
		return m, nil

	case tea.KeyMsg:
		if m.mode == modeInput {
			switch msg.String() {
			case "esc":
				m.mode = modeList
				m.input.Blur()
				return m, nil
			case "enter":
				val := strings.TrimSpace(m.input.Value())
				m.mode = modeList
				m.input.Blur()
				return m, m.submitInput(val)
			}
			var cmd tea.Cmd
			m.input, cmd = m.input.Update(msg)
			return m, cmd
		}

		// list mode
		if m.list.FilterState() == list.Filtering {
			// filter input in progress - pass everything to the list
			var cmd tea.Cmd
			m.list, cmd = m.list.Update(msg)
			return m, cmd
		}
		switch msg.String() {
		case "q":
			if m.list.FilterState() == list.Filtering {
				break
			}
			return m, tea.Quit
		case "enter":
			sel, ok := m.selected()
			if !ok {
				return m, nil
			}
			return m, tea.ExecProcess(m.launchCmd(sel), func(err error) tea.Msg {
				if err != nil {
					return statusMsg("launch error: " + err.Error())
				}
				return statusMsg("launch finished")
			})
		case "s":
			return m, m.cycleSandbox()
		case "u":
			return m, m.cycleRunAs()
		case "d":
			return m, m.toggleDesktop()
		case "m":
			sel, ok := m.selected()
			if !ok {
				return m, nil
			}
			m.mode = modeInput
			m.inputKind = "mode"
			m.target = sel.prog
			cur, _, _ := permInfo(sel.prog)
			m.input.SetValue(cur)
			m.input.Placeholder = "new mode, e.g. 755"
			m.input.CursorEnd()
			m.input.Focus()
			return m, textinput.Blink
		case "o":
			sel, ok := m.selected()
			if !ok {
				return m, nil
			}
			m.mode = modeInput
			m.inputKind = "owner"
			m.target = sel.prog
			_, curOwn, _ := permInfo(sel.prog)
			m.input.SetValue(curOwn)
			m.input.Placeholder = "owner, e.g. 1000:1000"
			m.input.CursorEnd()
			m.input.Focus()
			return m, textinput.Blink
		case "a":
			m.mode = modeInput
			m.inputKind = "add"
			m.input.SetValue("")
			m.input.Placeholder = "glibc program path"
			m.input.Focus()
			return m, textinput.Blink
		case "r":
			m.reload()
			m.status = "list refreshed"
			return m, nil
		}
	}

	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return m, cmd
}

type statusMsg string

func (m *model) submitInput(val string) tea.Cmd {
	switch m.inputKind {
	case "add":
		abs, err := resolveProg(val)
		if err != nil {
			return func() tea.Msg { return statusMsg("not found: " + val) }
		}
		// force-add to policy so it shows in the list
		if err := savePolicy(abs, getPolicy(abs)); err != nil {
			return func() tea.Msg { return statusMsg("error: " + err.Error()) }
		}
		m.reload()
		return func() tea.Msg { return statusMsg("added: " + abs) }
	case "mode":
		if err := permApply(m.target, val, ""); err != nil {
			return func() tea.Msg { return statusMsg("chmod: " + err.Error()) }
		}
		return func() tea.Msg { return statusMsg("mode set: " + val) }
	case "owner":
		if err := permApply(m.target, "", val); err != nil {
			return func() tea.Msg { return statusMsg("chown: " + err.Error()) }
		}
		return func() tea.Msg { return statusMsg("owner set: " + val) }
	}
	return nil
}

func (m *model) selected() (item, bool) {
	it, ok := m.list.SelectedItem().(item)
	return it, ok
}

// launchCmd - launch command (via glenv itself, so all flags work).
func (m model) launchCmd(it item) *exec.Cmd {
	pol := getPolicy(it.prog)
	args := []string{"run", "--sandbox=" + pol.Sandbox, "--as=" + runAsOrDefault(pol.RunAs), "--", it.prog}
	return exec.Command(self, args...)
}

var sandboxPresets = []string{SandboxFull, SandboxHome, SandboxHomeNoNet, "custom:" + homeDir, SandboxNone}
var sandboxLabels = map[string]string{
	SandboxFull:      "ALL like on a glibc distro",
	SandboxHome:      "home rw + rest ro, net",
	SandboxHomeNoNet: "home rw + rest ro, NO net",
	SandboxNone:      "no sandbox (loader only)",
}
var runAsPresets = []string{"", "root"}

func (m *model) cycleSandbox() tea.Cmd {
	sel, ok := m.selected()
	if !ok {
		return nil
	}
	pol := getPolicy(sel.prog)
	idx := 0
	for i, s := range sandboxPresets {
		if s == pol.Sandbox {
			idx = (i + 1) % len(sandboxPresets)
			break
		}
	}
	pol.Sandbox = sandboxPresets[idx]
	if err := savePolicy(sel.prog, pol); err != nil {
		return func() tea.Msg { return statusMsg("error: " + err.Error()) }
	}
	label := sandboxLabels[pol.Sandbox]
	if label == "" {
		label = pol.Sandbox
	}
	m.reload()
	m.status = fmt.Sprintf("sandbox \"%s\" - %s", pol.Sandbox, label)
	return nil
}

func (m *model) cycleRunAs() tea.Cmd {
	sel, ok := m.selected()
	if !ok {
		return nil
	}
	pol := getPolicy(sel.prog)
	idx := 0
	for i, s := range runAsPresets {
		if s == pol.RunAs {
			idx = (i + 1) % len(runAsPresets)
			break
		}
	}
	pol.RunAs = runAsPresets[idx]
	if err := savePolicy(sel.prog, pol); err != nil {
		return func() tea.Msg { return statusMsg("error: " + err.Error()) }
	}
	m.reload()
	m.status = "run as: " + runAsLabel(pol.RunAs)
	return nil
}

func (m *model) toggleDesktop() tea.Cmd {
	sel, ok := m.selected()
	if !ok {
		return nil
	}
	pol := getPolicy(sel.prog)
	if desktopStatus(sel.prog) {
		// remove
		_ = desktopRemoveSilent(pol.Desktop)
		pol.Desktop = ""
		_ = savePolicy(sel.prog, pol)
		m.reload()
		m.status = ".desktop removed"
		return nil
	}
	if err := installOrUpdateDesktop(sel.prog, pol); err != nil {
		return func() tea.Msg { return statusMsg(".desktop: " + err.Error()) }
	}
	m.reload()
	m.status = ".desktop installed: glenv-" + filepath.Base(sel.prog) + ".desktop"
	return nil
}

func desktopRemoveSilent(name string) error {
	if name == "" {
		return nil
	}
	return os.Remove(filepath.Join(desktopDir, name))
}

func (m model) View() string {
	var b strings.Builder

	if m.mode == modeInput {
		title := "Add program:"
		switch m.inputKind {
		case "mode":
			title = "New mode (octal) for " + filepath.Base(m.target) + ":"
		case "owner":
			title = "New owner (uid:gid) for " + filepath.Base(m.target) + ":"
		}
		b.WriteString(title + "\n\n")
		b.WriteString(m.input.View() + "\n\n")
		b.WriteString("enter - apply, esc - cancel")
		return b.String()
	}

	header := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("212")).Render("glenv - run glibc programs")
	b.WriteString(header + "\n")

	// selected item caption
	if sel, ok := m.selected(); ok {
		pol := getPolicy(sel.prog)
		sLabel := sandboxLabels[pol.Sandbox]
		if sLabel == "" {
			sLabel = pol.Sandbox
		}
		line := fmt.Sprintf("sandbox: %s (%s) │ run-as: %s │ .desktop: %v",
			pol.Sandbox, sLabel, runAsLabel(pol.RunAs), desktopStatus(sel.prog))
		if mo, ow, err := permInfo(sel.prog); err == nil {
			line += fmt.Sprintf(" │ perms: %s %s", mo, ow)
		}
		b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("244")).Render(line) + "\n")
	}

	b.WriteString(m.list.View() + "\n")

	keys := "enter: run │ s: sandbox │ u: run-as │ d: .desktop │ m: chmod │ o: owner │ a: add │ r: refresh │ q: quit"
	b.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("241")).Render(keys))
	if m.status != "" {
		b.WriteString("\n" + lipgloss.NewStyle().Foreground(lipgloss.Color("114")).Render("▸ "+m.status))
	}
	return b.String()
}
