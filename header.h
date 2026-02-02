#include <stdint.h>

struct word {
	uint8_t hi, lo;

	uint16_t getU() const { return lo | (hi << 8); }
	int16_t  getS() const { return (int16_t)getU(); }
	uint32_t getU2() const { return getU()<<1; }
	bool notZero() const { return hi || lo; }
	bool operator==(const word &that) const { return lo==that.lo && hi==that.hi; }

	void setByte(uint8_t b) { lo = b; hi = 0; }
	void setHL(uint8_t h,uint8_t l) { hi = h; lo = l; }
	void set(int x) { setHL(x>>8,x); }
	int16_t inc() { set(getS()+1); return getS(); }
	int16_t dec() { set(getS()-1); return getS(); }
	void setZscii(uint8_t index,uint8_t ch) {
		static const uint8_t sh[] = { 10,5,0 };
		if (index==0)
			hi = (ch&31)<<2;
		else if (index==1)
			hi |= (ch>>3)&3, lo=ch<<5;
		else
			lo |= (ch&31);
	}
};

inline word byte2word(uint8_t b) {
	word w;
	w.setByte(b);
	return w;
}

inline word word2word(uint16_t x) {
	word w;
	w.set(x);
	return w;
}

struct storyHeader {
	uint8_t version; // 1-8
	uint8_t flags; // bit 1: 0=score/turns, 1=time
	word pad0;
	word highMemoryAddr;
	word initialPCAddr; // V6: packed address of "main"

	word dictionaryAddr;
	word objectTableAddr;
	word globalVarsTableAddr;
	word staticMemoryAddr;

	word flags2;
	char serial[6];

	word abbreviationsAddr;
	word storyLength; // V1-3: *2; V4-5: *4; V6/7/8: *8
	word checksum;
	uint8_t interpreterNumber;
	uint8_t interpreterVersion;

	uint8_t screenHeightLines;
	uint8_t screenWidthChars;
	word screenWidthUnits;
	word screenHeightUnits;
	uint8_t fontWidthUnits;		// these two are swapped in V6
	uint8_t fontHeightUnits;

	word routinesOffsetDiv8;	// V6
	word staticStringsOffsetDiv8;	// V6
	uint8_t defaultBackgroundColor;
	uint8_t defaultForegroundColor;
	word terminatingCharactersTablesAddr;

	word widthOfTextSentToStream3;
	word standardRevisionNumber;
	word alphabetTableAddress;
	word headerExtensionTableAddress;
};
