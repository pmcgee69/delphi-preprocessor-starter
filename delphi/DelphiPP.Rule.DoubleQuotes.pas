unit DelphiPP.Rule.DoubleQuotes;

{ THE `double-quotes` RULE: a rewrite, the simplest there is. Each " inside a
  string becomes '':

      S := 'say "hi"';
  becomes
      S := 'say ''hi''';

  Not useful in itself: a first rewrite to learn from. Delphi 12's multi-line
  strings ('''...''') are left alone, since a quote inside them isn't doubled.

  HOW THIS ONE WAS MADE:

  1. A sample: tests\cases\double-quotes\basic.pas.
  2. Its tree (bin\delphipp.exe --tree ...): a string is a node of Kind
     'literalString', the whole of it, #13#10 and all:
         literalString                'say "hi"'#13#10'and "bye"'
           literalChar                #13
           literalChar                #10
     A " can only be inside its quotes: #34 is how one is written outside.
  3. So Kinds is ['literalString'], and Visit proposes the string's text with
     each " replaced (Ctx.Replace). The engine applies it. }

interface

uses
  DelphiPP.Engine;

type
  TDoubleQuotes = class(TRule)
  public
    function Name: string; override;
    function Kinds: TArray<string>; override;
    function Description: string; override;
    procedure Visit(const Node: TNode; Ctx: TContext); override;
  end;

implementation

uses
  System.SysUtils;

function TDoubleQuotes.Name: string;
begin
  Exit( 'double-quotes' );
end;

function TDoubleQuotes.Kinds: TArray<string>;
begin
  Result := ['literalString'];
end;

function TDoubleQuotes.Description: string;
begin
  Exit( 'A rewrite: each " inside a string becomes ''''.' );
end;

// called once for each string in the file
procedure TDoubleQuotes.Visit(const Node: TNode; Ctx: TContext);
begin
  const Text = Ctx.Text(Node);
  if not Text.Contains('"') or Text.StartsWith('''''''') then
    Exit;
  Ctx.Replace(Node, Text.Replace('"', ''''''));
end;

end.
