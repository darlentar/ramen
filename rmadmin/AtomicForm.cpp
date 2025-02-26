#include <QDebug>
#include <QVBoxLayout>
#include <QHBoxLayout>
#include <QPushButton>
#include <QMessageBox>
#include "conf.h"
#include "AtomicWidget.h"
#include "AtomicForm.h"

static bool const verbose = true;

AtomicForm::AtomicForm(QWidget *parent) :
  QWidget(parent),
  widgets()
{
  widgets.reserve(5);

  groupLayout = new QVBoxLayout(this);
  groupLayout->setContentsMargins(QMargins());
  setLayout(groupLayout);

  /* So we want 3 vertical areas:
   * - the "central widget" (to be set later)
   * - an error area
   * - the button bar "edit" / "cancel"+"submit"
   */
  // The central widget
  centralWidget = new QWidget;
  groupLayout->addWidget(centralWidget, 1);

  // The errors area
  errorArea = new QWidget;
  groupLayout->addWidget(errorArea);

  /* The button bar
   * According to MacOS UI guidelines, actions are supposed to be at right
   * and cancellation/going back on the left.
   * We keep the rightmost position for the "submit" action and keep
   * "delete" before it, in fear that users might go for the right-most
   * button out of habit. */
  buttonsLayout = new QHBoxLayout;
  editButton = new QPushButton(tr("&edit"));
  buttonsLayout->addWidget(editButton);
  connect(editButton, &QPushButton::clicked, this, &AtomicForm::wantEdit);

  cancelButton = new QPushButton(tr("&cancel"));
  buttonsLayout->addWidget(cancelButton);
  connect(cancelButton, &QPushButton::clicked, this, &AtomicForm::wantCancel);
  cancelButton->setEnabled(false);

  deleteButton = new QPushButton(tr("&delete"));
  buttonsLayout->addWidget(deleteButton);
  connect(deleteButton, &QPushButton::clicked, this, &AtomicForm::wantDelete);
  deleteButton->setEnabled(false);
  deleteButton->hide(); // until a deletable widget is added

  submitButton = new QPushButton(tr("&submit"));
  buttonsLayout->addWidget(submitButton);
  connect(submitButton, &QPushButton::clicked, this, &AtomicForm::wantSubmit);
  submitButton->setEnabled(false);

  groupLayout->addLayout(buttonsLayout);

  /* Also prepare the confirmation dialogs: */
  confirmCancelDialog = new QMessageBox(this);
  confirmCancelDialog->setText("Some values have been modified.");
  confirmCancelDialog->setInformativeText("Are you sure you want to cancel?");
  confirmCancelDialog->setStandardButtons(QMessageBox::Yes | QMessageBox::No);
  confirmCancelDialog->setDefaultButton(QMessageBox::No);
  confirmCancelDialog->setIcon(QMessageBox::Warning);
  // Would crash:
  //confirmDeleteDialog->setWindowModality(Qt::WindowModal);

  confirmDeleteDialog = new QMessageBox(this);
  confirmDeleteDialog->setText("Are you sure you want to delete this?");
  confirmDeleteDialog->setStandardButtons(QMessageBox::Yes | QMessageBox::Cancel);
  confirmDeleteDialog->setDefaultButton(QMessageBox::Cancel);
  confirmDeleteDialog->setIcon(QMessageBox::Warning);
  //confirmDeleteDialog->setWindowModality(Qt::WindowModal);

  // Listen to kvs changes:
  connect(&kvs, &KVStore::valueLocked, this, &AtomicForm::lockValue);
  connect(&kvs, &KVStore::valueUnlocked, this, &AtomicForm::unlockValue);
  connect(&kvs, &KVStore::valueDeleted, this, &AtomicForm::unlockValue);
}

AtomicForm::~AtomicForm()
{
  // Unlock everything that's locked:
  for (std::string const &k : locked) {
    if (verbose) qDebug() << "Unlocking" << QString::fromStdString(k);
    askUnlock(k);
  }
}

void AtomicForm::setCentralWidget(QWidget *w)
{
  QLayoutItem *previous =
    groupLayout->replaceWidget(centralWidget, w, Qt::FindDirectChildrenOnly);
  assert(previous);
  delete previous;
  /* Do not automatically add to the widget as the form central widget
   * need not be an AtomicWidget. */
}

void AtomicForm::addWidget(AtomicWidget *aw, bool deletable)
{
  widgets.emplace_back(*aw);
  if (deletable) {
    deletables.insert(aw);
    deleteButton->show();
  }

  connect(aw, &AtomicWidget::keyChanged,
          this, &AtomicForm::changeKey);

  // If key is already set, start from it:
  if (aw->key.length() > 0)
    changeKey(std::string(), aw->key);

  setEnabled(locked.size() >= widgets.size());
}

