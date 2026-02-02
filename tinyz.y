/* tinyz.y */
/* bison --debug --token-table --verbose tinyz.y -o tinyz.tab.cpp && clang++ -g -std=c++17 tinyz.tab.cpp */

%expect 1
%{
	#define ENABLE_DEBUG 1
	#include "opcodes.h"
	#include "header.h"
	#include <set>
	#include <map>
	#include <cassert>

	int yylex();
	void yyerror(const char*,...);
	uint16_t encode_string(uint8_t *dest,size_t destSize,const char *src,size_t srcSize,bool forDict = false);
	int encode_string(const char*);
	const uint8_t* print_encoded_string(const uint8_t *src,void (*pr)(char ch));
	uint8_t next_global, next_local, story_shift = 1, dict_entry_size = 4;
	storyHeader the_header = { 3 };

	template <typename T> struct list_node {
		list_node<T>(T a,list_node<T> *b) : car(a), cdr(b) { }
		~list_node() {
			delete cdr;
		}
		T car;
		list_node<T> *cdr;
		size_t size() const {
			return cdr? 1 + cdr->size() : 1;
		}
	};

	struct operand { // 0=long, 1=small, variable=2, omitted=3
		int value:29;
		bool relocation:1;
		optype type:2;
	};
	static_assert(sizeof(operand)==4);

	const uint16_t UD_DYNAMIC = 1;
	const uint16_t UD_STATIC = 2;
	const uint16_t UD_HIGH = 3;

	// a relocatable blob can itself be relocated, and can contain
	// zero or more references to other relocatable blobs.
	// all recloations are 16 bits and can represent either a
	// direct address, or a packed story-shifted address.
	// there can be up to 32768 relocations.
	std::vector<struct relocatableBlob*> the_relocations;
	struct relocatableBlob {
		using relocation_t = list_node<std::pair<uint16_t,uint16_t>>;
		static uint16_t firstFree, firstPlaced, lastPlaced;
		static uint32_t nextAddress;
		static relocatableBlob* create(uint16_t totalSize,uint16_t ud = 0,const char *desc = nullptr) {
			relocatableBlob* result = (relocatableBlob*) new uint8_t[totalSize + sizeof(relocatableBlob)];
			result->size = totalSize;
			result->offset = 0;
			result->relocations = nullptr;
			result->userData = ud;
			result->address = ~0U;
			result->nextPlaced = 0xFFFF;
			result->desc = desc? desc : "";
			memset(result->contents,0,totalSize);
			if (firstFree != 0xFFFF) {
				result->index = firstFree;
				firstFree = (uint16_t)(size_t)the_relocations[firstFree];
				the_relocations[result->index] = result;
			}
			else {
				result->index = the_relocations.size();
				the_relocations.push_back(result);
			}
			return result;
		}
		static uint16_t createInt(int16_t t,uint8_t propertyIndex) {
			auto r = createProperty(2,propertyIndex);
			r->storeInt(t);
			return r->index;
		}
		static relocatableBlob* createProperty(uint16_t size,uint8_t propertyIndex) {
			if (!size)
				yyerror("cannot have zero-sized proeprty");
			if (the_header.version == 3) {
				if (size > 8)
					yyerror("property too large for v3");
				auto r = create(size+1);
				r->storeByte(((size-1)<<5) | propertyIndex);
				return r;
			}
			else {
				if (size > 64)
					yyerror("property too large for v4+");
				if (size <= 2) {
					auto r = create(size+1);
					r->storeByte(size==1? propertyIndex : 64 | propertyIndex);
					return r;
				}
				else {
					auto r = create(size+2);
					r->storeByte(0x80 | propertyIndex);
					r->storeByte(0x80 | (size & 63));
					return r;
				}
			}
		}
		void destroy() {
			uint16_t indexSave = index;
			delete the_relocations[index]->relocations;
			delete [] (uint8_t*) the_relocations[index];
			the_relocations[indexSave] = (relocatableBlob*)(size_t)firstFree;
			firstFree = indexSave;
		}
		void seal() {
			assert(offset <= size);
			size = offset;
			/* relocatableBlob *newResult = (relocatableBlob*) new uint8_t[offset + sizeof(relocatableBlob)];
			newResult->size = newResult->offset = offset;
			newResult->index = index;
			newResult->address = ~0U;
			newResult->nextPlaced = 0xFFFF;
			newResult->relocations = relocations;
			newResult->userData = userData;
			delete [] (uint8_t*) the_relocations[index];
			the_relocations[newResult->index] = newResult; */
		}
		void place(uint32_t alignMask = 0) {
			if (firstPlaced == 0xFFFF)
				firstPlaced = index;
			else
				the_relocations[lastPlaced]->nextPlaced = index;
			lastPlaced = index;
			nextPlaced = 0xFFFF;
			nextAddress = (nextAddress + alignMask) & ~alignMask;
			address = nextAddress;
			nextAddress += size;
		}
		static void placeAll(uint16_t type) {
			for (uint16_t i=0; i<the_relocations.size(); i++) {
				if ((size_t)the_relocations[i] > 0xFFFF && the_relocations[i]->address == ~0U &&
					the_relocations[i]->userData == type)
					the_relocations[i]->place(type==UD_HIGH?(1U << story_shift)-1:0U);
			}
		}
		static void writeAll(FILE *output) {
			uint16_t i = firstPlaced;
			while (i != 0xFFFF) {
				the_relocations[i]->applyRelocations();
				while (ftell(output) != the_relocations[i]->address)
					fputc(0,output);
				fwrite(the_relocations[i]->contents,the_relocations[i]->size,1,output);
				i = the_relocations[i]->nextPlaced;
			}
		}
		void storeByte(uint8_t b) {
			assert(offset < size);
			contents[offset++] = b;
		}
		void copy(const uint8_t *src,size_t srcLen) {
			while (srcLen--)
				storeByte(*src++);
		}
		void storeWord(uint16_t w) {
			storeByte(w >> 8);
			storeByte(w);
		}
		void storeInt(int16_t w) {
			storeByte(w >> 8);
			storeByte(w);
		}
		uint8_t readByte(uint16_t &o) {
			assert(o < offset);
			return contents[o++];
		}
		uint16_t readWord(uint16_t &o) {
			assert(o+1 < offset);
			o+=2;
			return (contents[o-2]<<8) | contents[o-1];
		}
		void addRelocation(uint16_t ri,int16_t bias = 0) {
			relocations = new relocation_t(std::pair<uint16_t,uint16_t>(ri,offset),relocations);
			storeWord(bias);
		}
		void applyRelocations() {
			int count = 0;
			for (auto i = relocations; i; i=i->cdr, count++) {
				auto &r = *the_relocations[i->car.first];
				uint16_t a = r.address >> (r.userData == UD_HIGH? story_shift : 0);
				a += contents[i->car.second + 1];	// add lower byte of offset;
				contents[i->car.second] = a >> 8;
				contents[i->car.second + 1] = a;
			}
			delete relocations;
			relocations = nullptr;
			/* if (desc.size())
				printf("blob %d applied %d relocations to %s (size %u), final address %x\n",index,count,desc,size,address); */
		}
		void append(relocatableBlob *other) {
			for (auto i=other->relocations; i; i=i->cdr)
				relocations = new relocation_t(std::pair<uint16_t,uint16_t>(i->car.first,i->car.second + offset),relocations);
			copy(other->contents,other->size);
			other->destroy();
		}
		uint16_t size, offset, index, userData, nextPlaced;
		uint32_t address;
		relocation_t *relocations;
		std::string desc;
		uint8_t contents[0];
	};
	uint16_t relocatableBlob::firstFree=0xFFFF, relocatableBlob::firstPlaced=0xFFFF, relocatableBlob::lastPlaced;
	uint32_t relocatableBlob::nextAddress;
	relocatableBlob *header_blob, *dictionary_blob, *object_blob, *properties_blob, *globals_blob, *actions_blob, *synonyms_blob, *current_global;
	int16_t entry_point_index = -1;
	uint8_t action_bit = 0;

	static const uint8_t opsizes[3] = { 2,1,1 };
	const uint8_t LONG_JUMP = 0x8C;			// +/-32767
	const uint8_t SHORT_JUMP = 0x9C;		// 0-255
	const uint8_t CALL_VS = 0xE0;

	relocatableBlob * currentRoutine;
	uint8_t currentProperty, currentBits;
	void emitByte(uint8_t b) {
		// printf("%04x: %02x\n",currentRoutine->offset,b);
		currentRoutine->storeByte(b);
	}
	void emitOperand(operand o) {
		if (o.relocation && o.type==optype::large_constant) {
			// printf("add relocatoin to blob %d\n",o.value);
			currentRoutine->addRelocation(o.value);
		}
		else {
			// static const char *types[] = {"large","small","variable","omitted"};
			// printf("operand type %s\n",types[(uint8_t)o.type]);
			if (o.type==optype::large_constant)
				emitByte(o.value >> 8);
			if (o.type!=optype::omitted)
				emitByte(o.value);
		}
	}
	// void emitBranch(uint16_t target);
	void emitvarop(operand l,_2op op,operand r1,operand r2);
	void emitvarop(operand l,_2op op,operand r1,operand r2,operand r3);
	void emitvarop(_var op,operand o0);
	void emitvarop(_var op,operand o0,operand o1);
	void emitvarop(_var op,operand o0,operand o1,operand o2);
	void emitvarop(_var op,operand o0,operand o1,operand o2,operand o3);
	void emit2op(operand l,_2op op,operand r);
	void emit1op(_1op op,operand un);
	void emit0op(_0op op) { emitByte(uint8_t(op) | 0xB0); }
	const uint8_t TOS = 0, SCRATCH = 3;

	typedef struct label_info {
		uint16_t offset;
		list_node<uint16_t> *references;
	} *label;
	label createLabel() {
		label result = new label_info;
		result->offset = 0xFFFF;
		result->references = nullptr;
		return result;
	}
	label rfalseLabel, rtrueLabel;
	label continue_label, break_label;
	std::vector<std::pair<label,label>> flow_stack;
	void fillBranch(uint16_t branchOffset,uint16_t targetOffset,bool negated,bool isLong,bool isJump) {
		assert(!isJump || !negated);
		uint8_t *dest = currentRoutine->contents + branchOffset;
		int delta = (targetOffset - (branchOffset + 1 + isLong)) + 2;
		assert(delta!=0 && delta!=1);
		if (isJump) {
			assert(targetOffset != 0xFFF0 && targetOffset != 0xFFF1);
			if (isLong)
				dest[0] = delta >> 8, dest[1] = delta;
			else {
				if (delta>0 && delta<=255)
					dest[0] = delta;
				else {
					printf("warning - jump delta %d out of range in %s\n",delta,currentRoutine->desc.c_str());
					dest[0] = 0;
				}
			}
		}
		else {
			if (isLong) {
				assert(targetOffset != 0xFFF0 && targetOffset != 0xFFF1);
				assert(delta>=-8192&&delta<=8191);
				dest[0] = (negated? 0x00 : 0x80) | ((delta >> 8) & 0x3F), dest[1] = delta;
			}
			else {
				if (targetOffset == 0xFFF0 || targetOffset == 0xFFF1)
					dest[0] = (negated? 0x40 : 0xC0) | (targetOffset & 1);
				else if (delta>0 && delta<64)
					dest[0] = (negated? 0x00 : 0x80) | 0x40 | delta;
				else {
					printf("branch delta %d out of range in %s, changing to rfalse\n",delta,currentRoutine->desc.c_str());
					dest[0] = negated? 0x40 : 0xC0;
				}
			}
		}
	}
	void placeLabel(label l) {
		l->offset = currentRoutine->offset;
		for (auto i=l->references; i; i=i->cdr) {
			int16_t delta = (currentRoutine->offset - i->car + 2);
			uint8_t *dest = currentRoutine->contents + i->car;
			if (dest[0]==0xFF)
				fillBranch(i->car,l->offset,false,dest[-1]==LONG_JUMP,true);
			else
				fillBranch(i->car,l->offset,(dest[0] & 0x80) == 0,!(dest[0] & 0x40),false);
		}
	}
	void emitJump(label l,bool isLong) {
		emitByte(isLong? LONG_JUMP : SHORT_JUMP);
		if (l->offset != 0xFFFF) {
			fillBranch(currentRoutine->offset,l->offset,false,isLong,true);
			currentRoutine->offset += 1 + isLong;
		}
		else {
			l->references = new list_node<uint16_t>(currentRoutine->offset,l->references);
			emitByte(0xFF); // signal jump instead of branch
			if (isLong)
				emitByte(0);
		}
	}
	label createLabelHere() {
		auto l = createLabel();
		placeLabel(l);
		return l;
	}

	struct symbol {
		int16_t token;	// if zero, it's a NEWSYM
		union {
			int16_t ival;
			uint16_t uval;
		};
	};
	std::map<std::string,symbol> the_globals;
	std::vector<std::map<std::string,symbol>*> the_locals;
	std::vector<relocatableBlob*> routine_stack;
	void open_scope() { 
		the_locals.push_back(new std::map<std::string,symbol>()); 
		routine_stack.push_back(currentRoutine);
		currentRoutine = nullptr;
	}
	void close_scope() { 
		currentRoutine = routine_stack.back();
		routine_stack.pop_back();
		delete the_locals.back(); 
		the_locals.pop_back();
	 }

	struct object {
		int16_t child, sibling, parent;
		uint8_t attributes[6];
		uint16_t descrLen, propertySize;
		uint8_t *descr;
		union {
			relocatableBlob **properties;
			relocatableBlob *finalProps;
		};
	} *cdef;
	uint16_t self_value;
	std::vector<object*> the_object_table;
	struct action {
	};
	std::vector<action*> the_action_table;

	struct dict_entry {
		uint8_t encoded[6];
		bool operator <(const dict_entry &rhs) const {
			return memcmp(encoded,rhs.encoded,sizeof(encoded)) < 0;
		}
	};
	std::map<dict_entry,uint16_t> the_dictionary; // maps a dictionary word to its index
	uint8_t& z_dict_payload(uint16_t i) { return dictionary_blob->contents[7 + i * (dict_entry_size+1) + dict_entry_size]; }

	typedef int16_t (*binary_eval)(int16_t,int16_t);
	typedef int16_t (*unary_eval)(int16_t);

	struct core {
		virtual ~core() { }
		virtual void dump() const = 0;
		void printNode(const char *s) const {
			spaces();
			printf("%s\n",s);
		}
		void printNode(const core *c) const {
			if (c) {
				indentLevel += 2;
				c->dump();
				indentLevel -= 2;
			}
		}
		void printNode(uint8_t dest) const {
			spaces();
			if (dest==0)
				printf("TOS\n");
			else if (dest < 16)
				printf("local%d\n",dest-1);
			else
				printf("global%d\n",dest-16);
		}
		void spaces() const {
			for (int i=0; i<indentLevel; i++)
				putchar(32);
		}
		static int indentLevel;
	};
	int core::indentLevel;
	struct expr: public core {
		virtual void emit(uint8_t dest) const { }
		virtual void eval(operand &o) const {
			o.value = TOS;
			o.type = optype::variable;
			o.relocation = false;
			emit(TOS);
		}
		virtual bool isLogical() const { return false; }
		virtual bool isLeaf() const { return false; }
		virtual bool isConstant(int &c) const { return false; }
		bool isZero() const {
			int c;
			return isConstant(c) && c==0;
		}
		virtual unsigned size() const = 0;
		unsigned opsize() const {
			return isLeaf()? size() : size() + 1;
		}
		static expr *fold_constant(expr* e);
		virtual void dump(uint32_t indent) { }
	};

	struct expr_binary: public expr {
		expr_binary(expr *l,_2op op,expr *r,binary_eval f = nullptr) : left(l), opcode(op), right(r), func(f) { }
		~expr_binary() { delete left; delete right; }
		expr *left, *right;
		binary_eval func;
		_2op opcode;
		void emit(uint8_t dest) const {
			// we defer eval call because there may be unsigned forward references
			operand lval, rval;
			right->eval(rval);
			left->eval(lval);
			emit2op(lval,opcode,rval);
			emitByte(dest);
		}
		void eval(operand &o) const {
			o.value = TOS;
			o.type = optype::variable;
			o.relocation = false;
			emit(TOS);
		}
		unsigned size() const {
			unsigned lSize = left->opsize();
			unsigned rSize = right->opsize();
			// if both operands are 1 byte, total size is 3 bytes. otherwise we need a var type encoding.
			// plus one for dest
			return lSize + rSize == 2? 4 : lSize + rSize + 3;
		}
		bool isConstant(int &v) const {
			int l, r;
			if (func && left->isConstant(l) && right->isConstant(r)) {
				v = func(l,r);
				return true;
			}
			else
				return false;
		}
		void dump() const {
			spaces(); printf("%s\n",opcode_names[(uint8_t)opcode]);
			printNode(left);
			printNode(right);
		}
	};
	struct expr_binary_log_shift: public expr {
		expr_binary_log_shift(expr *l,expr *r) : left(l), right(r) { }
		expr *left, *right;
		void emit(uint8_t dest) const {
			// we defer eval call because there may be unsigned forward references
			operand lval, rval;
			right->eval(rval);
			left->eval(lval);
			if (the_header.version < 5)
				yyerror("shift instructions not available in v3 or v4 stories");
			emitByte(0xBE);
			emitByte((uint8_t)_ext::log_shift);
			emitByte(((uint8_t)lval.type << 6) | ((uint8_t)rval.type << 4) | 0xF);
			emitByte(dest);
		}
		bool isConstant(int &v) const {
			int l, r;
			if (left->isConstant(l)&&right->isConstant(r)) { 
				v = r<0? l >> -r : l << r; 
				return true; 
			} 
			else 
				return false; 
		} 
		unsigned size() const {
			return left->opsize() + right->opsize() + 4;
		}
		void dump() const {
			printNode("SHIFT");
		}
	};
	struct expr_unary: public expr {
		expr_unary(_1op op,expr *e) : opcode(op), unary(e) { } 
		~expr_unary() { delete unary; }
		expr *unary;
		_1op opcode;
		void emit(uint8_t dest) const {
			operand uval;
			unary->eval(uval);
			emit1op(opcode,uval);
			emitByte(dest);
			// emit a dummy branch to next instruction.
			if (opcode == _1op::get_sibling || opcode == _1op::get_child)
				emitByte(0x42);
		}
		unsigned size() const {
			return 1 + unary->opsize() + 1 + (opcode == _1op::get_sibling || opcode == _1op::get_child);
		}
		void dump() const {
			spaces(); printf("%s\n",opcode_names[(uint8_t)opcode | 0x80]);
			printNode(unary);
		}
	};
	struct expr_branch: public expr {
		expr_branch(bool n) : negated(n) { }
		void emit() const {
			assert(false); // shouldn't be called.
		}
		virtual void emitBranch(label target,bool n,bool isLong) {
			// printf("emitBranch negated %d, n %d\n",negated,n);
			if (negated)
				n = !n;
			if (target->offset != 0xFFFF) {
				fillBranch(currentRoutine->offset,target->offset,n,isLong,false);
				currentRoutine->offset += 1 + isLong;
			}
			else {
				target->references = new list_node<uint16_t>(currentRoutine->offset,target->references);
				if (isLong) {
					emitByte(n? 0x00 : 0x80);
					emitByte(0);
				}
				else
					emitByte(n? 0x40 : 0xC0);
			}
		}
		bool negated;
		bool isLogical() const { return true; }
	};

	struct expr_binary_branch: public expr_branch {
		expr_binary_branch(expr *l,_2op op,bool negated,expr *r,binary_eval f = nullptr) : left(l), opcode(op), right(r), func(f), expr_branch(negated) { }
		~expr_binary_branch() { delete left; delete right; }
		_2op opcode;
		expr *left, *right;
		binary_eval func;
		void emitBranch(label target,bool negated,bool isLong) {
			operand lval, rval;
			right->eval(rval);
			left->eval(lval);
			emit2op(lval,opcode,rval);
			expr_branch::emitBranch(target,negated,isLong);
		}
		bool isConstant(int &v) const {
			int l, r;
			if (func && left->isConstant(l) && right->isConstant(r)) {
				v = func(l,r);
				return true;
			}
			else
				return false;
		}
		unsigned size() const {
			return left->opsize() + right->opsize() + 3; // assume long branch
		}
		void dump() const {
			spaces(); printf("%s\n",opcode_names[(uint8_t)opcode]);
			printNode(left);
			printNode(right);
		}
	};
	struct expr_binary_branch_store: public expr_binary_branch {
		expr_binary_branch_store(expr *l,_2op op,bool negated,expr *r,uint8_t d) : expr_binary_branch(l,op,negated,r), dest(d) { }
		uint8_t dest;
		void emitBranch(label target,bool negated,bool isLong) {
			operand lval, rval;
			right->eval(rval);
			left->eval(lval);
			emit2op(lval,opcode,rval);
			emitByte(dest);
			expr_branch::emitBranch(target,negated,isLong);
		}
		unsigned size() const {
			return left->opsize() + right->opsize() + 2 /* 2op var */ + 2 /* branch */;
		}
		void dump() const {
			expr_binary_branch::dump();
			printNode(dest);
		}
	};	
	struct expr_in: public expr_branch {
		expr_in(expr *l,expr *r1,expr *r2=nullptr,expr *r3=nullptr) : left(l), right1(r1), right2(r2), right3(r3), expr_branch(false) { }
		~expr_in() { delete left; delete right1; delete right2; delete right3; }
		expr *left,*right1,*right2,*right3;
		void emitBranch(label target,bool negated,bool isLong) {
			operand lval, rval1, rval2, rval3;
			if (right3)
				right3->eval(rval3);
			if (right2)
				right2->eval(rval2);
			right1->eval(rval1);
			left->eval(lval);
			if (right3)
				emitvarop(lval,_2op::je,rval1,rval2,rval3);
			else if (right2)
				emitvarop(lval,_2op::je,rval1,rval2);
			else
				emit2op(lval,_2op::je,rval1);
			expr_branch::emitBranch(target,negated,isLong);
		}
		unsigned size() const {
			return right2? 
				(right3? right3->opsize() + right2->opsize() + right1->opsize() + left->opsize() + 2 : 
					right2->opsize() + right1->opsize() + left->opsize() + 2) : right1->opsize() + left->opsize() + 2;
		}
		void dump() const {
			printNode("in:");
			printNode(left);
			printNode(right1);
			printNode(right2);
			printNode(right3);
		}
	};
	struct expr_call: public expr { // first arg is func address
		expr_call(list_node<expr*> *a) : args(a) { }
		~expr_call() { delete args; }
		list_node<expr*> *args;
		// TODO: v3 only supports VAR call (3 params). v4 supports 1/2 operand with result and 7 params.
		// v5 supports implicit pop versions of all calls
		virtual void emit(uint8_t dest) const {
			operand o1, o2, o3, o4;
			if (args->size()>=4)
				args->cdr->cdr->cdr->car->eval(o4);
			else
				o4.type = optype::omitted;
			if (args->size()>=3)
				args->cdr->cdr->car->eval(o3);
			else
				o3.type = optype::omitted;
			if (args->size()>=2)
				args->cdr->car->eval(o2);
			else
				o2.type = optype::omitted;
			if (args->size()>=1)
				args->car->eval(o1);
			else
				o1.type = optype::omitted;
			emitvarop(_var::call_vs,o1,o2,o3,o4);
			emitByte(dest);
		}
		unsigned size() const {
			// size %zd\n",args->size(),3 + args->size()*2);
			return 2 + args->size() * 2 + 1 /* dest */;
		}
		void dump() const {
			printNode("call:");
			for (auto i=args; i; i=i->cdr)
				printNode(i->car);
		}
	};
	struct expr_unary_branch: public expr_branch {
		expr_unary_branch(_1op op,bool negated,expr *e) : opcode(op), unary(e), expr_branch(negated) { }
		~expr_unary_branch() { delete unary; }
		_1op opcode;
		expr *unary;
		void emitBranch(label target,bool negated,bool isLong) {
			operand un;
			unary->eval(un);
			emit1op(opcode,un);
			expr_branch::emitBranch(target,negated,isLong);
		}
		unsigned size() const {
			return 1 + unary->opsize() + 2;
		}
		void dump() const {
			printNode(opcode_names[(uint8_t)opcode | 0x80]);
			printNode(unary);
		}
	};
	struct expr_unary_branch_store: public expr_unary_branch {
		expr_unary_branch_store(_1op op,bool negated,expr *e,uint8_t d) : expr_unary_branch(op,negated,e), dest(d) { }
		uint8_t dest;
		void emitBranch(label target,bool negated,bool isLong) {
			operand un;
			unary->eval(un);
			emit1op(opcode,un);
			emitByte(dest);
			expr_branch::emitBranch(target,negated,isLong);
		}
		unsigned size() const {
			return 1 + unary->size() + 1 + 3;
		}
		void dump() const {
			expr_unary_branch::dump();
			printNode(dest);
		}
	};
	struct expr_operand: public expr {
		operand op;
		void eval(operand &o) const {
			o = op;
		}
		bool isLeaf() const { return true; }
		unsigned size() const { return op.type == optype::large_constant? 2 : 1; }
	};
	struct expr_literal: public expr_operand {
		expr_literal(int value) {
			op.type =  value >= 0 && value <= 255? optype::small_constant : optype::large_constant;
			op.value = value;
			op.relocation = false;
		}
		bool isConstant(int &v) const { v = op.value; return true; }
		void dump() const {
			spaces(); printf("%d\n",op.value);
		}
	};
	struct expr_reloc: public expr_operand {
		expr_reloc(uint16_t r) {
			op.type = optype::large_constant;
			op.value = r;
			op.relocation = true;
		}
		void dump() const {
			spaces(); printf("reloc %u (%s)\n",op.value,the_relocations[op.value]->desc.c_str());
		}
	};
	expr* expr::fold_constant(expr *e) {
			int c;
			if (e->isConstant(c)) {
				delete e;
				// printf("constant folded to %d\n",c);
				return new expr_literal(c);
			}
			else
				return e;
	}
	struct expr_variable: public expr_operand {
		expr_variable(uint8_t v) {
			op.type = optype::variable;
			op.value = v;
			op.relocation = false;
		}
		void dump() const {
			printNode((uint8_t)op.value);
		}
	};
	struct expr_logical_not: public expr_branch {
		expr_logical_not(expr_branch *e) : unary(), expr_branch(!e->negated) { }
		~expr_logical_not() { delete unary; }
		expr_branch *unary;
		void emitBranch(label target,bool negated,bool isLong) {
			unary->emitBranch(target,negated,isLong);
		}
		unsigned size() const {
			return unary->size();
		}
		void dump() const {
			printNode("not:");
			printNode(unary);
		}
	};
	// (a and b) or (c and d) { trueStuff; } else { falseStuff; }
	// jz a,label1
	// jnz b,ifTrue
	// label1: jz c,ifFalse
	// jz d,ifFalse
	// ifTrue: trueStuff
	// jump after
	// ifFalse: falseStuff
	// after:
	// not (a and b) -> (not a) OR (not b)
	struct expr_logical_and: public expr_branch {
		expr_logical_and(expr_branch *l,expr_branch *r) : left(l), right(r), expr_branch(false) { }
		~expr_logical_and() { delete left; delete right; }
		expr_branch *left, *right;
		void emitBranch(label target,bool negated,bool isLong) {
			// printf("emitBranch logical and, negated %d\n",negated);
			// (negated=true) if (a and b) means jz a,target; jz b,target
			// (negated=true) while (a and b) means jz a,target; jz b,target
			// (negated=false) repeat ... while (a and b) means jz skip; jnz b,target; skip:
			if (negated) {
				left->emitBranch(target,true,isLong);
				right->emitBranch(target,true,isLong);
			}
			else {
				label failed = createLabel();
				left->emitBranch(failed,true,isLong);
				right->emitBranch(target,false,isLong);
				placeLabel(failed);
			}
		}
		unsigned size() const {
			return left->size() + right->size();
		}
		void dump() const {
			printNode("and:");
			printNode(left);
			printNode(right);
		}
	};
	struct expr_logical_or: public expr_branch {
		expr_logical_or(expr_branch*l,expr_branch *r) : left(l), right(r), expr_branch(false) { }
		~expr_logical_or() { delete left; delete right; }
		expr_branch *left, *right;
		void emitBranch(label target,bool negated,bool isLong) {
			//printf("emitBranch logical or, negated %d\n",negated);
			// if (a or b) means jnz a,skip; jz b,target; skip:
			if (negated) { // not (a or b) -> (not a) and (not b)
				label success = createLabel();
				left->emitBranch(success,false,isLong);
				right->emitBranch(target,true,isLong);
				placeLabel(success);
			}
			else {
				left->emitBranch(target,false,isLong);
				right->emitBranch(target,false,isLong);
			}
		}
		unsigned size() const {
			return left->size() + right->size();
		}
		void dump() const {
			printNode("or:");
			printNode(left);
			printNode(right);
		}
	};
	struct expr_saveRestore: public expr_branch {
		expr_saveRestore(_0op o) : opcode(o), expr_branch(false) { }
		_0op opcode;
		void emitBranch(label target,bool negated,bool isLong) {
			emit0op(opcode);
			expr_branch::emitBranch(target,negated,isLong);
		}
		unsigned size() const {
			return 3;
		}
		void dump() const {
			printNode("saveRestore");
		}
	};
	enum scope_enum: uint8_t { SCOPE_GLOBAL, SCOPE_OBJECT, SCOPE_LOCATION };
	uint8_t expected_scope;
	const uint8_t SCOPE_OBJECT_MASK = 0x40;
	const uint8_t SCOPE_LOCATION_MASK = 0x80;
	const uint8_t scope_masks[3] = { SCOPE_OBJECT_MASK | SCOPE_LOCATION_MASK, SCOPE_OBJECT_MASK, SCOPE_LOCATION_MASK };
	uint8_t attribute_next[3] = {31,1,1}; // 31 should be 47 for v4+
	uint8_t property_next[3] = {31,1,1}; // 31 should be 63 for v4+
	uint8_t next_value_in_scope(scope_enum sc,uint8_t *state) {
		uint8_t result = state[sc] | scope_masks[sc];
		if (sc==SCOPE_GLOBAL) state[sc]--; else state[sc]++;
		return result;
	}
	struct stmt: public core {
		virtual void emit() const = 0;
		virtual unsigned size() const = 0;
		virtual bool isReturn() const { return false; }
		virtual bool isJustReturnBool(int &) const { return false; }
	};
	struct stmts: public stmt {
		stmts(list_node<stmt*> *s): slist(s) { 
			tsize = 0;
			for (auto i=slist; i; i=i->cdr)
				tsize += i->car->size();
		}
		~stmts() { delete slist; }
		list_node<stmt*> *slist;
		unsigned tsize;
		void emit() const {
			//unsigned actualSize = currentRoutine->offset;
			for (auto i=slist; i; i=i->cdr) {
				i->car->emit();
				// printf("accum %u\n",currentRoutine->offset - actualSize);
			}
			//actualSize = currentRoutine->offset - actualSize;
			// assert(computedSize <= tsize);
			/*if (actualSize > tsize) {
				for (auto i=slist; i; i=i->cdr)
					printf("element size %u\n",i->car->size());
				yyerror("error in size math, actual %d computed %d",actualSize,tsize);
			}*/
		}
		unsigned size() const { return tsize; }
		bool isReturn() const {
			for (auto i=slist; i; i=i->cdr)
				if (i->car->isReturn())
					return true;
			return false;
		}
		void dump() const {
			for (auto i=slist; i; i=i->cdr)
				i->car->dump();
		}
	};
	struct stmt_flow: public stmt {
	};
	size_t jumpPastSize(stmt*s) {
		return s? (s->size() > 61? 3 : 2) : 0;
	}
	size_t includingBranchPast(size_t s) {
		return s + (s > 61? 2 : 1);
	}
	size_t includingJumpPast(size_t s) {
		return s > 61? 3 : 2;
	}
	struct stmt_if: public stmt_flow {
		stmt_if(expr_branch *e,stmt *t,stmt *f): cond(e), ifTrue(t), ifFalse(f) { }
		~stmt_if() { delete cond; delete ifTrue; delete ifFalse; }
		expr_branch *cond;
		stmt *ifTrue, *ifFalse;
		// TODO: if ifTrue is rfalse/rtrue, we just need the non-negated branch to 0/1
		// TODO: else if ifFalse is rfalse/rtrue, we just need the negated branch to 0/1
		// TODO: If ifTrue ends in a return, we don't need the jump past false block
		void emit() const {
			int value;

			// dead code elimination
			if (cond->isConstant(value)) {
				if (value)
					ifTrue->emit();
				else if (ifFalse)
					ifFalse->emit();
				return;
			}

			if (ifTrue->isJustReturnBool(value)) {
				cond->emitBranch(value? rtrueLabel : rfalseLabel,false,false);
				if (ifFalse)
					ifFalse->emit();
				return;
			}

			label falseBranch = createLabel();
			cond->emitBranch(falseBranch,true,ifTrue->size() > (ifFalse? 57 : 59));
			ifTrue->emit();
			if (ifFalse) {
				if (ifTrue->isReturn()) {
					placeLabel(falseBranch);
					ifFalse->emit();
				}
				else {
					label skipFalse = createLabel();
					emitJump(skipFalse,ifFalse->size() > 59);
					placeLabel(falseBranch);
					ifFalse->emit();
					placeLabel(skipFalse);
				}
			}
			else
				placeLabel(falseBranch);
		}
		unsigned size() const {
			return cond->size() + includingBranchPast(ifTrue->size() + jumpPastSize(ifFalse)) +
				(ifFalse? ifFalse->size() : 0);
		}
		void dump() const {
			printNode("if:");
			printNode(cond);
			printNode("then:");
			printNode(ifTrue);
			if (ifFalse) {
				printNode("else:");
				printNode(ifFalse);
			}
		}
		bool isReturn() const {
			return ifFalse && ifFalse->isReturn() && ifTrue->isReturn();
		}
	};
	struct stmt_while: public stmt_flow {
		stmt_while(expr_branch *e,stmt *b): cond(e), body(b) { }
		~stmt_while() { delete cond; delete body; }
		expr_branch *cond;
		stmt *body;
		void emit() const {
			flow_stack.push_back(std::pair<label,label>(continue_label,break_label));
			label falseBranch = createLabel(), top = createLabelHere();
			continue_label = top;
			break_label = falseBranch;
			cond->emitBranch(falseBranch,true,body->size() > 58);
			// TODO: continue and break via a stack
			body->emit();
			emitJump(top,true);
			placeLabel(falseBranch);
			continue_label = flow_stack.back().first;
			break_label = flow_stack.back().second;
			flow_stack.pop_back();
		}
		unsigned size() const { 
			return cond->size() + includingJumpPast(body->size()) + 3; 
		}
		void dump() const {
			printNode("while:");
			printNode(cond);
			printNode("do:");
			printNode(body);
		}
	};
	struct stmt_repeat: public stmt_flow {
		stmt_repeat(stmt *b,expr_branch *e): body(b), cond(e) { }
		~stmt_repeat() { delete cond; delete body; }
		stmt *body;
		expr_branch *cond;
		void emit() const {
			auto trueBranch = createLabelHere();
			body->emit();
			cond->emitBranch(trueBranch,false,true);
		}
		unsigned size() const { 
			return cond->size() + body->size(); 
		}
		void dump() const {
			printNode("repeat:");
			printNode(body);
			printNode("while:");
			printNode(cond);
		}
	};
	// TODO: an if whose body is continue/break should just be a direct branch like rtrue/rfalse
	struct stmt_continue: public stmt {
		void emit() const {
			if (continue_label == nullptr)
				yyerror("continue found outside of any loop");
			emitJump(continue_label,true);
		}
		unsigned size() const { return 3; }
		void dump() const { printNode("continue;"); }
	};
	struct stmt_break: public stmt {
		void emit() const {
			if (break_label == nullptr)
				yyerror("break found outside of any loop");
			emitJump(break_label,true);
		}
		unsigned size() const { return 3; }
		void dump() const { printNode("break;"); }
	};
	struct stmt_return: public stmt {
		stmt_return(expr *e) : value(e) { }
		~stmt_return() { delete value; }
		expr *value;
		bool isReturn() const { return true; }
		bool isJustReturnBool(int &c) const {
			return (value->isConstant(c) && (c==0||c==1));
		}
		void emit() const {
			int c;
			if (value->isConstant(c) && (c==0||c==1))
				emit0op(c==0? _0op::rfalse : _0op::rtrue);
			else {
				operand o;
				value->eval(o);
				// printf("stmt_return o.type %d o.value %d\n",(uint8_t)o.type,o.value);
				if (o.type == optype::variable && o.value == TOS)
					emit0op(_0op::ret_popped);
				else
					emit1op(_1op::ret,o);
			}
		}
		unsigned size() const { 
			int c;
			if (value->isConstant(c)) {
				if (c==0||c==1)
					return 1;
				else if (c > 1 && c <= 255)
					return 2;
			}
			return 3;
		}
		void dump() const {
			printNode("return:");
			printNode(value);
		}
	};
	struct stmt_2op: public stmt {
		stmt_2op(_2op op,expr *l,expr *r) : opcode(op), left(l), right(r) { }
		~stmt_2op() { delete left; delete right; }
		_2op opcode;
		expr *left, *right;
		void emit() const {
			operand lop, rop;
			right->eval(rop);
			left->eval(lop);
			emit2op(lop,opcode,rop);
		}
		unsigned size() const {
			return left->size() + right->size() + 1;
		}
		void dump() const {
			printNode(opcode_names[(uint8_t)opcode]);
			printNode(left);
			printNode(right);
		}
	};		
	struct stmt_1op: public stmt {
		stmt_1op(_1op op,expr *e) : opcode(op), value(e) { }
		~stmt_1op() { delete value; }
		_1op opcode;
		expr *value;
		void emit() const {
			operand o;
			value->eval(o);
			emit1op(opcode,o);
		}
		unsigned size() const {
			return value->size() + 1;
		}
		void dump() const {
			printNode(opcode_names[(uint8_t)opcode | 0x80]);
			printNode(value);
		}
	};	
	struct stmt_0op: public stmt {
		stmt_0op(_0op op) : opcode(op) { }
		_0op opcode;
		void emit() const {
			emit0op(opcode);
		}
		unsigned size() const {
			return 1;
		}
		void dump() const {
			printNode(opcode_names[(uint8_t)opcode | 0xB0]);
		}
		bool isReturn() const {
			return opcode==_0op::quit || opcode==_0op::restart;
		}
	};
	struct stmt_assign: public stmt {
		stmt_assign(uint8_t d,expr *e) : dest(d), value(e) {  }
		~stmt_assign() { delete value; }
		uint8_t dest;
		expr* value;
		void emit() const {
				if (value->isLeaf()) {
					operand d, o;
					value->eval(o);
					d.type = optype::small_constant;
					d.relocation = false;
					d.value = dest;
					emit2op(d,_2op::store,o);
				}
				else
					value->emit(dest);
		}
		unsigned size() const {
			return value->size() + 1 + value->isLeaf();
		}
		void dump() const {
			printNode("assign:");
			printNode(value);
			printNode(dest);
		}
	};
	struct stmt_store: public stmt {
		stmt_store(_var o,expr *a,expr *i,expr *v) : opcode(o), array(a), index(i), value(v) { }
		~stmt_store() { delete array; delete index; delete value; }
		_var opcode;
		expr *array, *index, *value;
		void emit() const {
			operand a, i, v;
			value->eval(v);
			index->eval(i);
			array->eval(a);
			emitvarop(opcode,a,i,v);
		}
		unsigned size() const {
			return array->size() + value->size() + index->size() + 2;
		}
		void dump() const {
			printNode("store:");
			printNode(array);
			printNode(value);
			printNode(index);
		}
	};
	struct stmt_varop1: public stmt {
		stmt_varop1(_var op,expr *a) : opcode(op), expr0(a) { }
		~stmt_varop1() { delete expr0; }
		_var opcode;
		expr *expr0;
		void emit() const {
			operand op0;
			expr0->eval(op0);
			emitvarop(opcode,op0);
		}
		unsigned size() const {
			return expr0->opsize() + 2;
		}
		void dump() const {
			printNode(opcode_names[(uint8_t)opcode + 0xE0]);
			printNode(expr0);
		}
	};
	struct stmt_varop2: public stmt {
		stmt_varop2(_var op,expr *a,expr *b) : opcode(op), expr0(a), expr1(b) { }
		~stmt_varop2() { delete expr0; delete expr1; }
		_var opcode;
		expr *expr0, *expr1;
		void emit() const {
			operand op0, op1;
			expr1->eval(op1);
			expr0->eval(op0);
			emitvarop(opcode,op0,op1);
			// on v5+, it's a store, but let's just hide that for now.
			// if you really need the result you can check scratch.
			if (opcode == _var::sread && the_header.version >= 5)
				emitByte(16 + SCRATCH);
		}
		unsigned size() const {
			return expr0->size() + expr1->size() + 2;
		}
		void dump() const {
			printNode(opcode_names[(uint8_t)opcode + 0xE0]);
			printNode(expr0);
			printNode(expr1);
		}
	};
	struct stmt_call: public stmt {
		stmt_call(list_node<expr*> *a) : call(a) { }
		void emit() const {
			// Call as a statement dumps result to a global
			// (alternative is dump to TOS and emit a pop, but this is shorter)
			call.emit(16 + SCRATCH);
		}
		unsigned size() const {
			return call.size();
		}
		expr_call call;
		void dump() const {
			call.dump();
		}
	};
	struct stmt_print: public stmt {
		stmt_print(_0op o,const char *s) : opcode(o), string(s) { }
		~stmt_print() { delete [] string; }
		const char *string;
		_0op opcode;
		void emit() const {
			emit0op(opcode);
			currentRoutine->offset += encode_string(currentRoutine->contents + currentRoutine->offset,
				(currentRoutine->size - currentRoutine->offset) & ~1,string,strlen(string));
		}
		unsigned size() const {
			return 1 + encode_string(nullptr,0,string,strlen(string));
		}
		void dump() const {
			spaces();
			printf("%s \"%s\"\n",opcode_names[(uint8_t)opcode | 0xB0],string);
		}
		bool isReturn() const {
			return opcode == _0op::print_ret;
		}
	};
	uint16_t emit_routine(int numLocals,stmt *body) {
		currentRoutine = relocatableBlob::create(1024,UD_HIGH);
		// printf("%d locals\n",numLocals);
		emitByte(numLocals);
		if (the_header.version < 5) {
			while (numLocals--) { 
				emitByte(0); 
				emitByte(0); 
			}
		}
		// body->dump();
		if (!body->isReturn())
			yyerror("missing return at end of routine (or not all if paths return)");
		body->emit();
		while (currentRoutine->offset & ((1 << story_shift)-1))
			emitByte(0);
		currentRoutine->seal(); // arp arp
		delete body;
		return currentRoutine->index;
	}

	uint16_t property_defaults[63];
	uint8_t property_bits[256];
%}

