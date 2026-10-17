#ifndef WASM_LIBC_H
#define WASM_LIBC_H

#ifdef __wasm__

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdarg.h>

#ifndef UINTPTR_MAX
#define UINTPTR_MAX 0xffffffffU
#endif
#ifndef PTRDIFF_MAX
#define PTRDIFF_MAX 0x7fffffff
#endif

/* Character types */
static inline int isdigit(int c) { return c >= '0' && c <= '9'; }
static inline int isspace(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'; }
static inline int isalpha(int c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
static inline int isalnum(int c) { return isalpha(c) || isdigit(c); }
static inline int tolower(int c) { return (c >= 'A' && c <= 'Z') ? (c + 32) : c; }
static inline int toupper(int c) { return (c >= 'a' && c <= 'z') ? (c - 32) : c; }
static inline int abs(int x) { return x < 0 ? -x : x; }

/* Memory functions */
void *malloc(size_t sz);
void free(void *ptr);
void *calloc(size_t n, size_t sz);
void *realloc(void *ptr, size_t sz);

void *memcpy(void *dst, const void *src, size_t n);
void *memset(void *dst, int val, size_t n);
void *memmove(void *dst, const void *src, size_t n);
int memcmp(const void *s1, const void *s2, size_t n);

/* String functions */
size_t strlen(const char *s);
char *strcpy(char *dst, const char *src);
char *strncpy(char *dst, const char *src, size_t n);
int strcmp(const char *s1, const char *s2);
int strncmp(const char *s1, const char *s2, size_t n);
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strstr(const char *haystack, const char *needle);
char *strcat(char *dst, const char *src);

double strtod(const char *nptr, char **endptr);
long long strtoll(const char *nptr, char **endptr, int base);
unsigned long long strtoull(const char *nptr, char **endptr, int base);

/* File IO stubs */
typedef void FILE;
#define stdin  ((FILE*)1)
#define stdout ((FILE*)2)
#define stderr ((FILE*)3)

/* IO / Print */
int vsnprintf(char *str, size_t size, const char *format, va_list ap);
int snprintf(char *str, size_t size, const char *format, ...);
int sprintf(char *str, const char *format, ...);
int printf(const char *format, ...);
int fprintf(FILE *stream, const char *format, ...);
int putchar(int c);
int puts(const char *s);


void qsort(void *base, size_t nmemb, size_t size, int (*compar)(const void *, const void *));

/* JS imported IO */
__attribute__((import_module("env"), import_name("js_print"))) void js_print(const char *str, int len);

/* Math functions */
static inline double sqrt(double x) { return __builtin_sqrt(x); }
static inline double fabs(double x) { return __builtin_fabs(x); }
static inline double floor(double x) { return __builtin_floor(x); }
static inline double ceil(double x) { return __builtin_ceil(x); }
static inline double round(double x) { return __builtin_round(x); }
static inline double trunc(double x) { return __builtin_trunc(x); }

__attribute__((import_module("env"), import_name("sin"))) double sin(double x);
__attribute__((import_module("env"), import_name("cos"))) double cos(double x);
__attribute__((import_module("env"), import_name("tan"))) double tan(double x);
__attribute__((import_module("env"), import_name("asin"))) double asin(double x);
__attribute__((import_module("env"), import_name("acos"))) double acos(double x);
__attribute__((import_module("env"), import_name("atan"))) double atan(double x);
__attribute__((import_module("env"), import_name("atan2"))) double atan2(double y, double x);
__attribute__((import_module("env"), import_name("pow"))) double pow(double x, double y);
__attribute__((import_module("env"), import_name("log"))) double log(double x);
__attribute__((import_module("env"), import_name("exp"))) double exp(double x);
double exp2(double x);

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2


FILE *fopen(const char *path, const char *mode);
int fclose(FILE *f);
size_t fread(void *ptr, size_t sz, size_t n, FILE *f);
size_t fwrite(const void *ptr, size_t sz, size_t n, FILE *f);
int fputs(const char *s, FILE *f);
int fputc(int c, FILE *f);
int fseek(FILE *f, long off, int whence);
long ftell(FILE *f);
#define _IONBF 2
int setvbuf(FILE *f, char *buf, int mode, size_t size);
int fflush(FILE *f);
int remove(const char *path);
void exit(int code);
int system(const char *cmd);

#else /* !__wasm__ */

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>

#endif /* __wasm__ */

#endif /* WASM_LIBC_H */

