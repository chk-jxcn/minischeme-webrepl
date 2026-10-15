#include "wasm_libc.h"

/* MiniScheme OpCodes */
typedef enum {
    OP_HALT = 0,
    OP_CONST,
    OP_INT8,
    OP_NIL,
    OP_TRUE,
    OP_FALSE,
    OP_VOID,
    OP_GET_LOCAL,
    OP_SET_LOCAL,
    OP_GET_UPVALUE,
    OP_SET_UPVALUE,
    OP_GET_GLOBAL,
    OP_SET_GLOBAL,
    OP_DEF_GLOBAL,
    OP_POP,
    OP_JUMP,
    OP_JUMP_IF_FALSE,
    OP_CLOSURE,
    OP_CALL,
    OP_TAIL_CALL,
    OP_RETURN
} OpCode;

static const char *OP_NAMES[] = {
    "OP_HALT", "OP_CONST", "OP_INT8", "OP_NIL", "OP_TRUE", "OP_FALSE", "OP_VOID",
    "OP_GET_LOCAL", "OP_SET_LOCAL", "OP_GET_UPVALUE", "OP_SET_UPVALUE",
    "OP_GET_GLOBAL", "OP_SET_GLOBAL", "OP_DEF_GLOBAL", "OP_POP",
    "OP_JUMP", "OP_JUMP_IF_FALSE", "OP_CLOSURE", "OP_CALL", "OP_TAIL_CALL", "OP_RETURN"
};

/* AST Types */
typedef enum {
    AST_INT,
    AST_FLOAT,
    AST_BOOL,
    AST_STRING,
    AST_SYMBOL,
    AST_NIL,
    AST_PAIR
} AstType;

typedef struct AstNode {
    AstType type;
    union {
        long long int_val;
        double float_val;
        bool bool_val;
        char *str_val;
        struct {
            struct AstNode *car;
            struct AstNode *cdr;
        } pair;
    };
} AstNode;

/* Lexer / Tokenizer */
typedef enum {
    TOK_EOF,
    TOK_LPAREN,
    TOK_RPAREN,
    TOK_DOT,
    TOK_QUOTE,
    TOK_INT,
    TOK_FLOAT,
    TOK_BOOL,
    TOK_STRING,
    TOK_SYMBOL
} TokenType;

typedef struct {
    TokenType type;
    char text[256];
    long long int_val;
    double float_val;
    bool bool_val;
} Token;

typedef struct {
    const char *src;
    size_t pos;
    size_t len;
} Lexer;

static void lexer_init(Lexer *l, const char *src) {
    l->src = src;
    l->pos = 0;
    l->len = strlen(src);
}

static char lexer_peek(Lexer *l) {
    return (l->pos < l->len) ? l->src[l->pos] : '\0';
}

static char lexer_get(Lexer *l) {
    return (l->pos < l->len) ? l->src[l->pos++] : '\0';
}

static void lexer_skip_whitespace(Lexer *l) {
    while (l->pos < l->len) {
        char c = l->src[l->pos];
        if (isspace((unsigned char)c)) {
            l->pos++;
        } else if (c == ';') {
            while (l->pos < l->len && l->src[l->pos] != '\n') l->pos++;
        } else {
            break;
        }
    }
}

