#include "debug.h"

#include <stdio.h>

namespace debug {

inline void fputz(std::string &s,FILE *f) {
    fwrite(s.c_str(),1,s.length()+1,f);
}

inline void fputword(word w,FILE *f) {
    fputc(w.hi,f);
    fputc(w.lo,f);
}

inline void fskipz(FILE *f) {
    while (!feof(f) && fgetc(f))
        ;
}

inline std::string fgetz(FILE *f) {
    std::string r;
    int ch;
    while (!feof(f) && (ch=fgetc(f)))
        r.push_back(ch);
    return r;
}

word fgetword(FILE *f) {
    word w;
    w.hi = fgetc(f);
    w.lo = fgetc(f);
    return w;
}

line fgetline(FILE *f) {
    line r;
    fread(&r,sizeof(line),1,f);
    return r;
}

address fgetaddress(FILE *f) {
    address a;
    a.h = fgetc(f);
    a.m = fgetc(f);
    a.l = fgetc(f);
    return a;
}

bool debug_info::write(const char *filename) {
    FILE *f = fopen(filename, "wb");
    if (!f)
        return false;
    fputc(0xDE,f);
    fputc(0xBF,f);
    fputword(byte2word(0),f);
    fputword(byte2word(0),f);
    for (auto &i: files) {
        fputc(FILE_DBR,f);
        fputc(i.first,f);
        fputz(i.second,f);
        fputz(i.second,f);
    }
    for (auto &i: attributes) {
        fputc(ATTR_DBR,f);
        fputword(byte2word(i.first),f);
        fputz(i.second,f);
    }
    for (auto &i: properties) {
        fputc(PROP_DBR,f);
        fputword(byte2word(i.first),f);
        fputz(i.second,f);
    }
    for (auto &i: globals) {
        fputc(GLOBAL_DBR,f);
        fputc(i.first,f);
        fputz(i.second,f);
    }
    line dummy[2] = {};
    for (auto &i: objects) {
        fputc(OBJECT_DBR,f);
        fputword(word2word(i.first),f);
        fputz(i.second,f);
        fwrite(dummy,sizeof(line),2,f);
    }
    fputc(EOF_DBR,f);
    fclose(f);
    return true;
}

bool debug_info::read(const char *filename) {
    FILE *f = fopen(filename,"rb");
    if (!f)
        return false;
    if (fgetc(f) != 0xDE || fgetc(f) != 0xBF) {
        fclose(f);
        return false;
    }
    fgetword(f);
    fgetword(f);
    clear();
    uint8_t rectype;
    while (!feof(f) && (rectype=fgetc(f))!=EOF_DBR) {
        uint8_t b;
        word w;
        std::string s;
        switch(rectype) {
            case FILE_DBR: b=fgetc(f); fskipz(f); s=fgetz(f); files[b] = s; break;
            case CLASS_DBR: fskipz(f); fgetline(f); fgetline(f); break;
            case OBJECT_DBR: w=fgetword(f); s=fgetz(f); fgetline(f); fgetline(f); objects[w.getU()] = s; break;
            case GLOBAL_DBR: b=fgetc(f); s=fgetz(f); globals[b] = s; break;
            case ATTR_DBR: w=fgetword(f); s=fgetz(f); attributes[w.getU()] = s; break;
            case PROP_DBR: w=fgetword(f); s=fgetz(f); properties[w.getU()] = s; break;
            case FAKE_ACTION_DBR: fgetword(f); fskipz(f); break;
            case ACTION_DBR: fgetword(f); fskipz(f); break;
            case HEADER_DBR: fread(header,1,64,f); break;
            case LINEREF_DBR: fgetword(f); w=fgetword(f); while (w.getU()) { fgetline(f); fgetword(f); w.dec(); } break;
            case ROUTINE_DBR: fgetword(f); fgetline(f); fgetaddress(f); fskipz(f); while (!((s=fgetz(f)).empty())) {} break;
            case ARRAY_DBR: fgetword(f); fskipz(f); break;
            case MAP_DBR: while (!((s=fgetz(f)).empty())) fgetaddress(f); break;
            case ROUTINE_END_DBR: fgetword(f); fgetline(f); fgetaddress(f); break;
            default: printf("unknown record type %d\n",rectype); fclose(f); return false;
        }
    }
    fclose(f);
    printf("found %zu files, %zu objects, %zu globals, %zu attributes, %zu properties\n",
        files.size(),objects.size(),globals.size(),attributes.size(),properties.size());
    return true;
}

void debug_info::dump() {
    for (auto &i: files)
        printf("file %u named %s\n",i.first,i.second.c_str());
    for (auto &i: attributes)
        printf("attribute %u named %s\n",i.first,i.second.c_str());
    for (auto &i: properties)
        printf("property %u named %s\n",i.first,i.second.c_str());
    for (auto &i: globals)
        printf("global %u named %s\n",i.first,i.second.c_str());
    for (auto &i: objects)
        printf("object %u named %s\n",i.first,i.second.c_str());}


} // namespace debug
