#ifndef KTEXTEDIT_H_190603
#define KTEXTEDIT_H_190603
#include "AtomicWidget.h"

class QPlainTextEdit;

class KTextEdit : public AtomicWidget
{
  Q_OBJECT

  QPlainTextEdit *textEdit;

public:
  KTextEdit(QWidget *parent = nullptr);

  std::shared_ptr<conf::Value const> getValue() const;
  void setEnabled(bool);

public slots:
  bool setValue(std::string const &, std::shared_ptr<conf::Value const>);
};

#endif