static bool lexer_next(Lexer *l, Token *tok) {
    lexer_skip_whitespace(l);
    if (l->pos >= l->len) {
        tok->type = TOK_EOF;
        return false;
    }
    char c = lexer_get(l);
    if (c == '(') { tok->type = TOK_LPAREN; return true; }
    if (c == ')') { tok->type = TOK_RPAREN; return true; }
    if (c == '\'') { tok->type = TOK_QUOTE; return true; }
    if (c == '.' && isspace((unsigned char)lexer_peek(l))) {
        tok->type = TOK_DOT; return true;
    }
    if (c == '"') {
        int idx = 0;
        while (l->pos < l->len) {
            char ch = lexer_get(l);
            if (ch == '"') break;
            if (ch == '\\' && l->pos < l->len) {
                char esc = lexer_get(l);
                if (esc == 'n') ch = '\n';
                else if (esc == 't') ch = '\t';
                else if (esc == 'r') ch = '\r';
                else ch = esc;
            }
            if (idx < 250) tok->text[idx++] = ch;
        }
        tok->text[idx] = '\0';
        tok->type = TOK_STRING;
        return true;
    }
    if (c == '#') {
        char next = lexer_peek(l);
        if (next == 't' || next == 'T' || next == 'f' || next == 'F') {
            lexer_get(l);
            tok->type = TOK_BOOL;
            tok->bool_val = (next == 't' || next == 'T');
            return true;
        }
        if (next == 'x' || next == 'X' || next == 'b' || next == 'B' || next == 'o' || next == 'O' || next == 'd' || next == 'D') {
            lexer_get(l);
            int radix = 10;
            if (next == 'x' || next == 'X') radix = 16;
            else if (next == 'b' || next == 'B') radix = 2;
            else if (next == 'o' || next == 'O') radix = 8;
            int idx = 0;
            while (l->pos < l->len) {
                char ch = lexer_peek(l);
                if (isspace((unsigned char)ch) || ch == '(' || ch == ')' || ch == '"' || ch == ';') break;
                if (idx < 250) tok->text[idx++] = lexer_get(l);
                else lexer_get(l);
            }
            tok->text[idx] = '\0';
            char *end = NULL;
            long long iv = strtoll(tok->text, &end, radix);
            if (end && *end == '\0' && idx > 0) {
                tok->type = TOK_INT;
                tok->int_val = iv;
                return true;
            }
        }
    }

    /* Number or Symbol */
    int idx = 0;
    tok->text[idx++] = c;
    while (l->pos < l->len) {
        char ch = lexer_peek(l);
        if (isspace((unsigned char)ch) || ch == '(' || ch == ')' || ch == '"' || ch == ';') {
            break;
        }
        if (idx < 250) tok->text[idx++] = lexer_get(l);
        else lexer_get(l);
    }
    tok->text[idx] = '\0';

    /* Check if integer or float */
    char *end = NULL;
    long long iv = strtoll(tok->text, &end, 10);
    if (end && *end == '\0' && (isdigit((unsigned char)tok->text[0]) || ((tok->text[0] == '-' || tok->text[0] == '+') && isdigit((unsigned char)tok->text[1])))) {
        tok->type = TOK_INT;
        tok->int_val = iv;
        return true;
    }
    double dv = strtod(tok->text, &end);
    if (end && *end == '\0' && (strchr(tok->text, '.') || strchr(tok->text, 'e') || strchr(tok->text, 'E'))) {
        tok->type = TOK_FLOAT;
        tok->float_val = dv;
        return true;
    }

    tok->type = TOK_SYMBOL;
    return true;
}

/* AST Construction */
static AstNode *ast_make_int(long long v) {
    AstNode *n = (AstNode *)malloc(sizeof(AstNode));
    n->type = AST_INT; n->int_val = v; return n;
}
static AstNode *ast_make_float(double v) {
    AstNode *n = (AstNode *)malloc(sizeof(AstNode));
    n->type = AST_FLOAT; n->float_val = v; return n;
}
static AstNode *ast_make_bool(bool v) {
    AstNode *n = (AstNode *)malloc(sizeof(AstNode));
    n->type = AST_BOOL; n->bool_val = v; return n;
}
static AstNode *ast_make_string(const char *s) {
    AstNode *n = (AstNode *)malloc(sizeof(AstNode));
    n->type = AST_STRING;
    size_t len = strlen(s);
    n->str_val = (char *)malloc(len + 1);
    strcpy(n->str_val, s);
    return n;
}
static AstNode *ast_make_symbol(const char *s) {
    AstNode *n = (AstNode *)malloc(sizeof(AstNode));
    n->type = AST_SYMBOL;
    size_t len = strlen(s);
    n->str_val = (char *)malloc(len + 1);
    strcpy(n->str_val, s);
    return n;
}
static AstNode *ast_make_nil(void) {
    AstNode *n = (AstNode *)malloc(sizeof(AstNode));
    n->type = AST_NIL; return n;
}
static AstNode *ast_make_pair(AstNode *car, AstNode *cdr) {
    AstNode *n = (AstNode *)malloc(sizeof(AstNode));
    n->type = AST_PAIR; n->pair.car = car; n->pair.cdr = cdr; return n;
}

