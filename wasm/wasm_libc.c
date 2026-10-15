#include "wasm_libc.h"

extern unsigned char __heap_base;
static uintptr_t s_heap = 0;

void *malloc(size_t sz) {
    if (!s_heap) s_heap = (uintptr_t)&__heap_base;
    sz = (sz + 7) & ~7;
    uintptr_t p = s_heap;
    s_heap += sz;
    while (s_heap > (uintptr_t)__builtin_wasm_memory_size(0) * 65536) {
        if (__builtin_wasm_memory_grow(0, 8) == (size_t)-1) {
            return NULL;
        }
    }
    return (void *)p;
}

void free(void *ptr) {
    (void)ptr;
}

void *calloc(size_t n, size_t sz) {
    size_t total = n * sz;
    void *p = malloc(total);
    if (p) memset(p, 0, total);
    return p;
}

void *realloc(void *ptr, size_t sz) {
    void *p = malloc(sz);
    if (ptr && p) memcpy(p, ptr, sz);
    return p;
}

void *memcpy(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memset(void *dst, int val, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    while (n--) *d++ = (uint8_t)val;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dst;
    const uint8_t *s = (const uint8_t *)src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n;
        s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}

int memcmp(const void *s1, const void *s2, size_t n) {
    const uint8_t *p1 = (const uint8_t *)s1;
    const uint8_t *p2 = (const uint8_t *)s2;
    while (n--) {
        if (*p1 != *p2) return *p1 - *p2;
        p1++; p2++;
    }
    return 0;
}

size_t strlen(const char *s) {
    size_t len = 0;
    while (s && s[len]) len++;
    return len;
}

char *strcpy(char *dst, const char *src) {
    char *ret = dst;
    while ((*dst++ = *src++));
    return ret;
}

char *strncpy(char *dst, const char *src, size_t n) {
    char *ret = dst;
    while (n && (*dst++ = *src++)) n--;
    while (n--) *dst++ = '\0';
    return ret;
}

int strcmp(const char *s1, const char *s2) {
    while (*s1 && (*s1 == *s2)) { s1++; s2++; }
    return *(const unsigned char *)s1 - *(const unsigned char *)s2;
}

int strncmp(const char *s1, const char *s2, size_t n) {
    while (n && *s1 && (*s1 == *s2)) { s1++; s2++; n--; }
    if (!n) return 0;
    return *(const unsigned char *)s1 - *(const unsigned char *)s2;
}

char *strchr(const char *s, int c) {
    while (*s) {
        if (*s == (char)c) return (char *)s;
        s++;
    }
    return (c == 0) ? (char *)s : NULL;
}

char *strrchr(const char *s, int c) {
    const char *last = NULL;
    do {
        if (*s == (char)c) last = s;
    } while (*s++);
    return (char *)last;
}

char *strstr(const char *haystack, const char *needle) {
    if (!*needle) return (char *)haystack;
    size_t nlen = strlen(needle);
    while (*haystack) {
        if (strncmp(haystack, needle, nlen) == 0) return (char *)haystack;
        haystack++;
    }
    return NULL;
}

char *strcat(char *dst, const char *src) {
    char *ret = dst;
    while (*dst) dst++;
    while ((*dst++ = *src++));
    return ret;
}

long long strtoll(const char *nptr, char **endptr, int base) {
    const char *s = nptr;
    while (isspace((unsigned char)*s)) s++;
    int sign = 1;
    if (*s == '-') { sign = -1; s++; }
    else if (*s == '+') { s++; }
    if (base == 0) {
        if (*s == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
        else if (*s == '0') { base = 8; }
        else base = 10;
    }
    long long res = 0;
    int digits_found = 0;
    while (*s) {
        int v = -1;
        if (isdigit((unsigned char)*s)) v = *s - '0';
        else if (*s >= 'a' && *s <= 'f') v = *s - 'a' + 10;
        else if (*s >= 'A' && *s <= 'F') v = *s - 'A' + 10;
        if (v < 0 || v >= base) break;
        res = res * base + v;
        s++;
        digits_found++;
    }
    if (digits_found == 0) {
        if (endptr) *endptr = (char *)nptr;
        return 0;
    }
    if (endptr) *endptr = (char *)s;
    return sign * res;
}

unsigned long long strtoull(const char *nptr, char **endptr, int base) {
    return (unsigned long long)strtoll(nptr, endptr, base);
}

double strtod(const char *nptr, char **endptr) {
    const char *s = nptr;
    while (isspace((unsigned char)*s)) s++;
    int sign = 1;
    if (*s == '-') { sign = -1; s++; }
    else if (*s == '+') { s++; }
    int digits_found = 0;
    double val = 0.0;
    while (isdigit((unsigned char)*s)) {
        val = val * 10.0 + (*s - '0');
        s++;
        digits_found++;
    }
    if (*s == '.') {
        s++;
        double frac = 0.1;
        while (isdigit((unsigned char)*s)) {
            val += (*s - '0') * frac;
            frac *= 0.1;
            s++;
            digits_found++;
        }
    }
    if (digits_found == 0) {
        if (endptr) *endptr = (char *)nptr;
        return 0.0;
    }
    if (*s == 'e' || *s == 'E') {
        const char *exp_start = s;
        s++;
        int exp_sign = 1;
        if (*s == '-') { exp_sign = -1; s++; }
        else if (*s == '+') { s++; }
        int exp_val = 0;
        int exp_digits = 0;
        while (isdigit((unsigned char)*s)) {
            exp_val = exp_val * 10 + (*s - '0');
            s++;
            exp_digits++;
        }
        if (exp_digits == 0) {
            s = exp_start;
        } else {
            double factor = 1.0;
            for (int i = 0; i < exp_val; i++) factor *= 10.0;
            if (exp_sign < 0) val /= factor;
            else val *= factor;
        }
    }
    if (endptr) *endptr = (char *)s;
    return sign * val;
}

/* Print formatting: C99 subset (flags -0+ #, width, precision, hh/h/l/ll/z/j/t,
 * d i u o x X c s p f F e E g G %). Returns the number of bytes written
 * (clamped), which callers use to advance cursors safely. */
typedef struct {
    char *cur;
    size_t rem;
    size_t written;
} FmtOut;

static void fmt_putc(FmtOut *o, char c) {
    if (o->rem > 1) {
        *o->cur++ = c;
        o->rem--;
        o->written++;
    }
}

static void fmt_pad(FmtOut *o, char c, int n) {
    while (n-- > 0) fmt_putc(o, c);
}

/* Emits prefix + (zero padding) + body honoring width and '-' / '0' flags */
static void fmt_field(FmtOut *o, const char *prefix, const char *body, int body_len,
                      int width, int left, int zero) {
    int plen = (int)strlen(prefix);
    int pad = width - plen - body_len;
    if (pad < 0) pad = 0;
    if (!left && !zero) fmt_pad(o, ' ', pad);
    for (int i = 0; i < plen; i++) fmt_putc(o, prefix[i]);
    if (!left && zero) fmt_pad(o, '0', pad);
    for (int i = 0; i < body_len; i++) fmt_putc(o, body[i]);
    if (left) fmt_pad(o, ' ', pad);
}

static int fmt_utoa(unsigned long long v, int base, int upper, char *out) {
    char tmp[32];
    int n = 0;
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    do { tmp[n++] = digits[v % (unsigned)base]; v /= (unsigned)base; } while (v);
    for (int i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
    return n;
}

/* Exact decimal digit generation with a small fixed-size bignum, so results
 * match a correctly rounded libc (newlib on the device) digit for digit. */
#define FMT_BIG_WORDS 48

typedef struct {
    uint32_t w[FMT_BIG_WORDS];
    int n; /* used words, little endian */
} FmtBig;

static void big_set_u64(FmtBig *b, uint64_t v) {
    b->n = 0;
    while (v) { b->w[b->n++] = (uint32_t)v; v >>= 32; }
}

static void big_mul_small(FmtBig *b, uint32_t m) {
    uint64_t carry = 0;
    for (int i = 0; i < b->n; i++) {
        uint64_t t = (uint64_t)b->w[i] * m + carry;
        b->w[i] = (uint32_t)t;
        carry = t >> 32;
    }
    if (carry && b->n < FMT_BIG_WORDS) b->w[b->n++] = (uint32_t)carry;
}

static void big_mul_pow10(FmtBig *b, int k) {
    while (k >= 9) { big_mul_small(b, 1000000000u); k -= 9; }
    static const uint32_t p10[9] = { 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000 };
    if (k > 0) big_mul_small(b, p10[k]);
}

static void big_shl(FmtBig *b, int bits) {
    int words = bits / 32, rem = bits % 32;
    if (b->n == 0) return;
    if (rem) {
        uint32_t carry = 0;
        for (int i = 0; i < b->n; i++) {
            uint32_t nw = (b->w[i] << rem) | carry;
            carry = b->w[i] >> (32 - rem);
            b->w[i] = nw;
        }
        if (carry && b->n < FMT_BIG_WORDS) b->w[b->n++] = carry;
    }
    if (words) {
        int nn = b->n + words;
        if (nn > FMT_BIG_WORDS) nn = FMT_BIG_WORDS;
        for (int i = nn - 1; i >= words; i--) b->w[i] = b->w[i - words];
        for (int i = 0; i < words; i++) b->w[i] = 0;
        b->n = nn;
    }
}

static int big_cmp(const FmtBig *a, const FmtBig *b) {
    if (a->n != b->n) return a->n < b->n ? -1 : 1;
    for (int i = a->n - 1; i >= 0; i--) {
        if (a->w[i] != b->w[i]) return a->w[i] < b->w[i] ? -1 : 1;
    }
    return 0;
}

/* a -= b, requires a >= b */
static void big_sub(FmtBig *a, const FmtBig *b) {
    int64_t borrow = 0;
    for (int i = 0; i < a->n; i++) {
        int64_t t = (int64_t)a->w[i] - (i < b->n ? b->w[i] : 0) - borrow;
        borrow = t < 0;
        a->w[i] = (uint32_t)(t + (borrow ? ((int64_t)1 << 32) : 0));
    }
    while (a->n > 0 && a->w[a->n - 1] == 0) a->n--;
}

/* nsig (1..FMT_MAX_DIGITS) correctly rounded digits of v > 0; returns the
 * decimal exponent of the first digit. */
#define FMT_MAX_DIGITS 64

static void fmt_digits(double v, int nsig, char *digits, int *exp10) {
    uint64_t bits;
    memcpy(&bits, &v, sizeof(bits));
    int bexp = (int)((bits >> 52) & 0x7FF);
    uint64_t mant = bits & 0xFFFFFFFFFFFFFull;
    if (bexp == 0) bexp = 1; else mant |= 1ull << 52;
    bexp -= 1075; /* v = mant * 2^bexp */

    FmtBig num, den, tmp;
    big_set_u64(&num, mant);
    big_set_u64(&den, 1);
    if (bexp > 0) big_shl(&num, bexp); else big_shl(&den, -bexp);

    /* Estimate the exponent, then correct it exactly */
    int k = 0;
    double t = v;
    while (t >= 10.0) { t /= 10.0; k++; }
    while (t < 1.0) { t *= 10.0; k--; }
    if (k >= 0) big_mul_pow10(&den, k); else big_mul_pow10(&num, -k);
    if (big_cmp(&num, &den) < 0) { big_mul_small(&num, 10); k--; }
    tmp = den;
    big_mul_small(&tmp, 10);
    if (big_cmp(&num, &tmp) >= 0) { big_mul_small(&den, 10); k++; }

    for (int i = 0; i < nsig; i++) {
        int d = 0;
        while (big_cmp(&num, &den) >= 0) { big_sub(&num, &den); d++; }
        digits[i] = (char)('0' + d);
        if (i + 1 < nsig) big_mul_small(&num, 10);
    }
    /* Round half to even using the exact remainder */
    big_shl(&num, 1);
    int c = big_cmp(&num, &den);
    if (c > 0 || (c == 0 && ((digits[nsig - 1] - '0') & 1))) {
        int i = nsig - 1;
        while (i >= 0 && digits[i] == '9') digits[i--] = '0';
        if (i >= 0) {
            digits[i]++;
        } else {
            digits[0] = '1';
            for (int j = 1; j < nsig; j++) digits[j] = '0';
            k++;
        }
    }
    *exp10 = k;
}

/* Exponent of the first significant digit without rounding: 64 digits never
 * carry for a finite double, since its exact expansion has no 64-nine run. */
static int fmt_raw_exp10(double v, char *digits64) {
    int e = 0;
    fmt_digits(v, FMT_MAX_DIGITS, digits64, &e);
    return e;
}

static int fmt_float(double v, char conv, int prec, int alt, char *out, int cap) {
    int n = 0;
    if (v != v) { memcpy(out, (conv >= 'a') ? "nan" : "NAN", 3); return 3; }
    if (v > 1.7976931348623157e308) { memcpy(out, (conv >= 'a') ? "inf" : "INF", 3); return 3; }
    if (prec < 0) prec = 6;
    char lower = (char)(conv | 0x20);
    char digits[FMT_MAX_DIGITS + 2];
    int e10 = 0;

    if (lower == 'g') {
        int p = prec == 0 ? 1 : (prec > FMT_MAX_DIGITS ? FMT_MAX_DIGITS : prec);
        if (v == 0.0) e10 = 0;
        else fmt_digits(v, p, digits, &e10);
        char sub;
        if (e10 < -4 || e10 >= p) { sub = 'e'; prec = p - 1; }
        else { sub = 'f'; prec = p - 1 - e10; }
        if (conv == 'G') sub = (char)(sub - 32);
        n = fmt_float(v, sub, prec, alt, out, cap);
        if (!alt) {
            /* %g strips trailing zeros from the fraction */
            int epos = n;
            for (int i = 0; i < n; i++) if (out[i] == 'e' || out[i] == 'E') { epos = i; break; }
            int dot = -1;
            for (int i = 0; i < epos; i++) if (out[i] == '.') { dot = i; break; }
            if (dot >= 0) {
                int end = epos;
                while (end > dot + 1 && out[end - 1] == '0') end--;
                if (end == dot + 1) end = dot;
                memmove(out + end, out + epos, (size_t)(n - epos));
                n = end + (n - epos);
            }
        }
        return n;
    }

    if (lower == 'e') {
        int nsig = prec + 1 > FMT_MAX_DIGITS ? FMT_MAX_DIGITS : prec + 1;
        if (v == 0.0) { e10 = 0; memset(digits, '0', (size_t)nsig); }
        else fmt_digits(v, nsig, digits, &e10);
        out[n++] = digits[0];
        if (prec > 0 || alt) out[n++] = '.';
        for (int i = 1; i <= prec && n < cap - 8; i++) out[n++] = i < nsig ? digits[i] : '0';
        out[n++] = (conv == 'E') ? 'E' : 'e';
        out[n++] = e10 < 0 ? '-' : '+';
        int ae = e10 < 0 ? -e10 : e10;
        if (ae < 10) out[n++] = '0';
        char eb[8];
        int el = fmt_utoa((unsigned long long)ae, 10, 0, eb);
        memcpy(out + n, eb, (size_t)el);
        return n + el;
    }

    /* 'f' */
    if (prec > 40) prec = 40;
    if (v == 0.0) {
        out[n++] = '0';
        if (prec > 0 || alt) out[n++] = '.';
        for (int i = 0; i < prec; i++) out[n++] = '0';
        return n;
    }
    char raw[FMT_MAX_DIGITS + 2];
    int e_guess = fmt_raw_exp10(v, raw);
    int nsig = e_guess + 1 + prec;
    if (nsig < 1) {
        /* Everything is below the last printed decimal: round to 0 or 1 ulp.
         * With nsig == 0 the first digit sits right after it: bump if > half. */
        int bump = 0;
        if (nsig == 0) {
            if (raw[0] > '5') bump = 1;
            else if (raw[0] == '5') {
                for (int i = 1; i < FMT_MAX_DIGITS; i++) if (raw[i] != '0') { bump = 1; break; }
            }
        }
        out[n++] = (prec == 0 && bump) ? '1' : '0';
        if (prec > 0 || alt) out[n++] = '.';
        for (int i = 0; i < prec; i++) out[n++] = (i == prec - 1 && bump) ? '1' : '0';
        return n;
    }
    if (nsig > FMT_MAX_DIGITS) nsig = FMT_MAX_DIGITS;
    fmt_digits(v, nsig, digits, &e10);
    int int_digits = e10 + 1;
    int di = 0;
    if (int_digits <= 0) {
        out[n++] = '0';
    } else {
        for (int i = 0; i < int_digits && n < cap - 2; i++) out[n++] = di < nsig ? digits[di++] : '0';
    }
    if (prec > 0 || alt) out[n++] = '.';
    for (int i = 0; i < prec && n < cap - 1; i++) {
        int pos = int_digits + i;
        if (pos < 0) out[n++] = '0';
        else out[n++] = di < nsig ? digits[di++] : '0';
    }
    return n;
}

int vsnprintf(char *str, size_t size, const char *fmt, va_list ap) {
    if (!str || size == 0) return 0;
    FmtOut o = { str, size, 0 };

    while (*fmt) {
        if (*fmt != '%') {
            fmt_putc(&o, *fmt++);
            continue;
        }
        fmt++;
        int left = 0, zero = 0, plus = 0, space = 0, alt = 0;
        for (;; fmt++) {
            if (*fmt == '-') left = 1;
            else if (*fmt == '0') zero = 1;
            else if (*fmt == '+') plus = 1;
            else if (*fmt == ' ') space = 1;
            else if (*fmt == '#') alt = 1;
            else break;
        }
        int width = 0;
        if (*fmt == '*') {
            width = va_arg(ap, int);
            if (width < 0) { left = 1; width = -width; }
            fmt++;
        } else {
            while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        }
        int prec = -1;
        if (*fmt == '.') {
            fmt++;
            prec = 0;
            if (*fmt == '*') { prec = va_arg(ap, int); fmt++; }
            else while (*fmt >= '0' && *fmt <= '9') prec = prec * 10 + (*fmt++ - '0');
        }
        int len_mod = 0; /* 0=int, 1=long, 2=long long, -1=short, -2=char */
        if (*fmt == 'h') { len_mod = -1; fmt++; if (*fmt == 'h') { len_mod = -2; fmt++; } }
        else if (*fmt == 'l') { len_mod = 1; fmt++; if (*fmt == 'l') { len_mod = 2; fmt++; } }
        else if (*fmt == 'z' || *fmt == 't') { len_mod = 1; fmt++; }
        else if (*fmt == 'j') { len_mod = 2; fmt++; }
        if (left) zero = 0;

        char conv = *fmt ? *fmt++ : '\0';
        char body[160];
        int blen = 0;
        switch (conv) {
            case 'd':
            case 'i': {
                long long v = (len_mod == 2) ? va_arg(ap, long long) :
                              (len_mod == 1) ? va_arg(ap, long) : va_arg(ap, int);
                if (len_mod == -1) v = (short)v;
                if (len_mod == -2) v = (signed char)v;
                const char *prefix = v < 0 ? "-" : (plus ? "+" : (space ? " " : ""));
                unsigned long long uv = v < 0 ? (unsigned long long)(-(v + 1)) + 1 : (unsigned long long)v;
                blen = (prec == 0 && uv == 0) ? 0 : fmt_utoa(uv, 10, 0, body);
                if (prec >= 0) {
                    zero = 0;
                    if (blen < prec) {
                        memmove(body + (prec - blen), body, (size_t)blen);
                        memset(body, '0', (size_t)(prec - blen));
                        blen = prec;
                    }
                }
                fmt_field(&o, prefix, body, blen, width, left, zero);
                break;
            }
            case 'u':
            case 'x':
            case 'X':
            case 'o': {
                unsigned long long v = (len_mod == 2) ? va_arg(ap, unsigned long long) :
                                       (len_mod == 1) ? va_arg(ap, unsigned long) : va_arg(ap, unsigned int);
                if (len_mod == -1) v = (unsigned short)v;
                if (len_mod == -2) v = (unsigned char)v;
                int base = (conv == 'u') ? 10 : (conv == 'o') ? 8 : 16;
                blen = (prec == 0 && v == 0) ? 0 : fmt_utoa(v, base, conv == 'X', body);
                if (prec >= 0) {
                    zero = 0;
                    if (blen < prec) {
                        memmove(body + (prec - blen), body, (size_t)blen);
                        memset(body, '0', (size_t)(prec - blen));
                        blen = prec;
                    }
                }
                const char *prefix = (alt && v != 0 && base == 16) ? (conv == 'X' ? "0X" : "0x") :
                                     (alt && base == 8) ? "0" : "";
                fmt_field(&o, prefix, body, blen, width, left, zero);
                break;
            }
            case 'p': {
                uintptr_t v = (uintptr_t)va_arg(ap, void *);
                blen = fmt_utoa((unsigned long long)v, 16, 0, body);
                fmt_field(&o, "0x", body, blen, width, left, 0);
                break;
            }
            case 'c': {
                body[0] = (char)va_arg(ap, int);
                fmt_field(&o, "", body, 1, width, left, 0);
                break;
            }
            case 's': {
                const char *sv = va_arg(ap, const char *);
                if (!sv) sv = "(null)";
                int sl = 0;
                while (sv[sl] && (prec < 0 || sl < prec)) sl++;
                int pad = width - sl;
                if (!left) fmt_pad(&o, ' ', pad);
                for (int i = 0; i < sl; i++) fmt_putc(&o, sv[i]);
                if (left) fmt_pad(&o, ' ', pad);
                break;
            }
            case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': {
                double v = va_arg(ap, double);
                int neg = (v < 0) || (v == 0.0 && 1.0 / v < 0);
                if (neg) v = -v;
                blen = fmt_float(v, conv, prec, alt, body, (int)sizeof(body));
                const char *prefix = neg ? "-" : (plus ? "+" : (space ? " " : ""));
                if (v != v || v > 1.7976931348623157e308) zero = 0;
                fmt_field(&o, prefix, body, blen, width, left, zero);
                break;
            }
            case '%':
                fmt_putc(&o, '%');
                break;
            case '\0':
                break;
            default:
                fmt_putc(&o, '%');
                fmt_putc(&o, conv);
                break;
        }
        if (conv == '\0') break;
    }
    *o.cur = '\0';
    return (int)o.written;
}

int snprintf(char *str, size_t size, const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    int res = vsnprintf(str, size, format, ap);
    va_end(ap);
    return res;
}

int sprintf(char *str, const char *format, ...) {
    va_list ap;
    va_start(ap, format);
    int res = vsnprintf(str, 65536, format, ap);
    va_end(ap);
    return res;
}

int printf(const char *format, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, format);
    int res = vsnprintf(buf, sizeof(buf), format, ap);
    va_end(ap);
    js_print(buf, res);
    return res;
}

int puts(const char *s) {
    size_t len = strlen(s);
    js_print(s, (int)len);
    js_print("\n", 1);
    return (int)len + 1;
}

int putchar(int c) {
    char ch = (char)c;
    js_print(&ch, 1);
    return c;
}

int fprintf(FILE *stream, const char *format, ...) {
    (void)stream;
    char buf[1024];
    va_list ap;
    va_start(ap, format);
    int res = vsnprintf(buf, sizeof(buf), format, ap);
    va_end(ap);
    js_print(buf, res);
    return res;
}

void qsort(void *base, size_t nmemb, size_t size, int (*compar)(const void *, const void *)) {
    char *arr = (char *)base;
    for (size_t i = 0; i < nmemb; i++) {
        for (size_t j = i + 1; j < nmemb; j++) {
            if (compar(arr + i * size, arr + j * size) > 0) {
                for (size_t k = 0; k < size; k++) {
                    char tmp = arr[i * size + k];
                    arr[i * size + k] = arr[j * size + k];
                    arr[j * size + k] = tmp;
                }
            }
        }
    }
}

size_t fwrite(const void *ptr, size_t sz, size_t n, FILE *f) {
    (void)f;
    size_t total = sz * n;
    if (total > 0) js_print((const char *)ptr, (int)total);
    return n;
}

int fputs(const char *s, FILE *f) {
    (void)f;
    size_t len = strlen(s);
    if (len > 0) js_print(s, (int)len);
    return (int)len;
}

int fputc(int c, FILE *f) {
    (void)f;
    char ch = (char)c;
    js_print(&ch, 1);
    return c;
}

FILE *fopen(const char *path, const char *mode) { (void)path; (void)mode; return NULL; }
int fclose(FILE *f) { (void)f; return 0; }
size_t fread(void *ptr, size_t sz, size_t n, FILE *f) { (void)ptr; (void)sz; (void)n; (void)f; return 0; }
int fseek(FILE *f, long off, int whence) { (void)f; (void)off; (void)whence; return -1; }
long ftell(FILE *f) { (void)f; return -1; }
int setvbuf(FILE *f, char *buf, int mode, size_t size) { (void)f; (void)buf; (void)mode; (void)size; return 0; }
int fflush(FILE *f) { (void)f; return 0; }
int remove(const char *path) { (void)path; return -1; }
void exit(int code) { (void)code; while (1) {} }
int system(const char *cmd) { (void)cmd; return -1; }

