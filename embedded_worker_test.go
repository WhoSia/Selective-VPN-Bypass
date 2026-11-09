package main

import (
 "os"
 "os/exec"
 "path/filepath"
 "strings"
 "testing"
)

func TestWorkerArgumentBoundary(t *testing.T) {
 exe:=filepath.Join(t.TempDir(),"SelectiveVPNBypass_GUI.exe")
 dir:=filepath.Dir(exe)
 log:=filepath.Join(t.TempDir(),"svb-0123456789abcdef0123456789abcdef.log")
 if err:=validateWorkerArguments(exe,"apply",dir,log);err!=nil{t.Fatal(err)}
 if err:=validateWorkerArguments(exe,"restore",dir,log);err!=nil{t.Fatal(err)}
 cases:=[]struct{action,config,log string}{
  {"add",dir,log},
  {"status",dir,log},
  {"apply",filepath.Join(dir,"other"),log},
  {"apply",dir,filepath.Join(t.TempDir(),"different.log")},
 }
 for _,c:=range cases {
  if err:=validateWorkerArguments(exe,c.action,c.config,c.log);err==nil{
   t.Errorf("accepted untrusted worker arguments: action=%s",c.action)
  }
 }
}

func TestPowerShellSingleQuoteEscaping(t *testing.T){
 got:=psLiteral("a'b")
 if got!="'a''b'"{t.Fatalf("unexpected quote encoding: %s",got)}
}

// Runs the same stdin bootstrap as the embedded elevated helper but invokes
// the read-only list action in an isolated folder: no network privileges.
func TestEmbeddedPowerShellBootstrapList(t *testing.T){
 core,err:=scripts.ReadFile("src/Core.ps1");if err!=nil{t.Fatal(err)}
 tmp:=t.TempDir()
 log:=filepath.Join(tmp,"svb-0123456789abcdef0123456789abcdef.log")
 p:=filepath.Join(os.Getenv("SystemRoot"),"System32","WindowsPowerShell","v1.0","powershell.exe")
 cmd:=exec.Command(p,"-NoLogo","-NoProfile","-NonInteractive","-ExecutionPolicy","Bypass","-EncodedCommand",utf16EncodedCommand(workerBootstrap))
 cmd.Stdin=strings.NewReader(embeddedCoreWrapper(core,"list",tmp,log))
 output,err:=cmd.CombinedOutput()
 if err!=nil{t.Fatalf("embedded list failed: %v output=%s",err,output)}
 if _,err:=os.Stat(log);err!=nil{t.Fatalf("embedded worker failed to write log: %v",err)}
}