%union {
	int ival;
	uint16_t rval;
	const char *sval;
	expr *eval;
	expr_branch *brval;
	std::pair<const std::string,symbol> *sym;
	scope_enum scopeval;
	list_node<uint16_t> *dlist;
	list_node<expr*> *elist;
	list_node<stmt*> *stlist;
	stmt *stval;
	_0op zeroOp;
	_1op oneOp;
	_2op twoOp;
	_var varOp;
}

%token ATTRIBUTE PROPERTY GLOBAL OBJECT LOCATION ROUTINE WORDBIT ACTION HAS HASNT IN HOLDS SYNONYM CONTINUE BREAK
%token BYTE_ARRAY WORD_ARRAY CALL PRINT PRINT_RET SELF SIBLING CHILD PARENT MOVE INTO CONSTANT SIZEOF ADDROF
%token <ival> DICT ANAME PNAME LNAME GNAME INTLIT ONAME
%token <sval> STRLIT
%token <rval> RNAME
%token <sym> NEWSYM
%token WHILE REPEAT IF ELSE
%token LE "<=" GE ">=" EQ "==" NE "!="
// %token DEC_CHK "--<" INC_CHK "++>"
%token SAVE RESTORE
%token LSH "<<" RSH ">>"
%token ARROW "->" INCR "++" DECR "--"
%token RFALSE RTRUE RETURN
%token OR AND NOT
%token <zeroOp> STMT_0OP
%token <oneOp> STMT_1OP
%token <twoOp> STMT_2OP
%token <varOp> STMT_VAROP1 STMT_VAROP2
%token GAINS LOSES

