with Yaml.Sources;
with Yaml.Strings;
with Ada.Strings.UTF_Encoding;

private package Yaml.Lexing is
   use Ada.Strings.UTF_Encoding;

   Default_Initial_Buffer_Size : constant := 8096;

   type Lexer is limited private;

   procedure Init
     (L : in out Lexer; Input : Sources.Source_Access;
      Pool : Strings.String_Pool;
      Initial_Buffer_Size : Positive := Default_Initial_Buffer_Size);
   procedure Init (L : in out Lexer; Input : UTF_String;
                   Pool  : Strings.String_Pool);

   procedure Finish (L : in out Lexer);

   type Token_Kind is
     (Yaml_Directive,    --  `%YAML`
      Tag_Directive,     --  `%TAG`
      Unknown_Directive, --  any directive but `%YAML` and `%TAG`
      Directive_Param,   --  parameters of %YAML and unknown directives
      Empty_Line,        --  necessary for correctly handling line folding in
                         --  multiline plain scalars
      Directives_End,    --  explicit `---`
      Document_End,      --  explicit `...`
      Stream_End,        --  end of input
      Indentation,       --  yielded at beginning of non-empty line
      Plain_Scalar,
      Single_Quoted_Scalar,
      Double_Quoted_Scalar,
      Literal_Scalar,
      Folded_Scalar,
      Seq_Item_Ind,      --  block sequence item indicator `- `
      Map_Key_Ind,       --  mapping key indicator `? `
      Map_Value_Ind,     --  mapping value indicator `: `
      Flow_Map_Start,    --  `{`
      Flow_Map_End,      --  `}`
      Flow_Seq_Start,    --  `[`
      Flow_Seq_End,      --  `]`
      Flow_Separator,    --  `,`
      Tag_Handle,        --  a handle of a tag shorthand, e.g. `!!` of `!!str`
      Tag_Uri,           --  suffix of a tag shorthand, e.g. `str` of `!!str`
                         --  also used for the URI of the %TAG directive
      Verbatim_Tag,      --  a verbatim tag, e.g. `!<tag:yaml.org,2002:str>`
      Anchor,            --  an anchor property of a node, e.g. `&anchor`
      Alias,             --  an alias property of a node, e.g. `*alias`
      Annotation         --  an annotation property of a node, e.g. `@ann`
     );
   subtype Scalar_Token_Kind is Token_Kind range Plain_Scalar .. Folded_Scalar;
   subtype Flow_Scalar_Token_Kind is
     Token_Kind range Plain_Scalar .. Double_Quoted_Scalar;
   subtype Node_Property_Kind is Token_Kind with Static_Predicate =>
     Node_Property_Kind in Tag_Handle | Verbatim_Tag | Anchor | Annotation;

   type Token is record
      Kind : Token_Kind;
      --  Start_Pos is first character, End_Pos is after last character. This
      --  is necessary for zero-length tokens (stream end)
      Start_Pos, End_Pos : Mark;
   end record;

   function Next_Token (L : in out Lexer) return Token with Inline;

   --  return the lexeme of the recent token without the first character. This
   --  is useful for anchors, aliases, directive names and the like.
   function Short_Lexeme (L : Lexer) return String with Inline;

   --  return the current lexeme including the first character. This is useful
   --  for tokens that do not have a leading indicator char.
   function Full_Lexeme (L : Lexer) return String with Inline;

   function Current_Content (L : Lexer) return Strings.Content with Inline;

   subtype Indentation_Type is Integer range -1 .. Integer'Last;
   function Current_Indentation (L : Lexer) return Indentation_Type with Inline;
   function Recent_Indentation (L : Lexer) return Indentation_Type with Inline;
