with Yaml.Strings.Suite;
with AUnit.Run;
with AUnit.Reporter.Text;

procedure Yaml.Strings.Harness is
   procedure Run is new AUnit.Run.Test_Runner (Suite.Suite);
   Reporter : AUnit.Reporter.Text.Text_Reporter;
begin
   Reporter.Set_Use_ANSI_Colors (True);
   Run (Reporter);
end Yaml.Strings.Harness;