/* Parser */
static AstNode *parse_expr(Lexer *l, char *err_buf);

static AstNode *parse_list(Lexer *l, char *err_buf) {
    Token tok;
    Lexer look = *l;
    if (!lexer_next(&look, &tok)) {
        strcpy(err_buf, "unexpected end of input in list");
        return NULL;
    }
    if (tok.type == TOK_RPAREN) {
        *l = look;
        return ast_make_nil();
    }
    AstNode *head = parse_expr(l, err_buf);
    if (!head) return NULL;

    look = *l;
    if (lexer_next(&look, &tok) && tok.type == TOK_DOT) {
        *l = look;
        AstNode *tail = parse_expr(l, err_buf);
        if (!tail) return NULL;
        if (!lexer_next(l, &tok) || tok.type != TOK_RPAREN) {
            strcpy(err_buf, "expected ')' after dotted tail");
            return NULL;
        }
        return ast_make_pair(head, tail);
    }
    AstNode *rest = parse_list(l, err_buf);
    if (!rest) return NULL;
    return ast_make_pair(head, rest);
}

static AstNode *parse_expr(Lexer *l, char *err_buf) {
    Token tok;
    if (!lexer_next(l, &tok)) return NULL;
    if (tok.type == TOK_INT) return ast_make_int(tok.int_val);
    if (tok.type == TOK_FLOAT) return ast_make_float(tok.float_val);
    if (tok.type == TOK_BOOL) return ast_make_bool(tok.bool_val);
    if (tok.type == TOK_STRING) return ast_make_string(tok.text);
    if (tok.type == TOK_SYMBOL) return ast_make_symbol(tok.text);
    if (tok.type == TOK_LPAREN) return parse_list(l, err_buf);
    if (tok.type == TOK_QUOTE) {
        AstNode *q = ast_make_symbol("quote");
        AstNode *sub = parse_expr(l, err_buf);
        if (!sub) return NULL;
        return ast_make_pair(q, ast_make_pair(sub, ast_make_nil()));
    }
    snprintf(err_buf, 128, "unexpected token: %s", tok.text);
    return NULL;
}

/* Bytecode Compiler Buffer */
#define MAX_CONSTS 256
#define MAX_CODE_BYTES 4096

typedef struct {
    AstType type;
    long long int_val;
    double float_val;
    bool bool_val;
    char str_val[128];
} ConstEntry;

typedef struct {
    uint8_t code[MAX_CODE_BYTES];
    size_t code_len;
    ConstEntry consts[MAX_CONSTS];
    size_t const_count;
    char disasm[8192];
    size_t disasm_len;
} Compiler;

static int add_const_symbol(Compiler *c, const char *name) {
    for (size_t i = 0; i < c->const_count; i++) {
        if (c->consts[i].type == AST_SYMBOL && strcmp(c->consts[i].str_val, name) == 0) {
            return (int)i;
        }
    }
    if (c->const_count >= MAX_CONSTS) return -1;
    int idx = (int)c->const_count++;
    c->consts[idx].type = AST_SYMBOL;
    strncpy(c->consts[idx].str_val, name, 127);
    return idx;
}

