#ifndef DDCHECK_H
#define DDCHECK_H

#define DDCHECK_NUNITS 16
#define DDCHECK_NFUNCS 40

typedef double (*mu_fn)(const double *x, int n);

extern const mu_fn mu_table_0[DDCHECK_NFUNCS];
extern const mu_fn mu_table_1[DDCHECK_NFUNCS];
extern const mu_fn mu_table_2[DDCHECK_NFUNCS];
extern const mu_fn mu_table_3[DDCHECK_NFUNCS];
extern const mu_fn mu_table_4[DDCHECK_NFUNCS];
extern const mu_fn mu_table_5[DDCHECK_NFUNCS];
extern const mu_fn mu_table_6[DDCHECK_NFUNCS];
extern const mu_fn mu_table_7[DDCHECK_NFUNCS];
extern const mu_fn mu_table_8[DDCHECK_NFUNCS];
extern const mu_fn mu_table_9[DDCHECK_NFUNCS];
extern const mu_fn mu_table_10[DDCHECK_NFUNCS];
extern const mu_fn mu_table_11[DDCHECK_NFUNCS];
extern const mu_fn mu_table_12[DDCHECK_NFUNCS];
extern const mu_fn mu_table_13[DDCHECK_NFUNCS];
extern const mu_fn mu_table_14[DDCHECK_NFUNCS];
extern const mu_fn mu_table_15[DDCHECK_NFUNCS];

/* The table of tables lives in tables.c so main() doesn't have to know how
   many units there are. */
extern const mu_fn *const mu_tables[DDCHECK_NUNITS];

#endif