%left OR
%left AND
%left '|'
%left '&'
%left LSH RSH
%left EQ NE
%left '<' LE '>' GE
%nonassoc HAS HASNT
%left '+' '-'
%left '*' '/' '%'
%left PARENT
%right '~' NOT

%type <eval> expr pname objref primary aname arg
%type <brval> bool_expr cond_expr
%type <ival> vname opt_parent opt_default opt_wordbit opt_arrow has_or_hasnt phrase dict
%type <rval> routine_body pvalue
%type <scopeval> scope
%type <dlist> dict_list;
%type <elist> opt_call_args arg_list
%type <stval> stmt
%type <stlist> stmts

%%

prog
	: decl_list;

decl_list
	: decl_list decl
	| decl;

decl
	: attribute_def
	| property_def
	| global_def
	| object_def
	| location_def
	| routine_def
	| wordbit_def
	| action_def
	| synonym_def;
	| constant_def
	;

constant_def
	: CONSTANT NEWSYM '=' expr ';'
		{
			int v;
			if (!$4->isConstant(v))
				yyerror("constant directive must evaluate to compile-time constant value");
			 $2->second.token = INTLIT; 
			 $2->second.ival = v;
			 // printf("constant = %d\n",v);
		}
	;

attribute_def
	: ATTRIBUTE scope NEWSYM ';' 
		{ 
			$3->second.token = ANAME; 
			$3->second.ival = next_value_in_scope($2,attribute_next); 
		}
	;