static int add_const_string(Compiler *c, const char *str) {
    for (size_t i = 0; i < c->const_count; i++) {
        if (c->consts[i].type == AST_STRING && strcmp(c->consts[i].str_val, str) == 0) {
            return (int)i;
        }
    }
    if (c->const_count >= MAX_CONSTS) return -1;
    int idx = (int)c->const_count++;
    c->consts[idx].type = AST_STRING;
    strncpy(c->consts[idx].str_val, str, 127);
    return idx;
}

static int add_const_int(Compiler *c, long long v) {
    for (size_t i = 0; i < c->const_count; i++) {
        if (c->consts[i].type == AST_INT && c->consts[i].int_val == v) {
            return (int)i;
        }
    }
    if (c->const_count >= MAX_CONSTS) return -1;
    int idx = (int)c->const_count++;
    c->consts[idx].type = AST_INT;
    c->consts[idx].int_val = v;
    return idx;
}

static int add_const_float(Compiler *c, double v) {
    if (c->const_count >= MAX_CONSTS) return -1;
    int idx = (int)c->const_count++;
    c->consts[idx].type = AST_FLOAT;
    c->consts[idx].float_val = v;
    return idx;
}

static void emit_byte(Compiler *c, uint8_t b) {
    if (c->code_len < MAX_CODE_BYTES) {
        c->code[c->code_len++] = b;
    }
}

static void emit_u16(Compiler *c, uint16_t u) {
    emit_byte(c, (uint8_t)(u & 0xff));
    emit_byte(c, (uint8_t)((u >> 8) & 0xff));
}

static void append_disasm(Compiler *c, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char buf[256];
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (c->disasm_len + n < sizeof(c->disasm) - 1) {
        memcpy(c->disasm + c->disasm_len, buf, n);
        c->disasm_len += n;
        c->disasm[c->disasm_len] = '\0';
    }
}

