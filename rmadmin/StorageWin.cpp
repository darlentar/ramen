#include <QLabel>
#include "StorageView.h"
#include "GraphModel.h"
#include "StorageWin.h"

StorageWin::StorageWin(QWidget *parent) :
  SavedWindow("Storage", tr("Storage"), parent)
{
  if (GraphModel::globalGraphModel) {
    StorageView *storageView = new StorageView(GraphModel::globalGraphModel);
    setCentralWidget(storageView);
  } else {
    QString errMsg(tr("No graph model yet!?"));
    setCentralWidget(new QLabel(errMsg));
    // Better luck next time?
    setAttribute(Qt::WA_DeleteOnClose);
  }
}