scope
	: GLOBAL		{ $$ = SCOPE_GLOBAL; }
	| LOCATION		{ $$ = SCOPE_LOCATION; }
	| OBJECT		{ $$ = SCOPE_OBJECT; }
	;

property_def
	: PROPERTY scope NEWSYM opt_default opt_wordbit ';' 
		{ 
			$3->second.token = PNAME; 
			$3->second.ival = next_value_in_scope($2,property_next); 
			auto i = $3->second.ival & 63;
			if (property_defaults[i] && property_defaults[i] != $4)
				yyerror("inconsistent value for default property (index %d) %d <> %d",
					i,property_defaults[i],$4);
			property_defaults[i] = $4;
			property_bits[$3->second.ival] = $5;
		}
	;

opt_default
	: 				{ $$ = 0; }
	| '=' INTLIT	{ $$ = $2; }
	;

opt_wordbit
	:					{ $$ = 0; }
	| WORDBIT INTLIT	{ $$ = $2; }
	;

dict_list
	: dict dict_list	{ $$ = new list_node<uint16_t>($1,$2); }
	| dict				{ $$ = new list_node<uint16_t>($1,nullptr); }
	;

synonym_def
	: SYNONYM dict { synonyms_blob->storeWord($2 | 32768); } syn_list ';'
	;

syn_list
	: syn_list syn
	| syn
	;

syn
	: dict		{ synonyms_blob->storeWord($1); z_dict_payload($1) = 255; }
	;

global_def
	: GLOBAL GNAME opt_global_init ';'
	;

opt_global_init
	:					{ globals_blob->storeWord(0); }
	| '=' INTLIT		{ globals_blob->storeWord($2); }
	| '=' BYTE_ARRAY '(' INTLIT ')'	{ globals_blob->addRelocation((current_global = relocatableBlob::create($4,UD_DYNAMIC,"byte array"))->index); } opt_byte_list { current_global = nullptr; }
	| '=' WORD_ARRAY '(' INTLIT ')' { globals_blob->addRelocation((current_global = relocatableBlob::create($4,UD_DYNAMIC,"word array"))->index); } opt_word_list { current_global = nullptr; }
	;

opt_byte_list
	:
	| '{' byte_list '}'
	;

byte_list
	: byte
	| byte_list ',' byte
	;

byte
	: INTLIT	
	{ 
		if ($1 < 0 || $1 > 255) 
			yyerror("value of out range for BYTE_ARRAY"); 
		if (current_global->offset == current_global->size) 
			yyerror("too many byte initializers");
		current_global->storeByte($1); 
	}
	;

opt_word_list
	:
	| '{' word_list '}'
	;

word_list
	: word
	| word_list ',' word
	;

word
	: INTLIT 
	{ 
		if (current_global->offset == current_global->size) 
			yyerror("too many word initializers"); 
		current_global->storeWord($1); 
	}
	;

object_def
	: OBJECT { expected_scope = SCOPE_OBJECT_MASK; } object_or_location_def
	;

location_def
	: LOCATION { expected_scope = SCOPE_LOCATION_MASK; } object_or_location_def
	;

