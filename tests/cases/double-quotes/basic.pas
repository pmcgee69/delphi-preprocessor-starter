unit DoubleQuotesBasic;

interface

implementation

const
  Plain    = '"abc"';
  Inside   = 'say "hi"';
  Joined   = 'say "hi"'#13#10'and "bye"';
  Codes    = #34'x'#34;
  Already  = 'it''s';
  None     = 'abc';
  Multi    = '''
    "multi"
    ''';

end.
