module Wit
  module Codegen
    PTRSIZE = 8 # The size of a pointer, in bytes. (should equal sizeof(void*))

    # All the x64 registers.
    enum Reg
      Rax
      Rbx
      Rcx
      Rdx
      Rsi
      Rdi
      Rsp
      Rbp
      R8
      R9
      R10
      R11

      # Is this an x64-only register?
      def reg64?
        self.value >= 8
      end

      # Generate the appropiate register string given the desired size.
      def regsz(sz : Int32)
        reg64 = self.reg64?
        base = self.to_s.downcase
        case sz
        when 1
          reg64 ? base + 'b' : base[1].to_s + 'l'
        when 2
          reg64 ? base + 'w' : base[1..2]
        when 4
          reg64 ? base + 'd' : "e" + base[1..2]
        when 8
          base
        else
          raise "invalid size #{sz} given to Reg.regsz"
        end
      end
    end

    # x64 info for builtin types.
    class X64BuiltinTypeInfo
      getter size

      def initialize(sym)
        @size = case sym
        when :Byte, :Char
          1
        when :Int
          4
        when :Long
          8
        else
          raise "invalid type symbol #{sym}"
        end
      end
    end

    # Variable info.
    class X64VarInfo
      # global determines if this is a global variable.
      # size is the size in bytes.
      # label is the base of the variable.
      # offs is the offset.
      # Variable is at [label+offs]
      getter global, size, label, offs

      def initialize(@global : Bool, @size : Int32, @label : String,
        @offs : Int32)
      end
    end

    # Procedure info.
    class X64BuiltinProcInfo
      # sym: the procedure name
      getter sym

      def initialize(@sym)
      end
    end

    class X64Generator
      # All the registers that can be used for values.
      # XXX: This should be sorted in an order that will minimize spills by
      # needsregsfor.
      @@allregs = [Reg::R8, Reg::R9, Reg::R10, Reg::R11, Reg::Rdx, Reg::Rbx,
                   Reg::Rcx, Reg::Rsi, Reg::Rdi]

      def initialize
        # totals is used to determine how much space to let off the stack
        # when a procedure returns.
        @totals = [] of Int32
        # The used registers.
        @usedregs = [] of Reg
      end

      # Get the Intel-style string representing an integral byte count.
      def getszstr(sz : Int32)
        case sz
        when 1
          "byte"
        when 2
          "word"
        when 4
          "dword"
        when 8
          "qword"
        else
          raise "invalid size #{sz} given to szstr"
        end
      end

      # Get the d* size specifier for NASM data sections.
      def getszspec(typ : Parser::Type)
        if typ.is_a? Parser::ArrayType
          return self.getszspec typ.base
        end
        sz = self.tysize typ
        raise "invalid type size: #{sz}" if !sz || !(sz & (sz-1))
        "d#{"bwd q"[sz>>1]}"
      end

      # Emit a line.
      def emit(line="")
        puts line
      end

      # Emit a line with two preceding spaces.
      def emittb(line="")
        self.emit "  #{line}"
      end

      # Get a register from the list of available ones.
      # XXX: This will crash if too many registers are used.
      # It needs to spill one onto the stack and reuse it instead.
      def getreg
        reg = @@allregs.select{|reg| !@usedregs.includes? reg}[0]
        @usedregs.push reg
        reg
      end

      # Mark some registers as no longer used.
      def freereg(*regs : Reg)
        regs.each { |reg| @usedregs.delete reg }
      end

      # Free registers if they're register items.
      def ofree(*regs : Parser::Item)
        regs.each do |maybereg|
          self.freereg maybereg.reg if maybereg.is_a? Parser::RegItem
        end
      end

      # Use a register for the duration of the given block.
      def regblock
        yield reg = self.getreg
        self.freereg reg
      end

      # Require the given registers for the block's duration.
      # Spills a used one if needed.
      def needsregsfor(regs : Array(Reg))
        used = regs.select{|reg| @usedregs.includes? reg}
        used.each do |reg|
          self.emittb "push #{reg.regsz PTRSIZE}"
          @usedregs.push reg
        end
        yield
        used.each do |reg|
          self.emittb "pop #{reg.regsz PTRSIZE}"
          @usedregs.delete reg
        end
      end

      # Get the size of the given type.
      def tysize(typ : Parser::Type)
        case typ
        when Parser::BuiltinType
          typ.typeinfo.size
        when Parser::PointerType
          PTRSIZE
        when Parser::ArrayType
          typ.cap * self.tysize typ.base
        else
          raise "invalid type #{typ.class} given to tysize"
        end
      end

      # Convert the given item to a string suitiable for use in an x64 operand.
      def itemstr(item : Parser::Item)
        case item
        when Parser::ConstItem
          # to_s will give scientific notation for large numbers
          "%d" % item.value
        when Parser::MemItem
          # Optimize.
          if item.mul == "1" && item.offs == "0"
            "[#{item.base}]"
          else
            offs = item.offs
            "[#{item.base}*#{item.mul}#{offs[0] == '-' ? offs : "+#{offs}"}]"
          end
        when Parser::RegItem
          item.reg.regsz self.tysize item.typ
        else
          raise "invalid item #{item.class} given to itemstr"
        end
      end

      # The prolog of the program.
      def prprolog
        self.emit "global _start"
        self.emit
      end

      # The beginning of the data section.
      def datasect
        self.emit "section .data"
        self.emittb "wit$newl: db 10"
      end

      # The beginning of the instruction section.
      def isect
        self.emit "section .text"
      end

      # The program epilog.
      def prepilog
      end

      # The prolog of the main function.
      def mainprolog
        @totals.push 0
        self.emit "_start:"
      end

      # The epilog
      def mainepilog
        # No need to reset the stack if no variables were allocated.
        if @totals[-1] != 0
          self.emittb "mov rsp, rbp"
          self.emittb "pop rbp"
        end
        @totals.pop
        # Linux syscall for exit.
        self.emittb "mov rax, 60"
        self.emittb "xor rdi, rdi"
        self.emittb "syscall"
      end

      # Procedure prolog.
      def prolog
        @totals.push 0
      end

      # Procedure epilog.
      def epilog
        if @totals[-1] != 0
          self.emittb "mov rsp, rbp"
          self.emittb "pop rbp"
        end
        @totals.pop
        self.emittb "ret"
      end

      # Emit the given globals.
      def emitglobals(globals : Hash(String, Parser::Variable))
        labels = {} of String => String
        # Export the ones that need to be exported.
        globals.each do |name, var|
          labels[name] = var.export ? name : "wit$global$#{name}"
          self.emittb "global #{labels[name]}" if var.export
        end

        # Generate the storage sections.
        globals.each do |name, var|
          typ = var.typ
          sz = self.tysize typ
          sp = self.getszspec typ
          var.info = X64VarInfo.new true, sz, labels[name], 0
          if typ.is_a? Parser::ArrayType
            self.emittb "#{labels[name]}:"
            0.to(sz) {|i| self.emittb "  #{sp} 0"}
          else
            self.emittb "#{labels[name]}: #{sp} 0"
          end
        end
      end

      # Emit the code to allocate locals on the stack.
      def emitlocals(locals : Hash(String, Parser::Variable))
        total = 0
        locals.values.each do |var|
          sz = self.tysize var.typ
          total += sz
          var.info = X64VarInfo.new false, sz, "", total
        end
        # Save the total for use in the epilog.
        @totals[-1] = total
        return if total == 0 # Optimize.
        self.emittb "push rbp"
        self.emittb "mov rbp, rsp"
        self.emittb "sub rsp, #{total}"
      end

      # Return an item representing the given variable.
      def id(id : Parser::Variable)
        info = id.info as X64VarInfo
        if info.global
          Parser::MemItem.new info.label, "1", "0", id.typ
        else
          Parser::MemItem.new "rbp", "1", "-#{info.offs}", id.typ
        end
      end

      # Generate code for the address of the item.
      def address(item : Parser::Item)
        raise "invalid item #{item.class} given to address"\
          if !item.is_a? Parser::MemItem
        reg = self.getreg
        self.emittb "lea #{reg.regsz PTRSIZE}, #{self.itemstr item}"
        self.ofree item
        Parser::RegItem.new reg, Parser::PointerType.new item.typ
      end

      # Generate a two's complement (i.e. arithmetic) negation.
      def neg(item : Parser::Item)
        reg = self.getreg
        regsz = reg.regsz self.tysize item.typ
        self.emittb "mov #{regsz}, #{self.itemstr item}"
        self.emittb "neg #{regsz}"
        self.ofree item
        Parser::RegItem.new reg, item.typ
      end

      # Cast lhs and rhs to a common type
      def eqtyp(lhs : Parser::Item, rhs : Parser::Item)
        lhsz = self.tysize lhs.typ
        rhsz = self.tysize rhs.typ
        if lhsz > rhsz
          rhs = if rhs.is_a? Parser::ConstItem
            rhs.retype lhs.typ
          else
            self.cast rhs, lhs.typ
          end
        elsif lhsz < rhsz
          lhs = if lhs.is_a? Parser::ConstItem
            lhs.retype rhs.typ
          else
            self.cast lhs, rhs.typ
          end
        end

        {lhs, rhs}
      end

      # Generate an arithmetic operation.
      def op(lhs : Parser::Item, rhs : Parser::Item, op : Scanner::TokenType)
        optype = op.prec
        dst = if optype == 2
          # Multiplication and division always return in ax.
          Reg::Rax
        elsif lhs.is_a? Parser::RegItem
          # Registers are only used for temporaries, so the result can be placed
          # there.
          lhs.reg
        else
          # The left-hand-side must be moved to the register.
          reg = self.getreg
          self.emittb "mov #{reg.regsz self.tysize lhs.typ}, #{self.itemstr lhs}"
          reg
        end
        lhsz = self.tysize lhs.typ
        rhsz = self.tysize rhs.typ
        raise "lhs and rhs sizes should be the same in op" if lhsz != rhsz
        dsts = dst.regsz lhsz
        lhss = self.itemstr lhs
        rhss = self.itemstr rhs
        case optype
        when 0, 1 # <<, >>, +, -
          ops = case op
          when Scanner::TokenType::LShift
            "shl"
          when Scanner::TokenType::RShift
            "shr"
          when Scanner::TokenType::Plus
            "add"
          when Scanner::TokenType::Minus
            "sub"
          end

          self.emittb "#{ops} #{dsts}, #{rhss}"
        when 2 # *, /
          ops = case op
          when Scanner::TokenType::Star
            "mul"
          when Scanner::TokenType::Slash
            "div"
          end

          if rhs.is_a? Parser::ConstItem
            # x86/64 does not support the mul/div instruction with an immediate.
            reg = self.getreg.regsz self.tysize rhs.typ
            self.emittb "mov #{reg}, #{rhss}"
            rhss = reg
          end

          self.needsregsfor [Reg::Rdx] do
            self.emittb "mov #{Reg::Rax.regsz self.tysize lhs.typ}, #{lhss}"
            self.emittb "#{ops} #{rhss}"
          end
        end
        self.ofree lhs, rhs
        Parser::RegItem.new dst, lhs.typ
      end

      # Generate the code to cast a variable.
      def cast(item : Parser::Item, typ : Parser::Type)
        srcsz = self.tysize item.typ
        dstsz = self.tysize typ
        # Avoid generating useless instructions and `mov`s.
        return item.retype typ if srcsz == dstsz
        res = case item
        when Parser::RegItem
          # Clear out the top bits.
          self.emittb "and #{item.reg.regsz srcsz}, 0x#{"F"*(dstsz-srcsz).abs}"
          Parser::RegItem.new item.reg, typ
        when Parser::MemItem
          reg = self.getreg
          # Clear out the top bits.
          self.emittb "xor #{reg.regsz dstsz}, #{reg.regsz dstsz}"\
            if dstsz > srcsz
          self.emittb "mov #{reg.regsz dstsz}, #{self.itemstr item}"
          Parser::RegItem.new reg, typ
        when Parser::ConstItem
          # The parser should have handled this.
          raise "ConstItem given to cast"
        else
          raise "invalid item #{item.class} given to cast"
        end
        self.ofree item
        res
      end

      # Generate code for a call.
      def call(tgt : Parser::Proc, args : Array(Parser::Item))
        res = if tgt.is_a? Parser::BuiltinProc
          case sym = tgt.procinfo.sym
          when :WriteELn
            self.needsregsfor [Reg::Rdi, Reg::Rsi, Reg::Rdx] do
              self.emittb "mov rax, 1"
              self.emittb "mov rdi, 1"
              self.emittb "mov rsi, wit$newl"
              self.emittb "mov rdx, 1"
              self.emittb "syscall"
            end
            Parser::VoidItem.new
          when :D2I
            reg = self.getreg
            # d2i(x) = x - '0'
            self.emittb "mov #{reg.regsz 1}, #{self.itemstr args[0]}"
            self.emittb "sub #{reg.regsz 1}, 48"
            Parser::RegItem.new reg, tgt.ret as Parser::Type
          else
            raise "invalid proc #{sym} given to call"
          end
        else
          raise "invalid proc type #{tgt.class} given to call"
        end
        args.each { |arg| self.ofree arg }
        res
      end

      # Generate code for an index.
      def index(array : Parser::Item, index : Parser::Item)
        basetyp = (array.typ as Parser::DerivedType).base
        basesz = self.tysize basetyp

        mul, offs = if index.is_a? Parser::ConstItem
          {"1", (index.value * basesz).to_s}
        else
          if index.is_a? Parser::MemItem
            # Memory indexes should be moved to registers
            reg = self.getreg
            self.emittb "mov #{reg.regsz self.tysize index.typ}, \
              #{self.itemstr index}"
            index = Parser::RegItem.new reg, index.typ
          end
          {basesz.to_s, self.itemstr index}
        end

        case array
        when Parser::RegItem
          Parser::MemItem.new array.reg, mul, offs, basetyp
        when Parser::MemItem
          # XXX: This generates *horrible* code.
          regsz = self.getreg.regsz PTRSIZE
          self.emittb "lea #{regsz}, #{self.itemstr array}"
          Parser::MemItem.new regsz, mul, offs, basetyp
        else
          # XXX: This will explode when const arrays are implemented.
          raise "item #{array.class} given as array to index"
        end
      end

      # Generate code for a variable assignment.
      def assign(tgt : Parser::Item, expr : Parser::Item)
        tgtsz = self.tysize tgt.typ
        szstr = self.getszstr tgtsz
        itemstr = self.itemstr expr
        out = self.itemstr tgt
        if expr.is_a? Parser::MemItem
          self.regblock do |reg|
            # x64 doesn't allow moving memory to memory.
            regsz = reg.regsz tgtsz
            self.emittb "mov #{regsz}, #{itemstr}"
            self.emittb "mov #{out}, #{regsz}"
          end
        else
          self.emittb "mov #{szstr} #{out}, #{itemstr}"
        end
        self.ofree tgt, expr
        tgt
      end
    end
  end
end