private
   type Buffer_Type is access all UTF_8_String;

   type Lexer_State is access function
     (L : in out Lexer; T : out Token) return Boolean;

   type Lexer is limited record
      Cur_Line    : Positive;  --  index of the line at the current position
      Token_Start : Positive;
        --  index of the character that started the current token PLUS ONE.
        --  this index is one behind the actual first token for implementation
        --  reasons; use Short_Lexeme and Full_Lexeme to compensate.
      Line_Start  : Positive;
        --  the buffer index where the current line started
      Input       : Sources.Source_Access;  --  input provider
      Sentinel    : Positive;
        --  the position at which, when reached, the buffer must be refilled
      Pos         : Positive;
        --  position of the next character to be read from the buffer
      Buffer      : Buffer_Type;  --  input buffer. filled from the source.
      Indentation : Indentation_Type;
        --  number of indentation spaces of the recently yielded content token.
        --  this is important for internal processing of multiline tokens, as
        --  they must have at least one space of indentation more than their
        --  parents on all lines.
      Proposed_Indentation : Indentation_Type;
        --  number of indentation spaces of the recently started set of node
        --  properties. This is only necessary for implicit scalar keys with
        --  properties, to get the proper indentation value for those.
      State       : Lexer_State;
        --  pointer to the implementation of the current lexer state
      Line_Start_State : Lexer_State;
        --  state to go to after ending the current line. used in conjunction
        --  with the Expect_Line_End state.
      Json_Enabling_State : Lexer_State;
        --  used for special JSON compatibility productions. after certain
        --  tokens, it is allowed for a map value indicator to not be succeeded
        --  by whitespace.
      Cur         : Character;  --  recently read character
      Flow_Depth  : Natural; --  current level of flow collections
      Value : Strings.Content;
        --  content of the recently read scalar or URI, if any.
      Pool : Strings.String_Pool; --  used for generating Content
   end record;

   --  The following stuff is declared here so that it can be unit-tested.

   -----------------------------------------------------------------------------
   --  buffer handling
   -----------------------------------------------------------------------------

   function Next (Object : in out Lexer) return Character with Inline;
   procedure Handle_CR (L : in out Lexer);
   procedure Handle_LF (L : in out Lexer);

   -----------------------------------------------------------------------------
   --  special characters and character classes
   -----------------------------------------------------------------------------

   End_Of_Input    : constant Character := Character'Val (4);
   Line_Feed       : constant Character := Character'Val (10);
   Carriage_Return : constant Character := Character'Val (13);

   subtype Line_End is Character with Static_Predicate =>
     Line_End in Line_Feed | Carriage_Return | End_Of_Input;
   subtype Space_Or_Line_End is Character with Static_Predicate =>
     Space_Or_Line_End in ' ' | Line_End;
   subtype Comment_Or_Line_End is Character with Static_Predicate =>
     Comment_Or_Line_End in '#' | Line_End;
   subtype Digit is Character range '0' .. '9';
   subtype Ascii_Char is Character with Static_Predicate =>
     Ascii_Char in 'A' .. 'Z' | 'a' .. 'z';
   subtype Flow_Indicator is Character with Static_Predicate =>
     Flow_Indicator in '{' | '}' | '[' | ']' | ',';
   subtype Tag_Shorthand_Char is Character with Static_Predicate =>
     Tag_Shorthand_Char in Ascii_Char | Digit | '-';
   subtype Tag_Uri_Char is Character with Static_Predicate =>
     Tag_Uri_Char in Ascii_Char | Digit | '#' | ';' | '/' | '?' | ':' |
       '@' | '&' | '=' | '+' | '$' | ',' | '_' | '.' | '!' | '~' | '*' | ''' |
         '(' | ')' | '[' | ']' | '-';
   subtype Tag_Char is Character with Static_Predicate =>
     (Tag_Char in Tag_Uri_Char) and not (Tag_Char in Flow_Indicator | '!');

   -----------------------------------------------------------------------------
   --  utility subroutines (used by child packages)
   -----------------------------------------------------------------------------

   procedure End_Line (L : in out Lexer) with
     Pre => L.Cur in Comment_Or_Line_End;

   --  this function escapes a given string by converting all non-printable
   --  characters plus '"', ''' and '\', into c-style backslash escape
   --  sequences. it also surrounds the string with double quotation marks.
   --  this is primarily used for error message rendering.
   function Escaped (S : String) return String;
   function Escaped (C : Character) return String with Inline;
   function Escaped (C : Strings.Content) return String with Inline;

   function Next_Is_Plain_Safe (L : Lexer) return Boolean with Inline;

   procedure Start_Token (L : in out Lexer; T : out Token) with Inline;
   function Cur_Mark (L : Lexer; Offset : Integer := -1) return Mark
     with Inline;

   -----------------------------------------------------------------------------
   --  lexer states
   -----------------------------------------------------------------------------

   --  initial state of the lexer. in this state, the lexer is at the beginning
   --  of a line outside a YAML document. this state scans for directives,
   --  explicit directives / document end markers, or the implicit start of a
   --  document.
   function Outside_Doc (L : in out Lexer; T : out Token) return Boolean;

   --  state for reading the YAML version number after a '%YAML' directive.
   function Yaml_Version (L : in out Lexer; T : out Token) return Boolean;

   --  state for reading a tag shorthand after a '%TAG' directive.
   function Tag_Shorthand (L : in out Lexer; T : out Token) return Boolean;

   --  state for reading a tag URI after a '%TAG' directive and the
   --  corresponding tag shorthand.
   function At_Tag_Uri (L : in out Lexer; T : out Token) return Boolean;

   --  state for reading parameters of unknown directives.
   function Unknown_Directive (L : in out Lexer; T : out Token) return Boolean;

   --  state that indicates the lexer does not expect further content in the
   --  current line. it will skip whitespace and comments until the end of the
   --  line and raise an error if it encounters any content. This state never
   --  yields a token.
   function Expect_Line_End (L : in out Lexer; T : out Token) return Boolean;

   --  state at the end of the input stream.
   function Stream_End (L : in out Lexer; T : out Token) return Boolean;

   --  state at the beginnig of a line inside a YAML document when in block
   --  mode. reads indentation and directive / document end markers.
   function Line_Start (L : in out Lexer; T : out Token) return Boolean;

   --  state at the beginnig of a line inside a YAML document when in flow
   --  mode. this differs from Line_Start as it does not yield indentation
   --  tokens - instead, it just checks whether the indentation is more than
   --  the surrounding block element.
   function Flow_Line_Start (L : in out Lexer; T : out Token) return Boolean;

   --  state inside a line in block mode.
   function Inside_Line (L : in out Lexer; T : out Token) return Boolean;

   --  state inside a line in block mode where the next token on this line will
   --  set an indentation level.
   function Indentation_Setting_Token (L : in out Lexer; T : out Token)
                                       return Boolean;

   --  state after a content token in a line. used for skipping whitespace.
   function After_Token (L : in out Lexer; T : out Token) return Boolean
     with Post => After_Token'Result = False;

   --  state after a content token which allows subsequent tokens on the same
   --  line to set a new indentation level. These are tokens which allow the
   --  start of a complex node after them, namely as `- `, `: ` and `? `.
   function Before_Indentation_Setting_Token (L : in out Lexer; T : out Token)
                                              return Boolean;

   --  state after a content token which enables a json-style mapping value
   --  (i.e. a ':' without succeeding whitespace) following it.
   function After_Json_Enabling_Token (L : in out Lexer; T : out Token)
                                       return Boolean;

   --  lexing a plain scalar will always eat the indentation of the following
   --  line since the lexer must check whether the plain scalar continues on
   --  that line. this state is used for yielding that indentation after a
   --  plain scalar has been read.
   function Line_Indentation (L : in out Lexer; T : out Token) return Boolean;

   --  similar to Indentation_After_Plain_Scalar, but used for a directive end
   --  marker ending a plain scalar.
   function Line_Dir_End (L : in out Lexer; T : out Token) return Boolean;

   --  similar to Indentation_After_Plain_Scalar, but used for a document end
   --  marker ending a plain scalar.
   function Line_Doc_End (L : in out Lexer; T : out Token) return Boolean;

   --  state after having read a tag handle. this will always yield the
   --  corresponding tag suffix.
   function At_Tag_Suffix (L : in out Lexer; T : out Token) return Boolean;
end Yaml.Lexing;