void AtomicForm::changeKey(std::string const &, std::string const &newKey)
{
  kvs.lock.lock_shared();

  std::optional<QString> owner;

  if (newKey.length() > 0) {
    auto it = kvs.map.find(newKey);
    if (it != kvs.map.end())
      if (it->second.isLocked())
        owner = it->second.owner;
  }

  setOwner(newKey, owner);

  kvs.lock.unlock_shared();
}

void AtomicForm::wantEdit()
{
  // Lock all widgets that are not locked already:
  for (FormWidget const &w : widgets) {
    if (locked.find(w.widget.key) == locked.end()) {
      askLock(w.widget.key);
    }
  }
}

bool AtomicForm::someEdited()
{
  for (FormWidget const &w : widgets) {
    std::shared_ptr<conf::Value const> v(w.widget.getValue());
    if (! v) return false;
    if (! w.initValue) {
      if (verbose)
        qDebug() << "Value of" << QString::fromStdString(w.widget.key)
                 << "has been set to " << *v;
      return true;
    }
    if (*w.initValue != *v) {
      if (verbose)
        qDebug() << "Value of" << QString::fromStdString(w.widget.key)
                 << "has changed from " << *w.initValue << "to" << *v;
      return true;
    }
  }
  return false;
}

void AtomicForm::doCancel()
{
  for (FormWidget &w : widgets) {
    w.widget.setValue(w.widget.key, w.initValue);
    askUnlock(w.widget.key);
  }
}

void AtomicForm::wantCancel()
{
  if (someEdited()) {
    if (QMessageBox::Yes == confirmCancelDialog->exec()) {
      doCancel();
    }
  } else {
    doCancel();
  }
}

void AtomicForm::wantDelete()
{
  if (deletables.empty()) return;

  QString info(tr("Those keys will be lost forever:\n"));
  for (AtomicWidget *aw : deletables) {
    info.append(QString::fromStdString(aw->key));
    info.append("\n");
  }
  confirmDeleteDialog->setInformativeText(info);

  if (QMessageBox::Yes == confirmDeleteDialog->exec()) {
    for (AtomicWidget *aw : deletables) {
      askDel(aw->key);
    }
  }
}

void AtomicForm::doSubmit()
{
  for (FormWidget &w : widgets) {
    std::shared_ptr<conf::Value const> v(w.widget.getValue());
    if (v && (! w.initValue || *v != *w.initValue))
      askSet(w.widget.key, v);
    askUnlock(w.widget.key);
  }
}

void AtomicForm::wantSubmit()
{
  if (someEdited()) {
    doSubmit();
  } else {
    if (verbose)
      qDebug() << "Cancelling rather, as no edition was done.";
    doCancel();
  }
}

void AtomicForm::setEnabled(bool enabled)
{
  bool const wasEnabled = isEnabled();

  if (enabled == wasEnabled) return;

  if (verbose)
    qDebug() << "AtomicForm::setEnabled(" << enabled << ")";

  /* Capture the widget initial value if we are enabling edition: */
  if (enabled)
    for (FormWidget &w : widgets)
      w.initValue = w.widget.getValue();

  // An enabled form is a form that's editable:
  editButton->setEnabled(! enabled);
  cancelButton->setEnabled(enabled);
  deleteButton->setEnabled(enabled);
  submitButton->setEnabled(enabled);

  emit changeEnabled(enabled);
}

bool AtomicForm::isMyKey(std::string const &k) const
{
  for (FormWidget const &w : widgets) {
    if (w.widget.key == k) return true;
  }
  return false;
}

void AtomicForm::lockValue(std::string const &key, KValue const &kv)
{
  if (! isMyKey(key)) return;
  setOwner(key, kv.owner);
}

void AtomicForm::setOwner(std::string const &k, std::optional<QString> const &u)
{
  bool const is_me = my_uid && u.has_value() && *my_uid == *u;

  if (verbose)
    qDebug() << "locked key" << QString::fromStdString(k) << "to user "
             << (u.has_value() ? *u : "none")
             << "(I am" << *my_uid
             << (is_me ? ", that's me!)" : ", not me)");
  if (is_me) {
    locked.insert(k);
  } else {
    locked.erase(k);
  }
  if (locked.size() >= widgets.size()) setEnabled(true);
}

bool AtomicForm::isEnabled() const
{
  return cancelButton->isEnabled();
}

void AtomicForm::unlockValue(std::string const &key, KValue const &)
{
  if (! isMyKey(key)) return;

  locked.erase(key);
  if (locked.size() <= widgets.size()) setEnabled(false);
}
