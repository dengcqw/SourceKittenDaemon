//
//  fuzzyMatch.h
//  SourceKittenDaemon
//
//  Created by Deng Jinlong on 19/03/2018.
//

#ifndef fuzzyMatch_h
#define fuzzyMatch_h

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>

typedef struct TextContext
{
    char* text;
    uint16_t text_len;
    uint64_t* text_mask;
    uint16_t col_num;
    uint16_t offset;
}TextContext;

typedef struct PatternContext
{
    char* pattern;
    uint16_t pattern_len;
    int64_t pattern_mask[256];
    uint8_t is_lower;
}PatternContext;

typedef struct ValueElements
{
    float score;
    uint16_t beg;
    uint16_t end;
}ValueElements;

typedef struct HighlightPos
{
    uint16_t col;
    uint16_t len;
}HighlightPos;

typedef struct HighlightGroup
{
    float score;
    uint16_t beg;
    uint16_t end;
    HighlightPos positions[64];
    uint16_t end_index;
}HighlightGroup;


PatternContext* initPattern(char* pattern, uint16_t pattern_len);

float getWeight(char* text, uint16_t text_len,
                PatternContext* pPattern_ctxt,
                uint8_t is_name_only);


#endif /* fuzzyMatch_h */