object_or_location_def
	: ONAME STRLIT opt_parent '{' {
		self_value = $1;
		cdef = the_object_table[$1];
		cdef->child = 0;
		cdef->parent = $3;

		if ($3) {
			cdef->sibling = the_object_table[$3]->child;
			the_object_table[$3]->child = $1;
		}
		else
			cdef->sibling = 0;
		cdef->descrLen = encode_string(nullptr,0,$2,strlen($2));
		cdef->descr = new uint8_t[cdef->descrLen];
		encode_string(cdef->descr,cdef->descrLen,$2,strlen($2));
		delete[] $2;
		memset(cdef->attributes,0,sizeof(cdef->attributes));
		if (expected_scope == SCOPE_OBJECT_MASK)
			cdef->attributes[0] = 0x80;
		unsigned propCount = the_header.version==3? 32 : 64;
		cdef->properties = new relocatableBlob*[propCount];
		cdef->propertySize = 0;
		memset(cdef->properties,0,propCount * sizeof(relocatableBlob*));
	} opt_property_or_attribute_list '}' {
		unsigned finalSize = 1 + cdef->descrLen + cdef->propertySize + 1;
		// this could potentially be placed in static memory but that might break some interpreters.
		auto finalProps = relocatableBlob::create(finalSize,UD_DYNAMIC,"property table");
		finalProps->storeByte(cdef->descrLen>>1);
		finalProps->copy(cdef->descr,cdef->descrLen);
		unsigned propCount = the_header.version==3? 32 : 64;
		while (--propCount) {
			auto p = cdef->properties[propCount];
			if (p)
				finalProps->append(p);
		}
		finalProps->storeByte(0);
		delete [] cdef->properties;
		cdef->finalProps = finalProps;
		cdef->propertySize = finalSize;
		self_value = 0;
	}
	;

opt_parent
	: 						{ $$ = 0; }
	| '(' ONAME ')'			{ $$ = $2; }
	;

opt_property_or_attribute_list
	:
	| property_or_attribute_list
	;

property_or_attribute_list
	: property_or_attribute_list property_or_attribute
	| property_or_attribute
	;

property_or_attribute
	: PNAME ':' { currentProperty = $1 & 63; currentBits = $1; } pvalue		
			{ 
				if (!($1 & expected_scope))
					yyerror("wrong type of property"); 
				if (cdef->properties[currentProperty])
					yyerror("already have property %d set",currentProperty);
				cdef->properties[currentProperty] = the_relocations[$4];
				cdef->propertySize += the_relocations[$4]->size;
			}
	| ANAME ';'
			{ 
				if (!($1 & expected_scope)) 
					yyerror("wrong type of attribute"); 
				uint8_t thisIndex = $1 & 63;
				if (cdef->attributes[thisIndex>>3] & (0x80 >> (thisIndex & 7)))
					yyerror("already have attribute %d set",thisIndex);
				cdef->attributes[thisIndex>>3] |= (0x80 >> (thisIndex & 7));
			}
	;

pvalue
	: ONAME ';' { $$ = relocatableBlob::createInt($1,currentProperty); }
	| STRLIT ';'
		{
			// string literal is just a shorthand for the address of a routine that calls print_ret with that string
			open_scope();
			auto p = relocatableBlob::createProperty(2,currentProperty);
			p->addRelocation(emit_routine(0,new stmt_print(_0op::print_ret,$1)));
			close_scope();
			$$ = p->index;
		}
	| INTLIT ';' { $$ = relocatableBlob::createInt($1,currentProperty); }
	| routine_body { 
			auto p = relocatableBlob::createProperty(2,currentProperty); 
			p->addRelocation($1);
			$$ = p->index;
		}
	| dict_list ';' { 
		auto p = relocatableBlob::createProperty($1->size() * 2,currentProperty);
		$$ = p->index;
		auto s = $1;
		while (s) { 
			z_dict_payload(s->car) |= property_bits[currentBits];
			p->storeWord(s->car);
			s = s->cdr;
		}
		delete $1;
	}
	;

routine_def
	: ROUTINE NEWSYM routine_body 
		{
			the_relocations[$3]->desc = $2->first;
			if ($2->first == "main") {
				if (entry_point_index == -1) {
					if (the_relocations[$3]->contents[0])
						yyerror("main cannot declare any parameters or locals");
					entry_point_index = $3;
					// Make sure we get its real address, not packed address
					the_relocations[$3]->userData = UD_STATIC;
				}
				else
					yyerror("cannot have two routines named main");
			}
			$2->second.token = RNAME; 
			$2->second.ival = $3;
		}
	;

wordbit_def
	: WORDBIT INTLIT dict_list ';'
		{
			for (auto it=$3; it; it = it->cdr)
				z_dict_payload(it->car) |= $2;
			delete $3;
		}
	;

action_def
	: ACTION INTLIT ';'
	| ACTION INTLIT '{' RNAME ':' { actions_blob->addRelocation($4); action_bit = 32; } action_list '}'
	;

action_list
	: phrase_list { actions_blob->contents[actions_blob->offset-2] |= 0x80; }
	| phrase_list RNAME	{ actions_blob->contents[actions_blob->offset-2] |= 0xC0; actions_blob->addRelocation($2); }
	| phrase_list RNAME { actions_blob->contents[actions_blob->offset-2] |= 0x40; actions_blob->addRelocation($2); action_bit = 16; }
	  phrase_list RNAME { actions_blob->contents[actions_blob->offset-2] |= 0xC0; actions_blob->addRelocation($5); }
	;

phrase_list
	: phrase
	| phrase '/' phrase_list
	;

phrase
	: dict			{ z_dict_payload($1) |= action_bit; actions_blob->storeWord($1); }
	| dict dict		{ z_dict_payload($1) |= action_bit; actions_blob->storeWord($1 | 0x2000); actions_blob->storeWord($2); }
	;

dict
	: DICT	{ if (z_dict_payload($1)==255) yyerror("cannot use synonym here"); $$ = $1; }
	;

routine_body
	: '[' { open_scope(); next_local=0; } opt_params_list opt_locals_list ']' stmt
		{ 
			$$ = emit_routine(next_local,$6);
			close_scope();
		}
	;

opt_params_list
	: 
	| params_list
	;

params_list
	: param params_list
	| param
	;

param
	:  NEWSYM 
		{ 
			if (the_header.version==3 && next_local==3) 
				yyerror("too many params (limit is 3 for v3)"); 
			else if (the_header.version>3 && next_local==7)
				yyerror("too many params (limit is 7 for v4+)");
			$1->second.token = LNAME; 
			$1->second.ival = next_local++; 
		}
	;

opt_locals_list
	: 
	| ';' locals_list
	;

locals_list
	: local locals_list
	| local
	;

local
	: NEWSYM
		{ 
			if (next_local==15) 
				yyerror("too many params + locals"); 
			$1->second.token = LNAME; 
			$1->second.ival = next_local++; 
		}
	;

stmts
	: stmt stmts	{ if ($1->isReturn() && $2) yyerror("unreachable code"); $$ = new list_node<stmt*>($1,$2); }
	| stmt			{ $$ = new list_node<stmt*>($1,nullptr); }
	;

stmt
	: IF cond_expr stmt  				{ $$ = new stmt_if($2,$3,nullptr); }
	| IF cond_expr stmt ELSE stmt 	%prec IF	{ $$ = new stmt_if($2,$3,$5); }
	| REPEAT stmt WHILE cond_expr ';'	{ $$ = new stmt_repeat($2,$4); }
	| WHILE cond_expr stmt				{ $$ = new stmt_while($2,$3); }
	// | FOR '(' opt_init_expr ';' opt_bool_expr
	| '{' stmts '}'			{ $$ = new stmts($2); }
	| vname '=' expr ';'	{ $$ = new stmt_assign($1,expr::fold_constant($3)); }
	| vname '[' expr ']' '=' expr ';' { $$ = new stmt_store(_var::storeb,new expr_variable($1),$3,$6); }
	| vname '[' '[' expr ']' ']' '=' expr ';' { $$ = new stmt_store(_var::storew,new expr_variable($1),$4,$8); }
	| RETURN expr ';'		{ $$ = new stmt_return(expr::fold_constant($2)); }
	| RFALSE ';'			{ $$ = new stmt_return(new expr_literal(0)); }
	| RTRUE ';'				{ $$ = new stmt_return(new expr_literal(1)); }
	| CALL expr opt_call_args ';'	{ $$ = new stmt_call(new list_node<expr*>($2,$3));  }
	| RNAME opt_call_args ';'		{ $$ = new stmt_call(new list_node<expr*>(new expr_reloc($1),$2)); }
	| STMT_0OP ';'					{ $$ = new stmt_0op($1); }
	| STMT_1OP  expr  ';'			{ $$ = new stmt_1op($1,$2); }
	| STMT_2OP '(' expr ',' expr ')' ';' { $$ = new stmt_2op($1,$3,$5); } 
	| STMT_VAROP1 expr  ';'			{ $$ = new stmt_varop1($1,$2); }
	| STMT_VAROP2 '(' expr ',' expr ')'  ';'	{ $$ = new stmt_varop2($1,$3,$5); }
	| PRINT STRLIT ';'				{ $$ = new stmt_print(_0op::print,$2); }
	| PRINT_RET STRLIT ';'			{ $$ = new stmt_print(_0op::print_ret,$2); }
	| INCR vname ';'				{ $$ = new stmt_1op(_1op::inc,new expr_literal($2)); }
	| DECR vname ';'				{ $$ = new stmt_1op(_1op::dec,new expr_literal($2)); }
	| objref GAINS aname ';' 		{ $$ = new stmt_2op(_2op::set_attr,$1,$3); }
	| objref LOSES aname ';'		{ $$ = new stmt_2op(_2op::clear_attr,$1,$3); }
	| MOVE objref INTO objref ';'	{ $$ = new stmt_2op(_2op::insert_obj,$2,$4); }
	| CONTINUE ';'					{ $$ = new stmt_continue(); }
	| BREAK ';'						{ $$ = new stmt_break(); }
	; 
	
cond_expr
	: '(' bool_expr ')' { $$ = $2; }
	;

opt_call_args
	: STRLIT			{ $$ = new list_node<expr*>(new expr_literal(encode_string($1)),nullptr); delete[] $1; }
	| '(' ')'			{ $$ = nullptr; }
	| '(' arg_list ')'	{ $$ = $2; }
	;

arg_list
	: arg ',' arg_list	{ $$ = new list_node<expr*>($1,$3); }
	| arg				{ $$ = new list_node<expr*>($1,nullptr); }
	;

arg
	: expr				{ $$ = $1; }
	;

expr
	: expr '+' expr 	{ $$ = expr::fold_constant(new expr_binary($1,_2op::add,$3,[](int16_t a,int16_t b)->int16_t{return a+b;})); }
	| expr '-' expr 	{ $$ = expr::fold_constant(new expr_binary($1,_2op::sub,$3,[](int16_t a,int16_t b)->int16_t{return a-b;})); }
	| expr '*' expr 	{ $$ = expr::fold_constant(new expr_binary($1,_2op::mul,$3,[](int16_t a,int16_t b)->int16_t{return a*b;})); }
	| expr '/' expr 	{ $$ = expr::fold_constant(new expr_binary($1,_2op::div,$3,[](int16_t a,int16_t b)->int16_t{if (!b) yyerror("division by zero"); return a/b;})); }
	| expr '%' expr 	{ $$ = expr::fold_constant(new expr_binary($1,_2op::mod,$3,[](int16_t a,int16_t b)->int16_t{if (!b) yyerror("modulo by zero"); return a%b;})); }
	| '~' expr      	{ $$ = new expr_unary(_1op::not_,$2); }
	| expr '&' expr 	{ $$ = expr::fold_constant(new expr_binary($1,_2op::and_,$3,[](int16_t a,int16_t b)->int16_t{return a&b;})); }
	| expr '|' expr 	{ $$ = expr::fold_constant(new expr_binary($1,_2op::or_,$3,[](int16_t a,int16_t b)->int16_t{return a|b;})); }
	| expr LSH expr		{ $$ = new expr_binary_log_shift($1,$3); }
	| expr RSH expr		{ $$ = new expr_binary_log_shift($1,new expr_binary(new expr_literal(0),_2op::sub,$3)); }
	| objref '.' pname	{ $$ = new expr_binary($1,_2op::get_prop,$3); }
	| ADDROF '(' objref '.' pname ')' { $$ = new expr_binary($3,_2op::get_prop_addr,$5); }
	| SIZEOF '(' expr ')' { $$ = new expr_unary(_1op::get_prop_len,$3); }
	| '(' expr ')'  	{ $$ = expr::fold_constant($2); }
	| primary       	{ $$ = $1; }
	| INTLIT        	{ $$ = new expr_literal($1); }
	| dict				{ $$ = new expr_literal($1); }
	| PNAME				{ $$ = new expr_literal($1 & 63); }
	| RNAME opt_call_args { $$ = new expr_call(new list_node<expr*>(new expr_reloc($1),$2)); }
	| CALL expr opt_call_args { $$ = new expr_call(new list_node<expr*>($2,$3)); }
	;

