#ifndef ATOMICFORM_H_190504
#define ATOMICFORM_H_190504
#include <vector>
#include <set>
#include <optional>
#include <QWidget>
#include <QString>
#include "confValue.h"

/* We want to be able to edit a group of values atomically.
 * For this, we need this group of widget to be associated with 3 buttons:
 * "edit", "cancel" and "commit".
 *
 * We are passed a list of KWidgets (Keyed-Widget), which must have a
 * setEnabled(bool) slot (all QWidgets have this one),
 * and they must have a method to get the confValue out of it, that we call
 * when we commit the form and when we click "edit" to save the initial
 * values.
 *
 * Then this class will lock all the keys (then wait for them to be actually
 * locked before making the widget editable (thanks to the notifications)
 * and the cancel/submit buttons clickable), display errors, etc.
 *
 * Regarding the layout, this class does not mess with the layout of the
 * passed widgets (assuming they are laid out already).
 * The simpler would be to build it like the MainApplication window is build:
 * ie we have an empty widget where the user add one by one the widgets that
 * he want, some of them being atomic widgets and some of them being normal
 * widgets. And then atomic form adds ots buttons below.
 * We therefore just offer an "add" method, and use introspection to know
 * it the user adds an atomic widget to register it in the atomic group.
 */

class AtomicWidget;
struct KValue;
class QVBoxLayout;
class QHBoxLayout;
class QPushButton;
class QMessageBox;

class AtomicForm : public QWidget
{
  Q_OBJECT

  struct FormWidget {
    AtomicWidget &widget;
    /* Changes are detected by comparing the value stored in the widget at the
     * time it is enabled with the value stored in the widget when the used
     * submits or cancels it. */
    std::shared_ptr<conf::Value const> initValue;

    FormWidget(AtomicWidget &widget_) :
      widget(widget_), initValue(nullptr) {}
  };

  std::vector<FormWidget> widgets;
  std::set<AtomicWidget *> deletables;

  QVBoxLayout *groupLayout;
  QWidget *errorArea;
  QPushButton *editButton, *cancelButton, *deleteButton, *submitButton;
  QMessageBox *confirmCancelDialog, *confirmDeleteDialog;

  // The set of all keys currently locked by this user:
  std::set<std::string> locked;

  void wantEdit();
  void wantCancel();
  void wantDelete();
  void wantSubmit();
  void doCancel();
  void doSubmit();
  bool someEdited();

public:
  QWidget *centralWidget;

  AtomicForm(QWidget *parent = nullptr);

  ~AtomicForm();

  void setCentralWidget(QWidget *);
  // and take ownership of those QWidgets:
  void addWidget(AtomicWidget *, bool deletable = false);

  // In case one want to add buttons in there:
  QHBoxLayout *buttonsLayout;

  // Similar to lockValue, once we already know the key is our:
  void setOwner(std::string const &, std::optional<QString> const &);

  bool isEnabled() const;

protected:
  bool isMyKey(std::string const &) const;

public slots:
  void setEnabled(bool);
  void lockValue(std::string const &, KValue const &);
  void unlockValue(std::string const &, KValue const &);
  void changeKey(std::string const &oldKey, std::string const &newKey);

signals:
  void changeEnabled(bool);
};

#endif
