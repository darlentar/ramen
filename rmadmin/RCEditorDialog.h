#ifndef RCEDITORDIALOG_H_190809
#define RCEDITORDIALOG_H_190809
#include "SavedWindow.h"

class TargetConfigEditor;
class QMessageBox;
class QString;

class RCEditorDialog : public SavedWindow
{
  Q_OBJECT

  TargetConfigEditor *targetConfigEditor;

  QMessageBox *confirmDeleteDialog;
public:
  RCEditorDialog(QWidget *parent = nullptr);

  void preselect(QString const &programName);

protected slots:
  void wantDeleteEntry();
};

#endif