bool_expr
	: expr '<' expr		{ $$ = new expr_binary_branch($1,_2op::jl,false,$3,[](int16_t a,int16_t b)->int16_t{return a<b;}); }
	| expr LE expr		{ $$ = new expr_binary_branch($1,_2op::jg,true,$3,[](int16_t a,int16_t b)->int16_t{return a<=b;}); }
	| expr '>' expr		{ $$ = new expr_binary_branch($1,_2op::jg,false,$3,[](int16_t a,int16_t b)->int16_t{return a>b;}); }
	| expr GE expr		{ $$ = new expr_binary_branch($1,_2op::jl,true,$3,[](int16_t a,int16_t b)->int16_t{return a>=b;}); }
	| expr EQ expr		{ $$ = $3->isZero()? 
			static_cast<expr_branch*>(new expr_unary_branch(_1op::jz,false,$1)) : 
			static_cast<expr_branch*>(new expr_binary_branch($1,_2op::je,false,$3,[](int16_t a,int16_t b)->int16_t{return a==b;})); }
	| expr NE expr		{ $$ = $3->isZero()? 
			static_cast<expr_branch*>(new expr_unary_branch(_1op::jz,true,$1)) : 
			static_cast<expr_branch*>(new expr_binary_branch($1,_2op::je,true,$3,[](int16_t a,int16_t b)->int16_t{return a!=b;})); }
	| expr IN '{' expr '}'	{ $$ = new expr_in($1,$4); }
	| expr IN '{' expr ',' expr '}' { $$ = new expr_in($1,$4,$6); }
	| expr IN '{' expr ',' expr ',' expr '}' { $$ = new expr_in($1,$4,$6,$8); }
	| NOT bool_expr		{ $$ = new expr_logical_not($2); }
	| bool_expr AND bool_expr		{ $$ = new expr_logical_and($1,$3); }
	| bool_expr OR bool_expr		{ $$ = new expr_logical_or($1,$3); }
	| objref has_or_hasnt aname	{ $$ = new expr_binary_branch($1,_2op::test_attr,$2,$3); }
	| objref has_or_hasnt CHILD opt_arrow { $$ = new expr_unary_branch_store(_1op::get_child,$2,$1,$4); }
	| objref has_or_hasnt SIBLING opt_arrow { $$ = new expr_unary_branch_store(_1op::get_sibling,$2,$1,$4); }
	| objref HOLDS objref 	{ $$ = new expr_binary_branch($1,_2op::jin,false,$3); }
	| SAVE				{ $$ = new expr_saveRestore(_0op::save); }
	| RESTORE			{ $$ = new expr_saveRestore(_0op::restore); }
	| '(' bool_expr ')' { $$ = $2; }
	;

has_or_hasnt
	: HAS			{ $$ = false; }
	| HASNT			{ $$ = true; }
	;

opt_arrow
	: 				{ $$ = 16 + SCRATCH; }
	| ARROW vname 	{ $$ = $2; }
	;

pname
	: PNAME			{ $$ = new expr_literal($1 & 63); }
	| vname			{ $$ = new expr_variable($1); }
	;

primary
	: objref						{ $$ = $1; }
	| primary '[' expr ']'			{ $$ = new expr_binary($1,_2op::loadb,$3); }
	| primary '[' '[' expr ']' ']'	{ $$ = new expr_binary($1,_2op::loadw,$4); }
	;

objref
	: ONAME			{ $$ = new expr_literal($1); }
	| SELF			{ $$ = new expr_literal(self_value); }
	| vname			{ $$ = new expr_variable($1); }
	| objref PARENT { $$ = new expr_unary(_1op::get_parent,$1); }
	| objref CHILD 	{ $$ = new expr_unary(_1op::get_child,$1); }
	| objref SIBLING { $$ = new expr_unary(_1op::get_sibling,$1); }
	;

aname
	: ANAME			{ $$ = new expr_literal($1 & 63); }
	| vname			{ $$ = new expr_variable($1); }
	;

vname
	: LNAME			{ $$ = $1 + 1; }
	| GNAME			{ if ($1 == SCRATCH) yyerror("cannot refer to scratch variable here"); $$ = $1 + 16; }
	| NEWSYM		{ yyerror("unknown symbol '%s'",$1->first.c_str()); $$ = SCRATCH + 16; }
	;

%%

std::map<std::string,int16_t> rw;
std::map<std::string,_0op> f_0op;
std::map<std::string,_1op> f_1op;
std::map<std::string,_2op> f_2op;
std::map<std::string,_var> f_varop1;
std::map<std::string,_var> f_varop2;


static uint8_t s_EncodedCharacters[256];

const uint8_t* print_encoded_string(const uint8_t *src,void (*pr)(char ch)) {
	uint8_t step = 0, end = 0;
	auto readCode = [&]() {
		if (step==0) {
			step = 1;
			return (src[0] >> 2) & 31;
		}
		else if (step==1) {
			step = 2;
			return ((src[0] & 3) << 3) | (src[1] >> 5);
		}
		else {
			step = 0;
			end = !!(src[0] & 0x80);
			src += 2;
			return src[-1] & 31;
		}
	};
	const char *alphabet = DEFAULT_ZSCII_ALPHABET;
	uint8_t shift = 0;
	while (!end) {
		uint8_t ch = readCode();
		if (!ch)
			pr(32);
		else if (ch==4)
			shift = 26;
		else if (ch==5)
			shift = 52;
		else if (ch>=6) {
			if (ch == 6 && shift == 52) {	// 10-bit ZSCII code
				ch = readCode() << 5;
				ch |= readCode();
				pr(ch);
			}
			else if (ch == 7 && shift == 52)
				pr(10);
			else
				pr(alphabet[(ch-6)+shift]);
			shift = 0;
		}
	}
	return src;
}

uint16_t encode_string(uint8_t *dest,size_t destSize,const char *src,size_t srcSize,bool forDict) {
	uint16_t offset = 0, step = 0;
	assert((destSize & 1) == 0);
	auto storeCode = [&](uint8_t code) {
		assert(code<32);
		if (step==0) {
			step = 1;
			if (dest)
				 dest[offset] = code << 2;
		}
		else if (step==1) {
			step = 2;
			if (dest) {
				dest[offset] |= code >> 3;
				dest[offset+1] = code << 5;
			}
		}
		else {	/* step==2 */
			step = 0;
			if (dest)
				dest[offset+1] |= code;
			offset += 2;
		}
	};
	while (srcSize-- && (!destSize || offset < destSize)) {
		uint8_t code = s_EncodedCharacters[*src++];
		if (code == 255) {
			storeCode(5);
			storeCode(6);
			storeCode(src[-1]>>5);
			storeCode(src[-1]&31);
		}
		else {
			if (code > 31)
				storeCode(code >> 5);
			storeCode(code & 31);
		}
	}
	// pad with shift characters
	if (step) {
		storeCode(5);
		if (step)
			storeCode(5);
	}
	while (forDict && offset < destSize) {
		storeCode(5);
		storeCode(5);
		storeCode(5);
	}
	if (dest)
		dest[offset-2] |= 0x80; // mark end of string
	return offset;
}

void init(int version) {
	rw["attribute"] = ATTRIBUTE;
	rw["constant"] = CONSTANT;
	rw["property"] = PROPERTY;
	rw["global"] = GLOBAL;
	rw["object"] = OBJECT;
	rw["location"] = LOCATION;
	rw["routine"] = ROUTINE;
	rw["wordbit"] = WORDBIT;
	rw["synonym"] = SYNONYM;
	rw["action"] = ACTION;
	rw["in"] = IN;
	rw["is"] = EQ;
	rw["isnt"] = NE;
	rw["isn't"] = NE;
	rw["has"] = HAS;
	rw["hasnt"] = HASNT;
	rw["hasn't"] = HASNT;
	rw["holds"] = HOLDS;
	rw["gains"] = GAINS;
	rw["loses"] = LOSES;
	rw["byte_array"] = BYTE_ARRAY;
	rw["word_array"] = WORD_ARRAY;
	rw["call"] = CALL;
	rw["while"] = WHILE;
	rw["repeat"] = REPEAT;
	rw["rtrue"] = RTRUE;
	rw["rfalse"] = RFALSE;
	rw["if"] = IF;
	rw["else"] = ELSE;
	rw["return"] = RETURN;
	rw["or"] = OR;
	rw["and"] = AND;
	rw["not"] = NOT;
	rw["save"] = SAVE;
	rw["restore"] = RESTORE;
	rw["sibling"] = SIBLING;
	rw["parent"] = PARENT;
	rw["child"] = CHILD;
	rw["print"] = PRINT;
	rw["print_ret"] = PRINT_RET;
	rw["self"] = SELF;
	rw["move"] = MOVE;
	rw["into"] = INTO;
	rw["sizeof"] = SIZEOF;
	rw["addrof"] = ADDROF;
	rw["continue"] = CONTINUE;
	rw["break"] = BREAK;

	f_0op["restart"] = _0op::restart;
	f_0op["quit"] = _0op::quit;
	f_0op["crlf"] = _0op::new_line;
	f_0op["show_status"] = _0op::show_status;

	// f_1op["get_parent"] = _1op::get_parent; // unlike others, get_parent isn't a branch
	f_1op["print_addr"] = _1op::print_addr;
	f_1op["print_paddr"] = _1op::print_paddr;
	f_1op["remove_obj"] = _1op::remove_obj;
	f_1op["print_obj"] = _1op::print_obj;

	f_2op["set_attr"] = _2op::set_attr;
	f_2op["clear_attr"] = _2op::clear_attr;
	f_2op["insert_obj"] = _2op::insert_obj;

	f_varop1["print_num"] = _var::print_num;
	f_varop1["print_char"] = _var::print_char;
	f_varop2["sread"] = _var::sread;
	f_varop1["output_stream"] = _var::output_stream;
	f_varop2["output_stream2"] = _var::output_stream;
	f_varop1["input_stream"] = _var::input_stream;

	if (version >= 4) {
		f_varop1["erase_window"] = _var::erase_window;
		f_varop1["erase_line"] = _var::erase_line;
		f_varop2["set_cursor"] = _var::set_cursor;
		f_varop1["get_cursor"] = _var::get_cursor;
		f_varop1["set_text_style"] = _var::set_text_style;
		f_varop1["buffer_mode"] = _var::buffer_mode;
		f_varop1["read_char"] = _var::read_char; // not quite correct
	}

	if (version >= 5) {
		f_2op["set_color"] = _2op::set_colour;
		f_2op["set_colour"] = _2op::set_colour;
	}

	// build the forward mapping
	const char *alphabet = DEFAULT_ZSCII_ALPHABET;
	memset(s_EncodedCharacters,0xFF,sizeof(s_EncodedCharacters));
	for (uint32_t i=0; i<26; i++) {
		s_EncodedCharacters[alphabet[i]] = (i + 6);
		s_EncodedCharacters[alphabet[i+26]] = (4<<5) | (i + 6);
	}
	for (uint32_t i=2; i<26; i++)
		s_EncodedCharacters[alphabet[i+52]] = (5<<5) | (i + 6);
	s_EncodedCharacters[32] = 0;
	s_EncodedCharacters[13] = (5 << 5) | 7;
	// 1,2,3=abbreviations, 4=shift1, 5=shift2

	the_object_table.push_back(nullptr);	// object zero doesn't exist
	the_action_table.push_back(nullptr);

	rfalseLabel = createLabel(); rfalseLabel->offset = 0xFFF0;
	rtrueLabel = createLabel(); rtrueLabel->offset = 0xFFF1;

	if (version != 8 && (version < 3 || version > 5))
		yyerror("only versions 3,4,5,8 supported");
	attribute_next[0] = version>3? 47 : 31;
	property_next[0] = version>3? 63 : 31;
	story_shift = version==8? 3 : version==3? 1 : 2;
	dict_entry_size = version>3? 6 : 4;
	the_header.version = version;

	the_globals["$zversion"] = { INTLIT, int16_t(version) };
	the_globals["$dict_entry_size"] = { INTLIT, int16_t(dict_entry_size) };
	the_globals["$is_object"] = { ANAME, int16_t(0) };
}

int encode_string(const char *src) {
	size_t srcLen = strlen(src);
	uint16_t bytes = encode_string(nullptr,0,src,srcLen);
	uint8_t *dest = new uint8_t[bytes];
	encode_string(dest,bytes,src,srcLen);
	return 0; // TODO
}

