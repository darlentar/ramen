#ifndef ATOMICWIDGET_H_190506
#define ATOMICWIDGET_H_190506
/* What an AtomicForm remembers about its widgets */
#include <QWidget>
#include <memory>
#include "confKey.h"
#include "confValue.h"
#include "conf.h"

class AtomicWidget
{
  bool last_enabled;

public:
  conf::Key const key;
  std::shared_ptr<conf::Value const> initValue; // shared ptr

  AtomicWidget(conf::Key const &key_) :
    last_enabled(true),
    key(key_)
  {
  }

  virtual ~AtomicWidget() {}

  virtual void setEnabled(bool enabled)
  {
    if (enabled && !last_enabled) {
      // Capture the value at the beginning of edition:
     initValue = getValue();
    }
    last_enabled = enabled;
  }

  virtual std::shared_ptr<conf::Value const> getValue() const = 0;
  virtual void setValue(conf::Key const &, std::shared_ptr<conf::Value const>) = 0;

  void lockValue(conf::Key const &, QString const &uid)
  {
    setEnabled(uid == conf::my_uid);
  }
  void unlockValue(conf::Key const &)
  {
    setEnabled(false);
  }
};

#endif