static bool compile_node(Compiler *c, AstNode *n, char *err_buf) {
    if (!n) return false;
    switch (n->type) {
        case AST_INT: {
            if (n->int_val >= -128 && n->int_val <= 127) {
                append_disasm(c, "%04zu: OP_INT8        %lld\n", c->code_len, n->int_val);
                emit_byte(c, OP_INT8);
                emit_byte(c, (uint8_t)(int8_t)n->int_val);
            } else {
                int idx = add_const_int(c, n->int_val);
                append_disasm(c, "%04zu: OP_CONST       #%d (%lld)\n", c->code_len, idx, n->int_val);
                emit_byte(c, OP_CONST);
                emit_u16(c, (uint16_t)idx);
            }
            return true;
        }
        case AST_FLOAT: {
            int idx = add_const_float(c, n->float_val);
            append_disasm(c, "%04zu: OP_CONST       #%d (flonum)\n", c->code_len, idx);
            emit_byte(c, OP_CONST);
            emit_u16(c, (uint16_t)idx);
            return true;
        }
        case AST_BOOL: {
            if (n->bool_val) {
                append_disasm(c, "%04zu: OP_TRUE\n", c->code_len);
                emit_byte(c, OP_TRUE);
            } else {
                append_disasm(c, "%04zu: OP_FALSE\n", c->code_len);
                emit_byte(c, OP_FALSE);
            }
            return true;
        }
        case AST_STRING: {
            int idx = add_const_string(c, n->str_val);
            append_disasm(c, "%04zu: OP_CONST       #%d (\"%s\")\n", c->code_len, idx, n->str_val);
            emit_byte(c, OP_CONST);
            emit_u16(c, (uint16_t)idx);
            return true;
        }
        case AST_SYMBOL: {
            int idx = add_const_symbol(c, n->str_val);
            append_disasm(c, "%04zu: OP_GET_GLOBAL  #%d (%s)\n", c->code_len, idx, n->str_val);
            emit_byte(c, OP_GET_GLOBAL);
            emit_u16(c, (uint16_t)idx);
            return true;
        }
        case AST_NIL: {
            append_disasm(c, "%04zu: OP_NIL\n", c->code_len);
            emit_byte(c, OP_NIL);
            return true;
        }
        case AST_PAIR: {
            AstNode *head = n->pair.car;
            if (head->type == AST_SYMBOL) {
                /* Special forms */
                if (strcmp(head->str_val, "define") == 0) {
                    AstNode *args = n->pair.cdr;
                    if (!args || args->type != AST_PAIR) {
                        strcpy(err_buf, "malformed define");
                        return false;
                    }
                    AstNode *target = args->pair.car;
                    if (target->type == AST_SYMBOL) {
                        /* (define var val) */
                        AstNode *val_node = args->pair.cdr;
                        if (!val_node || val_node->type != AST_PAIR) {
                            strcpy(err_buf, "missing define value");
                            return false;
                        }
                        if (!compile_node(c, val_node->pair.car, err_buf)) return false;
                        int sidx = add_const_symbol(c, target->str_val);
                        append_disasm(c, "%04zu: OP_DEF_GLOBAL  #%d (%s)\n", c->code_len, sidx, target->str_val);
                        emit_byte(c, OP_DEF_GLOBAL);
                        emit_u16(c, (uint16_t)sidx);
                        return true;
                    }
                }
                if (strcmp(head->str_val, "set!") == 0) {
                    AstNode *args = n->pair.cdr;
                    if (!args || args->type != AST_PAIR || args->pair.car->type != AST_SYMBOL) {
                        strcpy(err_buf, "malformed set!");
                        return false;
                    }
                    AstNode *val_node = args->pair.cdr;
                    if (!val_node || val_node->type != AST_PAIR) {
                        strcpy(err_buf, "missing set! value");
                        return false;
                    }
                    if (!compile_node(c, val_node->pair.car, err_buf)) return false;
                    int sidx = add_const_symbol(c, args->pair.car->str_val);
                    append_disasm(c, "%04zu: OP_SET_GLOBAL  #%d (%s)\n", c->code_len, sidx, args->pair.car->str_val);
                    emit_byte(c, OP_SET_GLOBAL);
                    emit_u16(c, (uint16_t)sidx);
                    return true;
                }
            }


            /* Regular function call */
            /* 1. Push callee */
            if (!compile_node(c, head, err_buf)) return false;

            /* 2. Push arguments */
            int argc = 0;
            AstNode *cur = n->pair.cdr;
            while (cur && cur->type == AST_PAIR) {
                if (!compile_node(c, cur->pair.car, err_buf)) return false;
                argc++;
                cur = cur->pair.cdr;
            }

            /* 3. Call opcode */
            append_disasm(c, "%04zu: OP_CALL        %d args\n", c->code_len, argc);
            emit_byte(c, OP_CALL);
            emit_byte(c, (uint8_t)argc);
            return true;
        }
    }
    strcpy(err_buf, "unknown ast node type");
    return false;
}

/* Binary Serializer: Packages into MSBC (MiniScheme Bytecode Chunk) */
static size_t serialize_msbc(Compiler *c, uint8_t *out_buf, size_t max_size) {
    if (max_size < 16 + c->code_len + c->const_count * 32) return 0;
    uint8_t *p = out_buf;

    /* Magic: MSBC */
    p[0] = 'M'; p[1] = 'S'; p[2] = 'B'; p[3] = 'C'; p += 4;
    /* Version 1 */
    p[0] = 1; p[1] = 0; p[2] = 0; p[3] = 0; p += 4;
    /* Code bytes length */
    uint32_t clen = (uint32_t)c->code_len;
    memcpy(p, &clen, 4); p += 4;
    /* Constants count */
    uint32_t ccount = (uint32_t)c->const_count;
    memcpy(p, &ccount, 4); p += 4;

    /* Opcodes payload */
    memcpy(p, c->code, c->code_len); p += c->code_len;

    /* Constants table */
    for (size_t i = 0; i < c->const_count; i++) {
        ConstEntry *ce = &c->consts[i];
        *p++ = (uint8_t)ce->type;
        switch (ce->type) {
            case AST_INT:
                memcpy(p, &ce->int_val, 8); p += 8;
                break;
            case AST_FLOAT:
                memcpy(p, &ce->float_val, 8); p += 8;
                break;
            case AST_BOOL:
                *p++ = ce->bool_val ? 1 : 0;
                break;
            case AST_STRING:
            case AST_SYMBOL: {
                uint16_t slen = (uint16_t)strlen(ce->str_val);
                memcpy(p, &slen, 2); p += 2;
                memcpy(p, ce->str_val, slen); p += slen;
                break;
            }
            default:
                break;
        }
    }

    return (size_t)(p - out_buf);
}