void emit1op(_1op opcode,operand uval) {
	if (uval.type==optype::large_constant)
		emitByte(0x80 + (uint8_t)opcode);
	else if (uval.type==optype::small_constant)
		emitByte(0x90 + (uint8_t)opcode);
	else
		emitByte(0xA0 + (uint8_t)opcode);
	emitOperand(uval);
}

void emit2op(operand lval,_2op opcode,operand rval) {
	if (lval.type==optype::small_constant && rval.type==optype::small_constant)
		emitByte((uint8_t)opcode + 0x00);
	else if (lval.type==optype::small_constant && rval.type==optype::variable)
		emitByte((uint8_t)opcode + 0x20);
	else if (lval.type==optype::variable && rval.type==optype::small_constant)
		emitByte((uint8_t)opcode + 0x40);
	else if (lval.type==optype::variable && rval.type==optype::variable)
		emitByte((uint8_t)opcode + 0x60);
	else {
		emitByte((uint8_t)opcode + 0xC0);
		emitByte(((uint8_t)lval.type << 6) | ((uint8_t)rval.type << 4) | 0xF);
	}
	emitOperand(lval);
	emitOperand(rval);
}

void emitvarop(operand lval,_2op opcode,operand rval1,operand rval2) {
	emitByte((uint8_t)opcode + 0xC0);
	emitByte((uint8_t(lval.type) << 6) | (uint8_t(rval1.type) << 4) | (uint8_t(rval2.type) << 2) | 0x3);
	emitOperand(lval);
	emitOperand(rval1);
	emitOperand(rval2);
}

void emitvarop(_var opcode,operand op1) {
	emitByte((uint8_t)opcode + 0xE0);
	emitByte((uint8_t(op1.type) << 6) | 0x3F);
	emitOperand(op1);
}

void emitvarop(_var opcode,operand op1,operand op2) {
	emitByte((uint8_t)opcode + 0xE0);
	emitByte((uint8_t(op1.type) << 6) | (uint8_t(op2.type) << 4) | 0xF);
	emitOperand(op1);
	emitOperand(op2);
}

void emitvarop(_var opcode,operand op1,operand op2,operand op3) {
	emitByte((uint8_t)opcode + 0xE0);
	emitByte((uint8_t(op1.type) << 6) | (uint8_t(op2.type) << 4) | (uint8_t(op3.type) << 2) | 0x3);
	emitOperand(op1);
	emitOperand(op2);
	emitOperand(op3);
}

void emitvarop(_var opcode,operand op1,operand op2,operand op3,operand op4) {
	emitByte((uint8_t)opcode + 0xE0);
	emitByte((uint8_t(op1.type) << 6) | (uint8_t(op2.type) << 4) | (uint8_t(op3.type) << 2) | uint8_t(op4.type));
	emitOperand(op1);
	emitOperand(op2);
	emitOperand(op3);
	emitOperand(op4);
}

void emitvarop(operand lval,_2op opcode,operand rval1,operand rval2,operand rval3) {
	emitByte((uint8_t)opcode + 0xC0);
	emitByte((uint8_t(lval.type) << 6) | (uint8_t(rval1.type) << 4) | (uint8_t(rval2.type) << 2) | uint8_t(rval3.type));
	emitOperand(lval);
	emitOperand(rval1);
	emitOperand(rval2);
	emitOperand(rval3);
}

void disassemble(uint16_t blob) {
	const uint8_t *pc = the_relocations[blob]->contents, *base = pc, *stop = pc + the_relocations[blob]->size;
	uint32_t addr = the_relocations[blob]->address;
	printf("%s at %x:\n",the_relocations[blob]->desc.c_str(),addr);
	if (*pc) {
		printf("[%d locals]\n",*pc);
		if (the_header.version < 5)
			pc += 1 + (*pc<<1);
		else
			++pc;
	}
	else
		pc++, printf("[no locals]\n");
	auto prvar = [](uint8_t v) {
		if (!v)
			printf(" TOS");
		else if (v < 16)
			printf(" local%d",v-1);
		else
			printf(" global%d",v-16);
	};
	while (pc < stop) {
		uint16_t offs = pc - base + addr;
		uint8_t insn = *pc++;
		uint16_t types = opTypes[insn >> 4] << 8;
		if (!types) {
			types = *pc++ << 8;
			if (insn == (0xA0 | (uint8_t)_var::call_vs2))
				types |= *pc++;
			else
				types |= 0xFF;
		}
		else
			types |= 0xFF;
		if (insn==SHORT_JUMP)
			pc++, printf("%06x jump %zx\n",offs,addr + pc - base + pc[-1] - 2);
		else if (insn==LONG_JUMP)
			pc+=2, printf("%06x jump %zx\n",offs,addr + pc - base + int16_t((pc[-2] << 8) | pc[-1]) - 2);
		else {
			printf("%06x %s",offs,opcode_names[insn]);
			// make sure call address is shifted properly
			if (insn==CALL_VS && (types>>14)==(uint8_t)optype::large_constant) {
				pc+=2, printf(" 0x%x",(uint16_t(pc[-2]<<8)|pc[-1]) << story_shift);
				types = (types << 2) | 0x3;
			}
			while (types != 0xFFFF) {
				if ((types >> 14) == (uint8_t)optype::variable)
					prvar(*pc++);
				else if ((types >> 14) == (uint8_t)optype::small_constant)
					printf(" %d",*pc++);
				else
					pc+=2, printf(" %d",int16_t(pc[-2]<<8)|pc[-1]);
				types = (types << 2) | 0x3;
			}
			uint8_t extra = (decode[insn] >> version_shift[the_header.version]) & 3;
			if (extra & 1) {
				printf(" ->");
				prvar(*pc++);
			}
			if (extra & 2) {
				int16_t branch_offset = *pc++;
				uint8_t branch_cond = branch_offset >> 7;
				branch_offset &= 0x7F;
				if (branch_offset & 0x40)
					branch_offset &= 0x3F;
				else {
					if (branch_offset & 0x20)
						branch_offset |= 0xC0;
					branch_offset = (branch_offset << 8) | *pc++;
				}
				printf(branch_cond? " ?" : " ?~");
				if (branch_offset==0)
					printf("rfalse");
				else if (branch_offset==1)
					printf("rtrue");
				else
					printf("%x",(unsigned)(addr + (pc - base) + branch_offset - 2));
			}
			if (insn == 0xB2 || insn == 0xB3) {
				printf(" \"");
				pc = print_encoded_string(pc,[](char ch){putchar(ch);});
				printf("\"");
			}
			printf(" [");
			offs -= addr;
			while (base + offs < pc)
				printf(" %02x",base[offs++]);
			printf(" ]\n");
		}
	}
}

int yych, yylen, yypass, yyline, yyscope;
char yytoken[32];
FILE *yyinput;
inline int yynext() { if (yych!=EOF) { yych = getc(yyinput); if (yych == 10) ++yyline; } return yych; }

int yylex_() {
	yylen = 0;
	while (isspace(yych))
		yynext();

	if (isalpha(yych)||yych=='#'||yych=='_'||yych=='$') {
		do {
			if (yylen==sizeof(yytoken)-1)
				yyerror("token too long");
			yytoken[yylen++] = yych;
			yynext();
		} while (isalnum(yych)||yych=='_'||yych=='\'');
		yytoken[yylen] = 0;
		// reserved words and builtin funcs first
		auto r = rw.find(yytoken);
		if (r != rw.end())
			return r->second;
		auto z = f_0op.find(yytoken);
		if (z != f_0op.end()) {
			yylval.zeroOp = z->second;
			return STMT_0OP;
		}
		auto o = f_1op.find(yytoken);
		if (o != f_1op.end()) {
			yylval.oneOp = o->second;
			return STMT_1OP;
		}
		auto t = f_2op.find(yytoken);
		if (t != f_2op.end()) {
			yylval.twoOp = t->second;
			return STMT_2OP;
		}
		auto v1 = f_varop1.find(yytoken);
		if (v1 != f_varop1.end()) {
			yylval.varOp = v1->second;
			return STMT_VAROP1;
		}		
		auto v2 = f_varop2.find(yytoken);
		if (v2 != f_varop2.end()) {
			yylval.varOp = v2->second;
			return STMT_VAROP2;
		}		
		// check locals, which take precedence over other symbols
		if (the_locals.size()) {
			auto l = the_locals.back()->find(yytoken);
			if (l != the_locals.back()->end()) {
				yylval.ival = l->second.ival;
				return LNAME;
			}
		}
		// finally search globals
		auto s = the_globals.find(yytoken);
		if (s != the_globals.end()) {
			yylval.ival = s->second.ival;
			return s->second.token;
		}
		// otherwise it's a new symbol (do no actual work on first pass)
		if (yypass==1)
			return NEWSYM;
		else {
			if (the_locals.size())
				yylval.sym = &*the_locals.back()->insert(std::pair<std::string,symbol>(yytoken,{0,0})).first;
			else
				yylval.sym = &*the_globals.insert(std::pair<std::string,symbol>(yytoken,{0,0})).first;
			return NEWSYM;
		}
	}
	else switch(yych) {
		case '-':
			yytoken[yylen++] = '-';
			yynext();
			if (yych<'0'||yych>'9') {
				if (yych=='>') {
					yynext();
					return ARROW;
				}
				else if (yych=='-') {
					yynext();
					return DECR;
				}
				else	
					return '-';
			}
			[[fallthrough]];
		case '0': case '1': case '2': case '3': case '4':
		case '5': case '6': case '7': case '8': case '9':
			do {
				yytoken[yylen++] = yych;
				yynext();
			} while (yych>='0'&&yych<='9');
			yytoken[yylen] = 0;
			yylval.ival = atoi(yytoken);
			return INTLIT;
		case '+': 
			if (yynext()=='+') {
				yynext();
				return INCR;
			}
			else
				return '+';
		case '@': yynext(); yylval.ival = yych; yynext(); return INTLIT;
		case '(': case ')':
		case '~': case '*': case ':': case '.': case '%':
		case '&': case '|': case ';':
		case ',': case '!':
			yytoken[0] = yych;
			yynext();
			return yytoken[0];
		case '[':
			++yyscope;
			yynext();
			return '[';
		case ']':
			--yyscope;
			yynext();
			return ']';
		case '{':
			++yyscope;
			yynext();
			return '{';
		case '}':
			--yyscope;
			yynext();
			return '}';		
		case '=':
			yynext();
			if (yych=='=') {
				yynext();
				return EQ;
			}
			else
				return '='; 
		case '<':
			yynext();
			if (yych=='<') {
				yynext();
				return LSH;
			}
			else if (yych=='=') {
				yynext();
				return LE;
			}
			else if (yych=='>') {
				yynext();
				return NE;
			}
			else
				return '<';
		case '>':
			yynext();
			if (yych=='>') {
				yynext();
				return RSH;
			}
			else if (yych=='=') {
				yynext();
				return GE;
			}
			else
				return '>';
		case '/':
			yynext();
			if (yych == '/') {
				while (yynext() != EOF && yych != 10)
					;
				return yylex_();	// silly, should just goto top, hopefully compiler spots tail recursion :)
			}
			else if (yych == '*') {
				yynext();
				while (true)
					if ((yynext()=='*'&&yynext()=='/')||yych==EOF)
						return yynext(), yylex_();
			}
			else
				return '/';
		case '\'': {
			yynext();
			while (yych != '\'' && yych != EOF && yych != 32) {
				if (yylen+1==sizeof(yytoken))
					yyerror("dictionary word way too long");
				yytoken[yylen++] = tolower(yych);
				yynext();
			}
			// turn a space into a new dict word
			if (yych==32)
				yych = '\'';
			else
				yynext();
			yytoken[yylen] = 0;
			
			dict_entry de = {};
			encode_string(de.encoded,dict_entry_size,yytoken,yylen,true);
			if (yypass==1) {
				the_dictionary[de] = -1;
				yylval.ival = -1;
			}
			else {
				yylval.ival = the_dictionary[de];
			}
			return DICT;
		}
		case '"': {
			const unsigned maxString = 512;
			char *sval = new char[maxString];
			unsigned offset = 0;
			char term = yych;
			while (yynext()!=EOF && yych!=term) {
				if (yych==10||yych==13) {
NEWLINE:
					while (offset && (sval[offset-1]==9||sval[offset-1]==32))
						--offset;
					while (yynext()!=EOF && yych!=term && (yych==9||yych==32))
						;
					if (yych==10||yych==13)
						goto NEWLINE;
					if (yych==term)
						break;
					if (offset < maxString-1)
						sval[offset++] = 32;
				}
				if (offset < maxString-1) {
					if (yych < 32)
						printf("weird character %d line %d\n",yych,yyline);
					if (yych=='^'||yych==10)
						yych = 13;
					sval[offset++] = yych;
				}
			}
			yynext();
			sval[offset] = 0;
			yylval.sval = sval;
			return STRLIT;
		}
		default:
			yyerror("unknown character %c in input",yych);
			[[fallthrough]];
		case EOF:
			return EOF;
	}
}

