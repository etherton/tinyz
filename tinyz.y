/* tinyz.y */
/* bison --debug --token-table --verbose tinyz.y -o tinyz.tab.cpp && clang++ -g -std=c++17 tinyz.tab.cpp */

%expect 1
%{
	#define ENABLE_DEBUG 1
	#include "opcodes.h"
	#include "header.h"
	#include "debug.h"
	#include <set>
	#include <map>
	#include <cassert>
	#include <string_view>

#if DEBUG_MEM
	#include <malloc/malloc.h>
	#ifdef __APPLE__
	#include <execinfo.h>
	#endif
	const unsigned max_allocs = 32768, stacks_per = 16;
	struct debug_alloc {
		void *ptr;
		#ifdef __APPLE__
		void *stack[stacks_per];
		#endif
		unsigned size;
		int line;
		int stored;
	};
	debug_alloc debug_allocations[max_allocs];
	unsigned alloc_count;
	void* debug_alloc(size_t s,int line) {
		auto &da = debug_allocations[alloc_count++];
		da.ptr = malloc(s);
		#ifdef __APPLE__
		da.stored = backtrace(da.stack,stacks_per);
		#endif
		da.line = line;
		da.size = s;
		return da.ptr;
	}
	void debug_free(void *p) {
		if (!p)
			return;
		for (unsigned i=0; i<alloc_count; i++) {
			if (debug_allocations[i].ptr == p) {
				free(p);
				debug_allocations[i] = debug_allocations[--alloc_count];
				return;
			}
		}
		printf("unknown pointer %p\n",p);
		abort();
	}
	void debug_leaks() {
		if (alloc_count) {
			printf("%u leaks\n",alloc_count);
			for (unsigned i=0; i<alloc_count; i++) {
				auto &da = debug_allocations[i];
				printf("alloc at %p sized %u bytes from line %d\n",da.ptr,da.size,da.line);
				#ifdef __APPLE__
				fflush(stdout);
				backtrace_symbols_fd(da.stack,da.stored,fileno(stdout));
				#endif
			}
			exit(1);
		}
	}
	void *operator new[](size_t s) { return debug_alloc(s,0); }
	void *operator new(size_t s) { return debug_alloc(s,0); }
	void *operator new[](size_t s,int line) { return debug_alloc(s,line); }
	void *operator new(size_t s,int line) { return debug_alloc(s,line); }
	void operator delete(void *p) _NOEXCEPT { debug_free(p); }
	void operator delete[](void *p) _NOEXCEPT { debug_free(p); }
	#define NEW new(__LINE__)
#else
	#define NEW new
#endif

	int yylex();
	void yyerror(const char*,...);
	uint16_t encode_string(uint8_t *dest,size_t destSize,const char *src,size_t srcSize,bool forDict = false);
	int encode_string(const char*);
	const uint8_t* print_encoded_string(const uint8_t *src,void (*pr)(char ch));
	uint8_t next_global, story_shift = 1, dict_entry_size = 4;
	int8_t next_local = -1;
	storyHeader the_header = { 3 };
	debug::debug_info di;
	bool write_debug_info;
	int16_t release_number;

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

	FILE *gametext;
	bool gametext_inform;
	void write_gametext(char ch,const char *s) {
		if (!gametext)
			return;
		if (gametext_inform) {
			fputc(ch,gametext);
			fputc(':',gametext);
			fputc(' ',gametext);
			while (*s) {
				if (*s=='"')
					fputc('~',gametext);
				else if (*s==13)
					fputc('^',gametext);
				else
					fputc(*s,gametext);
				++s;
			}
			fputc(10,gametext);
		}
		else
			fprintf(gametext,"%c: %s\n",ch,s);
	}
	
	std::map<size_t,uint16_t> the_counted_strings;

	const uint16_t UD_DYNAMIC = 1;
	const uint16_t UD_STATIC = 2;
	const uint16_t UD_STATIC_ABBREVIATION = 3;
	const uint16_t UD_HIGH = 4;

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
			relocatableBlob* result = NEW relocatableBlob;
			result->size = totalSize;
			result->offset = 0;
			result->relocations = nullptr;
			result->userData = ud;
			result->address = ~0U;
			result->nextPlaced = 0xFFFF;
			result->desc = desc? desc : "";
			result->contents = NEW uint8_t[totalSize];
			result->referenceCount = 0;
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
			if (t >= 0 && t <= 255) {
				auto r = createProperty(1,propertyIndex);
				r->storeByte(t);
				return r->index;
			}
			else {
				auto r = createProperty(2,propertyIndex);
				r->storeInt(t);
				return r->index;
			}
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
			delete [] the_relocations[index]->contents;
			delete the_relocations[index];
			the_relocations[indexSave] = (relocatableBlob*)(size_t)firstFree;
			firstFree = indexSave;
		}
		void resize(unsigned newSize) {
			if (newSize != size) {
				uint8_t *newContents = NEW uint8_t[newSize];
				memcpy(newContents,contents,offset);
				delete [] contents;
				contents = newContents;
				size = newSize;
			}
		}
		void reserve(unsigned atLeast) {
			if (offset + atLeast > size)
				resize(offset + atLeast + 64);
		}
		void seal() {
			resize(offset);
		}
		void place(uint32_t alignMask = 0) {
			if (firstPlaced == 0xFFFF)
				firstPlaced = index;
			else
				the_relocations[lastPlaced]->nextPlaced = index;
			lastPlaced = index;
			nextPlaced = 0xFFFF;
			nextAddress = (nextAddress + alignMask) & ~alignMask;
			if (write_debug_info) {
				auto &r = di.routines[index];
				r.start = nextAddress;
				r.end = nextAddress + size;
				di.addressMappings[nextAddress] = index;
			}
			address = nextAddress;
			nextAddress += size;
		}
		static void deadStrip() {
			bool did_something;
			do {
				for (uint16_t i=0; i<the_relocations.size(); i++) {
					if ((size_t)the_relocations[i] > 0xFFFF && 
						the_relocations[i]->address == ~0U &&
						the_relocations[i]->referenceCount==0 && 
						the_relocations[i]->relocations &&
						the_relocations[i]->userData == UD_HIGH) {
							auto j = the_relocations[i]->relocations;
							while (j) {
								assert(the_relocations[j->car.first]->referenceCount);
								the_relocations[j->car.first]->referenceCount--;
								j = j->cdr;
							}
							delete [] the_relocations[i]->contents;
							the_relocations[i]->contents = nullptr;
							delete the_relocations[i]->relocations;
							the_relocations[i]->relocations = nullptr;
							did_something = true;
					}
				}
				did_something = false;
			} while (did_something);
		}
		static void placeAll(uint16_t type) {
			for (uint16_t i=0; i<the_relocations.size(); i++) {
				if ((size_t)the_relocations[i] > 0xFFFF && the_relocations[i]->address == ~0U &&
					the_relocations[i]->referenceCount && 
					the_relocations[i]->userData == type)
					the_relocations[i]->place(type==UD_HIGH?(1U << story_shift)-1:type==UD_STATIC_ABBREVIATION?1U:0U);
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
			if (offset == size)
				resize(offset + 256);
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
		void storeWordAt(uint16_t a,uint16_t w) {
			contents[a] = w >> 8;
			contents[a+1] = w;
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
			relocations = NEW relocation_t(std::pair<uint16_t,uint16_t>(ri,offset),relocations);
			the_relocations[ri]->referenceCount++;
			storeWord(bias);
		}
		void applyRelocations() {
			int count = 0;
			for (auto i = relocations; i; i=i->cdr, count++) {
				auto &r = *the_relocations[i->car.first];
				uint16_t a = r.address >> (r.userData == UD_HIGH? story_shift : r.userData == UD_STATIC_ABBREVIATION? 1 : 0);
				a += contents[i->car.second + 1];	// add lower byte of offset (used to skip zero byte of main[])
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
				relocations = NEW relocation_t(std::pair<uint16_t,uint16_t>(i->car.first,i->car.second + offset),relocations);
			copy(other->contents,other->size);
			other->destroy();
		}
		uint16_t size, offset, index, userData, nextPlaced, referenceCount;
		uint32_t address;
		relocation_t *relocations;
		std::string desc;
		uint8_t *contents;
	};
	uint16_t relocatableBlob::firstFree=0xFFFF, relocatableBlob::firstPlaced=0xFFFF, relocatableBlob::lastPlaced;
	uint32_t relocatableBlob::nextAddress;
	relocatableBlob *header_blob, *dictionary_blob, *object_blob, *properties_blob, *globals_blob, *actions_blob, 
		*synonyms_blob, *current_global, *abbreviations_blob;
	int16_t entry_point_index = -1;
	uint8_t action_bit = 0;

	static const uint8_t opsizes[3] = { 2,1,1 };
	const uint8_t LONG_JUMP = 0x8C;			// +/-32767
	const uint8_t SHORT_JUMP = 0x9C;		// 0-255
	const uint8_t CALL_VS = 0xE0;

	relocatableBlob * current_routine;
	uint8_t currentProperty, currentBits;
	void emitByte(uint8_t b) {
		// printf("%04x: %02x\n",current_routine->offset,b);
		current_routine->storeByte(b);
	}
	void emitOperand(operand o) {
		if (o.relocation && o.type==optype::large_constant) {
			// printf("add relocatoin to blob %d\n",o.value);
			current_routine->addRelocation(o.value);
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
	void emitvarop(_var op,operand o[8]);
	void emit2op(operand l,_2op op,operand r);
	void emit1op(_1op op,operand un);
	void emit0op(_0op op) { emitByte(uint8_t(op)); }
	const uint8_t TOS = 0, SCRATCH = 3;

	typedef struct label_info {
		label_info() : offset(0), references(nullptr) { }
		~label_info() { assert(!references); }
		uint16_t offset;
		list_node<uint16_t> *references;
	} *label;
	label createLabel() {
		label result = NEW label_info;
		result->offset = 0xFFFF;
		result->references = nullptr;
		return result;
	}
	label rfalseLabel, rtrueLabel;
	std::vector<std::pair<label,label>> flow_stack;
	void fillBranch(uint16_t branchOffset,uint16_t targetOffset,bool negated,bool isLong,bool isJump) {
		assert(!isJump || !negated);
		uint8_t *dest = current_routine->contents + branchOffset;
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
					printf("warning - jump delta %d out of range in %s\n",delta,current_routine->desc.c_str());
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
					printf("branch delta %d out of range in %s, changing to rfalse\n",delta,current_routine->desc.c_str());
					dest[0] = negated? 0x40 : 0xC0;
				}
			}
		}
	}
	void placeLabel(label l) {
		l->offset = current_routine->offset;
		for (auto i=l->references; i; i=i->cdr) {
			int16_t delta = (current_routine->offset - i->car + 2);
			uint8_t *dest = current_routine->contents + i->car;
			if (dest[0]==0xFF)
				fillBranch(i->car,l->offset,false,dest[-1]==LONG_JUMP,true);
			else
				fillBranch(i->car,l->offset,(dest[0] & 0x80) == 0,!(dest[0] & 0x40),false);
		}
		delete l->references;
		l->references = nullptr;
	}
	void emitJump(label l,bool isLong) {
		emitByte(isLong? LONG_JUMP : SHORT_JUMP);
		if (l->offset != 0xFFFF) {
			fillBranch(current_routine->offset,l->offset,false,isLong,true);
			current_routine->offset += 1 + isLong;
		}
		else {
			l->references = NEW list_node<uint16_t>(current_routine->offset,l->references);
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

	const char *abbreviations[96];
	uint8_t abbreviation_lengths[96];
	uint8_t abbreviations_next[96];
	uint8_t abbreviations_lut[256];
	uint8_t abbreviation_count;

	struct symbol {
		int16_t token;	// if zero, it's a NEWSYM
		union {
			int16_t ival;
			uint16_t uval;
		};
	};
	std::map<std::string,symbol> the_globals, the_locals;
	void open_scope() { 
		current_routine = nullptr;
		next_local = 0;
	}
	void close_scope() { 
		current_routine = nullptr;
		the_locals.clear();
		next_local = -1;
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
	uint16_t self_value, action_count;
	std::vector<object*> the_object_table;
	struct action {
	};

	struct dict_entry {
		uint8_t encoded[6];
		bool operator <(const dict_entry &rhs) const {
			return memcmp(encoded,rhs.encoded,sizeof(encoded)) < 0;
		}
	};
	std::map<dict_entry,uint16_t> the_dictionary; // maps a dictionary word to its index
	const uint8_t dict_payload_size = 1;
	uint8_t* z_dict_ptr(uint16_t i) { 
		uint8_t *c = dictionary_blob->contents;
		return c + c[0] + 4 + i * (dict_entry_size+dict_payload_size); 
	}
	uint8_t& z_dict_payload(uint16_t i) { return z_dict_ptr(i)[dict_entry_size]; }

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
		~expr_binary_log_shift() { delete left; delete right; }
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
			if (opcode == _1op::not_call_1n && the_header.version>=5)
				emitvarop(_var::not_,uval);
			else
				emit1op(opcode,uval);
			emitByte(dest);
			// emit a dummy branch to next instruction.
			if (opcode == _1op::get_sibling || opcode == _1op::get_child)
				emitByte(0x42);
		}
		unsigned size() const {
			return 1 + unary->opsize() + 1 + (opcode == _1op::get_sibling || opcode == _1op::get_child || 
				(opcode==_1op::not_call_1n && the_header.version>=5? 2 : 0));
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
				fillBranch(current_routine->offset,target->offset,n,isLong,false);
				current_routine->offset += 1 + isLong;
			}
			else {
				target->references = NEW list_node<uint16_t>(current_routine->offset,target->references);
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
	struct expr_scan_table_branch_store: public expr_branch {
		expr_scan_table_branch_store(expr *a,expr *b,expr *c,expr *d,uint8_t de) : expr0(a), expr1(b), expr2(c), expr3(d), dest(de), expr_branch(false) { }
		~expr_scan_table_branch_store() { delete expr0; delete expr1; delete expr2; delete expr3; }
		uint8_t dest;
		expr *expr0, *expr1, *expr2, *expr3;
		void emitBranch(label target,bool negated,bool isLong) {
			operand op0, op1, op2, op3;
			if (expr3)
				expr3->eval(op3);
			expr2->eval(op2);
			expr1->eval(op1);
			expr0->eval(op0);
			if (expr3)
				emitvarop(_var::scan_table,op0,op1,op2,op3);
			else
				emitvarop(_var::scan_table,op0,op1,op2);
			emitByte(dest);
			expr_branch::emitBranch(target,negated,isLong);
		}
		unsigned size() const {
			return expr0->size() + expr1->size() + expr2->size() + (expr3? expr3->size() : 0) + 5;
		}
		void dump() const {
			printNode("scan_table:");
			printNode(expr0);
			printNode(expr1);
			printNode(expr2);
			if (expr3)
				printNode(expr3);
		}
	};
	struct expr_call: public expr { // first arg is func address
		expr_call(list_node<expr*> *a) : args(a) { }
		~expr_call() { auto i = args; while (i) { delete i->car; i = i->cdr; } delete args; }
		list_node<expr*> *args;
		// TODO: v3 only supports VAR call (3 params). v4 supports 1/2 operand with result and 7 params.
		// v5 supports implicit pop versions of all calls
		static void fill_operands(operand dest[8],list_node<expr*> *a) {
			// args need to be pushed onto stack in reverse order so do recursion first.
			if (a->cdr)
				fill_operands(dest+1,a->cdr);
			a->car->eval(dest[0]);
		}
		virtual void emit(uint8_t dest) const {
			operand o[8];
			for (int i=0; i<8; i++)
				o[i].type = optype::omitted;
			fill_operands(o,args);
			if (the_header.version>=4 && args->size()==1 && o[0].type!=optype::large_constant) {
				if (the_header.version<5 || dest!=16+SCRATCH) {
					emit1op(_1op::call_1s,o[0]);
					emitByte(dest);
				}
				else
					emit1op(_1op::not_call_1n,o[0]);
			}
			else if (the_header.version>=4 && args->size()==2 && o[0].type!=optype::large_constant && o[1].type!=optype::large_constant) {
				if (the_header.version<5 || dest!=16+SCRATCH) {
					emit2op(o[0],_2op::call_2s,o[1]);
					emitByte(dest);
				}
				else
					emit2op(o[0],_2op::call_2n,o[1]);
			}
			else {
				if (args->size() > 4) {
					if (the_header.version<5 || dest!=16+SCRATCH) {
						emitvarop(_var::call_vs2,o);
						emitByte(dest);
					}
					else
						emitvarop(_var::call_vn2,o);
				}
				else if (the_header.version<5 || dest!=16+SCRATCH) {
					emitvarop(_var::call_vs,o[0],o[1],o[2],o[3]);
					emitByte(dest);
				}
				else
					emitvarop(_var::call_vn,o[0],o[1],o[2],o[3]);
			}
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
				return NEW expr_literal(c);
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
	expr *trace_level_expr() {
		static auto tl = the_globals.find("$tracebits");
		if (tl != the_globals.end()) {
			if (tl->second.token == GNAME)
				return NEW expr_variable(tl->second.ival + 16);
			else if (tl->second.token == INTLIT)
				return NEW expr_literal(tl->second.ival);
		}
		return NEW expr_literal(0);
	}
	struct expr_logical_not: public expr_branch {
		expr_logical_not(expr_branch *e) : unary(e), expr_branch(!e->negated) { }
		~expr_logical_not() { delete unary; }
		expr_branch *unary;
		void emitBranch(label target,bool negated,bool isLong) {
			unary->emitBranch(target,!negated,isLong);
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
				delete failed;
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
				delete success;
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
	struct expr_varop1: public expr {
		expr_varop1(_var o,expr *u) : opcode(o), unary(u) { }
		~expr_varop1() { delete unary; }
		_var opcode;
		expr *unary;
		void emit(uint8_t dest) const {
			operand uval;
			unary->eval(uval);
			emitvarop(opcode,uval);
			emitByte(dest);
		}
		unsigned size() const {
			return unary->size() + 2;
		}
		void dump() const {
			printNode("varop1:");
			printNode(unary);
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
		virtual bool isPrint() const { return false; }
	};
	struct stmt_expr: public stmt {
		stmt_expr(expr *e) : ignored(e) { }
		~stmt_expr() { delete ignored; }
		expr* ignored;
		void emit() const {
			ignored->emit(SCRATCH);
		}
		unsigned size() const { return ignored->size(); }
		void dump() const {
			printNode("stmt_expr");
			printNode(ignored);
		}
	};
	struct stmts: public stmt {
		stmts(list_node<stmt*> *s): slist(s) { 
			tsize = 0;
			for (auto i=slist; i; i=i->cdr)
				tsize += i->car->size();
		}
		~stmts() { 
			auto i = slist;
			while (i) {
				delete i->car;
				i = i->cdr;
			}
			delete slist;
		}
		list_node<stmt*> *slist;
		unsigned tsize;
		void emit() const {
			//unsigned actualSize = current_routine->offset;
			for (auto i=slist; i; i=i->cdr) {
				i->car->emit();
				// printf("accum %u\n",current_routine->offset - actualSize);
			}
			//actualSize = current_routine->offset - actualSize;
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
		return s + (s > 61? 3 : 2);
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
					delete skipFalse;
				}
			}
			else
				placeLabel(falseBranch);
			delete falseBranch;
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
	struct stmt_for: public stmt_flow {
		stmt_for(stmt *a,expr_branch *b,stmt *c,stmt *d) : init(a), cond(b), post(c), body(d) { }
		~stmt_for() { delete init; delete cond; delete post; delete body; }
		stmt *init, *post, *body;
		expr_branch *cond;
		void emit() const {
			if (init)
				init->emit();
			label falseBranch = createLabel(), postBranch = createLabel(), top = createLabelHere();
			if (!post)
				placeLabel(postBranch);
			flow_stack.push_back(std::pair<label,label>(falseBranch,postBranch));
			if (cond)
				cond->emitBranch(falseBranch,true,body->size() + (cond?cond->size():0) > 58);
			body->emit();
			if (post) {
				placeLabel(postBranch);
				post->emit();
			}
			emitJump(top,true);
			placeLabel(falseBranch);
			flow_stack.pop_back();
			delete top;
			delete postBranch;
			delete falseBranch;
		}
		unsigned size() const {
			return (init?init->size():0) + (cond?cond->size():0) + (post?post->size():0) + body->size() + 3;
		}
		void dump() const {
			printNode("for:");
			printNode(init);
			printNode(cond);
			printNode(post);
			printNode(body);
		}
	};
	struct stmt_while: public stmt_flow {
		stmt_while(expr_branch *e,stmt *b): cond(e), body(b) { }
		~stmt_while() { delete cond; delete body; }
		expr_branch *cond;
		stmt *body;
		void emit() const {
			label falseBranch = createLabel(), top = createLabelHere();
			flow_stack.push_back(std::pair<label,label>(falseBranch,top));
			cond->emitBranch(falseBranch,true,body->size() > 58);
			body->emit();
			emitJump(top,true);
			placeLabel(falseBranch);
			flow_stack.pop_back();
			delete falseBranch;
			delete top;
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
			auto trueBranch = createLabelHere(), falseBranch = createLabel();
			flow_stack.push_back(std::pair<label,label>(falseBranch,trueBranch));
			body->emit();
			cond->emitBranch(trueBranch,false,true);
			placeLabel(falseBranch);
			flow_stack.pop_back();
			delete falseBranch;
			delete trueBranch;
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
	struct stmt_break: public stmt {
		void emit() const {
			if (!flow_stack.size())
				yyerror("break found outside of any loop");
			emitJump(flow_stack.back().first,true);
		}
		unsigned size() const { return 3; }
		void dump() const { printNode("break;"); }
	};	struct stmt_continue: public stmt {
		void emit() const {
			if (!flow_stack.size())
				yyerror("continue found outside of any loop");
			emitJump(flow_stack.back().second,true);
		}
		unsigned size() const { return 3; }
		void dump() const { printNode("continue;"); }
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
		stmt_0op(uint32_t m) : macro(m) { }
		uint32_t macro;
		void emit() const {
			switch (macro>>28) {
				case 1: emitByte(macro); break;
				case 3: emitByte(macro); emitByte(macro>>8); emitByte(macro>>16); break;
			}
		}
		unsigned size() const {
			return macro >> 28;
		}
		void dump() const {
			printNode(opcode_names[(uint8_t)macro]);
		}
		bool isReturn() const {
			return (uint8_t)macro == (uint8_t)_0op::quit || (uint8_t)macro == (uint8_t)_0op::restart;
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
		stmt_print(_0op o,bool rf,const char *s) : opcode(o), isRetFalse(rf), string(s), 
			encodedLength(encode_string(nullptr,0,string,strlen(string))) { }
		~stmt_print() { delete [] string; }
		const char *string;
		uint16_t encodedLength;
		_0op opcode;
		bool isRetFalse;
		static void modify(list_node<stmt*> *s,_0op o,bool f) {
			while (s->cdr)
				s = s->cdr;
			if (!s->car->isPrint())
				yyerror("Last element in print_ret or print_retf must be a string literal.");
			stmt_print *sp = static_cast<stmt_print*>(s->car);
			sp->opcode = o;
			sp->isRetFalse = f;
		}
		void emit() const {
			emit0op(opcode);
			current_routine->reserve(encodedLength);
			encode_string(current_routine->contents + current_routine->offset,encodedLength,string,strlen(string));
			current_routine->offset += encodedLength;
			write_gametext('H',string);
			if (isRetFalse) {
				emit0op(_0op::new_line);
				emit0op(_0op::rfalse);
			}
		}
		unsigned size() const {
			return 1 + encodedLength + isRetFalse*2;
		}
		void dump() const {
			spaces();
			printf("%s \"%s\"\n",opcode_names[(uint8_t)opcode | 0xB0],string);
		}
		bool isReturn() const {
			return opcode == _0op::print_ret || isRetFalse;
		}
		bool isPrint() const { return true; }
	};
	uint16_t emit_routine(int numLocals,stmt *body) {
		if (!current_routine)
			current_routine = relocatableBlob::create(1024,UD_HIGH);
		// printf("%d locals\n",numLocals);
		emitByte(numLocals);
		if (the_header.version < 5) {
			while (numLocals--) { 
				emitByte(0); 
				emitByte(0); 
			}
		}
		if (write_debug_info) {
			auto &r = di.routines[current_routine->index];
			r.name = current_routine->desc;
			for (auto &l: the_locals)
				r.locals.push_back(l.first);
		}
		// body->dump();
		if (!body->isReturn())
			yyerror("missing return at end of routine (or not all if paths return)");
		body->emit();
		while (current_routine->offset & ((1 << story_shift)-1))
			emitByte(0xB4 /*nop*/);
		current_routine->seal(); // arp arp
		delete body;
		return current_routine->index;
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
	uint32_t zeroOp;
	_1op oneOp;
	_2op twoOp;
	_var varOp;
}

%token ATTRIBUTE PROPERTY GLOBAL OBJECT LOCATION ROUTINE WORDBIT ACTION HAS HASNT IN HOLDS SYNONYM CONTINUE BREAK
%token BYTE_ARRAY WORD_ARRAY CALL PRINT PRINT_RET PRINT_RETF SELF SIBLING CHILD PARENT MOVE INTO CONSTANT SIZEOF ADDROF ONCE
%token ISZERO ISNONZERO HASH_IF HASH_ELSE HASH_ENDIF HASH_INCLUDE TRACE UNPARENT FOR
%token <ival> DICT ANAME PNAME LNAME GNAME INTLIT ONAME
%token <sval> STRLIT CSTRLIT SEPARATORS
%token <rval> RNAME
%token <sym> NEWSYM
%token WHILE REPEAT IF ELSE
%token LE "<=" GE ">=" EQ "==" NE "!="
// %token DEC_CHK "--<" INC_CHK "++>"
%token SAVE RESTORE SCAN_TABLE READ_CHAR RANDOM
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

%type <eval> expr pname objref primary aname arg ignorable_expr
%type <brval> bool_expr cond_expr opt_bool_expr
%type <ival> vname opt_parent opt_default opt_wordbit opt_arrow has_or_hasnt phrase dict counted_string intlit
%type <rval> routine_body pvalue rname
%type <scopeval> scope
%type <dlist> dict_list;
%type <elist> opt_call_args arg_list
%type <stval> stmt print_item opt_assign opt_assign_incr
%type <stlist> stmts print_sequence

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
	| synonym_def
	| constant_def
	| separators_def
	;

constant_def
	: CONSTANT NEWSYM '=' expr ';'
		{
			int v;
			if (!$4->isConstant(v))
				yyerror("constant directive must evaluate to compile-time constant value");
			 $2->second.token = INTLIT; 
			 $2->second.ival = v;
			 delete $4;
			 // printf("constant = %d\n",v);
			 if ($2->first == "ReleaseNumber")
			 	release_number = v;
		}
	;

separators_def
	: SEPARATORS dict_list ';'
		{
			// This is parsed manually in the first pass since we generate the dictionary
			// between passes. This just verifies it was properly terminated with a semicolon.
			delete $2;
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
	| '=' intlit	{ $$ = $2; }
	;

opt_wordbit
	:					{ $$ = 0; }
	| WORDBIT intlit	{ $$ = $2; }
	;

dict_list
	: dict dict_list	{ $$ = NEW list_node<uint16_t>($1,$2); }
	| dict				{ $$ = NEW list_node<uint16_t>($1,nullptr); }
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
	| '=' intlit		{ globals_blob->storeWord($2); }
	| '=' counted_string { globals_blob->addRelocation($2); }
	| '=' BYTE_ARRAY '(' intlit ')'	{ globals_blob->addRelocation((current_global = relocatableBlob::create($4,UD_DYNAMIC,"byte array"))->index); } opt_byte_list { current_global = nullptr; }
	| '=' WORD_ARRAY '(' intlit ')' { globals_blob->addRelocation((current_global = relocatableBlob::create($4,UD_DYNAMIC,"word array"))->index); } opt_word_list { current_global = nullptr; }
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
	: intlit	
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
	: intlit 
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
		// don't overwrite child here, it was already zeroed on
		// creation and might already have children by now.
		cdef->parent = $3;

		if ($3) {
			cdef->sibling = the_object_table[$3]->child;
			the_object_table[$3]->child = $1;
		}

		cdef->descrLen = encode_string(nullptr,0,$2,strlen($2));
		cdef->descr = NEW uint8_t[cdef->descrLen];
		encode_string(cdef->descr,cdef->descrLen,$2,strlen($2));
		write_gametext('O',$2);
		delete[] $2;
		memset(cdef->attributes,0,sizeof(cdef->attributes));
		if (expected_scope == SCOPE_OBJECT_MASK)
			cdef->attributes[0] = 0x80;
		unsigned propCount = the_header.version==3? 32 : 64;
		cdef->properties = NEW relocatableBlob*[propCount];
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
		delete [] cdef->descr;
		delete [] cdef->properties;
		cdef->finalProps = finalProps;
		cdef->propertySize = finalSize;
		self_value = 0;
	}
	;

opt_parent
	: 						{ $$ = 0; }
	| '(' ONAME ')'			{ $$ = $2; }
	| IN ONAME				{ $$ = $2; }
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
	| PRINT print_sequence ';'
		{
			open_scope();
			auto p = relocatableBlob::createProperty(2,currentProperty);
			p->addRelocation(emit_routine(0,NEW stmts($2)));
			close_scope();
			$$ = p->index;
		}
	| PRINT_RET print_sequence ';'
		{
			open_scope();
			auto p = relocatableBlob::createProperty(2,currentProperty);
			stmt_print::modify($2,_0op::print_ret,false);
			p->addRelocation(emit_routine(0,NEW stmts($2)));
			close_scope();
			$$ = p->index;
		}
	| STRLIT ';'
		{
			// string literal is just a shorthand for the address of a routine that calls print_ret with that string
			open_scope();
			auto p = relocatableBlob::createProperty(2,currentProperty);
			p->addRelocation(emit_routine(0,NEW stmt_print(_0op::print_ret,false,$1)));
			close_scope();
			$$ = p->index;
		}
	| counted_string ';' 
		{
			auto p = relocatableBlob::createProperty(2,currentProperty);
			p->addRelocation($1);
			$$ = p->index;
		}
	| intlit ';' { $$ = relocatableBlob::createInt($1,currentProperty); }
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
	| NEWSYM ';' { yyerror("unknown symbol '%s'",$1->first.c_str()); }
	;

counted_string
	: CSTRLIT
		{
			auto sv = std::string_view($1);
			auto hashValue = std::hash<std::string_view>()(sv);
			auto prev = the_counted_strings.find(hashValue);
			if (prev != the_counted_strings.end()) {
				delete[] $1;
				return prev->second;
			}
			// this is a counted string (first byte is length) in static memory, not high memory
			size_t len = strlen($1);
			if (len > 255)
				yyerror("counted string is %zu characters, cannot be more than 255",len);
			auto cs = relocatableBlob::create(len+1,UD_STATIC);
			cs->storeByte(len);
			cs->copy((uint8_t*)$1,len);
			$$ = cs->index;
			the_counted_strings[hashValue] = cs->index;
			delete[] $1;
		}
	;

routine_def
	: ROUTINE NEWSYM '[' 
		{
			open_scope(); 
			current_routine = relocatableBlob::create(1024,UD_HIGH,$2->first.c_str()); 
			$2->second.token = RNAME;
			$2->second.ival = current_routine->index;
		} 
		opt_params_list opt_locals_list ']' stmt
		{
			int cr = current_routine->index;
			the_relocations[cr]->desc = $2->first;
			if ($2->first == "main") {
				if (entry_point_index == -1) {
					if (the_relocations[cr]->contents[0])
						yyerror("main cannot declare any parameters or locals");
					entry_point_index = cr;
					// Make sure we get its real address, not packed address
					the_relocations[cr]->userData = UD_STATIC;
				}
				else
					yyerror("cannot have two routines named main");
			}
			emit_routine(next_local,$8);
			// make sure recursive references don't count for deadstripping.
			the_relocations[cr]->referenceCount = 0;
			close_scope();
		}
	;

wordbit_def
	: WORDBIT intlit dict_list ';'
		{
			for (auto it=$3; it; it = it->cdr)
				z_dict_payload(it->car) |= $2;
			delete $3;
		}
	;

action_def
	: ACTION intlit ';'
	| ACTION intlit '{' { action_bit = 32; } action_list ':' rname '}' { actions_blob->addRelocation($7); }
	;

rname
	: RNAME				{ $$ = $1; }
	| routine_body		{ $$ = $1; }
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
	: dict			{ /*z_dict_payload($1) |= action_bit;*/ actions_blob->storeWord($1); }
	| dict dict		{ /*z_dict_payload($1) |= action_bit;*/ actions_blob->storeWord($1 | 0x2000); actions_blob->storeWord($2); }
	;

dict
	: DICT	{ if (z_dict_payload($1)==255) yyerror("cannot use synonym here"); $$ = $1; }
	;

routine_body
	: '[' { open_scope(); } opt_params_list opt_locals_list ']' stmt
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
	: stmt stmts	{ if ($1->isReturn() && $2) yyerror("unreachable code"); $$ = NEW list_node<stmt*>($1,$2); }
	| stmt			{ $$ = NEW list_node<stmt*>($1,nullptr); }
	;

stmt
	: IF cond_expr stmt  				{ $$ = NEW stmt_if($2,$3,nullptr); }
	| IF cond_expr stmt ELSE stmt 	%prec IF	{ $$ = NEW stmt_if($2,$3,$5); }
	| REPEAT stmt WHILE cond_expr ';'	{ $$ = NEW stmt_repeat($2,$4); }
	| WHILE cond_expr stmt				{ $$ = NEW stmt_while($2,$3); }
	| FOR '(' opt_assign ';' opt_bool_expr ';' opt_assign_incr ')' stmt { $$ = NEW stmt_for($3,$5,$7,$9); }
	// | FOR '(' opt_init_expr ';' opt_bool_expr
	| '{' stmts '}'			{ $$ = NEW stmts($2); }
	| vname '=' expr ';'	{ $$ = NEW stmt_assign($1,expr::fold_constant($3)); }
	| vname '[' expr ']' '=' expr ';' { $$ = NEW stmt_store(_var::storeb,NEW expr_variable($1),$3,$6); }
	| vname '[' '[' expr ']' ']' '=' expr ';' { $$ = NEW stmt_store(_var::storew,NEW expr_variable($1),$4,$8); }
	| RETURN expr ';'		{ $$ = NEW stmt_return(expr::fold_constant($2)); }
	| RFALSE ';'			{ $$ = NEW stmt_return(NEW expr_literal(0)); }
	| RTRUE ';'				{ $$ = NEW stmt_return(NEW expr_literal(1)); }
	| CALL expr opt_call_args ';'	{ $$ = NEW stmt_call(NEW list_node<expr*>($2,$3));  }
	| RNAME opt_call_args ';'		{ $$ = NEW stmt_call(NEW list_node<expr*>(NEW expr_reloc($1),$2)); }
	| STMT_0OP ';'					{ $$ = NEW stmt_0op($1); }
	| STMT_1OP  expr  ';'			{ $$ = NEW stmt_1op($1,$2); }
	| STMT_2OP '(' expr ',' expr ')' ';' { $$ = NEW stmt_2op($1,$3,$5); } 
	| STMT_VAROP1 expr  ';'			{ $$ = NEW stmt_varop1($1,$2); }
	| STMT_VAROP2 '(' expr ',' expr ')'  ';'	{ $$ = NEW stmt_varop2($1,$3,$5); }
	| PRINT print_sequence ';'			{ $$ = NEW stmts($2); }
	| PRINT_RET print_sequence ';'		{ stmt_print::modify($2,_0op::print_ret,false); $$ = NEW stmts($2); }
	| PRINT_RETF print_sequence ';'		{ stmt_print::modify($2,_0op::print,true); $$ = NEW stmts($2); }
	| TRACE intlit print_sequence ';'				
		{ 
			// depending on trace_level_expr, this will dead strip in release builds.
			auto c = NEW expr_binary_branch(trace_level_expr(),_2op::test,false,NEW expr_literal($2),[](int16_t a,int16_t b)->int16_t { return (a&b)==b; });
			$$ = NEW stmt_if(c,NEW stmts($3),nullptr);
		}
	| INCR vname ';'				{ $$ = NEW stmt_1op(_1op::inc,NEW expr_literal($2)); }
	| DECR vname ';'				{ $$ = NEW stmt_1op(_1op::dec,NEW expr_literal($2)); }
	| objref GAINS aname ';' 		{ $$ = NEW stmt_2op(_2op::set_attr,$1,$3); }
	| objref LOSES aname ';'		{ $$ = NEW stmt_2op(_2op::clear_attr,$1,$3); }
	| MOVE objref INTO objref ';'	{ $$ = NEW stmt_2op(_2op::insert_obj,$2,$4); }
	| UNPARENT objref ';'			{ $$ = NEW stmt_1op(_1op::remove_obj,$2); }
	| CONTINUE ';'					{ $$ = NEW stmt_continue(); }
	| BREAK ';'						{ $$ = NEW stmt_break(); }
	| ignorable_expr ';'			{ $$ = NEW stmt_expr($1); }
	; 

opt_assign
	:					{ $$ = nullptr; }
	| vname '=' expr	{ $$ = NEW stmt_assign($1,expr::fold_constant($3)); }
	;

opt_bool_expr
	:					{ $$ = nullptr; }
	| bool_expr			{ $$ = $1; }
	;

opt_assign_incr
	: opt_assign		{ $$ = $1; }
	| INCR vname		{ $$ = NEW stmt_1op(_1op::inc,NEW expr_literal($2)); }
	| DECR vname		{ $$ = NEW stmt_1op(_1op::dec,NEW expr_literal($2)); }
	;

print_sequence
	: print_item ',' print_sequence		{ $$ = NEW list_node<stmt*>($1,$3); }
	| print_item						{ $$ = NEW list_node<stmt*>($1,nullptr); }
	;

print_item
	: primary { $$ = NEW stmt_varop1(_var::print_num,$1); }
	| '(' expr ')' { $$ = NEW stmt_varop1(_var::print_num,$2); }
	| RNAME '(' arg_list ')' { $$ = NEW stmt_call(NEW list_node<expr*>(NEW expr_reloc($1),$3)) }
	| OBJECT expr { $$ = NEW stmt_1op(_1op::print_obj,$2); }
	| STMT_0OP { $$ = NEW stmt_0op($1); }
	| STRLIT { $$ = NEW stmt_print(_0op::print,false,$1); }
	| RFALSE { $$ = NEW stmt_return(NEW expr_literal(0)); }
	| RTRUE { $$ = NEW stmt_return(NEW expr_literal(1)); }
	| RETURN expr { $$ = NEW stmt_return($2); }
	;
	
cond_expr
	: '(' bool_expr ')' { $$ = $2; }
	;

opt_call_args
	: STRLIT			{ $$ = NEW list_node<expr*>(NEW expr_literal(encode_string($1)),nullptr); delete[] $1; }
	| '(' ')'			{ $$ = nullptr; }
	| '(' arg_list ')'	{ $$ = $2; }
	;

arg_list
	: arg ',' arg_list	{ $$ = NEW list_node<expr*>($1,$3); }
	| arg				{ $$ = NEW list_node<expr*>($1,nullptr); }
	;

arg
	: expr				{ $$ = $1; }
	;

intlit
	: INTLIT			{ $$ = $1; }
	| '-' INTLIT		{ $$ = -$2; }
	;

expr
	: expr '+' expr 	{ $$ = expr::fold_constant(NEW expr_binary($1,_2op::add,$3,[](int16_t a,int16_t b)->int16_t{return a+b;})); }
	| expr '-' expr 	{ $$ = expr::fold_constant(NEW expr_binary($1,_2op::sub,$3,[](int16_t a,int16_t b)->int16_t{return a-b;})); }
	| expr '*' expr 	{ $$ = expr::fold_constant(NEW expr_binary($1,_2op::mul,$3,[](int16_t a,int16_t b)->int16_t{return a*b;})); }
	| expr '/' expr 	{ $$ = expr::fold_constant(NEW expr_binary($1,_2op::div,$3,[](int16_t a,int16_t b)->int16_t{if (!b) yyerror("division by zero"); return a/b;})); }
	| expr '%' expr 	{ $$ = expr::fold_constant(NEW expr_binary($1,_2op::mod,$3,[](int16_t a,int16_t b)->int16_t{if (!b) yyerror("modulo by zero"); return a%b;})); }
	| '~' expr      	{ $$ = NEW expr_unary(_1op::not_call_1n,$2); }
//	| '-' expr %prec NEGATE { $$ = $$ = expr::fold_constant(NEW expr_binary(NEW expr_literal(0),_2op::sub,$2,[](int16_t a,int16_t b)->int16_t{return a-b;})); }
	| expr '&' expr 	{ $$ = expr::fold_constant(NEW expr_binary($1,_2op::and_,$3,[](int16_t a,int16_t b)->int16_t{return a&b;})); }
	| expr '|' expr 	{ $$ = expr::fold_constant(NEW expr_binary($1,_2op::or_,$3,[](int16_t a,int16_t b)->int16_t{return a|b;})); }
	| expr LSH expr		{ $$ = NEW expr_binary_log_shift($1,$3); }
	| expr RSH expr		{ $$ = NEW expr_binary_log_shift($1,NEW expr_binary(NEW expr_literal(0),_2op::sub,$3)); }
	| ADDROF '(' objref '.' pname ')' { $$ = NEW expr_binary($3,_2op::get_prop_addr,$5); }
	| SIZEOF '(' expr ')' { $$ = NEW expr_unary(_1op::get_prop_len,$3); }
	| '(' expr ')'  	{ $$ = expr::fold_constant($2); }
	| primary       	{ $$ = $1; }
	| intlit        	{ $$ = NEW expr_literal($1); }
	| dict				{ $$ = NEW expr_literal($1); }
	| PNAME				{ $$ = NEW expr_literal($1 & 63); }
	| RNAME opt_call_args { $$ = NEW expr_call(NEW list_node<expr*>(NEW expr_reloc($1),$2)); }
	| CALL expr opt_call_args { $$ = NEW expr_call(NEW list_node<expr*>($2,$3)); }
	| ignorable_expr	{ $$ = $1; }
	;

ignorable_expr
	: READ_CHAR 			{ $$ = NEW expr_varop1(_var::read_char,NEW expr_literal(1)); }
	| RANDOM '(' expr ')'	{ $$ = NEW expr_varop1(_var::random,$3); }
	;

bool_expr
	: expr '<' expr		{ $$ = NEW expr_binary_branch($1,_2op::jl,false,$3,[](int16_t a,int16_t b)->int16_t{return a<b;}); }
	| expr LE expr		{ $$ = NEW expr_binary_branch($1,_2op::jg,true,$3,[](int16_t a,int16_t b)->int16_t{return a<=b;}); }
	| expr '>' expr		{ $$ = NEW expr_binary_branch($1,_2op::jg,false,$3,[](int16_t a,int16_t b)->int16_t{return a>b;}); }
	| expr GE expr		{ $$ = NEW expr_binary_branch($1,_2op::jl,true,$3,[](int16_t a,int16_t b)->int16_t{return a>=b;}); }
	| expr EQ expr		
		{ 
			if ($3->isZero()) { 
				$$ = NEW expr_unary_branch(_1op::jz,false,$1);
				delete $3;
			}
			else 
				$$ = NEW expr_binary_branch($1,_2op::je,false,$3,[](int16_t a,int16_t b)->int16_t{return a==b;}); 
		}
	| expr NE expr		
		{ 
			if ($3->isZero()) {
				$$ = NEW expr_unary_branch(_1op::jz,true,$1);
				delete $3;
			}
			else
				$$ = NEW expr_binary_branch($1,_2op::je,true,$3,[](int16_t a,int16_t b)->int16_t{return a!=b;}); 
		}
	| ISZERO expr		{ $$ = NEW expr_unary_branch(_1op::jz,false,$2); }
	| ISNONZERO expr	{ $$ = NEW expr_unary_branch(_1op::jz,true,$2); }
	| expr '&' '=' expr { $$ = NEW expr_binary_branch($1,_2op::test,false,$4,[](int16_t a,int16_t b)->int16_t { return (a&b)==b; }); }
	| expr IN '{' expr '}'	{ $$ = NEW expr_in($1,$4); }
	| expr IN '{' expr ',' expr '}' { $$ = NEW expr_in($1,$4,$6); }
	| expr IN '{' expr ',' expr ',' expr '}' { $$ = NEW expr_in($1,$4,$6,$8); }
	| NOT bool_expr		{ $$ = NEW expr_logical_not($2); }
	| bool_expr AND bool_expr		{ $$ = NEW expr_logical_and($1,$3); }
	| bool_expr OR bool_expr		{ $$ = NEW expr_logical_or($1,$3); }
	| objref has_or_hasnt aname	{ $$ = NEW expr_binary_branch($1,_2op::test_attr,$2,$3); }
	| objref has_or_hasnt CHILD opt_arrow { $$ = NEW expr_unary_branch_store(_1op::get_child,$2,$1,$4); }
	| objref has_or_hasnt SIBLING opt_arrow { $$ = NEW expr_unary_branch_store(_1op::get_sibling,$2,$1,$4); }
	| objref HOLDS objref 	{ $$ = NEW expr_binary_branch($3,_2op::jin,false,$1); }
	| ONCE vname		{ $$ = NEW expr_binary_branch(NEW expr_literal($2),_2op::inc_chk,true,NEW expr_literal(1)); }
	| SAVE				{ $$ = NEW expr_saveRestore(_0op::save); }
	| RESTORE			{ $$ = NEW expr_saveRestore(_0op::restore); }
	| SCAN_TABLE '(' expr ',' expr ',' expr ')' ARROW vname { $$ = NEW expr_scan_table_branch_store($3,$5,$7,nullptr,$10); }
	| SCAN_TABLE '(' expr ',' expr ',' expr ',' expr ')' ARROW vname { $$ = NEW expr_scan_table_branch_store($3,$5,$7,$9,$12); }
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
	: PNAME			{ $$ = NEW expr_literal($1 & 63); }
	| vname			{ $$ = NEW expr_variable($1); }
	;

primary
	: objref						{ $$ = $1; }
	| primary '[' expr ']'			{ $$ = NEW expr_binary($1,_2op::loadb,$3); }
	| primary '[' '[' expr ']' ']'	{ $$ = NEW expr_binary($1,_2op::loadw,$4); }
	;

objref
	: ONAME			{ $$ = NEW expr_literal($1); }
	| SELF			{ $$ = NEW expr_literal(self_value); }
	| vname			{ $$ = NEW expr_variable($1); }
	| objref '.' pname	{ $$ = NEW expr_binary($1,_2op::get_prop,$3); }
	| objref PARENT { $$ = NEW expr_unary(_1op::get_parent,$1); }
	| objref CHILD 	{ $$ = NEW expr_unary(_1op::get_child,$1); }
	| objref SIBLING { $$ = NEW expr_unary(_1op::get_sibling,$1); }
	;

aname
	: ANAME			{ $$ = NEW expr_literal($1 & 63); }
	| vname			{ $$ = NEW expr_variable($1); }
	;

vname
	: LNAME			{ $$ = $1 + 1; }
	| GNAME			{ if ($1 == SCRATCH) yyerror("cannot refer to scratch variable here"); $$ = $1 + 16; }
	| NEWSYM		{ yyerror("unknown symbol '%s'",$1->first.c_str()); $$ = SCRATCH + 16; }
	;

%%

std::map<std::string,int16_t> rw;
std::map<std::string,uint32_t> f_0op;
std::map<std::string,_1op> f_1op;
std::map<std::string,_2op> f_2op;
std::map<std::string,_var> f_varop1;
std::map<std::string,_var> f_varop2;


static uint8_t s_EncodedCharacters[256], s_ZCost[256];

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
		else if (ch>=1 && ch<=3) {
			const char *s = abbreviations[((ch-1)<<5) | readCode()];
			while (*s)
				pr(*s++);
		}
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
				pr(13);
			else
				pr(alphabet[(ch-6)+shift]);
			shift = 0;
		}
	}
	return src;
}

const unsigned maxString = 512;
static char captured_string[maxString];
static uint8_t captured_string_length;
static void capture_string(char ch) {
	captured_string[captured_string_length++] = ch;
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

	// If we have abbreviations, do an optimal parse (Wagner, 1973) for them.
	// The paper is cryptic but Henrik Åsman explained it pretty simply:
	// 1. Loop through the string and find every possible abbreviation for each position in the string.
	// 2. Loop backwards through the string and calculate the cost from the current position to the end of the string 
	//    for each possible abbreviation at that position. Choose the abbreviation the yields the lowest cost.
	uint32_t *abbrevs = nullptr;
	if (!forDict && abbreviation_count) {
		int totalCount = 0;
		abbrevs = (uint32_t*) alloca(srcSize * 4);
		for (size_t i=0; i<srcSize-1; i++) {
			abbrevs[i] = 0;
			uint8_t j = abbreviations_lut[src[i]];
			while (j != 255) {
				if (!strncmp(abbreviations[j],src+i,abbreviation_lengths[j]) && (abbrevs[i] & 7) != 4)
					++totalCount, abbrevs[i] = ((abbrevs[i] & ~0x7U) << 7) | (j << 3) | ((abbrevs[i]&7)+1);
				j = abbreviations_next[j];
			}
		}
		abbrevs[srcSize-1] = 0;
		if (totalCount) {
			// Cost array has one extra slot, always zero, to simplify logic.
			uint16_t *costsFromHere = (uint16_t*)alloca((srcSize+1)*2);
			costsFromHere[srcSize] = 0;
			for (size_t i=srcSize; i--;) {
				costsFromHere[i] = s_ZCost[src[i]] + costsFromHere[i+1];
				if (abbrevs[i]) {
					int thisCount = abbrevs[i] & 7, best = -1;
					uint32_t a = abbrevs[i] >> 3;
					while (thisCount--) {
						uint16_t costWithPattern = 2 + costsFromHere[i + abbreviation_lengths[a & 127]];
						if (costWithPattern < costsFromHere[i]) {
							best = a & 127;
							costsFromHere[i] = costWithPattern;
						}
						a>>=7;
					}
					if (best == -1)
						abbrevs[i] = 0;
					else // store length to save extra lookup and ensure value isn't zero
						abbrevs[i] = best | (abbreviation_lengths[best] << 10);
				}
			}
		}
		else
			abbrevs = nullptr;
	}
	for (size_t i=0; i<srcSize && (!destSize || offset < destSize);) {
		if (abbrevs && abbrevs[i]) {
			storeCode(((abbrevs[i] >> 5)+1) & 31);
			storeCode(abbrevs[i] & 31);
			i += abbrevs[i]>>10;
		}
		else {
			uint8_t code = s_EncodedCharacters[src[i]];
			if (code == 255) {
				storeCode(5);
				storeCode(6);
				storeCode(src[i]>>5);
				storeCode(src[i]&31);
			}
			else {
				if (code > 31)
					storeCode(code >> 5);
				storeCode(code & 31);
			}
			++i;
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

	// test that it worked perfectly
	if (dest && !forDict) {
		captured_string_length = 0;
		print_encoded_string(dest,capture_string);
		captured_string[captured_string_length] = 0;
		if (strcmp(captured_string,src)) {
			printf("encode_string failed.\n");
			printf("input [%s]\n",src);
			printf("output [%s]\n",captured_string);
		}
	}

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
	rw["for"] = FOR;
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
	rw["scan_table"] = SCAN_TABLE;
	rw["sibling"] = SIBLING;
	rw["parent"] = PARENT;
	rw["child"] = CHILD;
	rw["print"] = PRINT;
	rw["print_ret"] = PRINT_RET;
	rw["print_retf"] = PRINT_RETF;
	rw["trace"] = TRACE;
	rw["self"] = SELF;
	rw["move"] = MOVE;
	rw["unparent"] = UNPARENT;
	rw["into"] = INTO;
	rw["sizeof"] = SIZEOF;
	rw["addrof"] = ADDROF;
	rw["continue"] = CONTINUE;
	rw["break"] = BREAK;
	rw["once"] = ONCE;
	rw["isz"] = ISZERO;
	rw["iszero"] = ISZERO;
	rw["isfalse"] = ISZERO;
	rw["isnz"] = ISNONZERO;
	rw["isnonzero"] = ISNONZERO;
	rw["istruth"] = ISNONZERO;
	rw["#if"] = HASH_IF;
	rw["#else"] = HASH_ELSE;
	rw["#endif"] = HASH_ENDIF;
	rw["#include"] = HASH_INCLUDE;
	rw["separators"] = SEPARATORS;
	rw["read_char"] = READ_CHAR;
	rw["random"] = RANDOM;

#define MACRO1(b)		(0x10000000 | uint8_t(b))
#define MACRO3(b,t,v)	(0x30000000 | (uint8_t(b)|((t)<<8)|((v)<<16)))

	f_0op["restart"] = MACRO1(_0op::restart);
	f_0op["quit"] = MACRO1(_0op::quit);
	f_0op["crlf"] = MACRO1(_0op::new_line);
	f_0op["show_status"] = MACRO1(_0op::show_status);

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

		f_0op["normal"] = MACRO3(_var::set_text_style,0x7F,0);
		f_0op["reverse"] = MACRO3(_var::set_text_style,0x7F,1);
		f_0op["italic"] = MACRO3(_var::set_text_style,0x7F,2);
		f_0op["bold"] = MACRO3(_var::set_text_style,0x7F,4);
		f_0op["fixed"] = MACRO3(_var::set_text_style,0x7F,8);
	}
	else {
		f_0op["normal"] = 0;
		f_0op["reverse"] = 0;
		f_0op["italic"] = 0;
		f_0op["bold"] = 0;
		f_0op["fixed"] = 0;
	}

	if (version >= 5) {
		f_2op["set_color"] = _2op::set_colour;
		f_2op["set_colour"] = _2op::set_colour;
	}

	// build the forward mapping
	const char *alphabet = DEFAULT_ZSCII_ALPHABET;
	memset(s_EncodedCharacters,0xFF,sizeof(s_EncodedCharacters));
	memset(s_ZCost,4,sizeof(s_ZCost));
	for (uint32_t i=0; i<26; i++) {
		s_EncodedCharacters[alphabet[i]] = (i + 6);
		s_ZCost[alphabet[i]] = 1;
		s_EncodedCharacters[alphabet[i+26]] = (4<<5) | (i + 6);
		s_ZCost[alphabet[i+26]] = 2;
	}
	for (uint32_t i=2; i<26; i++) {
		s_EncodedCharacters[alphabet[i+52]] = (5<<5) | (i + 6);
		s_ZCost[alphabet[i+52]] = 2;
	}
	s_EncodedCharacters[32] = 0;
	s_ZCost[32] = 1;
	s_EncodedCharacters[13] = (5 << 5) | 7;
	s_ZCost[13] = 2;
	// 1,2,3=abbreviations, 4=shift1, 5=shift2
	memset(abbreviations_lut,255,sizeof(abbreviations_lut));
	memset(abbreviations_next,255,sizeof(abbreviations_next));

	the_object_table.push_back(nullptr);	// object zero doesn't exist

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
	the_globals["$v4"] = { INTLIT, int16_t(version >= 4) };
	the_globals["$v5"] = { INTLIT, int16_t(version >= 5) };
	the_globals["$v8"] = { INTLIT, int16_t(version >= 8) };
}

int encode_string(const char *src) {
	size_t srcLen = strlen(src);
	uint16_t bytes = encode_string(nullptr,0,src,srcLen);
	uint8_t *dest = NEW uint8_t[bytes];
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
	emitByte((uint8_t)opcode);
	emitByte((uint8_t(op1.type) << 6) | 0x3F);
	emitOperand(op1);
}

void emitvarop(_var opcode,operand op1,operand op2) {
	emitByte((uint8_t)opcode);
	emitByte((uint8_t(op1.type) << 6) | (uint8_t(op2.type) << 4) | 0xF);
	emitOperand(op1);
	emitOperand(op2);
}

void emitvarop(_var opcode,operand op1,operand op2,operand op3) {
	emitByte((uint8_t)opcode);
	emitByte((uint8_t(op1.type) << 6) | (uint8_t(op2.type) << 4) | (uint8_t(op3.type) << 2) | 0x3);
	emitOperand(op1);
	emitOperand(op2);
	emitOperand(op3);
}

void emitvarop(_var opcode,operand op1,operand op2,operand op3,operand op4) {
	emitByte((uint8_t)opcode);
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

void emitvarop(_var opcode,operand op[8]) {
	emitByte((uint8_t)opcode);
	emitByte((uint8_t(op[0].type) << 6) | (uint8_t(op[1].type) << 4) | (uint8_t(op[2].type) << 2) | uint8_t(op[3].type));
	emitByte((uint8_t(op[4].type) << 6) | (uint8_t(op[5].type) << 4) | (uint8_t(op[6].type) << 2) | uint8_t(op[7].type));
	for (int i=0; i<8; i++)
		emitOperand(op[i]);
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
			pc++, printf("%06x jump %zx [%02x %02x]\n",offs,addr + pc - base + pc[-1] - 2,pc[-2],pc[-1]);
		else if (insn==LONG_JUMP)
			pc+=2, printf("%06x jump %zx [%02x %02x %02x]\n",offs,addr + pc - base + int16_t((pc[-2] << 8) | pc[-1]) - 2,
				pc[-3],pc[-2],pc[-1]);
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

struct yyfilestate {
	char filename[64];
	FILE *input;
	int line;
} yyfilestack[8];
int yyfilestackCount;
int yych, yylen, yypass, yyline, yyscope;
char yytoken[32], yyfilename[64];
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
		auto l = the_locals.find(yytoken);
		if (l != the_locals.end()) {
			yylval.ival = l->second.ival;
			return LNAME;
		}
		// finally search globals
		auto s = the_globals.find(yytoken);
		if (s != the_globals.end()) {
			yylval.ival = s->second.ival;
			return s->second.token;
		}
		// otherwise it's a NEW symbol (do no actual work on first pass)
		if (yypass==1)
			return NEWSYM;
		else {
			if (next_local != -1)
				yylval.sym = &*the_locals.insert(std::pair<std::string,symbol>(yytoken,{INTLIT,0})).first;
			else
				yylval.sym = &*the_globals.insert(std::pair<std::string,symbol>(yytoken,{INTLIT,0})).first;
			return NEWSYM;
		}
	}
	else switch(yych) {
		case '-':
			yynext();
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
			break;
		case '0': case '1': case '2': case '3': case '4':
		case '5': case '6': case '7': case '8': case '9': {
			int base = 10;
			int value = 0;
			do {
				if (yylen==1 && yych=='b')
					base=2;
				else if (yylen==1 && yych=='x')
					base=16;
				else {
					int digit = yych;
					if (digit>='A' && digit<='F')
						digit -= 'A' - 10;
					else if (digit>='a' && digit<='f')
						digit -= 'a' - 10;
					else if (digit>='0' && digit<='9')
						digit -= '0';
					if (digit < 0 || digit >= base)
						break;
					value = value * base + digit;
				}
				yytoken[yylen++] = yych;
				yynext();
			} while (yylen<sizeof(yytoken)-1);
			yytoken[yylen] = 0;
			if (yytoken[0]=='-')
				value = -value;
			yylval.ival = value;
			return INTLIT;
		}
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
			// turn a space into a NEW dict word
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
		case '`':
		case '"': {
			char sval[maxString];
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
					else if (yych=='~')
						yych='"';
					sval[offset++] = yych;
				}
				else
					yyerror("String too long, would be truncated");
			}
			yynext();
			sval[offset++] = 0;
			if (yypass==1)
				yylval.sval = nullptr;
			else
				memcpy((char*)(yylval.sval = NEW char[offset]), sval, offset);
			return term=='`'? CSTRLIT : STRLIT;
		}
		default:
			yyerror("unknown character %c in input",yych);
			[[fallthrough]];
		case EOF:
			return EOF;
	}
}

// preprocessing starts active
unsigned yyhashstate = 1;

int yylex() {
RESTART:
	int token = yylex_();
	if (token == EOF && yyfilestackCount) {
		auto &st = yyfilestack[--yyfilestackCount];
		fclose(yyinput);
		yyline = st.line;
		yyinput = st.input;
		strlcpy(yyfilename, st.filename, sizeof(yyfilename));
		yych = 32;
		goto RESTART;
	}
	if (token == HASH_IF) {
		bool negated = false;
		token = yylex_();
		if (token == NOT) {
			token = yylex_();
			negated = true;
		}
		if (token == NEWSYM)
			yylval.ival = 0;
		else if (token != INTLIT)
			yyerror("Expected symbol or integer after #if, got %s",yytoken);
		if (negated)
			yylval.ival = !yylval.ival;
		// if we were active before, we won't change state
		if (yyhashstate & 1)
			yyhashstate = (yyhashstate << 1) | (yylval.ival != 0);
		else
			yyhashstate <<= 1;
		goto RESTART;
	}
	else if (token == HASH_ELSE) {
		if (yyhashstate == 1)
			yyerror("#else without any #if");
		else if (yyhashstate & 2)
			yyhashstate ^= 1;
		goto RESTART;
	}
	else if (token == HASH_ENDIF) {
		if (yyhashstate==1)
			yyerror("#endif without any #if");
		yyhashstate >>= 1;
		goto RESTART;
	}
	// Note that dictionary words are still added if in inactive blocks.
	if (!(yyhashstate & 1))
		goto RESTART;
	if (token == HASH_INCLUDE) {
		int oldpass = yypass;
		yypass = 2;
		if (yylex() != STRLIT)
			yyerror("Expected quoted string after #include");
		yypass = oldpass;
		FILE *f = fopen(yylval.sval,"r");
		if (!f)
			yyerror("Unable to open include file '%s'",yylval.sval);
		auto &st = yyfilestack[yyfilestackCount++];
		strlcpy(st.filename,yyfilename,sizeof(st.filename));
		strlcpy(yyfilename,yylval.sval,sizeof(yyfilename));
		delete[] yylval.sval;
		st.line = yyline;
		st.input = yyinput;
		yyinput = f;
		yyline = 1;
		yych = 32;
		goto RESTART;
	}
#if YYDEBUG
	if (yydebug) {
		printf("(%d)",yyscope);
		if (token==EOF)
			printf("[[EOF]]\n");
		else if (token < 255)
			printf("%u:[%c][%d]\n",yyline,token,token);
		else
			printf("%u:[%s][%s][%d]\n",yyline,yytoken,yytname[token - 255],token);
	}
#endif
	return token;
}

void yyerror(const char *fmt,...) {
	va_list args;
	va_start(args,fmt);
	fprintf(stderr,"(%s,%d): ",yyfilename,yyline);
	vfprintf(stderr,fmt,args);
	putc('\n',stderr);
	va_end(args);
	exit(1);
}

char the_separators[8];
int separator_count;

int main(int argc,char **argv) {

	/* uint8_t dest[6];
	encode_string(dest,6,"Test",4);
	printf("%x %x %x %x %x %x\n",dest[0],dest[1],dest[2],dest[3],dest[4],dest[5]);
	print_encoded_string(dest,[](char ch){putchar(ch);});
	putchar('\n');
	return 1; */

	int zversion = 3;
	enum { R_OBJECTS=1,R_ROUTINES=2,R_GLOBALS=4,R_DICTIONARY=8,R_ACTIONS=16,R_SUMMARY=32,R_STRINGS=64,R_ALL=127};
	int report = 0;
	const char *help = 
			"-aFILE         write Inform-style gametext file\n"
			"-AFILE         read abbreviations from supplied file (in zabbrev format)\n"
			"-DSYM[=value]  define SYM as a constant (default 1, or supplied value)\n"
			"-g             write Inform DEBF debug information file\n"
			"-r[SORGDA]     generate report to stdout; default is all, else one or more of:\n"
			"               S=summary O=objects R=routines G=globals D=dictionary A=actions\n"
			"-RNUM          set release number in header to NUM\n"
#if YYDEBUG
			"-y             enable grammar debugging (for weird syntax errors)\n"
#endif
			"-zVER          set Z-machine version, one of 3/4/5/8\n\n"
			"output file is based on input file with extension changed to .z3/4/5/8.\n"
			"debug file is output file with .dbg tacked on to end";

	while (--argc && **++argv=='-') {
		char *arg = *argv + 1;
		switch(*arg++) {
			case 'h':
				puts(help);
#if YYDEBUG
			case 'y': yydebug = 1; break;
#endif
			case 'a': {
				gametext = fopen(arg,"w");
				if (!gametext)
					yyerror("unable to create gametext '%s'",arg);
				fprintf(gametext,"I: generated by tinyz\n");
				break;
			}
			case 'i':
				gametext_inform = true;
				break;
			case 'A': {
				FILE *a = fopen(arg,"r");
				if (!a)
					yyerror("unable to load abbreviations file '%s'",arg);
				char buf[256];
				int line = 0;
				while (fgets(buf,sizeof(buf),a)) {
					++line;
					if (strncmp(buf,"Abbreviate \"",12))
						continue;
					char *start = buf + 12;
					char *end = strrchr(buf,'"');
					if (end<start)
						continue;
					*end = 0;
					size_t sl = end - start;
					if (sl<2)
						continue;
					while (end-- > start)
						if (*end=='^') *end=13;
						else if (*end=='~') *end='"';
					abbreviations[abbreviation_count] = strcpy(NEW char[sl+1],start);
					abbreviation_lengths[abbreviation_count++] = sl;
				}
				fclose(a);
				break;
			}
			case 'D': {
				char *eq = strchr(arg,'=');
				int16_t value = 1;
				if (eq)
					value = atoi(eq+1);
				the_globals[arg] = { INTLIT,value };
				break;
			}
			case 'r':  if (*arg) while (*arg) switch (*arg++) {
				case 'S': report |= R_SUMMARY; break;
				case 'C': report |= R_STRINGS; break;
				case 'O': report |= R_OBJECTS; break;
				case 'R': report |= R_ROUTINES; break;
				case 'G': report |= R_GLOBALS; break;
				case 'D': report |= R_DICTIONARY; break;
				case 'A': report |= R_ACTIONS; break;
				} else report = R_ALL;
				break;
			case 'z': zversion = (argv[0][2]-'0'); break;
			case 'g': write_debug_info = true; break;
		}
	}
	if (!argc)
		yyerror("missing input tz name; use -h for help");
	if (write_debug_info)
		di.files[1] = argv[0];
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
	char dbgname[68];
	strlcpy(dbgname,outname,sizeof(dbgname));
	strlcat(dbgname,".dbg",sizeof(dbgname));

	// printf("compiling release %d\n",release_number);

	for (yypass=1; yypass<=2; yypass++) {
		yyinput = fopen(argv[0],"r");
		strlcpy(yyfilename,argv[0],sizeof(yyfilename));
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
							the_object_table.push_back(NEW object {});
						}
					}
					else if (t == ACTION) {
						if (yylex() == NEWSYM) {
							if (yytoken[0]!='#')
								yyerror("action symbols must start with #");
							the_globals[yytoken] = { INTLIT,(int16_t)++action_count };
						}
					}
					else if (t == GLOBAL) {
						if (yylex() == NEWSYM) {
							if (next_global==238)
								yyerror("cannot have more than 238 globals");
							the_globals[yytoken] = { GNAME,next_global++ };
						}
					}
					else if (t == SEPARATORS) {
						while (yylex() == DICT) {
							if (yylen != 1)
								yyerror("separator must be a single character");
							else if (separator_count==sizeof(the_separators))
								yyerror("too many separators");
							else if (memchr(the_separators,yytoken[0],separator_count))
								yyerror("duplicate separator in list");
							else
								the_separators[separator_count++] = yytoken[0];
						}
					}
				}
			}
			if (!separator_count && the_dictionary.size())
				yyerror("need at least one separators statement");
			if (report & R_SUMMARY) 
				printf("%zu words in dictionary (%u separators)\n",the_dictionary.size(),separator_count);
			// build the final dictionary, assigning word indices.
			dictionary_blob = relocatableBlob::create(separator_count + 4 + the_dictionary.size() * (dict_entry_size+dict_payload_size),UD_STATIC,"dictionary");
			dictionary_blob->storeByte(separator_count);
			for (int i=0; i<separator_count; i++)
				dictionary_blob->storeByte(the_separators[i]);
			dictionary_blob->storeByte(dict_entry_size+dict_payload_size);
			dictionary_blob->storeWord(the_dictionary.size());
			uint16_t idx = 0;
			for (auto &d: the_dictionary) {
#if YYDEBUG
				if (yydebug) {
					printf("word %u: [",idx);
					print_encoded_string(d.first.encoded,[](char ch){putchar(ch);});
					printf("]\n");
				}
#endif
				d.second = idx++;
				dictionary_blob->copy(d.first.encoded,dict_entry_size);
				dictionary_blob->storeByte(0);
			}
			the_globals["$actions"] = { GNAME, int16_t(next_global++) };
			the_globals["$synonyms"] = { GNAME, int16_t(next_global++) };

			globals_blob = relocatableBlob::create(next_global * 2,UD_DYNAMIC,"globals");
			actions_blob = relocatableBlob::create(action_count << 4,UD_STATIC,"actions");
			synonyms_blob = relocatableBlob::create(256,UD_STATIC,"synonyms");
			if (the_header.version > 3)
				synonyms_blob->storeWord(0); // table size
			if (report & R_SUMMARY) {
				printf("%u globals\n",next_global);
				printf("%zu objects\n",the_object_table.size()-1);
				printf("%u actions\n",action_count);
			}
			the_globals["$object_count"] = { INTLIT, int16_t(the_object_table.size() - 1) };
			the_globals["$dict_word_count"] = { INTLIT, int16_t(the_dictionary.size()) };
			header_blob = relocatableBlob::create(64,UD_DYNAMIC,"story header");

			if (abbreviation_count) {
				abbreviations_blob = relocatableBlob::create(abbreviation_count * 2,UD_STATIC,"abbreviation table");
				// temporarily reset abbreviation_count so encode_string doesn't find abbreviations
				// while trying to encode them.
				uint8_t ac = abbreviation_count;
				abbreviation_count = 0;
				for (int i=0; i<ac; i++) {
					uint16_t len = encode_string(nullptr,0,abbreviations[i],abbreviation_lengths[i]);
					auto a = relocatableBlob::create(len,UD_STATIC_ABBREVIATION,"an abbreviation");
					encode_string(a->contents,len,abbreviations[i],abbreviation_lengths[i]);
					a->offset = len;
					abbreviations_blob->addRelocation(a->index);
				}
				abbreviation_count = ac;
				// Now that all abbreviations are added, built the acceleration lut
				// Do it after we've encoded the abbreviations so we don't find the abbreviations
				// when trying to encode them!
				for (uint8_t i=0; i<abbreviation_count; i++) {
					// Use a 1D LUT to identify the first character of the abbreviation.
					// If there's more than one, they form a linked list.
					uint8_t *al = &abbreviations_lut[abbreviations[i][0]];
					while (*al != 255)
						al = &abbreviations_next[*al];
					*al = i;
				}
			}
		}
		else {
			yyparse();

			if (write_debug_info) {
				for (auto &g: the_globals) {
					if (g.second.token == GNAME)
						di.globals[g.second.ival] = g.first;
					else if (g.second.token == ANAME)
						di.attributes[g.second.ival & 63] = g.first;
					else if (g.second.token == PNAME)
						di.properties[g.second.ival & 63] = g.first;
					else if (g.second.token == ONAME)
						di.objects[g.second.ival] = g.first;
				}
				// di.dump();
			}
			actions_blob->storeWord(-1); // terminate the action list
			if (the_header.version==3)
				synonyms_blob->storeWord(-1);
			else
				synonyms_blob->storeWordAt(0,(synonyms_blob->offset - 2) >> 1); // store size of synonyms blob
			globals_blob->addRelocation(actions_blob->index);
			globals_blob->addRelocation(synonyms_blob->index);
			uint8_t objSize = the_header.version==3? 9 : 14;
			uint8_t defPropCount = the_header.version==3? 31 : 63;
			if (the_header.version==3 && the_object_table.size()>255)
				yyerror("too many objects (%d) for v3 story",the_object_table.size());
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
					delete &o;
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
					delete &o;
				}
			}

			std::vector<object*> empty;
			the_object_table.swap(empty);
			
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
			header_blob->storeWord(0); // +16 flags2
			time_t now;
			time(&now);
			auto t = localtime(&now);
			char yymmdd[7];
			snprintf(yymmdd,sizeof(yymmdd),"%02d%02d%02d",t->tm_year % 100,t->tm_mon + 1,t->tm_mday);
			header_blob->copy((uint8_t*)yymmdd,6);  // +18 ascii serial
			if (abbreviations_blob)
				header_blob->addRelocation(abbreviations_blob->index);
			else
				header_blob->storeWord(0); // +24 abbreviations
			header_blob->place();
			globals_blob->place();
			object_blob->place();
			relocatableBlob::placeAll(UD_DYNAMIC);
			// bocfel wants static start to be at least 64 + 480 + propSize bytes
			if (relocatableBlob::nextAddress < 64 + 480 + defPropCount * 2) {
				auto paddingBlob = relocatableBlob::create(64 + 480 + defPropCount * 2 - relocatableBlob::nextAddress,UD_DYNAMIC);
				printf("Dynamic memory is too small, adding %u bytes of padding\n",paddingBlob->size);
				paddingBlob->place();
			}
			relocatableBlob::placeAll(UD_STATIC);
			relocatableBlob::placeAll(UD_STATIC_ABBREVIATION);
			relocatableBlob::deadStrip();
			relocatableBlob::placeAll(UD_HIGH);

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

			if (write_debug_info)
				di.write(dbgname);

			if (report & R_ROUTINES) {
				disassemble(entry_point_index);
				for (int i=0; i<the_relocations.size(); i++) {
					if ((size_t)the_relocations[i] > 65535 && the_relocations[i]->userData == UD_HIGH &&
						the_relocations[i]->referenceCount)
						disassemble(i);
				}
			}
			if (report & R_GLOBALS) {
				for (int i=0; i<globals_blob->size; i+=2)
					printf("global %d value %04x\n",i>>1,(globals_blob->contents[i] << 8) | globals_blob->contents[i+1]);
			}
			if (report & R_STRINGS) {
				for (auto &it: the_counted_strings) {
					auto &r = the_relocations[it.second];
					printf("counted string @%06x [%*.*s]\n",r->address,r->contents[0],r->contents[0],(char*)r->contents+1);
				}
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
					uint16_t n = actions_blob->readWord(o);
					if (n != 0xFFFF) {
						for(;;) {
							print_encoded_string(d + (dict_entry_size+1) * (n & 0x1FFF),[](char ch){putchar(ch);});
							if (n & 0x2000)
								putchar('+');
							else
								putchar(32);
							if (n & 0x4000)
								printf(" (routine %06x)",actions_blob->readWord(o) << story_shift);
							if (n & 0x8000)
								break;
							n = actions_blob->readWord(o);
						}
						printf(": routine %06x\n:",actions_blob->readWord(o) << story_shift);
					}
				}
			}
			for (unsigned i=0; i<the_relocations.size(); i++)
				if ((size_t)the_relocations[i] > 65535)
					the_relocations[i]->destroy();
			the_dictionary.clear();
			the_globals.clear();
			the_locals.clear();
			std::vector<relocatableBlob*> the_relocations_empty;
			the_relocations.swap(the_relocations_empty);
			std::vector<std::pair<label,label>> flow_stack_empty;
			flow_stack.swap(flow_stack_empty);
			di.clear();
			rw.clear();
			f_0op.clear();
			f_1op.clear();
			f_2op.clear();
			f_varop1.clear();
			f_varop2.clear();
			the_counted_strings.clear();
			delete rfalseLabel;
			delete rtrueLabel;
			while (abbreviation_count)
				delete abbreviations[--abbreviation_count];
			if (gametext)
				fclose(gametext);
		}
		fclose(yyinput);

	}
#if DEBUG_MEM
	debug_leaks();
#endif
}