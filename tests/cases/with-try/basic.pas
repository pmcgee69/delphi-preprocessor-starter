unit WithTryBasic;

interface

implementation

uses
  System.SysUtils, Vcl.Forms;

procedure Save(Form1: TForm);
begin
  with Form1 do
    Caption := 'saving';
  try
    Form1.Close;
  except
  end;
  try
    Form1.Close;
  finally
  end;
  try
    Form1.Close;
  except
    on E: Exception do Form1.Caption := E.Message;
  end;
  try
    Form1.Close;
  except
    // closing twice is harmless: meant
  end;
end;

end.