int yylex() {
	int token = yylex_();
	if (yydebug) {
		printf("(%d)",yyscope);
		if (token==EOF)
			printf("[[EOF]]\n");
		else if (token < 255)
			printf("%u:[%c][%d]\n",yyline,token,token);
		else
			printf("%u:[%s][%s][%d]\n",yyline,yytoken,yytname[token - 255],token);
	}
	return token;
}

void yyerror(const char *fmt,...) {
	va_list args;
	va_start(args,fmt);
	fprintf(stderr,"line %d: ",yyline);
	vfprintf(stderr,fmt,args);
	putc('\n',stderr);
	va_end(args);
	exit(1);
}

int main(int argc,char **argv) {

	/* uint8_t dest[6];
	encode_string(dest,6,"Test",4);
	printf("%x %x %x %x %x %x\n",dest[0],dest[1],dest[2],dest[3],dest[4],dest[5]);
	print_encoded_string(dest,[](char ch){putchar(ch);});
	putchar('\n');
	return 1; */

	int zversion = 3;
	int release_number = 0;
	enum { R_OBJECTS=1,R_ROUTINES=2,R_GLOBALS=4,R_DICTIONARY=8,R_ACTIONS=16,R_SUMMARY=32,R_ALL=63};
	int report = 0;
	while (--argc && **++argv=='-') {
		const char *arg = *argv + 1;
		switch(*arg++) {
			case 'd': yydebug = 1; break;
			case 'r':  if (*arg) while (*arg) switch (*arg++) {
				case 'S': report |= R_SUMMARY; break;
				case 'O': report |= R_OBJECTS; break;
				case 'R': report |= R_ROUTINES; break;
				case 'G': report |= R_GLOBALS; break;
				case 'D': report |= R_DICTIONARY; break;
				case 'A': report |= R_ACTIONS; break;
				} else report = R_ALL;
				break;
			case 'R': release_number = atoi(arg); break;
			case 'z': zversion = (argv[0][2]-'0'); break;
		}
	}
	if (!argc)
		yyerror("missing input tz name");
	init(zversion);

	char outname[64];
	strlcpy(outname,argv[0],sizeof(outname)-4);
	char *ext = strrchr(outname,'.');
	if (!ext)
		ext = outname + strlen(outname);
	*ext++ = '.';
	*ext++ = 'z';
	*ext++ = the_header.version + '0';
	*ext = 0;
	// printf("compiling release %d\n",release_number);

	for (yypass=1; yypass<=2; yypass++) {
		yyinput = fopen(argv[0],"r");
		int nextObject = 1;
		yych = 32;
		yyline = 1;
		yyscope = 0;
		if (yypass==1) {
			int t;
			while ((t = yylex()) != EOF) {
				if (yyscope == 0) {
					if (t == ATTRIBUTE || t == PROPERTY)
						yylex();	// skip LOCATION/OBJECT/GLOBAL
					else if (t == OBJECT || t == LOCATION) {
						if (yylex() == NEWSYM) {
							// declare the object and assign its value
							the_globals[yytoken] = { ONAME,(int16_t)the_object_table.size() };
							the_object_table.push_back(new object {});
						}
					}
					else if (t == ACTION) {
						if (yylex() == NEWSYM) {
							if (yytoken[0]!='#')
								yyerror("action symbols must start with #");
							the_globals[yytoken] = { INTLIT,(int16_t)the_action_table.size() };
							the_action_table.push_back(new action {});
						}
					}
					else if (t == GLOBAL) {
						if (yylex() == NEWSYM) {
							if (next_global==238)
								yyerror("cannot have more than 238 globals");
							the_globals[yytoken] = { GNAME,next_global++ };
						}
					}
				}
			}
			if (report & R_SUMMARY) 
				printf("%zu words in dictionary\n",the_dictionary.size());
			// build the final dictionary, assigning word indices.
			dictionary_blob = relocatableBlob::create(7 + the_dictionary.size() * (dict_entry_size+1),UD_STATIC,"dictionary");
			dictionary_blob->storeByte(3);
			dictionary_blob->storeByte('.');
			dictionary_blob->storeByte(',');
			dictionary_blob->storeByte('"');
			dictionary_blob->storeByte(dict_entry_size+1);
			dictionary_blob->storeWord(the_dictionary.size());
			uint16_t idx = 0;
			for (auto &d: the_dictionary) {
				if (yydebug) {
					printf("word %u: [",idx);
					print_encoded_string(d.first.encoded,[](char ch){putchar(ch);});
					printf("]\n");
				}
				d.second = idx++;
				dictionary_blob->copy(d.first.encoded,dict_entry_size);
				dictionary_blob->storeByte(0);
			}
			the_globals["$actions"] = { GNAME, int16_t(next_global++) };
			the_globals["$synonyms"] = { GNAME, int16_t(next_global++) };

			globals_blob = relocatableBlob::create(next_global * 2,UD_DYNAMIC,"globals");
			actions_blob = relocatableBlob::create(the_action_table.size() << 4,UD_STATIC,"actions");
			synonyms_blob = relocatableBlob::create(256,UD_STATIC,"synonyms");
			if (report & R_SUMMARY) {
				printf("%u globals\n",next_global);
				printf("%zu objects\n",the_object_table.size()-1);
				printf("%zu actions\n",the_action_table.size()-1);
			}
			the_globals["$object_count"] = { INTLIT, int16_t(the_object_table.size() - 1) };
			the_globals["$dict_word_count"] = { INTLIT, int16_t(the_dictionary.size()) };
			header_blob = relocatableBlob::create(64,UD_DYNAMIC,"story header");
		}
		else {
			yyparse();
			actions_blob->storeWord(-1); // terminate the action list
			synonyms_blob->storeWord(-1); // terminate the synonym list
			globals_blob->addRelocation(actions_blob->index);
			globals_blob->addRelocation(synonyms_blob->index);
			uint8_t objSize = the_header.version==3? 9 : 14;
			uint8_t defPropCount = the_header.version==3? 31 : 63;
			object_blob = relocatableBlob::create((the_object_table.size()-1)*objSize + defPropCount*2,UD_DYNAMIC,"object table");
			for (int i=1; i<=defPropCount; i++)
				object_blob->storeWord(property_defaults[i]);
			if (the_header.version==3) {
				for (int i=1; i<the_object_table.size(); i++) {
					auto &o = *the_object_table[i];
					for (int j=0; j<4; j++)
						object_blob->storeByte(o.attributes[j]);
					object_blob->storeByte(o.parent);
					object_blob->storeByte(o.sibling);
					object_blob->storeByte(o.child);
					object_blob->addRelocation(o.finalProps->index);
					if (report & R_OBJECTS)
						printf("object %d properties at blob %d\n",i,o.finalProps->index);
				}
			}
			else {
				for (int i=1; i<the_object_table.size(); i++) {
					auto &o = *the_object_table[i];
					for (int j=0; j<6; j++)
						object_blob->storeByte(o.attributes[j]);
					object_blob->storeWord(o.parent);
					object_blob->storeWord(o.sibling);
					object_blob->storeWord(o.child);
					object_blob->addRelocation(o.finalProps->index);
					if (report & R_OBJECTS)
						printf("object %d properties at blob %d\n",i,o.finalProps->index);
				}
			}
			
			header_blob->storeByte(the_header.version);	// +0 version
			header_blob->storeByte(0);
			header_blob->storeWord(release_number);
			if (entry_point_index == -1)
				yyerror("missing main routine");
			// main routine is also the start of high memory
			header_blob->addRelocation(entry_point_index); // +4 high mem
			header_blob->addRelocation(entry_point_index,1); // +6 initial pc (skip local count)
			header_blob->addRelocation(dictionary_blob->index); // +8 dictionary table
			header_blob->addRelocation(object_blob->index); // +10 object table
			header_blob->addRelocation(globals_blob->index); // +12 globals
			header_blob->addRelocation(dictionary_blob->index); // +14 static memory
			header_blob->offset += 2;
			time_t now;
			time(&now);
			auto t = localtime(&now);
			char yymmdd[7];
			snprintf(yymmdd,sizeof(yymmdd),"%02d%02d%02d",t->tm_year % 100,t->tm_mon + 1,t->tm_mday);
			header_blob->copy((uint8_t*)yymmdd,6);
			header_blob->place();
			globals_blob->place();
			object_blob->place();
			relocatableBlob::placeAll(UD_DYNAMIC);
			relocatableBlob::placeAll(UD_STATIC);
			relocatableBlob::placeAll(UD_HIGH);

			header_blob->storeWord(0); // +24 abbreviations
			header_blob->storeWord((relocatableBlob::nextAddress + ((1<<story_shift)-1)) >> story_shift); // length of file
			header_blob->offset = 60;
			header_blob->storeByte('0');
			header_blob->storeByte('.');
			header_blob->storeByte('0');
			header_blob->storeByte('0');

			// todo: character table etc.
			printf("writing '%s'...\n",outname);
			FILE *output = fopen(outname,"w");
			relocatableBlob::writeAll(output);
			fclose(output);

			if (report & R_ROUTINES) {
				disassemble(entry_point_index);
				for (int i=0; i<the_relocations.size(); i++) {
					if ((size_t)the_relocations[i] > 65535 && the_relocations[i]->userData == UD_HIGH)
						disassemble(i);
				}
			}
			if (report & R_GLOBALS) {
				for (int i=0; i<globals_blob->size; i+=2)
					printf("global %d value %04x\n",i>>1,(globals_blob->contents[i] << 8) | globals_blob->contents[i+1]);
			}
			if (report & R_DICTIONARY) {
				uint8_t *d = dictionary_blob->contents + 7;
				int dc = (dictionary_blob->contents[5] << 8) | dictionary_blob->contents[6];
				for (; dc--; d+=dict_entry_size+1) {
					print_encoded_string(d,[](char ch){putchar(ch);});
					printf(" %02x\n",d[dict_entry_size]);
				}
			}
			if (report & R_OBJECTS) {
				for (int i=1; i<the_object_table.size(); i++) {
					printf("object %d properties:\n",i);
					uint8_t *p = the_relocations[the_object_table[i]->finalProps->index]->contents;
					p += 1 + p[0]*2;
					while (*p) {
						int len = (*p >> 5) + 1;
						printf("property %d size %d: [",*p & 31,len);
						p++;
						while (len--)
							printf(" %02x",*p++);
						printf(" ]\n");
					}
				}
			}
			if (report & R_ACTIONS) {
				uint16_t o = 0;
				uint8_t *d = dictionary_blob->contents + 7;
				while (o < actions_blob->offset) {
					uint16_t r = actions_blob->readWord(o); 
					if (r == 0xFFFF)
						break;
					printf("routine %06x:",r << story_shift);
					for (;;) {
						uint16_t n = actions_blob->readWord(o);
						//printf(" [%04x]",n);
						print_encoded_string(d + (dict_entry_size+1) * (n & 0x1FFF),[](char ch){putchar(ch);});
						if (n & 0x2000)
							putchar('+');
						else
							putchar(32);
						if (n & 0x4000)
							printf(" (routine %06x)",actions_blob->readWord(o) << story_shift);
						if (n & 0x8000) {
							putchar('\n');
							break;
						}
					}
				}
			}
		}
		fclose(yyinput);
	}

	// typical order
	// header (64 bytes)
	// +0 version
	// +1 misc flags
	// +4 byte address of high memory
	// +6 initial program counter
	// +8 byte address of dictionary
	// +10 byte address of object table
	// +12 byte address of globals
	// +14 byte address of static memory
	// +16 more flags
	// +18 serial number (ascii)
	// +24 byte address of abbreviation table
	// +26 length of file (>> story_shift)
	// +28 checksum
	// +46 (v5+) byte address of terminating characters table
	// +52 (v5+) byte address of alphabet table
	// property defaults (31 words in v3, else 63)
	// objects
	// object properties (dynamic) (first object must be here)
	// global variables
	// arrays
	// -- end of dynamic memory --
	// object properties (static)
	// abbreviations (one word per up to 96 abbreviations, word address of that abbreviation)
	// grammar table
	// actions table
	// dictionary
	// -- high memory --
	// routines
	// static strings
	// -- end of file --
}