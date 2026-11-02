unit CrlfCase;
interface
implementation
procedure P(const S: string);
var
  X: Integer;
begin
  case S of   // the comment's node holds this line's CR
    'abc' : X := 1;
  else
    X := 0;
  end;
end;
end.
