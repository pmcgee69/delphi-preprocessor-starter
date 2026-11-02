unit UsesIfdef;

interface

implementation

{$IFDEF MSWINDOWS}
uses Winapi.Windows, System.SysUtils;
{$ENDIF}
{$IFDEF POSIX}
uses Posix.Unistd, System.SysUtils;
{$ENDIF}

end.
