#ifndef KVALUE_H_190506
#define KVALUE_H_190506
#include <string>
#include <optional>
#include <memory>
#include <QObject>
#include <QString>
#include "confValue.h"
#include "confKey.h"
#include "UserIdentity.h"

class KValue : public QObject
{
  Q_OBJECT

public:
  std::shared_ptr<conf::Value> val; // may not be set
  QString uid;  // Of the user who has set this value
  double mtime;
  std::optional<QString> owner;
  double expiry;  // if owner above is set

  KValue() {}

  KValue(const KValue &other) : QObject() {
    owner = other.owner;
    val = other.val;
  }

  void set(conf::Key const &, std::shared_ptr<conf::Value>, QString const &, double);
  bool isSet() const {
    return val != nullptr;
  }
  bool isLocked() const {
    return isSet() && owner.has_value();
  }
  bool isMine() const {
    return isLocked() && *owner == my_uid;
  }
  void lock(conf::Key const &, QString const &, double);
  void unlock(conf::Key const &);

  KValue& operator=(const KValue &other) {
    owner = other.owner;
    val = other.val;
    return *this;
  }

signals:
  /* Always Once::connect to valueCreated or it will be called several times
   * on the same KValue (due to autoconnect) */
  void valueCreated(conf::Key const &, std::shared_ptr<conf::Value const>, QString const &, double) const;
  void valueChanged(conf::Key const &, std::shared_ptr<conf::Value const>, QString const &, double) const;
  void valueLocked(conf::Key const &, QString const &uid, double expiry) const;
  void valueUnlocked(conf::Key const &) const;
  void valueDeleted(conf::Key const &) const;
};

#endif
