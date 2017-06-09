with Ada.Unchecked_Deallocation;
with Yaml.Lexing.Evaluation;

package body Yaml.Lexing is
   use Yaml.Strings;

   -----------------------------------------------------------------------------
   --             Initialization and buffer handling                          --
   -----------------------------------------------------------------------------

   procedure Free is new Ada.Unchecked_Deallocation (String, Buffer_Type);

   function Next (Object : in out Lexer) return Character is
   begin
      return C : constant Character := Object.Buffer (Object.Pos) do
         Object.Pos := Object.Pos + 1;
      end return;
   end Next;

   procedure Refill_Buffer (L : in out Lexer) is
      Bytes_To_Copy : constant Natural := L.Buffer'Last + 1 - L.Sentinel;
      Fill_At : Positive := Bytes_To_Copy + 1;
      Bytes_Read : Positive;

      function Search_Sentinel return Boolean with Inline is
         Peek : Positive := L.Buffer'Last;
      begin
         while not (L.Buffer (Peek) in Line_End) loop
            if Peek = Fill_At then
               return False;
            else
               Peek := Peek - 1;
            end if;
         end loop;
         L.Sentinel := Peek + 1;
         return True;
      end Search_Sentinel;
   begin
      if Bytes_To_Copy > 0 then
         L.Buffer (1 .. Bytes_To_Copy) := L.Buffer (L.Sentinel .. L.Buffer'Last);
      end if;
      loop
         L.Input.Read_Data (L.Buffer (Fill_At .. L.Buffer'Last), Bytes_Read);
         if Bytes_Read < L.Buffer'Last - Fill_At then
            L.Sentinel := Fill_At + Bytes_Read + 1;
            L.Buffer (L.Sentinel - 1) := End_Of_Input;
            exit;
         else
            exit when Search_Sentinel;
            Fill_At := L.Buffer'Last + 1;
            declare
               New_Buffer : constant Buffer_Type :=
                 new UTF_String (1 .. 2 * L.Buffer'Last);
            begin
               New_Buffer.all (L.Buffer'Range) := L.Buffer.all;
               Free (L.Buffer);
               L.Buffer := New_Buffer;
            end;
         end if;
      end loop;
   end Refill_Buffer;

   procedure Handle_CR (L : in out Lexer) is
   begin
      if L.Buffer (L.Pos) = Line_Feed then
         L.Pos := L.Pos + 1;
      end if;
      if L.Pos = L.Sentinel then
         Refill_Buffer (L);
         L.Pos := 1;
      end if;
      L.Line_Start := L.Pos;
      L.Cur_Line := L.Cur_Line + 1;
      L.Cur := Next (L);
   end Handle_CR;

   procedure Handle_LF (L : in out Lexer) is
   begin
      if L.Pos = L.Sentinel then
         Refill_Buffer (L);
         L.Pos := 1;
      end if;
      L.Line_Start := L.Pos;
      L.Cur_Line := L.Cur_Line + 1;
      L.Cur := Next (L);
   end Handle_LF;

   procedure Basic_Init (L : in out Lexer; Input : Sources.Source_Access;
                        Buffer : Buffer_Type; Pool  : Strings.String_Pool) is
   begin
      L.Input := Input;
      L.Sentinel := Buffer.all'Last + 1;
      L.Buffer := Buffer;
      L.Pos := Buffer.all'First;
      L.Cur_Line := 1;
      L.State := Outside_Doc'Access;
      L.Flow_Depth := 0;
      L.Line_Start_State := Outside_Doc'Access;
      L.Json_Enabling_State := Inside_Line'Access;
      L.Pool := Pool;
      L.Line_Start := Buffer.all'First;
   end Basic_Init;

   procedure Init
     (L : in out Lexer; Input : Sources.Source_Access; Pool : Strings.String_Pool;
      Initial_Buffer_Size : Positive := Default_Initial_Buffer_Size) is
   begin
      Basic_Init (L, Input, new String (1 .. Initial_Buffer_Size), Pool);
      Refill_Buffer (L);
      L.Cur := Next (L);
   end Init;

   procedure Init (L : in out Lexer; Input : String;
                   Pool : Strings.String_Pool) is
   begin
      Basic_Init (L, null, new String (1 .. Input'Length + 1), Pool);
      L.Buffer.all := Input & End_Of_Input;
      L.Cur := Next (L);
   end Init;

   -----------------------------------------------------------------------------
   --  interface and utilities
   -----------------------------------------------------------------------------

   function Escaped (S : String) return String is
      Ret : String (1 .. S'Length * 4 + 2) := (1 => '"', others => <>);
      Retpos : Positive := 2;

      procedure Add_Escape_Sequence (C : Character) with Inline is
      begin
         Ret (Retpos .. Retpos + 1) := "\" & C;
         Retpos := Retpos + 2;
      end Add_Escape_Sequence;
   begin
      for C of S loop
         case C is
            when Line_Feed         => Add_Escape_Sequence ('l');
            when Carriage_Return   => Add_Escape_Sequence ('c');
            when '"' | ''' | '\'   => Add_Escape_Sequence (C);
            when Character'Val (9) => Add_Escape_Sequence ('t');
            when Character'Val (0) .. Character'Val (8) | Character'Val (11) |
                 Character'Val (12) | Character'Val (14) .. Character'Val (31)
               =>
               Add_Escape_Sequence ('x');
               declare
                  type Byte is range 0 .. 255;
                  Charpos : constant Byte := Character'Pos (C);
               begin
                  Ret (Retpos .. Retpos + 1) :=
                    (Character'Val (Charpos / 16 + Character'Pos ('0'))) &
                    (Character'Val (Charpos mod 16 + Character'Pos ('0')));
                  Retpos := Retpos + 2;
               end;
            when others =>
               Ret (Retpos) := C;
               Retpos := Retpos + 1;
         end case;
      end loop;
      Ret (Retpos) := '"';
      return Ret (1 .. Retpos);
   end Escaped;

   function Escaped (C : Character) return String is (Escaped ("" & C));

   function Escaped (C : Strings.Content) return String is
     (Escaped (Value (C)));

   function Next_Is_Plain_Safe (L : Lexer) return Boolean is
      (case L.Buffer (L.Pos) is
         when Space_Or_Line_End => False,
         when Flow_Indicator => L.Flow_Depth = 0,
          when others => True);

   function Next_Token (L : in out Lexer) return Token is
      Ret : Token;
   begin
      loop
         exit when L.State.all (L, Ret);
      end loop;
      return Ret;
   end Next_Token;

   function Short_Lexeme (L : Lexer) return String is
      (L.Buffer (L.Token_Start .. L.Pos - 2));

   function Full_Lexeme (L : Lexer) return String is
     (L.Buffer (L.Token_Start - 1 .. L.Pos - 2));

   procedure Start_Token (L : in out Lexer; T : out Token) is
   begin
      L.Token_Start := L.Pos;
      T := (Start_Pos => Cur_Mark (L), others => <>);
   end Start_Token;

   function Cur_Mark (L : Lexer; Offset : Integer := -1) return Mark is
     ((Line => L.Cur_Line, Column => L.Pos - L.Line_Start - Offset, Index => 1));

   function Current_Content (L : Lexer) return Strings.Content is
     (L.Value);

   function Current_Indentation (L : Lexer) return Indentation_Type is
     (L.Pos - L.Line_Start - 1);

   function Recent_Indentation (L : Lexer) return Indentation_Type is
      (L.Indentation);

   -----------------------------------------------------------------------------
   --                            Tokenization                                 --
   -----------------------------------------------------------------------------

   --  to be called whenever a '-' is read as first character in a line. this
   --  function checks for whether this is a directives end marker ('---'). if
   --  yes, the lexer position is updated to be after the marker.
   function Is_Directives_End (L : in out Lexer) return Boolean is
      Peek : Positive := L.Pos;
   begin
      if L.Buffer (Peek) = '-' then
         Peek := Peek + 1;
         if L.Buffer (Peek) = '-' then
            Peek := Peek + 1;
            if L.Buffer (Peek) in Space_Or_Line_End then
               L.Pos := Peek;
               L.Cur := Next (L);
               return True;
            end if;
         end if;
      end if;
      return False;
   end Is_Directives_End;

   --  similar to Hyphen_Line_Type, this function checks whether, when a line
   --  begin with a '.', that line contains a document end marker ('...'). if
   --  yes, the lexer position is updated to be after the marker.
   function Is_Document_End (L : in out Lexer) return Boolean is
      Peek : Positive := L.Pos;
   begin
      if L.Buffer (Peek) = '.' then
         Peek := Peek + 1;
         if L.Buffer (Peek) = '.' then
            Peek := Peek + 1;
            if L.Buffer (Peek) in Space_Or_Line_End then
               L.Pos := Peek;
               L.Cur := Next (L);
               return True;
            end if;
         end if;
      end if;
      return False;
   end Is_Document_End;

   function Outside_Doc (L : in out Lexer; T : out Token) return Boolean is
   begin
      case L.Cur is
         when '%' =>
            Start_Token (L, T);
            loop
               L.Cur := Next (L);
               exit when L.Cur in Space_Or_Line_End;
            end loop;
            T.End_Pos := Cur_Mark (L);
            declare
               Name : constant String := Short_Lexeme (L);
            begin
               if Name = "YAML" then
                  L.State := Yaml_Version'Access;
                  T.Kind := Yaml_Directive;
                  return True;
               elsif Name = "TAG" then
                  L.State := Tag_Shorthand'Access;
                  T.Kind := Tag_Directive;
                  return True;
               else
                  L.State := Unknown_Directive'Access;
                  T.Kind := Unknown_Directive;
                  return True;
               end if;
            end;
         when '-' =>
            Start_Token (L, T);
            if Is_Directives_End (L) then
               L.State := Inside_Line'Access;
               T.Kind := Directives_End;
            else
               L.State := Indentation_Setting_Token'Access;
               T.Kind := Indentation;
            end if;
            T.End_Pos := Cur_Mark (L);
            L.Indentation := -1;
            L.Line_Start_State := Line_Start'Access;
            return True;
         when '.' =>
            Start_Token (L, T);
            if Is_Document_End (L) then
               L.State := Expect_Line_End'Access;
               T.Kind := Document_End;
            else
               L.State := Indentation_Setting_Token'Access;
               L.Line_Start_State := Line_Start'Access;
               L.Indentation := -1;
               T.Kind := Indentation;
            end if;
            T.End_Pos := Cur_Mark (L);
            return True;
         when others =>
            Start_Token (L, T);
            while L.Cur = ' ' loop
               L.Cur := Next (L);
            end loop;
            if L.Cur in Comment_Or_Line_End then
               L.State := Expect_Line_End'Access;
               return False;
            end if;
            T.Kind := Indentation;
            T.End_Pos := Cur_Mark (L);
            L.Indentation := -1;
            L.State := Indentation_Setting_Token'Access;
            L.Line_Start_State := Line_Start'Access;
            return True;
      end case;
   end Outside_Doc;

   function Yaml_Version (L : in out Lexer; T : out Token) return Boolean is
      procedure Read_Numeric_Subtoken is
      begin
         if not (L.Cur in Digit) then
            raise Lexer_Error with "Illegal character in YAML version string: " &
              Escaped (L.Cur);
         end if;
         loop
            L.Cur := Next (L);
            exit when not (L.Cur in Digit);
         end loop;
      end Read_Numeric_Subtoken;
   begin
      while L.Cur = ' ' loop
         L.Cur := Next (L);
      end loop;
      Start_Token (L, T);
      Read_Numeric_Subtoken;
      if L.Cur /= '.' then
         raise Lexer_Error with "Illegal character in YAML version string: " &
           Escaped (L.Cur);
      end if;
      L.Cur := Next (L);
      Read_Numeric_Subtoken;
      if not (L.Cur in Space_Or_Line_End) then
         raise Lexer_Error with "Illegal character in YAML version string: " &
           Escaped (L.Cur);
      end if;
      T.End_Pos := Cur_Mark (L);
      T.Kind := Directive_Param;
      L.State := Expect_Line_End'Access;
      return True;
   end Yaml_Version;

   function Tag_Shorthand (L : in out Lexer; T : out Token) return Boolean is
   begin
      while L.Cur = ' ' loop
         L.Cur := Next (L);
      end loop;
      if L.Cur /= '!' then
         raise Lexer_Error with
           "Illegal character, tag shorthand must start with ""!"":" &
           Escaped (L.Cur);
      end if;
      Start_Token (L, T);
      L.Cur := Next (L);
      if L.Cur /= ' ' then
         while L.Cur in Tag_Shorthand_Char loop
            L.Cur := Next (L);
         end loop;
         if L.Cur /= '!' then
            if L.Cur in Space_Or_Line_End then
               raise Lexer_Error with "Tag shorthand must end with ""!"".";
            else
               raise Lexer_Error with "Illegal character in tag shorthand: " &
                 Escaped (L.Cur);
            end if;
         end if;
         L.Cur := Next (L);
         if L.Cur /= ' ' then
            raise Lexer_Error with "Missing space after tag shorthand";
         end if;
      end if;
      T.End_Pos := Cur_Mark (L);
      T.Kind := Tag_Handle;
      L.State := At_Tag_Uri'Access;
      return True;
   end Tag_Shorthand;

   function At_Tag_Uri (L : in out Lexer; T : out Token) return Boolean is
   begin
      while L.Cur = ' ' loop
         L.Cur := Next (L);
      end loop;
      Start_Token (L, T);
      if L.Cur = '<' then
         raise Lexer_Error with "Illegal character in tag prefix: " &
           Escaped (L.Cur);
      end if;
      Evaluation.Read_URI (L, False);
      T.End_Pos := Cur_Mark (L);
      T.Kind := Tag_Uri;
      L.State := Expect_Line_End'Access;
      return True;
   end At_Tag_Uri;

   function Unknown_Directive (L : in out Lexer; T : out Token) return Boolean
   is begin
      while L.Cur = ' ' loop
         L.Cur := Next (L);
      end loop;
      if L.Cur in Comment_Or_Line_End then
         L.State := Expect_Line_End'Access;
         return False;
      end if;
      Start_Token (L, T);
      loop
         L.Cur := Next (L);
         exit when L.Cur in Space_Or_Line_End;
      end loop;
      T.End_Pos := Cur_Mark (L);
      T.Kind := Directive_Param;
      return True;
   end Unknown_Directive;

   procedure End_Line (L : in out Lexer) is
   begin
      loop
         case L.Cur is
            when Line_Feed =>
               Handle_LF (L);
               L.State := L.Line_Start_State;
               exit;
            when Carriage_Return =>
               Handle_CR (L);
               L.State := L.Line_Start_State;
               exit;
            when End_Of_Input =>
               L.State := Stream_End'Access;
               exit;
            when '#' =>
               loop
                  L.Cur := Next (L);
                  exit when L.Cur in Line_End;
               end loop;
            when others => null; --  forbidden by precondition
         end case;
      end loop;
   end End_Line;

   function Expect_Line_End (L : in out Lexer; T : out Token) return Boolean is
      pragma Unreferenced (T);
   begin
      while L.Cur = ' ' loop
         L.Cur := Next (L);
      end loop;
      if not (L.Cur in Comment_Or_Line_End) then
         raise Lexer_Error with
           "Unexpected character (expected line end): " & Escaped (L.Cur);
      end if;
      End_Line (L);
      return False;
   end Expect_Line_End;

   function Stream_End (L : in out Lexer; T : out Token) return Boolean is
   begin
      Start_Token (L, T);
      T.End_Pos := Cur_Mark (L);
      T.Kind := Stream_End;
      return True;
   end Stream_End;

   function Line_Start (L : in out Lexer; T : out Token) return Boolean is
   begin
      case L.Cur is
         when '-' =>
            if Is_Directives_End (L) then
               return Line_Dir_End (L, T);
            else
               return Line_Indentation (L, T);
            end if;
         when '.' =>
            if Is_Document_End (L) then
               return Line_Doc_End (L, T);
            else
               return Line_Indentation (L, T);
            end if;
         when others =>
            while L.Cur = ' ' loop
               L.Cur := Next (L);
            end loop;
            if L.Cur in Comment_Or_Line_End then
               End_Line (L);
               return False;
            end if;
            return Line_Indentation (L, T);
      end case;
   end Line_Start;

   function Flow_Line_Start (L : in out Lexer; T : out Token) return Boolean is
      pragma Unreferenced (T);
      Indent : Natural;
   begin
      case L.Cur is
         when '-' =>
            if Is_Directives_End (L) then
               raise Lexer_Error with
                 "Directives end marker before end of flow content";
            else
               Indent := 0;
            end if;
         when '.' =>
            if Is_Document_End (L) then
               raise Lexer_Error with
                 "Document end marker before end of flow content";
            else
               Indent := 0;
            end if;
         when others =>
            while L.Cur = ' ' loop
               L.Cur := Next (L);
            end loop;
            Indent := L.Pos - L.Line_Start - 1;
      end case;
      if Indent <= L.Indentation then
         raise Lexer_Error with
           "Too few indentation spaces (must surpass surrounding block element)" & L.Indentation'Img;
      end if;
      L.State := Inside_Line'Access;
      return False;
   end Flow_Line_Start;

   procedure Check_Indicator_Char (L : in out Lexer; Kind : Token_Kind;
                                   T : out Token) is
   begin
      if Next_Is_Plain_Safe (L) then
         Evaluation.Read_Plain_Scalar (L, T);
      else
         Start_Token (L, T);
         L.Cur := Next (L);
         T.Kind := Kind;
         T.End_Pos := Cur_Mark (L);
         L.State := Before_Indentation_Setting_Token'Access;
      end if;
   end Check_Indicator_Char;

   procedure Enter_Flow_Collection (L : in out Lexer; T : out Token) is
   begin
      Start_Token (L, T);
      if L.Flow_Depth = 0 then
         L.Json_Enabling_State := After_Json_Enabling_Token'Access;
         L.Line_Start_State := Flow_Line_Start'Access;
      end if;
      L.Flow_Depth := L.Flow_Depth + 1;
      L.State := After_Token'Access;
      L.Cur := Next (L);
      T.End_Pos := Cur_Mark (L);
   end Enter_Flow_Collection;

   procedure Leave_Flow_Collection (L : in out Lexer; T : out Token) is
   begin
      Start_Token (L, T);
      if L.Flow_Depth = 0 then
         raise Lexer_Error with "No flow collection to leave!";
      end if;
      L.Flow_Depth := L.Flow_Depth - 1;
      if L.Flow_Depth = 0 then
         L.Json_Enabling_State := After_Token'Access;
         L.Line_Start_State := Line_Start'Access;
      end if;
      L.State := L.Json_Enabling_State;
      L.Cur := Next (L);
      T.End_Pos := Cur_Mark (L);
   end Leave_Flow_Collection;

   procedure Read_Tag_Handle (L : in out Lexer; T : out Token) with
     Pre => L.Cur = '!' is
   begin
      Start_Token (L, T);
      L.Cur := Next (L);
      if L.Cur = '<' then
         Evaluation.Read_URI (L, False);
         T.End_Pos := Cur_Mark (L);
         T.Kind := Verbatim_Tag;
         L.State := After_Token'Access;
      else
         --  we need to scan for a possible second '!' in case this is not a
         --  primary tag handle. We must lookahead here because there may be
         --  URI characters in the suffix that are not allowed in the handle.
         declare
            Handle_End : Positive := L.Token_Start;
         begin
            loop
               case L.Buffer (Handle_End) is
                  when Space_Or_Line_End | Flow_Indicator =>
                     Handle_End := L.Token_Start;
                     L.Pos := L.Pos - 1;
                     exit;
                  when '!' =>
                     Handle_End := Handle_End + 1;
                     exit;
                  when others =>
                     Handle_End := Handle_End + 1;
               end case;
            end loop;
            while L.Pos < Handle_End loop
               L.Cur := Next (L);
               if not (L.Cur in Tag_Shorthand_Char | '!') then
                  raise Lexer_Error with "Illegal character in tag handle: " &
                    Escaped (L.Cur);
               end if;
            end loop;
            L.Cur := Next (L);
            T.End_Pos := Cur_Mark (L);
            T.Kind := Tag_Handle;
            L.State := At_Tag_Suffix'Access;
         end;
      end if;
   end Read_Tag_Handle;

   procedure Read_Anchor_Name (L : in out Lexer; T : out Token) is
   begin
      Start_Token (L, T);
      loop
         L.Cur := Next (L);
         exit when not (L.Cur in Ascii_Char | Digit | '-' | '_');
      end loop;
      T.End_Pos := Cur_Mark (L);
      if not (L.Cur in Space_Or_Line_End | Flow_Indicator) then
         raise Lexer_Error with "Illegal character in anchor: " &
           Escaped (L.Cur);
      elsif L.Pos = L.Token_Start + 1 then
         raise Lexer_Error with "Anchor name must not be empty";
      end if;
      L.State := After_Token'Access;
   end Read_Anchor_Name;

   function Inside_Line (L : in out Lexer; T : out Token) return Boolean is
   begin
      case L.Cur is
         when ':' =>
            Check_Indicator_Char (L, Map_Value_Ind, T);
            return True;
         when '?' =>
            Check_Indicator_Char (L, Map_Key_Ind, T);
            return True;
         when '-' =>
            Check_Indicator_Char (L, Seq_Item_Ind, T);
            return True;
         when Comment_Or_Line_End =>
            End_Line (L);
            return False;
         when '"' =>
            Evaluation.Read_Double_Quoted_Scalar (L, T);
            L.State := L.Json_Enabling_State;
            return True;
         when ''' =>
            Evaluation.Read_Single_Quoted_Scalar (L, T);
            L.State := L.Json_Enabling_State;
            return True;
         when '>' | '|' =>
            if L.Flow_Depth > 0 then
               Evaluation.Read_Plain_Scalar (L, T);
            else
               Evaluation.Read_Block_Scalar (L, T);
            end if;
            return True;
         when '{' =>
            Enter_Flow_Collection (L, T);
            T.Kind := Flow_Map_Start;
            return True;
         when '}' =>
            Leave_Flow_Collection (L, T);
            T.Kind := Flow_Map_End;
            return True;
         when '[' =>
            Enter_Flow_Collection (L, T);
            T.Kind := Flow_Seq_Start;
            return True;
         when ']' =>
            Leave_Flow_Collection (L, T);
            T.Kind := Flow_Seq_End;
            return True;
         when ',' =>
            Start_Token (L, T);
            L.Cur := Next (L);
            T.End_Pos := Cur_Mark (L);
            T.Kind := Flow_Separator;
            L.State := After_Token'Access;
            return True;
         when '!' =>
            Read_Tag_Handle (L, T);
            return True;
         when '&' =>
            Read_Anchor_Name (L, T);
            T.Kind := Anchor;
            return True;
         when '*' =>
            Read_Anchor_Name (L, T);
            T.Kind := Alias;
            return True;
         when '@' =>
            Read_Anchor_Name (L, T);
            T.Kind := Annotation;
            return True;
         when '`' =>
            raise Lexer_Error with
              "Reserved characters cannot start a plain scalar.";
         when others =>
            Evaluation.Read_Plain_Scalar (L, T);
            return True;
      end case;
   end Inside_Line;

   function Indentation_Setting_Token (L : in out Lexer; T : out Token)
                                       return Boolean is
      Cached_Indentation : constant Natural := L.Pos - L.Line_Start - 1;
   begin
      return Ret : constant Boolean := Inside_Line (L, T) do
         if Ret and L.Flow_Depth = 0 then
            L.Indentation := Cached_Indentation;
         end if;
      end return;
   end Indentation_Setting_Token;

   function After_Token (L : in out Lexer; T : out Token) return Boolean is
      pragma Unreferenced (T);
   begin
      while L.Cur = ' ' loop
         L.Cur := Next (L);
      end loop;
      if L.Cur in Comment_Or_Line_End then
         End_Line (L);
      else
         L.State := Inside_Line'Access;
      end if;
      return False;
   end After_Token;

   function Before_Indentation_Setting_Token (L : in out Lexer; T : out Token)
                                              return Boolean is
   begin
      if After_Token (L, T) then
         null;
      end if;
      if L.State = Inside_Line'Access then
         L.State := Indentation_Setting_Token'Access;
      end if;
      return False;
   end Before_Indentation_Setting_Token;

   function After_Json_Enabling_Token (L : in out Lexer; T : out Token)
                                       return Boolean is
   begin
      while L.Cur = ' ' loop
         L.Cur := Next (L);
      end loop;
      loop
         case L.Cur is
            when ':' =>
               Start_Token (L, T);
               L.Cur := Next (L);
               T.Kind := Map_Value_Ind;
               T.End_Pos := Cur_Mark (L);
               L.State := After_Token'Access;
               return True;
            when '#' | Carriage_Return | Line_Feed =>
               End_Line (L);
               if Flow_Line_Start (L, T) then null; end if;
            when End_Of_Input =>
               L.State := Stream_End'Access;
               return False;
            when others =>
               L.State := Inside_Line'Access;
               return False;
         end case;
      end loop;
   end After_Json_Enabling_Token;

   function Line_Indentation (L : in out Lexer; T : out Token)
                              return Boolean is
   begin
      T := (Start_Pos => (Line => L.Cur_Line, Column => 1, Index => 1),
            End_Pos => Cur_Mark (L), Kind => Indentation);
      L.State := Indentation_Setting_Token'Access;
      return True;
   end Line_Indentation;

   function Line_Dir_End (L : in out Lexer; T : out Token)
                          return Boolean is
   begin
      T := (Start_Pos => (Line => L.Cur_Line, Column => 1, Index => 1),
            End_Pos => Cur_Mark (L), Kind => Directives_End);
      L.State := Inside_Line'Access;
      L.Indentation := -1;
      return True;
   end Line_Dir_End;

   --  similar to Indentation_After_Plain_Scalar, but used for a document end
   --  marker ending a plain scalar.
   function Line_Doc_End (L : in out Lexer; T : out Token)
                          return Boolean is
   begin
      T := (Start_Pos => (Line => L.Cur_Line, Column => 1, Index => 1),
            End_Pos => Cur_Mark (L), Kind => Document_End);
      L.State := Expect_Line_End'Access;
      L.Line_Start_State := Outside_Doc'Access;
      return True;
   end Line_Doc_End;

   function At_Tag_Suffix (L : in out Lexer; T : out Token) return Boolean is
   begin
      Start_Token (L, T);
      Evaluation.Read_URI (L, True);
      T.End_Pos := Cur_Mark (L);
      T.Kind := Tag_Uri;
      L.State := After_Token'Access;
      return True;
   end At_Tag_Suffix;

end Yaml.Lexing;