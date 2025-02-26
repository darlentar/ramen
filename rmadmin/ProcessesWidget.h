#ifndef PROCESSESWIDGET_H_190806
#define PROCESSESWIDGET_H_190806
#include <memory>
#include <bitset>
#include <QWidget>
#include "GraphModel.h"

/* A tree to display the sites/programs/workers. */

class QTreeView;
class QLineEdit;
class QTimer;
class ProcessesWidgetProxy;
class ProgramItem;
struct Program;
class Function;

class ProcessesWidget : public QWidget
{
  Q_OBJECT

  QTimer *adjustColumnTimer;
  std::bitset<GraphModel::NumColumns> needResizing;

public:
  QTreeView *treeView;
  QLineEdit *searchBox;
  QWidget *searchFrame;
  ProcessesWidgetProxy *proxyModel;

  ProcessesWidget(GraphModel *, QWidget *parent = nullptr);

  QSize sizeHint() const { return QSize(700, 300); }

public slots:
  /* Flag those columns as needing adjustment and start a timer: */
  void askAdjustColumnSize(
    QModelIndex const &, QModelIndex const &, QVector<int> const &);
  /* Do adjust column size now: */
  void adjustColumnSize();
  void adjustAllColumnSize();
  void openSearch();
  void changeSearch(QString const &);
  void closeSearch();
  void wantEdit(std::shared_ptr<Program const>);
  void wantTable(std::shared_ptr<Function>);
  void activate(QModelIndex const &);
  void expandRows(QModelIndex const &parent, int first, int last);
};

#endif