/* Exported WASM API Buffer */
static char s_json_response[16384];
static uint8_t s_msbc_binary[8192];
static size_t s_msbc_len = 0;

__attribute__((visibility("default")))
void wasm_init(void) {
    s_msbc_len = 0;
}

__attribute__((visibility("default")))
uint8_t *wasm_get_bytecode_ptr(void) {
    return s_msbc_binary;
}

__attribute__((visibility("default")))
int wasm_get_bytecode_len(void) {
    return (int)s_msbc_len;
}

__attribute__((visibility("default")))
const char *wasm_compile(const char *scm_source) {
    if (!scm_source || !*scm_source) {
        return "{\"success\":false,\"error\":\"empty input\"}";
    }

    char err_buf[128];
    err_buf[0] = '\0';

    Lexer l;
    lexer_init(&l, scm_source);

    Compiler comp;
    memset(&comp, 0, sizeof(comp));

    AstNode *ast = parse_expr(&l, err_buf);
    if (!ast) {
        snprintf(s_json_response, sizeof(s_json_response),
                 "{\"success\":false,\"error\":\"Syntax Error: %s\"}", err_buf);
        return s_json_response;
    }

    if (!compile_node(&comp, ast, err_buf)) {
        snprintf(s_json_response, sizeof(s_json_response),
                 "{\"success\":false,\"error\":\"Compile Error: %s\"}", err_buf);
        return s_json_response;
    }

    /* Terminate with OP_RETURN */
    append_disasm(&comp, "%04zu: OP_RETURN\n", comp.code_len);
    emit_byte(&comp, OP_RETURN);

    /* Serialize to MSBC */
    s_msbc_len = serialize_msbc(&comp, s_msbc_binary, sizeof(s_msbc_binary));

    /* Format Hex String */
    char hex_str[4096];
    size_t hex_idx = 0;
    for (size_t i = 0; i < s_msbc_len && hex_idx < sizeof(hex_str) - 3; i++) {
        sprintf(hex_str + hex_idx, "%02X", s_msbc_binary[i]);
        hex_idx += 2;
    }
    hex_str[hex_idx] = '\0';

    /* Escape disassembly for JSON */
    char escaped_disasm[8192];
    size_t e_idx = 0;
    for (size_t i = 0; i < comp.disasm_len && e_idx < sizeof(escaped_disasm) - 4; i++) {
        char ch = comp.disasm[i];
        if (ch == '\n') {
            escaped_disasm[e_idx++] = '\\';
            escaped_disasm[e_idx++] = 'n';
        } else if (ch == '"') {
            escaped_disasm[e_idx++] = '\\';
            escaped_disasm[e_idx++] = '"';
        } else {
            escaped_disasm[e_idx++] = ch;
        }
    }
    escaped_disasm[e_idx] = '\0';

    snprintf(s_json_response, sizeof(s_json_response),
             "{\"success\":true,\"byte_len\":%zu,\"bytecode_hex\":\"%s\",\"disasm\":\"%s\"}",
             s_msbc_len, hex_str, escaped_disasm);

    return s_json_response;
}
