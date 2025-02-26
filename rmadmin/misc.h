#ifndef MISC_H_190603
#define MISC_H_190603
#include <string>

#define SIZEOF_ARRAY(x) (sizeof(x) / sizeof(*(x)))

typedef unsigned __int128 uint128_t;
typedef __int128 int128_t;

bool startsWith(std::string const &, std::string const &);
bool endsWith(std::string const &, std::string const &);

// Remove everything after and including the last occurrence of the given char
std::string const removeExt(std::string const &, char const);

// Remove the optional program name suffix:
std::string const srcPathFromProgramName(std::string const &);
// The other way around: extract the suffix from a program name
std::string const suffixFromProgramName(std::string const &);

std::ostream &operator<<(std::ostream &, int128_t const &);
std::ostream &operator<<(std::ostream &, uint128_t const &);

#include <QString>

QString const removeExtQ(QString const &, char const);

bool looks_like_true(QString);

QString const stringOfDate(double);
QString const stringOfDuration(double);
QString const stringOfBytes(size_t);

class QLayout;

void emptyLayout(QLayout *);

std::string demangle(const char *);

/* There are a few global variables that are used if not NULL. When they are
 * deleted, the global variable has to be invalidated before destruction
 * begins. */
template<class T>
void danceOfDel(T **t)
{
  if (! *t) return;

  T *tmp = *t;
  *t = nullptr;
  delete tmp;
}

/* Don't be too strict when comparing edited values for equality: */

bool isClose(double v1, double v2, double prec = 1e-6);

// Expand a tree view recursively from a parent:
class QModelIndex;
class QTreeView;
void expandAllFromParent(QTreeView *, QModelIndex const &, int first, int last);

#endif
