#ifndef KVALUE_H_190506
#define KVALUE_H_190506
#include <string>
#include <optional>
#include <memory>
#include <QString>
#include "UserIdentity.h"

namespace conf {
  class Value;
};

struct KValue
{
  std::shared_ptr<conf::Value> val; // always set
  QString uid;  // Of the user who has set this value
  double mtime;
  std::optional<QString> owner;
  double expiry;  // if owner above is set
  bool can_write, can_del;

  KValue(std::shared_ptr<conf::Value> v, QString const &u, double mt,
         bool cw, bool cd) :
    val(v), uid(u), mtime(mt), can_write(cw), can_del(cd) {}

  KValue() {}

  void set(std::shared_ptr<conf::Value> v, QString const &u, double mt)
  {
    val = v;
    uid = u;
    mtime = mt;
  }

  void setLock(QString const &o, double ex)
  {
    owner = o;
    expiry = ex;
  }

  void setUnlock()
  {
    assert(owner.has_value());
    owner.reset();
  }

  bool isLocked() const {
    return owner.has_value();
  }
  bool isMine() const {
    return isLocked() && *owner == my_uid;
  }
};

Q_DECLARE_METATYPE(KValue);

#endif
