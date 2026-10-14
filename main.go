package main

import (
    "crypto/sha256"
    "embed"
    "fmt"
    "os"
    "os/exec"
    "path/filepath"
    "runtime"
    "strings"
    "syscall"
    "unsafe"
)

//go:embed src/Gui.ps1 src/Core.ps1 src/Worker.ps1
var resources embed.FS

func errorBox(s string) {
    dll := syscall.NewLazyDLL("user32.dll")
    proc := dll.NewProc("MessageBoxW")
    txt, _ := syscall.UTF16PtrFromString(s)
    title, _ := syscall.UTF16PtrFromString("Selective VPN Bypass")
    proc.Call(0, uintptr(unsafe.Pointer(txt)), uintptr(unsafe.Pointer(title)), 0x10)
}

func saveRuntime(runtimeDir, file string) error {
    b, err := resources.ReadFile("src/" + file)
    if err != nil { return err }
    out := filepath.Join(runtimeDir, file)
    existing, err := os.ReadFile(out)
    if err == nil && sha256.Sum256(existing) == sha256.Sum256(b) { return nil }
    temp := out + ".new"
    if err := os.WriteFile(temp, b, 0600); err != nil { return err }
    _ = os.Remove(out)
    return os.Rename(temp, out)
}

func run() error {
    if runtime.GOOS != "windows" { return fmt.Errorf("Windows only") }
    exe, err := os.Executable()
    if err != nil { return err }
    dataDir := filepath.Dir(exe)
    parent := filepath.Dir(dataDir)
    cfgName := "Selective-VPN-Bypass.domains.json"
    _, inCurrentErr := os.Stat(filepath.Join(dataDir, cfgName))
    if os.IsNotExist(inCurrentErr) {
        for _, n := range []string{cfgName, "Selective-VPN-Bypass_v3.state.json", "Selective-VPN-Bypass.state.json"} {
            if _, err := os.Stat(filepath.Join(parent, n)); err == nil {
                dataDir = parent
                break
            }
        }
    }
    root := os.Getenv("LOCALAPPDATA")
    if strings.TrimSpace(root) == "" {
        root, err = os.UserConfigDir()
        if err != nil { return err }
    }
    runtimeDir := filepath.Join(root, "SelectiveVPNBypass", "runtime-2")
    if err := os.MkdirAll(runtimeDir, 0700); err != nil { return err }
    for _, f := range []string{"Gui.ps1", "Core.ps1", "Worker.ps1"} {
        if err := saveRuntime(runtimeDir, f); err != nil { return err }
    }
    ps := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
    if _, err := os.Stat(ps); err != nil { ps = "powershell.exe" }
    cmd := exec.Command(ps,
        "-NoLogo", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
        "-File", filepath.Join(runtimeDir, "Gui.ps1"),
        "-RuntimeDir", runtimeDir, "-DataDir", dataDir,
    )
    cmd.Dir = dataDir
    cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
    logPath := filepath.Join(runtimeDir,"startup.log")
    f, err := os.Create(logPath)
    if err == nil { defer f.Close(); cmd.Stdout = f; cmd.Stderr = f }
    if err := cmd.Run(); err != nil {
        return fmt.Errorf("GUI startup failed (%v). Log: %s",err,logPath)
    }
    return nil
}

func main() {
    if err := run(); err != nil { errorBox(err.Error()) }
}
