unit Errors;

interface

type
  [Derive(ToString)]
  TPoint = record
    X, Y: Integer;
  end;

  [Derive(Parse)]
  TA = (A1, A2);

  [Derive(ToString), Weak]
  TB = (B1, B2);

  [Derive]
  TC = (C1, C2);

implementation

procedure P;
type
  [Derive(ToString)]
  TInner = (I1, I2);
begin
end;

end.
