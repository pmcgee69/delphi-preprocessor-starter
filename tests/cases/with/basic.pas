unit WithBasic;

interface

implementation

uses
  Vcl.Forms, Vcl.StdCtrls;

procedure Show(Form1: TForm; Edit1: TEdit);
begin
  with Form1, Edit1 do
    Text := Caption;
  with Form1 do Caption := 'checked';
  // with in a comment is not a statement
end;

end.
