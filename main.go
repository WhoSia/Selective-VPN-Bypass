package main

import (
 "crypto/sha256"
 "embed"
 "fmt"
 "os"
 "os/exec"
 "path/filepath"
 "runtime"
 "syscall"
 "unsafe"
)

//go:embed src/Gui.ps1 src/Core.ps1 src/Worker.ps1
var scripts embed.FS

func errorBox(message string) {
 p:=syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW")
 s,_:=syscall.UTF16PtrFromString(message)
 title,_:=syscall.UTF16PtrFromString("Selective VPN Bypass")
 p.Call(0,uintptr(unsafe.Pointer(s)),uintptr(unsafe.Pointer(title)),0x10)
}
func unpack(dir,name string) error {
 data,err:=scripts.ReadFile("src/"+name);if err!=nil{return err}
 dest:=filepath.Join(dir,name)
 existing,err:=os.ReadFile(dest)
 if err==nil && sha256.Sum256(existing)==sha256.Sum256(data){return nil}
 tmp:=dest+".new"
 if err=os.WriteFile(tmp,data,0600);err!=nil{return err}
 _=os.Remove(dest)
 return os.Rename(tmp,dest)
}
func launch() error {
 if runtime.GOOS!="windows"{return fmt.Errorf("Windows only")}
 exe,err:=os.Executable();if err!=nil{return err}
 // Portable local configuration only. Never silently read a parent Downloads folder.
 dataDir:=filepath.Dir(exe)
 configRoot:=os.Getenv("LOCALAPPDATA")
 if configRoot==""{configRoot,err=os.UserConfigDir();if err!=nil{return err}}
 rt:=filepath.Join(configRoot,"SelectiveVPNBypass","runtime-v4")
 if err=os.MkdirAll(rt,0700);err!=nil{return err}
 for _,f:=range []string{"Gui.ps1","Core.ps1","Worker.ps1"}{
  if err=unpack(rt,f);err!=nil{return err}
 }
 powershell:=filepath.Join(os.Getenv("SystemRoot"),"System32","WindowsPowerShell","v1.0","powershell.exe")
 cmd:=exec.Command(powershell,"-NoLogo","-NoProfile","-STA","-ExecutionPolicy","Bypass","-WindowStyle","Hidden",
  "-File",filepath.Join(rt,"Gui.ps1"),"-RuntimeDir",rt,"-DataDir",dataDir)
 cmd.Dir=dataDir
 cmd.SysProcAttr=&syscall.SysProcAttr{HideWindow:true}
 logFile,err:=os.Create(filepath.Join(rt,"startup.log"))
 if err==nil{defer logFile.Close();cmd.Stdout=logFile;cmd.Stderr=logFile}
 if err=cmd.Run();err!=nil{return fmt.Errorf("GUI execution failed: %v (see runtime startup.log)",err)}
 return nil
}
func main(){if err:=launch();err!=nil{errorBox(err.Error())}}
